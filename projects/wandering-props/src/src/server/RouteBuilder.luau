--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local configModule = ReplicatedStorage:WaitForChild("Config", 10)
assert(configModule and configModule:IsA("ModuleScript"), "WanderingProps RouteBuilder: ReplicatedStorage.Config not found")

local typesModule = ReplicatedStorage:WaitForChild("Types", 10)
assert(typesModule and typesModule:IsA("ModuleScript"), "WanderingProps RouteBuilder: ReplicatedStorage.Types not found")

local nodeGraphModule = script.Parent:WaitForChild("NodeGraph", 10)
assert(nodeGraphModule and nodeGraphModule:IsA("ModuleScript"), "WanderingProps RouteBuilder: NodeGraph module not found")

local seatManagerModule = script.Parent:WaitForChild("SeatManager", 10)
assert(seatManagerModule and seatManagerModule:IsA("ModuleScript"), "WanderingProps RouteBuilder: SeatManager module not found")

local Config = require(configModule)
local _Types = require(typesModule)
local NodeGraph = require(nodeGraphModule)
local SeatManager = require(seatManagerModule)

type GraphNode = {
	part: Part,
	tag: string,
	position: Vector3,
	isZone: boolean,
	size: Vector3?,
	connections: { GraphNode },
	weight: number?,
	viewTargets: { Part }?,
	seats: { Part }?,
	capacityCap: number?,
}

type RouteStep = {
	position: Vector3,
	action: "walk" | "idle" | "sit" | "despawn",
	duration: number?,
	faceCFrame: CFrame?,
	sitCFrame: CFrame?,
}

local RouteBuilder = {}

local EPSILON = 0.0001

local function debugLog(message: string): ()
	if Config.DEBUG_ENABLED then
		warn(("[WanderingProps/RouteBuilder] %s"):format(message))
	end
end

local function randomFloat(minValue: number, maxValue: number): number
	if maxValue < minValue then
		minValue, maxValue = maxValue, minValue
	end
	if math.abs(maxValue - minValue) < EPSILON then
		return minValue
	end
	return minValue + math.random() * (maxValue - minValue)
end

local function randomPointInPart(part: Part): Vector3
	local halfSize = part.Size * 0.5
	local randomOffset = Vector3.new(
		(math.random() * 2 - 1) * halfSize.X,
		(math.random() * 2 - 1) * halfSize.Y,
		(math.random() * 2 - 1) * halfSize.Z
	)
	return (part.CFrame * CFrame.new(randomOffset)).Position
end

local function resolveScenicLookPosition(poiNode: GraphNode): Vector3?
	local targets = poiNode.viewTargets
	if not targets or #targets == 0 then
		return nil
	end

	local targetPart = targets[math.random(1, #targets)]
	return randomPointInPart(targetPart)
end

local function randomInt(minValue: number, maxValue: number): number
	if maxValue < minValue then
		minValue, maxValue = maxValue, minValue
	end
	if minValue == maxValue then
		return minValue
	end
	return math.random(minValue, maxValue)
end

local function copyNodes(nodes: { GraphNode }): { GraphNode }
	local copy: { GraphNode } = table.create(#nodes)
	for i, node in ipairs(nodes) do
		copy[i] = node
	end
	return copy
end

local function shuffleNodes(nodes: { GraphNode }): ()
	for i = #nodes, 2, -1 do
		local j = math.random(1, i)
		nodes[i], nodes[j] = nodes[j], nodes[i]
	end
end

local function appendPathNodesUnique(destination: { GraphNode }, source: { GraphNode }, startIndex: number): ()
	for i = startIndex, #source do
		local node = source[i]
		local last = destination[#destination]
		if not last or last.part ~= node.part then
			table.insert(destination, node)
		end
	end
end

local function collapseImmediateBacktracks(path: { GraphNode }): { GraphNode }
	if #path <= 2 then
		return path
	end

	local collapsed: { GraphNode } = {}
	for _, node in ipairs(path) do
		local count = #collapsed
		if count >= 2 and collapsed[count - 1].part == node.part then
			table.remove(collapsed, count)
			continue
		end

		local last = collapsed[count]
		if not last or last.part ~= node.part then
			table.insert(collapsed, node)
		end
	end

	return collapsed
end

local function injectWander(path: { GraphNode }): { GraphNode }
	if #path <= 1 then
		return path
	end

	if Config.WANDER_CHANCE <= 0 or Config.WANDER_MAX_HOPS <= 0 then
		return path
	end

	local expanded: { GraphNode } = { path[1] }

	for index = 1, #path - 1 do
		local fromNode = path[index]
		local toNode = path[index + 1]
		local insertedDeviation = false

		if math.random() < Config.WANDER_CHANCE then
			local candidates = NodeGraph.getNearbyNodes(fromNode.part, Config.WANDER_MAX_HOPS)
			for attempt = 1, math.min(2, #candidates) do
				local candidateIndex = math.random(1, #candidates)
				local candidate = table.remove(candidates, candidateIndex)

				if candidate.part ~= fromNode.part and candidate.part ~= toNode.part then
					local pathToCandidate = NodeGraph.getPath(fromNode.part, candidate.part)
					local pathBackToMain = NodeGraph.getPath(candidate.part, toNode.part)
					if pathToCandidate and pathBackToMain then
						appendPathNodesUnique(expanded, pathToCandidate, 2)
						appendPathNodesUnique(expanded, pathBackToMain, 2)
						insertedDeviation = true
						break
					end
				end
			end
		end

		if not insertedDeviation then
			local last = expanded[#expanded]
			if not last or last.part ~= toNode.part then
				table.insert(expanded, toNode)
			end
		end
	end

	return expanded
end

local function buildTraversalPath(basePath: { GraphNode }): { GraphNode }
	return collapseImmediateBacktracks(injectWander(basePath))
end

local function resolveSegmentPositions(path: { GraphNode }, finalOverride: Vector3?): { Vector3 }
	local positions: { Vector3 } = {}
	for i = 2, #path do
		table.insert(positions, NodeGraph.resolvePosition(path[i]))
	end

	if finalOverride then
		if #positions == 0 then
			table.insert(positions, finalOverride)
		else
			positions[#positions] = finalOverride
		end
	end

	return positions
end

local function estimateTravelDuration(fromPosition: Vector3, positions: { Vector3 }, speed: number): number
	if speed <= 0 then
		return 0
	end

	local duration = 0
	local lastPosition = fromPosition
	for _, position in ipairs(positions) do
		duration += (position - lastPosition).Magnitude / speed
		lastPosition = position
	end
	return duration
end

local function appendWalkPositions(
	route: { RouteStep },
	positions: { Vector3 },
	lastPosition: Vector3,
	elapsedTime: number
): (Vector3, number)
	local baseSpeed = math.max(Config.BASE_WALK_SPEED, EPSILON)

	for _, position in ipairs(positions) do
		local distance = (position - lastPosition).Magnitude
		elapsedTime += distance / baseSpeed

		table.insert(route, {
			position = position,
			action = "walk",
			duration = nil,
			faceCFrame = nil,
			sitCFrame = nil,
		})

		lastPosition = position
	end

	return lastPosition, elapsedTime
end

local function getAllPOINodes(): { GraphNode }
	local result: { GraphNode } = {}

	for _, node in ipairs(NodeGraph.getNodesByTag(Config.TAG_SCENIC)) do
		table.insert(result, node)
	end
	for _, node in ipairs(NodeGraph.getNodesByTag(Config.TAG_BUSY)) do
		table.insert(result, node)
	end
	for _, node in ipairs(NodeGraph.getNodesByTag(Config.TAG_SOCIAL)) do
		table.insert(result, node)
	end

	return result
end

local function pickWeightedPOIs(count: number): { GraphNode }
	local pool = getAllPOINodes()
	local picked: { GraphNode } = {}

	count = math.min(count, #pool)
	for _ = 1, count do
		local totalWeight = 0
		for _, node in ipairs(pool) do
			totalWeight += math.max(node.weight or 1, 0)
		end

		local chosenIndex = 1
		if totalWeight > 0 then
			local roll = math.random() * totalWeight
			local running = 0
			for index, node in ipairs(pool) do
				running += math.max(node.weight or 1, 0)
				if roll <= running then
					chosenIndex = index
					break
				end
			end
		else
			chosenIndex = math.random(1, #pool)
		end

		local chosen = table.remove(pool, chosenIndex)
		table.insert(picked, chosen)
	end

	return picked
end

local function findReachableDespawnPath(fromNode: GraphNode, disallowedFirstHopPart: Part?): { GraphNode }?
	local despawnNodes = copyNodes(NodeGraph.getNodesByTag(Config.TAG_DESPAWN))
	if #despawnNodes == 0 then
		return nil
	end

	shuffleNodes(despawnNodes)
	for _, despawnNode in ipairs(despawnNodes) do
		local basePath = NodeGraph.getPath(fromNode.part, despawnNode.part)
		local path = if basePath then buildTraversalPath(basePath) else nil
		if path then
			if disallowedFirstHopPart and #path >= 2 and path[2].part == disallowedFirstHopPart then
				continue
			end
			return path
		end
	end

	return nil
end

local function hasReachableDespawn(fromNode: GraphNode): boolean
	return findReachableDespawnPath(fromNode) ~= nil
end

local function cloneRoute(route: { RouteStep }): { RouteStep }
	local copy: { RouteStep } = table.create(#route)
	for i, step in ipairs(route) do
		copy[i] = {
			position = step.position,
			action = step.action,
			duration = step.duration,
			faceCFrame = step.faceCFrame,
			sitCFrame = step.sitCFrame,
		}
	end
	return copy
end

local function offsetRoute(route: { RouteStep }, offsetAmount: number): { RouteStep }
	local result: { RouteStep } = table.create(#route)

	for index, step in ipairs(route) do
		local previousStep = route[index - 1]
		local nextStep = route[index + 1]
		local direction = Vector3.new(1, 0, 0)

		if nextStep then
			local raw = nextStep.position - step.position
			local flat = Vector3.new(raw.X, 0, raw.Z)
			if flat.Magnitude > EPSILON then
				direction = flat.Unit
			end
		elseif previousStep then
			local raw = step.position - previousStep.position
			local flat = Vector3.new(raw.X, 0, raw.Z)
			if flat.Magnitude > EPSILON then
				direction = flat.Unit
			end
		end

		local lateral = Vector3.new(-direction.Z, 0, direction.X) * offsetAmount
		local isDespawnStep = step.action == "despawn"
		if isDespawnStep then
			lateral = Vector3.zero
		end

		result[index] = {
			position = step.position + lateral,
			action = step.action,
			duration = step.duration,
			faceCFrame = if step.faceCFrame then step.faceCFrame + lateral else nil,
			sitCFrame = if step.sitCFrame then step.sitCFrame + lateral else nil,
		}
	end

	return result
end

function RouteBuilder.buildRoute(spawnNode: GraphNode): ({ RouteStep }, { Part })
	if not spawnNode or not spawnNode.part then
		return {}, {}
	end

	local route: { RouteStep } = {}
	local reservedSeats: { Part } = {}

	local currentNode = spawnNode
	local previousHopPart: Part? = nil
	local lastPosition = NodeGraph.resolvePosition(spawnNode)
	local elapsedTime = 0

	table.insert(route, {
		position = lastPosition,
		action = "walk",
		duration = nil,
		faceCFrame = nil,
		sitCFrame = nil,
	})

	local poiMin = math.max(0, math.floor(Config.ROUTE_POI_MIN))
	local poiMax = math.max(poiMin, math.floor(Config.ROUTE_POI_MAX))
	local poiCount = randomInt(poiMin, poiMax)
	local selectedPOIs = pickWeightedPOIs(poiCount)

	for _, poiNode in ipairs(selectedPOIs) do
		if not hasReachableDespawn(poiNode) then
			debugLog(("Skipping POI without reachable despawn exit: %s"):format(poiNode.part:GetFullName()))
			continue
		end

		local basePath = NodeGraph.getPath(currentNode.part, poiNode.part)
		if not basePath then
			debugLog(("Skipping unreachable POI %s"):format(poiNode.part:GetFullName()))
			continue
		end

		local path = buildTraversalPath(basePath)
		if previousHopPart and #path >= 2 and path[2].part == previousHopPart then
			debugLog(("Skipping immediate-backtrack POI leg at %s"):format(poiNode.part:GetFullName()))
			continue
		end

		if poiNode.tag == Config.TAG_SOCIAL then
			local sitDuration = randomFloat(Config.SOCIAL_SIT_MIN, Config.SOCIAL_SIT_MAX)
			local predictedPositions = resolveSegmentPositions(path, nil)
			local predictedArrivalTime = tick()
				+ elapsedTime
				+ estimateTravelDuration(lastPosition, predictedPositions, math.max(Config.BASE_WALK_SPEED, EPSILON))
			local reservedSeat = SeatManager.reserveSeat(poiNode.part, predictedArrivalTime, sitDuration, nil)
			if not reservedSeat then
				debugLog(("Skipping social POI without available seat: %s"):format(poiNode.part:GetFullName()))
				continue
			end

			table.insert(reservedSeats, reservedSeat)

			local socialPositions = resolveSegmentPositions(path, reservedSeat.Position)
			lastPosition, elapsedTime = appendWalkPositions(route, socialPositions, lastPosition, elapsedTime)

			local finalStep = route[#route]
			if finalStep then
				finalStep.action = "sit"
				finalStep.duration = sitDuration
				finalStep.sitCFrame = reservedSeat.CFrame
				finalStep.faceCFrame = nil
			end
			elapsedTime += sitDuration
			if #path >= 2 then
				previousHopPart = path[#path - 1].part
			end
			currentNode = poiNode
			continue
		end

		local poiPositions = resolveSegmentPositions(path, nil)
		lastPosition, elapsedTime = appendWalkPositions(route, poiPositions, lastPosition, elapsedTime)

		local finalStep = route[#route]
		if finalStep and poiNode.tag == Config.TAG_SCENIC then
			local idleDuration = randomFloat(Config.SCENIC_IDLE_MIN, Config.SCENIC_IDLE_MAX)
			finalStep.action = "idle"
			finalStep.duration = idleDuration
			finalStep.sitCFrame = nil

			local lookAtPosition = resolveScenicLookPosition(poiNode)
			if lookAtPosition then
				local flatTarget = Vector3.new(lookAtPosition.X, finalStep.position.Y, lookAtPosition.Z)
				if (flatTarget - finalStep.position).Magnitude > EPSILON then
					finalStep.faceCFrame = CFrame.lookAt(finalStep.position, flatTarget)
				end
			end

			elapsedTime += idleDuration
		end

		if #path >= 2 then
			previousHopPart = path[#path - 1].part
		end
		currentNode = poiNode
	end

	local despawnPath = findReachableDespawnPath(currentNode, previousHopPart)
	if not despawnPath then
		debugLog(("No reachable despawn from node %s; returning empty route"):format(currentNode.part:GetFullName()))
		return {}, {}
	end

	local finalPositions = resolveSegmentPositions(despawnPath, nil)
	lastPosition, elapsedTime = appendWalkPositions(route, finalPositions, lastPosition, elapsedTime)

	if #route == 0 then
		return {}, {}
	end

	if #finalPositions == 0 and route[#route].action ~= "walk" then
		table.insert(route, {
			position = route[#route].position,
			action = "despawn",
			duration = nil,
			faceCFrame = nil,
			sitCFrame = nil,
		})
	else
		local terminalStep = route[#route]
		terminalStep.action = "despawn"
		terminalStep.duration = nil
		terminalStep.faceCFrame = nil
		terminalStep.sitCFrame = nil
	end

	if #route < 2 or route[1].action == "despawn" then
		return {}, {}
	end

	return route, reservedSeats
end

function RouteBuilder.buildGroupRoute(
	spawnNode: GraphNode,
	groupSize: number
): { { route: { RouteStep }, reservedSeats: { Part } } }
	groupSize = math.max(1, math.floor(groupSize))

	local leaderRoute, leaderSeats = RouteBuilder.buildRoute(spawnNode)
	if #leaderRoute == 0 then
		return {}
	end

	local groupRoutes: { { route: { RouteStep }, reservedSeats: { Part } } } = {}
	table.insert(groupRoutes, {
		route = cloneRoute(leaderRoute),
		reservedSeats = leaderSeats,
	})

	for followerIndex = 1, groupSize - 1 do
		local offsetAmount = Config.GROUP_FOLLOWER_OFFSET * followerIndex
		table.insert(groupRoutes, {
			route = offsetRoute(leaderRoute, offsetAmount),
			reservedSeats = {},
		})
	end

	return groupRoutes
end

return RouteBuilder
