--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local sharedFolder = ReplicatedStorage:WaitForChild("WanderingProps")
local Config = require(sharedFolder:WaitForChild("Config"))
local Diagnostics = require(sharedFolder:WaitForChild("Diagnostics"))

type SeatData = {
    id: string,
    instance: BasePart,
    cframe: CFrame,
    approachNodeId: string?,
}

type NodeData = {
    id: string,
    instance: BasePart,
    position: Vector3,
    nodeType: "spot" | "zone",
    nodeRole: "waypoint" | "spawn" | "despawn",
    connections: { string },
    size: Vector3?,
    poi: {
        poiType: "scenic" | "busy" | "social",
        weight: number,
        viewZone: BasePart?,
        seats: { SeatData }?,
    }?,
    socialPOIId: string?,
}

type SeatClaim = {
    seatId: string,
    poiNodeId: string,
    cframe: CFrame,
    approachNodeId: string?,
}

type SeatEntry = {
    seatId: string,
    poiNodeId: string,
    cframe: CFrame,
    instance: BasePart,
    approachNodeId: string?,
    groupKey: string,
    occupied: boolean,
}

type POISeatRecord = {
    poiNodeId: string,
    seats: { SeatEntry },
    occupiedCount: number,
    capacityCap: number,
}

local SeatManager = {}

local poiRecords: { [string]: POISeatRecord } = {}
local seatById: { [string]: SeatEntry } = {}
local seatTotalCount = 0
local seatOccupiedCount = 0

local function adjustCounter(counter: string, delta: number): ()
    if delta > 0 then
        for _ = 1, delta do
            Diagnostics.increment(counter)
        end
    elseif delta < 0 then
        for _ = 1, -delta do
            Diagnostics.decrement(counter)
        end
    end
end

local function resetDiagnosticsSeatCounters(newSeatTotal: number): ()
    adjustCounter("seatOccupied", -seatOccupiedCount)
    seatOccupiedCount = 0

    local deltaTotal = newSeatTotal - seatTotalCount
    adjustCounter("seatTotal", deltaTotal)
    seatTotalCount = newSeatTotal
end

local function resolveGroupKey(poiPart: BasePart, seatPart: BasePart): string
    local tableId = seatPart:GetAttribute("TableId")
    if typeof(tableId) == "string" and tableId ~= "" then
        return string.format("%s::table::%s", poiPart:GetFullName(), tableId)
    end

    local topChild: Instance = seatPart
    local cursor: Instance? = seatPart

    while cursor and cursor ~= poiPart do
        topChild = cursor
        cursor = cursor.Parent
    end

    return topChild:GetFullName()
end

local function resolveNearestNodeId(candidates: { NodeData }, position: Vector3): string?
    local nearestId: string? = nil
    local nearestDistance = math.huge
    for _, candidate in ipairs(candidates) do
        local dist = (candidate.position - position).Magnitude
        if dist < nearestDistance then
            nearestDistance = dist
            nearestId = candidate.id
        end
    end
    return nearestId
end

local function chooseWeightedSeat(available: { SeatEntry }, groupOccupancy: { [string]: number }): SeatEntry
    local socialWeight = math.max(0, tonumber(Config.SOCIAL_GROUP_WEIGHT) or 0.7)
    local totalWeight = 0
    local weights: { number } = table.create(#available, 1)

    for index, seat in ipairs(available) do
        local occupiedAtTable = groupOccupancy[seat.groupKey] or 0
        local weight = 1 + occupiedAtTable * socialWeight
        weights[index] = weight
        totalWeight += weight
    end

    if totalWeight <= 0 then
        return available[math.random(1, #available)]
    end

    local roll = math.random() * totalWeight
    local running = 0
    for index, seat in ipairs(available) do
        running += weights[index]
        if roll <= running then
            return seat
        end
    end

    return available[#available]
end

function SeatManager.init(nodeGraph: any): ()
    poiRecords = {}
    seatById = {}

    local totalSeats = 0
    local socialCapacity = math.clamp(tonumber(Config.SOCIAL_CAPACITY_PERCENT) or 0.75, 0, 1)
    local allNodes: { NodeData } = nodeGraph.getAllNodes()
    local socialNavNodesByPOI: { [string]: { NodeData } } = {}

    local function pushSocialNode(poiId: string, node: NodeData): ()
        local list = socialNavNodesByPOI[poiId]
        if not list then
            list = {}
            socialNavNodesByPOI[poiId] = list
        end
        table.insert(list, node)
    end

    for _, node in ipairs(allNodes) do
        if node.poi and node.poi.poiType == "social" then
            pushSocialNode(node.id, node)
        end

        if node.socialPOIId then
            pushSocialNode(node.socialPOIId, node)
        end
    end

    for _, poiNode: NodeData in ipairs(nodeGraph.getPOINodes()) do
        local poi = poiNode.poi
        if not poi or poi.poiType ~= "social" then
            continue
        end

        local seats = poi.seats or {}
        local entries: { SeatEntry } = {}
        local socialNavNodes = socialNavNodesByPOI[poiNode.id] or { poiNode }
        for _, seat in ipairs(seats) do
            local approachNodeId = seat.approachNodeId
            if approachNodeId then
                local approachNode = nodeGraph.getNode(approachNodeId)
                if not approachNode then
                    approachNodeId = nil
                elseif approachNode.id ~= poiNode.id and approachNode.socialPOIId ~= poiNode.id then
                    approachNodeId = nil
                end
            end

            if not approachNodeId then
                approachNodeId = resolveNearestNodeId(socialNavNodes, seat.instance.Position) or poiNode.id
            end

            local entry: SeatEntry = {
                seatId = seat.id,
                poiNodeId = poiNode.id,
                cframe = seat.cframe,
                instance = seat.instance,
                approachNodeId = approachNodeId,
                groupKey = resolveGroupKey(poiNode.instance, seat.instance),
                occupied = false,
            }
            table.insert(entries, entry)
            seatById[seat.id] = entry
            totalSeats += 1
        end

        poiRecords[poiNode.id] = {
            poiNodeId = poiNode.id,
            seats = entries,
            occupiedCount = 0,
            capacityCap = socialCapacity,
        }
    end

    resetDiagnosticsSeatCounters(totalSeats)
end

function SeatManager.claimSeat(poiNodeId: string): SeatClaim?
    local record = poiRecords[poiNodeId]
    if not record then
        return nil
    end

    local totalSeats = #record.seats
    if totalSeats <= 0 then
        return nil
    end

    local maxOccupied = math.floor(totalSeats * record.capacityCap)
    if record.capacityCap > 0 then
        maxOccupied = math.max(1, maxOccupied)
    end

    if maxOccupied <= 0 or record.occupiedCount >= maxOccupied then
        Diagnostics.increment("totalRejects", "no_seat")
        return nil
    end

    local groupOccupancy: { [string]: number } = {}
    local available: { SeatEntry } = {}
    for _, seat in ipairs(record.seats) do
        if seat.occupied then
            groupOccupancy[seat.groupKey] = (groupOccupancy[seat.groupKey] or 0) + 1
        else
            table.insert(available, seat)
        end
    end

    if #available <= 0 then
        Diagnostics.increment("totalRejects", "no_seat")
        return nil
    end

    local chosen = chooseWeightedSeat(available, groupOccupancy)
    chosen.occupied = true
    record.occupiedCount += 1

    seatOccupiedCount += 1
    Diagnostics.increment("seatOccupied")

    return {
        seatId = chosen.seatId,
        poiNodeId = chosen.poiNodeId,
        cframe = chosen.cframe,
        approachNodeId = chosen.approachNodeId,
    }
end

function SeatManager.releaseSeat(seatId: string): ()
    local entry = seatById[seatId]
    if not entry or not entry.occupied then
        return
    end

    local record = poiRecords[entry.poiNodeId]
    if record then
        record.occupiedCount = math.max(0, record.occupiedCount - 1)
    end

    entry.occupied = false
    seatOccupiedCount = math.max(0, seatOccupiedCount - 1)
    Diagnostics.decrement("seatOccupied")
end

function SeatManager.getOccupancy(poiNodeId: string): (number, number)
    local record = poiRecords[poiNodeId]
    if not record then
        return 0, 0
    end

    return record.occupiedCount, #record.seats
end

return SeatManager
