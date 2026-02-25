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

local sharedRoot = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatConfig = require(sharedRoot:WaitForChild("CombatConfig"))
local CombatTypes = require(sharedRoot:WaitForChild("CombatTypes"))

local CombatHUD = require(clientRoot:WaitForChild("HUD"):WaitForChild("CombatHUD"))
local RemoteVehicleSmoother = require(clientRoot:WaitForChild("Vehicles"):WaitForChild("RemoteVehicleSmoother"))
local VehicleCamera = require(clientRoot:WaitForChild("Vehicles"):WaitForChild("VehicleCamera"))
local SoundProfileLoader = require(clientRoot:WaitForChild("Vehicles"):WaitForChild("SoundProfiles"):WaitForChild("SoundProfileLoader"))
local SoundProfileTypes = require(clientRoot:WaitForChild("Vehicles"):WaitForChild("SoundProfiles"):WaitForChild("SoundProfileTypes"))

type VehicleConfig = CombatTypes.VehicleConfig

local FighterClient = {}

local EXIT_ACTION_NAME = "CombatExitFighter"
local FIGHTER_CURSOR_CIRCLE_SCALE = 1.15
local FIGHTER_TIME_TO_MAX_SPEED = 1.0
local FIGHTER_NOSE_UP_PITCH_RATE_BOOST = 1.25
local FIGHTER_NOSE_UP_ALIGN_BOOST = 1.35
local LANDING_ENTRY_MIN_SPEED = 90
local LANDING_ENTRY_MAX_SPEED = 100
local LANDING_SEQUENCE_MAX_SPEED = 50
local LANDING_VERTICAL_SPEED = 16
local LANDING_VERTICAL_ACCEL = 70
local LANDING_HORIZONTAL_DAMPING = 2.2
local LANDING_STOP_BRAKE = 220
local LANDING_STOP_SPEED_THRESHOLD = 4
local LANDING_GROUND_CLEARANCE = 1.1
local LANDING_ENTRY_IDLE_CLEARANCE = 2.0
local LANDING_ENTRY_LIFT_DURATION = 0.25
local LANDING_ENTRY_RAY_HEIGHT = 10
local LANDING_ENTRY_RAY_LENGTH = 40

local vehicleExitRemote: RemoteEvent? = nil
local renderConnection: RBXScriptConnection? = nil
local scrollConnection: RBXScriptConnection? = nil
local seatOccupantConnection: RBXScriptConnection? = nil
local focusLostConnection: RBXScriptConnection? = nil
local focusGainedConnection: RBXScriptConnection? = nil

local activeEntityId: string? = nil
local activeModel: Model? = nil
local activeConfig: VehicleConfig? = nil
local activeDriverSeat: BasePart? = nil
local virtualCursorX = 0
local virtualCursorY = 0
local displayedCursorX = 0
local displayedCursorY = 0
local freelookActive = false

local savedMouseBehavior: Enum.MouseBehavior? = nil
local savedMouseIconEnabled: boolean? = nil
local windowFocused = true

local activeProfileController: SoundProfileTypes.ProfileController? = nil
local inlineEngineLoop: Sound? = nil

-- Flight physics state (persistent across frames)
local currentSpeed: number = 0
local smoothedThrottleInput: number = 0
local physicalVelocity: Vector3 = Vector3.zero
local physicsOrientation: CFrame = CFrame.new()
local visualOrientation: CFrame = CFrame.new()
local autoRollVisualDeg: number = 0
local visualYawOverDeg: number = 0
local visualPitchOverDeg: number = 0
local visualRollOverDeg: number = 0
local previousVisualYawRate: number = 0
local previousVisualPitchRate: number = 0
local smoothedPitchRate: number = 0
local smoothedYawRate: number = 0
local smoothedRollRate: number = 0
local smoothedPitchAccel: number = 0
local smoothedYawAccel: number = 0
local smoothedRollAccel: number = 0
local smoothedForwardAccel: number = 0
local filteredYawInput: number = 0
local filteredPitchInput: number = 0
local yawInputHysteresisActive: boolean = false
local pitchInputHysteresisActive: boolean = false
local bodyVelocity: BodyVelocity? = nil
local bodyGyro: BodyGyro? = nil
local vectorForce: VectorForce? = nil
local useForceFlight: boolean = false
local takeoffActive: boolean = false
local takeoffRemaining: number = 0
local takeoffTargetY: number = 0
local takeoffLiftSpeed: number = 0
local landingSequenceActive: boolean = false
local landingToggleHeld: boolean = false
local flightRayParams: RaycastParams? = nil
local lastDebugPrintTick: number = 0

local function getFighterSounds(): any
	local sounds = CombatConfig.FighterSounds
	if type(sounds) ~= "table" then
		return {}
	end
	return sounds
end

local function isUsableSoundId(value: any): boolean
	return type(value) == "string" and value ~= "" and value ~= "rbxassetid://0"
end

local function playOneShot(soundId: any, parent: Instance)
	if not isUsableSoundId(soundId) then
		return
	end
	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Looped = false
	sound.Volume = 0.8
	sound.Parent = parent
	sound.Ended:Connect(function()
		sound:Destroy()
	end)
	sound:Play()
end

local function findDriverSeat(model: Model): BasePart?
	for _, descendant in ipairs(model:GetDescendants()) do
		if (descendant:IsA("Seat") or descendant:IsA("VehicleSeat")) and CollectionService:HasTag(descendant, "DriverSeat") then
			return descendant :: BasePart
		end
	end
	return nil
end

local function isLocalPilotStillValid(): boolean
	local model = activeModel
	local seat = activeDriverSeat
	if model == nil or seat == nil then
		return false
	end
	if model.Parent == nil or seat.Parent == nil then
		return false
	end
	local character = localPlayer.Character
	if character == nil then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil or humanoid.Health <= 0 then
		return false
	end
	return humanoid.SeatPart == seat
end

local function setLocalPilotControl(enabled: boolean)
	local character = localPlayer.Character
	if character == nil then
		return
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp ~= nil and hrp:IsA("BasePart") and enabled then
		local rootPart = hrp :: BasePart
		rootPart.AssemblyLinearVelocity = Vector3.zero
		rootPart.AssemblyAngularVelocity = Vector3.zero
	end
end

local function activateMouse()
	savedMouseBehavior = UserInputService.MouseBehavior
	savedMouseIconEnabled = UserInputService.MouseIconEnabled
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	UserInputService.MouseIconEnabled = false
	virtualCursorX = 0
	virtualCursorY = 0
	displayedCursorX = 0
	displayedCursorY = 0
end

local function restoreMouse()
	UserInputService.MouseBehavior = savedMouseBehavior or Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = if savedMouseIconEnabled ~= nil then savedMouseIconEnabled else true
	savedMouseBehavior = nil
	savedMouseIconEnabled = nil
end

local function onExitAction(_name: string, inputState: Enum.UserInputState, _inputObject: InputObject): Enum.ContextActionResult
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	if vehicleExitRemote ~= nil and activeEntityId ~= nil then
		vehicleExitRemote:FireServer()
	end
	return Enum.ContextActionResult.Sink
end

local function cleanupAudio(playShutdown: boolean)
	if activeProfileController ~= nil then
		activeProfileController:destroy()
		activeProfileController = nil
	end
	if inlineEngineLoop ~= nil then
		local parent = inlineEngineLoop.Parent
		if playShutdown and parent ~= nil then
			playOneShot(getFighterSounds().shutdown, parent)
		end
		inlineEngineLoop:Destroy()
		inlineEngineLoop = nil
	end
end

local function setupAudio(model: Model, config: VehicleConfig)
	cleanupAudio(false)
	local primaryPart = model.PrimaryPart
	if primaryPart == nil then
		return
	end

	activeProfileController = SoundProfileLoader.createController(model, primaryPart, config.maxSpeed, true)
	if activeProfileController ~= nil then
		return
	end

	local sounds = getFighterSounds()
	if isUsableSoundId(sounds.engineLoop) then
		local loopSound = Instance.new("Sound")
		loopSound.Name = "FighterEngineLoop"
		loopSound.SoundId = sounds.engineLoop
		loopSound.Looped = true
		loopSound.Volume = 0.35
		loopSound.RollOffMode = Enum.RollOffMode.InverseTapered
		loopSound.RollOffMinDistance = 40
		loopSound.RollOffMaxDistance = 1200
		loopSound.PlaybackSpeed = 0.9
		loopSound.Parent = primaryPart
		loopSound:Play()
		inlineEngineLoop = loopSound
	end

	playOneShot(sounds.startup, primaryPart)
end

local function updateAudio(dt: number, speed: number, maxSpeed: number, throttle: number, yawInput: number)
	if activeProfileController ~= nil then
		local speedFrac = if maxSpeed > 0 then math.clamp(speed / maxSpeed, 0, 1) else 0
		local frameState: SoundProfileTypes.VehicleFrameState = {
			speed = speed,
			maxSpeed = maxSpeed,
			speedFraction = speedFrac,
			hpFraction = 1,
			isBoosting = false,
			isGrounded = false,
			throttle = throttle,
			steerInput = yawInput,
			isLocal = true,
			dt = dt,
		}
		activeProfileController:update(dt, frameState)
		return
	end

	if inlineEngineLoop ~= nil then
		local speedFrac = if maxSpeed > 0 then math.clamp(speed / maxSpeed, 0, 1) else 0
		inlineEngineLoop.PlaybackSpeed = 0.85 + speedFrac * 0.55
		inlineEngineLoop.Volume = 0.25 + speedFrac * 0.35
	end
end

local function extractRollAngle(cf: CFrame): number
	return math.atan2(-cf.RightVector.Y, cf.UpVector.Y)
end

local function applySignedExpo(value: number, exponent: number): number
	if exponent <= 0 or exponent == 1 then
		return value
	end
	local magnitude = math.abs(value)
	if magnitude <= 0 then
		return 0
	end
	return math.sign(value) * (magnitude ^ exponent)
end

local function updateCursorAndInputs(dt: number, config: VehicleConfig): (number, number, number, number)
	if not windowFocused then
		virtualCursorX = 0
		virtualCursorY = 0
		displayedCursorX = 0
		displayedCursorY = 0
		smoothedPitchRate = 0
		smoothedYawRate = 0
		smoothedRollRate = 0
		smoothedPitchAccel = 0
		smoothedYawAccel = 0
		smoothedRollAccel = 0
		smoothedForwardAccel = 0
		previousVisualYawRate = 0
		previousVisualPitchRate = 0
		autoRollVisualDeg = 0
		visualYawOverDeg = 0
		visualPitchOverDeg = 0
		visualRollOverDeg = 0
		filteredYawInput = 0
		filteredPitchInput = 0
		yawInputHysteresisActive = false
		pitchInputHysteresisActive = false
		local camera = Workspace.CurrentCamera
		if camera ~= nil then
			CombatHUD.setCursorDotPosition(camera.ViewportSize * 0.5)
		end
		return 0, 0, 0, 0
	end

	if not freelookActive then
		local mouseDelta = UserInputService:GetMouseDelta()
		local sensitivity = config.fighterMouseSensitivity
		if type(sensitivity) ~= "number" then
			sensitivity = 0.5
		end
		virtualCursorX += mouseDelta.X * sensitivity * 0.01
		virtualCursorY += mouseDelta.Y * sensitivity * 0.01

		local rangeX = config.fighterMouseRangeX
		if type(rangeX) ~= "number" or rangeX <= 0 then
			rangeX = 1.0
		end
		local rangeY = config.fighterMouseRangeY
		if type(rangeY) ~= "number" or rangeY <= 0 then
			rangeY = 0.8
		end
		local circleRadius = math.max(rangeX, rangeY) * FIGHTER_CURSOR_CIRCLE_SCALE
		local distSq = virtualCursorX * virtualCursorX + virtualCursorY * virtualCursorY
		if distSq > circleRadius * circleRadius then
			local scale = circleRadius / math.sqrt(distSq)
			virtualCursorX *= scale
			virtualCursorY *= scale
		end

		local autoCenter = config.fighterMouseAutoCenter
		if type(autoCenter) ~= "number" or autoCenter < 0 then
			autoCenter = 3.0
		end
		local deadzone = config.fighterMouseDeadzone
		if type(deadzone) ~= "number" or deadzone < 0 then
			deadzone = 0.06
		end

		local nearCenterRadius = config.fighterMouseCenterReturnRadius
		if type(nearCenterRadius) ~= "number" or nearCenterRadius <= 0 then
			nearCenterRadius = math.max(deadzone * 0.35, 0.02)
		end
		local cursorDistSq = virtualCursorX * virtualCursorX + virtualCursorY * virtualCursorY
		if cursorDistSq <= nearCenterRadius * nearCenterRadius then
			local centerAlpha = 1 - math.exp(-autoCenter * dt)
			virtualCursorX = virtualCursorX * (1 - centerAlpha)
			virtualCursorY = virtualCursorY * (1 - centerAlpha)
			if math.abs(virtualCursorX) < deadzone * 0.5 then
				virtualCursorX = 0
			end
			if math.abs(virtualCursorY) < deadzone * 0.5 then
				virtualCursorY = 0
			end
		end
	end

	local throttle = 0
	if UserInputService:IsKeyDown(Enum.KeyCode.W) then
		throttle = 1
	elseif UserInputService:IsKeyDown(Enum.KeyCode.S) then
		throttle = -1
	end

	local rollInput = 0
	local aDown = UserInputService:IsKeyDown(Enum.KeyCode.A)
	local dDown = UserInputService:IsKeyDown(Enum.KeyCode.D)
	if aDown and not dDown then
		rollInput = 1
	elseif dDown and not aDown then
		rollInput = -1
	end

	local rangeX = config.fighterMouseRangeX
	if type(rangeX) ~= "number" or rangeX <= 0 then
		rangeX = 1.0
	end
	local rangeY = config.fighterMouseRangeY
	if type(rangeY) ~= "number" or rangeY <= 0 then
		rangeY = 0.8
	end
	local circleRadius = math.max(rangeX, rangeY) * FIGHTER_CURSOR_CIRCLE_SCALE
	local deadzone = config.fighterMouseDeadzone
	if type(deadzone) ~= "number" or deadzone < 0 then
		deadzone = 0.06
	end

	local yawInput = 0
	local pitchInput = 0
	local cursorDistSq = virtualCursorX * virtualCursorX + virtualCursorY * virtualCursorY
	if cursorDistSq >= deadzone * deadzone then
		yawInput = math.clamp(-virtualCursorX / circleRadius, -1, 1)
		pitchInput = math.clamp(-virtualCursorY / circleRadius, -1, 1)
		local inputExpo = config.fighterInputExpo
		if type(inputExpo) ~= "number" or inputExpo <= 0 then
			inputExpo = 1.35
		end
		yawInput = math.clamp(applySignedExpo(yawInput, inputExpo), -1, 1)
		pitchInput = math.clamp(applySignedExpo(pitchInput, inputExpo), -1, 1)
	end

	if freelookActive then
		yawInput = 0
		pitchInput = 0
		filteredYawInput = 0
		filteredPitchInput = 0
		yawInputHysteresisActive = false
		pitchInputHysteresisActive = false
	end

	local camera = Workspace.CurrentCamera
	if camera ~= nil then
		local center = camera.ViewportSize * 0.5
		local maxPixelRadius = math.min(300, math.max(1, math.min(center.X, center.Y) - 24))
		local cursorLagRate = config.fighterCursorLagRate
		if type(cursorLagRate) ~= "number" then
			cursorLagRate = 18
		end
		if cursorLagRate <= 0 then
			displayedCursorX = virtualCursorX
			displayedCursorY = virtualCursorY
		else
			local alpha = 1 - math.exp(-cursorLagRate * math.max(dt, 1 / 240))
			displayedCursorX += (virtualCursorX - displayedCursorX) * alpha
			displayedCursorY += (virtualCursorY - displayedCursorY) * alpha
		end
		local normalizedX = if circleRadius > 0 then displayedCursorX / circleRadius else 0
		local normalizedY = if circleRadius > 0 then displayedCursorY / circleRadius else 0
		CombatHUD.setCursorDotPosition(Vector2.new(
			center.X + math.clamp(normalizedX, -1, 1) * maxPixelRadius,
			center.Y + math.clamp(normalizedY, -1, 1) * maxPixelRadius
		))
	end

	return throttle, yawInput, pitchInput, rollInput
end

function FighterClient.activate(model: Model, entityId: string, config: VehicleConfig): ()
	if activeEntityId == entityId then
		return
	end

	FighterClient.deactivate()

	activeEntityId = entityId
	activeModel = model
	activeConfig = config
	activeDriverSeat = findDriverSeat(model)
	virtualCursorX = 0
	virtualCursorY = 0
	displayedCursorX = 0
	displayedCursorY = 0
	freelookActive = false
	windowFocused = true
	lastDebugPrintTick = 0

	RemoteVehicleSmoother.setLocalVehicle(model)
	activateMouse()
	setLocalPilotControl(true)
	setupAudio(model, config)

	VehicleCamera.activate(model, config)
	VehicleCamera.setEffectsEnabled(activeProfileController ~= nil)
	VehicleCamera.setExternalFOVOffset(0)

	CombatHUD.showHP(entityId)
	CombatHUD.showSpeed(true)
	CombatHUD.showCrosshair(false)
	CombatHUD.showVehicleCursor(true)
	CombatHUD.showHeat(false)
	CombatHUD.showAmmo(false)
	CombatHUD.showShield(false)
	CombatHUD.setSpeedContext(nil)
	CombatHUD.setZoomVignette(0)

	local primary = model.PrimaryPart
	if primary == nil then
		FighterClient.deactivate()
		return
	end

	bodyVelocity = primary:FindFirstChildOfClass("BodyVelocity")
	if bodyVelocity == nil then
		bodyVelocity = primary:WaitForChild("BodyVelocity", 5) :: BodyVelocity?
	end
	bodyGyro = primary:FindFirstChildOfClass("BodyGyro")
	if bodyGyro == nil then
		bodyGyro = primary:WaitForChild("BodyGyro", 5) :: BodyGyro?
	end
	local forceCandidate = primary:FindFirstChild("FighterVectorForce")
	if forceCandidate ~= nil and forceCandidate:IsA("VectorForce") then
		vectorForce = forceCandidate
	else
		vectorForce = nil
	end
	if vectorForce == nil then
		local waitedForce = primary:WaitForChild("FighterVectorForce", 2)
		if waitedForce ~= nil and waitedForce:IsA("VectorForce") then
			vectorForce = waitedForce
		end
	end

	if bodyVelocity == nil or bodyGyro == nil then
		warn("[P10_ERROR] BodyMovers not found on fighter after 5s wait")
		FighterClient.deactivate()
		return
	end

	useForceFlight = config.fighterUseForceFlight == true and vectorForce ~= nil
	if config.fighterUseForceFlight == true and vectorForce == nil then
		warn("[P10_FORCE] FighterVectorForce missing; falling back to BodyVelocity mode")
	end

	bodyVelocity.MaxForce = if useForceFlight then Vector3.zero else Vector3.new(math.huge, math.huge, math.huge)
	bodyVelocity.Velocity = Vector3.zero
	bodyGyro.MaxTorque = Vector3.new(math.huge, math.huge, math.huge)
	if vectorForce ~= nil then
		vectorForce.Enabled = useForceFlight
		vectorForce.Force = Vector3.zero
	end
	physicsOrientation = primary.CFrame - primary.CFrame.Position
	visualOrientation = physicsOrientation
	autoRollVisualDeg = 0
	visualYawOverDeg = 0
	visualPitchOverDeg = 0
	visualRollOverDeg = 0
	previousVisualYawRate = 0
	previousVisualPitchRate = 0
	currentSpeed = 0
	smoothedThrottleInput = 0
	physicalVelocity = primary.AssemblyLinearVelocity
	landingSequenceActive = false
	landingToggleHeld = false
	smoothedPitchRate = 0
	smoothedYawRate = 0
	smoothedRollRate = 0
	smoothedPitchAccel = 0
	smoothedYawAccel = 0
	smoothedRollAccel = 0
	smoothedForwardAccel = 0
	filteredYawInput = 0
	filteredPitchInput = 0
	yawInputHysteresisActive = false
	pitchInputHysteresisActive = false

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	local filter: { Instance } = { model }
	if localPlayer.Character ~= nil then
		table.insert(filter, localPlayer.Character)
	end
	rayParams.FilterDescendantsInstances = filter
	rayParams.IgnoreWater = true
	flightRayParams = rayParams

	takeoffActive = false
	takeoffRemaining = 0
	takeoffTargetY = primary.Position.Y
	takeoffLiftSpeed = 0
	landingSequenceActive = true
	currentSpeed = 0
	physicalVelocity = Vector3.zero

	local desiredIdleY = primary.Position.Y
	if flightRayParams ~= nil then
		local groundRay = Workspace:Raycast(
			primary.Position + Vector3.new(0, LANDING_ENTRY_RAY_HEIGHT, 0),
			Vector3.new(0, -LANDING_ENTRY_RAY_LENGTH, 0),
			flightRayParams
		)
		if groundRay ~= nil then
			desiredIdleY = groundRay.Position.Y + LANDING_ENTRY_IDLE_CLEARANCE
		else
			desiredIdleY = primary.Position.Y + LANDING_ENTRY_IDLE_CLEARANCE
		end
	else
		desiredIdleY = primary.Position.Y + LANDING_ENTRY_IDLE_CLEARANCE
	end
	if primary.Position.Y < desiredIdleY - 0.05 then
		takeoffActive = true
		takeoffTargetY = desiredIdleY
		takeoffRemaining = LANDING_ENTRY_LIFT_DURATION
		takeoffLiftSpeed = (desiredIdleY - primary.Position.Y) / LANDING_ENTRY_LIFT_DURATION
	end

	if activeDriverSeat ~= nil and (activeDriverSeat:IsA("Seat") or activeDriverSeat:IsA("VehicleSeat")) then
		seatOccupantConnection = activeDriverSeat:GetPropertyChangedSignal("Occupant"):Connect(function()
			if not isLocalPilotStillValid() then
				FighterClient.deactivate()
			end
		end)
	end

	renderConnection = RunService.RenderStepped:Connect(function(dt)
		if activeEntityId == nil or activeModel == nil then
			return
		end
		if not isLocalPilotStillValid() then
			FighterClient.deactivate()
			return
		end

		local mdl = activeModel :: Model
		if mdl.Parent == nil then
			FighterClient.deactivate()
			return
		end

		local cfg = activeConfig :: VehicleConfig
		local base = mdl.PrimaryPart
		if base == nil then
			FighterClient.deactivate()
			return
		end
			if lastDebugPrintTick == 0 then
				print(string.format(
					"[P10_ACTIVATE] bv=%s bg=%s vf=%s forceMode=%s maxF=%s",
					tostring(bodyVelocity ~= nil),
					tostring(bodyGyro ~= nil),
					tostring(vectorForce ~= nil),
					tostring(useForceFlight),
					tostring(if bodyVelocity ~= nil then bodyVelocity.MaxForce else "nil")
				))
			end
			if useForceFlight and (vectorForce == nil or vectorForce.Parent == nil) then
				useForceFlight = false
				if vectorForce ~= nil then
					vectorForce.Enabled = false
					vectorForce.Force = Vector3.zero
				end
				if bodyVelocity ~= nil then
					bodyVelocity.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
					bodyVelocity.Velocity = Vector3.zero
				end
				warn("[P10_FORCE] VectorForce lost during flight; falling back to BodyVelocity mode")
			end

		local altHeld = UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt)
		if altHeld and not freelookActive then
			freelookActive = true
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			UserInputService.MouseIconEnabled = true
			VehicleCamera.setFreelook(true)
			CombatHUD.showVehicleCursor(false)
		elseif not altHeld and freelookActive then
			freelookActive = false
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
			UserInputService.MouseIconEnabled = false
			VehicleCamera.setFreelook(false)
			virtualCursorX = 0
			virtualCursorY = 0
			displayedCursorX = 0
			displayedCursorY = 0
			CombatHUD.showVehicleCursor(true)
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
		elseif windowFocused then
			if UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter then
				UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
			end
			if UserInputService.MouseIconEnabled then
				UserInputService.MouseIconEnabled = false
			end
		end

		local throttle, yawInput, pitchInput, rollInput = updateCursorAndInputs(dt, cfg)

		local clampedDt = math.min(dt, 1 / 30)
		local cruiseMinSpeed = math.max(0, cfg.minSpeed or 0)
		local cruiseMaxSpeed = math.max(cruiseMinSpeed, cfg.maxSpeed)
		local landingEntrySpeed = math.max(currentSpeed, physicalVelocity.Magnitude)
		local landingEligible = landingEntrySpeed >= LANDING_ENTRY_MIN_SPEED and landingEntrySpeed <= LANDING_ENTRY_MAX_SPEED

		local landingToggleDown = UserInputService:IsKeyDown(Enum.KeyCode.L)
		local landingTogglePressed = landingToggleDown and not landingToggleHeld
		landingToggleHeld = landingToggleDown
		if landingTogglePressed then
			if landingSequenceActive then
				landingSequenceActive = false
				currentSpeed = math.max(currentSpeed, cruiseMinSpeed)
				local launchHeight = cfg.fighterTakeoffHeight
				if type(launchHeight) ~= "number" or launchHeight <= 0 then
					launchHeight = 12
				end
				local launchDuration = cfg.fighterTakeoffDuration
				if type(launchDuration) ~= "number" or launchDuration <= 0 then
					launchDuration = 0.9
				end
				takeoffActive = true
				takeoffRemaining = launchDuration
				takeoffTargetY = base.Position.Y + launchHeight
				takeoffLiftSpeed = launchHeight / launchDuration
				smoothedThrottleInput = 0
			elseif landingEligible then
				takeoffActive = false
				landingSequenceActive = true
				currentSpeed = math.min(currentSpeed, LANDING_SEQUENCE_MAX_SPEED)
			end
		end

		local verticalInput = 0
		if landingSequenceActive then
			local eDown = UserInputService:IsKeyDown(Enum.KeyCode.E)
			local qDown = UserInputService:IsKeyDown(Enum.KeyCode.Q)
			if eDown and not qDown then
				verticalInput = 1
			elseif qDown and not eDown then
				verticalInput = -1
			end
		end

		local minSpeed = if landingSequenceActive then 0 else cruiseMinSpeed
		local maxSpeed = if landingSequenceActive then math.min(LANDING_SEQUENCE_MAX_SPEED, cruiseMaxSpeed) else cruiseMaxSpeed

		local speedContext: string? = nil
		if landingSequenceActive then
			speedContext = "Press L: Leave Landing Sequence | E/Q Alt"
		elseif landingEligible then
			speedContext = "Press L: Landing Sequence"
		end
		CombatHUD.setSpeedContext(speedContext)

		if takeoffActive then
			smoothedForwardAccel = 0
			smoothedYawAccel = 0
			smoothedPitchAccel = 0
			smoothedRollAccel = 0
			local takeoffTargetVelocity = Vector3.new(0, takeoffLiftSpeed, 0)
			if useForceFlight and vectorForce ~= nil then
				local forceGain = cfg.fighterForceVelocityGain
				if type(forceGain) ~= "number" or forceGain <= 0 then
					forceGain = 7.5
				end
				local maxAccel = cfg.fighterForceMaxAccel
				if type(maxAccel) ~= "number" or maxAccel <= 0 then
					maxAccel = 300
				end
				local velocityError = takeoffTargetVelocity - base.AssemblyLinearVelocity
				local controlAccel = velocityError * forceGain
				if controlAccel.Magnitude > maxAccel then
					controlAccel = controlAccel.Unit * maxAccel
				end
					local desiredAccel = controlAccel + Vector3.new(0, Workspace.Gravity, 0)
					vectorForce.Force = desiredAccel * base.AssemblyMass
					physicalVelocity = base.AssemblyLinearVelocity
			else
				physicalVelocity = takeoffTargetVelocity
				if vectorForce ~= nil then
					vectorForce.Force = Vector3.zero
				end
				if bodyVelocity ~= nil then
					bodyVelocity.Velocity = physicalVelocity
				end
			end
			takeoffRemaining -= clampedDt
			if takeoffRemaining <= 0 or base.Position.Y >= takeoffTargetY - 0.5 then
				takeoffActive = false
				currentSpeed = minSpeed
				physicalVelocity = physicsOrientation.LookVector * currentSpeed
			end
		else
			local desiredThrottleInput = throttle
			if desiredThrottleInput == 0 then
				-- Neutral throttle must stop acceleration immediately.
				smoothedThrottleInput = 0
			else
				local throttleSpoolUp = cfg.fighterThrottleSpoolUp
				if type(throttleSpoolUp) ~= "number" or throttleSpoolUp <= 0 then
					throttleSpoolUp = 8
				end
				local throttleSpoolDown = cfg.fighterThrottleSpoolDown
				if type(throttleSpoolDown) ~= "number" or throttleSpoolDown <= 0 then
					throttleSpoolDown = 5.5
				end
				local spoolRate =
					if math.abs(desiredThrottleInput) > math.abs(smoothedThrottleInput) then throttleSpoolUp else throttleSpoolDown
				local throttleAlpha = 1 - math.exp(-spoolRate * clampedDt)
				smoothedThrottleInput += (desiredThrottleInput - smoothedThrottleInput) * throttleAlpha
				local throttleDeadzone = cfg.fighterThrottleDeadzone
				if type(throttleDeadzone) ~= "number" or throttleDeadzone < 0 then
					throttleDeadzone = 0.03
				end
				if math.abs(smoothedThrottleInput) < throttleDeadzone then
					smoothedThrottleInput = 0
				end
			end

			if smoothedThrottleInput > 0 then
				local accelToMax = (maxSpeed - minSpeed) / FIGHTER_TIME_TO_MAX_SPEED
				local accelRate = math.max(cfg.acceleration, accelToMax)
				currentSpeed = math.min(currentSpeed + accelRate * smoothedThrottleInput * clampedDt, maxSpeed)
			elseif smoothedThrottleInput < 0 then
				currentSpeed = math.max(currentSpeed - (cfg.deceleration or 60) * math.abs(smoothedThrottleInput) * clampedDt, minSpeed)
			else
				local coastDeceleration = cfg.coastDeceleration
				if type(coastDeceleration) == "number" and coastDeceleration > 0 then
					currentSpeed = math.max(currentSpeed - coastDeceleration * clampedDt, minSpeed)
				else
					-- Prevent stale target-speed catch-up after throttle release.
					currentSpeed = math.clamp(physicalVelocity.Magnitude, minSpeed, maxSpeed)
				end
			end

			local speedRange = math.max(1, maxSpeed - minSpeed)
			local speedFrac = math.clamp((currentSpeed - minSpeed) / speedRange, 0, 1)
			local turnScaleMin = cfg.turnRateSpeedScaleMin or 0.6
			local turnScaleMax = cfg.turnRateSpeedScaleMax or 1.0
			local turnScale = turnScaleMax + (turnScaleMin - turnScaleMax) * speedFrac

			local desiredYaw = yawInput * (cfg.yawRate or 90) * turnScale
			local noseUpBoost = if pitchInput < 0 then FIGHTER_NOSE_UP_PITCH_RATE_BOOST else 1
			local desiredPitch = pitchInput * (cfg.pitchRate or 70) * turnScale * noseUpBoost
			local desiredRoll = rollInput * (cfg.rollRate or 120)
			if landingSequenceActive then
				desiredPitch = 0
				desiredRoll = 0
			end
			local yawInputMag = math.abs(yawInput)
			local pitchInputMag = math.abs(pitchInput)
			local effectivePitchInputMag = math.clamp(pitchInputMag * noseUpBoost, 0, 1.5)
			local turnInputMag = math.clamp(math.sqrt(yawInput * yawInput + effectivePitchInputMag * effectivePitchInputMag), 0, 1)
			local pitchDominance = math.clamp(effectivePitchInputMag - yawInputMag, 0, 1)

			local resp = math.max(0.01, cfg.angularResponsiveness or 8)
			local alpha = 1 - math.exp(-resp * clampedDt)
			local yawAccelLimit = cfg.fighterYawRateAccelLimit
			if type(yawAccelLimit) ~= "number" or yawAccelLimit <= 0 then
				yawAccelLimit = 180
			end
			local pitchAccelLimit = cfg.fighterPitchRateAccelLimit
			if type(pitchAccelLimit) ~= "number" or pitchAccelLimit <= 0 then
				pitchAccelLimit = 170
			end
			local rollAccelLimit = cfg.fighterRollRateAccelLimit
			if type(rollAccelLimit) ~= "number" or rollAccelLimit <= 0 then
				rollAccelLimit = 240
			end
			local yawDelta = (desiredYaw - smoothedYawRate) * alpha
			local pitchDelta = (desiredPitch - smoothedPitchRate) * alpha
			local rollDelta = (desiredRoll - smoothedRollRate) * alpha
			smoothedYawRate += math.clamp(yawDelta, -yawAccelLimit * clampedDt, yawAccelLimit * clampedDt)
			smoothedPitchRate += math.clamp(pitchDelta, -pitchAccelLimit * clampedDt, pitchAccelLimit * clampedDt)
			smoothedRollRate += math.clamp(rollDelta, -rollAccelLimit * clampedDt, rollAccelLimit * clampedDt)
			local angularDamping = cfg.fighterAngularDamping
			if type(angularDamping) ~= "number" or angularDamping < 0 then
				angularDamping = 3
			end
			if angularDamping > 0 then
				local dampingFactor = math.exp(-angularDamping * clampedDt)
				if math.abs(desiredYaw) < 0.001 then
					smoothedYawRate *= dampingFactor
				end
				if math.abs(desiredPitch) < 0.001 then
					smoothedPitchRate *= dampingFactor
				end
				if math.abs(desiredRoll) < 0.001 then
					smoothedRollRate *= dampingFactor
				end
			end
			local yawCap = math.max(1, math.abs(cfg.yawRate or 90))
			local pitchCap = math.max(1, math.abs(cfg.pitchRate or 70))
			local rollCap = math.max(1, math.abs(cfg.rollRate or 120))
			smoothedYawRate = math.clamp(smoothedYawRate, -yawCap, yawCap)
			smoothedPitchRate = math.clamp(smoothedPitchRate, -pitchCap, pitchCap)
			smoothedRollRate = math.clamp(smoothedRollRate, -rollCap, rollCap)

			local rotDelta = CFrame.Angles(
				math.rad(smoothedPitchRate) * clampedDt,
				math.rad(smoothedYawRate) * clampedDt,
				math.rad(smoothedRollRate) * clampedDt
			)
			physicsOrientation = physicsOrientation * rotDelta
			if landingSequenceActive then
				local flatLook = Vector3.new(physicsOrientation.LookVector.X, 0, physicsOrientation.LookVector.Z)
				if flatLook.Magnitude > 1e-4 then
					local targetLevelOrientation = CFrame.lookAt(Vector3.zero, flatLook.Unit, Vector3.yAxis)
					local levelAlpha = 1 - math.exp(-10 * clampedDt)
					physicsOrientation = physicsOrientation:Lerp(targetLevelOrientation, levelAlpha)
				end
				local landingRateDamping = math.exp(-12 * clampedDt)
				smoothedPitchRate *= landingRateDamping
				smoothedRollRate *= landingRateDamping
			end

			local forward = physicsOrientation.LookVector
			local right = physicsOrientation.RightVector
			local up = physicsOrientation.UpVector
			local vForward = physicalVelocity:Dot(forward)
			local vRight = physicalVelocity:Dot(right)
			local vUp = physicalVelocity:Dot(up)
			local velocityAlignRate = cfg.fighterVelocityAlignRate
			if type(velocityAlignRate) ~= "number" or velocityAlignRate <= 0 then
				velocityAlignRate = 6
			end
			local turnAlignBoost = cfg.fighterTurnAlignBoost
			if type(turnAlignBoost) ~= "number" or turnAlignBoost < 0 then
				turnAlignBoost = 8
			end
			velocityAlignRate += turnInputMag * turnAlignBoost
			velocityAlignRate += pitchDominance * turnAlignBoost * FIGHTER_NOSE_UP_ALIGN_BOOST
			local alignAlpha = 1 - math.exp(-velocityAlignRate * clampedDt)
			local turnSpeedPenalty = cfg.fighterTurnSpeedPenalty
			if type(turnSpeedPenalty) ~= "number" or turnSpeedPenalty < 0 then
				turnSpeedPenalty = 0.3
			end
			local turnPenaltyInput = math.clamp(yawInputMag + effectivePitchInputMag * 0.28, 0, 1)
			local targetForwardSpeed = currentSpeed * (1 - turnPenaltyInput * math.clamp(turnSpeedPenalty, 0, 0.9))
			local desiredForward = vForward + (targetForwardSpeed - vForward) * alignAlpha
			local forwardAccelLimit = cfg.fighterForwardAccelLimit
			if type(forwardAccelLimit) ~= "number" or forwardAccelLimit <= 0 then
				forwardAccelLimit = 140
			end
			local forwardDecelLimit = cfg.fighterForwardDecelLimit
			if type(forwardDecelLimit) ~= "number" or forwardDecelLimit <= 0 then
				forwardDecelLimit = 180
			end
			local forwardDelta = desiredForward - vForward
			local forwardLimit = if forwardDelta >= 0 then forwardAccelLimit else forwardDecelLimit
			local maxForwardStep = forwardLimit * clampedDt
			vForward += math.clamp(forwardDelta, -maxForwardStep, maxForwardStep)
			local sideSlipDamping = cfg.fighterSideSlipDamping
			if type(sideSlipDamping) ~= "number" or sideSlipDamping < 0 then
				sideSlipDamping = 3.5
			end
			local turnSlipDampingBoost = cfg.fighterTurnSlipDampingBoost
			if type(turnSlipDampingBoost) ~= "number" or turnSlipDampingBoost < 0 then
				turnSlipDampingBoost = 8
			end
			sideSlipDamping += turnInputMag * turnSlipDampingBoost
			local verticalSlipDamping = cfg.fighterVerticalSlipDamping
			if type(verticalSlipDamping) ~= "number" or verticalSlipDamping < 0 then
				verticalSlipDamping = 2.5
			end
			local turnVerticalDampingBoost = cfg.fighterTurnVerticalDampingBoost
			if type(turnVerticalDampingBoost) ~= "number" or turnVerticalDampingBoost < 0 then
				turnVerticalDampingBoost = 6
			end
			verticalSlipDamping += turnInputMag * turnVerticalDampingBoost
			vRight *= math.exp(-sideSlipDamping * clampedDt)
			vUp *= math.exp(-verticalSlipDamping * clampedDt)
			local yawRef = math.max(1, math.abs(cfg.yawRate or 90))
			local pitchRef = math.max(1, math.abs(cfg.pitchRate or 70))
			local turnRatio = math.clamp(
				math.abs(smoothedYawRate) / yawRef + (math.abs(smoothedPitchRate) / pitchRef) * 0.55,
				0,
				1
			)
			local turnEnergyLoss = cfg.fighterTurnEnergyLoss
			if type(turnEnergyLoss) ~= "number" or turnEnergyLoss < 0 then
				turnEnergyLoss = 10
			end
			local inducedDrag = cfg.fighterInducedDrag
			if type(inducedDrag) ~= "number" or inducedDrag < 0 then
				inducedDrag = 28
			end
			local slipRatio = math.sqrt(vRight * vRight + vUp * vUp) / math.max(1, math.abs(vForward))
			vForward -= slipRatio * slipRatio * inducedDrag * clampedDt
			vForward -= turnRatio * turnEnergyLoss * clampedDt
			vForward = math.max(0, vForward)

			physicalVelocity = forward * vForward + right * vRight + up * vUp
			local velocityDirAlignBase = cfg.fighterVelocityDirAlignBase
			if type(velocityDirAlignBase) ~= "number" or velocityDirAlignBase < 0 then
				velocityDirAlignBase = 1.6
			end
			local velocityDirAlignTurnBoost = cfg.fighterVelocityDirAlignTurnBoost
			if type(velocityDirAlignTurnBoost) ~= "number" or velocityDirAlignTurnBoost < 0 then
				velocityDirAlignTurnBoost = 6.5
			end
			local dirAlignRate = velocityDirAlignBase + turnInputMag * velocityDirAlignTurnBoost
			dirAlignRate += pitchDominance * velocityDirAlignTurnBoost * FIGHTER_NOSE_UP_ALIGN_BOOST
			if dirAlignRate > 0 then
				local speedMagnitude = physicalVelocity.Magnitude
				if speedMagnitude > 1 then
					local velDir = physicalVelocity / speedMagnitude
					local dirAlpha = 1 - math.exp(-dirAlignRate * clampedDt)
					local blendedDir = velDir:Lerp(forward, dirAlpha)
					if blendedDir.Magnitude > 1e-4 then
						physicalVelocity = blendedDir.Unit * speedMagnitude
					end
				end
			end
			local worldGravity = cfg.fighterWorldGravity
			if type(worldGravity) ~= "number" or worldGravity < 0 then
				worldGravity = 26
			end
			local liftCoefficient = cfg.fighterLiftCoefficient
			if type(liftCoefficient) ~= "number" or liftCoefficient < 0 then
				liftCoefficient = 0.22
			end
				local baseDrag = cfg.fighterBaseDrag
				if type(baseDrag) ~= "number" or baseDrag < 0 then
					baseDrag = 0.08
				end
				local liftAccel = if landingSequenceActive then 0 else math.max(0, vForward) * liftCoefficient
				physicalVelocity += (up * liftAccel + Vector3.new(0, -worldGravity, 0)) * clampedDt
			physicalVelocity *= math.exp(-baseDrag * clampedDt)
			local maxVelocityMagnitude = maxSpeed * 1.15
			local velocityMagnitude = physicalVelocity.Magnitude
			if velocityMagnitude > maxVelocityMagnitude and maxVelocityMagnitude > 0 then
				physicalVelocity = physicalVelocity.Unit * maxVelocityMagnitude
			end

				if flightRayParams ~= nil then
					local collisionRadius = math.max(0, cfg.collisionRadius or 5)
					local groundRay = Workspace:Raycast(base.Position + Vector3.new(0, 50, 0), Vector3.new(0, -100, 0), flightRayParams)
					if groundRay ~= nil then
						local minAlt = if landingSequenceActive
							then (groundRay.Position.Y + LANDING_GROUND_CLEARANCE)
							else (groundRay.Position.Y + collisionRadius + 2)
						if base.Position.Y < minAlt then
							if landingSequenceActive then
								local yVelocity = if physicalVelocity.Y < 0 then math.max(physicalVelocity.Y, -1.5) else physicalVelocity.Y
								if verticalInput == 0 then
									local altError = minAlt - base.Position.Y
									yVelocity = math.max(yVelocity, math.clamp(altError * 10, 0, 6))
								end
								physicalVelocity = Vector3.new(physicalVelocity.X, yVelocity, physicalVelocity.Z)
							else
								physicalVelocity = Vector3.new(physicalVelocity.X, math.max(physicalVelocity.Y, 30), physicalVelocity.Z)
								currentSpeed = math.max(currentSpeed * 0.7, minSpeed)
								physicsOrientation = physicsOrientation * CFrame.Angles(math.rad(-5), 0, 0)
								print(string.format("[P10_COLLISION] type=%s speed=%.0f", "ground", currentSpeed))
							end
						end
					end
				end

				if landingSequenceActive then
					local horizontalVelocity = Vector3.new(physicalVelocity.X, 0, physicalVelocity.Z)
					if throttle == 0 then
						local horizontalSpeed = horizontalVelocity.Magnitude
						if horizontalSpeed > 0 then
							local brakeStep = LANDING_STOP_BRAKE * clampedDt
							local nextHorizontalSpeed = math.max(0, horizontalSpeed - brakeStep)
							if nextHorizontalSpeed > 0 then
								horizontalVelocity = horizontalVelocity.Unit * nextHorizontalSpeed
							else
								horizontalVelocity = Vector3.zero
							end
						end
						horizontalVelocity *= math.exp(-LANDING_HORIZONTAL_DAMPING * clampedDt)
					end
					if horizontalVelocity.Magnitude < LANDING_STOP_SPEED_THRESHOLD then
						horizontalVelocity = Vector3.zero
					end
					local targetVerticalSpeed = verticalInput * LANDING_VERTICAL_SPEED
					local verticalDelta = targetVerticalSpeed - physicalVelocity.Y
					local maxVerticalStep = LANDING_VERTICAL_ACCEL * clampedDt
					local nextVerticalSpeed = physicalVelocity.Y + math.clamp(verticalDelta, -maxVerticalStep, maxVerticalStep)
					if verticalInput == 0 and math.abs(nextVerticalSpeed) < 1 then
						nextVerticalSpeed = 0
					end
					physicalVelocity = Vector3.new(horizontalVelocity.X, nextVerticalSpeed, horizontalVelocity.Z)
					if throttle == 0 and verticalInput == 0 and physicalVelocity.Magnitude < LANDING_STOP_SPEED_THRESHOLD then
						physicalVelocity = Vector3.zero
						currentSpeed = 0
					end
				end

				if landingSequenceActive then
					if vectorForce ~= nil then
						vectorForce.Enabled = false
						vectorForce.Force = Vector3.zero
					end
					if bodyVelocity ~= nil then
						bodyVelocity.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
						bodyVelocity.Velocity = physicalVelocity
					end
				elseif useForceFlight and vectorForce ~= nil then
					local forceGain = cfg.fighterForceVelocityGain
					if type(forceGain) ~= "number" or forceGain <= 0 then
						forceGain = 7.5
					end
					local maxAccel = cfg.fighterForceMaxAccel
					if type(maxAccel) ~= "number" or maxAccel <= 0 then
						maxAccel = 300
					end
					if bodyVelocity ~= nil then
						bodyVelocity.MaxForce = Vector3.zero
						bodyVelocity.Velocity = Vector3.zero
					end
					vectorForce.Enabled = true
					local velocityError = physicalVelocity - base.AssemblyLinearVelocity
					local controlAccel = velocityError * forceGain
					if controlAccel.Magnitude > maxAccel then
						controlAccel = controlAccel.Unit * maxAccel
					end
					local desiredAccel = controlAccel + Vector3.new(0, Workspace.Gravity, 0)
					vectorForce.Force = desiredAccel * base.AssemblyMass
					physicalVelocity = base.AssemblyLinearVelocity
				else
					if vectorForce ~= nil then
						vectorForce.Enabled = false
						vectorForce.Force = Vector3.zero
					end
					if bodyVelocity ~= nil then
						bodyVelocity.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
						bodyVelocity.Velocity = physicalVelocity
					end
				end
		end

		local accelDt = math.max(clampedDt, 1 / 240)
		local yawAccelForVisual = math.clamp((smoothedYawRate - previousVisualYawRate) / accelDt, -420, 420)
		local pitchAccelForVisual = math.clamp((smoothedPitchRate - previousVisualPitchRate) / accelDt, -420, 420)
		previousVisualYawRate = smoothedYawRate
		previousVisualPitchRate = smoothedPitchRate

		local autoBankMaxAngle = math.max(0, cfg.autoBankMaxAngle or 35)
		local autoBankYawRateRef = math.max(1, math.abs(cfg.autoBankYawRateRef or 90))
		local targetAutoRollDeg = math.clamp((smoothedYawRate / autoBankYawRateRef) * autoBankMaxAngle, -autoBankMaxAngle, autoBankMaxAngle)
		local autoBankRate = math.max(0, cfg.autoBankRate or 90)
		if autoBankRate <= 0 then
			autoRollVisualDeg = targetAutoRollDeg
		else
			local maxStepDeg = autoBankRate * clampedDt
			local deltaDeg = math.clamp(targetAutoRollDeg - autoRollVisualDeg, -maxStepDeg, maxStepDeg)
			autoRollVisualDeg += deltaDeg
		end

		local speedForVisualSlip = math.max(1, physicalVelocity.Magnitude)
		local sideSlipNorm = math.clamp(physicalVelocity:Dot(physicsOrientation.RightVector) / speedForVisualSlip, -1, 1)
		local verticalSlipNorm = math.clamp(physicalVelocity:Dot(physicsOrientation.UpVector) / speedForVisualSlip, -1, 1)
		local visualYawRateGain = cfg.fighterVisualYawRateGain
		if type(visualYawRateGain) ~= "number" then
			visualYawRateGain = 0.09
		end
		local visualPitchRateGain = cfg.fighterVisualPitchRateGain
		if type(visualPitchRateGain) ~= "number" then
			visualPitchRateGain = 0.08
		end
		local visualYawAccelGain = cfg.fighterVisualYawAccelGain
		if type(visualYawAccelGain) ~= "number" then
			visualYawAccelGain = 0.015
		end
		local visualPitchAccelGain = cfg.fighterVisualPitchAccelGain
		if type(visualPitchAccelGain) ~= "number" then
			visualPitchAccelGain = 0.012
		end
		local visualSlipYawGain = cfg.fighterVisualSlipYawGain
		if type(visualSlipYawGain) ~= "number" then
			visualSlipYawGain = 8.0
		end
		local visualSlipPitchGain = cfg.fighterVisualSlipPitchGain
		if type(visualSlipPitchGain) ~= "number" then
			visualSlipPitchGain = 6.0
		end
		local visualRollRateGain = cfg.fighterVisualRollRateGain
		if type(visualRollRateGain) ~= "number" then
			visualRollRateGain = 0.08
		end
		local visualYawMax = math.max(0, cfg.fighterVisualYawMax or 18)
		local visualPitchMax = math.max(0, cfg.fighterVisualPitchMax or 14)
		local visualRollMax = math.max(0, cfg.fighterVisualRollMax or 15)
		local targetVisualYawOverDeg = smoothedYawRate * visualYawRateGain + yawAccelForVisual * visualYawAccelGain - sideSlipNorm * visualSlipYawGain
		local targetVisualPitchOverDeg = smoothedPitchRate * visualPitchRateGain + pitchAccelForVisual * visualPitchAccelGain - verticalSlipNorm * visualSlipPitchGain
		local targetVisualRollOverDeg = smoothedYawRate * visualRollRateGain
		targetVisualYawOverDeg = math.clamp(targetVisualYawOverDeg, -visualYawMax, visualYawMax)
		targetVisualPitchOverDeg = math.clamp(targetVisualPitchOverDeg, -visualPitchMax, visualPitchMax)
		targetVisualRollOverDeg = math.clamp(targetVisualRollOverDeg, -visualRollMax, visualRollMax)
		local visualResponse = cfg.fighterVisualResponse
		if type(visualResponse) ~= "number" or visualResponse <= 0 then
			visualResponse = 10
		end
		local visualAlpha = 1 - math.exp(-visualResponse * clampedDt)
		visualYawOverDeg += (targetVisualYawOverDeg - visualYawOverDeg) * visualAlpha
		visualPitchOverDeg += (targetVisualPitchOverDeg - visualPitchOverDeg) * visualAlpha
		visualRollOverDeg += (targetVisualRollOverDeg - visualRollOverDeg) * visualAlpha
		local visualRollDeg = autoRollVisualDeg + visualRollOverDeg
		visualOrientation = physicsOrientation
			* CFrame.Angles(math.rad(visualPitchOverDeg), math.rad(visualYawOverDeg), 0)
			* CFrame.Angles(0, 0, math.rad(visualRollDeg))

		if bodyGyro ~= nil then
			bodyGyro.CFrame = CFrame.new(base.Position) * visualOrientation
		end

		local reportedSpeed = physicalVelocity.Magnitude
		mdl:SetAttribute("VehicleSpeed", reportedSpeed)
		local moveLook = physicsOrientation.LookVector
		mdl:SetAttribute("VehicleHeading", math.atan2(-moveLook.X, -moveLook.Z))
		local look = base.CFrame.LookVector

		CombatHUD.setSpeed(reportedSpeed)
		updateAudio(dt, reportedSpeed, cfg.maxSpeed, throttle, yawInput)

		local now = tick()
		if now - lastDebugPrintTick >= 0.5 then
			local pitchDeg = math.deg(math.asin(math.clamp(look.Y, -1, 1)))
			local yawDeg = math.deg(math.atan2(-look.X, -look.Z))
			local rollDeg = math.deg(extractRollAngle(base.CFrame))
			print(string.format("[P10_SPEED] speed=%.0f throttle=%d", reportedSpeed, throttle))
			print(string.format("[P10_ORIENT] pitch=%.1f yaw=%.1f roll=%.1f", pitchDeg, yawDeg, rollDeg))
			lastDebugPrintTick = now
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
end

function FighterClient.deactivate(): ()
	if renderConnection ~= nil then
		renderConnection:Disconnect()
		renderConnection = nil
	end
	if seatOccupantConnection ~= nil then
		seatOccupantConnection:Disconnect()
		seatOccupantConnection = nil
	end
	if scrollConnection ~= nil then
		scrollConnection:Disconnect()
		scrollConnection = nil
	end

	ContextActionService:UnbindAction(EXIT_ACTION_NAME)
	cleanupAudio(true)
	local model = activeModel
	if model ~= nil and model.PrimaryPart ~= nil then
		for _, child in ipairs((model.PrimaryPart :: BasePart):GetChildren()) do
			if child:IsA("Sound") and (child.Name == "FighterEngineLoop" or child.Name == "RemoteFighterEngineLoop") then
				child:Destroy()
			end
		end
	end
	VehicleCamera.deactivate()
	restoreMouse()
	setLocalPilotControl(false)
	RemoteVehicleSmoother.setLocalVehicle(nil)

	CombatHUD.hideHP()
	CombatHUD.showSpeed(false)
	CombatHUD.showVehicleCursor(false)
	CombatHUD.showCrosshair(false)
	CombatHUD.showHeat(false)
	CombatHUD.showAmmo(false)
	CombatHUD.showShield(false)
	CombatHUD.setSpeedContext(nil)
	VehicleCamera.setExternalFOVOffset(0)
	CombatHUD.setZoomVignette(0)

	activeEntityId = nil
	activeModel = nil
	activeConfig = nil
	activeDriverSeat = nil
	virtualCursorX = 0
	virtualCursorY = 0
	displayedCursorX = 0
	displayedCursorY = 0
	freelookActive = false
	currentSpeed = 0
	smoothedThrottleInput = 0
	physicalVelocity = Vector3.zero
	physicsOrientation = CFrame.new()
	visualOrientation = CFrame.new()
	autoRollVisualDeg = 0
	visualYawOverDeg = 0
	visualPitchOverDeg = 0
	visualRollOverDeg = 0
	previousVisualYawRate = 0
	previousVisualPitchRate = 0
	smoothedPitchRate = 0
	smoothedYawRate = 0
	smoothedRollRate = 0
	smoothedPitchAccel = 0
	smoothedYawAccel = 0
	smoothedRollAccel = 0
	smoothedForwardAccel = 0
	filteredYawInput = 0
	filteredPitchInput = 0
	yawInputHysteresisActive = false
	pitchInputHysteresisActive = false
	if vectorForce ~= nil then
		vectorForce.Enabled = false
		vectorForce.Force = Vector3.zero
	end
	bodyVelocity = nil
	bodyGyro = nil
	vectorForce = nil
	useForceFlight = false
	takeoffActive = false
	takeoffRemaining = 0
	takeoffTargetY = 0
	takeoffLiftSpeed = 0
	landingSequenceActive = false
	landingToggleHeld = false
	flightRayParams = nil
	lastDebugPrintTick = 0
end

function FighterClient.isActive(): boolean
	return activeEntityId ~= nil
end

function FighterClient.init(remotesFolder: Folder): ()
	vehicleExitRemote = remotesFolder:WaitForChild("VehicleExitRequest") :: RemoteEvent
	if focusLostConnection == nil then
		focusLostConnection = UserInputService.WindowFocusReleased:Connect(function()
			windowFocused = false
			landingToggleHeld = false
			virtualCursorX = 0
			virtualCursorY = 0
			displayedCursorX = 0
			displayedCursorY = 0
			smoothedPitchRate = 0
			smoothedYawRate = 0
			smoothedRollRate = 0
			previousVisualYawRate = 0
			previousVisualPitchRate = 0
			autoRollVisualDeg = 0
			visualYawOverDeg = 0
			visualPitchOverDeg = 0
			visualRollOverDeg = 0
			smoothedPitchAccel = 0
			smoothedYawAccel = 0
			smoothedRollAccel = 0
			smoothedForwardAccel = 0
			filteredYawInput = 0
			filteredPitchInput = 0
			yawInputHysteresisActive = false
			pitchInputHysteresisActive = false
		end)
	end
	if focusGainedConnection == nil then
		focusGainedConnection = UserInputService.WindowFocused:Connect(function()
			windowFocused = true
			landingToggleHeld = false
			virtualCursorX = 0
			virtualCursorY = 0
			displayedCursorX = 0
			displayedCursorY = 0
		end)
	end
end

return FighterClient
