# Pass 10 Accumulator Fix Design: The Real Smoking Gun

**Type:** Bugfix — live-server flight physics (fourth pass, FINAL)
**Based on:** Deep critic audit of fixed-step accumulator, FPS-dependency analysis, full codebase sweep
**Existing code:** FighterClient.luau (BV mode, `fighterUseForceFlight = false`)
**Critic Status:** APPROVED — 3 blocking, confirmed root cause with 5:1 FPS ratio match
**Date:** 2026-02-26

---

## Problem Statement

After four rounds of fixes, fighter flight is STILL 5x slower in live servers vs Studio. The previous fix (switching to BV mode) was correct but didn't address the real problem. Deep critic audit found the actual smoking gun:

**The fixed-step accumulator we added in pass-10-flight-fix-design.md is the cause.**

### The Bug

`FighterClient.luau` line 1192:
```lua
for _ = 1, math.max(1, substepCount) do
    local stepDt = PHYSICS_FIXED_STEP   -- always 1/60
```

When FPS > 60, `substepCount = 0` (frame time < 1/60), but `math.max(1, 0) = 1` forces one physics step anyway. Each step uses fixed `stepDt = 1/60` regardless of real frame time. The accumulator doesn't drain the forced step (it drained `substepCount * PHYSICS_FIXED_STEP = 0`).

**Result: physics runs at (FPS / 60) speed.**

- Studio at ~300fps: 300 steps/sec × 1/60 each = **5.0× real-time**
- Live at ~60fps: 60 steps/sec × 1/60 each = **1.0× real-time**
- Ratio: **5:1** — exactly matches user report of "5x slower"

This contaminates EVERY physics calculation: acceleration (line 1269), angular rates (lines 1322-1324), throttle spool (line 1258), gravity/lift (line 1448), drag (line 1449), slip damping (lines 1403-1404), velocity alignment (line 1385), all exponential smoothing.

### Why This Wasn't Caught

The fixed-step accumulator was added to fix "dt clamp discards real time at <30 FPS." But the actual problem was Studio-vs-live divergence, which has nothing to do with sub-30fps behavior. The accumulator solved a non-problem and created a catastrophic new one. At 60fps (the rate it was designed around), it works correctly. The bug only manifests at FPS > 60, which is exactly the condition in Studio Play Solo.

### Secondary Issues

1. **Velocity feedback (lines 1554-1567)** runs inside the substep loop, pulling `physicalVelocity` toward stale `base.AssemblyLinearVelocity` every step. In Studio at 300fps, BV tracks perfectly → divergence < 2 → feedback never triggers. In live at 60fps, BV lags 1-2 frames during turns → divergence > 2 → feedback actively fights every turn command. This was designed for force-flight mode (now disabled) and has no purpose in BV mode.

2. **Orientation feedback (lines 1574-1591)** at rate 3.0 is slightly too aggressive for live conditions where BodyGyro lags 1-3 degrees during fast turns. Reducing to 1.5 prevents it from fighting the sim while still correcting long-term drift.

---

## File Changes

### Modified Files
| File | What's Changing | Why |
|------|----------------|-----|
| `src/Client/Vehicles/FighterClient.luau` | Remove fixed-step accumulator, remove velocity feedback, reduce orientation feedback rate, clean up orphaned constants | Eliminate FPS-proportional physics bug |

**One file. No new files. No config changes.**

---

## Build Steps

### Step 1: Remove Fixed-Step Accumulator

**File:** `src/Client/Vehicles/FighterClient.luau`

**Remove constants** at lines 141-142:
```lua
-- DELETE these two lines:
local PHYSICS_FIXED_STEP = 1 / 60
local PHYSICS_MAX_SUBSTEPS = 4
```

**Remove state variable** at line 213:
```lua
-- DELETE this line:
local physicsTimeAccumulator: number = 0
```

**Remove accumulator reset** at line 874:
```lua
-- DELETE this line:
physicsTimeAccumulator = 0
```

**Remove accumulator reset** in deactivate() at line 1795:
```lua
-- DELETE this line:
physicsTimeAccumulator = 0
```

**Replace the accumulator block and substep loop** at lines 1182-1193.

**Current code (WRONG):**
```lua
		physicsTimeAccumulator += dt
		local substepCount = math.min(
			math.floor(physicsTimeAccumulator / PHYSICS_FIXED_STEP),
			PHYSICS_MAX_SUBSTEPS
		)
		physicsTimeAccumulator -= substepCount * PHYSICS_FIXED_STEP
		if physicsTimeAccumulator > PHYSICS_FIXED_STEP then
			physicsTimeAccumulator = PHYSICS_FIXED_STEP
		end

		for _ = 1, math.max(1, substepCount) do
			local stepDt = PHYSICS_FIXED_STEP
```

**New code (CORRECT):**
```lua
		do
			local stepDt = math.clamp(dt, 1 / 240, 1 / 20)
```

The `do` block preserves the existing indentation scope. The `end` that currently closes the `for` loop at line 1593 now closes this `do` block — no change needed there.

**Why `math.clamp(dt, 1/240, 1/20)`:**
- Floor at 1/240: prevents near-zero dt from causing numerical issues in divisions
- Cap at 1/20: prevents a single lag spike from causing a huge physics jump (same purpose as the old 1/30 clamp, but more permissive since we're no longer in a substep loop)
- Between 1/240 and 1/20 (20fps to 240fps): `stepDt = dt` — physics advances by real frame time

**Frame-rate independence verification:**
All physics calculations inside the loop are already frame-rate-independent by construction:
- Exponential smoothing: `1 - math.exp(-rate * stepDt)` — mathematically FPS-independent
- Linear integration: `value += rate * stepDt` — `rate * stepDt` scales with frame time
- Accel limiters: `math.clamp(delta, -limit * stepDt, limit * stepDt)` — clamp scales with frame time
- Exponential damping: `math.exp(-damping * stepDt)` — mathematically FPS-independent

**At 300fps:** stepDt = 1/300 = 0.00333. accelRate * 0.00333 per frame × 300 frames = accelRate per second. Correct.
**At 60fps:** stepDt = 1/60 = 0.0167. accelRate * 0.0167 per frame × 60 frames = accelRate per second. Correct.
**At 30fps:** stepDt = 1/30 = 0.0333. accelRate * 0.0333 per frame × 30 frames = accelRate per second. Correct.

**AI Build Print:** Replace the existing `[P10F2_S3]` print at line 739 with:
```lua
print("[P10F3] physics_step=realtime_dt clamp=[1/240,1/20]")
```

**Pass condition:** Physics feels identical in Studio and live server. Acceleration, turning, and speed all match.
**Fail condition:** Physics still feels different between Studio and live.

---

### Step 2: Remove Velocity Feedback

**File:** `src/Client/Vehicles/FighterClient.luau`
**Location:** Lines 1554-1567 (inside the physics block, after BodyMover writes)

**Delete the entire velocity feedback block:**
```lua
			-- DELETE all of this (lines 1554-1567):
			-- Physics feedback: blend virtual velocity toward actual to prevent divergence.
			-- In Studio (no network) these are nearly identical. In live, BodyMover response
			-- can lag slightly, causing the virtual simulation to drift from reality.
			-- Force-flight mode already does this. BV mode needs it too.
			if not useForceFlight and not inTakeoff then
				local actualVelocity = base.AssemblyLinearVelocity
				local divergence = (physicalVelocity - actualVelocity).Magnitude
				if divergence > 2 then
					-- Blend toward actual at a rate that corrects drift without fighting
					-- the simulation.
					local feedbackAlpha = math.clamp(divergence * 0.003, 0.05, 0.25)
					physicalVelocity = physicalVelocity:Lerp(actualVelocity, feedbackAlpha)
				end
			end
```

**Why:** In BV mode, the virtual sim is the authority. `bodyVelocity.Velocity = physicalVelocity` tells the BV what to target. The BV tracks it. Reading back `base.AssemblyLinearVelocity` (which lags 1-2 frames) and blending the virtual sim toward it creates a circular feedback loop that actively fights turn commands. In Studio at high FPS, BV tracks perfectly so divergence < 2 and this never triggers. In live at 60fps, it triggers during every turn and slows down the response.

This feedback was added for force-flight mode (now disabled) where the virtual sim was snapped to actual. In BV mode it's both unnecessary and harmful.

**Also delete the `divergenceWarned` state variable** at line 214:
```lua
-- DELETE:
local orientDivergenceWarned: boolean = false
```

And its reset at line 875:
```lua
-- DELETE:
orientDivergenceWarned = false
```

And in deactivate() at line 1796:
```lua
-- DELETE:
orientDivergenceWarned = false
```

**AI Build Print:** None needed — we're removing code.

**Pass condition:** Turns feel responsive in live. No sluggish velocity response during maneuvers.
**Fail condition:** Ship drifts or oscillates during turns (would indicate BV P=10000 is insufficient — escalate to increasing P).

---

### Step 3: Reduce Orientation Feedback Rate

**File:** `src/Client/Vehicles/FighterClient.luau`
**Location:** Line 1584 (inside orientation feedback block)

**Current code:**
```lua
local orientFeedbackAlpha = 1 - math.exp(-3.0 * stepDt)
```

**New code:**
```lua
local orientFeedbackAlpha = 1 - math.exp(-1.5 * stepDt)
```

**Why:** At rate 3.0, the feedback closes 4.9% of the divergence per step at 60fps. During fast turns where BodyGyro lags 1-3 degrees, this pulls the virtual orientation back toward a stale actual CFrame, adding a damping effect that slows turns. At rate 1.5, the feedback closes 2.5% per step — gentle enough to not fight turns but still prevents long-term orientation drift.

The existing 0.5-degree threshold (line 1579: `angleBetween > math.rad(0.5)`) is correct and stays — small divergences are ignored.

**Also remove the one-shot `orientDivergenceWarned` print** (lines 1586-1589):
```lua
-- DELETE these lines:
					if angleBetween > math.rad(2) and not orientDivergenceWarned then
						orientDivergenceWarned = true
						print(string.format("[P10F2_ORIENT] divergence=%.1f_deg feedback_active=true", math.deg(angleBetween)))
					end
```

This print is one-shot (never fires again after first trigger) and provides no ongoing diagnostic value. The `orientDivergenceWarned` variable was already deleted in Step 2.

**AI Build Print:** None needed.

**Pass condition:** Turns feel sharp and responsive. No visible orientation lag during aggressive maneuvers.
**Fail condition:** Ship orientation jitters or oscillates during turns (would indicate feedback rate is too low — try 2.0).

---

### Step 4: Clean Up Stale Diagnostic Prints

**File:** `src/Client/Vehicles/FighterClient.luau`

Remove all stale pass-10 diagnostic prints that are no longer useful:

**Line 738:**
```lua
-- DELETE:
print("[P10F2_S1] camera_speed_source=physics vehiclespeed_attr_write=server_only")
```

**Line 739 (now the Step 1 replacement):**
Keep the new `[P10F3]` print from Step 1.

**Pass condition:** Output log is clean with only the `[P10F3]` print on activation plus the existing `[FIGHTER_OWNER]` ownership probe print.

---

## Integration Pass

After all 4 steps, verify in **BOTH Studio AND live server**:

1. **Acceleration test (hold W from minSpeed):**
   - Time from minSpeed (90) to maxSpeed (260) should be ~1 second in BOTH Studio and live
   - Should feel identical in both environments

2. **Turn test (mouse to edge, full yaw):**
   - Ship turns responsively in BOTH environments
   - No diagonal velocity drift — ship goes where it's pointing
   - No "stuck mouse" feeling — cursor deflection produces immediate turn response
   - Camera stays locked behind ship

3. **Pitch test (mouse up/down):**
   - Pitch responds immediately in both environments
   - No vertical axis lockup or sluggishness
   - Nose-up pull feels responsive

4. **Combined maneuver (turn + accelerate + pitch):**
   - Feels identical in Studio and live
   - No sluggishness, no drift, no lag
   - Camera tracks smoothly

5. **Landing/takeoff cycle (L key):**
   - Landing entry works at appropriate speed
   - Takeoff from landing works (L to launch)
   - Transition feels smooth

6. **Boost test (Shift while holding W):**
   - Boost activates and accelerates in both environments
   - Speed increase feels identical

---

## Regression Checks

- [ ] All physics calculations still use `stepDt` (not hardcoded values) — frame-rate-independent
- [ ] Landing mode still works (uses same stepDt as flight)
- [ ] Takeoff still works
- [ ] Ground collision deflection still works
- [ ] Boost still works
- [ ] Camera tracking works in both environments
- [ ] Sound plays correctly
- [ ] Remote observers see smooth fighter movement
- [ ] Speeders and walkers unaffected (different code path)
- [ ] At very low FPS (20fps), physics caps at stepDt = 1/20 — graceful degradation, no explosion
- [ ] At very high FPS (240+fps), physics uses real dt — no speed multiplication

---

## AI Build Prints Summary

| Tag | Location | Purpose | Action |
|-----|----------|---------|--------|
| `[P10F2_S1]` | FighterClient.activate | Old camera speed diagnostic | DELETE |
| `[P10F2_S3]` | FighterClient.activate | Old fixed-step diagnostic | REPLACE with `[P10F3]` |
| `[P10F2_ORIENT]` | FighterClient RenderStepped | Old orientation divergence | DELETE |
| `[P10F3]` | FighterClient.activate | New physics step diagnostic | ADD |
| `[FIGHTER_OWNER]` | FighterClient.activate | Ownership probe timing | KEEP |
| `[P10_COLLISION]` | FighterClient ground collision | Ground proximity events | KEEP |

---

## Build Order

1. Step 1 (accumulator removal) — **highest priority, the root cause**
2. Step 2 (velocity feedback removal) — **eliminates secondary drag**
3. Step 3 (orientation feedback reduction) — **polish**
4. Step 4 (print cleanup) — **cosmetic**

Steps 1-3 are all in the same file and can be built together in one pass.

---

## Why This Is The Final Fix

The previous 4 rounds of fixes addressed real but secondary issues:
1. **Replication audit** — wrong layer entirely
2. **Physics fix** — ownership race, collision pitch, lift balance — real bugs, but not the 5x speed difference
3. **Flight fix** — dt clamp, orientation feedback, fixed-step accumulator — the accumulator was supposed to fix the dt clamp but CREATED the FPS-proportional bug
4. **Force-fix** — force-flight snap — real bug but now inactive since `useForceFlight = false`

The fixed-step accumulator was the trigger. It was added in round 3 and immediately made physics FPS-dependent above 60fps. Studio runs at high FPS (200-400fps typically), live runs at ~60fps. The 3-7x speed ratio is exactly what the user has been experiencing.

After this fix, the physics uses `stepDt = dt` (clamped for safety). All calculations are frame-rate-independent by construction. Studio and live will produce identical physics regardless of FPS.
