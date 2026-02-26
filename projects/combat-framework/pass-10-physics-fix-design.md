# Pass 10 Physics Fix Design: Fighter Live-Server Flight Failure

**Type:** Bugfix — live-server flight physics
**Based on:** Live playtesting, code audit of FighterClient.luau + FighterServer.luau + VehicleCamera.luau
**Existing code:** FighterServer, FighterClient, VehicleCamera, CombatConfig (fighter section)
**Date:** 2026-02-25

---

## Problem Statement

Fighter flight works correctly in Studio Play Solo but fails catastrophically in live servers. Symptoms reported by pilot:
1. After pressing L (landing → flight), fighter slowly accelerates then pitches nose-down
2. Nose-down increments repeatedly until facing straight into the ground
3. Cursor-up (pitch up) input is unresponsive during the dive, then unlocks after ~1 second
4. Once flying, acceleration/deceleration feel "super slow"
5. Camera drifts away from the actual fighter model
6. All movement physics feel like "network clog"

**Root cause:** Studio Play Solo has NO network ownership system — client and server are the same process, BodyMover writes take effect in the same physics step, `base.Position` is always perfectly synchronized. In live servers, the client starts driving BodyMovers before `SetNetworkOwner` transfer arrives from the server. During that ownership gap (~0.5–1s), BodyMover writes are ineffective, the fighter drifts under server-computed gravity, and the virtual simulation (`physicalVelocity`) diverges from reality (`base.Position`). This triggers a ground collision handler that has an inverted pitch correction, creating a positive-feedback death spiral.

---

## What This Pass Fixes

1. **Ownership gate** — client waits for confirmed BodyMover responsiveness before starting flight physics
2. **Ground collision pitch direction** — inverted pitch correction that dives into terrain instead of away
3. **Lift/gravity balance** — fighter sinks at minSpeed, making ground collision unavoidable after every takeoff
4. **Physics state feedback** — virtual simulation never syncs back to actual physics, causing accumulating divergence
5. **Camera speed source** — camera reads stale attribute for speed instead of live physics velocity

---

## File Changes

### Modified Files
| File | What's Changing | Why |
|------|----------------|-----|
| `src/Client/Vehicles/FighterClient.luau` | Add ownership probe before RenderStepped loop, fix collision pitch sign, add physics feedback sync, write VehicleSpeed for camera | Core flight physics fixes |
| `src/Shared/CombatConfig.luau` | Adjust `fighterLiftCoefficient` | Level flight at minSpeed |

No new files. No changes to FighterServer, VehicleCamera, or RemoteVehicleSmoother.

---

## Build Steps

### Step 1: Ownership Gate Before Flight Loop

**File:** `src/Client/Vehicles/FighterClient.luau`
**Location:** Inside `FighterClient.activate()`, after BodyMover setup (current line ~789) and before the landing idle/takeoff setup (current line ~830)

**What to add:** An ownership probe loop that confirms the client actually controls the physics before starting the flight simulation. Without this, every BodyMover write during the first 0.5–1s goes nowhere in live servers.

**Implementation:**

After the BodyMover MaxForce/MaxTorque setup (lines 789–795) and `physicsOrientation` init (line 796), BEFORE the raycast/landing setup (line 830), insert:

```lua
-- Ownership probe: confirm BodyMover responsiveness before starting flight.
-- In Studio (client=server) this passes instantly. In live, waits for
-- SetNetworkOwner transfer to arrive from server.
local ownershipConfirmed = false
local probeStartTime = os.clock()
local OWNERSHIP_PROBE_TIMEOUT = 3.0
local OWNERSHIP_PROBE_INTERVAL = 0.05

while not ownershipConfirmed do
    local elapsed = os.clock() - probeStartTime
    if elapsed > OWNERSHIP_PROBE_TIMEOUT then
        warn("[P10F_OWNER] ownership probe timed out after 3s — starting flight anyway")
        break
    end

    -- Write a known test velocity and check if the physics engine responds
    local testVelocity = Vector3.new(0, 0.5, 0)
    if bodyVelocity ~= nil then
        bodyVelocity.Velocity = testVelocity
    end
    task.wait(OWNERSHIP_PROBE_INTERVAL)

    -- If we don't have the primary anymore, bail
    if primary == nil or primary.Parent == nil then
        FighterClient.deactivate()
        return
    end

    -- Check if the assembly responded to our BodyMover write.
    -- With ownership, the local physics engine processes it immediately.
    -- Without ownership, AssemblyLinearVelocity stays at whatever the server computes.
    local actualVelocity = primary.AssemblyLinearVelocity
    local responded = actualVelocity.Y > 0.1
    if responded then
        ownershipConfirmed = true
        print(string.format("[P10F_OWNER] ownership confirmed in %.2fs", elapsed + OWNERSHIP_PROBE_INTERVAL))
    end
end

-- Zero out the probe velocity before starting real flight
if bodyVelocity ~= nil then
    bodyVelocity.Velocity = Vector3.zero
end
if primary.Parent == nil then
    FighterClient.deactivate()
    return
end
```

**Also:** During the ownership probe, the fighter should be held in place (BodyGyro keeps orientation, BodyVelocity at zero/probe). The existing BodyGyro MaxTorque = math.huge from line 791 handles orientation hold. After the probe succeeds, the existing landing/takeoff setup code runs as before.

**AI Build Print:** `[P10F_OWNER] ownership confirmed in %.2fs` — fires once on activation, shows how long the ownership transfer took. `[P10F_OWNER] ownership probe timed out after 3s` — fires if ownership never arrives (indicates a deeper problem).

**Pass condition:** In live server, activation print shows ownership confirmed within 0.1–1.0s. Fighter does not start moving until ownership is confirmed.
**Fail condition:** Fighter starts moving before ownership print, or fighter pitches down during first second.

---

### Step 2: Fix Ground Collision Pitch Direction

**File:** `src/Client/Vehicles/FighterClient.luau`
**Location:** Line ~1398 (inside the ground collision handler, non-landing branch)

**Current code (WRONG):**
```lua
physicsOrientation = physicsOrientation * CFrame.Angles(math.rad(-5), 0, 0)
```

**Fixed code:**
```lua
physicsOrientation = physicsOrientation * CFrame.Angles(math.rad(5), 0, 0)
```

**Why:** `math.rad(-5)` pitches the nose DOWN on ground proximity. This is backwards — the correction should pitch UP to deflect away from terrain. The current code creates a positive feedback death spiral: each ground proximity event pitches the nose further into the ground, which causes more ground proximity events.

Additionally, cap the maximum cumulative ground-correction pitch to prevent overcorrection. After the pitch adjustment, add:

```lua
-- Prevent the ground correction from pitching past 20 degrees up from level
local correctedLookY = physicsOrientation.LookVector.Y
if correctedLookY > 0.34 then -- sin(20°) ≈ 0.34
    physicsOrientation = levelOrientationYawOnly(physicsOrientation)
        * CFrame.Angles(math.rad(20), 0, 0)
end
```

**AI Build Print:** The existing `[P10_COLLISION]` print on line ~1399 already logs collisions. No new print needed.

**Pass condition:** Fighter deflects upward on ground proximity instead of diving. No more nose-first-into-ground death spiral.
**Fail condition:** Fighter still pitches down on ground proximity, or overcorrects to pointing straight up.

---

### Step 3: Balance Lift vs Gravity at minSpeed

**File:** `src/Shared/CombatConfig.luau`
**Location:** Fighter vehicle config, `fighterLiftCoefficient` (line ~616)

**Current value:** `fighterLiftCoefficient = 0.22`
**New value:** `fighterLiftCoefficient = 0.32`

**Math:** At minSpeed (90), lift = `90 * 0.32 = 28.8`. Gravity = `26`. Net: **+2.8 studs/s² upward** — fighter gently climbs at minimum speed instead of sinking. At cruise (175 studs/s): lift = `175 * 0.32 = 56`, net = +30 studs/s² up — balanced by the velocity alignment pulling velocity forward (not up) during level flight.

**Why:** With the old coefficient (0.22), lift at minSpeed = 19.8 vs gravity 26 = net 6.2 studs/s² sink. This means every takeoff is a race to accelerate before hitting ground. Combined with the ground collision bug, this made takeoff impossible in live servers. Even with the collision pitch fix (step 2), an insufficient lift coefficient means the fighter constantly brushes ground altitude at low speed, triggering the collision handler repeatedly.

**No other config values change.** The gravity, drag, speed, and all other flight parameters stay the same.

**AI Build Print:** None — this is a config value change. Verified by observing level or slightly climbing flight at minSpeed.

**Pass condition:** Fighter launched from landing at minSpeed (90) maintains altitude or climbs gently without throttle input.
**Fail condition:** Fighter sinks at minSpeed, or climbs so aggressively that level flight at minSpeed is impossible.

---

### Step 4: Physics State Feedback Sync

**File:** `src/Client/Vehicles/FighterClient.luau`
**Location:** Inside the RenderStepped flight loop, at the end of the non-takeoff physics section (after the BodyMover write block, before the visual overdrive section — approximately after current line ~1470)

**What to add:** A feedback step that syncs the virtual simulation state back to the actual physics state, preventing unbounded divergence between `physicalVelocity` and `base.AssemblyLinearVelocity`.

**Implementation:** After the BodyMover writes (the `if inLanding` / `elseif useForceFlight` / `else` block ending at line ~1470), add:

```lua
-- Physics feedback: blend virtual velocity toward actual to prevent divergence.
-- In Studio (no network) these are nearly identical. In live, BodyMover response
-- can lag slightly, causing the virtual simulation to drift from reality.
-- Force-flight mode already does this (line ~1460). BV mode needs it too.
if not useForceFlight and not inTakeoff then
    local actualVelocity = base.AssemblyLinearVelocity
    local divergence = (physicalVelocity - actualVelocity).Magnitude
    if divergence > 2 then
        -- Blend toward actual at a rate that corrects drift without fighting
        -- the simulation. At 60fps with alpha ~0.15, corrects 10 stud/s drift
        -- in about 0.5s.
        local feedbackAlpha = math.clamp(divergence * 0.003, 0.05, 0.25)
        physicalVelocity = physicalVelocity:Lerp(actualVelocity, feedbackAlpha)
    end
end
```

**Why:** In BodyVelocity mode, `physicalVelocity` is a pure client-side simulation that never reads back from the actual physics. In Studio, BodyVelocity response is instant so they match. In live, any lag between the BodyMover write and the physics response causes `physicalVelocity` to diverge from `base.AssemblyLinearVelocity`. This divergence accumulates and causes:
- Ground collision checks using `base.Position.Y` (actual) while the sim thinks the fighter is higher
- Camera tracking the actual model position while the sim drives a different trajectory
- The "network clog" feeling of sluggish, disconnected control

The force-flight path already does this (line ~1460: `physicalVelocity = base.AssemblyLinearVelocity`). This extends the same principle to BV mode, but with blending instead of hard snap to preserve the simulation's smoothness.

**AI Build Print:** Add a one-time print when large divergence is first detected:
```lua
-- Inside the divergence > 2 block, before the blend:
if divergence > 10 and not divergenceWarned then
    divergenceWarned = true
    print(string.format("[P10F_SYNC] velocity_divergence=%.1f blending_active=true", divergence))
end
```

Add `local divergenceWarned = false` alongside the other flight state variables at module scope (near line ~168). Reset it to `false` in `FighterClient.activate()` after the flight state reset block.

**Pass condition:** In live server, camera stays locked to fighter. No "drifting away" feeling. `[P10F_SYNC]` print fires at most once per activation (small initial divergence during ownership transfer) then stops.
**Fail condition:** Camera still drifts from model, or the feedback blend makes the fighter jittery/oscillate.

---

### Step 5: Client Writes VehicleSpeed for Camera

**File:** `src/Client/Vehicles/FighterClient.luau`
**Location:** Inside the RenderStepped loop, near line ~1553 where `VehicleBoosting` is written.

**What to add:** Restore the client-side `VehicleSpeed` attribute write. The previous fix patch removed this to eliminate write contention with the server. But VehicleCamera reads `VehicleSpeed` (VehicleCamera.luau line ~201) for speed-based FOV. With the server writing at only 15Hz, the camera FOV jumps in live instead of smoothly following speed.

**Current code:**
```lua
mdl:SetAttribute("VehicleBoosting", boostActive)
```

**New code:**
```lua
mdl:SetAttribute("VehicleBoosting", boostActive)
mdl:SetAttribute("VehicleSpeed", reportedSpeed)
```

**Note:** The server also writes `VehicleSpeed` at 15Hz in `writeFighterTelemetry`. This is fine — the client write at 60Hz ensures the local camera gets smooth speed data, while the server write provides the value for other clients' RemoteVehicleSmoother sound systems. The write contention concern from the previous audit is a non-issue because: (a) the pilot client's write is the one that matters for the pilot's camera, and (b) the server's 15Hz write is only needed by remote clients who don't have the pilot's camera.

**AI Build Print:** None needed — this is a one-line restore.

**Pass condition:** Camera FOV transitions smoothly during acceleration/deceleration in live server.
**Fail condition:** FOV still jumps in discrete steps during speed changes.

---

## Integration Pass

After all 5 steps, verify in live server (NOT Studio):

1. **Sit in fighter → press L (landing to flight):**
   - `[P10F_OWNER]` prints ownership confirmed within 1s
   - Fighter rises during takeoff, transitions to forward flight
   - No nose-down diving
   - Acceleration to max speed feels responsive (within ~2s of holding W)

2. **Fly at minSpeed (release W, let speed settle to ~90):**
   - Fighter maintains altitude or gently climbs
   - Does NOT sink toward ground
   - Ground collision handler does NOT trigger repeatedly

3. **Fly near terrain at high speed:**
   - Ground proximity pushes nose UP (not down)
   - Fighter deflects away from terrain
   - No death spiral

4. **General flight feel:**
   - Camera stays locked to fighter model (no drift)
   - Speed changes feel smooth and responsive
   - Turn/pitch/roll rates feel similar to Studio
   - No "network clog" sluggishness

5. **Exit (press F):**
   - Clean dismount, fighter coasts with momentum
   - No residual BodyMover forces

---

## Regression Checks

- [ ] Existing speeder vehicles unaffected (different code path)
- [ ] Walker movement unaffected (different code path)
- [ ] Turret combat unaffected
- [ ] Fighter takeoff from ground (standard L press) works in both Studio and live
- [ ] Fighter crash detection still works (high-speed terrain collision = destruction)
- [ ] Fighter landing mode (L to enter landing) still works
- [ ] Fighter boost still works (Shift)
- [ ] Remote observers see smooth fighter movement (physics replication)
- [ ] Fighter sound plays correctly for pilot and remote observers

---

## AI Build Prints Summary

| Tag | Location | Purpose | When to Remove |
|-----|----------|---------|----------------|
| `[P10F_OWNER]` | FighterClient.activate ownership probe | Confirms ownership transfer timing | After live verification |
| `[P10F_SYNC]` | FighterClient RenderStepped feedback | Detects velocity divergence | After live verification |
| `[P10_COLLISION]` | FighterClient ground collision | Already exists — confirms collision events | Already present |

Remove `[P10F_S1]` through `[P10F_S5]` prints from the previous fix patch during this build if still present. They were step-verification prints for the replication fix and are no longer needed.

---

## Build Order

Steps 1–5 are independent and can be built in any order. However, recommended order is:
1. Step 2 (collision pitch fix) — one-line fix, highest immediate impact
2. Step 3 (lift coefficient) — one-line config change, prevents ground collision triggering
3. Step 1 (ownership gate) — most important structural fix, prevents the entire class of ownership-race bugs
4. Step 4 (physics feedback) — prevents long-term divergence
5. Step 5 (camera speed attribute) — polish, lowest priority
