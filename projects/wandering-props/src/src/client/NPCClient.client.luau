--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local sharedFolder = ReplicatedStorage:WaitForChild("WanderingProps")
local Config = require(sharedFolder:WaitForChild("Config"))

local NPCMover = require(script.Parent:WaitForChild("NPCMover"))
local NPCAnimator = require(script.Parent:WaitForChild("NPCAnimator"))

local modelPoolModule = script.Parent:FindFirstChild("ModelPool")
local lodControllerModule = script.Parent:FindFirstChild("LODController")

local ModelPool = if modelPoolModule and modelPoolModule:IsA("ModuleScript") then require(modelPoolModule) else nil
local LODController = if lodControllerModule and lodControllerModule:IsA("ModuleScript") then require(lodControllerModule) else nil
local useModelPool = ModelPool ~= nil and Config.MODEL_POOL_ENABLED == true

type RouteStep = {
    type: "walk" | "scenic" | "social" | "despawn",
    targetPosition: Vector3,
    distance: number,
    dwellTime: number?,
    seatCFrame: CFrame?,
    viewPosition: Vector3?,
    poiName: string?,
}

type PackedRouteStep = { [number]: any }

type AnimatorHandle = {
    animator: Animator,
    walkTrack: AnimationTrack,
    idleTrack: AnimationTrack,
    sitTrack: AnimationTrack,
}

type ClientNPC = {
    npcId: string,
    model: Model,
    modelIndex: number,
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
    repairAttempts: number,
}

type SpawnPayload = {
    npcId: string,
    modelIndex: number,
    walkSpeed: number,
    route: { RouteStep }?,
    routePacked: { PackedRouteStep }?,
    startPosition: Vector3,
}

type DespawnPayload = {
    npcId: string,
}

type BulkSyncEntry = {
    npcId: string,
    modelIndex: number,
    walkSpeed: number,
    route: { RouteStep }?,
    routePacked: { PackedRouteStep }?,
    startPosition: Vector3,
    currentStepIndex: number,
    stepElapsed: number,
}

local activeNPCs: { [string]: ClientNPC } = {}
local modelOwnerByInstance: { [Model]: string } = {}
local modelTemplates: { Model } = {}
local reconcileAccumulator = 0

local globalState = _G :: any
local clientLockKey = "__WP_ClientNPCControllerLock"
local existingClientPath = globalState[clientLockKey]
if existingClientPath and existingClientPath ~= script:GetFullName() then
    warn(string.format(
        "[WP][CLIENT] Duplicate NPCClient detected. Active='%s' Ignoring='%s'",
        tostring(existingClientPath),
        script:GetFullName()
    ))
    return
end
globalState[clientLockKey] = script:GetFullName()

print(string.format("[WP] Client build: %s", tostring(Config.BUILD_SIGNATURE)))
print(string.format("[WP] Client script path: %s", script:GetFullName()))

local function ensureWorkspaceFolders(): Folder
    local rootName = tostring(Config.WORKSPACE_ROOT_NAME)
    local rootInstance = Workspace:FindFirstChild(rootName)
    local rootFolder: Folder
    if rootInstance and rootInstance:IsA("Folder") then
        rootFolder = rootInstance
    else
        if rootInstance then
            local fallbackName = rootName .. "_Folder"
            warn(string.format(
                "[WP][CLIENT] Workspace.%s exists but is not a Folder (%s). Using %s instead.",
                rootName,
                rootInstance.ClassName,
                fallbackName
            ))
            local fallback = Workspace:FindFirstChild(fallbackName)
            if fallback and fallback:IsA("Folder") then
                rootFolder = fallback
            else
                rootFolder = Instance.new("Folder")
                rootFolder.Name = fallbackName
                rootFolder.Parent = Workspace
            end
        else
            rootFolder = Instance.new("Folder")
            rootFolder.Name = rootName
            rootFolder.Parent = Workspace
        end
    end

    local activeName = tostring(Config.WORKSPACE_ACTIVE_NPCS_FOLDER_NAME)
    local activeInstance = rootFolder:FindFirstChild(activeName)
    if activeInstance and activeInstance:IsA("Folder") then
        return activeInstance
    end

    if activeInstance then
        local fallbackActiveName = activeName .. "_Folder"
        warn(string.format(
            "[WP][CLIENT] %s.%s exists but is not a Folder (%s). Using %s instead.",
            rootFolder:GetFullName(),
            activeName,
            activeInstance.ClassName,
            fallbackActiveName
        ))
        local fallback = rootFolder:FindFirstChild(fallbackActiveName)
        if fallback and fallback:IsA("Folder") then
            return fallback
        end
        local createdFallback = Instance.new("Folder")
        createdFallback.Name = fallbackActiveName
        createdFallback.Parent = rootFolder
        return createdFallback
    end

    local created = Instance.new("Folder")
    created.Name = activeName
    created.Parent = rootFolder
    return created
end

local function clearFolderModels(folder: Folder): ()
    for _, child in ipairs(folder:GetChildren()) do
        if child:IsA("Model") then
            child:Destroy()
        end
    end
end

local function warnIfDuplicateClientScripts(): ()
    local localPlayer = Players.LocalPlayer
    if not localPlayer then
        return
    end

    local playerScripts = localPlayer:FindFirstChildOfClass("PlayerScripts")
        or localPlayer:WaitForChild("PlayerScripts", 10)
    if not playerScripts then
        return
    end

    local npcClientScripts: { string } = {}
    for _, descendant in ipairs(playerScripts:GetDescendants()) do
        if descendant:IsA("LocalScript") and descendant.Name == script.Name then
            table.insert(npcClientScripts, descendant:GetFullName())
        end
    end

    if #npcClientScripts > 1 then
        warn(string.format(
            "[WP][CLIENT] Multiple '%s' LocalScripts detected (%d). This can cause conflicting visual state:",
            script.Name,
            #npcClientScripts
        ))
        table.sort(npcClientScripts)
        for _, fullName in ipairs(npcClientScripts) do
            warn(string.format("[WP][CLIENT] - %s", fullName))
        end
    end
end

local function disableCompetingClientScripts(): ()
    local localPlayer = Players.LocalPlayer
    if not localPlayer then
        return
    end

    local playerScripts = localPlayer:FindFirstChildOfClass("PlayerScripts")
        or localPlayer:WaitForChild("PlayerScripts", 10)
    if not playerScripts then
        return
    end

    for _, descendant in ipairs(playerScripts:GetDescendants()) do
        if not descendant:IsA("LocalScript") then
            continue
        end
        if descendant == script then
            continue
        end
        if descendant.Name == script.Name or descendant.Name == "NPCClient" then
            descendant.Disabled = true
            warn(string.format(
                "[WP][CLIENT] Disabled competing client script: %s",
                descendant:GetFullName()
            ))
        end
    end
end

local function collectModels(): { Model }
    local modelsFolder = ReplicatedStorage:WaitForChild(Config.MODELS_FOLDER_NAME)
    local list: { Model } = {}
    local indexed: { [number]: Model } = {}
    local unindexed: { Model } = {}
    local maxIndex = 0

    local attributeName = Config.MODEL_TEMPLATE_INDEX_ATTRIBUTE
    for _, child in ipairs(modelsFolder:GetChildren()) do
        if child:IsA("Model") then
            local attr = child:GetAttribute(attributeName)
            if typeof(attr) == "number" and attr >= 1 then
                local index = math.floor(attr)
                indexed[index] = child
                if index > maxIndex then
                    maxIndex = index
                end
            else
                table.insert(unindexed, child)
            end
        end
    end

    for index = 1, maxIndex do
        local model = indexed[index]
        if model then
            list[index] = model
        end
    end

    table.sort(unindexed, function(a, b)
        return a.Name < b.Name
    end)

    local appendIndex = 1
    for _, model in ipairs(unindexed) do
        while list[appendIndex] do
            appendIndex += 1
        end
        list[appendIndex] = model
        appendIndex += 1
    end

    if #list == 0 then
        warn("[WP] No Model templates found in ReplicatedStorage.WanderingPropModels")
    end

    return list
end

local function prepareModel(model: Model, modelIndex: number): ()
    model:SetAttribute("WP_ModelIndex", modelIndex)

    for _, descendant in ipairs(model:GetDescendants()) do
        if descendant:IsA("BasePart") then
            descendant.Anchored = false
            descendant.CanCollide = false
            descendant.CanTouch = false
            descendant.CanQuery = false
            descendant.LocalTransparencyModifier = 0
            descendant.AssemblyLinearVelocity = Vector3.zero
            descendant.AssemblyAngularVelocity = Vector3.zero
        elseif descendant:IsA("Script") or descendant:IsA("LocalScript") then
            descendant.Disabled = true
        end
    end
end

local function acquireModel(modelIndex: number): Model?
    if useModelPool and ModelPool then
        local model = ModelPool.acquire(modelIndex)
        return model
    end

    local template = modelTemplates[modelIndex]
    if not template then
        return nil
    end

    return template:Clone()
end

local function cloneModelFromTemplate(modelIndex: number): Model?
    local template = modelTemplates[modelIndex] or modelTemplates[1]
    if not template then
        return nil
    end

    local clone = template:Clone()
    clone:SetAttribute("WP_ModelIndex", modelIndex)
    return clone
end

local function acquireModelForNPC(modelIndex: number, npcId: string): Model?
    local model = acquireModel(modelIndex)
    if not model then
        return nil
    end

    local existingOwner = modelOwnerByInstance[model]
    if existingOwner and existingOwner ~= npcId then
        warn(string.format(
            "[WP][CLIENT] Model alias detected: npc '%s' received a model already owned by '%s'. Cloning fallback.",
            npcId,
            existingOwner
        ))
        local replacement = cloneModelFromTemplate(modelIndex)
        if replacement then
            model = replacement
        else
            warn(string.format(
                "[WP][CLIENT] Failed to clone fallback model for npc '%s'; keeping aliased model.",
                npcId
            ))
        end
    end

    return model
end

local function findOwnerByModel(model: Model, excludeNpcId: string?): string?
    for id, npc in pairs(activeNPCs) do
        if id ~= excludeNpcId and npc.model == model then
            return id
        end
    end
    return nil
end

local function releaseModel(model: Model): ()
    if useModelPool and ModelPool then
        ModelPool.release(model)
    else
        model:Destroy()
    end
end

local function computeTimings(route: { RouteStep }, walkSpeed: number): ({ number }, { number }, number)
    local durations: { number } = table.create(#route, 0)
    local cumulative: { number } = table.create(#route, 0)
    local total = 0
    local speed = math.max(0.001, walkSpeed)

    for i, step in ipairs(route) do
        local duration = 0
        if step.type == "walk" then
            duration = step.distance / speed
        elseif step.type == "scenic" or step.type == "social" then
            duration = math.max(0, step.dwellTime or 0)
        else
            duration = math.max(0, step.dwellTime or tonumber(Config.DESPAWN_LINGER) or 0)
        end

        durations[i] = duration
        total += duration
        cumulative[i] = total
    end

    return durations, cumulative, total
end

local STEP_CODE_TO_TYPE: { [number]: "walk" | "scenic" | "social" | "despawn" } = {
    [1] = "walk",
    [2] = "scenic",
    [3] = "social",
    [4] = "despawn",
}

local function normalizeRoute(rawRoute: { any }?, startPosition: Vector3): { RouteStep }
    if not rawRoute then
        return {}
    end

    local normalized: { RouteStep } = table.create(#rawRoute)
    local previousPosition = startPosition

    for _, rawStep in ipairs(rawRoute) do
        local stepType: "walk" | "scenic" | "social" | "despawn" = "walk"
        local targetPosition = previousPosition
        local dwellTime: number? = nil
        local seatCFrame: CFrame? = nil
        local viewPosition: Vector3? = nil
        local poiName: string? = nil
        local distance = 0

        if typeof(rawStep) == "table" then
            if rawStep.type ~= nil then
                local rawType = rawStep.type
                if rawType == "walk" or rawType == "scenic" or rawType == "social" or rawType == "despawn" then
                    stepType = rawType
                end
                if typeof(rawStep.targetPosition) == "Vector3" then
                    targetPosition = rawStep.targetPosition
                end
                if typeof(rawStep.dwellTime) == "number" then
                    dwellTime = rawStep.dwellTime
                end
                if typeof(rawStep.seatCFrame) == "CFrame" then
                    seatCFrame = rawStep.seatCFrame
                end
                if typeof(rawStep.viewPosition) == "Vector3" then
                    viewPosition = rawStep.viewPosition
                end
                if typeof(rawStep.poiName) == "string" then
                    poiName = rawStep.poiName
                end
                if typeof(rawStep.distance) == "number" then
                    distance = math.max(0, rawStep.distance)
                end
            else
                local code = rawStep[1]
                local decodedType = if typeof(code) == "number" then STEP_CODE_TO_TYPE[code] else nil
                if decodedType then
                    stepType = decodedType
                end
                if typeof(rawStep[2]) == "Vector3" then
                    targetPosition = rawStep[2]
                end
                if typeof(rawStep[3]) == "number" then
                    dwellTime = rawStep[3]
                end
                if typeof(rawStep[4]) == "CFrame" then
                    seatCFrame = rawStep[4]
                end
                if typeof(rawStep[5]) == "Vector3" then
                    viewPosition = rawStep[5]
                end
            end
        end

        if stepType == "walk" then
            distance = (targetPosition - previousPosition).Magnitude
        else
            distance = 0
        end
        previousPosition = targetPosition

        table.insert(normalized, {
            type = stepType,
            targetPosition = targetPosition,
            distance = distance,
            dwellTime = dwellTime,
            seatCFrame = seatCFrame,
            viewPosition = viewPosition,
            poiName = poiName,
        })
    end

    return normalized
end

local function cleanupNPC(npcId: string): ()
    local npc = activeNPCs[npcId]
    if not npc then
        return
    end

    if LODController then
        LODController.unregister(npcId)
    end

    NPCMover.stopMoving(npcId)
    NPCAnimator.cleanup(npc.animatorHandle)

    local owner = modelOwnerByInstance[npc.model]
    if owner == npcId then
        modelOwnerByInstance[npc.model] = nil
    elseif owner then
        warn(string.format(
            "[WP][CLIENT] Ownership mismatch while cleaning npc '%s' (model owned by '%s').",
            npcId,
            owner
        ))
    end

    releaseModel(npc.model)
    activeNPCs[npcId] = nil
end

local function getModelRenderState(model: Model): (boolean, boolean, boolean)
    local hasParts = false
    local hasRenderablePart = false
    local allAnchored = true

    for _, descendant in ipairs(model:GetDescendants()) do
        if descendant:IsA("BasePart") then
            hasParts = true
            if not descendant.Anchored then
                allAnchored = false
            end

            local effectiveTransparency = math.clamp(descendant.Transparency + descendant.LocalTransparencyModifier, 0, 1)
            if effectiveTransparency < 0.99 and descendant.Size.Magnitude > 0.001 then
                hasRenderablePart = true
            end
        end
    end

    return hasParts, hasRenderablePart, allAnchored
end

local function repairNPCModel(npc: ClientNPC, reason: string): boolean
    local replacement = acquireModelForNPC(npc.modelIndex, npc.npcId)
    if not replacement then
        warn(string.format("[WP][CLIENT] Failed to repair npc '%s' (%s): no replacement model.", npc.npcId, reason))
        return false
    end

    prepareModel(replacement, npc.modelIndex)

    local activeFolder = ensureWorkspaceFolders()
    if npc.lodTier == "far" and Config.LOD_ENABLE_FAR_CULL == true then
        replacement.Parent = nil
    else
        replacement.Parent = activeFolder
    end

    local position = NPCMover.getVirtualPosition(npc.npcId) or npc.virtualPosition
    replacement:PivotTo(CFrame.new(position))

    local newAnimatorHandle = NPCAnimator.setup(replacement)
    if not newAnimatorHandle then
        releaseModel(replacement)
        warn(string.format("[WP][CLIENT] Failed to repair npc '%s' (%s): animator setup failed.", npc.npcId, reason))
        return false
    end

    local oldModel = npc.model
    local oldAnimatorHandle = npc.animatorHandle

    npc.model = replacement
    npc.animatorHandle = newAnimatorHandle
    modelOwnerByInstance[replacement] = npc.npcId

    local owner = modelOwnerByInstance[oldModel]
    if owner == npc.npcId then
        modelOwnerByInstance[oldModel] = nil
    end

    NPCAnimator.cleanup(oldAnimatorHandle)
    releaseModel(oldModel)

    NPCMover.refreshVisual(npc.npcId)

    if Config.CLIENT_DEBUG_MODE == true then
        warn(string.format("[WP][CLIENT] Repaired npc '%s' model (%s).", npc.npcId, reason))
    end

    return true
end

local function spawnNPC(payload: SpawnPayload, stepIndex: number?, stepElapsed: number?): ()
    local route = normalizeRoute(payload.routePacked or payload.route, payload.startPosition)
    if #route == 0 then
        return
    end

    cleanupNPC(payload.npcId)

    local model = acquireModelForNPC(payload.modelIndex, payload.npcId)
    if not model then
        return
    end

    local trackedOwner = findOwnerByModel(model, payload.npcId)
    if trackedOwner then
        warn(string.format(
            "[WP][CLIENT] Prevented shared model instance between '%s' and '%s'; cloning dedicated replacement.",
            trackedOwner,
            payload.npcId
        ))
        local replacement = cloneModelFromTemplate(payload.modelIndex)
        if replacement then
            model = replacement
        end
    end

    prepareModel(model, payload.modelIndex)

    local activeFolder = ensureWorkspaceFolders()
    model.Parent = activeFolder
    model:PivotTo(CFrame.new(payload.startPosition))

    local animatorHandle = NPCAnimator.setup(model)
    if not animatorHandle then
        releaseModel(model)
        return
    end

    local stepDurations, cumulativeTimes = computeTimings(route, payload.walkSpeed)

    local clientNPC: ClientNPC = {
        npcId = payload.npcId,
        model = model,
        modelIndex = payload.modelIndex,
        walkSpeed = payload.walkSpeed,
        route = route,
        stepDurations = stepDurations,
        cumulativeTimes = cumulativeTimes,
        startTime = os.clock(),
        startPosition = payload.startPosition,
        animatorHandle = animatorHandle,
        currentStepType = "",
        virtualPosition = payload.startPosition,
        lodTier = "near",
        pathLateralOffset = 0,
        groundPivotClearance = 0,
        repairAttempts = 0,
    }

    modelOwnerByInstance[model] = payload.npcId
    activeNPCs[payload.npcId] = clientNPC

    NPCMover.startMoving(payload.npcId, clientNPC, stepIndex, stepElapsed)

    if LODController then
        LODController.register(payload.npcId, model)
    else
        NPCMover.setLODTier(payload.npcId, "near")
    end
end

local function onSpawn(payload: SpawnPayload): ()
    spawnNPC(payload, 1, 0)
end

local function onDespawn(payload: DespawnPayload): ()
    cleanupNPC(payload.npcId)
end

local function onBulkSync(payload: { npcs: { BulkSyncEntry } }): ()
    for _, entry in ipairs(payload.npcs) do
        spawnNPC({
            npcId = entry.npcId,
            modelIndex = entry.modelIndex,
            walkSpeed = entry.walkSpeed,
            route = entry.route,
            routePacked = entry.routePacked,
            startPosition = entry.startPosition,
        }, entry.currentStepIndex, entry.stepElapsed)
    end
end

local function reconcileClientState(): ()
    local activeFolder = ensureWorkspaceFolders()
    local trackedModels: { [Model]: boolean } = {}
    local trackedCount = 0
    local tierCounts = {
        near = 0,
        low = 0,
        mid = 0,
        far = 0,
    }
    local debugMode = Config.CLIENT_DEBUG_MODE == true
    local hiddenCount = 0
    local offworldCount = 0
    local destroyedRefCount = 0
    local anchoredModelCount = 0
    local duplicateModelRefs = 0
    local repairedModels = 0
    local seenByModel: { [Model]: string } = {}

    for _, npc in pairs(activeNPCs) do
        local hasParts, hasRenderablePart, allAnchored = getModelRenderState(npc.model)
        if (not hasParts or not hasRenderablePart) and npc.repairAttempts < 2 then
            npc.repairAttempts += 1
            local repaired = repairNPCModel(npc, if not hasParts then "no_parts" else "not_renderable")
            if repaired then
                repairedModels += 1
                hasParts, hasRenderablePart, allAnchored = getModelRenderState(npc.model)
            end
        end

        trackedCount += 1
        trackedModels[npc.model] = true
        tierCounts[npc.lodTier] += 1

        local seenOwner = seenByModel[npc.model]
        if seenOwner then
            duplicateModelRefs += 1
            if debugMode then
                warn(string.format(
                    "[WP][CLIENT] Duplicate model ref: npc '%s' and '%s' share one model instance.",
                    seenOwner,
                    npc.npcId
                ))
            end
        else
            seenByModel[npc.model] = npc.npcId
        end

        if npc.lodTier ~= "far" and npc.model.Parent ~= activeFolder then
            npc.model.Parent = activeFolder
        end

        if debugMode then
            local okPivot, pivot = pcall(function()
                return npc.model:GetPivot()
            end)

            if not okPivot then
                destroyedRefCount += 1
            else
                local position = pivot.Position
                if math.abs(position.X) > 50000 or math.abs(position.Z) > 50000 or position.Y < -1000 or position.Y > 20000 then
                    offworldCount += 1
                end

                if hasParts and allAnchored then
                    anchoredModelCount += 1
                end
                if hasParts and not hasRenderablePart then
                    hiddenCount += 1
                end
            end
        end
    end

    local folderModels = 0
    local orphanModels = 0
    for _, child in ipairs(activeFolder:GetChildren()) do
        if child:IsA("Model") then
            folderModels += 1
            if not trackedModels[child] then
                orphanModels += 1
                child:Destroy()
            end
        end
    end

    if debugMode then
        print(string.format(
            "[WP][CLIENT] tracked=%d folder=%d orphansCleaned=%d dupRefs=%d repaired=%d | tiers near=%d low=%d mid=%d far=%d | hidden=%d offworld=%d anchored=%d destroyedRefs=%d",
            trackedCount,
            folderModels,
            orphanModels,
            duplicateModelRefs,
            repairedModels,
            tierCounts.near,
            tierCounts.low,
            tierCounts.mid,
            tierCounts.far,
            hiddenCount,
            offworldCount,
            anchoredModelCount,
            destroyedRefCount
        ))
    end
end

modelTemplates = collectModels()
if useModelPool and ModelPool then
    ModelPool.init(modelTemplates)
end

if LODController then
    LODController.init()
    NPCMover.setPositionCallback(function(npcId, position)
        LODController.updatePosition(npcId, position)
    end)
else
    NPCMover.setPositionCallback(nil)
end

local activeFolder = ensureWorkspaceFolders()
clearFolderModels(activeFolder)
warnIfDuplicateClientScripts()
disableCompetingClientScripts()

-- Keep player character references warm for ground snap filters inside NPCMover.
Players.PlayerAdded:Connect(function(player)
    player.CharacterAdded:Connect(function() end)
end)

local remotesFolder = ReplicatedStorage:WaitForChild(Config.REMOTES_FOLDER_NAME, 15)
if not remotesFolder or not remotesFolder:IsA("Folder") then
    warn("[WP] Remotes folder missing (WanderingPropsRemotes). Server likely failed startup validation.")
    return
end

local spawnRemote = remotesFolder:WaitForChild(Config.REMOTE_SPAWN_NAME, 15)
local despawnRemote = remotesFolder:WaitForChild(Config.REMOTE_DESPAWN_NAME, 15)
local bulkSyncRemote = remotesFolder:WaitForChild(Config.REMOTE_BULK_SYNC_NAME, 15)

if not spawnRemote or not spawnRemote:IsA("RemoteEvent") then
    warn("[WP] Spawn remote missing (WP_Spawn).")
    return
end

if not despawnRemote or not despawnRemote:IsA("RemoteEvent") then
    warn("[WP] Despawn remote missing (WP_Despawn).")
    return
end

if not bulkSyncRemote or not bulkSyncRemote:IsA("RemoteEvent") then
    warn("[WP] BulkSync remote missing (WP_BulkSync).")
    return
end

local spawnRemoteEvent = spawnRemote :: RemoteEvent
local despawnRemoteEvent = despawnRemote :: RemoteEvent
local bulkSyncRemoteEvent = bulkSyncRemote :: RemoteEvent

spawnRemoteEvent.OnClientEvent:Connect(onSpawn)
despawnRemoteEvent.OnClientEvent:Connect(onDespawn)
bulkSyncRemoteEvent.OnClientEvent:Connect(onBulkSync)

RunService.Heartbeat:Connect(function(dt)
    reconcileAccumulator += dt
    local interval = math.max(1, tonumber(Config.CLIENT_RECONCILE_INTERVAL) or 5)
    if reconcileAccumulator >= interval then
        reconcileAccumulator = 0
        reconcileClientState()
    end
end)
