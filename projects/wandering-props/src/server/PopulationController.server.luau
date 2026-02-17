local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local sharedFolder = ReplicatedStorage:WaitForChild("WanderingPropsShared")

local Config = require(sharedFolder:WaitForChild("Config"))
local Remotes = require(sharedFolder:WaitForChild("Remotes"))
local RouteBuilder = require(sharedFolder:WaitForChild("RouteBuilder"))
local WaypointGraph = require(sharedFolder:WaitForChild("WaypointGraph"))
local PathSmoother = require(sharedFolder:WaitForChild("PathSmoother"))
local POIRegistry = require(script.Parent:WaitForChild("POIRegistry"))
local PopulationHooks = require(script.Parent:WaitForChild("PopulationHooks"))

local activeNPCs = {}
local activeCount = 0
local nextNpcId = 1
local validModels = {}
local rng = Random.new()
local lastModelIndex: number? = nil
local modelBag = {}
local modelBagCursor = 1

local npcsSpawnedTotal = 0
local npcsDespawnedTotal = 0
local routeFailures = 0

local poiRoutesTotal = 0
local poiSkips = 0
local seatsOccupiedNow = 0
local routeStuckTotal = 0
local zoneRoutesTotal = 0

local npcSpawnedRemote
local npcDespawnedRemote
local npcBulkSyncRemote
local npcDesyncRemote

local graph
local poiRegistry = nil
local wanderingFolder
local lastIsNightState: boolean? = nil
local queuedSpawnRequests = 0
local queuedRecycleRequests = {}
local queuedRecycleHead = 1
local queuedDespawnIds = {}
local queuedDespawnHead = 1
local queuedDespawnSet = {}
local queuedSpawnEvents = {}
local queuedDespawnEvents = {}
local queuedDespawnEventSet = {}
local nextEventFlushAt = 0
local bevelRuntimeEnabled = Config.BevelEnabled
local bevelRuntimeRadius = Config.BevelRadius
local bevelRuntimeSegments = math.max(2, math.floor(Config.BevelSegments or 2))

local function diagnostics(message: string)
	if Config.DiagnosticsEnabled then
		print(message)
	end
end

local function fatal(message: string)
	diagnostics(string.format("[WanderingProps] VALIDATION_FAIL %s", message))
	error(message)
end

local function validateConfig()
	if Config.WalkAnimationId == "" or Config.IdleAnimationId == "" then
		fatal("[WanderingProps] FATAL: Animation IDs not set in Config. Set WalkAnimationId and IdleAnimationId.")
	end
end

local function collectValidModels(modelsFolder: Folder)
	local allChildren = modelsFolder:GetChildren()
	if #allChildren == 0 then
		fatal("[WanderingProps] FATAL: No models found in WanderingPropModels.")
	end

	for _, child in ipairs(allChildren) do
		if child:IsA("Model") then
			if child.PrimaryPart then
				table.insert(validModels, child)
			else
				warn(string.format("[WanderingProps] WARNING: Model \"%s\" has no PrimaryPart set. It will be skipped.", child.Name))
			end
		end
	end

	if #validModels == 0 then
		fatal("[WanderingProps] FATAL: No valid models (all missing PrimaryPart).")
	end

	if #validModels == 1 then
		warn(string.format(
			"[WanderingProps] WARNING: Only one valid NPC model found (%s). All NPCs will use that model.",
			validModels[1].Name
		))
	end
end

local function refillModelBag()
	modelBag = {}
	for index = 1, #validModels do
		table.insert(modelBag, index)
	end

	for i = #modelBag, 2, -1 do
		local j = rng:NextInteger(1, i)
		modelBag[i], modelBag[j] = modelBag[j], modelBag[i]
	end

	modelBagCursor = 1
end

local function pickRandomModel(): Model
	if #validModels == 1 then
		lastModelIndex = 1
		return validModels[1]
	end

	if #modelBag == 0 or modelBagCursor > #modelBag then
		refillModelBag()
	end

	local index = modelBag[modelBagCursor]
	modelBagCursor += 1

	if lastModelIndex and index == lastModelIndex then
		if modelBagCursor <= #modelBag then
			local swapIndex = modelBag[modelBagCursor]
			modelBag[modelBagCursor] = index
			index = swapIndex
		else
			index = (index % #validModels) + 1
		end
	end

	lastModelIndex = index
	return validModels[index]
end

local function hideWaypointParts(builtGraph)
	if not Config.HideMarkersAtRuntime then
		return
	end

	for part in pairs(builtGraph.partToId) do
		if part and part:IsA("BasePart") then
			part.Transparency = 1
		end
	end
end

local function createRemoteEvent(remotesFolder: Folder, name: string): RemoteEvent
	local existing = remotesFolder:FindFirstChild(name)
	if existing then
		if existing:IsA("RemoteEvent") then
			return existing
		end
		existing:Destroy()
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = remotesFolder
	return remote
end

local function setupRemotes()
	local remotesFolder = ReplicatedStorage:FindFirstChild("WanderingPropsRemotes")
	if not remotesFolder then
		remotesFolder = Instance.new("Folder")
		remotesFolder.Name = "WanderingPropsRemotes"
		remotesFolder.Parent = ReplicatedStorage
	end

	npcSpawnedRemote = createRemoteEvent(remotesFolder, Remotes.NPCSpawned)
	npcDespawnedRemote = createRemoteEvent(remotesFolder, Remotes.NPCDespawned)
	npcBulkSyncRemote = createRemoteEvent(remotesFolder, Remotes.NPCBulkSync)
	npcDesyncRemote = createRemoteEvent(remotesFolder, Remotes.NPCDesync)
end

local function isEventBatchingEnabled(): boolean
	return Config.EventBatchingEnabled ~= false
end

local function fireRemoteWithDesyncFilter(remote: RemoteEvent, payload)
	if next(PopulationHooks.desyncedPlayers) == nil then
		remote:FireAllClients(payload)
		return
	end

	for _, player in ipairs(Players:GetPlayers()) do
		if not PopulationHooks.desyncedPlayers[player] then
			remote:FireClient(player, payload)
		end
	end
end

local function flushQueuedRemoteEvents(force: boolean?)
	if not npcSpawnedRemote or not npcDespawnedRemote then
		return
	end

	local now = Workspace:GetServerTimeNow()
	if isEventBatchingEnabled() then
		if not force and now < nextEventFlushAt then
			return
		end
	else
		if not force then
			return
		end
	end

	if #queuedDespawnEvents > 0 then
		local despawnPayload = if #queuedDespawnEvents == 1 then queuedDespawnEvents[1] else queuedDespawnEvents
		fireRemoteWithDesyncFilter(npcDespawnedRemote, despawnPayload)
		queuedDespawnEvents = {}
		queuedDespawnEventSet = {}
	end

	if #queuedSpawnEvents > 0 then
		local spawnPayload = if #queuedSpawnEvents == 1 then queuedSpawnEvents[1] else queuedSpawnEvents
		fireRemoteWithDesyncFilter(npcSpawnedRemote, spawnPayload)
		queuedSpawnEvents = {}
	end

	nextEventFlushAt = now + math.max(0.01, Config.EventBatchInterval or 0.05)
end

local function queueSpawnBroadcast(spawnData)
	table.insert(queuedSpawnEvents, spawnData)
	if not isEventBatchingEnabled() then
		flushQueuedRemoteEvents(true)
	end
end

local function queueDespawnBroadcast(id: string)
	if queuedDespawnEventSet[id] then
		return
	end
	queuedDespawnEventSet[id] = true
	table.insert(queuedDespawnEvents, id)
	if not isEventBatchingEnabled() then
		flushQueuedRemoteEvents(true)
	end
end

local function requestSpawn(count: number?)
	local amount = math.max(1, math.floor(count or 1))
	queuedSpawnRequests += amount
end

local function requestDespawn(id: string)
	if queuedDespawnSet[id] then
		return
	end
	queuedDespawnSet[id] = true
	table.insert(queuedDespawnIds, id)
end

local function getQueuedRecycleCount(): number
	if queuedRecycleHead > #queuedRecycleRequests then
		return 0
	end
	return #queuedRecycleRequests - queuedRecycleHead + 1
end

local function clampDelayRange(minValue: number?, maxValue: number?, fallback: number): (number, number)
	local minDelay = if minValue then math.max(0, minValue) else fallback
	local maxDelay = if maxValue then math.max(0, maxValue) else minDelay
	if maxDelay < minDelay then
		minDelay, maxDelay = maxDelay, minDelay
	end
	return minDelay, maxDelay
end

local function queueRecycleRequest(request, delayRangeMin: number?, delayRangeMax: number?)
	local minDelay, maxDelay = clampDelayRange(delayRangeMin, delayRangeMax, 0)
	local now = Workspace:GetServerTimeNow()
	local delaySeconds = if maxDelay > minDelay
		then rng:NextNumber(minDelay, maxDelay)
		else minDelay
	request.readyAt = now + delaySeconds
	table.insert(queuedRecycleRequests, request)
end

local function routeDistance(waypoints: { Vector3 }): number
	local totalDistance = 0
	for i = 1, #waypoints - 1 do
		totalDistance += (waypoints[i + 1] - waypoints[i]).Magnitude
	end
	return totalDistance
end

local function isNightNow(): boolean
	if not Config.DayNightEnabled then
		return false
	end

	local clockTime = Lighting.ClockTime % 24
	local nightStart = (Config.NightStartHour or 19) % 24
	local dayStart = (Config.DayStartHour or 6) % 24
	if nightStart == dayStart then
		return false
	end

	if nightStart < dayStart then
		return clockTime >= nightStart and clockTime < dayStart
	end
	return clockTime >= nightStart or clockTime < dayStart
end

local function getEffectiveMaxPopulation(): number
	local isNight = isNightNow()

	if isNight ~= lastIsNightState then
		lastIsNightState = isNight
		local effectiveMax = Config.MaxPopulation
		if isNight then
			effectiveMax = math.max(1, math.floor(Config.MaxPopulation * Config.NightPopulationMultiplier))
		end
		diagnostics(string.format(
			"[WanderingProps] DAYNIGHT_CHANGE isNight=%s effectiveMax=%d clock=%.2f",
			tostring(isNight),
			effectiveMax,
			Lighting.ClockTime
		))
	end

	if isNight then
		return math.max(1, math.floor(Config.MaxPopulation * Config.NightPopulationMultiplier))
	end
	return Config.MaxPopulation
end

local function randomizeZonePosition(node): Vector3
	if not node.zoneSize then
		return node.position
	end
	local halfX = node.zoneSize.X / 2
	local halfZ = node.zoneSize.Z / 2
	return node.position + Vector3.new(
		rng:NextNumber(-halfX, halfX),
		0,
		rng:NextNumber(-halfZ, halfZ)
	)
end

local function randomizePOIWaypointPosition(basePosition: Vector3, waypointSize: Vector3?): Vector3
	if not waypointSize or waypointSize.X <= 0 or waypointSize.Z <= 0 then
		return basePosition
	end
	local halfX = waypointSize.X / 2
	local halfZ = waypointSize.Z / 2
	return basePosition + Vector3.new(
		rng:NextNumber(-halfX, halfX),
		0,
		rng:NextNumber(-halfZ, halfZ)
	)
end

local function pickNearestDespawnNodeId(graphTable, fromNodeId: string?): string
	if not fromNodeId or not graphTable.nodes[fromNodeId] then
		return RouteBuilder.pickRandomDespawn(graphTable)
	end

	local fromNode = graphTable.nodes[fromNodeId]
	local nearestId = graphTable.despawns[1]
	local nearestDist = math.huge
	for _, despawnId in ipairs(graphTable.despawns) do
		local despawnNode = graphTable.nodes[despawnId]
		if despawnNode then
			local dist = (despawnNode.position - fromNode.position).Magnitude
			if dist < nearestDist then
				nearestDist = dist
				nearestId = despawnId
			end
		end
	end
	return nearestId or RouteBuilder.pickRandomDespawn(graphTable)
end

local function buildRouteNodeIds(graphTable, preferNearestDespawn: boolean?): { string }?
	for _ = 1, 3 do
		local spawnId = RouteBuilder.pickRandomSpawn(graphTable)
		local despawnId = if preferNearestDespawn
			then pickNearestDespawnNodeId(graphTable, spawnId)
			else RouteBuilder.pickRandomDespawn(graphTable)
		local nodeIds = RouteBuilder.computeRoute(graphTable, spawnId, despawnId)
		if nodeIds then
			return nodeIds
		end
	end
	return nil
end

local function makeSpawnData(record)
	return {
		id = record.id,
		modelName = record.modelName,
		modelTemplate = record.modelTemplate,
		walkSpeed = record.walkSpeed,
		waypoints = record.waypoints,
		startTime = record.startTime,
		poiStops = record.poiStops,
	}
end

local function releaseSeatClaim(poiId: string, seatIndex: number, expectedNpcId: string?)
	if not poiRegistry then
		return
	end

	local poi = POIRegistry.getPOI(poiRegistry, poiId)
	if not poi then
		return
	end

	local occupantId = nil
	if poi.seats and poi.seats[seatIndex] then
		occupantId = poi.seats[seatIndex].occupiedBy
	end

	if occupantId == nil then
		return
	end
	if expectedNpcId and occupantId ~= expectedNpcId then
		-- Ignore stale timers/releases that no longer own this seat.
		return
	end

	POIRegistry.releaseSeat(poi, seatIndex)

	seatsOccupiedNow = math.max(0, seatsOccupiedNow - 1)
	local totalSeats = poi.totalSeats or (poi.seats and #poi.seats or 0)
	diagnostics(string.format(
		"[WanderingProps] SEAT_RELEASE poi=%s seat=%d occupied=%d/%d",
		poi.id,
		seatIndex,
		poi.occupiedCount or 0,
		totalSeats
	))
end

local function releaseMarketStandClaim(poiId: string, standIndex: number, expectedNpcId: string?)
	if not poiRegistry then
		return
	end

	local poi = POIRegistry.getPOI(poiRegistry, poiId)
	if not poi or poi.poiType ~= "market" or not poi.stands or not poi.stands[standIndex] then
		return
	end

	local stand = poi.stands[standIndex]
	local occupiedCount = stand.occupiedCount or 0
	if occupiedCount <= 0 then
		return
	end

	POIRegistry.releaseMarketStand(poi, standIndex)
	diagnostics(string.format(
		"[WanderingProps] MARKET_CLAIM_RELEASE poi=%s stand=%d occupied=%d/%d",
		poi.id,
		standIndex,
		math.max(0, (stand.occupiedCount or 0)),
		stand.capacity or 0
	))
end

local spawnNPC

local function despawnNPC(id: string)
	local record = activeNPCs[id]
	if not record then
		return
	end

	if record.seatClaims then
		for _, claim in ipairs(record.seatClaims) do
			releaseSeatClaim(claim.poiId, claim.seatIndex, claim.npcId)
		end
	end
	if record.marketStandClaims then
		for _, claim in ipairs(record.marketStandClaims) do
			releaseMarketStandClaim(claim.poiId, claim.standIndex, claim.npcId)
		end
	end

	activeNPCs[id] = nil
	activeCount -= 1
	npcsDespawnedTotal += 1

	if Config.RecycleNPCsEnabled and spawnNPC then
		queueRecycleRequest({
			reuseId = id,
			model = record.modelTemplate,
			baseWalkSpeed = record.baseWalkSpeed or record.walkSpeed,
			routeVersion = (record.routeVersion or 1) + 1,
		}, Config.RecycleRespawnDelayMin, Config.RecycleRespawnDelayMax)
		queueDespawnBroadcast(id)
		diagnostics(string.format(
			"[WanderingProps] RECYCLE_QUEUE %s active=%d/%d pending_recycle=%d",
			id,
			activeCount,
			Config.MaxPopulation,
			getQueuedRecycleCount()
		))
		return
	end

	queueDespawnBroadcast(id)
	diagnostics(string.format(
		"[WanderingProps] DESPAWN %s active=%d/%d total_despawned=%d",
		id,
		activeCount,
		Config.MaxPopulation,
		npcsDespawnedTotal
	))
end

local function buildNodeSequence(spawnId: string, selectedPOIs, despawnId: string, chosenEntrances: { [number]: string }?)
	local nodeSequence = { spawnId }
	for i, poi in ipairs(selectedPOIs) do
		local entranceId = if chosenEntrances then chosenEntrances[i] else nil
		table.insert(nodeSequence, entranceId or poi.waypointNodeId)
	end
	table.insert(nodeSequence, despawnId)
	return nodeSequence
end

local function findBusyBacktrackPOIIndex(selectedPOIs, poiWaypointIndices, pathNodeIds): number?
	for i, poi in ipairs(selectedPOIs) do
		if poi.poiType == "busy" then
			local waypointIndex = poiWaypointIndices[i]
			if waypointIndex and waypointIndex > 1 and waypointIndex < #pathNodeIds then
				if pathNodeIds[waypointIndex - 1] == pathNodeIds[waypointIndex + 1] then
					return i
				end
			end
		end
	end
	return nil
end

local function convertNodeIdsToWaypoints(pathNodeIds: { string }, poiWaypointIndexSet: { [number]: boolean }?)
	local waypoints = {}
	local indexSet = poiWaypointIndexSet or {}
	local maxOffset = Config.PathLateralOffsetMax or 0
	for i, nodeId in ipairs(pathNodeIds) do
		local node = graph.nodes[nodeId]
		if node.zoneSize and not indexSet[i] then
			table.insert(waypoints, randomizeZonePosition(node))
		elseif maxOffset > 0 and i > 1 and i < #pathNodeIds and not indexSet[i] then
			local prevPos = graph.nodes[pathNodeIds[i - 1]].position
			local nextPos = graph.nodes[pathNodeIds[i + 1]].position
			local forward = nextPos - prevPos
			local flatForward = Vector3.new(forward.X, 0, forward.Z)
			if flatForward.Magnitude > 0.01 then
				local perpendicular = Vector3.new(-flatForward.Z, 0, flatForward.X).Unit
				local offset = rng:NextNumber(-maxOffset, maxOffset)
				table.insert(waypoints, node.position + perpendicular * offset)
			else
				table.insert(waypoints, node.position)
			end
		else
			table.insert(waypoints, node.position)
		end
	end
	return waypoints
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

local function calculateServerRouteState(waypoints: { Vector3 }, walkSpeed: number, elapsed: number, poiStops)
	if not poiStops or #poiStops == 0 then
		local position, currentLeg, legProgress = calculatePositionAlongWaypoints(waypoints, walkSpeed, elapsed, 1, #waypoints)
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
				if poi.type == "social" and poi.seatCFrame then
					return {
						state = "sitting",
						position = poi.seatCFrame.Position,
						currentLeg = poi.waypointIndex,
						legProgress = 0,
						nextPoiStopIdx = poiIdx,
					}
				end
				return {
					state = "dwelling",
					position = waypoints[poi.waypointIndex],
					currentLeg = poi.waypointIndex,
					legProgress = 0,
					nextPoiStopIdx = poiIdx,
				}
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
		legProgress = 1,
		nextPoiStopIdx = #poiStops + 1,
	}
end

local function scheduleNPCDespawn(record, duration: number)
	local delaySeconds = math.max(0, duration)
	local scheduledAt = Workspace:GetServerTimeNow() + delaySeconds
	record.despawnAt = scheduledAt
	task.delay(delaySeconds, function()
		local current = activeNPCs[record.id]
		if current and current.despawnAt == scheduledAt then
			requestDespawn(record.id)
		end
	end)
end

local function findNearestNodeIdFromPosition(position: Vector3): string?
	local nearestId = nil
	local nearestDist = math.huge
	for nodeId, node in pairs(graph.nodes) do
		if node then
			local dist = (node.position - position).Magnitude
			if dist < nearestDist then
				nearestDist = dist
				nearestId = nodeId
			end
		end
	end
	return nearestId
end

local function findNearestDespawnIdFromPosition(position: Vector3): string?
	local nearestId = nil
	local nearestDist = math.huge
	for _, despawnId in ipairs(graph.despawns) do
		local node = graph.nodes[despawnId]
		if node then
			local dist = (node.position - position).Magnitude
			if dist < nearestDist then
				nearestDist = dist
				nearestId = despawnId
			end
		end
	end
	return nearestId
end

local function rerouteRecordToNearestDespawn(record, now: number, reason: string): boolean
	if not record or not record.waypoints or #record.waypoints < 1 then
		return false
	end

	local elapsed = math.max(0, now - record.startTime)
	local routeState = calculateServerRouteState(record.waypoints, record.walkSpeed, elapsed, record.poiStops)
	local currentPosition = routeState.position
	local startNodeId = findNearestNodeIdFromPosition(currentPosition)
	local despawnId = findNearestDespawnIdFromPosition(currentPosition)

	if not startNodeId or not despawnId then
		return false
	end

	local routeNodeIds = RouteBuilder.computeRoute(graph, startNodeId, despawnId)
	local newWaypoints = nil
	if routeNodeIds and #routeNodeIds > 0 then
		newWaypoints = convertNodeIdsToWaypoints(routeNodeIds, nil)
	else
		newWaypoints = { graph.nodes[despawnId].position }
	end
	if #newWaypoints == 0 then
		return false
	end
	if (newWaypoints[1] - currentPosition).Magnitude > 0.01 then
		table.insert(newWaypoints, 1, currentPosition)
	else
		newWaypoints[1] = currentPosition
	end
	if #newWaypoints < 2 then
		return false
	end

	if record.seatClaims then
		for _, claim in ipairs(record.seatClaims) do
			releaseSeatClaim(claim.poiId, claim.seatIndex, claim.npcId)
		end
	end
	if record.marketStandClaims then
		for _, claim in ipairs(record.marketStandClaims) do
			releaseMarketStandClaim(claim.poiId, claim.standIndex, claim.npcId)
		end
	end

	record.seatClaims = nil
	record.marketStandClaims = nil
	record.poiStops = nil
	record.waypoints = newWaypoints
	record.startTime = now
	record.nightDrainApplied = true
	record.routeVersion = (record.routeVersion or 1) + 1

	local duration = 0
	if record.walkSpeed > 0 then
		duration = routeDistance(newWaypoints) / record.walkSpeed
	end
	record.totalDuration = duration
	scheduleNPCDespawn(record, duration)
	queueSpawnBroadcast(makeSpawnData(record))

	diagnostics(string.format(
		"[WanderingProps] REROUTE_%s %s legs=%d",
		reason,
		record.id,
		math.max(0, #newWaypoints - 1)
	))
	return true
end

local function trimRouteForNightDrain(record, now: number): boolean
	if not record or record.nightDrainApplied or not record.waypoints or #record.waypoints < 2 then
		return false
	end

	local elapsed = math.max(0, now - record.startTime)
	local routeState = calculateServerRouteState(record.waypoints, record.walkSpeed, elapsed, record.poiStops)
	if routeState.state == "sitting" then
		-- Do not reroute while seated; let client walk out from seat naturally.
		return false
	end

	local newWaypoints = { routeState.position }
	local newPoiStops = nil
	if record.poiStops and routeState.nextPoiStopIdx <= #record.poiStops then
		local nextPoiStop = table.clone(record.poiStops[routeState.nextPoiStopIdx])
		local stopPosition = record.waypoints[nextPoiStop.waypointIndex]
		if stopPosition then
			if (stopPosition - newWaypoints[#newWaypoints]).Magnitude > 0.01 then
				table.insert(newWaypoints, stopPosition)
				nextPoiStop.waypointIndex = #newWaypoints
			else
				nextPoiStop.waypointIndex = 1
			end
			if routeState.state == "dwelling" then
				nextPoiStop.dwellTime = 0
			end
			newPoiStops = { nextPoiStop }
		end
	end

	local despawnWaypoint = record.waypoints[#record.waypoints]
	if (despawnWaypoint - newWaypoints[#newWaypoints]).Magnitude > 0.01 then
		table.insert(newWaypoints, despawnWaypoint)
	end
	if #newWaypoints < 2 then
		return false
	end

	if bevelRuntimeEnabled and #newWaypoints > 2 then
		newWaypoints, newPoiStops = PathSmoother.bevel(
			newWaypoints,
			newPoiStops,
			bevelRuntimeRadius,
			bevelRuntimeSegments
		)
	end

	if record.seatClaims then
		for _, claim in ipairs(record.seatClaims) do
			releaseSeatClaim(claim.poiId, claim.seatIndex, claim.npcId)
		end
	end
	if record.marketStandClaims then
		for _, claim in ipairs(record.marketStandClaims) do
			releaseMarketStandClaim(claim.poiId, claim.standIndex, claim.npcId)
		end
	end
	record.seatClaims = nil
	record.marketStandClaims = nil
	record.poiStops = newPoiStops
	record.waypoints = newWaypoints
	record.startTime = now
	record.nightDrainApplied = true

	local totalDwellTime = 0
	for _, poi in ipairs(record.poiStops or {}) do
		totalDwellTime += poi.dwellTime
	end
	local totalDuration = totalDwellTime
	if record.walkSpeed > 0 then
		totalDuration += routeDistance(newWaypoints) / record.walkSpeed
	end
	record.totalDuration = totalDuration

	scheduleNPCDespawn(record, totalDuration)
	queueSpawnBroadcast(makeSpawnData(record))
	diagnostics(string.format(
		"[WanderingProps] NIGHT_DRAIN_ROUTE %s nextPoi=%s legs=%d",
		record.id,
		tostring(newPoiStops ~= nil),
		math.max(0, #newWaypoints - 1)
	))

	return true
end

local function applyNightDrain(now: number)
	if not Config.NightDrainEnabled or not isNightNow() then
		return
	end

	local effectiveMax = getEffectiveMaxPopulation()
	local excess = activeCount - effectiveMax
	if excess <= 0 then
		return
	end

	local candidates = {}
	for _, record in pairs(activeNPCs) do
		local despawnAt = record.despawnAt or (record.startTime + record.totalDuration)
		local remaining = math.max(0, despawnAt - now)
		table.insert(candidates, {
			record = record,
			remaining = remaining,
		})
	end
	table.sort(candidates, function(a, b)
		return a.remaining > b.remaining
	end)

	local batchSize = math.max(1, math.floor(Config.NightDrainBatchSize))
	local target = math.min(excess, batchSize)
	local drained = 0
	for _, candidate in ipairs(candidates) do
		if drained >= target then
			break
		end
		if trimRouteForNightDrain(candidate.record, now) then
			drained += 1
		end
	end

	if drained > 0 then
		diagnostics(string.format(
			"[WanderingProps] NIGHT_DRAIN trimmed=%d excess=%d active=%d target=%d",
			drained,
			excess,
			activeCount,
			effectiveMax
		))
	end
end

local function expandSocialInternalWaypoints(
	waypoints: { Vector3 },
	poiWaypointIndex: number,
	poi,
	accessNodeId: string,
	chosenEntranceNodeId: string?
): ({ Vector3 }, number, number)
	if not poi.internalGraph then
		diagnostics(string.format("[WanderingProps] INTERNAL_NAV_SKIP poi=%s reason=no_internal_graph", poi.id))
		return waypoints, poiWaypointIndex, 0
	end
	if not accessNodeId then
		diagnostics(string.format("[WanderingProps] INTERNAL_NAV_SKIP poi=%s reason=no_access_node", poi.id))
		return waypoints, poiWaypointIndex, 0
	end

	-- Filter entry nodes to those mapping to the chosen entrance (if specified)
	local candidateEntryIds = poi.internalGraph.entryNodeIds
	if chosenEntranceNodeId and poi.internalGraph.entryToEntranceMap then
		local filtered = {}
		for _, entryId in ipairs(poi.internalGraph.entryNodeIds) do
			if poi.internalGraph.entryToEntranceMap[entryId] == chosenEntranceNodeId then
				table.insert(filtered, entryId)
			end
		end
		if #filtered > 0 then
			candidateEntryIds = filtered
		end
	end

	diagnostics(string.format(
		"[WanderingProps] INTERNAL_NAV_BFS poi=%s entries=%d accessNode=%s",
		poi.id, #candidateEntryIds, accessNodeId
	))

	-- Pick the entry node with the shortest path to the access node
	local approachPath = nil
	for _, candidateEntryId in ipairs(candidateEntryIds) do
		local candidatePath = POIRegistry.getCachedInternalPath(poi, candidateEntryId, accessNodeId)
		diagnostics(string.format(
			"[WanderingProps] INTERNAL_NAV_BFS_TRY entry=%s result=%s",
			candidateEntryId, if candidatePath then tostring(#candidatePath) else "nil"
		))
		if candidatePath and #candidatePath >= 2 then
			if not approachPath or #candidatePath < #approachPath then
				approachPath = candidatePath
			end
		end
	end
	if not approachPath then
		diagnostics(string.format("[WanderingProps] INTERNAL_NAV_SKIP poi=%s reason=no_path_found", poi.id))
		return waypoints, poiWaypointIndex, 0
	end

	-- Build new waypoints array with approach + exit inserted around the POI waypoint
	local newWaypoints = {}

	-- Copy waypoints up to and including the POI waypoint
	for i = 1, poiWaypointIndex do
		table.insert(newWaypoints, waypoints[i])
	end

	-- Insert approach waypoints (door → ... → access node)
	for i = 1, #approachPath do
		table.insert(newWaypoints, approachPath[i])
	end

	-- The new POI waypoint index is at the end of the approach path
	-- (the access node position, where the NPC enters the seat state)
	local newPoiWaypointIndex = #newWaypoints

	-- Build exit path (reverse of approach)
	-- Skip first element (access node — NPC is already there after walking from seat)
	for i = #approachPath - 1, 1, -1 do
		table.insert(newWaypoints, approachPath[i])
	end

	-- Return through the social POI waypoint before leaving the POI route.
	table.insert(newWaypoints, waypoints[poiWaypointIndex])

	-- Copy remaining waypoints after the original POI waypoint
	for i = poiWaypointIndex + 1, #waypoints do
		table.insert(newWaypoints, waypoints[i])
	end

	local insertedCount = #newWaypoints - #waypoints
	return newWaypoints, newPoiWaypointIndex, insertedCount
end

local function expandScenicStandWaypoints(
	waypoints: { Vector3 },
	poiWaypointIndex: number,
	standPoint: Vector3
): ({ Vector3 }, number, number)
	local scenicWaypoint = waypoints[poiWaypointIndex]
	if not scenicWaypoint then
		return waypoints, poiWaypointIndex, 0
	end

	local newWaypoints = {}
	for i = 1, poiWaypointIndex do
		table.insert(newWaypoints, waypoints[i])
	end

	-- Scenic flow: walk through scenic waypoint -> stand point (dwell) -> scenic waypoint -> continue.
	table.insert(newWaypoints, standPoint)
	local newPoiWaypointIndex = #newWaypoints
	table.insert(newWaypoints, scenicWaypoint)

	for i = poiWaypointIndex + 1, #waypoints do
		table.insert(newWaypoints, waypoints[i])
	end

	local insertedCount = #newWaypoints - #waypoints
	return newWaypoints, newPoiWaypointIndex, insertedCount
end

local function expandScenicInternalWaypoints(
	waypoints: { Vector3 },
	poiWaypointIndex: number,
	poi,
	standPoint: Vector3,
	standAccessNodeId: string?,
	chosenEntranceNodeId: string?
): ({ Vector3 }, number, number)
	if not poi.internalGraph or not standAccessNodeId then
		return expandScenicStandWaypoints(waypoints, poiWaypointIndex, standPoint)
	end

	local candidateEntryIds = poi.internalGraph.entryNodeIds
	if chosenEntranceNodeId and poi.internalGraph.entryToEntranceMap then
		local filtered = {}
		for _, entryId in ipairs(poi.internalGraph.entryNodeIds) do
			if poi.internalGraph.entryToEntranceMap[entryId] == chosenEntranceNodeId then
				table.insert(filtered, entryId)
			end
		end
		if #filtered > 0 then
			candidateEntryIds = filtered
		end
	end

	local approachPath = nil
	for _, candidateEntryId in ipairs(candidateEntryIds) do
		local candidatePath = POIRegistry.getCachedInternalPath(poi, candidateEntryId, standAccessNodeId)
		if candidatePath and #candidatePath >= 1 then
			if not approachPath or #candidatePath < #approachPath then
				approachPath = candidatePath
			end
		end
	end
	if not approachPath then
		diagnostics(string.format("[WanderingProps] SCENIC_INTERNAL_SKIP poi=%s reason=no_path_found", poi.id))
		return expandScenicStandWaypoints(waypoints, poiWaypointIndex, standPoint)
	end

	local newWaypoints = {}
	for i = 1, poiWaypointIndex do
		table.insert(newWaypoints, waypoints[i])
	end

	-- Scenic internal flow: entrance -> internal path -> stand point (dwell) -> internal path back -> continue.
	for i = 1, #approachPath do
		table.insert(newWaypoints, approachPath[i])
	end
	table.insert(newWaypoints, standPoint)
	local newPoiWaypointIndex = #newWaypoints
	for i = #approachPath, 1, -1 do
		table.insert(newWaypoints, approachPath[i])
	end

	for i = poiWaypointIndex + 1, #waypoints do
		table.insert(newWaypoints, waypoints[i])
	end

	local insertedCount = #newWaypoints - #waypoints
	return newWaypoints, newPoiWaypointIndex, insertedCount
end

local function selectMarketStandPosition(stand): Vector3
	local halfX = stand.standZoneSize.X / 2
	local halfZ = stand.standZoneSize.Z / 2
	local localOffset = Vector3.new(
		rng:NextNumber(-halfX, halfX),
		0,
		rng:NextNumber(-halfZ, halfZ)
	)
	if stand.standZoneCFrame then
		return stand.standZoneCFrame:PointToWorldSpace(localOffset)
	end
	return stand.standZonePosition + localOffset
end

local function pathDistance(path: { Vector3 }): number
	local total = 0
	for i = 1, #path - 1 do
		total += (path[i + 1] - path[i]).Magnitude
	end
	return total
end

local function appendUniquePathPoints(dst: { Vector3 }, path: { Vector3 })
	for _, point in ipairs(path) do
		if #dst == 0 or (dst[#dst] - point).Magnitude > 0.01 then
			table.insert(dst, point)
		end
	end
end

local function resolveStandAccessNodeIds(stand): { string }
	local ids = {}
	if stand.accessNodeIds then
		for _, nodeId in ipairs(stand.accessNodeIds) do
			if nodeId and not table.find(ids, nodeId) then
				table.insert(ids, nodeId)
			end
		end
	end
	if stand.accessNodeId and not table.find(ids, stand.accessNodeId) then
		table.insert(ids, stand.accessNodeId)
	end
	return ids
end

local function pickBestStandPath(internalGraph, fromNodeId: string, stand): ({ Vector3 }?, string?)
	local candidateNodeIds = resolveStandAccessNodeIds(stand)
	if #candidateNodeIds == 0 then
		return nil, nil
	end

	local bestPath = nil
	local bestNodeId = nil
	local bestDistance = math.huge
	for _, accessNodeId in ipairs(candidateNodeIds) do
		local candidatePath = POIRegistry.computeInternalPath(internalGraph, fromNodeId, accessNodeId)
		if candidatePath and #candidatePath >= 1 then
			local distance = pathDistance(candidatePath)
			if distance < bestDistance then
				bestDistance = distance
				bestPath = candidatePath
				bestNodeId = accessNodeId
			end
		end
	end
	return bestPath, bestNodeId
end

local function expandMarketInternalWaypoints(
	waypoints: { Vector3 },
	poiWaypointIndex: number,
	poi,
	selectedStandIndices: { number },
	chosenEntranceNodeId: string?
): ({ Vector3 }, { number }, number)
	if not poi.internalGraph or not poi.stands or not selectedStandIndices or #selectedStandIndices == 0 then
		return waypoints, {}, 0
	end

	local candidateEntryIds = poi.internalGraph.entryNodeIds
	if chosenEntranceNodeId and poi.internalGraph.entryToEntranceMap then
		local filtered = {}
		for _, entryId in ipairs(poi.internalGraph.entryNodeIds) do
			if poi.internalGraph.entryToEntranceMap[entryId] == chosenEntranceNodeId then
				table.insert(filtered, entryId)
			end
		end
		if #filtered > 0 then
			candidateEntryIds = filtered
		end
	end
	if not candidateEntryIds or #candidateEntryIds == 0 then
		return waypoints, {}, 0
	end

	local entryNodeId = candidateEntryIds[1]
	local firstStand = poi.stands[selectedStandIndices[1]]
	local firstAccessNodeIds = if firstStand then resolveStandAccessNodeIds(firstStand) else {}
	if #firstAccessNodeIds > 0 then
		local bestPathDistance = math.huge
		for _, candidateEntryId in ipairs(candidateEntryIds) do
			for _, firstAccessNodeId in ipairs(firstAccessNodeIds) do
				local candidatePath = POIRegistry.computeInternalPath(poi.internalGraph, candidateEntryId, firstAccessNodeId)
				if candidatePath and #candidatePath >= 1 then
					local distance = pathDistance(candidatePath)
					if distance < bestPathDistance then
						bestPathDistance = distance
						entryNodeId = candidateEntryId
					end
				end
			end
		end
	end

	local newWaypoints = {}
	for i = 1, poiWaypointIndex do
		table.insert(newWaypoints, waypoints[i])
	end

	local standWaypointIndices = {}
	local currentAccessNodeId = entryNodeId
	for _, standIndex in ipairs(selectedStandIndices) do
		local stand = poi.stands[standIndex]
		if not stand then
			continue
		end

		local standPath, chosenStandAccessNodeId = pickBestStandPath(poi.internalGraph, currentAccessNodeId, stand)
		if standPath and #standPath >= 1 then
			appendUniquePathPoints(newWaypoints, standPath)
		else
			diagnostics(string.format(
				"[WanderingProps] MARKET_SKIP_STAND poi=%s stand=%d reason=no_path",
				poi.id,
				standIndex
			))
			continue
		end

		table.insert(newWaypoints, selectMarketStandPosition(stand))
		table.insert(standWaypointIndices, #newWaypoints)
		if chosenStandAccessNodeId then
			currentAccessNodeId = chosenStandAccessNodeId
		end
	end

	if #standWaypointIndices == 0 then
		return waypoints, {}, 0
	end

	if currentAccessNodeId ~= entryNodeId then
		local exitPath = POIRegistry.computeInternalPath(poi.internalGraph, currentAccessNodeId, entryNodeId)
		if exitPath and #exitPath >= 1 then
			appendUniquePathPoints(newWaypoints, exitPath)
		end
	end

	-- Return through the external market entry node before continuing route.
	if waypoints[poiWaypointIndex] then
		table.insert(newWaypoints, waypoints[poiWaypointIndex])
	end

	for i = poiWaypointIndex + 1, #waypoints do
		table.insert(newWaypoints, waypoints[i])
	end

	local insertedCount = #newWaypoints - #waypoints
	return newWaypoints, standWaypointIndices, insertedCount
end

local function findUnreachableSocialInternalPOIIndex(selectedPOIs, claimedSeatsByPoiId, chosenEntrances): number?
	if not Config.InternalNavigationEnabled then
		return nil
	end

	for i, poi in ipairs(selectedPOIs) do
		if poi.poiType == "social" and poi.internalGraph then
			local claim = claimedSeatsByPoiId[poi.id]
			local accessNodeId = if claim then claim.accessNodeId else nil
			if not accessNodeId then
				return i
			end

			local candidateEntryIds = poi.internalGraph.entryNodeIds
			local chosenEntranceNodeId = if chosenEntrances then chosenEntrances[i] else nil
			if chosenEntranceNodeId and poi.internalGraph.entryToEntranceMap then
				local filtered = {}
				for _, entryId in ipairs(poi.internalGraph.entryNodeIds) do
					if poi.internalGraph.entryToEntranceMap[entryId] == chosenEntranceNodeId then
						table.insert(filtered, entryId)
					end
				end
				if #filtered > 0 then
					candidateEntryIds = filtered
				end
			end

				local hasPath = false
				for _, candidateEntryId in ipairs(candidateEntryIds) do
					local candidatePath = POIRegistry.getCachedInternalPath(poi, candidateEntryId, accessNodeId)
					if candidatePath and #candidatePath >= 2 then
						hasPath = true
						break
					end
			end
			if not hasPath then
				return i
			end
		end
	end

	return nil
end

local function selectStandPointPosition(standPoints): (Vector3, string?)
	local sp = standPoints[rng:NextInteger(1, #standPoints)]
	local halfX = sp.size.X / 2
	local halfZ = sp.size.Z / 2
	local localOffset = Vector3.new(
		rng:NextNumber(-halfX, halfX),
		0,
		rng:NextNumber(-halfZ, halfZ)
	)
	if sp.cframe then
		return sp.cframe:PointToWorldSpace(localOffset), sp.accessNodeId
	end
	return sp.position + localOffset, sp.accessNodeId
end

spawnNPC = function(options)
	local effectiveMax = getEffectiveMaxPopulation()
	if activeCount >= effectiveMax then
		return false
	end
	local currentlyNight = isNightNow()
	local preferNearestDespawn = currentlyNight and Config.NightPreferNearestDespawn == true

	local model = nil
	if options and typeof(options.model) == "Instance" and options.model:IsA("Model") then
		model = options.model
	else
		model = pickRandomModel()
	end

	local baseWalkSpeed = nil
	if options and options.baseWalkSpeed ~= nil then
		baseWalkSpeed = math.max(0.1, options.baseWalkSpeed)
	elseif options and options.walkSpeed ~= nil then
		baseWalkSpeed = math.max(0.1, options.walkSpeed)
	else
		local walkVariation = math.abs(Config.WalkSpeedVariation or 0)
		local sampledWalkSpeed = Config.BaseWalkSpeed + rng:NextNumber(-walkVariation, walkVariation)
		baseWalkSpeed = math.max(0.1, sampledWalkSpeed)
	end
	local walkSpeed = baseWalkSpeed * math.max(0.1, PopulationHooks.walkSpeedMultiplier or 1.0)

	local id = nil
	if options and options.reuseId then
		id = options.reuseId
	else
		id = "npc_" .. tostring(nextNpcId)
		nextNpcId += 1
	end

	local routeVersion = 1
	if options and options.routeVersion ~= nil then
		routeVersion = options.routeVersion
	end

	local waypoints = nil
	local totalDistance = 0
	local poiStops = nil
	local seatClaims = nil
	local marketStandClaims = nil

	if poiRegistry and #poiRegistry.pois > 0 then
		local minPoiCount = Config.POICountMin
		local maxPoiCount = Config.POICountMax
		if currentlyNight then
			local nightPOIMax = math.max(0, math.floor(Config.NightPOICountMax))
			maxPoiCount = math.min(maxPoiCount, nightPOIMax)
			minPoiCount = math.min(minPoiCount, maxPoiCount)
		end

		local count = 0
		if maxPoiCount > 0 then
			count = math.random(minPoiCount, maxPoiCount)
		end
		count = math.min(count, #poiRegistry.pois)

			local spawnId = RouteBuilder.pickRandomSpawn(graph)
			local selectedPOIs = POIRegistry.selectPOIs(poiRegistry, count, graph.nodes[spawnId].position)
			local claimedSeatsByPoiId = {}
			local marketStandsByPoiId = {}

			local filteredPOIs = {}
			for _, poi in ipairs(selectedPOIs) do
				if poi.poiType == "social" then
					local seatIndex, seatCFrame, accessNodeId = POIRegistry.claimSeat(poi, id)
				if seatIndex and seatCFrame then
					claimedSeatsByPoiId[poi.id] = {
						seatIndex = seatIndex,
						seatCFrame = seatCFrame,
						accessNodeId = accessNodeId,
						npcId = id,
					}
					seatsOccupiedNow += 1
					local totalSeats = poi.totalSeats or (poi.seats and #poi.seats or 0)
					diagnostics(string.format(
						"[WanderingProps] SEAT_CLAIM poi=%s seat=%d npc=%s occupied=%d/%d",
						poi.id,
						seatIndex,
						id,
						poi.occupiedCount or 0,
						totalSeats
					))
					table.insert(filteredPOIs, poi)
					else
						poiSkips += 1
						diagnostics(string.format("[WanderingProps] POI_SKIP %s poi=%s reason=capacity_full", id, poi.id))
					end
				elseif poi.poiType == "market" then
					local stands = poi.stands or {}
					local standsMin = math.max(1, math.floor(Config.MarketStandsMin or 1))
					local standsMax = math.max(1, math.floor(Config.MarketStandsMax or standsMin))
					if standsMax < standsMin then
						standsMin, standsMax = standsMax, standsMin
					end
					local requestedCount = rng:NextInteger(standsMin, standsMax)

					local availableStandIndices = {}
					for standIndex, stand in ipairs(stands) do
						local configuredCap = math.max(1, math.floor(Config.MarketStandCapacity or 2))
						local capacity = math.max(1, math.floor(stand.capacity or configuredCap))
						capacity = math.min(capacity, configuredCap)
						if (stand.occupiedCount or 0) < capacity then
							table.insert(availableStandIndices, standIndex)
						end
					end

					if #availableStandIndices == 0 then
						poiSkips += 1
						diagnostics(string.format("[WanderingProps] POI_SKIP %s poi=%s reason=no_available_stands", id, poi.id))
					else
						local visitCount = math.min(requestedCount, #availableStandIndices)
						for idx = #availableStandIndices, 2, -1 do
							local swapIdx = rng:NextInteger(1, idx)
							availableStandIndices[idx], availableStandIndices[swapIdx] =
								availableStandIndices[swapIdx], availableStandIndices[idx]
						end

						local selectedStandIndices = {}
						local claimedAny = false
						for i = 1, visitCount do
							local standIndex = availableStandIndices[i]
							if standIndex and POIRegistry.claimMarketStand(poi, standIndex, id) then
								table.insert(selectedStandIndices, standIndex)
								claimedAny = true
							end
						end

						if claimedAny and #selectedStandIndices > 0 then
							marketStandsByPoiId[poi.id] = {
								standIndices = selectedStandIndices,
							}
							table.insert(filteredPOIs, poi)
						else
							poiSkips += 1
							diagnostics(string.format("[WanderingProps] POI_SKIP %s poi=%s reason=claim_failed", id, poi.id))
						end
					end
				else
					table.insert(filteredPOIs, poi)
				end
			end
		selectedPOIs = filteredPOIs

		-- Pick best external entrance for each POI with multiple entrances
		local chosenEntrances = nil
		if Config.InternalNavigationEnabled then
			local hasMultiEntrance = false
			for _, poi in ipairs(selectedPOIs) do
				if poi.entranceNodeIds and #poi.entranceNodeIds > 1 then
					hasMultiEntrance = true
					break
				end
			end
			if hasMultiEntrance then
				chosenEntrances = {}
				local prevPosition = graph.nodes[spawnId].position
				for i, poi in ipairs(selectedPOIs) do
					if poi.entranceNodeIds and #poi.entranceNodeIds > 1 then
						local bestId = poi.entranceNodeIds[1]
						local bestDist = (graph.nodes[bestId].position - prevPosition).Magnitude
						for _, entranceId in ipairs(poi.entranceNodeIds) do
							local entranceNode = graph.nodes[entranceId]
							if entranceNode then
								local dist = (entranceNode.position - prevPosition).Magnitude
								if dist < bestDist then
									bestDist = dist
									bestId = entranceId
								end
							end
						end
						chosenEntrances[i] = bestId
						prevPosition = graph.nodes[bestId].position
					else
						prevPosition = poi.waypointPosition
					end
				end
			end
		end

		local routeStartNodeId = if #selectedPOIs > 0 then selectedPOIs[#selectedPOIs].waypointNodeId else spawnId
		if chosenEntrances and #selectedPOIs > 0 and chosenEntrances[#selectedPOIs] then
			routeStartNodeId = chosenEntrances[#selectedPOIs]
		end
		local despawnId = if preferNearestDespawn
			then pickNearestDespawnNodeId(graph, routeStartNodeId)
			else RouteBuilder.pickRandomDespawn(graph)
		local nodeSequence = buildNodeSequence(spawnId, selectedPOIs, despawnId, chosenEntrances)
		local pathNodeIds, poiWaypointIndices = RouteBuilder.computeMultiSegmentRoute(graph, nodeSequence)

		while #selectedPOIs > 0 do
			local droppedPOI = nil
			local skipReason = ""

			if not pathNodeIds then
				droppedPOI = table.remove(selectedPOIs, #selectedPOIs)
				skipReason = "no_path"
				else
					local busyBacktrackPOIIndex = findBusyBacktrackPOIIndex(selectedPOIs, poiWaypointIndices, pathNodeIds)
					if busyBacktrackPOIIndex then
						droppedPOI = table.remove(selectedPOIs, busyBacktrackPOIIndex)
						skipReason = "busy_backtrack"
					else
						local unreachableSocialPOIIndex =
							findUnreachableSocialInternalPOIIndex(selectedPOIs, claimedSeatsByPoiId, chosenEntrances)
						if unreachableSocialPOIIndex then
							droppedPOI = table.remove(selectedPOIs, unreachableSocialPOIIndex)
							skipReason = "social_internal_unreachable"
						end
					end
				end

			if not droppedPOI then
				break
			end

			poiSkips += 1
			diagnostics(string.format("[WanderingProps] POI_SKIP %s poi=%s reason=%s", id, droppedPOI.id, skipReason))
				local droppedClaim = claimedSeatsByPoiId[droppedPOI.id]
				if droppedClaim then
					releaseSeatClaim(droppedPOI.id, droppedClaim.seatIndex, droppedClaim.npcId)
					claimedSeatsByPoiId[droppedPOI.id] = nil
				end
				local droppedMarket = marketStandsByPoiId[droppedPOI.id]
				if droppedMarket and droppedMarket.standIndices then
					for _, standIndex in ipairs(droppedMarket.standIndices) do
						releaseMarketStandClaim(droppedPOI.id, standIndex, id)
					end
					marketStandsByPoiId[droppedPOI.id] = nil
				end

			-- Recalculate chosen entrances after dropping a POI
			if chosenEntrances then
				chosenEntrances = {}
				local prevPos = graph.nodes[spawnId].position
				for i, poi in ipairs(selectedPOIs) do
					if poi.entranceNodeIds and #poi.entranceNodeIds > 1 then
						local bestId = poi.entranceNodeIds[1]
						local bestDist = (graph.nodes[bestId].position - prevPos).Magnitude
						for _, entranceId in ipairs(poi.entranceNodeIds) do
							local entranceNode = graph.nodes[entranceId]
							if entranceNode then
								local dist = (entranceNode.position - prevPos).Magnitude
								if dist < bestDist then
									bestDist = dist
									bestId = entranceId
								end
							end
						end
						chosenEntrances[i] = bestId
						prevPos = graph.nodes[bestId].position
					else
						prevPos = poi.waypointPosition
					end
				end
			end

			nodeSequence = buildNodeSequence(spawnId, selectedPOIs, despawnId, chosenEntrances)
			pathNodeIds, poiWaypointIndices = RouteBuilder.computeMultiSegmentRoute(graph, nodeSequence)
		end

		if not pathNodeIds then
			local despawnCandidates = table.clone(graph.despawns)
			if preferNearestDespawn then
				table.sort(despawnCandidates, function(a, b)
					local nodeA = graph.nodes[a]
					local nodeB = graph.nodes[b]
					local spawnPos = graph.nodes[spawnId].position
					local distA = if nodeA then (nodeA.position - spawnPos).Magnitude else math.huge
					local distB = if nodeB then (nodeB.position - spawnPos).Magnitude else math.huge
					return distA < distB
				end)
			end
			for _, candidateDespawnId in ipairs(despawnCandidates) do
				local fallbackPath = RouteBuilder.computeRoute(graph, spawnId, candidateDespawnId)
				if fallbackPath then
					pathNodeIds = fallbackPath
					poiWaypointIndices = {}
					break
				end
			end
		end

		if not pathNodeIds then
			routeFailures += 1
			routeStuckTotal += 1
			diagnostics(string.format("[WanderingProps] ROUTE_STUCK npc=%s spawn=%s", id, spawnId))
				for poiId, claim in pairs(claimedSeatsByPoiId) do
					releaseSeatClaim(poiId, claim.seatIndex, claim.npcId)
				end
				for poiId, marketData in pairs(marketStandsByPoiId) do
					for _, standIndex in ipairs(marketData.standIndices or {}) do
						releaseMarketStandClaim(poiId, standIndex, id)
					end
				end
				return false
			end

		local poiWaypointIndexSet = {}
		for _, idx in ipairs(poiWaypointIndices) do
			poiWaypointIndexSet[idx] = true
		end

		local zoneCount = 0
		for i, nodeId in ipairs(pathNodeIds) do
			local node = graph.nodes[nodeId]
			if node and node.zoneSize and not poiWaypointIndexSet[i] then
				zoneCount += 1
			end
		end
		if zoneCount > 0 then
			zoneRoutesTotal += 1
			diagnostics(string.format("[WanderingProps] ZONE_ROUTE %s zones=%d", id, zoneCount))
		end

		waypoints = convertNodeIdsToWaypoints(pathNodeIds, poiWaypointIndexSet)
		for i, poi in ipairs(selectedPOIs) do
			local scenicStandFlowActive = Config.InternalNavigationEnabled
				and poi.standPoints ~= nil
				and #poi.standPoints > 0
			local shouldRandomizeAreaStop = (poi.poiType == "busy")
				or (poi.poiType == "scenic" and not scenicStandFlowActive)
			if shouldRandomizeAreaStop and poi.waypointIsInsidePOI and poi.waypointSize then
				local waypointIndex = poiWaypointIndices[i]
				if waypointIndex and waypoints[waypointIndex] then
					waypoints[waypointIndex] = randomizePOIWaypointPosition(waypoints[waypointIndex], poi.waypointSize)
				end
			end
		end

		-- Pass 6: Internal navigation expansion
		if Config.InternalNavigationEnabled then
			-- Scenic/Social POIs: expand waypoints in forward order and keep POI indices aligned.
			for i, poi in ipairs(selectedPOIs) do
				if poi.poiType == "scenic" and poi.standPoints and #poi.standPoints > 0 then
					local waypointIndex = poiWaypointIndices[i]
					if waypointIndex and waypoints[waypointIndex] then
						local standPoint, standAccessNodeId = selectStandPointPosition(poi.standPoints)
						local chosenEntrance = if chosenEntrances then chosenEntrances[i] else nil
						local newWaypoints, newPoiIndex, insertedCount =
							expandScenicInternalWaypoints(
								waypoints,
								waypointIndex,
								poi,
								standPoint,
								standAccessNodeId,
								chosenEntrance
							)
						if insertedCount and insertedCount > 0 then
							waypoints = newWaypoints
							poiWaypointIndices[i] = newPoiIndex
							for j = i + 1, #poiWaypointIndices do
								poiWaypointIndices[j] += insertedCount
							end
							diagnostics(string.format(
								"[WanderingProps] SCENIC_STAND_EXPAND %s poi=%s inserted=%d newIndex=%d",
								id, poi.id, insertedCount, newPoiIndex
							))
						end
					end
					elseif poi.poiType == "social" then
						local claim = claimedSeatsByPoiId[poi.id]

						if poi.internalGraph and claim and claim.accessNodeId then
							local chosenEntrance = if chosenEntrances then chosenEntrances[i] else nil
						local newWaypoints, newPoiIndex, insertedCount =
							expandSocialInternalWaypoints(waypoints, poiWaypointIndices[i], poi, claim.accessNodeId, chosenEntrance)
						if insertedCount and insertedCount > 0 then
							waypoints = newWaypoints
							poiWaypointIndices[i] = newPoiIndex
							for j = i + 1, #poiWaypointIndices do
								poiWaypointIndices[j] += insertedCount
							end
							diagnostics(string.format(
								"[WanderingProps] INTERNAL_NAV_EXPAND %s poi=%s inserted=%d newIndex=%d",
								id, poi.id, insertedCount, newPoiIndex
								))
							end
						end
					elseif poi.poiType == "market" then
						local marketData = marketStandsByPoiId[poi.id]
						if poi.internalGraph and marketData and marketData.standIndices and #marketData.standIndices > 0 then
							local chosenEntrance = if chosenEntrances then chosenEntrances[i] else nil
							local newWaypoints, standWaypointIndices, insertedCount = expandMarketInternalWaypoints(
								waypoints,
								poiWaypointIndices[i],
								poi,
								marketData.standIndices,
								chosenEntrance
							)
							if insertedCount and insertedCount > 0 and standWaypointIndices and #standWaypointIndices > 0 then
								waypoints = newWaypoints
								marketData.standWaypointIndices = standWaypointIndices
								-- Keep representative index for this POI aligned to first stand stop.
								poiWaypointIndices[i] = standWaypointIndices[1]
								for j = i + 1, #poiWaypointIndices do
									poiWaypointIndices[j] += insertedCount
								end
								diagnostics(string.format(
									"[WanderingProps] MARKET_EXPAND %s poi=%s stands=%d inserted=%d",
									id,
									poi.id,
									#standWaypointIndices,
									insertedCount
								))
							end
						end
					end
				end
			end

		totalDistance = routeDistance(waypoints)

			local builtPoiStops = {}
			local builtSeatClaims = {}
			local builtSeatClaimStopIndices = {}
			local builtMarketStandClaims = {}
			local builtMarketClaimStopIndices = {}

				for i, poi in ipairs(selectedPOIs) do
					if poi.poiType == "market" then
						local marketData = marketStandsByPoiId[poi.id]
						local standIndices = if marketData and marketData.standIndices then marketData.standIndices else {}
						local standWaypointIndices = if marketData and marketData.standWaypointIndices then marketData.standWaypointIndices else {}
						local usedStandIndices = {}

						for standOrder, standIndex in ipairs(standIndices) do
							local stand = poi.stands and poi.stands[standIndex]
							local standWaypointIndex = standWaypointIndices[standOrder]
							if stand and standWaypointIndex then
							local dwellTime = rng:NextNumber(Config.MarketBrowseDwellMin, Config.MarketBrowseDwellMax)
							local scanExtent = math.max(0, (stand.viewTargetSize and stand.viewTargetSize.X or 0) / 2)
							table.insert(builtPoiStops, {
								type = "market",
								waypointIndex = standWaypointIndex,
								dwellTime = dwellTime,
								viewTarget = stand.viewTargetPosition,
								seatCFrame = nil,
								scanTarget = stand.viewTargetPosition,
								scanExtent = scanExtent,
							})
								table.insert(builtMarketStandClaims, {
									poiId = poi.id,
									standIndex = standIndex,
									npcId = id,
									releaseTime = 0,
								})
								builtMarketClaimStopIndices[#builtMarketStandClaims] = #builtPoiStops
								usedStandIndices[standIndex] = true
							end
						end

						for _, standIndex in ipairs(standIndices) do
							if not usedStandIndices[standIndex] then
								releaseMarketStandClaim(poi.id, standIndex, id)
							end
						end
					else
					local dwellTime = 0
					if poi.poiType ~= "busy" then
						local dwellMin = poi.dwellMin or 0
						local dwellMax = poi.dwellMax or dwellMin
						dwellTime = rng:NextNumber(dwellMin, dwellMax)
					end

					local claim = claimedSeatsByPoiId[poi.id]
					table.insert(builtPoiStops, {
						type = poi.poiType,
						waypointIndex = poiWaypointIndices[i],
						dwellTime = dwellTime,
						viewTarget = if poi.poiType == "scenic" then poi.viewTarget else nil,
						seatCFrame = if poi.poiType == "social" and claim then claim.seatCFrame else nil,
						scanTarget = nil,
						scanExtent = nil,
					})

					if poi.poiType == "social" and claim and builtPoiStops[#builtPoiStops].seatCFrame then
						table.insert(builtSeatClaims, {
							poiId = poi.id,
							seatIndex = claim.seatIndex,
							releaseTime = 0,
							npcId = id,
						})
						builtSeatClaimStopIndices[#builtSeatClaims] = #builtPoiStops
					end
				end
			end

			if #builtPoiStops > 0 then
				poiStops = builtPoiStops
				poiRoutesTotal += 1
				local poiTypes = {}
				for _, poiStop in ipairs(poiStops) do
					table.insert(poiTypes, poiStop.type)
				end
				diagnostics(string.format(
					"[WanderingProps] POI_ROUTE %s pois=%d types=%s",
					id,
					#poiStops,
					table.concat(poiTypes, ",")
				))
			end
			if #builtSeatClaims > 0 then
				seatClaims = builtSeatClaims
			end
			if #builtMarketStandClaims > 0 then
				marketStandClaims = builtMarketStandClaims
			end

			if bevelRuntimeEnabled and #waypoints > 2 then
				local rawLegs = #waypoints - 1
				waypoints, poiStops = PathSmoother.bevel(
					waypoints,
					poiStops,
					bevelRuntimeRadius,
					bevelRuntimeSegments
				)
				totalDistance = routeDistance(waypoints)
				diagnostics(string.format(
					"[WanderingProps] BEVEL_PATH %s raw_legs=%d smoothed_legs=%d",
					id,
					rawLegs,
					math.max(0, #waypoints - 1)
				))
			end

			if poiStops then
				local function computeClaimReleaseTime(targetPOIIndex: number): number
					local arrivalTime = 0
					local lastResumeIdx = 1

					for p = 1, targetPOIIndex do
						local poiStop = poiStops[p]
						local walkDist = 0
						for w = lastResumeIdx, poiStop.waypointIndex - 1 do
							walkDist += (waypoints[w + 1] - waypoints[w]).Magnitude
						end
						if walkSpeed > 0 then
							arrivalTime += walkDist / walkSpeed
						end
						if p < targetPOIIndex then
							arrivalTime += poiStop.dwellTime
						end
						lastResumeIdx = poiStop.waypointIndex
					end

					return arrivalTime + poiStops[targetPOIIndex].dwellTime
				end

				if seatClaims then
					for claimIndex, claim in ipairs(seatClaims) do
						local targetPOIIndex = builtSeatClaimStopIndices[claimIndex]
						if targetPOIIndex then
							claim.releaseTime = computeClaimReleaseTime(targetPOIIndex)
							local targetPoiStop = poiStops[targetPOIIndex]
							if walkSpeed > 0 and targetPoiStop and targetPoiStop.seatCFrame then
								local waypointPos = waypoints[targetPoiStop.waypointIndex]
								if waypointPos then
									local seatTravelDistance = (targetPoiStop.seatCFrame.Position - waypointPos).Magnitude
									claim.releaseTime += (seatTravelDistance * 2) / walkSpeed
								end
							end
						end
					end
				end

				if marketStandClaims then
					for claimIndex, claim in ipairs(marketStandClaims) do
						local targetPOIIndex = builtMarketClaimStopIndices[claimIndex]
						if targetPOIIndex then
							claim.releaseTime = computeClaimReleaseTime(targetPOIIndex)
						end
					end
				end
			end
			else
			local nodeIds = buildRouteNodeIds(graph, preferNearestDespawn)
			if not nodeIds then
				routeFailures += 1
				diagnostics(string.format("[WanderingProps] SPAWN_FAIL no valid route failures=%d", routeFailures))
				return false
			end

		local zoneCount = 0
		for _, nodeId in ipairs(nodeIds) do
			local node = graph.nodes[nodeId]
			if node and node.zoneSize then
				zoneCount += 1
			end
		end
		if zoneCount > 0 then
			zoneRoutesTotal += 1
			diagnostics(string.format("[WanderingProps] ZONE_ROUTE %s zones=%d", id, zoneCount))
		end

			waypoints = convertNodeIdsToWaypoints(nodeIds, nil)
			totalDistance = routeDistance(waypoints)
			if bevelRuntimeEnabled and #waypoints > 2 then
				local rawLegs = #waypoints - 1
				waypoints = PathSmoother.bevel(waypoints, nil, bevelRuntimeRadius, bevelRuntimeSegments)
				totalDistance = routeDistance(waypoints)
				diagnostics(string.format(
					"[WanderingProps] BEVEL_PATH %s raw_legs=%d smoothed_legs=%d",
					id,
					rawLegs,
					math.max(0, #waypoints - 1)
				))
			end
		end

	local startTime = Workspace:GetServerTimeNow()
	local totalDwellTime = 0
	for _, poi in ipairs(poiStops or {}) do
		totalDwellTime += poi.dwellTime
	end

	local totalDuration = totalDwellTime
	if walkSpeed > 0 then
		totalDuration += totalDistance / walkSpeed
	end

		local record = {
			id = id,
			modelName = model.Name,
			modelTemplate = model,
		baseWalkSpeed = baseWalkSpeed,
		walkSpeed = walkSpeed,
		waypoints = waypoints,
		startTime = startTime,
			totalDuration = totalDuration,
			poiStops = poiStops,
			seatClaims = seatClaims,
			marketStandClaims = marketStandClaims,
			nightDrainApplied = false,
			routeVersion = routeVersion,
		}

	activeNPCs[id] = record
	activeCount += 1
	npcsSpawnedTotal += 1

		if record.seatClaims then
			local scheduledRouteVersion = record.routeVersion or 1
			for _, claim in ipairs(record.seatClaims) do
			task.delay(claim.releaseTime, function()
				local current = activeNPCs[record.id]
				if not current or current.routeVersion ~= scheduledRouteVersion then
					return
				end
				releaseSeatClaim(claim.poiId, claim.seatIndex, claim.npcId)
				end)
			end
		end
		if record.marketStandClaims then
			local scheduledRouteVersion = record.routeVersion or 1
			for _, claim in ipairs(record.marketStandClaims) do
				task.delay(claim.releaseTime, function()
					local current = activeNPCs[record.id]
					if not current or current.routeVersion ~= scheduledRouteVersion then
						return
					end
					releaseMarketStandClaim(claim.poiId, claim.standIndex, claim.npcId)
				end)
			end
		end

	queueSpawnBroadcast(makeSpawnData(record))
	scheduleNPCDespawn(record, totalDuration)

	diagnostics(string.format(
		"[WanderingProps] SPAWN %s model=%s speed=%.1f legs=%d duration=%.1fs active=%d/%d total=%d",
		id,
		record.modelName,
		record.walkSpeed,
		math.max(0, #record.waypoints - 1),
		record.totalDuration,
		activeCount,
		Config.MaxPopulation,
		npcsSpawnedTotal
	))
	return true
end

local function rebroadcastAllSpeeds(multiplier: number)
	local appliedMultiplier = math.max(0.1, multiplier or 1.0)
	PopulationHooks.walkSpeedMultiplier = appliedMultiplier

	local affected = 0
	for _, record in pairs(activeNPCs) do
		local base = math.max(0.1, record.baseWalkSpeed or record.walkSpeed or Config.BaseWalkSpeed)
		record.baseWalkSpeed = base
		record.walkSpeed = base * appliedMultiplier
		queueSpawnBroadcast(makeSpawnData(record))
		affected += 1
	end

	print(string.format("[P8_TEST] SPEED_MULTIPLIER value=%.2f affected=%d", appliedMultiplier, affected))
	diagnostics(string.format("[WanderingProps] SPEED_MULTIPLIER value=%.2f", appliedMultiplier))
end

local function rerouteAllToNearestDespawn()
	local now = Workspace:GetServerTimeNow()
	local rerouted = 0
	for _, record in pairs(activeNPCs) do
		if rerouteRecordToNearestDespawn(record, now, "MODE") then
			rerouted += 1
		end
	end

	print(string.format("[P8_TEST] REROUTE_ALL count=%d", rerouted))
	diagnostics(string.format("[WanderingProps] REROUTE_ALL count=%d", rerouted))
end

local function sendBulkSyncToPlayer(player: Player): number
	if not player then
		return 0
	end
	if PopulationHooks.desyncedPlayers[player] then
		return 0
	end

	local bulk = {}
	for _, record in pairs(activeNPCs) do
		table.insert(bulk, makeSpawnData(record))
	end
	npcBulkSyncRemote:FireClient(player, bulk)
	return #bulk
end

local function processSpawnDespawnQueues()
	local despawnBudget = math.max(1, math.floor(Config.DespawnOpsPerHeartbeat or 8))
	local spawnBudget = math.max(1, math.floor(Config.SpawnOpsPerHeartbeat or 4))
	local spawnBuildBudgetMs = math.max(0, tonumber(Config.SpawnBuildTimeBudgetMs) or 0)
	local spawnBuildDeadline = if spawnBuildBudgetMs > 0
		then (os.clock() + (spawnBuildBudgetMs / 1000))
		else math.huge

	local despawnProcessed = 0
	while despawnProcessed < despawnBudget and queuedDespawnHead <= #queuedDespawnIds do
		local id = queuedDespawnIds[queuedDespawnHead]
		queuedDespawnIds[queuedDespawnHead] = nil
		queuedDespawnHead += 1
		queuedDespawnSet[id] = nil
		despawnNPC(id)
		despawnProcessed += 1
	end
	if queuedDespawnHead > #queuedDespawnIds then
		queuedDespawnIds = {}
		queuedDespawnHead = 1
	end

	local spawnProcessed = 0
	while spawnProcessed < spawnBudget and os.clock() <= spawnBuildDeadline do
		if PopulationHooks.spawnPaused then
			break
		end
		if activeCount >= getEffectiveMaxPopulation() then
			break
		end

		local now = Workspace:GetServerTimeNow()
		local didWork = false

		if queuedRecycleHead <= #queuedRecycleRequests then
			local recycleRequest = queuedRecycleRequests[queuedRecycleHead]
			if recycleRequest and now >= (recycleRequest.readyAt or 0) then
				queuedRecycleRequests[queuedRecycleHead] = nil
				queuedRecycleHead += 1
				didWork = true
				spawnProcessed += 1

				local recycled = spawnNPC({
					reuseId = recycleRequest.reuseId,
					model = recycleRequest.model,
					baseWalkSpeed = recycleRequest.baseWalkSpeed or recycleRequest.walkSpeed,
					routeVersion = recycleRequest.routeVersion,
				})
				if recycled then
					diagnostics(string.format(
						"[WanderingProps] RECYCLE_SPAWN %s active=%d/%d pending_recycle=%d",
						recycleRequest.reuseId,
						activeCount,
						Config.MaxPopulation,
						getQueuedRecycleCount()
					))
				else
					queueRecycleRequest(recycleRequest, Config.RecycleRetryDelayMin, Config.RecycleRetryDelayMax)
					diagnostics(string.format(
						"[WanderingProps] RECYCLE_RETRY %s pending_recycle=%d",
						recycleRequest.reuseId,
						getQueuedRecycleCount()
					))
				end
			end
		end

		if not didWork then
			-- While recycle requests are pending (even if delayed), reserve slots and pause fresh spawns.
			if getQueuedRecycleCount() > 0 then
				break
			end
			if queuedSpawnRequests <= 0 then
				break
			end

			spawnNPC()
			queuedSpawnRequests -= 1
			spawnProcessed += 1
		end
	end

	if queuedRecycleHead > #queuedRecycleRequests then
		queuedRecycleRequests = {}
		queuedRecycleHead = 1
	end
end

local function onPlayerAdded(player: Player)
	if PopulationHooks.desyncedPlayers[player] then
		return
	end

	local sent = sendBulkSyncToPlayer(player)
	diagnostics(string.format("[WanderingProps] BULK_SYNC player=%s npcs_sent=%d", player.Name, sent))
end

local function startup()
	validateConfig()

	wanderingFolder = Workspace:FindFirstChild("WanderingProps")
	if not wanderingFolder then
		fatal("[WanderingProps] FATAL: Workspace.WanderingProps folder not found. Create it in Studio.")
	end

	local modelsFolder = ReplicatedStorage:FindFirstChild("WanderingPropModels")
	if not modelsFolder or not modelsFolder:IsA("Folder") then
		fatal("[WanderingProps] FATAL: ReplicatedStorage.WanderingPropModels folder not found.")
	end

	collectValidModels(modelsFolder)

	if bevelRuntimeEnabled then
		if Config.BevelRadius <= 0 then
			warn("[WanderingProps] WARNING: BevelRadius must be > 0. Beveling disabled.")
			bevelRuntimeEnabled = false
		end
		if Config.BevelSegments < 2 then
			warn("[WanderingProps] WARNING: BevelSegments must be >= 2. Using 2.")
			bevelRuntimeSegments = 2
		else
			bevelRuntimeSegments = math.max(2, math.floor(Config.BevelSegments))
		end
	end

	local waypointsFolder = wanderingFolder:FindFirstChild("Waypoints")
	if not waypointsFolder or not waypointsFolder:IsA("Folder") then
		fatal("[WanderingProps] FATAL: Workspace.WanderingProps.Waypoints folder not found.")
	end

	local builtGraph, buildError = WaypointGraph.build(waypointsFolder)
	if not builtGraph then
		fatal(buildError or "[WanderingProps] FATAL: Failed to build waypoint graph.")
	end

	graph = builtGraph

	local ok, validateError = WaypointGraph.validate(graph)
	if not ok then
		fatal(validateError or "[WanderingProps] FATAL: Failed to validate waypoint graph.")
	end

	local poisFolderForZoneValidation = wanderingFolder:FindFirstChild("POIs")
	for part, nodeId in pairs(graph.partToId) do
		local node = graph.nodes[nodeId]
		if node then
			if part:GetAttribute("Zone") == true and node.nodeType ~= "waypoint" then
				warn(string.format(
					'[WanderingProps] WARNING: Zone attribute on %s node "%s" ignored. Only waypoint nodes can be zones.',
					node.nodeType,
					node.id
				))
				node.zoneSize = nil
			end
			if poisFolderForZoneValidation and part:IsDescendantOf(poisFolderForZoneValidation) then
				node.zoneSize = nil
			end
			if node.zoneSize and (node.zoneSize.X <= 0 or node.zoneSize.Z <= 0) then
				warn(string.format(
					'[WanderingProps] WARNING: Zone node "%s" has zero or negative Size (%.1f x %.1f). Treating as spot.',
					node.id,
					node.zoneSize.X,
					node.zoneSize.Z
				))
				node.zoneSize = nil
			end
		end
	end

	hideWaypointParts(graph)

	local poisFolder = wanderingFolder:FindFirstChild("POIs")
	if poisFolder and poisFolder:IsA("Folder") then
		poiRegistry = POIRegistry.discover(poisFolder, graph)

		if poiRegistry then
				local scenicCount = 0
				local busyCount = 0
				local socialCount = 0
				local marketCount = 0
				local totalSeats = 0
				local totalMarketStands = 0
				local hasSocial = false
				local internalGraphCount = 0
				local standPointPOICount = 0

			for _, poi in ipairs(poiRegistry.pois) do
				if poi.poiType == "scenic" then
					scenicCount += 1
					if poi.standPoints then
						standPointPOICount += 1
					end
				elseif poi.poiType == "busy" then
					busyCount += 1
					elseif poi.poiType == "social" then
						socialCount += 1
						hasSocial = true
						totalSeats += poi.totalSeats or 0
						if poi.internalGraph then
							internalGraphCount += 1
						end
					elseif poi.poiType == "market" then
						marketCount += 1
						totalMarketStands += poi.totalStands or (poi.stands and #poi.stands or 0)
						if poi.internalGraph then
							internalGraphCount += 1
						end
					end
				end

				diagnostics(string.format(
					"[WanderingProps] POI_REGISTRY_BUILT scenic=%d busy=%d social=%d market=%d seats=%d marketStands=%d internalGraphs=%d standPointPOIs=%d",
					scenicCount,
					busyCount,
					socialCount,
					marketCount,
					totalSeats,
					totalMarketStands,
					internalGraphCount,
					standPointPOICount
				))

			if hasSocial and (Config.SitAnimationId == nil or Config.SitAnimationId == "") then
				error("[WanderingProps] FATAL: Social POIs found but SitAnimationId not set in Config.")
			end
			if Config.POICountMin > Config.POICountMax then
				error("[WanderingProps] FATAL: POICountMin must be ≤ POICountMax.")
			end
		end
	else
		warn("[WanderingProps] WARNING: No POIs folder found. NPCs will walk random routes.")
	end

	setupRemotes()
	nextEventFlushAt = Workspace:GetServerTimeNow()
	PopulationHooks.rerouteAllToNearestDespawn = rerouteAllToNearestDespawn
	PopulationHooks.rebroadcastAllSpeeds = rebroadcastAllSpeeds
	PopulationHooks.sendBulkSyncToPlayer = sendBulkSyncToPlayer

	local edgeCount = 0
	local nodeCount = 0
	for _, node in pairs(graph.nodes) do
		nodeCount += 1
		edgeCount += #node.connections
	end
	diagnostics(string.format(
		"[WanderingProps] GRAPH_BUILT nodes=%d spawns=%d despawns=%d edges=%d",
		nodeCount,
		#graph.spawns,
		#graph.despawns,
		math.floor(edgeCount / 2)
	))

	Players.PlayerAdded:Connect(onPlayerAdded)
	RunService.Heartbeat:Connect(function()
		processSpawnDespawnQueues()
		flushQueuedRemoteEvents(false)
	end)

	if Config.InitialSpawnBurst then
		local initialCount = math.max(0, math.floor(getEffectiveMaxPopulation()))
		if initialCount > 0 then
			requestSpawn(initialCount)
		end
	end

	local nextNightDrainAt = 0
	while true do
		task.wait(math.max(0, Config.SpawnInterval or 0))
			local now = Workspace:GetServerTimeNow()
			if Config.NightDrainEnabled and now >= nextNightDrainAt then
				applyNightDrain(now)
				nextNightDrainAt = now + math.max(0.1, Config.NightDrainCheckInterval)
			end
		local effectiveMax = getEffectiveMaxPopulation()
		local pendingTotal = activeCount + queuedSpawnRequests + getQueuedRecycleCount()
		if not PopulationHooks.spawnPaused and pendingTotal < effectiveMax then
			requestSpawn(1)
		end
	end
end

startup()
