# Pass 5 Polish: Lean Turn Effects (Camera Offset, Dust Kick, Entry Shake)

Date: 2026-02-20
Type: Fix Plan — visual effects addition to existing lean turn system
Scope: Client camera (VehicleCamera), client effects (VehicleClient), config/types. No server changes.
Depends on: pass-5-lean-polish-design.md (entry/exit/FOV) should be built first.

---

## Root Cause

The lean turn has mechanical feel (entry bite, exit settle, FOV) but lacks visual reinforcement. The camera stays rigidly centered during turns, there's no ground interaction feedback, and the weight transfer moment has no physical punctuation.

---

## Changes

### 1. CombatTypes.luau — VehicleConfig type additions

Add 4 fields to the `VehicleConfig` type (after the lean polish fields from pass-5-lean-polish-design.md):

```
leanCameraOffset: number,
leanShakeAmplitude: number,
leanShakeDuration: number,
leanDustEmitCount: number,
```

### 2. CombatConfig.luau — light_speeder values

Add to the `light_speeder` config table, after the lean polish values:

```lua
leanCameraOffset = 1.5,
leanShakeAmplitude = 0.12,
leanShakeDuration = 0.12,
leanDustEmitCount = 8,
```

Tuning notes:
- `leanCameraOffset = 1.5`: studs of lateral camera shift at max lean + max speed. Enough to reveal road into the turn, not enough to feel disorienting. Scales down with speed.
- `leanShakeAmplitude = 0.12`: very subtle — peak displacement ~0.05 studs. Sells the weight transfer without feeling jarring.
- `leanShakeDuration = 0.12`: one-tenth of a second. A quick bump, not sustained rumble.
- `leanDustEmitCount = 8`: particles per outer hover point. With 2 outer points, that's ~16 particles total per lean entry. Lightweight.

### 3. VehicleCamera.luau — Camera lateral offset

**New state variable (add near line 40, after `smoothedLeanMagnitude`):**

```lua
local smoothedLeanDirection = 0
```

**Reset in `activate` (after `smoothedLeanMagnitude = 0` on line 313):**

```lua
smoothedLeanDirection = 0
```

**Reset in `deactivate` (after `smoothedLeanMagnitude = 0` on line 350):**

```lua
smoothedLeanDirection = 0
```

**Compute smoothed lean direction in `stepCamera`, after the existing `smoothedLeanMagnitude` block (after line 264).**

Insert:
```lua
local leanDirAlpha = computeAlpha(6.5, clampedDt)
smoothedLeanDirection += (activeLeanInput - smoothedLeanDirection) * leanDirAlpha
```

This smooths the signed lean input (-1 to +1) at the same rate as the magnitude ramp-up. The smoothing prevents snap-in on rapid direction changes.

**Apply lateral offset to camera position and look-at target.**

The right vector can be derived from `smoothedForward` (already computed on line 148):
```lua
local cameraRight = smoothedForward:Cross(Vector3.yAxis)
```

`smoothedForward` is always a flat (Y=0) unit vector, so this cross product gives a clean horizontal right vector without normalization.

**Modify `desiredCameraPosition` (line 216).**

Current:
```lua
local desiredCameraPosition = focusPosition - smoothedForward * distance + Vector3.new(0, height, 0)
```

New:
```lua
local cameraRight = smoothedForward:Cross(Vector3.yAxis)
local lateralShift = smoothedLeanDirection * config.leanCameraOffset * math.max(0.2, speedFactor)
local desiredCameraPosition = focusPosition - smoothedForward * distance + Vector3.new(0, height, 0) + cameraRight * lateralShift
```

`lateralShift` is:
- Proportional to lean direction (positive = right, negative = left)
- Proportional to `leanCameraOffset` config value
- Scaled by speed: `math.max(0.2, speedFactor)` gives a floor of 20% at standstill, 100% at max speed. This prevents noticeable drift at low speed.

The offset is applied BEFORE the collision distance check (lines 224-242), so if the shifted camera would clip into geometry, the collision system handles it naturally.

**Also shift look-at target (line 220-222).**

Current:
```lua
local desiredLookAt = focusPosition
    + smoothedForward * lookAhead
    + Vector3.new(0, config.cameraHeight * 0.43 + uphill * 0.9 - downhill * 0.05, 0)
```

New:
```lua
local desiredLookAt = focusPosition
    + smoothedForward * lookAhead
    + Vector3.new(0, config.cameraHeight * 0.43 + uphill * 0.9 - downhill * 0.05, 0)
    + cameraRight * lateralShift * 0.5
```

Shifting the look-at point by half the camera offset makes the camera subtly angle into the turn rather than just translating. This reveals more of the road ahead in the turn direction — the core point of this feature.

### 4. VehicleCamera.luau — Entry camera shake

**New state variables (add near line 40, after the lean state):**

```lua
local vehicleShakeAmplitude = 0
local vehicleShakeDecayRate = 0
local vehicleShakePhase = 0
```

**New public function (add after `setLeanInput` on line 278):**

```lua
function VehicleCamera.pushShake(amplitude: number, duration: number): ()
    vehicleShakeAmplitude = math.max(vehicleShakeAmplitude, amplitude)
    vehicleShakeDecayRate = amplitude / math.max(0.01, duration)
    vehicleShakePhase = 0
end
```

`math.max` on amplitude means overlapping shakes don't stack — the stronger one wins. The decay rate is linear: `amplitude / duration` means it reaches 0 exactly when the duration expires.

**Reset in `activate` (after the lean resets):**

```lua
vehicleShakeAmplitude = 0
vehicleShakeDecayRate = 0
vehicleShakePhase = 0
```

**Reset in `deactivate` (after the lean resets):**

```lua
vehicleShakeAmplitude = 0
vehicleShakeDecayRate = 0
vehicleShakePhase = 0
```

**Apply shake in `stepCamera`, AFTER the `cameraPosition` lerp (after line 250), BEFORE the `lookAtPosition` lerp (line 252).**

Insert:
```lua
-- Vehicle camera shake (lean entry)
vehicleShakePhase += clampedDt
vehicleShakeAmplitude = math.max(0, vehicleShakeAmplitude - vehicleShakeDecayRate * clampedDt)
if vehicleShakeAmplitude > 0.001 then
    local shakeRight = smoothedForward:Cross(Vector3.yAxis)
    local shakeX = math.sin(vehicleShakePhase * 28) * vehicleShakeAmplitude * 0.4
    local shakeY = math.sin(vehicleShakePhase * 35 + 1.3) * vehicleShakeAmplitude * 0.25
    cameraPosition += shakeRight * shakeX + Vector3.yAxis * shakeY
end
```

The shake uses two sine waves at different frequencies (28 Hz and 35 Hz) to avoid repetitive patterns. X is lateral, Y is vertical. The 0.4/0.25 multipliers make it wider than tall (feels like a lateral jolt, matching the weight transfer direction).

At `amplitude = 0.12`: peak X displacement = 0.048 studs, peak Y = 0.03 studs. Very subtle — you feel it more than you see it.

The shake is applied AFTER the camera position lerp (so it doesn't get smoothed away) and BEFORE the look-at position computation (so the camera shakes but the look-at stays stable, creating a natural head-bobble feel).

### 5. VehicleClient.luau — Lean transition detection + effect triggers

**New state variables (add near line 40, after `inputAccumulator`):**

```lua
local previousClientLean = 0
local hoverDustEmitters: { { part: BasePart, emitter: ParticleEmitter } } = {}
```

**New function: `setupHoverDustEmitters` (add before `enterVehicleMode`).**

```lua
local function setupHoverDustEmitters(renderModel: Model)
    hoverDustEmitters = {}
    for _, descendant in ipairs(renderModel:GetDescendants()) do
        if descendant:IsA("BasePart") and CollectionService:HasTag(descendant, "HoverPoint") then
            local emitter = Instance.new("ParticleEmitter")
            emitter.Color = ColorSequence.new(Color3.fromRGB(180, 160, 130))
            emitter.Transparency = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 0.3),
                NumberSequenceKeypoint.new(0.5, 0.55),
                NumberSequenceKeypoint.new(1, 1),
            })
            emitter.Size = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 0.3),
                NumberSequenceKeypoint.new(0.4, 0.8),
                NumberSequenceKeypoint.new(1, 0.4),
            })
            emitter.Lifetime = NumberRange.new(0.3, 0.7)
            emitter.Speed = NumberRange.new(6, 14)
            emitter.SpreadAngle = Vector2.new(35, 35)
            emitter.Drag = 5
            emitter.Rate = 0
            emitter.EmissionDirection = Enum.NormalId.Top
            emitter.LightEmission = 0.15
            emitter.Parent = descendant
            table.insert(hoverDustEmitters, { part = descendant, emitter = emitter })
        end
    end
end
```

Emitters are created once during `enterVehicleMode` and attached to the render model's hover point parts. `Rate = 0` means they don't emit continuously — only on `:Emit(N)` calls. They are destroyed automatically when `VehicleVisualSmoother.deactivate()` destroys the render model clone.

Particle properties:
- Warm tan color (generic dust tone)
- Fade from semi-transparent to fully transparent
- Grow then shrink (puff shape)
- Short lifetime (0.3-0.7s)
- Fast initial speed with wide spread, high drag
- Emit upward from hover point (away from ground)

**New function: `fireDustKick` (add after `setupHoverDustEmitters`).**

```lua
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
```

The function determines "outer" hover points by checking their local X position relative to the model's pivot. When leaning right, the left-side hover points (negative local X) are on the outside of the turn — these are the ones digging into the surface harder, so they kick up dust.

The 0.3-stud threshold avoids triggering on center-line hover points (if any exist).

**Modify `enterVehicleMode` (line 141) — add dust emitter setup.**

After `activeVehicleRenderModel = VehicleVisualSmoother.activate(vehicleModel)` (line 152), insert:
```lua
setupHoverDustEmitters(activeVehicleRenderModel)
```

**Modify `exitVehicleMode` (line 121) — clear dust state.**

After `inputAccumulator = 0` (line 138), add:
```lua
previousClientLean = 0
hoverDustEmitters = {}
```

Note: the emitters themselves are destroyed when the render model is destroyed by `VehicleVisualSmoother.deactivate()` (line 128). We just clear the reference table.

**Modify the RenderStepped callback in `enterVehicleMode` (line 155-182) — add lean transition detection.**

After `VehicleCamera.setLeanInput(payload.lean)` (line 168), before `inputAccumulator += dt` (line 170), insert:

```lua
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
```

The speed gate (`> 15 studs/s`) prevents effects at low speeds where there's no meaningful ground interaction. Effects only fire on the lean ENTRY transition (0 → ±1), not during sustained lean or on exit.

---

## What Does NOT Change

- **VehicleServer.luau** — no changes. All three features are client-side visual effects.
- **HoverPhysics.luau** — no changes. Dust is visual only.
- **CollisionHandler.luau** — no changes.
- **VehicleVisualSmoother.luau** — no changes. It already clones hover point parts; the dust emitters are attached after cloning.

---

## Data Flow Summary

```
CAMERA LATERAL OFFSET:
  activeLeanInput → smoothedLeanDirection (signed, smoothed at alpha 6.5)
  lateralShift = smoothedLeanDirection * config.leanCameraOffset * max(0.2, speedFactor)
  → desiredCameraPosition += cameraRight * lateralShift
  → desiredLookAt += cameraRight * lateralShift * 0.5
  Result: camera slides into turns, look-at point follows at half rate

ENTRY CAMERA SHAKE:
  VehicleClient detects lean start (prevLean=0 → lean≠0, speed > 15)
  → calls VehicleCamera.pushShake(0.12, 0.12)
  → vehicleShakeAmplitude decays linearly over 0.12s
  → sinusoidal X/Y offsets applied to cameraPosition after lerp
  Result: brief lateral jolt on lean entry

HOVER DUST KICK:
  VehicleClient detects lean start (same trigger as shake)
  → calls fireDustKick(leanDirection, 8)
  → finds outer hover points (opposite side of lean direction)
  → emitter:Emit(8) on each outer hover point
  → particles: tan dust puffs, 0.3-0.7s lifetime, fast initial speed + drag
  Result: brief dust burst from outer hover points on lean entry
```

---

## Test Packet

### AI Build Prints

No new prints needed. These effects are visual-only (client-side particles, camera offsets). The existing `[P5_LEAN]` print from the base lean system is sufficient for verifying lean state.

### Pass/Fail Conditions

**Test 1 — Camera lateral offset:**
- Setup: Drive forward at high speed (~80+ studs/s)
- Action: Hold D (lean right)
- PASS if: camera visibly shifts to the right, revealing more of the road in the turn direction. Camera returns to center on D release.
- FAIL if: camera stays dead-center during lean, or shifts in the wrong direction (away from turn)

**Test 2 — Camera offset scales with speed:**
- Setup: Drive forward at low speed (~20 studs/s)
- Action: Hold A
- Compare: repeat at high speed (~100 studs/s)
- PASS if: lateral shift is noticeably larger at high speed than at low speed
- FAIL if: shift is identical at all speeds

**Test 3 — Entry camera shake:**
- Setup: Drive forward at speed (~60+ studs/s)
- Action: Press A quickly
- PASS if: brief camera jolt visible on lean entry (very subtle, lateral-feeling). Should last less than 0.15 seconds.
- FAIL if: no visible shake on lean entry, or shake is sustained/excessive

**Test 4 — Hover dust kick:**
- Setup: Drive forward at speed (~60+ studs/s)
- Action: Press D
- PASS if: brief dust particles emit from the LEFT-side hover points (outer side of a right lean turn). Particles shoot upward, slow down, fade out within ~0.7s.
- FAIL if: no particles visible, particles emit from wrong side, or particles persist/loop

**Test 5 — No effects at standstill:**
- Setup: Vehicle stationary (speed < 15)
- Action: Press A
- PASS if: no camera shake and no dust particles
- FAIL if: shake or dust fires at standstill

**Test 6 — Rapid tap stability:**
- Setup: Drive forward at speed
- Action: Rapidly tap A-D-A-D (4-5 times in 2 seconds)
- PASS if: camera offset smoothly follows without snapping, dust fires on each entry transition, no error spam
- FAIL if: camera snaps between positions, particles accumulate excessively, or errors in output

### MCP Procedure

Default procedure. No deviations. Tests 1-6 are visual — evaluated by user during playtest, not MCP automation.

### Expected Summary Format

No new print tags. Existing `[P5_LEAN]` covers state verification. Visual effects verified by user.
