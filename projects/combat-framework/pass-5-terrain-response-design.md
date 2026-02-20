# Pass 5 Polish: Terrain Response (Rotational Inertia + Landing Camera Shake)

Date: 2026-02-20
Type: Design — physics feel, Step 3 of 3
Scope: VehicleServer.luau (tilt spring-damper), VehicleClient.luau (landing shake trigger), CombatConfig, CombatTypes.

---

## Overview

Two changes that make the speeder feel like a heavy object reacting to terrain:

1. **Rotational inertia (spring-damper tilt)**: Replace the current first-order lerp (smooth approach, never overshoots) with a second-order spring-damper system (resist → yield → overshoot slightly → settle). When the speeder hits a bump, its body resists the rotation, then slowly corrects, overshoots a few percent past level, and settles. The "heavy bobblehead" effect — subtle but alive.

2. **Landing camera shake**: When the speeder lands hard, the camera shakes briefly proportional to impact speed. The hover springs already handle the physical squat-and-bounce — this adds the camera feedback that sells the impact.

---

## File Changes

### 1. CombatTypes.luau — VehicleConfig type additions

Add 4 fields (after `leanDustEmitCount` or after the lateral grip fields):

```
tiltStiffness: number,
tiltDamping: number,
landingShakeThreshold: number,
landingShakeIntensity: number,
```

### 2. CombatConfig.luau — light_speeder values

Add to the `light_speeder` config table (after the lateral grip / acceleration taper values, before `hoverHeight`):

```lua
tiltStiffness = 100,
tiltDamping = 14,
landingShakeThreshold = 25,
landingShakeIntensity = 0.35,
```

Tuning notes:
- `tiltStiffness = 100`: spring force pulling the body toward the terrain normal. Higher = faster response, snappier corrections. Natural frequency = sqrt(100) = 10 rad/s.
- `tiltDamping = 14`: resistance to angular velocity change. Damping ratio = 14 / (2 * sqrt(100)) = 0.7 — slightly underdamped, which means ~4.6% overshoot on step changes. This is the bobble: the speeder tilts past the target angle by a few degrees, then settles back.
- `landingShakeThreshold = 25`: minimum vertical impact speed (studs/s) for camera shake. Small hops and crest landings don't shake. Noticeable drops do. For reference, fall damage starts at 80 studs/s, so shake triggers well before damage.
- `landingShakeIntensity = 0.35`: maximum shake amplitude at fall-damage-threshold speed. For comparison, lean entry shake uses amplitude 0.2. A hard landing shakes harder than leaning in.

Spring-damper tuning reference:
| Damping ratio | Overshoot | Feel |
|--------------|-----------|------|
| 1.0 (critical) | 0% | Current behavior — smooth approach, no bobble |
| 0.8 | ~1.5% | Very subtle, barely perceptible |
| **0.7** | **~4.6%** | **Chosen — visible bobble, settles quickly** |
| 0.6 | ~9.5% | Noticeable wobble, borderline floaty |
| 0.5 | ~16% | Excessive, looks broken |

To adjust feel via config:
- More bobble: lower `tiltDamping` (e.g., 12 → ratio 0.6)
- Less bobble: raise `tiltDamping` (e.g., 16 → ratio 0.8)
- Faster response: raise `tiltStiffness` (e.g., 150)
- Slower response: lower `tiltStiffness` (e.g., 60)

Landing shake at key impact speeds:
| Impact speed | Shake amplitude | Feel |
|-------------|----------------|------|
| 25 studs/s (threshold) | 0 | No shake — small hop |
| 40 studs/s | 0.10 | Subtle rumble |
| 55 studs/s | 0.19 | Moderate — you feel the hit |
| 70 studs/s | 0.29 | Heavy impact |
| 80 studs/s (damage threshold) | 0.35 | Maximum — serious crash |

### 3. VehicleServer.luau — VehicleRuntimeStateInternal type

Add one field (after `prevInputLean`):

```lua
tiltAngularVelocity: Vector3,
```

### 4. VehicleServer.luau — registerVehicle initialization

Add to the state initializer (after `prevInputLean = 0`):

```lua
tiltAngularVelocity = Vector3.zero,
```

### 5. VehicleServer.luau — Spring-damper tilt (replaces lerp)

**Replace the tilt smoothing block (lines 802-808).**

Current:
```lua
	local tiltLerp = math.clamp(readConfigNumber("VehicleMaxTiltLerp", 8.0) * dt, 0, 1)
	local smoothedUp = currentUp:Lerp(averageNormal, tiltLerp)
	if smoothedUp.Magnitude <= 1e-4 then
		smoothedUp = Vector3.yAxis
	else
		smoothedUp = smoothedUp.Unit
	end
```

New:
```lua
	-- Spring-damper tilt: rotational inertia with overshoot-and-settle
	local tiltError = averageNormal - currentUp
	local springForce = tiltError * state.config.tiltStiffness
	local dampingForce = -state.tiltAngularVelocity * state.config.tiltDamping
	state.tiltAngularVelocity += (springForce + dampingForce) * dt
	-- Clamp angular velocity to prevent explosions on teleport or extreme cases
	local maxAngularSpeed = 15
	if state.tiltAngularVelocity.Magnitude > maxAngularSpeed then
		state.tiltAngularVelocity = state.tiltAngularVelocity.Unit * maxAngularSpeed
	end
	local smoothedUp = currentUp + state.tiltAngularVelocity * dt
	if smoothedUp.Magnitude <= 1e-4 then
		smoothedUp = Vector3.yAxis
	else
		smoothedUp = smoothedUp.Unit
	end
```

How the spring-damper works:
- `tiltError`: the difference between where the terrain wants the body to point and where it currently points. On flat ground this is near zero. When a bump changes the terrain normal, this spikes.
- `springForce`: pulls the body toward the terrain normal. Proportional to error — big bumps pull harder.
- `dampingForce`: resists changes in angular velocity. This is the "mass" — it slows down rotation, creating the inertia feel.
- `tiltAngularVelocity`: tracked between frames. This is what creates overshoot — the body builds up rotational momentum, overshoots the target, and the spring pulls it back. With damping ratio 0.7, the overshoot is ~4.6% and settles in ~0.6s.

The `maxAngularSpeed = 15` clamp is a safety rail. At normal operation, angular velocity stays well below this. It only activates if something weird happens (teleport, massive terrain discontinuity) to prevent the body from spinning wildly.

**What this replaces:**
The old `currentUp:Lerp(averageNormal, tiltLerp)` was a first-order exponential approach — it always moved toward the target, never past it. That's overdamped behavior. The spring-damper is second-order — it can overshoot, creating the bobblehead self-correction effect.

**What `VehicleMaxTiltLerp` becomes:**
The global config constant `VehicleMaxTiltLerp` (default 8.0) is no longer used for tilt. It can be left in `CombatConfig` without harm (nothing else reads it), or removed. The spring-damper's response speed is controlled entirely by `tiltStiffness` and `tiltDamping` in the per-vehicle config.

### 6. VehicleServer.luau — Landing impact attribute for client

**Modify the landing detection block (lines 719-738).**

After the existing fall damage block (after line 738, still inside the `if previousAirborne and hasSurfaceContact then` check), insert:

```lua
		-- Signal landing impact to client for camera shake
		local landingImpactSpeed = math.abs(previousVerticalSpeed)
		if landingImpactSpeed > state.config.landingShakeThreshold then
			state.instance:SetAttribute("VehicleLandingImpact", landingImpactSpeed)
		end
```

Note: the existing `if previousAirborne and hasSurfaceContact then` check is on line 719. The fall damage logic is lines 720-737 (inside that block). This new code goes after line 737 but still inside the `if` block (before its `end` on line 738).

The attribute is set on the vehicle model instance. The client watches for changes on this attribute (see change 7). Each landing sets the attribute to the impact speed. Since consecutive landings almost never have identical speeds, `GetAttributeChangedSignal` fires reliably.

### 7. VehicleClient.luau — Landing shake connection

**Add a new connection in `enterVehicleMode` (line 247).**

After `setupHoverDustEmitters` (line 261-262) and before the `sendInterval` line (line 264), insert:

```lua
	local landingShakeConnection: RBXScriptConnection? = nil
	local shakeModel = activeVehicleRenderModel or vehicleModel
	landingShakeConnection = shakeModel:GetAttributeChangedSignal("VehicleLandingImpact"):Connect(function()
		local impactSpeed = shakeModel:GetAttribute("VehicleLandingImpact")
		if type(impactSpeed) ~= "number" or impactSpeed <= 0 then
			return
		end
		local cfg = activeVehicleConfig
		if cfg == nil then
			return
		end
		local threshold = cfg.landingShakeThreshold
		local intensity = cfg.landingShakeIntensity
		local fraction = math.clamp((impactSpeed - threshold) / math.max(1, cfg.fallDamageThreshold - threshold), 0, 1)
		local amplitude = fraction * intensity
		if amplitude > 0.01 then
			VehicleCamera.pushShake(amplitude, 0.2)
		end
	end)
```

The shake amplitude scales linearly from 0 at `landingShakeThreshold` (25 studs/s) to `landingShakeIntensity` (0.35) at `fallDamageThreshold` (80 studs/s). Duration is fixed at 0.2 seconds — slightly longer than lean entry shake (0.12s), giving a heavier feel.

`VehicleCamera.pushShake` already exists and handles shake decay, so this is just a trigger.

**Add cleanup in `exitVehicleMode` (line 175).**

After `VehicleCamera.deactivate()` (line 183) and `restoreVehicleMouse()` (line 184), insert:

```lua
	if landingShakeConnection ~= nil then
		landingShakeConnection:Disconnect()
		landingShakeConnection = nil
	end
```

**Scoping note:** `landingShakeConnection` must be accessible to both `enterVehicleMode` and `exitVehicleMode`. Move it to module-level scope (near the other state variables around line 40):

```lua
local landingShakeConnection: RBXScriptConnection? = nil
```

Then in `enterVehicleMode`, assign to the module-level variable instead of declaring local:
```lua
	landingShakeConnection = shakeModel:GetAttributeChangedSignal(...):Connect(...)
```

---

## What Does NOT Change

- **HoverPhysics.luau** — no changes. The hover springs already handle physical landing compression naturally through their spring stiffness and damping.
- **VehicleCamera.luau** — no changes. `pushShake` already exists. The camera's existing position smoothing also captures the model's tilt bobble naturally.
- **VehicleVisualSmoother.luau** — no changes.
- **CollisionHandler.luau** — no changes.
- **CrestRelease / BlockedClimb / Airborne branches** — untouched. The spring-damper tilt operates on the shared `smoothedUp` computation after all branches complete. All branches benefit from the rotational inertia.
- **Lean system** — unchanged. Bank angle is applied AFTER tilt smoothing, so the bobble doesn't affect lean visuals.
- **Fall damage** — unchanged. Landing shake is triggered in addition to damage, not instead of it.
- **computeTargetSpeed / acceleration taper / lateral momentum** — all untouched.

---

## Data Flow Summary

```
SPRING-DAMPER TILT (CFrame construction, all drive modes):
  tiltError = averageNormal - currentUp
  springForce = error * tiltStiffness          (100 — pulls toward terrain)
  dampingForce = -angularVelocity * tiltDamping (14 — resists rotation)
  angularVelocity += (spring + damping) * dt   (builds momentum, can overshoot)
  smoothedUp = (currentUp + angularVelocity * dt).Unit

  Bump response timeline:
    0.00s — bump hits, terrain normal changes, error appears
    0.05s — spring starts pulling, body begins rotating (resisted by damping)
    0.15s — body approaching new angle, angular velocity peaking
    0.20s — body reaches target angle, velocity still positive → overshoots
    0.25s — body 4.6% past target, spring pulling back
    0.40s — settling, oscillation dying
    0.60s — settled at terrain angle, velocity near zero

  After bump passes (terrain returns to flat):
    Same cycle in reverse — resist, tilt back, overshoot slightly, settle

LANDING CAMERA SHAKE (airborne → grounded):
  Server:
    impactSpeed = |previousVerticalSpeed|
    if impactSpeed > 25: set VehicleLandingImpact attribute
  Client:
    watches attribute → computes shake amplitude
    fraction = (impactSpeed - 25) / (80 - 25)
    amplitude = fraction * 0.35
    VehicleCamera.pushShake(amplitude, 0.2)
```

---

## Test Packet

### AI Build Prints

No new print tags. The existing `[P5_HOVER]` print is unchanged. The spring-damper behavior is visually observable through the model's tilt response.

### Pass/Fail Conditions

**Test 1 — Bobble on bump at speed:**
- Setup: Drive at ~80 studs/s over a single bump or terrain ridge
- PASS if: when the speeder crosses the bump, the body tilts to follow the terrain, then overshoots slightly past level (a subtle nose-dip or nose-up past flat), then settles. The overshoot should be small — a few degrees at most. It should look like the vehicle has mass that needs to self-correct.
- FAIL if: body snaps instantly to terrain angle (old lerp behavior, no overshoot), or body oscillates wildly (underdamped), or body doesn't respond at all

**Test 2 — Inertia resistance visible:**
- Setup: Drive at ~100 studs/s and hit a sharp terrain transition (flat → slope)
- PASS if: there's a brief delay before the body starts tilting to match the slope. The speeder resists the rotation for a moment, then catches up. Compare to driving the same transition at ~15 studs/s — at low speed the response should feel similar to before.
- FAIL if: body tilts instantly with no delay/resistance

**Test 3 — Settle without persistent wobble:**
- Setup: Drive over bumpy terrain at any speed, then reach flat ground
- PASS if: within ~0.6 seconds of reaching flat ground, the body is level and stable. No persistent rocking.
- FAIL if: body keeps oscillating for more than 1 second on flat ground

**Test 4 — Terrain following on sustained slope:**
- Setup: Drive onto a long hillside (slope > 15 degrees) at max speed
- PASS if: body tilts to match the slope, overshoots slightly, then settles on the correct angle. The overshoot should be visible as a brief dip-past-level before stabilizing.
- FAIL if: body never aligns with slope, or alignment takes more than 1 second

**Test 5 — Landing camera shake on hard drop:**
- Setup: Drive off a cliff with ~6+ stud vertical drop
- PASS if: on landing, the camera shakes noticeably. Harder drops = more shake.
- FAIL if: no camera shake on landing, or shake on tiny hops

**Test 6 — No shake on small hops:**
- Setup: Drive over a small bump at moderate speed (becomes briefly airborne for 1-2 frames)
- PASS if: no camera shake. Impact speed should be below the 25 studs/s threshold.
- FAIL if: camera shakes on every tiny hop

**Test 7 — Shake intensity scales:**
- Setup: Do a moderate drop (~3 stud ledge) then a large drop (~8+ stud ledge)
- PASS if: large drop shake is visibly stronger than moderate drop shake
- FAIL if: both produce the same shake intensity

**Test 8 — Normal flat driving stable:**
- Setup: Drive on flat terrain at any speed
- PASS if: body stays level, no unexpected tilting or bobbling. No camera shake.
- FAIL if: random tilt oscillations on flat ground

### MCP Procedure

Default procedure. No deviations.

### Expected Summary Format

No new print format. Existing prints unchanged.
