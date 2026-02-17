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
		populationOverride = nil,
		drainEnabled = false,
		drainBatchSize = 0,
		drainCheckInterval = 0,
		rerouteToNearest = false,
		rerouteSpeedMultiplier = nil,
	},
	pause = {
		name = "pause",
		priority = 10,
		spawnPaused = true,
		populationOverride = nil,
		drainEnabled = false,
		drainBatchSize = 0,
		drainCheckInterval = 0,
		rerouteToNearest = false,
		rerouteSpeedMultiplier = nil,
	},
	evacuate = {
		name = "evacuate",
		priority = 20,
		spawnPaused = true,
		populationOverride = 0,
		drainEnabled = false,
		drainBatchSize = 0,
		drainCheckInterval = 0,
		rerouteToNearest = true,
		rerouteSpeedMultiplier = math.max(0.1, Config.EvacuateRerouteSpeedMultiplier or 1.0),
	},
	scatter = {
		name = "scatter",
		priority = 30,
		spawnPaused = true,
		populationOverride = 0,
		drainEnabled = false,
		drainBatchSize = 0,
		drainCheckInterval = 0,
		rerouteToNearest = true,
		rerouteSpeedMultiplier = math.max(0.1, Config.ScatterRerouteSpeedMultiplier or 1.0),
	},
}

local activeModes = {}
local currentModeName = "normal"
local npcDesyncRemote: RemoteEvent? = nil

local function diagnostics(message: string)
	if Config.DiagnosticsEnabled then
		print(message)
	end
end

local function ensureDesyncRemote(): RemoteEvent
	if npcDesyncRemote and npcDesyncRemote.Parent then
		return npcDesyncRemote
	end

	local remotesFolder = ReplicatedStorage:FindFirstChild("WanderingPropsRemotes")
	if not remotesFolder then
		remotesFolder = Instance.new("Folder")
		remotesFolder.Name = "WanderingPropsRemotes"
		remotesFolder.Parent = ReplicatedStorage
	end

	local existing = remotesFolder:FindFirstChild(Remotes.NPCDesync)
	if existing and existing:IsA("RemoteEvent") then
		npcDesyncRemote = existing
		return npcDesyncRemote
	end
	if existing then
		existing:Destroy()
	end

	npcDesyncRemote = Instance.new("RemoteEvent")
	npcDesyncRemote.Name = Remotes.NPCDesync
	npcDesyncRemote.Parent = remotesFolder
	return npcDesyncRemote
end

local function applyModeDefinition(modeDef, previousModeDef)
	PopulationHooks.spawnPaused = modeDef.spawnPaused
	PopulationHooks.populationOverride = modeDef.populationOverride
	PopulationHooks.drainEnabled = modeDef.drainEnabled
	PopulationHooks.drainBatchSize = modeDef.drainBatchSize
	PopulationHooks.drainCheckInterval = modeDef.drainCheckInterval

	if modeDef.rerouteToNearest and (not previousModeDef or not previousModeDef.rerouteToNearest) then
		if PopulationHooks.rerouteAllToNearestDespawn then
			local speedMultiplier = math.max(0.1, modeDef.rerouteSpeedMultiplier or 1.0)
			PopulationHooks.rerouteAllToNearestDespawn(speedMultiplier)
		end
	end
end

local function evaluateActiveMode()
	local now = Workspace:GetServerTimeNow()
	local bestName = "normal"
	local bestPriority = MODE_DEFS.normal.priority

	for modeName, activeMode in pairs(activeModes) do
		if activeMode.expiresAt <= now then
			activeModes[modeName] = nil
		else
			local modeDef = MODE_DEFS[modeName]
			if modeDef and modeDef.priority > bestPriority then
				bestName = modeName
				bestPriority = modeDef.priority
			end
		end
	end

	if bestName == currentModeName then
		return
	end

	local previous = currentModeName
	local previousDef = MODE_DEFS[previous] or MODE_DEFS.normal
	currentModeName = bestName
	applyModeDefinition(MODE_DEFS[bestName] or MODE_DEFS.normal, previousDef)
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
	evaluateActiveMode()
end

function WanderingPropsAPI.SetMode(modeName: string, duration: number)
	local modeDef = MODE_DEFS[modeName]
	if not modeDef or modeName == "normal" then
		warn(string.format('[WanderingProps] WARNING: invalid SetMode("%s").', tostring(modeName)))
		return
	end

	local clampedDuration = math.max(0, duration or 0)
	if clampedDuration <= 0 then
		return
	end

	local now = Workspace:GetServerTimeNow()
	local cooldown = math.max(0, Config.ModeRetriggerCooldown or 0)
	local existing = activeModes[modeName]
	if existing and (now - existing.lastTriggeredAt) < cooldown then
		return
	end

	local expiresAt = now + clampedDuration
	activeModes[modeName] = {
		name = modeName,
		expiresAt = expiresAt,
		lastTriggeredAt = now,
	}

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

	local fired, fireErr = pcall(function()
		ensureDesyncRemote():FireClient(player, true)
	end)
	if not fired then
		warn(string.format("[WanderingProps] WARNING: DesyncPlayer failed for %s: %s", player.Name, tostring(fireErr)))
		return
	end

	PopulationHooks.desyncedPlayers[player] = true
	diagnostics(string.format("[WanderingProps] DESYNC player=%s", player.Name))
end

function WanderingPropsAPI.ResyncPlayer(player: Player)
	if not player then
		return
	end
	if not PopulationHooks.desyncedPlayers[player] then
		return
	end

	local fired, fireErr = pcall(function()
		ensureDesyncRemote():FireClient(player, false)
	end)
	if not fired then
		warn(string.format("[WanderingProps] WARNING: ResyncPlayer failed for %s: %s", player.Name, tostring(fireErr)))
		return
	end

	PopulationHooks.desyncedPlayers[player] = nil
	task.defer(function()
		if PopulationHooks.sendBulkSyncToPlayer then
			local sent = PopulationHooks.sendBulkSyncToPlayer(player) or 0
			diagnostics(string.format("[WanderingProps] RESYNC_BULK_SEND player=%s npcs_sent=%d", player.Name, sent))
		end
	end)
end

function WanderingPropsAPI.IsPlayerDesynced(player: Player): boolean
	return player ~= nil and PopulationHooks.desyncedPlayers[player] == true
end

ensureDesyncRemote()
applyModeDefinition(MODE_DEFS.normal, MODE_DEFS.normal)

Players.PlayerRemoving:Connect(function(leavingPlayer)
	PopulationHooks.desyncedPlayers[leavingPlayer] = nil
end)

return WanderingPropsAPI
