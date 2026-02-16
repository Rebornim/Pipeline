local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local sharedFolder = ReplicatedStorage:WaitForChild("WanderingPropsShared")

local Config = require(sharedFolder:WaitForChild("Config"))
local Remotes = require(sharedFolder:WaitForChild("Remotes"))
local NPCAnimator = require(script.Parent:WaitForChild("NPCAnimator"))
local NPCMover = require(script.Parent:WaitForChild("NPCMover"))
local LODController = require(script.Parent:WaitForChild("LODController"))
local ModelPool = require(script.Parent:WaitForChild("ModelPool"))

local activeNPCs = {}
local activeNPCsFolderRef: Folder? = nil
local waypointsFolderRef: Folder? = nil
local restoreRaycastParams: RaycastParams? = nil
local pendingEventOps = {}
local pendingEventOpsHead = 1

local globalFrame = 0
local lodRuntimeEnabled = Config.LODEnabled
local lodCheckInterval = math.max(1, Config.LODCheckInterval)

local lodTransitionsTotal = 0
local poolAcquireHits = 0
local poolAcquireMisses = 0
local poolDestroys = 0

local function diagnostics(message: string)
	if Config.DiagnosticsEnabled then
		print(message)
	end
end

local function routeDistance(waypoints: { Vector3 }): number
	local total = 0
	for i = 1, #waypoints - 1 do
		total += (waypoints[i + 1] - waypoints[i]).Magnitude
	end
	return total
end

local function socialSeatTravelDistance(waypoints: { Vector3 }, poiStops): number
	local total = 0
	for _, poi in ipairs(poiStops or {}) do
		if poi.type == "social" and poi.seatCFrame and waypoints[poi.waypointIndex] then
			local waypointPos = waypoints[poi.waypointIndex]
			local seatPos = poi.seatCFrame.Position
			total += (seatPos - waypointPos).Magnitude * 2
		end
	end
	return total
end

local function moveModelTowardCFrame(npc, targetCFrame: CFrame, dt: number): boolean
	if not npc.model.PrimaryPart then
		return true
	end

	local currentPos = npc.model.PrimaryPart.Position
	local targetPos = targetCFrame.Position
	local delta = targetPos - currentPos
	local distance = delta.Magnitude
	if distance <= 0.001 then
		npc.model.PrimaryPart.CFrame = targetCFrame
		return true
	end

	local maxStep = math.max(0, dt) * npc.walkSpeed
	if maxStep >= distance then
		npc.model.PrimaryPart.CFrame = targetCFrame
		return true
	end

	local direction = delta / distance
	local newPos = currentPos + direction * maxStep
	local flatDirection = Vector3.new(direction.X, 0, direction.Z)
	if flatDirection.Magnitude > 0.001 then
		npc.model.PrimaryPart.CFrame = CFrame.lookAt(newPos, newPos + flatDirection)
	else
		npc.model.PrimaryPart.CFrame = CFrame.new(newPos)
	end

	return false
end

local function rebuildRestoreRaycastFilter()
	if not restoreRaycastParams then
		return
	end

	local excludes = {}
	if waypointsFolderRef then
		table.insert(excludes, waypointsFolderRef)
	end
	if activeNPCsFolderRef then
		table.insert(excludes, activeNPCsFolderRef)
	end

	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			table.insert(excludes, player.Character)
		end
	end

	restoreRaycastParams.FilterDescendantsInstances = excludes
end

local function initRestoreRaycastParams(waypointsFolder: Folder, activeNPCsFolder: Folder)
	waypointsFolderRef = waypointsFolder
	activeNPCsFolderRef = activeNPCsFolder

	restoreRaycastParams = RaycastParams.new()
	restoreRaycastParams.FilterType = Enum.RaycastFilterType.Exclude
	restoreRaycastParams.IgnoreWater = true

	rebuildRestoreRaycastFilter()

	for _, player in ipairs(Players:GetPlayers()) do
		player.CharacterAdded:Connect(function()
			rebuildRestoreRaycastFilter()
		end)
		player.CharacterRemoving:Connect(function()
			rebuildRestoreRaycastFilter()
		end)
	end

	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function()
			rebuildRestoreRaycastFilter()
		end)
		player.CharacterRemoving:Connect(function()
			rebuildRestoreRaycastFilter()
		end)
		rebuildRestoreRaycastFilter()
	end)

	Players.PlayerRemoving:Connect(function()
		rebuildRestoreRaycastFilter()
	end)
end

local function removeNPC(id: string)
	local npc = activeNPCs[id]
	if not npc then
		return
	end

	NPCAnimator.stopAll(npc)

	if Config.PoolEnabled then
		local stats = ModelPool.getStats()
		local beforeCount = stats.perModel[npc.modelName] or 0
		local maxCount = math.max(0, math.floor(Config.PoolMaxPerModel))
		local willDestroy = beforeCount >= maxCount

		ModelPool.release(npc.modelName, {
			model = npc.model,
			animator = npc.animator,
			walkTrack = npc.walkTrack,
			idleTrack = npc.idleTrack,
			sitTrack = npc.sitTrack,
		})

		if willDestroy then
			poolDestroys += 1
			diagnostics(string.format(
				"[WanderingProps] POOL_FULL_DESTROY model=%s max=%d",
				npc.modelName,
				maxCount
			))
		else
			local afterCount = beforeCount + 1
			diagnostics(string.format(
				"[WanderingProps] POOL_RELEASE model=%s pool_size=%d",
				npc.modelName,
				afterCount
			))
		end
	else
		npc.model:Destroy()
	end

	activeNPCs[id] = nil
end

local function sliceWaypoints(waypoints: { Vector3 }, startIdx: number, endIdx: number)
	local out = {}
	for i = startIdx, endIdx do
		table.insert(out, waypoints[i])
	end
	return out
end

local function calculateRouteState(waypoints: { Vector3 }, walkSpeed: number, elapsed: number, poiStops)
	if not poiStops or #poiStops == 0 then
		local position, currentLeg, legProgress = NPCMover.calculatePositionAtTime(waypoints, walkSpeed, elapsed)
		return {
			state = "walking",
			position = position,
			currentLeg = currentLeg,
			legProgress = legProgress,
			nextPoiStopIdx = 1,
		}
	end

	local timeConsumed = 0
	local lastResumeIndex = 1

	for poiIdx = 1, #poiStops do
		local poi = poiStops[poiIdx]

		local walkDist = 0
		for w = lastResumeIndex, poi.waypointIndex - 1 do
			walkDist += (waypoints[w + 1] - waypoints[w]).Magnitude
		end
		local walkTime = 0
		if walkSpeed > 0 then
			walkTime = walkDist / walkSpeed
		end

		if elapsed < timeConsumed + walkTime then
			local walkElapsed = elapsed - timeConsumed
			local subWaypoints = sliceWaypoints(waypoints, lastResumeIndex, poi.waypointIndex)
			local position, subLeg, subProgress = NPCMover.calculatePositionAtTime(subWaypoints, walkSpeed, walkElapsed)
			local currentLeg = lastResumeIndex + subLeg - 1
			return {
				state = "walking",
				position = position,
				currentLeg = currentLeg,
				legProgress = subProgress,
				nextPoiStopIdx = poiIdx,
			}
		end
		timeConsumed += walkTime

		if poi.type ~= "busy" and poi.dwellTime > 0 then
			if elapsed < timeConsumed + poi.dwellTime then
				local dwellElapsed = elapsed - timeConsumed
				local dwellRemaining = poi.dwellTime - dwellElapsed
				local position = waypoints[poi.waypointIndex]

				if poi.type == "scenic" then
					return {
						state = "dwelling",
						position = position,
						currentLeg = poi.waypointIndex,
						legProgress = 0,
						nextPoiStopIdx = poiIdx,
						dwellEndTime = Workspace:GetServerTimeNow() + dwellRemaining,
						viewTarget = poi.viewTarget,
					}
				elseif poi.type == "social" then
					return {
						state = "sitting",
						position = position,
						currentLeg = poi.waypointIndex,
						legProgress = 0,
						nextPoiStopIdx = poiIdx,
						dwellEndTime = Workspace:GetServerTimeNow() + dwellRemaining,
						seatCFrame = poi.seatCFrame,
					}
				end
			end
			timeConsumed += poi.dwellTime
		end

		lastResumeIndex = poi.waypointIndex
	end

	local walkDist = 0
	for w = lastResumeIndex, #waypoints - 1 do
		walkDist += (waypoints[w + 1] - waypoints[w]).Magnitude
	end
	local walkTime = 0
	if walkSpeed > 0 then
		walkTime = walkDist / walkSpeed
	end

	if elapsed < timeConsumed + walkTime then
		local walkElapsed = elapsed - timeConsumed
		local subWaypoints = sliceWaypoints(waypoints, lastResumeIndex, #waypoints)
		local position, subLeg, subProgress = NPCMover.calculatePositionAtTime(subWaypoints, walkSpeed, walkElapsed)
		local currentLeg = lastResumeIndex + subLeg - 1
		return {
			state = "walking",
			position = position,
			currentLeg = currentLeg,
			legProgress = subProgress,
			nextPoiStopIdx = #poiStops + 1,
		}
	end

	return {
		state = "finished",
		position = waypoints[#waypoints],
		currentLeg = #waypoints - 1,
		legProgress = 1.0,
		nextPoiStopIdx = #poiStops + 1,
	}
end

local function isMovingState(state: string): boolean
	return state == "walking" or state == "walking_to_seat" or state == "walking_from_seat"
end

local function restoreFromFarTier(npc)
	local elapsed = Workspace:GetServerTimeNow() - npc.startTime
	if elapsed < 0 then
		elapsed = 0
	end

	local routeState = calculateRouteState(npc.waypoints, npc.walkSpeed, elapsed, npc.poiStops)

	npc.currentLeg = routeState.currentLeg
	npc.legProgress = routeState.legProgress
	npc.state = routeState.state
	npc.nextPoiStopIdx = routeState.nextPoiStopIdx
	npc.dwellEndTime = routeState.dwellEndTime or nil

	local flatPos = routeState.position
	local snappedY = npc.lastGroundY
	if restoreRaycastParams then
		local rayOrigin = flatPos + Vector3.new(0, Config.SnapRayOriginOffset, 0)
		local rayDirection = Vector3.new(0, -Config.SnapRayLength, 0)
		local hitResult = Workspace:Raycast(rayOrigin, rayDirection, restoreRaycastParams)
		if hitResult then
			snappedY = hitResult.Position.Y + Config.SnapHipOffset
			npc.lastGroundY = snappedY
		end
	end
	local snappedPos = Vector3.new(flatPos.X, snappedY, flatPos.Z)

	if npc.model.PrimaryPart then
		if routeState.state == "sitting" and routeState.seatCFrame then
			npc.model.PrimaryPart.CFrame = routeState.seatCFrame
			npc.preSeatCFrame = CFrame.new(snappedPos)
			npc.seatTargetCFrame = routeState.seatCFrame
		elseif routeState.state == "dwelling" and routeState.viewTarget then
			local flatTarget = Vector3.new(routeState.viewTarget.X, snappedPos.Y, routeState.viewTarget.Z)
			if (flatTarget - snappedPos).Magnitude > 0.01 then
				npc.model.PrimaryPart.CFrame = CFrame.lookAt(snappedPos, flatTarget)
			else
				npc.model.PrimaryPart.CFrame = CFrame.new(snappedPos)
			end
			npc.preSeatCFrame = nil
			npc.seatTargetCFrame = nil
		else
			npc.model.PrimaryPart.CFrame = CFrame.new(snappedPos)
			npc.preSeatCFrame = nil
			npc.seatTargetCFrame = nil
		end
	end

	npc.lastKnownPosition = snappedPos
end

local function applyAnimationForState(npc)
	if not lodRuntimeEnabled or LODController.shouldAnimate(npc.lodTier) then
		if npc.state == "sitting" then
			NPCAnimator.playSit(npc)
		else
			NPCAnimator.update(npc, isMovingState(npc.state))
		end
	end
end

local function buildFreshModelFromTemplate(data, modelsFolder: Folder)
	local modelTemplate = nil
	if typeof(data.modelTemplate) == "Instance" and data.modelTemplate:IsA("Model") then
		modelTemplate = data.modelTemplate
	end

	if modelTemplate == nil then
		modelTemplate = modelsFolder:FindFirstChild(data.modelName)
	end

	if not modelTemplate or not modelTemplate:IsA("Model") then
		warn(string.format("[WanderingProps] Model not found: %s", data.modelName))
		return nil
	end

	local cloneSuccess, clonedModel = pcall(function()
		return modelTemplate:Clone()
	end)
	if not cloneSuccess or not clonedModel then
		warn(string.format("[WanderingProps] Failed to clone model %s for NPC %s", data.modelName, data.id))
		return nil
	end

	if not clonedModel.PrimaryPart then
		warn(string.format("[WanderingProps] Model %s has no PrimaryPart", data.modelName))
		clonedModel:Destroy()
		return nil
	end

	local animator
	local humanoid = clonedModel:FindFirstChildOfClass("Humanoid")
	if humanoid then
		animator = humanoid:FindFirstChildOfClass("Animator")
		if not animator then
			animator = Instance.new("Animator")
			animator.Parent = humanoid
		end
	else
		local animationController = clonedModel:FindFirstChildOfClass("AnimationController")
		if not animationController then
			animationController = Instance.new("AnimationController")
			animationController.Parent = clonedModel
		end

		animator = animationController:FindFirstChildOfClass("Animator")
		if not animator then
			animator = Instance.new("Animator")
			animator.Parent = animationController
		end
	end

	return {
		model = clonedModel,
		animator = animator,
	}
end

local function ensureModelDataTracks(modelData)
	local walkTrack = modelData.walkTrack
	local idleTrack = modelData.idleTrack
	local sitTrack = modelData.sitTrack

	if not walkTrack or not idleTrack then
		walkTrack, idleTrack = NPCAnimator.setup(modelData.animator)
		modelData.walkTrack = walkTrack
		modelData.idleTrack = idleTrack
	end
	if not sitTrack then
		sitTrack = NPCAnimator.setupSit(modelData.animator)
		modelData.sitTrack = sitTrack
	end

	return walkTrack, idleTrack, sitTrack
end

local function prewarmModelPool(modelsFolder: Folder)
	if not Config.PoolEnabled then
		return
	end

	local maxPerModel = math.max(0, math.floor(Config.PoolMaxPerModel or 0))
	local prewarmPerModel = math.max(0, math.floor(Config.PoolPrewarmPerModel or 0))
	local targetPerModel = math.min(maxPerModel, prewarmPerModel)
	if targetPerModel <= 0 then
		return
	end

	local created = 0
	for _, child in ipairs(modelsFolder:GetChildren()) do
		if child:IsA("Model") and child.PrimaryPart then
			local modelName = child.Name
			for i = 1, targetPerModel do
				local modelData = buildFreshModelFromTemplate({
					id = string.format("prewarm_%s_%d", modelName, i),
					modelName = modelName,
					modelTemplate = child,
				}, modelsFolder)
				if not modelData then
					break
				end
				if modelData.model.PrimaryPart then
					modelData.model.PrimaryPart.CFrame = CFrame.new(0, -500, 0)
				end
				if activeNPCsFolderRef then
					modelData.model.Parent = activeNPCsFolderRef
				end
				ensureModelDataTracks(modelData)
				ModelPool.release(modelName, modelData)
				created += 1
			end
		end
	end

	if created > 0 then
		diagnostics(string.format("[WanderingProps] POOL_PREWARM created=%d", created))
	end
end

local function spawnNPCFromData(data, modelsFolder: Folder)
	removeNPC(data.id)

	local poolEntry = nil
	if Config.PoolEnabled then
		poolEntry = ModelPool.acquire(data.modelName)
		if poolEntry then
			poolAcquireHits += 1
			local stats = ModelPool.getStats()
			local remaining = stats.perModel[data.modelName] or 0
			diagnostics(string.format(
				"[WanderingProps] POOL_ACQUIRE model=%s pool_remaining=%d",
				data.modelName,
				remaining
			))
		else
			poolAcquireMisses += 1
		end
	end

	local modelData = poolEntry
	if not modelData then
		modelData = buildFreshModelFromTemplate(data, modelsFolder)
		if not modelData then
			return
		end
	end

	local clonedModel = modelData.model
	local animator = modelData.animator
	local walkTrack = modelData.walkTrack
	local idleTrack = modelData.idleTrack
	local sitTrack = modelData.sitTrack

	if not clonedModel.PrimaryPart then
		warn(string.format("[WanderingProps] Model %s has no PrimaryPart", data.modelName))
		if Config.PoolEnabled then
			ModelPool.release(data.modelName, modelData)
		else
			clonedModel:Destroy()
		end
		return
	end

	for _, descendant in ipairs(clonedModel:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
			descendant.CanCollide = false
		end
	end
	clonedModel.PrimaryPart.Anchored = true

	local elapsed = Workspace:GetServerTimeNow() - data.startTime
	if elapsed < 0 then
		elapsed = 0
	end

	local routeState = calculateRouteState(data.waypoints, data.walkSpeed, elapsed, data.poiStops)
	clonedModel.PrimaryPart.CFrame = CFrame.new(routeState.position)
	if activeNPCsFolderRef then
		clonedModel.Parent = activeNPCsFolderRef
	end

	walkTrack, idleTrack, sitTrack = ensureModelDataTracks(modelData)

	local walkTime = 0
	local totalDistance = routeDistance(data.waypoints)
	local socialTravelDistance = socialSeatTravelDistance(data.waypoints, data.poiStops)
	totalDistance += socialTravelDistance
	if data.walkSpeed > 0 then
		walkTime = totalDistance / data.walkSpeed
	end
	local totalDwellTime = 0
	for _, poi in ipairs(data.poiStops or {}) do
		totalDwellTime += poi.dwellTime
	end
	local expectedDespawnTime = data.startTime + walkTime + totalDwellTime + Config.ClientDespawnBuffer

	local maxPhase = math.max(1, math.max(Config.LODLowRaycastSkip, Config.LODMidRaycastSkip))
	local npc = {
		id = data.id,
		model = clonedModel,
		walkSpeed = data.walkSpeed,
		waypoints = data.waypoints,
		currentLeg = routeState.currentLeg,
		legProgress = routeState.legProgress,
		lastGroundY = routeState.position.Y,
		expectedDespawnTime = expectedDespawnTime,
		animator = animator,
		walkTrack = walkTrack,
		idleTrack = idleTrack,
		state = routeState.state,
		poiStops = data.poiStops,
		nextPoiStopIdx = routeState.nextPoiStopIdx,
		dwellEndTime = nil,
		preSeatCFrame = nil,
		seatTargetCFrame = nil,
		sitTrack = sitTrack,
		modelName = data.modelName,
		startTime = data.startTime,
		lodTier = "near",
		raycastPhase = math.random(0, maxPhase - 1),
		lastKnownPosition = routeState.position,
	}

	if routeState.dwellEndTime then
		npc.dwellEndTime = routeState.dwellEndTime
	end
	if routeState.state == "sitting" and routeState.seatCFrame then
		npc.preSeatCFrame = CFrame.new(routeState.position)
		npc.seatTargetCFrame = routeState.seatCFrame
		npc.model.PrimaryPart.CFrame = routeState.seatCFrame
		applyAnimationForState(npc)
	elseif routeState.state == "dwelling" then
		if routeState.viewTarget then
			local pos = routeState.position
			local flatTarget = Vector3.new(routeState.viewTarget.X, pos.Y, routeState.viewTarget.Z)
			if (flatTarget - pos).Magnitude > 0.01 then
				npc.model.PrimaryPart.CFrame = CFrame.lookAt(pos, flatTarget)
			end
		end
		applyAnimationForState(npc)
	else
		applyAnimationForState(npc)
	end

	activeNPCs[data.id] = npc

	task.defer(function()
		local current = activeNPCs[data.id]
		if current == npc then
			applyAnimationForState(current)
		end
	end)
end

local function queueSpawnPayload(payload)
	if typeof(payload) ~= "table" then
		return
	end
	if payload.id ~= nil then
		table.insert(pendingEventOps, {
			kind = "spawn",
			data = payload,
		})
		return
	end
	for _, entry in ipairs(payload) do
		if typeof(entry) == "table" and entry.id ~= nil then
			table.insert(pendingEventOps, {
				kind = "spawn",
				data = entry,
			})
		end
	end
end

local function queueDespawnPayload(payload)
	if typeof(payload) == "string" then
		table.insert(pendingEventOps, {
			kind = "despawn",
			id = payload,
		})
		return
	end
	if typeof(payload) ~= "table" then
		return
	end
	for _, id in ipairs(payload) do
		if typeof(id) == "string" then
			table.insert(pendingEventOps, {
				kind = "despawn",
				id = id,
			})
		end
	end
end

local function processPendingEventOps(modelsFolder: Folder)
	local maxOps = math.max(1, math.floor(Config.ClientEventOpsPerHeartbeat or 8))
	local processed = 0
	while processed < maxOps and pendingEventOpsHead <= #pendingEventOps do
		local op = pendingEventOps[pendingEventOpsHead]
		pendingEventOps[pendingEventOpsHead] = nil
		pendingEventOpsHead += 1
		processed += 1

		if op.kind == "spawn" then
			spawnNPCFromData(op.data, modelsFolder)
		elseif op.kind == "despawn" then
			removeNPC(op.id)
		end
	end

	if pendingEventOpsHead <= #pendingEventOps then
		diagnostics(string.format("[WanderingProps] EVENT_QUEUE_BACKLOG pending=%d", #pendingEventOps - pendingEventOpsHead + 1))
	end

	if pendingEventOpsHead > #pendingEventOps then
		pendingEventOps = {}
		pendingEventOpsHead = 1
	end
end

local function startup()
	local remotesFolder = ReplicatedStorage:WaitForChild("WanderingPropsRemotes")
	local npcSpawnedRemote = remotesFolder:WaitForChild(Remotes.NPCSpawned)
	local npcDespawnedRemote = remotesFolder:WaitForChild(Remotes.NPCDespawned)
	local npcBulkSyncRemote = remotesFolder:WaitForChild(Remotes.NPCBulkSync)

	local wanderingFolder = Workspace:WaitForChild("WanderingProps")
	local waypointsFolder = wanderingFolder:WaitForChild("Waypoints")

	local activeNPCsFolder = wanderingFolder:FindFirstChild("ActiveNPCs")
	if not activeNPCsFolder then
		activeNPCsFolder = Instance.new("Folder")
		activeNPCsFolder.Name = "ActiveNPCs"
		activeNPCsFolder.Parent = wanderingFolder
	end

	activeNPCsFolderRef = activeNPCsFolder

	local modelsFolder = ReplicatedStorage:WaitForChild("WanderingPropModels")

	if lodRuntimeEnabled then
		if Config.LODNearDistance >= Config.LODLowDistance
			or Config.LODLowDistance >= Config.LODMidDistance
		then
			warn("[WanderingProps] WARNING: LOD distances must be LODNearDistance < LODLowDistance < LODMidDistance. LOD disabled.")
			lodRuntimeEnabled = false
		end
	end

	ModelPool.init(Config.PoolMaxPerModel)
	prewarmModelPool(modelsFolder)
	NPCMover.init(waypointsFolder, activeNPCsFolder)
	initRestoreRaycastParams(waypointsFolder, activeNPCsFolder)

	npcSpawnedRemote.OnClientEvent:Connect(function(payload)
		queueSpawnPayload(payload)
	end)

	npcDespawnedRemote.OnClientEvent:Connect(function(payload)
		queueDespawnPayload(payload)
	end)

	npcBulkSyncRemote.OnClientEvent:Connect(function(entries)
		queueSpawnPayload(entries)
	end)

	RunService.Heartbeat:Connect(function(dt)
		processPendingEventOps(modelsFolder)

		globalFrame = (globalFrame + 1) % 100000
		local isLODCheckFrame = lodRuntimeEnabled and (globalFrame % lodCheckInterval == 0)

		local playerPosition = nil
			if isLODCheckFrame then
				local localPlayer = Players.LocalPlayer
				local character = localPlayer and localPlayer.Character
			local rootPart = character and character:FindFirstChild("HumanoidRootPart")
			if rootPart and rootPart:IsA("BasePart") then
				playerPosition = rootPart.Position
			end
		end

		for id, npc in pairs(activeNPCs) do
			if Workspace:GetServerTimeNow() > npc.expectedDespawnTime then
				warn(string.format("[WanderingProps] FORCE_DESPAWN %s - server event not received", id))
				removeNPC(id)
				continue
			end

			if isLODCheckFrame and playerPosition then
				local npcPos = npc.lastKnownPosition
				if npc.lodTier ~= "far" and npc.model.PrimaryPart then
					npcPos = npc.model.PrimaryPart.Position
				end
				if not npcPos then
					npcPos = npc.waypoints[npc.currentLeg] or npc.waypoints[1]
				end

				local newTier = LODController.computeTier(npcPos, playerPosition)
				if newTier ~= npc.lodTier then
					local oldTier = npc.lodTier
					npc.lodTier = newTier

					if newTier == "far" then
						if npc.model.PrimaryPart then
							npc.lastKnownPosition = npc.model.PrimaryPart.Position
						end
						NPCAnimator.stopAll(npc)
						npc.model.Parent = nil
					elseif oldTier == "far" then
						restoreFromFarTier(npc)
						if activeNPCsFolderRef then
							npc.model.Parent = activeNPCsFolderRef
						end
						if LODController.shouldAnimate(newTier) then
							applyAnimationForState(npc)
						else
							NPCAnimator.stopAll(npc)
						end
					elseif newTier == "mid" and oldTier ~= "mid" then
						NPCAnimator.stopAll(npc)
					elseif oldTier == "mid" and newTier ~= "mid" then
						applyAnimationForState(npc)
					end

					lodTransitionsTotal += 1
					diagnostics(string.format("[WanderingProps] LOD_TRANSITION %s tier=%s→%s", id, oldTier, newTier))
				end
			end

			if npc.lodTier == "far" then
				continue
			end
			if lodRuntimeEnabled and not LODController.shouldMove(npc.lodTier) then
				continue
			end

			if npc.state == "walking" then
				local stopAt = nil
				if npc.poiStops and npc.nextPoiStopIdx <= #npc.poiStops then
					stopAt = npc.poiStops[npc.nextPoiStopIdx].waypointIndex
				end

				local skipRaycast = lodRuntimeEnabled
					and (not LODController.shouldRaycast(npc.lodTier, globalFrame, npc.raycastPhase))
				local finished = NPCMover.update(npc, dt, stopAt, skipRaycast)

				if npc.model.PrimaryPart then
					npc.lastKnownPosition = npc.model.PrimaryPart.Position
				end

				if stopAt and npc.currentLeg >= stopAt then
					local poi = npc.poiStops[npc.nextPoiStopIdx]
					if poi.type == "scenic" then
						npc.state = "dwelling"
						npc.dwellEndTime = Workspace:GetServerTimeNow() + poi.dwellTime
						if poi.viewTarget and npc.model.PrimaryPart then
							local pos = npc.model.PrimaryPart.Position
							local flatTarget = Vector3.new(poi.viewTarget.X, pos.Y, poi.viewTarget.Z)
							if (flatTarget - pos).Magnitude > 0.01 then
								npc.model.PrimaryPart.CFrame = CFrame.lookAt(pos, flatTarget)
							end
						end
						if not lodRuntimeEnabled or LODController.shouldAnimate(npc.lodTier) then
							NPCAnimator.update(npc, false)
						end
					elseif poi.type == "social" then
						npc.state = "walking_to_seat"
						npc.dwellEndTime = Workspace:GetServerTimeNow() + poi.dwellTime
						if npc.model.PrimaryPart then
							npc.preSeatCFrame = npc.model.PrimaryPart.CFrame
						end
						npc.seatTargetCFrame = poi.seatCFrame
						if not lodRuntimeEnabled or LODController.shouldAnimate(npc.lodTier) then
							NPCAnimator.update(npc, true)
						end
					elseif poi.type == "busy" then
						npc.nextPoiStopIdx += 1
						if not lodRuntimeEnabled or LODController.shouldAnimate(npc.lodTier) then
							NPCAnimator.update(npc, true)
						end
					end
				elseif finished then
					npc.state = "finished"
					if not lodRuntimeEnabled or LODController.shouldAnimate(npc.lodTier) then
						NPCAnimator.update(npc, false)
					end
				else
					if not lodRuntimeEnabled or LODController.shouldAnimate(npc.lodTier) then
						NPCAnimator.update(npc, true)
					end
				end
			elseif npc.state == "dwelling" then
				if not lodRuntimeEnabled or LODController.shouldAnimate(npc.lodTier) then
					NPCAnimator.update(npc, false)
				end
				if npc.dwellEndTime and Workspace:GetServerTimeNow() >= npc.dwellEndTime then
					npc.nextPoiStopIdx += 1
					npc.state = "walking"
					npc.dwellEndTime = nil
				end
			elseif npc.state == "walking_to_seat" then
				if npc.seatTargetCFrame then
					local reachedSeat = moveModelTowardCFrame(npc, npc.seatTargetCFrame, dt)
					if npc.model.PrimaryPart then
						npc.lastKnownPosition = npc.model.PrimaryPart.Position
					end
					if not lodRuntimeEnabled or LODController.shouldAnimate(npc.lodTier) then
						NPCAnimator.update(npc, true)
					end
					if reachedSeat then
						npc.state = "sitting"
						if not lodRuntimeEnabled or LODController.shouldAnimate(npc.lodTier) then
							NPCAnimator.playSit(npc)
						end
					end
				else
					npc.state = "sitting"
					if not lodRuntimeEnabled or LODController.shouldAnimate(npc.lodTier) then
						NPCAnimator.playSit(npc)
					end
				end
			elseif npc.state == "sitting" then
				if not lodRuntimeEnabled or LODController.shouldAnimate(npc.lodTier) then
					NPCAnimator.playSit(npc)
				end
				if npc.dwellEndTime and Workspace:GetServerTimeNow() >= npc.dwellEndTime then
					if not lodRuntimeEnabled or LODController.shouldAnimate(npc.lodTier) then
						NPCAnimator.stopSit(npc)
					end
					npc.state = "walking_from_seat"
					npc.dwellEndTime = nil
				end
			elseif npc.state == "walking_from_seat" then
				if npc.preSeatCFrame then
					local reachedWaypoint = moveModelTowardCFrame(npc, npc.preSeatCFrame, dt)
					if npc.model.PrimaryPart then
						npc.lastKnownPosition = npc.model.PrimaryPart.Position
					end
					if not lodRuntimeEnabled or LODController.shouldAnimate(npc.lodTier) then
						NPCAnimator.update(npc, true)
					end
					if reachedWaypoint then
						npc.nextPoiStopIdx += 1
						npc.state = "walking"
						npc.preSeatCFrame = nil
						npc.seatTargetCFrame = nil
					end
				else
					npc.nextPoiStopIdx += 1
					npc.state = "walking"
					npc.seatTargetCFrame = nil
				end
			elseif npc.state == "finished" then
				if not lodRuntimeEnabled or LODController.shouldAnimate(npc.lodTier) then
					NPCAnimator.update(npc, false)
				end
			end

			if npc.model.PrimaryPart then
				npc.lastKnownPosition = npc.model.PrimaryPart.Position
			end
		end
	end)
end

startup()
