# Pass 10 Flight Fix Design: Fighter Live-Server Physics Divergence

**Type:** Bugfix — live-server flight physics (second pass)
**Based on:** Live playtesting after physics-fix patch, critic audit of FighterClient + FighterServer + VehicleCamera
**Existing code:** FighterServer, FighterClient, VehicleCamera, CombatConfig (fighter section)
**Critic Status:** APPROVED — 3 blocking, 2 flagged
**Date:** 2026-02-26

---

## Problem Statement

Previous fix (pass-10-physics-fix-design.md) resolved the landing→flight death spiral. Remaining live-server symptoms:
1. Physics feels slower — acceleration, deceleration, turn rates all sluggish vs Studio
2. Mouse gets stuck on vertical — pitch input unresponsive for periods
3. Model turns but velocity stays diagonal — ship rotates visually but keeps flying in the old direction
4. Camera drifts from model during turns
5. General disconnected/laggy feeling

**Root cause:** Three compounding issues that are invisible in Studio (where client = server, no network, same physics process) but severe in live:

1. **dt clamp discards real time at low FPS** — `math.min(dt, 1/30)` means at 20 FPS, only 66% of real time is simulated. Everything runs in slow motion.
2. **Virtual orientation never syncs to actual** — `physicsOrientation` is computed client-side and never reads from `base.CFrame`. Velocity is computed from virtual forward while the model/camera show actual forward. When BodyGyro lags even slightly, the velocity direction diverges from where the model points.
3. **SetNetworkOwner re-assertion causes micro-freezes** — server re-calls SetNetworkOwner every 0.5s if a transient ownership read fails, causing brief physics authority handoffs.

---

## What This Pass Fixes

1. Replace dt clamp with fixed-step accumulator — honest time simulation at any FPS
2. Add orientation feedback — close the virtual/actual orientation loop
3. Downgrade ownership re-assertion to log-only — stop physics authority handoff disruptions
4. Fix VehicleSpeed double-writer — remove attribute contention, fix camera speed source

---

## File Changes

### Modified Files
| File | What's Changing | Why |
|------|----------------|-----|
| `src/Client/Vehicles/FighterClient.luau` | Fixed-step accumulator, orientation feedback, remove VehicleSpeed attribute write | Core flight physics fixes |
| `src/Client/Vehicles/VehicleCamera.luau` | Read speed from physics instead of attribute | Camera no longer depends on stale attribute |
| `src/Server/Vehicles/FighterServer.luau` | Downgrade ensurePilotOwnership to log-only | Stop ownership re-assertion disruptions |

No new files. No config changes.

---

## Build Steps

### Step 1: Fix VehicleSpeed Double-Writer and Camera Speed Source

**Files:** `src/Client/Vehicles/FighterClient.luau`, `src/Client/Vehicles/VehicleCamera.luau`

**FighterClient change:** Remove the `VehicleSpeed` attribute write from the RenderStepped loop.

Current code (line ~1553):
```lua
mdl:SetAttribute("VehicleBoosting", boostActive)
mdl:SetAttribute("VehicleSpeed", reportedSpeed)
```

New code:
```lua
mdl:SetAttribute("VehicleBoosting", boostActive)
```

Remove only the `VehicleSpeed` line. Keep `VehicleBoosting`.

Also remove the `VehicleSpeed` write in `FighterClient.deactivate()` (line ~1594):
```lua
-- REMOVE this line:
model:SetAttribute("VehicleSpeed", 0)
```

**VehicleCamera change:** In the fighter camera mode section (line ~201–203), stop reading the `VehicleSpeed` attribute. Read the actual physics velocity instead.

Current code:
```lua
local speedAttribute = vehicleModel:GetAttribute("VehicleSpeed")
local speed = if type(speedAttribute) == "number" then math.max(0, speedAttribute) else 0
local speedFrac = math.clamp(speed / math.max(1, config.maxSpeed), 0, 1)
```

New code:
```lua
local speed = if primaryPart ~= nil then primaryPart.AssemblyLinearVelocity.Magnitude else 0
local speedFrac = math.clamp(speed / math.max(1, config.maxSpeed), 0, 1)
```

**Why:** Client and server both writing `VehicleSpeed` creates replication contention in live — the server's 15Hz write periodically stomps the client's frame-rate write, causing stuttery speed reads. Reading `AssemblyLinearVelocity.Magnitude` directly gives the camera smooth, live physics data at full frame rate with zero attribute overhead. The server's 15Hz `writeFighterTelemetry` still writes `VehicleSpeed` for remote clients' sound systems — that's fine, it's the only writer now.

**AI Build Print:** `[P10F2_S1] camera_speed_source=physics vehiclespeed_attr_write=server_only`
Add this print once in `FighterClient.activate()` after the existing activate prints.

**Pass condition:** Camera FOV transitions smoothly during acceleration. No VehicleSpeed attribute writes from client visible in output.
**Fail condition:** Camera FOV jumps in steps, or HUD speed display stops working.

---

### Step 2: Add Orientation Feedback

**File:** `src/Client/Vehicles/FighterClient.luau`
**Location:** Inside the RenderStepped loop, after the BodyMover write block (the `if inLanding / elseif useForceFlight / else` section ending around line ~1470), and after the existing velocity feedback block. Before the visual overdrive section.

**What to add:** A corrective blend that keeps `physicsOrientation` close to the actual model orientation (`base.CFrame`). This closes the virtual/actual orientation loop that causes velocity to diverge from where the model points.

**Implementation:**

```lua
-- Orientation feedback: blend virtual orientation toward actual to prevent divergence.
-- In Studio (client=server), BodyGyro tracks virtual perfectly — no divergence.
-- In live, BodyGyro P=50000/D=1000 can lag 1-3 degrees during fast turns.
-- The velocity is computed from virtual forward, but the model/camera show actual forward.
-- Without this feedback, the pilot sees the nose pointing one way but flying another.
if not inTakeoff and not inLanding and takeoffVisualLockRemaining <= 0 then
    local actualRotation = base.CFrame - base.CFrame.Position
    local angleBetween = math.acos(math.clamp(
        physicsOrientation.LookVector:Dot(actualRotation.LookVector), -1, 1
    ))
    if angleBetween > math.rad(0.5) then
        -- Blend toward actual at a moderate rate.
        -- Too fast = fights the BodyGyro and causes oscillation.
        -- Too slow = divergence persists through turns.
        -- 3.0 Hz equivalent matches the BodyGyro's ability to close the gap.
        local orientFeedbackAlpha = 1 - math.exp(-3.0 * clampedDt)
        physicsOrientation = physicsOrientation:Lerp(actualRotation, orientFeedbackAlpha)
    end
end
```

**Guard:** The feedback is disabled during takeoff, landing, and the post-takeoff visual lock period. These modes intentionally decouple virtual orientation from actual (the transition logic needs independent virtual control to level the ship).

**Why:** `physicsOrientation` is initialized from `base.CFrame` at activation but then updated exclusively by integrating mouse input. It never reads back from reality. The BodyGyro drives the model toward `physicsOrientation`, but with finite P/D it can't perfectly track — especially during fast turns. The gap means:
- `physicsOrientation.LookVector` (used for velocity decomposition) ≠ `base.CFrame.LookVector` (what the model/camera show)
- Velocity computed from virtual forward → model appears to fly sideways
- Camera follows actual CFrame → camera drifts from where the sim thinks the ship is

In Studio: BodyGyro writes are same-process, same-physics-step — virtual and actual are always within sub-degree agreement. In live: the gap can reach 1–3 degrees during fast turns, which is visually obvious at fighter speeds.

**AI Build Print:** Add a one-time print when orientation divergence exceeds 2 degrees (for diagnostics only):
```lua
-- Inside the angleBetween > 0.5° block:
if angleBetween > math.rad(2) and not orientDivergenceWarned then
    orientDivergenceWarned = true
    print(string.format("[P10F2_ORIENT] divergence=%.1f_deg feedback_active=true", math.deg(angleBetween)))
end
```

Add `local orientDivergenceWarned: boolean = false` at module scope near the other flight state variables (line ~168 area). Reset to `false` in `FighterClient.activate()` and in `FighterClient.deactivate()`.

**Pass condition:** During turns in live server, the velocity direction matches where the model nose points. Camera stays locked to model. No sideways drift visible.
**Fail condition:** Ship oscillates or jitters during turns (feedback too aggressive), or sideways drift persists (feedback too weak).

---

### Step 3: Replace dt Clamp With Fixed-Step Accumulator

**File:** `src/Client/Vehicles/FighterClient.luau`

This is the highest-impact change. The `math.min(dt, 1/30)` clamp discards real time at <30 FPS, making every rate-limited accumulator in the simulation run in slow motion. In Studio at 60 FPS, `dt ≈ 0.017` is well under the clamp — no effect. In live at 20 FPS, `dt = 0.05` gets clamped to `0.033` — 34% of real time is lost every frame.

**Module-level additions** (near line ~168, with other flight state variables):

```lua
local PHYSICS_FIXED_STEP = 1 / 60
local PHYSICS_MAX_SUBSTEPS = 4
local physicsTimeAccumulator: number = 0
```

Reset `physicsTimeAccumulator = 0` in both `FighterClient.activate()` (after the existing state reset block, before the raycast setup) and `FighterClient.deactivate()`.

**RenderStepped change:** Replace the current dt handling with an accumulator-driven loop. The structure changes from:

```
-- CURRENT STRUCTURE:
RenderStepped(dt)
  clampedDt = math.min(dt, 1/30)
  ... input/cursor ...
  ... ALL physics + visuals using clampedDt ...
```

To:

```
-- NEW STRUCTURE:
RenderStepped(dt)
  ... input/cursor (runs once with real dt, BEFORE physics loop) ...
  ... frame-skip guard ...
  physicsTimeAccumulator += dt
  local substepCount = math.min(
      math.floor(physicsTimeAccumulator / PHYSICS_FIXED_STEP),
      PHYSICS_MAX_SUBSTEPS
  )
  physicsTimeAccumulator -= substepCount * PHYSICS_FIXED_STEP
  -- Prevent accumulator drift (cap leftover to one step)
  if physicsTimeAccumulator > PHYSICS_FIXED_STEP then
      physicsTimeAccumulator = PHYSICS_FIXED_STEP
  end
  for substep = 1, math.max(1, substepCount) do
      local stepDt = PHYSICS_FIXED_STEP
      ... ALL physics using stepDt (orientation, velocity, BodyMover writes) ...
  end
  ... visual overdrive + HUD + audio (runs once with real dt, AFTER physics loop) ...
```

**What goes BEFORE the physics loop (runs once per frame):**
- The `isLocalPilotStillValid()` check and bail-out (current lines ~892–911)
- Force-flight fallback check (current lines ~913–924)
- Freelook toggle handling (current lines ~926–964)
- `updateCursorAndInputs(dt, cfg)` — cursor uses real dt for mouse sensitivity (current line ~966)
- Streaming request (current lines ~968–983)
- Landing toggle press detection (current lines ~997–1041)
- Landing transition blend computation (current lines ~1043–1057)
- Vertical input read for landing (current lines ~1059–1068)
- Boost charge/blend computation (current lines ~1072–1096)
- Speed context/HUD text (current lines ~1098–1120)

**What goes INSIDE the physics loop (runs per substep with `stepDt = PHYSICS_FIXED_STEP`):**

Everything that currently uses `clampedDt` for physics integration:
- `takeoffVisualLockRemaining -= stepDt` (currently line ~988)
- Takeoff physics (currently lines ~1122–1170)
- Throttle spool (currently lines ~1172–1187)
- Speed accumulation (currently lines ~1189–1212)
- Speed authority and turn scale computation (currently lines ~1214–1221)
- Angular rate computation (desired yaw/pitch/roll) and smoothing (currently lines ~1223–1271)
- Orientation rotation delta and apply (currently lines ~1273–1289)
- Velocity decomposition, alignment, slip damping, drag, gravity, lift (currently lines ~1291–1377)
- Ground collision check (currently lines ~1380–1403)
- Landing vertical control (currently lines ~1405–1434)
- BodyMover writes (currently lines ~1436–1470)
- Physics feedback — velocity AND orientation (step 2 above)

**What goes AFTER the physics loop (runs once per frame with real `dt`):**
- Visual overdrive computation (currently lines ~1473–1541)
- BodyGyro write for visual orientation (currently lines ~1543–1550) — this runs ONCE after all substeps, using the final `physicsOrientation`
- Speed HUD update (currently line ~1555)
- VehicleBoosting attribute write (current line ~1553)
- Audio update (currently line ~1556)

**Important notes for implementation:**
- The `base` variable (PrimaryPart reference) is read at the top of RenderStepped and stays valid through the frame. No need to re-read per substep.
- `throttle`, `yawInput`, `pitchInput`, `rollInput` are computed once per frame (from cursor) and used by all substeps. Do NOT re-read input per substep.
- The `landingTransitionBlend` is computed once per frame and used by all substeps (it's a visual blend, not a physics accumulator).
- `boostBlend`, `boostActive`, `boostCharge`, and the effective speed limits are computed once per frame. The substep loop uses them as constants.
- The `inTakeoff`, `inLanding` flags can change during a substep (takeoff can complete mid-loop). This is fine — the existing logic already handles this within a single frame.
- `preStepHorizontalVelocity` (currently line ~967) should be computed BEFORE the physics loop, not per substep. It captures the velocity from the previous frame for landing neutral-throttle handling.

**Frame-skip guard:** Before the accumulator, add:
```lua
if dt > 0.25 then
    -- Frame took >250ms (tab-away, severe stutter). Skip physics entirely
    -- to prevent the accumulator from running 15 substeps of catch-up.
    physicsTimeAccumulator = 0
    return
end
```

**Why fixed-step accumulator instead of just raising the cap:** A higher cap (e.g. 1/10) would fix the time loss down to 10 FPS, but integration stability degrades at large dt — Euler integration of orientation at 150 deg/s with dt=0.1 produces 15-degree steps, and exponential smoothing alphas exceed 0.5 which can cause overshooting. The fixed-step accumulator gives deterministic, stable physics at any framerate with zero time loss.

**AI Build Print:** At activation (inside `FighterClient.activate()`):
```lua
print("[P10F2_S3] physics_step=fixed_60hz max_substeps=4")
```

**Pass condition:** In live server at any FPS, acceleration/turn/pitch rates match Studio feel. No sluggishness.
**Fail condition:** Physics feels different from Studio at 60 FPS (regression), or jitters at low FPS.

---

### Step 4: Downgrade Ownership Re-Assertion to Log-Only

**File:** `src/Server/Vehicles/FighterServer.luau`
**Location:** `ensurePilotOwnership()` function, lines ~377–405

**Current code:**
```lua
local function ensurePilotOwnership(state: FighterRuntimeStateInternal, now: number)
    local pilot = state.pilot
    if pilot == nil then
        return
    end
    if (now - state.lastOwnershipVerifyTick) < 0.5 then
        return
    end
    state.lastOwnershipVerifyTick = now

    local ownerOk, currentOwner = pcall(function()
        return state.primaryPart:GetNetworkOwner()
    end)
    if not ownerOk or currentOwner ~= pilot then
        local ownerName = "nil"
        if ownerOk and typeof(currentOwner) == "Instance" and (currentOwner :: Instance):IsA("Player") then
            ownerName = (currentOwner :: Player).Name
        end
        pcall(function()
            (state.primaryPart.AssemblyRootPart or state.primaryPart):SetNetworkOwner(pilot)
        end)
        print(string.format(
            "[P10F_S3] ownership_check pilot=%s owner=%s reassigned=%s",
            pilot.Name,
            ownerName,
            "true"
        ))
    end
end
```

**New code:**
```lua
local function ensurePilotOwnership(state: FighterRuntimeStateInternal, now: number)
    local pilot = state.pilot
    if pilot == nil then
        return
    end
    if (now - state.lastOwnershipVerifyTick) < 2.0 then
        return
    end
    state.lastOwnershipVerifyTick = now

    local ownerOk, currentOwner = pcall(function()
        return state.primaryPart:GetNetworkOwner()
    end)
    if not ownerOk or currentOwner ~= pilot then
        local ownerName = "nil"
        if ownerOk and typeof(currentOwner) == "Instance" and (currentOwner :: Instance):IsA("Player") then
            ownerName = (currentOwner :: Player).Name
        end
        -- Log only — do NOT re-assert SetNetworkOwner.
        -- Re-assertion causes a physics authority handoff that freezes
        -- BodyMover responsiveness for multiple frames. The initial
        -- SetNetworkOwner at pilot entry (updatePilotFromSeat line ~469)
        -- is sufficient. Transient ownership reads are a known Roblox
        -- engine behavior and do not indicate actual ownership loss.
        warn(string.format(
            "[P10F2_S4] ownership_mismatch pilot=%s owner=%s (log_only, no_reassert)",
            pilot.Name,
            ownerName
        ))
    end
end
```

**Changes:**
1. Check interval increased from 0.5s to 2.0s (reduces polling overhead)
2. Removed the `SetNetworkOwner` re-assertion call entirely
3. Changed `print` to `warn` so it's more visible in live logs
4. Updated the print tag and message to indicate log-only behavior

**Why:** In live servers, `GetNetworkOwner()` can transiently return nil or server even when the client actually owns the physics (known Roblox engine behavior at physics scheduling boundaries). The re-assertion of `SetNetworkOwner` causes a brief physics authority handoff — during which the client's BodyMover writes are ignored, causing a freeze/stutter. This happens every 0.5s if the transient read triggers, creating periodic micro-freezes that contribute to the "network clog" feeling.

The initial `SetNetworkOwner(player)` at pilot entry (line ~469 in `updatePilotFromSeat`) is sufficient. If ownership is genuinely lost (not just a transient read), the pilot will experience complete loss of control, which is a different failure mode that the log will catch. Continuously re-asserting makes both real and transient failures feel the same (periodic stutter).

**AI Build Print:** The `warn` in the new code serves as the diagnostic. If it fires frequently in live logs, that indicates Roblox's transient ownership read behavior (expected). If it fires AND the pilot has no control, that would indicate genuine ownership loss (needs investigation).

**Pass condition:** No periodic micro-freezes during flight. `[P10F2_S4]` warn may fire occasionally but flight remains smooth.
**Fail condition:** Pilot loses control entirely mid-flight (genuine ownership loss not recovered). If this happens, the re-assertion may need to be restored with a much longer interval (5s+) and a confirmation check (verify ownership is still wrong after a delay before re-asserting).

---

## Integration Pass

After all 4 steps, verify in a **live server** (NOT Studio):

1. **Sit in fighter → takeoff → fly at various speeds:**
   - Acceleration from minSpeed to maxSpeed feels responsive (~2s with W held)
   - Pitch response is immediate — no "stuck on vertical" periods
   - Turn rates match Studio feel

2. **Turn hard (full cursor deflection):**
   - Velocity follows the nose — no sideways drift
   - Camera stays locked to model — no offset or drift
   - Ship flies where it's pointing, not diagonally

3. **Fly near terrain:**
   - Ground proximity deflects nose UP (step 2 from previous fix)
   - No death spiral

4. **General feel:**
   - No periodic micro-freezes or stutters
   - Smooth, connected physics — no "network clog" sensation
   - Landing mode (L) works correctly
   - Boost (Shift) works correctly
   - Exit (F) works cleanly

5. **Compare to Studio:**
   - Flight feel should be materially similar at ≥30 FPS
   - At lower FPS (15-20), physics should still be responsive (just lower visual framerate)

---

## Regression Checks

- [ ] Studio 60 FPS flight feel unchanged (fixed-step at 60 FPS = same as old dt at 60 FPS)
- [ ] Existing speeder vehicles unaffected (different code path, own dt handling)
- [ ] Walker movement unaffected (different code path)
- [ ] Turret combat unaffected
- [ ] Fighter crash detection still works
- [ ] Remote observers see smooth fighter movement (physics replication)
- [ ] Fighter sound works for pilot and remote observers
- [ ] No stale `[P10F_S1]` through `[P10F_S5]` prints from previous patches remaining

---

## AI Build Prints Summary

| Tag | Location | Purpose | When to Remove |
|-----|----------|---------|----------------|
| `[P10F2_S1]` | FighterClient.activate | Confirms camera reads physics speed | After live verification |
| `[P10F2_ORIENT]` | FighterClient RenderStepped | Detects orientation divergence | After live verification |
| `[P10F2_S3]` | FighterClient.activate | Confirms fixed-step accumulator active | After live verification |
| `[P10F2_S4]` | FighterServer ensurePilotOwnership | Logs ownership mismatches (warn level) | Keep as permanent diagnostic |

**Remove from previous patches** (if still present): `[P10F_S1]`, `[P10F_S2]`, `[P10F_S3]`, `[P10F_S4]`, `[P10F_S5]`, `[P10F_OWNER]`, `[P10F_SYNC]`.

---

## Build Order

Recommended order (smallest risk first):
1. **Step 1** (VehicleSpeed fix) — two small edits, zero physics risk
2. **Step 4** (ownership log-only) — small server change, removes a stutter source
3. **Step 2** (orientation feedback) — moderate, adds new blending logic
4. **Step 3** (fixed-step accumulator) — largest structural change, must be last because it restructures the RenderStepped callback

Steps 1, 2, and 4 are independent and can be tested individually. Step 3 should be built last because it changes the frame structure that steps 2 depends on.
