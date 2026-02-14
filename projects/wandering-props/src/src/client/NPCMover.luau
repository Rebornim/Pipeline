--!strict

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local sharedFolder = ReplicatedStorage:WaitForChild("WanderingProps")
local Config = require(sharedFolder:WaitForChild("Config"))
local NPCAnimator = require(script.Parent:WaitForChild("NPCAnimator"))

type RouteStep = {
    type: "walk" | "scenic" | "social" | "despawn",
    targetPosition: Vector3,
    distance: number,
    dwellTime: number?,
    seatCFrame: CFrame?,
    viewPosition: Vector3?,
    poiName: string?,
}

type AnimatorHandle = {
    animator: Animator,
    walkTrack: AnimationTrack,
    idleTrack: AnimationTrack,
    sitTrack: AnimationTrack,
}

type ClientNPC = {
    npcId: string,
    model: Model,
    walkSpeed: number,
    route: { RouteStep },
    stepDurations: { number },
    cumulativeTimes: { number },
    startTime: number,
    startPosition: Vector3,
    animatorHandle: AnimatorHandle,
    currentStepType: string,
    virtualPosition: Vector3,
    lodTier: "near" | "low" | "mid" | "far",
    pathLateralOffset: number,
    groundPivotClearance: number,
}

local NPCMover = {}

type CurveCache = {
    b0: Vector3,
    b1: Vector3,
    b2: Vector3,
    b3: Vector3,
    sampleT: { number },
    sampleLength: { number },
    totalLength: number,
}

local movingNPCs: { [string]: ClientNPC } = {}
local positionCallback: ((string, Vector3) -> ())? = nil
local curveCacheByNpc: { [string]: { [number]: CurveCache } } = {}

local function farCullEnabled(): boolean
    return Config.LOD_ENABLE_FAR_CULL == true
end

local function getWorkspaceRootFolder(): Folder?
    local rootName = tostring(Config.WORKSPACE_ROOT_NAME)
    local rootInstance = Workspace:FindFirstChild(rootName)
    if rootInstance and rootInstance:IsA("Folder") then
        return rootInstance
    end

    if rootInstance then
        local fallbackName = rootName .. "_Folder"
        local fallback = Workspace:FindFirstChild(fallbackName)
        if fallback and fallback:IsA("Folder") then
            return fallback
        end
        local createdFallback = Instance.new("Folder")
        createdFallback.Name = fallbackName
        createdFallback.Parent = Workspace
        return createdFallback
    end

    local created = Instance.new("Folder")
    created.Name = rootName
    created.Parent = Workspace
    return created
end

local function getActiveNPCsFolder(): Folder?
    local root = getWorkspaceRootFolder()
    if not root then
        return nil
    end

    local activeName = tostring(Config.WORKSPACE_ACTIVE_NPCS_FOLDER_NAME)
    local folder = root:FindFirstChild(activeName)
    if folder and folder:IsA("Folder") then
        return folder
    end

    local created = Instance.new("Folder")
    created.Name = if folder then activeName .. "_Folder" else activeName
    created.Parent = root
    return created
end

local function isCharacterPart(part: BasePart): boolean
    local model = part:FindFirstAncestorOfClass("Model")
    if not model then
        return false
    end
    return Players:GetPlayerFromCharacter(model) ~= nil
end

local function isNPCPart(part: BasePart): boolean
    local model = part:FindFirstAncestorOfClass("Model")
    if not model then
        return false
    end
    return model:GetAttribute("WP_ModelIndex") ~= nil
end

local function groundSnap(position: Vector3, ignoreModel: Model?, pivotClearance: number?): Vector3
    local origin = position + Vector3.new(0, math.max(1, tonumber(Config.GROUND_SNAP_HEIGHT) or 5), 0)
    local distance = math.max(1, tonumber(Config.GROUND_SNAP_DISTANCE) or 10)

    local exclusions: { Instance } = {}
    local root = getWorkspaceRootFolder()
    if root then
        local nodes = root:FindFirstChild(Config.WORKSPACE_NODES_FOLDER_NAME)
        if nodes then
            table.insert(exclusions, nodes)
        end

        local active = root:FindFirstChild(Config.WORKSPACE_ACTIVE_NPCS_FOLDER_NAME)
            or root:FindFirstChild(tostring(Config.WORKSPACE_ACTIVE_NPCS_FOLDER_NAME) .. "_Folder")
        if active then
            table.insert(exclusions, active)
        end
    end

    for _, player in ipairs(Players:GetPlayers()) do
        if player.Character then
            table.insert(exclusions, player.Character)
        end
    end
    if ignoreModel then
        table.insert(exclusions, ignoreModel)
    end

    for _ = 1, 4 do
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances = exclusions
        params.IgnoreWater = true

        local result = Workspace:Raycast(origin, Vector3.new(0, -distance, 0), params)
        if not result then
            break
        end

        local hit = result.Instance
        if CollectionService:HasTag(hit, Config.TAG_NODE) or isCharacterPart(hit) or isNPCPart(hit) then
            local container = hit:FindFirstAncestorOfClass("Model")
            if container then
                table.insert(exclusions, container)
            else
                table.insert(exclusions, hit)
            end
        else
            local clearance = math.max(0, tonumber(Config.GROUND_SNAP_CLEARANCE) or 0)
                + math.max(0, pivotClearance or 0)
            return Vector3.new(position.X, result.Position.Y + clearance, position.Z)
        end
    end

    return position
end

local function computeGroundPivotClearance(model: Model): number
    local pivot = model:GetPivot()
    local minLocalY = math.huge
    for _, descendant in ipairs(model:GetDescendants()) do
        if descendant:IsA("BasePart") then
            local localCenter = pivot:PointToObjectSpace(descendant.Position)
            local bottomY = localCenter.Y - descendant.Size.Y * 0.5
            if bottomY < minLocalY then
                minLocalY = bottomY
            end
        end
    end

    if minLocalY == math.huge then
        return 0
    end

    return math.max(0, -minLocalY)
end

local function stableUnitFromId(id: string): number
    local hash = 2166136261
    for i = 1, #id do
        hash = bit32.bxor(hash, string.byte(id, i))
        hash = (hash * 16777619) % 4294967296
    end
    return (hash % 10000) / 9999
end

local function binarySearchStep(cumulativeTimes: { number }, elapsed: number): number
    local count = #cumulativeTimes
    if count == 0 then
        return 0
    end

    local left = 1
    local right = count
    local answer = count

    while left <= right do
        local mid = math.floor((left + right) * 0.5)
        local value = cumulativeTimes[mid]
        if elapsed <= value then
            answer = mid
            right = mid - 1
        else
            left = mid + 1
        end
    end

    return answer
end

local function playForStep(npc: ClientNPC, stepType: string): ()
    if npc.lodTier == "mid" or npc.lodTier == "far" then
        NPCAnimator.setEnabled(npc.animatorHandle, false)
        return
    end

    NPCAnimator.setEnabled(npc.animatorHandle, true)
    local steppedFps = if npc.lodTier == "low" then math.max(1, math.floor(tonumber(Config.LOD_LOW_ANIMATION_FPS) or 10)) else nil

    if stepType == "walk" then
        NPCAnimator.playWalk(npc.animatorHandle, npc.walkSpeed, 1, steppedFps)
    elseif stepType == "scenic" then
        NPCAnimator.playIdle(npc.animatorHandle, 1, steppedFps)
    elseif stepType == "social" then
        NPCAnimator.playSit(npc.animatorHandle, 1, steppedFps)
    else
        NPCAnimator.stopAll(npc.animatorHandle)
    end
end

local function applyTierState(npc: ClientNPC): ()
    if npc.lodTier == "far" then
        if farCullEnabled() then
            npc.model.Parent = nil
        else
            local activeFolder = getActiveNPCsFolder()
            if activeFolder then
                npc.model.Parent = activeFolder
            end
        end
        NPCAnimator.setEnabled(npc.animatorHandle, false)
        return
    end

    local activeFolder = getActiveNPCsFolder()
    if activeFolder then
        npc.model.Parent = activeFolder
    end

    if npc.lodTier == "mid" then
        NPCAnimator.setEnabled(npc.animatorHandle, false)
        return
    end

    playForStep(npc, npc.currentStepType)
end

local function shouldUpdateVisual(npc: ClientNPC): boolean
    if npc.lodTier == "far" and farCullEnabled() then
        return false
    end

    return true
end

local function flatDirection(fromPosition: Vector3, toPosition: Vector3): Vector3?
    local delta = toPosition - fromPosition
    local flat = Vector3.new(delta.X, 0, delta.Z)
    if flat.Magnitude <= 0.001 then
        return nil
    end
    return flat.Unit
end

local function cubicBezierPoint(b0: Vector3, b1: Vector3, b2: Vector3, b3: Vector3, t: number): Vector3
    local t2 = t * t
    local t3 = t2 * t
    local inv = 1 - t
    local inv2 = inv * inv
    local inv3 = inv2 * inv
    return b0 * inv3 + b1 * (3 * inv2 * t) + b2 * (3 * inv * t2) + b3 * t3
end

local function nearlyEqual(a: Vector3, b: Vector3): boolean
    return (a - b).Magnitude <= 0.001
end

local function findDistinctRoutePoint(
    npc: ClientNPC,
    startIndex: number,
    stepDelta: number,
    reference: Vector3
): Vector3?
    local index = startIndex
    while index >= 1 and index <= #npc.route do
        local candidate = npc.route[index].targetPosition
        if not nearlyEqual(candidate, reference) then
            return candidate
        end
        index += stepDelta
    end
    return nil
end

local function evaluateCurve(cache: CurveCache, t: number): Vector3
    return cubicBezierPoint(cache.b0, cache.b1, cache.b2, cache.b3, t)
end

local function buildCurveCache(npc: ClientNPC, stepIndex: number, fromPosition: Vector3, toPosition: Vector3): CurveCache
    local prevPoint = findDistinctRoutePoint(npc, stepIndex - 1, -1, fromPosition)
    local nextPoint = findDistinctRoutePoint(npc, stepIndex + 1, 1, toPosition)

    local segment = toPosition - fromPosition
    local segmentLength = segment.Magnitude
    local dirCurrent = if segmentLength > 0.001 then segment.Unit else Vector3.new(1, 0, 0)

    local startTangent = dirCurrent
    if prevPoint then
        local prevVector = fromPosition - prevPoint
        if prevVector.Magnitude > 0.001 then
            local sum = prevVector.Unit + dirCurrent
            if sum.Magnitude > 0.001 then
                startTangent = sum.Unit
            end
        end
    end

    local endTangent = dirCurrent
    if nextPoint then
        local nextVector = nextPoint - toPosition
        if nextVector.Magnitude > 0.001 then
            local sum = dirCurrent + nextVector.Unit
            if sum.Magnitude > 0.001 then
                endTangent = sum.Unit
            end
        end
    end

    local curveStrength = math.clamp(tonumber(Config.PATH_CURVE_STRENGTH) or 0.22, 0, 1)
    local handleLength = segmentLength * (0.5 * curveStrength)
    local b1 = fromPosition + startTangent * handleLength
    local b2 = toPosition - endTangent * handleLength

    local samples = math.max(6, math.floor(tonumber(Config.PATH_CURVE_SAMPLES) or 18))

    local sampleT: { number } = table.create(samples + 1, 0)
    local sampleLength: { number } = table.create(samples + 1, 0)

    local cache: CurveCache = {
        b0 = fromPosition,
        b1 = b1,
        b2 = b2,
        b3 = toPosition,
        sampleT = sampleT,
        sampleLength = sampleLength,
        totalLength = 0,
    }

    sampleT[1] = 0
    sampleLength[1] = 0
    local prev = evaluateCurve(cache, 0)
    local total = 0

    for i = 2, samples + 1 do
        local t = (i - 1) / samples
        local point = evaluateCurve(cache, t)
        total += (point - prev).Magnitude
        sampleT[i] = t
        sampleLength[i] = total
        prev = point
    end

    cache.totalLength = total
    return cache
end

local function getCurveCache(npc: ClientNPC, stepIndex: number, fromPosition: Vector3, toPosition: Vector3): CurveCache
    local npcCache = curveCacheByNpc[npc.npcId]
    if not npcCache then
        npcCache = {}
        curveCacheByNpc[npc.npcId] = npcCache
    end

    local existing = npcCache[stepIndex]
    if existing and nearlyEqual(existing.b0, fromPosition) and nearlyEqual(existing.b3, toPosition) then
        return existing
    end

    local created = buildCurveCache(npc, stepIndex, fromPosition, toPosition)
    npcCache[stepIndex] = created
    return created
end

local function remapProgressByArcLength(cache: CurveCache, progress: number): number
    local clamped = math.clamp(progress, 0, 1)
    if cache.totalLength <= 0.001 then
        return clamped
    end

    local targetLength = clamped * cache.totalLength
    for i = 2, #cache.sampleLength do
        local leftLen = cache.sampleLength[i - 1]
        local rightLen = cache.sampleLength[i]
        if targetLength <= rightLen then
            local span = rightLen - leftLen
            local alpha = if span > 0.0001 then (targetLength - leftLen) / span else 0
            return cache.sampleT[i - 1] + (cache.sampleT[i] - cache.sampleT[i - 1]) * alpha
        end
    end

    return 1
end

local function curvedWalkPosition(
    npc: ClientNPC,
    stepIndex: number,
    fromPosition: Vector3,
    toPosition: Vector3,
    progress: number
): Vector3
    local cache = getCurveCache(npc, stepIndex, fromPosition, toPosition)
    local t = remapProgressByArcLength(cache, progress)
    return evaluateCurve(cache, t)
end

local function computeWalkChainAlpha(npc: ClientNPC, stepIndex: number, stepProgress: number): number
    if stepIndex < 1 or stepIndex > #npc.route then
        return math.clamp(stepProgress, 0, 1)
    end

    local currentStep = npc.route[stepIndex]
    if not currentStep or currentStep.type ~= "walk" then
        return math.clamp(stepProgress, 0, 1)
    end

    local chainStart = stepIndex
    while chainStart > 1 and npc.route[chainStart - 1].type == "walk" do
        chainStart -= 1
    end

    local chainEnd = stepIndex
    while chainEnd < #npc.route and npc.route[chainEnd + 1].type == "walk" do
        chainEnd += 1
    end

    local totalDistance = 0
    local progressDistance = 0
    local clampedStepProgress = math.clamp(stepProgress, 0, 1)

    for index = chainStart, chainEnd do
        local step = npc.route[index]
        local distance = math.max(0, step.distance or 0)
        totalDistance += distance

        if index < stepIndex then
            progressDistance += distance
        elseif index == stepIndex then
            progressDistance += distance * clampedStepProgress
        end
    end

    if totalDistance <= 0.001 then
        return clampedStepProgress
    end

    return math.clamp(progressDistance / totalDistance, 0, 1)
end

local function applyWalkLateralOffset(
    npc: ClientNPC,
    stepIndex: number,
    fromPosition: Vector3,
    toPosition: Vector3,
    progress: number,
    position: Vector3
): Vector3
    if math.abs(npc.pathLateralOffset) <= 0.0001 then
        return position
    end

    local direction = flatDirection(fromPosition, toPosition)
    if not direction then
        return position
    end

    local side = Vector3.new(-direction.Z, 0, direction.X)
    local chainAlpha = computeWalkChainAlpha(npc, stepIndex, progress)
    local envelope = math.sin(math.pi * chainAlpha)
    return position + side * (npc.pathLateralOffset * envelope)
end

local function getWalkStepEndpoints(npc: ClientNPC, stepIndex: number): (Vector3?, Vector3?)
    local step = npc.route[stepIndex]
    if not step or step.type ~= "walk" then
        return nil
    end

    local fromPosition = if stepIndex == 1 then npc.startPosition else npc.route[stepIndex - 1].targetPosition
    local toPosition = step.targetPosition
    return fromPosition, toPosition
end

local function walkLookAheadPosition(npc: ClientNPC, stepIndex: number, progress: number): Vector3?
    local fromPosition, toPosition = getWalkStepEndpoints(npc, stepIndex)
    if not fromPosition or not toPosition then
        return nil
    end

    local lookAhead = math.clamp(tonumber(Config.PATH_LOOKAHEAD_FRACTION) or 0.14, 0.02, 0.75)
    local advanced = progress + lookAhead
    if advanced <= 1 then
        local curved = curvedWalkPosition(npc, stepIndex, fromPosition, toPosition, advanced)
        return applyWalkLateralOffset(npc, stepIndex, fromPosition, toPosition, advanced, curved)
    end

    local overflow = advanced - 1
    local nextFromPosition, nextToPosition = getWalkStepEndpoints(npc, stepIndex + 1)
    if nextFromPosition and nextToPosition then
        local curved = curvedWalkPosition(npc, stepIndex + 1, nextFromPosition, nextToPosition, overflow)
        return applyWalkLateralOffset(npc, stepIndex + 1, nextFromPosition, nextToPosition, overflow, curved)
    end

    return toPosition
end

local function pivotLookAt(model: Model, position: Vector3, lookTarget: Vector3?, deltaTime: number): ()
    local target = lookTarget
    if not target then
        local forward = model:GetPivot().LookVector
        target = position + Vector3.new(forward.X, 0, forward.Z)
    end

    local desiredDirection = flatDirection(position, Vector3.new(target.X, position.Y, target.Z))
    if not desiredDirection then
        local currentForward = model:GetPivot().LookVector
        desiredDirection = flatDirection(position, position + Vector3.new(currentForward.X, 0, currentForward.Z))
    end

    if not desiredDirection then
        model:PivotTo(CFrame.new(position))
        return
    end

    local currentLook = model:GetPivot().LookVector
    local currentDirection = flatDirection(position, position + Vector3.new(currentLook.X, 0, currentLook.Z)) or desiredDirection

    local turnSpeed = math.max(0.1, tonumber(Config.TURN_SMOOTH_SPEED) or 10)
    local alpha = 1 - math.exp(-turnSpeed * math.max(0, deltaTime))
    local blended = currentDirection:Lerp(desiredDirection, alpha)
    if blended.Magnitude <= 0.001 then
        blended = desiredDirection
    else
        blended = blended.Unit
    end

    model:PivotTo(CFrame.lookAt(position, position + blended))
end

local function updateNPC(npc: ClientNPC, deltaTime: number): ()
    local elapsed = math.max(0, os.clock() - npc.startTime)
    local stepIndex = binarySearchStep(npc.cumulativeTimes, elapsed)
    if stepIndex <= 0 then
        return
    end

    local step = npc.route[stepIndex]
    if not step then
        return
    end

    if step.type ~= npc.currentStepType then
        npc.currentStepType = step.type
        playForStep(npc, step.type)
    end

    local stepStart = if stepIndex > 1 then npc.cumulativeTimes[stepIndex - 1] else 0
    local stepDuration = npc.stepDurations[stepIndex] or 0
    local progress = if stepDuration <= 0 then 1 else math.clamp((elapsed - stepStart) / stepDuration, 0, 1)

    local position = step.targetPosition
    local lookTarget: Vector3? = nil

    if step.type == "walk" then
        local fromPosition = if stepIndex == 1 then npc.startPosition else npc.route[stepIndex - 1].targetPosition
        local curved = curvedWalkPosition(npc, stepIndex, fromPosition, step.targetPosition, progress)
        position = applyWalkLateralOffset(npc, stepIndex, fromPosition, step.targetPosition, progress, curved)
        position = groundSnap(position, npc.model, npc.groundPivotClearance)
        lookTarget = walkLookAheadPosition(npc, stepIndex, progress) or step.targetPosition
    elseif step.type == "scenic" then
        lookTarget = step.viewPosition
    elseif step.type == "social" and step.seatCFrame then
        position = step.seatCFrame.Position
    end

    npc.virtualPosition = position
    if positionCallback then
        positionCallback(npc.npcId, position)
    end

    if not shouldUpdateVisual(npc) then
        return
    end

    if step.type == "social" and step.seatCFrame then
        npc.model:PivotTo(step.seatCFrame)
        return
    end

    pivotLookAt(npc.model, position, lookTarget, deltaTime)
end

function NPCMover.startMoving(npcId: string, clientNPC: ClientNPC, stepIndex: number?, stepElapsed: number?): ()
    local offsetTime = 0
    if stepIndex and stepIndex > 1 then
        offsetTime += clientNPC.cumulativeTimes[stepIndex - 1] or 0
    end
    if stepElapsed and stepElapsed > 0 then
        offsetTime += stepElapsed
    end

    local lateralOffsetMax = math.max(0, tonumber(Config.PATH_LATERAL_OFFSET_MAX) or 0)
    if lateralOffsetMax > 0 then
        clientNPC.pathLateralOffset = (stableUnitFromId(npcId) * 2 - 1) * lateralOffsetMax
    else
        clientNPC.pathLateralOffset = 0
    end
    clientNPC.groundPivotClearance = computeGroundPivotClearance(clientNPC.model)

    clientNPC.startTime = os.clock() - offsetTime
    clientNPC.currentStepType = ""
    curveCacheByNpc[npcId] = nil
    movingNPCs[npcId] = clientNPC
    applyTierState(clientNPC)
end

function NPCMover.stopMoving(npcId: string): ()
    movingNPCs[npcId] = nil
    curveCacheByNpc[npcId] = nil
end

function NPCMover.setLODTier(npcId: string, tier: "near" | "low" | "mid" | "far"): ()
    local npc = movingNPCs[npcId]
    if not npc then
        return
    end

    local previousTier = npc.lodTier
    if previousTier == tier then
        return
    end

    npc.lodTier = tier
    applyTierState(npc)

    if previousTier == "far" and tier ~= "far" then
        updateNPC(npc, 0)
    end
end

function NPCMover.setPositionCallback(callback: ((string, Vector3) -> ())?): ()
    positionCallback = callback
end

function NPCMover.getVirtualPosition(npcId: string): Vector3?
    local npc = movingNPCs[npcId]
    if npc then
        return npc.virtualPosition
    end
    return nil
end

function NPCMover.refreshVisual(npcId: string): ()
    local npc = movingNPCs[npcId]
    if not npc then
        return
    end

    applyTierState(npc)
    updateNPC(npc, 0)
end

RunService.Heartbeat:Connect(function(deltaTime)
    for _, npc in pairs(movingNPCs) do
        updateNPC(npc, deltaTime)
    end
end)

return NPCMover
