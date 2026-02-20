# Pass 5 Polish: Lean Turn Feel (Entry Bite, Exit Settle, FOV)

Date: 2026-02-20
Type: Fix Plan — polish addition to existing lean turn system
Scope: Server movement feel (VehicleServer), client camera FOV (VehicleCamera), config/types. No structural changes.

---

## Root Cause

The lean turn works mechanically (heading change + visual bank) but feels flat. There's no weight transition on entry or exit — you press A/D and the turn just starts/stops linearly. The FOV push-in during lean is too subtle (4 degrees) to sell the speed-into-turn feel.

---

## Changes

### 1. CombatTypes.luau — VehicleConfig type additions

Add 5 fields to the `VehicleConfig` type (after `leanSpeedPenalty: number` on the current last lean field):

```
leanEntryDuration: number,
leanEntryYawBoost: number,
leanEntrySpeedBoost: number,
leanExitDuration: number,
leanExitCounterBankDeg: number,
```

### 2. CombatConfig.luau — light_speeder values

Add to the `light_speeder` config table, after `leanSpeedPenalty = 0.06`:

```lua
leanEntryDuration = 0.25,
leanEntryYawBoost = 0.35,
leanEntrySpeedBoost = 20,
leanExitDuration = 0.18,
leanExitCounterBankDeg = 3.5,
```

Tuning notes:
- `leanEntryDuration = 0.25`: quarter-second ramp-in. Short enough to feel immediate, long enough to not be a snap.
- `leanEntryYawBoost = 0.35`: 35% extra turn rate at entry peak, fading to 0% over the duration. Makes the turn "bite" harder initially.
- `leanEntrySpeedBoost = 20`: studs/s^2 of forward push during entry, decaying over the duration. Total velocity gain ~2.5 studs/s — perceptible as a brief surge, not enough to destabilize.
- `leanExitDuration = 0.18`: slightly shorter than entry. The settle should be quick.
- `leanExitCounterBankDeg = 3.5`: degrees of counter-bank overshoot. The bike briefly rocks past level to the opposite side before settling. At `LEAN_VISUAL_YAW_RATIO = 1.0`, this also produces ~3.5 degrees of visual counter-yaw through the existing yaw coupling (line 798).

### 3. VehicleCamera.luau — FOV push-in

**Constant change (line 19):**

Current: `local LEAN_FOV_PUSH_IN = 4`
New: `local LEAN_FOV_PUSH_IN = 8`

**FOV computation change (lines 260-268).**

Current:
```lua
local targetLeanMagnitude = math.abs(activeLeanInput)
local leanAlpha = if targetLeanMagnitude > smoothedLeanMagnitude
    then computeAlpha(6.5, clampedDt)
    else computeAlpha(9.5, clampedDt)
smoothedLeanMagnitude += (targetLeanMagnitude - smoothedLeanMagnitude) * leanAlpha

local baseFieldOfView = savedFieldOfView or camera.FieldOfView
local targetFieldOfView = baseFieldOfView - (LEAN_FOV_PUSH_IN * smoothedLeanMagnitude)
camera.FieldOfView += (targetFieldOfView - camera.FieldOfView) * computeAlpha(8.5, clampedDt)
```

New:
```lua
local targetLeanMagnitude = math.abs(activeLeanInput)
local leanAlpha = if targetLeanMagnitude > smoothedLeanMagnitude
    then computeAlpha(6.5, clampedDt)
    else computeAlpha(9.5, clampedDt)
smoothedLeanMagnitude += (targetLeanMagnitude - smoothedLeanMagnitude) * leanAlpha

local leanFovSpeedScale = math.max(0.3, speedFactor)
local baseFieldOfView = savedFieldOfView or camera.FieldOfView
local targetFieldOfView = baseFieldOfView - (LEAN_FOV_PUSH_IN * smoothedLeanMagnitude * leanFovSpeedScale)
camera.FieldOfView += (targetFieldOfView - camera.FieldOfView) * computeAlpha(8.5, clampedDt)
```

Key: multiply the push-in by `leanFovSpeedScale = math.max(0.3, speedFactor)`. `speedFactor` is already computed on line 145 of VehicleCamera.luau. This gives:
- At standstill: `8 * 1.0 * 0.3 = 2.4` degrees (subtle)
- At half speed: `8 * 1.0 * 0.5 = 4.0` degrees (same as old constant)
- At max speed: `8 * 1.0 * 1.0 = 8.0` degrees (double old value — punchy)

The existing `smoothedLeanMagnitude` lerp (alpha 6.5 ramp-up, 9.5 ramp-down) prevents spam. Rapidly tapping A/D won't cause FOV oscillation because the smoothed value can't track fast inputs.

The `savedFieldOfView` baseline (captured once on `activate`, line 289) ensures the FOV always restores to the exact pre-vehicle value. No drift.

### 4. VehicleServer.luau — State additions

**VehicleRuntimeStateInternal type (lines 22-32)** — add 4 fields:

```
leanEntryTimer: number,
leanExitTimer: number,
leanExitSign: number,
prevInputLean: number,
```

**registerVehicle state table (lines 971-998)** — add initial values:

```lua
leanEntryTimer = 0,
leanExitTimer = 0,
leanExitSign = 0,
prevInputLean = 0,
```

### 5. VehicleServer.luau — stepSingleVehicle: transition detection + entry yaw boost

**Insert AFTER line 486 (after `mouseSteerDelta` computation, BEFORE the `leanSteerDelta` computation on line 489).**

Detect lean transitions and compute fractions:
```lua
-- Lean transition detection
local leanJustStarted = (state.prevInputLean == 0 and state.inputLean ~= 0)
local leanJustEnded = (state.prevInputLean ~= 0 and state.inputLean == 0)
if leanJustStarted then
    state.leanEntryTimer = state.config.leanEntryDuration
    state.leanExitTimer = 0
end
if leanJustEnded then
    state.leanExitTimer = state.config.leanExitDuration
    state.leanExitSign = -math.sign(state.prevInputLean)
    state.leanEntryTimer = 0
end
local entryFraction = math.clamp(state.leanEntryTimer / math.max(0.001, state.config.leanEntryDuration), 0, 1)
local exitFraction = math.clamp(state.leanExitTimer / math.max(0.001, state.config.leanExitDuration), 0, 1)
```

**Modify line 489 (leanSteerDelta computation).**

Current:
```lua
local leanSteerDelta = math.rad(state.inputLean * state.config.leanTurnRate * steerScale * leanSpeedFraction) * dt
```

New:
```lua
local leanEntryMult = 1 + state.config.leanEntryYawBoost * entryFraction
local leanSteerDelta = math.rad(state.inputLean * state.config.leanTurnRate * steerScale * leanSpeedFraction * leanEntryMult) * dt
```

This multiplies the lean turn rate by `(1 + 0.35)` at the start of a lean, decaying to `1.0` over 0.25 seconds. The turn "bites" harder initially.

### 6. VehicleServer.luau — stepSingleVehicle: entry speed boost

**Insert AFTER line 678 (end of the velocity computation branches, BEFORE line 681 `state.velocity += Vector3.new(0, verticalAccel * dt, 0)`).**

```lua
-- Entry speed boost (forward push on lean initiation)
if state.leanEntryTimer > 0 and canUseGroundDrive and horizontalSpeed > 5 then
    local boost = state.config.leanEntrySpeedBoost * entryFraction * dt
    state.velocity += forwardDirection * boost
end
```

Gates:
- `leanEntryTimer > 0`: only during entry ramp
- `canUseGroundDrive`: no boost in air
- `horizontalSpeed > 5`: no boost at standstill

`entryFraction` is already computed from step 5. `forwardDirection` is computed on line 492.

Physics safety: the boost decays from 20 to 0 studs/s^2 over 0.25s. Total velocity addition over the entry window ≈ 20 * 0.25 / 2 = 2.5 studs/s. At max speed 120, that's 2% — not enough to cause terrain clipping or collision issues. The boost happens BEFORE collision checks (line 711), so CollisionHandler catches any problems.

### 7. VehicleServer.luau — stepSingleVehicle: exit counter-bank

**Modify the bank angle computation (lines 793-797).**

Current:
```lua
local speedFraction = math.clamp(horizontalSpeed / math.max(1, state.config.maxSpeed), 0, 1)
local bankSpeedFraction = if state.inputLean ~= 0 then math.max(0.15, speedFraction) else speedFraction
local targetBankAngle = state.inputLean * math.rad(state.config.leanBankAngle) * bankSpeedFraction
local bankLerp = math.clamp(12 * dt, 0, 1)
state.currentBankAngle += (targetBankAngle - state.currentBankAngle) * bankLerp
```

New:
```lua
local speedFraction = math.clamp(horizontalSpeed / math.max(1, state.config.maxSpeed), 0, 1)
local bankSpeedFraction = if state.inputLean ~= 0 then math.max(0.15, speedFraction) else speedFraction
local targetBankAngle = state.inputLean * math.rad(state.config.leanBankAngle) * bankSpeedFraction
-- Exit counter-bank: overshoot past level in the opposite direction
if exitFraction > 0 then
    targetBankAngle += state.leanExitSign * math.rad(state.config.leanExitCounterBankDeg) * exitFraction
end
local bankLerp = math.clamp(12 * dt, 0, 1)
state.currentBankAngle += (targetBankAngle - state.currentBankAngle) * bankLerp
```

How it works:
- When lean releases, `state.inputLean = 0`, so `targetBankAngle` from the first line = 0.
- `leanExitSign` = `-sign(previousLean)`. If you were leaning right (lean=1), exitSign = -1.
- Counter-bank target = `-1 * 3.5deg * exitFraction`. This is negative = left lean.
- The bank overshoots past center to the opposite side, then `exitFraction` decays to 0 over 0.18s, and the bank settles back to 0.
- The existing visual yaw coupling (`LEAN_VISUAL_YAW_RATIO` on line 798) naturally produces a matching visual counter-yaw from this counter-bank. No separate heading change needed.

`exitFraction` is already computed from step 5.

Physics safety: the counter-bank is purely visual (applied via `CFrame.fromAxisAngle` on line 800). It does NOT modify heading, velocity, or any physics state. The `smoothedUp` unbanking on lines 768-771 ensures the counter-bank doesn't compound into terrain tilt.

### 8. VehicleServer.luau — stepSingleVehicle: timer updates + prevInputLean

**Insert AFTER line 805 (`state.lastVerticalSpeed = state.velocity.Y`), BEFORE the airborne transition prints (line 807).**

```lua
-- Lean polish timer updates
state.leanEntryTimer = math.max(0, state.leanEntryTimer - dt)
state.leanExitTimer = math.max(0, state.leanExitTimer - dt)
state.prevInputLean = state.inputLean
```

Timer decrement happens AFTER all uses of `entryFraction`/`exitFraction`, so the fractions are correct for the current frame.

### 9. VehicleServer.luau — debug print update

**Modify the existing `[P5_LEAN]` print (lines 844-851).**

Current:
```lua
print(
    string.format(
        "[P5_LEAN] vehicleId=%s lean=%d bank=%.1f",
        state.vehicleId,
        state.inputLean,
        math.deg(state.currentBankAngle)
    )
)
```

New:
```lua
print(
    string.format(
        "[P5_LEAN] vehicleId=%s lean=%d bank=%.1f entry=%.2f exit=%.2f",
        state.vehicleId,
        state.inputLean,
        math.deg(state.currentBankAngle),
        state.leanEntryTimer,
        state.leanExitTimer
    )
)
```

---

## What Does NOT Change

- **HoverPhysics.luau** — untouched. Entry speed boost is a velocity addition, not a hover parameter change.
- **CollisionHandler.luau** — untouched. It runs after the entry speed boost and catches any resulting issues.
- **VehicleVisualSmoother.luau** — untouched. Counter-bank flows through CFrame interpolation naturally.
- **VehicleClient.luau** — untouched. A/D input reading is unchanged. The camera calls `setLeanInput` as before.
- **Heading** — exit reaction does NOT change heading. Counter-yaw feel comes from the visual yaw coupling with counter-bank (line 798), which is purely cosmetic CFrame rotation.

---

## Data Flow Summary

```
ENTRY (A/D pressed while prevInputLean == 0):
  leanEntryTimer = 0.25 → decays to 0
  entryFraction = timer / duration (1.0 → 0.0)
  → leanSteerDelta *= (1 + 0.35 * entryFraction)    [extra yaw bite]
  → velocity += forwardDir * 20 * entryFraction * dt  [forward push]

EXIT (A/D released while prevInputLean != 0):
  leanExitTimer = 0.18 → decays to 0
  leanExitSign = -sign(prevLean)
  exitFraction = timer / duration (1.0 → 0.0)
  → targetBankAngle += exitSign * 3.5deg * exitFraction  [counter-bank overshoot]
  → visual yaw coupling produces matching counter-yaw feel

FOV (client-side, VehicleCamera):
  LEAN_FOV_PUSH_IN = 8 (was 4)
  push scaled by max(0.3, speedFactor)
  → 2.4deg at standstill, 4deg at half speed, 8deg at max speed
```

---

## Test Packet

### AI Build Prints

The existing `[P5_LEAN]` print is updated with `entry` and `exit` timer values (see change 9 above).

### Pass/Fail Conditions

**Test 1 — Entry bite yaw boost:**
- Setup: Drive forward at steady speed (~60+ studs/s), straight line
- Action: Press and hold A
- PASS if: `[P5_LEAN]` shows `entry > 0` in the first few prints after lean=−1 appears, AND the turn feels noticeably sharper in the first quarter-second than after it settles
- FAIL if: `entry` stays at 0, or the turn rate is constant from the moment A is pressed

**Test 2 — Entry speed boost:**
- Setup: Drive forward at ~80 studs/s (not max speed), straight line
- Action: Press and hold D
- PASS if: `[P5_SPEED]` shows a brief speed increase (1-3 studs/s above pre-lean speed) in the first 0.25 seconds, then speed settles to the lean-penalized cap
- FAIL if: speed immediately drops on lean entry with no brief surge

**Test 3 — Exit counter-bank:**
- Setup: Drive forward at speed, hold A for 1+ seconds
- Action: Release A
- PASS if: `[P5_LEAN]` shows `bank` briefly goes positive (opposite of the negative bank during left lean) in the prints immediately after `lean=0` appears, then bank settles back to ~0. `exit > 0` appears in those prints.
- FAIL if: bank goes directly to 0 without overshooting, or `exit` stays at 0

**Test 4 — No entry boost at standstill:**
- Setup: Vehicle stationary (speed < 5)
- Action: Press and hold D
- PASS if: `[P5_SPEED]` shows speed stays near 0 (no forward push)
- FAIL if: speed increases from standstill due to lean entry

**Test 5 — FOV push scales with speed:**
- This test is visual only (client-side, no server print). Verify by feel.
- Setup: Lean at low speed (~20 studs/s), note FOV change. Then lean at max speed (~120 studs/s), note FOV change.
- PASS if: FOV narrowing is noticeably stronger at max speed than at low speed
- FAIL if: FOV change feels identical at all speeds

### MCP Procedure

Default procedure. No deviations.

### Expected Summary Format

```
[P5_LEAN] vehicleId=<id> lean=<-1|0|1> bank=<degrees> entry=<timer> exit=<timer>
```
