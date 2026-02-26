# Pass 10 Exit Fix v3 — Auto-Land Settled Check

**Type:** Bugfix — auto-land reaches ground but settled check never fires
**Date:** 2026-02-26
**Prerequisite:** pass-10-exit-fix-v2 already applied (Jump block, seated check, prompt recreate)

---

## Problem Statement

After v2 fixes: Jump is blocked (good), ship descends during auto-land (good), but the ship reaches the ground and sits there indefinitely. The exit remote never fires. Player is stuck — can turn the ship but can't exit. Pressing L cancels auto-land back to landing mode, which is the only way out.

---

## Root Cause

The settled check at FighterClient line 1511-1512:
```lua
local isGrounded = math.abs(altError) < 0.8
local isStopped = horizontalVelocity.Magnitude < 1 and math.abs(nextVerticalSpeed) < 0.8
```

Both conditions are permanently false because of a physics collision gap:

1. `targetAltitude = groundRay.Position.Y + 1.1` — this is 1.1 studs above the ground **surface**.
2. `altError = targetAltitude - base.Position.Y` — `base` is PrimaryPart. Its `Position.Y` is the part's **center**, not its bottom edge.
3. The fighter's collision geometry rests on the ground with the PrimaryPart center several studs above ground. For example, if the PrimaryPart center is 3 studs above ground, `altError = (ground + 1.1) - (ground + 3) = -1.9`. `abs(-1.9) = 1.9 > 0.8` → `isGrounded = false`.
4. The BodyVelocity tries to push the ship down to reach targetAltitude, but ground collision prevents it. The ship physically can't go lower.
5. Since the virtual sim has no velocity feedback from actual physics (feedback was correctly removed for flight stability), `nextVerticalSpeed` converges to `≈ altError * 3 = -5.7`. `abs(-5.7) > 0.8` → part of `isStopped` is also false.
6. Both conditions are permanently false. The settled block never fires. The exit remote is never sent.

**In Studio** this may work because Studio's physics at 300fps can overshoot collision resolution, momentarily placing the part at the target altitude. In live at 60fps, collision is more stable and the part stays firmly at its collision resting position.

---

## Build Steps

### Step 1: Fix Settled Detection

**File:** `src/Client/Vehicles/FighterClient.luau`
**Location:** Auto-land settled check — lines 1511-1513

**Replace:**
```lua
						local isGrounded = math.abs(altError) < 0.8
						local isStopped = horizontalVelocity.Magnitude < 1 and math.abs(nextVerticalSpeed) < 0.8
						if isGrounded and isStopped then
```

**With:**
```lua
						local isNearGround = altError > -8
						local isHorizontallyBraked = horizontalVelocity.Magnitude < 1
						local actualVel = base.AssemblyLinearVelocity
						local isPhysicallyStopped = actualVel.Magnitude < 2
						if isNearGround and isHorizontallyBraked and isPhysicallyStopped then
```

**Why each condition:**

- `altError > -8`: The ship's PrimaryPart center is within 8 studs above `targetAltitude` (ground + 1.1). This accepts any fighter whose PrimaryPart center-to-bottom is up to ~9 studs — generous for any ship geometry. The one-sided check (`>` not `abs`) is intentional: we don't care if the ship is slightly below target (not physically possible due to collision), only that it's not still 50 studs up in the air.

- `isHorizontallyBraked`: Virtual horizontal velocity braked to < 1 by the exponential decay (`math.exp(-8 * stepDt)`). This confirms the deceleration phase completed. Uses virtual velocity because we control it directly.

- `isPhysicallyStopped`: `base.AssemblyLinearVelocity.Magnitude < 2` reads the **actual physics engine velocity**. When the ship is resting on the ground held by collision, this will be near zero regardless of what the virtual sim thinks. This is the key fix — it replaces the broken `nextVerticalSpeed` check (which uses virtual velocity that doesn't know about collision). The 2 stud/s threshold accounts for minor physics solver jitter.

**Pass condition:** Auto-land reaches ground, settled check fires, `[P10_AUTOLAND] settled` prints, exit remote fires, player exits ship.
**Fail condition:** Still stuck in auto-land after reaching ground.

### Step 2: Clamp Virtual Descent When Physically Stopped

**File:** `src/Client/Vehicles/FighterClient.luau`
**Location:** After the `nextVerticalSpeed` snap-to-zero check (line 1505-1507), before `physicalVelocity` assignment (line 1509)

**After:**
```lua
					if math.abs(nextVerticalSpeed) < 0.5 and math.abs(altError) < 0.5 then
						nextVerticalSpeed = 0
					end
```

**Insert:**
```lua
					if altError < -0.5 and math.abs(base.AssemblyLinearVelocity.Y) < 1 then
						nextVerticalSpeed = 0
						landingVerticalCommandSpeed = 0
					end
```

**Why:** When the ship is above targetAltitude (altError < -0.5) but physically not descending (AssemblyLinearVelocity.Y near zero — collision holds it), the virtual sim's descent command is fighting a losing battle against the ground. This creates BodyVelocity jitter (commanding -5 stud/s downward, collision pushes back, repeat). Clamping `nextVerticalSpeed` and `landingVerticalCommandSpeed` to 0 stops the jitter and gives the player a smooth landing experience.

**Pass condition:** Ship doesn't vibrate/jitter while sitting on the ground during auto-land.
**Fail condition:** Ship shakes visibly while auto-landing on the ground.

### Step 3: Add Diagnostic Print to Settled Check (Temporary)

**File:** `src/Client/Vehicles/FighterClient.luau`
**Location:** Inside the auto-land block, after the `physicalVelocity` assignment (line 1509), before the settled check

**Insert:**
```lua
					if tick() % 1 < stepDt then
						print(string.format(
							"[P10_AUTOLAND] altErr=%.2f hSpd=%.2f physVel=%.2f nearGnd=%s hBrk=%s pStop=%s",
							altError,
							horizontalVelocity.Magnitude,
							base.AssemblyLinearVelocity.Magnitude,
							tostring(altError > -8),
							tostring(horizontalVelocity.Magnitude < 1),
							tostring(base.AssemblyLinearVelocity.Magnitude < 2)
						))
					end
```

**Why:** Prints once per second during auto-land so we can see the actual values if the settled check still doesn't fire. The `tick() % 1 < stepDt` throttle prevents console spam.

---

## Test Procedure

1. Enter fighter, fly around.
2. Press L to enter landing mode.
3. Press F to trigger auto-land.
4. Watch console for `[P10_AUTOLAND]` diagnostics — `nearGnd=true`, `hBrk=true`, `pStop=true` should appear within a few seconds.
5. `[P10_AUTOLAND] settled - firing exit remote` should print.
6. Player exits ship. Ship stays frozen (anchored).
7. ProximityPrompt should appear (prompt recreate from v2). Press E to re-enter.
8. Repeat: fly, land, exit, re-enter. Should work every time.

**If still stuck:** Report the `[P10_AUTOLAND]` diagnostic values. Which condition is false?

---

## Build Order

1. Step 1 — Fix settled detection (the critical fix)
2. Step 2 — Clamp virtual descent jitter (polish)
3. Step 3 — Diagnostic print (temporary, helps debug if still failing)

---

## Files Modified

- `src/Client/Vehicles/FighterClient.luau` — settled check, descent clamp, diagnostic print
