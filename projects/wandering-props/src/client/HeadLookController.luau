local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local sharedFolder = ReplicatedStorage:WaitForChild("WanderingPropsShared")
local Config = require(sharedFolder:WaitForChild("Config"))

local HeadLookController = {}
local TAU = math.pi * 2

local LOOK_HOLD_MIN = 1.0
local LOOK_HOLD_MAX = 2.8
local LOOK_TRANSITION_MIN = 0.14
local LOOK_TRANSITION_MAX = 0.35
local LOOK_GLIDE_MIN = 0.7
local LOOK_GLIDE_MAX = 1.4
local HOLDS_BETWEEN_GLIDES_MIN = 1
local HOLDS_BETWEEN_GLIDES_MAX = 3
local MIN_RETARGET_DELTA = math.rad(10)
local SCAN_START_SETTLE_TIME = 0.12
local SCAN_OUTPUT_SPEED_ACTIVE = 14
local SCAN_OUTPUT_SPEED_INACTIVE = 7
local SCAN_RANGE_SMOOTH_SPEED = 8
local SCAN_DEFAULT_YAW_RANGE = math.rad(14)
local SCAN_DEFAULT_PITCH_RANGE = math.rad(6)

local function randomRange(minValue: number, maxValue: number): number
	return minValue + (maxValue - minValue) * math.random()
end

local function approach(current: number, target: number, speed: number, dt: number): number
	local alpha = math.min(1, math.max(0, dt) * math.max(0, speed))
	return current + (target - current) * alpha
end

local function smoothstep(alpha: number): number
	local a = math.clamp(alpha, 0, 1)
	return a * a * (3 - 2 * a)
end

local function computeScanRanges(npc, neckMotor: Motor6D, dt: number): (number, number)
	local priorYawRange = npc.scanLastYawRange or SCAN_DEFAULT_YAW_RANGE
	local priorPitchRange = npc.scanLastPitchRange or SCAN_DEFAULT_PITCH_RANGE
	local rootPart = npc.model.PrimaryPart
	if not rootPart then
		return priorYawRange, priorPitchRange
	end

	local headPos = rootPart.Position
	if neckMotor.Part1 then
		headPos = neckMotor.Part1.Position
	end

	local target = npc.scanTarget
	if not target then
		return priorYawRange, priorPitchRange
	end

	local distToTarget = (target - headPos).Magnitude
	local extent = math.max(0, npc.scanExtent or 0)

	local maxYaw = math.rad(Config.HeadLookMaxYaw)
	local maxPitch = math.rad(Config.HeadLookMaxPitch)

	local scanYawRange = math.atan2(extent, math.max(1, distToTarget))
	scanYawRange = math.min(scanYawRange, maxYaw)

	local scanPitchRange = math.min(maxPitch * 0.35, scanYawRange * 0.55)
	scanYawRange = approach(priorYawRange, scanYawRange, SCAN_RANGE_SMOOTH_SPEED, dt)
	scanPitchRange = approach(priorPitchRange, scanPitchRange, SCAN_RANGE_SMOOTH_SPEED, dt)
	npc.scanLastYawRange = scanYawRange
	npc.scanLastPitchRange = scanPitchRange
	return scanYawRange, scanPitchRange
end

local function sampleLookTarget(currentYaw: number, scanYawRange: number, scanPitchRange: number): (number, number)
	local bestYaw = currentYaw
	local bestPitch = 0

	if scanYawRange <= 0.001 then
		return 0, 0
	end

	local minDelta = math.min(MIN_RETARGET_DELTA, scanYawRange * 0.6)
	for _ = 1, 7 do
		local yaw = randomRange(-scanYawRange, scanYawRange)
		local pitch = randomRange(-scanPitchRange, scanPitchRange)
		bestYaw = yaw
		bestPitch = pitch
		if math.abs(yaw - currentYaw) >= minDelta then
			break
		end
	end

	return bestYaw, bestPitch
end

local function beginTransition(npc, toYaw: number, toPitch: number)
	npc.scanMode = "transition"
	npc.scanTransitionElapsed = 0
	npc.scanTransitionDuration = randomRange(LOOK_TRANSITION_MIN, LOOK_TRANSITION_MAX)
	npc.scanFromYaw = npc.scanCurrentYaw or 0
	npc.scanFromPitch = npc.scanCurrentPitch or 0
	npc.scanToYaw = toYaw
	npc.scanToPitch = toPitch
end

local function beginHold(npc)
	npc.scanMode = "hold"
	npc.scanHoldRemaining = randomRange(LOOK_HOLD_MIN, LOOK_HOLD_MAX)
end

local function beginGlide(npc, scanYawRange: number, scanPitchRange: number)
	npc.scanMode = "glide"
	npc.scanGlideElapsed = 0
	npc.scanGlideDuration = randomRange(LOOK_GLIDE_MIN, LOOK_GLIDE_MAX)
	npc.scanGlideBaseYaw = npc.scanCurrentYaw or 0
	npc.scanGlideBasePitch = npc.scanCurrentPitch or 0
	npc.scanGlideFreqYaw = randomRange(0.5, 1.1)
	npc.scanGlideFreqPitch = randomRange(0.35, 0.9)
	npc.scanGlidePhaseYaw = randomRange(0, TAU)
	npc.scanGlidePhasePitch = randomRange(0, TAU)
	npc.scanGlideAmpYaw = math.min(scanYawRange * randomRange(0.16, 0.36), math.rad(20))
	npc.scanGlideAmpPitch = math.min(scanPitchRange * randomRange(0.2, 0.45), math.rad(7))
end

function HeadLookController.init(npc, neckMotor: Motor6D?, neckOriginalC0: CFrame?)
	npc.headLookNeckMotor = neckMotor
	npc.headLookOriginalC0 = neckOriginalC0
	npc.headLookActive = false
	npc.headLookAlpha = 0
	npc.headLookEndTime = 0
	local checkInterval = math.max(0.1, Config.HeadLookCheckInterval)
	npc.headLookNextCheckTime = Workspace:GetServerTimeNow() + math.random() * checkInterval

	npc.scanActive = false
	npc.scanTarget = nil
	npc.scanExtent = nil
	npc.scanBlendAlpha = 0
	npc.scanMode = "idle"
	npc.scanCurrentYaw = 0
	npc.scanCurrentPitch = 0
	npc.scanFromYaw = 0
	npc.scanFromPitch = 0
	npc.scanToYaw = 0
	npc.scanToPitch = 0
	npc.scanTransitionElapsed = 0
	npc.scanTransitionDuration = 0
	npc.scanHoldRemaining = 0
	npc.scanHoldsUntilGlide = math.random(HOLDS_BETWEEN_GLIDES_MIN, HOLDS_BETWEEN_GLIDES_MAX)
	npc.scanGlideElapsed = 0
	npc.scanGlideDuration = 0
	npc.scanGlideBaseYaw = 0
	npc.scanGlideBasePitch = 0
	npc.scanGlideFreqYaw = 0
	npc.scanGlideFreqPitch = 0
	npc.scanGlidePhaseYaw = 0
	npc.scanGlidePhasePitch = 0
	npc.scanGlideAmpYaw = 0
	npc.scanGlideAmpPitch = 0
	npc.scanSettleRemaining = 0
	npc.scanLastYawRange = SCAN_DEFAULT_YAW_RANGE
	npc.scanLastPitchRange = SCAN_DEFAULT_PITCH_RANGE
	npc.scanOutputYaw = 0
	npc.scanOutputPitch = 0

	if not npc.headLookNeckMotor or not npc.headLookOriginalC0 then
		for _, desc in ipairs(npc.model:GetDescendants()) do
			if desc:IsA("Motor6D") and desc.Name == "Neck" then
				npc.headLookNeckMotor = desc
				npc.headLookOriginalC0 = desc.C0
				break
			end
		end
	end
end

function HeadLookController.update(npc, playerPosition: Vector3, dt: number, now: number)
	local neckMotor = npc.headLookNeckMotor
	local originalC0 = npc.headLookOriginalC0
	if not neckMotor or not originalC0 then
		return
	end
	if not neckMotor.Parent then
		return
	end

	if not npc.headLookActive
		and (npc.headLookAlpha or 0) <= 0
		and now < (npc.headLookNextCheckTime or 0)
	then
		return
	end

	if now >= (npc.headLookNextCheckTime or 0) then
		local rootPart = npc.model.PrimaryPart
		if rootPart then
			local distance = (playerPosition - rootPart.Position).Magnitude
			if distance <= Config.HeadLookDistance then
				if npc.headLookActive then
					npc.headLookEndTime = now + Config.HeadLookDuration
				elseif math.random() <= Config.HeadLookChance then
					npc.headLookActive = true
					npc.headLookEndTime = now + Config.HeadLookDuration
					if Config.DiagnosticsEnabled then
						print(string.format("[WanderingProps] HEAD_LOOK_START %s distance=%.1f", npc.id, distance))
					end
				end
			end
		end
		npc.headLookNextCheckTime = now + math.max(0.1, Config.HeadLookCheckInterval)
	end

	if npc.headLookActive and now >= (npc.headLookEndTime or 0) then
		npc.headLookActive = false
	end

	local targetAlpha = if npc.headLookActive then 1 else 0
	local currentAlpha = npc.headLookAlpha or 0
	local blendAlpha = math.min(1, math.max(0, dt) * math.max(0, Config.HeadLookLerpSpeed))
	local nextAlpha = currentAlpha + (targetAlpha - currentAlpha) * blendAlpha
	npc.headLookAlpha = nextAlpha

	if nextAlpha < 0.01 then
		npc.headLookAlpha = 0
		if not npc.scanActive and (npc.scanBlendAlpha or 0) <= 0.001 then
			neckMotor.C0 = originalC0
		end
		return
	end

	local rootPart = npc.model.PrimaryPart
	if not rootPart then
		return
	end

	local headPos = rootPart.Position
	if neckMotor.Part1 then
		headPos = neckMotor.Part1.Position
	end

	local toPlayer = playerPosition - headPos
	if toPlayer.Magnitude <= 0.001 then
		neckMotor.C0 = originalC0
		return
	end

	local localDir = rootPart.CFrame:VectorToObjectSpace(toPlayer.Unit)
	local yaw = math.atan2(localDir.X, -localDir.Z)
	local forward = math.sqrt(localDir.X * localDir.X + localDir.Z * localDir.Z)
	local pitch = math.atan2(-localDir.Y, forward)

	local maxYaw = math.rad(Config.HeadLookMaxYaw)
	local maxPitch = math.rad(Config.HeadLookMaxPitch)
	local breakYaw = maxYaw * 0.8
	local breakPitch = maxPitch * 0.8
	if npc.headLookActive and (math.abs(yaw) > breakYaw or math.abs(pitch) > breakPitch) then
		npc.headLookActive = false
		npc.headLookEndTime = 0
		npc.headLookNextCheckTime = now + Config.HeadLookCheckInterval
		npc.headLookAlpha = currentAlpha + (0 - currentAlpha) * blendAlpha
		if npc.headLookAlpha < 0.01 then
			npc.headLookAlpha = 0
		end
		neckMotor.C0 = neckMotor.C0:Lerp(originalC0, blendAlpha)
		return
	end

	yaw = math.clamp(yaw, -maxYaw, maxYaw)
	pitch = math.clamp(pitch, -maxPitch, maxPitch)

	local rotation = CFrame.Angles(pitch * nextAlpha, -yaw * nextAlpha, 0)
	neckMotor.C0 = originalC0 * rotation
end

function HeadLookController.startScan(npc, scanTarget: Vector3, scanExtent: number)
	npc.scanActive = true
	npc.scanTarget = scanTarget
	npc.scanExtent = math.max(0, scanExtent or 0)
	npc.scanMode = "settle"
	npc.scanSettleRemaining = SCAN_START_SETTLE_TIME
	npc.scanHoldRemaining = 0
	npc.scanTransitionElapsed = 0
	npc.scanTransitionDuration = 0
	npc.scanHoldsUntilGlide = math.random(HOLDS_BETWEEN_GLIDES_MIN, HOLDS_BETWEEN_GLIDES_MAX)
	npc.scanCurrentYaw = 0
	npc.scanCurrentPitch = 0
	npc.scanFromYaw = 0
	npc.scanFromPitch = 0
	npc.scanToYaw = 0
	npc.scanToPitch = 0
	npc.scanOutputYaw = 0
	npc.scanOutputPitch = 0
	npc.scanBlendAlpha = 0
	npc.scanLastYawRange = SCAN_DEFAULT_YAW_RANGE
	npc.scanLastPitchRange = SCAN_DEFAULT_PITCH_RANGE
end

function HeadLookController.stopScan(npc)
	npc.scanActive = false
	npc.scanTarget = nil
	npc.scanExtent = nil
	npc.scanMode = "idle"
	npc.scanHoldRemaining = 0
	npc.scanTransitionElapsed = 0
	npc.scanTransitionDuration = 0
	npc.scanGlideElapsed = 0
	npc.scanGlideDuration = 0
	npc.scanSettleRemaining = 0
end

function HeadLookController.applyScan(npc, dt: number)
	local neckMotor = npc.headLookNeckMotor
	local originalC0 = npc.headLookOriginalC0
	if not neckMotor or not originalC0 or not neckMotor.Parent then
		return
	end

	-- Player look always overrides marketplace scan.
	if npc.headLookActive or (npc.headLookAlpha or 0) > 0.01 then
		npc.scanBlendAlpha = approach(npc.scanBlendAlpha or 0, 0, 8, dt)
		return
	end

	local hasScanTarget = npc.scanActive and npc.scanTarget ~= nil
	local blendTarget = if hasScanTarget then 1 else 0
	local blendSpeed = if hasScanTarget then 7 else 5
	local scanBlend = approach(npc.scanBlendAlpha or 0, blendTarget, blendSpeed, dt)
	npc.scanBlendAlpha = scanBlend

	if hasScanTarget then
		local scanYawRange, scanPitchRange = computeScanRanges(npc, neckMotor, dt)
		local currentYaw = npc.scanCurrentYaw or 0
		local currentPitch = npc.scanCurrentPitch or 0

		if npc.scanMode == "settle" then
			npc.scanSettleRemaining = math.max(0, (npc.scanSettleRemaining or 0) - math.max(0, dt))
			currentYaw = 0
			currentPitch = 0
			if (npc.scanSettleRemaining or 0) <= 0 then
				local toYaw, toPitch = sampleLookTarget(currentYaw, scanYawRange, scanPitchRange)
				beginTransition(npc, toYaw, toPitch)
			end
		elseif npc.scanMode == "bootstrap" or npc.scanMode == "idle" then
			local toYaw, toPitch = sampleLookTarget(currentYaw, scanYawRange, scanPitchRange)
			beginTransition(npc, toYaw, toPitch)
		end

		if npc.scanMode == "transition" then
			npc.scanTransitionElapsed = (npc.scanTransitionElapsed or 0) + math.max(0, dt)
			local duration = math.max(0.01, npc.scanTransitionDuration or 0)
			local alpha = smoothstep(npc.scanTransitionElapsed / duration)
			local fromYaw = npc.scanFromYaw or 0
			local fromPitch = npc.scanFromPitch or 0
			local toYaw = npc.scanToYaw or 0
			local toPitch = npc.scanToPitch or 0
			currentYaw = fromYaw + (toYaw - fromYaw) * alpha
			currentPitch = fromPitch + (toPitch - fromPitch) * alpha
			if alpha >= 1 then
				currentYaw = toYaw
				currentPitch = toPitch
				beginHold(npc)
			end
		elseif npc.scanMode == "hold" then
			npc.scanHoldRemaining = math.max(0, (npc.scanHoldRemaining or 0) - math.max(0, dt))
			if (npc.scanHoldRemaining or 0) <= 0 then
				local holdsUntilGlide = npc.scanHoldsUntilGlide or 0
				if holdsUntilGlide <= 0 and (scanYawRange > math.rad(6) or scanPitchRange > math.rad(3)) then
					beginGlide(npc, scanYawRange, scanPitchRange)
				else
					npc.scanHoldsUntilGlide = math.max(0, holdsUntilGlide - 1)
					local toYaw, toPitch = sampleLookTarget(currentYaw, scanYawRange, scanPitchRange)
					beginTransition(npc, toYaw, toPitch)
				end
			end
		elseif npc.scanMode == "glide" then
			npc.scanGlideElapsed = (npc.scanGlideElapsed or 0) + math.max(0, dt)
			local t = npc.scanGlideElapsed or 0
			local yawPhase = t * (npc.scanGlideFreqYaw or 0.8) * TAU + (npc.scanGlidePhaseYaw or 0)
			local pitchPhase = t * (npc.scanGlideFreqPitch or 0.6) * TAU + (npc.scanGlidePhasePitch or 0)
			local drift = math.sin(yawPhase * 0.4 + 1.37) * (npc.scanGlideAmpYaw or 0) * 0.25
			currentYaw = (npc.scanGlideBaseYaw or 0) + math.sin(yawPhase) * (npc.scanGlideAmpYaw or 0) + drift
			currentPitch = (npc.scanGlideBasePitch or 0) + math.sin(pitchPhase) * (npc.scanGlideAmpPitch or 0)
			if t >= math.max(0.01, npc.scanGlideDuration or 0) then
				npc.scanHoldsUntilGlide = math.random(HOLDS_BETWEEN_GLIDES_MIN, HOLDS_BETWEEN_GLIDES_MAX)
				local toYaw, toPitch = sampleLookTarget(currentYaw, scanYawRange, scanPitchRange)
				beginTransition(npc, toYaw, toPitch)
			end
		end

		npc.scanCurrentYaw = math.clamp(currentYaw, -scanYawRange, scanYawRange)
		npc.scanCurrentPitch = math.clamp(currentPitch, -scanPitchRange, scanPitchRange)
	end

	if scanBlend <= 0.001 and not hasScanTarget then
		scanBlend = 0
		npc.scanBlendAlpha = 0
	end

	local desiredYaw = npc.scanCurrentYaw or 0
	local desiredPitch = npc.scanCurrentPitch or 0
	local outputSpeed = if hasScanTarget then SCAN_OUTPUT_SPEED_ACTIVE else SCAN_OUTPUT_SPEED_INACTIVE
	npc.scanOutputYaw = approach(npc.scanOutputYaw or 0, desiredYaw, outputSpeed, dt)
	npc.scanOutputPitch = approach(npc.scanOutputPitch or 0, desiredPitch, outputSpeed, dt)

	local targetC0 = originalC0 * CFrame.Angles((npc.scanOutputPitch or 0) * scanBlend, -(npc.scanOutputYaw or 0) * scanBlend, 0)
	local neckLerpSpeed = if hasScanTarget then 11 else 7
	neckMotor.C0 = neckMotor.C0:Lerp(targetC0, math.min(1, math.max(0, dt) * neckLerpSpeed))
end

function HeadLookController.reset(npc)
	if npc.headLookNeckMotor and npc.headLookOriginalC0 then
		npc.headLookNeckMotor.C0 = npc.headLookOriginalC0
	end
	npc.headLookAlpha = 0
	npc.headLookActive = false
	npc.headLookEndTime = 0
	npc.headLookNextCheckTime = 0
	npc.scanActive = false
	npc.scanTarget = nil
	npc.scanExtent = nil
	npc.scanBlendAlpha = 0
	npc.scanMode = "idle"
	npc.scanCurrentYaw = 0
	npc.scanCurrentPitch = 0
	npc.scanFromYaw = 0
	npc.scanFromPitch = 0
	npc.scanToYaw = 0
	npc.scanToPitch = 0
	npc.scanTransitionElapsed = 0
	npc.scanTransitionDuration = 0
	npc.scanHoldRemaining = 0
	npc.scanHoldsUntilGlide = math.random(HOLDS_BETWEEN_GLIDES_MIN, HOLDS_BETWEEN_GLIDES_MAX)
	npc.scanGlideElapsed = 0
	npc.scanGlideDuration = 0
	npc.scanGlideBaseYaw = 0
	npc.scanGlideBasePitch = 0
	npc.scanGlideFreqYaw = 0
	npc.scanGlideFreqPitch = 0
	npc.scanGlidePhaseYaw = 0
	npc.scanGlidePhasePitch = 0
	npc.scanGlideAmpYaw = 0
	npc.scanGlideAmpPitch = 0
	npc.scanSettleRemaining = 0
	npc.scanLastYawRange = SCAN_DEFAULT_YAW_RANGE
	npc.scanLastPitchRange = SCAN_DEFAULT_PITCH_RANGE
	npc.scanOutputYaw = 0
	npc.scanOutputPitch = 0
end

return HeadLookController
