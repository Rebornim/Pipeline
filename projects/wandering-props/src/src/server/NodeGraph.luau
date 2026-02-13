--!strict

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local configModule = ReplicatedStorage:WaitForChild("Config", 10)
assert(configModule and configModule:IsA("ModuleScript"), "WanderingProps NodeGraph: ReplicatedStorage.Config not found")

local Config = require(configModule)

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

local NodeGraph = {}

local NAVIGATION_TAGS = {
	Config.TAG_WAYPOINT,
	Config.TAG_SPAWN,
	Config.TAG_DESPAWN,
	Config.TAG_SCENIC,
	Config.TAG_BUSY,
	Config.TAG_SOCIAL,
}

local DEFAULT_WEIGHT = 1
local DEFAULT_CAPACITY_CAP = 0.75
local DEFAULT_TURN_PENALTY = 0

local graph: { [Part]: GraphNode } = {}
local nodesByTag: { [string]: { GraphNode } } = {}
local initialized = false

local function debugLog(message: string): ()
	if Config.DEBUG_ENABLED then
		warn(("[WanderingProps/NodeGraph] %s"):format(message))
	end
end

local function resolveWeight(part: Part): number
	local weightAttr = part:GetAttribute("Weight")
	if typeof(weightAttr) == "number" and weightAttr > 0 then
		return weightAttr
	end
	return DEFAULT_WEIGHT
end

local function resolveCapacityCap(part: Part): number
	local capAttr = part:GetAttribute("CapacityCap")
	if typeof(capAttr) == "number" then
		return math.clamp(capAttr, 0, 1)
	end
	return DEFAULT_CAPACITY_CAP
end

local function resolveViewTargets(part: Part): { Part }
	local viewTargets: { Part } = {}

	local viewTargetsContainer = part:FindFirstChild("ViewTargets")
	if viewTargetsContainer then
		for _, descendant in ipairs(viewTargetsContainer:GetDescendants()) do
			if descendant:IsA("Part") then
				table.insert(viewTargets, descendant)
			end
		end
	end

	-- If no "ViewTargets" container exists, allow direct child parts named "ViewTarget*".
	if #viewTargets == 0 then
		for _, child in ipairs(part:GetChildren()) do
			if child:IsA("Part") and string.sub(child.Name, 1, 10) == "ViewTarget" then
				table.insert(viewTargets, child)
			end
		end
	end

	-- Backward compatibility: legacy ObjectValue ViewTarget.
	if #viewTargets == 0 then
		local legacyViewTarget = part:FindFirstChild("ViewTarget")
		if legacyViewTarget and legacyViewTarget:IsA("ObjectValue") then
			local target = legacyViewTarget.Value
			if target and target:IsA("Part") then
				table.insert(viewTargets, target)
			end
		end
	end

	if #viewTargets == 0 then
		debugLog(("Scenic node %s is missing view target Parts"):format(part:GetFullName()))
	end

	return viewTargets
end

local function resolveSocialSeats(part: Part): { Part }
	local seats: { Part } = {}
	for _, descendant in ipairs(part:GetDescendants()) do
		if descendant:IsA("Part") and CollectionService:HasTag(descendant, Config.TAG_SEAT) then
			table.insert(seats, descendant)
		end
	end
	return seats
end

local function createNode(part: Part, tag: string): GraphNode
	local isZone = part:GetAttribute("IsZone") == true
	local node: GraphNode = {
		part = part,
		tag = tag,
		position = part.Position,
		isZone = isZone,
		size = if isZone then part.Size else nil,
		connections = {},
	}

	return node
end

local function applyTagProperties(node: GraphNode, part: Part, tag: string): ()
	if tag == Config.TAG_SCENIC or tag == Config.TAG_BUSY or tag == Config.TAG_SOCIAL then
		node.weight = resolveWeight(part)
	end

	if tag == Config.TAG_SCENIC then
		node.viewTargets = resolveViewTargets(part)
	end

	if tag == Config.TAG_SOCIAL then
		node.capacityCap = resolveCapacityCap(part)
		node.seats = resolveSocialSeats(part)
	end
end

local function reverseNodesInPlace(nodes: { GraphNode }): ()
	local left = 1
	local right = #nodes
	while left < right do
		nodes[left], nodes[right] = nodes[right], nodes[left]
		left += 1
		right -= 1
	end
end

local function estimateHeuristicDistance(fromNode: GraphNode, toNode: GraphNode): number
	return (toNode.position - fromNode.position).Magnitude
end

local function getTurnPenalty(): number
	local raw = tonumber(Config.PATH_TURN_PENALTY)
	if raw == nil then
		return DEFAULT_TURN_PENALTY
	end
	return math.max(0, raw)
end

local function estimateTurnPenalty(
	currentNode: GraphNode,
	nextNode: GraphNode,
	cameFrom: { [Part]: Part },
	graphByPart: { [Part]: GraphNode }
): number
	local previousPart = cameFrom[currentNode.part]
	if not previousPart then
		return 0
	end

	local previousNode = graphByPart[previousPart]
	if not previousNode then
		return 0
	end

	local incoming = currentNode.position - previousNode.position
	local outgoing = nextNode.position - currentNode.position
	if incoming.Magnitude <= 0.0001 or outgoing.Magnitude <= 0.0001 then
		return 0
	end

	local dot = math.clamp(incoming.Unit:Dot(outgoing.Unit), -1, 1)
	local turnStrength = 1 - dot -- 0 straight, 2 full reversal
	return turnStrength * getTurnPenalty()
end

function NodeGraph.init(): ()
	graph = {}
	nodesByTag = {}
	initialized = false

	for _, tag in ipairs(NAVIGATION_TAGS) do
		nodesByTag[tag] = {}
	end

	local partRoles: { [Part]: { [string]: boolean } } = {}
	for _, tag in ipairs(NAVIGATION_TAGS) do
		for _, tagged in ipairs(CollectionService:GetTagged(tag)) do
			if not tagged:IsDescendantOf(Workspace) then
				continue
			end

			if not tagged:IsA("Part") then
				debugLog(("Ignoring non-Part tagged instance %s for tag %s"):format(tagged:GetFullName(), tag))
				continue
			end

			local part = tagged
			local roleMap = partRoles[part]
			if not roleMap then
				roleMap = {}
				partRoles[part] = roleMap
			end
			if roleMap[tag] then
				continue
			end
			roleMap[tag] = true

			local node = graph[part]
			if not node then
				node = createNode(part, tag)
				graph[part] = node
			end

			applyTagProperties(node, part, tag)
			table.insert(nodesByTag[tag], node)
		end
	end

	for part, node in pairs(graph) do
		for _, child in ipairs(part:GetChildren()) do
			if not child:IsA("ObjectValue") then
				continue
			end

			-- Scenic nodes use this reserved ObjectValue for facing direction, not graph edges.
			if child.Name == "ViewTarget" then
				continue
			end

			local target = child.Value
			if not target then
				continue
			end

			if not target:IsA("Part") then
				debugLog(("Connection %s on %s points to non-Part instance"):format(child.Name, part:GetFullName()))
				continue
			end

			local targetNode = graph[target]
			if targetNode then
				table.insert(node.connections, targetNode)
			else
				debugLog(("Connection %s on %s points to untagged node %s"):format(child.Name, part:GetFullName(), target:GetFullName()))
			end
		end
	end

	initialized = true
end

function NodeGraph.getPath(from: Part, to: Part): { GraphNode }?
	if not initialized then
		NodeGraph.init()
	end

	local startNode = graph[from]
	local goalNode = graph[to]
	if not startNode or not goalNode then
		return nil
	end

	if from == to then
		return { startNode }
	end

	local openList: { Part } = { from }
	local isOpen: { [Part]: boolean } = { [from] = true }
	local cameFrom: { [Part]: Part } = {}
	local gScore: { [Part]: number } = { [from] = 0 }
	local fScore: { [Part]: number } = {
		[from] = estimateHeuristicDistance(startNode, goalNode),
	}

	while #openList > 0 do
		local bestIndex = 1
		local bestPart = openList[1]
		local bestScore = fScore[bestPart] or math.huge

		for index = 2, #openList do
			local candidatePart = openList[index]
			local candidateScore = fScore[candidatePart] or math.huge
			if candidateScore < bestScore then
				bestIndex = index
				bestPart = candidatePart
				bestScore = candidateScore
			end
		end

		local currentPart = bestPart
		if currentPart == to then
			break
		end

		table.remove(openList, bestIndex)
		isOpen[currentPart] = nil

		local currentNode = graph[currentPart]
		if not currentNode then
			continue
		end

		local currentG = gScore[currentPart] or math.huge
		for _, neighborNode in ipairs(currentNode.connections) do
			local neighborPart = neighborNode.part
			local distanceCost = (neighborNode.position - currentNode.position).Magnitude
			local turnPenalty = estimateTurnPenalty(currentNode, neighborNode, cameFrom, graph)
			local tentativeG = currentG + distanceCost + turnPenalty

			if tentativeG < (gScore[neighborPart] or math.huge) then
				cameFrom[neighborPart] = currentPart
				gScore[neighborPart] = tentativeG
				fScore[neighborPart] = tentativeG + estimateHeuristicDistance(neighborNode, goalNode)

				if not isOpen[neighborPart] then
					table.insert(openList, neighborPart)
					isOpen[neighborPart] = true
				end
			end
		end
	end

	if gScore[to] == nil then
		return nil
	end

	local pathReversed: { GraphNode } = {}
	local cursor: Part? = to
	while cursor do
		local node = graph[cursor]
		if node then
			table.insert(pathReversed, node)
		end
		cursor = cameFrom[cursor]
	end

	reverseNodesInPlace(pathReversed)
	return pathReversed
end

function NodeGraph.getNearbyNodes(node: Part, maxHops: number): { GraphNode }
	if not initialized then
		NodeGraph.init()
	end

	if maxHops < 1 then
		return {}
	end

	local startNode = graph[node]
	if not startNode then
		return {}
	end

	local queue: { Part } = { node }
	local queueHead = 1
	local depthByPart: { [Part]: number } = { [node] = 0 }
	local nearby: { GraphNode } = {}

	while queueHead <= #queue do
		local current = queue[queueHead]
		queueHead += 1

		local currentDepth = depthByPart[current]
		if not currentDepth then
			continue
		end

		if currentDepth >= maxHops then
			continue
		end

		local currentNode = graph[current]
		if not currentNode then
			continue
		end

		for _, neighborNode in ipairs(currentNode.connections) do
			local neighborPart = neighborNode.part
			if depthByPart[neighborPart] ~= nil then
				continue
			end

			local nextDepth = currentDepth + 1
			depthByPart[neighborPart] = nextDepth
			table.insert(queue, neighborPart)
			table.insert(nearby, neighborNode)
		end
	end

	return nearby
end

function NodeGraph.resolvePosition(node: GraphNode): Vector3
	if node.isZone and node.size then
		if node.tag == Config.TAG_WAYPOINT and node.part:GetAttribute("RandomizeTravelPoint") ~= true then
			return node.part.Position
		end

		local halfSize = node.size * 0.5
		local randomOffset = Vector3.new(
			(math.random() * 2 - 1) * halfSize.X,
			(math.random() * 2 - 1) * halfSize.Y,
			(math.random() * 2 - 1) * halfSize.Z
		)
		return (node.part.CFrame * CFrame.new(randomOffset)).Position
	end

	return node.part.Position
end

function NodeGraph.getNodesByTag(tag: string): { GraphNode }
	if not initialized then
		NodeGraph.init()
	end

	local taggedNodes = nodesByTag[tag]
	if not taggedNodes then
		return {}
	end

	local copy: { GraphNode } = table.create(#taggedNodes)
	for index, value in ipairs(taggedNodes) do
		copy[index] = value
	end
	return copy
end

function NodeGraph.getNode(part: Part): GraphNode?
	if not initialized then
		NodeGraph.init()
	end

	return graph[part]
end

return NodeGraph
