# Pass 5 Critic Report: Speeder Terrain Interaction

Date: 2026-02-20
Reviewer: Claude (architect)
Scope: VehicleServer.luau, HoverPhysics.luau, CollisionHandler.luau
Trigger: Codex escalation after multiple failed stabilization iterations

---

## 1. Root-Cause Analysis

### Failure 1: Crest Lock (W stalls at uphill-to-steep-downhill crest)

**Root cause:** The terrain sweep (`applyTerrainSweep`, VehicleServer.luau:266-354) fires a raycast from `currentPosition` to `nextPosition`. At a crest, forward+down travel hits the downhill face. The drivable-slope bypass (line 332-334) checks `hit.Normal.Y >= drivableMinUpDot` but only passes slopes under ~49 degrees. A steep downhill face (>49 degrees) fails this check and falls through to the blocking resolution (lines 342-351), which stops the vehicle at the hit point and reflects velocity out of the surface. The crest-release bypass (lines 310-317) and downhill continuation bypass (lines 319-327) have `travelDir.Y > -0.6` gates that can fail when the vehicle's velocity has a significant downward component at the crest lip. Combined: vehicle gets blocked by its own downhill destination surface.

**Secondary contributor:** The intent system can oscillate between `NormalDrive` and `CrestRelease` at the crest boundary because `crestDropAhead` depends on 3-point forward probes (line 356-391) that can alternate between detecting and not detecting the drop depending on exact position relative to the crest edge.

**Confidence: HIGH**

### Failure 2: Uphill Sink / Phase-Through

**Root cause (sink):** Hover force averaging (HoverPhysics.luau:59) divides `totalForce` by `groundedCount` (not `pointCount`). With 4 hover points and 2 grounded, force per-point is doubled. With 3 grounded, force per-point is 1.33x. This doesn't cause sink directly. The sink comes from the spring being support-only: compression is clamped to `>= 0` (line 45), and force is clamped to `>= 0` (lines 50-52). When the vehicle is above hover height (which happens during uphill approach as rear points lose contact), there is zero downward spring force to track the terrain surface. The vehicle relies entirely on gravity to descend, which is slow relative to forward speed on a slope. Over several frames, the vehicle position drifts above the terrain contour, then when it re-enters hover range, the remaining grounded points produce averaged force that can't overcome the accumulated height error fast enough.

**Root cause (phase-through):** Clearance assist (VehicleServer.luau:716-736) is gated on `shouldAssist` (line 717-718), which requires either `BlockedClimb` intent OR active climbing with slope > 16 degrees and throttle > 0. If the vehicle is climbing but slope is < 16 degrees at the measurement point, or if the vehicle is coasting uphill without throttle, clearance assist doesn't fire. Without it, the only terrain protection is the terrain sweep raycast, which fires a single ray from center-of-model current position to next position (line 279). Hover points extend beyond the center, so corner/side hover points can penetrate terrain that the center ray doesn't detect.

**Confidence: HIGH**

### Failure 3: Cliff Landing Phase-Through

**Root cause:** The drivable-slope bypass in `applyTerrainSweep` (VehicleServer.luau:332-334) has NO falling-speed gate:

```lua
if hit.Normal.Y >= drivableMinUpDot and hitSlopeAngle <= (state.config.maxClimbSlope + 2) then
    return nextPosition
end
```

When a vehicle falls from a cliff onto flat ground (Normal.Y ~= 1.0, slope ~= 0 degrees), this condition is trivially true — flat ground is a "drivable slope." The sweep returns `nextPosition` unmodified, letting the vehicle pass through the ground. The vehicle is falling fast (`velocity.Y << 0`), travel is strongly downward, and the single-frame displacement can be several studs. The sweep ray hits the ground but says "drivable, let it through."

This is the highest-confidence single bug. It directly causes cliff-fall phase-through with no mitigating factor.

**Confidence: CRITICAL / CERTAIN**

### Failure 4: Stop-on-Uphill Void Fall

**Root cause:** When the driver releases throttle on an uphill:
1. `isClimbing` becomes false (requires `inputThrottle > 0`, line 495)
2. Clearance assist requires `isClimbing and slopeAngle > 16 and state.inputThrottle > 0` (line 718), so it turns off
3. The vehicle enters `NormalDrive` with no throttle on a slope
4. Post-ground vertical clamp (lines 696-710) fires: `isClimbingSurface` is false (requires `inputThrottle > 0.05`), so velocity.Y is zeroed or damped (lines 699-703)
5. Hover spring is support-only, so if the vehicle is slightly above hover height (common after slope transitions), spring force is zero
6. With velocity.Y zeroed and no spring downforce, the vehicle floats. If it drifts above ray range, hover returns 0 grounded points, and the vehicle enters airborne free-fall with gravity only
7. A single missed grounding frame means `hasSurfaceContact = false`, clearance assist is off, and the vehicle falls until terrain sweep catches it (or doesn't, per Failure 3)

**Confidence: HIGH**

---

## 2. Invariant Audit

### Invariant A: Non-Penetration Guarantee

**Statement:** After each `stepSingleVehicle` call, no hover point should be below the terrain surface.

**Verdict: FAILS**

Evidence:
- `applyTerrainSweep` is the only spatial collision check (line 738). It uses a single center ray (line 279). Hover points at the vehicle's corners are not sampled.
- The drivable-slope bypass (line 332-334) passes through ALL drivable terrain regardless of falling speed. Flat ground at terminal velocity = pass-through.
- Clearance assist (lines 716-736) is conditional on climbing state. It does not run when stopped, coasting, or in `CrestRelease` intent.
- There is NO post-movement depenetration step. After `SetPrimaryPartCFrame` (line 761), no code checks whether hover points ended up below terrain. If they did, the error persists into the next frame and compounds.
- The system has no hard floor. Every protection is heuristic and conditional.

### Invariant B: Velocity Ownership (single-writer-per-axis-per-frame)

**Statement:** Each component of `state.velocity` should be written by at most one system per frame, with clear priority.

**Verdict: FAILS**

`state.velocity.Y` is written by these sites in order within one `stepSingleVehicle` call:

| Order | Site | Lines | Condition |
|-------|------|-------|-----------|
| 1 | Intent resolver (CrestRelease) | 569 | terrainIntent == CrestRelease |
| 1 | Intent resolver (BlockedClimb) | 598 | terrainIntent == BlockedClimb |
| 1 | Intent resolver (NormalDrive ground) | 637 | canUseGroundDrive |
| 1 | Intent resolver (NormalDrive air) | 652 | airborne |
| 2 | Hover integration | 656 | Always |
| 3 | Crest floor clamp | 657-662 | terrainIntent == CrestRelease |
| 4 | Global clamp | 663 | Always |
| 5 | Post-ground clamp | 696-710 | canUseGroundDrive AND NormalDrive |
| 6 | Terrain sweep velocity correction | 337-338 | sweep hit detected AND into-surface |

Sites 1-5 execute sequentially and each can overwrite the previous. Site 6 (terrain sweep) runs after site 5 and can further modify velocity. The intent resolver at site 1 sets velocity.Y, then hover integration at site 2 adds `verticalAccel * dt`, then the crest floor at site 3 can clamp it back down, then the post-ground clamp at site 5 can zero it. This is 4 writes to the same axis in one frame, each with different assumptions about what the value should be.

### Invariant C: Hover Math Coherence

**Statement:** Hover forces should produce stable equilibrium at `hoverHeight` and track terrain surface changes smoothly.

**Verdict: FAILS**

- Spring compression is clamped to `>= 0` (HoverPhysics.luau:45). When the vehicle is above hover height, compression is 0, force is 0. The spring cannot pull the vehicle down toward the surface. Equilibrium only exists from below, not from above. This makes the hover system unable to follow descending terrain.
- Force averaging divides by `groundedCount` (line 59), not `pointCount`. With 4 hover points, if 1 point loses contact (common at terrain edges), the remaining 3 points each contribute 1/3 of their force instead of 1/4. Total effective force increases by 33%, producing an upward spike. At 2/4 grounded, effective force doubles. This is the source of launch spikes at terrain edges.
- The spring has no overshoot control. `verticalAccel` is clamped to `[-gravity * 1.5, gravity * 1.15]` (line 62), but within those bounds the spring is a simple stiffness * compression formula with velocity damping only when compression > 0. There's no damping when the vehicle approaches from above (because compression is 0 from above).

---

## 3. Technical Outline (Implementation Plan)

### Step 1: Add Unconditional Post-Movement Depenetration

**What:** After `SetPrimaryPartCFrame` (VehicleServer.luau:761), add a multi-point depenetration check that guarantees no hover point ends a frame below terrain.

**Algorithm:**
1. After setting CFrame, raycast downward from each hover point (same params as HoverPhysics)
2. Find the worst-case penetration: `penetration = max(0, -(hoverPointPosition.Y - hitPosition.Y))` for each hover point
3. If `worstPenetration > 0.01`, shift the entire model up by `worstPenetration + 0.05` (small epsilon for stability)
4. If upward shift is applied and `velocity.Y < 0`, clamp `velocity.Y` to `max(velocity.Y, 0)` to prevent re-penetration next frame

**Where:** New function `enforceTerrainFloor(state, rayParams)`, called AFTER line 761 (SetPrimaryPartCFrame). This is unconditional — runs every frame regardless of intent, grounding state, or input.

**Acceptance test:** Drive off a 50-stud cliff onto flat ground at max speed. Hover points must never be below terrain surface on any frame. Repeat 10 times.

**Done when:** No repro scenario produces a hover point below terrain after the frame completes.

### Step 2: Gate Drivable-Slope Bypass on Falling Speed

**What:** Fix the terrain sweep drivable-slope bypass (VehicleServer.luau:332-334) so it doesn't let the vehicle pass through ground during landing.

**Algorithm:** Add a falling-speed gate to the existing condition:
```
if hit.Normal.Y >= drivableMinUpDot
   and hitSlopeAngle <= (state.config.maxClimbSlope + 2)
   and state.velocity.Y > -(state.config.gravity * 0.15)
then
    return nextPosition
end
```

When falling faster than ~29 studs/s (at gravity=196.2), the bypass no longer applies and the sweep resolves the collision normally. This prevents flat-ground pass-through during landing while still allowing normal driving over drivable slopes (where vertical speed is low).

**Acceptance test:** Same cliff-fall test as Step 1. Vehicle must land on surface, not pass through. Also verify: driving on flat ground and gentle slopes (< 45 degrees) still works without stutter.

**Done when:** Cliff landing works AND flat/gentle-slope driving is unaffected.

### Step 3: Fix Hover Force Averaging

**What:** Change HoverPhysics.luau:59 to always divide by `pointCount`, not `groundedCount`.

**Algorithm:** Replace:
```lua
local supportPointCount = if groundedCount > 0 then groundedCount else pointCount
```
With:
```lua
local supportPointCount = pointCount
```

This ensures that losing contact on one hover point reduces total force (as it should physically) rather than redistributing to remaining points. A vehicle with 2/4 points grounded gets half the force, not the same force concentrated on fewer points.

**Acceptance test:** Drive along a terrain edge where 1-2 hover points lose contact. Vehicle should NOT launch upward. Height should decrease smoothly as contact is lost.

**Done when:** No terrain-edge launch spikes. Vehicle settles lower when partial contact is lost.

### Step 4: Make Clearance Assist Unconditional (When Grounded)

**What:** Remove the `shouldAssist` gate (VehicleServer.luau:717-718) and run clearance assist whenever `hasSurfaceContact` is true and intent is not `CrestRelease`.

**Algorithm:** Replace lines 716-736 with:
```
if hasSurfaceContact and groundedCount >= 1 and terrainIntent ~= "CrestRelease" then
    local avgHoverDistance = measureAverageHoverPointDistance(...)
    if avgHoverDistance ~= nil then
        local clearanceFloor = state.config.hoverHeight * 0.45
        if avgHoverDistance < clearanceFloor then
            local correction = math.min(state.config.hoverHeight * 0.16, clearanceFloor - avgHoverDistance)
            local correctionNormal = if averageNormal.Y > 0.25 then averageNormal else Vector3.yAxis
            nextPosition += correctionNormal * correction
            if state.velocity.Y < 0 then
                state.velocity = Vector3.new(state.velocity.X, 0, state.velocity.Z)
            end
        end
    end
end
```

Key change: removed the `shouldAssist` condition entirely. Now clearance assist runs when stopped on a slope, when coasting uphill, when descending — anytime the vehicle has surface contact and isn't in crest release.

**Acceptance test:** Stop on a steep uphill (hold W, release W). Vehicle must not sink or fall through. Hover height must stay above `clearanceFloor`.

**Done when:** Stop-on-uphill never triggers void fall. Vehicle maintains hover envelope on all slopes.

### Step 5: Simplify Terrain Sweep Bypasses

**What:** Reduce the 3 heuristic bypasses (drop-off, crest release, downhill continuation at lines 302-327) to 1 unified bypass with tighter gates.

**Algorithm:** Replace the 3 separate bypass blocks with a single combined check:
```
-- Unified downhill/crest bypass: only when NOT falling fast and there's confirmed ground ahead
local isFallingFast = state.velocity.Y < -(state.config.gravity * 0.12)
local isDescendingGently = travelDir.Y > -0.5 and state.velocity.Y <= 6
if not isFallingFast and isDescendingGently and hasGroundAhead and aheadDropDelta > (state.config.hoverHeight * 0.15) and forwardSpeed > 5 then
    return nextPosition
end
```

This eliminates the 3 separate bypass paths that each had slightly different assumptions and could individually create phase-through windows. The single path requires: not falling fast, descending gently, confirmed ground ahead, measurable drop delta, and forward carry.

**Acceptance test:** Drive over a crest into steep downhill — must not lock. Drive off a cliff — must not phase through. Drive on gentle slopes — must not stutter.

**Done when:** Crest transitions work AND no new phase-through paths exist.

### Step 6: Allow Bounded Negative Spring Force

**What:** Remove the `force >= 0` clamp in HoverPhysics.luau (lines 50-52) and allow a bounded negative spring force when the vehicle is above hover height.

**Algorithm:** Replace lines 44-52 with:
```lua
local compression = hoverHeight - correctedDistance
local clampedCompression = math.clamp(compression, -hoverHeight * 0.5, hoverHeight * 1.8)
local force = springStiffness * clampedCompression
if clampedCompression > 0 then
    force -= springDamping * currentVelocityY
elseif clampedCompression < 0 then
    -- Light damping when above hover height to prevent oscillation
    force -= springDamping * 0.3 * currentVelocityY
end
-- Limit downward pull to a fraction of gravity to avoid snapping
force = math.max(force, -gravity * 0.5)
```

This allows the spring to gently pull the vehicle toward hover height from above, fixing the inability to track descending terrain. The `-hoverHeight * 0.5` compression clamp and `-gravity * 0.5` force floor prevent the spring from yanking the vehicle down aggressively.

**Acceptance test:** Drive over a hill crest onto descending terrain. Vehicle should smoothly follow the terrain contour down rather than floating above and then snapping down. Also verify: vehicle doesn't oscillate or bounce excessively on flat ground.

**Done when:** Vehicle tracks descending terrain smoothly. No oscillation on flat ground.

---

## 4. Implementation Order and Dependencies

```
Step 1 (depenetration) ← No dependencies. Do first. This is the safety net.
Step 2 (sweep gate)    ← No dependencies. Can parallel with Step 1.
Step 3 (hover avg)     ← No dependencies. Can parallel with Steps 1-2.
Step 4 (clearance)     ← Benefits from Step 1 being in place as backstop.
Step 5 (sweep simplify)← Depends on Step 2 being verified first.
Step 6 (negative spring)← Do last. Depends on Steps 1+3 being stable.
```

**Recommended build order:** 1 → 2 → 3 → 4 → 5 → 6

After each step, verify the 4 repro scenarios from the handoff dossier:
1. Crest lock: sharp triangular crest, W held, uphill to steep downhill
2. Uphill sink: hold W on steep uphill for several seconds
3. Cliff landing: drive off cliff to flat ground
4. Stop-on-uphill: stop movement on uphill

**Rollback plan:** Each step is independent enough to revert individually. If Step 6 (negative spring) causes oscillation, revert it — Steps 1-5 still provide the safety guarantees. If Step 5 (simplified bypass) breaks crest transitions, revert to the 3-bypass version — Steps 1-4 provide the hard floor that prevents the phase-through the 3-bypass version used to cause.

---

## 5. Summary of Bugs by Severity

| # | Severity | File | Line(s) | Bug |
|---|----------|------|---------|-----|
| 1 | CRITICAL | VehicleServer | 332-334 | Drivable-slope bypass has no falling-speed gate — flat ground pass-through on landing |
| 2 | CRITICAL | VehicleServer | 761 | No post-movement depenetration — no hard floor guarantee |
| 3 | HIGH | HoverPhysics | 59 | Force averaging divides by groundedCount — launch spikes on partial contact |
| 4 | HIGH | HoverPhysics | 45, 50-52 | Support-only spring — can't track descending terrain |
| 5 | HIGH | VehicleServer | 716-718 | Clearance assist gated on active climbing — doesn't protect stopped/coasting vehicles |
| 6 | MEDIUM | VehicleServer | 302-327 | Three separate sweep bypasses with overlapping but inconsistent gates |
| 7 | MEDIUM | VehicleServer | 656-710 | velocity.Y written by 6 sites per frame without reconciliation |
| 8 | LOW | CollisionHandler | 77 | Terrain-like normal ignore removes fallback collision guard |
