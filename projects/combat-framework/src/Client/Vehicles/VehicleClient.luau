--!strict

local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local localPlayer = Players.LocalPlayer
local playerScripts = localPlayer:WaitForChild("PlayerScripts")
local clientRoot = playerScripts:WaitForChild("CombatFramework")

local sharedRoot = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatConfig = require(sharedRoot:WaitForChild("CombatConfig"))
local CombatTypes = require(sharedRoot:WaitForChild("CombatTypes"))

local CombatHUD = require(clientRoot:WaitForChild("HUD"):WaitForChild("CombatHUD"))
local TargetingClient = require(clientRoot:WaitForChild("Targeting"):WaitForChild("TargetingClient"))
local VehicleCamera = require(clientRoot:WaitForChild("Vehicles"):WaitForChild("VehicleCamera"))
local VehicleVisualSmoother = require(clientRoot:WaitForChild("Vehicles"):WaitForChild("VehicleVisualSmoother"))
local WalkerClient = require(clientRoot:WaitForChild("Vehicles"):WaitForChild("WalkerClient"))
local RemoteVehicleSmoother = require(clientRoot:WaitForChild("Vehicles"):WaitForChild("RemoteVehicleSmoother"))
local SoundProfileLoader = require(clientRoot:WaitForChild("Vehicles"):WaitForChild("SoundProfiles"):WaitForChild("SoundProfileLoader"))
local SoundProfileTypes = require(clientRoot:WaitForChild("Vehicles"):WaitForChild("SoundProfiles"):WaitForChild("SoundProfileTypes"))
type VehicleConfig = CombatTypes.VehicleConfig
type VehicleInputPayload = CombatTypes.VehicleInputPayload

local VehicleClient = {}

local EXIT_ACTION_NAME = "CombatExitVehicle"
local LOCK_ACTION_NAME = "CombatVehicleLock"

local vehicleInputRemote: RemoteEvent? = nil
local vehicleExitRemote: RemoteEvent? = nil
local seatConnection: RBXScriptConnection? = nil
local characterAddedConnection: RBXScriptConnection? = nil
local inputConnection: RBXScriptConnection? = nil
local scrollConnection: RBXScriptConnection? = nil
local landingShakeConnection: RBXScriptConnection? = nil
local misfireVisualConnection: RBXScriptConnection? = nil

local activeVehicleEntityId: string? = nil
local activeVehicleModel: Model? = nil
local activeVehicleRenderModel: Model? = nil
local activeVehicleConfig: VehicleConfig? = nil
local inputAccumulator = 0
local virtualCursorX = 0
local virtualCursorY = 0
local savedMouseBehavior: Enum.MouseBehavior? = nil
local savedMouseIconEnabled: boolean? = nil
local previousClientLean = 0
local freelookActive = false
local lastSentThrottle: number = 0
local lastSentSteerX: number = 0
local lastSentLean: number = 0
local lastSentTick: number = 0
local INPUT_REFRESH_INTERVAL = 1.0
local INPUT_STEER_DEADBAND = 0.02
-- Sound/VFX profile controller
local activeProfileController: SoundProfileTypes.ProfileController? = nil
local previousBoostActive: boolean = false
local previousHpFraction: number = 1

-- Vehicle weapon state
local activeVehicleHasWeapon: boolean = false
local fireWeaponRemote: RemoteEvent? = nil
local updateTurretAimRemote: RemoteEvent? = nil
local lastVehicleHeatRecoverCueId: number = 0
local nextVehicleFireSoundTime: number = 0

-- Boost tracking (for camera FOV, kept here since profile handles sound/VFX)
local boostActive: boolean = false
local boostConnection: RBXScriptConnection? = nil

local VEHICLE_POOL_COPIES = 6
local vehicleFireSoundPool: { Sound } = {}
local vehicleFireSoundPoolIndex: number = 0

local function buildVehicleFireSoundPool()
	for _, s in ipairs(vehicleFireSoundPool) do s:Destroy() end
	table.clear(vehicleFireSoundPool)
	vehicleFireSoundPoolIndex = 0

	local model = activeVehicleModel
	if model == nil then return end
	local groupKey: string? = nil
	local raw = model:GetAttribute("FireSound")
	if type(raw) == "string" and raw ~= "" then
		groupKey = raw
	end
	if groupKey == nil then return end

	local group = CombatConfig.WeaponSounds[groupKey]
	if type(group) ~= "table" then return end
	local entry = (group :: any).fire
	local rawVolume = (group :: any).fireVolume
	local volume: number = if type(rawVolume) == "number" then rawVolume else 1
	local ids: { string } = {}
	if type(entry) == "string" and entry ~= "" then
		table.insert(ids, entry)
	elseif type(entry) == "table" then
		for _, id in ipairs(entry) do
			if type(id) == "string" and id ~= "" then
				table.insert(ids, id)
			end
		end
	end
	if #ids == 0 then return end

	local parent: Instance = if model.PrimaryPart ~= nil then model.PrimaryPart else (model :: Instance)
	for _ = 1, VEHICLE_POOL_COPIES do
		for _, id in ipairs(ids) do
			local sound = Instance.new("Sound")
			sound.SoundId = id
			sound.Volume = volume
			sound.Looped = false
			sound.Parent = parent
			table.insert(vehicleFireSoundPool, sound)
		end
	end
end

local function destroyVehicleFireSoundPool()
	for _, s in ipairs(vehicleFireSoundPool) do s:Destroy() end
	table.clear(vehicleFireSoundPool)
	vehicleFireSoundPoolIndex = 0
end

local function playVehicleInstantFireSound()
	local now = tick()
	if now < nextVehicleFireSoundTime then return end
	if #vehicleFireSoundPool == 0 then return end

	local model = activeVehicleModel
	if model ~= nil then
		local configId = model:GetAttribute("ConfigId")
		if type(configId) == "string" then
			local entityConfig = CombatConfig.Entities[configId]
			if entityConfig ~= nil and entityConfig.weaponId ~= nil then
				local weaponConfig = CombatConfig.Weapons[entityConfig.weaponId]
				if weaponConfig ~= nil and weaponConfig.fireRate > 0 then
					nextVehicleFireSoundTime = now + (1 / weaponConfig.fireRate)
				end
			end
		end
	end

	local sound = vehicleFireSoundPool[math.random(1, #vehicleFireSoundPool)]
	sound.TimePosition = 0
	sound:Play()
end

local function getVehicleInputRate(): number
	local raw = CombatConfig.VehicleInputRate
	if type(raw) ~= "number" or raw <= 0 then
		return 30
	end
	return raw
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

local function resolveVehicleConfig(instance: Model): VehicleConfig?
	local category = instance:GetAttribute("VehicleCategory")
	if type(category) ~= "string" then
		category = instance:GetAttribute("VehicleConfigId")
	end
	if type(category) ~= "string" then
		return nil
	end

	local vehiclesConfig = CombatConfig.Vehicles
	if type(vehiclesConfig) ~= "table" then
		return nil
	end
	local baseConfig = vehiclesConfig[category]
	if type(baseConfig) ~= "table" then
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
		{ "VehicleBrakingMod", "brakingDeceleration" },
		{ "VehicleReverseSpeedMod", "reverseMaxSpeed" },
		{ "VehicleTurnSpeedLowMod", "turnSpeedLow" },
		{ "VehicleTurnSpeedHighMod", "turnSpeedHigh" },
		{ "VehicleLateralGripLowMod", "lateralGripLow" },
		{ "VehicleLateralGripHighMod", "lateralGripHigh" },
		{ "VehicleHoverHeightMod", "hoverHeight" },
		{ "VehicleSpringStiffnessMod", "springStiffness" },
		{ "VehicleSpringDampingMod", "springDamping" },
		{ "VehicleTiltStiffnessMod", "tiltStiffness" },
		{ "VehicleTiltDampingMod", "tiltDamping" },
		{ "VehicleTerrainConformityMod", "terrainConformity" },
		{ "VehicleMaxClimbSlopeMod", "maxClimbSlope" },
		{ "VehicleCollisionRadiusMod", "collisionRadius" },
		{ "VehicleCollisionBounceMod", "collisionBounce" },
		{ "VehicleCollisionDmgThresholdMod", "collisionDamageThreshold" },
		{ "VehicleCollisionDmgScaleMod", "collisionDamageScale" },
		{ "VehicleFallDmgThresholdMod", "fallDamageThreshold" },
		{ "VehicleFallDmgScaleMod", "fallDamageScale" },
		{ "VehicleCameraDistanceMod", "cameraDistance" },
		{ "VehicleCameraHeightMod", "cameraHeight" },
		{ "VehicleCameraLerpMod", "cameraLerpSpeed" },
		{ "VehicleBoostSpeedMod", "boostSpeedMultiplier" },
		{ "VehicleBoostDurationMod", "boostDuration" },
		{ "VehicleBoostCooldownMod", "boostCooldown" },
		{ "VehicleLeanBankAngleMod", "leanBankAngle" },
		{ "VehicleLeanTurnRateMod", "leanTurnRate" },
		{ "VehicleLeanSpeedPenaltyMod", "leanSpeedPenalty" },
	}

	for _, entry in ipairs(percentModifiers) do
		local attrName = entry[1]
		local configKey = entry[2]
		local mod = readNumberAttribute(instance, attrName)
		if mod ~= nil then
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
	local leanEnabled = readBoolAttribute(instance, "VehicleLeanEnabled")
	if leanEnabled ~= nil then
		resolved.leanEnabled = leanEnabled
	end

	return resolved :: any
end

local function resolveDriverWeaponId(vehicleModel: Model, config: VehicleConfig): string?
	local configId = vehicleModel:GetAttribute("ConfigId")
	if type(configId) ~= "string" or configId == "" then
		configId = config.entityConfigId
	end
	if type(configId) ~= "string" or configId == "" then
		return nil
	end

	local entityConfig = CombatConfig.Entities[configId]
	if entityConfig == nil then
		return nil
	end
	local weaponId = entityConfig.weaponId
	if type(weaponId) == "string" and weaponId ~= "" then
		return weaponId
	end
	return nil
end

local function hasDriverWeaponMount(vehicleModel: Model): boolean
	local mountCount = vehicleModel:GetAttribute("WeaponMountCount")
	if type(mountCount) == "number" then
		return mountCount > 0
	end

	for _, descendant in ipairs(vehicleModel:GetDescendants()) do
		if descendant:IsA("BasePart") and CollectionService:HasTag(descendant, "WeaponMount") then
			local insideStationFolder = false
			local current: Instance? = descendant.Parent
			while current ~= nil and current ~= vehicleModel do
				if current:IsA("Folder") then
					insideStationFolder = true
					break
				end
				current = current.Parent
			end
			if not insideStationFolder then
				return true
			end
		end
	end

	return false
end

local function findVehicleModelFromSeat(seat: BasePart): Model?
	local current: Instance? = seat
	while current ~= nil do
		if current:IsA("Model") and CollectionService:HasTag(current, "VehicleEntity") then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function updateSpeedHud()
	local vehicleModel = activeVehicleModel
	if vehicleModel == nil then
		return
	end

	local speed = vehicleModel:GetAttribute("VehicleSpeed")
	if type(speed) == "number" then
		CombatHUD.setSpeed(speed)
	else
		CombatHUD.setSpeed(0)
	end
end

local function readInputPayload(): VehicleInputPayload
	local throttle = 0
	if UserInputService:IsKeyDown(Enum.KeyCode.W) then
		throttle = 1
	elseif UserInputService:IsKeyDown(Enum.KeyCode.S) then
		throttle = -1
	end

	local lean = 0
	if activeVehicleConfig ~= nil and activeVehicleConfig.leanEnabled then
		local aDown = UserInputService:IsKeyDown(Enum.KeyCode.A)
		local dDown = UserInputService:IsKeyDown(Enum.KeyCode.D)
		if aDown and not dDown then
			lean = -1
		elseif dDown and not aDown then
			lean = 1
		end
	end

	local steerX = 0
	if not freelookActive then
		local camera = Workspace.CurrentCamera
		if camera ~= nil then
			local rangeX = CombatConfig.VehicleMouseRangeX
			if type(rangeX) ~= "number" or rangeX <= 0 then
				rangeX = 0.18
			end
			local maxX = math.max(1, camera.ViewportSize.X * rangeX)
			local rawSteerX = math.clamp(virtualCursorX / maxX, -1, 1)
			-- Dead zone: ignore small inputs near center, remap the rest smoothly
			local deadZone = 0.08
			local absSteer = math.abs(rawSteerX)
			if absSteer < deadZone then
				steerX = 0
			else
				steerX = math.sign(rawSteerX) * (absSteer - deadZone) / (1 - deadZone)
			end
		end
	end

	local boost = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
		and throttle > 0
		and lean == 0

	return {
		throttle = throttle,
		steerX = steerX,
		lean = lean,
		boost = boost,
	}
end

local function onExitAction(_name: string, inputState: Enum.UserInputState, _inputObject: InputObject): Enum.ContextActionResult
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end

	if vehicleExitRemote ~= nil and activeVehicleEntityId ~= nil then
		vehicleExitRemote:FireServer()
	end

	return Enum.ContextActionResult.Sink
end

local function activateVehicleMouse()
	savedMouseBehavior = UserInputService.MouseBehavior
	savedMouseIconEnabled = UserInputService.MouseIconEnabled
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	UserInputService.MouseIconEnabled = false
	virtualCursorX = 0
	virtualCursorY = 0
end

local function restoreVehicleMouse()
	UserInputService.MouseBehavior = savedMouseBehavior or Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = if savedMouseIconEnabled ~= nil then savedMouseIconEnabled else true
	savedMouseBehavior = nil
	savedMouseIconEnabled = nil
end

local function updateVirtualCursor(dt: number)
	local mouseDelta = UserInputService:GetMouseDelta()
	local sensitivity = CombatConfig.VehicleMouseSensitivity
	if type(sensitivity) ~= "number" or sensitivity <= 0 then
		sensitivity = 0.7
	end

	virtualCursorX += mouseDelta.X * sensitivity
	virtualCursorY += mouseDelta.Y * sensitivity

	local camera = Workspace.CurrentCamera
	if camera ~= nil then
		local rangeX = CombatConfig.VehicleMouseRangeX
		if type(rangeX) ~= "number" or rangeX <= 0 then
			rangeX = 0.18
		end
		local rangeY = CombatConfig.VehicleMouseRangeY
		if type(rangeY) ~= "number" or rangeY <= 0 then
			rangeY = 0.06
		end

		local maxX = camera.ViewportSize.X * rangeX
		local maxY = camera.ViewportSize.Y * rangeY
		virtualCursorX = math.clamp(virtualCursorX, -maxX, maxX)
		virtualCursorY = math.clamp(virtualCursorY, -maxY, maxY)

		-- Auto-center only when cursor is in the inner half of its range
		local centeringRate = CombatConfig.VehicleMouseCenteringRate
		if type(centeringRate) ~= "number" or centeringRate <= 0 then
			centeringRate = 1.5
		end
		local deflectionX = if maxX > 0 then math.abs(virtualCursorX) / maxX else 0
		local deflectionY = if maxY > 0 then math.abs(virtualCursorY) / maxY else 0
		-- Full centering at 0%, fades to zero at 90%, none beyond 90%
		local centerStrengthX = math.clamp(1 - deflectionX / 0.9, 0, 1)
		local centerStrengthY = math.clamp(1 - deflectionY / 0.9, 0, 1)
		local centerAlpha = 1 - math.exp(-centeringRate * dt)
		virtualCursorX -= virtualCursorX * centerAlpha * centerStrengthX
		virtualCursorY -= virtualCursorY * centerAlpha * centerStrengthY

		local screenCenter = camera.ViewportSize * 0.5
		CombatHUD.setCursorDotPosition(Vector2.new(screenCenter.X + virtualCursorX, screenCenter.Y + virtualCursorY))
	end
end

local function onBoostChanged(model: Model)
	local isBoosting = model:GetAttribute("VehicleBoosting") == true
	if isBoosting and not boostActive then
		boostActive = true
		if activeProfileController ~= nil then
			activeProfileController:onEvent("boost_start")
		end
	elseif not isBoosting and boostActive then
		boostActive = false
		if activeProfileController ~= nil then
			activeProfileController:onEvent("boost_end")
		end
	end
end

local function setupBoostConnection(model: Model)
	if boostConnection ~= nil then
		boostConnection:Disconnect()
	end
	boostActive = model:GetAttribute("VehicleBoosting") == true
	boostConnection = model:GetAttributeChangedSignal("VehicleBoosting"):Connect(function()
		onBoostChanged(model)
	end)
end

local function cleanupBoostConnection()
	if boostConnection ~= nil then
		boostConnection:Disconnect()
		boostConnection = nil
	end
	boostActive = false
end

local function exitVehicleMode()
	destroyVehicleFireSoundPool()
	if inputConnection ~= nil then
		inputConnection:Disconnect()
		inputConnection = nil
	end
	ContextActionService:UnbindAction(EXIT_ACTION_NAME)
	ContextActionService:UnbindAction(LOCK_ACTION_NAME)
	if scrollConnection ~= nil then
		scrollConnection:Disconnect()
		scrollConnection = nil
	end

	if activeProfileController ~= nil then
		activeProfileController:destroy()
		activeProfileController = nil
	end
	previousBoostActive = false
	previousHpFraction = 1
	cleanupBoostConnection()
	VehicleVisualSmoother.deactivate()
	RemoteVehicleSmoother.setLocalVehicle(nil)
	VehicleCamera.deactivate()
	restoreVehicleMouse()
	if landingShakeConnection ~= nil then
		landingShakeConnection:Disconnect()
		landingShakeConnection = nil
	end
	if misfireVisualConnection ~= nil then
		misfireVisualConnection:Disconnect()
		misfireVisualConnection = nil
	end
	CombatHUD.showVehicleCursor(false)

	CombatHUD.hideHP()
	CombatHUD.showSpeed(false)
	CombatHUD.showCrosshair(false)
	CombatHUD.showHeat(false)
	CombatHUD.showAmmo(false)
	CombatHUD.showShield(false)
	activeVehicleHasWeapon = false
	lastVehicleHeatRecoverCueId = 0

	activeVehicleEntityId = nil
	activeVehicleModel = nil
	activeVehicleRenderModel = nil
	activeVehicleConfig = nil
	inputAccumulator = 0
	previousClientLean = 0
	freelookActive = false
	lastSentThrottle = 0
	lastSentSteerX = 0
	lastSentLean = 0
	lastSentTick = 0
end


local VEHICLE_AIM_MAX_ELEVATION = 15 -- degrees up/down from horizontal

local vehicleAimRayParams: RaycastParams? = nil

local function getVehicleWorldForward(): Vector3?
	local model = activeVehicleRenderModel or activeVehicleModel
	if model == nil or model.PrimaryPart == nil then
		return nil
	end
	local forwardAxisRaw = (activeVehicleModel :: Model):GetAttribute("ForwardAxis")
	local forwardAxisLocal: Vector3
	if forwardAxisRaw == "X" then
		forwardAxisLocal = Vector3.new(1, 0, 0)
	elseif forwardAxisRaw == "-X" then
		forwardAxisLocal = Vector3.new(-1, 0, 0)
	elseif forwardAxisRaw == "Z" then
		forwardAxisLocal = Vector3.new(0, 0, 1)
	else
		forwardAxisLocal = Vector3.new(0, 0, -1)
	end
	local worldForward = model.PrimaryPart.CFrame:VectorToWorldSpace(forwardAxisLocal)
	return Vector3.new(worldForward.X, 0, worldForward.Z).Unit
end

local function computeVehicleAimDirection(): Vector3?
	local forward = getVehicleWorldForward()
	if forward == nil then
		return nil
	end
	-- Mouse Y controls elevation: cursor above center = aim up, below = aim down.
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return forward
	end
	local rangeY = CombatConfig.VehicleMouseRangeY
	if type(rangeY) ~= "number" or rangeY <= 0 then
		rangeY = 0.06
	end
	local maxY = camera.ViewportSize.Y * rangeY
	local yFraction = if maxY > 0 then math.clamp(-virtualCursorY / maxY, -1, 1) else 0
	local elevationRad = math.rad(yFraction * VEHICLE_AIM_MAX_ELEVATION)
	-- Tilt the forward vector up/down by the elevation angle
	local cosE = math.cos(elevationRad)
	local sinE = math.sin(elevationRad)
	return Vector3.new(forward.X * cosE, sinE, forward.Z * cosE).Unit
end

local function updateVehicleCrosshairPosition()
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end
	local model = activeVehicleRenderModel or activeVehicleModel
	if model == nil then
		return
	end
	local aimDir = computeVehicleAimDirection()
	if aimDir == nil then
		return
	end
	-- Start raycast ahead of the vehicle to avoid hitting the vehicle body or seated character
	local forward = getVehicleWorldForward()
	if forward == nil then
		return
	end
	local vehiclePos = model:GetPivot().Position
	local origin = vehiclePos + forward * 8
	-- Raycast from ahead of vehicle along aim direction to find where bullet hits
	if vehicleAimRayParams == nil then
		vehicleAimRayParams = RaycastParams.new()
		vehicleAimRayParams.FilterType = Enum.RaycastFilterType.Exclude
		vehicleAimRayParams.IgnoreWater = true
	end
	local filterList: { Instance } = {
		model,
		activeVehicleModel :: Instance,
	}
	local character = localPlayer.Character
	if character ~= nil then
		table.insert(filterList, character)
	end
	vehicleAimRayParams.FilterDescendantsInstances = filterList
	local maxDist = 1000
	local result = Workspace:Raycast(origin, aimDir * maxDist, vehicleAimRayParams)
	local hitPoint = if result then result.Position else origin + aimDir * maxDist
	local screenPos, onScreen = camera:WorldToViewportPoint(hitPoint)
	if onScreen then
		CombatHUD.setCrosshairPosition(Vector2.new(screenPos.X, screenPos.Y))
	end
end

local function updateVehicleWeaponHUD()
	local model = activeVehicleModel
	if model == nil then
		return
	end

	-- Heat
	local heatValue = model:GetAttribute("WeaponHeat")
	local heatMax = model:GetAttribute("WeaponHeatMax")
	local maxHeat = if type(heatMax) == "number" and heatMax > 0 then heatMax else 100
	if type(heatValue) == "number" then
		local heatDecayPerSecond = model:GetAttribute("WeaponHeatDecayPerSecond")
		local heatUpdatedAt = model:GetAttribute("WeaponHeatUpdatedAt")
		local overheated = model:GetAttribute("WeaponOverheated") == true
		local displayHeat = math.clamp(heatValue, 0, maxHeat)
		if type(heatDecayPerSecond) == "number" and heatDecayPerSecond > 0 and type(heatUpdatedAt) == "number" then
			local elapsed = math.max(0, Workspace:GetServerTimeNow() - heatUpdatedAt)
			local coolingRate = heatDecayPerSecond / maxHeat
			displayHeat = math.max(0, displayHeat * math.exp(-coolingRate * elapsed))
		end
		CombatHUD.setWeaponHeat(displayHeat, maxHeat, overheated)

		local cueId = model:GetAttribute("WeaponHeatRecoverCueId")
		if type(cueId) == "number" then
			local cueCounter = math.floor(cueId)
			if cueCounter > lastVehicleHeatRecoverCueId then
				lastVehicleHeatRecoverCueId = cueCounter
				CombatHUD.onWeaponRecoveredCue()
			end
		end
	end

	-- Ammo
	local ammoMaxRaw = model:GetAttribute("WeaponAmmoMax")
	if type(ammoMaxRaw) == "number" and ammoMaxRaw > 0 then
		local ammoRaw = model:GetAttribute("WeaponAmmo")
		local ammoCurrent = if type(ammoRaw) == "number" then ammoRaw else ammoMaxRaw
		CombatHUD.setAmmo(ammoCurrent, ammoMaxRaw)
	end

	-- Shield
	local maxShieldRaw = model:GetAttribute("MaxShieldHP")
	if type(maxShieldRaw) == "number" and maxShieldRaw > 0 then
		local shieldRaw = model:GetAttribute("ShieldHP")
		local shieldCurrent = if type(shieldRaw) == "number" then shieldRaw else maxShieldRaw
		CombatHUD.setShield(shieldCurrent, maxShieldRaw)
	end
end

local function enterVehicleMode(entityId: string, vehicleModel: Model, config: VehicleConfig)
	if activeVehicleEntityId == entityId and activeVehicleModel == vehicleModel then
		return
	end

	exitVehicleMode()

	activeVehicleEntityId = entityId
	activeVehicleModel = vehicleModel
	activeVehicleConfig = config
	inputAccumulator = 0
	RemoteVehicleSmoother.setLocalVehicle(vehicleModel)
	activeVehicleRenderModel = VehicleVisualSmoother.activate(vehicleModel)
	activateVehicleMouse()
	setupBoostConnection(vehicleModel)
	if activeVehicleRenderModel ~= nil then
		local rp = activeVehicleRenderModel.PrimaryPart
		if rp ~= nil then
			activeProfileController = SoundProfileLoader.createController(vehicleModel, rp, config.maxSpeed, true)
		end
	end
	previousBoostActive = false
	previousHpFraction = 1
	local shakeModel = activeVehicleRenderModel or vehicleModel
	landingShakeConnection = shakeModel:GetAttributeChangedSignal("VehicleLandingImpact"):Connect(function()
		if activeProfileController == nil then
			return
		end
		local impactSpeed = shakeModel:GetAttribute("VehicleLandingImpact")
		if type(impactSpeed) ~= "number" or impactSpeed <= 0 then
			return
		end
		activeProfileController:onEvent("landing", {
			impactSpeed = impactSpeed,
		} :: SoundProfileTypes.LandingData)
	end)

	-- Misfire event → forward to profile
	misfireVisualConnection = vehicleModel:GetAttributeChangedSignal("VehicleMisfire"):Connect(function()
		if vehicleModel:GetAttribute("VehicleMisfire") == true and activeProfileController ~= nil then
			activeProfileController:onEvent("misfire")
		end
	end)

	local sendInterval = 1 / getVehicleInputRate()
	inputConnection = RunService.RenderStepped:Connect(function(dt)
		if activeVehicleEntityId == nil then
			return
		end

		local model = activeVehicleModel
		if model == nil or model.Parent == nil then
			exitVehicleMode()
			return
		end

		local altHeld = UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt)
		if altHeld and not freelookActive then
			freelookActive = true
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			UserInputService.MouseIconEnabled = true
			CombatHUD.showVehicleCursor(false)
			VehicleCamera.setFreelook(true)
		elseif not altHeld and freelookActive then
			freelookActive = false
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
			UserInputService.MouseIconEnabled = false
			virtualCursorX = 0
			virtualCursorY = 0
			CombatHUD.showVehicleCursor(true)
			VehicleCamera.setFreelook(false)
		end

		if freelookActive then
			local rmbHeld = UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
			if rmbHeld then
				UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
				local delta = UserInputService:GetMouseDelta()
				VehicleCamera.addFreelookInput(delta.X, delta.Y)
			else
				UserInputService.MouseBehavior = Enum.MouseBehavior.Default
				UserInputService.MouseIconEnabled = true
			end
		else
			updateVirtualCursor(dt)
		end
		updateSpeedHud()

		-- Build frame state and update profile controller
		if activeProfileController ~= nil and activeVehicleConfig ~= nil then
			local speedAttrP = model:GetAttribute("VehicleSpeed")
			local speedP: number = if type(speedAttrP) == "number" then speedAttrP else 0
			local msP = activeVehicleConfig.maxSpeed
			local hullHP = model:GetAttribute("HullHP")
			local maxHP = model:GetAttribute("MaxHullHP")
			local hpFracP: number = 1
			if type(hullHP) == "number" and type(maxHP) == "number" and maxHP > 0 then
				hpFracP = math.clamp(hullHP / maxHP, 0, 1)
			end
			-- Detect damage taken
			if hpFracP < previousHpFraction then
				activeProfileController:onEvent("damage_taken", {
					amount = (previousHpFraction - hpFracP) * (if type(maxHP) == "number" then maxHP else 100),
					newHpFraction = hpFracP,
				})
			end
			previousHpFraction = hpFracP

			local frameState: SoundProfileTypes.VehicleFrameState = {
				speed = speedP,
				maxSpeed = msP,
				speedFraction = if msP > 0 then math.clamp(speedP / msP, 0, 1) else 0,
				hpFraction = hpFracP,
				isBoosting = boostActive,
				isGrounded = true,
				throttle = lastSentThrottle,
				steerInput = lastSentSteerX,
				isLocal = true,
				dt = dt,
			}
			activeProfileController:update(dt, frameState)
		end

		-- Vehicle weapon: aim, fire, HUD update
		if activeVehicleHasWeapon and not freelookActive then
			updateVehicleWeaponHUD()
			updateVehicleCrosshairPosition()
			local aimDirection = computeVehicleAimDirection()
			if aimDirection ~= nil and updateTurretAimRemote ~= nil then
				updateTurretAimRemote:FireServer(aimDirection)
			end
			if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
				if aimDirection ~= nil and fireWeaponRemote ~= nil then
					fireWeaponRemote:FireServer(aimDirection)
					playVehicleInstantFireSound()
				end
			end
		end

		local payload = readInputPayload()
		-- Steer banking: pass mouse steer + speed fraction to visual smoother
		local steerSpeedAttr = activeVehicleRenderModel and activeVehicleRenderModel:GetAttribute("VehicleSpeed")
		local steerSpeed = if type(steerSpeedAttr) == "number" then steerSpeedAttr else 0
		local steerSpeedFrac = if activeVehicleConfig ~= nil and activeVehicleConfig.maxSpeed > 0
			then math.clamp(steerSpeed / activeVehicleConfig.maxSpeed, 0, 1)
			else 0
		VehicleVisualSmoother.setSteerBank(payload.steerX, steerSpeedFrac, payload.lean ~= 0)
		VehicleCamera.setLeanInput(payload.lean)
		-- Lean entry effects
		if previousClientLean == 0 and payload.lean ~= 0 then
			local speedAttr = activeVehicleRenderModel and activeVehicleRenderModel:GetAttribute("VehicleSpeed")
			local currentSpeed = if type(speedAttr) == "number" then speedAttr else 0
			if currentSpeed > 15 and activeVehicleConfig ~= nil and activeProfileController ~= nil then
				activeProfileController:onEvent("lean_start", {
					speedFraction = currentSpeed / activeVehicleConfig.maxSpeed,
					direction = payload.lean,
				} :: SoundProfileTypes.LeanStartData)
			end
		end
		previousClientLean = payload.lean

		inputAccumulator += dt
		if inputAccumulator < sendInterval then
			return
		end

		while inputAccumulator >= sendInterval do
			inputAccumulator -= sendInterval
		end

		-- Only send if input changed or heartbeat interval elapsed
		local now = tick()
		local throttleChanged = payload.throttle ~= lastSentThrottle
		local leanChanged = payload.lean ~= lastSentLean
		local steerChanged = math.abs(payload.steerX - lastSentSteerX) > INPUT_STEER_DEADBAND
		local refreshNeeded = (now - lastSentTick) >= INPUT_REFRESH_INTERVAL

		if throttleChanged or leanChanged or steerChanged or refreshNeeded then
			if vehicleInputRemote ~= nil then
				vehicleInputRemote:FireServer(payload)
			end
			lastSentThrottle = payload.throttle
			lastSentSteerX = payload.steerX
			lastSentLean = payload.lean
			lastSentTick = now
		end
	end)

	ContextActionService:BindAction(EXIT_ACTION_NAME, onExitAction, false, Enum.KeyCode.F)
	scrollConnection = UserInputService.InputChanged:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseWheel then
			VehicleCamera.applyScrollZoom(-input.Position.Z)
		end
	end)
	local renderModel = activeVehicleRenderModel or vehicleModel
	VehicleCamera.activate(renderModel, config)
	VehicleCamera.setEffectsEnabled(activeProfileController ~= nil)

	CombatHUD.showHP(entityId)
	CombatHUD.showSpeed(true)
	CombatHUD.showVehicleCursor(true)
	updateSpeedHud()

	local driverWeaponId = resolveDriverWeaponId(vehicleModel, config)
	local hasDriverMount = hasDriverWeaponMount(vehicleModel)
	activeVehicleHasWeapon = driverWeaponId ~= nil and hasDriverMount
	if activeVehicleHasWeapon then
		CombatHUD.showCrosshair(true)
		local ammoMax = vehicleModel:GetAttribute("WeaponAmmoMax")
		if type(ammoMax) == "number" and ammoMax > 0 then
			CombatHUD.showAmmo(true)
			CombatHUD.showHeat(false)
		else
			CombatHUD.showHeat(true)
			CombatHUD.showAmmo(false)
		end
		local maxShield = vehicleModel:GetAttribute("MaxShieldHP")
		if type(maxShield) == "number" and maxShield > 0 then
			CombatHUD.showShield(true)
		else
			CombatHUD.showShield(false)
		end
		lastVehicleHeatRecoverCueId = 0
		ContextActionService:BindAction(LOCK_ACTION_NAME, function(_name: string, inputState: Enum.UserInputState)
			if inputState ~= Enum.UserInputState.Begin then
				return Enum.ContextActionResult.Pass
			end
			if TargetingClient.isLocked() then
				TargetingClient.requestClearLock()
			else
				TargetingClient.requestLock()
			end
			return Enum.ContextActionResult.Sink
		end, false, Enum.KeyCode.T)
	else
		CombatHUD.showCrosshair(false)
		CombatHUD.showHeat(false)
		CombatHUD.showAmmo(false)
		CombatHUD.showShield(false)
		-- showCrosshair(false) also hides cursorDot; restore it for vehicle steering
		CombatHUD.showVehicleCursor(true)
	end
	if activeVehicleHasWeapon then
		buildVehicleFireSoundPool()
	else
		destroyVehicleFireSoundPool()
	end
end

local function onSeatChanged(humanoid: Humanoid)
	local seatPart = humanoid.SeatPart
	if seatPart ~= nil and CollectionService:HasTag(seatPart, "DriverSeat") then
		local vehicleModel = findVehicleModelFromSeat(seatPart)
		if vehicleModel ~= nil then
			local entityId = vehicleModel:GetAttribute("EntityId")
			if type(entityId) == "string" then
				local config = resolveVehicleConfig(vehicleModel)
				if config ~= nil then
					-- Route walkers to WalkerClient
					if config.vehicleClass == "walker_biped" then
						if activeVehicleEntityId ~= nil then
							exitVehicleMode()
						end
						WalkerClient.activate(vehicleModel, entityId, config)
						return
					end
					enterVehicleMode(entityId, vehicleModel, config)
					return
				end
			end
		end
	end

	-- Deactivate walker if active
	if WalkerClient.isActive() then
		WalkerClient.deactivate()
	end

	if activeVehicleEntityId ~= nil then
		exitVehicleMode()
	end
end

local function bindCharacter(character: Model)
	exitVehicleMode()

	if seatConnection ~= nil then
		seatConnection:Disconnect()
		seatConnection = nil
	end

	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	seatConnection = humanoid:GetPropertyChangedSignal("SeatPart"):Connect(function()
		onSeatChanged(humanoid)
	end)
	onSeatChanged(humanoid)
end

function VehicleClient.init(remotesFolder: Folder): ()
	vehicleInputRemote = remotesFolder:WaitForChild("VehicleInput") :: RemoteEvent
	vehicleExitRemote = remotesFolder:WaitForChild("VehicleExitRequest") :: RemoteEvent
	fireWeaponRemote = remotesFolder:WaitForChild("FireWeapon") :: RemoteEvent
	updateTurretAimRemote = remotesFolder:WaitForChild("UpdateTurretAim") :: RemoteEvent
	WalkerClient.init(remotesFolder)

	if characterAddedConnection == nil then
		characterAddedConnection = localPlayer.CharacterAdded:Connect(bindCharacter)
	end

	local existingCharacter = localPlayer.Character
	if existingCharacter ~= nil then
		bindCharacter(existingCharacter)
	end
end

return VehicleClient
