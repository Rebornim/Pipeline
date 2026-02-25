--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local sharedRoot = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatConfig = require(sharedRoot:WaitForChild("CombatConfig"))
local CombatTypes = require(sharedRoot:WaitForChild("CombatTypes"))

local serverRoot = ServerScriptService:WaitForChild("CombatFramework")
local HealthManager = require(serverRoot:WaitForChild("Health"):WaitForChild("HealthManager"))

type VehicleConfig = CombatTypes.VehicleConfig
type FighterRuntimeState = CombatTypes.FighterRuntimeState

type FighterRuntimeStateInternal = FighterRuntimeState & {
	prompt: ProximityPrompt?,
	lastReplicationTick: number,
}

type FighterSpawnData = {
	spawnCFrame: CFrame,
	vehicleConfigId: string,
	pilotSeat: Seat,
}

local FighterServer = {}

local fightersByEntityId: { [string]: FighterRuntimeStateInternal } = {}
local fightersByFighterId: { [string]: FighterRuntimeStateInternal } = {}
local pilotToFighterId: { [Player]: string } = {}
local spawnDataByEntityId: { [string]: FighterSpawnData } = {}

local vehicleExitRemote: RemoteEvent? = nil
local exitConnection: RBXScriptConnection? = nil
local playerRemovingConnection: RBXScriptConnection? = nil
local heartbeatConnection: RBXScriptConnection? = nil

local FIGHTER_REP_POS_X = "FighterRepPosX"
local FIGHTER_REP_POS_Y = "FighterRepPosY"
local FIGHTER_REP_POS_Z = "FighterRepPosZ"
local FIGHTER_REP_LOOK_X = "FighterRepLookX"
local FIGHTER_REP_LOOK_Y = "FighterRepLookY"
local FIGHTER_REP_LOOK_Z = "FighterRepLookZ"
local FIGHTER_REP_UP_X = "FighterRepUpX"
local FIGHTER_REP_UP_Y = "FighterRepUpY"
local FIGHTER_REP_UP_Z = "FighterRepUpZ"

local function writeFighterTelemetry(state: FighterRuntimeStateInternal)
	local primaryPart = state.primaryPart
	if primaryPart.Parent == nil then
		return
	end

	local cf = primaryPart.CFrame
	local pos = cf.Position
	local look = cf.LookVector
	local up = cf.UpVector
	local speed = primaryPart.AssemblyLinearVelocity.Magnitude

	state.instance:SetAttribute("VehicleSpeed", speed)
	state.instance:SetAttribute("VehicleHeading", math.atan2(-look.X, -look.Z))
	state.instance:SetAttribute(FIGHTER_REP_POS_X, pos.X)
	state.instance:SetAttribute(FIGHTER_REP_POS_Y, pos.Y)
	state.instance:SetAttribute(FIGHTER_REP_POS_Z, pos.Z)
	state.instance:SetAttribute(FIGHTER_REP_LOOK_X, look.X)
	state.instance:SetAttribute(FIGHTER_REP_LOOK_Y, look.Y)
	state.instance:SetAttribute(FIGHTER_REP_LOOK_Z, look.Z)
	state.instance:SetAttribute(FIGHTER_REP_UP_X, up.X)
	state.instance:SetAttribute(FIGHTER_REP_UP_Y, up.Y)
	state.instance:SetAttribute(FIGHTER_REP_UP_Z, up.Z)
end

local function getVehicleConfig(vehicleConfigId: string): VehicleConfig?
	local vehiclesConfig = CombatConfig.Vehicles
	if type(vehiclesConfig) ~= "table" then
		return nil
	end
	local rawConfig = vehiclesConfig[vehicleConfigId]
	if type(rawConfig) ~= "table" then
		return nil
	end
	return rawConfig :: VehicleConfig
end

local function readNumberAttribute(instance: Instance, name: string): number?
	local raw = instance:GetAttribute(name)
	if type(raw) == "number" then
		return raw
	end
	if type(raw) == "string" then
		return tonumber(raw)
	end
	return nil
end

local function readBoolAttribute(instance: Instance, name: string): boolean?
	local raw = instance:GetAttribute(name)
	if type(raw) == "boolean" then
		return raw
	end
	if type(raw) == "number" then
		return raw ~= 0
	end
	if type(raw) == "string" then
		local normalized = string.lower(string.match(raw, "^%s*(.-)%s*$") or "")
		if normalized == "true" or normalized == "1" or normalized == "yes" or normalized == "on" then
			return true
		end
		if normalized == "false" or normalized == "0" or normalized == "no" or normalized == "off" then
			return false
		end
	end
	return nil
end

local function applyPercentModifier(baseValue: number, modifier: number?, minValue: number?): number
	local adjusted = baseValue
	if modifier ~= nil then
		adjusted = baseValue * (1 + modifier)
	end
	if minValue ~= nil then
		adjusted = math.max(minValue, adjusted)
	end
	return adjusted
end

local function resolveVehicleConfig(instance: Model, fallbackConfigId: string): VehicleConfig?
	local category = instance:GetAttribute("VehicleCategory")
	if type(category) ~= "string" then
		category = instance:GetAttribute("VehicleConfigId")
	end
	if type(category) ~= "string" then
		category = fallbackConfigId
	end

	local baseConfig = getVehicleConfig(category)
	if baseConfig == nil then
		return nil
	end

	local resolved: { [string]: any } = {}
	for key, value in pairs(baseConfig :: any) do
		resolved[key] = value
	end

	local percentModifiers: { { string } } = {
		{ "VehicleMaxSpeedMod", "maxSpeed" },
		{ "VehicleAccelerationMod", "acceleration" },
		{ "VehicleDecelerationMod", "deceleration" },
		{ "VehicleCollisionRadiusMod", "collisionRadius" },
		{ "VehicleCollisionBounceMod", "collisionBounce" },
		{ "VehicleCameraDistanceMod", "cameraDistance" },
		{ "VehicleCameraHeightMod", "cameraHeight" },
		{ "VehicleCameraLerpMod", "cameraLerpSpeed" },
	}

	for _, entry in ipairs(percentModifiers) do
		local attrName = entry[1]
		local configKey = entry[2]
		local mod = readNumberAttribute(instance, attrName)
		if mod ~= nil and type(resolved[configKey]) == "number" then
			resolved[configKey] = applyPercentModifier(resolved[configKey], mod, 0)
		end
	end

	local minSpeedMod = readNumberAttribute(instance, "VehicleMinSpeedMod")
	if minSpeedMod ~= nil and type(resolved.minSpeed) == "number" then
		resolved.minSpeed = applyPercentModifier(resolved.minSpeed, minSpeedMod, 0)
	end

	local canCrossWater = readBoolAttribute(instance, "VehicleCanCrossWater")
	if canCrossWater ~= nil then
		resolved.canCrossWater = canCrossWater
	end

	return resolved :: any
end

local function getFighterByPilot(player: Player): FighterRuntimeStateInternal?
	local fighterId = pilotToFighterId[player]
	if fighterId == nil then
		return nil
	end
	return fightersByFighterId[fighterId]
end

local function setPilotCharacterControl(player: Player, enabled: boolean)
	local character = player.Character
	if character == nil then
		return
	end

	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp ~= nil and hrp:IsA("BasePart") then
		if enabled then
			pcall(function()
				(hrp :: BasePart):SetNetworkOwner(nil)
			end)
		else
			pcall(function()
				(hrp :: BasePart):SetNetworkOwnershipAuto()
			end)
		end
	end
end

local function clearPilot(state: FighterRuntimeStateInternal)
	local previousPilot = state.pilot
	if previousPilot ~= nil and pilotToFighterId[previousPilot] == state.fighterId then
		pilotToFighterId[previousPilot] = nil
		setPilotCharacterControl(previousPilot, false)
	end
	state.pilot = nil
end

local function updatePilotFromSeat(state: FighterRuntimeStateInternal)
	local occupant = state.pilotSeat.Occupant
	if occupant ~= nil then
		local character = occupant.Parent
		local player = if character ~= nil then Players:GetPlayerFromCharacter(character) else nil
		if player ~= nil then
			local previousPilot = state.pilot
			if previousPilot ~= nil and previousPilot ~= player and pilotToFighterId[previousPilot] == state.fighterId then
				pilotToFighterId[previousPilot] = nil
				setPilotCharacterControl(previousPilot, false)
			end

			state.pilot = player
			pilotToFighterId[player] = state.fighterId

			local useForceFlight = state.config.fighterUseForceFlight == true
			state.primaryPart.Anchored = false
			state.bodyVelocity.MaxForce = if useForceFlight then Vector3.zero else Vector3.new(math.huge, math.huge, math.huge)
			state.bodyVelocity.Velocity = Vector3.zero
			state.bodyGyro.MaxTorque = Vector3.new(math.huge, math.huge, math.huge)
			state.bodyGyro.CFrame = state.primaryPart.CFrame
			state.vectorForce.Force = Vector3.zero
			state.vectorForce.Enabled = useForceFlight
			local assemblyRoot = state.primaryPart.AssemblyRootPart or state.primaryPart
			local ownerOk, ownerErr = pcall(function()
				assemblyRoot:SetNetworkOwner(player)
			end)
			if not ownerOk then
				warn(string.format("[P10_OWNER] SetNetworkOwner failed on %s: %s", assemblyRoot:GetFullName(), tostring(ownerErr)))
			else
				print(string.format("[P10_OWNER] owner=%s root=%s", player.Name, assemblyRoot.Name))
			end

			if state.prompt ~= nil then
				state.prompt.Enabled = false
			end
			return
		end
	end

	if state.pilot ~= nil then
		clearPilot(state)
	end

	state.bodyVelocity.MaxForce = Vector3.zero
	state.bodyVelocity.Velocity = Vector3.zero
	state.bodyGyro.MaxTorque = Vector3.zero
	state.vectorForce.Enabled = false
	state.vectorForce.Force = Vector3.zero
	pcall(function()
		state.primaryPart:SetNetworkOwner(nil)
	end)
	state.primaryPart.Anchored = true
	writeFighterTelemetry(state)

	if state.prompt ~= nil then
		state.prompt.Enabled = true
	end
end

local function cleanupFighterState(state: FighterRuntimeStateInternal)
	for _, connection in ipairs(state.connections) do
		connection:Disconnect()
	end
	table.clear(state.connections)

	if state.pilot ~= nil then
		local player = state.pilot
		clearPilot(state)
		local character = player.Character
		if character ~= nil then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if humanoid ~= nil then
				humanoid.Sit = false
			end
		end
	end

	state.bodyVelocity.MaxForce = Vector3.zero
	state.bodyVelocity.Velocity = Vector3.zero
	state.bodyGyro.MaxTorque = Vector3.zero
	state.vectorForce.Enabled = false
	state.vectorForce.Force = Vector3.zero
	pcall(function()
		state.primaryPart:SetNetworkOwner(nil)
	end)
	state.primaryPart.Anchored = true

	if state.prompt ~= nil then
		state.prompt:Destroy()
		state.prompt = nil
	end

	state.instance:SetAttribute("VehicleSpeed", nil)
	state.instance:SetAttribute("VehicleHeading", nil)
	state.instance:SetAttribute(FIGHTER_REP_POS_X, nil)
	state.instance:SetAttribute(FIGHTER_REP_POS_Y, nil)
	state.instance:SetAttribute(FIGHTER_REP_POS_Z, nil)
	state.instance:SetAttribute(FIGHTER_REP_LOOK_X, nil)
	state.instance:SetAttribute(FIGHTER_REP_LOOK_Y, nil)
	state.instance:SetAttribute(FIGHTER_REP_LOOK_Z, nil)
	state.instance:SetAttribute(FIGHTER_REP_UP_X, nil)
	state.instance:SetAttribute(FIGHTER_REP_UP_Y, nil)
	state.instance:SetAttribute(FIGHTER_REP_UP_Z, nil)
	fightersByEntityId[state.entityId] = nil
	fightersByFighterId[state.fighterId] = nil
end

function FighterServer.onEntityDestroyed(entityId: string): ()
	local state = fightersByEntityId[entityId]
	if state == nil then
		return
	end
	cleanupFighterState(state)
end

function FighterServer.onEntityRespawned(entityId: string): ()
	local spawnData = spawnDataByEntityId[entityId]
	if spawnData == nil then
		return
	end
	if fightersByEntityId[entityId] ~= nil then
		return
	end

	local instance = spawnData.pilotSeat:FindFirstAncestorOfClass("Model")
	if instance == nil or instance.PrimaryPart == nil then
		return
	end
	instance:PivotTo(spawnData.spawnCFrame)

	FighterServer.registerFighter(entityId, instance, spawnData.vehicleConfigId, spawnData.pilotSeat)
end

function FighterServer.registerFighter(entityId: string, instance: Model, vehicleConfigId: string, pilotSeat: Seat): ()
	if fightersByEntityId[entityId] ~= nil then
		FighterServer.onEntityDestroyed(entityId)
	end

	spawnDataByEntityId[entityId] = {
		spawnCFrame = instance:GetPivot(),
		vehicleConfigId = vehicleConfigId,
		pilotSeat = pilotSeat,
	}

	local config = resolveVehicleConfig(instance, vehicleConfigId)
	if config == nil then
		config = getVehicleConfig(vehicleConfigId)
	end
	if config == nil then
		warn("[FIGHTER_ERROR] Missing fighter config for " .. instance.Name)
		return
	end

	local primaryPart = instance.PrimaryPart
	if primaryPart == nil then
		warn("[FIGHTER_ERROR] No PrimaryPart for " .. instance.Name)
		return
	end

	primaryPart.Anchored = false
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") and descendant ~= primaryPart then
			descendant.Anchored = false
			if descendant:FindFirstChildOfClass("WeldConstraint") == nil then
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = descendant
				weld.Part1 = primaryPart
				weld.Parent = descendant
			end
		end
	end

	local bodyVel = primaryPart:FindFirstChildOfClass("BodyVelocity")
	if bodyVel == nil then
		bodyVel = Instance.new("BodyVelocity")
		bodyVel.Name = "BodyVelocity"
		bodyVel.P = 10000
		bodyVel.Parent = primaryPart
	end
	bodyVel.MaxForce = Vector3.zero
	bodyVel.Velocity = Vector3.zero

	local bodyGyro = primaryPart:FindFirstChildOfClass("BodyGyro")
	if bodyGyro == nil then
		bodyGyro = Instance.new("BodyGyro")
		bodyGyro.Name = "BodyGyro"
		bodyGyro.P = 50000
		bodyGyro.D = 1000
		bodyGyro.Parent = primaryPart
	end
	bodyGyro.MaxTorque = Vector3.zero
	bodyGyro.CFrame = primaryPart.CFrame

	local forceAttachment = primaryPart:FindFirstChild("FighterForceAttachment")
	if forceAttachment == nil or not forceAttachment:IsA("Attachment") then
		if forceAttachment ~= nil then
			forceAttachment:Destroy()
		end
		forceAttachment = Instance.new("Attachment")
		forceAttachment.Name = "FighterForceAttachment"
		forceAttachment.Parent = primaryPart
	end

	local vectorForce = primaryPart:FindFirstChild("FighterVectorForce")
	if vectorForce == nil or not vectorForce:IsA("VectorForce") then
		if vectorForce ~= nil then
			vectorForce:Destroy()
		end
		vectorForce = Instance.new("VectorForce")
		vectorForce.Name = "FighterVectorForce"
		vectorForce.Parent = primaryPart
	end
	local fighterVectorForce = vectorForce :: VectorForce
	fighterVectorForce.Attachment0 = forceAttachment :: Attachment
	fighterVectorForce.RelativeTo = Enum.ActuatorRelativeTo.World
	fighterVectorForce.ApplyAtCenterOfMass = true
	fighterVectorForce.Enabled = false
	fighterVectorForce.Force = Vector3.zero

	-- Keep ship parked until pilot enters.
	primaryPart.Anchored = true

	local state: FighterRuntimeStateInternal = {
		fighterId = entityId,
		entityId = entityId,
		instance = instance,
		primaryPart = primaryPart,
		pilotSeat = pilotSeat,
		config = config,
		pilot = nil,
		bodyVelocity = bodyVel :: BodyVelocity,
		bodyGyro = bodyGyro :: BodyGyro,
		vectorForce = fighterVectorForce,
		connections = {},
		prompt = nil,
		lastReplicationTick = 0,
	}

	local prompt = pilotSeat:FindFirstChildOfClass("ProximityPrompt")
	if prompt == nil then
		prompt = Instance.new("ProximityPrompt")
		prompt.Name = "PilotFighterPrompt"
		prompt.Parent = pilotSeat
	end
	prompt.ActionText = "Pilot"
	prompt.ObjectText = instance.Name
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 16
	prompt.RequiresLineOfSight = false
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	state.prompt = prompt

	table.insert(state.connections, prompt.Triggered:Connect(function(player: Player)
		if state.pilot ~= nil then
			return
		end
		if not HealthManager.isAlive(state.entityId) then
			return
		end
		local character = player.Character
		if character == nil then
			return
		end
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid == nil then
			return
		end
		pilotSeat:Sit(humanoid)
	end))

	table.insert(state.connections, pilotSeat:GetPropertyChangedSignal("Occupant"):Connect(function()
		updatePilotFromSeat(state)
	end))

	updatePilotFromSeat(state)
	fightersByEntityId[entityId] = state
	fightersByFighterId[state.fighterId] = state

	writeFighterTelemetry(state)
end

function FighterServer.init(remotesFolder: Folder): ()
	vehicleExitRemote = remotesFolder:WaitForChild("VehicleExitRequest") :: RemoteEvent

	if exitConnection == nil then
		exitConnection = vehicleExitRemote.OnServerEvent:Connect(function(player: Player)
			local state = getFighterByPilot(player)
			if state == nil then
				return
			end
			local character = player.Character
			if character == nil then
				return
			end
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if humanoid ~= nil then
				humanoid.Sit = false
			end
		end)
	end

	if playerRemovingConnection == nil then
		playerRemovingConnection = Players.PlayerRemoving:Connect(function(player: Player)
			local state = getFighterByPilot(player)
			if state == nil then
				return
			end
			clearPilot(state)
			state.bodyVelocity.MaxForce = Vector3.zero
			state.bodyVelocity.Velocity = Vector3.zero
			state.bodyGyro.MaxTorque = Vector3.zero
			state.vectorForce.Enabled = false
			state.vectorForce.Force = Vector3.zero
			pcall(function()
				state.primaryPart:SetNetworkOwner(nil)
			end)
			state.primaryPart.Anchored = true
			writeFighterTelemetry(state)
		end)
	end

	if heartbeatConnection == nil then
		heartbeatConnection = RunService.Heartbeat:Connect(function()
			local replicationRate = CombatConfig.VehicleReplicationRateActive
			if type(replicationRate) ~= "number" or replicationRate <= 0 then
				replicationRate = 30
			end
			local writeInterval = 1 / math.clamp(replicationRate, 5, 60)
			local now = os.clock()
			for _, state in pairs(fightersByEntityId) do
				if state.instance.Parent == nil or state.primaryPart.Parent == nil then
					continue
				end
				if state.pilot == nil then
					continue
				end
				if (now - state.lastReplicationTick) < writeInterval then
					continue
				end
				state.lastReplicationTick = now
				writeFighterTelemetry(state)
			end
		end)
	end
end

return FighterServer
