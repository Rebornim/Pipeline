--!strict

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

if not RunService:IsStudio() then
	return
end

local ENABLE_ATTR = "Pass5HarnessEnabled"
if Workspace:GetAttribute(ENABLE_ATTR) ~= true then
	return
end

local sharedRoot = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatConfig = require(sharedRoot:WaitForChild("CombatConfig"))

local serverRoot = ServerScriptService:WaitForChild("CombatFramework")
local HealthManager = require(serverRoot:WaitForChild("Health"):WaitForChild("HealthManager"))

local function waitForEntityId(model: Model, timeoutSeconds: number): string?
	local deadline = tick() + timeoutSeconds
	while tick() < deadline do
		local entityId = model:GetAttribute("EntityId")
		if type(entityId) == "string" and entityId ~= "" then
			return entityId
		end
		task.wait(0.1)
	end
	return nil
end

local function createDummy(name: string, position: Vector3): (Model, Humanoid)
	local model = Instance.new("Model")
	model.Name = name

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Anchored = false
	root.CanCollide = true
	root.Parent = model

	local torso = Instance.new("Part")
	torso.Name = "Torso"
	torso.Size = Vector3.new(2, 2, 1)
	torso.Anchored = false
	torso.CanCollide = true
	torso.Parent = model

	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = Vector3.new(2, 1, 1)
	head.Anchored = false
	head.CanCollide = true
	head.Parent = model

	local rootJoint = Instance.new("Motor6D")
	rootJoint.Name = "RootJoint"
	rootJoint.Part0 = root
	rootJoint.Part1 = torso
	rootJoint.Parent = root

	local neck = Instance.new("Motor6D")
	neck.Name = "Neck"
	neck.Part0 = torso
	neck.Part1 = head
	neck.Parent = torso

	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = model

	model.PrimaryPart = root
	model:PivotTo(CFrame.new(position))
	model.Parent = Workspace
	return model, humanoid
end

local function run()
	local vehicle = Workspace:FindFirstChild("Pass5TestVehicle")
	if vehicle == nil or not vehicle:IsA("Model") then
		warn("[P5_TEST] missing Pass5TestVehicle fixture")
		return
	end

	local entityId = waitForEntityId(vehicle, 6)
	if entityId == nil then
		warn("[P5_TEST] no EntityId assigned for Pass5TestVehicle")
		return
	end

	local driverSeatInstance = vehicle:FindFirstChild("DriverSeat", true)
	local passengerSeatInstance = vehicle:FindFirstChild("PassengerSeat", true)
	if driverSeatInstance == nil or not driverSeatInstance:IsA("VehicleSeat") then
		warn("[P5_TEST] missing DriverSeat VehicleSeat")
		return
	end
	if passengerSeatInstance == nil or not passengerSeatInstance:IsA("Seat") then
		warn("[P5_TEST] missing PassengerSeat")
		return
	end

	local driverSeat = driverSeatInstance :: VehicleSeat
	local passengerSeat = passengerSeatInstance :: Seat
	local seatTagged = CollectionService:HasTag(driverSeat, "DriverSeat")
	print(string.format("[P5_TEST] driver_tagged=%s entity=%s", tostring(seatTagged), entityId))

	local spawnPosition = vehicle:GetPivot().Position

	local driverDummy, driverHumanoid = createDummy("P5DriverDummy", driverSeat.Position + Vector3.new(0, 3, 0))
	local passengerDummy, passengerHumanoid = createDummy("P5PassengerDummy", passengerSeat.Position + Vector3.new(0, 3, 0))
	driverSeat:Sit(driverHumanoid)
	passengerSeat:Sit(passengerHumanoid)
	task.wait(0.35)

	vehicle:PivotTo(vehicle:GetPivot() + Vector3.new(30, 0, 0))
	HealthManager.applyDamage(entityId, 9999, "blaster", "rebel", vehicle:GetPivot().Position, true)
	task.wait(0.8)

	local driverDead = driverHumanoid.Health <= 0
	local passengerDead = passengerHumanoid.Health <= 0
	print(string.format("[P5_TEST] occupants_dead driver=%s passenger=%s", tostring(driverDead), tostring(passengerDead)))

	local configId = vehicle:GetAttribute("ConfigId")
	local respawnSeconds = 10
	if type(configId) == "string" then
		local config = CombatConfig.Entities[configId]
		if config ~= nil and type(config.respawnTime) == "number" and config.respawnTime > 0 then
			respawnSeconds = config.respawnTime
		end
	end
	task.wait(respawnSeconds + 0.75)

	local respawnPosition = vehicle:GetPivot().Position
	local respawnDistance = (respawnPosition - spawnPosition).Magnitude
	local hullHP = vehicle:GetAttribute("HullHP")
	print(string.format("[P5_TEST] respawn_dist=%.2f hull=%s", respawnDistance, tostring(hullHP)))

	local score = 0
	if seatTagged then
		score += 1
	end
	if driverDead and passengerDead then
		score += 1
	end
	if respawnDistance <= 1.5 and type(hullHP) == "number" and hullHP >= 300 then
		score += 1
	end

	print(string.format("[P5_SUMMARY] pass=%d/3 entity=%s", score, entityId))

	driverDummy:Destroy()
	passengerDummy:Destroy()
end

task.spawn(run)
