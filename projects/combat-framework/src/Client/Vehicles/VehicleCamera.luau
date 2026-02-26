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
local isFighterMode = false
local smoothedShipCFrame: CFrame? = nil
local smoothedCameraPos: Vector3? = nil
local cameraConnection: RBXScriptConnection? = nil
local savedCameraType: Enum.CameraType? = nil
local savedFieldOfView: number? = nil
local activeLeanInput = 0
local smoothedLeanMagnitude = 0
local smoothedLeanDirection = 0
local vehicleShakeAmplitude = 0
local vehicleShakeDecayRate = 0
local vehicleShakePhase = 0
local boostFOVTarget = 0
local smoothedBoostFOV = 0
local BOOST_FOV_AMOUNT = 12
local externalFOVOffset = 0
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

-- Speed-reactive FOV and vibration
local SPEED_FOV_MAX = 4
local smoothedSpeedFOV = 0
local SPEED_VIB_MAX = 0.012

-- Broken engine vibration
local brokenVibActive = false
local BROKEN_VIB_AMP = 0.07

-- FOV punch (gear shift / misfire)
local fovPunchValue = 0
local fovPunchDecay = 0

-- Roll wobble (howl wind gust)
local rollWobbleValue = 0
local rollWobblePhase = 0
local rollWobbleDecay = 0

-- Effects gate: all VFX (FOV, shake, vibration) require a sound profile
local effectsEnabled = false

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
		local rawPos = if primaryPart ~= nil then primaryPart.Position else vehicleModel:GetPivot().Position
		-- Smooth the orbit target to avoid 20Hz server CFrame write jitter
		local anchor = smoothedAnchorPosition
		if anchor == nil then
			anchor = rawPos
		else
			anchor = anchor:Lerp(rawPos, computeAlpha(14, math.clamp(dt, MIN_DT, MAX_DT)))
		end
		smoothedAnchorPosition = anchor
		local targetPos = anchor + Vector3.new(0, config.cameraHeight * 0.3, 0)

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

	if isFighterMode then
		local targetCF = if primaryPart ~= nil then primaryPart.CFrame else vehicleModel:GetPivot()
		local orientLag = config.fighterCameraOrientLag
		if type(orientLag) ~= "number" or orientLag <= 0 then
			orientLag = 8
		end
		if smoothedShipCFrame == nil then
			smoothedShipCFrame = targetCF
		else
			-- Separate position (high stiffness) from orientation (orientLag) so camera
			-- stays on ship even when facing diverges from velocity (e.g. engine kill drift).
			local posAlpha = computeAlpha(20, clampedDt)
			local oriAlpha = computeAlpha(orientLag, clampedDt)
			local smoothPos = (smoothedShipCFrame :: CFrame).Position:Lerp(targetCF.Position, posAlpha)
			local smoothRot = (smoothedShipCFrame :: CFrame):Lerp(targetCF, oriAlpha).Rotation
			smoothedShipCFrame = CFrame.new(smoothPos) * smoothRot
		end
		local smoothCF = smoothedShipCFrame :: CFrame
		local shipFwd = smoothCF.LookVector
		local shipUp = smoothCF.UpVector
		local shipPos = smoothCF.Position
		local speed = if primaryPart ~= nil then primaryPart.AssemblyLinearVelocity.Magnitude else 0
		local speedFrac = math.clamp(speed / math.max(1, config.maxSpeed), 0, 1)

		----------------------------------------------------------------
		-- CAMERA POSITION (behind + above in smoothed ship frame)
		----------------------------------------------------------------
		local fighterDist = math.max(0, config.cameraDistance + zoomOffset)
		local desiredCamPos = shipPos - shipFwd * fighterDist + shipUp * config.cameraHeight
		if smoothedCameraPos == nil then
			smoothedCameraPos = desiredCamPos
		else
			smoothedCameraPos = (smoothedCameraPos :: Vector3):Lerp(desiredCamPos, computeAlpha(12, clampedDt))
		end

		----------------------------------------------------------------
		-- COLLISION AVOIDANCE
		----------------------------------------------------------------
		local minDist = math.max(config.cameraDistance * 0.6, 6)
		local allowedDist = measureAllowedCameraDistance(shipPos, smoothedCameraPos :: Vector3, vehicleModel, minDist)
		local camDir = (smoothedCameraPos :: Vector3) - shipPos
		if camDir.Magnitude > 0.01 and camDir.Magnitude > allowedDist then
			smoothedCameraPos = shipPos + camDir.Unit * allowedDist
		end

			----------------------------------------------------------------
			-- LOOK TARGET (ahead of ship in smoothed orientation)
			----------------------------------------------------------------
			local lookAhead = config.fighterCameraLookAhead or 15
			local aimHeight = config.fighterCameraAimHeight
			if type(aimHeight) ~= "number" then
				aimHeight = config.cameraHeight * 0.55
			end
			local aimHeightSpeedBoost = config.fighterCameraAimHeightSpeedBoost
			if type(aimHeightSpeedBoost) ~= "number" then
				aimHeightSpeedBoost = config.cameraHeight * 0.32
			end
			aimHeight += aimHeightSpeedBoost * speedFrac
			local desiredLookTarget = shipPos + shipFwd * lookAhead + shipUp * aimHeight
		local lookAt = currentLookAtPosition
		if lookAt == nil then
			lookAt = desiredLookTarget
		else
			lookAt = lookAt:Lerp(desiredLookTarget, computeAlpha(10, clampedDt))
		end
		currentLookAtPosition = lookAt
		currentCameraPosition = smoothedCameraPos

		----------------------------------------------------------------
		-- BUILD CAMERA CFRAME
		-- Up vector = smoothed ship up (full follow through all orientations)
		----------------------------------------------------------------
		camera.CFrame = CFrame.lookAt(smoothedCameraPos :: Vector3, lookAt, shipUp)

		----------------------------------------------------------------
		-- SPEED FOV
		----------------------------------------------------------------
		local baseFov = savedFieldOfView or camera.FieldOfView
		local speedFov = speedFrac * SPEED_FOV_MAX
		camera.FieldOfView += (baseFov + speedFov + externalFOVOffset - camera.FieldOfView) * computeAlpha(8.5, clampedDt)
		return
	end

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
	if effectsEnabled then
		smoothedSpeedFOV += (SPEED_FOV_MAX * speedFactor - smoothedSpeedFOV) * computeAlpha(4, clampedDt)
	end

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
	if primaryPart ~= nil then
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
	if effectsEnabled then
		-- Vehicle camera shake (lean entry)
		vehicleShakePhase += clampedDt
		vehicleShakeAmplitude = math.max(0, vehicleShakeAmplitude - vehicleShakeDecayRate * clampedDt)
		if vehicleShakeAmplitude > 0.001 then
			local shakeRight = smoothedForward:Cross(Vector3.yAxis)
			local shakeX = math.sin(vehicleShakePhase * 28) * vehicleShakeAmplitude * 0.4
			local shakeY = math.sin(vehicleShakePhase * 35 + 1.3) * vehicleShakeAmplitude * 0.25
			cameraPosition += shakeRight * shakeX + Vector3.yAxis * shakeY
		end
		-- Speed micro-vibration (smooth sine hum scaling with speed)
		if speedFactor > 0.05 then
			local vibAmp = SPEED_VIB_MAX * speedFactor
			local vibTime = tick()
			local vibRight = smoothedForward:Cross(Vector3.yAxis)
			cameraPosition += vibRight * math.sin(vibTime * 13.7) * vibAmp
				+ Vector3.yAxis * math.sin(vibTime * 17.3 + 0.9) * vibAmp * 0.6
		end
		-- Broken engine vibration (low-freq, scales with speed — subtle at idle, full at speed)
		if brokenVibActive then
			local brokenScale = 0.12 + 0.88 * speedFactor
			local brokenPhase = tick() * 6
			local vibRight = smoothedForward:Cross(Vector3.yAxis)
			cameraPosition += vibRight * math.sin(brokenPhase) * BROKEN_VIB_AMP * brokenScale * 0.5
				+ Vector3.yAxis * math.sin(brokenPhase * 1.3 + 0.7) * BROKEN_VIB_AMP * brokenScale * 0.3
		end
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

	local baseFieldOfView = savedFieldOfView or camera.FieldOfView
	local targetFieldOfView = baseFieldOfView
	if effectsEnabled then
		local leanFovSpeedScale = math.max(0.3, speedFactor)
		local boostFovAlpha = if boostFOVTarget > 0 then computeAlpha(12, clampedDt) else computeAlpha(4, clampedDt)
		smoothedBoostFOV += (boostFOVTarget - smoothedBoostFOV) * boostFovAlpha
		-- FOV punch decay (gear shift / misfire)
		if math.abs(fovPunchValue) > 0.01 then
			local punchSign = if fovPunchValue > 0 then 1 else -1
			fovPunchValue -= punchSign * fovPunchDecay * clampedDt
			if punchSign * fovPunchValue < 0 then
				fovPunchValue = 0
			end
		else
			fovPunchValue = 0
		end
		targetFieldOfView += -(LEAN_FOV_PUSH_IN * smoothedLeanMagnitude * leanFovSpeedScale) + smoothedBoostFOV + smoothedSpeedFOV + fovPunchValue
	end
	targetFieldOfView += externalFOVOffset
	camera.FieldOfView += (targetFieldOfView - camera.FieldOfView) * computeAlpha(8.5, clampedDt)
	camera.CFrame = CFrame.lookAt(cameraPosition, lookAtPosition, Vector3.yAxis)

	if effectsEnabled then
		-- Roll wobble (howl wind gust)
		if math.abs(rollWobbleValue) > 0.01 then
			rollWobblePhase += clampedDt
			local wobbleAngle = rollWobbleValue * math.sin(rollWobblePhase * 18)
			camera.CFrame *= CFrame.Angles(0, 0, math.rad(wobbleAngle))
			local wobbleSign = if rollWobbleValue > 0 then 1 else -1
			rollWobbleValue -= wobbleSign * rollWobbleDecay * clampedDt
			if wobbleSign * rollWobbleValue < 0 then
				rollWobbleValue = 0
			end
		end
	end
end

function VehicleCamera.setEffectsEnabled(enabled: boolean): ()
	effectsEnabled = enabled
end

function VehicleCamera.setLeanInput(lean: number): ()
	if type(lean) ~= "number" then
		activeLeanInput = 0
		return
	end
	activeLeanInput = math.clamp(math.round(lean), -1, 1)
end

function VehicleCamera.setBoostFOV(active: boolean): ()
	boostFOVTarget = if active then BOOST_FOV_AMOUNT else 0
end

function VehicleCamera.setExternalFOVOffset(offset: number): ()
	if type(offset) ~= "number" then
		externalFOVOffset = 0
		return
	end
	externalFOVOffset = offset
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

function VehicleCamera.pushFOVPunch(amount: number, duration: number): ()
	fovPunchValue = amount
	fovPunchDecay = math.abs(amount) / math.max(0.01, duration)
end

function VehicleCamera.pushRollWobble(degrees: number, duration: number): ()
	rollWobbleValue = degrees
	rollWobbleDecay = degrees / math.max(0.01, duration)
	rollWobblePhase = 0
end

function VehicleCamera.setBrokenVibration(active: boolean): ()
	brokenVibActive = active
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
	isFighterMode = config.vehicleClass == "fighter"

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
	smoothedShipCFrame = nil
	smoothedCameraPos = nil
	if isFighterMode then
		local startCF = if vehicleModel.PrimaryPart ~= nil then vehicleModel.PrimaryPart.CFrame else vehicleModel:GetPivot()
		smoothedShipCFrame = startCF
		smoothedCameraPos = startCF.Position - startCF.LookVector * config.cameraDistance + startCF.UpVector * config.cameraHeight
	end
	activeLeanInput = 0
	smoothedLeanMagnitude = 0
	smoothedLeanDirection = 0
	vehicleShakeAmplitude = 0
	vehicleShakeDecayRate = 0
	vehicleShakePhase = 0
	zoomOffset = 0
	smoothedSpeedFOV = 0
	externalFOVOffset = 0
	fovPunchValue = 0
	fovPunchDecay = 0
	rollWobbleValue = 0
	rollWobblePhase = 0
	rollWobbleDecay = 0
	brokenVibActive = false
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
	isFighterMode = false
	currentCameraPosition = nil
	currentLookAtPosition = nil
	smoothedShipCFrame = nil
	smoothedCameraPos = nil
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
	boostFOVTarget = 0
	smoothedBoostFOV = 0
	smoothedSpeedFOV = 0
	externalFOVOffset = 0
	fovPunchValue = 0
	fovPunchDecay = 0
	rollWobbleValue = 0
	rollWobblePhase = 0
	rollWobbleDecay = 0
	brokenVibActive = false
	effectsEnabled = false
end

return VehicleCamera
