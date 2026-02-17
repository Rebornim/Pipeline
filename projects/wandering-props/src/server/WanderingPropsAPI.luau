local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local sharedFolder = ReplicatedStorage:WaitForChild("WanderingPropsShared")

local Config = require(sharedFolder:WaitForChild("Config"))
local Remotes = require(sharedFolder:WaitForChild("Remotes"))
local PopulationHooks = require(script.Parent:WaitForChild("PopulationHooks"))

local WanderingPropsAPI = {}

local MODE_DEFS = {
	normal = {
		name = "normal",
		priority = 0,
		spawnPaused = false,
		speedMultiplier = 1.0,
		rerouteToNearest = false,
	},
	pause = {
		name = "pause",
		priority = 10,
		spawnPaused = true,
		speedMultiplier = 1.0,
		rerouteToNearest = false,
	},
	evacuate = {
		name = "evacuate",
		priority = 20,
		spawnPaused = true,
		speedMultiplier = Config.EvacuateSpeedMultiplier,
		rerouteToNearest = true,
	},
	scatter = {
		name = "scatter",
		priority = 30,
		spawnPaused = true,
		speedMultiplier = Config.ScatterSpeedMultiplier,
		rerouteToNearest = true,
	},
}

local activeModes = {}
local currentModeName = "normal"
local desyncRemote: RemoteEvent? = nil

local function diagnostics(message: string)
	if Config.DiagnosticsEnabled then
		print(message)
	end
end

local function ensureDesyncRemote(): RemoteEvent
	if desyncRemote and desyncRemote.Parent then
		return desyncRemote
	end

	local remotesFolder = ReplicatedStorage:FindFirstChild("WanderingPropsRemotes")
	if not remotesFolder then
		remotesFolder = Instance.new("Folder")
		remotesFolder.Name = "WanderingPropsRemotes"
		remotesFolder.Parent = ReplicatedStorage
	end

	local existing = remotesFolder:FindFirstChild(Remotes.NPCDesync)
	if existing and existing:IsA("RemoteEvent") then
		desyncRemote = existing
		return desyncRemote
	end
	if existing then
		existing:Destroy()
	end

	desyncRemote = Instance.new("RemoteEvent")
	desyncRemote.Name = Remotes.NPCDesync
	desyncRemote.Parent = remotesFolder
	return desyncRemote
end

local function applyMode(modeName: string, previousModeName: string)
	local modeDef = MODE_DEFS[modeName] or MODE_DEFS.normal
	local previousDef = MODE_DEFS[previousModeName] or MODE_DEFS.normal

	PopulationHooks.spawnPaused = modeDef.spawnPaused
	PopulationHooks.walkSpeedMultiplier = math.max(0.1, modeDef.speedMultiplier or 1.0)
	print(string.format("[P8_TEST] SPAWN_PAUSED state=%s", tostring(PopulationHooks.spawnPaused)))
	diagnostics(string.format("[WanderingProps] SPAWN_PAUSED state=%s", tostring(PopulationHooks.spawnPaused)))

	if PopulationHooks.rebroadcastAllSpeeds then
		PopulationHooks.rebroadcastAllSpeeds(PopulationHooks.walkSpeedMultiplier)
	end

	if modeDef.rerouteToNearest and not previousDef.rerouteToNearest then
		if PopulationHooks.rerouteAllToNearestDespawn then
			PopulationHooks.rerouteAllToNearestDespawn()
		end
	end
end

local function evaluateActiveMode()
	local now = Workspace:GetServerTimeNow()
	local bestName = "normal"
	local bestPriority = MODE_DEFS.normal.priority

	for modeName, mode in pairs(activeModes) do
		if mode.expiresAt <= now then
			activeModes[modeName] = nil
		else
			local def = MODE_DEFS[modeName]
			if def and def.priority > bestPriority then
				bestName = modeName
				bestPriority = def.priority
			end
		end
	end

	if bestName == currentModeName then
		return
	end

	local previous = currentModeName
	currentModeName = bestName
	applyMode(bestName, previous)
	print(string.format("[P8_TEST] MODE_CHANGE from=%s to=%s priority=%d", previous, bestName, bestPriority))
	diagnostics(string.format(
		"[WanderingProps] MODE_CHANGE from=%s to=%s priority=%d",
		previous,
		bestName,
		bestPriority
	))
end

local function expireMode(modeName: string, expectedExpiresAt: number)
	local current = activeModes[modeName]
	if not current then
		return
	end
	if current.expiresAt ~= expectedExpiresAt then
		return
	end

	activeModes[modeName] = nil
	print(string.format("[P8_TEST] MODE_EXPIRE mode=%s", modeName))
	evaluateActiveMode()
end

function WanderingPropsAPI.SetMode(modeName: string, duration: number)
	local modeDef = MODE_DEFS[modeName]
	if not modeDef then
		warn(string.format("[WanderingProps] WARNING: SetMode invalid mode \"%s\".", tostring(modeName)))
		return
	end

	local now = Workspace:GetServerTimeNow()
	local cooldown = math.max(0, Config.ModeRetriggerCooldown or 0)
	local existing = activeModes[modeName]
	if existing and (now - existing.lastTriggeredAt) < cooldown then
		local remaining = cooldown - (now - existing.lastTriggeredAt)
		print(string.format(
			"[P8_TEST] MODE_DEBOUNCE mode=%s cooldown_remaining=%.2f",
			modeName,
			math.max(0, remaining)
		))
		return
	end

	local clampedDuration = math.max(0, duration or 0)
	local expiresAt = now + clampedDuration
	activeModes[modeName] = {
		name = modeName,
		expiresAt = expiresAt,
		lastTriggeredAt = now,
	}

	print(string.format(
		"[P8_TEST] MODE_SET mode=%s duration=%.2f priority=%d",
		modeName,
		clampedDuration,
		modeDef.priority
	))
	task.delay(clampedDuration, function()
		expireMode(modeName, expiresAt)
	end)

	evaluateActiveMode()
end

function WanderingPropsAPI.ClearMode(modeName: string)
	if activeModes[modeName] == nil then
		return
	end
	activeModes[modeName] = nil
	print(string.format("[P8_TEST] MODE_CLEAR mode=%s", modeName))
	evaluateActiveMode()
end

function WanderingPropsAPI.GetActiveMode(): string
	evaluateActiveMode()
	return currentModeName
end

function WanderingPropsAPI.DesyncPlayer(player: Player)
	if not player then
		return
	end
	if PopulationHooks.desyncedPlayers[player] then
		return
	end

	PopulationHooks.desyncedPlayers[player] = true
	ensureDesyncRemote():FireClient(player, true)
	print(string.format("[P8_TEST] DESYNC player=%s", player.Name))
	diagnostics(string.format("[WanderingProps] DESYNC player=%s", player.Name))
end

function WanderingPropsAPI.ResyncPlayer(player: Player)
	if not player then
		return
	end
	if not PopulationHooks.desyncedPlayers[player] then
		return
	end

	PopulationHooks.desyncedPlayers[player] = nil
	ensureDesyncRemote():FireClient(player, false)

	task.defer(function()
		if player.Parent ~= Players then
			return
		end

		local sentCount = 0
		if PopulationHooks.sendBulkSyncToPlayer then
			sentCount = PopulationHooks.sendBulkSyncToPlayer(player) or 0
		end
		print(string.format("[P8_TEST] RESYNC player=%s npcs_sent=%d", player.Name, sentCount))
		diagnostics(string.format("[WanderingProps] RESYNC player=%s", player.Name))
	end)
end

function WanderingPropsAPI.IsPlayerDesynced(player: Player): boolean
	return PopulationHooks.desyncedPlayers[player] == true
end

Players.PlayerRemoving:Connect(function(player)
	PopulationHooks.desyncedPlayers[player] = nil
end)

ensureDesyncRemote()

return WanderingPropsAPI
