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

local CombatHUD = require(clientRoot:WaitForChild("HUD"):WaitForChild("CombatHUD"))
local TargetingClient = require(clientRoot:WaitForChild("Targeting"):WaitForChild("TargetingClient"))
local DriverClient = require(clientRoot:WaitForChild("Vehicle"):WaitForChild("DriverClient"))
local sharedRoot = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatConfig = require(sharedRoot:WaitForChild("CombatConfig"))
local WeaponRig = require(sharedRoot:WaitForChild("WeaponRig"))

local WeaponClient = {}

local FIRE_ACTION_NAME = "CombatFireWeapon"
local EXIT_ACTION_NAME = "CombatExitTurret"
local ZOOM_ACTION_NAME = "CombatZoomWeapon"
local LOCK_ACTION_NAME = "CombatLockToggle"
local CAMERA_POINT_NAME = "CameraPoint"

local MIN_VERTICAL_ANGLE = math.rad(-25)
local MAX_VERTICAL_ANGLE = math.rad(50)
local CAMERA_MOUSE_SENSITIVITY = 0.0025
local AIM_DEADZONE_ANGLE = math.rad(1.5)
local TURN_RATE_GAIN = 3
local MIN_TURN_RATE = math.rad(20)
local MAX_TURN_RATE = math.rad(100)
local STOP_SMOOTH_ZONE = math.rad(3)
local STOP_SMOOTH_RATE = 8
local LOCK_CAMERA_DEADZONE_ANGLE = math.rad(1.0)
local LOCK_CAMERA_TURN_GAIN = 2.6
local LOCK_CAMERA_MIN_TURN_RATE = math.rad(10)
local LOCK_CAMERA_MAX_TURN_RATE = math.rad(55)
local CAMERA_FALLBACK_LOCAL_OFFSET = Vector3.new(0, 9, 22)
local CAMERA_LOOK_DISTANCE = 500
local DEFAULT_PROJECTILE_RANGE = 500
local MAX_PHYSICS_CAST_DISTANCE = 1024
local SHOT_KICK_IMPULSE = 7.2
local SHOT_KICK_SPRING = 44
local SHOT_KICK_DAMPING = 12
local SHOT_SHAKE_IMPULSE = 1.15
local SHOT_SHAKE_DAMPING = 5
local SHOT_SHAKE_FREQUENCY = 28
local MAX_SHAKE_AMPLITUDE = 2.6
local MAX_KICK_VELOCITY = 10
local SHOT_FOV_IMPULSE = 1.4
local SHOT_FOV_SPRING = 30
local SHOT_FOV_DAMPING = 10
local MAX_FOV_OFFSET = 3.4
local ZOOM_FOV_REDUCTION = 52
local ZOOM_IN_RATE = 18
local ZOOM_OUT_RATE = 11
local MIN_TURRET_FOV = 10
local HEAT_VFX_START_RATIO = 0.68
local HEAT_VFX_OVERHEAT_BURST_INTERVAL = 0.18
local AIM_UPDATE_INTERVAL = 1 / 30

type RigOverride = {
	mode: string?,
	minYawDeg: number?,
	maxYawDeg: number?,
	minPitchDeg: number?,
	maxPitchDeg: number?,
	pivotName: string?,
	pivotAttachment: Attachment?,
}

type DrivenPartState = {
	part: BasePart,
	neutralAimFrame: CFrame,
	clampOverride: RigOverride?,
}

local fireWeaponRemote: RemoteEvent? = nil
local updateTurretAimRemote: RemoteEvent? = nil

local activeTurretModel: Model? = nil
local activeSeat: BasePart? = nil
local activeWeaponMount: BasePart? = nil
local activeNeutralAimFrame: CFrame? = nil
local activeCameraPoint: Instance? = nil

local desiredAimDirection: Vector3? = nil
local currentAimDirection: Vector3? = nil
local lockedCameraLookDirection: Vector3? = nil
local cameraYaw = 0
local cameraPitch = 0
local cameraKickOffset = 0
local cameraKickVelocity = 0
local cameraShakeAmplitude = 0
local cameraShakeTime = 0
local cameraFovOffset = 0
local cameraFovVelocity = 0
local turretBaseFov = 70
local zoomHeld = false
local fireHeld = false
local zoomBlend = 0
local nextClientFireTime = 0
local nextAimUpdateTime = 0
local lastHeatRecoverCueId = 0
local heatVfxMount: BasePart? = nil
local heatVfxAttachment: Attachment? = nil
local heatVfxLight: PointLight? = nil
local heatVfxSmoke: ParticleEmitter? = nil
local heatVfxBurstAccumulator = 0
local activeDrivenParts: { DrivenPartState } = {}
local ensureWeaponMount: (() -> ())? = nil
local updateDrivenParts: ((Vector3) -> ())? = nil

local seatedConnection: RBXScriptConnection? = nil
local characterAddedConnection: RBXScriptConnection? = nil
local turretStepConnection: RBXScriptConnection? = nil
local aimRaycastParams = RaycastParams.new()
local aimRaycastExcludeList: { Instance } = {}

local function triggerFireCameraFeedback()
	local shakeImpulse = SHOT_SHAKE_IMPULSE
	if activeTurretModel ~= nil then
		local rawModifier = activeTurretModel:GetAttribute("WeaponScreenShakeModifier")
		local modifier: number? = nil
		if type(rawModifier) == "number" then
			modifier = rawModifier
		elseif type(rawModifier) == "string" then
			modifier = tonumber(rawModifier)
		end
		if modifier ~= nil then
			shakeImpulse *= math.max(0, 1 + modifier)
		end
	end

	cameraKickVelocity += SHOT_KICK_IMPULSE
	cameraKickVelocity = math.clamp(cameraKickVelocity, -MAX_KICK_VELOCITY, MAX_KICK_VELOCITY)
	cameraShakeAmplitude = math.min(MAX_SHAKE_AMPLITUDE, cameraShakeAmplitude + shakeImpulse)
	cameraFovVelocity += SHOT_FOV_IMPULSE
end

local function readModelNumberAttribute(instance: Instance, attributeName: string): number?
	local raw = instance:GetAttribute(attributeName)
	if type(raw) == "number" then
		return raw
	end
	if type(raw) == "string" then
		return tonumber(raw)
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

local function smoothDirectionToward(
	currentDirection: Vector3,
	targetDirection: Vector3,
	dt: number,
	deadzoneAngle: number,
	rateGain: number,
	minTurnRate: number,
	maxTurnRate: number
): Vector3
	local currentUnit = if currentDirection.Magnitude > 1e-4 then currentDirection.Unit else targetDirection.Unit
	local targetUnit = if targetDirection.Magnitude > 1e-4 then targetDirection.Unit else currentUnit
	local dot = math.clamp(currentUnit:Dot(targetUnit), -1, 1)
	local angularError = math.acos(dot)

	if angularError <= deadzoneAngle then
		return currentUnit
	end

	local turnRate = math.clamp(angularError * rateGain, minTurnRate, maxTurnRate)
	local alpha = math.min(1, (turnRate * dt) / math.max(angularError, 1e-4))
	return (currentUnit:Lerp(targetUnit, alpha)).Unit
end

local function getActiveWeaponCooldown(): number
	if activeTurretModel == nil then
		return 0
	end

	local effectiveFireRate = readModelNumberAttribute(activeTurretModel, "EffectiveWeaponFireRate")
	if effectiveFireRate ~= nil and effectiveFireRate > 0 then
		return 1 / effectiveFireRate
	end

	local configId = activeTurretModel:GetAttribute("ConfigId")
	if type(configId) ~= "string" then
		return 0
	end

	local entityConfig = CombatConfig.Entities[configId]
	if entityConfig == nil or type(entityConfig.weaponId) ~= "string" then
		return 0
	end

	local weaponConfig = CombatConfig.Weapons[entityConfig.weaponId]
	if weaponConfig == nil or type(weaponConfig.fireRate) ~= "number" or weaponConfig.fireRate <= 0 then
		return 0
	end

	local fireRateModifier = readModelNumberAttribute(activeTurretModel, "WeaponFireRateModifier")
	local resolvedFireRate = applyPercentModifier(weaponConfig.fireRate, fireRateModifier, 0.01)
	return 1 / resolvedFireRate
end

local function isHoldToFireEnabled(): boolean
	return activeTurretModel ~= nil and activeTurretModel:GetAttribute("WeaponHoldToFire") == true
end

local function isLockRequiredForActiveWeapon(): boolean
	if activeTurretModel == nil then
		return false
	end

	local requiresLockAttr = activeTurretModel:GetAttribute("WeaponRequiresLock")
	if type(requiresLockAttr) == "boolean" then
		return requiresLockAttr
	end

	local configId = activeTurretModel:GetAttribute("ConfigId")
	if type(configId) ~= "string" then
		return false
	end

	local entityConfig = CombatConfig.Entities[configId]
	if entityConfig == nil or type(entityConfig.weaponId) ~= "string" then
		return false
	end

	local weaponConfig = CombatConfig.Weapons[entityConfig.weaponId]
	return weaponConfig ~= nil and weaponConfig.requiresLock == true
end

local function tryFireCurrentWeapon(): boolean
	if activeTurretModel == nil or fireWeaponRemote == nil then
		return false
	end

	if ensureWeaponMount ~= nil then
		ensureWeaponMount()
	end
	local weaponMount = activeWeaponMount
	if weaponMount == nil then
		return false
	end

	local aimDirection = currentAimDirection or desiredAimDirection or weaponMount.CFrame.LookVector
	if aimDirection.Magnitude < 1e-4 then
		return false
	end

	if activeTurretModel:GetAttribute("WeaponOverheated") == true then
		return false
	end
	if isLockRequiredForActiveWeapon() and not TargetingClient.isLocked() then
		return false
	end

	local ammoMaxRaw = activeTurretModel:GetAttribute("WeaponAmmoMax")
	if type(ammoMaxRaw) == "number" and ammoMaxRaw > 0 then
		local ammoRaw = activeTurretModel:GetAttribute("WeaponAmmo")
		if type(ammoRaw) == "number" and ammoRaw <= 0 then
			return false
		end
	end

	local now = tick()
	local cooldown = getActiveWeaponCooldown()
	if cooldown > 0 and now < nextClientFireTime then
		return false
	end

	fireWeaponRemote:FireServer(aimDirection.Unit)
	triggerFireCameraFeedback()
	if cooldown > 0 then
		nextClientFireTime = now + cooldown
	end
	return true
end

local function sendAimUpdate(aimDirection: Vector3)
	if updateTurretAimRemote == nil or activeTurretModel == nil then
		return
	end
	if aimDirection.Magnitude < 1e-4 then
		return
	end

	local now = tick()
	if now < nextAimUpdateTime then
		return
	end
	nextAimUpdateTime = now + AIM_UPDATE_INTERVAL
	updateTurretAimRemote:FireServer(aimDirection.Unit)
end

local function findTaggedDescendant(model: Model, tagName: string, className: string?): Instance?
	for _, descendant in ipairs(model:GetDescendants()) do
		if CollectionService:HasTag(descendant, tagName) then
			if className == nil or descendant:IsA(className) then
				return descendant
			end
		end
	end
	return nil
end

local function findCameraPoint(model: Model): Instance?
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant.Name == CAMERA_POINT_NAME and (descendant:IsA("BasePart") or descendant:IsA("Attachment")) then
			return descendant
		end
	end
	return nil
end

local function clampDirectionPitch(direction: Vector3): Vector3
	local horizontal = Vector3.new(direction.X, 0, direction.Z)
	if horizontal.Magnitude < 1e-4 then
		horizontal = Vector3.new(0, 0, -1)
	end

	local rawPitch = math.asin(math.clamp(direction.Y, -1, 1))
	local clampedPitch = math.clamp(rawPitch, MIN_VERTICAL_ANGLE, MAX_VERTICAL_ANGLE)
	local horizontalMagnitude = math.cos(clampedPitch)

	return (horizontal.Unit * horizontalMagnitude + Vector3.new(0, math.sin(clampedPitch), 0)).Unit
end

local function directionToYawPitch(direction: Vector3): (number, number)
	local unitDirection = direction.Unit
	local yaw = math.atan2(-unitDirection.X, -unitDirection.Z)
	local pitch = math.asin(math.clamp(unitDirection.Y, -1, 1))
	return yaw, pitch
end

local function yawPitchToDirection(yaw: number, pitch: number): Vector3
	local cosPitch = math.cos(pitch)
	return Vector3.new(-math.sin(yaw) * cosPitch, math.sin(pitch), -math.cos(yaw) * cosPitch).Unit
end

local function isMuzzleAttachment(candidate: Instance): boolean
	if not candidate:IsA("Attachment") then
		return false
	end

	if CollectionService:HasTag(candidate, "MuzzlePoint") then
		return true
	end

	return candidate.Name == "MuzzlePoint" or string.sub(candidate.Name, 1, 11) == "MuzzlePoint"
end

local function getPrimaryMuzzleLocalOffset(weaponMount: BasePart): Vector3
	local attachments: { Attachment } = {}
	for _, descendant in ipairs(weaponMount:GetDescendants()) do
		if isMuzzleAttachment(descendant) then
			table.insert(attachments, descendant :: Attachment)
		end
	end

	table.sort(attachments, function(a: Attachment, b: Attachment)
		return a:GetFullName() < b:GetFullName()
	end)

	local muzzlePoint = attachments[1]
	if muzzlePoint ~= nil then
		return weaponMount.CFrame:PointToObjectSpace(muzzlePoint.WorldPosition)
	end

	return Vector3.new(0, 0, -weaponMount.Size.Z * 0.5)
end

local function performAimCast(origin: Vector3, directionUnit: Vector3, totalDistance: number): RaycastResult?
	local remainingDistance = totalDistance
	local castOrigin = origin

	while remainingDistance > 0 do
		local segmentDistance = math.min(remainingDistance, MAX_PHYSICS_CAST_DISTANCE)
		local segmentDirection = directionUnit * segmentDistance
		local castResult = Workspace:Raycast(castOrigin, segmentDirection, aimRaycastParams)
		if castResult ~= nil then
			return castResult
		end

		castOrigin += segmentDirection
		remainingDistance -= segmentDistance
	end

	return nil
end

local function updateAimReticle(camera: Camera, aimDirection: Vector3)
	local weaponMount = activeWeaponMount
	if weaponMount == nil then
		return
	end

	local maxRange = DEFAULT_PROJECTILE_RANGE
	local hasRangeOverride = false
	if activeTurretModel ~= nil then
		local effectiveMaxRange = readModelNumberAttribute(activeTurretModel, "EffectiveWeaponMaxRange")
		if effectiveMaxRange ~= nil and effectiveMaxRange > 0 then
			maxRange = effectiveMaxRange
			hasRangeOverride = true
		end
	end
	local turretConfigId = if activeTurretModel ~= nil then activeTurretModel:GetAttribute("ConfigId") else nil
	if not hasRangeOverride and type(turretConfigId) == "string" then
		local entityConfig = CombatConfig.Entities[turretConfigId]
		if entityConfig ~= nil and type(entityConfig.weaponId) == "string" then
				local weaponConfig = CombatConfig.Weapons[entityConfig.weaponId]
				if weaponConfig ~= nil and type(weaponConfig.maxRange) == "number" then
					local rangeModifier = readModelNumberAttribute(activeTurretModel :: Instance, "WeaponMaxRangeModifier")
					maxRange = applyPercentModifier(weaponConfig.maxRange, rangeModifier, 1)
				end
			end
		end

	local muzzleLocalOffset = getPrimaryMuzzleLocalOffset(weaponMount)

	local originFrame = WeaponRig.getAimFrame(weaponMount, aimDirection)
	local muzzleOrigin = originFrame:PointToWorldSpace(muzzleLocalOffset)

	table.clear(aimRaycastExcludeList)
	if activeTurretModel ~= nil then
		aimRaycastExcludeList[1] = activeTurretModel
	end
	aimRaycastParams.FilterDescendantsInstances = aimRaycastExcludeList

	local aimDirectionMagnitude = aimDirection.Magnitude
	if aimDirectionMagnitude <= 0 then
		return
	end
	local castDirectionUnit = aimDirection / aimDirectionMagnitude
	local fullRangeDirection = castDirectionUnit * maxRange
	local castResult = performAimCast(muzzleOrigin, castDirectionUnit, maxRange)

	local aimPoint = if castResult ~= nil then castResult.Position else (muzzleOrigin + fullRangeDirection)
	local viewportPoint, onScreen = camera:WorldToViewportPoint(aimPoint)
	local viewportSize = camera.ViewportSize

	local x = viewportPoint.X
	local y = viewportPoint.Y
	if not onScreen then
		x = math.clamp(x, 0, viewportSize.X)
		y = math.clamp(y, 0, viewportSize.Y)
	end

	CombatHUD.setCrosshairPosition(Vector2.new(x, y))
end

local function getCameraPointWorldPosition(point: Instance?): Vector3?
	if point == nil then
		return nil
	end

	if point:IsA("Attachment") then
		return point.WorldPosition
	end
	if point:IsA("BasePart") then
		return point.Position
	end

	return nil
end

local function getCameraAnchorWorldPosition(cameraPoint: Instance?, seatPart: BasePart?, mount: BasePart?): Vector3?
	local pointPosition = getCameraPointWorldPosition(cameraPoint)
	if pointPosition ~= nil then
		return pointPosition
	end

	if seatPart ~= nil then
		return seatPart.CFrame:PointToWorldSpace(CAMERA_FALLBACK_LOCAL_OFFSET)
	end

	if mount ~= nil then
		return mount.CFrame:PointToWorldSpace(CAMERA_FALLBACK_LOCAL_OFFSET)
	end

	return nil
end

local function initializeAimFromCurrentRig()
	if activeWeaponMount == nil then
		return
	end

	activeNeutralAimFrame = WeaponRig.getNeutralAimFrame(activeWeaponMount)
	local initialDirection = clampDirectionPitch(WeaponRig.getCurrentAimDirection(activeWeaponMount))
	if activeNeutralAimFrame ~= nil then
		initialDirection = WeaponRig.clampDirectionToMountLimits(activeWeaponMount, activeNeutralAimFrame, initialDirection)
	end

	desiredAimDirection = initialDirection
	currentAimDirection = initialDirection
	cameraYaw, cameraPitch = directionToYawPitch(initialDirection)
end

local rebuildDrivenParts: (() -> ())? = nil

ensureWeaponMount = function()
	if activeTurretModel == nil then
		activeWeaponMount = nil
		activeNeutralAimFrame = nil
		return
	end

	if activeWeaponMount ~= nil and activeWeaponMount.Parent ~= nil then
		return
	end

	local mount = findTaggedDescendant(activeTurretModel, "WeaponMount", "BasePart")
	if mount ~= nil then
		activeWeaponMount = mount :: BasePart
		activeNeutralAimFrame = WeaponRig.getNeutralAimFrame(activeWeaponMount)
		if rebuildDrivenParts ~= nil then
			rebuildDrivenParts()
		end
		if currentAimDirection == nil or desiredAimDirection == nil then
			initializeAimFromCurrentRig()
		end
	end
end

local function clearDrivenParts()
	table.clear(activeDrivenParts)
end

local function modeFromFolderName(folderName: string): string?
	local normalized = string.lower(string.gsub(folderName, "[%s_%-]", ""))
	if normalized == "yawonly" or normalized == "yawonlyparts" or normalized == "drivenyawonly" then
		return "yawonly"
	end
	if normalized == "pitchonly" or normalized == "pitchonlyparts" or normalized == "drivenpitchonly" then
		return "pitchonly"
	end
	if normalized == "yawpitch" or normalized == "yawpitchparts" or normalized == "drivenyawpitch" then
		return "yawpitch"
	end
	return nil
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

local function getClampOverride(folder: Instance, modeFromName: string?): RigOverride?
	local modeFromAttr = folder:GetAttribute("AimMode")
	local mode: string? = modeFromName
	if type(modeFromAttr) == "string" and modeFromAttr ~= "" then
		mode = modeFromAttr
	end

	local minYawDeg = readNumberAttribute(folder, "MinYawDeg")
	local maxYawDeg = readNumberAttribute(folder, "MaxYawDeg")
	local minPitchDeg = readNumberAttribute(folder, "MinPitchDeg")
	local maxPitchDeg = readNumberAttribute(folder, "MaxPitchDeg")
	local pivotName: string? = nil
	local pivotNameRaw = folder:GetAttribute("AimPivotName")
	if type(pivotNameRaw) == "string" and string.match(pivotNameRaw, "%S") ~= nil then
		pivotName = pivotNameRaw
	end

	local pivotAttachment: Attachment? = nil
	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("ObjectValue") and child.Value ~= nil and child.Value:IsA("Attachment") then
			local attachedValue = child.Value :: Attachment
			if child.Name == "AimPivotAttachment" or child.Name == "PivotAttachment" then
				pivotAttachment = attachedValue
				break
			end

			if pivotAttachment == nil then
				pivotAttachment = attachedValue
			end
		end
	end

	if
		mode == nil
		and minYawDeg == nil
		and maxYawDeg == nil
		and minPitchDeg == nil
		and maxPitchDeg == nil
		and pivotName == nil
		and pivotAttachment == nil
	then
		return nil
	end

	return {
		mode = mode,
		minYawDeg = minYawDeg,
		maxYawDeg = maxYawDeg,
		minPitchDeg = minPitchDeg,
		maxPitchDeg = maxPitchDeg,
		pivotName = pivotName,
		pivotAttachment = pivotAttachment,
	}
end

local function addDrivenPart(
	part: BasePart,
	seen: { [BasePart]: boolean },
	clampOverride: RigOverride?
)
	if activeWeaponMount ~= nil and part == activeWeaponMount then
		return
	end
	if seen[part] then
		return
	end

	seen[part] = true
	table.insert(activeDrivenParts, {
		part = part,
		neutralAimFrame = WeaponRig.getNeutralAimFrame(part),
		clampOverride = clampOverride,
	})
end

local function collectDrivenPartsFromContainer(
	container: Instance,
	seen: { [BasePart]: boolean },
	clampOverride: RigOverride?
)
	for _, descendant in ipairs(container:GetDescendants()) do
		if descendant:IsA("BasePart") then
			addDrivenPart(descendant, seen, clampOverride)
		elseif descendant:IsA("ObjectValue") and descendant.Value ~= nil and descendant.Value:IsA("BasePart") then
			addDrivenPart(descendant.Value, seen, clampOverride)
		end
	end
end

rebuildDrivenParts = function()
	clearDrivenParts()

	local turretModel = activeTurretModel
	if turretModel == nil then
		return
	end

	local seen: { [BasePart]: boolean } = {}
	if activeWeaponMount ~= nil then
		seen[activeWeaponMount] = true
	end

	local rigFolder = turretModel:FindFirstChild("TurretRig")
	if rigFolder == nil then
		return
	end

	local drivenPartsFolder = rigFolder:FindFirstChild("DrivenParts")
	if drivenPartsFolder ~= nil then
		local clampOverride = getClampOverride(drivenPartsFolder, nil)
		collectDrivenPartsFromContainer(drivenPartsFolder, seen, clampOverride)
	end

	for _, child in ipairs(rigFolder:GetChildren()) do
		if child:IsA("Folder") and child.Name ~= "DrivenParts" then
			local modeOverride = modeFromFolderName(child.Name)
			local clampOverride = getClampOverride(child, modeOverride)
			if modeOverride ~= nil or clampOverride ~= nil then
				collectDrivenPartsFromContainer(child, seen, clampOverride)
			end
		end
	end
end

updateDrivenParts = function(aimDirection: Vector3)
	if #activeDrivenParts == 0 then
		return
	end

	for index = #activeDrivenParts, 1, -1 do
		local driven = activeDrivenParts[index]
		if driven.part.Parent == nil then
			table.remove(activeDrivenParts, index)
		else
			local drivenDirection =
				WeaponRig.clampDirectionToMountLimits(driven.part, driven.neutralAimFrame, aimDirection, driven.clampOverride)
			if drivenDirection.Magnitude > 1e-4 then
				driven.part.CFrame = WeaponRig.getAimFrame(driven.part, drivenDirection, driven.clampOverride)
			end
		end
	end
end

local function clearHeatVfx()
	if heatVfxAttachment ~= nil and heatVfxAttachment.Parent ~= nil then
		heatVfxAttachment:Destroy()
	end
	heatVfxMount = nil
	heatVfxAttachment = nil
	heatVfxLight = nil
	heatVfxSmoke = nil
	heatVfxBurstAccumulator = 0
end

local function ensureHeatVfxForMount(weaponMount: BasePart)
	if heatVfxMount == weaponMount and heatVfxAttachment ~= nil and heatVfxAttachment.Parent == weaponMount then
		return
	end

	clearHeatVfx()

	local attachment = Instance.new("Attachment")
	attachment.Name = "WeaponHeatVFX"
	local muzzleLocalOffset = getPrimaryMuzzleLocalOffset(weaponMount)
	attachment.Position = muzzleLocalOffset
	attachment.Parent = weaponMount

	local glow = Instance.new("PointLight")
	glow.Name = "HeatGlow"
	glow.Enabled = false
	glow.Shadows = false
	glow.Brightness = 0
	glow.Range = 0
	glow.Color = Color3.fromRGB(255, 170, 95)
	glow.Parent = attachment

	local smoke = Instance.new("ParticleEmitter")
	smoke.Name = "HeatSmoke"
	smoke.Enabled = false
	smoke.Rate = 0
	smoke.Speed = NumberRange.new(0.35, 1.45)
	smoke.Lifetime = NumberRange.new(0.5, 1.2)
	smoke.SpreadAngle = Vector2.new(16, 16)
	smoke.RotSpeed = NumberRange.new(-25, 25)
	smoke.Rotation = NumberRange.new(0, 360)
	smoke.Acceleration = Vector3.new(0, 3, 0)
	smoke.Texture = "rbxassetid://716847870"
	smoke.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.45),
		NumberSequenceKeypoint.new(0.5, 1.15),
		NumberSequenceKeypoint.new(1, 1.95),
	})
	smoke.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.45),
		NumberSequenceKeypoint.new(1, 1),
	})
	smoke.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(120, 120, 120)),
		ColorSequenceKeypoint.new(0.35, Color3.fromRGB(82, 82, 82)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(38, 38, 38)),
	})
	smoke.Parent = attachment

	heatVfxMount = weaponMount
	heatVfxAttachment = attachment
	heatVfxLight = glow
	heatVfxSmoke = smoke
end

local function updateWeaponHeatVfx(dt: number, heatRatio: number, overheated: boolean)
	if activeWeaponMount == nil then
		clearHeatVfx()
		return
	end

	ensureHeatVfxForMount(activeWeaponMount)
	local glow = heatVfxLight
	local smoke = heatVfxSmoke
	if glow == nil or smoke == nil then
		return
	end

	local visualRatio = math.clamp((heatRatio - HEAT_VFX_START_RATIO) / (1 - HEAT_VFX_START_RATIO), 0, 1)
	if overheated then
		visualRatio = 1
	end

	local enabled = visualRatio > 0.01
	glow.Enabled = enabled
	smoke.Enabled = enabled

	if not enabled then
		smoke.Rate = 0
		heatVfxBurstAccumulator = 0
		return
	end

	local heatColor: Color3
	if overheated then
		heatColor = Color3.fromRGB(255, 74, 52)
	else
		local g = math.floor(212 - visualRatio * 118 + 0.5)
		local b = math.floor(128 - visualRatio * 64 + 0.5)
		heatColor = Color3.fromRGB(255, math.clamp(g, 94, 212), math.clamp(b, 62, 128))
	end

	glow.Color = heatColor
	glow.Brightness = 0.35 + visualRatio * 2.4
	glow.Range = 2.4 + visualRatio * 5.4
	smoke.Rate = 2 + visualRatio * (if overheated then 42 else 24)

	if overheated then
		heatVfxBurstAccumulator += dt
		if heatVfxBurstAccumulator >= HEAT_VFX_OVERHEAT_BURST_INTERVAL then
			heatVfxBurstAccumulator = 0
			smoke:Emit(5)
		end
	else
		heatVfxBurstAccumulator = 0
	end
end

local function updateWeaponHeatHud(): (number, boolean)
	local turretModel = activeTurretModel
	if turretModel == nil then
		return 0, false
	end

	local heatValue = turretModel:GetAttribute("WeaponHeat")
	if type(heatValue) ~= "number" then
		CombatHUD.setWeaponHeat(0, 100, false)
		return 0, false
	end

	local heatMax = turretModel:GetAttribute("WeaponHeatMax")
	local maxHeat = if type(heatMax) == "number" and heatMax > 0 then heatMax else 100
	local heatDecayPerSecond = turretModel:GetAttribute("WeaponHeatDecayPerSecond")
	local heatUpdatedAt = turretModel:GetAttribute("WeaponHeatUpdatedAt")
	local overheated = turretModel:GetAttribute("WeaponOverheated") == true

	local displayHeat = math.clamp(heatValue, 0, maxHeat)
	if type(heatDecayPerSecond) == "number" and heatDecayPerSecond > 0 and type(heatUpdatedAt) == "number" then
		local elapsed = math.max(0, Workspace:GetServerTimeNow() - heatUpdatedAt)
		local coolingRate = heatDecayPerSecond / maxHeat
		displayHeat = math.max(0, displayHeat * math.exp(-coolingRate * elapsed))
	end

	CombatHUD.setWeaponHeat(displayHeat, maxHeat, overheated)
	local heatRatio = math.clamp(displayHeat / math.max(1, maxHeat), 0, 1)

	local cueId = turretModel:GetAttribute("WeaponHeatRecoverCueId")
	if type(cueId) == "number" then
		local cueCounter = math.floor(cueId)
		if cueCounter > lastHeatRecoverCueId then
			lastHeatRecoverCueId = cueCounter
			CombatHUD.onWeaponRecoveredCue()
		end
	end

	return heatRatio, overheated
end

local function updateWeaponAmmoHud(): boolean
	local turretModel = activeTurretModel
	if turretModel == nil then
		return false
	end

	local ammoMaxRaw = turretModel:GetAttribute("WeaponAmmoMax")
	if type(ammoMaxRaw) ~= "number" or ammoMaxRaw <= 0 then
		return false
	end

	local ammoRaw = turretModel:GetAttribute("WeaponAmmo")
	local ammoCurrent = if type(ammoRaw) == "number" then ammoRaw else ammoMaxRaw
	CombatHUD.setAmmo(ammoCurrent, ammoMaxRaw)
	return true
end

local function updateShieldHud()
	local turretModel = activeTurretModel
	if turretModel == nil then
		CombatHUD.showShield(false)
		return
	end

	local maxShieldRaw = turretModel:GetAttribute("MaxShieldHP")
	if type(maxShieldRaw) ~= "number" or maxShieldRaw <= 0 then
		CombatHUD.showShield(false)
		return
	end

	local currentShieldRaw = turretModel:GetAttribute("ShieldHP")
	local currentShield = if type(currentShieldRaw) == "number" then currentShieldRaw else maxShieldRaw
	CombatHUD.showShield(true)
	CombatHUD.setShield(currentShield, maxShieldRaw)
end

local function updateTurretAndCamera(dt: number)
	if activeTurretModel == nil then
		return
	end

	ensureWeaponMount()
	local weaponMount = activeWeaponMount
	if weaponMount == nil then
		return
	end

	local camera = workspace.CurrentCamera
	if camera == nil then
		return
	end

	local mouseDelta = UserInputService:GetMouseDelta()
	cameraYaw += -mouseDelta.X * CAMERA_MOUSE_SENSITIVITY
	cameraPitch = math.clamp(cameraPitch - mouseDelta.Y * CAMERA_MOUSE_SENSITIVITY, MIN_VERTICAL_ANGLE, MAX_VERTICAL_ANGLE)
	local cameraLookDirection = yawPitchToDirection(cameraYaw, cameraPitch)

	if activeNeutralAimFrame == nil then
		activeNeutralAimFrame = WeaponRig.getNeutralAimFrame(weaponMount)
	end

	local aimDirection = clampDirectionPitch(currentAimDirection or WeaponRig.getCurrentAimDirection(weaponMount))
	local targetDirection = aimDirection
	local lockedTargetModel = TargetingClient.getLockedModel()
	local hasLockedAim = false
	local cameraLockTargetDirection: Vector3? = nil
	if lockedTargetModel ~= nil and lockedTargetModel.Parent ~= nil then
		local aimWorldPoint = lockedTargetModel:GetPivot().Position
		local cameraWorldPoint = aimWorldPoint
		if activeTurretModel ~= nil then
			local rawLeadPoint = TargetingClient.getLockedLeadPoint(weaponMount.Position, activeTurretModel)
			if rawLeadPoint ~= nil then
				aimWorldPoint = rawLeadPoint
				cameraWorldPoint = rawLeadPoint
			end

			local visualLeadPoint = TargetingClient.getLockedVisualLeadPoint(weaponMount.Position, activeTurretModel, dt)
			if visualLeadPoint ~= nil then
				cameraWorldPoint = visualLeadPoint
			end
		end

		local toLockedAimPoint = aimWorldPoint - weaponMount.Position
		if toLockedAimPoint.Magnitude > 1e-4 then
			targetDirection = toLockedAimPoint.Unit
			hasLockedAim = true
		end

		local toLockedCameraPoint = cameraWorldPoint - weaponMount.Position
		if toLockedCameraPoint.Magnitude > 1e-4 then
			cameraLockTargetDirection = toLockedCameraPoint.Unit
		end
	end

	if hasLockedAim then
		local cameraFollowDirection = lockedCameraLookDirection
		if cameraFollowDirection == nil then
			cameraFollowDirection = cameraLookDirection
		end

		local desiredCameraDirection = cameraLockTargetDirection or targetDirection
		cameraLookDirection = smoothDirectionToward(
			cameraFollowDirection,
			desiredCameraDirection,
			dt,
			LOCK_CAMERA_DEADZONE_ANGLE,
			LOCK_CAMERA_TURN_GAIN,
			LOCK_CAMERA_MIN_TURN_RATE,
			LOCK_CAMERA_MAX_TURN_RATE
		)
		lockedCameraLookDirection = cameraLookDirection
		cameraYaw, cameraPitch = directionToYawPitch(cameraLookDirection)
	else
		lockedCameraLookDirection = nil
	end

	if not hasLockedAim then
		local cameraToAimError = math.acos(math.clamp(aimDirection:Dot(cameraLookDirection), -1, 1))
		if cameraToAimError > AIM_DEADZONE_ANGLE then
			targetDirection = cameraLookDirection
		end
	end
	if activeNeutralAimFrame ~= nil then
		targetDirection = WeaponRig.clampDirectionToMountLimits(weaponMount, activeNeutralAimFrame, targetDirection)
	end
	desiredAimDirection = targetDirection

	if hasLockedAim then
		-- Locked aim should track prediction directly; smoothing here makes the reticle lag behind moving targets.
		aimDirection = targetDirection
	else
		local dot = math.clamp(aimDirection:Dot(targetDirection), -1, 1)
		local angularError = math.acos(dot)

		if angularError > 1e-4 then
			local alpha: number
			if angularError <= STOP_SMOOTH_ZONE then
				alpha = math.min(1, dt * STOP_SMOOTH_RATE)
			else
				local turnRate = math.clamp(angularError * TURN_RATE_GAIN, MIN_TURN_RATE, MAX_TURN_RATE)
				alpha = math.min(1, (turnRate * dt) / angularError)
			end
			aimDirection = (aimDirection:Lerp(targetDirection, alpha)).Unit
		else
			aimDirection = targetDirection
		end
	end

	currentAimDirection = aimDirection
	sendAimUpdate(aimDirection)

	local mountFrame = WeaponRig.getAimFrame(weaponMount, aimDirection)
	weaponMount.CFrame = mountFrame
	if updateDrivenParts ~= nil then
		updateDrivenParts(aimDirection)
	end

	local baseCameraPosition = getCameraAnchorWorldPosition(activeCameraPoint, activeSeat, weaponMount)
	if baseCameraPosition == nil then
		baseCameraPosition = camera.CFrame.Position
	end

	local finalCameraPosition = baseCameraPosition :: Vector3
	local finalCameraLook = cameraLookDirection

	local kickAcceleration = -cameraKickOffset * SHOT_KICK_SPRING - cameraKickVelocity * SHOT_KICK_DAMPING
	cameraKickVelocity += kickAcceleration * dt
	cameraKickOffset += cameraKickVelocity * dt
	if math.abs(cameraKickOffset) < 1e-4 and math.abs(cameraKickVelocity) < 1e-3 then
		cameraKickOffset = 0
		cameraKickVelocity = 0
	end

	cameraShakeTime += dt
	cameraShakeAmplitude = math.max(0, cameraShakeAmplitude - SHOT_SHAKE_DAMPING * dt)
	local zoomTarget = if zoomHeld then 1 else 0
	local zoomRate = if zoomTarget > zoomBlend then ZOOM_IN_RATE else ZOOM_OUT_RATE
	zoomBlend += (zoomTarget - zoomBlend) * math.min(1, dt * zoomRate)

	local forward = finalCameraLook.Unit
	local right = forward:Cross(Vector3.new(0, 1, 0))
	if right.Magnitude <= 1e-4 then
		right = Vector3.new(1, 0, 0)
	else
		right = right.Unit
	end
	local up = right:Cross(forward).Unit

	local shakePhase = cameraShakeTime * SHOT_SHAKE_FREQUENCY
	local shakeX = math.sin(shakePhase * 1.9) * cameraShakeAmplitude * 0.03
	local shakeY = math.sin(shakePhase * 2.3 + 1.3) * cameraShakeAmplitude * 0.02
	local shakeZ = math.sin(shakePhase * 3.1 + 0.7) * cameraShakeAmplitude * 0.04
	local recoilOffset = -forward * cameraKickOffset + right * shakeX + up * shakeY + forward * shakeZ
	local shakenCameraPosition = finalCameraPosition + recoilOffset

	local fovAcceleration = -cameraFovOffset * SHOT_FOV_SPRING - cameraFovVelocity * SHOT_FOV_DAMPING
	cameraFovVelocity += fovAcceleration * dt
	cameraFovOffset += cameraFovVelocity * dt
	cameraFovOffset = math.clamp(cameraFovOffset, -MAX_FOV_OFFSET, MAX_FOV_OFFSET)
	local zoomFovOffset = -ZOOM_FOV_REDUCTION * zoomBlend
	local desiredFov = turretBaseFov + cameraFovOffset + zoomFovOffset
	camera.FieldOfView = math.max(MIN_TURRET_FOV, desiredFov)
	CombatHUD.setZoomVignette(zoomBlend)

	camera.CFrame = CFrame.lookAt(shakenCameraPosition, shakenCameraPosition + finalCameraLook * CAMERA_LOOK_DISTANCE)

	local center = camera.ViewportSize * 0.5
	CombatHUD.setCursorDotPosition(Vector2.new(center.X, center.Y))
	updateAimReticle(camera, aimDirection)
	local usesAmmoHud = updateWeaponAmmoHud()
	if usesAmmoHud then
		CombatHUD.showAmmo(true)
		CombatHUD.showHeat(false)
		clearHeatVfx()
	else
		CombatHUD.showAmmo(false)
		CombatHUD.showHeat(true)
		local heatRatio, overheated = updateWeaponHeatHud()
		updateWeaponHeatVfx(dt, heatRatio, overheated)
	end
	updateShieldHud()
	if fireHeld and isHoldToFireEnabled() then
		tryFireCurrentWeapon()
	end
end

local function restoreDefaultCameraAndMouse()
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true

	local camera = workspace.CurrentCamera
	if camera ~= nil then
		camera.FieldOfView = turretBaseFov
		camera.CameraType = Enum.CameraType.Custom
		local character = localPlayer.Character
		if character ~= nil then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if humanoid ~= nil then
				camera.CameraSubject = humanoid
			end
		end
	end
end

local function activateTurretCameraAndMouse()
	local camera = workspace.CurrentCamera
	if camera ~= nil then
		turretBaseFov = camera.FieldOfView
		cameraFovOffset = 0
		cameraFovVelocity = 0
		camera.CameraType = Enum.CameraType.Scriptable
	end

	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	UserInputService.MouseIconEnabled = false
end

local function deactivateTurretMode()
	ContextActionService:UnbindAction(FIRE_ACTION_NAME)
	ContextActionService:UnbindAction(EXIT_ACTION_NAME)
	ContextActionService:UnbindAction(ZOOM_ACTION_NAME)
	ContextActionService:UnbindAction(LOCK_ACTION_NAME)

	if turretStepConnection ~= nil then
		turretStepConnection:Disconnect()
		turretStepConnection = nil
	end

	restoreDefaultCameraAndMouse()

	CombatHUD.showCrosshair(false)
	CombatHUD.hideHP()
	CombatHUD.showShield(false)
	CombatHUD.showAmmo(false)
	CombatHUD.showHeat(false)
	CombatHUD.setZoomVignette(0)
	clearHeatVfx()
	TargetingClient.onSeatExit()

	activeTurretModel = nil
	activeSeat = nil
	activeWeaponMount = nil
	activeNeutralAimFrame = nil
	clearDrivenParts()
	activeCameraPoint = nil
	desiredAimDirection = nil
	currentAimDirection = nil
	lockedCameraLookDirection = nil
	cameraYaw = 0
	cameraPitch = 0
	cameraKickOffset = 0
	cameraKickVelocity = 0
	cameraShakeAmplitude = 0
	cameraShakeTime = 0
	cameraFovOffset = 0
	cameraFovVelocity = 0
	zoomHeld = false
	fireHeld = false
	zoomBlend = 0
	nextClientFireTime = 0
	nextAimUpdateTime = 0
	lastHeatRecoverCueId = 0
end

local function onFireAction(_actionName: string, inputState: Enum.UserInputState, _inputObject: InputObject): Enum.ContextActionResult
	if activeTurretModel == nil or fireWeaponRemote == nil then
		return Enum.ContextActionResult.Pass
	end

	local holdToFireEnabled = isHoldToFireEnabled()
	if inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
		fireHeld = false
		return Enum.ContextActionResult.Sink
	end

	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end

	if holdToFireEnabled then
		fireHeld = true
		tryFireCurrentWeapon()
		return Enum.ContextActionResult.Sink
	end

	tryFireCurrentWeapon()
	return Enum.ContextActionResult.Sink
end

local function onExitAction(_actionName: string, inputState: Enum.UserInputState, _inputObject: InputObject): Enum.ContextActionResult
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end

	local character = localPlayer.Character
	if character ~= nil then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid ~= nil then
			humanoid.Sit = false
		end
	end

	return Enum.ContextActionResult.Sink
end

local function onZoomAction(_actionName: string, inputState: Enum.UserInputState, _inputObject: InputObject): Enum.ContextActionResult
	if activeTurretModel == nil then
		return Enum.ContextActionResult.Pass
	end

	if inputState == Enum.UserInputState.Begin then
		zoomHeld = true
	elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
		zoomHeld = false
	end

	return Enum.ContextActionResult.Sink
end

local function onLockToggleAction(
	_actionName: string,
	inputState: Enum.UserInputState,
	_inputObject: InputObject
): Enum.ContextActionResult
	if activeTurretModel == nil then
		return Enum.ContextActionResult.Pass
	end
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end

	if TargetingClient.isLocked() then
		TargetingClient.requestClearLock()
	else
		TargetingClient.requestLock()
	end

	return Enum.ContextActionResult.Sink
end

local function activateTurretMode(turretSeat: BasePart)
	local turretModel = turretSeat:FindFirstAncestorWhichIsA("Model")
	if turretModel == nil then
		return
	end

	activeTurretModel = turretModel
	activeSeat = turretSeat
	activeWeaponMount = findTaggedDescendant(turretModel, "WeaponMount", "BasePart") :: BasePart?
	activeCameraPoint = findCameraPoint(turretModel)
	if rebuildDrivenParts ~= nil then
		rebuildDrivenParts()
	end
	initializeAimFromCurrentRig()
	clearHeatVfx()
	activateTurretCameraAndMouse()
	zoomHeld = false
	fireHeld = false
	zoomBlend = 0
	nextClientFireTime = 0
	nextAimUpdateTime = 0
	local cueId = turretModel:GetAttribute("WeaponHeatRecoverCueId")
	lastHeatRecoverCueId = if type(cueId) == "number" then math.floor(cueId) else 0
	CombatHUD.setZoomVignette(0)

	ContextActionService:BindAction(FIRE_ACTION_NAME, onFireAction, false, Enum.UserInputType.MouseButton1)
	ContextActionService:BindAction(EXIT_ACTION_NAME, onExitAction, false, Enum.KeyCode.F)
	ContextActionService:BindAction(ZOOM_ACTION_NAME, onZoomAction, false, Enum.UserInputType.MouseButton2)
	ContextActionService:BindAction(LOCK_ACTION_NAME, onLockToggleAction, false, Enum.KeyCode.T)

	if turretStepConnection == nil then
		turretStepConnection = RunService.RenderStepped:Connect(updateTurretAndCamera)
	end

	CombatHUD.showCrosshair(true)
	local usingAmmoHud = updateWeaponAmmoHud()
	CombatHUD.showAmmo(usingAmmoHud)
	CombatHUD.showHeat(not usingAmmoHud)
	if not usingAmmoHud then
		updateWeaponHeatHud()
	end
	local entityId = turretModel:GetAttribute("EntityId")
	if type(entityId) == "string" then
		CombatHUD.showHP(entityId)
	else
		CombatHUD.hideHP()
	end
	updateShieldHud()
end

local function onHumanoidSeated(isSeated: boolean, seatPart: BasePart?)
	if isSeated and DriverClient.isDriverSeated() then
		deactivateTurretMode()
		return
	end

	if isSeated and seatPart ~= nil and CollectionService:HasTag(seatPart, "TurretSeat") then
		activateTurretMode(seatPart)
		return
	end

	deactivateTurretMode()
end

local function bindCharacter(character: Model)
	deactivateTurretMode()

	if seatedConnection ~= nil then
		seatedConnection:Disconnect()
		seatedConnection = nil
	end

	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	seatedConnection = humanoid.Seated:Connect(onHumanoidSeated)

	if
		humanoid.SeatPart ~= nil
		and CollectionService:HasTag(humanoid.SeatPart, "TurretSeat")
		and not DriverClient.isDriverSeated()
	then
		activateTurretMode(humanoid.SeatPart)
	end
end

function WeaponClient.init(remotes: Folder)
	fireWeaponRemote = remotes:WaitForChild("FireWeapon") :: RemoteEvent
	updateTurretAimRemote = remotes:WaitForChild("UpdateTurretAim") :: RemoteEvent
	aimRaycastParams.FilterType = Enum.RaycastFilterType.Exclude
	aimRaycastParams.IgnoreWater = true

	if characterAddedConnection == nil then
		characterAddedConnection = localPlayer.CharacterAdded:Connect(bindCharacter)
	end

	local existingCharacter = localPlayer.Character
	if existingCharacter ~= nil then
		bindCharacter(existingCharacter)
	end
end

return WeaponClient
