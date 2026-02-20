--!strict

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local serverRoot = ServerScriptService:WaitForChild("CombatFramework")
local VehicleServer = require(serverRoot:WaitForChild("Vehicles"):WaitForChild("VehicleServer"))

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

local Pass5Test = {}

local HARNESS_FOLDER_NAME = "P5Harness"
local TEST_TIMEOUT_SECONDS = 12
local HARNESS_ORIGIN_X = 5000

local harnessFolder: Folder? = nil
local staticParts: { BasePart } = {}
local speedersByName: { [string]: Model } = {}
local didSetup = false
local didRun = false

local function clearHarness()
	if harnessFolder ~= nil and harnessFolder.Parent ~= nil then
		harnessFolder:Destroy()
	end
	harnessFolder = nil
	table.clear(staticParts)
	table.clear(speedersByName)
	didSetup = false
end

local function newAnchoredPart(
	parent: Instance,
	name: string,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	transparency: number
): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Anchored = true
	part.CanCollide = true
	part.CanTouch = true
	part.CanQuery = true
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.Transparency = transparency
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

	local body = newAnchoredPart(
		model,
		"Body",
		Vector3.new(6, 2, 10),
		spawnCFrame,
		Color3.fromRGB(130, 130, 130),
		0
	)
	model.PrimaryPart = body

	local fwdRef = Instance.new("Attachment")
	fwdRef.Name = "ForwardRef"
	fwdRef.CFrame = CFrame.new()
	fwdRef.Parent = body

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
	local hoverNames = { "HoverFL", "HoverFR", "HoverBL", "HoverBR" }
	for index, offset in ipairs(hoverOffsets) do
		local hoverPoint = newAnchoredPart(
			model,
			hoverNames[index],
			Vector3.new(0.5, 0.5, 0.5),
			spawnCFrame * CFrame.new(offset),
			Color3.fromRGB(255, 255, 255),
			1
		)
		hoverPoint.CanCollide = false
		hoverPoint.CanTouch = false
		hoverPoint.CanQuery = false
		CollectionService:AddTag(hoverPoint, "HoverPoint")
	end

	return model
end

local function raycastGroundDistance(origin: Vector3, ignoreModel: Model): number?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { ignoreModel }
	params.IgnoreWater = true

	local result = Workspace:Raycast(origin, Vector3.new(0, -80, 0), params)
	if result == nil then
		return nil
	end
	return result.Distance
end

local function measureHover(model: Model): (number, number)
	local totalDistance = 0
	local grounded = 0
	for _, descendant in ipairs(model:GetDescendants()) do
		if CollectionService:HasTag(descendant, "HoverPoint") then
			local hoverOrigin: Vector3?
			if descendant:IsA("Attachment") then
				hoverOrigin = descendant.WorldPosition
			elseif descendant:IsA("BasePart") then
				hoverOrigin = descendant.Position
			end
			if hoverOrigin == nil then
				continue
			end

			local distance = raycastGroundDistance(hoverOrigin, model)
			if distance ~= nil then
				grounded += 1
				totalDistance += distance
			end
		end
	end

	if grounded <= 0 then
		return 0, 0
	end
	return totalDistance / grounded, grounded
end

local function waitForVehicleState(model: Model): (string, VehicleRuntimeState?) 
	local deadline = tick() + TEST_TIMEOUT_SECONDS
	while tick() < deadline do
		local entityId = model:GetAttribute("EntityId")
		if type(entityId) == "string" then
			local state = VehicleServer.getVehicleByEntityId(entityId)
			if state ~= nil then
				return entityId, state :: VehicleRuntimeState
			end
		end
		task.wait(0.1)
	end

	local fallback = model:GetAttribute("EntityId")
	return if type(fallback) == "string" then fallback else "unknown", nil
end

local function resetVehicleState(model: Model, state: VehicleRuntimeState, cframe: CFrame)
	if model.PrimaryPart ~= nil then
		model:SetPrimaryPartCFrame(cframe)
	else
		model:PivotTo(cframe)
	end
	state.velocity = Vector3.zero
	state.inputThrottle = 0
	state.inputSteerX = 0
	state.heading = math.atan2(-cframe.LookVector.X, -cframe.LookVector.Z)
	state.isAirborne = false
	state.lastVerticalSpeed = 0
	model:SetAttribute("VehicleSpeed", 0)
	task.wait(0.5)
end

local function getHullHP(model: Model): number
	local value = model:GetAttribute("HullHP")
	if type(value) == "number" then
		return value
	end
	return 0
end

function Pass5Test.setup()
	if not RunService:IsStudio() then
		return
	end

	clearHarness()

	local folder = Instance.new("Folder")
	folder.Name = HARNESS_FOLDER_NAME
	folder.Parent = Workspace
	harnessFolder = folder

	local flatGround = newAnchoredPart(
		folder,
		"FlatGround",
		Vector3.new(600, 2, 600),
		CFrame.new(HARNESS_ORIGIN_X, -1, -220),
		Color3.fromRGB(58, 58, 58),
		0
	)
	local wall = newAnchoredPart(
		folder,
		"CollisionWall",
		Vector3.new(40, 20, 2),
		CFrame.new(HARNESS_ORIGIN_X, 10, -420),
		Color3.fromRGB(95, 95, 95),
		0
	)
	local fallPlatform = newAnchoredPart(
		folder,
		"FallPlatform",
		Vector3.new(40, 2, 40),
		CFrame.new(HARNESS_ORIGIN_X, 50, -520),
		Color3.fromRGB(70, 70, 70),
		0
	)
	table.insert(staticParts, flatGround)
	table.insert(staticParts, wall)
	table.insert(staticParts, fallPlatform)

	speedersByName.hover = createSpeeder(folder, "P5_Speeder_Hover", CFrame.new(HARNESS_ORIGIN_X, 5, 0))
	speedersByName.collision = createSpeeder(folder, "P5_Speeder_Collision", CFrame.new(HARNESS_ORIGIN_X + 200, 5, -220))
	speedersByName.fall = createSpeeder(folder, "P5_Speeder_Fall", CFrame.new(HARNESS_ORIGIN_X, 60, -510))

	didSetup = true
	print("[P5_TEST] setup=complete")
end

local function runDriveHoverTest(model: Model): boolean
	local entityId, state = waitForVehicleState(model)
	if state == nil then
		print(string.format("[P5_SUMMARY] test=drive_hover finalSpeed=0 hoverError=999 collisions=0 fallDamage=0 result=FAIL"))
		return false
	end

	resetVehicleState(model, state, CFrame.new(HARNESS_ORIGIN_X, 5, 0))

	local elapsed = 0
	local printAccumulator = 0
	state.inputThrottle = 1
	state.inputSteerX = 0
	while elapsed < 3.1 do
		task.wait(0.1)
		elapsed += 0.1
		printAccumulator += 0.1
		if printAccumulator >= 0.5 then
			printAccumulator = 0
			local speed = Vector3.new(state.velocity.X, 0, state.velocity.Z).Magnitude
			local height, grounded = measureHover(model)
			print(string.format("[P5_SPEED] vehicleId=%s speed=%.1f", entityId, speed))
			print(string.format("[P5_HOVER] vehicleId=%s height=%.2f target=4.00 grounded=%d", entityId, height, grounded))
		end
	end
	state.inputThrottle = 0

	local finalSpeed = Vector3.new(state.velocity.X, 0, state.velocity.Z).Magnitude
	local finalHeight, finalGrounded = measureHover(model)
	local hoverError = math.abs(finalHeight - 4)
	local passed = finalSpeed > 100 and hoverError < 1 and finalGrounded >= 3
	print(
		string.format(
			"[P5_SUMMARY] test=drive_hover finalSpeed=%d hoverError=%.2f collisions=0 fallDamage=0 result=%s",
			math.floor(finalSpeed + 0.5),
			hoverError,
			if passed then "PASS" else "FAIL"
		)
	)
	return passed
end

local function runCollisionTest(model: Model): boolean
	local entityId, state = waitForVehicleState(model)
	if state == nil then
		print(string.format("[P5_SUMMARY] test=collision finalSpeed=0 hoverError=0 collisions=0 fallDamage=0 result=FAIL"))
		return false
	end

	resetVehicleState(model, state, CFrame.new(HARNESS_ORIGIN_X, 5, -220))
	local hpStart = getHullHP(model)
	local collided = false
	local elapsed = 0
	state.inputThrottle = 1
	state.inputSteerX = 0
	while elapsed < 7.5 do
		task.wait(0.1)
		elapsed += 0.1
		local speed = Vector3.new(state.velocity.X, 0, state.velocity.Z).Magnitude
		local hpNow = getHullHP(model)
		if hpNow < hpStart then
			collided = true
		end
		if collided and speed < 5 then
			break
		end
	end
	state.inputThrottle = 0

	local hpEnd = getHullHP(model)
	local damage = math.max(0, hpStart - hpEnd)
	local finalSpeed = Vector3.new(state.velocity.X, 0, state.velocity.Z).Magnitude
	local passed = collided and damage > 0 and finalSpeed < 5
	print(
		string.format(
			"[P5_SUMMARY] test=collision finalSpeed=%d hoverError=0 collisions=%d fallDamage=0 result=%s",
			math.floor(finalSpeed + 0.5),
			if collided then 1 else 0,
			if passed then "PASS" else "FAIL"
		)
	)
	return passed
end

local function runFallDamageTest(model: Model): boolean
	local entityId, state = waitForVehicleState(model)
	if state == nil then
		print(string.format("[P5_SUMMARY] test=fall_damage finalSpeed=0 hoverError=0 collisions=0 fallDamage=0 result=FAIL"))
		return false
	end

	resetVehicleState(model, state, CFrame.new(HARNESS_ORIGIN_X, 60, -510) * CFrame.Angles(0, math.pi, 0))
	local hpStart = getHullHP(model)
	local airborneSeen = false
	local landedAfterAirborne = false
	local landingVerticalSpeed = 0
	local maxObservedVerticalSpeed = 0
	local elapsed = 0
	state.inputThrottle = 1
	state.inputSteerX = 0
	while elapsed < 9.5 do
		task.wait(0.05)
		elapsed += 0.05

		if state.isAirborne and not airborneSeen then
			airborneSeen = true
			print(string.format("[P5_AIRBORNE] vehicleId=%s verticalSpeed=%.1f", entityId, state.lastVerticalSpeed))
		end
		if airborneSeen then
			maxObservedVerticalSpeed = math.max(maxObservedVerticalSpeed, math.abs(state.lastVerticalSpeed))
		end

		if airborneSeen and not state.isAirborne and not landedAfterAirborne then
			landedAfterAirborne = true
			landingVerticalSpeed = math.max(math.abs(state.lastVerticalSpeed), maxObservedVerticalSpeed)
			print(string.format("[P5_GROUNDED] vehicleId=%s verticalSpeed=%.1f", entityId, state.lastVerticalSpeed))
		end

		local hpNow = getHullHP(model)
		if airborneSeen and hpNow < hpStart and not landedAfterAirborne then
			landedAfterAirborne = true
			landingVerticalSpeed = math.max(math.abs(state.lastVerticalSpeed), maxObservedVerticalSpeed)
			print(string.format("[P5_GROUNDED] vehicleId=%s verticalSpeed=%.1f", entityId, state.lastVerticalSpeed))
		end
		if landedAfterAirborne and hpNow < hpStart then
			break
		end
	end
	state.inputThrottle = 0

	local hpEnd = getHullHP(model)
	local damage = math.max(0, hpStart - hpEnd)
	if damage > 0 then
		print(string.format("[P5_FALL_DAMAGE] vehicleId=%s verticalSpeed=%.1f damage=%d", entityId, landingVerticalSpeed, damage))
	end

	local passed = airborneSeen and landedAfterAirborne and damage > 0
	print(
		string.format(
			"[P5_SUMMARY] test=fall_damage finalSpeed=0 hoverError=0 collisions=0 fallDamage=%d result=%s",
			damage,
			if passed then "PASS" else "FAIL"
		)
	)
	return passed
end

local function parkVehicleForIsolation(model: Model, cframe: CFrame)
	local _, state = waitForVehicleState(model)
	if state == nil then
		return
	end
	resetVehicleState(model, state, cframe)
	state.inputThrottle = 0
	state.inputSteerX = 0
end

function Pass5Test.run()
	if didRun then
		return
	end
	didRun = true

	if not didSetup then
		print("[P5_TEST] setup_missing")
		return
	end

	task.wait(1)
	print("========== START READ HERE ==========")

	local hoverModel = speedersByName.hover
	local collisionModel = speedersByName.collision
	local fallModel = speedersByName.fall
	if hoverModel == nil or collisionModel == nil or fallModel == nil then
		print("[P5_TEST] missing_speeder_models")
		return
	end

	local passHover = runDriveHoverTest(hoverModel)
	parkVehicleForIsolation(hoverModel, CFrame.new(HARNESS_ORIGIN_X + 600, 5, 200))

	local passCollision = runCollisionTest(collisionModel)
	parkVehicleForIsolation(collisionModel, CFrame.new(HARNESS_ORIGIN_X + 800, 5, 200))

	local passFall = runFallDamageTest(fallModel)

	local entityIds: { string } = {}
	for _, model in pairs(speedersByName) do
		local entityId = model:GetAttribute("EntityId")
		if type(entityId) == "string" then
			table.insert(entityIds, entityId)
			VehicleServer.onEntityDestroyed(entityId)
		end
	end

	local activeVehicles = 0
	for _, entityId in ipairs(entityIds) do
		if VehicleServer.getVehicleByEntityId(entityId) ~= nil then
			activeVehicles += 1
		end
	end
	print(string.format("[P5_LEAK] activeVehicles=%d", activeVehicles))

	clearHarness()
	print(
		string.format(
			"[P5_SUMMARY] test=aggregate finalSpeed=0 hoverError=0 collisions=0 fallDamage=0 result=%s",
			if passHover and passCollision and passFall and activeVehicles == 0 then "PASS" else "FAIL"
		)
	)
	print("========== END READ HERE ==========")
end

return Pass5Test
