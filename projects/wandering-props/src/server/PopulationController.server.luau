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
local POIRegistry = require(script.Parent:WaitForChild("POIRegistry"))

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

local graph
local poiRegistry = nil
local wanderingFolder
local lastIsNightState: boolean? = nil

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

local function randomizeScenicPOIWaypointPosition(basePosition: Vector3, waypointSize: Vector3?): Vector3
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

local function releaseSeatClaim(poiId: string, seatIndex: number)
	if not poiRegistry then
		return
	end

	local poi = POIRegistry.getPOI(poiRegistry, poiId)
	if not poi then
		return
	end

	local wasOccupied = false
	if poi.seats and poi.seats[seatIndex] and poi.seats[seatIndex].occupiedBy ~= nil then
		wasOccupied = true
	end

	POIRegistry.releaseSeat(poi, seatIndex)

	if wasOccupied then
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
end

local function despawnNPC(id: string)
	local record = activeNPCs[id]
	if not record then
		return
	end

	if record.seatClaims then
		for _, claim in ipairs(record.seatClaims) do
			releaseSeatClaim(claim.poiId, claim.seatIndex)
		end
	end

	activeNPCs[id] = nil
	activeCount -= 1
	npcsDespawnedTotal += 1

	npcDespawnedRemote:FireAllClients(id)
	diagnostics(string.format(
		"[WanderingProps] DESPAWN %s active=%d/%d total_despawned=%d",
		id,
		activeCount,
		Config.MaxPopulation,
		npcsDespawnedTotal
	))
end

local function buildNodeSequence(spawnId: string, selectedPOIs, despawnId: string)
	local nodeSequence = { spawnId }
	for _, poi in ipairs(selectedPOIs) do
		table.insert(nodeSequence, poi.waypointNodeId)
	end
	table.insert(nodeSequence, despawnId)
	return nodeSequence
end

local function convertNodeIdsToWaypoints(pathNodeIds: { string }, poiWaypointIndexSet: { [number]: boolean }?)
	local waypoints = {}
	local indexSet = poiWaypointIndexSet or {}
	for i, nodeId in ipairs(pathNodeIds) do
		local node = graph.nodes[nodeId]
		if node.zoneSize and not indexSet[i] then
			table.insert(waypoints, randomizeZonePosition(node))
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
			despawnNPC(record.id)
		end
	end)
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

	if record.seatClaims then
		for _, claim in ipairs(record.seatClaims) do
			releaseSeatClaim(claim.poiId, claim.seatIndex)
		end
	end
	record.seatClaims = nil
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
	npcSpawnedRemote:FireAllClients(makeSpawnData(record))
	diagnostics(string.format(
		"[WanderingProps] NIGHT_DRAIN_ROUTE %s nextPoi=%s legs=%d",
		record.id,
		tostring(newPoiStops ~= nil),
		math.max(0, #newWaypoints - 1)
	))

	return true
end

local function applyNightDrain()
	if not Config.NightDrainEnabled or not isNightNow() then
		return
	end

	local effectiveMax = getEffectiveMaxPopulation()
	local excess = activeCount - effectiveMax
	if excess <= 0 then
		return
	end

	local now = Workspace:GetServerTimeNow()
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

local function spawnNPC()
	local effectiveMax = getEffectiveMaxPopulation()
	if activeCount >= effectiveMax then
		return
	end
	local currentlyNight = isNightNow()
	local preferNearestDespawn = currentlyNight and Config.NightPreferNearestDespawn == true

	local model = pickRandomModel()
	local walkVariation = math.abs(Config.WalkSpeedVariation or 0)
	local sampledWalkSpeed = Config.BaseWalkSpeed + rng:NextNumber(-walkVariation, walkVariation)
	local walkSpeed = math.max(0.1, sampledWalkSpeed)
	local id = "npc_" .. tostring(nextNpcId)
	nextNpcId += 1

	local waypoints = nil
	local totalDistance = 0
	local poiStops = nil
	local seatClaims = nil

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

		local filteredPOIs = {}
		for _, poi in ipairs(selectedPOIs) do
			if poi.poiType == "social" then
				local seatIndex, seatCFrame = POIRegistry.claimSeat(poi, id)
				if seatIndex and seatCFrame then
					claimedSeatsByPoiId[poi.id] = {
						seatIndex = seatIndex,
						seatCFrame = seatCFrame,
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
			else
				table.insert(filteredPOIs, poi)
			end
		end
		selectedPOIs = filteredPOIs

		local routeStartNodeId = if #selectedPOIs > 0 then selectedPOIs[#selectedPOIs].waypointNodeId else spawnId
		local despawnId = if preferNearestDespawn
			then pickNearestDespawnNodeId(graph, routeStartNodeId)
			else RouteBuilder.pickRandomDespawn(graph)
		local nodeSequence = buildNodeSequence(spawnId, selectedPOIs, despawnId)
		local pathNodeIds, poiWaypointIndices = RouteBuilder.computeMultiSegmentRoute(graph, nodeSequence)

		while not pathNodeIds and #selectedPOIs > 0 do
			local droppedPOI = table.remove(selectedPOIs, #selectedPOIs)
			poiSkips += 1
			diagnostics(string.format("[WanderingProps] POI_SKIP %s poi=%s reason=no_path", id, droppedPOI.id))
			local droppedClaim = claimedSeatsByPoiId[droppedPOI.id]
			if droppedClaim then
				releaseSeatClaim(droppedPOI.id, droppedClaim.seatIndex)
				claimedSeatsByPoiId[droppedPOI.id] = nil
			end

			nodeSequence = buildNodeSequence(spawnId, selectedPOIs, despawnId)
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
				releaseSeatClaim(poiId, claim.seatIndex)
			end
			return
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
			if poi.poiType == "scenic" and poi.waypointIsInsidePOI and poi.waypointSize then
				local waypointIndex = poiWaypointIndices[i]
				if waypointIndex and waypoints[waypointIndex] then
					waypoints[waypointIndex] = randomizeScenicPOIWaypointPosition(waypoints[waypointIndex], poi.waypointSize)
				end
			end
		end
		totalDistance = routeDistance(waypoints)

		local builtPoiStops = {}
		local builtSeatClaims = {}
		local claimPoiStopIndices = {}
		for i, poi in ipairs(selectedPOIs) do
			local dwellTime = 0
			if poi.poiType ~= "busy" then
				local dwellMin = poi.dwellMin or 0
				local dwellMax = poi.dwellMax or dwellMin
				dwellTime = rng:NextNumber(dwellMin, dwellMax)
			end

			local claim = claimedSeatsByPoiId[poi.id]
			builtPoiStops[i] = {
				type = poi.poiType,
				waypointIndex = poiWaypointIndices[i],
				dwellTime = dwellTime,
				viewTarget = if poi.poiType == "scenic" then poi.viewTarget else nil,
				seatCFrame = if poi.poiType == "social" and claim then claim.seatCFrame else nil,
			}

			if poi.poiType == "social" and claim and builtPoiStops[i].seatCFrame then
				table.insert(builtSeatClaims, {
					poiId = poi.id,
					seatIndex = claim.seatIndex,
					releaseTime = 0,
				})
				claimPoiStopIndices[#builtSeatClaims] = i
			end
		end

		if #builtPoiStops > 0 then
			poiStops = builtPoiStops
			poiRoutesTotal += 1
			local poiTypes = {}
			for _, poi in ipairs(poiStops) do
				table.insert(poiTypes, poi.type)
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

		if seatClaims and poiStops then
			for claimIndex, claim in ipairs(seatClaims) do
				local targetPOIIndex = claimPoiStopIndices[claimIndex]
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

				claim.releaseTime = arrivalTime + poiStops[targetPOIIndex].dwellTime
			end
		end
	else
		local nodeIds = buildRouteNodeIds(graph, preferNearestDespawn)
		if not nodeIds then
			routeFailures += 1
			diagnostics(string.format("[WanderingProps] SPAWN_FAIL no valid route failures=%d", routeFailures))
			return
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
		walkSpeed = walkSpeed,
		waypoints = waypoints,
		startTime = startTime,
		totalDuration = totalDuration,
		poiStops = poiStops,
		seatClaims = seatClaims,
		nightDrainApplied = false,
	}

	activeNPCs[id] = record
	activeCount += 1
	npcsSpawnedTotal += 1

	if record.seatClaims then
		for _, claim in ipairs(record.seatClaims) do
			task.delay(claim.releaseTime, function()
				releaseSeatClaim(claim.poiId, claim.seatIndex)
			end)
		end
	end

	npcSpawnedRemote:FireAllClients(makeSpawnData(record))
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
end

local function onPlayerAdded(player: Player)
	local bulk = {}
	for _, record in pairs(activeNPCs) do
		table.insert(bulk, makeSpawnData(record))
	end

	npcBulkSyncRemote:FireClient(player, bulk)
	diagnostics(string.format("[WanderingProps] BULK_SYNC player=%s npcs_sent=%d", player.Name, #bulk))
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
			local totalSeats = 0
			local hasSocial = false

			for _, poi in ipairs(poiRegistry.pois) do
				if poi.poiType == "scenic" then
					scenicCount += 1
				elseif poi.poiType == "busy" then
					busyCount += 1
				elseif poi.poiType == "social" then
					socialCount += 1
					hasSocial = true
					totalSeats += poi.totalSeats or 0
				end
			end

			diagnostics(string.format(
				"[WanderingProps] POI_REGISTRY_BUILT scenic=%d busy=%d social=%d seats=%d",
				scenicCount,
				busyCount,
				socialCount,
				totalSeats
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

	if Config.InitialSpawnBurst then
		for _ = 1, getEffectiveMaxPopulation() do
			spawnNPC()
			RunService.Heartbeat:Wait()
		end
	end

	local nextNightDrainAt = 0
	while true do
		task.wait(Config.SpawnInterval)
		local now = Workspace:GetServerTimeNow()
		if Config.NightDrainEnabled and now >= nextNightDrainAt then
			applyNightDrain()
			nextNightDrainAt = now + math.max(0.1, Config.NightDrainCheckInterval)
		end
		if activeCount < getEffectiveMaxPopulation() then
			spawnNPC()
		end
	end
end

startup()
