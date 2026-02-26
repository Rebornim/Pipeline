# Pass 10 Force-Flight Fix Design: The Smoking Gun

**Type:** Bugfix — live-server flight physics (third pass)
**Based on:** Live playtesting after two fix patches, deep critic audit of force-flight code path
**Existing code:** FighterClient.luau, CombatConfig.luau
**Critic Status:** APPROVED — 2 blocking, 4 flagged
**Date:** 2026-02-26

---

## Problem Statement

After two rounds of fixes (ownership gate, collision pitch, lift balance, orientation feedback, fixed-step accumulator, speed attribute cleanup), fighter flight is still fundamentally different in live servers vs Studio. Symptoms: sluggish physics, velocity stays diagonal through turns, camera drift.

**Root Cause (confirmed by critic):** The config has `fighterUseForceFlight = true`, which activates the VectorForce code path. At `FighterClient.luau` line 1542:

```lua
physicalVelocity = base.AssemblyLinearVelocity
```

This line **discards the entire virtual flight simulation every frame** and replaces `physicalVelocity` with the actual physics velocity read from the engine. In Studio (client=server, same process), `AssemblyLinearVelocity` reflects VectorForce writes instantly — the snap reads back the correct value. In live servers, `AssemblyLinearVelocity` lags 1-3 physics frames behind the force write. The virtual sim is always chasing reality from behind instead of leading it. Every turn direction change, speed adjustment, alignment correction, lift/gravity calculation is computed, written as a VectorForce, then thrown away.

This single line explains all remaining symptoms:
1. **Sluggish physics** — virtual sim is dragged back to stale values every frame
2. **Diagonal velocity on turns** — new heading computed, new velocity computed, then overwritten with old-direction actual velocity that hasn't caught up yet
3. **Camera drift** — slip calculations (used for visual overdrive) read wrong velocity vs orientation, producing wrong visual angles, causing BodyGyro to target a wrong orientation, causing primaryPart.CFrame to diverge from where the ship should be pointing

---

## Fix Approach

Two options exist. This design implements **Option A** (safest, one-line config change) with an optional **Option B** follow-up (proper force-flight fix) if the user wants force-flight behavior later.

### Option A: Switch to BodyVelocity mode (recommended, ship now)
Change `fighterUseForceFlight` from `true` to `false` in CombatConfig. This activates the BodyVelocity code path (lines 1543-1551) which:
- Sets `bodyVelocity.Velocity = physicalVelocity` (virtual sim leads, BV follows)
- Does NOT snap physicalVelocity to actual
- Already has velocity feedback (lines 1554-1567) with gentle blending for drift correction

This is the same code path that was used before force-flight was enabled. The virtual sim is the authority, BodyVelocity tracks it, and all the flight physics (alignment, slip damping, drag, lift, gravity) actually take effect.

### Option B: Fix force-flight mode (deferred, for later)
Delete line 1542, increase `fighterForceVelocityGain` from 20→40, test for oscillation. This makes force-flight work like BV mode conceptually (virtual sim leads, force controller closes the gap) but using VectorForce as the actuator instead of BodyVelocity. More complex, requires tuning, save for after live flight is confirmed working.

---

## File Changes

### Modified Files
| File | What's Changing | Why |
|------|----------------|-----|
| `src/Shared/CombatConfig.luau` | `fighterUseForceFlight = false` | Switch to BodyVelocity code path where virtual sim is the authority |

**One file. One line. No structural changes.**

---

## Build Steps

### Step 1: Disable Force-Flight Mode

**File:** `src/Shared/CombatConfig.luau`
**Location:** Fighter vehicle config, `fighterUseForceFlight` (line ~591)

**Current value:** `fighterUseForceFlight = true,`
**New value:** `fighterUseForceFlight = false,`

**Why:** When `fighterUseForceFlight = true`, the VectorForce code path at FighterClient lines 1527-1542 runs. Line 1542 (`physicalVelocity = base.AssemblyLinearVelocity`) discards the virtual sim's output every frame. In Studio this is invisible (instant physics response). In live, AssemblyLinearVelocity lags 1-3 frames, so the virtual sim is always reading stale values and can never lead reality.

Setting to `false` activates the BodyVelocity path (lines 1543-1551) which:
- Writes `bodyVelocity.Velocity = physicalVelocity` — tells BodyVelocity the target
- Does NOT overwrite physicalVelocity — virtual sim leads, BodyVelocity follows
- Has existing velocity feedback at lines 1554-1567 for drift correction (gated by `not useForceFlight`, which is now true)

The VectorForce and BodyVelocity paths differ only in the actuator used. Both compute the same flight physics. The difference is that BV mode lets the virtual sim be the authority, while force mode snaps it back to actual every frame.

**What else changes when `useForceFlight = false`:**
- FighterClient line 788: `useForceFlight = false` (already false when config is false)
- FighterClient line 793: `bodyVelocity.MaxForce = Vector3.new(math.huge, math.huge, math.huge)` — BV gets full force
- FighterClient line 797: `vectorForce.Enabled = false` — VectorForce disabled
- FighterServer line 454: `useForceFlight = false` → `bodyVelocity.MaxForce = math.huge` (BV active from server side too)
- FighterServer line 462: `vectorForce.Enabled = false`
- Landing mode (line 1518-1526): already uses BV regardless of force mode — no change
- Takeoff mode (lines 1198-1223): the force-flight takeoff branch won't run, BV takeoff does — functionally identical (both drive upward at takeoffLiftSpeed)

**AI Build Print:** None needed — this is a config value change. The existing `[P10F2_S3]` and `[P10F2_S1]` prints from the previous fix patch remain.

**Pass condition:** In live server, flight physics feel identical to Studio. Turns respond immediately, velocity follows heading, camera stays locked to ship, acceleration/deceleration feel responsive.
**Fail condition:** Flight still feels sluggish or disconnected in live. If this fails, the root cause is elsewhere (escalate).

---

## Integration Pass

After the single config change, verify in live server (NOT Studio):

1. **Sit in fighter → press L (landing to flight):**
   - Fighter rises, transitions to forward flight
   - No nose-down diving (already fixed in physics fix patch)
   - Acceleration to max speed feels responsive and matches Studio

2. **Turn hard (mouse to edge):**
   - Ship turns AND velocity follows the new heading
   - No diagonal drift — ship goes where it's pointing
   - Camera stays behind the ship, no offset or drift

3. **Fly at various speeds:**
   - Speed changes feel smooth and responsive
   - No sluggishness on acceleration or deceleration
   - Boost works correctly

4. **Pitch up and down:**
   - Mouse vertical axis responds at all times
   - No stuck/frozen pitch
   - Nose-up pulls feel responsive

5. **Compare to Studio:**
   - Flight feel should be functionally identical
   - Turn rates, speed, responsiveness all match

---

## Regression Checks

- [ ] Landing mode still works (uses BV path in both modes — no change)
- [ ] Takeoff still works (BV takeoff path is functionally identical to force takeoff)
- [ ] Ground collision deflection still works (unrelated to force/BV choice)
- [ ] Boost still works
- [ ] Camera FOV speed response still works
- [ ] Sound still plays correctly
- [ ] Remote observers see smooth fighter movement
- [ ] Existing speeder/walker vehicles unaffected (different code path entirely)

---

## Cleanup Notes

After confirming BV mode works correctly in live:

1. **Remove stale force-flight diagnostic prints** — `[P10F2_S1]` at line 738 references "vehiclespeed_attr_write=server_only" which is still true. The "camera_speed_source=physics" is still true. These can stay or be removed at user's discretion.

2. **Dead code consideration** — The force-flight branches (lines 1204-1223 takeoff, lines 1527-1542 flight) still exist but are unreachable when `useForceFlight = false`. They can be left for future Option B work or removed for cleanliness. Not urgent.

3. **Dead hysteresis variables** — `yawInputHysteresisActive`, `pitchInputHysteresisActive`, `filteredYawInput`, `filteredPitchInput` are declared, reset in multiple places, but never read for input filtering. They're noise from a removed feature. Can be cleaned up in a future pass.

---

## AI Build Prints Summary

No new prints. Existing prints from previous fix patches:

| Tag | Location | Purpose | Status |
|-----|----------|---------|--------|
| `[P10F2_S1]` | FighterClient.activate | Camera speed source diagnostic | Keep for now |
| `[P10F2_S3]` | FighterClient.activate | Fixed-step accumulator diagnostic | Keep for now |
| `[P10F2_ORIENT]` | FighterClient RenderStepped | Orientation divergence warning | Keep for now |
| `[FIGHTER_OWNER]` | FighterClient.activate | Ownership probe timing | Keep for now |
| `[P10_COLLISION]` | FighterClient ground collision | Ground proximity events | Keep for now |

All prints should be removed together once flight is confirmed working in live.

---

## Build Order

One step. One file. One line change. Build time: <1 minute.
