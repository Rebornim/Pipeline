--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local sharedRoot = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatTypes = require(sharedRoot:WaitForChild("CombatTypes"))

type VehicleConfig = CombatTypes.VehicleConfig

local VehicleCamera = {}

local LOCAL_PLAYER = Players.LocalPlayer

local MIN_DT = 1 / 240
local MAX_DT = 1 / 20
local LEAN_FOV_PUSH_IN = 8
local VISUALS_FOLDER_NAME = "CombatClientVisuals"

local activeVehicleModel: Model? = nil
local activeConfig: VehicleConfig? = nil
local currentCameraPosition: Vector3? = nil
local currentLookAtPosition: Vector3? = nil
local smoothedHeading: number? = nil
local smoothedSpeed = 0
local smoothedAnchorPosition: Vector3? = nil
local smoothedHorizontalVelocity: Vector3 = Vector3.zero
local smoothedPitchFactor = 0
local smoothedForward: Vector3 = Vector3.new(0, 0, -1)
local smoothedDistance: number? = nil
local smoothedHeight: number? = nil
local smoothedLookAhead: number? = nil
local smoothedCollisionDistance: number? = nil
local lastRawPosition: Vector3? = nil
local cameraConnection: RBXScriptConnection? = nil
local savedCameraType: Enum.CameraType? = nil
local savedFieldOfView: number? = nil
local activeLeanInput = 0
local smoothedLeanMagnitude = 0
local smoothedLeanDirection = 0
local vehicleShakeAmplitude = 0
local vehicleShakeDecayRate = 0
local vehicleShakePhase = 0
local freelookPaused = false
local freelookYaw = 0
local freelookPitch = 0
local freelookDistance = 15
local FREELOOK_PITCH_MIN = -math.rad(60)
local FREELOOK_PITCH_MAX = math.rad(45)
local zoomOffset = 0
local ZOOM_STEP = 5
local ZOOM_MIN = -10
local ZOOM_MAX = 35

local function computeAlpha(stiffness: number, dt: number): number
	return 1 - math.exp(-stiffness * dt)
end

local function shortestAngleDelta(a: number, b: number): number
	local delta = (a - b) % (math.pi * 2)
	if delta > math.pi then
		delta -= math.pi * 2
	end
	return delta
end

local function flattenUnit(v: Vector3, fallback: Vector3): Vector3
	local flat = Vector3.new(v.X, 0, v.Z)
	if flat.Magnitude <= 1e-4 then
		return fallback
	end
	return flat.Unit
end

local function getForwardVectorFromHeading(heading: number): Vector3
	return Vector3.new(-math.sin(heading), 0, -math.cos(heading))
end

local function measureAllowedCameraDistance(
	focusPosition: Vector3,
	desiredCameraPosition: Vector3,
	vehicleModel: Model,
	minDistance: number
): number
	local ray = desiredCameraPosition - focusPosition
	local rayLength = ray.Magnitude
	if rayLength <= 1e-4 then
		return rayLength
	end

	local filter: { Instance } = { vehicleModel }
	local character = LOCAL_PLAYER.Character
	if character ~= nil then
		table.insert(filter, character)
	end
	local visualsFolder = Workspace:FindFirstChild(VISUALS_FOLDER_NAME)
	if visualsFolder ~= nil then
		table.insert(filter, visualsFolder)
	end

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = filter
	rayParams.IgnoreWater = true

	local result = Workspace:Raycast(focusPosition, ray, rayParams)
	if result == nil then
		return rayLength
	end

	return math.max(minDistance, result.Distance - 0.6)
end

local function stepCamera(dt: number)
	local vehicleModel = activeVehicleModel
	local config = activeConfig
	local camera = Workspace.CurrentCamera
	if vehicleModel == nil or config == nil or camera == nil then
		return
	end

	if freelookPaused then
		if vehicleModel.Parent == nil then
			VehicleCamera.deactivate()
			return
		end
		local primaryPart = vehicleModel.PrimaryPart
		local targetPos = if primaryPart ~= nil then primaryPart.Position else vehicleModel:GetPivot().Position
		targetPos = targetPos + Vector3.new(0, config.cameraHeight * 0.3, 0)

		local orbitCFrame = CFrame.new(targetPos)
			* CFrame.Angles(0, freelookYaw, 0)
			* CFrame.Angles(freelookPitch, 0, 0)
			* CFrame.new(0, 0, freelookDistance)

		camera.CFrame = CFrame.lookAt(orbitCFrame.Position, targetPos)
		return
	end

	if vehicleModel.Parent == nil then
		VehicleCamera.deactivate()
		return
	end

	local clampedDt = math.clamp(dt, MIN_DT, MAX_DT)
	local primaryPart = vehicleModel.PrimaryPart
	local rawPosition = if primaryPart ~= nil then primaryPart.Position else vehicleModel:GetPivot().Position
	local derivedVelocity = Vector3.zero
	if lastRawPosition ~= nil then
		local frameDelta = rawPosition - lastRawPosition
		derivedVelocity = frameDelta / clampedDt
		-- Guard against interpolation snaps contaminating camera velocity smoothing.
		local maxDerivedSpeed = math.max(config.maxSpeed * 2.5, 220)
		if derivedVelocity.Magnitude > maxDerivedSpeed then
			derivedVelocity = Vector3.zero
		end
	end
	lastRawPosition = rawPosition

	local rawVelocity = if primaryPart ~= nil then primaryPart.AssemblyLinearVelocity else derivedVelocity
	if rawVelocity.Magnitude < 0.05 then
		rawVelocity = derivedVelocity
	end
	local rawHorizontalVelocity = Vector3.new(rawVelocity.X, 0, rawVelocity.Z)
	local rawHorizontalSpeed = rawHorizontalVelocity.Magnitude
	local speedAttribute = vehicleModel:GetAttribute("VehicleSpeed")
	local speedSource = if type(speedAttribute) == "number" then math.max(0, speedAttribute) else rawHorizontalSpeed

	local heading = vehicleModel:GetAttribute("VehicleHeading")
	if type(heading) ~= "number" then
		heading = smoothedHeading or 0
	end
	local headingNow = smoothedHeading
	if headingNow == nil then
		headingNow = heading
	else
		headingNow += shortestAngleDelta(heading, headingNow) * computeAlpha(8.5, clampedDt)
	end
	smoothedHeading = headingNow

	local targetSpeed = speedSource
	local maxSpeedStep = math.max(config.acceleration, config.deceleration, 25) * clampedDt
	local speedDelta = math.clamp(targetSpeed - smoothedSpeed, -maxSpeedStep * 1.2, maxSpeedStep)
	smoothedSpeed += speedDelta
	smoothedSpeed += (targetSpeed - smoothedSpeed) * computeAlpha(4.5, clampedDt)
	local speedFactor = math.clamp(smoothedSpeed / math.max(1, config.maxSpeed), 0, 1)

	local forward = getForwardVectorFromHeading(headingNow)
	smoothedForward = flattenUnit(smoothedForward:Lerp(forward, computeAlpha(11, clampedDt)), forward)

	smoothedHorizontalVelocity = smoothedHorizontalVelocity:Lerp(rawHorizontalVelocity, computeAlpha(10, clampedDt))
	local anchor = smoothedAnchorPosition
	if anchor == nil then
		anchor = rawPosition
	else
		local anchorTarget = rawPosition + smoothedHorizontalVelocity * 0.035
		anchor = anchor:Lerp(anchorTarget, computeAlpha(14, clampedDt))
	end
	smoothedAnchorPosition = anchor

	local pitchTarget = 0
	local forwardRef = vehicleModel:FindFirstChild("VehicleForwardRef", true)
	if forwardRef ~= nil and forwardRef:IsA("Attachment") then
		pitchTarget = math.clamp(forwardRef.WorldAxis.Y, -0.45, 0.45)
	elseif primaryPart ~= nil then
		pitchTarget = math.clamp(primaryPart.CFrame.LookVector.Y, -0.45, 0.45)
	end
	if math.abs(pitchTarget) < 0.06 then
		pitchTarget = 0
	end
	smoothedPitchFactor += (pitchTarget - smoothedPitchFactor) * computeAlpha(2.2, clampedDt)
	local uphill = math.max(0, smoothedPitchFactor)
	local downhill = math.max(0, -smoothedPitchFactor)

	local baseDistance = math.max(0, config.cameraDistance + zoomOffset)
	local zoomRatio = baseDistance / math.max(1, config.cameraDistance)
	local targetDistance = baseDistance
	targetDistance += config.cameraDistance * 0.08 * speedFactor
	targetDistance += config.cameraDistance * 0.08 * uphill
	targetDistance += config.cameraDistance * 0.04 * downhill
	targetDistance = math.max(0, targetDistance)

	local targetHeight = config.cameraHeight * 0.95 * zoomRatio
	targetHeight += config.cameraHeight * 0.09 * speedFactor
	targetHeight += config.cameraHeight * 0.42 * uphill
	targetHeight += config.cameraHeight * 0.1 * downhill
	targetHeight += uphill * 0.9

	local targetLookAhead = config.cameraDistance * 0.17
	targetLookAhead += speedFactor * 1.2
	targetLookAhead += uphill * 0.7
	targetLookAhead -= downhill * 0.08
	targetLookAhead = math.clamp(targetLookAhead, 2.4, config.cameraDistance * 0.65)

	if smoothedDistance == nil then
		smoothedDistance = targetDistance
	else
		smoothedDistance += (targetDistance - smoothedDistance) * computeAlpha(5.5, clampedDt)
	end

	if smoothedHeight == nil then
		smoothedHeight = targetHeight
	else
		smoothedHeight += (targetHeight - smoothedHeight) * computeAlpha(4.8, clampedDt)
	end

	if smoothedLookAhead == nil then
		smoothedLookAhead = targetLookAhead
	else
		smoothedLookAhead += (targetLookAhead - smoothedLookAhead) * computeAlpha(5.2, clampedDt)
	end

	local distance = smoothedDistance or targetDistance
	local height = smoothedHeight or targetHeight
	local lookAhead = smoothedLookAhead or targetLookAhead

	local focusHeight = config.cameraHeight * 0.28 + speedFactor * 0.12 + uphill * 0.55
	local focusPosition = anchor + Vector3.new(0, focusHeight, 0)
	local cameraRight = smoothedForward:Cross(Vector3.yAxis)
	local lateralShift = smoothedLeanDirection * config.leanCameraOffset * math.max(0.2, speedFactor)
	local desiredCameraPosition = focusPosition - smoothedForward * distance + Vector3.new(0, height, 0) + cameraRight * lateralShift
	local desiredRay = desiredCameraPosition - focusPosition
	local desiredRayLength = desiredRay.Magnitude

	local desiredLookAt = focusPosition
		+ smoothedForward * lookAhead
		+ Vector3.new(0, config.cameraHeight * 0.43 + uphill * 0.9 - downhill * 0.05, 0)
		+ cameraRight * lateralShift * 0.5

	if desiredRayLength > 1e-4 then
		local allowedDistance = measureAllowedCameraDistance(
			focusPosition,
			desiredCameraPosition,
			vehicleModel,
			math.max(config.cameraDistance * 0.62, 5.2)
		)
		if smoothedCollisionDistance == nil then
			smoothedCollisionDistance = allowedDistance
		else
			local correctionAlpha = if allowedDistance < smoothedCollisionDistance
				then computeAlpha(18, clampedDt)
				else computeAlpha(6.5, clampedDt)
			smoothedCollisionDistance += (allowedDistance - smoothedCollisionDistance) * correctionAlpha
		end
		local collisionDistance = smoothedCollisionDistance or allowedDistance
		local rayDirection = desiredRay / desiredRayLength
		desiredCameraPosition = focusPosition + rayDirection * collisionDistance
	end

	local cameraPosition = currentCameraPosition
	if cameraPosition == nil then
		cameraPosition = desiredCameraPosition
	else
		cameraPosition = cameraPosition:Lerp(desiredCameraPosition, computeAlpha(12.5, clampedDt))
	end
	-- Vehicle camera shake (lean entry)
	vehicleShakePhase += clampedDt
	vehicleShakeAmplitude = math.max(0, vehicleShakeAmplitude - vehicleShakeDecayRate * clampedDt)
	if vehicleShakeAmplitude > 0.001 then
		local shakeRight = smoothedForward:Cross(Vector3.yAxis)
		local shakeX = math.sin(vehicleShakePhase * 28) * vehicleShakeAmplitude * 0.4
		local shakeY = math.sin(vehicleShakePhase * 35 + 1.3) * vehicleShakeAmplitude * 0.25
		cameraPosition += shakeRight * shakeX + Vector3.yAxis * shakeY
	end
	currentCameraPosition = cameraPosition

	local lookAtPosition = currentLookAtPosition
	if lookAtPosition == nil then
		lookAtPosition = desiredLookAt
	else
		lookAtPosition = lookAtPosition:Lerp(desiredLookAt, computeAlpha(13.5, clampedDt))
	end
	currentLookAtPosition = lookAtPosition

	local targetLeanMagnitude = math.abs(activeLeanInput)
	local leanAlpha = if targetLeanMagnitude > smoothedLeanMagnitude
		then computeAlpha(6.5, clampedDt)
		else computeAlpha(9.5, clampedDt)
	smoothedLeanMagnitude += (targetLeanMagnitude - smoothedLeanMagnitude) * leanAlpha
	local leanDirAlpha = computeAlpha(6.5, clampedDt)
	smoothedLeanDirection += (activeLeanInput - smoothedLeanDirection) * leanDirAlpha

	local leanFovSpeedScale = math.max(0.3, speedFactor)
	local baseFieldOfView = savedFieldOfView or camera.FieldOfView
	local targetFieldOfView = baseFieldOfView - (LEAN_FOV_PUSH_IN * smoothedLeanMagnitude * leanFovSpeedScale)
	camera.FieldOfView += (targetFieldOfView - camera.FieldOfView) * computeAlpha(8.5, clampedDt)
	camera.CFrame = CFrame.lookAt(cameraPosition, lookAtPosition, Vector3.yAxis)
end

function VehicleCamera.setLeanInput(lean: number): ()
	if type(lean) ~= "number" then
		activeLeanInput = 0
		return
	end
	activeLeanInput = math.clamp(math.round(lean), -1, 1)
end

function VehicleCamera.pushShake(amplitude: number, duration: number): ()
	vehicleShakeAmplitude = math.max(vehicleShakeAmplitude, amplitude)
	vehicleShakeDecayRate = amplitude / math.max(0.01, duration)
	vehicleShakePhase = 0
end

function VehicleCamera.applyScrollZoom(direction: number): ()
	-- direction: -1 = scroll up (zoom in), 1 = scroll down (zoom out)
	zoomOffset = math.clamp(zoomOffset + direction * ZOOM_STEP, ZOOM_MIN, ZOOM_MAX)
end

function VehicleCamera.setFreelook(active: boolean): ()
	if active and not freelookPaused then
		freelookPaused = true
		-- Initialize orbit from current camera position so there's no snap
		local camera = Workspace.CurrentCamera
		if camera ~= nil and activeVehicleModel ~= nil then
			local vehiclePos = activeVehicleModel:GetPivot().Position
			local camPos = camera.CFrame.Position
			local toCamera = camPos - vehiclePos
			freelookYaw = math.atan2(toCamera.X, toCamera.Z)
			local horizontalDist = Vector3.new(toCamera.X, 0, toCamera.Z).Magnitude
			freelookPitch = -math.atan2(toCamera.Y, horizontalDist)
			freelookPitch = math.clamp(freelookPitch, FREELOOK_PITCH_MIN, FREELOOK_PITCH_MAX)
			freelookDistance = math.max(5, toCamera.Magnitude)
		end
	elseif not active and freelookPaused then
		freelookPaused = false
		-- Seed smoothed positions from current camera so transition back is smooth
		local camera = Workspace.CurrentCamera
		if camera ~= nil then
			currentCameraPosition = camera.CFrame.Position
			currentLookAtPosition = camera.CFrame.Position + camera.CFrame.LookVector * 20
		end
		lastRawPosition = nil
	end
end

function VehicleCamera.addFreelookInput(deltaX: number, deltaY: number): ()
	local sensitivity = 0.003
	freelookYaw -= deltaX * sensitivity
	freelookPitch -= deltaY * sensitivity
	freelookPitch = math.clamp(freelookPitch, FREELOOK_PITCH_MIN, FREELOOK_PITCH_MAX)
end

function VehicleCamera.activate(vehicleModel: Model, config: VehicleConfig): ()
	VehicleCamera.deactivate()

	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end

	savedCameraType = camera.CameraType
	savedFieldOfView = camera.FieldOfView
	camera.CameraType = Enum.CameraType.Scriptable

	activeVehicleModel = vehicleModel
	activeConfig = config

	local heading = vehicleModel:GetAttribute("VehicleHeading")
	if type(heading) ~= "number" then
		heading = 0
	end
	smoothedHeading = heading
	smoothedSpeed = 0
	smoothedAnchorPosition = nil
	smoothedHorizontalVelocity = Vector3.zero
	smoothedPitchFactor = 0
	smoothedForward = getForwardVectorFromHeading(heading)
	smoothedDistance = nil
	smoothedHeight = nil
	smoothedLookAhead = nil
	smoothedCollisionDistance = nil
	lastRawPosition = nil
	currentCameraPosition = nil
	currentLookAtPosition = nil
	activeLeanInput = 0
	smoothedLeanMagnitude = 0
	smoothedLeanDirection = 0
	vehicleShakeAmplitude = 0
	vehicleShakeDecayRate = 0
	vehicleShakePhase = 0
	zoomOffset = 0
	stepCamera(1 / 60)
	cameraConnection = RunService.RenderStepped:Connect(stepCamera)
end

function VehicleCamera.deactivate(): ()
	if cameraConnection ~= nil then
		cameraConnection:Disconnect()
		cameraConnection = nil
	end

	local camera = Workspace.CurrentCamera
	if camera ~= nil then
		camera.CameraType = savedCameraType or Enum.CameraType.Custom
		if savedFieldOfView ~= nil then
			camera.FieldOfView = savedFieldOfView
		end
	end

	activeVehicleModel = nil
	activeConfig = nil
	currentCameraPosition = nil
	currentLookAtPosition = nil
	smoothedHeading = nil
	smoothedSpeed = 0
	smoothedAnchorPosition = nil
	smoothedHorizontalVelocity = Vector3.zero
	smoothedPitchFactor = 0
	smoothedForward = Vector3.new(0, 0, -1)
	smoothedDistance = nil
	smoothedHeight = nil
	smoothedLookAhead = nil
	smoothedCollisionDistance = nil
	lastRawPosition = nil
	savedCameraType = nil
	savedFieldOfView = nil
	activeLeanInput = 0
	smoothedLeanMagnitude = 0
	smoothedLeanDirection = 0
	vehicleShakeAmplitude = 0
	vehicleShakeDecayRate = 0
	vehicleShakePhase = 0
	freelookPaused = false
	zoomOffset = 0
end

return VehicleCamera
