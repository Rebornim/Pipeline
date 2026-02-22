--!strict

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local sharedRoot = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatConfig = require(sharedRoot:WaitForChild("CombatConfig"))
local CombatTypes = require(sharedRoot:WaitForChild("CombatTypes"))
local WeaponRig = require(sharedRoot:WaitForChild("WeaponRig"))

local serverRoot = ServerScriptService:WaitForChild("CombatFramework")
local HealthManager = require(serverRoot:WaitForChild("Health"):WaitForChild("HealthManager"))
local ProjectileServer = require(serverRoot:WaitForChild("Projectiles"):WaitForChild("ProjectileServer"))
local TargetingServer = require(serverRoot:WaitForChild("Targeting"):WaitForChild("TargetingServer"))

type HealthState = CombatTypes.HealthState
type LockState = CombatTypes.LockState
type ProjectileData = CombatTypes.ProjectileData
type WeaponConfig = CombatTypes.WeaponConfig

type WeaponHeatState = {
	heat: number,
	lastUpdatedAt: number,
	lastShotAt: number,
	overheated: boolean,
	recoverCueId: number,
	recoverToken: number,
}

type AmmoState = {
	current: number,
	max: number,
}

type FireNode = {
	mount: BasePart,
	muzzleLocalOffset: Vector3,
}

type FireNodeState = {
	nodes: { FireNode },
	nextIndex: number,
}

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

type DrivenRigState = {
	mount: BasePart,
	mountNeutralAimFrame: CFrame,
	drivenParts: { DrivenPartState },
}

local WeaponServer = {}

local remotesFolder: Folder? = nil
local fireWeaponRemote: RemoteEvent? = nil
local updateTurretAimRemote: RemoteEvent? = nil
local fireConnection: RBXScriptConnection? = nil
local aimUpdateConnection: RBXScriptConnection? = nil
local playerRemovingConnection: RBXScriptConnection? = nil

local lastFireTimeByPlayer: { [Player]: number } = {}
local lastAimUpdateByPlayer: { [Player]: number } = {}
local heatStateByEntityId: { [string]: WeaponHeatState } = {}
local ammoStateByEntityId: { [string]: AmmoState } = {}
local fireNodeStateByEntityId: { [string]: FireNodeState } = {}
local drivenRigStateByEntityId: { [string]: DrivenRigState } = {}
local warnedUnknownWeaponClass: { [string]: boolean } = {}
local projectileCounter = 0

local DEFAULT_HEAT_MAX = 100
local DEFAULT_HEAT_PER_SHOT = 15
local DEFAULT_HEAT_DECAY_PER_SECOND = 8
local DEFAULT_HEAT_RECOVER_FRACTION = 0.5
local CADENCE_RAPID_BONUS_MAX = 0.45
local CADENCE_SLOW_DISCOUNT_MAX = 0.25
local CADENCE_SLOW_DISCOUNT_WINDOW = 2
local DEFAULT_WEAPON_CLASS = "projectile"
local DEFAULT_BURST_COUNT = 3
local DEFAULT_BURST_INTERVAL = 0.08
local AIM_UPDATE_INTERVAL = 1 / 30

local ATTR_WEAPON_CLASS = "WeaponClass"
local ATTR_DAMAGE_TYPE = "WeaponDamageType"
local ATTR_BOLT_COLOR = "WeaponBoltColor"
local ATTR_SPLASH_ENABLED = "WeaponSplashEnabled"
local ATTR_SPLASH_RADIUS = "WeaponSplashRadius"
local ATTR_DAMAGE_MODIFIER = "WeaponDamageModifier"
local ATTR_DAMAGE_PERCENT = "WeaponDamagePercent"
local ATTR_FIRE_RATE_MODIFIER = "WeaponFireRateModifier"
local ATTR_PROJECTILE_SPEED_MODIFIER = "WeaponProjectileSpeedModifier"
local ATTR_MAX_RANGE_MODIFIER = "WeaponMaxRangeModifier"
local ATTR_BURST_COUNT_MODIFIER = "WeaponBurstCountModifier"
local ATTR_BURST_INTERVAL_MODIFIER = "WeaponBurstIntervalModifier"
local ATTR_HEAT_MAX_MODIFIER = "WeaponHeatMaxModifier"
local ATTR_HEAT_PER_SHOT_MODIFIER = "WeaponHeatPerShotModifier"
local ATTR_HEAT_DECAY_MODIFIER = "WeaponHeatDecayPerSecondModifier"
local ATTR_HEAT_RECOVER_THRESHOLD_MODIFIER = "WeaponHeatRecoverThresholdModifier"
local ATTR_AMMO_CAPACITY = "WeaponAmmoCapacity"
local ATTR_ARTILLERY_GRAVITY = "WeaponArtilleryGravity"
local ATTR_ARTILLERY_MIN_ELEVATION = "WeaponArtilleryMinElevation"
local ATTR_ARTILLERY_MAX_ELEVATION = "WeaponArtilleryMaxElevation"
local ATTR_ARTILLERY_ADJUST_SPEED = "WeaponArtilleryAdjustSpeed"
local ATTR_ARTILLERY_FINE_ADJUST_SPEED = "WeaponArtilleryFineAdjustSpeed"
local ATTR_ARTILLERY_MIN_RANGE = "WeaponArtilleryMinRange"

local EFFECTIVE_WEAPON_CLASS = "EffectiveWeaponClass"
local EFFECTIVE_DAMAGE_TYPE = "EffectiveWeaponDamageType"
local EFFECTIVE_DAMAGE = "EffectiveWeaponDamage"
local EFFECTIVE_FIRE_RATE = "EffectiveWeaponFireRate"
local EFFECTIVE_PROJECTILE_SPEED = "EffectiveWeaponProjectileSpeed"
local EFFECTIVE_MAX_RANGE = "EffectiveWeaponMaxRange"
local EFFECTIVE_LOCK_RANGE = "EffectiveWeaponLockRange"
local EFFECTIVE_UNLOCKED_SPREAD = "EffectiveWeaponUnlockedSpread"
local EFFECTIVE_AUTO_AIM_SPREAD = "EffectiveWeaponAutoAimSpread"
local EFFECTIVE_REQUIRES_LOCK = "WeaponRequiresLock"
local EFFECTIVE_HOMING_TURN_RATE = "EffectiveWeaponHomingTurnRate"
local EFFECTIVE_BOLT_COLOR = "EffectiveWeaponBoltColor"
local EFFECTIVE_SPLASH_ENABLED = "EffectiveWeaponSplashEnabled"
local EFFECTIVE_SPLASH_RADIUS = "EffectiveWeaponSplashRadius"
local EFFECTIVE_BURST_COUNT = "EffectiveWeaponBurstCount"
local EFFECTIVE_BURST_INTERVAL = "EffectiveWeaponBurstInterval"
local EFFECTIVE_HEAT_MAX = "EffectiveWeaponHeatMax"
local EFFECTIVE_HEAT_PER_SHOT = "EffectiveWeaponHeatPerShot"
local EFFECTIVE_HEAT_DECAY = "EffectiveWeaponHeatDecayPerSecond"
local EFFECTIVE_HEAT_RECOVER_THRESHOLD = "EffectiveWeaponHeatRecoverThreshold"

local function findTaggedDescendants(model: Model, tagName: string, className: string?): { Instance }
	local tagged: { Instance } = {}
	for _, descendant in ipairs(model:GetDescendants()) do
		if CollectionService:HasTag(descendant, tagName) then
			if className == nil or descendant:IsA(className) then
				table.insert(tagged, descendant)
			end
		end
	end

	table.sort(tagged, function(a: Instance, b: Instance)
		return a:GetFullName() < b:GetFullName()
	end)

	return tagged
end

local function getFireRemote(): RemoteEvent
	if fireWeaponRemote == nil then
		error("WeaponServer not initialized with remotes")
	end
	return fireWeaponRemote
end

local function getAimUpdateRemote(): RemoteEvent
	if updateTurretAimRemote == nil then
		error("WeaponServer not initialized with aim update remote")
	end
	return updateTurretAimRemote
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

local function getMuzzleLocalOffsets(weaponMount: BasePart): { Vector3 }
	local offsets: { Vector3 } = {}
	local muzzleAttachments: { Attachment } = {}
	for _, descendant in ipairs(weaponMount:GetDescendants()) do
		if isMuzzleAttachment(descendant) then
			table.insert(muzzleAttachments, descendant :: Attachment)
		end
	end

	table.sort(muzzleAttachments, function(a: Attachment, b: Attachment)
		return a:GetFullName() < b:GetFullName()
	end)

	for _, attachment in ipairs(muzzleAttachments) do
		table.insert(offsets, weaponMount.CFrame:PointToObjectSpace(attachment.WorldPosition))
	end

	if #offsets == 0 then
		-- Fallback: front face of the weapon mount.
		table.insert(offsets, Vector3.new(0, 0, -weaponMount.Size.Z * 0.5))
	end

	return offsets
end

local function collectFireNodes(entityModel: Model): { FireNode }
	local nodes: { FireNode } = {}
	local mounts = findTaggedDescendants(entityModel, "WeaponMount", "BasePart")
	for _, mountInstance in ipairs(mounts) do
		local mount = mountInstance :: BasePart
		for _, offset in ipairs(getMuzzleLocalOffsets(mount)) do
			table.insert(nodes, {
				mount = mount,
				muzzleLocalOffset = offset,
			})
		end
	end
	return nodes
end

local function getOrRefreshFireNodeState(entityId: string, entityModel: Model): FireNodeState?
	local state = fireNodeStateByEntityId[entityId]
	local needsRebuild = state == nil or #state.nodes == 0

	if not needsRebuild then
		for _, node in ipairs(state.nodes) do
			if node.mount.Parent == nil or not node.mount:IsDescendantOf(entityModel) then
				needsRebuild = true
				break
			end
		end
	end

	if needsRebuild then
		local nodes = collectFireNodes(entityModel)
		if #nodes == 0 then
			fireNodeStateByEntityId[entityId] = nil
			return nil
		end
		state = {
			nodes = nodes,
			nextIndex = 1,
		}
		fireNodeStateByEntityId[entityId] = state
	end

	return state
end

local function getNextFireNode(entityId: string, entityModel: Model): FireNode?
	local state = getOrRefreshFireNodeState(entityId, entityModel)
	if state == nil then
		return nil
	end

	local count = #state.nodes
	if count == 0 then
		return nil
	end

	local index = math.clamp(state.nextIndex, 1, count)
	local node = state.nodes[index]
	state.nextIndex = if index >= count then 1 else index + 1
	return node
end

local function setFireNodeAttributes(entityModel: Model, entityId: string)
	local state = fireNodeStateByEntityId[entityId]
	if state == nil then
		entityModel:SetAttribute("WeaponMountCount", 0)
		entityModel:SetAttribute("WeaponMuzzleCount", 0)
		return
	end

	local uniqueMounts: { [BasePart]: boolean } = {}
	for _, node in ipairs(state.nodes) do
		uniqueMounts[node.mount] = true
	end

	local mountCount = 0
	for _ in pairs(uniqueMounts) do
		mountCount += 1
	end

	entityModel:SetAttribute("WeaponMountCount", mountCount)
	entityModel:SetAttribute("WeaponMuzzleCount", #state.nodes)
end

local function getHeatParams(weaponConfig: WeaponConfig): (number, number, number, number)
	if type(weaponConfig.heatMax) ~= "number" or weaponConfig.heatMax <= 0 then
		return 0, 0, 0, 0
	end

	local heatMax = weaponConfig.heatMax

	local heatPerShot = DEFAULT_HEAT_PER_SHOT
	if type(weaponConfig.heatPerShot) == "number" and weaponConfig.heatPerShot >= 0 then
		heatPerShot = weaponConfig.heatPerShot
	end

	local heatDecayPerSecond = DEFAULT_HEAT_DECAY_PER_SECOND
	if type(weaponConfig.heatDecayPerSecond) == "number" and weaponConfig.heatDecayPerSecond >= 0 then
		heatDecayPerSecond = weaponConfig.heatDecayPerSecond
	end

	local heatRecoverThreshold = heatMax * DEFAULT_HEAT_RECOVER_FRACTION
	if type(weaponConfig.heatRecoverThreshold) == "number" then
		heatRecoverThreshold = weaponConfig.heatRecoverThreshold
	end
	heatRecoverThreshold = math.clamp(heatRecoverThreshold, 0, heatMax)

	return heatMax, heatPerShot, heatDecayPerSecond, heatRecoverThreshold
end

local function getAmmoCapacity(weaponConfig: WeaponConfig): number
	if type(weaponConfig.ammoCapacity) ~= "number" then
		return 0
	end
	return math.max(0, math.floor(weaponConfig.ammoCapacity + 0.5))
end

local function getOrCreateHeatState(entityId: string, nowServer: number): WeaponHeatState
	local existing = heatStateByEntityId[entityId]
	if existing ~= nil then
		return existing
	end

	local state: WeaponHeatState = {
		heat = 0,
		lastUpdatedAt = nowServer,
		lastShotAt = 0,
		overheated = false,
		recoverCueId = 0,
		recoverToken = 0,
	}
	heatStateByEntityId[entityId] = state
	return state
end

local function setAmmoAttributes(entityModel: Model, ammoState: AmmoState?)
	if ammoState == nil then
		entityModel:SetAttribute("WeaponAmmo", nil)
		entityModel:SetAttribute("WeaponAmmoMax", nil)
		return
	end

	entityModel:SetAttribute("WeaponAmmo", ammoState.current)
	entityModel:SetAttribute("WeaponAmmoMax", ammoState.max)
end

local function coolHeatState(state: WeaponHeatState, nowServer: number, heatDecayPerSecond: number, heatMax: number)
	local elapsed = math.max(0, nowServer - state.lastUpdatedAt)
	if elapsed > 0 and heatDecayPerSecond > 0 and heatMax > 0 then
		-- Exponential cooling feels more physical than fixed linear drain.
		local coolingRate = heatDecayPerSecond / heatMax
		state.heat = math.clamp(state.heat * math.exp(-coolingRate * elapsed), 0, heatMax)
	end
	state.lastUpdatedAt = nowServer
end

local function computeShotHeat(
	baseHeatPerShot: number,
	cooldown: number,
	nowServer: number,
	lastShotAt: number
): number
	if cooldown <= 0 or lastShotAt <= 0 then
		return baseHeatPerShot
	end

	local timeSinceShot = math.max(0, nowServer - lastShotAt)
	local cadenceRatio = timeSinceShot / cooldown
	local multiplier = 1

	if cadenceRatio < 1 then
		multiplier = 1 + (1 - cadenceRatio) * CADENCE_RAPID_BONUS_MAX
	elseif cadenceRatio > 1 then
		local slowNormalized = math.clamp((cadenceRatio - 1) / (CADENCE_SLOW_DISCOUNT_WINDOW - 1), 0, 1)
		multiplier = 1 - slowNormalized * CADENCE_SLOW_DISCOUNT_MAX
	end

	return baseHeatPerShot * multiplier
end

local function getWeaponClass(weaponConfig: WeaponConfig): string
	if type(weaponConfig.weaponClass) == "string" and weaponConfig.weaponClass ~= "" then
		return string.lower(weaponConfig.weaponClass)
	end
	return DEFAULT_WEAPON_CLASS
end

local function getBurstParams(weaponConfig: WeaponConfig): (number, number)
	local burstCount = DEFAULT_BURST_COUNT
	if type(weaponConfig.burstCount) == "number" then
		burstCount = math.max(1, math.floor(weaponConfig.burstCount + 0.5))
	end

	local burstInterval = DEFAULT_BURST_INTERVAL
	if type(weaponConfig.burstInterval) == "number" then
		burstInterval = math.max(0, weaponConfig.burstInterval)
	end

	return burstCount, burstInterval
end

local function parseColor3String(raw: string): Color3?
	local rRaw, gRaw, bRaw = string.match(raw, "^%s*([%+%-]?[%d%.]+)%s*,%s*([%+%-]?[%d%.]+)%s*,%s*([%+%-]?[%d%.]+)%s*$")
	if rRaw == nil or gRaw == nil or bRaw == nil then
		return nil
	end

	local r = tonumber(rRaw)
	local g = tonumber(gRaw)
	local b = tonumber(bRaw)
	if r == nil or g == nil or b == nil then
		return nil
	end

	if r <= 1 and g <= 1 and b <= 1 and r >= 0 and g >= 0 and b >= 0 then
		return Color3.new(r, g, b)
	end

	return Color3.fromRGB(math.clamp(math.floor(r + 0.5), 0, 255), math.clamp(math.floor(g + 0.5), 0, 255), math.clamp(math.floor(b + 0.5), 0, 255))
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
	mount: BasePart,
	drivenParts: { DrivenPartState },
	clampOverride: RigOverride?
)
	if part == mount or seen[part] then
		return
	end

	seen[part] = true
	table.insert(drivenParts, {
		part = part,
		neutralAimFrame = WeaponRig.getNeutralAimFrame(part),
		clampOverride = clampOverride,
	})
end

local function collectDrivenPartsFromContainer(
	container: Instance,
	seen: { [BasePart]: boolean },
	mount: BasePart,
	drivenParts: { DrivenPartState },
	clampOverride: RigOverride?
)
	for _, descendant in ipairs(container:GetDescendants()) do
		if descendant:IsA("BasePart") then
			addDrivenPart(descendant, seen, mount, drivenParts, clampOverride)
		elseif descendant:IsA("ObjectValue") and descendant.Value ~= nil and descendant.Value:IsA("BasePart") then
			addDrivenPart(descendant.Value, seen, mount, drivenParts, clampOverride)
		end
	end
end

local function collectDrivenRigState(entityModel: Model): DrivenRigState?
	local mountCandidates = findTaggedDescendants(entityModel, "WeaponMount", "BasePart")
	local mountInstance = mountCandidates[1]
	if mountInstance == nil then
		return nil
	end

	local mount = mountInstance :: BasePart
	local drivenParts: { DrivenPartState } = {}
	local seen: { [BasePart]: boolean } = { [mount] = true }

	local rigFolder = entityModel:FindFirstChild("TurretRig")
	if rigFolder ~= nil then
		local drivenPartsFolder = rigFolder:FindFirstChild("DrivenParts")
		if drivenPartsFolder ~= nil then
			local clampOverride = getClampOverride(drivenPartsFolder, nil)
			collectDrivenPartsFromContainer(drivenPartsFolder, seen, mount, drivenParts, clampOverride)
		end

		for _, child in ipairs(rigFolder:GetChildren()) do
			if child:IsA("Folder") and child.Name ~= "DrivenParts" then
				local modeOverride = modeFromFolderName(child.Name)
				local clampOverride = getClampOverride(child, modeOverride)
				if modeOverride ~= nil or clampOverride ~= nil then
					collectDrivenPartsFromContainer(child, seen, mount, drivenParts, clampOverride)
				end
			end
		end
	end

	return {
		mount = mount,
		mountNeutralAimFrame = WeaponRig.getNeutralAimFrame(mount),
		drivenParts = drivenParts,
	}
end

local function getOrRefreshDrivenRigState(entityId: string, entityModel: Model): DrivenRigState?
	local state = drivenRigStateByEntityId[entityId]
	local needsRebuild = state == nil

	if not needsRebuild then
		if state.mount.Parent == nil or not state.mount:IsDescendantOf(entityModel) then
			needsRebuild = true
		else
			for _, driven in ipairs(state.drivenParts) do
				if driven.part.Parent == nil then
					needsRebuild = true
					break
				end
			end
		end
	end

	if needsRebuild then
		state = collectDrivenRigState(entityModel)
		drivenRigStateByEntityId[entityId] = state
	end

	return state
end

local function applyAimToRig(entityId: string, entityModel: Model, desiredDirection: Vector3): Vector3?
	if desiredDirection.Magnitude < 1e-4 then
		return nil
	end

	local drivenState = getOrRefreshDrivenRigState(entityId, entityModel)
	if drivenState == nil then
		return nil
	end

	local mount = drivenState.mount
	local clampedDirection =
		WeaponRig.clampDirectionToMountLimits(mount, drivenState.mountNeutralAimFrame, desiredDirection.Unit)
	if clampedDirection.Magnitude <= 1e-4 then
		return nil
	end

	mount.CFrame = WeaponRig.getAimFrame(mount, clampedDirection)

	for index = #drivenState.drivenParts, 1, -1 do
		local driven = drivenState.drivenParts[index]
		if driven.part.Parent == nil then
			table.remove(drivenState.drivenParts, index)
		else
			local drivenDirection = WeaponRig.clampDirectionToMountLimits(
				driven.part,
				driven.neutralAimFrame,
				clampedDirection,
				driven.clampOverride
			)
			if drivenDirection.Magnitude > 1e-4 then
				driven.part.CFrame = WeaponRig.getAimFrame(driven.part, drivenDirection, driven.clampOverride)
			end
		end
	end

	return clampedDirection
end

local function readColorAttribute(instance: Instance, name: string): Color3?
	local raw = instance:GetAttribute(name)
	if typeof(raw) == "Color3" then
		return raw :: Color3
	end
	if typeof(raw) == "BrickColor" then
		return (raw :: BrickColor).Color
	end
	if type(raw) == "string" then
		return parseColor3String(raw)
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

local function applyDirectionalSpread(direction: Vector3, spreadDegrees: number): Vector3
	if direction.Magnitude < 1e-4 then
		return Vector3.new(0, 0, -1)
	end
	if spreadDegrees <= 0 then
		return direction.Unit
	end

	local spreadRadians = math.rad(spreadDegrees)
	local yaw = (math.random() * 2 - 1) * spreadRadians
	local pitch = (math.random() * 2 - 1) * spreadRadians
	local lookFrame = CFrame.lookAt(Vector3.zero, direction.Unit)
	return (lookFrame * CFrame.Angles(pitch, yaw, 0)).LookVector.Unit
end

local function resolveWeaponConfig(entityModel: Model, baseWeaponConfig: WeaponConfig): WeaponConfig
	local resolved: WeaponConfig = {
		weaponClass = baseWeaponConfig.weaponClass,
		damageType = baseWeaponConfig.damageType,
		damage = baseWeaponConfig.damage,
		fireRate = baseWeaponConfig.fireRate,
		projectileSpeed = baseWeaponConfig.projectileSpeed,
		maxRange = baseWeaponConfig.maxRange,
		lockRange = baseWeaponConfig.lockRange,
		unlockedSpread = baseWeaponConfig.unlockedSpread,
		autoAimSpread = baseWeaponConfig.autoAimSpread,
		requiresLock = baseWeaponConfig.requiresLock,
		homingTurnRate = baseWeaponConfig.homingTurnRate,
		boltColor = baseWeaponConfig.boltColor,
		splashRadius = baseWeaponConfig.splashRadius,
		burstCount = baseWeaponConfig.burstCount,
		burstInterval = baseWeaponConfig.burstInterval,
		heatMax = baseWeaponConfig.heatMax,
		heatPerShot = baseWeaponConfig.heatPerShot,
		heatDecayPerSecond = baseWeaponConfig.heatDecayPerSecond,
		heatRecoverThreshold = baseWeaponConfig.heatRecoverThreshold,
		ammoCapacity = baseWeaponConfig.ammoCapacity,
		artilleryGravity = baseWeaponConfig.artilleryGravity,
		artilleryMinElevation = baseWeaponConfig.artilleryMinElevation,
		artilleryMaxElevation = baseWeaponConfig.artilleryMaxElevation,
		artilleryAdjustSpeed = baseWeaponConfig.artilleryAdjustSpeed,
		artilleryFineAdjustSpeed = baseWeaponConfig.artilleryFineAdjustSpeed,
		artilleryMinRange = baseWeaponConfig.artilleryMinRange,
	}

	local weaponClassOverride = entityModel:GetAttribute(ATTR_WEAPON_CLASS)
	if type(weaponClassOverride) == "string" and weaponClassOverride ~= "" then
		resolved.weaponClass = string.lower(weaponClassOverride)
	end

	local damageTypeOverride = entityModel:GetAttribute(ATTR_DAMAGE_TYPE)
	if type(damageTypeOverride) == "string" and damageTypeOverride ~= "" then
		resolved.damageType = damageTypeOverride
	end

	local damageModifier = readNumberAttribute(entityModel, ATTR_DAMAGE_MODIFIER)
	if damageModifier == nil then
		damageModifier = readNumberAttribute(entityModel, ATTR_DAMAGE_PERCENT)
	end
	resolved.damage = applyPercentModifier(resolved.damage, damageModifier, 0)

	local fireRateModifier = readNumberAttribute(entityModel, ATTR_FIRE_RATE_MODIFIER)
	resolved.fireRate = applyPercentModifier(resolved.fireRate, fireRateModifier, 0.01)

	local projectileSpeedModifier = readNumberAttribute(entityModel, ATTR_PROJECTILE_SPEED_MODIFIER)
	resolved.projectileSpeed = applyPercentModifier(resolved.projectileSpeed, projectileSpeedModifier, 0.01)

	local maxRangeModifier = readNumberAttribute(entityModel, ATTR_MAX_RANGE_MODIFIER)
	resolved.maxRange = applyPercentModifier(resolved.maxRange, maxRangeModifier, 1)
	if type(resolved.lockRange) == "number" then
		resolved.lockRange = applyPercentModifier(resolved.lockRange, maxRangeModifier, 1)
		if resolved.lockRange >= resolved.maxRange then
			resolved.lockRange = math.max(0, resolved.maxRange - 1)
		end
	end

	local splashRadiusOverride = readNumberAttribute(entityModel, ATTR_SPLASH_RADIUS)
	if splashRadiusOverride ~= nil then
		resolved.splashRadius = math.max(0, splashRadiusOverride)
	elseif resolved.splashRadius == nil then
		resolved.splashRadius = 0
	end
	local splashEnabledOverride = readBoolAttribute(entityModel, ATTR_SPLASH_ENABLED)
	local splashEnabled = (baseWeaponConfig.splashRadius or 0) > 0
	if splashEnabledOverride ~= nil then
		splashEnabled = splashEnabledOverride
	end
	if not splashEnabled then
		resolved.splashRadius = 0
	end

	local baseBurstCount = if type(resolved.burstCount) == "number" then resolved.burstCount else DEFAULT_BURST_COUNT
	local burstCountModifier = readNumberAttribute(entityModel, ATTR_BURST_COUNT_MODIFIER)
	local scaledBurstCount = applyPercentModifier(baseBurstCount, burstCountModifier, 1)
	resolved.burstCount = math.max(1, math.floor(scaledBurstCount + 0.5))

	local baseBurstInterval = if type(resolved.burstInterval) == "number" then resolved.burstInterval else DEFAULT_BURST_INTERVAL
	local burstIntervalModifier = readNumberAttribute(entityModel, ATTR_BURST_INTERVAL_MODIFIER)
	resolved.burstInterval = applyPercentModifier(baseBurstInterval, burstIntervalModifier, 0)

	local baseHeatMax = if type(resolved.heatMax) == "number" and resolved.heatMax > 0 then resolved.heatMax else DEFAULT_HEAT_MAX
	local heatMaxModifier = readNumberAttribute(entityModel, ATTR_HEAT_MAX_MODIFIER)
	resolved.heatMax = applyPercentModifier(baseHeatMax, heatMaxModifier, 0.01)

	local baseHeatPerShot = if type(resolved.heatPerShot) == "number" and resolved.heatPerShot >= 0 then resolved.heatPerShot else DEFAULT_HEAT_PER_SHOT
	local heatPerShotModifier = readNumberAttribute(entityModel, ATTR_HEAT_PER_SHOT_MODIFIER)
	resolved.heatPerShot = applyPercentModifier(baseHeatPerShot, heatPerShotModifier, 0)

	local baseHeatDecay = if type(resolved.heatDecayPerSecond) == "number" and resolved.heatDecayPerSecond >= 0
		then resolved.heatDecayPerSecond
		else DEFAULT_HEAT_DECAY_PER_SECOND
	local heatDecayModifier = readNumberAttribute(entityModel, ATTR_HEAT_DECAY_MODIFIER)
	resolved.heatDecayPerSecond = applyPercentModifier(baseHeatDecay, heatDecayModifier, 0)

	local baseHeatRecoverThreshold = if type(resolved.heatRecoverThreshold) == "number"
		then resolved.heatRecoverThreshold
		else (resolved.heatMax :: number) * DEFAULT_HEAT_RECOVER_FRACTION
	local heatRecoverThresholdModifier = readNumberAttribute(entityModel, ATTR_HEAT_RECOVER_THRESHOLD_MODIFIER)
	resolved.heatRecoverThreshold = applyPercentModifier(baseHeatRecoverThreshold, heatRecoverThresholdModifier, 0)

	local boltColorOverride = readColorAttribute(entityModel, ATTR_BOLT_COLOR)
	if boltColorOverride ~= nil then
		resolved.boltColor = boltColorOverride
	end

	local ammoCapacityOverride = readNumberAttribute(entityModel, ATTR_AMMO_CAPACITY)
	if ammoCapacityOverride ~= nil then
		resolved.ammoCapacity = math.max(1, math.floor(ammoCapacityOverride + 0.5))
	end

	local artilleryGravityOverride = readNumberAttribute(entityModel, ATTR_ARTILLERY_GRAVITY)
	if artilleryGravityOverride ~= nil then
		resolved.artilleryGravity = math.max(1, artilleryGravityOverride)
	end

	local artilleryMinElevOverride = readNumberAttribute(entityModel, ATTR_ARTILLERY_MIN_ELEVATION)
	if artilleryMinElevOverride ~= nil then
		resolved.artilleryMinElevation = math.clamp(artilleryMinElevOverride, 0, 89)
	end

	local artilleryMaxElevOverride = readNumberAttribute(entityModel, ATTR_ARTILLERY_MAX_ELEVATION)
	if artilleryMaxElevOverride ~= nil then
		resolved.artilleryMaxElevation = math.clamp(artilleryMaxElevOverride, 1, 90)
	end

	local artilleryAdjustSpeedOverride = readNumberAttribute(entityModel, ATTR_ARTILLERY_ADJUST_SPEED)
	if artilleryAdjustSpeedOverride ~= nil then
		resolved.artilleryAdjustSpeed = math.max(1, artilleryAdjustSpeedOverride)
	end

	local artilleryFineAdjustOverride = readNumberAttribute(entityModel, ATTR_ARTILLERY_FINE_ADJUST_SPEED)
	if artilleryFineAdjustOverride ~= nil then
		resolved.artilleryFineAdjustSpeed = math.max(0.1, artilleryFineAdjustOverride)
	end

	local artilleryMinRangeOverride = readNumberAttribute(entityModel, ATTR_ARTILLERY_MIN_RANGE)
	if artilleryMinRangeOverride ~= nil then
		resolved.artilleryMinRange = math.max(0, artilleryMinRangeOverride)
	end

	return resolved
end

local function publishResolvedWeaponAttributes(entityModel: Model, weaponConfig: WeaponConfig)
	entityModel:SetAttribute(EFFECTIVE_WEAPON_CLASS, weaponConfig.weaponClass or DEFAULT_WEAPON_CLASS)
	entityModel:SetAttribute(EFFECTIVE_DAMAGE_TYPE, weaponConfig.damageType)
	entityModel:SetAttribute(EFFECTIVE_DAMAGE, weaponConfig.damage)
	entityModel:SetAttribute(EFFECTIVE_FIRE_RATE, weaponConfig.fireRate)
	entityModel:SetAttribute(EFFECTIVE_PROJECTILE_SPEED, weaponConfig.projectileSpeed)
	entityModel:SetAttribute(EFFECTIVE_MAX_RANGE, weaponConfig.maxRange)
	entityModel:SetAttribute(EFFECTIVE_LOCK_RANGE, weaponConfig.lockRange)
	entityModel:SetAttribute(EFFECTIVE_UNLOCKED_SPREAD, weaponConfig.unlockedSpread)
	entityModel:SetAttribute(EFFECTIVE_AUTO_AIM_SPREAD, weaponConfig.autoAimSpread)
	entityModel:SetAttribute(EFFECTIVE_REQUIRES_LOCK, weaponConfig.requiresLock == true)
	entityModel:SetAttribute(EFFECTIVE_HOMING_TURN_RATE, weaponConfig.homingTurnRate)
	entityModel:SetAttribute(EFFECTIVE_SPLASH_ENABLED, (weaponConfig.splashRadius or 0) > 0)
	entityModel:SetAttribute(EFFECTIVE_SPLASH_RADIUS, weaponConfig.splashRadius)
	entityModel:SetAttribute(EFFECTIVE_BURST_COUNT, weaponConfig.burstCount)
	entityModel:SetAttribute(EFFECTIVE_BURST_INTERVAL, weaponConfig.burstInterval)
	entityModel:SetAttribute(EFFECTIVE_HEAT_MAX, weaponConfig.heatMax)
	entityModel:SetAttribute(EFFECTIVE_HEAT_PER_SHOT, weaponConfig.heatPerShot)
	entityModel:SetAttribute(EFFECTIVE_HEAT_DECAY, weaponConfig.heatDecayPerSecond)
	entityModel:SetAttribute(EFFECTIVE_HEAT_RECOVER_THRESHOLD, weaponConfig.heatRecoverThreshold)
	if weaponConfig.boltColor ~= nil then
		entityModel:SetAttribute(EFFECTIVE_BOLT_COLOR, weaponConfig.boltColor)
	else
		entityModel:SetAttribute(EFFECTIVE_BOLT_COLOR, nil)
	end
	entityModel:SetAttribute("EffectiveAmmoCapacity", weaponConfig.ammoCapacity)
	entityModel:SetAttribute("EffectiveArtilleryGravity", weaponConfig.artilleryGravity)
	entityModel:SetAttribute("EffectiveArtilleryMinElevation", weaponConfig.artilleryMinElevation)
	entityModel:SetAttribute("EffectiveArtilleryMaxElevation", weaponConfig.artilleryMaxElevation)
	entityModel:SetAttribute("EffectiveArtilleryAdjustSpeed", weaponConfig.artilleryAdjustSpeed)
	entityModel:SetAttribute("EffectiveArtilleryFineAdjustSpeed", weaponConfig.artilleryFineAdjustSpeed)
	entityModel:SetAttribute("EffectiveArtilleryMinRange", weaponConfig.artilleryMinRange)
end

local function setHeatAttributes(
	entityModel: Model,
	state: WeaponHeatState,
	heatMax: number,
	heatDecayPerSecond: number,
	heatRecoverThreshold: number
)
	if heatMax <= 0 then
		entityModel:SetAttribute("WeaponHeat", nil)
		entityModel:SetAttribute("WeaponHeatMax", nil)
		entityModel:SetAttribute("WeaponHeatDecayPerSecond", nil)
		entityModel:SetAttribute("WeaponHeatRecoverThreshold", nil)
		entityModel:SetAttribute("WeaponOverheated", false)
		entityModel:SetAttribute("WeaponHeatUpdatedAt", nil)
		entityModel:SetAttribute("WeaponHeatRecoverCueId", nil)
		return
	end

	entityModel:SetAttribute("WeaponHeat", state.heat)
	entityModel:SetAttribute("WeaponHeatMax", heatMax)
	entityModel:SetAttribute("WeaponHeatDecayPerSecond", heatDecayPerSecond)
	entityModel:SetAttribute("WeaponHeatRecoverThreshold", heatRecoverThreshold)
	entityModel:SetAttribute("WeaponOverheated", state.overheated)
	entityModel:SetAttribute("WeaponHeatUpdatedAt", state.lastUpdatedAt)
	entityModel:SetAttribute("WeaponHeatRecoverCueId", state.recoverCueId)
end

local function scheduleRecoveryCue(entityId: string, weaponConfig: WeaponConfig)
	local state = heatStateByEntityId[entityId]
	if state == nil or not state.overheated then
		return
	end

	local heatMax, _, heatDecayPerSecond, heatRecoverThreshold = getHeatParams(weaponConfig)
	if heatDecayPerSecond <= 0 then
		return
	end

	state.recoverToken += 1
	local token = state.recoverToken
	local recoverDelay = 0
	local recoverThreshold = math.max(0.001, heatRecoverThreshold)
	if state.heat > recoverThreshold and heatMax > 0 then
		local coolingRate = heatDecayPerSecond / heatMax
		if coolingRate > 0 then
			recoverDelay = math.log(state.heat / recoverThreshold) / coolingRate
		end
	end

	task.delay(recoverDelay + 0.02, function()
		local liveState = heatStateByEntityId[entityId]
		if liveState == nil or liveState.recoverToken ~= token then
			return
		end

		local healthState = HealthManager.getHealth(entityId)
		if healthState == nil or healthState.config.weaponId == nil then
			return
		end

		local liveBaseWeaponConfig = CombatConfig.Weapons[healthState.config.weaponId]
		if liveBaseWeaponConfig == nil then
			return
		end

		local liveWeaponConfig = resolveWeaponConfig(healthState.instance, liveBaseWeaponConfig)
		publishResolvedWeaponAttributes(healthState.instance, liveWeaponConfig)
		local liveHeatMax, _, liveHeatDecay, liveRecoverThreshold = getHeatParams(liveWeaponConfig)
		local nowServer = Workspace:GetServerTimeNow()
		coolHeatState(liveState, nowServer, liveHeatDecay, liveHeatMax)

		if liveState.overheated and liveState.heat <= liveRecoverThreshold then
			liveState.overheated = false
			liveState.recoverCueId += 1
			liveState.recoverToken += 1
		end

		setHeatAttributes(healthState.instance, liveState, liveHeatMax, liveHeatDecay, liveRecoverThreshold)
	end)
end

local function fireSingleProjectile(
	entityModel: Model,
	entityId: string,
	healthState: HealthState,
	weaponConfig: WeaponConfig,
	character: Model,
	normalizedDirection: Vector3,
	cooldown: number,
	lockState: LockState?,
	applyAimSpread: boolean
): boolean
	if normalizedDirection.Magnitude < 1e-4 then
		return false
	end

	local nowServer = Workspace:GetServerTimeNow()
	local ammoState = ammoStateByEntityId[entityId]
	if ammoState ~= nil and ammoState.current <= 0 then
		print(string.format("[P3_AMMO_EMPTY] entity=%s", entityId))
		setAmmoAttributes(entityModel, ammoState)
		return false
	end

	local heatMax, heatPerShot, heatDecayPerSecond, heatRecoverThreshold = getHeatParams(weaponConfig)
	local heatEnabled = heatMax > 0
	local heatState = getOrCreateHeatState(entityId, nowServer)
	if heatEnabled then
		coolHeatState(heatState, nowServer, heatDecayPerSecond, heatMax)

		if heatState.overheated and heatState.heat <= heatRecoverThreshold then
			heatState.overheated = false
			heatState.recoverCueId += 1
			heatState.recoverToken += 1
		end

		if heatState.overheated then
			setHeatAttributes(entityModel, heatState, heatMax, heatDecayPerSecond, heatRecoverThreshold)
			return false
		end
	else
		heatState.heat = 0
		heatState.overheated = false
		heatState.lastUpdatedAt = nowServer
		heatState.lastShotAt = 0
	end

	local fireNode = getNextFireNode(entityId, entityModel)
	if fireNode == nil then
		return false
	end

	local neutralAimFrame = WeaponRig.getNeutralAimFrame(fireNode.mount)
	local clampedDirection = WeaponRig.clampDirectionToMountLimits(fireNode.mount, neutralAimFrame, normalizedDirection)
	if clampedDirection.Magnitude < 1e-4 then
		return false
	end

	local originFrame = WeaponRig.getAimFrame(fireNode.mount, clampedDirection)
	local fireOrigin = originFrame:PointToWorldSpace(fireNode.muzzleLocalOffset)
	local resolvedDirection = clampedDirection

	if applyAimSpread then
		if lockState ~= nil and type(weaponConfig.autoAimSpread) == "number" then
			local autoAimDirection = TargetingServer.computeLeadDirection(
				fireOrigin,
				lockState.targetEntityId,
				weaponConfig.projectileSpeed,
				weaponConfig.autoAimSpread
			)
			if autoAimDirection ~= nil then
				local autoClampedDirection =
					WeaponRig.clampDirectionToMountLimits(fireNode.mount, neutralAimFrame, autoAimDirection.Unit)
				if autoClampedDirection.Magnitude >= 1e-4 then
					resolvedDirection = autoClampedDirection
					local autoOriginFrame = WeaponRig.getAimFrame(fireNode.mount, resolvedDirection)
					fireOrigin = autoOriginFrame:PointToWorldSpace(fireNode.muzzleLocalOffset)
					print(string.format(
						"[P4_AUTO_AIM] entity=%s target=%s spread=%.2f",
						entityId,
						lockState.targetEntityId,
						weaponConfig.autoAimSpread
					))
				end
			end
		elseif lockState == nil and type(weaponConfig.unlockedSpread) == "number" and weaponConfig.unlockedSpread > 0 then
			local spreadDirection = applyDirectionalSpread(resolvedDirection, weaponConfig.unlockedSpread)
			local spreadClampedDirection =
				WeaponRig.clampDirectionToMountLimits(fireNode.mount, neutralAimFrame, spreadDirection)
			if spreadClampedDirection.Magnitude >= 1e-4 then
				resolvedDirection = spreadClampedDirection
				local spreadOriginFrame = WeaponRig.getAimFrame(fireNode.mount, resolvedDirection)
				fireOrigin = spreadOriginFrame:PointToWorldSpace(fireNode.muzzleLocalOffset)
			end
		end
	end

	local faction = HealthManager.getFaction(entityId)
	if faction == nil then
		return false
	end

	projectileCounter += 1
	local projectileId = "proj_" .. tostring(projectileCounter)
	local projectileData: ProjectileData = {
		projectileId = projectileId,
			sourceEntityId = entityId,
			sourceInstance = healthState.instance,
			sourceCharacter = character,
			origin = fireOrigin,
			direction = resolvedDirection,
			speed = weaponConfig.projectileSpeed,
			maxRange = weaponConfig.maxRange,
			damage = weaponConfig.damage,
			damageType = weaponConfig.damageType,
			faction = faction,
			boltColor = weaponConfig.boltColor,
			splashRadius = weaponConfig.splashRadius,
			targetEntityId = nil,
			homingTurnRate = nil,
			currentPosition = nil,
			createdAt = tick(),
		}
	if lockState ~= nil and type(weaponConfig.homingTurnRate) == "number" and weaponConfig.homingTurnRate > 0 then
		projectileData.targetEntityId = lockState.targetEntityId
		projectileData.homingTurnRate = weaponConfig.homingTurnRate
	end

	if ammoState ~= nil then
		ammoState.current = math.max(0, ammoState.current - 1)
		setAmmoAttributes(entityModel, ammoState)
		print(string.format("[P3_AMMO] entity=%s ammo=%d/%d", entityId, ammoState.current, ammoState.max))
	end

	local wasOverheated = heatState.overheated
	if heatEnabled then
		local shotHeat = computeShotHeat(heatPerShot, cooldown, nowServer, heatState.lastShotAt)
		heatState.heat = math.min(heatMax, heatState.heat + shotHeat)
		heatState.lastUpdatedAt = nowServer
		heatState.lastShotAt = nowServer
		if heatState.heat >= heatMax then
			heatState.overheated = true
		end
	else
		heatState.heat = 0
		heatState.overheated = false
		heatState.lastUpdatedAt = nowServer
	end
	setHeatAttributes(entityModel, heatState, heatMax, heatDecayPerSecond, heatRecoverThreshold)
	if heatEnabled and not wasOverheated and heatState.overheated then
		scheduleRecoveryCue(entityId, weaponConfig)
	end

	ProjectileServer.fireProjectile(projectileData)
	return true
end

local function fireArtilleryProjectile(
	entityModel: Model,
	entityId: string,
	healthState: HealthState,
	weaponConfig: WeaponConfig,
	character: Model,
	normalizedDirection: Vector3,
	cooldown: number
): boolean
	if normalizedDirection.Magnitude < 1e-4 then
		return false
	end

	local ammoState = ammoStateByEntityId[entityId]
	if ammoState ~= nil and ammoState.current <= 0 then
		print(string.format("[P3_AMMO_EMPTY] entity=%s", entityId))
		setAmmoAttributes(entityModel, ammoState)
		return false
	end

	local fireNode = getNextFireNode(entityId, entityModel)
	if fireNode == nil then
		return false
	end

	local neutralAimFrame = WeaponRig.getNeutralAimFrame(fireNode.mount)
	local clampedDirection = WeaponRig.clampDirectionToMountLimits(fireNode.mount, neutralAimFrame, normalizedDirection)
	if clampedDirection.Magnitude < 1e-4 then
		return false
	end

	local originFrame = WeaponRig.getAimFrame(fireNode.mount, clampedDirection)
	local fireOrigin = originFrame:PointToWorldSpace(fireNode.muzzleLocalOffset)

	local faction = HealthManager.getFaction(entityId)
	if faction == nil then
		return false
	end

	projectileCounter += 1
	local projectileId = "proj_" .. tostring(projectileCounter)
	local projectileData: ProjectileData = {
		projectileId = projectileId,
		sourceEntityId = entityId,
		sourceInstance = healthState.instance,
		sourceCharacter = character,
		origin = fireOrigin,
		direction = clampedDirection,
		speed = weaponConfig.projectileSpeed,
		maxRange = weaponConfig.maxRange,
		damage = weaponConfig.damage,
		damageType = weaponConfig.damageType,
		faction = faction,
		boltColor = weaponConfig.boltColor,
		splashRadius = weaponConfig.splashRadius,
		targetEntityId = nil,
		homingTurnRate = nil,
		currentPosition = nil,
		createdAt = tick(),
		artilleryGravity = weaponConfig.artilleryGravity,
		currentVelocity = nil,
	}

	if ammoState ~= nil then
		ammoState.current = math.max(0, ammoState.current - 1)
		setAmmoAttributes(entityModel, ammoState)
		print(string.format("[P3_AMMO] entity=%s ammo=%d/%d", entityId, ammoState.current, ammoState.max))
	end

	local elevationDeg = math.deg(math.asin(math.clamp(clampedDirection.Y, -1, 1)))
	local headingRad = math.atan2(-clampedDirection.X, -clampedDirection.Z)
	local headingDeg = math.deg(headingRad) % 360
	local artilleryGravity = weaponConfig.artilleryGravity or 300
	local v = weaponConfig.projectileSpeed
	local flatRange = v * v * math.sin(2 * math.asin(math.clamp(clampedDirection.Y, -1, 1))) / artilleryGravity
	print(string.format(
		"[P7_FIRE] entity=%s elevation=%.1f heading=%.1f range=%.0f",
		entityId, elevationDeg, headingDeg, math.max(0, flatRange)
	))

	ProjectileServer.fireProjectile(projectileData)
	return true
end

local function resolvePlayerTurretContext(player: Player): (Model?, Model?, string?, HealthState?)
	local character = player.Character
	if character == nil then
		return nil, nil, nil, nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return nil, nil, nil, nil
	end

	local seatPart = humanoid.SeatPart
	if seatPart == nil or (not CollectionService:HasTag(seatPart, "TurretSeat") and not CollectionService:HasTag(seatPart, "ArtillerySeat")) then
		return nil, nil, nil, nil
	end

	local entityModel = seatPart:FindFirstAncestorWhichIsA("Model")
	if entityModel == nil then
		return nil, nil, nil, nil
	end

	local entityIdAttr = entityModel:GetAttribute("EntityId")
	if type(entityIdAttr) ~= "string" then
		return nil, nil, nil, nil
	end

	local entityId = entityIdAttr
	if not HealthManager.isAlive(entityId) then
		return nil, nil, nil, nil
	end

	local healthState: HealthState? = HealthManager.getHealth(entityId)
	if healthState == nil or healthState.config.weaponId == nil then
		return nil, nil, nil, nil
	end

	return character, entityModel, entityId, healthState
end

local function onUpdateTurretAim(player: Player, aimDirection: Vector3)
	if typeof(aimDirection) ~= "Vector3" or aimDirection.Magnitude < 1e-4 then
		return
	end

	local now = tick()
	local lastUpdate = lastAimUpdateByPlayer[player]
	if lastUpdate ~= nil and now - lastUpdate < AIM_UPDATE_INTERVAL * 0.5 then
		return
	end

	local _character, entityModel, entityId, _healthState = resolvePlayerTurretContext(player)
	if entityModel == nil or entityId == nil then
		return
	end

	local applied = applyAimToRig(entityId, entityModel, aimDirection.Unit)
	if applied ~= nil then
		lastAimUpdateByPlayer[player] = now
	end
end

local function onFireWeapon(player: Player, aimDirection: Vector3)
	if typeof(aimDirection) ~= "Vector3" then
		return
	end

	local character, entityModel, entityId, healthState = resolvePlayerTurretContext(player)
	if character == nil or entityModel == nil or entityId == nil or healthState == nil then
		return
	end

	local baseWeaponConfig = CombatConfig.Weapons[healthState.config.weaponId]
	if baseWeaponConfig == nil then
		return
	end

	local weaponConfig = resolveWeaponConfig(entityModel, baseWeaponConfig)
	publishResolvedWeaponAttributes(entityModel, weaponConfig)
	if weaponConfig.fireRate <= 0 then
		return
	end

	local now = tick()
	local cooldown = 1 / weaponConfig.fireRate
	local lastFireTime = lastFireTimeByPlayer[player]
	if lastFireTime ~= nil and now - lastFireTime < cooldown then
		return
	end

	if aimDirection.Magnitude < 1e-4 then
		return
	end

	local normalizedDirection = aimDirection.Unit
	applyAimToRig(entityId, entityModel, normalizedDirection)
	local firedAny = false
	local weaponClass = getWeaponClass(weaponConfig)
	local lockState = TargetingServer.getLockState(entityId)
	if weaponConfig.requiresLock == true and lockState == nil then
		print(string.format("[P4_LOCK_REQUIRED] entity=%s", entityId))
		return
	end

	if weaponClass == "projectile" then
		firedAny = fireSingleProjectile(
			entityModel,
			entityId,
			healthState,
			weaponConfig,
			character,
			normalizedDirection,
			cooldown,
			lockState,
			true
		)
	elseif weaponClass == "burst_projectile" then
		local burstCount, burstInterval = getBurstParams(weaponConfig)
		firedAny = fireSingleProjectile(
			entityModel,
			entityId,
			healthState,
			weaponConfig,
			character,
			normalizedDirection,
			cooldown,
			lockState,
			true
		)
		if firedAny and burstCount > 1 then
			for shotIndex = 2, burstCount do
				local delayTime = (shotIndex - 1) * burstInterval
				task.delay(delayTime, function()
					if not HealthManager.isAlive(entityId) then
						return
					end

					local liveHealthState = HealthManager.getHealth(entityId)
					if liveHealthState == nil or liveHealthState.config.weaponId == nil then
						return
					end

					local liveBaseWeaponConfig = CombatConfig.Weapons[liveHealthState.config.weaponId]
					if liveBaseWeaponConfig == nil then
						return
					end

					local liveWeaponConfig = resolveWeaponConfig(entityModel, liveBaseWeaponConfig)
					local liveLockState = TargetingServer.getLockState(entityId)
					if liveWeaponConfig.requiresLock == true and liveLockState == nil then
						print(string.format("[P4_LOCK_REQUIRED] entity=%s", entityId))
						return
					end
					publishResolvedWeaponAttributes(entityModel, liveWeaponConfig)
					fireSingleProjectile(
						entityModel,
						entityId,
						liveHealthState,
						liveWeaponConfig,
						character,
						normalizedDirection,
						cooldown,
						liveLockState,
						true
					)
				end)
			end
		end
	elseif weaponClass == "artillery" then
		local artilleryGravity = weaponConfig.artilleryGravity
		local muzzleVelocity = weaponConfig.projectileSpeed
		if type(artilleryGravity) == "number" and artilleryGravity > 0 and muzzleVelocity > 0 then
			local elevation = math.asin(math.clamp(normalizedDirection.Y, -1, 1))
			local flatRange = muzzleVelocity * muzzleVelocity * math.sin(2 * elevation) / artilleryGravity
			local minRange = weaponConfig.artilleryMinRange or 0
			if flatRange < minRange and minRange > 0 then
				print(string.format("[P7_MIN_RANGE] entity=%s range=%.0f min=%.0f", entityId, flatRange, minRange))
				return
			end
		end
		firedAny = fireArtilleryProjectile(
			entityModel, entityId, healthState, weaponConfig, character, normalizedDirection, cooldown
		)
	else
		if not warnedUnknownWeaponClass[weaponClass] then
			warn(string.format("[P1_WEAPON] Unknown weaponClass '%s'; falling back to projectile", weaponClass))
			warnedUnknownWeaponClass[weaponClass] = true
		end
		firedAny = fireSingleProjectile(
			entityModel,
			entityId,
			healthState,
			weaponConfig,
			character,
			normalizedDirection,
			cooldown,
			lockState,
			true
		)
	end

	if firedAny then
		lastFireTimeByPlayer[player] = now
	end
end

local function resetEntityInternal(entityId: string)
	local healthState = HealthManager.getHealth(entityId)
	if healthState == nil or healthState.config.weaponId == nil then
		return
	end

	local baseWeaponConfig = CombatConfig.Weapons[healthState.config.weaponId]
	if baseWeaponConfig == nil then
		return
	end

	local weaponConfig = resolveWeaponConfig(healthState.instance, baseWeaponConfig)
	publishResolvedWeaponAttributes(healthState.instance, weaponConfig)

	local nowServer = Workspace:GetServerTimeNow()
	local heatMax, _, heatDecayPerSecond, heatRecoverThreshold = getHeatParams(weaponConfig)
	local heatState = getOrCreateHeatState(entityId, nowServer)
	heatState.heat = 0
	heatState.lastUpdatedAt = nowServer
	heatState.lastShotAt = 0
	heatState.overheated = false
	heatState.recoverCueId = 0
	heatState.recoverToken += 1
	setHeatAttributes(healthState.instance, heatState, heatMax, heatDecayPerSecond, heatRecoverThreshold)

	local ammoCapacity = getAmmoCapacity(weaponConfig)
	if ammoCapacity > 0 then
		local ammoState = ammoStateByEntityId[entityId]
		if ammoState == nil then
			ammoState = {
				current = ammoCapacity,
				max = ammoCapacity,
			}
			ammoStateByEntityId[entityId] = ammoState
		else
			ammoState.max = ammoCapacity
			ammoState.current = ammoCapacity
		end
		setAmmoAttributes(healthState.instance, ammoState)
		print(string.format("[P3_AMMO_RESET] entity=%s ammo=%d", entityId, ammoState.current))
	else
		ammoStateByEntityId[entityId] = nil
		setAmmoAttributes(healthState.instance, nil)
	end
end

function WeaponServer.registerEntity(entityId: string)
	local healthState = HealthManager.getHealth(entityId)
	if healthState == nil or healthState.config.weaponId == nil then
		return
	end

	local baseWeaponConfig = CombatConfig.Weapons[healthState.config.weaponId]
	if baseWeaponConfig == nil then
		return
	end
	local weaponConfig = resolveWeaponConfig(healthState.instance, baseWeaponConfig)
	publishResolvedWeaponAttributes(healthState.instance, weaponConfig)

	fireNodeStateByEntityId[entityId] = nil
	drivenRigStateByEntityId[entityId] = nil
	getOrRefreshFireNodeState(entityId, healthState.instance)
	setFireNodeAttributes(healthState.instance, entityId)
	getOrRefreshDrivenRigState(entityId, healthState.instance)
	resetEntityInternal(entityId)
end

function WeaponServer.resetEntity(entityId: string)
	resetEntityInternal(entityId)
end

function WeaponServer.fireTestShot(entityId: string, direction: Vector3, applyAimSpreadForTest: boolean?): boolean
	if not RunService:IsStudio() then
		return false
	end
	if typeof(direction) ~= "Vector3" or direction.Magnitude < 1e-4 then
		return false
	end

	local healthState = HealthManager.getHealth(entityId)
	if healthState == nil or healthState.config.weaponId == nil then
		return false
	end

	local baseWeaponConfig = CombatConfig.Weapons[healthState.config.weaponId]
	if baseWeaponConfig == nil then
		return false
	end

	local weaponConfig = resolveWeaponConfig(healthState.instance, baseWeaponConfig)
	publishResolvedWeaponAttributes(healthState.instance, weaponConfig)
	if weaponConfig.fireRate <= 0 then
		return false
	end
	local lockState = TargetingServer.getLockState(entityId)
	if weaponConfig.requiresLock == true and lockState == nil then
		print(string.format("[P4_LOCK_REQUIRED] entity=%s", entityId))
		return false
	end

	local cooldown = 1 / weaponConfig.fireRate
	local shouldApplyAimSpread = applyAimSpreadForTest == true
	return fireSingleProjectile(
		healthState.instance,
		entityId,
		healthState,
		weaponConfig,
		healthState.instance,
		direction.Unit,
		cooldown,
		lockState,
		shouldApplyAimSpread
	)
end

function WeaponServer.init(remotes: Folder)
	remotesFolder = remotes
	fireWeaponRemote = remotesFolder:WaitForChild("FireWeapon") :: RemoteEvent
	updateTurretAimRemote = remotesFolder:WaitForChild("UpdateTurretAim") :: RemoteEvent

	if fireConnection == nil then
		fireConnection = getFireRemote().OnServerEvent:Connect(onFireWeapon)
	end
	if aimUpdateConnection == nil then
		aimUpdateConnection = getAimUpdateRemote().OnServerEvent:Connect(onUpdateTurretAim)
	end

	if playerRemovingConnection == nil then
		playerRemovingConnection = Players.PlayerRemoving:Connect(function(player)
			lastFireTimeByPlayer[player] = nil
			lastAimUpdateByPlayer[player] = nil
		end)
	end
end

return WeaponServer
