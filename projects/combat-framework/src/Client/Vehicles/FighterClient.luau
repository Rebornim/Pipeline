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
local CombatTypes = require(sharedRoot:WaitForChild("CombatTypes"))

local CombatHUD = require(clientRoot:WaitForChild("HUD"):WaitForChild("CombatHUD"))
local RemoteVehicleSmoother = require(clientRoot:WaitForChild("Vehicles"):WaitForChild("RemoteVehicleSmoother"))
local VehicleCamera = require(clientRoot:WaitForChild("Vehicles"):WaitForChild("VehicleCamera"))
local SoundProfileLoader = require(clientRoot:WaitForChild("Vehicles"):WaitForChild("SoundProfiles"):WaitForChild("SoundProfileLoader"))
local SoundProfileTypes = require(clientRoot:WaitForChild("Vehicles"):WaitForChild("SoundProfiles"):WaitForChild("SoundProfileTypes"))

type VehicleConfig = CombatTypes.VehicleConfig
type FighterFlightMode = "Takeoff" | "Flight" | "Landing"
type FighterTuning = {
	minSpeed: number,
	maxSpeed: number,
	acceleration: number,
	deceleration: number,
	coastDeceleration: number?,
	yawRate: number,
	pitchRate: number,
	rollRate: number,
	turnRateSpeedScaleMin: number,
	turnRateSpeedScaleMax: number,
	angularResponsiveness: number,
	autoBankMaxAngle: number,
	autoBankYawRateRef: number,
	autoBankRate: number,
	fighterMouseSensitivity: number,
	fighterMouseRangeX: number,
	fighterMouseRangeY: number,
	fighterMouseAutoCenter: number,
	fighterMouseDeadzone: number,
	fighterMouseCenterReturnRadius: number,
	fighterCursorLagRate: number,
	fighterInputExpo: number,
	fighterUseForceFlight: boolean,
	fighterForceVelocityGain: number,
	fighterForceMaxAccel: number,
	fighterThrottleSpoolUp: number,
	fighterThrottleSpoolDown: number,
	fighterThrottleDeadzone: number,
	fighterAngularDamping: number,
	fighterYawRateAccelLimit: number,
	fighterPitchRateAccelLimit: number,
	fighterRollRateAccelLimit: number,
	fighterVelocityAlignRate: number,
	fighterVelocityDirAlignBase: number,
	fighterVelocityDirAlignTurnBoost: number,
	fighterTurnAlignBoost: number,
	fighterTurnSpeedPenalty: number,
	fighterSideSlipDamping: number,
	fighterTurnSlipDampingBoost: number,
	fighterVerticalSlipDamping: number,
	fighterTurnVerticalDampingBoost: number,
	fighterTurnEnergyLoss: number,
	fighterForwardAccelLimit: number,
	fighterForwardDecelLimit: number,
	fighterInducedDrag: number,
	fighterWorldGravity: number,
	fighterLiftCoefficient: number,
	fighterBaseDrag: number,
	fighterVisualYawRateGain: number,
	fighterVisualPitchRateGain: number,
	fighterVisualYawAccelGain: number,
	fighterVisualPitchAccelGain: number,
	fighterVisualSlipYawGain: number,
	fighterVisualSlipPitchGain: number,
	fighterVisualRollRateGain: number,
	fighterVisualResponse: number,
	fighterVisualYawMax: number,
	fighterVisualPitchMax: number,
	fighterVisualRollMax: number,
	fighterTakeoffHeight: number,
	fighterTakeoffDuration: number,
	boostEnabled: boolean,
	boostSpeedMultiplier: number,
	boostDuration: number,
	boostCooldown: number,
	collisionRadius: number,
}

local FighterClient = {}

local EXIT_ACTION_NAME = "CombatExitFighter"
local BLOCK_JUMP_ACTION_NAME = "BlockFighterJump"
local LEVEL_OFF_ACTION_NAME = "CombatFighterLevelOff"
local ENGINE_KILL_ACTION_NAME = "CombatFighterEngineKill"
local ENGINE_KILL_DRAG = 0.4
local LEVEL_OFF_SLERP_RATE = 2.0
local FIGHTER_CURSOR_CIRCLE_SCALE = 1.15
local FIGHTER_TIME_TO_MAX_SPEED = 1.0
local FIGHTER_NOSE_UP_PITCH_RATE_BOOST = 1.35
local FIGHTER_NOSE_UP_ALIGN_BOOST = 1.6
local FIGHTER_MANEUVER_LIFT_PULL_BOOST = 1.15
local FIGHTER_MANEUVER_LIFT_BANK_BOOST = 0.65
local FIGHTER_COORDINATED_ALIGN_BOOST = 1.2
local FIGHTER_COORDINATED_TURN_PENALTY_RELIEF = 0.35
local FIGHTER_SPEED_AUTHORITY_MIN = 0.68
local FIGHTER_SPEED_AUTHORITY_MAX = 1.15
local FIGHTER_SPEED_AUTHORITY_GAMMA = 1.35
local FIGHTER_TURN_EXIT_CARRY_DAMPING_RELIEF = 0.55
local FIGHTER_MOUSE_IDLE_RECENTER_DELAY = 1.0
local FIGHTER_MOUSE_IDLE_RECENTER_RATE = 0.55
local FIGHTER_MOUSE_IDLE_RECENTER_EDGE_THRESHOLD = 0.82
local FIGHTER_LANDING_VISUAL_ROLL_SCALE = 0.12
local FIGHTER_LANDING_VISUAL_PITCH_SCALE = 0.18
local FIGHTER_STRAIGHT_VISUAL_ROLL_SETTLE_RATE = 6.5
local FIGHTER_BOOST_BLEND_RESPONSE = 10.0
local FIGHTER_BOOST_MIN_START_CHARGE = 0.08
local FIGHTER_BOOST_REUSE_COOLDOWN = 2.0
local LANDING_ENTRY_MIN_SPEED = 90
local LANDING_ENTRY_MAX_SPEED = 100
local LANDING_SEQUENCE_MAX_SPEED = 50
local LANDING_TRANSITION_DURATION = 0.35
local LANDING_REVERSE_MAX_SPEED = 22
local LANDING_VERTICAL_SPEED = 16
local LANDING_VERTICAL_ACCEL = 70
local LANDING_VERTICAL_COMMAND_RESPONSE = 4.8
local LANDING_HORIZONTAL_DAMPING = 2.2
local LANDING_IDLE_BRAKE_DECEL = 25
local LANDING_HEADING_ALIGN_RATE = 3.5
local LANDING_REVERSE_BRAKE_DECEL = 45
local LANDING_STRAFE_ACCEL = 35
local LANDING_STRAFE_MAX_SPEED = 18
local LANDING_STRAFE_DAMPING = 5.0
local LANDING_STOP_BRAKE = 220
local LANDING_STOP_SPEED_THRESHOLD = 4
local LANDING_GROUND_CLEARANCE = 1.1
local LANDING_ENTRY_IDLE_CLEARANCE = 2.0
local LANDING_ENTRY_LIFT_DURATION = 0.25
local LANDING_ENTRY_RAY_HEIGHT = 10
local LANDING_ENTRY_RAY_LENGTH = 40
local FIGHTER_POST_LANDING_VISUAL_LOCK = 0.45

-- Landing wobble (damped spring — driven by actual ship turn rate, not cursor)
local LANDING_WOBBLE_ROLL_STIFFNESS = 65
local LANDING_WOBBLE_ROLL_DAMPING = 4.5
local LANDING_WOBBLE_PITCH_STIFFNESS = 45
local LANDING_WOBBLE_PITCH_DAMPING = 4.0
local LANDING_WOBBLE_ROLL_MAX_DEG = 1.8
local LANDING_WOBBLE_PITCH_MAX_DEG = 1.0
local LANDING_WOBBLE_ROLL_GAIN = 0.1
local LANDING_WOBBLE_PITCH_GAIN = 0.8
local LANDING_WOBBLE_SPEED_AUTHORITY = 0.6
local LANDING_WOBBLE_PIVOT_HEIGHT = 25

-- Idle hover drift (Perlin noise when near-stationary in landing)
local HOVER_NOISE_ROLL_AMP = 0.9
local HOVER_NOISE_PITCH_AMP = 0.5
local HOVER_NOISE_LATERAL_AMP = 1.2
local HOVER_NOISE_VERTICAL_AMP = 0.5
local HOVER_NOISE_SPEED = 0.8
local HOVER_NOISE_SPEED_FADE = 8

-- Flight turbulence (fast tight jitter, scales with speed)
local TURB_ROLL_AMP = 0.35
local TURB_PITCH_AMP = 0.2
local TURB_NOISE_SPEED = 3.0
local TURB_TURN_BONUS = 0.4
local TURB_BOOST_BONUS = 0.3
local FIGHTER_STREAM_REQUEST_INTERVAL = 0.35
local FIGHTER_STREAM_LOOKAHEAD_TIME = 1.25
local FIGHTER_STREAM_LOOKAHEAD_MIN = 80
local FIGHTER_STREAM_LOOKAHEAD_MAX = 320

local vehicleExitRemote: RemoteEvent? = nil
local renderConnection: RBXScriptConnection? = nil
local scrollConnection: RBXScriptConnection? = nil
local seatOccupantConnection: RBXScriptConnection? = nil
local focusLostConnection: RBXScriptConnection? = nil
local focusGainedConnection: RBXScriptConnection? = nil

local activeEntityId: string? = nil
local activeModel: Model? = nil
local activeTuning: FighterTuning? = nil
local activeDriverSeat: BasePart? = nil
local virtualCursorX = 0
local virtualCursorY = 0
local displayedCursorX = 0
local displayedCursorY = 0
local mouseIdleNoInputTime = 0
local freelookActive = false

local savedMouseBehavior: Enum.MouseBehavior? = nil
local savedMouseIconEnabled: boolean? = nil
local windowFocused = true

local activeProfileController: SoundProfileTypes.ProfileController? = nil

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
local landingVerticalCommandSpeed: number = 0
local filteredYawInput: number = 0
local filteredPitchInput: number = 0
local yawInputHysteresisActive: boolean = false
local pitchInputHysteresisActive: boolean = false
local bodyVelocity: BodyVelocity? = nil
local bodyGyro: BodyGyro? = nil
local vectorForce: VectorForce? = nil
local useForceFlight: boolean = false
local flightMode: FighterFlightMode = "Landing"
local takeoffExitMode: FighterFlightMode = "Flight"
local takeoffRemaining: number = 0
local takeoffTargetY: number = 0
local takeoffLiftSpeed: number = 0
local takeoffVisualLockRemaining: number = 0
local landingToggleHeld: boolean = false
local landingTransitionActive: boolean = false
local landingTransitionElapsed: number = 0
local landingTransitionFromLanding: boolean = false
local landingTransitionToLanding: boolean = false
local boostCharge: number = 1
local boostBlend: number = 0
local boostActive: boolean = false
local prevBoostForEvents: boolean = false
local boostReuseCooldown: number = 0
local wobbleRoll: number = 0
local wobbleRollVel: number = 0
local wobblePitch: number = 0
local wobblePitchVel: number = 0
local hoverNoiseClock: number = 0
local exitAutoLandActive: boolean = false
local exitAutoLandStartClock: number = 0
local exitAutoLandStartY: number = 0
local exitAutoLandTargetY: number = 0
local exitAutoLandHeading: CFrame = CFrame.identity
local exitAutoLandDone: boolean = false
local AUTO_LAND_MAX_HEIGHT = 150
local AUTO_LAND_MAX_SPEED = 40
local levelOffActive: boolean = false
local engineKillActive: boolean = false
local engineKillSavedSpeed: number = 0
local flightRayParams: RaycastParams? = nil
local nextStreamRequestTime: number = 0

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
	if flightMode ~= "Landing" then
		return Enum.ContextActionResult.Sink
	end
	if not exitAutoLandActive then
		local mdl = activeModel
		local pp = if mdl ~= nil then mdl.PrimaryPart else nil
		if pp ~= nil and flightRayParams ~= nil then
			local groundCheck = Workspace:Raycast(pp.Position, Vector3.new(0, -500, 0), flightRayParams)
			if groundCheck == nil then
				return Enum.ContextActionResult.Sink
			end
			local groundY = groundCheck.Position.Y
			if pp.Position.Y - groundY > AUTO_LAND_MAX_HEIGHT then
				return Enum.ContextActionResult.Sink
			end
			exitAutoLandStartY = pp.Position.Y
			exitAutoLandTargetY = groundY
		end
		exitAutoLandActive = true
		exitAutoLandDone = false
		exitAutoLandStartClock = os.clock()
		if activeProfileController ~= nil then
			activeProfileController:onEvent("auto_land_start", nil)
		end
		local flatLook = Vector3.new(physicsOrientation.LookVector.X, 0, physicsOrientation.LookVector.Z)
		if flatLook.Magnitude > 1e-4 then
			exitAutoLandHeading = CFrame.lookAt(Vector3.zero, flatLook.Unit, Vector3.yAxis)
		else
			exitAutoLandHeading = CFrame.lookAt(Vector3.zero, Vector3.new(0, 0, -1), Vector3.yAxis)
		end
	end
	return Enum.ContextActionResult.Sink
end

local function onLevelOffAction(_name: string, inputState: Enum.UserInputState, _inputObject: InputObject): Enum.ContextActionResult
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	if flightMode ~= "Flight" then
		return Enum.ContextActionResult.Sink
	end
	levelOffActive = true
	virtualCursorX = 0
	virtualCursorY = 0
	displayedCursorX = 0
	displayedCursorY = 0
	return Enum.ContextActionResult.Sink
end

local function onEngineKillAction(_name: string, inputState: Enum.UserInputState, _inputObject: InputObject): Enum.ContextActionResult
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	if flightMode ~= "Flight" then
		return Enum.ContextActionResult.Sink
	end
	engineKillActive = not engineKillActive
	if engineKillActive then
		engineKillSavedSpeed = currentSpeed
		if activeProfileController ~= nil then
			local spd = if activeTuning ~= nil then math.clamp(currentSpeed / (activeTuning :: any).maxSpeed, 0, 1) else 0.5
			activeProfileController:onEvent("engine_kill_on", { speedFraction = spd })
		end
	else
		currentSpeed = engineKillSavedSpeed
		if activeProfileController ~= nil then
			activeProfileController:onEvent("engine_kill_off", nil)
		end
	end
	return Enum.ContextActionResult.Sink
end

local function cleanupAudio()
	if activeProfileController ~= nil then
		activeProfileController:destroy()
		activeProfileController = nil
	end
end

local function setupAudio(model: Model, config: FighterTuning)
	cleanupAudio()
	local profileAttr = model:GetAttribute("SoundProfile")
	if type(profileAttr) ~= "string" or profileAttr == "" then
		return
	end
	local primaryPart = model.PrimaryPart
	if primaryPart == nil then
		return
	end
	activeProfileController = SoundProfileLoader.createController(model, primaryPart, config.maxSpeed, true)
end

local function updateAudio(dt: number, speed: number, maxSpeed: number, throttle: number, yawInput: number, isBoosting: boolean, inLanding: boolean)
	if activeProfileController == nil then
		return
	end
	local speedFrac = if maxSpeed > 0 then math.clamp(speed / maxSpeed, 0, 1) else 0
	local frameState: SoundProfileTypes.VehicleFrameState = {
		speed = speed,
		maxSpeed = maxSpeed,
		speedFraction = speedFrac,
		hpFraction = 1,
		isBoosting = isBoosting,
		isGrounded = false,
		throttle = throttle,
		steerInput = yawInput,
		isLanding = inLanding,
		isLocal = true,
		dt = dt,
	}
	activeProfileController:update(dt, frameState)
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

local function smoothstep01(t: number): number
	local x = math.clamp(t, 0, 1)
	return x * x * (3 - 2 * x)
end

local function resetFlightDynamicsVisuals()
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
end

local function levelOrientationYawOnly(current: CFrame): CFrame
	local flatLook = Vector3.new(current.LookVector.X, 0, current.LookVector.Z)
	if flatLook.Magnitude <= 1e-4 then
		return CFrame.lookAt(Vector3.zero, Vector3.new(0, 0, -1), Vector3.yAxis)
	end
	return CFrame.lookAt(Vector3.zero, flatLook.Unit, Vector3.yAxis)
end

local function readConfigNumber(config: VehicleConfig, key: string, defaultValue: number): number
	local raw = (config :: any)[key]
	if type(raw) == "number" then
		return raw
	end
	return defaultValue
end

local function readConfigBool(config: VehicleConfig, key: string, defaultValue: boolean): boolean
	local raw = (config :: any)[key]
	if type(raw) == "boolean" then
		return raw
	end
	return defaultValue
end

local function buildFighterTuning(config: VehicleConfig): FighterTuning
	local resolvedMinSpeed = math.max(0, readConfigNumber(config, "minSpeed", 90))
	local resolvedMaxSpeed = math.max(resolvedMinSpeed, readConfigNumber(config, "maxSpeed", 260))

	return {
		minSpeed = resolvedMinSpeed,
		maxSpeed = resolvedMaxSpeed,
		acceleration = readConfigNumber(config, "acceleration", 95),
		deceleration = readConfigNumber(config, "deceleration", 70),
		coastDeceleration = (config.coastDeceleration :: number?),
		yawRate = readConfigNumber(config, "yawRate", 90),
		pitchRate = readConfigNumber(config, "pitchRate", 70),
		rollRate = readConfigNumber(config, "rollRate", 120),
		turnRateSpeedScaleMin = readConfigNumber(config, "turnRateSpeedScaleMin", 0.6),
		turnRateSpeedScaleMax = readConfigNumber(config, "turnRateSpeedScaleMax", 1.0),
		angularResponsiveness = math.max(0.01, readConfigNumber(config, "angularResponsiveness", 8)),
		autoBankMaxAngle = math.max(0, readConfigNumber(config, "autoBankMaxAngle", 35)),
		autoBankYawRateRef = math.max(1, math.abs(readConfigNumber(config, "autoBankYawRateRef", 90))),
		autoBankRate = math.max(0, readConfigNumber(config, "autoBankRate", 90)),
		fighterMouseSensitivity = readConfigNumber(config, "fighterMouseSensitivity", 0.5),
		fighterMouseRangeX = math.max(0.01, readConfigNumber(config, "fighterMouseRangeX", 1.0)),
		fighterMouseRangeY = math.max(0.01, readConfigNumber(config, "fighterMouseRangeY", 0.8)),
		fighterMouseAutoCenter = math.max(0, readConfigNumber(config, "fighterMouseAutoCenter", 3.0)),
		fighterMouseDeadzone = math.max(0, readConfigNumber(config, "fighterMouseDeadzone", 0.075)),
		fighterMouseCenterReturnRadius = math.max(0, readConfigNumber(config, "fighterMouseCenterReturnRadius", 0.11)),
		fighterCursorLagRate = math.max(0, readConfigNumber(config, "fighterCursorLagRate", 16)),
		fighterInputExpo = readConfigNumber(config, "fighterInputExpo", 1.35),
		fighterUseForceFlight = readConfigBool(config, "fighterUseForceFlight", false),
		fighterForceVelocityGain = readConfigNumber(config, "fighterForceVelocityGain", 7.5),
		fighterForceMaxAccel = readConfigNumber(config, "fighterForceMaxAccel", 300),
		fighterThrottleSpoolUp = readConfigNumber(config, "fighterThrottleSpoolUp", 8),
		fighterThrottleSpoolDown = readConfigNumber(config, "fighterThrottleSpoolDown", 5.5),
		fighterThrottleDeadzone = readConfigNumber(config, "fighterThrottleDeadzone", 0.03),
		fighterAngularDamping = readConfigNumber(config, "fighterAngularDamping", 3),
		fighterYawRateAccelLimit = readConfigNumber(config, "fighterYawRateAccelLimit", 180),
		fighterPitchRateAccelLimit = readConfigNumber(config, "fighterPitchRateAccelLimit", 170),
		fighterRollRateAccelLimit = readConfigNumber(config, "fighterRollRateAccelLimit", 240),
		fighterVelocityAlignRate = readConfigNumber(config, "fighterVelocityAlignRate", 6),
		fighterVelocityDirAlignBase = readConfigNumber(config, "fighterVelocityDirAlignBase", 1.6),
		fighterVelocityDirAlignTurnBoost = readConfigNumber(config, "fighterVelocityDirAlignTurnBoost", 6.5),
		fighterTurnAlignBoost = readConfigNumber(config, "fighterTurnAlignBoost", 8),
		fighterTurnSpeedPenalty = readConfigNumber(config, "fighterTurnSpeedPenalty", 0.3),
		fighterSideSlipDamping = readConfigNumber(config, "fighterSideSlipDamping", 3.5),
		fighterTurnSlipDampingBoost = readConfigNumber(config, "fighterTurnSlipDampingBoost", 8),
		fighterVerticalSlipDamping = readConfigNumber(config, "fighterVerticalSlipDamping", 2.5),
		fighterTurnVerticalDampingBoost = readConfigNumber(config, "fighterTurnVerticalDampingBoost", 6),
		fighterTurnEnergyLoss = readConfigNumber(config, "fighterTurnEnergyLoss", 10),
		fighterForwardAccelLimit = readConfigNumber(config, "fighterForwardAccelLimit", 140),
		fighterForwardDecelLimit = readConfigNumber(config, "fighterForwardDecelLimit", 180),
		fighterInducedDrag = readConfigNumber(config, "fighterInducedDrag", 28),
		fighterWorldGravity = readConfigNumber(config, "fighterWorldGravity", 26),
		fighterLiftCoefficient = readConfigNumber(config, "fighterLiftCoefficient", 0.22),
		fighterBaseDrag = readConfigNumber(config, "fighterBaseDrag", 0.08),
		fighterVisualYawRateGain = readConfigNumber(config, "fighterVisualYawRateGain", 0.09),
		fighterVisualPitchRateGain = readConfigNumber(config, "fighterVisualPitchRateGain", 0.08),
		fighterVisualYawAccelGain = readConfigNumber(config, "fighterVisualYawAccelGain", 0.015),
		fighterVisualPitchAccelGain = readConfigNumber(config, "fighterVisualPitchAccelGain", 0.012),
		fighterVisualSlipYawGain = readConfigNumber(config, "fighterVisualSlipYawGain", 8.0),
		fighterVisualSlipPitchGain = readConfigNumber(config, "fighterVisualSlipPitchGain", 6.0),
		fighterVisualRollRateGain = readConfigNumber(config, "fighterVisualRollRateGain", 0.08),
		fighterVisualResponse = readConfigNumber(config, "fighterVisualResponse", 10),
		fighterVisualYawMax = math.max(0, readConfigNumber(config, "fighterVisualYawMax", 18)),
		fighterVisualPitchMax = math.max(0, readConfigNumber(config, "fighterVisualPitchMax", 14)),
		fighterVisualRollMax = math.max(0, readConfigNumber(config, "fighterVisualRollMax", 15)),
		fighterTakeoffHeight = readConfigNumber(config, "fighterTakeoffHeight", 12),
		fighterTakeoffDuration = readConfigNumber(config, "fighterTakeoffDuration", 0.9),
		boostEnabled = readConfigBool(config, "boostEnabled", false),
		boostSpeedMultiplier = math.max(1, readConfigNumber(config, "boostSpeedMultiplier", 1.35)),
		boostDuration = readConfigNumber(config, "boostDuration", 2.5),
		boostCooldown = readConfigNumber(config, "boostCooldown", 4.0),
		collisionRadius = math.max(0, readConfigNumber(config, "collisionRadius", 5)),
	}
end

local function updateCursorAndInputs(dt: number, config: FighterTuning): (number, number, number, number)
	if not windowFocused then
		virtualCursorX = 0
		virtualCursorY = 0
		displayedCursorX = 0
		displayedCursorY = 0
		mouseIdleNoInputTime = 0
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
		local hasMouseInput = math.abs(mouseDelta.X) > 0.01 or math.abs(mouseDelta.Y) > 0.01
		if hasMouseInput then
			mouseIdleNoInputTime = 0
		else
			mouseIdleNoInputTime += dt
		end
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
		end
		if mouseIdleNoInputTime >= FIGHTER_MOUSE_IDLE_RECENTER_DELAY then
			local edgeRadius = circleRadius * FIGHTER_MOUSE_IDLE_RECENTER_EDGE_THRESHOLD
			if cursorDistSq < edgeRadius * edgeRadius then
				local idleCenterAlpha = 1 - math.exp(-FIGHTER_MOUSE_IDLE_RECENTER_RATE * dt)
				virtualCursorX *= (1 - idleCenterAlpha)
				virtualCursorY *= (1 - idleCenterAlpha)
			end
		end
	else
		mouseIdleNoInputTime = 0
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
	activeTuning = buildFighterTuning(config)
	activeDriverSeat = findDriverSeat(model)
	virtualCursorX = 0
	virtualCursorY = 0
	displayedCursorX = 0
	displayedCursorY = 0
	mouseIdleNoInputTime = 0
	freelookActive = false
	windowFocused = true

	RemoteVehicleSmoother.setLocalVehicle(model)
	activateMouse()
	setLocalPilotControl(true)
	setupAudio(model, activeTuning :: FighterTuning)
	print("[P10F3] physics_step=realtime_dt clamp=[1/240,1/20]")

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

	useForceFlight = (activeTuning :: FighterTuning).fighterUseForceFlight and vectorForce ~= nil
	if (activeTuning :: FighterTuning).fighterUseForceFlight and vectorForce == nil then
		warn("[P10_FORCE] FighterVectorForce missing; falling back to BodyVelocity mode")
	end

	bodyVelocity.MaxForce = if useForceFlight then Vector3.zero else Vector3.new(math.huge, math.huge, math.huge)
	bodyVelocity.Velocity = Vector3.zero
	bodyGyro.MaxTorque = Vector3.new(math.huge, math.huge, math.huge)
	bodyGyro.P = 50000
	bodyGyro.D = 1000
	if vectorForce ~= nil then
		vectorForce.Enabled = useForceFlight
		vectorForce.Force = Vector3.zero
	end
	physicsOrientation = primary.CFrame - primary.CFrame.Position
	visualOrientation = physicsOrientation
	-- Ownership probe: confirm BodyMover responsiveness before starting flight.
	-- In Studio (client=server) this passes instantly. In live, waits for
	-- SetNetworkOwner transfer to arrive from server.
	local ownershipConfirmed = false
	local probeStartTime = os.clock()
	local OWNERSHIP_PROBE_TIMEOUT = 3.0
	local OWNERSHIP_PROBE_INTERVAL = 0.05
	local probeOriginalMaxForce = if bodyVelocity ~= nil then bodyVelocity.MaxForce else Vector3.zero
	if bodyVelocity ~= nil then
		bodyVelocity.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
	end

	while not ownershipConfirmed do
		local elapsed = os.clock() - probeStartTime
		if elapsed > OWNERSHIP_PROBE_TIMEOUT then
			warn("[FIGHTER_OWNER] ownership probe timed out after 3s — starting flight anyway")
			break
		end

		-- Write a known test velocity and check if the physics engine responds
		local testVelocity = Vector3.new(0, 0.5, 0)
		if bodyVelocity ~= nil then
			bodyVelocity.Velocity = testVelocity
		end
		task.wait(OWNERSHIP_PROBE_INTERVAL)

		-- If we don't have the primary anymore, bail
		if primary == nil or primary.Parent == nil then
			FighterClient.deactivate()
			return
		end

		-- Check if the assembly responded to our BodyMover write.
		-- With ownership, the local physics engine processes it immediately.
		-- Without ownership, AssemblyLinearVelocity stays at whatever the server computes.
		local actualVelocity = primary.AssemblyLinearVelocity
		local responded = actualVelocity.Y > 0.1
		if responded then
			ownershipConfirmed = true
			print(string.format("[FIGHTER_OWNER] ownership confirmed in %.2fs", elapsed + OWNERSHIP_PROBE_INTERVAL))
		end
	end

	-- Zero out the probe velocity before starting real flight
	if bodyVelocity ~= nil then
		bodyVelocity.Velocity = Vector3.zero
		bodyVelocity.MaxForce = probeOriginalMaxForce
	end
	if primary.Parent == nil then
		FighterClient.deactivate()
		return
	end

	autoRollVisualDeg = 0
	visualYawOverDeg = 0
	visualPitchOverDeg = 0
	visualRollOverDeg = 0
	previousVisualYawRate = 0
	previousVisualPitchRate = 0
	currentSpeed = 0
	smoothedThrottleInput = 0
	physicalVelocity = primary.AssemblyLinearVelocity
	flightMode = "Flight"
	takeoffExitMode = "Flight"
	landingToggleHeld = false
	landingTransitionActive = false
	landingTransitionElapsed = 0
	landingTransitionFromLanding = false
	landingTransitionToLanding = false
	boostCharge = 1
	boostBlend = 0
	boostActive = false
	smoothedPitchRate = 0
	smoothedYawRate = 0
	smoothedRollRate = 0
	smoothedPitchAccel = 0
	smoothedYawAccel = 0
	smoothedRollAccel = 0
	smoothedForwardAccel = 0
	landingVerticalCommandSpeed = 0
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
	nextStreamRequestTime = 0

	takeoffRemaining = 0
	takeoffTargetY = primary.Position.Y
	takeoffLiftSpeed = 0
	takeoffVisualLockRemaining = 0
	flightMode = "Landing"
	takeoffExitMode = "Landing"
	exitAutoLandActive = false
	landingTransitionActive = false
	landingTransitionElapsed = 0
	landingTransitionFromLanding = true
	landingTransitionToLanding = true
	boostCharge = 1
	boostBlend = 0
	boostActive = false
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
		flightMode = "Takeoff"
		takeoffExitMode = "Landing"
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

		local cfg = activeTuning
		if cfg == nil then
			FighterClient.deactivate()
			return
		end
		local base = mdl.PrimaryPart
		if base == nil then
			FighterClient.deactivate()
			return
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
			mouseIdleNoInputTime = 0
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			UserInputService.MouseIconEnabled = true
			VehicleCamera.setFreelook(true)
			CombatHUD.showVehicleCursor(false)
		elseif not altHeld and freelookActive then
			freelookActive = false
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
			UserInputService.MouseIconEnabled = false
			VehicleCamera.setFreelook(false)
			mouseIdleNoInputTime = 0
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
		local preStepHorizontalVelocity = Vector3.new(physicalVelocity.X, 0, physicalVelocity.Z)
		if Workspace.StreamingEnabled then
			local now = os.clock()
			if now >= nextStreamRequestTime then
				nextStreamRequestTime = now + FIGHTER_STREAM_REQUEST_INTERVAL
				local lookAheadDistance = math.clamp(
					physicalVelocity.Magnitude * FIGHTER_STREAM_LOOKAHEAD_TIME,
					FIGHTER_STREAM_LOOKAHEAD_MIN,
					FIGHTER_STREAM_LOOKAHEAD_MAX
				)
				local requestPosition = base.Position + physicsOrientation.LookVector * lookAheadDistance
				task.spawn(function()
					pcall(function()
						localPlayer:RequestStreamAroundAsync(requestPosition)
					end)
				end)
			end
		end

		if dt > 0.25 then
			return
		end

		local inTakeoff = flightMode == "Takeoff"
		local inLanding = flightMode == "Landing"
		local cruiseMinSpeed = math.max(0, cfg.minSpeed)
		local cruiseMaxSpeed = math.max(cruiseMinSpeed, cfg.maxSpeed)
		local landingEntrySpeed = math.max(currentSpeed, physicalVelocity.Magnitude)
		local landingEligible = landingEntrySpeed >= LANDING_ENTRY_MIN_SPEED and landingEntrySpeed <= LANDING_ENTRY_MAX_SPEED

		local landingToggleDown = UserInputService:IsKeyDown(Enum.KeyCode.R)
		local landingTogglePressed = landingToggleDown and not landingToggleHeld
		landingToggleHeld = landingToggleDown
		if landingTogglePressed then
			if inLanding then
				landingTransitionActive = true
				landingTransitionElapsed = 0
				landingTransitionFromLanding = true
				landingTransitionToLanding = false
				exitAutoLandActive = false

				flightMode = "Takeoff"
				takeoffExitMode = "Flight"
				inTakeoff = true
				inLanding = false
				landingVerticalCommandSpeed = 0
				local launchHeight = math.max(0, cfg.fighterTakeoffHeight)
				local launchDuration = math.max(0.05, cfg.fighterTakeoffDuration)
				takeoffRemaining = launchDuration
				takeoffTargetY = base.Position.Y + launchHeight
				takeoffLiftSpeed = launchHeight / launchDuration
				takeoffVisualLockRemaining = LANDING_TRANSITION_DURATION + 0.2
				smoothedThrottleInput = 0
				physicsOrientation = levelOrientationYawOnly(physicsOrientation)
				visualOrientation = physicsOrientation
				resetFlightDynamicsVisuals()
				virtualCursorX = 0
				virtualCursorY = 0
				displayedCursorX = 0
				displayedCursorY = 0
				mouseIdleNoInputTime = 0
			elseif landingEligible and not inTakeoff then
				landingTransitionActive = true
				landingTransitionElapsed = 0
				landingTransitionFromLanding = false
				landingTransitionToLanding = true

				flightMode = "Landing"
				takeoffExitMode = "Landing"
				inTakeoff = false
				inLanding = true
				engineKillActive = false
				currentSpeed = math.min(currentSpeed, LANDING_SEQUENCE_MAX_SPEED)
				landingVerticalCommandSpeed = physicalVelocity.Y
			end
		end

		local landingTransitionBlend: number
		if landingTransitionActive then
			landingTransitionElapsed += dt
			local rawAlpha = if LANDING_TRANSITION_DURATION > 0 then landingTransitionElapsed / LANDING_TRANSITION_DURATION else 1
			local alpha = smoothstep01(rawAlpha)
			local fromValue = if landingTransitionFromLanding then 1 else 0
			local toValue = if landingTransitionToLanding then 1 else 0
			landingTransitionBlend = fromValue + (toValue - fromValue) * alpha
			if rawAlpha >= 1 then
				landingTransitionActive = false
				landingTransitionBlend = toValue
			end
		else
			landingTransitionBlend = if inLanding then 1 else 0
		end

		local verticalInput = 0
		if inLanding then
			local eDown = UserInputService:IsKeyDown(Enum.KeyCode.E)
			local qDown = UserInputService:IsKeyDown(Enum.KeyCode.Q)
			if eDown and not qDown then
				verticalInput = 1
			elseif qDown and not eDown then
				verticalInput = -1
			end
		end

		local landingMinSpeed = -LANDING_REVERSE_MAX_SPEED
		local landingMaxSpeed = math.min(LANDING_SEQUENCE_MAX_SPEED, cruiseMaxSpeed)
		local boostDuration = math.max(0.1, cfg.boostDuration)
		local boostCooldown = math.max(0.1, cfg.boostCooldown)
		local configuredBoostMultiplier = math.max(1, cfg.boostSpeedMultiplier)
		local boostAllowed = cfg.boostEnabled and not inLanding and not inTakeoff and not engineKillActive
		local boostHeld = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
		local wantsBoost = boostAllowed and boostHeld and throttle > 0
		boostReuseCooldown = math.max(0, boostReuseCooldown - dt)
		local canStartBoost = boostActive or (boostCharge >= FIGHTER_BOOST_MIN_START_CHARGE and boostReuseCooldown <= 0)
		if wantsBoost and canStartBoost then
			boostActive = true
		elseif not wantsBoost then
			boostActive = false
		end
		if boostActive then
			boostCharge = math.max(0, boostCharge - dt / boostDuration)
			if boostCharge <= 0 then
				boostActive = false
			end
		else
			boostCharge = math.min(1, boostCharge + dt / boostCooldown)
		end
		if boostActive ~= prevBoostForEvents then
			if not boostActive and prevBoostForEvents then
				boostReuseCooldown = FIGHTER_BOOST_REUSE_COOLDOWN
			end
			prevBoostForEvents = boostActive
			if activeProfileController ~= nil then
				activeProfileController:onEvent(if boostActive then "boost_start" else "boost_end", nil)
			end
		end
		local targetBoostBlend = if boostActive then 1 else 0
		local boostBlendAlpha = 1 - math.exp(-FIGHTER_BOOST_BLEND_RESPONSE * dt)
		boostBlend += (targetBoostBlend - boostBlend) * boostBlendAlpha
		local effectiveBoostMultiplier = 1 + (configuredBoostMultiplier - 1) * boostBlend
		local minSpeed = cruiseMinSpeed + (landingMinSpeed - cruiseMinSpeed) * landingTransitionBlend
		local maxSpeed = (cruiseMaxSpeed + (landingMaxSpeed - cruiseMaxSpeed) * landingTransitionBlend) * effectiveBoostMultiplier

		local speedContext: string? = nil
		if inLanding and exitAutoLandActive then
			speedContext = "Auto-Landing..."
		elseif inLanding then
			speedContext = "Press R: Leave Landing Sequence | E/Q Alt | F: Exit"
		elseif landingEligible then
			speedContext = "Press R: Landing Sequence"
		end
		if engineKillActive then
			speedContext = if speedContext ~= nil then "ENGINES OFF | " .. speedContext else "ENGINES OFF"
		end
		local boostContext: string? = nil
		if cfg.boostEnabled and not inLanding then
			local boostPct = math.floor(math.clamp(boostCharge, 0, 1) * 100 + 0.5)
			if boostActive then
				boostContext = string.format("BOOST %d%%", boostPct)
			elseif boostPct < 100 then
				boostContext = string.format("Shift: Boost (%d%%)", boostPct)
			else
				boostContext = "Shift: Boost"
			end
		end
		if speedContext ~= nil and boostContext ~= nil then
			speedContext ..= " | " .. boostContext
		elseif speedContext == nil then
			speedContext = boostContext
		end
		CombatHUD.setSpeedContext(speedContext)

		do
			local stepDt = math.clamp(dt, 1 / 240, 1 / 20)
			if takeoffVisualLockRemaining > 0 then
				takeoffVisualLockRemaining = math.max(0, takeoffVisualLockRemaining - stepDt)
			end

			if inTakeoff then
				smoothedForwardAccel = 0
				smoothedYawAccel = 0
				smoothedPitchAccel = 0
				smoothedRollAccel = 0
				local takeoffTargetVelocity = Vector3.new(0, takeoffLiftSpeed, 0)
				if useForceFlight and vectorForce ~= nil then
					local forceGain = cfg.fighterForceVelocityGain
					local maxAccel = cfg.fighterForceMaxAccel
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
				takeoffRemaining -= stepDt
				if takeoffRemaining <= 0 or base.Position.Y >= takeoffTargetY - 0.5 then
					inTakeoff = false
					if takeoffExitMode == "Landing" then
						flightMode = "Landing"
						inLanding = true
						currentSpeed = 0
						physicalVelocity = Vector3.zero
					else
						landingTransitionActive = false
						landingTransitionElapsed = 0
						landingTransitionFromLanding = false
						landingTransitionToLanding = false
						physicsOrientation = levelOrientationYawOnly(physicsOrientation)
						visualOrientation = physicsOrientation
						resetFlightDynamicsVisuals()
						virtualCursorX = 0
						virtualCursorY = 0
						displayedCursorX = 0
						displayedCursorY = 0
						mouseIdleNoInputTime = 0
						takeoffVisualLockRemaining = FIGHTER_POST_LANDING_VISUAL_LOCK
						flightMode = "Flight"
						inLanding = false
						currentSpeed = math.max(currentSpeed, minSpeed * 0.3)
						physicalVelocity = physicsOrientation.LookVector * currentSpeed
					end
				end
			else
				local desiredThrottleInput = throttle
				if desiredThrottleInput == 0 then
					-- Neutral throttle must stop acceleration immediately.
					smoothedThrottleInput = 0
				else
					local throttleSpoolUp = cfg.fighterThrottleSpoolUp
					local throttleSpoolDown = cfg.fighterThrottleSpoolDown
					local spoolRate =
						if math.abs(desiredThrottleInput) > math.abs(smoothedThrottleInput) then throttleSpoolUp else throttleSpoolDown
					local throttleAlpha = 1 - math.exp(-spoolRate * stepDt)
					smoothedThrottleInput += (desiredThrottleInput - smoothedThrottleInput) * throttleAlpha
					local throttleDeadzone = cfg.fighterThrottleDeadzone
					if math.abs(smoothedThrottleInput) < throttleDeadzone then
						smoothedThrottleInput = 0
					end
				end

				if smoothedThrottleInput > 0 then
					local accelToMax = (maxSpeed - minSpeed) / FIGHTER_TIME_TO_MAX_SPEED
					local boostAccelMultiplier = 1 + (configuredBoostMultiplier - 1) * boostBlend * 0.9
					local accelRate = math.max(cfg.acceleration, accelToMax) * boostAccelMultiplier
					currentSpeed = math.min(currentSpeed + accelRate * smoothedThrottleInput * stepDt, maxSpeed)
				elseif smoothedThrottleInput < 0 then
					currentSpeed = math.max(currentSpeed - cfg.deceleration * math.abs(smoothedThrottleInput) * stepDt, minSpeed)
				else
					local coastDeceleration = cfg.coastDeceleration
					if type(coastDeceleration) == "number" and coastDeceleration > 0 then
						currentSpeed = math.max(currentSpeed - coastDeceleration * stepDt, minSpeed)
					elseif landingTransitionBlend > 0.001 then
						-- In landing mode, neutral throttle follows actual forward motion to avoid release notches.
						currentSpeed = math.clamp(physicalVelocity:Dot(physicsOrientation.LookVector), minSpeed, maxSpeed)
					else
						-- Hold cruise target through turns so straightening regains prior speed.
						if currentSpeed > maxSpeed then
							local overcapBleed = cfg.deceleration * 0.8
							currentSpeed = math.max(currentSpeed - overcapBleed * stepDt, maxSpeed)
						else
							currentSpeed = math.clamp(currentSpeed, minSpeed, maxSpeed)
						end
					end
				end

				local speedRange = math.max(1, maxSpeed - minSpeed)
				local speedFrac = math.clamp((currentSpeed - minSpeed) / speedRange, 0, 1)
				local speedAuthority = FIGHTER_SPEED_AUTHORITY_MIN
					+ (FIGHTER_SPEED_AUTHORITY_MAX - FIGHTER_SPEED_AUTHORITY_MIN) * (speedFrac ^ FIGHTER_SPEED_AUTHORITY_GAMMA)
				speedAuthority *= 1 + 0.12 * boostBlend
				local turnScaleMin = cfg.turnRateSpeedScaleMin
				local turnScaleMax = cfg.turnRateSpeedScaleMax
				local turnScale = turnScaleMax + (turnScaleMin - turnScaleMax) * speedFrac
				if engineKillActive then
					speedAuthority = 1.0
					turnScale = 1.0
				end

				local desiredYaw = yawInput * cfg.yawRate * turnScale * speedAuthority
				local noseUpBoost = if pitchInput < 0 then FIGHTER_NOSE_UP_PITCH_RATE_BOOST else 1
				local desiredPitch = pitchInput * cfg.pitchRate * turnScale * noseUpBoost * speedAuthority
				local desiredRoll = rollInput * cfg.rollRate * speedAuthority
				desiredPitch *= (1 - landingTransitionBlend)
				desiredRoll *= (1 - landingTransitionBlend)
				local yawInputMag = math.abs(yawInput)
				local pitchInputMag = math.abs(pitchInput)
				local effectivePitchInputMag = math.clamp(pitchInputMag * noseUpBoost, 0, 1.5)
				local turnInputMag = math.clamp(math.sqrt(yawInput * yawInput + effectivePitchInputMag * effectivePitchInputMag), 0, 1)
				local pitchDominance = math.clamp(effectivePitchInputMag - yawInputMag, 0, 1)

				local resp = math.max(0.01, cfg.angularResponsiveness)
				local alpha = 1 - math.exp(-resp * stepDt)
				local yawAccelLimit = cfg.fighterYawRateAccelLimit
				local pitchAccelLimit = cfg.fighterPitchRateAccelLimit
				local rollAccelLimit = cfg.fighterRollRateAccelLimit
				yawAccelLimit *= speedAuthority
				pitchAccelLimit *= speedAuthority
				rollAccelLimit *= speedAuthority
				local yawDelta = (desiredYaw - smoothedYawRate) * alpha
				local pitchDelta = (desiredPitch - smoothedPitchRate) * alpha
				local rollDelta = (desiredRoll - smoothedRollRate) * alpha
				smoothedYawRate += math.clamp(yawDelta, -yawAccelLimit * stepDt, yawAccelLimit * stepDt)
				smoothedPitchRate += math.clamp(pitchDelta, -pitchAccelLimit * stepDt, pitchAccelLimit * stepDt)
				smoothedRollRate += math.clamp(rollDelta, -rollAccelLimit * stepDt, rollAccelLimit * stepDt)
				local angularDamping = cfg.fighterAngularDamping
				if angularDamping > 0 then
					local function computeAxisDampingFactor(axisRate: number, axisCap: number): number
						local carry = math.clamp(math.abs(axisRate) / math.max(1, axisCap), 0, 1) * speedFrac
						local effectiveDamping = angularDamping * (1 - carry * FIGHTER_TURN_EXIT_CARRY_DAMPING_RELIEF)
						return math.exp(-math.max(0.05, effectiveDamping) * stepDt)
					end
					if math.abs(desiredYaw) < 0.001 then
						smoothedYawRate *= computeAxisDampingFactor(smoothedYawRate, cfg.yawRate)
					end
					if math.abs(desiredPitch) < 0.001 then
						smoothedPitchRate *= computeAxisDampingFactor(smoothedPitchRate, cfg.pitchRate)
					end
					if math.abs(desiredRoll) < 0.001 then
						smoothedRollRate *= computeAxisDampingFactor(smoothedRollRate, cfg.rollRate)
					end
				end
				local yawCap = math.max(1, math.abs(cfg.yawRate))
				local pitchCap = math.max(1, math.abs(cfg.pitchRate))
				local rollCap = math.max(1, math.abs(cfg.rollRate))
				smoothedYawRate = math.clamp(smoothedYawRate, -yawCap, yawCap)
				smoothedPitchRate = math.clamp(smoothedPitchRate, -pitchCap, pitchCap)
				smoothedRollRate = math.clamp(smoothedRollRate, -rollCap, rollCap)

				local rotDelta = CFrame.Angles(
					math.rad(smoothedPitchRate) * stepDt,
					math.rad(smoothedYawRate) * stepDt,
					math.rad(smoothedRollRate) * stepDt
				)
				physicsOrientation = physicsOrientation * rotDelta
				if landingTransitionBlend > 0 then
					local flatLook = Vector3.new(physicsOrientation.LookVector.X, 0, physicsOrientation.LookVector.Z)
					if flatLook.Magnitude > 1e-4 then
						local targetLevel = CFrame.lookAt(Vector3.zero, flatLook.Unit, Vector3.yAxis)
						local levelAlpha = (1 - math.exp(-10 * stepDt)) * landingTransitionBlend
						physicsOrientation = physicsOrientation:Lerp(targetLevel, levelAlpha)
					end
					local landingRateDamping = math.exp(-12 * stepDt * landingTransitionBlend)
					smoothedPitchRate *= landingRateDamping
					smoothedRollRate *= landingRateDamping
				end

				if levelOffActive then
					local targetLevel = levelOrientationYawOnly(physicsOrientation)
					local levelAlpha = 1 - math.exp(-LEVEL_OFF_SLERP_RATE * stepDt)
					physicsOrientation = physicsOrientation:Lerp(targetLevel, levelAlpha)
					smoothedPitchRate *= (1 - levelAlpha)
					smoothedRollRate *= (1 - levelAlpha)
					local angleDiff = math.acos(math.clamp(
						physicsOrientation.UpVector:Dot(Vector3.yAxis), -1, 1
					))
					if angleDiff < math.rad(1) then
						levelOffActive = false
						physicsOrientation = targetLevel
					end
				end

				if inLanding and exitAutoLandActive then
					-- Auto-land controls velocity entirely — skip normal computation.
				elseif engineKillActive then
					-- Engine kill: coast on momentum. No thrust, no alignment.
					-- Just drag + gravity. Player can freely rotate.
					local worldGravity = cfg.fighterWorldGravity
					physicalVelocity += Vector3.new(0, -worldGravity, 0) * stepDt
					physicalVelocity *= math.exp(-ENGINE_KILL_DRAG * stepDt)
				else
					local forward = physicsOrientation.LookVector
					local right = physicsOrientation.RightVector
					local up = physicsOrientation.UpVector
					local vForward = physicalVelocity:Dot(forward)
					local vRight = physicalVelocity:Dot(right)
					local vUp = physicalVelocity:Dot(up)
					local velocityAlignRate = cfg.fighterVelocityAlignRate
					local turnAlignBoost = cfg.fighterTurnAlignBoost
					local coordinatedTurnFactor = 0
					if landingTransitionBlend < 0.999 then
						local coordinatedPullInput = math.clamp(-pitchInput, 0, 1)
						local bankAmount = 1 - math.abs(up:Dot(Vector3.yAxis))
						coordinatedTurnFactor = math.clamp(coordinatedPullInput * bankAmount * speedFrac, 0, 1)
						coordinatedTurnFactor *= (1 - landingTransitionBlend)
					end
					velocityAlignRate += turnInputMag * turnAlignBoost
					velocityAlignRate += pitchDominance * turnAlignBoost * FIGHTER_NOSE_UP_ALIGN_BOOST
					velocityAlignRate += coordinatedTurnFactor * FIGHTER_COORDINATED_ALIGN_BOOST
					local alignAlpha = 1 - math.exp(-velocityAlignRate * stepDt)
					local turnSpeedPenalty = cfg.fighterTurnSpeedPenalty
					turnSpeedPenalty *= (1 - coordinatedTurnFactor * FIGHTER_COORDINATED_TURN_PENALTY_RELIEF)
					local turnPenaltyInput = math.clamp(yawInputMag + effectivePitchInputMag * 0.28, 0, 1)
					local targetForwardSpeed = currentSpeed * (1 - turnPenaltyInput * math.clamp(turnSpeedPenalty, 0, 0.9))
					local desiredForward = vForward + (targetForwardSpeed - vForward) * alignAlpha
					local forwardAccelLimit = cfg.fighterForwardAccelLimit
					local forwardDecelLimit = cfg.fighterForwardDecelLimit
					local forwardDelta = desiredForward - vForward
					local forwardLimit = if forwardDelta >= 0 then forwardAccelLimit else forwardDecelLimit
					local maxForwardStep = forwardLimit * stepDt
					vForward += math.clamp(forwardDelta, -maxForwardStep, maxForwardStep)
					local sideSlipDamping = cfg.fighterSideSlipDamping
					local turnSlipDampingBoost = cfg.fighterTurnSlipDampingBoost
					sideSlipDamping += turnInputMag * turnSlipDampingBoost
					local verticalSlipDamping = cfg.fighterVerticalSlipDamping
					local turnVerticalDampingBoost = cfg.fighterTurnVerticalDampingBoost
					verticalSlipDamping += turnInputMag * turnVerticalDampingBoost
					vRight *= math.exp(-sideSlipDamping * stepDt)
					vUp *= math.exp(-verticalSlipDamping * stepDt)
					local yawRef = math.max(1, math.abs(cfg.yawRate))
					local pitchRef = math.max(1, math.abs(cfg.pitchRate))
					local turnRatio = math.clamp(
						math.abs(smoothedYawRate) / yawRef + (math.abs(smoothedPitchRate) / pitchRef) * 0.55,
						0,
						1
					)
					local turnEnergyLoss = cfg.fighterTurnEnergyLoss
					local inducedDrag = cfg.fighterInducedDrag
					local slipRatio = math.sqrt(vRight * vRight + vUp * vUp) / math.max(1, math.abs(vForward))
					vForward -= slipRatio * slipRatio * inducedDrag * stepDt
					vForward -= turnRatio * turnEnergyLoss * stepDt
					local vForwardFlight = math.max(0, vForward)
					local vForwardLanding = math.clamp(vForward, -LANDING_REVERSE_MAX_SPEED, maxSpeed)
					vForward = vForwardFlight + (vForwardLanding - vForwardFlight) * landingTransitionBlend

					physicalVelocity = forward * vForward + right * vRight + up * vUp
					local velocityDirAlignBase = cfg.fighterVelocityDirAlignBase
					local velocityDirAlignTurnBoost = cfg.fighterVelocityDirAlignTurnBoost
					local dirAlignRate = velocityDirAlignBase + turnInputMag * velocityDirAlignTurnBoost
					dirAlignRate += pitchDominance * velocityDirAlignTurnBoost * FIGHTER_NOSE_UP_ALIGN_BOOST
					if dirAlignRate > 0 then
						local speedMagnitude = physicalVelocity.Magnitude
						if speedMagnitude > 1 then
							local velDir = physicalVelocity / speedMagnitude
							local dirAlpha = 1 - math.exp(-dirAlignRate * stepDt)
							local blendedDir = velDir:Lerp(forward, dirAlpha)
							if blendedDir.Magnitude > 1e-4 then
								physicalVelocity = blendedDir.Unit * speedMagnitude
							end
						end
					end
					local worldGravity = cfg.fighterWorldGravity
					local liftCoefficient = cfg.fighterLiftCoefficient
					local baseDrag = cfg.fighterBaseDrag
					local liftAccel = 0
					if landingTransitionBlend < 0.999 then
						local pullInput = math.clamp(-pitchInput, 0, 1)
						local bankAmount = 1 - math.abs(up:Dot(Vector3.yAxis))
						local maneuverLiftScale =
							1 + pullInput * FIGHTER_MANEUVER_LIFT_PULL_BOOST + bankAmount * pullInput * FIGHTER_MANEUVER_LIFT_BANK_BOOST
						liftAccel = math.max(0, vForward) * liftCoefficient * maneuverLiftScale * (1 - landingTransitionBlend)
					end
					physicalVelocity += (up * liftAccel + Vector3.new(0, -worldGravity, 0)) * stepDt
					physicalVelocity *= math.exp(-baseDrag * stepDt)
					local maxVelocityMagnitude = maxSpeed * 1.15
					local velocityMagnitude = physicalVelocity.Magnitude
					if velocityMagnitude > maxVelocityMagnitude and maxVelocityMagnitude > 0 then
						physicalVelocity = physicalVelocity.Unit * maxVelocityMagnitude
					end
				end

				if flightRayParams ~= nil then
					local collisionRadius = cfg.collisionRadius
					local groundRay = Workspace:Raycast(base.Position + Vector3.new(0, 50, 0), Vector3.new(0, -100, 0), flightRayParams)
					if groundRay ~= nil then
						local minAlt = if inLanding
							then (groundRay.Position.Y + LANDING_GROUND_CLEARANCE)
							else (groundRay.Position.Y + collisionRadius + 2)
						if base.Position.Y < minAlt then
							if inLanding then
								local yVelocity = if physicalVelocity.Y < 0 then math.max(physicalVelocity.Y, -1.5) else physicalVelocity.Y
								if verticalInput == 0 then
									local altError = minAlt - base.Position.Y
									yVelocity = math.max(yVelocity, math.clamp(altError * 10, 0, 6))
								end
								physicalVelocity = Vector3.new(physicalVelocity.X, yVelocity, physicalVelocity.Z)
							else
								if engineKillActive then
									engineKillActive = false
									currentSpeed = engineKillSavedSpeed
								end
								physicalVelocity = Vector3.new(physicalVelocity.X, math.max(physicalVelocity.Y, 30), physicalVelocity.Z)
								currentSpeed = math.max(currentSpeed * 0.7, minSpeed)
								physicsOrientation = physicsOrientation * CFrame.Angles(math.rad(5), 0, 0)
								-- Prevent the ground correction from pitching past 20 degrees up from level
								local correctedLookY = physicsOrientation.LookVector.Y
								if correctedLookY > 0.34 then -- sin(20°) ≈ 0.34
									physicsOrientation = levelOrientationYawOnly(physicsOrientation)
										* CFrame.Angles(math.rad(20), 0, 0)
								end
								print(string.format("[P10_COLLISION] type=%s speed=%.0f", "ground", currentSpeed))
							end
						end
					end
				end

				if inLanding and exitAutoLandActive then
					-- After exit has fired, just freeze everything until server deactivates
					if exitAutoLandDone then
						base.Anchored = true
					else
						-- Kill thrust
						currentSpeed = 0
						smoothedThrottleInput = 0

						-- 3-point ground probe for surface normal
						local headingFwd = exitAutoLandHeading.LookVector
						local headingRight = exitAutoLandHeading.RightVector
						local mdlRef = activeModel :: Model
						local _, bSize = mdlRef:GetBoundingBox()
						local probeHalfLen = bSize.Z * 0.4
						local probeHalfWid = bSize.X * 0.4
						local rayDown = Vector3.new(0, -510, 0)
						local rayUp = Vector3.new(0, 10, 0)
						local landNormal = Vector3.yAxis
						if flightRayParams ~= nil then
							local hitC = Workspace:Raycast(base.Position + rayUp, rayDown, flightRayParams)
							if hitC ~= nil then
								exitAutoLandTargetY = hitC.Position.Y
							else
								exitAutoLandActive = false
							end
							local pFront = base.Position + headingFwd * probeHalfLen + rayUp
							local pLeftRear = base.Position - headingFwd * probeHalfLen - headingRight * probeHalfWid + rayUp
							local pRightRear = base.Position - headingFwd * probeHalfLen + headingRight * probeHalfWid + rayUp
							local hitF = Workspace:Raycast(pFront, rayDown, flightRayParams)
							local hitL = Workspace:Raycast(pLeftRear, rayDown, flightRayParams)
							local hitR = Workspace:Raycast(pRightRear, rayDown, flightRayParams)
							if hitF ~= nil and hitL ~= nil and hitR ~= nil then
								local v1 = hitL.Position - hitF.Position
								local v2 = hitR.Position - hitF.Position
								local triNormal = v1:Cross(v2)
								if triNormal.Magnitude > 1e-4 then
									triNormal = triNormal.Unit
									if triNormal.Y < 0 then triNormal = -triNormal end
									landNormal = triNormal
								end
							end
						end

						-- Compute target landing CFrame: on the ground, aligned to surface
						local boundsCF, boundsSize = mdlRef:GetBoundingBox()
						local halfHeight = boundsSize.Y * 0.5
						local landY = exitAutoLandTargetY + halfHeight
						local surfaceRight = headingFwd:Cross(landNormal)
						local landCFrame: CFrame
						if surfaceRight.Magnitude > 1e-4 then
							surfaceRight = surfaceRight.Unit
							local surfaceForward = landNormal:Cross(surfaceRight).Unit
							landCFrame = CFrame.lookAt(
								Vector3.new(base.Position.X, landY, base.Position.Z),
								Vector3.new(base.Position.X, landY, base.Position.Z) + surfaceForward,
								landNormal
							)
						else
							landCFrame = CFrame.new(base.Position.X, landY, base.Position.Z) * physicsOrientation.Rotation
						end

						-- Two-phase landing:
						local distToLandY = base.Position.Y - landY
						if distToLandY > 3 then
							-- Phase 1: descend with smoothstep, start aligning
							local totalDrop = math.max(1, exitAutoLandStartY - landY)
							local currentDrop = math.clamp(exitAutoLandStartY - base.Position.Y, 0, totalDrop)
							local progress = currentDrop / totalDrop
							local speedCurve = 6 * progress * (1 - progress)
							local descentSpeed = math.max(2, speedCurve * AUTO_LAND_MAX_SPEED / 1.5)
							physicalVelocity = Vector3.new(0, -descentSpeed, 0)
							local levelAlpha = 1 - math.exp(-4 * stepDt)
							physicsOrientation = physicsOrientation:Lerp(landCFrame.Rotation + physicsOrientation.Position, levelAlpha)
							smoothedPitchRate *= (1 - levelAlpha)
							smoothedRollRate *= (1 - levelAlpha)
						else
							-- Phase 2: push gently down, align aggressively.
							-- Let physics collision stop the ship on the actual surface.
							physicalVelocity = Vector3.new(0, -3, 0)
							local levelAlpha = 1 - math.exp(-20 * stepDt)
							physicsOrientation = physicsOrientation:Lerp(landCFrame.Rotation + physicsOrientation.Position, levelAlpha)
							smoothedPitchRate = 0
							smoothedRollRate = 0
							-- Wait at least 0.5s in phase 2 for alignment + physics to settle
							local timeInAutoLand = os.clock() - exitAutoLandStartClock
							local actualYVel = base.AssemblyLinearVelocity.Y
							local collisionHolding = actualYVel > -1 and timeInAutoLand > 0.5
							if collisionHolding then
								-- On the surface — stop pushing, snap orientation, exit
								physicsOrientation = landCFrame.Rotation + physicsOrientation.Position
								physicsOrientation = landCFrame.Rotation + physicsOrientation.Position
								physicalVelocity = Vector3.zero
								currentSpeed = 0
								if bodyVelocity ~= nil then
									bodyVelocity.Velocity = Vector3.zero
								end
								boostActive = false
								smoothedThrottleInput = 0
								if activeModel ~= nil then
									activeModel:SetAttribute("VehicleBoosting", false)
								end
								if vehicleExitRemote ~= nil and activeEntityId ~= nil then
									print("[P10_AUTOLAND] settled - firing exit remote")
									vehicleExitRemote:FireServer()
								end
								exitAutoLandDone = true
							end
						end
					end
				elseif inLanding then
					-- Flat heading axes from current orientation
					local fwd3 = physicsOrientation.LookVector
					local flatFwd = Vector3.new(fwd3.X, 0, fwd3.Z)
					if flatFwd.Magnitude > 1e-4 then flatFwd = flatFwd.Unit
					else flatFwd = Vector3.new(0, 0, -1) end
					local right3 = physicsOrientation.RightVector
					local flatRight = Vector3.new(right3.X, 0, right3.Z)
					if flatRight.Magnitude > 1e-4 then flatRight = flatRight.Unit
					else flatRight = Vector3.new(1, 0, 0) end

					-- Decompose horizontal velocity into heading axes
					local hVel = if throttle == 0 then preStepHorizontalVelocity else Vector3.new(physicalVelocity.X, 0, physicalVelocity.Z)
					local fwdSpeed = hVel:Dot(flatFwd)
					local sideSpeed = hVel:Dot(flatRight)

					-- Damp side-slip when moving forward/back (heading alignment)
					if math.abs(fwdSpeed) > 2 then
						sideSpeed *= math.exp(-LANDING_HEADING_ALIGN_RATE * stepDt)
					end

					-- No throttle: brake forward speed to zero
					if throttle == 0 then
						if math.abs(fwdSpeed) > LANDING_STOP_SPEED_THRESHOLD then
							local brake = LANDING_IDLE_BRAKE_DECEL * stepDt
							fwdSpeed = if fwdSpeed > 0 then math.max(0, fwdSpeed - brake) else math.min(0, fwdSpeed + brake)
						else
							fwdSpeed = 0
							currentSpeed = 0
						end
					end

					-- S brakes to zero before reversing, W brakes to zero before going forward
					if throttle < 0 and fwdSpeed > 1 then
						fwdSpeed = math.max(0, fwdSpeed - LANDING_REVERSE_BRAKE_DECEL * stepDt)
						currentSpeed = fwdSpeed
					elseif throttle > 0 and fwdSpeed < -1 then
						fwdSpeed = math.min(0, fwdSpeed + LANDING_REVERSE_BRAKE_DECEL * stepDt)
						currentSpeed = fwdSpeed
					end

					-- A/D strafe
					local strafeA = UserInputService:IsKeyDown(Enum.KeyCode.A)
					local strafeD = UserInputService:IsKeyDown(Enum.KeyCode.D)
					local strafeInput = (if strafeD then 1 else 0) - (if strafeA then 1 else 0)
					if strafeInput ~= 0 then
						sideSpeed += strafeInput * LANDING_STRAFE_ACCEL * stepDt
						sideSpeed = math.clamp(sideSpeed, -LANDING_STRAFE_MAX_SPEED, LANDING_STRAFE_MAX_SPEED)
					elseif math.abs(sideSpeed) > 0.5 then
						sideSpeed *= math.exp(-LANDING_STRAFE_DAMPING * stepDt)
					else
						sideSpeed = 0
					end

					-- Reconstruct horizontal velocity along current heading
					local horizontalVelocity = flatFwd * fwdSpeed + flatRight * sideSpeed
					if throttle == 0 and strafeInput == 0 and horizontalVelocity.Magnitude < LANDING_STOP_SPEED_THRESHOLD then
						horizontalVelocity = Vector3.zero
						currentSpeed = 0
					end

					-- Vertical input (E/Q)
					local targetVerticalSpeed = verticalInput * LANDING_VERTICAL_SPEED * landingTransitionBlend
					local verticalCommandResponse = math.max(0.05, LANDING_VERTICAL_COMMAND_RESPONSE * landingTransitionBlend)
					local verticalCommandAlpha = 1 - math.exp(-verticalCommandResponse * stepDt)
					landingVerticalCommandSpeed += (targetVerticalSpeed - landingVerticalCommandSpeed) * verticalCommandAlpha
					local verticalDelta = landingVerticalCommandSpeed - physicalVelocity.Y
					local maxVerticalStep = LANDING_VERTICAL_ACCEL * stepDt
					local nextVerticalSpeed = physicalVelocity.Y + math.clamp(verticalDelta, -maxVerticalStep, maxVerticalStep)
					if verticalInput == 0 and math.abs(nextVerticalSpeed) < 1 and math.abs(landingVerticalCommandSpeed) < 0.5 then
						nextVerticalSpeed = 0
					end
					physicalVelocity = Vector3.new(horizontalVelocity.X, nextVerticalSpeed, horizontalVelocity.Z)
					if throttle == 0 and verticalInput == 0 and strafeInput == 0 and physicalVelocity.Magnitude < LANDING_STOP_SPEED_THRESHOLD then
						physicalVelocity = Vector3.zero
						currentSpeed = 0
					end
				end

				if inLanding then
					if vectorForce ~= nil then
						vectorForce.Enabled = false
						vectorForce.Force = Vector3.zero
					end
					if bodyVelocity ~= nil then
						bodyVelocity.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
						-- Pendulum sway: wobble angular velocity → lateral position drift
						local swayVel = Vector3.zero
						if math.abs(wobbleRollVel) > 0.01 or math.abs(wobblePitchVel) > 0.01 then
							local pivotScale = LANDING_WOBBLE_PIVOT_HEIGHT * math.pi / 180
							local rDir = physicsOrientation.RightVector
							local fDir = physicsOrientation.LookVector
							swayVel = Vector3.new(rDir.X, 0, rDir.Z) * (wobbleRollVel * pivotScale)
								+ Vector3.new(-fDir.X, 0, -fDir.Z) * (wobblePitchVel * pivotScale)
						end
						-- Idle hover noise: Perlin-driven positional drift
						local hoverSpeedFrac = math.clamp(physicalVelocity.Magnitude / HOVER_NOISE_SPEED_FADE, 0, 1)
						local posFade = math.clamp(1 - hoverSpeedFrac, 0, 1)
						if posFade > 0.01 then
							local noiseX = math.noise(hoverNoiseClock, 3.1, 0) * HOVER_NOISE_LATERAL_AMP * posFade
							local noiseZ = math.noise(hoverNoiseClock, 0, 5.7) * HOVER_NOISE_LATERAL_AMP * posFade
							local noiseY = math.noise(hoverNoiseClock, 9.2, 0) * HOVER_NOISE_VERTICAL_AMP * posFade
							swayVel += Vector3.new(noiseX, noiseY, noiseZ)
						end
						bodyVelocity.Velocity = physicalVelocity + swayVel
					end
				elseif useForceFlight and vectorForce ~= nil then
					local forceGain = cfg.fighterForceVelocityGain
					local maxAccel = cfg.fighterForceMaxAccel
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

				-- Orientation feedback: blend virtual orientation toward actual to prevent divergence.
				-- In Studio (client=server), BodyGyro tracks virtual perfectly — no divergence.
				-- In live, BodyGyro P=50000/D=1000 can lag 1-3 degrees during fast turns.
				-- The velocity is computed from virtual forward, but the model/camera show actual forward.
				-- Without this feedback, the pilot sees the nose pointing one way but flying another.
				if not inTakeoff and not inLanding and takeoffVisualLockRemaining <= 0 then
					local actualRotation = base.CFrame - base.CFrame.Position
					local angleBetween = math.acos(math.clamp(
						physicsOrientation.LookVector:Dot(actualRotation.LookVector), -1, 1
					))
					if angleBetween > math.rad(0.5) then
						-- Blend toward actual at a moderate rate.
						-- Too fast = fights the BodyGyro and causes oscillation.
						-- Too slow = divergence persists through turns.
						-- Lower feedback rate avoids fighting turn response in live.
						local orientFeedbackAlpha = 1 - math.exp(-1.5 * stepDt)
						physicsOrientation = physicsOrientation:Lerp(actualRotation, orientFeedbackAlpha)
					end
				end
			end
		end

		local accelDt = math.max(dt, 1 / 240)
		local yawAccelForVisual = math.clamp((smoothedYawRate - previousVisualYawRate) / accelDt, -420, 420)
		local pitchAccelForVisual = math.clamp((smoothedPitchRate - previousVisualPitchRate) / accelDt, -420, 420)
		previousVisualYawRate = smoothedYawRate
		previousVisualPitchRate = smoothedPitchRate

		local autoBankMaxAngle = math.max(0, cfg.autoBankMaxAngle)
		local autoBankYawRateRef = math.max(1, math.abs(cfg.autoBankYawRateRef))
		local landingRollScale = 1 - (1 - FIGHTER_LANDING_VISUAL_ROLL_SCALE) * landingTransitionBlend
		local landingPitchScale = 1 - (1 - FIGHTER_LANDING_VISUAL_PITCH_SCALE) * landingTransitionBlend
		local targetAutoRollDeg = math.clamp(
			(smoothedYawRate / autoBankYawRateRef) * autoBankMaxAngle * landingRollScale,
			-autoBankMaxAngle,
			autoBankMaxAngle
		)
		local autoBankRate = math.max(0, cfg.autoBankRate)
		if autoBankRate <= 0 then
			autoRollVisualDeg = targetAutoRollDeg
		else
			local maxStepDeg = autoBankRate * dt
			local deltaDeg = math.clamp(targetAutoRollDeg - autoRollVisualDeg, -maxStepDeg, maxStepDeg)
			autoRollVisualDeg += deltaDeg
		end

		local speedForVisualSlip = math.max(1, physicalVelocity.Magnitude)
		local sideSlipNorm = math.clamp(physicalVelocity:Dot(physicsOrientation.RightVector) / speedForVisualSlip, -1, 1)
		local verticalSlipNorm = math.clamp(physicalVelocity:Dot(physicsOrientation.UpVector) / speedForVisualSlip, -1, 1)
		local visualYawRateGain = cfg.fighterVisualYawRateGain
		local visualPitchRateGain = cfg.fighterVisualPitchRateGain
		local visualYawAccelGain = cfg.fighterVisualYawAccelGain
		local visualPitchAccelGain = cfg.fighterVisualPitchAccelGain
		local visualSlipYawGain = cfg.fighterVisualSlipYawGain
		local visualSlipPitchGain = cfg.fighterVisualSlipPitchGain
		local visualRollRateGain = cfg.fighterVisualRollRateGain
		local visualYawMax = math.max(0, cfg.fighterVisualYawMax)
		local visualPitchMax = math.max(0, cfg.fighterVisualPitchMax)
		local visualRollMax = math.max(0, cfg.fighterVisualRollMax)
		local targetVisualYawOverDeg = smoothedYawRate * visualYawRateGain + yawAccelForVisual * visualYawAccelGain - sideSlipNorm * visualSlipYawGain
		local targetVisualPitchOverDeg = (
			smoothedPitchRate * visualPitchRateGain
			+ pitchAccelForVisual * visualPitchAccelGain
			- verticalSlipNorm * visualSlipPitchGain
		) * landingPitchScale
		local targetVisualRollOverDeg = smoothedYawRate * visualRollRateGain * landingRollScale
		targetVisualYawOverDeg = math.clamp(targetVisualYawOverDeg, -visualYawMax, visualYawMax)
		targetVisualPitchOverDeg = math.clamp(targetVisualPitchOverDeg, -visualPitchMax, visualPitchMax)
		targetVisualRollOverDeg = math.clamp(targetVisualRollOverDeg, -visualRollMax, visualRollMax)
		local visualResponse = cfg.fighterVisualResponse
		local visualAlpha = 1 - math.exp(-visualResponse * dt)
		visualYawOverDeg += (targetVisualYawOverDeg - visualYawOverDeg) * visualAlpha
		visualPitchOverDeg += (targetVisualPitchOverDeg - visualPitchOverDeg) * visualAlpha
		visualRollOverDeg += (targetVisualRollOverDeg - visualRollOverDeg) * visualAlpha
		if takeoffVisualLockRemaining > 0 then
			autoRollVisualDeg = 0
			visualYawOverDeg = 0
			visualPitchOverDeg = 0
			visualRollOverDeg = 0
		end
		local straightVisualSettle = math.abs(yawInput) < 0.04 and math.abs(pitchInput) < 0.04 and math.abs(rollInput) < 0.04
			and math.abs(smoothedYawRate) < 7 and math.abs(smoothedPitchRate) < 7
		if straightVisualSettle then
			local settleAlpha = 1 - math.exp(-FIGHTER_STRAIGHT_VISUAL_ROLL_SETTLE_RATE * dt)
			autoRollVisualDeg += (0 - autoRollVisualDeg) * settleAlpha
			visualRollOverDeg += (0 - visualRollOverDeg) * settleAlpha
		end
		-- Landing wobble: damped spring driven by actual ship turn rate + forward accel
		local wobbleRollDeg = 0
		local wobblePitchDeg = 0
		local hoverNoiseRollDeg = 0
		local hoverNoisePitchDeg = 0
		if inLanding and not exitAutoLandActive and takeoffVisualLockRemaining <= 0 then
			local landingSpeedFrac = math.clamp(physicalVelocity.Magnitude / LANDING_SEQUENCE_MAX_SPEED, 0, 1)
			local wobbleScale = 1 - landingSpeedFrac * LANDING_WOBBLE_SPEED_AUTHORITY

			-- Drive spring target from ship's actual turn rate and throttle
			local rollTarget = smoothedYawRate * LANDING_WOBBLE_ROLL_GAIN
			local pitchTarget = smoothedThrottleInput * LANDING_WOBBLE_PITCH_GAIN

			local springRoll = -LANDING_WOBBLE_ROLL_STIFFNESS * (wobbleRoll - rollTarget) - LANDING_WOBBLE_ROLL_DAMPING * wobbleRollVel
			wobbleRollVel += springRoll * dt
			wobbleRoll += wobbleRollVel * dt

			local springPitch = -LANDING_WOBBLE_PITCH_STIFFNESS * (wobblePitch - pitchTarget) - LANDING_WOBBLE_PITCH_DAMPING * wobblePitchVel
			wobblePitchVel += springPitch * dt
			wobblePitch += wobblePitchVel * dt

			wobbleRollDeg = math.clamp(wobbleRoll, -LANDING_WOBBLE_ROLL_MAX_DEG, LANDING_WOBBLE_ROLL_MAX_DEG) * wobbleScale
			wobblePitchDeg = math.clamp(wobblePitch, -LANDING_WOBBLE_PITCH_MAX_DEG, LANDING_WOBBLE_PITCH_MAX_DEG) * wobbleScale

			-- Idle hover noise: Perlin-driven micro-drift, fades out with speed
			hoverNoiseClock += dt * HOVER_NOISE_SPEED
			local hoverFade = math.clamp(1 - landingSpeedFrac / (HOVER_NOISE_SPEED_FADE / LANDING_SEQUENCE_MAX_SPEED), 0, 1)
			hoverNoiseRollDeg = math.noise(hoverNoiseClock, 0, 0) * HOVER_NOISE_ROLL_AMP * hoverFade
			hoverNoisePitchDeg = math.noise(0, hoverNoiseClock, 7.3) * HOVER_NOISE_PITCH_AMP * hoverFade
		else
			local decayAlpha = 1 - math.exp(-8 * dt)
			wobbleRoll *= (1 - decayAlpha)
			wobbleRollVel *= (1 - decayAlpha)
			wobblePitch *= (1 - decayAlpha)
			wobblePitchVel *= (1 - decayAlpha)
			-- Flight turbulence: fast jitter scaling with speed + turn + boost
			hoverNoiseClock += dt * TURB_NOISE_SPEED
			local speedFrac = math.clamp(physicalVelocity.Magnitude / math.max(1, cfg.maxSpeed), 0, 1)
			local turbAmp = speedFrac * speedFrac
				+ math.abs(smoothedYawRate) / math.max(1, cfg.yawRate) * TURB_TURN_BONUS
				+ boostBlend * TURB_BOOST_BONUS
			hoverNoiseRollDeg = math.noise(hoverNoiseClock, 0, 0) * TURB_ROLL_AMP * turbAmp
			hoverNoisePitchDeg = math.noise(0, hoverNoiseClock, 7.3) * TURB_PITCH_AMP * turbAmp
		end

		local visualRollDeg = autoRollVisualDeg + visualRollOverDeg + wobbleRollDeg + hoverNoiseRollDeg
		visualOrientation = physicsOrientation
			* CFrame.Angles(math.rad(visualPitchOverDeg + wobblePitchDeg + hoverNoisePitchDeg), math.rad(visualYawOverDeg), 0)
			* CFrame.Angles(0, 0, math.rad(visualRollDeg))

		local gyroTargetOrientation = visualOrientation
		if inLanding or inTakeoff or takeoffVisualLockRemaining > 0 then
			-- Keep liftoff/landing physically level but include landing wobble + hover noise.
			gyroTargetOrientation = physicsOrientation
				* CFrame.Angles(math.rad(wobblePitchDeg + hoverNoisePitchDeg), 0, math.rad(wobbleRollDeg + hoverNoiseRollDeg))
		end
		if bodyGyro ~= nil then
			bodyGyro.CFrame = CFrame.new(base.Position) * gyroTargetOrientation
		end

		local reportedSpeed = physicalVelocity.Magnitude
		mdl:SetAttribute("VehicleBoosting", boostActive)

		CombatHUD.setSpeed(reportedSpeed)
		updateAudio(dt, reportedSpeed, cfg.maxSpeed, throttle, yawInput, boostActive, inLanding or exitAutoLandActive)
	end)

	ContextActionService:BindAction(EXIT_ACTION_NAME, onExitAction, false, Enum.KeyCode.F)
	ContextActionService:BindAction(BLOCK_JUMP_ACTION_NAME, function()
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.Space)
	ContextActionService:BindAction(LEVEL_OFF_ACTION_NAME, onLevelOffAction, false, Enum.KeyCode.G)
	ContextActionService:BindAction(ENGINE_KILL_ACTION_NAME, onEngineKillAction, false, Enum.KeyCode.X)
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
	local _dbgModel = activeModel
	local _dbgSeat = activeDriverSeat
	local _dbgMode = flightMode
	local _dbgAutoLand = exitAutoLandActive
	print(string.format(
		"[P10_EXIT] deactivate flightMode=%s exitAutoLandActive=%s model=%s seat_occupant=%s",
		tostring(_dbgMode),
		tostring(_dbgAutoLand),
		tostring(_dbgModel and _dbgModel.Name or "nil"),
		tostring(_dbgSeat and _dbgSeat:IsA("Seat") and (_dbgSeat :: Seat).Occupant or "nil")
	))
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
	ContextActionService:UnbindAction(BLOCK_JUMP_ACTION_NAME)
	ContextActionService:UnbindAction(LEVEL_OFF_ACTION_NAME)
	ContextActionService:UnbindAction(ENGINE_KILL_ACTION_NAME)
	levelOffActive = false
	engineKillActive = false
	cleanupAudio()
	local model = activeModel
	if model ~= nil and model.PrimaryPart ~= nil then
		for _, child in ipairs((model.PrimaryPart :: BasePart):GetChildren()) do
			if child:IsA("Sound") and (child.Name == "FighterEngineLoop" or child.Name == "RemoteFighterEngineLoop") then
				child:Destroy()
			end
		end
		model:SetAttribute("VehicleBoosting", false)
		-- Client-side anchor closes the gap before the server processes exit.
		model.PrimaryPart.Anchored = true
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
	activeTuning = nil
	activeDriverSeat = nil
	virtualCursorX = 0
	virtualCursorY = 0
	displayedCursorX = 0
	displayedCursorY = 0
	mouseIdleNoInputTime = 0
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
	landingVerticalCommandSpeed = 0
	filteredYawInput = 0
	filteredPitchInput = 0
	yawInputHysteresisActive = false
	pitchInputHysteresisActive = false
	if vectorForce ~= nil then
		vectorForce.Enabled = false
		vectorForce.Force = Vector3.zero
	end
	if bodyVelocity ~= nil then
		bodyVelocity.MaxForce = Vector3.zero
		bodyVelocity.Velocity = Vector3.zero
	end
	if bodyGyro ~= nil then
		bodyGyro.MaxTorque = Vector3.zero
	end
	bodyVelocity = nil
	bodyGyro = nil
	vectorForce = nil
	useForceFlight = false
	flightMode = "Landing"
	takeoffExitMode = "Flight"
	takeoffRemaining = 0
	takeoffTargetY = 0
	takeoffLiftSpeed = 0
	takeoffVisualLockRemaining = 0
	landingToggleHeld = false
	landingTransitionActive = false
	landingTransitionElapsed = 0
	landingTransitionFromLanding = false
	landingTransitionToLanding = false
	boostCharge = 1
	boostBlend = 0
	boostActive = false
	prevBoostForEvents = false
	boostReuseCooldown = 0
	wobbleRoll = 0
	wobbleRollVel = 0
	wobblePitch = 0
	wobblePitchVel = 0
	hoverNoiseClock = 0
	exitAutoLandActive = false
	flightRayParams = nil
	nextStreamRequestTime = 0
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
			takeoffVisualLockRemaining = 0
			landingTransitionActive = false
			landingTransitionElapsed = 0
			landingTransitionFromLanding = false
			landingTransitionToLanding = false
			boostCharge = 1
			boostBlend = 0
			boostActive = false
			prevBoostForEvents = false
			exitAutoLandActive = false
			virtualCursorX = 0
			virtualCursorY = 0
			displayedCursorX = 0
			displayedCursorY = 0
			mouseIdleNoInputTime = 0
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
			landingVerticalCommandSpeed = 0
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
			takeoffVisualLockRemaining = 0
			landingTransitionActive = false
			landingTransitionElapsed = 0
			landingTransitionFromLanding = false
			landingTransitionToLanding = false
			boostCharge = 1
			boostBlend = 0
			boostActive = false
			prevBoostForEvents = false
			exitAutoLandActive = false
			virtualCursorX = 0
			virtualCursorY = 0
			displayedCursorX = 0
			displayedCursorY = 0
			mouseIdleNoInputTime = 0
			landingVerticalCommandSpeed = 0
		end)
	end
end

return FighterClient
