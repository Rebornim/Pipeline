--!strict

local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Debris = game:GetService("Debris")
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
local VehicleCamera = require(clientRoot:WaitForChild("Vehicles"):WaitForChild("VehicleCamera"))
local VehicleVisualSmoother = require(clientRoot:WaitForChild("Vehicles"):WaitForChild("VehicleVisualSmoother"))
local RemoteVehicleSmoother = require(clientRoot:WaitForChild("Vehicles"):WaitForChild("RemoteVehicleSmoother"))
type VehicleConfig = CombatTypes.VehicleConfig
type VehicleInputPayload = CombatTypes.VehicleInputPayload

local VehicleClient = {}

local EXIT_ACTION_NAME = "CombatExitVehicle"

local vehicleInputRemote: RemoteEvent? = nil
local vehicleExitRemote: RemoteEvent? = nil
local seatConnection: RBXScriptConnection? = nil
local characterAddedConnection: RBXScriptConnection? = nil
local inputConnection: RBXScriptConnection? = nil
local scrollConnection: RBXScriptConnection? = nil
local landingShakeConnection: RBXScriptConnection? = nil

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
local hoverDustEmitters: { { part: BasePart, emitter: ParticleEmitter } } = {}
local dustRayParams: RaycastParams? = nil
local currentDustColor: Color3? = nil
local DUST_MAX_LIFETIME = 1.6

-- Damage smoke
local damageSmokeEmitter: ParticleEmitter? = nil
local DAMAGE_SMOKE_START = 0.6 -- HP fraction where smoke begins
local DAMAGE_SMOKE_FULL = 0.2 -- HP fraction where smoke is at max


local TERRAIN_DUST_COLORS: { [Enum.Material]: Color3 } = {
	[Enum.Material.Grass] = Color3.fromRGB(120, 140, 80),
	[Enum.Material.LeafyGrass] = Color3.fromRGB(100, 130, 60),
	[Enum.Material.Sand] = Color3.fromRGB(194, 178, 128),
	[Enum.Material.Sandstone] = Color3.fromRGB(180, 160, 120),
	[Enum.Material.Ground] = Color3.fromRGB(140, 120, 90),
	[Enum.Material.Mud] = Color3.fromRGB(90, 70, 50),
	[Enum.Material.Rock] = Color3.fromRGB(140, 135, 130),
	[Enum.Material.Slate] = Color3.fromRGB(130, 130, 135),
	[Enum.Material.Basalt] = Color3.fromRGB(80, 80, 85),
	[Enum.Material.Snow] = Color3.fromRGB(220, 225, 230),
	[Enum.Material.Ice] = Color3.fromRGB(200, 215, 230),
	[Enum.Material.Glacier] = Color3.fromRGB(190, 210, 225),
	[Enum.Material.Salt] = Color3.fromRGB(230, 230, 225),
	[Enum.Material.Concrete] = Color3.fromRGB(165, 160, 155),
	[Enum.Material.Pavement] = Color3.fromRGB(155, 150, 145),
	[Enum.Material.Asphalt] = Color3.fromRGB(100, 100, 100),
	[Enum.Material.Limestone] = Color3.fromRGB(190, 185, 170),
	[Enum.Material.CrackedLava] = Color3.fromRGB(60, 40, 35),
	[Enum.Material.Metal] = Color3.fromRGB(160, 155, 150),
	[Enum.Material.DiamondPlate] = Color3.fromRGB(160, 155, 150),
	[Enum.Material.WoodPlanks] = Color3.fromRGB(130, 100, 65),
	[Enum.Material.Wood] = Color3.fromRGB(130, 100, 65),
	[Enum.Material.Brick] = Color3.fromRGB(150, 100, 80),
}
local DEFAULT_DUST_COLOR = Color3.fromRGB(180, 160, 130)

local function getVehicleInputRate(): number
	local raw = CombatConfig.VehicleInputRate
	if type(raw) ~= "number" or raw <= 0 then
		return 30
	end
	return raw
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
	local aDown = UserInputService:IsKeyDown(Enum.KeyCode.A)
	local dDown = UserInputService:IsKeyDown(Enum.KeyCode.D)
	if aDown and not dDown then
		lean = -1
	elseif dDown and not aDown then
		lean = 1
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

	return {
		throttle = throttle,
		steerX = steerX,
		lean = lean,
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
		-- Full centering at 0%, fades to zero at 50%, none beyond 50%
		local centerStrengthX = math.clamp(1 - deflectionX / 0.5, 0, 1)
		local centerStrengthY = math.clamp(1 - deflectionY / 0.5, 0, 1)
		local centerAlpha = 1 - math.exp(-centeringRate * dt)
		virtualCursorX -= virtualCursorX * centerAlpha * centerStrengthX
		virtualCursorY -= virtualCursorY * centerAlpha * centerStrengthY

		local screenCenter = camera.ViewportSize * 0.5
		CombatHUD.setCursorDotPosition(Vector2.new(screenCenter.X + virtualCursorX, screenCenter.Y + virtualCursorY))
	end
end

local function setupDamageSmoke(renderModel: Model)
	local primary = renderModel.PrimaryPart
	if primary == nil then
		return
	end
	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = "rbxassetid://716847870"
	emitter.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(40, 40, 40)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(20, 20, 20)),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4),
		NumberSequenceKeypoint.new(0.4, 0.6),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(0.3, 2.0),
		NumberSequenceKeypoint.new(1, 4.0),
	})
	emitter.Lifetime = NumberRange.new(1.0, 2.0)
	emitter.Speed = NumberRange.new(2, 6)
	emitter.SpreadAngle = Vector2.new(30, 30)
	emitter.Drag = 1
	emitter.Rate = 0
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.LightEmission = 0
	emitter.Parent = primary
	damageSmokeEmitter = emitter
end

local function cleanupDamageSmoke()
	if damageSmokeEmitter ~= nil then
		damageSmokeEmitter:Destroy()
		damageSmokeEmitter = nil
	end
end

local function updateDamageSmoke()
	local emitter = damageSmokeEmitter
	if emitter == nil then
		return
	end
	local model = activeVehicleModel
	if model == nil then
		emitter.Rate = 0
		return
	end
	local hullHP = model:GetAttribute("HullHP")
	local maxHP = model:GetAttribute("MaxHullHP")
	if type(hullHP) ~= "number" or type(maxHP) ~= "number" or maxHP <= 0 then
		emitter.Rate = 0
		return
	end
	local fraction = hullHP / maxHP
	if fraction >= DAMAGE_SMOKE_START then
		emitter.Rate = 0
		return
	end
	-- Scale from 0 at DAMAGE_SMOKE_START to 1 at DAMAGE_SMOKE_FULL
	local intensity = math.clamp((DAMAGE_SMOKE_START - fraction) / (DAMAGE_SMOKE_START - DAMAGE_SMOKE_FULL), 0, 1)
	emitter.Rate = intensity * 15
end

local function exitVehicleMode()
	if inputConnection ~= nil then
		inputConnection:Disconnect()
		inputConnection = nil
	end
	ContextActionService:UnbindAction(EXIT_ACTION_NAME)
	if scrollConnection ~= nil then
		scrollConnection:Disconnect()
		scrollConnection = nil
	end

	VehicleVisualSmoother.deactivate()
	RemoteVehicleSmoother.setLocalVehicle(nil)
	VehicleCamera.deactivate()
	restoreVehicleMouse()
	if landingShakeConnection ~= nil then
		landingShakeConnection:Disconnect()
		landingShakeConnection = nil
	end
	CombatHUD.showVehicleCursor(false)
	cleanupDamageSmoke()

	CombatHUD.hideHP()
	CombatHUD.showSpeed(false)

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
	hoverDustEmitters = {}
	currentDustColor = nil
end

local function createDustEmitter(parent: BasePart, color: Color3): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = "rbxassetid://716847870"
	emitter.Color = ColorSequence.new(color)
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.6),
		NumberSequenceKeypoint.new(0.3, 0.7),
		NumberSequenceKeypoint.new(0.7, 0.85),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.0),
		NumberSequenceKeypoint.new(0.3, 3.0),
		NumberSequenceKeypoint.new(0.7, 4.5),
		NumberSequenceKeypoint.new(1, 3.0),
	})
	emitter.Lifetime = NumberRange.new(0.8, 1.6)
	emitter.Speed = NumberRange.new(3, 8)
	emitter.SpreadAngle = Vector2.new(50, 50)
	emitter.Drag = 3
	emitter.Rate = 0
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.LightEmission = 0.1
	emitter.Parent = parent
	return emitter
end

local function setupHoverDustEmitters(renderModel: Model)
	hoverDustEmitters = {}
	currentDustColor = DEFAULT_DUST_COLOR
	for _, descendant in ipairs(renderModel:GetDescendants()) do
		if descendant:IsA("BasePart") and CollectionService:HasTag(descendant, "HoverPoint") then
			local emitter = createDustEmitter(descendant, DEFAULT_DUST_COLOR)
			table.insert(hoverDustEmitters, { part = descendant, emitter = emitter })
		end
	end
end

local function fireDustKick(leanDirection: number, emitCount: number)
	local renderModel = activeVehicleRenderModel
	if renderModel == nil or #hoverDustEmitters == 0 then
		return
	end
	local modelCFrame = renderModel:GetPivot()
	for _, entry in ipairs(hoverDustEmitters) do
		if entry.part.Parent == nil then
			continue
		end
		local localPos = modelCFrame:PointToObjectSpace(entry.part.Position)
		-- Outer points: lean right (1) = left side (-X) is outer, lean left (-1) = right side (+X) is outer
		local isOuter = (leanDirection > 0 and localPos.X < -0.3) or (leanDirection < 0 and localPos.X > 0.3)
		if isOuter then
			entry.emitter:Emit(emitCount)
		end
	end
end

local function updateHoverDust()
	local renderModel = activeVehicleRenderModel
	if renderModel == nil or #hoverDustEmitters == 0 then
		return
	end

	local speedAttr = renderModel:GetAttribute("VehicleSpeed")
	local speed = if type(speedAttr) == "number" then speedAttr else 0

	if dustRayParams == nil then
		dustRayParams = RaycastParams.new()
		dustRayParams.FilterType = Enum.RaycastFilterType.Exclude
	end
	local filter: { Instance } = { renderModel }
	local srcModel = activeVehicleModel
	if srcModel ~= nil then
		table.insert(filter, srcModel)
	end
	local character = localPlayer.Character
	if character ~= nil then
		table.insert(filter, character)
	end
	dustRayParams.FilterDescendantsInstances = filter

	local origin = renderModel:GetPivot().Position
	local result = Workspace:Raycast(origin, Vector3.new(0, -20, 0), dustRayParams)
	local material = if result ~= nil then result.Material else nil
	local dustColor = if material ~= nil then (TERRAIN_DUST_COLORS[material] or DEFAULT_DUST_COLOR) else DEFAULT_DUST_COLOR

	local colorChanged = currentDustColor == nil or dustColor.R ~= currentDustColor.R or dustColor.G ~= currentDustColor.G or dustColor.B ~= currentDustColor.B

	local rate = math.clamp(speed / 6, 0, 20)
	if colorChanged then
		currentDustColor = dustColor
		for _, entry in ipairs(hoverDustEmitters) do
			if entry.part.Parent == nil then
				continue
			end
			-- Retire old emitter: stop emitting, let existing particles die
			local oldEmitter = entry.emitter
			oldEmitter.Rate = 0
			Debris:AddItem(oldEmitter, DUST_MAX_LIFETIME)
			-- Spawn fresh emitter with new color
			local newEmitter = createDustEmitter(entry.part, dustColor)
			newEmitter.Rate = rate
			entry.emitter = newEmitter
		end
	else
		for _, entry in ipairs(hoverDustEmitters) do
			if entry.emitter.Parent ~= nil then
				entry.emitter.Rate = rate
			end
		end
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
	if activeVehicleRenderModel ~= nil then
		setupHoverDustEmitters(activeVehicleRenderModel)
		setupDamageSmoke(activeVehicleRenderModel)
	end
	local shakeModel = activeVehicleRenderModel or vehicleModel
	landingShakeConnection = shakeModel:GetAttributeChangedSignal("VehicleLandingImpact"):Connect(function()
		local impactSpeed = shakeModel:GetAttribute("VehicleLandingImpact")
		if type(impactSpeed) ~= "number" or impactSpeed <= 0 then
			return
		end
		local cfg = activeVehicleConfig
		if cfg == nil then
			return
		end
		local threshold = cfg.landingShakeThreshold
		local intensity = cfg.landingShakeIntensity
		local fraction = math.clamp((impactSpeed - threshold) / math.max(1, cfg.fallDamageThreshold - threshold), 0, 1)
		local amplitude = fraction * intensity
		if amplitude > 0.01 then
			VehicleCamera.pushShake(amplitude, 0.2)
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
		updateHoverDust()
		updateDamageSmoke()
		local payload = readInputPayload()
		VehicleCamera.setLeanInput(payload.lean)
		-- Lean entry effects
		if previousClientLean == 0 and payload.lean ~= 0 then
			local speedAttr = activeVehicleRenderModel and activeVehicleRenderModel:GetAttribute("VehicleSpeed")
			local currentSpeed = if type(speedAttr) == "number" then speedAttr else 0
			if currentSpeed > 15 and activeVehicleConfig ~= nil then
				VehicleCamera.pushShake(activeVehicleConfig.leanShakeAmplitude, activeVehicleConfig.leanShakeDuration)
				fireDustKick(payload.lean, activeVehicleConfig.leanDustEmitCount)
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

	CombatHUD.showHP(entityId)
	CombatHUD.showSpeed(true)
	CombatHUD.showCrosshair(false)
	CombatHUD.showVehicleCursor(true)
	CombatHUD.showHeat(false)
	CombatHUD.showAmmo(false)
	CombatHUD.showShield(false)
	updateSpeedHud()
end

local function onSeatChanged(humanoid: Humanoid)
	local seatPart = humanoid.SeatPart
	if seatPart ~= nil and CollectionService:HasTag(seatPart, "DriverSeat") then
		local vehicleModel = findVehicleModelFromSeat(seatPart)
		if vehicleModel ~= nil then
			local entityId = vehicleModel:GetAttribute("EntityId")
			local vehicleConfigId = vehicleModel:GetAttribute("VehicleConfigId")
			if type(entityId) == "string" and type(vehicleConfigId) == "string" then
				local config = CombatConfig.Vehicles[vehicleConfigId]
				if type(config) == "table" then
					enterVehicleMode(entityId, vehicleModel, config :: VehicleConfig)
					return
				end
			end
		end
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

	if characterAddedConnection == nil then
		characterAddedConnection = localPlayer.CharacterAdded:Connect(bindCharacter)
	end

	local existingCharacter = localPlayer.Character
	if existingCharacter ~= nil then
		bindCharacter(existingCharacter)
	end
end

return VehicleClient
