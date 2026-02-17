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
local HeadLookController = require(script.Parent:WaitForChild("HeadLookController"))

local activeNPCs = {}
local activeNPCsFolderRef: Folder? = nil
local waypointsFolderRef: Folder? = nil
local restoreRaycastParams: RaycastParams? = nil
local pendingSpawnOps = {}
local pendingSpawnOpsHead = 1
local pendingDespawnOps = {}
local pendingDespawnOpsHead = 1

local globalFrame = 0
local lodRuntimeEnabled = Config.LODEnabled
local lodCheckInterval = math.max(1, Config.LODCheckInterval)

local lodTransitionsTotal = 0
local poolAcquireHits = 0
local poolAcquireMisses = 0
local poolDestroys = 0
local headLookTriggersTotal = 0

local headLookRuntimeEnabled = Config.HeadLookEnabled
local activeNPCCount = 0
local poolMaxPerModelRuntime = math.max(0, math.floor(Config.PoolMaxPerModel or 0))
local poolPrewarmPerModelRuntime = math.max(0, math.floor(Config.PoolPrewarmPerModel or 0))
local pooledStashCFrame = CFrame.new(0, -500, 0)

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
		npc.model.PrimaryPart.CFrame = npc.model.PrimaryPart.CFrame.Rotation + targetPos
		return true
	end

	local maxStep = math.max(0, dt) * npc.walkSpeed
	if maxStep >= distance then
		npc.model.PrimaryPart.CFrame = npc.model.PrimaryPart.CFrame.Rotation + targetPos
		return true
	end

	local direction = delta / distance
	local newPos = currentPos + direction * maxStep
	local flatDirection = Vector3.new(direction.X, 0, direction.Z)
	if flatDirection.Magnitude > 0.001 then
		if Config.TurnSmoothing then
			local targetLook = CFrame.lookAt(newPos, newPos + flatDirection)
			local currentRotation = npc.model.PrimaryPart.CFrame.Rotation
			local alpha = math.min(1, dt * Config.TurnLerpSpeed)
			local smoothedRotation = currentRotation:Lerp(targetLook.Rotation, alpha)
			npc.model.PrimaryPart.CFrame = smoothedRotation + newPos
		else
			npc.model.PrimaryPart.CFrame = CFrame.lookAt(newPos, newPos + flatDirection)
		end
	else
		npc.model.PrimaryPart.CFrame = npc.model.PrimaryPart.CFrame.Rotation + newPos
	end

	return false
end

local function restorePartTransparencies(npc)
	if not npc.partTransparencies then
		return
	end
	for part, original in pairs(npc.partTransparencies) do
		if part then
			part.Transparency = original
		end
	end
	npc.partTransparencies = nil
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

	HeadLookController.reset(npc)
	restorePartTransparencies(npc)
	NPCAnimator.stopAll(npc)

	if Config.PoolEnabled then
		if npc.model.PrimaryPart then
			npc.model.PrimaryPart.CFrame = pooledStashCFrame
		end
		local beforeCount = ModelPool.getModelCount(npc.modelName)
		local maxCount = poolMaxPerModelRuntime
		local willDestroy = beforeCount >= maxCount

		ModelPool.release(npc.modelName, {
			model = npc.model,
			animator = npc.animator,
			walkTrack = npc.walkTrack,
			idleTrack = npc.idleTrack,
			sitTrack = npc.sitTrack,
			baseParts = npc.baseParts,
			neckMotor = npc.headLookNeckMotor,
			neckOriginalC0 = npc.headLookOriginalC0,
		}, activeNPCsFolderRef)

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
	activeNPCCount = math.max(0, activeNPCCount - 1)
end

local function calculatePositionAlongWaypoints(
	waypoints: { Vector3 },
	walkSpeed: number,
	elapsed: number,
	startIndex: number,
	endIndex: number
): (Vector3, number, number)
	if #waypoints == 0 then
		return Vector3.zero, startIndex, 0
	end
	if startIndex >= endIndex then
		local clamped = math.clamp(startIndex, 1, #waypoints)
		return waypoints[clamped], clamped, 0
	end
	if walkSpeed <= 0 or elapsed <= 0 then
		return waypoints[startIndex], startIndex, 0
	end

	local remaining = elapsed
	for i = startIndex, endIndex - 1 do
		local a = waypoints[i]
		local b = waypoints[i + 1]
		local segmentDistance = (b - a).Magnitude
		local segmentTime = segmentDistance / walkSpeed
		if segmentTime <= 0 then
			continue
		end
		if remaining <= segmentTime then
			local alpha = remaining / segmentTime
			return a:Lerp(b, alpha), i, alpha
		end
		remaining -= segmentTime
	end

	return waypoints[endIndex], endIndex - 1, 1
end

local function calculateRouteState(waypoints: { Vector3 }, walkSpeed: number, elapsed: number, poiStops)
	if not poiStops or #poiStops == 0 then
		local position, currentLeg, legProgress =
			calculatePositionAlongWaypoints(waypoints, walkSpeed, elapsed, 1, #waypoints)
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
			local walkElapsed = math.max(0, elapsed - timeConsumed)
			local position, currentLeg, legProgress =
				calculatePositionAlongWaypoints(waypoints, walkSpeed, walkElapsed, lastResumeIndex, poi.waypointIndex)
			return {
				state = "walking",
				position = position,
				currentLeg = currentLeg,
				legProgress = legProgress,
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
		local walkElapsed = math.max(0, elapsed - timeConsumed)
		local position, currentLeg, legProgress =
			calculatePositionAlongWaypoints(waypoints, walkSpeed, walkElapsed, lastResumeIndex, #waypoints)
		return {
			state = "walking",
			position = position,
			currentLeg = currentLeg,
			legProgress = legProgress,
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
	HeadLookController.reset(npc)

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
	npc.dwellFacingTarget = nil

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

local function resolveMovementDt(npc, dt: number): number
	if not lodRuntimeEnabled then
		return dt
	end

	local interval = 1
	if npc.lodTier == "low" then
		interval = math.max(1, math.floor(Config.LODLowMoveSkip or 1))
	elseif npc.lodTier == "mid" then
		interval = math.max(1, math.floor(Config.LODMidMoveSkip or 1))
	end

	if interval <= 1 then
		npc.moveAccum = 0
		return dt
	end

	local accumulated = (npc.moveAccum or 0) + math.max(0, dt)
	npc.moveAccum = accumulated

	if ((globalFrame + (npc.movePhase or 0)) % interval) ~= 0 then
		return 0
	end

	npc.moveAccum = 0
	return accumulated
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

	local baseParts = {}
	local neckMotor = nil
	local neckOriginalC0 = nil
	for _, descendant in ipairs(clonedModel:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
			descendant.CanCollide = false
			table.insert(baseParts, descendant)
		elseif descendant:IsA("Motor6D") and descendant.Name == "Neck" and not neckMotor then
			neckMotor = descendant
			neckOriginalC0 = descendant.C0
		end
	end
	clonedModel.PrimaryPart.Anchored = true

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
		baseParts = baseParts,
		neckMotor = neckMotor,
		neckOriginalC0 = neckOriginalC0,
	}
end

local function ensureModelDataBaseParts(modelData)
	if modelData.baseParts then
		return modelData.baseParts
	end

	local baseParts = {}
	for _, descendant in ipairs(modelData.model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			table.insert(baseParts, descendant)
		end
	end
	modelData.baseParts = baseParts
	return baseParts
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

local function configureRuntimePoolSizing(modelsFolder: Folder)
	if not Config.PoolEnabled then
		return
	end

	local modelCount = 0
	for _, child in ipairs(modelsFolder:GetChildren()) do
		if child:IsA("Model") and child.PrimaryPart then
			modelCount += 1
		end
	end
	if modelCount <= 0 then
		return
	end

	local targetPopulation = math.max(1, math.floor(Config.MaxPopulation or 0))
	local expectedPerModel = math.max(1, math.ceil(targetPopulation / modelCount))
	local recommendedPerModel = expectedPerModel + 2
	local adjustedPerModel = math.max(poolMaxPerModelRuntime, recommendedPerModel)
	if adjustedPerModel ~= poolMaxPerModelRuntime then
		poolMaxPerModelRuntime = adjustedPerModel
		diagnostics(string.format(
			"[WanderingProps] POOL_AUTOTUNE max_per_model=%d model_count=%d target_population=%d",
			poolMaxPerModelRuntime,
			modelCount,
			targetPopulation
		))
	end

	local recommendedPrewarm = math.min(expectedPerModel, poolMaxPerModelRuntime)
	if recommendedPrewarm > poolPrewarmPerModelRuntime then
		poolPrewarmPerModelRuntime = recommendedPrewarm
		diagnostics(string.format(
			"[WanderingProps] POOL_PREWARM_AUTOTUNE prewarm_per_model=%d",
			poolPrewarmPerModelRuntime
		))
	end

	poolPrewarmPerModelRuntime = math.min(poolPrewarmPerModelRuntime, poolMaxPerModelRuntime)
end

local function prewarmModelPool(modelsFolder: Folder)
	if not Config.PoolEnabled then
		return
	end

	local maxPerModel = poolMaxPerModelRuntime
	local prewarmPerModel = poolPrewarmPerModelRuntime
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
						modelData.model.PrimaryPart.CFrame = pooledStashCFrame
					end
					if activeNPCsFolderRef then
						modelData.model.Parent = activeNPCsFolderRef
					end
					ensureModelDataTracks(modelData)
					ModelPool.release(modelName, modelData, activeNPCsFolderRef)
					created += 1
				end
				task.wait()
			end
		end

	if created > 0 then
		diagnostics(string.format("[WanderingProps] POOL_PREWARM created=%d", created))
	end
end

local function spawnNPCFromData(data, modelsFolder: Folder)
	removeNPC(data.id)

	local waypoints = data.waypoints
	local poiStops = data.poiStops

	local poolEntry = nil
	local resolvedModelName = data.modelName
	if Config.PoolEnabled then
		poolEntry = ModelPool.acquire(data.modelName)
		if not poolEntry and Config.PoolFallbackAnyModel ~= false then
			local fallbackModelName, fallbackEntry = ModelPool.acquireAny()
			if fallbackEntry then
				poolEntry = fallbackEntry
				resolvedModelName = fallbackModelName
			end
		end
		if poolEntry then
			poolAcquireHits += 1
			local remaining = ModelPool.getModelCount(resolvedModelName)
			diagnostics(string.format(
				"[WanderingProps] POOL_ACQUIRE model=%s pool_remaining=%d",
				resolvedModelName,
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
	local baseParts = ensureModelDataBaseParts(modelData)

	if not clonedModel.PrimaryPart then
		warn(string.format("[WanderingProps] Model %s has no PrimaryPart", resolvedModelName))
		if Config.PoolEnabled then
			ModelPool.release(resolvedModelName, modelData, activeNPCsFolderRef)
		else
			clonedModel:Destroy()
		end
		return
	end

	clonedModel.PrimaryPart.Anchored = true

	local elapsed = Workspace:GetServerTimeNow() - data.startTime
	if elapsed < 0 then
		elapsed = 0
	end

	local routeState = calculateRouteState(waypoints, data.walkSpeed, elapsed, poiStops)
	clonedModel.PrimaryPart.CFrame = CFrame.new(routeState.position)
	if activeNPCsFolderRef then
		clonedModel.Parent = activeNPCsFolderRef
	end

	walkTrack, idleTrack, sitTrack = ensureModelDataTracks(modelData)

	local walkTime = 0
	local totalDistance = routeDistance(waypoints)
	local socialTravelDistance = socialSeatTravelDistance(waypoints, poiStops)
	totalDistance += socialTravelDistance
	if data.walkSpeed > 0 then
		walkTime = totalDistance / data.walkSpeed
	end
	local totalDwellTime = 0
	for _, poi in ipairs(poiStops or {}) do
		totalDwellTime += poi.dwellTime
	end
	local expectedDespawnTime = data.startTime + walkTime + totalDwellTime + Config.ClientDespawnBuffer

	local maxPhase = math.max(1, math.max(Config.LODLowRaycastSkip, Config.LODMidRaycastSkip))
	local maxLODPhase = math.max(1, lodCheckInterval)
	local maxMovePhase = math.max(1, math.max(Config.LODLowMoveSkip or 1, Config.LODMidMoveSkip or 1))
	local npc = {
		id = data.id,
		model = clonedModel,
		walkSpeed = data.walkSpeed,
		waypoints = waypoints,
		currentLeg = routeState.currentLeg,
		legProgress = routeState.legProgress,
		lastGroundY = routeState.position.Y,
		expectedDespawnTime = expectedDespawnTime,
		animator = animator,
		walkTrack = walkTrack,
		idleTrack = idleTrack,
		state = routeState.state,
		poiStops = poiStops,
		nextPoiStopIdx = routeState.nextPoiStopIdx,
		dwellEndTime = nil,
		dwellFacingTarget = nil,
		preSeatCFrame = nil,
		seatTargetCFrame = nil,
		sitTrack = sitTrack,
		modelName = resolvedModelName,
		startTime = data.startTime,
		lodTier = "near",
		lodPhase = math.random(0, maxLODPhase - 1),
		movePhase = math.random(0, maxMovePhase - 1),
		moveAccum = 0,
		raycastPhase = math.random(0, maxPhase - 1),
		lastKnownPosition = routeState.position,
		fadeDirection = nil,
		fadeProgress = 0,
		partTransparencies = nil,
		headLookNeckMotor = nil,
		headLookOriginalC0 = nil,
		headLookActive = false,
		headLookEndTime = 0,
		headLookAlpha = 0,
		headLookNextCheckTime = 0,
		baseParts = baseParts,
	}
	HeadLookController.init(npc, modelData.neckMotor, modelData.neckOriginalC0)

	local shouldFadeIn = Config.FadeEnabled
	local spawnFadeDisableAboveCount = math.max(0, math.floor(Config.SpawnFadeDisableAboveCount or 0))
	if shouldFadeIn and spawnFadeDisableAboveCount > 0 and activeNPCCount >= spawnFadeDisableAboveCount then
		shouldFadeIn = false
	end
	if shouldFadeIn then
		local transparencies = {}
		for _, part in ipairs(baseParts) do
			transparencies[part] = part.Transparency
			part.Transparency = 1
		end
		npc.partTransparencies = transparencies
		npc.fadeDirection = "in"
		npc.fadeProgress = 0
		diagnostics(string.format("[WanderingProps] FADE_IN_START %s duration=%.2f", data.id, Config.SpawnFadeDuration))
	end

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
		npc.dwellFacingTarget = nil
		applyAnimationForState(npc)
	else
		applyAnimationForState(npc)
	end

	activeNPCs[data.id] = npc
	activeNPCCount += 1

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
		table.insert(pendingSpawnOps, payload)
		return
	end
	for _, entry in ipairs(payload) do
		if typeof(entry) == "table" and entry.id ~= nil then
			table.insert(pendingSpawnOps, entry)
		end
	end
end

local function queueDespawnPayload(payload)
	if typeof(payload) == "string" then
		table.insert(pendingDespawnOps, payload)
		return
	end
	if typeof(payload) ~= "table" then
		return
	end
	for _, id in ipairs(payload) do
		if typeof(id) == "string" then
			table.insert(pendingDespawnOps, id)
		end
	end
end

local function processPendingEventOps(modelsFolder: Folder)
	local maxOps = math.max(1, math.floor(Config.ClientEventOpsPerHeartbeat or 8))
	local processed = 0
	-- Process despawns first so pooled models are released before same-frame spawns.
	while processed < maxOps and pendingDespawnOpsHead <= #pendingDespawnOps do
		local id = pendingDespawnOps[pendingDespawnOpsHead]
		pendingDespawnOps[pendingDespawnOpsHead] = nil
		pendingDespawnOpsHead += 1
		processed += 1
		removeNPC(id)
	end

	while processed < maxOps and pendingSpawnOpsHead <= #pendingSpawnOps do
		local spawnData = pendingSpawnOps[pendingSpawnOpsHead]
		pendingSpawnOps[pendingSpawnOpsHead] = nil
		pendingSpawnOpsHead += 1
		processed += 1
		spawnNPCFromData(spawnData, modelsFolder)
	end

	local pendingDespawnCount = if pendingDespawnOpsHead <= #pendingDespawnOps
		then (#pendingDespawnOps - pendingDespawnOpsHead + 1)
		else 0
	local pendingSpawnCount = if pendingSpawnOpsHead <= #pendingSpawnOps
		then (#pendingSpawnOps - pendingSpawnOpsHead + 1)
		else 0
	local pendingTotal = pendingDespawnCount + pendingSpawnCount
	if pendingTotal > 0 then
		diagnostics(string.format(
			"[WanderingProps] EVENT_QUEUE_BACKLOG pending=%d despawn=%d spawn=%d",
			pendingTotal,
			pendingDespawnCount,
			pendingSpawnCount
		))
	end

	if pendingDespawnOpsHead > #pendingDespawnOps then
		pendingDespawnOps = {}
		pendingDespawnOpsHead = 1
	end

	if pendingSpawnOpsHead > #pendingSpawnOps then
		pendingSpawnOps = {}
		pendingSpawnOpsHead = 1
	end
end

local function beginFadeOut(npc)
	if not Config.FadeEnabled or npc.fadeDirection == "out" then
		return
	end

	npc.fadeDirection = "out"
	npc.fadeProgress = 0
	if not npc.partTransparencies then
		local transparencies = {}
		for _, part in ipairs(npc.baseParts or {}) do
			transparencies[part] = part.Transparency
		end
		npc.partTransparencies = transparencies
	end
	diagnostics(string.format("[WanderingProps] FADE_OUT_START %s duration=%.2f", npc.id, Config.DespawnFadeDuration))
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

	if headLookRuntimeEnabled then
		if Config.HeadLookMaxYaw <= 0 or Config.HeadLookMaxPitch <= 0 then
			warn("[WanderingProps] WARNING: HeadLookMaxYaw and HeadLookMaxPitch must be > 0. Head look disabled.")
			headLookRuntimeEnabled = false
		end
	end

	configureRuntimePoolSizing(modelsFolder)
	ModelPool.init(poolMaxPerModelRuntime)
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
		local now = Workspace:GetServerTimeNow()
		local headLookAllowed = headLookRuntimeEnabled
		local headLookDisableAboveCount = math.max(0, math.floor(Config.HeadLookDisableAboveCount or 0))
		if headLookAllowed and headLookDisableAboveCount > 0 and activeNPCCount > headLookDisableAboveCount then
			headLookAllowed = false
		end

		local playerPosition = nil
		if lodRuntimeEnabled or headLookAllowed then
			local localPlayer = Players.LocalPlayer
			local character = localPlayer and localPlayer.Character
			local rootPart = character and character:FindFirstChild("HumanoidRootPart")
			if rootPart and rootPart:IsA("BasePart") then
				playerPosition = rootPart.Position
			end
		end

		for id, npc in pairs(activeNPCs) do
			if now > npc.expectedDespawnTime then
				warn(string.format("[WanderingProps] FORCE_DESPAWN %s - server event not received", id))
				removeNPC(id)
				continue
			end

			local shouldCheckLOD = lodRuntimeEnabled
				and playerPosition ~= nil
				and ((globalFrame + (npc.lodPhase or 0)) % lodCheckInterval == 0)
			if shouldCheckLOD then
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
						if npc.fadeDirection == "in" then
							restorePartTransparencies(npc)
							npc.fadeDirection = nil
							npc.fadeProgress = 0
						end
						HeadLookController.reset(npc)
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
			local movementDt = resolveMovementDt(npc, dt)

			if npc.fadeDirection then
				local fadeDuration = if npc.fadeDirection == "in" then Config.SpawnFadeDuration else Config.DespawnFadeDuration
				npc.fadeProgress = math.min(1, npc.fadeProgress + dt / math.max(0.01, fadeDuration))

				local alpha = if npc.fadeDirection == "in" then npc.fadeProgress else (1 - npc.fadeProgress)
				if npc.partTransparencies then
					for part, original in pairs(npc.partTransparencies) do
						if part and part.Parent then
							part.Transparency = 1 - alpha * (1 - original)
						end
					end
				end

				if npc.fadeProgress >= 1 then
					if npc.fadeDirection == "in" then
						restorePartTransparencies(npc)
						npc.fadeDirection = nil
					end
				end
			end

			if npc.state == "walking" then
				local stopAt = nil
				if npc.poiStops and npc.nextPoiStopIdx <= #npc.poiStops then
					local blockingStopIndex = npc.nextPoiStopIdx
					while blockingStopIndex <= #npc.poiStops and npc.poiStops[blockingStopIndex].type == "busy" do
						blockingStopIndex += 1
					end
					if blockingStopIndex <= #npc.poiStops then
						stopAt = npc.poiStops[blockingStopIndex].waypointIndex
					end
				end

				local isOnDespawnRoute = (not npc.poiStops) or (npc.nextPoiStopIdx > #npc.poiStops)
				local skipRaycast = isOnDespawnRoute
					or (lodRuntimeEnabled and (not LODController.shouldRaycast(npc.lodTier, globalFrame, npc.raycastPhase)))
				local finished = NPCMover.update(npc, movementDt, stopAt, skipRaycast)

				if npc.model.PrimaryPart then
					npc.lastKnownPosition = npc.model.PrimaryPart.Position
				end

				-- Busy POIs are pass-through checkpoints with no dwell/seat state.
				while npc.poiStops and npc.nextPoiStopIdx <= #npc.poiStops do
					local poi = npc.poiStops[npc.nextPoiStopIdx]
					if poi.type ~= "busy" then
						break
					end
					if npc.currentLeg < poi.waypointIndex then
						break
					end
					npc.nextPoiStopIdx += 1
				end

				if npc.poiStops and npc.nextPoiStopIdx <= #npc.poiStops then
					local poi = npc.poiStops[npc.nextPoiStopIdx]
					if poi.type ~= "busy" and npc.currentLeg >= poi.waypointIndex then
						if poi.type == "scenic" then
							npc.state = "dwelling"
							npc.dwellEndTime = now + poi.dwellTime
							npc.dwellFacingTarget = poi.viewTarget
							if not Config.TurnSmoothing and poi.viewTarget and npc.model.PrimaryPart then
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
							npc.dwellEndTime = now + poi.dwellTime
							if npc.model.PrimaryPart then
								npc.preSeatCFrame = npc.model.PrimaryPart.CFrame
							end
							npc.seatTargetCFrame = poi.seatCFrame
							-- Seed rotation to face seat before first walk-to-seat frame
							if npc.model.PrimaryPart and poi.seatCFrame then
								local pos = npc.model.PrimaryPart.Position
								local seatPos = poi.seatCFrame.Position
								local dir = Vector3.new(seatPos.X - pos.X, 0, seatPos.Z - pos.Z)
								if dir.Magnitude > 0.01 then
									npc.model.PrimaryPart.CFrame = CFrame.lookAt(pos, pos + dir)
								end
							end
							if not lodRuntimeEnabled or LODController.shouldAnimate(npc.lodTier) then
								NPCAnimator.update(npc, true)
							end
						end
					elseif finished then
						npc.state = "finished"
						beginFadeOut(npc)
						if not lodRuntimeEnabled or LODController.shouldAnimate(npc.lodTier) then
							NPCAnimator.update(npc, false)
						end
					else
						if not lodRuntimeEnabled or LODController.shouldAnimate(npc.lodTier) then
							NPCAnimator.update(npc, true)
						end
					end
				elseif finished then
					npc.state = "finished"
					beginFadeOut(npc)
					if not lodRuntimeEnabled or LODController.shouldAnimate(npc.lodTier) then
						NPCAnimator.update(npc, false)
					end
				else
					if not lodRuntimeEnabled or LODController.shouldAnimate(npc.lodTier) then
						NPCAnimator.update(npc, true)
					end
				end
			elseif npc.state == "dwelling" then
				if Config.TurnSmoothing and npc.dwellFacingTarget and npc.model.PrimaryPart then
					local pos = npc.model.PrimaryPart.Position
					local flatTarget = Vector3.new(npc.dwellFacingTarget.X, pos.Y, npc.dwellFacingTarget.Z)
					if (flatTarget - pos).Magnitude > 0.01 then
						local targetRotation = CFrame.lookAt(pos, flatTarget).Rotation
						local currentRotation = npc.model.PrimaryPart.CFrame.Rotation
						local alpha = math.min(1, dt * Config.TurnLerpSpeed)
						local smoothedRotation = currentRotation:Lerp(targetRotation, alpha)
						npc.model.PrimaryPart.CFrame = smoothedRotation + pos
					end
				end
				if not lodRuntimeEnabled or LODController.shouldAnimate(npc.lodTier) then
					NPCAnimator.update(npc, false)
				end
				if npc.dwellEndTime and now >= npc.dwellEndTime then
					npc.nextPoiStopIdx += 1
					npc.state = "walking"
					npc.dwellEndTime = nil
					npc.dwellFacingTarget = nil
					NPCAnimator.stopSit(npc)
					if not lodRuntimeEnabled or LODController.shouldAnimate(npc.lodTier) then
						NPCAnimator.update(npc, true)
					end
				end
				elseif npc.state == "walking_to_seat" then
					if npc.seatTargetCFrame then
						local reachedSeat = moveModelTowardCFrame(npc, npc.seatTargetCFrame, movementDt)
						if npc.model.PrimaryPart then
							npc.lastKnownPosition = npc.model.PrimaryPart.Position
						end
						if not lodRuntimeEnabled or LODController.shouldAnimate(npc.lodTier) then
							NPCAnimator.update(npc, true)
						end
						if reachedSeat then
							npc.state = "sitting"
							if npc.model.PrimaryPart and npc.seatTargetCFrame then
								npc.model.PrimaryPart.CFrame = npc.seatTargetCFrame
							end
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
					if npc.seatTargetCFrame and npc.model.PrimaryPart then
						local pos = npc.model.PrimaryPart.Position
						local targetRotation = npc.seatTargetCFrame.Rotation
						if Config.TurnSmoothing then
							local currentRotation = npc.model.PrimaryPart.CFrame.Rotation
							local alpha = math.min(1, dt * Config.TurnLerpSpeed)
							npc.model.PrimaryPart.CFrame = currentRotation:Lerp(targetRotation, alpha) + pos
						else
							npc.model.PrimaryPart.CFrame = targetRotation + pos
						end
					end
					if not lodRuntimeEnabled or LODController.shouldAnimate(npc.lodTier) then
						NPCAnimator.playSit(npc)
					end
					if npc.dwellEndTime and now >= npc.dwellEndTime then
						if not lodRuntimeEnabled or LODController.shouldAnimate(npc.lodTier) then
							NPCAnimator.stopSit(npc)
						end
						npc.state = "walking_from_seat"
						npc.dwellEndTime = nil
						-- Seed rotation to face social waypoint before first walk-back frame
						if npc.model.PrimaryPart and npc.preSeatCFrame then
							local pos = npc.model.PrimaryPart.Position
							local wpPos = npc.preSeatCFrame.Position
							local dir = Vector3.new(wpPos.X - pos.X, 0, wpPos.Z - pos.Z)
							if dir.Magnitude > 0.01 then
								npc.model.PrimaryPart.CFrame = CFrame.lookAt(pos, pos + dir)
							end
						end
					end
				elseif npc.state == "walking_from_seat" then
					if npc.preSeatCFrame then
						local waypointTarget = npc.preSeatCFrame
						if npc.model.PrimaryPart then
							local nextIdx = math.min(#npc.waypoints, npc.currentLeg + 1)
							local nextWaypoint = npc.waypoints[nextIdx]
							if nextWaypoint then
								local waypointPos = npc.preSeatCFrame.Position
								local flatLook = Vector3.new(nextWaypoint.X, waypointPos.Y, nextWaypoint.Z)
								if (flatLook - waypointPos).Magnitude > 0.01 then
									waypointTarget = CFrame.lookAt(waypointPos, flatLook)
								else
									waypointTarget = npc.model.PrimaryPart.CFrame.Rotation + waypointPos
								end
							else
								waypointTarget = npc.model.PrimaryPart.CFrame.Rotation + npc.preSeatCFrame.Position
							end
						end
						local reachedWaypoint = moveModelTowardCFrame(npc, waypointTarget, movementDt)
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
							-- Seed rotation to face next route waypoint before NPCMover takes over
							if npc.model.PrimaryPart then
								local nextIdx = math.min(#npc.waypoints, npc.currentLeg + 1)
								local nextWp = npc.waypoints[nextIdx]
								if nextWp then
									local pos = npc.model.PrimaryPart.Position
									local dir = Vector3.new(nextWp.X - pos.X, 0, nextWp.Z - pos.Z)
									if dir.Magnitude > 0.01 then
										npc.model.PrimaryPart.CFrame = CFrame.lookAt(pos, pos + dir)
									end
								end
							end
						end
					else
						npc.nextPoiStopIdx += 1
						npc.state = "walking"
						npc.seatTargetCFrame = nil
					end
					elseif npc.state == "finished" then
						beginFadeOut(npc)
						if not lodRuntimeEnabled or LODController.shouldAnimate(npc.lodTier) then
							NPCAnimator.update(npc, false)
						end
					end

			if headLookAllowed and npc.lodTier == "near" and playerPosition then
				local wasActive = npc.headLookActive
				HeadLookController.update(npc, playerPosition, dt, now)
				if not wasActive and npc.headLookActive then
					headLookTriggersTotal += 1
				end
			elseif npc.headLookAlpha and npc.headLookAlpha > 0 then
				HeadLookController.reset(npc)
			end

			if npc.model.PrimaryPart then
				npc.lastKnownPosition = npc.model.PrimaryPart.Position
			end
		end
	end)
end

startup()
