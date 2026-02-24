--!strict

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
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
local WalkerIKServer = require(serverRoot:WaitForChild("Vehicles"):WaitForChild("WalkerIKServer"))

type VehicleConfig = CombatTypes.VehicleConfig
type WalkerRuntimeState = CombatTypes.WalkerRuntimeState

local WalkerServer = {}

local walkersByEntityId: { [string]: WalkerRuntimeState } = {}
local walkersByWalkerId: { [string]: WalkerRuntimeState } = {}
local driverToWalkerId: { [Player]: string } = {}

type WalkerSpawnData = {
	spawnCFrame: CFrame,
	driverSeat: Seat,
}
local spawnDataByEntityId: { [string]: WalkerSpawnData } = {}
local legsFolderByEntityId: { [string]: Instance } = {}

local VOID_DESTROY_HEIGHT = -500

local vehicleInputRemote: RemoteEvent? = nil
local vehicleExitRemote: RemoteEvent? = nil
local heartbeatConnection: RBXScriptConnection? = nil
local playerRemovingConnection: RBXScriptConnection? = nil
local inputConnection: RBXScriptConnection? = nil
local exitConnection: RBXScriptConnection? = nil

local walkerErrorCount = 0

local function readConfigNumber(name: string, defaultValue: number): number
	local value = (CombatConfig :: any)[name]
	if type(value) == "number" then
		return value
	end
	return defaultValue
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

local function appendPlayerCharacters(filter: { Instance })
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		if character ~= nil then
			table.insert(filter, character)
		end
	end
end

local function buildWalkerRayParams(state: WalkerRuntimeState): RaycastParams
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.IgnoreWater = true
	local filterList: { Instance } = { state.instance }
	local legsFolder = legsFolderByEntityId[state.entityId]
	if legsFolder then
		table.insert(filterList, legsFolder)
	end
	appendPlayerCharacters(filterList)
	rayParams.FilterDescendantsInstances = filterList
	return rayParams
end

local function applyIdlePose(state: WalkerRuntimeState, dt: number)
	local config = state.config
	local bodyCFrame = state.simulatedCFrame
	local rayParams = buildWalkerRayParams(state)
	local modBodyCF, lStrut1CF, lStrut2CF, lUpperCF, lLowerCF, lFootCF, rStrut1CF, rStrut2CF, rUpperCF, rLowerCF, rFootCF =
		WalkerIKServer.update(
			state.ikState,
			bodyCFrame,
			Vector3.zero,
			config,
			dt,
			rayParams,
			0,
			state.gaitSide,
			false,
			0,
			false
		)

	local aimOffset = state.aimYaw - state.heading
	aimOffset = ((aimOffset + math.pi) % (math.pi * 2)) - math.pi
	local headYawMin = math.rad(config.headYawMin or -120)
	local headYawMax = math.rad(config.headYawMax or 120)
	aimOffset = math.clamp(aimOffset, headYawMin, headYawMax)
	local cockpitYaw = state.heading + aimOffset
	local tiltCF = bodyCFrame:Inverse() * modBodyCF
	local _, tiltPitch, tiltRoll = tiltCF:ToEulerAnglesYXZ()
	local modPos = modBodyCF.Position
	local cockpitCFrame = CFrame.new(modPos) * CFrame.Angles(0, cockpitYaw, 0) * CFrame.Angles(tiltPitch, 0, tiltRoll)
	local nextHeadCFrame = CFrame.new(modPos) * CFrame.Angles(0, cockpitYaw, 0) * state.headBaseOffset

	local previousHeadCFrame = state.lastHeadCFrame
	local headDelta = nextHeadCFrame * previousHeadCFrame:Inverse()
	for _, childEntry in ipairs(state.childPartOffsets) do
		local childPart = childEntry.part
		if childPart.Parent == nil then
			continue
		end
		if state.legPartSet[childPart] then
			continue
		end
		if childPart == state.headPart or childPart:IsDescendantOf(state.headPart) then
			continue
		end
		childPart.CFrame = cockpitCFrame * childEntry.offset
	end

	state.primaryPart.CFrame = cockpitCFrame
	state.headPart.CFrame = nextHeadCFrame
	for _, followerPart in ipairs(state.headFollowerParts) do
		if followerPart.Parent ~= nil then
			followerPart.CFrame = headDelta * followerPart.CFrame
		end
	end

	local legParts = state.legParts
	if legParts.left.strut1 ~= nil then legParts.left.strut1.CFrame = lStrut1CF end
	if legParts.left.strut2 ~= nil then legParts.left.strut2.CFrame = lStrut2CF end
	legParts.left.upper.CFrame = lUpperCF
	legParts.left.lower.CFrame = lLowerCF
	legParts.left.foot.CFrame = lFootCF
	if legParts.right.strut1 ~= nil then legParts.right.strut1.CFrame = rStrut1CF end
	if legParts.right.strut2 ~= nil then legParts.right.strut2.CFrame = rStrut2CF end
	legParts.right.upper.CFrame = rUpperCF
	legParts.right.lower.CFrame = rLowerCF
	legParts.right.foot.CFrame = rFootCF
	state.lastHeadCFrame = nextHeadCFrame
end

local function clearDriver(state: WalkerRuntimeState)
	local previousDriver = state.driver
	state.instance:SetAttribute("WalkerDriverUserId", nil)
	if previousDriver ~= nil and driverToWalkerId[previousDriver] == state.walkerId then
		driverToWalkerId[previousDriver] = nil
	end
	state.driver = nil
	state.inputThrottle = 0
	state.inputStrafe = 0
	state.inputSteerX = 0
	state.inputSprint = false
	state.sprintFrac = 0
	-- Zero horizontal velocity immediately — a mech stopping dead on exit
	-- prevents the cockpit sliding forward while legs lag behind
	state.velocity = Vector3.new(0, state.velocity.Y, 0)
	-- Kill gait so client IK stops animating legs
	state.gaitActive = false
	state.gaitStopRequested = false
	state.gaitPhase = 0
	state.instance:SetAttribute("WalkerGaitActive", false)
	state.instance:SetAttribute("WalkerGaitPhase", 0)
	state.instance:SetAttribute("WalkerSprintFrac", 0)
	state.instance:SetAttribute("VehicleSpeed", 0)
	state.instance:SetAttribute("VehicleHeading", state.heading)
	-- Reset aim to heading so the cockpit snaps back to center on exit
	state.aimYaw = state.heading
	-- Snap to computed idle pose immediately on exit.
	state.ikState = WalkerIKServer.createState()
	applyIdlePose(state, 1 / 30)
end

local function updateDriverFromSeat(state: WalkerRuntimeState)
	local occupant = state.driverSeat.Occupant
	if occupant ~= nil then
		local character = occupant.Parent
		local player = if character ~= nil then Players:GetPlayerFromCharacter(character) else nil
		if player ~= nil then
			local previousDriver = state.driver
			if previousDriver ~= nil and previousDriver ~= player and driverToWalkerId[previousDriver] == state.walkerId then
				driverToWalkerId[previousDriver] = nil
			end

			state.driver = player
			driverToWalkerId[player] = state.walkerId
			state.instance:SetAttribute("WalkerDriverUserId", player.UserId)
			state.inputThrottle = 0
			state.inputStrafe = 0
			state.inputSteerX = 0
			state.wasStopped = false
			state.replicationState = "Active"
			state.settlingStartTick = 0
			state.lastSpeedUpdateTick = 0
			state.simulatedCFrame = state.primaryPart.CFrame
			state.lastCFrameWriteTick = 0
			state.ikState = WalkerIKServer.createState()
			if state.velocity.Y > 0 then
				state.velocity = Vector3.new(state.velocity.X, 0, state.velocity.Z)
			end
			return
		end
	end

	clearDriver(state)
	if state.replicationState == "Active" then
		state.replicationState = "Settling"
		state.settlingStartTick = tick()
	end
end

local function cleanupWalkerState(state: WalkerRuntimeState)
	for _, connection in ipairs(state.connections) do
		connection:Disconnect()
	end
	table.clear(state.connections)

	if state.driver ~= nil then
		clearDriver(state)
	end

	-- Clean up prompt part (lives in Workspace, not the model)
	if state.promptPart then
		state.promptPart:Destroy()
		state.promptPart = nil
	end

	-- Move legs back into model (for respawn) and clean up Workspace folder
	local legsFolder = legsFolderByEntityId[state.entityId]
	if legsFolder ~= nil then
		local leftLeg = legsFolder:FindFirstChild("LeftLeg")
		local rightLeg = legsFolder:FindFirstChild("RightLeg")
		if leftLeg ~= nil then
			leftLeg.Parent = state.instance
		end
		if rightLeg ~= nil then
			rightLeg.Parent = state.instance
		end
		legsFolder:Destroy()
		legsFolderByEntityId[state.entityId] = nil
	end

	walkersByEntityId[state.entityId] = nil
	walkersByWalkerId[state.walkerId] = nil
end

local function applySpeedAttributeReplication(state: WalkerRuntimeState, horizontalSpeed: number)
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
	state.instance:SetAttribute("WalkerAimYaw", state.aimYaw)
	state.lastReplicatedSpeed = horizontalSpeed
	state.lastReplicatedHeading = state.heading
	state.lastSpeedUpdateTick = now
end

local function stepSingleWalker(state: WalkerRuntimeState, dt: number)
	local config = state.config

	-- Guards
	if not HealthManager.isAlive(state.entityId) then
		return
	end
	if state.instance.Parent == nil then
		return
	end
	local pos = state.simulatedCFrame.Position
	if pos.Y < VOID_DESTROY_HEIGHT then
		HealthManager.applyDamage(state.entityId, 99999, "impact", "", pos, true)
		return
	end

	-- No driver: only process gravity while airborne, then go dormant
	if state.driver == nil then
		if state.replicationState == "Dormant" then
			return
		end

		-- Airborne: apply gravity until landing, then freeze
		if state.isAirborne then
			state.velocity = state.velocity + Vector3.new(0, -(config.gravity or 196) * dt, 0)
			state.lastVerticalSpeed = state.velocity.Y
			pos = pos + state.velocity * dt
			state.simulatedCFrame = CFrame.new(pos) * CFrame.Angles(0, state.heading, 0)

			-- Ground check for landing
			local rayParams = RaycastParams.new()
			rayParams.FilterType = Enum.RaycastFilterType.Exclude
			rayParams.IgnoreWater = true
			local filterList: { Instance } = { state.instance }
			local legsFolder2 = legsFolderByEntityId[state.entityId]
			if legsFolder2 then
				table.insert(filterList, legsFolder2)
			end
			appendPlayerCharacters(filterList)
			rayParams.FilterDescendantsInstances = filterList
			local walkHeight = config.walkHeight or 12
			local probeHeight = walkHeight * 0.5
			local rayOrigin = pos + Vector3.new(0, probeHeight, 0)
			local rayLength = walkHeight * 3
			local result = Workspace:Raycast(rayOrigin, Vector3.new(0, -rayLength, 0), rayParams)
			if result then
				local targetY = result.Position.Y + walkHeight
				if pos.Y <= targetY + 0.5 then
					state.velocity = Vector3.zero
					state.isAirborne = false
					state.lastGroundedTick = tick()
					pos = Vector3.new(pos.X, targetY, pos.Z)
					state.simulatedCFrame = CFrame.new(pos) * CFrame.Angles(0, state.heading, 0)
				end
			end

			-- Write CFrames while falling
			for _, entry in ipairs(state.childPartOffsets) do
				entry.part.CFrame = state.simulatedCFrame * entry.offset
			end
			state.primaryPart.CFrame = state.simulatedCFrame
			state.lastHeadCFrame = state.headPart.CFrame
			if state.promptPart then
				state.promptPart.CFrame = CFrame.new(pos.X, pos.Y - (config.walkHeight or 12), pos.Z)
			end
		end

			-- Grounded with no driver: one ground check to ensure correct walkHeight, then dormant
			if not state.isAirborne then
				local rayParams = buildWalkerRayParams(state)
				local walkHeight = config.walkHeight or 12
				local probeHeight = walkHeight * 0.5
				local rayOrigin = pos + Vector3.new(0, probeHeight, 0)
				local rayLength = walkHeight * 3
			local result = Workspace:Raycast(rayOrigin, Vector3.new(0, -rayLength, 0), rayParams)
			if result then
					local targetY = result.Position.Y + walkHeight
					pos = Vector3.new(pos.X, targetY, pos.Z)
					state.simulatedCFrame = CFrame.new(pos) * CFrame.Angles(0, state.heading, 0)
				end
				-- Write final idle pose before going dormant.
				applyIdlePose(state, dt)
				if state.promptPart then
					state.promptPart.CFrame = CFrame.new(pos.X, pos.Y - walkHeight, pos.Z)
				end
				state.replicationState = "Dormant"
			state.wasStopped = true
			state.velocity = Vector3.zero
		end
		return
	end

	-- 0. Sprint fraction: smooth 0→1 transition
	local wantSprint = state.inputSprint and state.inputThrottle > 0 and state.inputStrafe == 0
	local sprintRampSpeed = if wantSprint then (config.sprintAcceleration or 15) else 30
	local sprintTarget = if wantSprint then 1 else 0
	state.sprintFrac = state.sprintFrac + (sprintTarget - state.sprintFrac) * (1 - math.exp(-sprintRampSpeed * dt))
	if state.sprintFrac < 0.01 then state.sprintFrac = 0 end
	if state.sprintFrac > 0.99 then state.sprintFrac = 1 end
	local sprintReplicated = math.floor(math.clamp(state.sprintFrac, 0, 1) * 20 + 0.5) / 20
	local previousSprintReplicated = state.instance:GetAttribute("WalkerSprintFrac")
	if type(previousSprintReplicated) ~= "number" or math.abs(previousSprintReplicated - sprintReplicated) > 1e-4 then
		state.instance:SetAttribute("WalkerSprintFrac", sprintReplicated)
	end

	-- 1. Heading chases aimYaw (shortest-angle, rate-limited by turnSpeed)
	local walkTurnSpeed = math.rad(config.turnSpeed or 90)
	local sprintTurnSpeed = math.rad(config.sprintTurnSpeed or 15)
	local turnSpeed = walkTurnSpeed + (sprintTurnSpeed - walkTurnSpeed) * state.sprintFrac
	local aimDiff = state.aimYaw - state.heading
	-- Normalize to -pi..pi (shortest path)
	aimDiff = ((aimDiff + math.pi) % (math.pi * 2)) - math.pi
	local maxTurn = turnSpeed * dt
	local headingDelta = math.clamp(aimDiff, -maxTurn, maxTurn)
	state.heading = state.heading + headingDelta

	-- 2. Compute movement direction from WASD relative to heading
	local forward = Vector3.new(-math.sin(state.heading), 0, -math.cos(state.heading))
	local right = Vector3.new(-forward.Z, 0, forward.X)
	-- Sprint: lock to forward only (no strafe)
	local effectiveStrafe = if state.sprintFrac > 0.5 then 0 else state.inputStrafe
	local moveDir = forward * state.inputThrottle + right * effectiveStrafe
	if moveDir.Magnitude > 1 then
		moveDir = moveDir.Unit
	end

	-- 3. Compute target speed (lerp between walk and sprint)
	local walkMaxSpeed = config.maxSpeed
	if state.inputThrottle < 0 then
		walkMaxSpeed = config.reverseMaxSpeed or 12
	end
	local strafeMaxSpeed = config.strafeMaxSpeed or 15
	if effectiveStrafe ~= 0 and state.inputThrottle == 0 then
		walkMaxSpeed = strafeMaxSpeed
	end
	if effectiveStrafe ~= 0 and state.inputThrottle ~= 0 then
		local fwdFrac = math.abs(state.inputThrottle) / (math.abs(state.inputThrottle) + math.abs(effectiveStrafe))
		walkMaxSpeed = walkMaxSpeed * fwdFrac + strafeMaxSpeed * (1 - fwdFrac)
	end
	local sprintMaxSpeed = config.sprintMaxSpeed or 62.5
	local maxSpeed = walkMaxSpeed + (sprintMaxSpeed - walkMaxSpeed) * state.sprintFrac

	-- 4. Gait oscillator (replaces constant accel/decel)
	local walkHalfCycle = config.halfCycleDuration or 0.5
	local sprintHalfCycle = config.sprintHalfCycleDuration or 0.4
	local halfCycle = walkHalfCycle + (sprintHalfCycle - walkHalfCycle) * state.sprintFrac
	local walkMinFrac = config.gaitMinSpeedFrac or 0.3
	local sprintMinFrac = config.sprintGaitMinSpeedFrac or 0.6
	local minFrac = walkMinFrac + (sprintMinFrac - walkMinFrac) * state.sprintFrac

	if moveDir.Magnitude > 0.01 then
		if not state.gaitActive then
			state.gaitActive = true
			state.gaitPhase = 0
			state.gaitStopRequested = false
		end
	else
		if state.gaitActive then
			state.gaitStopRequested = true
		end
	end

	if state.gaitActive then
		state.gaitPhase += dt / halfCycle

		if state.gaitPhase >= 1 then
			state.gaitPhase -= 1
			state.gaitSide = if state.gaitSide == "left" then "right" else "left"

			if state.gaitStopRequested then
				state.gaitActive = false
				state.gaitPhase = 0
				state.gaitStopRequested = false
				state.velocity = Vector3.new(0, state.velocity.Y, 0)
			end
		end

		if state.gaitActive then
			local speedProfile = minFrac + (1 - minFrac) * math.sin(state.gaitPhase * math.pi)
			local gaitSpeed = maxSpeed * speedProfile

			local dir = moveDir
			if state.gaitStopRequested and moveDir.Magnitude < 0.01 then
				local hVel = Vector3.new(state.velocity.X, 0, state.velocity.Z)
				dir = if hVel.Magnitude > 0.01 then hVel.Unit else Vector3.zero
			end

			if dir.Magnitude > 0.01 then
				local horizontalVelocity = dir.Unit * gaitSpeed
				state.velocity = Vector3.new(horizontalVelocity.X, state.velocity.Y, horizontalVelocity.Z)
			end

			-- [GAIT_DBG] uncomment for debugging: print(string.format("[GAIT_DBG] phase=%.2f side=%s active=%s speed=%.1f", state.gaitPhase, state.gaitSide, tostring(state.gaitActive), gaitSpeed))
		end
	else
		local hVel = Vector3.new(state.velocity.X, 0, state.velocity.Z)
		if hVel.Magnitude > 0.01 then
			local newSpeed = math.max(hVel.Magnitude - (config.deceleration or 25) * dt, 0)
			state.velocity = hVel.Unit * newSpeed + Vector3.new(0, state.velocity.Y, 0)
		else
			state.velocity = Vector3.new(0, state.velocity.Y, 0)
		end
	end

	-- 5. Ground detection (center raycast)
	pos = state.simulatedCFrame.Position
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.IgnoreWater = true
	local filterList: { Instance } = { state.instance }
	local legsFolder = legsFolderByEntityId[state.entityId]
	if legsFolder then
		table.insert(filterList, legsFolder)
	end
	appendPlayerCharacters(filterList)
	rayParams.FilterDescendantsInstances = filterList

	local walkHeight = config.walkHeight or 12
	local probeHeight = walkHeight * 0.5
	local rayOrigin = pos + Vector3.new(0, probeHeight, 0)
	local rayLength = walkHeight * 3
	local result = Workspace:Raycast(rayOrigin, Vector3.new(0, -rayLength, 0), rayParams)

	-- Reject steep hits (cliff faces): treat as no ground
	local validGround = result ~= nil and result.Normal:Dot(Vector3.yAxis) > math.cos(math.rad(config.maxClimbSlope or 45))

	if result and validGround then
		local groundY = result.Position.Y
		local maxStepDown = config.maxStepDown or 4
		local targetY = groundY + walkHeight

		-- Slope check: gentle slopes slow the walker (skip when airborne or just landed)
		local slopeAngle = math.deg(math.acos(math.clamp(result.Normal:Dot(Vector3.yAxis), -1, 1)))
		local maxClimbSlope = config.maxClimbSlope or 45
		local justLanded = (tick() - state.lastGroundedTick) < 0.3
		if not state.isAirborne and not justLanded then
			if slopeAngle > maxClimbSlope and state.velocity.Y <= 0 and (pos.Y - groundY) < walkHeight + maxStepDown then
				local uphill = Vector3.new(result.Normal.X, 0, result.Normal.Z)
				if uphill.Magnitude > 0.01 then
					uphill = uphill.Unit
					local dot = Vector3.new(state.velocity.X, 0, state.velocity.Z):Dot(uphill)
					if dot > 0 then
						state.velocity = state.velocity - uphill * dot
					end
				end
			end
		end

		if state.isAirborne then
			local airborneGrace = (tick() - state.lastGroundedTick) > 0.25
			if pos.Y <= targetY + 0.5 and airborneGrace then
				-- Landing — check fall damage
				local fallSpeed = math.abs(state.lastVerticalSpeed)
				local fallDamageThreshold = config.fallDamageThreshold or 80
				if fallSpeed > fallDamageThreshold then
					local excess = fallSpeed - fallDamageThreshold
					local damage = math.floor(excess * (config.fallDamageScale or 0.3))
					if damage > 0 then
						local faction = HealthManager.getFaction(state.entityId) or ""
						HealthManager.applyDamage(state.entityId, damage, "impact", faction, pos, true)
					end
				end
				state.velocity = Vector3.new(state.velocity.X, 0, state.velocity.Z)
				state.isAirborne = false
				state.lastGroundedTick = tick()
				pos = Vector3.new(pos.X, targetY, pos.Z)
			end
		else
			if pos.Y - targetY > maxStepDown then
				-- Drop too large: go airborne instead of snapping
				state.isAirborne = true
				state.lastGroundedTick = tick()
			else
				-- Normal ground: snap to walk height
				state.velocity = Vector3.new(state.velocity.X, 0, state.velocity.Z)
				pos = Vector3.new(pos.X, targetY, pos.Z)
			end
		end
	else
		if not state.isAirborne then
			state.isAirborne = true
		end
	end

	-- 6. Gravity when airborne
	if state.isAirborne then
		state.velocity = state.velocity + Vector3.new(0, -(config.gravity or 196) * dt, 0)
	end
	state.lastVerticalSpeed = state.velocity.Y

	-- 7. Wall collision: forward raycast + radial overlap pushback
	local collisionRadius = config.collisionRadius or 5
	if collisionRadius > 0 then
		local hVel = Vector3.new(state.velocity.X, 0, state.velocity.Z)
		local hSpd2 = hVel.Magnitude
		if hSpd2 > 1 then
			-- Forward probe: cast in movement direction
			local moveUnit = hVel.Unit
			local lookahead = hSpd2 * dt * 3
			local hit = Workspace:Raycast(pos, moveUnit * (lookahead + collisionRadius), rayParams)
			if hit and hit.Normal.Y < 0.35 then
				-- Near-vertical wall: remove into-wall velocity component
				local wallNormal = Vector3.new(hit.Normal.X, 0, hit.Normal.Z)
				if wallNormal.Magnitude > 0.001 then
					wallNormal = wallNormal.Unit
					local intoWall = -state.velocity:Dot(wallNormal)
					if intoWall > 0 then
						local bounce = config.collisionBounce or 0.1
						state.velocity += wallNormal * intoWall * (1 + bounce)
					end
				end
			end
		end
		-- Radial overlap pushback: prevent clipping through walls
		local pushDirs = {
			Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0),
			Vector3.new(0, 0, 1), Vector3.new(0, 0, -1),
			Vector3.new(0.707, 0, 0.707), Vector3.new(-0.707, 0, 0.707),
			Vector3.new(0.707, 0, -0.707), Vector3.new(-0.707, 0, -0.707),
		}
		local totalPush = Vector3.zero
		for _, dir in ipairs(pushDirs) do
			local hit = Workspace:Raycast(pos, dir * collisionRadius, rayParams)
			if hit then
				local pen = collisionRadius - hit.Distance
				if pen > 0 then
					local pushNormal = Vector3.new(hit.Normal.X, 0, hit.Normal.Z)
					if pushNormal.Magnitude > 0.001 then
						totalPush += pushNormal.Unit * pen
					else
						totalPush += -dir * pen
					end
				end
			end
		end
		if totalPush.Magnitude > 0.01 then
			local maxPush = collisionRadius * 0.5
			if totalPush.Magnitude > maxPush then
				totalPush = totalPush.Unit * maxPush
			end
			pos = pos + totalPush
			local pushDir = totalPush.Unit
			local intoWall = state.velocity:Dot(pushDir)
			if intoWall < 0 then
				state.velocity -= pushDir * intoWall
			end
		end
	end

	-- 8. Apply velocity
	pos = pos + state.velocity * dt
	state.simulatedCFrame = CFrame.new(pos) * CFrame.Angles(0, state.heading, 0)

	-- 9. Solve authoritative walker pose (body, head, legs)
	local bodyCFrame = state.simulatedCFrame
	local horizontalVelocity = Vector3.new(state.velocity.X, 0, state.velocity.Z)
	local modBodyCF, lStrut1CF, lStrut2CF, lUpperCF, lLowerCF, lFootCF, rStrut1CF, rStrut2CF, rUpperCF, rLowerCF, rFootCF, lJustPlanted, rJustPlanted, lJustLifted, rJustLifted =
		WalkerIKServer.update(
			state.ikState,
			bodyCFrame,
			horizontalVelocity,
			config,
			dt,
			rayParams,
			state.gaitPhase,
			state.gaitSide,
			state.gaitActive,
			state.sprintFrac,
			state.driver ~= nil
		)
	local liftCount = (if lJustLifted then 1 else 0) + (if rJustLifted then 1 else 0)
	if liftCount > 0 then
		state.audioFootLiftSeq += liftCount
		state.instance:SetAttribute("WalkerAudioFootLiftSeq", state.audioFootLiftSeq)
	end
	local plantCount = (if lJustPlanted then 1 else 0) + (if rJustPlanted then 1 else 0)
	if plantCount > 0 then
		state.audioFootPlantSeq += plantCount
		state.instance:SetAttribute("WalkerAudioFootPlantSeq", state.audioFootPlantSeq)
	end

	local aimOffset = state.aimYaw - state.heading
	aimOffset = ((aimOffset + math.pi) % (math.pi * 2)) - math.pi
	local headYawMin = math.rad(config.headYawMin or -120)
	local headYawMax = math.rad(config.headYawMax or 120)
	aimOffset = math.clamp(aimOffset, headYawMin, headYawMax)
	local cockpitYaw = state.heading + aimOffset
	local tiltCF = bodyCFrame:Inverse() * modBodyCF
	local _, tiltPitch, tiltRoll = tiltCF:ToEulerAnglesYXZ()
	local modPos = modBodyCF.Position
	local cockpitCFrame = CFrame.new(modPos) * CFrame.Angles(0, cockpitYaw, 0) * CFrame.Angles(tiltPitch, 0, tiltRoll)
	local nextHeadCFrame = CFrame.new(modPos) * CFrame.Angles(0, cockpitYaw, 0) * state.headBaseOffset

	-- 10. Replicate
	local horizontalSpeed = Vector3.new(state.velocity.X, 0, state.velocity.Z).Magnitude
	applySpeedAttributeReplication(state, horizontalSpeed)
	-- Gait attributes: only write on discrete changes (side swap or active toggle)
	local prevGaitSide = state.instance:GetAttribute("WalkerGaitSide")
	local prevGaitActive = state.instance:GetAttribute("WalkerGaitActive")
	if state.gaitSide ~= prevGaitSide or state.gaitActive ~= prevGaitActive then
		state.instance:SetAttribute("WalkerGaitPhase", state.gaitPhase)
		state.instance:SetAttribute("WalkerGaitSide", state.gaitSide)
		state.instance:SetAttribute("WalkerGaitActive", state.gaitActive)
	end

	-- 11. Write CFrame (rate-limited)
	local now = tick()
	local isSettling = state.replicationState == "Settling"
	local configuredWriteRate = if isSettling
		then readConfigNumber("VehicleCFrameWriteRateSettling", 5)
		else readConfigNumber("VehicleCFrameWriteRateActive", 20)
	local writeRate = math.max(1, configuredWriteRate)
	local writeInterval = 1 / math.max(1, writeRate)
		if (now - state.lastCFrameWriteTick) >= writeInterval then
			local previousHeadCFrame = state.lastHeadCFrame
			local headDelta = nextHeadCFrame * previousHeadCFrame:Inverse()

			for _, childEntry in ipairs(state.childPartOffsets) do
				local childPart = childEntry.part
				if childPart.Parent == nil then
					continue
				end
				if state.legPartSet[childPart] then
					continue
				end
				if childPart == state.headPart or childPart:IsDescendantOf(state.headPart) then
					continue
				end
				childPart.CFrame = cockpitCFrame * childEntry.offset
			end

			state.primaryPart.CFrame = cockpitCFrame
			state.headPart.CFrame = nextHeadCFrame
			for _, followerPart in ipairs(state.headFollowerParts) do
			if followerPart.Parent ~= nil then
				followerPart.CFrame = headDelta * followerPart.CFrame
			end
		end
		local legParts = state.legParts
		if legParts.left.strut1 ~= nil then legParts.left.strut1.CFrame = lStrut1CF end
		if legParts.left.strut2 ~= nil then legParts.left.strut2.CFrame = lStrut2CF end
		legParts.left.upper.CFrame = lUpperCF
		legParts.left.lower.CFrame = lLowerCF
		legParts.left.foot.CFrame = lFootCF
		if legParts.right.strut1 ~= nil then legParts.right.strut1.CFrame = rStrut1CF end
		if legParts.right.strut2 ~= nil then legParts.right.strut2.CFrame = rStrut2CF end
		legParts.right.upper.CFrame = rUpperCF
		legParts.right.lower.CFrame = rLowerCF
		legParts.right.foot.CFrame = rFootCF
		state.lastHeadCFrame = nextHeadCFrame
		state.lastCFrameWriteTick = now
	end

end

local function stepWalkers(dt: number)
	for _, state in pairs(walkersByWalkerId) do
		local ok, err = pcall(stepSingleWalker, state, dt)
		if not ok then
			walkerErrorCount += 1
			warn("[WALKER_ERROR] " .. tostring(err))
		end
	end
end

function WalkerServer.registerWalker(entityId: string, instance: Model, driverSeat: Seat): ()
	if walkersByEntityId[entityId] ~= nil then
		WalkerServer.onEntityDestroyed(entityId)
	end

	spawnDataByEntityId[entityId] = {
		spawnCFrame = instance:GetPivot(),
		driverSeat = driverSeat,
	}

	local walkerConfig = resolveVehicleConfig(instance)
	if walkerConfig == nil then
		warn("[WALKER_ERROR] Failed to resolve config for " .. instance.Name)
		walkerErrorCount += 1
		return
	end

	local primaryPart = instance.PrimaryPart
	if primaryPart == nil then
		warn("[WALKER_ERROR] No PrimaryPart on " .. instance.Name)
		walkerErrorCount += 1
		return
	end

	-- Find walker-specific parts
	local headPart: BasePart? = nil
	local hipAttachments: { Attachment } = {}
	local leftLegFolder = instance:FindFirstChild("LeftLeg")
	local rightLegFolder = instance:FindFirstChild("RightLeg")

	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") and CollectionService:HasTag(descendant, "WalkerHead") then
			headPart = descendant :: BasePart
		end
		if descendant:IsA("Attachment") and CollectionService:HasTag(descendant, "WalkerHip") then
			table.insert(hipAttachments, descendant :: Attachment)
		end
	end

	if headPart == nil then
		warn("[WALKER_ERROR] No WalkerHead on " .. instance.Name)
		walkerErrorCount += 1
		return
	end

	if #hipAttachments < 2 then
		warn("[WALKER_ERROR] Need 2 WalkerHip attachments, found " .. tostring(#hipAttachments))
		walkerErrorCount += 1
		return
	end

	-- Sort hip attachments: left first (negative X), right second
	table.sort(hipAttachments, function(a: Attachment, b: Attachment)
		return a.WorldPosition.X < b.WorldPosition.X
	end)

	-- Resolve leg parts
	local function getLegParts(folder: Instance?): { strut1: BasePart?, strut2: BasePart?, upper: BasePart, lower: BasePart, foot: BasePart }?
		if folder == nil then
			return nil
		end
		local strut1 = folder:FindFirstChild("Strut1")
		local strut2 = folder:FindFirstChild("HipStrut")
		local upper = folder:FindFirstChild("UpperLeg")
		local lower = folder:FindFirstChild("LowerLeg")
		local foot = folder:FindFirstChild("Foot")
		if upper and upper:IsA("BasePart") and lower and lower:IsA("BasePart") and foot and foot:IsA("BasePart") then
			return {
				strut1 = if strut1 ~= nil and strut1:IsA("BasePart") then strut1 :: BasePart else nil,
				strut2 = if strut2 ~= nil and strut2:IsA("BasePart") then strut2 :: BasePart else nil,
				upper = upper :: BasePart,
				lower = lower :: BasePart,
				foot = foot :: BasePart,
			}
		end
		return nil
	end

	local leftLeg = getLegParts(leftLegFolder)
	local rightLeg = getLegParts(rightLegFolder)
	if leftLeg == nil or rightLeg == nil then
		warn("[WALKER_ERROR] Missing leg parts on " .. instance.Name)
		walkerErrorCount += 1
		return
	end

	-- Compute initial heading
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
		else
			forwardAxisLocal = Vector3.new(0, 0, -1)
		end
	end
	local worldForward = primaryPart.CFrame:VectorToWorldSpace(forwardAxisLocal)
	local horizontalForward = Vector3.new(worldForward.X, 0, worldForward.Z)
	if horizontalForward.Magnitude > 1e-4 then
		worldForward = horizontalForward.Unit
	else
		worldForward = instance:GetPivot().LookVector
	end
	local heading = computeHeadingFromLook(worldForward)

	-- Collect leg parts into set
	local legPartSet: { [BasePart]: boolean } = {}
	if leftLegFolder ~= nil then
		for _, desc in ipairs(leftLegFolder:GetDescendants()) do
			if desc:IsA("BasePart") then
				legPartSet[desc] = true
			end
		end
	end
	if rightLegFolder ~= nil then
		for _, desc in ipairs(rightLegFolder:GetDescendants()) do
			if desc:IsA("BasePart") then
				legPartSet[desc] = true
			end
		end
	end

	-- Store child part offsets BEFORE reparenting (captures all parts including legs)
	local childPartOffsets: { { part: BasePart, offset: CFrame } } = {}
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") and descendant ~= primaryPart then
			descendant.Anchored = true
			local offset = primaryPart.CFrame:Inverse() * descendant.CFrame
			table.insert(childPartOffsets, { part = descendant, offset = offset })
		end
	end

	-- Reparent leg folders to a detached model in Workspace so they're independent from
	-- PrimaryPart.CFrame replication and still resolve as walker hitboxes.
	local legPartsFolder = Instance.new("Model")
	legPartsFolder.Name = entityId .. "_Legs"
	legPartsFolder:SetAttribute("EntityId", entityId)
	if leftLegFolder ~= nil then
		leftLegFolder.Parent = legPartsFolder
	end
	if rightLegFolder ~= nil then
		rightLegFolder.Parent = legPartsFolder
	end
	legPartsFolder.Parent = Workspace
	legsFolderByEntityId[entityId] = legPartsFolder

	local state: WalkerRuntimeState = {
		walkerId = entityId,
		entityId = entityId,
		instance = instance,
		primaryPart = primaryPart,
		driverSeat = driverSeat,
		headPart = headPart :: BasePart,
		headBaseOffset = primaryPart.CFrame:Inverse() * (headPart :: BasePart).CFrame,
		headFollowerParts = {},
		lastHeadCFrame = (headPart :: BasePart).CFrame,
		hipAttachments = { left = hipAttachments[1], right = hipAttachments[2] },
		legParts = { left = leftLeg :: any, right = rightLeg :: any },
		ikState = WalkerIKServer.createState(),
		config = walkerConfig,
		driver = nil,
		velocity = Vector3.zero,
		heading = heading,
		aimYaw = heading,
		isAirborne = false,
		lastGroundedTick = tick(),
		lastVerticalSpeed = 0,
		inputThrottle = 0,
		inputStrafe = 0,
		inputSteerX = 0,
		inputSprint = false,
		sprintFrac = 0,
		connections = {},
		childPartOffsets = childPartOffsets,
		legPartSet = legPartSet,
		replicationState = "Active",
		settlingStartTick = 0,
		simulatedCFrame = primaryPart.CFrame,
		lastCFrameWriteTick = 0,
		lastSpeedUpdateTick = 0,
		lastReplicatedSpeed = 0,
		lastReplicatedHeading = heading,
		wasStopped = true,
		gaitPhase = 0,
		gaitActive = false,
		gaitSide = "left",
		gaitStopRequested = false,
		audioFootLiftSeq = 0,
		audioFootPlantSeq = 0,
	}

	for _, descendant in ipairs((headPart :: BasePart):GetDescendants()) do
		if descendant:IsA("BasePart") then
			table.insert(state.headFollowerParts, descendant :: BasePart)
		end
	end

	-- Store walker-head weapon mount neutral aim frames relative to PrimaryPart.
	-- WeaponServer reconstructs this frame each shot for moving vehicle platforms.
	for _, descendant in ipairs((headPart :: BasePart):GetDescendants()) do
		if descendant:IsA("BasePart") and CollectionService:HasTag(descendant, "WeaponMount") then
			local mount = descendant :: BasePart
			local relCF = primaryPart.CFrame:Inverse() * mount.CFrame
			local aimOffset = WeaponRig.getMountAimOffset(mount)
			local neutralLocalFrame = relCF * aimOffset:Inverse()
			local rx, ry, rz = neutralLocalFrame:ToOrientation()
			mount:SetAttribute("NeutralAimRX", rx)
			mount:SetAttribute("NeutralAimRY", ry)
			mount:SetAttribute("NeutralAimRZ", rz)
		end
	end

	table.insert(
		state.connections,
		driverSeat:GetPropertyChangedSignal("Occupant"):Connect(function()
			updateDriverFromSeat(state)
		end)
	)

	-- Proximity prompt: ground-level part positioned at foot level.
	-- Parented to Workspace (not the model) so PrimaryPart CFrame cascade
	-- doesn't fight our positioning. Updated each frame in the physics step.
	local promptPart = Instance.new("Part")
	promptPart.Name = "WalkerPromptAnchor"
	promptPart.Size = Vector3.new(4, 4, 4)
	promptPart.Transparency = 1
	promptPart.CanCollide = false
	promptPart.CanQuery = false
	promptPart.Anchored = true
	promptPart.CFrame = primaryPart.CFrame * CFrame.new(0, -(walkerConfig.walkHeight or 12), 0)
	promptPart.Parent = Workspace

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Pilot"
	prompt.ObjectText = instance.Name
	prompt.MaxActivationDistance = 25
	prompt.HoldDuration = 0
	prompt.RequiresLineOfSight = false
	prompt.Parent = promptPart

	-- Store references on state so the physics step can reposition and cleanup can destroy
	state.promptPart = promptPart
	state.prompt = prompt

	table.insert(
		state.connections,
		prompt.Triggered:Connect(function(player: Player)
			if state.driver ~= nil then return end
			local character = player.Character
			if not character then return end
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if not humanoid then return end
			driverSeat:Sit(humanoid)
		end)
	)

	-- Hide prompt while occupied
	table.insert(
		state.connections,
		driverSeat:GetPropertyChangedSignal("Occupant"):Connect(function()
			prompt.Enabled = (driverSeat.Occupant == nil)
		end)
	)

	updateDriverFromSeat(state)

	walkersByEntityId[entityId] = state
	walkersByWalkerId[state.walkerId] = state
	instance:SetAttribute("VehicleSpeed", 0)
	instance:SetAttribute("VehicleHeading", heading)
	instance:SetAttribute("WalkerAimYaw", heading)
	instance:SetAttribute("WalkerDriverUserId", nil)
	instance:SetAttribute("WalkerAudioFootLiftSeq", 0)
	instance:SetAttribute("WalkerAudioFootPlantSeq", 0)
	applyIdlePose(state, 1 / 30)
end

function WalkerServer.getWalkerByEntityId(entityId: string): WalkerRuntimeState?
	return walkersByEntityId[entityId]
end

function WalkerServer.getWalkerByDriver(player: Player): WalkerRuntimeState?
	local walkerId = driverToWalkerId[player]
	if walkerId == nil then
		return nil
	end
	return walkersByWalkerId[walkerId]
end

function WalkerServer.onEntityDestroyed(entityId: string): ()
	local state = walkersByEntityId[entityId]
	if state == nil then
		return
	end
	cleanupWalkerState(state)
end

function WalkerServer.onEntityRespawned(entityId: string): ()
	local spawnData = spawnDataByEntityId[entityId]
	if spawnData == nil then
		return
	end

	if walkersByEntityId[entityId] ~= nil then
		return
	end

	local instance = spawnData.driverSeat:FindFirstAncestorOfClass("Model")
	if instance == nil or instance.PrimaryPart == nil then
		return
	end
	instance:PivotTo(spawnData.spawnCFrame)

	WalkerServer.registerWalker(entityId, instance, spawnData.driverSeat)
end

function WalkerServer.getWalkerCount(): number
	local count = 0
	for _ in pairs(walkersByWalkerId) do
		count += 1
	end
	return count
end

function WalkerServer.getErrorCount(): number
	return walkerErrorCount
end

function WalkerServer.init(remotesFolder: Folder): ()
	vehicleInputRemote = remotesFolder:WaitForChild("VehicleInput") :: RemoteEvent
	vehicleExitRemote = remotesFolder:WaitForChild("VehicleExitRequest") :: RemoteEvent

	if inputConnection == nil then
		inputConnection = vehicleInputRemote.OnServerEvent:Connect(function(player: Player, payload: any)
			if type(payload) ~= "table" then
				return
			end

			local walkerId = driverToWalkerId[player]
			if walkerId == nil then
				return
			end
			local state = walkersByWalkerId[walkerId]
			if state == nil then
				return
			end

			local throttle = payload.throttle
			local steerX = payload.steerX
			if type(throttle) ~= "number" or type(steerX) ~= "number" then
				return
			end

			state.inputThrottle = math.clamp(math.round(throttle), -1, 1)
			state.inputSteerX = math.clamp(steerX, -1, 1)

			local strafe = payload.strafe
			if type(strafe) == "number" then
				state.inputStrafe = math.clamp(math.round(strafe), -1, 1)
			else
				state.inputStrafe = 0
			end

			state.inputSprint = (payload.boost == true) and state.inputThrottle > 0

			local aimYaw = payload.aimYaw
			if type(aimYaw) == "number" then
				state.aimYaw = aimYaw
			end
		end)
	end

	if exitConnection == nil then
		exitConnection = vehicleExitRemote.OnServerEvent:Connect(function(player: Player)
			local state = WalkerServer.getWalkerByDriver(player)
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
			local state = WalkerServer.getWalkerByDriver(player)
			if state == nil then
				return
			end
			clearDriver(state)
		end)
	end

	if heartbeatConnection == nil then
		heartbeatConnection = RunService.Heartbeat:Connect(stepWalkers)
	end
end

return WalkerServer
