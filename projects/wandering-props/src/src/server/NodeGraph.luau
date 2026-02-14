--!strict

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local sharedFolder = ReplicatedStorage:WaitForChild("WanderingProps")
local Config = require(sharedFolder:WaitForChild("Config"))
local Diagnostics = require(sharedFolder:WaitForChild("Diagnostics"))

type SeatData = {
    id: string,
    instance: BasePart,
    cframe: CFrame,
    approachNodeId: string?,
}

type POIData = {
    poiType: "scenic" | "busy" | "social",
    weight: number,
    viewZone: BasePart?,
    seats: { SeatData }?,
}

type NodeData = {
    id: string,
    instance: BasePart,
    position: Vector3,
    nodeType: "spot" | "zone",
    nodeRole: "waypoint" | "spawn" | "despawn",
    connections: { string },
    size: Vector3?,
    poi: POIData?,
    socialPOIId: string?,
}

local NodeGraph = {}

local nodesById: { [string]: NodeData } = {}
local idByPart: { [BasePart]: string } = {}
local spawnNodes: { NodeData } = {}
local despawnNodes: { NodeData } = {}
local poiNodes: { NodeData } = {}
local built = false

local function copyArray<T>(source: { T }): { T }
    local copy = table.create(#source)
    for i, value in ipairs(source) do
        copy[i] = value
    end
    return copy
end

local function addConnectionUnique(node: NodeData, targetId: string): ()
    for _, existing in ipairs(node.connections) do
        if existing == targetId then
            return
        end
    end
    table.insert(node.connections, targetId)
end

local function parseNodeType(part: BasePart): "spot" | "zone"
    local nodeTypeAttr = part:GetAttribute("NodeType")
    if typeof(nodeTypeAttr) == "string" and string.lower(nodeTypeAttr) == "zone" then
        return "zone"
    end
    return "spot"
end

local function parseNodeRole(part: BasePart): "waypoint" | "spawn" | "despawn"
    local roleAttr = part:GetAttribute("NodeRole")
    if typeof(roleAttr) == "string" then
        local normalized = string.lower(roleAttr)
        if normalized == "spawn" then
            return "spawn"
        elseif normalized == "despawn" then
            return "despawn"
        end
    end
    return "waypoint"
end

local function parsePOI(part: BasePart): POIData?
    if not CollectionService:HasTag(part, Config.TAG_POI) then
        return nil
    end

    local poiTypeAttr = part:GetAttribute("POIType")
    local poiType: "scenic" | "busy" | "social" = "busy"
    if typeof(poiTypeAttr) == "string" then
        local normalized = string.lower(poiTypeAttr)
        if normalized == "scenic" or normalized == "social" or normalized == "busy" then
            poiType = normalized
        end
    end

    local weightAttr = part:GetAttribute("POIWeight")
    local weight = 1
    if typeof(weightAttr) == "number" and weightAttr > 0 then
        weight = weightAttr
    end

    local poi: POIData = {
        poiType = poiType,
        weight = weight,
        viewZone = nil,
        seats = nil,
    }

    if poiType == "scenic" then
        for _, child in ipairs(part:GetChildren()) do
            if child:IsA("BasePart") and CollectionService:HasTag(child, Config.TAG_VIEW_ZONE) then
                poi.viewZone = child
                break
            end
        end
    elseif poiType == "social" then
        local seats: { SeatData } = {}
        local seatCounter = 0
        for _, descendant in ipairs(part:GetDescendants()) do
            if descendant:IsA("BasePart") and CollectionService:HasTag(descendant, Config.TAG_SEAT) then
                local approachNodeId: string? = nil
                for _, child in ipairs(descendant:GetChildren()) do
                    if child:IsA("ObjectValue") then
                        local target = child.Value
                        if target and target:IsA("BasePart") and CollectionService:HasTag(target, Config.TAG_NODE) then
                            approachNodeId = target.Name
                            break
                        end
                    end
                end

                seatCounter += 1
                table.insert(seats, {
                    id = string.format("%s::%s::%d", part.Name, descendant.Name, seatCounter),
                    instance = descendant,
                    cframe = descendant.CFrame,
                    approachNodeId = approachNodeId,
                })
            end
        end
        poi.seats = seats
    end

    return poi
end

function NodeGraph.build(): boolean
    nodesById = {}
    idByPart = {}
    spawnNodes = {}
    despawnNodes = {}
    poiNodes = {}
    built = false

    local taggedNodes = CollectionService:GetTagged(Config.TAG_NODE)
    for _, tagged in ipairs(taggedNodes) do
        if not tagged:IsA("BasePart") then
            continue
        end
        if not tagged:IsDescendantOf(Workspace) then
            continue
        end

        local nodeId = tagged.Name
        if nodesById[nodeId] then
            Diagnostics.increment("totalRejects", "duplicate_node_id")
            continue
        end

        local node: NodeData = {
            id = nodeId,
            instance = tagged,
            position = tagged.Position,
            nodeType = parseNodeType(tagged),
            nodeRole = parseNodeRole(tagged),
            connections = {},
            size = if parseNodeType(tagged) == "zone" then tagged.Size else nil,
            poi = parsePOI(tagged),
            socialPOIId = nil,
        }

        nodesById[nodeId] = node
        idByPart[tagged] = nodeId

        if node.nodeRole == "spawn" then
            table.insert(spawnNodes, node)
        elseif node.nodeRole == "despawn" then
            table.insert(despawnNodes, node)
        end

        if node.poi then
            table.insert(poiNodes, node)
        end
    end

    local function resolveSocialPOIId(node: NodeData): string?
        local explicitAttr = node.instance:GetAttribute("SocialPOIId")
        if typeof(explicitAttr) == "string" and explicitAttr ~= "" then
            local explicitOwner = nodesById[explicitAttr]
            if explicitOwner and explicitOwner.id ~= node.id and explicitOwner.poi and explicitOwner.poi.poiType == "social" then
                return explicitOwner.id
            end
        end

        local cursor: Instance? = node.instance.Parent
        while cursor do
            if cursor:IsA("BasePart") then
                local ownerId = idByPart[cursor]
                if ownerId and ownerId ~= node.id then
                    local ownerNode = nodesById[ownerId]
                    if ownerNode and ownerNode.poi and ownerNode.poi.poiType == "social" then
                        return ownerNode.id
                    end
                end
            end
            cursor = cursor.Parent
        end

        return nil
    end

    for _, node in pairs(nodesById) do
        node.socialPOIId = resolveSocialPOIId(node)
    end

    for nodeId, node in pairs(nodesById) do
        local sourcePart = node.instance
        for _, child in ipairs(sourcePart:GetChildren()) do
            if not child:IsA("ObjectValue") then
                continue
            end

            local target = child.Value
            if not target or not target:IsA("BasePart") then
                continue
            end
            if not CollectionService:HasTag(target, Config.TAG_NODE) then
                continue
            end

            local targetId = idByPart[target]
            if targetId and targetId ~= nodeId then
                local targetNode = nodesById[targetId]
                if targetNode then
                    addConnectionUnique(node, targetId)
                    addConnectionUnique(targetNode, nodeId)
                end
            end
        end
    end

    built = true
    return true
end

local function ensureBuilt(): ()
    if not built then
        NodeGraph.build()
    end
end

function NodeGraph.findPath(
    fromId: string,
    toId: string,
    excludeFirstHop: string?,
    blockedNodeIds: { [string]: boolean }?
): { string }?
    ensureBuilt()

    if fromId == toId and nodesById[fromId] then
        return { fromId }
    end

    local startNode = nodesById[fromId]
    local goalNode = nodesById[toId]
    if not startNode or not goalNode then
        return nil
    end

    local dist: { [string]: number } = {}
    local prev: { [string]: string } = {}
    local unvisited: { [string]: boolean } = {}

    for nodeId in pairs(nodesById) do
        dist[nodeId] = math.huge
        unvisited[nodeId] = true
    end
    dist[fromId] = 0

    while true do
        local currentId: string? = nil
        local currentDist = math.huge

        for nodeId in pairs(unvisited) do
            local d = dist[nodeId] or math.huge
            if d < currentDist then
                currentDist = d
                currentId = nodeId
            end
        end

        if not currentId or currentDist == math.huge then
            break
        end

        if currentId == toId then
            break
        end

        unvisited[currentId] = nil

        local currentNode = nodesById[currentId]
        if currentNode then
            for _, neighborId in ipairs(currentNode.connections) do
                if currentId == fromId and excludeFirstHop and neighborId == excludeFirstHop then
                    continue
                end

                if unvisited[neighborId] then
                    if blockedNodeIds and blockedNodeIds[neighborId] and neighborId ~= toId then
                        continue
                    end
                    local neighborNode = nodesById[neighborId]
                    if neighborNode then
                        local alt = (dist[currentId] or math.huge)
                            + (neighborNode.position - currentNode.position).Magnitude
                        if alt < (dist[neighborId] or math.huge) then
                            dist[neighborId] = alt
                            prev[neighborId] = currentId
                        end
                    end
                end
            end
        end
    end

    if (dist[toId] or math.huge) == math.huge then
        return nil
    end

    local pathReversed: { string } = {}
    local cursor: string? = toId
    while cursor do
        table.insert(pathReversed, cursor)
        cursor = prev[cursor]
    end

    local path: { string } = table.create(#pathReversed)
    for i = #pathReversed, 1, -1 do
        table.insert(path, pathReversed[i])
    end

    if excludeFirstHop and #path >= 2 and path[2] == excludeFirstHop then
        return nil
    end

    return path
end

function NodeGraph.getNode(nodeId: string): NodeData?
    ensureBuilt()
    return nodesById[nodeId]
end

function NodeGraph.getSpawnNodes(): { NodeData }
    ensureBuilt()
    return copyArray(spawnNodes)
end

function NodeGraph.getDespawnNodes(): { NodeData }
    ensureBuilt()
    return copyArray(despawnNodes)
end

function NodeGraph.getPOINodes(): { NodeData }
    ensureBuilt()
    return copyArray(poiNodes)
end

function NodeGraph.getAllNodes(): { NodeData }
    ensureBuilt()
    local result: { NodeData } = {}
    for _, node in pairs(nodesById) do
        table.insert(result, node)
    end
    return result
end

function NodeGraph.getNodesInRadius(position: Vector3, radius: number): { NodeData }
    ensureBuilt()

    local result: { NodeData } = {}
    local radiusSq = radius * radius
    for _, node in pairs(nodesById) do
        local offset = node.position - position
        local distSq = offset.X * offset.X + offset.Y * offset.Y + offset.Z * offset.Z
        if distSq <= radiusSq then
            table.insert(result, node)
        end
    end

    return result
end

function NodeGraph.resolvePosition(nodeId: string): Vector3
    ensureBuilt()

    local node = nodesById[nodeId]
    if not node then
        return Vector3.zero
    end

    if node.nodeType == "zone" and node.size then
        local half = node.size * 0.5
        local localOffset = Vector3.new(
            (math.random() * 2 - 1) * half.X,
            0,
            (math.random() * 2 - 1) * half.Z
        )
        return node.instance.CFrame:PointToWorldSpace(localOffset)
    end

    return node.position
end

return NodeGraph
