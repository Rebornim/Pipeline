--!strict

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local sharedRoot = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatConfig = require(sharedRoot:WaitForChild("CombatConfig"))

local serverRoot = ServerScriptService:WaitForChild("CombatFramework")
local HealthManager = require(serverRoot:WaitForChild("Health"):WaitForChild("HealthManager"))
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

type ScenarioResult = {
	name: string,
	passed: boolean,
	detail: string,
}

local Pass5CriticVerify = {}

local ORIGIN = Vector3.new(12000, 0, 0)
local vehicleConfigId = "light_speeder"

local function resolveEntityConfigId(): string
	local vehicles = CombatConfig.Vehicles
	local entities = CombatConfig.Entities
	if type(vehicles) == "table" and type(vehicles[vehicleConfigId]) == "table" then
		local configured = vehicles[vehicleConfigId].entityConfigId
		if type(configured) == "string" and type(entities[configured]) == "table" then
			return configured
		end
	end

	if type(entities) == "table" then
		for configId, config in pairs(entities) do
			if type(configId) == "string" and type(config) == "table" then
				return configId
			end
		end
	end

	return "light_speeder"
end

local function readConfigNumber(name: string, fallback: number): number
	local raw = CombatConfig[name]
	if type(raw) == "number" then
		return raw
	end
	return fallback
end

local function newPart(
	parent: Instance,
	name: string,
	size: Vector3,
	cframe: CFrame,
	anchored: boolean,
	canCollide: boolean,
	transparency: number
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Anchored = anchored
	part.CanCollide = canCollide
	part.CanTouch = canCollide
	part.CanQuery = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Transparency = transparency
	part.Material = Enum.Material.SmoothPlastic
	part.Parent = parent
	return part
end

local function createSpeederModel(parent: Instance, name: string, spawnCFrame: CFrame): (Model, Seat, { BasePart })
	local model = Instance.new("Model")
	model.Name = name
	model.Parent = parent

	local body = newPart(model, "Body", Vector3.new(6, 2, 10), spawnCFrame, true, true, 0)
	model.PrimaryPart = body

	local forwardRef = Instance.new("Attachment")
	forwardRef.Name = "ForwardRef"
	forwardRef.CFrame = CFrame.new()
	forwardRef.Parent = body

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
	local hoverPoints: { BasePart } = {}
	for index, offset in ipairs(hoverOffsets) do
		local hover = newPart(
			model,
			"Hover" .. tostring(index),
			Vector3.new(0.5, 0.5, 0.5),
			spawnCFrame * CFrame.new(offset),
			true,
			false,
			1
		)
		CollectionService:AddTag(hover, "HoverPoint")
		table.insert(hoverPoints, hover)
	end

	return model, seat, hoverPoints
end

local function registerSpeeder(
	parent: Instance,
	name: string,
	spawnCFrame: CFrame
): (Model, VehicleRuntimeState, string)
	local model, seat, hoverPoints = createSpeederModel(parent, name, spawnCFrame)
	local entityId = string.format("p5_crit_%s_%d", name, math.floor(os.clock() * 1000 + math.random(1, 999)))
	local entityConfigId = resolveEntityConfigId()
	model:SetAttribute("EntityId", entityId)
	model:SetAttribute("Faction", "empire")
	model:SetAttribute("ConfigId", entityConfigId)
	model:SetAttribute("VehicleConfigId", vehicleConfigId)

	HealthManager.registerEntity(entityId, {
		instance = model,
		configId = entityConfigId,
		faction = "empire",
		weaponMount = nil,
		muzzlePoint = nil,
		turretSeat = nil,
	})
	VehicleServer.registerVehicle(entityId, model, vehicleConfigId, seat, hoverPoints)

	local deadline = os.clock() + 2
	repeat
		local state = VehicleServer.getVehicleByEntityId(entityId)
		if state ~= nil then
			return model, state :: VehicleRuntimeState, entityId
		end
		task.wait(0.05)
	until os.clock() >= deadline

	error("Failed to register vehicle for critic verification: " .. name)
end

local function destroyVehicle(model: Model, entityId: string)
	VehicleServer.onEntityDestroyed(entityId)
	if model.Parent ~= nil then
		model:Destroy()
	end
end

local function computePenetrationAtPoint(point: Vector3, ignore: Instance): number
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { ignore }
	params.IgnoreWater = true

	local probeHeight = 12
	local result = Workspace:Raycast(point + Vector3.new(0, probeHeight, 0), Vector3.new(0, -probeHeight * 2.5, 0), params)
	if result == nil then
		return 0
	end
	return math.max(0, probeHeight - result.Distance)
end

local function maxHoverPenetration(state: VehicleRuntimeState): number
	local maxPen = 0
	for _, hp in ipairs(state.hoverPoints) do
		local pen = computePenetrationAtPoint(hp.Position, state.instance)
		if pen > maxPen then
			maxPen = pen
		end
	end
	return maxPen
end

local function scenarioCrestLock(folder: Folder): ScenarioResult
	newPart(
		folder,
		"CrestBase",
		Vector3.new(320, 2, 160),
		CFrame.new(ORIGIN + Vector3.new(120, -1, 0)),
		true,
		true,
		0
	)
	newPart(
		folder,
		"CrestUphill",
		Vector3.new(120, 4, 60),
		CFrame.new(ORIGIN + Vector3.new(0, 30, 0)) * CFrame.Angles(0, 0, math.rad(25)),
		true,
		true,
		0
	)
	newPart(
		folder,
		"CrestDownhill",
		Vector3.new(120, 4, 60),
		CFrame.new(ORIGIN + Vector3.new(120, 7, 0)) * CFrame.Angles(0, 0, math.rad(-55)),
		true,
		true,
		0
	)

	local spawn = CFrame.lookAt(ORIGIN + Vector3.new(-70, 14, 0), ORIGIN + Vector3.new(-69, 14, 0))
	local model, state, entityId = registerSpeeder(folder, "crest", spawn)

	state.inputThrottle = 1
	state.inputSteerX = 0

	local elapsed = 0
	local maxX = model.PrimaryPart.Position.X
	local crestCrossed = false
	local crestStall = 0
	while elapsed < 7.5 do
		task.wait(0.05)
		elapsed += 0.05
		local pos = model.PrimaryPart.Position
		local speed = Vector3.new(state.velocity.X, 0, state.velocity.Z).Magnitude
		maxX = math.max(maxX, pos.X)
		if pos.X >= (ORIGIN.X + 78) then
			crestCrossed = true
		end
		local atCrestBand = pos.X >= (ORIGIN.X + 52) and pos.X <= (ORIGIN.X + 72)
		if atCrestBand and speed < 2.5 then
			crestStall += 0.05
		else
			crestStall = math.max(0, crestStall - 0.025)
		end
	end

	state.inputThrottle = 0
	destroyVehicle(model, entityId)

	local passed = crestCrossed and crestStall < 1.0
	return {
		name = "crest_lock",
		passed = passed,
		detail = string.format("crossed=%s maxX=%.1f stall=%.2f", tostring(crestCrossed), maxX - ORIGIN.X, crestStall),
	}
end

local function scenarioUphillSink(folder: Folder): ScenarioResult
	newPart(
		folder,
		"SinkBase",
		Vector3.new(300, 2, 200),
		CFrame.new(ORIGIN + Vector3.new(500, -1, 0)),
		true,
		true,
		0
	)
	newPart(
		folder,
		"SinkRamp",
		Vector3.new(180, 4, 70),
		CFrame.new(ORIGIN + Vector3.new(500, 65, 0)) * CFrame.Angles(0, 0, math.rad(35)),
		true,
		true,
		0
	)

	local spawn = CFrame.lookAt(ORIGIN + Vector3.new(410, 16, 0), ORIGIN + Vector3.new(411, 16, 0))
	local model, state, entityId = registerSpeeder(folder, "uphill_sink", spawn)
	state.inputThrottle = 1
	state.inputSteerX = 0

	local elapsed = 0
	local maxPen = 0
	local voidFall = false
	while elapsed < 7 do
		task.wait(0.05)
		elapsed += 0.05
		maxPen = math.max(maxPen, maxHoverPenetration(state))
		if model.PrimaryPart.Position.Y < -30 then
			voidFall = true
			break
		end
	end

	state.inputThrottle = 0
	destroyVehicle(model, entityId)

	local passed = (not voidFall) and maxPen < 0.22
	return {
		name = "uphill_sink",
		passed = passed,
		detail = string.format("maxPen=%.3f void=%s", maxPen, tostring(voidFall)),
	}
end

local function scenarioCliffLanding(folder: Folder): ScenarioResult
	newPart(
		folder,
		"CliffPlatform",
		Vector3.new(70, 2, 70),
		CFrame.new(ORIGIN + Vector3.new(900, 54, 0)),
		true,
		true,
		0
	)
	newPart(
		folder,
		"CliffLanding",
		Vector3.new(500, 2, 220),
		CFrame.new(ORIGIN + Vector3.new(1060, -1, 0)),
		true,
		true,
		0
	)

	local spawn = CFrame.lookAt(ORIGIN + Vector3.new(872, 60, 0), ORIGIN + Vector3.new(873, 60, 0))
	local model, state, entityId = registerSpeeder(folder, "cliff_land", spawn)
	state.inputThrottle = 1
	state.inputSteerX = 0

	local elapsed = 0
	local sawAir = false
	local sawLand = false
	local voidFall = false
	while elapsed < 9 do
		task.wait(0.05)
		elapsed += 0.05

		if state.isAirborne then
			sawAir = true
		elseif sawAir then
			sawLand = true
		end
		if model.PrimaryPart.Position.Y < -35 then
			voidFall = true
			break
		end
	end

	state.inputThrottle = 0
	destroyVehicle(model, entityId)

	local passed = sawAir and sawLand and (not voidFall)
	return {
		name = "cliff_landing",
		passed = passed,
		detail = string.format("air=%s land=%s void=%s", tostring(sawAir), tostring(sawLand), tostring(voidFall)),
	}
end

local function scenarioStopOnUphill(folder: Folder): ScenarioResult
	newPart(
		folder,
		"StopBase",
		Vector3.new(260, 2, 200),
		CFrame.new(ORIGIN + Vector3.new(1400, -1, 0)),
		true,
		true,
		0
	)
	newPart(
		folder,
		"StopRamp",
		Vector3.new(170, 4, 70),
		CFrame.new(ORIGIN + Vector3.new(1400, 53, 0)) * CFrame.Angles(0, 0, math.rad(30)),
		true,
		true,
		0
	)

	local spawn = CFrame.lookAt(ORIGIN + Vector3.new(1325, 18, 0), ORIGIN + Vector3.new(1326, 18, 0))
	local model, state, entityId = registerSpeeder(folder, "stop_uphill", spawn)

	state.inputThrottle = 1
	state.inputSteerX = 0
	task.wait(2.8)
	state.inputThrottle = 0

	local elapsed = 0
	local airborneTime = 0
	local maxPen = 0
	local voidFall = false
	while elapsed < 4 do
		task.wait(0.05)
		elapsed += 0.05
		maxPen = math.max(maxPen, maxHoverPenetration(state))
		if state.isAirborne then
			airborneTime += 0.05
		end
		if model.PrimaryPart.Position.Y < -30 then
			voidFall = true
			break
		end
	end

	destroyVehicle(model, entityId)

	local passed = (not voidFall) and airborneTime < 1 and maxPen < 0.22
	return {
		name = "stop_on_uphill",
		passed = passed,
		detail = string.format("airborne=%.2f maxPen=%.3f void=%s", airborneTime, maxPen, tostring(voidFall)),
	}
end

function Pass5CriticVerify.run(): { overallPass: boolean, results: { ScenarioResult } }
	local folder = Instance.new("Folder")
	folder.Name = "P5CriticVerify"
	folder.Parent = Workspace

	local results: { ScenarioResult } = {}
	local ok, err = pcall(function()
		table.insert(results, scenarioCrestLock(folder))
		table.insert(results, scenarioUphillSink(folder))
		table.insert(results, scenarioCliffLanding(folder))
		table.insert(results, scenarioStopOnUphill(folder))
	end)

	if not ok then
		table.insert(results, {
			name = "runtime_error",
			passed = false,
			detail = tostring(err),
		})
	end

	local overallPass = true
	for _, result in ipairs(results) do
		print(string.format("[P5_CRIT] scenario=%s result=%s detail=%s", result.name, if result.passed then "PASS" else "FAIL", result.detail))
		if not result.passed then
			overallPass = false
		end
	end

	print(string.format("[P5_CRIT_SUMMARY] result=%s scenarios=%d", if overallPass then "PASS" else "FAIL", #results))
	folder:Destroy()
	return {
		overallPass = overallPass,
		results = results,
	}
end

return Pass5CriticVerify
