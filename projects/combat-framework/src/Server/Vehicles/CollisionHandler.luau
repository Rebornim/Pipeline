--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local sharedRoot = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatConfig = require(sharedRoot:WaitForChild("CombatConfig"))
local CombatTypes = require(sharedRoot:WaitForChild("CombatTypes"))

local serverRoot = ServerScriptService:WaitForChild("CombatFramework")
local HealthManager = require(serverRoot:WaitForChild("Health"):WaitForChild("HealthManager"))

type VehicleRuntimeState = CombatTypes.VehicleRuntimeState

local CollisionHandler = {}

local function readConfigNumber(name: string, defaultValue: number): number
	local value = CombatConfig[name]
	if type(value) == "number" then
		return value
	end
	return defaultValue
end

local function computeForwardDirection(heading: number): Vector3
	return Vector3.new(-math.sin(heading), 0, -math.cos(heading))
end

local function computeRightDirection(forward: Vector3): Vector3
	local right = Vector3.new(forward.Z, 0, -forward.X)
	if right.Magnitude <= 1e-4 then
		return Vector3.xAxis
	end
	return right.Unit
end

function CollisionHandler.checkObstacles(state: VehicleRuntimeState, dt: number, rayParams: RaycastParams): ()
	if dt <= 0 then
		return
	end

	local forwardDir = computeForwardDirection(state.heading)
	local forwardSpeed = state.velocity:Dot(forwardDir)
	if forwardSpeed < 5 then
		return
	end
	-- Avoid false frontal collisions while descending steep geometry transitions.
	if state.velocity.Y < -18 then
		return
	end

	local lookaheadFrames = readConfigNumber("VehicleCollisionLookahead", 2.0)
	local lookaheadDistance = forwardSpeed * lookaheadFrames * dt
	if lookaheadDistance <= 0 then
		return
	end

	local rayCountConfig = math.floor(readConfigNumber("VehicleCollisionRayCount", 3))
	local rayCount = math.max(1, rayCountConfig)
	local rightDir = computeRightDirection(forwardDir)
	local origin = state.simulatedCFrame.Position

	for i = 1, rayCount do
		local alpha = if rayCount == 1 then 0 else (((i - 1) / (rayCount - 1)) * 2 - 1)
		local lateralOffset = alpha * state.config.collisionRadius
		local rayOrigin = origin + rightDir * lateralOffset
		local hit = Workspace:Raycast(rayOrigin, forwardDir * lookaheadDistance, rayParams)
		if hit ~= nil then
			local drivableSlopeAllowance = if math.abs(state.velocity.Y) > 10 then 8 else 5
			local drivableSlope = math.min(75, state.config.maxClimbSlope + drivableSlopeAllowance)
			local drivableMinUpDot = math.cos(math.rad(drivableSlope))
			if hit.Normal.Y >= drivableMinUpDot then
				continue
			end
			-- Terrain-like faces: skip slopes but keep near-vertical walls (up to ~20° from vertical).
			if hit.Normal.Y > 0.35 then
				continue
			end
			-- Descending crest/drop transitions can produce edge hits that should not count as frontal impacts.
			if hit.Position.Y < (rayOrigin.Y - state.config.hoverHeight * 0.2) then
				continue
			end

			-- Compute horizontal wall normal for reflection
			local wallNormal = Vector3.new(hit.Normal.X, 0, hit.Normal.Z)
			if wallNormal.Magnitude <= 1e-4 then
				wallNormal = -forwardDir
			else
				wallNormal = wallNormal.Unit
			end

			-- Into-wall speed: component of velocity moving into the wall surface
			-- wallNormal is horizontal (Y=0), so this only considers horizontal velocity
			local intoWallSpeed = -state.velocity:Dot(wallNormal)
			if intoWallSpeed <= 0 then
				-- Moving away from or parallel to wall — no response needed
				continue
			end

			-- Skip glancing/scraping hits: heading must be aimed into the wall
			local headingIntoWall = math.abs(-forwardDir:Dot(wallNormal))
			if headingIntoWall > 0.5 and intoWallSpeed > state.config.collisionDamageThreshold then
				local canApplyDamage = state.driver ~= nil or math.abs(state.inputThrottle) > 0.01
				if canApplyDamage then
					local damage = math.floor(
						(intoWallSpeed - state.config.collisionDamageThreshold) * state.config.collisionDamageScale + 0.5
					)
					if damage > 0 then
						HealthManager.applyDamage(state.entityId, damage, "impact", "", state.primaryPart.Position, true)
					end
				end
			end

			-- Reflect: remove into-wall component + add bounce, preserve tangential speed
			-- wallNormal is horizontal, so this only modifies X/Z — vertical velocity is untouched
			state.velocity += wallNormal * intoWallSpeed * (1 + state.config.collisionBounce)
			break
		end
	end
end

-- Continuous overlap pushback: fires short rays radially to detect walls at any speed.
-- Returns a position correction vector to push the vehicle out of overlapping geometry.
local PUSHBACK_DIRECTIONS = {
	Vector3.new(1, 0, 0),
	Vector3.new(-1, 0, 0),
	Vector3.new(0, 0, 1),
	Vector3.new(0, 0, -1),
	Vector3.new(0.707, 0, 0.707),
	Vector3.new(-0.707, 0, 0.707),
	Vector3.new(0.707, 0, -0.707),
	Vector3.new(-0.707, 0, -0.707),
}

function CollisionHandler.checkOverlapPushback(state: VehicleRuntimeState, rayParams: RaycastParams): ()
	local origin = state.simulatedCFrame.Position
	local radius = state.config.collisionRadius
	local pushback = Vector3.zero
	local hitCount = 0
	local hasOpposing = false
	local normals: { Vector3 } = {}

	for _, dir in ipairs(PUSHBACK_DIRECTIONS) do
		local hit = Workspace:Raycast(origin, dir * radius, rayParams)
		if hit ~= nil then
			local wallNormal = Vector3.new(hit.Normal.X, 0, hit.Normal.Z)
			if wallNormal.Magnitude > 1e-4 then
				wallNormal = wallNormal.Unit
			else
				wallNormal = -Vector3.new(dir.X, 0, dir.Z).Unit
			end
			local penetration = radius - hit.Distance
			if penetration > 0 then
				hitCount += 1
				pushback += wallNormal * penetration
				for _, prev in ipairs(normals) do
					if prev:Dot(wallNormal) < -0.3 then
						hasOpposing = true
					end
				end
				table.insert(normals, wallNormal)
			end
		end
	end

	if hitCount == 0 then
		return
	end

	if hasOpposing then
		-- Pinched between walls: kill horizontal velocity, don't push
		-- (positional corrections would fight each other and cause oscillation)
		state.velocity = Vector3.new(0, state.velocity.Y, 0)
		return
	end

	if pushback.Magnitude > 1e-4 then
		-- Cap pushback to prevent launching
		local maxPush = radius * 0.5
		if pushback.Magnitude > maxPush then
			pushback = pushback.Unit * maxPush
		end
		state.simulatedCFrame = state.simulatedCFrame + pushback
		local pushDir = pushback.Unit
		local intoWall = state.velocity:Dot(pushDir)
		if intoWall < 0 then
			state.velocity -= pushDir * intoWall
		end
	end
end

function CollisionHandler.checkVehicleCollisions(state: VehicleRuntimeState, allVehicles: { VehicleRuntimeState }): ()
	local myPosition = state.simulatedCFrame.Position
	local myRadius = state.config.collisionRadius

	for _, other in ipairs(allVehicles) do
		if other.vehicleId == state.vehicleId then
			continue
		end
		if state.vehicleId >= other.vehicleId then
			continue
		end
		if other.instance.Parent == nil or other.primaryPart.Parent == nil then
			continue
		end

		local delta = other.primaryPart.Position - myPosition
		local distance = delta.Magnitude
		local combinedRadius = myRadius + other.config.collisionRadius
		if distance <= 1e-4 or distance >= combinedRadius then
			continue
		end

		local normal = delta / distance
		local relativeVelocity = state.velocity - other.velocity
		local relativeSpeed = relativeVelocity:Dot(normal)
		if relativeSpeed <= 0 then
			continue
		end

		local averageBounce = (state.config.collisionBounce + other.config.collisionBounce) * 0.5
		local impulse = normal * relativeSpeed * averageBounce
		state.velocity = state.velocity - impulse * 0.5
		other.velocity = other.velocity + impulse * 0.5

		local averageThreshold = (state.config.collisionDamageThreshold + other.config.collisionDamageThreshold) * 0.5
		if relativeSpeed > averageThreshold then
			local canApplyDamage = state.driver ~= nil
				or other.driver ~= nil
				or math.abs(state.inputThrottle) > 0.01
				or math.abs(other.inputThrottle) > 0.01
			if canApplyDamage then
				local averageScale = (state.config.collisionDamageScale + other.config.collisionDamageScale) * 0.5
				local damage = math.floor((relativeSpeed - averageThreshold) * averageScale + 0.5)
				if damage > 0 then
					HealthManager.applyDamage(state.entityId, damage, "impact", "", myPosition, true)
					HealthManager.applyDamage(other.entityId, damage, "impact", "", other.primaryPart.Position, true)
				end
			end
		end
	end
end

return CollisionHandler
