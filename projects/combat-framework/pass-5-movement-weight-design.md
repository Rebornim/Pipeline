# Pass 5 Polish: Movement Weight (Lateral Momentum + Acceleration Curve)

Date: 2026-02-20
Type: Design — physics feel, Step 2 of 3
Scope: VehicleServer.luau (velocity computation), CombatConfig, CombatTypes. No client changes.

---

## Overview

Two changes that add physical mass to the speeder:

1. **Lateral momentum**: Velocity lags behind heading changes. When you turn, the speeder briefly slides sideways before gripping in the new direction. Grip rate is speed-dependent — tight at low speed, looser at high speed.

2. **Acceleration curve**: Acceleration tapers near max speed. Punchy launch, gradual top-end approach. Replaces the current flat 80 studs/s² at all speeds.

---

## File Changes

### 1. CombatTypes.luau — VehicleConfig type additions

Add 4 fields (after `leanDustEmitCount` or after the last lean field):

```
lateralGripLow: number,
lateralGripHigh: number,
accelerationTaper: number,
accelerationMinFactor: number,
```

### 2. CombatConfig.luau — light_speeder values

Add to the `light_speeder` config table (after the lean effect values, before `hoverHeight`):

```lua
lateralGripLow = 14,
lateralGripHigh = 7,
accelerationTaper = 0.7,
accelerationMinFactor = 0.3,
```

Tuning notes:
- `lateralGripLow = 14`: at low speed, velocity realigns to heading in ~0.12s to 80%. Feels nimble, barely any slide. Just enough to sense mass.
- `lateralGripHigh = 7`: at max speed, velocity realigns in ~0.22s to 80%. Noticeable lateral slide on sharp turns — you feel the speeder's weight shift before it grips. Not ice physics, just inertia.
- `accelerationTaper = 0.7`: at max speed, acceleration drops to 30% of base (80 → 24 studs/s²). The speeder reaches 80% of max speed quickly, then gradually approaches the cap.
- `accelerationMinFactor = 0.3`: floor — acceleration never drops below 30% of base, even at max speed. Prevents the vehicle from feeling completely unresponsive near top speed.

Acceleration feel at key speeds (base 80 studs/s²):
| Speed | Speed% | Effective accel | Time from 0 to here |
|-------|--------|----------------|---------------------|
| 0 | 0% | 80 studs/s² | 0s |
| 30 | 25% | 66 studs/s² | ~0.4s |
| 60 | 50% | 52 studs/s² | ~1.0s |
| 90 | 75% | 38 studs/s² | ~1.9s |
| 108 | 90% | 30 studs/s² | ~2.5s |
| 120 | 100% | 24 studs/s² | ~3.3s |

Current (flat 80): 0 to 120 in 1.5s. New: 0 to 120 in ~3.3s. Feels like a real engine — punchy off the line, fighting drag at the top.

### 3. VehicleServer.luau — Acceleration taper

**Modify the NormalDrive ground branch (lines 644-685).**

After `climbSpeedCap` computation and lean speed penalty (lines 646-662), BEFORE the `computeTargetSpeed` call (line 664), insert:

```lua
			-- Acceleration taper: reduce acceleration as speed approaches max
			local accelTaperFraction = if currentDriveSpeed > 0
				then math.clamp(currentDriveSpeed / math.max(1, climbSpeedCap), 0, 1)
				else 0
			local accelMultiplier = math.max(
				state.config.accelerationMinFactor,
				1 - accelTaperFraction * state.config.accelerationTaper
			)
			local effectiveAccel = state.config.acceleration * accelMultiplier
```

**Modify the `computeTargetSpeed` call (lines 664-672).**

Current:
```lua
			local targetSpeed = computeTargetSpeed(
				currentDriveSpeed,
				state.inputThrottle,
				state.config.acceleration,
				state.config.deceleration,
				state.config.brakingDeceleration,
				climbSpeedCap,
				state.config.reverseMaxSpeed,
				dt
			)
```

New:
```lua
			local targetSpeed = computeTargetSpeed(
				currentDriveSpeed,
				state.inputThrottle,
				effectiveAccel,
				state.config.deceleration,
				state.config.brakingDeceleration,
				climbSpeedCap,
				state.config.reverseMaxSpeed,
				dt
			)
```

Only the `acceleration` parameter changes. Deceleration and braking are unchanged — they should feel consistent regardless of speed.

The taper applies only in the NormalDrive ground branch. CrestRelease (line 589) and BlockedClimb (line 621) use their own acceleration multipliers and are untouched.

The taper only activates when `currentDriveSpeed > 0` (moving forward). In reverse, `accelTaperFraction = 0`, so full base acceleration applies. Reverse max speed is only 30, so taper would be negligible anyway.

### 4. VehicleServer.luau — Lateral momentum (grip blend)

**Modify the velocity assignment at the end of the NormalDrive ground branch (line 685).**

Current:
```lua
			state.velocity = Vector3.new(driveVelocity.X, blendedVerticalSpeed, driveVelocity.Z)
```

New:
```lua
			-- Lateral momentum: blend current horizontal velocity toward desired direction
			local desiredHorizontal = Vector3.new(driveVelocity.X, 0, driveVelocity.Z)
			local currentHorizontal = Vector3.new(state.velocity.X, 0, state.velocity.Z)
			local gripRate = state.config.lateralGripLow
				+ (state.config.lateralGripHigh - state.config.lateralGripLow) * speedFractionForTurn
			local gripAlpha = 1 - math.exp(-gripRate * dt)
			local blendedHorizontal = currentHorizontal:Lerp(desiredHorizontal, gripAlpha)
			state.velocity = Vector3.new(blendedHorizontal.X, blendedVerticalSpeed, blendedHorizontal.Z)
```

`speedFractionForTurn` is already computed on line 491. It's `horizontalSpeed / maxSpeed`, which gives 0 at standstill and 1 at max speed.

How the grip blend works:
- `desiredHorizontal`: where the vehicle WANTS to go (forward direction * target speed). This is the heading-aligned velocity.
- `currentHorizontal`: where the vehicle IS going. When the heading changes, this still points in the old direction.
- `gripAlpha`: how fast velocity catches up. Uses frame-rate-independent exponential smoothing (`1 - exp(-rate * dt)`).
- `blendedHorizontal`: the actual resulting velocity. Gradually steers from the old direction to the new direction.

At low speed (gripRate 14): velocity catches up quickly (~0.12s to 80%). Turns feel responsive.
At high speed (gripRate 7): velocity lags noticeably (~0.22s to 80%). Sharp turns produce a brief sideways slide before the speeder grips in the new direction.

**What this does NOT affect:**
- **Vertical velocity**: `blendedVerticalSpeed` is passed through unchanged. The grip blend only operates on X/Z.
- **CrestRelease/BlockedClimb/Airborne**: these branches set velocity directly (no grip blend). Their physics are specialized and should not have lateral momentum.
- **Speed magnitude**: the blend preserves speed magnitude during transitions. The speeder doesn't lose speed from turning — it just changes direction gradually instead of instantly.
- **Lean entry speed boost** (line 704-708): this adds velocity AFTER the grip blend, so the forward push overcomes grip naturally. Correct behavior.

### 5. VehicleServer.luau — Debug print update

**Modify the `[P5_SPEED]` print (currently in the debug block).**

Add lateral slide info:

Current:
```lua
			local debugTurnFraction = math.clamp(horizontalSpeed / math.max(1, state.config.maxSpeed), 0, 1)
			local debugTurnSpeed = state.config.turnSpeedLow + (state.config.turnSpeedHigh - state.config.turnSpeedLow) * debugTurnFraction
			print(string.format("[P5_SPEED] vehicleId=%s speed=%.1f turnRate=%.0f", state.vehicleId, horizontalSpeed, debugTurnSpeed))
```

New:
```lua
			local debugTurnFraction = math.clamp(horizontalSpeed / math.max(1, state.config.maxSpeed), 0, 1)
			local debugTurnSpeed = state.config.turnSpeedLow + (state.config.turnSpeedHigh - state.config.turnSpeedLow) * debugTurnFraction
			local lateralSpeed = 0
			if horizontalSpeed > 1 then
				local hVel = Vector3.new(state.velocity.X, 0, state.velocity.Z)
				local fwd = computeForwardDirection(state.heading)
				local fwdComponent = hVel:Dot(fwd)
				lateralSpeed = math.sqrt(math.max(0, horizontalSpeed * horizontalSpeed - fwdComponent * fwdComponent))
			end
			print(string.format("[P5_SPEED] vehicleId=%s speed=%.1f turnRate=%.0f slide=%.1f", state.vehicleId, horizontalSpeed, debugTurnSpeed, lateralSpeed))
```

`lateralSpeed` is the component of horizontal velocity perpendicular to the heading direction. When the speeder slides sideways during a turn, this value is positive. When perfectly aligned, it's 0. This lets us verify the grip system is working.

---

## What Does NOT Change

- **VehicleClient.luau** — no changes. The client sends `steerX` and `lean` as before.
- **VehicleCamera.luau** — no changes. The camera follows the heading attribute and model position. The lateral slide manifests as the model briefly moving in a different direction than it's pointing, which the camera captures naturally.
- **VehicleVisualSmoother.luau** — no changes. CFrame interpolation handles the sliding model.
- **CollisionHandler.luau** — no changes. Collision checks use `state.velocity` which now includes the lateral component. The angle-aware deflection (from the collision fix) handles this correctly.
- **HoverPhysics.luau** — no changes. Hover springs are position-based, not velocity-based.
- **CrestRelease / BlockedClimb / Airborne branches** — untouched. Lateral momentum only applies in NormalDrive ground driving.
- **computeTargetSpeed function** — unchanged. The taper is applied externally by modifying the acceleration parameter before the call.

---

## Data Flow Summary

```
ACCELERATION TAPER (NormalDrive ground only):
  accelTaperFraction = currentDriveSpeed / climbSpeedCap  (0 at standstill, 1 at cap)
  accelMultiplier = max(0.3, 1 - fraction * 0.7)
  effectiveAccel = 80 * multiplier
  → Passed to computeTargetSpeed instead of raw acceleration
  → 80 at standstill, 52 at half speed, 24 at max speed

LATERAL MOMENTUM (NormalDrive ground only):
  desiredHorizontal = driveDirection * targetSpeed  (heading-aligned)
  currentHorizontal = current velocity X/Z  (may be misaligned after turn)
  gripRate = lerp(14, 7, speedFraction)
  gripAlpha = 1 - exp(-gripRate * dt)
  blendedHorizontal = current.Lerp(desired, gripAlpha)
  → At low speed: near-instant realignment (14 rate)
  → At high speed: ~0.22s to 80% alignment (7 rate)
  → Lateral slide visible as heading ≠ velocity direction
```

---

## Test Packet

### AI Build Prints

The `[P5_SPEED]` print is updated with `slide` value (see change 5).

### Pass/Fail Conditions

**Test 1 — Lateral slide on sharp turn at speed:**
- Setup: Drive straight at ~100 studs/s
- Action: Turn sharply with full mouse right
- PASS if: `[P5_SPEED] slide` shows a non-zero value (> 5) briefly during the turn, then settles back toward 0 as the grip catches up. Visually, the speeder's heading rotates before the movement direction follows.
- FAIL if: `slide` stays at 0 during turns (no lateral momentum), or slide persists indefinitely (no grip)

**Test 2 — Minimal slide at low speed:**
- Setup: Drive at ~15 studs/s
- Action: Turn sharply
- PASS if: `[P5_SPEED] slide` stays very small (< 3). Turn feels responsive with barely any perceptible slide.
- FAIL if: significant sliding at low speed (grip too loose)

**Test 3 — Acceleration punch off the line:**
- Setup: Vehicle stationary, no input
- Action: Hold W (throttle)
- PASS if: speeder accelerates strongly in the first second, then acceleration visibly tapers as speed increases. Speed increases rapidly at first, then the rate of increase slows noticeably above ~80 studs/s.
- FAIL if: acceleration feels constant from 0 to max speed (no taper)

**Test 4 — Top speed still reachable:**
- Setup: Hold W on flat terrain for 5+ seconds
- Action: Wait for speed to stabilize
- PASS if: `[P5_SPEED]` eventually shows speed at or very near 120 studs/s (max speed is still reachable, just slower to get there)
- FAIL if: speed plateaus significantly below max (taper too aggressive, or accelerationMinFactor preventing approach)

**Test 5 — Deceleration unchanged:**
- Setup: Drive at max speed
- Action: Release W (coast)
- PASS if: deceleration feels the same as before (30 studs/s², consistent rate). Speed drops linearly, not tapered.
- FAIL if: deceleration feels different or tapered

**Test 6 — Slide resolves during straight driving:**
- Setup: After a sharp turn at speed, straighten out (center mouse)
- Action: Drive straight for 1-2 seconds
- PASS if: `[P5_SPEED] slide` drops to ~0 within 0.5 seconds of straightening. No persistent drift.
- FAIL if: slide value persists after straightening out

**Test 7 — Physics stability during slide:**
- Setup: Drive at max speed, make several sharp turns in sequence
- Action: S-curve pattern (left-right-left)
- PASS if: speeder handles direction changes smoothly, no jitter, no sudden speed loss, no terrain clipping
- FAIL if: oscillation, speed spikes, or collision artifacts during rapid direction changes

### MCP Procedure

Default procedure. No deviations.

### Expected Summary Format

```
[P5_SPEED] vehicleId=<id> speed=<studs/s> turnRate=<deg/s> slide=<studs/s>
```
