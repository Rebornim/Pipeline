--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local sharedRoot = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatConfig = require(sharedRoot:WaitForChild("CombatConfig"))
local CombatTypes = require(sharedRoot:WaitForChild("CombatTypes"))

local serverRoot = ServerScriptService:WaitForChild("CombatFramework")
local CollisionHandler = require(serverRoot:WaitForChild("Vehicles"):WaitForChild("CollisionHandler"))
local HealthManager = require(serverRoot:WaitForChild("Health"):WaitForChild("HealthManager"))
local HoverPhysics = require(serverRoot:WaitForChild("Vehicles"):WaitForChild("HoverPhysics"))

type VehicleConfig = CombatTypes.VehicleConfig
type VehicleRuntimeState = CombatTypes.VehicleRuntimeState
type TerrainIntent = "NormalDrive" | "BlockedClimb" | "CrestRelease"

type VehicleRuntimeStateInternal = VehicleRuntimeState & {
	lastSpeedUpdateTick: number,
	lastReplicatedSpeed: number,
	lastReplicatedHeading: number,
	wasStopped: boolean,
	attachmentYawOffset: number,
	attachmentRollAxisLocal: Vector3,
	crestReleaseUntil: number,
	crestLaunchUntil: number,
	currentBankAngle: number,
	leanEntryTimer: number,
	leanExitTimer: number,
	leanExitSign: number,
	prevInputLean: number,
	tiltAngularVelocity: Vector3,
	wasWaterContact: boolean,
	waterBounceTimer: number,
	waterBounceTriggered: boolean,
	airborneStartedAt: number,
	landingDampUntil: number,
	lastLandingShakeAt: number,
	driverEnterStabilizeUntil: number,
	driverEnterBaseY: number,
	replicationState: string,
	settlingStartTick: number,
	simulatedCFrame: CFrame,
	lastCFrameWriteTick: number,
	hoverPointLocalOffsets: { CFrame },
	inputBoost: boolean,
	boostActive: boolean,
	boostStartTick: number,
	boostCooldownUntil: number,
	nextMisfireTick: number,
	misfireAttributeClearTick: number,
}

local VehicleServer = {}

local vehiclesByEntityId: { [string]: VehicleRuntimeStateInternal } = {}
local vehiclesByVehicleId: { [string]: VehicleRuntimeStateInternal } = {}
local driverToVehicleId: { [Player]: string } = {}

local vehicleInputRemote: RemoteEvent? = nil
local vehicleExitRemote: RemoteEvent? = nil
local heartbeatConnection: RBXScriptConnection? = nil
local playerRemovingConnection: RBXScriptConnection? = nil
local vehicleInputConnection: RBXScriptConnection? = nil
local vehicleExitConnection: RBXScriptConnection? = nil
local LEAN_VISUAL_YAW_RATIO = 1.0

local function readConfigNumber(name: string, defaultValue: number): number
	local value = CombatConfig[name]
	if type(value) == "number" then
		return value
	end
	return defaultValue
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

-- Resolve a vehicle's config by reading its VehicleCategory (or VehicleConfigId fallback),
-- fetching the base config, and applying any percentage modifier attributes from the model.
local function resolveVehicleConfig(instance: Model): VehicleConfig?
	-- Determine which base config to use
	local category = instance:GetAttribute("VehicleCategory")
	if type(category) ~= "string" then
		-- Fallback to old VehicleConfigId attribute
		category = instance:GetAttribute("VehicleConfigId")
	end
	if type(category) ~= "string" then
		return nil
	end

	local baseConfig = getVehicleConfig(category)
	if baseConfig == nil then
		return nil
	end

	-- Clone the base config so modifiers don't mutate the shared table
	local resolved: { [string]: any } = {}
	for key, value in pairs(baseConfig :: any) do
		resolved[key] = value
	end

	-- Percentage modifiers: attribute name -> config key
	local percentModifiers: { { string } } = {
		-- Movement
		{ "VehicleMaxSpeedMod", "maxSpeed" },
		{ "VehicleAccelerationMod", "acceleration" },
		{ "VehicleDecelerationMod", "deceleration" },
		{ "VehicleBrakingMod", "brakingDeceleration" },
		{ "VehicleReverseSpeedMod", "reverseMaxSpeed" },
		{ "VehicleTurnSpeedLowMod", "turnSpeedLow" },
		{ "VehicleTurnSpeedHighMod", "turnSpeedHigh" },
		{ "VehicleLateralGripLowMod", "lateralGripLow" },
		{ "VehicleLateralGripHighMod", "lateralGripHigh" },
		-- Hover
		{ "VehicleHoverHeightMod", "hoverHeight" },
		{ "VehicleSpringStiffnessMod", "springStiffness" },
		{ "VehicleSpringDampingMod", "springDamping" },
		{ "VehicleTiltStiffnessMod", "tiltStiffness" },
		{ "VehicleTiltDampingMod", "tiltDamping" },
		{ "VehicleTerrainConformityMod", "terrainConformity" },
		{ "VehicleMaxClimbSlopeMod", "maxClimbSlope" },
		-- Collision
		{ "VehicleCollisionRadiusMod", "collisionRadius" },
		{ "VehicleCollisionBounceMod", "collisionBounce" },
		{ "VehicleCollisionDmgThresholdMod", "collisionDamageThreshold" },
		{ "VehicleCollisionDmgScaleMod", "collisionDamageScale" },
		-- Fall damage
		{ "VehicleFallDmgThresholdMod", "fallDamageThreshold" },
		{ "VehicleFallDmgScaleMod", "fallDamageScale" },
		-- Camera
		{ "VehicleCameraDistanceMod", "cameraDistance" },
		{ "VehicleCameraHeightMod", "cameraHeight" },
		{ "VehicleCameraLerpMod", "cameraLerpSpeed" },
		-- Boost
		{ "VehicleBoostSpeedMod", "boostSpeedMultiplier" },
		{ "VehicleBoostDurationMod", "boostDuration" },
		{ "VehicleBoostCooldownMod", "boostCooldown" },
		-- Lean (light only, but harmless on heavy since base is 0)
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

	-- Absolute boolean overrides
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

local function computeHeadingFromLook(lookVector: Vector3): number
	return math.atan2(-lookVector.X, -lookVector.Z)
end

local function shortestAngleDelta(a: number, b: number): number
	local delta = (a - b) % (math.pi * 2)
	if delta > math.pi then
		delta -= math.pi * 2
	end
	return delta
end

local function computeForwardDirection(heading: number): Vector3
	return Vector3.new(-math.sin(heading), 0, -math.cos(heading))
end

local function projectVectorOntoPlane(vector: Vector3, planeNormal: Vector3): Vector3
	return vector - planeNormal * vector:Dot(planeNormal)
end

local function computeHoverPointWorldPositions(state: VehicleRuntimeStateInternal): { Vector3 }
	local positions: { Vector3 } = {}
	for i, localOffset in ipairs(state.hoverPointLocalOffsets) do
		positions[i] = (state.simulatedCFrame * localOffset).Position
	end
	return positions
end

local function computeTargetSpeed(
	currentSpeed: number,
	inputThrottle: number,
	acceleration: number,
	deceleration: number,
	brakingDeceleration: number,
	maxForwardSpeed: number,
	maxReverseSpeed: number,
	dt: number
): number
	local targetSpeed = currentSpeed
	if inputThrottle > 0 then
		if currentSpeed < 0 then
			targetSpeed = math.min(currentSpeed + brakingDeceleration * dt, 0)
		elseif currentSpeed > maxForwardSpeed then
			-- Above max (post-boost) — gentle deceleration back to max
			targetSpeed = math.max(currentSpeed - deceleration * 0.5 * dt, maxForwardSpeed)
		else
			targetSpeed = math.min(currentSpeed + acceleration * dt, maxForwardSpeed)
		end
	elseif inputThrottle < 0 then
		if currentSpeed > 0 then
			targetSpeed = math.max(currentSpeed - brakingDeceleration * dt, 0)
		else
			targetSpeed = math.max(currentSpeed - acceleration * dt, -maxReverseSpeed)
		end
	else
		if currentSpeed > 0 then
			targetSpeed = math.max(currentSpeed - deceleration * dt, 0)
		elseif currentSpeed < 0 then
			targetSpeed = math.min(currentSpeed + deceleration * dt, 0)
		end
	end
	return targetSpeed
end

local function getVehicleByDriver(player: Player): VehicleRuntimeStateInternal?
	local vehicleId = driverToVehicleId[player]
	if vehicleId == nil then
		return nil
	end
	return vehiclesByVehicleId[vehicleId]
end

local function clearDriver(state: VehicleRuntimeStateInternal)
	local previousDriver = state.driver
	if previousDriver ~= nil and driverToVehicleId[previousDriver] == state.vehicleId then
		driverToVehicleId[previousDriver] = nil
	end
	state.driver = nil
	state.inputThrottle = 0
	state.inputSteerX = 0
	state.inputLean = 0
	state.inputBoost = false
	if state.boostActive then
		state.boostActive = false
		state.instance:SetAttribute("VehicleBoosting", false)
	end
end

local function appendPlayerCharacters(filter: { Instance })
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		if character ~= nil then
			table.insert(filter, character)
		end
	end
end

local function updateDriverFromSeat(state: VehicleRuntimeStateInternal)
	local occupant = state.driverSeat.Occupant
	if occupant ~= nil then
		local character = occupant.Parent
		local player = if character ~= nil then Players:GetPlayerFromCharacter(character) else nil
		if player ~= nil then
			local previousDriver = state.driver
			if previousDriver ~= nil and previousDriver ~= player and driverToVehicleId[previousDriver] == state.vehicleId then
				driverToVehicleId[previousDriver] = nil
			end

			state.driver = player
			driverToVehicleId[player] = state.vehicleId
			state.inputThrottle = 0
			state.inputSteerX = 0
			state.inputLean = 0
			state.wasStopped = false
			state.replicationState = "Active"
			state.settlingStartTick = 0
			state.lastSpeedUpdateTick = 0
			state.simulatedCFrame = state.primaryPart.CFrame
			state.driverEnterBaseY = state.simulatedCFrame.Position.Y
			state.lastCFrameWriteTick = 0
			state.driverEnterStabilizeUntil = tick() + 0.35
			state.tiltAngularVelocity = Vector3.zero
			if state.velocity.Y > 0 then
				state.velocity = Vector3.new(state.velocity.X, 0, state.velocity.Z)
			end
			return
		end
	end

	local previousDriver = state.driver
	clearDriver(state)
	if state.replicationState == "Active" then
		state.replicationState = "Settling"
		state.settlingStartTick = tick()
	end
end

local function measureHoverHeight(state: VehicleRuntimeStateInternal): number?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local filter: { Instance } = { state.instance }
	appendPlayerCharacters(filter)
	params.FilterDescendantsInstances = filter
	params.IgnoreWater = true

	local maxDistance = math.max(4, state.config.hoverHeight * 4)
	local result = Workspace:Raycast(state.simulatedCFrame.Position, Vector3.new(0, -maxDistance, 0), params)
	if result == nil then
		return nil
	end

	return result.Distance
end

local function measureAverageHoverPointDistance(
	vehicleModel: Model,
	hoverPointPositions: { Vector3 },
	maxDistance: number
): number?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local filter: { Instance } = { vehicleModel }
	appendPlayerCharacters(filter)
	params.FilterDescendantsInstances = filter
	params.IgnoreWater = true

	local probeLift = math.max(1, maxDistance * 0.1)
	local rayLength = maxDistance + probeLift
	local grounded = 0
	local totalDistance = 0
	for _, hoverPointPos in ipairs(hoverPointPositions) do
		local probeOrigin = hoverPointPos + Vector3.new(0, probeLift, 0)
		local result = Workspace:Raycast(probeOrigin, Vector3.new(0, -rayLength, 0), params)
		if result ~= nil then
			grounded += 1
			totalDistance += math.max(0, result.Distance - probeLift)
		end
	end

	if grounded <= 0 then
		return nil
	end
	return totalDistance / grounded
end

local function enforceTerrainFloor(state: VehicleRuntimeStateInternal, rayParams: RaycastParams)
	local probeLift = math.max(1.5, state.config.hoverHeight * 0.8)
	local rayLength = math.max(10, state.config.hoverHeight * 4) + probeLift
	local worstPenetration = 0

	for _, localOffset in ipairs(state.hoverPointLocalOffsets) do
		local hoverWorldPos = (state.simulatedCFrame * localOffset).Position
		local origin = hoverWorldPos + Vector3.new(0, probeLift, 0)
		local hit = Workspace:Raycast(origin, Vector3.new(0, -rayLength, 0), rayParams)
		if hit ~= nil then
			local penetration = math.max(0, hit.Position.Y - hoverWorldPos.Y)
			if penetration > worstPenetration then
				worstPenetration = penetration
			end
		end
	end

	if worstPenetration > 0.01 then
		local correction = worstPenetration + 0.05
		state.simulatedCFrame = state.simulatedCFrame + Vector3.new(0, correction, 0)
		if state.velocity.Y < 0 then
			state.velocity = Vector3.new(state.velocity.X, 0, state.velocity.Z)
		end
	end
end

local function applySpeedAttributeReplication(state: VehicleRuntimeStateInternal, horizontalSpeed: number)
	if state.replicationState == "Dormant" then
		return
	end

	local now = tick()
	local timeSinceLastUpdate = now - state.lastSpeedUpdateTick

	local isSettling = state.replicationState == "Settling"
	local maxRate = if isSettling
		then readConfigNumber("VehicleReplicationRateSettling", 5)
		else readConfigNumber("VehicleReplicationRateActive", 20)
	local minInterval = 1 / math.max(1, maxRate)

	if timeSinceLastUpdate < minInterval then
		return
	end

	local speedDeadband = if isSettling
		then readConfigNumber("VehicleSettlingSpeedDeadband", 3.0)
		else readConfigNumber("VehicleReplicationSpeedDeadband", 1.0)
	local headingDeadband = if isSettling
		then readConfigNumber("VehicleSettlingHeadingDeadband", 0.05)
		else readConfigNumber("VehicleReplicationHeadingDeadband", 0.02)
	local refreshInterval = if isSettling
		then readConfigNumber("VehicleReplicationRefreshSettling", 1.0)
		else readConfigNumber("VehicleReplicationRefreshActive", 0.5)

	local speedDelta = math.abs(horizontalSpeed - state.lastReplicatedSpeed)
	local headingDelta = math.abs(shortestAngleDelta(state.heading, state.lastReplicatedHeading))
	local refreshNeeded = timeSinceLastUpdate >= refreshInterval

	if speedDelta < speedDeadband and headingDelta < headingDeadband and not refreshNeeded then
		return
	end

	state.instance:SetAttribute("VehicleSpeed", horizontalSpeed)
	state.instance:SetAttribute("VehicleHeading", state.heading)
	state.lastReplicatedSpeed = horizontalSpeed
	state.lastReplicatedHeading = state.heading
	state.lastSpeedUpdateTick = now
end

local function applySlopeLimit(state: VehicleRuntimeStateInternal, averageNormal: Vector3)
	local slopeDot = math.clamp(averageNormal:Dot(Vector3.yAxis), -1, 1)
	local slopeAngle = math.deg(math.acos(slopeDot))
	if slopeAngle <= state.config.maxClimbSlope then
		return
	end

	local horizontalVelocity = Vector3.new(state.velocity.X, 0, state.velocity.Z)
	local forwardDirection = computeForwardDirection(state.heading)
	local forwardSpeed = horizontalVelocity:Dot(forwardDirection)
	if forwardSpeed <= 0 then
		return
	end

	local uphillDirection = Vector3.new(-averageNormal.X, 0, -averageNormal.Z)
	if uphillDirection.Magnitude <= 1e-4 then
		return
	end
	uphillDirection = uphillDirection.Unit

	if forwardDirection:Dot(uphillDirection) <= 0 then
		return
	end

	horizontalVelocity -= forwardDirection * forwardSpeed
	local downhillDirection = -uphillDirection
	local slideSpeed = math.min(forwardSpeed, state.config.deceleration)
	horizontalVelocity += downhillDirection * slideSpeed
	state.velocity = Vector3.new(horizontalVelocity.X, state.velocity.Y, horizontalVelocity.Z)
end

local function buildVehicleRayParams(vehicles: { VehicleRuntimeStateInternal }): RaycastParams
	local filter: { Instance } = table.create(#vehicles)
	for index, state in ipairs(vehicles) do
		filter[index] = state.instance
	end
	appendPlayerCharacters(filter)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = filter
	params.IgnoreWater = true
	return params
end

local function hasWaterAtPosition(position: Vector3): boolean
	local terrain = Workspace.Terrain
	local sampleHalf = Vector3.new(1.5, 1.5, 1.5)
	local region = Region3.new(position - sampleHalf, position + sampleHalf):ExpandToGrid(4)
	local materials, occupancy = terrain:ReadVoxels(region, 4)
	for x = 1, #materials do
		for y = 1, #materials[x] do
			for z = 1, #materials[x][y] do
				if materials[x][y][z] == Enum.Material.Water and occupancy[x][y][z] > 0.05 then
					return true
				end
			end
		end
	end
	return false
end

local function isWaterSupported(state: VehicleRuntimeStateInternal): boolean
	if hasWaterAtPosition(state.simulatedCFrame.Position) then
		return true
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local filter: { Instance } = { state.instance }
	appendPlayerCharacters(filter)
	params.FilterDescendantsInstances = filter
	params.IgnoreWater = false

	local hoverPointWorldPositions = computeHoverPointWorldPositions(state)
	local probeLift = math.max(1, state.config.hoverHeight * 0.5)
	local rayLength = state.config.hoverHeight * 3 + probeLift
	for _, hoverPointWorldPos in ipairs(hoverPointWorldPositions) do
		local origin = hoverPointWorldPos + Vector3.new(0, probeLift, 0)
		local hit = Workspace:Raycast(origin, Vector3.new(0, -rayLength, 0), params)
		if hit ~= nil and hit.Material == Enum.Material.Water then
			return true
		end
	end
	return false
end

local function applyTerrainSweep(
	state: VehicleRuntimeStateInternal,
	hoverPointWorldPositions: { Vector3 },
	currentPosition: Vector3,
	nextPosition: Vector3,
	rayParams: RaycastParams
): Vector3
	local travel = nextPosition - currentPosition
	local travelDistance = travel.Magnitude
	if travelDistance <= 1e-4 then
		return nextPosition
	end
	local travelDir = travel / travelDistance

	local hit = Workspace:Raycast(currentPosition, travel, rayParams)
	-- Also sweep from hover points to catch edge/side tunneling when the center ray misses.
	for _, hoverPointWorldPos in ipairs(hoverPointWorldPositions) do
		local hoverHit = Workspace:Raycast(hoverPointWorldPos, travel, rayParams)
		if hoverHit ~= nil then
			if hit == nil or hoverHit.Distance < hit.Distance then
				hit = hoverHit
			end
		end
	end
	if hit == nil then
		return nextPosition
	end
	-- Ignore only true near-end floor grazes; keep near-end wall contacts to prevent tunneling.
	if hit.Distance >= (travelDistance - 0.04) and hit.Normal.Y > 0.75 then
		return nextPosition
	end

	-- Wall impact damage: check BEFORE slope/crest bypasses so those early returns can't skip it
	-- Skip ground-level hits (lips, curbs, seams) — only damage from hits well below vehicle floor
	local hitHeightAboveGround = hit.Position.Y - (currentPosition.Y - state.config.hoverHeight * 1.5)
	if hit.Normal.Y < 0.35 and hitHeightAboveGround > 0 then
		local wallNormal = Vector3.new(hit.Normal.X, 0, hit.Normal.Z)
		if wallNormal.Magnitude > 1e-4 then
			wallNormal = wallNormal.Unit
			local intoWallSpeed = -state.velocity:Dot(wallNormal)
			-- Skip glancing/scraping hits: use the vehicle's heading (where it's pointed)
			-- to determine if this is a head-on impact. Heading only changes via steering,
			-- not from wall bounces or physics forces, so it reliably reflects approach angle.
			local headingDir = computeForwardDirection(state.heading)
			local headingIntoWall = math.abs(-headingDir:Dot(wallNormal))
			if headingIntoWall > 0.5 and intoWallSpeed > state.config.collisionDamageThreshold then
				local canApplyDamage = state.driver ~= nil or math.abs(state.inputThrottle) > 0.01
				if canApplyDamage then
					local damage = math.floor(
						(intoWallSpeed - state.config.collisionDamageThreshold) * state.config.collisionDamageScale + 0.5
					)
					if damage > 0 then
						HealthManager.applyDamage(state.entityId, damage, "impact", "", currentPosition, true)
					end
				end
			end
		end
	end

	local forwardDir = computeForwardDirection(state.heading)
	local dropProbeOrigin = nextPosition + forwardDir * math.max(1.5, state.config.collisionRadius * 0.65)
	local dropProbeLength = math.max(state.config.hoverHeight * 2.6, 10)
	local dropHit = Workspace:Raycast(dropProbeOrigin, Vector3.new(0, -dropProbeLength, 0), rayParams)
	local currentDropHit = Workspace:Raycast(currentPosition, Vector3.new(0, -dropProbeLength, 0), rayParams)
	local hasGroundAhead = dropHit ~= nil
	local aheadDrop = if dropHit ~= nil then (currentPosition.Y - dropHit.Position.Y) else (state.config.hoverHeight * 2)
	local currentDrop = if currentDropHit ~= nil
		then (currentPosition.Y - currentDropHit.Position.Y)
		else state.config.hoverHeight
	local aheadDropDelta = math.max(0, aheadDrop - currentDrop)
	local forwardSpeed = state.velocity:Dot(forwardDir)
	local hitSlopeAngle = math.deg(math.acos(math.clamp(hit.Normal.Y, -1, 1)))

	-- Unified downhill/crest bypass: only while not falling fast and with confirmed terrain continuation.
	local isFallingFast = state.velocity.Y < -(state.config.gravity * 0.12)
	local isDescendingGently = travelDir.Y > -0.5 and state.velocity.Y <= 6
	if
		not isFallingFast
		and isDescendingGently
		and hasGroundAhead
		and aheadDropDelta > (state.config.hoverHeight * 0.15)
		and forwardSpeed > 5
	then
		return nextPosition
	end

	local drivableSlope = math.min(72, state.config.maxClimbSlope + 4)
	local drivableMinUpDot = math.cos(math.rad(drivableSlope))
	if
		hit.Normal.Y >= drivableMinUpDot
		and hitSlopeAngle <= (state.config.maxClimbSlope + 2)
		and state.velocity.Y > -(state.config.gravity * 0.15)
	then
		return nextPosition
	end

	local intoSurface = state.velocity:Dot(hit.Normal)
	if intoSurface < 0 then
		state.velocity -= hit.Normal * intoSurface
	end

	-- Resolve along travel path first, then apply a tiny push-out, capped to avoid side-jump jitter.
	local stopDistance = math.max(0, hit.Distance - 0.06)
	local resolved = currentPosition + travelDir * stopDistance
	local pushOut = hit.Normal * math.min(0.12, state.config.collisionRadius * 0.06 + 0.03)
	resolved += pushOut

	local correction = resolved - nextPosition
	local maxCorrection = math.max(0.22, state.config.collisionRadius * 0.25)
	if correction.Magnitude > maxCorrection then
		resolved = nextPosition + correction.Unit * maxCorrection
	end

	return resolved
end

local function detectCrestDropAhead(state: VehicleRuntimeStateInternal, rayParams: RaycastParams): (boolean, number)
	local forwardDir = computeForwardDirection(state.heading)
	local rightDir = Vector3.new(forwardDir.Z, 0, -forwardDir.X)
	if rightDir.Magnitude <= 1e-4 then
		rightDir = Vector3.xAxis
	else
		rightDir = rightDir.Unit
	end

	local origin = state.simulatedCFrame.Position
	local probeForward = math.max(2, state.config.collisionRadius + state.config.hoverHeight * 0.45)
	local probeDown = math.max(10, state.config.hoverHeight * 3)
	-- Lift forward probes so uphill slopes don't cause false "no ground" results.
	-- Covers slopes up to ~56° at the default probe distance.
	local probeLift = probeForward * 1.5
	local lateralOffsets = { -0.6, 0, 0.6 }
	local dropSum = 0
	local hitCount = 0
	local currentDropHit = Workspace:Raycast(origin, Vector3.new(0, -probeDown, 0), rayParams)
	local currentDrop = if currentDropHit ~= nil then (origin.Y - currentDropHit.Position.Y) else state.config.hoverHeight

	for _, alpha in ipairs(lateralOffsets) do
		local probeOrigin = origin + forwardDir * probeForward + rightDir * (alpha * state.config.collisionRadius) + Vector3.new(0, probeLift, 0)
		local hit = Workspace:Raycast(probeOrigin, Vector3.new(0, -(probeDown + probeLift), 0), rayParams)
		if hit ~= nil then
			hitCount += 1
			local drop = origin.Y - hit.Position.Y
			dropSum += math.max(0, drop)
		end
	end

	if hitCount == 0 then
		return true, state.config.hoverHeight * 2
	end

	local averageDrop = dropSum / hitCount
	local dropDelta = math.max(0, averageDrop - currentDrop)
	return dropDelta > (state.config.hoverHeight * 0.4), dropDelta
end

local function cleanupVehicleState(state: VehicleRuntimeStateInternal)
	for _, connection in ipairs(state.connections) do
		connection:Disconnect()
	end
	table.clear(state.connections)

	if state.driver ~= nil then
		local player = state.driver
		clearDriver(state)
		local character = player.Character
		if character ~= nil then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if humanoid ~= nil then
				humanoid.Sit = false
			end
		end
	end

	state.instance:SetAttribute("VehicleSpeed", nil)
	state.instance:SetAttribute("VehicleHeading", nil)
	vehiclesByEntityId[state.entityId] = nil
	vehiclesByVehicleId[state.vehicleId] = nil
end

local function stepSingleVehicle(
	state: VehicleRuntimeStateInternal,
	dt: number,
	allVehicles: { VehicleRuntimeStateInternal },
	obstacleRayParams: RaycastParams
)
	if dt <= 0 then
		return
	end
	if vehiclesByEntityId[state.entityId] ~= state then
		return
	end
	if state.instance.Parent == nil or state.primaryPart.Parent == nil then
		VehicleServer.onEntityDestroyed(state.entityId)
		return
	end
	if not HealthManager.isAlive(state.entityId) then
		return
	end

	-- Boost logic (tap-to-activate: runs full duration regardless of shift held)
	local now = tick()
	local wantsBoost = state.config.boostEnabled and state.inputBoost and state.inputThrottle > 0 and state.inputLean == 0
	if state.boostActive then
		local elapsed = now - state.boostStartTick
		if elapsed >= state.config.boostDuration or state.inputThrottle < 0 then
			state.boostActive = false
			state.boostCooldownUntil = now + state.config.boostCooldown
			state.instance:SetAttribute("VehicleBoosting", false)
		end
	elseif wantsBoost and now >= state.boostCooldownUntil then
		state.boostActive = true
		state.boostStartTick = now
		state.instance:SetAttribute("VehicleBoosting", true)
	end

	local boostMultiplier = 1.0
	if state.boostActive then
		local elapsed = now - state.boostStartTick
		local duration = state.config.boostDuration
		local peak = state.config.boostSpeedMultiplier
		local endMult = 1 + (peak - 1) * 0.4
		local rampFraction = math.clamp(elapsed / 0.3, 0, 1)
		local decayFraction = math.clamp(elapsed / duration, 0, 1)
		local currentPeak = peak + (endMult - peak) * decayFraction
		boostMultiplier = 1 + (currentPeak - 1) * rampFraction
	end

	-- Misfire logic (damage-based engine stutters)
	if state.misfireAttributeClearTick > 0 and now >= state.misfireAttributeClearTick then
		state.instance:SetAttribute("VehicleMisfire", nil)
		state.misfireAttributeClearTick = 0
	end
	if state.driver ~= nil then
		local misfireHullHP = state.instance:GetAttribute("HullHP")
		local misfireMaxHP = state.instance:GetAttribute("MaxHullHP")
		if type(misfireHullHP) == "number" and type(misfireMaxHP) == "number" and misfireMaxHP > 0 then
			local misfireHpFrac = misfireHullHP / misfireMaxHP
			if misfireHpFrac > 0 and misfireHpFrac <= 0.6 and now >= state.nextMisfireTick then
				state.instance:SetAttribute("VehicleMisfire", true)
				state.misfireAttributeClearTick = now + 0.15
				-- Speed stutter: immediate 15% horizontal velocity reduction
				local hVel = Vector3.new(state.velocity.X, 0, state.velocity.Z)
				state.velocity = hVel * 0.85 + Vector3.new(0, state.velocity.Y, 0)
				-- Next interval: 10s at 60% HP → 3s near death
				local intervalBase = 3 + 7 * math.clamp(misfireHpFrac / 0.6, 0, 1)
				state.nextMisfireTick = now + intervalBase * (0.7 + math.random() * 0.6)
			end
		end
	end

	local previousAirborne = state.isAirborne
	local previousVerticalSpeed = state.lastVerticalSpeed

	local hoverPointWorldPositions = computeHoverPointWorldPositions(state)
	local verticalAccel, averageNormal, groundedCount = HoverPhysics.step(
		hoverPointWorldPositions,
		state.instance,
		state.velocity.Y,
		state.config.hoverHeight,
		state.config.springStiffness,
		state.config.springDamping,
		state.config.gravity,
		dt
	)
	local waterContact = isWaterSupported(state)

	local hasSurfaceContact = groundedCount >= 1
	local canUseGroundDrive = groundedCount >= 2
	local slopeDot = math.clamp(averageNormal:Dot(Vector3.yAxis), -1, 1)
	local slopeAngle = math.deg(math.acos(slopeDot))
	local terrainIntent: TerrainIntent = "NormalDrive"
	local crestDropAhead = false
	local crestDropAmount = 0
	local tooSteepClimbTransition = false
	local now = tick()
	local driverEntryStabilizing = now < state.driverEnterStabilizeUntil

	if driverEntryStabilizing then
		-- Prevent initial mount pop: do not allow hover springs to add upward impulse
		-- during the short entry stabilization window.
		verticalAccel = math.min(verticalAccel, 0)
	end

	if hasSurfaceContact then
		state.lastGroundedTick = tick()
	end

	local steerScale = if canUseGroundDrive then 1 else 0.55
	local horizontalSpeed = Vector3.new(state.velocity.X, 0, state.velocity.Z).Magnitude
	local speedFractionForTurn = math.clamp(horizontalSpeed / math.max(1, state.config.maxSpeed), 0, 1)
	local effectiveTurnSpeed =
		state.config.turnSpeedLow + (state.config.turnSpeedHigh - state.config.turnSpeedLow) * speedFractionForTurn
	local mouseSteerDelta = math.rad(state.inputSteerX * effectiveTurnSpeed * steerScale) * dt
	-- Lean transition detection
	local leanJustStarted = state.prevInputLean == 0 and state.inputLean ~= 0
	local leanJustEnded = state.prevInputLean ~= 0 and state.inputLean == 0
	if leanJustStarted then
		state.leanEntryTimer = state.config.leanEntryDuration
		state.leanExitTimer = 0
	end
	if leanJustEnded then
		state.leanExitTimer = state.config.leanExitDuration
		state.leanExitSign = -math.sign(state.prevInputLean)
		state.leanEntryTimer = 0
	end
	local entryFraction = math.clamp(state.leanEntryTimer / math.max(0.001, state.config.leanEntryDuration), 0, 1)
	local exitFraction = math.clamp(state.leanExitTimer / math.max(0.001, state.config.leanExitDuration), 0, 1)
	local leanSpeedFraction = math.clamp(horizontalSpeed / math.max(1, state.config.maxSpeed), 0, 1)
	local leanEntryMult = 1 + state.config.leanEntryYawBoost * entryFraction
	-- Counter-steer: separate opposite yaw impulse at lean start
	local counterSteerDelta = 0
	local counterSteerActive = false
	if state.leanEntryTimer > 0 then
		local elapsed = state.config.leanEntryDuration - state.leanEntryTimer
		local csDur = state.config.leanCounterSteerDuration
		if elapsed < csDur and csDur > 0 then
			counterSteerActive = true
			local t = elapsed / csDur
			local intensity = 1 - t
			counterSteerDelta = math.rad(-state.inputLean * state.config.leanCounterSteerRate * steerScale * intensity) * dt
		end
	end
	local leanSteerDelta =
		math.rad(state.inputLean * state.config.leanTurnRate * steerScale * leanSpeedFraction * leanEntryMult) * dt
	state.heading -= (mouseSteerDelta + leanSteerDelta + counterSteerDelta)

	local forwardDirection = computeForwardDirection(state.heading)
	local driveDirection = forwardDirection
	local uphillDirection = Vector3.new(-averageNormal.X, 0, -averageNormal.Z)
	local uphillUnit = if uphillDirection.Magnitude > 1e-4 then uphillDirection.Unit else Vector3.zero
	if canUseGroundDrive then
		driveDirection = projectVectorOntoPlane(forwardDirection, averageNormal)
		if driveDirection.Magnitude <= 1e-4 then
			driveDirection = forwardDirection
		else
			driveDirection = driveDirection.Unit
		end

		local maxDriveVertical = math.sin(math.rad(math.min(78, state.config.maxClimbSlope + 2)))
		if math.abs(driveDirection.Y) > maxDriveVertical then
			local horizontalDrive = Vector3.new(driveDirection.X, 0, driveDirection.Z)
			if horizontalDrive.Magnitude > 1e-4 then
				local clampedY = math.sign(driveDirection.Y) * maxDriveVertical
				local horizontalMagnitude = math.sqrt(math.max(0, 1 - clampedY * clampedY))
				driveDirection = horizontalDrive.Unit * horizontalMagnitude + Vector3.new(0, clampedY, 0)
			end
		end
	end

	local uphillAlignment = if uphillUnit.Magnitude > 1e-4 then driveDirection:Dot(uphillUnit) else 0
	local downhillAlignment = if uphillUnit.Magnitude > 1e-4 then driveDirection:Dot(-uphillUnit) else 0
	local isClimbing = state.inputThrottle > 0 and uphillAlignment > 0.14 and driveDirection.Y > 0.02
	local currentDriveSpeed = state.velocity:Dot(driveDirection)
	local crestReleaseActive = state.crestReleaseUntil > now

	local inLaunchWindow = state.crestLaunchUntil > now

	if canUseGroundDrive and not inLaunchWindow then
		tooSteepClimbTransition = isClimbing and slopeAngle > (state.config.maxClimbSlope + 1)
		local shouldProbeCrestDrop = state.inputThrottle > 0
			and (downhillAlignment > 0.06 or slopeAngle >= 6 or currentDriveSpeed > state.config.maxSpeed * 0.35 or crestReleaseActive)
		if shouldProbeCrestDrop then
			crestDropAhead, crestDropAmount = detectCrestDropAhead(state, obstacleRayParams)
		end

		local hasForwardCarry = currentDriveSpeed > math.max(8, state.config.maxSpeed * 0.18)
		local oversteepDownhill = state.inputThrottle > 0
			and downhillAlignment > 0.1
			and slopeAngle > (state.config.maxClimbSlope + 1)
			and state.velocity.Y <= 8
		local isGoingUphill = state.inputThrottle > 0 and driveDirection.Y > 0.15
		local crestCandidate = state.inputThrottle > 0
			and hasForwardCarry
			and crestDropAhead
			and not isGoingUphill
			and state.velocity.Y <= 10
			and (downhillAlignment > -0.06 or uphillAlignment < 0.32 or slopeAngle < 22)

		if oversteepDownhill then
			terrainIntent = "CrestRelease"
			state.crestReleaseUntil = now + 0.3
		elseif crestCandidate then
			terrainIntent = "CrestRelease"
			state.crestReleaseUntil = now + 0.3
		elseif tooSteepClimbTransition then
			terrainIntent = "BlockedClimb"
			state.crestReleaseUntil = 0
		elseif crestReleaseActive and state.inputThrottle >= 0 then
			terrainIntent = "CrestRelease"
		end
	elseif crestReleaseActive and state.inputThrottle >= 0 and not inLaunchWindow then
		terrainIntent = "CrestRelease"
	end

	if state.inputThrottle < 0 then
		state.crestReleaseUntil = 0
	elseif state.crestReleaseUntil <= now and terrainIntent ~= "CrestRelease" then
		state.crestReleaseUntil = 0
	end

	local horizontalVelocity = Vector3.new(state.velocity.X, 0, state.velocity.Z)
	local currentForwardFlat = horizontalVelocity:Dot(forwardDirection)

	if terrainIntent == "CrestRelease" then
		local carrySpeed = computeTargetSpeed(
			currentForwardFlat,
			state.inputThrottle,
			state.config.acceleration * 0.45,
			state.config.deceleration * 0.08,
			state.config.brakingDeceleration * 0.65,
			state.config.maxSpeed,
			state.config.reverseMaxSpeed,
			dt
		)
		if state.inputThrottle > 0 then
			local minCarry = math.max(8, state.config.maxSpeed * 0.2)
			carrySpeed = math.max(carrySpeed, math.max(currentForwardFlat, minCarry))
		end

		local lateralVelocity = horizontalVelocity - forwardDirection * currentForwardFlat
		lateralVelocity *= math.clamp(1 - (5 * dt), 0, 1)
		local releaseHorizontal = forwardDirection * carrySpeed + lateralVelocity

		-- Hover physics absorbs most vertical velocity during climbs, so velocity.Y
		-- is only ~5 even on steep slopes at high speed. Synthesize launch velocity
		-- from horizontal speed so crests produce proper arcs regardless of hover.
		local launchVelY = state.velocity.Y
		if horizontalSpeed > state.config.maxSpeed * 0.4 and state.velocity.Y < 12 then
			local synthLaunchY = horizontalSpeed * 0.15
			launchVelY = math.max(launchVelY, synthLaunchY)
		end
		if launchVelY > 10 and horizontalSpeed > state.config.maxSpeed * 0.4 then
			-- Launch: kill CrestRelease, set velocity, mark launch window.
			-- During launch window, NormalDrive skips vertical blend so gravity works cleanly.
			state.crestReleaseUntil = 0
			state.crestLaunchUntil = now + 0.3
			state.velocity = Vector3.new(releaseHorizontal.X, launchVelY, releaseHorizontal.Z)
			groundedCount = 0
			canUseGroundDrive = false
			terrainIntent = "NormalDrive"
		else
			local dropBoost = if crestDropAhead then math.clamp(crestDropAmount * 0.45, 0, 3.5) else 0
			local baseRelease = math.max(2.5, state.config.gravity * 0.02)
			local releaseVertical = math.min(
				state.velocity.Y - state.config.gravity * dt * 0.28,
				-(baseRelease + dropBoost)
			)
			state.velocity = Vector3.new(releaseHorizontal.X, releaseVertical, releaseHorizontal.Z)
		end
	elseif terrainIntent == "BlockedClimb" and canUseGroundDrive then
		local over = math.clamp((slopeAngle - state.config.maxClimbSlope) / 25, 0, 1)
		local rollbackSpeed = math.max(
			state.config.deceleration * (0.45 + over),
			state.config.reverseMaxSpeed * (0.3 + over * 0.5)
		)
		local targetSpeed = computeTargetSpeed(
			currentDriveSpeed,
			state.inputThrottle,
			state.config.acceleration,
			state.config.deceleration,
			state.config.brakingDeceleration,
			state.config.maxSpeed * boostMultiplier,
			state.config.reverseMaxSpeed,
			dt
		)
		targetSpeed = math.min(targetSpeed, 0)
		targetSpeed = math.max(targetSpeed - state.config.brakingDeceleration * dt * (1 + over * 1.1), -rollbackSpeed)

		local driveVelocity = driveDirection * targetSpeed
		if uphillUnit.Magnitude > 1e-4 then
			local downhillDirection = -uphillUnit
			local slideSpeed = math.max(state.config.deceleration * 0.5, math.abs(targetSpeed) * 0.7)
			local horizontalDrive = Vector3.new(driveVelocity.X, 0, driveVelocity.Z)
			local slideAlpha = math.clamp(0.55 + over * 0.35, 0.55, 0.9)
			horizontalDrive = horizontalDrive:Lerp(downhillDirection * slideSpeed, slideAlpha)
			driveVelocity = Vector3.new(horizontalDrive.X, driveVelocity.Y, horizontalDrive.Z)
		end
		state.velocity = Vector3.new(driveVelocity.X, math.min(state.velocity.Y, -4), driveVelocity.Z)
	else
		if canUseGroundDrive then
			local climbSpeedCap = state.config.maxSpeed * boostMultiplier
			-- Slope speed penalty: reduce target speed proportional to grade.
			-- Applied to the cap so computeTargetSpeed aims for the reduced value
			-- instead of multiplying desiredHorizontal per-frame (which compounds).
			if slopeAngle > 5 and state.inputThrottle > 0 and driveDirection.Y > 0.05 then
				local slopeFraction = math.clamp(slopeAngle / state.config.maxClimbSlope, 0, 1)
				climbSpeedCap = climbSpeedCap * (1 - slopeFraction * 0.30)
			end
			if isClimbing then
				local softStart = state.config.maxClimbSlope * 0.85
				if slopeAngle > softStart then
					local softSpan = math.max(1, state.config.maxClimbSlope - softStart)
					local t = math.clamp((slopeAngle - softStart) / softSpan, 0, 1)
					local capFactor = 1 - (t * 0.15)
					if slopeAngle > state.config.maxClimbSlope then
						local over = math.clamp((slopeAngle - state.config.maxClimbSlope) / 25, 0, 1)
						capFactor -= over * 0.08
					end
					climbSpeedCap = math.min(climbSpeedCap, math.max(state.config.maxSpeed * 0.65, state.config.maxSpeed * capFactor))
				end
			end
			if state.inputLean ~= 0 then
				climbSpeedCap = climbSpeedCap * (1 - state.config.leanSpeedPenalty)
			end

			local driveSpeedForThrottle = currentDriveSpeed
			if state.inputThrottle > 0 then
				if driveSpeedForThrottle < -2 then
					driveSpeedForThrottle = 0
				else
					driveSpeedForThrottle = math.max(driveSpeedForThrottle, horizontalSpeed)
				end
			elseif state.inputThrottle < 0 and driveSpeedForThrottle > 0 and horizontalSpeed < 5 then
				-- At low speed, snap to 0 so reverse starts immediately instead of
				-- fighting hover oscillations that keep currentDriveSpeed slightly positive.
				driveSpeedForThrottle = 0
			else
				-- No throttle: use horizontal-only projection to prevent vertical
				-- velocity on slopes from inflating drive speed (causes runaway).
				driveSpeedForThrottle = currentForwardFlat
			end

			-- Acceleration taper: reduce acceleration as speed approaches max
			local accelTaperFraction = if driveSpeedForThrottle > 0
				then math.clamp(driveSpeedForThrottle / math.max(1, climbSpeedCap), 0, 1)
				else 0
			local accelMultiplier = math.max(
				state.config.accelerationMinFactor,
				1 - accelTaperFraction * state.config.accelerationTaper
			)
			local effectiveAccel = state.config.acceleration * accelMultiplier

			local targetSpeed = computeTargetSpeed(
				driveSpeedForThrottle,
				state.inputThrottle,
				effectiveAccel,
				state.config.deceleration,
				state.config.brakingDeceleration,
				climbSpeedCap,
				state.config.reverseMaxSpeed,
				dt
			)
			local driveVelocity = driveDirection * targetSpeed
			local desiredVerticalSpeed = driveVelocity.Y
			if isClimbing and slopeAngle > state.config.maxClimbSlope then
				desiredVerticalSpeed = math.min(desiredVerticalSpeed, 6)
			end
			if isClimbing and slopeAngle <= (state.config.maxClimbSlope + 2) then
				local climbAssist = targetSpeed * (1 - math.clamp(averageNormal.Y, 0, 1)) * 0.35
				desiredVerticalSpeed += math.clamp(climbAssist, 0, 10)
			end
			-- During a crest launch, skip vertical blend entirely — let gravity handle it.
			-- Otherwise blend toward terrain-following desiredVerticalSpeed normally.
			local blendedVerticalSpeed: number
			if state.crestLaunchUntil > now then
				blendedVerticalSpeed = state.velocity.Y - state.config.gravity * dt
			else
				local verticalBlend = math.clamp(8 * dt, 0, 1)
				blendedVerticalSpeed = state.velocity.Y + (desiredVerticalSpeed - state.velocity.Y) * verticalBlend
			end
			local desiredHorizontal = forwardDirection * targetSpeed
			local currentHorizontal = Vector3.new(state.velocity.X, 0, state.velocity.Z)
			local gripRate =
				state.config.lateralGripLow + (state.config.lateralGripHigh - state.config.lateralGripLow) * speedFractionForTurn
			local gripAlpha = 1 - math.exp(-gripRate * dt)
			local desiredSpeed = desiredHorizontal.Magnitude
			local blendedHorizontal: Vector3
			if desiredSpeed <= 1e-4 then
				blendedHorizontal = currentHorizontal:Lerp(desiredHorizontal, gripAlpha)
			elseif currentHorizontal.Magnitude <= 1 then
				blendedHorizontal = desiredHorizontal
			else
				local blendedDirection = currentHorizontal.Unit:Lerp(desiredHorizontal.Unit, gripAlpha)
				if blendedDirection.Magnitude <= 1e-4 then
					blendedHorizontal = desiredHorizontal
				else
					blendedHorizontal = blendedDirection.Unit * desiredSpeed
				end
			end
			state.velocity = Vector3.new(blendedHorizontal.X, blendedVerticalSpeed, blendedHorizontal.Z)
		else
			-- Airborne deceleration: higher when coasting (throttle=0) so slope
			-- oscillation between grounded/airborne doesn't kill effective decel.
			local airDecelMult = if state.inputThrottle == 0 then 0.65 else 0.2
			local targetSpeed = computeTargetSpeed(
				currentForwardFlat,
				state.inputThrottle,
				state.config.acceleration * 0.35,
				state.config.deceleration * airDecelMult,
				state.config.brakingDeceleration * 0.4,
				state.config.maxSpeed * boostMultiplier,
				state.config.reverseMaxSpeed,
				dt
			)
			local lateralVelocity = horizontalVelocity - forwardDirection * currentForwardFlat
			lateralVelocity *= math.clamp(1 - (4 * dt), 0, 1)
			local airHorizontal = forwardDirection * targetSpeed + lateralVelocity
			state.velocity = Vector3.new(airHorizontal.X, state.velocity.Y, airHorizontal.Z)
		end
	end

	-- Entry speed boost (forward push on lean initiation)
	if state.leanEntryTimer > 0 and canUseGroundDrive and horizontalSpeed > 5 then
		local boost = state.config.leanEntrySpeedBoost * entryFraction * dt
		state.velocity += forwardDirection * boost
	end

	-- Set landing damp window on the frame we land from significant airtime.
	-- Must be before verticalAccel application so spring damping takes effect immediately.
	-- 1.0s window covers the micro-separation→return cycle on slopes (can take 0.6s+).
	if previousAirborne and hasSurfaceContact and math.abs(previousVerticalSpeed) > 15 then
		state.landingDampUntil = now + 1.0
	end
	-- During crest launch, apply only gravity (skip hover spring forces that cause float).
	-- Outside launch window, apply verticalAccel (spring + gravity from HoverPhysics).
	if inLaunchWindow then
		state.velocity += Vector3.new(0, -state.config.gravity * dt, 0)
	else
		local effectiveVAccel = verticalAccel
		-- During landing damp when briefly airborne (micro-separation), coast
		-- instead of free-falling under gravity. This prevents gravity from
		-- accelerating the vehicle away from the slope surface, letting the
		-- spring recapture and settle the oscillation naturally.
		if now < state.landingDampUntil and not hasSurfaceContact then
			effectiveVAccel = 0
		end
		state.velocity += Vector3.new(0, effectiveVAccel * dt, 0)
	end
	-- Landing damping: when grounded and moving upward, clamp to expected
	-- terrain-following velocity. Prevents bunny-hop on slopes while allowing climbs.
	-- Skip during launch window — the launch velocity IS the intended velocity.
	-- Uses landingDampUntil (0.5s window) so the tight clamp persists across the
	-- many frames it takes the spring to push velY from negative to positive.
	local inLandingDamp = now < state.landingDampUntil
	if groundedCount >= 2 and state.velocity.Y > 2 and not inLaunchWindow then
		local isOnClimb = slopeAngle > 4 and math.abs(state.inputThrottle) > 0.05
		local expectedUp = if isOnClimb
			then horizontalSpeed * math.sin(math.rad(math.min(slopeAngle, 50))) * 0.6
			else 0
		local maxBounce: number
		if inLandingDamp then
			-- Within landing damp window: tight clamp to kill spring overcorrection.
			maxBounce = math.max(2, expectedUp * 0.2)
		else
			maxBounce = math.max(3, expectedUp)
		end
		state.velocity = Vector3.new(state.velocity.X, math.min(state.velocity.Y, maxBounce), state.velocity.Z)
	end
	if terrainIntent == "CrestRelease" and state.velocity.Y <= 15
		and horizontalSpeed < state.config.maxSpeed * 0.4 then
		-- Terrain-following clamp for low-speed bumps only.
		-- At high speed, let gravity work naturally for launch arcs.
		local minFallSpeed = -math.max(6, state.config.gravity * 0.035)
		if state.velocity.Y > minFallSpeed then
			state.velocity = Vector3.new(state.velocity.X, minFallSpeed, state.velocity.Z)
		end
	end
	-- Clamp horizontal speed to prevent gravity runaway on downhills.
	do
		local hVel = Vector3.new(state.velocity.X, 0, state.velocity.Z)
		local hSpd = hVel.Magnitude
		local maxH = state.config.maxSpeed
		if state.boostActive then
			maxH *= state.config.boostSpeedMultiplier
		end
		if hSpd > maxH and hSpd > 1e-4 then
			local clamped = hVel * (maxH / hSpd)
			state.velocity = Vector3.new(clamped.X, state.velocity.Y, clamped.Z)
		end
	end
	-- Recompute horizontal speed post-clamp for accurate replication
	horizontalSpeed = Vector3.new(state.velocity.X, 0, state.velocity.Z).Magnitude
	state.velocity = Vector3.new(state.velocity.X, math.clamp(state.velocity.Y, -220, 120), state.velocity.Z)
	if now < state.driverEnterStabilizeUntil then
		local maxY = state.driverEnterBaseY + math.max(0.35, state.config.hoverHeight * 0.1)
		local currentY = state.simulatedCFrame.Position.Y
		local clampedY = math.min(state.velocity.Y, 0)
		if currentY > maxY then
			clampedY = math.min(clampedY, -10)
		end
		state.velocity = Vector3.new(state.velocity.X, clampedY, state.velocity.Z)
	end

	-- Water entry behavior: brief sink, then strong rebound, then resume normal hover.
	if waterContact and not state.wasWaterContact and previousVerticalSpeed < -12 then
		state.waterBounceTimer = 0.05
		state.waterBounceTriggered = false
	end
	if waterContact then
		if state.waterBounceTimer > 0 then
			state.waterBounceTimer = math.max(0, state.waterBounceTimer - dt)
			state.velocity = Vector3.new(state.velocity.X, math.min(state.velocity.Y, -12), state.velocity.Z)
		elseif not state.waterBounceTriggered then
			state.waterBounceTriggered = true
			state.velocity = Vector3.new(state.velocity.X, math.max(state.velocity.Y, 72), state.velocity.Z)
		else
			state.velocity = Vector3.new(state.velocity.X, math.max(state.velocity.Y, -36), state.velocity.Z)
		end
	else
		state.waterBounceTimer = 0
		state.waterBounceTriggered = false
	end
	state.wasWaterContact = waterContact

	if previousAirborne and hasSurfaceContact then
		local impactSpeed = math.abs(previousVerticalSpeed)
		if impactSpeed > state.config.fallDamageThreshold then
			local canApplyDamage = state.driver ~= nil or math.abs(state.inputThrottle) > 0.01
			if canApplyDamage then
				local damage = math.floor((impactSpeed - state.config.fallDamageThreshold) * state.config.fallDamageScale + 0.5)
				if damage > 0 then
					HealthManager.applyDamage(state.entityId, damage, "impact", "", state.simulatedCFrame.Position, true)
				end
			end
		end
		-- Signal landing impact to client for camera shake
		local landingImpactSpeed = math.abs(previousVerticalSpeed)
		local airborneDuration = now - state.airborneStartedAt
		local shakeCooldownElapsed = (now - state.lastLandingShakeAt) > 0.3
		if
			landingImpactSpeed > state.config.landingShakeThreshold
			and airborneDuration > 0.12
			and shakeCooldownElapsed
		then
			state.lastLandingShakeAt = now
			state.instance:SetAttribute("VehicleLandingImpact", landingImpactSpeed)
		end
	end

	CollisionHandler.checkObstacles(state, dt, obstacleRayParams)
	if vehiclesByEntityId[state.entityId] ~= state then
		return
	end

	CollisionHandler.checkVehicleCollisions(state, allVehicles)
	if vehiclesByEntityId[state.entityId] ~= state then
		return
	end

	CollisionHandler.checkOverlapPushback(state, obstacleRayParams)

	if canUseGroundDrive and terrainIntent == "NormalDrive" and not inLaunchWindow then
		local isClimbingSurface = slopeAngle > 4 and math.abs(state.inputThrottle) > 0.05
		if not isClimbingSurface then
			-- Smooth exponential damping: no dead zone so springs can track terrain
			-- variations. Stronger upward damp prevents bounce; softer downward
			-- damp allows smooth settling.
			if state.velocity.Y > 0 then
				state.velocity = Vector3.new(state.velocity.X, state.velocity.Y * math.exp(-12 * dt), state.velocity.Z)
			else
				state.velocity = Vector3.new(state.velocity.X, state.velocity.Y * math.exp(-6 * dt), state.velocity.Z)
			end
		else
			-- Climbing surface: clamp and decay positive velY to prevent bounce
			local clampedY = math.clamp(state.velocity.Y, -65, 45)
			if clampedY > 0 then
				-- Decay upward velocity — stronger after a landing to kill bounce
				local decayRate = if previousAirborne then 0.4 else 0.82
				clampedY *= decayRate
			end
			state.velocity = Vector3.new(state.velocity.X, clampedY, state.velocity.Z)
		end
		if groundedCount >= 3 and state.velocity.Y > -20 then
			applySlopeLimit(state, averageNormal)
		end
	end

	local currentPosition = state.simulatedCFrame.Position
	local nextPosition = currentPosition + state.velocity * dt

	-- Prevent terrain sink on all grounded intents except crest release.
	if hasSurfaceContact and groundedCount >= 1 and terrainIntent ~= "CrestRelease" and not driverEntryStabilizing then
		local avgHoverDistance =
			measureAverageHoverPointDistance(state.instance, hoverPointWorldPositions, math.max(12, state.config.hoverHeight * 4))
		if avgHoverDistance ~= nil then
			local clearanceFloor = state.config.hoverHeight * 0.45
			if avgHoverDistance < clearanceFloor then
				local correction = math.min(state.config.hoverHeight * 0.16, clearanceFloor - avgHoverDistance)
				local correctionNormal = if averageNormal.Y > 0.25 then averageNormal else Vector3.yAxis
				nextPosition += correctionNormal * correction
				if state.velocity.Y < 0 then
					state.velocity = Vector3.new(state.velocity.X, 0, state.velocity.Z)
				end
			end
		end
	end

	nextPosition = applyTerrainSweep(state, hoverPointWorldPositions, currentPosition, nextPosition, obstacleRayParams)

	-- Post-sweep landing damp: on landing frames during the damp window, set
	-- velY to the slope-following rate so the vehicle tracks the surface.
	-- Without this, terrain sweep zeros velY on contact, but on a 20° slope at
	-- 120 hSpd the surface drops at ~41 studs/s → vehicle separates immediately.
	-- Only modifies velY — horizontal direction untouched. Skips launch window.
	if now < state.landingDampUntil and not inLaunchWindow then
		if previousAirborne and hasSurfaceContact then
			-- Landing frame: match velY to slope-following rate
			local hVel = Vector3.new(state.velocity.X, 0, state.velocity.Z)
			local hSpd = hVel.Magnitude
			if hSpd > 1 then
				local hDir = hVel / hSpd
				local slopeDir = projectVectorOntoPlane(hDir, averageNormal)
				if slopeDir.Magnitude > 0.01 then
					slopeDir = slopeDir.Unit
					local slopeVelY = slopeDir.Y * hSpd
					state.velocity = Vector3.new(state.velocity.X, slopeVelY, state.velocity.Z)
				end
			end
		elseif hasSurfaceContact and state.velocity.Y > 3 then
			-- Non-landing grounded frames: cap positive velY
			state.velocity = Vector3.new(state.velocity.X, 3, state.velocity.Z)
		end
	end

	local rollAxis = state.attachmentRollAxisLocal
	if rollAxis.Magnitude <= 1e-4 then
		rollAxis = Vector3.zAxis
	else
		rollAxis = rollAxis.Unit
	end

	-- Remove previously applied visual bank from the tilt-smoothing input so bank
	-- does not compound into terrain-follow orientation at high speed.
	local unbankedCurrentCFrame = state.simulatedCFrame
	if math.abs(state.currentBankAngle) > 0.001 then
		unbankedCurrentCFrame = unbankedCurrentCFrame * CFrame.fromAxisAngle(rollAxis, -state.currentBankAngle)
	end
	local currentUp = unbankedCurrentCFrame.UpVector
	-- Reduce terrain roll (sideways tilt) based on conformity; pitch (uphill/downhill) always preserved
	local conformity = state.config.terrainConformity
	local tiltForward = computeForwardDirection(state.heading - state.attachmentYawOffset)
	local tiltRight = tiltForward:Cross(Vector3.yAxis)
	if tiltRight.Magnitude <= 1e-4 then
		tiltRight = Vector3.xAxis
	else
		tiltRight = tiltRight.Unit
	end
	local rollAmount = averageNormal:Dot(tiltRight)
	local tiltTarget = (averageNormal - tiltRight * rollAmount * (1 - conformity)).Unit
	-- Spring-damper tilt: rotational inertia with overshoot-and-settle
	local tiltError = tiltTarget - currentUp
	local springForce = tiltError * state.config.tiltStiffness
	local dampingForce = -state.tiltAngularVelocity * state.config.tiltDamping
	state.tiltAngularVelocity += (springForce + dampingForce) * dt
	-- Clamp angular velocity to prevent explosions on teleport or extreme cases
	local maxAngularSpeed = 15
	if state.tiltAngularVelocity.Magnitude > maxAngularSpeed then
		state.tiltAngularVelocity = state.tiltAngularVelocity.Unit * maxAngularSpeed
	end
	local smoothedUp = currentUp + state.tiltAngularVelocity * dt
	if smoothedUp.Magnitude <= 1e-4 then
		smoothedUp = Vector3.yAxis
	else
		smoothedUp = smoothedUp.Unit
	end

	local bodyHeading = state.heading - state.attachmentYawOffset
	local bodyForward = computeForwardDirection(bodyHeading)
	local alignedForward = projectVectorOntoPlane(bodyForward, smoothedUp)
	if alignedForward.Magnitude <= 1e-4 then
		alignedForward = projectVectorOntoPlane(state.simulatedCFrame.LookVector, smoothedUp)
	end
	if alignedForward.Magnitude <= 1e-4 then
		alignedForward = bodyForward
	end
	alignedForward = alignedForward.Unit

	local nextCFrame = CFrame.lookAt(nextPosition, nextPosition + alignedForward, smoothedUp)
	local speedFraction = math.clamp(horizontalSpeed / math.max(1, state.config.maxSpeed), 0, 1)
	local bankSpeedFraction = if state.inputLean ~= 0 then math.max(0.15, speedFraction) else speedFraction
	local targetBankAngle = state.inputLean * math.rad(state.config.leanBankAngle) * bankSpeedFraction
	-- Counter-steer visual: briefly tip opposite before committing to lean bank
	if counterSteerActive then
		local elapsed = state.config.leanEntryDuration - state.leanEntryTimer
		local csDur = state.config.leanCounterSteerDuration
		local t = elapsed / math.max(0.001, csDur)
		targetBankAngle += -state.inputLean * math.rad(state.config.leanCounterSteerBankDeg) * (1 - t) * bankSpeedFraction
	end
	-- Exit counter-bank: overshoot past level in the opposite direction
	if exitFraction > 0 then
		targetBankAngle += state.leanExitSign * math.rad(state.config.leanExitCounterBankDeg) * exitFraction
	end
	local bankLerpRate = if counterSteerActive then 30 else 12
	local bankLerp = math.clamp(bankLerpRate * dt, 0, 1)
	state.currentBankAngle += (targetBankAngle - state.currentBankAngle) * bankLerp
	local visualYawAngle = -state.currentBankAngle * LEAN_VISUAL_YAW_RATIO
	nextCFrame = nextCFrame * CFrame.Angles(0, visualYawAngle, 0)
	nextCFrame = nextCFrame * CFrame.fromAxisAngle(rollAxis, state.currentBankAngle)
	state.simulatedCFrame = nextCFrame
	enforceTerrainFloor(state, obstacleRayParams)
	hoverPointWorldPositions = computeHoverPointWorldPositions(state)

	local cframeWriteRate = if state.replicationState == "Settling"
		then readConfigNumber("VehicleCFrameWriteRateSettling", 5)
		else readConfigNumber("VehicleCFrameWriteRateActive", 20)
	local cframeWriteInterval = 1 / math.max(1, cframeWriteRate)
	local cframePositionDeadband = readConfigNumber("VehicleCFramePositionDeadband", 0.01)
	local currentWriteDelta = (state.primaryPart.Position - state.simulatedCFrame.Position).Magnitude
	local rotationDelta = 1 - state.primaryPart.CFrame.LookVector:Dot(state.simulatedCFrame.LookVector)
	if (now - state.lastCFrameWriteTick) >= cframeWriteInterval and (currentWriteDelta >= cframePositionDeadband or rotationDelta > 0.001 or state.lastCFrameWriteTick == 0) then
		state.primaryPart.CFrame = state.simulatedCFrame
		state.lastCFrameWriteTick = now
	end

	state.isAirborne = not hasSurfaceContact
	if not previousAirborne and state.isAirborne then
		state.airborneStartedAt = now
	end
	state.lastVerticalSpeed = state.velocity.Y
	-- Lean polish timer updates
	state.leanEntryTimer = math.max(0, state.leanEntryTimer - dt)
	state.leanExitTimer = math.max(0, state.leanExitTimer - dt)
	state.prevInputLean = state.inputLean

	local speedThreshold = readConfigNumber("VehicleStopThreshold", 0.5)
	local hasInput = math.abs(state.inputThrottle) > 0 or math.abs(state.inputSteerX) > 0
	if state.driver == nil and not hasInput and state.velocity.Magnitude < speedThreshold then
		-- Preserve vertical settling so unoccupied vehicles can return to hover height.
		state.velocity = Vector3.new(0, state.velocity.Y, 0)
		if not state.wasStopped then
			state.wasStopped = true
		end
	else
		state.wasStopped = false
	end

	applySpeedAttributeReplication(state, horizontalSpeed)

end

local function stepVehicles(dt: number)
	if dt <= 0 then
		return
	end

	local clampedDt = math.min(dt, 1 / 30)
	local activeVehicles: { VehicleRuntimeStateInternal } = {}
	local dormancyDelay = readConfigNumber("VehicleDormancyDelay", 2.0)
	local now = tick()
	for entityId, state in pairs(vehiclesByEntityId) do
		if state.instance.Parent == nil or state.primaryPart.Parent == nil then
			VehicleServer.onEntityDestroyed(entityId)
		elseif not HealthManager.isAlive(entityId) then
			-- dead vehicle, skip
		elseif state.replicationState == "Dormant" then
			-- fully dormant: skip physics entirely
		else
			if state.replicationState == "Settling" then
				local speedThreshold = readConfigNumber("VehicleStopThreshold", 0.5)
				if state.velocity.Magnitude < speedThreshold and (now - state.settlingStartTick) >= dormancyDelay then
					state.replicationState = "Dormant"
					state.instance:SetAttribute("VehicleSpeed", 0)
					state.instance:SetAttribute("VehicleHeading", state.heading)
					state.lastReplicatedSpeed = 0
					state.lastReplicatedHeading = state.heading
					state.lastSpeedUpdateTick = now
					state.velocity = Vector3.zero
				else
					table.insert(activeVehicles, state)
				end
			else
				table.insert(activeVehicles, state)
			end
		end
	end

	if #activeVehicles == 0 then
		return
	end

	local obstacleRayParams = buildVehicleRayParams(activeVehicles)

	-- START READ HERE (P5 VEHICLE STEP)
	for _, state in ipairs(activeVehicles) do
		stepSingleVehicle(state, clampedDt, activeVehicles, obstacleRayParams)
	end
	-- END READ HERE (P5 VEHICLE STEP)
end

function VehicleServer.getVehicleByEntityId(entityId: string): VehicleRuntimeState?
	return vehiclesByEntityId[entityId]
end

function VehicleServer.getVehicleByDriver(player: Player): VehicleRuntimeState?
	return getVehicleByDriver(player)
end

function VehicleServer.onEntityDestroyed(entityId: string): ()
	local state = vehiclesByEntityId[entityId]
	if state == nil then
		return
	end

	cleanupVehicleState(state)
end

function VehicleServer.registerVehicle(
	entityId: string,
	instance: Model,
	vehicleConfigId: string,
	driverSeat: Seat,
	hoverPoints: { BasePart }
): ()
	if vehiclesByEntityId[entityId] ~= nil then
		VehicleServer.onEntityDestroyed(entityId)
	end

	-- Resolve config from base + model attribute modifiers
	local vehicleConfig = resolveVehicleConfig(instance)
	if vehicleConfig == nil then
		-- Fallback to raw config lookup (backward compat)
		vehicleConfig = getVehicleConfig(vehicleConfigId)
	end
	if vehicleConfig == nil then
		return
	end

	local primaryPart = instance.PrimaryPart
	if primaryPart == nil then
		return
	end

	local sortedHoverPoints: { BasePart } = table.clone(hoverPoints)
	table.sort(sortedHoverPoints, function(a: BasePart, b: BasePart)
		return a:GetFullName() < b:GetFullName()
	end)
	if #sortedHoverPoints > 4 then
		sortedHoverPoints = { sortedHoverPoints[1], sortedHoverPoints[2], sortedHoverPoints[3], sortedHoverPoints[4] }
	end

	-- Prevent startup launch when authored hover points start too close to the ground.
	local registrationHoverPositions: { Vector3 } = {}
	for i, hoverPoint in ipairs(sortedHoverPoints) do
		registrationHoverPositions[i] = hoverPoint.Position
	end
	local averageHoverDistance =
		measureAverageHoverPointDistance(instance, registrationHoverPositions, math.max(20, vehicleConfig.hoverHeight * 6))
	if averageHoverDistance ~= nil and averageHoverDistance < (vehicleConfig.hoverHeight - 0.25) then
		local liftDelta =
			math.min(vehicleConfig.hoverHeight - averageHoverDistance, math.max(0.6, vehicleConfig.hoverHeight * 0.2))
		instance:SetPrimaryPartCFrame(primaryPart.CFrame + Vector3.new(0, liftDelta, 0))
	end

	-- Read forward direction from model attributes.
	-- ForwardYawOffset (number, degrees from local -Z) takes priority over ForwardAxis string.
	local forwardAxisLocal: Vector3
	local forwardYawOffset = instance:GetAttribute("ForwardYawOffset")
	if type(forwardYawOffset) == "number" then
		local rad = math.rad(forwardYawOffset)
		forwardAxisLocal = Vector3.new(math.sin(rad), 0, -math.cos(rad))
	else
		local forwardAxisRaw = instance:GetAttribute("ForwardAxis")
		if forwardAxisRaw == "X" then
			forwardAxisLocal = Vector3.new(1, 0, 0)
		elseif forwardAxisRaw == "-X" then
			forwardAxisLocal = Vector3.new(-1, 0, 0)
		elseif forwardAxisRaw == "Z" then
			forwardAxisLocal = Vector3.new(0, 0, 1)
		elseif forwardAxisRaw == "-Z" then
			forwardAxisLocal = Vector3.new(0, 0, -1)
		else
			forwardAxisLocal = Vector3.new(0, 0, -1)
			warn("[VEHICLE] No/invalid ForwardAxis or ForwardYawOffset on " .. instance.Name)
		end
	end

	local worldForward: Vector3 = primaryPart.CFrame:VectorToWorldSpace(forwardAxisLocal)
	local attachmentYawOffset = 0
	local attachmentRollAxisLocal = Vector3.new(0, 0, -1)

	local partForwardHorizontal = Vector3.new(primaryPart.CFrame.LookVector.X, 0, primaryPart.CFrame.LookVector.Z)
	local forwardHorizontal = Vector3.new(worldForward.X, 0, worldForward.Z)
	if partForwardHorizontal.Magnitude > 1e-4 and forwardHorizontal.Magnitude > 1e-4 then
		local partHeading = computeHeadingFromLook(partForwardHorizontal.Unit)
		local forwardHeading = computeHeadingFromLook(forwardHorizontal.Unit)
		attachmentYawOffset = shortestAngleDelta(forwardHeading, partHeading)
	end
	local horizontalForward = Vector3.new(worldForward.X, 0, worldForward.Z)
	if horizontalForward.Magnitude > 1e-4 then
		worldForward = horizontalForward.Unit
	else
		worldForward = instance:GetPivot().LookVector
	end
	local heading = computeHeadingFromLook(worldForward)
	local state: VehicleRuntimeStateInternal = {
		vehicleId = entityId,
		entityId = entityId,
		instance = instance,
		primaryPart = primaryPart,
		driverSeat = driverSeat,
		hoverPoints = sortedHoverPoints,
		config = vehicleConfig,
		driver = nil,
		velocity = Vector3.zero,
		heading = heading,
		isAirborne = false,
		lastGroundedTick = tick(),
		lastVerticalSpeed = 0,
		inputThrottle = 0,
		inputSteerX = 0,
		inputLean = 0,
		connections = {},
		lastSpeedUpdateTick = 0,
		lastReplicatedSpeed = 0,
		lastReplicatedHeading = heading,
		wasStopped = true,
		attachmentYawOffset = attachmentYawOffset,
		attachmentRollAxisLocal = attachmentRollAxisLocal,
		crestReleaseUntil = 0,
		crestLaunchUntil = 0,
		currentBankAngle = 0,
		leanEntryTimer = 0,
		leanExitTimer = 0,
		leanExitSign = 0,
		prevInputLean = 0,
		tiltAngularVelocity = Vector3.zero,
		wasWaterContact = false,
		waterBounceTimer = 0,
		waterBounceTriggered = false,
		airborneStartedAt = tick(),
		landingDampUntil = 0,
		lastLandingShakeAt = 0,
		driverEnterStabilizeUntil = 0,
		driverEnterBaseY = primaryPart.Position.Y,
		replicationState = "Active",
		settlingStartTick = 0,
		simulatedCFrame = primaryPart.CFrame,
		lastCFrameWriteTick = 0,
		hoverPointLocalOffsets = {},
		inputBoost = false,
		boostActive = false,
		boostStartTick = 0,
		boostCooldownUntil = 0,
		nextMisfireTick = tick() + 5,
		misfireAttributeClearTick = 0,
	}

	local weldedPartCount = 0
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") and descendant ~= primaryPart then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = primaryPart
			weld.Part1 = descendant
			weld.Parent = descendant
			descendant.Anchored = false
			descendant.Massless = true
			weldedPartCount += 1
		end
	end
	local localOffsets: { CFrame } = {}
	for i, hp in ipairs(sortedHoverPoints) do
		localOffsets[i] = primaryPart.CFrame:Inverse() * hp.CFrame
	end
	state.hoverPointLocalOffsets = localOffsets

	table.insert(
		state.connections,
		driverSeat:GetPropertyChangedSignal("Occupant"):Connect(function()
			updateDriverFromSeat(state)
		end)
	)
	updateDriverFromSeat(state)

	vehiclesByEntityId[entityId] = state
	vehiclesByVehicleId[state.vehicleId] = state
	instance:SetAttribute("VehicleSpeed", 0)
	instance:SetAttribute("VehicleHeading", heading)
end

function VehicleServer.init(remotesFolder: Folder): ()
	vehicleInputRemote = remotesFolder:WaitForChild("VehicleInput") :: RemoteEvent
	vehicleExitRemote = remotesFolder:WaitForChild("VehicleExitRequest") :: RemoteEvent

	if vehicleInputConnection == nil then
		vehicleInputConnection = vehicleInputRemote.OnServerEvent:Connect(function(player: Player, payload: any)
			if type(payload) ~= "table" then
				return
			end

			local throttle = payload.throttle
			local steerX = payload.steerX
			local lean = payload.lean
			if type(throttle) ~= "number" or type(steerX) ~= "number" then
				return
			end
			if type(lean) ~= "number" then
				lean = 0
			end

			local state = getVehicleByDriver(player)
			if state == nil then
				return
			end

			state.inputThrottle = math.clamp(math.round(throttle), -1, 1)
			state.inputSteerX = math.clamp(steerX, -1, 1)
			state.inputBoost = payload.boost == true
			-- Block lean if disabled or during active boost
			if not state.config.leanEnabled or state.boostActive then
				state.inputLean = 0
			else
				state.inputLean = math.clamp(math.round(lean), -1, 1)
			end
		end)
	end

	if vehicleExitConnection == nil then
		vehicleExitConnection = vehicleExitRemote.OnServerEvent:Connect(function(player: Player)
			local state = getVehicleByDriver(player)
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
			local state = getVehicleByDriver(player)
			if state == nil then
				return
			end

			clearDriver(state)
		end)
	end

	if heartbeatConnection == nil then
		heartbeatConnection = RunService.Heartbeat:Connect(stepVehicles)
	end
end

return VehicleServer
