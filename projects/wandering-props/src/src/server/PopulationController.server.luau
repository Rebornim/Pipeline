--!strict

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local configModule = ReplicatedStorage:WaitForChild("Config", 10)
assert(configModule and configModule:IsA("ModuleScript"), "WanderingProps PopulationController: ReplicatedStorage.Config not found")

local typesModule = ReplicatedStorage:WaitForChild("Types", 10)
assert(typesModule and typesModule:IsA("ModuleScript"), "WanderingProps PopulationController: ReplicatedStorage.Types not found")

local nodeGraphModule = script.Parent:WaitForChild("NodeGraph", 10)
assert(nodeGraphModule and nodeGraphModule:IsA("ModuleScript"), "WanderingProps PopulationController: NodeGraph module not found")

local routeBuilderModule = script.Parent:WaitForChild("RouteBuilder", 10)
assert(routeBuilderModule and routeBuilderModule:IsA("ModuleScript"), "WanderingProps PopulationController: RouteBuilder module not found")

local seatManagerModule = script.Parent:WaitForChild("SeatManager", 10)
assert(seatManagerModule and seatManagerModule:IsA("ModuleScript"), "WanderingProps PopulationController: SeatManager module not found")

local registryModule = script.Parent:WaitForChild("NPCRegistry", 10)
assert(registryModule and registryModule:IsA("ModuleScript"), "WanderingProps PopulationController: NPCRegistry module not found")

local Config = require(configModule)
local Types = require(typesModule)
local NodeGraph = require(nodeGraphModule)
local RouteBuilder = require(routeBuilderModule)
local SeatManager = require(seatManagerModule)
local NPCRegistry = require(registryModule)

type GraphNode = Types.GraphNode
type RouteStep = Types.RouteStep
type NPCRecord = Types.NPCRecord
type SpawnPayload = Types.SpawnPayload

local REMOTES_FOLDER_NAME = "WanderingPropsRemotes"
local SPAWN_EVENT_NAME = "WP_SpawnNPC"
local DESPAWN_EVENT_NAME = "WP_DespawnNPC"
local SYNC_EVENT_NAME = "WP_SyncState"
local MODEL_FOLDER_NAME = "WanderingPropModels"

local spawnEvent: RemoteEvent
local despawnEvent: RemoteEvent
local syncEvent: RemoteEvent

local npcIdCounter = 0
local groupIdCounter = 0
local warnedNoModelTemplates = false
local lastSpawnStallWarnAt = 0
local SPAWN_STALL_WARN_COOLDOWN = 30
local SPAWN_STALL_WARN_MIN_CONSECUTIVE_CYCLES = 2
local consecutiveSpawnNoProgressCycles = 0
local SPAWN_ROUTE_RETRIES_PER_ATTEMPT = 3

local function debugLog(message: string): ()
	if Config.DEBUG_ENABLED then
		warn(("[WanderingProps/PopulationController] %s"):format(message))
	end
end

local function generateId(): string
	npcIdCounter += 1
	return "npc_" .. tostring(npcIdCounter)
end

local function generateGroupId(): string
	groupIdCounter += 1
	return "group_" .. tostring(groupIdCounter)
end

local function ensureRemotesFolder(): Folder
	local existing = ReplicatedStorage:FindFirstChild(REMOTES_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end

	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = REMOTES_FOLDER_NAME
	folder.Parent = ReplicatedStorage
	return folder
end

local function ensureRemoteEvent(parentFolder: Folder, name: string): RemoteEvent
	local existing = parentFolder:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end

	if existing then
		existing:Destroy()
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = parentFolder
	return remote
end

local function createRemoteInfrastructure(): ()
	local remotesFolder = ensureRemotesFolder()
	spawnEvent = ensureRemoteEvent(remotesFolder, SPAWN_EVENT_NAME)
	despawnEvent = ensureRemoteEvent(remotesFolder, DESPAWN_EVENT_NAME)
	syncEvent = ensureRemoteEvent(remotesFolder, SYNC_EVENT_NAME)
end

local function computeTimestamps(route: { RouteStep }, speed: number): ({ number }, number)
	local timestamps: { number } = {}
	if #route == 0 then
		return timestamps, 0
	end

	local clampedSpeed = math.max(speed, 0.001)
	local cumulative = 0

	for index, step in ipairs(route) do
		timestamps[index] = cumulative

		local stepDuration = 0
		if step.action == "walk" then
			local nextStep = route[index + 1]
			if nextStep then
				stepDuration = (nextStep.position - step.position).Magnitude / clampedSpeed
			end
		elseif step.action == "idle" or step.action == "sit" then
			stepDuration = math.max(0, step.duration or 0)
		end

		cumulative += stepDuration
	end

	return timestamps, cumulative
end

local function getTargetPopulation(): number
	local minPopulation = math.max(0, math.floor(tonumber(Config.MIN_POPULATION) or 0))
	local maxPopulation = math.max(minPopulation, math.floor(tonumber(Config.MAX_POPULATION) or minPopulation))
	local adjustedMax = maxPopulation

	if Config.DAY_NIGHT_ENABLED then
		local hour = Lighting.ClockTime
		local isNight = hour >= Config.NIGHT_START_HOUR or hour < Config.NIGHT_END_HOUR
		if isNight then
			local multiplier = tonumber(Config.NIGHT_POPULATION_MULTIPLIER) or 1
			adjustedMax = math.max(0, math.floor(maxPopulation * multiplier))
		end
	end

	return math.max(minPopulation, adjustedMax)
end

local function getRandomNodeByTag(tag: string): GraphNode?
	local nodes: { GraphNode } = NodeGraph.getNodesByTag(tag)
	if #nodes == 0 then
		debugLog(("No nodes found for tag %s"):format(tag))
		return nil
	end

	return nodes[math.random(1, #nodes)]
end

local function getRandomSpeed(): number
	local baseSpeed = tonumber(Config.BASE_WALK_SPEED) or 0
	local variation = tonumber(Config.WALK_SPEED_VARIATION) or 0
	local speed = baseSpeed + (math.random() * 2 - 1) * variation
	return math.max(0.001, speed)
end

local function getRandomModelIndex(): number?
	local modelCount = 0
	local modelsFolder = ReplicatedStorage:FindFirstChild(MODEL_FOLDER_NAME)
	if modelsFolder then
		for _, child in ipairs(modelsFolder:GetChildren()) do
			if child:IsA("Model") then
				modelCount += 1
			end
		end
	end

	if modelCount <= 0 and not warnedNoModelTemplates then
		warnedNoModelTemplates = true
		warn(("[WanderingProps/PopulationController] ReplicatedStorage.%s has no model templates"):format(MODEL_FOLDER_NAME))
	end
	if modelCount <= 0 then
		return nil
	end

	return math.random(1, modelCount)
end

local function incrementReasonCount(reasonCounts: { [string]: number }, reason: string?): ()
	local key = if reason and reason ~= "" then reason else "unknown"
	reasonCounts[key] = (reasonCounts[key] or 0) + 1
end

local function formatReasonCounts(reasonCounts: { [string]: number }): string
	local reasons: { string } = {}
	for reason in pairs(reasonCounts) do
		table.insert(reasons, reason)
	end

	table.sort(reasons)

	local parts: { string } = table.create(#reasons)
	for _, reason in ipairs(reasons) do
		table.insert(parts, ("%s=%d"):format(reason, reasonCounts[reason]))
	end

	return table.concat(parts, ", ")
end

local function buildSpawnPayload(record: NPCRecord): SpawnPayload
	return {
		id = record.id,
		modelIndex = record.modelIndex,
		speed = record.speed,
		route = record.route,
		groupId = record.groupId,
	}
end

local function registerAndBroadcast(
	npcId: string,
	groupId: string?,
	modelIndex: number,
	speed: number,
	route: { RouteStep },
	reservedSeats: { Part },
	delaySeconds: number?
): boolean
	if #route < 2 or route[1].action == "despawn" then
		local firstAction = if route[1] then route[1].action else "nil"
		debugLog(("Rejected invalid route for %s (steps=%d, firstAction=%s)"):format(npcId, #route, firstAction))
		return false
	end
	if modelIndex <= 0 then
		debugLog(("Rejected spawn for %s due to invalid model index"):format(npcId))
		return false
	end

	if #reservedSeats > 0 then
		SeatManager.claimReservations(reservedSeats, npcId)
	end

	local stepTimestamps, totalDuration = computeTimestamps(route, speed)
	local delayOffset = if delaySeconds and delaySeconds > 0 then delaySeconds else 0
	local record: NPCRecord = {
		id = npcId,
		modelIndex = modelIndex,
		speed = speed,
		route = route,
		stepTimestamps = stepTimestamps,
		totalDuration = totalDuration,
		spawnTime = tick() + delayOffset,
		groupId = groupId,
		reservedSeats = reservedSeats,
	}

	NPCRegistry.register(record)

	local payload = buildSpawnPayload(record)
	if delaySeconds and delaySeconds > 0 then
		task.delay(delaySeconds, function()
			if NPCRegistry.getAll()[npcId] ~= nil then
				spawnEvent:FireAllClients(payload)
			end
		end)
	else
		spawnEvent:FireAllClients(payload)
	end

	return true
end

local function spawnSolo(): (boolean, string?)
	local lastFailureReason = "no_spawn_nodes"

	for _ = 1, SPAWN_ROUTE_RETRIES_PER_ATTEMPT do
		local spawnNode = getRandomNodeByTag(Config.TAG_SPAWN)
		if not spawnNode then
			return false, "no_spawn_nodes"
		end

		local route, reservedSeats, routeFailureReason = RouteBuilder.buildRoute(spawnNode)
		if #route == 0 then
			local detail = if routeFailureReason and routeFailureReason ~= "" then routeFailureReason else "unknown"
			lastFailureReason = "solo_empty_route(" .. detail .. ")"
			continue
		end

		local modelIndex = getRandomModelIndex()
		if not modelIndex then
			return false, "no_model_templates"
		end

		local spawned = registerAndBroadcast(
			generateId(),
			nil,
			modelIndex,
			getRandomSpeed(),
			route,
			reservedSeats,
			nil
		)
		if spawned then
			return true, nil
		end

		lastFailureReason = "solo_register_rejected"
	end

	return false, lastFailureReason
end

local function spawnGroup(remainingCapacity: number): (boolean, string?)
	local minSize = math.max(1, math.floor(tonumber(Config.GROUP_SIZE_MIN) or 1))
	local maxSize = math.max(minSize, math.floor(tonumber(Config.GROUP_SIZE_MAX) or minSize))
	local targetSize = math.random(minSize, maxSize)
	local groupSize = math.max(1, math.min(targetSize, remainingCapacity))

	if groupSize <= 1 then
		return spawnSolo()
	end

	local chosenRoutes: { { route: { RouteStep }, reservedSeats: { Part } } }? = nil
	local lastFailureReason = "group_empty_route(unknown)"

	for _ = 1, SPAWN_ROUTE_RETRIES_PER_ATTEMPT do
		local spawnNode = getRandomNodeByTag(Config.TAG_SPAWN)
		if not spawnNode then
			return false, "no_spawn_nodes"
		end

		local groupRoutes, groupFailureReason = RouteBuilder.buildGroupRoute(spawnNode, groupSize)
		if #groupRoutes > 0 then
			chosenRoutes = groupRoutes
			break
		end

		local detail = if groupFailureReason and groupFailureReason ~= "" then groupFailureReason else "unknown"
		lastFailureReason = "group_empty_route(" .. detail .. ")"
	end

	if not chosenRoutes then
		return false, lastFailureReason
	end

	local groupId = generateGroupId()
	local sharedSpeed = getRandomSpeed()
	local spawnDelay = math.max(0, tonumber(Config.GROUP_FOLLOWER_DELAY) or 0)
	local spawnedAny = false
	local memberFailureReasons: { [string]: number } = {}

	for index, member in ipairs(chosenRoutes) do
		local npcId = generateId()
		local delaySeconds = if index == 1 then nil else spawnDelay * (index - 1)
		local modelIndex = getRandomModelIndex()
		if not modelIndex then
			incrementReasonCount(memberFailureReasons, "no_model_templates")
			continue
		end

		local spawned = registerAndBroadcast(
			npcId,
			groupId,
			modelIndex,
			sharedSpeed,
			member.route,
			member.reservedSeats,
			delaySeconds
		)
		if not spawned then
			incrementReasonCount(memberFailureReasons, "group_register_rejected")
		end
		spawnedAny = spawnedAny or spawned
	end

	if spawnedAny then
		return true, nil
	end

	local groupedReasons = formatReasonCounts(memberFailureReasons)
	if groupedReasons ~= "" then
		return false, "group_failed(" .. groupedReasons .. ")"
	end
	return false, "group_no_members_spawned"
end

local function handlePlayerAdded(player: Player): ()
	task.delay(1, function()
		if player.Parent == Players then
			syncEvent:FireClient(player, { npcs = NPCRegistry.getSyncData() })
		end
	end)
end

local function despawnExpired(): ()
	local nowTime = tick()
	local timeout = math.max(0, tonumber(Config.STUCK_TIMEOUT) or 0)

	for npcId, record in pairs(NPCRegistry.getAll()) do
		if nowTime - record.spawnTime >= record.totalDuration + timeout then
			despawnEvent:FireAllClients({ id = npcId })
			SeatManager.releaseByNPC(npcId)
			NPCRegistry.unregister(npcId)
		end
	end
end

local function runMainLoop(): ()
	local spawnCheckInterval = math.max(0.1, tonumber(Config.SPAWN_CHECK_INTERVAL) or 1)
	local spawnsPerCycle = math.max(0, math.floor(tonumber(Config.SPAWNS_PER_CYCLE) or 0))
	local groupSpawnChance = math.clamp(tonumber(Config.GROUP_SPAWN_CHANCE) or 0, 0, 1)

	while true do
		task.wait(spawnCheckInterval)

		despawnExpired()

		local targetPop = getTargetPopulation()
		local spawnedActions = 0
		local attemptBudget = math.max(4, spawnsPerCycle * 4)
		local minPopulation = math.max(0, math.floor(tonumber(Config.MIN_POPULATION) or 0))
		if NPCRegistry.getCount() < minPopulation then
			attemptBudget = math.max(attemptBudget, spawnsPerCycle * 8, 16)
		end
		local attempts = 0
		local failureReasons: { [string]: number } = {}

		while NPCRegistry.getCount() < targetPop and spawnedActions < spawnsPerCycle and attempts < attemptBudget do
			attempts += 1
			local remaining = targetPop - NPCRegistry.getCount()
			if remaining <= 0 then
				break
			end

			local spawned = false
			local failureReason: string? = nil
			if math.random() < groupSpawnChance then
				spawned, failureReason = spawnGroup(remaining)
			else
				spawned, failureReason = spawnSolo()
			end

			if spawned then
				spawnedActions += 1
			else
				incrementReasonCount(failureReasons, failureReason)
			end
		end

		local currentPopulation = NPCRegistry.getCount()
		local isNoProgressCycle = currentPopulation < targetPop and spawnedActions == 0 and attempts > 0
		if isNoProgressCycle then
			consecutiveSpawnNoProgressCycles += 1
		else
			consecutiveSpawnNoProgressCycles = 0
		end

		if isNoProgressCycle and consecutiveSpawnNoProgressCycles >= SPAWN_STALL_WARN_MIN_CONSECUTIVE_CYCLES then
			local nowTime = tick()
			if nowTime - lastSpawnStallWarnAt >= SPAWN_STALL_WARN_COOLDOWN then
				lastSpawnStallWarnAt = nowTime
				warn(
					("[WanderingProps/PopulationController] Spawn cycle made no progress for %d consecutive cycles (current=%d, target=%d, attempts=%d, budget=%d). Reasons: %s"):format(
						consecutiveSpawnNoProgressCycles,
						currentPopulation,
						targetPop,
						attempts,
						attemptBudget,
						formatReasonCounts(failureReasons)
					)
				)
			end
		end
	end
end

NodeGraph.init()
SeatManager.init()
createRemoteInfrastructure()

Players.PlayerAdded:Connect(handlePlayerAdded)
for _, player in ipairs(Players:GetPlayers()) do
	handlePlayerAdded(player)
end

runMainLoop()
