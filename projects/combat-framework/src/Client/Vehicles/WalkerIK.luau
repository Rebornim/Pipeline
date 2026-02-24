--!strict
--------------------------------------------------------------------------------
-- WalkerIK.luau — Procedural AT-ST walking (3-segment legs)
--
-- Leg chain per side:
--   Pivot (fixed on body front) → HipStrut (rigid, pivots) → Hip →
--   UpperLeg (2-bone IK) → Knee → LowerLeg (2-bone IK) → Foot (flat pad)
--
-- The strut PIVOTS at its body attachment. It does NOT stretch/compress.
-- When the body bounces (bob/jolt/sway), the pivot moves with it.
-- The strut swings to keep its end (hip) near the ideal position,
-- constrained to strutLength from the pivot. This is the suspension.
--
-- Sections:
--   1. Foot homes + gait geometry (from raw body)
--   2. Gait state machine
--   3. Foot step animation
--   4. Body secondary motion → modBody
--   5. Strut pivot (from modBody) → constrained hip → 2-bone IK → foot CF
--
-- Convention: positive "forward" config values = toward LookVector.
--------------------------------------------------------------------------------

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local sharedRoot = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatTypes = require(sharedRoot:WaitForChild("CombatTypes"))

type VehicleConfig = CombatTypes.VehicleConfig

local WalkerIK = {}

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

export type FootState = {
	planted: Vector3,
	target: Vector3,
	home: Vector3,
	state: string,
	progress: number,
	settleTimer: number,
	smoothedNormal: Vector3,
}

export type WalkerIKState = {
	leftFoot: FootState,
	rightFoot: FootState,
	lastStepSide: string,
	lastGaitSide: string,
	smoothedSway: number,
	swayVelocity: number,
	smoothedBob: number,
	joltValue: number,
	joltVelocity: number,
	fig8Dir: number,
	smoothedFig8: number,
	initialized: boolean,
}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- Reject steep surfaces (walls/cliff faces) — feet only plant on walkable ground
local FOOT_GROUND_MIN_DOT = 0.5 -- cos(60°): anything steeper is treated as no ground

local function rayDown(origin: Vector3, params: RaycastParams, fallbackY: number): Vector3
	local hit = Workspace:Raycast(origin + Vector3.new(0, 5, 0), Vector3.new(0, -50, 0), params)
	if hit and hit.Normal:Dot(Vector3.yAxis) >= FOOT_GROUND_MIN_DOT then
		return hit.Position
	end
	return Vector3.new(origin.X, fallbackY, origin.Z)
end

local function hdist(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

local function solveKnee(
	hip: Vector3,
	foot: Vector3,
	upperLen: number,
	lowerLen: number,
	kneeHint: Vector3
): Vector3
	local toFoot = foot - hip
	local dist = math.clamp(toFoot.Magnitude, math.abs(upperLen - lowerLen) + 0.01, upperLen + lowerLen - 0.01)
	local dir = toFoot.Unit

	local cosHip = (upperLen * upperLen + dist * dist - lowerLen * lowerLen) / (2 * upperLen * dist)
	local hipAngle = math.acos(math.clamp(cosHip, -1, 1))

	local norm = dir:Cross(kneeHint)
	if norm.Magnitude < 0.001 then norm = dir:Cross(Vector3.new(0, 0, -1)) end
	if norm.Magnitude < 0.001 then norm = dir:Cross(Vector3.new(1, 0, 0)) end
	norm = norm.Unit

	local upperDir = (CFrame.fromAxisAngle(norm, -hipAngle) * CFrame.new(dir)).Position.Unit
	return hip + upperDir * upperLen
end

-- Hinge bone CFrame: single-axis rotation constraint.
-- Y axis = actual bone direction (parts connect at joints).
-- X axis = hinge axis projected perpendicular to bone (locks roll).
local function hingeBoneCF(joint1: Vector3, joint2: Vector3, hingeAxis: Vector3): CFrame
	local boneDir = (joint2 - joint1)
	if boneDir.Magnitude < 0.001 then boneDir = -Vector3.yAxis end
	boneDir = boneDir.Unit
	local mid = (joint1 + joint2) * 0.5
	local xAxis = hingeAxis - boneDir * hingeAxis:Dot(boneDir)
	if xAxis.Magnitude < 0.001 then xAxis = Vector3.xAxis end
	xAxis = xAxis.Unit
	return CFrame.fromMatrix(mid, xAxis, boneDir)
end

-- 3-point ground plane normal for foot orientation.
-- Probes front, back-left, back-right of foot pad to compute surface tilt.
local function footSurfaceNormal(
	footPos: Vector3, footFwd: Vector3, footRight: Vector3,
	footLen: number, params: RaycastParams
): Vector3
	local halfLen = footLen * 0.5
	local p1 = footPos + footFwd * halfLen
	local p2 = footPos - footFwd * halfLen - footRight * halfLen
	local p3 = footPos - footFwd * halfLen + footRight * halfLen

	local function probe(origin: Vector3): Vector3?
		local hit = Workspace:Raycast(origin + Vector3.yAxis * 2, Vector3.new(0, -6, 0), params)
		return if hit then hit.Position else nil
	end

	local h1, h2, h3 = probe(p1), probe(p2), probe(p3)
	if h1 and h2 and h3 then
		local normal = (h2 - h1):Cross(h3 - h1)
		if normal.Y < 0 then normal = -normal end
		if normal.Magnitude > 0.001 then return normal.Unit end
	end
	return Vector3.yAxis
end

--------------------------------------------------------------------------------
-- Create state
--------------------------------------------------------------------------------

local function makeFoot(): FootState
	return { planted = Vector3.zero, target = Vector3.zero, home = Vector3.zero, state = "planted", progress = 0, settleTimer = 1, smoothedNormal = Vector3.yAxis }
end

function WalkerIK.createState(): WalkerIKState
	return {
		leftFoot = makeFoot(),
		rightFoot = makeFoot(),
		lastStepSide = "right",
		lastGaitSide = "left",
		smoothedSway = 0,
		swayVelocity = 0,
		smoothedBob = 0,
		joltValue = 0,
		joltVelocity = 0,
		fig8Dir = 0,
		smoothedFig8 = 0,
		wasGaitActive = false,
		settleLeft = false,
		settleRight = false,
		initialized = false,
		prevSpeed = 0,
	}
end

--------------------------------------------------------------------------------
-- Main update
-- Returns 11 CFrames:
--   modBody, lStrut1, lStrut2, lUpper, lLower, lFoot, rStrut1, rStrut2, rUpper, rLower, rFoot
--------------------------------------------------------------------------------

function WalkerIK.update(
	s: WalkerIKState,
	body: CFrame,
	vel: Vector3,
	cfg: VehicleConfig,
	dt: number,
	ray: RaycastParams,
	gaitPhase: number?,
	gaitSide: string?,
	gaitActive: boolean?,
	sprintFrac: number?,
	isOccupied: boolean?
): (CFrame, CFrame, CFrame, CFrame, CFrame, CFrame, CFrame, CFrame, CFrame, CFrame, CFrame, boolean, boolean, boolean, boolean)

	local sf = sprintFrac or 0
	local function lerp(a: number, b: number): number return a + (b - a) * sf end

	local upperLen   = cfg.legUpperLength or 6
	local lowerLen   = cfg.legLowerLength or 6
	local threshold  = cfg.stepThreshold or 4
	local duration   = cfg.stepDuration or 0.3
	local arcHeight  = lerp(cfg.stepHeight or 2, cfg.sprintStepHeight or 9)
	local lead       = lerp(cfg.strideLead or 12, cfg.sprintStrideLead or 24)
	local latOff     = cfg.homeOffsetLateral or 4
	local homeFwd    = cfg.homeOffsetForward or 2
	local walkH      = cfg.walkHeight or 12
	local hipFwd     = cfg.hipAttachForward or -2
	local hipVert    = cfg.hipAttachVertical or -1
	local strutFwd   = cfg.strutAttachForward or 2
	local strutVert  = cfg.strutAttachVertical or -1
	local strutLen   = cfg.strutLength or 4
	local maxSpd     = lerp(cfg.maxSpeed or 25, cfg.sprintMaxSpeed or 62.5)
	local swayAmp    = lerp(cfg.swayAmplitude or 0.4, cfg.sprintSwayAmplitude or 6)
	local bobAmp     = lerp(cfg.bobAmplitude or 0.3, cfg.sprintBobAmplitude or 5)
	local leanMax    = math.rad(lerp(cfg.leanMaxAngle or 3, cfg.sprintLeanAngle or 8))
	local joltAmp    = lerp(cfg.impactJoltAmplitude or 0.15, cfg.sprintImpactJoltAmplitude or 1.2)
	local joltDecay  = cfg.impactJoltDecay or 12
	local toeTilt    = math.rad(cfg.stepToeTilt or 10)

	local pos = body.Position
	local fwd = body.LookVector
	local rgt = body.RightVector
	local up  = body.UpVector
	local fallY = pos.Y - walkH

	--------------------------------------------------------------------
	-- 1. GEOMETRY (from raw body — stable reference)
	--------------------------------------------------------------------

	-- Velocity decomposition (needed by homes and gait)
	local hVel = Vector3.new(vel.X, 0, vel.Z)
	local spd  = hVel.Magnitude
	local ratio = math.clamp(spd / maxSpd, 0, 1)
	local leadDir = if spd > 0.5 then hVel.Unit else fwd
	local strafeFrac = if spd > 0.5 then math.abs(hVel:Dot(rgt)) / spd else 0
	local effectiveLead = lead + strafeFrac * lead * 0.4
	local leadVec = leadDir * ratio * effectiveLead

	-- Ideal hip targets: where the hip "wants" to be (raw body, no bounce)
	local leftHipTarget  = pos + fwd * hipFwd + up * hipVert - rgt * latOff
	local rightHipTarget = pos + fwd * hipFwd + up * hipVert + rgt * latOff

	-- Foot homes: where feet ideally rest (projected to ground)
	-- Forward component of velocity determines home bias direction.
	-- Backward: homes shift behind (half distance to avoid overextend).
	-- Strafing: homes stay centered (no lateral shift, prevents crossover).
	local walkBias = cfg.footInwardBias or 0
	local sprintBias = cfg.sprintFootInwardBias or walkBias
	local footLat = latOff - lerp(walkBias, sprintBias)
	local velFwdDot = if spd > 0.5 then hVel:Dot(fwd) / spd else 1
	-- Gait-based home offset: full forward when walking, zero when idle.
	-- Gait activates before speed builds up, so feet lead the first step.
	local useGaitHome = (gaitActive == true) or spd > 1
	local homeBias = if useGaitHome
		then fwd * homeFwd * math.clamp(velFwdDot, -0.5, 1)
		else Vector3.zero
	s.leftFoot.home  = rayDown(pos + homeBias - rgt * footLat, ray, fallY)
	s.rightFoot.home = rayDown(pos + homeBias + rgt * footLat, ray, fallY)

	if not s.initialized then
		s.leftFoot.planted  = s.leftFoot.home
		s.leftFoot.target   = s.leftFoot.home
		s.rightFoot.planted = s.rightFoot.home
		s.rightFoot.target  = s.rightFoot.home
		s.initialized = true
	end

	--------------------------------------------------------------------
	-- 2. GAIT
	--------------------------------------------------------------------

	-- Snapshot pre-gait states (gait section changes state before we can check it)
	local lWasPlantedPreGait = s.leftFoot.state == "planted"
	local rWasPlantedPreGait = s.rightFoot.state == "planted"

	local walkHalfCycle = cfg.halfCycleDuration or 0.5
	local sprintHalfCycle = cfg.sprintHalfCycleDuration or 0.4
	local halfCycleDur = lerp(walkHalfCycle, sprintHalfCycle)
	-- If gait says active but body is barely moving (wall collision), fall back to
	-- distance-based triggers so feet pull back to home instead of stepping past walls
	local useGait = gaitActive == true and spd > 1

	-- When gait is active, step duration is a fraction of half-cycle.
	-- Walk: 70% stepping / 30% planted (deliberate steps).
	-- Sprint: 92% stepping / 8% planted (brief ground contact, less time to fall behind).
	if useGait then
		local stepFrac = 0.7 + sf * 0.22
		duration = halfCycleDur * stepFrac
	end

	local lDist = hdist(s.leftFoot.planted, s.leftFoot.home)
	local rDist = hdist(s.rightFoot.planted, s.rightFoot.home)

	local function triggerStep(foot: FootState, side: string, otherState: string)
		if otherState ~= "planted" then return end
		foot.state = "stepping"
		-- Leading foot in strafe direction reaches further, trailing foot uses normal lead
		local stepLead = leadVec
		if strafeFrac > 0.3 then
			local strafeSign = if hVel:Dot(rgt) > 0 then 1 else -1
			local isLeadFoot = (side == "left" and strafeSign < 0) or (side == "right" and strafeSign > 0)
			if isLeadFoot then
				stepLead = leadVec * 1.8
			end
		end
		foot.target = rayDown(foot.home + stepLead, ray, fallY)
		foot.progress = 0
		s.lastStepSide = side
	end

	-- Helper: force the first step with a generous forward lead.
	-- Normal leadVec is tiny at low speed, so we use half the full stride
	-- lead to put the foot well ahead of the accelerating body.
	local function forceFirstStep()
		if s.leftFoot.state ~= "planted" or s.rightFoot.state ~= "planted" then
			return
		end
		local firstLead = leadDir * lead * 0.5
		s.leftFoot.state = "stepping"
		s.leftFoot.target = rayDown(s.leftFoot.home + firstLead, ray, fallY)
		s.leftFoot.progress = 0
		s.lastStepSide = "left"
	end

	if useGait then
		-- FIRST-STEP ON GAIT ACTIVATION: gait just turned on but gaitSide
		-- won't change for a full half-cycle (~0.65s). Force the first step
		-- immediately so the feet lead the body instead of lagging behind.
		if not s.wasGaitActive then
			forceFirstStep()
		end

		-- Normal gait: step when server swaps gaitSide
		local gSide = gaitSide or "left"
		local gPhase = gaitPhase or 0
		local sideChanged = gSide ~= s.lastGaitSide
		s.lastGaitSide = gSide

		if sideChanged then
			if gSide == "left" and s.leftFoot.state == "planted" then
				triggerStep(s.leftFoot, "left", s.rightFoot.state)
			elseif gSide == "right" and s.rightFoot.state == "planted" then
				triggerStep(s.rightFoot, "right", s.leftFoot.state)
			end
		end
	else
		-- PRE-GAIT FIRST-STEP: body started moving (velocity detected) but
		-- gait attribute hasn't replicated yet. Covers the 1-2 frame gap.
		if spd > 0.3 and s.prevSpeed < 0.2 then
			forceFirstStep()
		end

		-- Gait just stopped: queue settle steps to bring feet to homes
		if s.wasGaitActive then
			s.settleLeft = true
			s.settleRight = true
		end

		-- Settle: step feet back to home (one at a time)
		if s.settleLeft and s.leftFoot.state == "planted" and s.rightFoot.state ~= "stepping" then
			if lDist > 1 then
				s.leftFoot.state = "stepping"
				s.leftFoot.target = s.leftFoot.home
				s.leftFoot.progress = 0
				s.lastStepSide = "left"
			end
			s.settleLeft = false
		end
		if s.settleRight and s.rightFoot.state == "planted" and s.leftFoot.state ~= "stepping" then
			if rDist > 1 then
				s.rightFoot.state = "stepping"
				s.rightFoot.target = s.rightFoot.home
				s.rightFoot.progress = 0
				s.lastStepSide = "right"
			end
			s.settleRight = false
		end

		-- Fallback: distance-based triggers (standing adjustments, no driver)
		local lWant = lDist > threshold and s.leftFoot.state == "planted"
		local rWant = rDist > threshold and s.rightFoot.state == "planted"

		if lWant and rWant then
			if lDist >= rDist then rWant = false else lWant = false end
		end

		if lWant then triggerStep(s.leftFoot, "left", s.rightFoot.state) end
		if rWant then triggerStep(s.rightFoot, "right", s.leftFoot.state) end
	end
	s.prevSpeed = spd

	s.wasGaitActive = useGait

	--------------------------------------------------------------------
	-- 3. FEET — step animation
	--------------------------------------------------------------------
	local function animateFoot(f: FootState): Vector3
		if f.state == "stepping" then
			f.progress += dt / duration
			if f.progress >= 1 then
				f.planted = f.target
				f.state = "planted"
				f.progress = 0
				f.settleTimer = 0
				s.joltVelocity -= joltAmp * 8
			else
				local t = f.progress
				local st = t * t * (3 - 2 * t)
				local horiz = f.planted:Lerp(f.target, st)

				-- Arc shape blends between walk and sprint:
				-- Walk: peak at 35% (gentle pull-up, cosine descent)
				-- Sprint: peak at 20% (sharp kick-back, holds height, drops to land)
				local arcPeak = 0.35 - sf * 0.15  -- walk 0.35 → sprint 0.20
				local arc
				if t < arcPeak then
					arc = math.sin(t / arcPeak * math.pi * 0.5) * arcHeight
				else
					local fallT = (t - arcPeak) / (1 - arcPeak)
					local fallShape = fallT * fallT
					local cosShape = 1 - math.cos(fallT * math.pi * 0.5)
					local shape = cosShape + (fallShape - cosShape) * sf
					arc = (1 - shape) * arcHeight
				end

				return horiz + Vector3.new(0, arc + 0.25, 0)
			end
		end
		return f.planted + Vector3.new(0, 0.25, 0)
	end

	-- Sprint: smoothly chase the stepping foot's target toward the body.
	-- Planted feet stay FIXED on the ground for the push-off feel.
	if sf > 0.2 then
		local chaseRate = 1 - math.exp(-12 * dt)
		if s.leftFoot.state == "stepping" then
			local ideal = rayDown(s.leftFoot.home + leadVec, ray, fallY)
			s.leftFoot.target = s.leftFoot.target:Lerp(ideal, chaseRate * sf)
		end
		if s.rightFoot.state == "stepping" then
			local ideal = rayDown(s.rightFoot.home + leadVec, ray, fallY)
			s.rightFoot.target = s.rightFoot.target:Lerp(ideal, chaseRate * sf)
		end
	end

	-- Track which foot was stepping before animate (to detect plant events)
	local lWasStepping = s.leftFoot.state == "stepping"
	local rWasStepping = s.rightFoot.state == "stepping"

	local leftFoot  = animateFoot(s.leftFoot)
	local rightFoot = animateFoot(s.rightFoot)

	-- Emergency foot reset: if a foot is impossibly far from the body (cliff fall,
	-- wall overshoot), snap it to home. Threshold is generous enough to never
	-- trigger during normal walking or sprinting.
	local maxFootReach = (upperLen + lowerLen) * 2
	local function resetIfOverextended(foot: FootState, footPos: Vector3): Vector3
		-- Foot above the body = cliff fall (never happens during normal movement)
		-- Or total distance exceeds max reach
		if footPos.Y > pos.Y + 2 or (footPos - pos).Magnitude > maxFootReach then
			foot.planted = foot.home
			foot.target = foot.home
			foot.state = "planted"
			foot.progress = 0
			return foot.home + Vector3.new(0, 0.25, 0)
		end
		return footPos
	end
	leftFoot = resetIfOverextended(s.leftFoot, leftFoot)
	rightFoot = resetIfOverextended(s.rightFoot, rightFoot)

	-- Detect foot plant/lift events
	local lJustPlanted = lWasStepping and s.leftFoot.state == "planted"
	local rJustPlanted = rWasStepping and s.rightFoot.state == "planted"
	-- Lift uses pre-gait snapshot (gait changes state before lWasStepping is captured)
	local lJustLifted = lWasPlantedPreGait and s.leftFoot.state == "stepping"
	local rJustLifted = rWasPlantedPreGait and s.rightFoot.state == "stepping"
	-- Sway impulse on foot plant (swayAmp lerps between walk/sprint via config)
	if lJustPlanted then
		s.swayVelocity -= swayAmp * 2.4
		s.fig8Dir = -1
	end
	if rJustPlanted then
		s.swayVelocity += swayAmp * 2.4
		s.fig8Dir = 1
	end

	-- (Sprint uses the same walk step system with lerped parameters — no separate override)

	--------------------------------------------------------------------
	-- 4. BODY SECONDARY MOTION
	--------------------------------------------------------------------
	local off = CFrame.identity

	-- Rule A: Sway (spring-damper — impulse on foot plant, overshoots then settles)
	local swaySpring = 35
	local swayDamp = 7
	s.swayVelocity += (-s.smoothedSway * swaySpring) * dt
	s.swayVelocity *= math.exp(-swayDamp * dt)
	s.smoothedSway += s.swayVelocity * dt
	off *= CFrame.new(s.smoothedSway, 0, 0)
	-- Sway-induced torso roll: body tilts toward weight-bearing foot
	off *= CFrame.Angles(0, 0, -s.smoothedSway * 0.04)

	-- Rule B: Bob — body rises when a foot is in the air, peaks at foot apex.
	-- When both feet are stepping (sprint overlap), use the higher bob value.
	local bobTarget = 0
	local lBob = if s.leftFoot.state == "stepping"
		then math.sin(s.leftFoot.progress * math.pi) * bobAmp else 0
	local rBob = if s.rightFoot.state == "stepping"
		then math.sin(s.rightFoot.progress * math.pi) * bobAmp else 0
	bobTarget = math.max(lBob, rBob)
	s.smoothedBob += (bobTarget - s.smoothedBob) * (1 - math.exp(-14 * dt))
	off *= CFrame.new(0, s.smoothedBob, 0)

	-- Rule B2: Figure-8 lobe — sine bump pushes head toward planted side.
	-- Ramps from 0 at plant, peaks at 25% step progress (during bob rise),
	-- fades back to 0 by 50% (bob peak = top-center, no extra push).
	local fig8Push = 0
	if s.leftFoot.state == "stepping" or s.rightFoot.state == "stepping" then
		local stepProg = 0
		if s.leftFoot.state == "stepping" then stepProg = s.leftFoot.progress
		elseif s.rightFoot.state == "stepping" then stepProg = s.rightFoot.progress end
		local fig8Envelope = 0
		if stepProg < 0.5 then
			fig8Envelope = math.sin(stepProg / 0.5 * math.pi)
		end
		fig8Push = s.fig8Dir * fig8Envelope * swayAmp * 0.2
	end
	s.smoothedFig8 += (fig8Push - s.smoothedFig8) * (1 - math.exp(-10 * dt))
	off *= CFrame.new(s.smoothedFig8, 0, 0)

	-- Rule C: Lean into movement + sprint forward lean
	local spdFrac = math.clamp(spd / maxSpd, 0, 1)
	if spdFrac > 0.01 then
		local lv = body:VectorToObjectSpace(vel)
		local angle = math.atan2(lv.X, lv.Z)
		off *= CFrame.Angles(
			-math.cos(angle) * leanMax * spdFrac * 0.5,
			0,
			-math.sin(angle) * leanMax * spdFrac
		)
	end
	-- Sprint: extra forward pitch (body hunches forward when running)
	if sf > 0.01 then
		off *= CFrame.Angles(-math.rad(12) * sf * spdFrac, 0, 0)
	end

	-- Rule D: Impact jolt (spring-damper: smooth dip → bounce → settle)
	local joltSpring = 60
	s.joltVelocity += (-s.joltValue * joltSpring) * dt
	s.joltVelocity *= math.exp(-joltDecay * dt)
	s.joltValue += s.joltVelocity * dt
	if math.abs(s.joltValue) < 0.001 and math.abs(s.joltVelocity) < 0.01 then
		s.joltValue = 0
		s.joltVelocity = 0
	end
	off *= CFrame.new(0, s.joltValue, 0)

	-- Rule E: Terrain tilt
	local tilt = math.atan2(rightFoot.Y - leftFoot.Y, latOff * 2) * 0.3
	off *= CFrame.Angles(0, 0, tilt)

	-- Rule F: Servo vibration — tiny Perlin noise, machine is always alive
	-- Only when occupied (no micro-movements on idle unoccupied walkers)
	local t_now = tick()
	if isOccupied ~= false then
		local vibeX = math.noise(t_now * 12, 0.5, 0) * 0.04
		local vibeY = math.noise(0.5, t_now * 14, 0) * 0.03
		local vibeZ = math.noise(0, 0.5, t_now * 11) * 0.04
		off *= CFrame.new(vibeX, vibeY, vibeZ)
		-- Micro-rotation noise (subtle mechanical shudder)
		off *= CFrame.Angles(
			math.noise(t_now * 10, 3, 0) * 0.003,
			0,
			math.noise(3, t_now * 10, 0) * 0.003
		)
	end

	-- Rule G: Idle breathing — slow sway/bob when standing still
	-- Only when occupied
	if isOccupied ~= false and not useGait and spd < 1 then
		local idleSway = math.sin(t_now * 0.7) * 0.2
		local idleBob = math.sin(t_now * 1.1) * 0.1
		off *= CFrame.new(idleSway, idleBob, 0)
	end

	-- Rule H: Static forward lean — shifts cockpit center of gravity over the feet
	local idleLean = math.rad(cfg.bodyIdleLean or 0)
	if idleLean > 0 then
		off *= CFrame.Angles(-idleLean, 0, 0)
	end

	local modBody = body * off

	--------------------------------------------------------------------
	-- 5. LEGS — pivoting strut + 2-bone IK + foot
	--------------------------------------------------------------------

	-- 5a. STRUT1 — computed from modBody (moves with sway/bob/jolt).
	-- The sway drives the whole leg via the Strut1 lateral hinge.
	-- Hip targets shift by the same offset → Strut1-Strut2 angle stays constant.
	local mPos = modBody.Position
	local mFwd = modBody.LookVector
	local mUp  = modBody.UpVector
	local mRgt = modBody.RightVector

	local s1Fwd    = cfg.strut1AttachForward or -2
	local s1Vert   = cfg.strut1AttachVertical or -0.5
	local s1Lat    = cfg.strut1AttachLateral or 0.5
	local s1Len    = cfg.strut1Length or 4
	local s1Pitch  = math.rad(cfg.strut1PitchDeg or 25)
	local s1Spread = math.rad(cfg.strut1SpreadDeg or 15)

	-- Strut1 bases (on modBody — moves with sway)
	local lStrut1Base = mPos + mFwd * s1Fwd + mUp * s1Vert - mRgt * s1Lat
	local rStrut1Base = mPos + mFwd * s1Fwd + mUp * s1Vert + mRgt * s1Lat

	-- Strut1 direction: forward + down + outward (fixed angle from modBody)
	local s1FwdComp  = math.cos(s1Pitch)
	local s1DownComp = math.sin(s1Pitch)
	local s1OutComp  = math.sin(s1Spread)

	local lStrut1Dir = (mFwd * s1FwdComp - mUp * s1DownComp - mRgt * s1OutComp).Unit
	local rStrut1Dir = (mFwd * s1FwdComp - mUp * s1DownComp + mRgt * s1OutComp).Unit

	-- Strut1 ends = Strut2 pivots
	local lStrut1End = lStrut1Base + lStrut1Dir * s1Len
	local rStrut1End = rStrut1Base + rStrut1Dir * s1Len

	-- Strut1 CFrames (hinge axis = mFwd, lateral in/out hinge)
	local lStrut1CF = hingeBoneCF(lStrut1Base, lStrut1End, mFwd)
	local rStrut1CF = hingeBoneCF(rStrut1Base, rStrut1End, mFwd)

	-- 5b. STRUT2 + LEGS — Strut2 pivots at Strut1 ends, swings toward hip
	local leftPivot  = lStrut1End
	local rightPivot = rStrut1End

	-- Shift hip targets by the same sway offset as the body.
	-- This keeps Strut1-Strut2 angle constant (no pinch) while the
	-- whole leg tilts because hips shift but feet stay planted.
	local swayOffset = mPos - pos
	leftHipTarget = leftHipTarget + swayOffset
	rightHipTarget = rightHipTarget + swayOffset

	-- Bias hip target based on foot lift (strut reacts to stepping)
	local leftFootLift = leftFoot.Y - s.leftFoot.home.Y
	local rightFootLift = rightFoot.Y - s.rightFoot.home.Y
	leftHipTarget = leftHipTarget + Vector3.new(0, leftFootLift * 0.4, 0)
	rightHipTarget = rightHipTarget + Vector3.new(0, rightFootLift * 0.4, 0)


	-- Constrain hip to strutLength from Strut2 pivot
	local function constrainHip(pivot: Vector3, target: Vector3): Vector3
		local dir = target - pivot
		if dir.Magnitude < 0.01 then dir = -mFwd end
		return pivot + dir.Unit * strutLen
	end

	local leftHip  = constrainHip(leftPivot, leftHipTarget)
	local rightHip = constrainHip(rightPivot, rightHipTarget)

	-- Absorb body bob into strut: if the hip-to-foot chain would overextend
	-- (bob raises hip beyond IK reach), pull the hip DOWN toward the foot.
	-- Visually this looks like the strut compressing — natural suspension.
	-- The foot stays perfectly still on the ground (no bobbing artifact).
	local maxChain = (upperLen + lowerLen) * 0.95
	local function absorbOverextend(hip: Vector3, footPos: Vector3): Vector3
		local dist = (hip - footPos).Magnitude
		if dist > maxChain then
			return footPos + (hip - footPos).Unit * maxChain
		end
		return hip
	end
	leftHip = absorbOverextend(leftHip, leftFoot)
	rightHip = absorbOverextend(rightHip, rightFoot)

	-- Legs always face forward — fixed hinge axis (body right vector).
	-- Strut1→Strut2 joint absorbs the lateral mismatch (effective ball joint).
	-- No dynamic plane = no twisting.
	-- Knee hint with micro-noise (joints never perfectly rigid)
	local kneeNoise = Vector3.new(
		math.noise(t_now * 7, 5, 0) * 0.1,
		0,
		math.noise(5, t_now * 7, 0) * 0.1
	)
	local kneeHint = fwd + kneeNoise
	local lKnee = solveKnee(leftHip, leftFoot, upperLen, lowerLen, kneeHint)
	local rKnee = solveKnee(rightHip, rightFoot, upperLen, lowerLen, kneeHint)

	-- Strut2 + legs: hinge-constrained to rgt axis (connected at joints, roll-locked)
	local lStrut2CF = hingeBoneCF(leftPivot, leftHip, rgt)
	local rStrut2CF = hingeBoneCF(rightPivot, rightHip, rgt)

	local lUpperCF = hingeBoneCF(leftHip, lKnee, rgt)
	local lLowerCF = hingeBoneCF(lKnee, leftFoot, rgt)
	local rUpperCF = hingeBoneCF(rightHip, rKnee, rgt)
	local rLowerCF = hingeBoneCF(rKnee, rightFoot, rgt)

	-- Foot CFrames with toe tilt during step + settle wobble on plant
	local heading = math.atan2(-fwd.X, -fwd.Z)

	-- Tick settle timers
	if s.leftFoot.state == "planted" then s.leftFoot.settleTimer += dt end
	if s.rightFoot.state == "planted" then s.rightFoot.settleTimer += dt end

	-- Settle wobble: decaying pitch oscillation after plant (foot rocks then settles)
	local function settleWobble(foot: FootState): number
		local t2 = foot.settleTimer
		if t2 > 0.5 then return 0 end
		return math.sin(t2 * 28) * math.exp(-t2 * 10) * toeTilt * 0.4
	end

	local lTilt = if s.leftFoot.state == "stepping"
		then math.sin(s.leftFoot.progress * math.pi) * toeTilt
		else settleWobble(s.leftFoot)
	local rTilt = if s.rightFoot.state == "stepping"
		then math.sin(s.rightFoot.progress * math.pi) * toeTilt
		else settleWobble(s.rightFoot)

	-- Foot surface orientation: 3-point probe for planted feet, flat for stepping
	local footFwdDir = Vector3.new(-math.sin(heading), 0, -math.cos(heading))
	local footRgtDir = Vector3.new(-footFwdDir.Z, 0, footFwdDir.X)
	local footLen = cfg.footLength or 1.5

	-- Target normals: terrain surface when planted, flat when stepping
	local lNormalTarget = if s.leftFoot.state == "planted"
		then footSurfaceNormal(leftFoot, footFwdDir, footRgtDir, footLen, ray)
		else Vector3.yAxis
	local rNormalTarget = if s.rightFoot.state == "planted"
		then footSurfaceNormal(rightFoot, footFwdDir, footRgtDir, footLen, ray)
		else Vector3.yAxis

	-- Smooth normals: lerp toward target to avoid snapping on land/lift
	local normalRate = 1 - math.exp(-14 * dt)
	s.leftFoot.smoothedNormal = s.leftFoot.smoothedNormal:Lerp(lNormalTarget, normalRate).Unit
	s.rightFoot.smoothedNormal = s.rightFoot.smoothedNormal:Lerp(rNormalTarget, normalRate).Unit
	local lNormal = s.leftFoot.smoothedNormal
	local rNormal = s.rightFoot.smoothedNormal

	local function buildFootCF(footPos: Vector3, normal: Vector3, tiltAngle: number): CFrame
		local projFwd = (footFwdDir - normal * footFwdDir:Dot(normal))
		if projFwd.Magnitude < 0.001 then projFwd = footFwdDir end
		projFwd = projFwd.Unit
		local projRight = projFwd:Cross(normal).Unit
		return CFrame.fromMatrix(footPos, projRight, normal) * CFrame.Angles(-tiltAngle, 0, 0)
	end

	local lFootCF = buildFootCF(leftFoot, lNormal, lTilt)
	local rFootCF = buildFootCF(rightFoot, rNormal, rTilt)

	return modBody, lStrut1CF, lStrut2CF, lUpperCF, lLowerCF, lFootCF, rStrut1CF, rStrut2CF, rUpperCF, rLowerCF, rFootCF, lJustPlanted, rJustPlanted, lJustLifted, rJustLifted
end

return WalkerIK
