--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local sharedFolder = ReplicatedStorage:WaitForChild("WanderingProps")
local Config = require(sharedFolder:WaitForChild("Config"))
local Diagnostics = require(sharedFolder:WaitForChild("Diagnostics"))

local NodeGraph = require(script.Parent:WaitForChild("NodeGraph"))
local RouteBuilder = require(script.Parent:WaitForChild("RouteBuilder"))
local NPCRegistry = require(script.Parent:WaitForChild("NPCRegistry"))
local SeatManager = require(script.Parent:WaitForChild("SeatManager"))
local StartupValidator = require(script.Parent:WaitForChild("StartupValidator"))

local globalState = _G :: any
local serverControllerLockKey = "__WP_ServerPopulationControllerLock"
local existingControllerPath = globalState[serverControllerLockKey]
if existingControllerPath and existingControllerPath ~= script:GetFullName() then
    warn(string.format(
        "[WP] Duplicate PopulationController detected. Active='%s' Ignoring='%s'",
        tostring(existingControllerPath),
        script:GetFullName()
    ))
    return
end
globalState[serverControllerLockKey] = script:GetFullName()

local function disableCompetingPopulationControllers(): ()
    for _, descendant in ipairs(ServerScriptService:GetDescendants()) do
        if not descendant:IsA("Script") then
            continue
        end
        if descendant == script then
            continue
        end
        if descendant.Name == script.Name or descendant.Name == "PopulationController" then
            descendant.Disabled = true
            warn(string.format(
                "[WP] Disabled competing server script: %s",
                descendant:GetFullName()
            ))
        end
    end
end

disableCompetingPopulationControllers()

print(string.format(
    "[WP] Server build: %s | Controller=%s | AnimIDs walk=%s idle=%s sit=%s",
    tostring(Config.BUILD_SIGNATURE),
    script:GetFullName(),
    tostring(Config.WALK_ANIMATION_ID),
    tostring(Config.IDLE_ANIMATION_ID),
    tostring(Config.SIT_ANIMATION_ID)
))

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

type RouteResult = {
    route: { RouteStep },
    stepDurations: { number },
    cumulativeTimes: { number },
    totalDuration: number,
    startPosition: Vector3,
    spawnNodeId: string,
    seatClaims: { [number]: string },
}

type NPCData = {
    npcId: string,
    modelIndex: number,
    walkSpeed: number,
    route: { RouteStep },
    stepDurations: { number },
    cumulativeTimes: { number },
    totalDuration: number,
    spawnTime: number,
    currentStepIndex: number,
    state: "active" | "despawning",
    seatClaims: { [number]: string }?,
    startPosition: Vector3,
}

local remotesFolder: Folder
local spawnRemote: RemoteEvent
local despawnRemote: RemoteEvent
local bulkSyncRemote: RemoteEvent

local sortedModels: { Model } = {}
local serverStartTime = os.clock()
local tickAccumulator = 0
local spawnAccumulator = 0
local healthPrintAccumulator = 0
local controllerDebugAccumulator = 0

type SpawnPassStats = {
    desiredPopulation: number,
    activeBefore: number,
    activeAfter: number,
    deficitBefore: number,
    deficitAfter: number,
    burstBudget: number,
    targetSpawn: number,
    attempts: number,
    spawned: number,
    groupAttempts: number,
    singleAttempts: number,
}

local lastSpawnPassStats: SpawnPassStats? = nil

local function ensureRemotes(): ()
    local existing = ReplicatedStorage:FindFirstChild(Config.REMOTES_FOLDER_NAME)
    if existing and existing:IsA("Folder") then
        remotesFolder = existing
    else
        if existing then
            existing:Destroy()
        end

        remotesFolder = Instance.new("Folder")
        remotesFolder.Name = Config.REMOTES_FOLDER_NAME
        remotesFolder.Parent = ReplicatedStorage
    end

    local function ensureRemote(name: string): RemoteEvent
        local current = remotesFolder:FindFirstChild(name)
        if current and current:IsA("RemoteEvent") then
            return current
        end

        if current then
            current:Destroy()
        end

        local created = Instance.new("RemoteEvent")
        created.Name = name
        created.Parent = remotesFolder
        return created
    end

    spawnRemote = ensureRemote(Config.REMOTE_SPAWN_NAME)
    despawnRemote = ensureRemote(Config.REMOTE_DESPAWN_NAME)
    bulkSyncRemote = ensureRemote(Config.REMOTE_BULK_SYNC_NAME)
end

local function collectSortedModels(): { Model }
    local modelsFolder = ReplicatedStorage:FindFirstChild(Config.MODELS_FOLDER_NAME)
    if not modelsFolder then
        return {}
    end

    local models: { Model } = {}
    for _, child in ipairs(modelsFolder:GetChildren()) do
        if child:IsA("Model") then
            table.insert(models, child)
        end
    end

    -- Server stamps each template with a runtime index so client lookup does not
    -- depend on model names (duplicate names are allowed).
    for index, model in ipairs(models) do
        model:SetAttribute(Config.MODEL_TEMPLATE_INDEX_ATTRIBUTE, index)
    end

    return models
end

local function recomputeStepTiming(route: { RouteStep }, walkSpeed: number): ({ number }, { number }, number)
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

local function randomWalkSpeed(baseOverride: number?): number
    local base = if baseOverride then baseOverride else tonumber(Config.BASE_WALK_SPEED) or 10
    local variation = tonumber(Config.WALK_SPEED_VARIATION) or 0
    return math.max(0.001, base + (math.random() * 2 - 1) * variation)
end

local STEP_TYPE_TO_CODE: { [string]: number } = {
    walk = 1,
    scenic = 2,
    social = 3,
    despawn = 4,
}

local function packRoute(route: { RouteStep }): { PackedRouteStep }
    local packed: { PackedRouteStep } = table.create(#route)
    for _, step in ipairs(route) do
        local code = STEP_TYPE_TO_CODE[step.type] or 1
        -- Keep packed entries dense (no nil gaps) so replication preserves all fields.
        local entry: PackedRouteStep = {
            code,
            step.targetPosition,
            step.dwellTime or false,
            step.seatCFrame or false,
            step.viewPosition or false,
        }
        table.insert(packed, entry)
    end
    return packed
end

local function createNPCFromRoute(routeResult: RouteResult, walkSpeed: number, isGroupMember: boolean): boolean
    if #sortedModels == 0 then
        Diagnostics.increment("totalRejects", "no_model")
        return false
    end

    local npcId = NPCRegistry.nextId()
    local modelIndex = math.random(1, #sortedModels)
    local stepDurations, cumulativeTimes, totalDuration = recomputeStepTiming(routeResult.route, walkSpeed)

    local npcData: NPCData = {
        npcId = npcId,
        modelIndex = modelIndex,
        walkSpeed = walkSpeed,
        route = routeResult.route,
        stepDurations = stepDurations,
        cumulativeTimes = cumulativeTimes,
        totalDuration = totalDuration,
        spawnTime = os.clock(),
        currentStepIndex = 1,
        state = "active",
        seatClaims = routeResult.seatClaims,
        startPosition = routeResult.startPosition,
    }

    NPCRegistry.createNPC(npcData)

    spawnRemote:FireAllClients({
        npcId = npcData.npcId,
        modelIndex = npcData.modelIndex,
        walkSpeed = npcData.walkSpeed,
        routePacked = packRoute(npcData.route),
        startPosition = npcData.startPosition,
    })

    Diagnostics.log(npcData.npcId, if isGroupMember then "spawned_group" else "spawned", routeResult.spawnNodeId)
    Diagnostics.trail(npcData.npcId, "spawned_at:" .. routeResult.spawnNodeId)
    return true
end

local function releaseOutstandingSeats(npcData: NPCData): ()
    if not npcData.seatClaims then
        return
    end

    for _, seatId in pairs(npcData.seatClaims) do
        SeatManager.releaseSeat(seatId)
    end
end

local function despawnNPC(npcData: NPCData, reason: string): ()
    releaseOutstandingSeats(npcData)

    despawnRemote:FireAllClients({ npcId = npcData.npcId })

    NPCRegistry.removeNPC(npcData.npcId)
    Diagnostics.increment("totalDespawned", reason)
    Diagnostics.log(npcData.npcId, "despawned", reason)
    Diagnostics.trail(npcData.npcId, "despawn:" .. reason)
    Diagnostics.clearTrail(npcData.npcId)
end

local function advanceNPCs(): ()
    for _, npcData: NPCData in pairs(NPCRegistry.getAllNPCs()) do
        local elapsed = math.max(0, os.clock() - npcData.spawnTime)

        while npcData.currentStepIndex <= #npcData.route do
            local stepEnd = npcData.cumulativeTimes[npcData.currentStepIndex]
            if not stepEnd or elapsed < stepEnd then
                break
            end

            local completedStepIndex = npcData.currentStepIndex
            local completedStep = npcData.route[completedStepIndex]
            local seatId = npcData.seatClaims and npcData.seatClaims[completedStepIndex] or nil
            if seatId then
                SeatManager.releaseSeat(seatId)
                npcData.seatClaims[completedStepIndex] = nil
            end

            npcData.currentStepIndex += 1
            Diagnostics.trail(npcData.npcId, string.format("step_advance:%d_%s", completedStepIndex, completedStep.type))
        end

        if npcData.currentStepIndex > #npcData.route then
            despawnNPC(npcData, "route_complete")
        end
    end
end

local function computeDesiredPopulation(): number
    local minPop = math.max(0, math.floor(tonumber(Config.MIN_POPULATION) or 0))
    local maxPop = math.max(minPop, math.floor(tonumber(Config.MAX_POPULATION) or minPop))

    local desired = minPop
    if not Config.MAINTAIN_MIN_POPULATION then
        local rampTime = math.max(1, tonumber(Config.SPAWN_RAMP_TIME) or 30)
        local alpha = math.clamp((os.clock() - serverStartTime) / rampTime, 0, 1)
        desired = math.floor(minPop + (maxPop - minPop) * alpha + 0.5)
    end

    if Config.DAY_NIGHT_ENABLED then
        local indicator = Workspace:FindFirstChild(Config.NIGHT_INDICATOR_NAME)
        if indicator and indicator:IsA("BoolValue") and indicator.Value then
            desired = math.floor(desired * math.clamp(tonumber(Config.NIGHT_POPULATION_MULTIPLIER) or 1, 0, 1))
        end
    end

    return math.max(0, desired)
end

local function trySpawnSingle(): number
    local route = RouteBuilder.buildRoute(NodeGraph, SeatManager)
    if not route then
        Diagnostics.increment("totalRejects", "no_route")
        return 0
    end

    if createNPCFromRoute(route, randomWalkSpeed(nil), false) then
        return 1
    end
    return 0
end

local function trySpawnGroup(remainingCapacity: number): number
    local minSize = math.max(1, math.floor(tonumber(Config.GROUP_SIZE_MIN) or 2))
    local maxSize = math.max(minSize, math.floor(tonumber(Config.GROUP_SIZE_MAX) or 4))
    local groupSize = math.clamp(math.random(minSize, maxSize), 1, remainingCapacity)

    if groupSize <= 1 then
        return trySpawnSingle()
    end

    local groupRoutes = RouteBuilder.buildGroupRoute(groupSize, NodeGraph, SeatManager)
    if not groupRoutes then
        local fallbackSpawned = trySpawnSingle()
        if fallbackSpawned <= 0 then
            Diagnostics.increment("totalRejects", "no_route")
        end
        return fallbackSpawned
    end

    local groupBaseSpeed = randomWalkSpeed(nil)
    local groupVariation = math.max(0, tonumber(Config.GROUP_SPEED_VARIATION) or 1)

    local spawnedCount = 0
    for _, route in ipairs(groupRoutes) do
        local speed = math.max(0.001, groupBaseSpeed + (math.random() * 2 - 1) * groupVariation)
        if createNPCFromRoute(route, speed, true) then
            spawnedCount += 1
        end
    end

    return spawnedCount
end

local function runSpawnPass(): SpawnPassStats
    local desiredPopulation = computeDesiredPopulation()
    local activeCount = NPCRegistry.getActiveCount()
    local stats: SpawnPassStats = {
        desiredPopulation = desiredPopulation,
        activeBefore = activeCount,
        activeAfter = activeCount,
        deficitBefore = math.max(0, desiredPopulation - activeCount),
        deficitAfter = math.max(0, desiredPopulation - activeCount),
        burstBudget = 0,
        targetSpawn = 0,
        attempts = 0,
        spawned = 0,
        groupAttempts = 0,
        singleAttempts = 0,
    }

    if activeCount >= desiredPopulation then
        return stats
    end

    local initialDeficit = desiredPopulation - activeCount
    local burstBudget = math.max(1, math.floor(tonumber(Config.SPAWN_BURST_PER_PASS) or 1))
    local maxAttempts = math.max(1, math.floor(tonumber(Config.SPAWN_MAX_ATTEMPTS_PER_PASS) or (burstBudget * 2)))
    local targetSpawn = math.min(initialDeficit, burstBudget)
    local spawnedThisPass = 0
    local attempts = 0
    local groupAttempts = 0
    local singleAttempts = 0

    while spawnedThisPass < targetSpawn and attempts < maxAttempts do
        attempts += 1

        local currentActive = NPCRegistry.getActiveCount()
        local remaining = desiredPopulation - currentActive
        if remaining <= 0 then
            break
        end

        local useGroup = remaining > 1 and math.random() <= math.clamp(tonumber(Config.GROUP_SPAWN_CHANCE) or 0, 0, 1)
        if useGroup then
            groupAttempts += 1
        else
            singleAttempts += 1
        end

        local spawned = if useGroup then trySpawnGroup(remaining) else trySpawnSingle()
        if spawned > 0 then
            spawnedThisPass += spawned
        else
            -- Route constraints can temporarily fail; keep retrying this pass
            -- up to maxAttempts to avoid long under-population periods.
        end
    end

    local activeAfter = NPCRegistry.getActiveCount()
    stats.activeAfter = activeAfter
    stats.deficitAfter = math.max(0, desiredPopulation - activeAfter)
    stats.burstBudget = burstBudget
    stats.targetSpawn = targetSpawn
    stats.attempts = attempts
    stats.spawned = spawnedThisPass
    stats.groupAttempts = groupAttempts
    stats.singleAttempts = singleAttempts
    return stats
end

local function printControllerSummary(): ()
    if Config.CONTROLLER_DEBUG_MODE ~= true then
        return
    end

    local active = NPCRegistry.getActiveCount()
    local desired = computeDesiredPopulation()
    local deficit = math.max(0, desired - active)
    local stats = lastSpawnPassStats
    if not stats then
        print(string.format(
            "[WP][CTRL] active=%d desired=%d deficit=%d (no spawn pass stats yet)",
            active,
            desired,
            deficit
        ))
        return
    end

    print(string.format(
        "[WP][CTRL] active=%d desired=%d deficit=%d | pass before=%d after=%d target=%d spawned=%d attempts=%d (group=%d single=%d)",
        active,
        desired,
        deficit,
        stats.activeBefore,
        stats.activeAfter,
        stats.targetSpawn,
        stats.spawned,
        stats.attempts,
        stats.groupAttempts,
        stats.singleAttempts
    ))
end

local function buildBulkSyncEntries(): { any }
    local entries: { any } = {}

    for _, npcData: NPCData in pairs(NPCRegistry.getAllNPCs()) do
        local elapsed = math.max(0, os.clock() - npcData.spawnTime)
        local stepIndex = math.clamp(npcData.currentStepIndex, 1, math.max(1, #npcData.route))
        local previousCumulative = if stepIndex > 1 then npcData.cumulativeTimes[stepIndex - 1] else 0
        local stepElapsed = math.max(0, elapsed - previousCumulative)

        table.insert(entries, {
            npcId = npcData.npcId,
            modelIndex = npcData.modelIndex,
            walkSpeed = npcData.walkSpeed,
            routePacked = packRoute(npcData.route),
            startPosition = npcData.startPosition,
            currentStepIndex = stepIndex,
            stepElapsed = stepElapsed,
        })
    end

    return entries
end

local function onPlayerAdded(player: Player): ()
    bulkSyncRemote:FireClient(player, {
        npcs = buildBulkSyncEntries(),
    })
end

local function stepServerTick(): ()
    advanceNPCs()

    spawnAccumulator += tonumber(Config.SERVER_TICK_RATE) or 0.5
    local spawnInterval = math.max(tonumber(Config.SERVER_TICK_RATE) or 0.5, tonumber(Config.SPAWN_INTERVAL) or 2)
    if spawnAccumulator >= spawnInterval then
        spawnAccumulator -= spawnInterval
        lastSpawnPassStats = runSpawnPass()
    end

    if Config.CONTROLLER_DEBUG_MODE == true then
        controllerDebugAccumulator += tonumber(Config.SERVER_TICK_RATE) or 0.5
        local interval = math.max(1, tonumber(Config.CONTROLLER_DEBUG_INTERVAL) or 10)
        if controllerDebugAccumulator >= interval then
            controllerDebugAccumulator -= interval
            printControllerSummary()
        end
    end

    if Config.DEBUG_MODE then
        healthPrintAccumulator += tonumber(Config.SERVER_TICK_RATE) or 0.5
        if healthPrintAccumulator >= 10 then
            healthPrintAccumulator = 0
            Diagnostics.printHealth()
        end
    end
end

if not NodeGraph.build() then
    warn("[WP] ERROR: NodeGraph build failed")
    return
end

SeatManager.init(NodeGraph)
ensureRemotes()

local passed, errors = StartupValidator.validate(NodeGraph)
if not passed then
    for _, message in ipairs(errors) do
        warn(message)
    end
    warn("[WP] Startup validation failed. Wandering Props halted.")
    return
end

sortedModels = collectSortedModels()

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in ipairs(Players:GetPlayers()) do
    onPlayerAdded(player)
end

RunService.Heartbeat:Connect(function(deltaTime)
    tickAccumulator += deltaTime

    local tickRate = math.max(0.05, tonumber(Config.SERVER_TICK_RATE) or 0.5)
    while tickAccumulator >= tickRate do
        tickAccumulator -= tickRate
        stepServerTick()
    end
end)
