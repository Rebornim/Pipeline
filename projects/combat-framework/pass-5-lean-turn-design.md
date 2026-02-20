# Pass 5 Polish: Lean Turn (A/D Aggressive Cornering)

Date: 2026-02-20
Type: Pass 5 polish addition
Scope: Input, server movement, visual banking. No structural changes.

---

## Overview

A/D keys add a "lean turn" — the speeder banks into the turn and gets a tighter cornering radius. This is additive to mouse steering. Not drifting (no traction loss). Visually, the model rolls toward the turn direction proportional to speed and lean input.

---

## File Changes

### 1. CombatTypes.luau

**VehicleInputPayload** — add `lean` field:
```
export type VehicleInputPayload = {
    throttle: number,
    steerX: number,
    lean: number,
}
```

**VehicleRuntimeState** — add `inputLean` field:
```
inputLean: number,
```

### 2. CombatConfig.luau — VehicleConfig type + light_speeder values

**VehicleConfig type** — add 3 fields to the type in CombatTypes.luau:
```
leanTurnRate: number,
leanBankAngle: number,
leanSpeedPenalty: number,
```

**light_speeder config** — add values:
```
leanTurnRate = 75,        -- degrees/sec of additional turn from A/D lean
leanBankAngle = 22,       -- max visual roll in degrees at full speed
leanSpeedPenalty = 0.06,  -- 6% max speed reduction while leaning
```

Tuning notes:
- `leanTurnRate = 75`: combined with mouse steer (120 deg/s max), total peak turn is ~195 deg/s. Lean alone at 75 deg/s feels meaningful without being overpowered.
- `leanBankAngle = 22`: enough to read clearly, not so extreme it looks broken. Endor speeder bikes bank roughly this much.
- `leanSpeedPenalty = 0.06`: gentle — you feel the trade-off but it doesn't punish you. Tweak in config later.

### 3. VehicleClient.luau — readInputPayload()

**Modify `readInputPayload` (line 75-97)** to capture A/D:

After the throttle block (line 76-81), add:
```lua
local lean = 0
if UserInputService:IsKeyDown(Enum.KeyCode.A) then
    lean = -1
elseif UserInputService:IsKeyDown(Enum.KeyCode.D) then
    lean = 1
end
```

If both A and D are held, lean = 0 (cancel out). Update the check:
```lua
local lean = 0
local aDown = UserInputService:IsKeyDown(Enum.KeyCode.A)
local dDown = UserInputService:IsKeyDown(Enum.KeyCode.D)
if aDown and not dDown then
    lean = -1
elseif dDown and not aDown then
    lean = 1
end
```

Update the return payload (line 93-96):
```lua
return {
    throttle = throttle,
    steerX = steerX,
    lean = lean,
}
```

### 4. VehicleServer.luau — Input handler

**Modify input handler (line 964-981)** to validate and store lean:

After the throttle/steerX validation (line 971-972), add lean validation:
```lua
local lean = payload.lean
if type(lean) ~= "number" then
    lean = 0
end
```

After `state.inputSteerX = ...` (line 981), add:
```lua
state.inputLean = math.clamp(math.round(lean), -1, 1)
```

### 5. VehicleServer.luau — registerVehicle

**Modify initial state table (line 918-942)** to include `inputLean` and `currentBankAngle`:

Add to the state table:
```lua
inputLean = 0,
currentBankAngle = 0,
```

Also add `currentBankAngle: number` to the `VehicleRuntimeStateInternal` type (line 22-30).

### 6. VehicleServer.luau — clearDriver

**Modify clearDriver (line 128-136)** to also zero lean:

After `state.inputSteerX = 0` (line 135), add:
```lua
state.inputLean = 0
```

### 7. VehicleServer.luau — stepSingleVehicle: heading computation

**Modify heading delta (line 466-468).**

Current:
```lua
local steerScale = if canUseGroundDrive then 1 else 0.55
local headingDelta = math.rad(state.inputSteerX * state.config.turnSpeed * steerScale) * dt
state.heading -= headingDelta
```

New:
```lua
local steerScale = if canUseGroundDrive then 1 else 0.55
local mouseSteerDelta = math.rad(state.inputSteerX * state.config.turnSpeed * steerScale) * dt
local leanSteerDelta = math.rad(state.inputLean * state.config.leanTurnRate * steerScale) * dt
state.heading -= (mouseSteerDelta + leanSteerDelta)
```

Lean turn uses the same `steerScale` (reduced in air). Lean direction: -1 (A) = turn left, +1 (D) = turn right, matching the heading sign convention.

### 8. VehicleServer.luau — stepSingleVehicle: speed penalty

**Modify the NormalDrive ground speed computation (around line 600-626).**

When lean is active, reduce the effective max forward speed. In the NormalDrive ground branch, after computing `climbSpeedCap` (line 612), apply lean penalty:

```lua
if state.inputLean ~= 0 then
    climbSpeedCap = climbSpeedCap * (1 - state.config.leanSpeedPenalty)
end
```

This reduces the speed cap by the penalty fraction when leaning. Speed naturally decelerates toward the lower cap. When lean is released, the cap returns to normal and the vehicle accelerates back.

### 9. VehicleServer.luau — stepSingleVehicle: visual banking

**Modify CFrame construction (line 740-760).**

After computing `smoothedUp` (line 746) and before computing `alignedForward` (line 751), add bank angle computation and application:

```lua
-- Lean banking: roll the up vector toward the turn direction
local horizontalSpeed = Vector3.new(state.velocity.X, 0, state.velocity.Z).Magnitude
local speedFraction = math.clamp(horizontalSpeed / math.max(1, state.config.maxSpeed), 0, 1)
local targetBankAngle = state.inputLean * math.rad(state.config.leanBankAngle) * speedFraction
-- Smooth the bank angle to avoid snap-in/snap-out
local bankLerp = math.clamp(12 * dt, 0, 1)
state.currentBankAngle += (targetBankAngle - state.currentBankAngle) * bankLerp
-- Apply roll: rotate smoothedUp around the forward axis
if math.abs(state.currentBankAngle) > 0.001 then
    local bodyForwardForBank = computeForwardDirection(state.heading - state.attachmentYawOffset)
    smoothedUp = CFrame.fromAxisAngle(bodyForwardForBank, state.currentBankAngle):VectorToWorldSpace(smoothedUp)
    if smoothedUp.Magnitude <= 1e-4 then
        smoothedUp = Vector3.yAxis
    else
        smoothedUp = smoothedUp.Unit
    end
end
```

Bank angle is:
- Proportional to lean input direction (-1 / 0 / +1)
- Proportional to speed (no bank at standstill, full bank at max speed)
- Smoothed with exponential lerp (stiffness 12, same ballpark as tilt lerp)
- Applied as a rotation of the up vector around the forward axis

The rest of the CFrame construction (`alignedForward`, `CFrame.lookAt`) proceeds unchanged — it naturally produces the banked orientation.

### 10. VehicleServer.luau — updateDriverFromSeat

**Modify updateDriverFromSeat (around line 153)** to also zero lean on enter:

After `state.inputSteerX = 0` (line 152), add:
```lua
state.inputLean = 0
```

---

## What Does NOT Change

- **HoverPhysics.luau** — no changes. Hover springs are unaffected by lean.
- **CollisionHandler.luau** — no changes. Collision rays use forward direction from heading, which already includes lean turn.
- **VehicleCamera.luau** — no changes. Camera tracks heading attribute and model position. The banked vehicle model rotates beneath a stable camera. This is the correct Star Wars speeder look.
- **VehicleVisualSmoother.luau** — no changes. The smoother interpolates CFrame snapshots from the server. The bank is in the CFrame, so it interpolates naturally.

---

## Data Flow Summary

```
Client: A/D keys → lean (-1/0/1) → VehicleInputPayload.lean → RemoteEvent
Server: validate lean → state.inputLean → stepSingleVehicle:
  1. Heading delta += lean * leanTurnRate * steerScale * dt
  2. Speed cap *= (1 - leanSpeedPenalty) when lean != 0
  3. Bank angle smoothed toward lean * bankAngle * speedFraction
  4. smoothedUp rotated by bank angle around forward axis
  5. CFrame.lookAt uses banked up vector → banked model
Visual: smoother interpolates banked CFrame → player sees smooth lean
Camera: stays level, tracks heading → stable camera with banked speeder beneath
```

---

## Test Packet

### AI Build Prints

Add to `stepSingleVehicle`, inside the existing periodic debug block (lines 787-807, the `debugPrintAccumulator >= 0.5` section):

```lua
print(string.format("[P5_LEAN] vehicleId=%s lean=%d bank=%.1f",
    state.vehicleId, state.inputLean, math.deg(state.currentBankAngle)))
```

### Pass/Fail Conditions

**Test 1 — Lean turns the vehicle:**
- Setup: Drive forward at speed (W held)
- Action: Hold D
- PASS if: heading changes rightward (VehicleHeading attribute decreases over 1 second) AND `[P5_LEAN] lean=1` appears in output
- FAIL if: heading does not change, or lean=0 when D is held

**Test 2 — Visual banking:**
- Setup: Drive forward at speed
- Action: Hold A
- PASS if: `[P5_LEAN] bank` shows negative value (between -15 and -25 degrees at high speed)
- FAIL if: bank stays at 0 when lean is active and speed > 50

**Test 3 — No bank at standstill:**
- Setup: Vehicle stationary (no throttle)
- Action: Hold D
- PASS if: `[P5_LEAN] bank` stays near 0 (< 2 degrees)
- FAIL if: bank exceeds 5 degrees while speed is < 5

**Test 4 — Lean + mouse steer combined:**
- Setup: Drive forward, position mouse to right side of screen (steerX > 0.5)
- Action: Also hold D
- PASS if: turn rate is visibly faster than mouse-only or lean-only
- FAIL if: turn rate is identical to mouse-only steering

### MCP Procedure

Default procedure. No deviations.

### Expected Summary Format

No separate summary line needed — lean is polish within pass 5. The existing `[P5_SPEED]` and `[P5_HOVER]` prints plus the new `[P5_LEAN]` print are sufficient.
