# Pass 10 Landing Fix Design: Auto-Land Exit + Mouse Cursor Fix

**Type:** Bugfix + UX improvement — landing exit system + mouse stuck on takeoff exit
**Based on:** User report: prompt vanishes after landing exit, mouse locked up after leaving landing sequence
**Existing code:** FighterClient.luau, FighterServer.luau
**Date:** 2026-02-26

---

## Problem Statement

Two bugs after accumulator fix:

1. **Proximity prompt vanishes after landing exit.** Player lands, presses F, ship falls away unanchored, prompt unreachable.

2. **Mouse locked on pitch after landing→takeoff→flight.** Player presses L to leave landing, takes off, tries to pitch up — nothing. Must push mouse down first before up works. Specific: "I have to move my mouse down before I can move it up."

---

## Root Cause Analysis

### Bug 1: Prompt Vanishes (Confirmed — Server Exit Path)

When pilot presses F, server calls `releaseFighterMomentum()` which:
- Disables all BodyMovers
- Sets `primaryPart.Anchored = false`
- Re-enables prompt

The ship was hovering via BodyVelocity. With BV disabled and no anchor, it falls under gravity. Prompt is re-enabled but attached to a falling ship.

**User's design request:** Don't just unanchor the ship. The exit system should:
- Only allow exit during the landing sequence (not mid-flight)
- When F is pressed during landing while moving: auto-decelerate, raycast to ground, smoothly land itself
- Then player exits and ship stays parked
- If already stopped and grounded: exit immediately

### Bug 2: Mouse Locked on Pitch (Confirmed — Cursor Accumulation During Takeoff)

Traced the exact sequence:
1. Player presses L to leave landing → cursor resets to 0,0 at `FighterClient.luau:1075-1079`
2. Takeoff phase runs for **0.9 seconds** (`fighterTakeoffDuration`)
3. During those 0.9s, cursor processing at lines 563-591 **still runs** — `GetMouseDelta()` accumulates into `virtualCursorY`
4. Player instinctively moves mouse upward during takeoff → `virtualCursorY` goes negative → hits circle boundary (clamped at edge)
5. Takeoff completes → flight begins → **cursor is stuck at the TOP edge of the circle**
6. Moving mouse up = already at edge, no effect. Must move down first to pull cursor away from boundary.

Fix: reset cursor to 0,0 **again** when takeoff completes into flight (line ~1221), not just when takeoff starts.

---

## File Changes

### Modified Files
| File | What's Changing | Why |
|------|----------------|-----|
| `src/Client/Vehicles/FighterClient.luau` | Auto-land exit system, block F during flight, cursor reset on takeoff completion | Auto-land UX + mouse fix |
| `src/Server/Vehicles/FighterServer.luau` | Always `parkFighter()` on exit (since exit now only happens from landed state) | Ship stays anchored after exit |

**Two files. No new files.**

---

## Build Steps

### Step 1: Fix Mouse Cursor Lock on Takeoff Exit

**File:** `src/Client/Vehicles/FighterClient.luau`
**Location:** Takeoff completion → flight transition, line ~1221

**Current code (lines 1219-1226):**
```lua
						physicsOrientation = levelOrientationYawOnly(physicsOrientation)
						visualOrientation = physicsOrientation
						resetFlightDynamicsVisuals()
						takeoffVisualLockRemaining = FIGHTER_POST_LANDING_VISUAL_LOCK
						flightMode = "Flight"
						inLanding = false
						currentSpeed = math.max(currentSpeed, minSpeed)
						physicalVelocity = physicsOrientation.LookVector * currentSpeed
```

**New code:**
```lua
						physicsOrientation = levelOrientationYawOnly(physicsOrientation)
						visualOrientation = physicsOrientation
						resetFlightDynamicsVisuals()
						virtualCursorX = 0
						virtualCursorY = 0
						displayedCursorX = 0
						displayedCursorY = 0
						mouseIdleNoInputTime = 0
						takeoffVisualLockRemaining = FIGHTER_POST_LANDING_VISUAL_LOCK
						flightMode = "Flight"
						inLanding = false
						currentSpeed = math.max(currentSpeed, minSpeed)
						physicalVelocity = physicsOrientation.LookVector * currentSpeed
```

**Why:** During the 0.9s takeoff, mouse deltas accumulate into `virtualCursorY`. If the player moves the mouse upward (natural instinct during takeoff), the cursor hits the circle boundary. When flight begins, the cursor is stuck at the edge — pitch up has no effect because cursor is already at max displacement. Resetting to 0,0 when flight actually begins gives the player a clean centered cursor with full range in all directions.

**Pass condition:** After landing→takeoff→flight, mouse immediately responds in all directions. No need to "unstick" by moving in the opposite direction first.
**Fail condition:** Mouse still locks on one axis after landing exit.

---

### Step 2: Block Exit During Flight — Only Allow During Landing

**File:** `src/Client/Vehicles/FighterClient.luau`
**Location:** `onExitAction()` function, line ~299

**Current code:**
```lua
local function onExitAction(_name: string, inputState: Enum.UserInputState, _inputObject: InputObject): Enum.ContextActionResult
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	-- Immediately stop local force writes so dismount can't leave client-side residual push.
	if bodyVelocity ~= nil then
		bodyVelocity.MaxForce = Vector3.zero
		bodyVelocity.Velocity = Vector3.zero
	end
	if bodyGyro ~= nil then
		bodyGyro.MaxTorque = Vector3.zero
	end
	if vectorForce ~= nil then
		vectorForce.Enabled = false
		vectorForce.Force = Vector3.zero
	end
	boostActive = false
	smoothedThrottleInput = 0
	if activeModel ~= nil then
		activeModel:SetAttribute("VehicleBoosting", false)
	end
	if vehicleExitRemote ~= nil and activeEntityId ~= nil then
		vehicleExitRemote:FireServer()
	end
	return Enum.ContextActionResult.Sink
end
```

**New code:**
```lua
local function onExitAction(_name: string, inputState: Enum.UserInputState, _inputObject: InputObject): Enum.ContextActionResult
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	if flightMode ~= "Landing" then
		return Enum.ContextActionResult.Sink
	end
	if not exitAutoLandActive then
		exitAutoLandActive = true
	end
	return Enum.ContextActionResult.Sink
end
```

**Why:** Exit is now only allowed during landing mode. Pressing F during flight does nothing. Pressing F during landing sets a flag (`exitAutoLandActive`) that triggers the auto-land sequence (Step 3). The actual BodyMover cleanup and `VehicleExitRequest` are deferred until the ship is grounded and stopped.

**New state variable** — add near the other landing state variables (around line 210):
```lua
local exitAutoLandActive: boolean = false
```

**Reset `exitAutoLandActive`** in all places where other landing state is reset:
- In `deactivate()` (line ~1744 area, with the other landing resets): add `exitAutoLandActive = false`
- In the `WindowFocusReleased` handler (line ~1769 area): add `exitAutoLandActive = false`
- In the `WindowFocused` handler (line ~1806 area): add `exitAutoLandActive = false`
- In `activate()` after `flightMode = "Landing"` (line ~897 area): add `exitAutoLandActive = false`
- When the player presses L to leave landing (takeoff from landing) at line ~1059 area: add `exitAutoLandActive = false` (cancels auto-land if player changes their mind)

**Pass condition:** Pressing F during flight does nothing. Pressing F during landing triggers auto-land.
**Fail condition:** Player can still exit mid-flight, or auto-land doesn't trigger.

---

### Step 3: Auto-Land Sequence

**File:** `src/Client/Vehicles/FighterClient.luau`
**Location:** Inside the landing physics block, after the existing `if inLanding then` velocity processing (line ~1500-1503)

The auto-land sequence activates when `exitAutoLandActive == true` and `inLanding == true`. It does three things simultaneously:
1. **Decelerate horizontally** — force throttle to 0, apply heavy braking
2. **Descend to ground** — raycast down, drive vertical velocity toward ground clearance altitude
3. **When stopped and grounded** — fire exit remote, clean up

**Add the auto-land block after the existing `if inLanding then ... end` block at line ~1503.** Insert right after `end` of the landing velocity block, before the next `if inLanding then` block at line ~1500:

Actually, the auto-land should REPLACE the normal landing input processing when active. The simplest approach: at the top of the landing input section (line ~1469), check `exitAutoLandActive` and override the inputs.

**Insert at line ~1469, BEFORE the existing `if inLanding then` block:**

```lua
				if inLanding and exitAutoLandActive then
					-- Auto-land: override all inputs to bring ship to a stop on the ground.
					-- Heavy horizontal braking.
					local horizontalVelocity = Vector3.new(physicalVelocity.X, 0, physicalVelocity.Z)
					local horizontalSpeed = horizontalVelocity.Magnitude
					if horizontalSpeed > 1 then
						local brakeFactor = math.exp(-8 * stepDt)
						horizontalVelocity *= brakeFactor
						if horizontalVelocity.Magnitude < 1 then
							horizontalVelocity = Vector3.zero
						end
					else
						horizontalVelocity = Vector3.zero
					end

					-- Auto-descend: raycast to find ground, drive toward LANDING_GROUND_CLEARANCE above it.
					local targetAltitude = base.Position.Y -- default: hold current altitude
					if flightRayParams ~= nil then
						local groundRay = Workspace:Raycast(
							base.Position + Vector3.new(0, 10, 0),
							Vector3.new(0, -60, 0),
							flightRayParams
						)
						if groundRay ~= nil then
							targetAltitude = groundRay.Position.Y + LANDING_GROUND_CLEARANCE
						end
					end
					local altError = targetAltitude - base.Position.Y
					local autoDescentSpeed: number
					if altError > 0.3 then
						-- Below target — rise gently
						autoDescentSpeed = math.clamp(altError * 6, 0, 8)
					elseif altError < -0.3 then
						-- Above target — descend smoothly
						autoDescentSpeed = math.clamp(altError * 3, -12, 0)
					else
						-- At target — hold
						autoDescentSpeed = 0
					end
					local verticalAlpha = 1 - math.exp(-6 * stepDt)
					landingVerticalCommandSpeed += (autoDescentSpeed - landingVerticalCommandSpeed) * verticalAlpha
					local verticalDelta = landingVerticalCommandSpeed - physicalVelocity.Y
					local maxVerticalStep = LANDING_VERTICAL_ACCEL * stepDt
					local nextVerticalSpeed = physicalVelocity.Y + math.clamp(verticalDelta, -maxVerticalStep, maxVerticalStep)
					if math.abs(nextVerticalSpeed) < 0.5 and math.abs(altError) < 0.5 then
						nextVerticalSpeed = 0
					end

					physicalVelocity = Vector3.new(horizontalVelocity.X, nextVerticalSpeed, horizontalVelocity.Z)

					-- Check if settled: stopped horizontally and at ground level.
					local isGrounded = math.abs(altError) < 0.8
					local isStopped = horizontalVelocity.Magnitude < 1 and math.abs(nextVerticalSpeed) < 0.8
					if isGrounded and isStopped then
						-- Fully landed. Fire exit and deactivate.
						physicalVelocity = Vector3.zero
						currentSpeed = 0
						if bodyVelocity ~= nil then
							bodyVelocity.MaxForce = Vector3.zero
							bodyVelocity.Velocity = Vector3.zero
						end
						if bodyGyro ~= nil then
							bodyGyro.MaxTorque = Vector3.zero
						end
						if vectorForce ~= nil then
							vectorForce.Enabled = false
							vectorForce.Force = Vector3.zero
						end
						boostActive = false
						smoothedThrottleInput = 0
						if activeModel ~= nil then
							activeModel:SetAttribute("VehicleBoosting", false)
						end
						if vehicleExitRemote ~= nil and activeEntityId ~= nil then
							vehicleExitRemote:FireServer()
						end
						exitAutoLandActive = false
					end
				elseif inLanding then
```

This replaces the `if inLanding then` at line 1469 with `if inLanding and exitAutoLandActive then ... elseif inLanding then`.

The existing landing velocity processing (lines 1470-1503) becomes the `elseif inLanding then` branch — untouched, works exactly as before when auto-land isn't active.

**HUD feedback during auto-land:** In the `speedContext` section (lines 1150-1155), add an auto-land message:

**Current code:**
```lua
		local speedContext: string? = nil
		if inLanding then
			speedContext = "Press L: Leave Landing Sequence | E/Q Alt"
		elseif landingEligible then
			speedContext = "Press L: Landing Sequence"
		end
```

**New code:**
```lua
		local speedContext: string? = nil
		if inLanding and exitAutoLandActive then
			speedContext = "Auto-Landing..."
		elseif inLanding then
			speedContext = "Press L: Leave Landing Sequence | E/Q Alt | F: Exit"
		elseif landingEligible then
			speedContext = "Press L: Landing Sequence"
		end
```

This shows "Auto-Landing..." during the sequence and adds "F: Exit" to the landing HUD hint.

**Pass condition:** Pressing F during landing triggers smooth auto-deceleration and descent. Ship settles on ground, player exits, ship stays parked and prompt appears.
**Fail condition:** Ship jitters, overshoots ground, or exits while still moving.

---

### Step 4: Server Always Parks on Exit

**File:** `src/Server/Vehicles/FighterServer.luau`
**Location:** Exit request handler (line ~770) and `updatePilotFromSeat` fallback (line ~506-508)

Since the client now only fires `VehicleExitRequest` after the ship is grounded and stopped, the server should always park. No speed check needed — the client guarantees settled state.

**Exit request handler — replace `releaseFighterMomentum(state)` at line 770:**

**Current code:**
```lua
    state.exitRequestedAt = os.clock()
    releaseFighterMomentum(state)
```

**New code:**
```lua
    state.exitRequestedAt = os.clock()
    parkFighter(state)
```

**`updatePilotFromSeat` fallback — replace `releaseFighterMomentum(state)` at line 508:**

**Current code:**
```lua
		clearPilot(state)
		state.exitRequestedAt = 0
		releaseFighterMomentum(state)
```

**New code:**
```lua
		clearPilot(state)
		state.exitRequestedAt = 0
		parkFighter(state)
```

**Also update the `hasPilotedOnce` fallback at lines 510-514:**

**Current code:**
```lua
	else
		if state.hasPilotedOnce then
			releaseFighterMomentum(state)
		else
			parkFighter(state)
		end
```

**New code:**
```lua
	else
		parkFighter(state)
```

**Why:** All three paths now call `parkFighter()`. Since exit only happens from landed state (client auto-lands first), the ship is always near-stationary when the exit remote fires. `parkFighter()` anchors it in place, zeros any residual motion, and re-enables the prompt. No more falling ships.

The `releaseFighterMomentum()` function can remain in the code (it's still used nowhere, but removing it is optional cleanup — not urgent).

**Pass condition:** After auto-land exit, ship stays anchored, prompt appears, player can re-enter.
**Fail condition:** Ship still falls/drifts after exit.

---

## Integration Pass

After all 4 steps, verify:

1. **Landing → F to exit:**
   - Enter landing mode (L at appropriate speed)
   - Press F while moving — ship smoothly decelerates and descends
   - HUD shows "Auto-Landing..."
   - Ship settles on ground, player exits
   - Ship stays anchored in place
   - ProximityPrompt appears immediately
   - Press E to re-enter — works normally

2. **Landing → already stopped → F:**
   - Enter landing, stop completely (release all keys, Q to ground)
   - Press F — ship exits immediately (already settled)
   - Prompt appears

3. **Flight → F (should do nothing):**
   - Flying at full speed, press F — nothing happens
   - Ship continues flying normally
   - No exit, no deactivation

4. **Landing → F → change mind → L:**
   - Enter landing, press F (auto-land starts)
   - Press L before auto-land completes — auto-land cancels, takeoff begins
   - Flight resumes normally, cursor centered, all inputs work

5. **Landing → takeoff → fly (mouse fix):**
   - Enter landing mode
   - Press L to take off, move mouse around during the 0.9s takeoff
   - Flight begins — mouse immediately responds in ALL directions
   - No need to "unstick" by moving in opposite direction

6. **Re-enter after exit → full flight cycle:**
   - After exiting via auto-land, re-enter via ProximityPrompt
   - Take off, fly, turn, pitch, boost — everything works
   - Land again, exit again — prompt appears again

---

## Regression Checks

- [ ] Landing mode E/Q vertical controls still work (untouched when auto-land not active)
- [ ] Landing throttle (W/S) still works
- [ ] Takeoff from landing (L) still works
- [ ] Entering landing from flight (L) still works
- [ ] Boost still works in flight
- [ ] Camera tracking works throughout
- [ ] Sound plays correctly during auto-land
- [ ] Death/respawn cycle still works
- [ ] Re-entry after park works
- [ ] Remote observers see smooth landing sequence
- [ ] Mid-air character death (e.g., from damage while flying) still clears pilot properly on server

---

## AI Build Prints Summary

| Tag | Location | Purpose | Action |
|-----|----------|---------|--------|
| `[P10F3]` | FighterClient.activate | Physics step diagnostic | KEEP |
| `[FIGHTER_OWNER]` | FighterClient.activate | Ownership probe timing | KEEP |
| `[P10_COLLISION]` | FighterClient ground collision | Ground proximity events | KEEP |

No new prints needed — the auto-land is observable (ship moves to ground and stops).

---

## Build Order

1. Step 1 (cursor reset on takeoff completion) — **fixes the mouse bug**
2. Step 2 (block exit during flight, add `exitAutoLandActive` flag) — **gate change**
3. Step 3 (auto-land sequence) — **the new exit behavior**
4. Step 4 (server always parks) — **server-side match**

Steps 1+2 are independent. Step 3 depends on Step 2 (needs the flag). Step 4 is independent of client changes.
