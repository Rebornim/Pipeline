--!strict

local CollectionService = game:GetService("CollectionService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local serverRoot = ServerScriptService:WaitForChild("CombatFramework")
local VehicleServer = require(serverRoot:WaitForChild("Vehicles"):WaitForChild("VehicleServer"))
local HealthManager = require(serverRoot:WaitForChild("Health"):WaitForChild("HealthManager"))

local sharedRoot = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatConfig = require(sharedRoot:WaitForChild("CombatConfig"))

type VehicleRuntimeState = {
	entityId: string,
	vehicleId: string,
	instance: Model,
	primaryPart: BasePart,
	hoverPoints: { BasePart },
	velocity: Vector3,
	heading: number,
	inputThrottle: number,
	inputSteerX: number,
	isAirborne: boolean,
	lastVerticalSpeed: number,
}

local CollisionMatrix = {}

local ORIGIN = Vector3.new(6000, 0, 0)
local FOLDER_NAME = "CollisionMatrixHarness"
local TEST_TIMEOUT = 8
local BIG_HP = 100000 -- prevent death during testing

--------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------

local function newPart(parent: Instance, name: string, size: Vector3, cframe: CFrame): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Anchored = true
	part.CanCollide = true
	part.CanTouch = true
	part.CanQuery = true
	part.Color = Color3.fromRGB(80, 80, 80)
	part.Material = Enum.Material.SmoothPlastic
	part.Transparency = 0
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function createSpeeder(parent: Instance, name: string, spawnCFrame: CFrame): Model
	local model = Instance.new("Model")
	model.Name = name
	model.Parent = parent
	model:SetAttribute("Faction", "empire")
	model:SetAttribute("ConfigId", "light_speeder")
	model:SetAttribute("VehicleConfigId", "light_speeder")
	CollectionService:AddTag(model, "CombatEntity")
	CollectionService:AddTag(model, "VehicleEntity")

	local body = Instance.new("Part")
	body.Name = "Body"
	body.Size = Vector3.new(6, 2, 10)
	body.CFrame = spawnCFrame
	body.Anchored = true
	body.CanCollide = true
	body.Color = Color3.fromRGB(130, 130, 130)
	body.Material = Enum.Material.SmoothPlastic
	body.TopSurface = Enum.SurfaceType.Smooth
	body.BottomSurface = Enum.SurfaceType.Smooth
	body.Parent = model
	model.PrimaryPart = body
	model:SetAttribute("ForwardAxis", "-Z")

	local seat = Instance.new("Seat")
	seat.Name = "DriverSeat"
	seat.Size = Vector3.new(2, 1, 2)
	seat.CFrame = spawnCFrame * CFrame.new(0, 1.5, -2.5)
	seat.Anchored = true
	seat.CanCollide = true
	seat.TopSurface = Enum.SurfaceType.Smooth
	seat.BottomSurface = Enum.SurfaceType.Smooth
	seat.Parent = model
	CollectionService:AddTag(seat, "DriverSeat")

	local hoverOffsets = {
		Vector3.new(-2.5, -1, -4),
		Vector3.new(2.5, -1, -4),
		Vector3.new(-2.5, -1, 4),
		Vector3.new(2.5, -1, 4),
	}
	for i, offset in ipairs(hoverOffsets) do
		local hp = Instance.new("Part")
		hp.Name = "Hover" .. i
		hp.Size = Vector3.new(0.5, 0.5, 0.5)
		hp.CFrame = spawnCFrame * CFrame.new(offset)
		hp.Anchored = true
		hp.CanCollide = false
		hp.CanTouch = false
		hp.CanQuery = false
		hp.Transparency = 1
		hp.Parent = model
		CollectionService:AddTag(hp, "HoverPoint")
	end
	return model
end

local function registerAndGetState(model: Model): (VehicleRuntimeState?, string)
	local entityId = string.format("cm_%d", math.floor(os.clock() * 1000 + math.random(1, 9999)))
	model:SetAttribute("EntityId", entityId)
	model:SetAttribute("ConfigId", "light_speeder")

	HealthManager.registerEntity(entityId, {
		instance = model,
		configId = "light_speeder",
		faction = "empire",
		weaponMount = nil,
		muzzlePoint = nil,
		turretSeat = nil,
	})

	local seat: Seat? = nil
	local hoverPoints: { BasePart } = {}
	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("Seat") and CollectionService:HasTag(desc, "DriverSeat") then
			seat = desc
		end
		if desc:IsA("BasePart") and CollectionService:HasTag(desc, "HoverPoint") then
			table.insert(hoverPoints, desc)
		end
	end

	if seat ~= nil and #hoverPoints >= 4 then
		VehicleServer.registerVehicle(entityId, model, "light_speeder", seat, hoverPoints)
	end

	local deadline = tick() + TEST_TIMEOUT
	while tick() < deadline do
		local state = VehicleServer.getVehicleByEntityId(entityId)
		if state ~= nil then
			return state :: VehicleRuntimeState, entityId
		end
		task.wait(0.1)
	end
	return nil, entityId
end

-- Reset HP using HealthManager internal state to prevent death accumulation
local function forceResetHP(entityId: string, model: Model)
	local healthState = HealthManager.getHealth(entityId)
	if healthState ~= nil then
		local h = healthState :: any
		h.currentHP = BIG_HP
		h.maxHP = BIG_HP
		h.state = "active"
	end
	model:SetAttribute("HullHP", BIG_HP)
	model:SetAttribute("MaxHullHP", BIG_HP)
end

local function getHP(entityId: string): number
	local healthState = HealthManager.getHealth(entityId)
	if healthState ~= nil then
		return (healthState :: any).currentHP
	end
	return 0
end

--------------------------------------------------------------------------
-- Single collision test case
--------------------------------------------------------------------------

local function runCase(
	state: VehicleRuntimeState,
	model: Model,
	wallPart: BasePart,
	approachAngleDeg: number,
	speed: number,
	label: string
): (number, number) -- returns (intoWallSpeed, damage)
	-- Reset HP via HealthManager internal state
	forceResetHP(state.entityId, model)
	local hpBefore = getHP(state.entityId)

	-- Position vehicle 8 studs from wall to minimize acceleration drift
	local wallPos = wallPart.Position
	local wallFaceNormal = wallPart.CFrame.LookVector -- +Z face
	-- Rotate approach direction by the angle (in the horizontal plane)
	local angleRad = math.rad(approachAngleDeg)
	local approachDir = CFrame.fromAxisAngle(Vector3.yAxis, angleRad):VectorToWorldSpace(-wallFaceNormal)
	approachDir = Vector3.new(approachDir.X, 0, approachDir.Z).Unit

	local startPos = wallPos + wallFaceNormal * 8 -- 8 studs in front of wall
	startPos = Vector3.new(startPos.X, 2, startPos.Z) -- hover height

	local heading = math.atan2(-approachDir.X, -approachDir.Z)
	local forwardDir = Vector3.new(-math.sin(heading), 0, -math.cos(heading))
	local spawnCF = CFrame.lookAt(startPos, startPos + forwardDir)
	model:PivotTo(spawnCF);
	(state :: any).simulatedCFrame = spawnCF
	state.velocity = approachDir * speed
	state.heading = heading
	-- Use small throttle: enough to pass the damage guard (> 0.01)
	-- but small enough to minimize acceleration
	state.inputThrottle = 0.02
	state.inputSteerX = 0
	state.isAirborne = false
	state.lastVerticalSpeed = 0;
	(state :: any).replicationState = "Active";
	(state :: any).landingDampUntil = 0;
	(state :: any).crestReleaseUntil = 0;
	(state :: any).crestLaunchUntil = 0;
	(state :: any).wasStopped = false
	model:SetAttribute("VehicleSpeed", speed)

	-- Run physics until collision or timeout
	local elapsed = 0
	while elapsed < 3.0 do
		task.wait(0.05)
		elapsed += 0.05;
		(state :: any).replicationState = "Active"
		local hpNow = getHP(state.entityId)
		if hpNow < hpBefore then
			break
		end
		-- Re-inject velocity if it decayed too much
		local currentSpeed = Vector3.new(state.velocity.X, 0, state.velocity.Z).Magnitude
		if currentSpeed < speed * 0.5 then
			state.velocity = approachDir * speed
		end
	end
	state.inputThrottle = 0

	local hpAfter = getHP(state.entityId)
	local damage = math.max(0, hpBefore - hpAfter)

	-- Compute theoretical into-wall speed component
	local wallNormalFlat = Vector3.new(wallFaceNormal.X, 0, wallFaceNormal.Z)
	if wallNormalFlat.Magnitude > 1e-4 then
		wallNormalFlat = wallNormalFlat.Unit
	end
	local intoWallSpeed = math.abs(approachDir:Dot(wallNormalFlat)) * speed

	return intoWallSpeed, damage
end

--------------------------------------------------------------------------
-- Main test
--------------------------------------------------------------------------

function CollisionMatrix.run()
	print("[COLLISION_MATRIX] Starting comprehensive collision damage test...")

	-- Setup
	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = Workspace

	-- Ground
	newPart(folder, "Ground", Vector3.new(4000, 2, 400), CFrame.new(ORIGIN + Vector3.new(1500, -1, 0)))

	-- Create walls with different slopes (tilt around X axis)
	-- wallSlopeDeg: 90 = vertical, 75/60/45 = progressively tilted
	local wallConfigs: { { name: string, slopeDeg: number, part: BasePart? } } = {
		{ name = "Vertical_90", slopeDeg = 90, part = nil },
		{ name = "Slope_75", slopeDeg = 75, part = nil },
		{ name = "Slope_60", slopeDeg = 60, part = nil },
		{ name = "Slope_45", slopeDeg = 45, part = nil },
	}

	for i, wc in ipairs(wallConfigs) do
		local xOffset = (i - 1) * 800
		local tiltAngle = math.rad(90 - wc.slopeDeg) -- 0 for vertical, increasing for slopes
		local wallCF = CFrame.new(ORIGIN + Vector3.new(xOffset, 10, -60))
			* CFrame.Angles(tiltAngle, 0, 0)
		wc.part = newPart(folder, "Wall_" .. wc.name, Vector3.new(600, 20, 2), wallCF)
	end

	-- Create test vehicle
	local speeder = createSpeeder(folder, "CM_Speeder", CFrame.new(ORIGIN + Vector3.new(0, 5, 0)))
	task.wait(0.5)

	local state, entityId = registerAndGetState(speeder)
	if state == nil then
		print("[COLLISION_MATRIX] FAIL: vehicle state not found after manual registration")
		folder:Destroy()
		return
	end
	print("[COLLISION_MATRIX] Vehicle registered: " .. entityId)

	-- Pump maxHP to BIG_HP so it never dies
	forceResetHP(entityId, speeder)

	-- Test parameters
	local approachAngles = { 0, 15, 30, 45, 60, 75 }
	local speeds = { 50, 70, 90, 120 }

	local threshold = CombatConfig.Vehicles.light_speeder.collisionDamageThreshold
	local scale = CombatConfig.Vehicles.light_speeder.collisionDamageScale

	-- Print header
	print(string.format("[COLLISION_MATRIX] threshold=%d, scale=%.1f, HP=%d", threshold, scale, BIG_HP))
	print("[COLLISION_MATRIX] Format: wall|angle|speed|theoreticalIntoWall|damage")
	print("[COLLISION_MATRIX] ================================================")

	local totalTests = 0
	local totalDamageOK = 0
	local totalDamageBad = 0
	local results: { string } = {}

	for _, wc in ipairs(wallConfigs) do
		local wallPart = wc.part
		if wallPart == nil then continue end

		print(string.format("[COLLISION_MATRIX] --- Wall: %s (slope=%d deg) ---", wc.name, wc.slopeDeg))

		-- Is this a slope where Normal.Y >= 0.35 (should NOT deal wall damage)?
		local wallNormalY = math.sin(math.rad(90 - wc.slopeDeg))
		local slopeSkipsDamage = wallNormalY >= 0.35

		for _, angleDeg in ipairs(approachAngles) do
			for _, speed in ipairs(speeds) do
				totalTests += 1
				local intoWall, damage = runCase(state, speeder, wallPart, angleDeg, speed, wc.name)

				-- Determine if this result is reasonable
				local tag = "OK"
				if slopeSkipsDamage then
					if damage > 0 then
						tag = "BAD_SLOPE_DMG"
						totalDamageBad += 1
					else
						totalDamageOK += 1
					end
				else
					if intoWall > threshold + 10 and damage == 0 then
						tag = "MISS_NO_DMG"
						totalDamageBad += 1
					elseif intoWall < threshold - 5 and damage > 0 then
						tag = "UNEXPECTED_DMG"
						totalDamageBad += 1
					else
						totalDamageOK += 1
					end
				end

				local line = string.format(
					"%s|angle=%d|speed=%d|intoWall=%.0f|damage=%d|%s",
					wc.name, angleDeg, speed, intoWall, damage, tag
				)
				print("[COLLISION_MATRIX] " .. line)
				table.insert(results, line)
			end
		end
	end

	-- Cleanup
	if type(entityId) == "string" then
		VehicleServer.onEntityDestroyed(entityId)
	end
	folder:Destroy()

	-- Summary
	print("[COLLISION_MATRIX] ================================================")
	print(string.format("[COLLISION_MATRIX] TOTAL: %d tests, %d OK, %d issues", totalTests, totalDamageOK, totalDamageBad))
	if totalDamageBad > 0 then
		print("[COLLISION_MATRIX] ISSUES:")
		for _, line in ipairs(results) do
			if string.find(line, "BAD") or string.find(line, "MISS") or string.find(line, "UNEXPECTED") then
				print("[COLLISION_MATRIX]   " .. line)
			end
		end
	end
	print(string.format("[COLLISION_MATRIX] RESULT=%s", if totalDamageBad == 0 then "ALL_OK" else "HAS_ISSUES"))
end

return CollisionMatrix
