--!strict

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local sharedFolder = ReplicatedStorage:WaitForChild("WanderingProps")
local Config = require(sharedFolder:WaitForChild("Config"))
local Diagnostics = require(sharedFolder:WaitForChild("Diagnostics"))

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
        seats: {
            {
                id: string,
                instance: BasePart,
                cframe: CFrame,
                approachNodeId: string?,
            }
        }?,
    }?,
    socialPOIId: string?,
}

type RouteStep = {
    type: "walk" | "scenic" | "social" | "despawn",
    targetPosition: Vector3,
    distance: number,
    dwellTime: number?,
    seatCFrame: CFrame?,
    viewPosition: Vector3?,
    poiName: string?,
}

type SeatClaim = {
    seatId: string,
    poiNodeId: string,
    cframe: CFrame,
    approachNodeId: string?,
}

export type RouteResult = {
    route: { RouteStep },
    stepDurations: { number },
    cumulativeTimes: { number },
    totalDuration: number,
    startPosition: Vector3,
    spawnNodeId: string,
    seatClaims: { [number]: string },
}

local RouteBuilder = {}

local EPSILON = 0.001

local function randomFloat(minValue: number, maxValue: number): number
    if maxValue < minValue then
        minValue, maxValue = maxValue, minValue
    end
    if math.abs(maxValue - minValue) <= EPSILON then
        return minValue
    end
    return minValue + math.random() * (maxValue - minValue)
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

local function copyAndShuffle<T>(source: { T }): { T }
    local copy = table.create(#source)
    for i, value in ipairs(source) do
        copy[i] = value
    end

    for i = #copy, 2, -1 do
        local j = math.random(1, i)
        copy[i], copy[j] = copy[j], copy[i]
    end

    return copy
end

local function randomPointInPart(part: BasePart): Vector3
    local half = part.Size * 0.5
    local localOffset = Vector3.new(
        (math.random() * 2 - 1) * half.X,
        (math.random() * 2 - 1) * half.Y,
        (math.random() * 2 - 1) * half.Z
    )
    return part.CFrame:PointToWorldSpace(localOffset)
end

local function randomPointOnPartXZ(part: BasePart): Vector3
    local half = part.Size * 0.5
    local localOffset = Vector3.new(
        (math.random() * 2 - 1) * half.X,
        0,
        (math.random() * 2 - 1) * half.Z
    )
    return part.CFrame:PointToWorldSpace(localOffset)
end

local function resolveScenicViewPosition(poiNode: NodeData): Vector3?
    local viewZones: { BasePart } = {}
    for _, descendant in ipairs(poiNode.instance:GetDescendants()) do
        if descendant:IsA("BasePart") and CollectionService:HasTag(descendant, Config.TAG_VIEW_ZONE) then
            table.insert(viewZones, descendant)
        end
    end

    if #viewZones == 0 and poiNode.poi and poiNode.poi.viewZone then
        table.insert(viewZones, poiNode.poi.viewZone)
    end

    if #viewZones == 0 then
        return nil
    end

    local chosen = viewZones[math.random(1, #viewZones)]
    return randomPointInPart(chosen)
end

local function computeTimings(route: { RouteStep }, walkSpeed: number): ({ number }, { number }, number)
    local speed = math.max(EPSILON, walkSpeed)
    local durations: { number } = table.create(#route, 0)
    local cumulative: { number } = table.create(#route, 0)
    local total = 0

    for i, step in ipairs(route) do
        local duration = 0
        if step.type == "walk" then
            duration = step.distance / speed
        elseif step.type == "scenic" or step.type == "social" then
            duration = math.max(0, step.dwellTime or 0)
        elseif step.type == "despawn" then
            duration = math.max(0, step.dwellTime or tonumber(Config.DESPAWN_LINGER) or 0)
        end

        durations[i] = duration
        total += duration
        cumulative[i] = total
    end

    return durations, cumulative, total
end

local function appendUniquePath(expanded: { string }, path: { string }, startIndex: number): ()
    for i = startIndex, #path do
        local nodeId = path[i]
        local last = expanded[#expanded]
        if last ~= nodeId then
            table.insert(expanded, nodeId)
        end
    end
end

local function pickWeightedNode(nodes: { NodeData }, disallowNodeId: string?): NodeData?
    local candidates: { NodeData } = {}
    for _, node in ipairs(nodes) do
        if not disallowNodeId or node.id ~= disallowNodeId then
            table.insert(candidates, node)
        end
    end

    if #candidates == 0 then
        candidates = nodes
    end
    if #candidates == 0 then
        return nil
    end

    local totalWeight = 0
    for _, node in ipairs(candidates) do
        totalWeight += math.max(0, node.poi and node.poi.weight or 1)
    end

    if totalWeight <= 0 then
        return candidates[math.random(1, #candidates)]
    end

    local roll = math.random() * totalWeight
    local running = 0
    for _, node in ipairs(candidates) do
        running += math.max(0, node.poi and node.poi.weight or 1)
        if roll <= running then
            return node
        end
    end

    return candidates[#candidates]
end

local function buildWeightedPOISequence(nodeGraph: any, count: number): { string }
    local pool: { NodeData } = {}
    for _, node: NodeData in ipairs(nodeGraph.getPOINodes()) do
        table.insert(pool, node)
    end

    local selected: { string } = {}
    if count <= 0 or #pool == 0 then
        return selected
    end

    local allowRepeats = Config.ALLOW_POI_REPEATS == true
    local repeatChance = math.clamp(tonumber(Config.POI_REPEAT_CHANCE) or 0.65, 0, 1)
    local avoidImmediateRepeat = Config.POI_AVOID_IMMEDIATE_REPEAT ~= false

    if not allowRepeats then
        local available: { NodeData } = copyAndShuffle(pool)
        local picks = math.min(count, #available)
        for _ = 1, picks do
            local lastId = selected[#selected]
            local disallowId = if avoidImmediateRepeat then lastId else nil
            local chosen = pickWeightedNode(available, disallowId)
            if not chosen then
                break
            end

            table.insert(selected, chosen.id)

            for index = #available, 1, -1 do
                if available[index].id == chosen.id then
                    table.remove(available, index)
                    break
                end
            end
        end
        return selected
    end

    local usedCounts: { [string]: number } = {}
    for _ = 1, count do
        local unused: { NodeData } = {}
        for _, node in ipairs(pool) do
            if not usedCounts[node.id] then
                table.insert(unused, node)
            end
        end

        local useRepeat = #selected > 0 and math.random() <= repeatChance
        local source = if useRepeat or #unused == 0 then pool else unused
        local lastId = selected[#selected]
        local disallowId = if avoidImmediateRepeat then lastId else nil
        local chosen = pickWeightedNode(source, disallowId)
        if not chosen then
            break
        end

        table.insert(selected, chosen.id)
        usedCounts[chosen.id] = (usedCounts[chosen.id] or 0) + 1
    end

    return selected
end

local function injectWander(path: { string }, nodeGraph: any, blockedNodeIds: { [string]: boolean }?): { string }
    if #path <= 1 then
        return path
    end

    local chance = math.clamp(tonumber(Config.WANDER_CHANCE) or 0, 0, 1)
    local radius = math.max(0, tonumber(Config.WANDER_MAX_DISTANCE) or 0)
    if chance <= 0 or radius <= 0 then
        return path
    end

    local expanded: { string } = { path[1] }
    local pathMembership: { [string]: boolean } = {}
    for _, nodeId in ipairs(path) do
        pathMembership[nodeId] = true
    end

    for i = 1, #path - 1 do
        local fromId = path[i]
        local toId = path[i + 1]
        local inserted = false

        if math.random() <= chance then
            local fromNode = nodeGraph.getNode(fromId)
            if fromNode then
                local candidates = copyAndShuffle(nodeGraph.getNodesInRadius(fromNode.position, radius))
                local attempts = 0
                for _, candidate: NodeData in ipairs(candidates) do
                    if attempts >= 2 then
                        break
                    end

                    if candidate.id ~= fromId
                        and candidate.id ~= toId
                        and not pathMembership[candidate.id]
                        and not (blockedNodeIds and blockedNodeIds[candidate.id])
                    then
                        attempts += 1
                        local toCandidate = nodeGraph.findPath(fromId, candidate.id, nil, blockedNodeIds)
                        local backToMain = nodeGraph.findPath(candidate.id, toId, nil, blockedNodeIds)
                        if toCandidate and backToMain then
                            appendUniquePath(expanded, toCandidate, 2)
                            appendUniquePath(expanded, backToMain, 2)
                            inserted = true
                            break
                        end
                    end
                end

                if attempts > 0 and not inserted then
                    Diagnostics.increment("totalRejects", "wander_fail")
                end
            end
        end

        if not inserted then
            local last = expanded[#expanded]
            if last ~= toId then
                table.insert(expanded, toId)
            end
        end
    end

    return expanded
end

local function findLegPath(
    nodeGraph: any,
    fromNodeId: string,
    toNodeId: string,
    excludeFirstHop: string?,
    allowedSocialPOIId: string?
): { string }?
    local resolvedAllowedSocialPOIId = allowedSocialPOIId
    if not resolvedAllowedSocialPOIId then
        local fromNode: NodeData? = nodeGraph.getNode(fromNodeId)
        if fromNode then
            if fromNode.poi and fromNode.poi.poiType == "social" then
                resolvedAllowedSocialPOIId = fromNode.id
            elseif fromNode.socialPOIId then
                resolvedAllowedSocialPOIId = fromNode.socialPOIId
            end
        end
    end

    local blockedSocialNodes: { [string]: boolean } = {}
    local blockedTransitNodes: { [string]: boolean } = {}
    for _, node: NodeData in ipairs(nodeGraph.getAllNodes()) do
        if node.id == fromNodeId or node.id == toNodeId then
            continue
        end

        if node.nodeRole == "spawn" or node.nodeRole == "despawn" then
            blockedTransitNodes[node.id] = true
        end

        if node.poi and node.poi.poiType == "social" then
            if node.id ~= resolvedAllowedSocialPOIId then
                blockedSocialNodes[node.id] = true
                blockedTransitNodes[node.id] = true
            end
        elseif node.socialPOIId then
            if node.socialPOIId ~= resolvedAllowedSocialPOIId then
                blockedSocialNodes[node.id] = true
                blockedTransitNodes[node.id] = true
            end
        end
    end

    local function hasBlockedTransit(pathToCheck: { string }): boolean
        for i = 2, #pathToCheck - 1 do
            local nodeId = pathToCheck[i]
            if blockedTransitNodes[nodeId] then
                return true
            end
        end
        return false
    end

    local basePath = nodeGraph.findPath(fromNodeId, toNodeId, excludeFirstHop, blockedTransitNodes)
    if not basePath and excludeFirstHop then
        -- Dead-end fallback: allow immediate backtracking when needed.
        basePath = nodeGraph.findPath(fromNodeId, toNodeId, nil, blockedTransitNodes)
    end

    if not basePath then
        return nil
    end

    if hasBlockedTransit(basePath) then
        Diagnostics.increment("totalRejects", "social_transit_blocked")
        return nil
    end

    local expandedPath = injectWander(basePath, nodeGraph, blockedTransitNodes)
    if hasBlockedTransit(expandedPath) then
        -- Wander can temporarily introduce social transit. Keep strict social-transit
        -- blocking while preserving the valid base leg.
        return basePath
    end

    return expandedPath
end

local function appendWalkStep(
    route: { RouteStep },
    fromPosition: Vector3,
    targetPosition: Vector3,
    poiName: string?
): Vector3
    local distance = (targetPosition - fromPosition).Magnitude
    if distance <= EPSILON then
        return fromPosition
    end

    table.insert(route, {
        type = "walk",
        targetPosition = targetPosition,
        distance = distance,
        dwellTime = nil,
        seatCFrame = nil,
        viewPosition = nil,
        poiName = poiName,
    })

    return targetPosition
end

local function smoothWalkPositions(fromPosition: Vector3, rawPositions: { Vector3 }): { Vector3 }
    if #rawPositions <= 1 then
        return rawPositions
    end

    local anchors: { Vector3 } = { fromPosition }
    for _, position in ipairs(rawPositions) do
        table.insert(anchors, position)
    end

    local output: { Vector3 } = {}
    local bevelDistance = math.max(0, tonumber(Config.PATH_CORNER_BEVEL_DISTANCE) or 4.5)
    local bevelSegments = math.max(0, math.floor(tonumber(Config.PATH_CORNER_BEVEL_SEGMENTS) or 2))

    for i = 2, #anchors - 1 do
        local prevPoint = anchors[i - 1]
        local cornerPoint = anchors[i]
        local nextPoint = anchors[i + 1]

        local inVector = cornerPoint - prevPoint
        local outVector = nextPoint - cornerPoint
        local inLength = inVector.Magnitude
        local outLength = outVector.Magnitude
        local insertedCorner = false

        if bevelDistance > 0 and inLength > EPSILON and outLength > EPSILON then
            local inDir = inVector.Unit
            local outDir = outVector.Unit
            local turnDot = math.clamp(inDir:Dot(outDir), -1, 1)

            if turnDot < 0.995 then
                local cut = math.min(bevelDistance, inLength * 0.35, outLength * 0.35)
                if cut > 0.05 then
                    local entry = cornerPoint - inDir * cut
                    local exit = cornerPoint + outDir * cut
                    table.insert(output, entry)

                    for segment = 1, bevelSegments do
                        local t = segment / (bevelSegments + 1)
                        local inv = 1 - t
                        local point = entry * (inv * inv) + cornerPoint * (2 * inv * t) + exit * (t * t)
                        table.insert(output, point)
                    end

                    table.insert(output, exit)
                    insertedCorner = true
                end
            end
        end

        if not insertedCorner then
            table.insert(output, cornerPoint)
        end
    end

    table.insert(output, anchors[#anchors])

    local filtered: { Vector3 } = {}
    local last = fromPosition
    for _, point in ipairs(output) do
        if (point - last).Magnitude > 0.05 then
            table.insert(filtered, point)
            last = point
        end
    end

    return filtered
end

local function appendPathAsWalk(
    route: { RouteStep },
    nodeGraph: any,
    path: { string },
    fromPosition: Vector3,
    finalOverride: Vector3?
): (Vector3, string?)
    local lastPosition = fromPosition
    local approachNodeId: string? = nil
    local rawPositions: { Vector3 } = {}

    for i = 2, #path do
        local nodeId = path[i]
        local position = nodeGraph.resolvePosition(nodeId)
        if i == #path and finalOverride then
            position = finalOverride
        end

        table.insert(rawPositions, position)

        if i == #path and #path >= 2 then
            approachNodeId = path[#path - 1]
        end
    end

    local smoothedPositions = smoothWalkPositions(fromPosition, rawPositions)
    local finalNode = nodeGraph.getNode(path[#path])
    local finalPOIName = if finalNode and finalNode.poi then finalNode.instance.Name else nil
    for _, position in ipairs(smoothedPositions) do
        local poiName = if position == smoothedPositions[#smoothedPositions] then finalPOIName else nil
        lastPosition = appendWalkStep(route, lastPosition, position, poiName)
    end

    return lastPosition, approachNodeId
end

local function releaseClaimedSeats(seatManager: any, claimedSeatIds: { string }): ()
    for _, seatId in ipairs(claimedSeatIds) do
        seatManager.releaseSeat(seatId)
    end
end

local function buildRouteWithPlan(
    spawnNodeId: string,
    poiPlan: { string },
    preferredDespawnId: string?,
    nodeGraph: any,
    seatManager: any
): RouteResult?
    local route: { RouteStep } = {}
    local seatClaims: { [number]: string } = {}
    local claimedSeatIds: { string } = {}

    local currentNodeId = spawnNodeId
    local previousApproachNodeId: string? = nil
    local startPosition = nodeGraph.resolvePosition(spawnNodeId)
    local lastPosition = startPosition

    for _, poiNodeId in ipairs(poiPlan) do
        local poiNode: NodeData? = nodeGraph.getNode(poiNodeId)
        if not poiNode or not poiNode.poi then
            continue
        end

        local poi = poiNode.poi
        if poi.poiType == "social" then
            local seatClaim: SeatClaim? = seatManager.claimSeat(poiNodeId)
            if not seatClaim then
                -- If seats are full, still route through the social POI as a walk-through
                -- so route lifetimes do not collapse under high occupancy.
                local fallbackPath = findLegPath(nodeGraph, currentNodeId, poiNodeId, previousApproachNodeId, nil)
                if fallbackPath then
                    lastPosition, previousApproachNodeId = appendPathAsWalk(route, nodeGraph, fallbackPath, lastPosition, nil)
                    currentNodeId = poiNodeId
                else
                    Diagnostics.increment("totalRejects", "no_path")
                    Diagnostics.increment("totalRejects", "poi_skip")
                end
                continue
            end

            local seatApproachNodeId = seatClaim.approachNodeId or poiNodeId
            local legPath = findLegPath(nodeGraph, currentNodeId, seatApproachNodeId, previousApproachNodeId, poiNodeId)
            if not legPath then
                seatManager.releaseSeat(seatClaim.seatId)
                local fallbackPath = findLegPath(nodeGraph, currentNodeId, poiNodeId, previousApproachNodeId, nil)
                if fallbackPath then
                    lastPosition, previousApproachNodeId = appendPathAsWalk(route, nodeGraph, fallbackPath, lastPosition, nil)
                    currentNodeId = poiNodeId
                else
                    Diagnostics.increment("totalRejects", "no_path")
                    Diagnostics.increment("totalRejects", "poi_skip")
                end
                continue
            end

            table.insert(claimedSeatIds, seatClaim.seatId)
            local seatYOffset = tonumber(Config.SOCIAL_SEAT_HEIGHT_OFFSET) or 0
            local adjustedSeatCFrame = seatClaim.cframe + Vector3.new(0, seatYOffset, 0)
            lastPosition, previousApproachNodeId = appendPathAsWalk(
                route,
                nodeGraph,
                legPath,
                lastPosition,
                adjustedSeatCFrame.Position
            )

            local dwellTime = randomFloat(
                tonumber(Config.SOCIAL_DWELL_MIN) or 8,
                tonumber(Config.SOCIAL_DWELL_MAX) or 20
            )

            local socialStepIndex = #route + 1
            table.insert(route, {
                type = "social",
                targetPosition = adjustedSeatCFrame.Position,
                distance = 0,
                dwellTime = dwellTime,
                seatCFrame = adjustedSeatCFrame,
                viewPosition = nil,
                poiName = poiNode.instance.Name,
            })

            seatClaims[socialStepIndex] = seatClaim.seatId
            currentNodeId = seatApproachNodeId
        else
            local legPath = findLegPath(nodeGraph, currentNodeId, poiNodeId, previousApproachNodeId, nil)
            if not legPath then
                Diagnostics.increment("totalRejects", "no_path")
                Diagnostics.increment("totalRejects", "poi_skip")
                continue
            end

            if poi.poiType == "scenic" then
                local scenicStandPosition = randomPointOnPartXZ(poiNode.instance)
                lastPosition, previousApproachNodeId = appendPathAsWalk(
                    route,
                    nodeGraph,
                    legPath,
                    lastPosition,
                    scenicStandPosition
                )

                local dwellTime = randomFloat(
                    tonumber(Config.SCENIC_DWELL_MIN) or 4,
                    tonumber(Config.SCENIC_DWELL_MAX) or 10
                )

                table.insert(route, {
                    type = "scenic",
                    targetPosition = lastPosition,
                    distance = 0,
                    dwellTime = dwellTime,
                    seatCFrame = nil,
                    viewPosition = resolveScenicViewPosition(poiNode),
                    poiName = poiNode.instance.Name,
                })
            else
                lastPosition, previousApproachNodeId = appendPathAsWalk(route, nodeGraph, legPath, lastPosition, nil)
            end

            currentNodeId = poiNodeId
        end
    end

    local despawnCandidates: { NodeData } = {}
    if preferredDespawnId then
        local preferredNode = nodeGraph.getNode(preferredDespawnId)
        if preferredNode and preferredNode.nodeRole == "despawn" then
            table.insert(despawnCandidates, preferredNode)
        end
    else
        despawnCandidates = copyAndShuffle(nodeGraph.getDespawnNodes())
    end

    local selectedPath: { string }? = nil
    for _, despawnNode: NodeData in ipairs(despawnCandidates) do
        selectedPath = findLegPath(nodeGraph, currentNodeId, despawnNode.id, previousApproachNodeId, nil)
        if selectedPath then
            break
        end
    end

    if not selectedPath then
        releaseClaimedSeats(seatManager, claimedSeatIds)
        Diagnostics.increment("totalRejects", "no_route")
        return nil
    end

    lastPosition, previousApproachNodeId = appendPathAsWalk(route, nodeGraph, selectedPath, lastPosition, nil)
    table.insert(route, {
        type = "despawn",
        targetPosition = lastPosition,
        distance = 0,
        dwellTime = randomFloat(
            tonumber(Config.DESPAWN_DWELL_MIN) or 0,
            tonumber(Config.DESPAWN_DWELL_MAX) or tonumber(Config.DESPAWN_LINGER) or 0
        ),
        seatCFrame = nil,
        viewPosition = nil,
        poiName = nil,
    })

    local stepDurations, cumulativeTimes, totalDuration = computeTimings(route, tonumber(Config.BASE_WALK_SPEED) or 10)
    if #route == 0 or totalDuration <= 0 then
        releaseClaimedSeats(seatManager, claimedSeatIds)
        Diagnostics.increment("totalRejects", "no_route")
        return nil
    end

    return {
        route = route,
        stepDurations = stepDurations,
        cumulativeTimes = cumulativeTimes,
        totalDuration = totalDuration,
        startPosition = startPosition,
        spawnNodeId = spawnNodeId,
        seatClaims = seatClaims,
    }
end

function RouteBuilder.buildRoute(nodeGraph: any, seatManager: any): RouteResult?
    local spawnNodes: { NodeData } = nodeGraph.getSpawnNodes()
    if #spawnNodes == 0 then
        Diagnostics.increment("totalRejects", "no_route")
        return nil
    end

    local spawnNode = spawnNodes[math.random(1, #spawnNodes)]
    local poiMin = math.max(0, math.floor(tonumber(Config.MIN_POIS_PER_ROUTE) or 2))
    local poiMax = math.max(poiMin, math.floor(tonumber(Config.MAX_POIS_PER_ROUTE) or 4))
    local poiCount = randomInt(poiMin, poiMax)
    local poiPlan = buildWeightedPOISequence(nodeGraph, poiCount)

    return buildRouteWithPlan(spawnNode.id, poiPlan, nil, nodeGraph, seatManager)
end

function RouteBuilder.buildGroupRoute(count: number, nodeGraph: any, seatManager: any): { RouteResult }?
    local groupSize = math.max(1, math.floor(count))
    local spawnNodes: { NodeData } = nodeGraph.getSpawnNodes()
    local despawnNodes: { NodeData } = nodeGraph.getDespawnNodes()
    if #spawnNodes == 0 or #despawnNodes == 0 then
        Diagnostics.increment("totalRejects", "no_route")
        return nil
    end

    local spawnNode = spawnNodes[math.random(1, #spawnNodes)]
    local despawnNode = despawnNodes[math.random(1, #despawnNodes)]

    local poiMin = math.max(0, math.floor(tonumber(Config.MIN_POIS_PER_ROUTE) or 2))
    local poiMax = math.max(poiMin, math.floor(tonumber(Config.MAX_POIS_PER_ROUTE) or 4))
    local poiCount = randomInt(poiMin, poiMax)
    local poiPlan = buildWeightedPOISequence(nodeGraph, poiCount)

    local results: { RouteResult } = {}
    for _ = 1, groupSize do
        local member = buildRouteWithPlan(spawnNode.id, poiPlan, despawnNode.id, nodeGraph, seatManager)
        if not member then
            for _, existing in ipairs(results) do
                for _, seatId in pairs(existing.seatClaims) do
                    seatManager.releaseSeat(seatId)
                end
            end
            return nil
        end
        table.insert(results, member)
    end

    return results
end

return RouteBuilder
