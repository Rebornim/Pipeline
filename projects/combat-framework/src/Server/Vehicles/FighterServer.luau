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
	hasPilotedOnce: boolean,
	lastOwnershipVerifyTick: number,
	lastOccupantSeenTick: number,
	pilotSeatMissingSince: number,
	exitRequestedAt: number,
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

local FIGHTER_CRASH_DEFAULT_SPEED = 85
local FIGHTER_CRASH_MIN_HEADING_INTO_SURFACE = 0.35
local FIGHTER_CRASH_MIN_PROBE_DISTANCE = 4
local FIGHTER_CRASH_MAX_PROBE_DISTANCE = 40
local FIGHTER_OCCUPANT_GRACE_SECONDS = 1.5
local FIGHTER_EXIT_GRACE_SECONDS = 1.0
local FIGHTER_TELEMETRY_RATE = 15

local function writeFighterTelemetry(state: FighterRuntimeStateInternal)
	local primaryPart = state.primaryPart
	if primaryPart.Parent == nil then
		return
	end

	local look = primaryPart.CFrame.LookVector
	local speed = primaryPart.AssemblyLinearVelocity.Magnitude

	state.instance:SetAttribute("VehicleSpeed", speed)
	state.instance:SetAttribute("VehicleHeading", math.atan2(-look.X, -look.Z))
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
		{ "VehicleMinSpeedMod", "minSpeed" },
		{ "VehicleMaxSpeedMod", "maxSpeed" },
		{ "VehicleAccelerationMod", "acceleration" },
		{ "VehicleDecelerationMod", "deceleration" },
		{ "VehicleBoostSpeedMod", "boostSpeedMultiplier" },
		{ "VehicleBoostDurationMod", "boostDuration" },
		{ "VehicleBoostCooldownMod", "boostCooldown" },
		{ "VehicleCollisionRadiusMod", "collisionRadius" },
		{ "VehicleCollisionBounceMod", "collisionBounce" },
		{ "VehicleCameraDistanceMod", "cameraDistance" },
		{ "VehicleCameraHeightMod", "cameraHeight" },
		{ "VehicleCameraLerpMod", "cameraLerpSpeed" },
		{ "VehicleFighterYawRateMod", "yawRate" },
		{ "VehicleFighterPitchRateMod", "pitchRate" },
		{ "VehicleFighterRollRateMod", "rollRate" },
		{ "VehicleFighterTurnScaleMinMod", "turnRateSpeedScaleMin" },
		{ "VehicleFighterTurnScaleMaxMod", "turnRateSpeedScaleMax" },
		{ "VehicleFighterAngularResponsivenessMod", "angularResponsiveness" },
		{ "VehicleFighterAutoBankMaxAngleMod", "autoBankMaxAngle" },
		{ "VehicleFighterAutoBankYawRefMod", "autoBankYawRateRef" },
		{ "VehicleFighterAutoBankRateMod", "autoBankRate" },
		{ "VehicleFighterMouseSensitivityMod", "fighterMouseSensitivity" },
		{ "VehicleFighterMouseRangeXMod", "fighterMouseRangeX" },
		{ "VehicleFighterMouseRangeYMod", "fighterMouseRangeY" },
		{ "VehicleFighterMouseAutoCenterMod", "fighterMouseAutoCenter" },
		{ "VehicleFighterMouseDeadzoneMod", "fighterMouseDeadzone" },
		{ "VehicleFighterMouseCenterReturnRadiusMod", "fighterMouseCenterReturnRadius" },
		{ "VehicleFighterCursorLagRateMod", "fighterCursorLagRate" },
		{ "VehicleFighterInputExpoMod", "fighterInputExpo" },
		{ "VehicleFighterThrottleSpoolUpMod", "fighterThrottleSpoolUp" },
		{ "VehicleFighterThrottleSpoolDownMod", "fighterThrottleSpoolDown" },
		{ "VehicleFighterThrottleDeadzoneMod", "fighterThrottleDeadzone" },
		{ "VehicleFighterForceVelocityGainMod", "fighterForceVelocityGain" },
		{ "VehicleFighterForceMaxAccelMod", "fighterForceMaxAccel" },
		{ "VehicleFighterYawAccelLimitMod", "fighterYawRateAccelLimit" },
		{ "VehicleFighterPitchAccelLimitMod", "fighterPitchRateAccelLimit" },
		{ "VehicleFighterRollAccelLimitMod", "fighterRollRateAccelLimit" },
		{ "VehicleFighterAngularDampingMod", "fighterAngularDamping" },
		{ "VehicleFighterVelocityAlignRateMod", "fighterVelocityAlignRate" },
		{ "VehicleFighterVelocityDirAlignBaseMod", "fighterVelocityDirAlignBase" },
		{ "VehicleFighterVelocityDirAlignTurnBoostMod", "fighterVelocityDirAlignTurnBoost" },
		{ "VehicleFighterTurnAlignBoostMod", "fighterTurnAlignBoost" },
		{ "VehicleFighterTurnSpeedPenaltyMod", "fighterTurnSpeedPenalty" },
		{ "VehicleFighterSideSlipDampingMod", "fighterSideSlipDamping" },
		{ "VehicleFighterTurnSlipDampingBoostMod", "fighterTurnSlipDampingBoost" },
		{ "VehicleFighterVerticalSlipDampingMod", "fighterVerticalSlipDamping" },
		{ "VehicleFighterTurnVerticalDampingBoostMod", "fighterTurnVerticalDampingBoost" },
		{ "VehicleFighterTurnEnergyLossMod", "fighterTurnEnergyLoss" },
		{ "VehicleFighterForwardAccelLimitMod", "fighterForwardAccelLimit" },
		{ "VehicleFighterForwardDecelLimitMod", "fighterForwardDecelLimit" },
		{ "VehicleFighterInducedDragMod", "fighterInducedDrag" },
		{ "VehicleFighterWorldGravityMod", "fighterWorldGravity" },
		{ "VehicleFighterLiftCoefficientMod", "fighterLiftCoefficient" },
		{ "VehicleFighterBaseDragMod", "fighterBaseDrag" },
		{ "VehicleFighterVisualYawRateGainMod", "fighterVisualYawRateGain" },
		{ "VehicleFighterVisualPitchRateGainMod", "fighterVisualPitchRateGain" },
		{ "VehicleFighterVisualYawAccelGainMod", "fighterVisualYawAccelGain" },
		{ "VehicleFighterVisualPitchAccelGainMod", "fighterVisualPitchAccelGain" },
		{ "VehicleFighterVisualSlipYawGainMod", "fighterVisualSlipYawGain" },
		{ "VehicleFighterVisualSlipPitchGainMod", "fighterVisualSlipPitchGain" },
		{ "VehicleFighterVisualRollRateGainMod", "fighterVisualRollRateGain" },
		{ "VehicleFighterVisualResponseMod", "fighterVisualResponse" },
		{ "VehicleFighterVisualYawMaxMod", "fighterVisualYawMax" },
		{ "VehicleFighterVisualPitchMaxMod", "fighterVisualPitchMax" },
		{ "VehicleFighterVisualRollMaxMod", "fighterVisualRollMax" },
		{ "VehicleFighterTakeoffHeightMod", "fighterTakeoffHeight" },
		{ "VehicleFighterTakeoffDurationMod", "fighterTakeoffDuration" },
		{ "VehicleFighterCameraRollFollowMod", "fighterCameraRollFollow" },
		{ "VehicleFighterCameraAimHeightMod", "fighterCameraAimHeight" },
		{ "VehicleFighterCameraAimHeightSpeedBoostMod", "fighterCameraAimHeightSpeedBoost" },
		{ "VehicleFighterCameraLookAheadMod", "fighterCameraLookAhead" },
		{ "VehicleFighterCameraOrientLagMod", "fighterCameraOrientLag" },
	}

	for _, entry in ipairs(percentModifiers) do
		local attrName = entry[1]
		local configKey = entry[2]
		local mod = readNumberAttribute(instance, attrName)
		if mod ~= nil and type(resolved[configKey]) == "number" then
			resolved[configKey] = applyPercentModifier(resolved[configKey], mod, 0)
		end
	end

	local canCrossWater = readBoolAttribute(instance, "VehicleCanCrossWater")
	if canCrossWater ~= nil then
		resolved.canCrossWater = canCrossWater
	end
	local boostEnabled = readBoolAttribute(instance, "VehicleBoostEnabled")
	if boostEnabled ~= nil then
		resolved.boostEnabled = boostEnabled
	end
	local fighterUseForceFlight = readBoolAttribute(instance, "VehicleFighterUseForceFlight")
	if fighterUseForceFlight ~= nil then
		resolved.fighterUseForceFlight = fighterUseForceFlight
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

local function isPilotCharacterStillSeatedInState(state: FighterRuntimeStateInternal): boolean
	local pilot = state.pilot
	if pilot == nil then
		return false
	end
	local character = pilot.Character
	if character == nil then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return false
	end
	return humanoid.SeatPart == state.pilotSeat
end

local function zeroAssemblyMotion(part: BasePart)
	part.AssemblyLinearVelocity = Vector3.zero
	part.AssemblyAngularVelocity = Vector3.zero
end

local function disableFighterDrive(state: FighterRuntimeStateInternal)
	state.bodyVelocity.MaxForce = Vector3.zero
	state.bodyVelocity.Velocity = Vector3.zero
	state.bodyGyro.MaxTorque = Vector3.zero
	state.vectorForce.Enabled = false
	state.vectorForce.Force = Vector3.zero
	state.instance:SetAttribute("VehicleBoosting", false)
end

local function parkFighter(state: FighterRuntimeStateInternal)
	disableFighterDrive(state)
	pcall(function()
		state.primaryPart:SetNetworkOwner(nil)
	end)
	zeroAssemblyMotion(state.primaryPart)
	state.primaryPart.Anchored = true
	writeFighterTelemetry(state)
	if state.prompt ~= nil then
		local oldPrompt = state.prompt
		local parent = oldPrompt.Parent
		local objectText = oldPrompt.ObjectText
		local actionText = oldPrompt.ActionText
		local maxDist = oldPrompt.MaxActivationDistance
		local keyCode = oldPrompt.KeyboardKeyCode
		local holdDuration = oldPrompt.HoldDuration
		local requiresLOS = oldPrompt.RequiresLineOfSight

		oldPrompt:Destroy()

		local newPrompt = Instance.new("ProximityPrompt")
		newPrompt.ObjectText = objectText
		newPrompt.ActionText = actionText
		newPrompt.MaxActivationDistance = maxDist
		newPrompt.KeyboardKeyCode = keyCode
		newPrompt.HoldDuration = holdDuration
		newPrompt.RequiresLineOfSight = requiresLOS
		newPrompt.Enabled = true
		newPrompt.Parent = parent

		state.prompt = newPrompt

		table.insert(state.connections, newPrompt.Triggered:Connect(function(player: Player)
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
			if humanoid.Sit then
				return
			end
			state.pilotSeat:Sit(humanoid)
		end))

		print(string.format(
			"[P10_PROMPT] parkFighter recreated prompt parent=%s enabled=%s",
			tostring(parent and parent:GetFullName() or "nil"),
			tostring(newPrompt.Enabled)
		))
	end
end

local function releaseFighterMomentum(state: FighterRuntimeStateInternal)
	disableFighterDrive(state)
	pcall(function()
		state.primaryPart:SetNetworkOwner(nil)
	end)
	state.primaryPart.Anchored = false
	state.instance:SetAttribute("VehicleSpeed", state.primaryPart.AssemblyLinearVelocity.Magnitude)
	state.instance:SetAttribute("VehicleHeading", nil)
	if state.prompt ~= nil then
		state.prompt.Enabled = true
	end
end

local function getFighterCrashSpeedThreshold(state: FighterRuntimeStateInternal): number
	local modelOverride = readNumberAttribute(state.instance, "VehicleFighterCrashSpeed")
	if modelOverride ~= nil and modelOverride > 0 then
		return modelOverride
	end
	local configThreshold = state.config.collisionDamageThreshold
	if type(configThreshold) == "number" and configThreshold > 0 then
		return configThreshold
	end
	return FIGHTER_CRASH_DEFAULT_SPEED
end

local function checkFighterCrash(state: FighterRuntimeStateInternal, dt: number)
	if state.primaryPart.Anchored then
		return
	end
	if not HealthManager.isAlive(state.entityId) then
		return
	end

	local velocity = state.primaryPart.AssemblyLinearVelocity
	local speed = velocity.Magnitude
	local crashSpeed = getFighterCrashSpeedThreshold(state)
	if speed < crashSpeed then
		return
	end

	local direction = velocity.Unit
	local lookaheadFrames = CombatConfig.VehicleCollisionLookahead
	if type(lookaheadFrames) ~= "number" or lookaheadFrames <= 0 then
		lookaheadFrames = 2.0
	end
	local collisionRadius = state.config.collisionRadius
	if type(collisionRadius) ~= "number" or collisionRadius <= 0 then
		collisionRadius = 5
	end
	local probeDistance = math.clamp(
		speed * math.max(dt, 1 / 120) * lookaheadFrames + collisionRadius,
		FIGHTER_CRASH_MIN_PROBE_DISTANCE,
		FIGHTER_CRASH_MAX_PROBE_DISTANCE
	)

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	local filter: { Instance } = { state.instance }
	if state.pilot ~= nil and state.pilot.Character ~= nil then
		table.insert(filter, state.pilot.Character)
	end
	rayParams.FilterDescendantsInstances = filter
	rayParams.IgnoreWater = false

	local hit = Workspace:Raycast(state.primaryPart.Position, direction * probeDistance, rayParams)
	if hit == nil then
		return
	end
	if hit.Instance == nil or not hit.Instance.CanCollide then
		return
	end

	local headingIntoSurface = math.clamp(-hit.Normal:Dot(direction), 0, 1)
	if headingIntoSurface < FIGHTER_CRASH_MIN_HEADING_INTO_SURFACE then
		return
	end
	local impactSpeed = speed * headingIntoSurface
	if impactSpeed < crashSpeed then
		return
	end

	local faction = HealthManager.getFaction(state.entityId) or ""
	print(string.format("[FIGHTER_CRASH] entity=%s speed=%.1f hit=%s", state.entityId, impactSpeed, hit.Instance:GetFullName()))
	HealthManager.applyDamage(state.entityId, 99999, "impact", faction, hit.Position, true)
end

local function ensurePilotOwnership(state: FighterRuntimeStateInternal, now: number)
	local pilot = state.pilot
	if pilot == nil then
		return
	end
	if (now - state.lastOwnershipVerifyTick) < 2.0 then
		return
	end
	state.lastOwnershipVerifyTick = now

	local ownerOk, currentOwner = pcall(function()
		return state.primaryPart:GetNetworkOwner()
	end)
	if not ownerOk or currentOwner ~= pilot then
		local ownerName = "nil"
		if ownerOk and typeof(currentOwner) == "Instance" and (currentOwner :: Instance):IsA("Player") then
			ownerName = (currentOwner :: Player).Name
		end
		-- Log only: do not reassert ownership, which can cause authority handoff stutters.
		warn(string.format(
			"[P10F2_S4] ownership_mismatch pilot=%s owner=%s (log_only, no_reassert)",
			pilot.Name,
			ownerName
		))
	end
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
	state.pilotSeatMissingSince = 0
end

local function updatePilotFromSeat(state: FighterRuntimeStateInternal)
	local now = os.clock()
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
			state.hasPilotedOnce = true
			state.lastOccupantSeenTick = now
			state.pilotSeatMissingSince = 0
			state.exitRequestedAt = 0

			local useForceFlight = state.config.fighterUseForceFlight == true
			state.primaryPart.Anchored = false
			zeroAssemblyMotion(state.primaryPart)
			state.bodyVelocity.MaxForce = if useForceFlight then Vector3.zero else Vector3.new(math.huge, math.huge, math.huge)
			state.bodyVelocity.Velocity = Vector3.zero
			state.bodyGyro.MaxTorque = Vector3.new(math.huge, math.huge, math.huge)
			state.bodyGyro.CFrame = state.primaryPart.CFrame
			state.vectorForce.Force = Vector3.zero
			state.vectorForce.Enabled = useForceFlight
			state.instance:SetAttribute("VehicleBoosting", false)
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

	local hadPilot = state.pilot ~= nil
	if hadPilot then
		local hasRecentExitRequest = state.exitRequestedAt > 0 and (now - state.exitRequestedAt) <= FIGHTER_EXIT_GRACE_SECONDS
		if not hasRecentExitRequest then
			if isPilotCharacterStillSeatedInState(state) then
				state.lastOccupantSeenTick = now
				state.pilotSeatMissingSince = 0
				return
			end
			if state.pilotSeatMissingSince <= 0 then
				state.pilotSeatMissingSince = now
				-- Safety: anchor immediately to prevent falling while grace period runs.
				state.primaryPart.Anchored = true
				-- Occupant signal fires only once, so schedule a retry after grace period.
				task.delay(FIGHTER_OCCUPANT_GRACE_SECONDS + 0.1, function()
					if fightersByFighterId[state.fighterId] == state and state.pilot ~= nil then
						updatePilotFromSeat(state)
					end
				end)
				return
			end
			if (now - state.pilotSeatMissingSince) < FIGHTER_OCCUPANT_GRACE_SECONDS then
				return
			end
		end
		local clearReason = if hasRecentExitRequest then "exit_request" else "occupant_signal"
		local graceElapsed = if state.pilotSeatMissingSince > 0 then (now - state.pilotSeatMissingSince) else 0
		print(string.format(
			"[FIGHTER_PILOT] clear reason=%s entity=%s grace_elapsed=%.2f",
			clearReason,
			state.entityId,
			graceElapsed
		))
		clearPilot(state)
		state.exitRequestedAt = 0
		parkFighter(state)
	else
		parkFighter(state)
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

	parkFighter(state)

	if state.prompt ~= nil then
		state.prompt:Destroy()
		state.prompt = nil
	end

	state.instance:SetAttribute("VehicleSpeed", nil)
	state.instance:SetAttribute("VehicleHeading", nil)
	state.instance:SetAttribute("VehicleBoosting", nil)
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
		hasPilotedOnce = false,
		lastOwnershipVerifyTick = 0,
		lastOccupantSeenTick = 0,
		pilotSeatMissingSince = 0,
		exitRequestedAt = 0,
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
	prompt.MaxActivationDistance = 50
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
		if humanoid.Sit then
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
			print(string.format("[P10_EXIT_SERVER] exit_remote received player=%s", player.Name))
			local state = getFighterByPilot(player)
			if state == nil then
				return
			end
			state.exitRequestedAt = os.clock()
			parkFighter(state)
			local character = player.Character
			if character == nil then
				return
			end
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if humanoid ~= nil then
				humanoid.Sit = false
			end
			task.defer(function()
				if fightersByFighterId[state.fighterId] == state then
					updatePilotFromSeat(state)
				end
			end)
		end)
	end

	if playerRemovingConnection == nil then
		playerRemovingConnection = Players.PlayerRemoving:Connect(function(player: Player)
			local state = getFighterByPilot(player)
			if state == nil then
				return
			end
			print(string.format(
				"[FIGHTER_PILOT] clear reason=%s entity=%s grace_elapsed=%.2f",
				"player_removing",
				state.entityId,
				0
			))
			clearPilot(state)
			parkFighter(state)
		end)
	end

	if heartbeatConnection == nil then
		heartbeatConnection = RunService.Heartbeat:Connect(function(dt: number)
			local writeInterval = 1 / FIGHTER_TELEMETRY_RATE
			local now = os.clock()
			for _, state in pairs(fightersByEntityId) do
				if state.instance.Parent == nil or state.primaryPart.Parent == nil then
					continue
				end
				checkFighterCrash(state, dt)
				if not HealthManager.isAlive(state.entityId) then
					continue
				end
				ensurePilotOwnership(state, now)
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
