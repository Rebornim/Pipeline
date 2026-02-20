# Pass 5 Polish: Steering Overhaul (Mouse Rework + Speed-Dependent Turn Rate)

Date: 2026-02-20
Type: Design — physics feel, Step 1 of 3
Scope: VehicleClient (mouse input), VehicleServer (turn rate), CombatHUD (cursor), CombatConfig, CombatTypes.

---

## Overview

Two coupled changes that define the steering foundation:

1. **Mouse rework**: Lock mouse to center (like turrets), track virtual cursor via delta accumulation, constrain to a horizontal band, self-centering return, custom cursor dot. Replaces the current free-roaming absolute-position mouse.

2. **Speed-dependent turn rate**: Turn rate scales from high at low speed to low at max speed. Tight parking turns, wide highway turns. Replaces the current flat 120 deg/s at all speeds.

---

## File Changes

### 1. CombatTypes.luau — VehicleConfig type

**Replace `turnSpeed: number` with two fields:**

Remove:
```
turnSpeed: number,
```

Add (in the same position):
```
turnSpeedLow: number,
turnSpeedHigh: number,
```

### 2. CombatConfig.luau — light_speeder values + global mouse constants

**light_speeder config table — replace `turnSpeed`:**

Remove:
```lua
turnSpeed = 120,
```

Add:
```lua
turnSpeedLow = 120,
turnSpeedHigh = 45,
```

Tuning notes:
- `turnSpeedLow = 120`: same as current at standstill. No change in low-speed feel.
- `turnSpeedHigh = 45`: at max speed (120 studs/s), mouse turn rate drops to 45 deg/s. Turn radius at max speed ≈ 120 / (45 * π/180) ≈ 153 studs. With lean (50 deg/s additive), total max turn rate = 95 deg/s, radius ≈ 72 studs for committed lean-turns.

**Global mouse constants — add after `VehicleMaxTiltLerp`:**

```lua
CombatConfig.VehicleMouseSensitivity = 0.7
CombatConfig.VehicleMouseRangeX = 0.18
CombatConfig.VehicleMouseRangeY = 0.06
CombatConfig.VehicleMouseCenteringRate = 4.5
```

Tuning notes:
- `VehicleMouseSensitivity = 0.7`: delta-to-pixel scaling. Less than 1:1 to prevent twitchy steering. At 0.7, moving the mouse 100 physical pixels moves the virtual cursor 70 pixels.
- `VehicleMouseRangeX = 0.18`: max horizontal cursor range as fraction of viewport width per side. At 1920px, cursor can go ±346 pixels from center. This is the full-steer zone — reaching the edge means full `steerX = ±1`.
- `VehicleMouseRangeY = 0.06`: vertical range fraction. At 1080px, cursor can go ±65 pixels vertically. Enough room for future weapon aiming without encouraging big vertical sweeps.
- `VehicleMouseCenteringRate = 4.5`: spring-return speed. When the player stops moving the mouse, the cursor drifts back to center at this exponential rate. At 4.5, after 0.3s idle the cursor is at ~26% of its peak displacement. Smooth, not snappy.

### 3. CombatHUD.luau — Vehicle cursor control

**Add new function after `setCursorDotPosition` (after line 705):**

```lua
function CombatHUD.showVehicleCursor(visible: boolean)
	if cursorDot ~= nil then
		cursorDot.Visible = visible
		if not visible then
			cursorDot.BackgroundColor3 = Color3.new(1, 1, 1)
		end
	end
end
```

This controls the cursor dot independently of the crosshair. Needed because `showCrosshair(false)` (called in `enterVehicleMode`) hides both the crosshair text AND the cursor dot. The vehicle needs the dot visible without the crosshair.

### 4. VehicleClient.luau — Mouse locking + virtual cursor + steerX rework

**New state variables (add near line 40, after `inputAccumulator`):**

```lua
local virtualCursorX = 0
local virtualCursorY = 0
local savedMouseBehavior: Enum.MouseBehavior? = nil
local savedMouseIconEnabled: boolean? = nil
```

**New function: `activateVehicleMouse` (add before `enterVehicleMode`):**

```lua
local function activateVehicleMouse()
	savedMouseBehavior = UserInputService.MouseBehavior
	savedMouseIconEnabled = UserInputService.MouseIconEnabled
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	UserInputService.MouseIconEnabled = false
	virtualCursorX = 0
	virtualCursorY = 0
end
```

Pattern matches `activateTurretCameraAndMouse` in WeaponClient.luau (lines 1116-1127). Saves previous state, locks mouse to center, hides system cursor, resets virtual cursor to center (straight steering on entry).

**New function: `restoreVehicleMouse` (add after `activateVehicleMouse`):**

```lua
local function restoreVehicleMouse()
	UserInputService.MouseBehavior = savedMouseBehavior or Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = if savedMouseIconEnabled ~= nil then savedMouseIconEnabled else true
	savedMouseBehavior = nil
	savedMouseIconEnabled = nil
end
```

**New function: `updateVirtualCursor` (add after `restoreVehicleMouse`):**

```lua
local function updateVirtualCursor(dt: number)
	local mouseDelta = UserInputService:GetMouseDelta()
	local sensitivity = CombatConfig.VehicleMouseSensitivity
	if type(sensitivity) ~= "number" or sensitivity <= 0 then
		sensitivity = 0.7
	end

	virtualCursorX += mouseDelta.X * sensitivity
	virtualCursorY += mouseDelta.Y * sensitivity

	-- Self-centering: spring return toward center when no active delta
	local centeringRate = CombatConfig.VehicleMouseCenteringRate
	if type(centeringRate) ~= "number" or centeringRate <= 0 then
		centeringRate = 4.5
	end
	local centerAlpha = 1 - math.exp(-centeringRate * dt)
	virtualCursorX *= (1 - centerAlpha)
	virtualCursorY *= (1 - centerAlpha)

	-- Clamp to configured screen range
	local camera = Workspace.CurrentCamera
	if camera ~= nil then
		local rangeX = CombatConfig.VehicleMouseRangeX
		if type(rangeX) ~= "number" or rangeX <= 0 then
			rangeX = 0.18
		end
		local rangeY = CombatConfig.VehicleMouseRangeY
		if type(rangeY) ~= "number" or rangeY <= 0 then
			rangeY = 0.06
		end

		local maxX = camera.ViewportSize.X * rangeX
		local maxY = camera.ViewportSize.Y * rangeY
		virtualCursorX = math.clamp(virtualCursorX, -maxX, maxX)
		virtualCursorY = math.clamp(virtualCursorY, -maxY, maxY)

		-- Update HUD cursor dot position
		local screenCenter = camera.ViewportSize * 0.5
		CombatHUD.setCursorDotPosition(Vector2.new(
			screenCenter.X + virtualCursorX,
			screenCenter.Y + virtualCursorY
		))
	end
end
```

The virtual cursor:
- Accumulates mouse deltas (locked center means GetMouseDelta returns relative movement)
- Self-centers via exponential decay (steering wheel spring-return feel)
- Clamps to the configured horizontal band
- Updates the HUD cursor dot every frame

Self-centering math: `virtualCursorX *= (1 - centerAlpha)` where `centerAlpha = 1 - exp(-rate * dt)`. This is frame-rate-independent exponential decay toward 0. Active mouse deltas (added each frame) overcome the centering naturally. When the player stops moving the mouse, the cursor smoothly returns to center and the speeder straightens out.

**Modify `readInputPayload` (lines 75-107) — replace steerX computation:**

Current steerX block (lines 92-100):
```lua
	local steerX = 0
	local camera = Workspace.CurrentCamera
	if camera ~= nil then
		local mousePosition = UserInputService:GetMouseLocation()
		local viewportSize = camera.ViewportSize
		local screenCenterX = viewportSize.X * 0.5
		local denominator = math.max(1, screenCenterX * 0.7)
		steerX = math.clamp((mousePosition.X - screenCenterX) / denominator, -1, 1)
	end
```

New:
```lua
	local steerX = 0
	local camera = Workspace.CurrentCamera
	if camera ~= nil then
		local rangeX = CombatConfig.VehicleMouseRangeX
		if type(rangeX) ~= "number" or rangeX <= 0 then
			rangeX = 0.18
		end
		local maxX = math.max(1, camera.ViewportSize.X * rangeX)
		steerX = math.clamp(virtualCursorX / maxX, -1, 1)
	end
```

`steerX` is now derived from the virtual cursor position divided by the max range. At center: 0. At the edge: ±1. The value is still -1 to +1, so the server-side heading computation works unchanged.

**Modify RenderStepped callback in `enterVehicleMode` (lines 155-182):**

Insert `updateVirtualCursor(dt)` at the start of the callback, right after the early-exit checks (after line 163):

```lua
		updateVirtualCursor(dt)
```

This must run BEFORE `readInputPayload()` (line 167) so the virtual cursor is up-to-date when steerX is computed.

**Modify `enterVehicleMode` (line 141) — add mouse activation:**

After `activeVehicleRenderModel = VehicleVisualSmoother.activate(vehicleModel)` (line 152) and before the RenderStepped connection (line 154), insert:

```lua
	activateVehicleMouse()
```

After `CombatHUD.showCrosshair(false)` (line 190), insert:
```lua
	CombatHUD.showVehicleCursor(true)
```

**Modify `exitVehicleMode` (line 121) — add mouse restoration:**

After `VehicleCamera.deactivate()` (line 129), insert:

```lua
	restoreVehicleMouse()
	CombatHUD.showVehicleCursor(false)
```

### 5. VehicleServer.luau — Speed-dependent turn rate

**Modify heading computation (lines 485-490).**

Current:
```lua
	local steerScale = if canUseGroundDrive then 1 else 0.55
	local mouseSteerDelta = math.rad(state.inputSteerX * state.config.turnSpeed * steerScale) * dt
```

New:
```lua
	local steerScale = if canUseGroundDrive then 1 else 0.55
	local speedFractionForTurn = math.clamp(horizontalSpeed / math.max(1, state.config.maxSpeed), 0, 1)
	local effectiveTurnSpeed = state.config.turnSpeedLow + (state.config.turnSpeedHigh - state.config.turnSpeedLow) * speedFractionForTurn
	local mouseSteerDelta = math.rad(state.inputSteerX * effectiveTurnSpeed * steerScale) * dt
```

Note: `horizontalSpeed` is already computed on line 487. Move it BEFORE this block (or compute it earlier). Currently:
```lua
-- line 487:
local horizontalSpeed = Vector3.new(state.velocity.X, 0, state.velocity.Z).Magnitude
```

This line must come before the `speedFractionForTurn` computation. If it's currently AFTER the heading computation, move it before. Check the actual line order and ensure `horizontalSpeed` is available.

The interpolation `turnSpeedLow + (turnSpeedHigh - turnSpeedLow) * speedFraction` gives:
- At speed 0: `120 + (45-120) * 0 = 120` deg/s (full agility)
- At speed 60: `120 + (45-120) * 0.5 = 82.5` deg/s (moderate)
- At speed 120: `120 + (45-120) * 1.0 = 45` deg/s (wide turns)

**Update debug print (lines 830-831) — add effective turn rate:**

Change the `[P5_SPEED]` print to include the computed turn rate:

Current:
```lua
			print(string.format("[P5_SPEED] vehicleId=%s speed=%.1f", state.vehicleId, horizontalSpeed))
```

New:
```lua
			local debugTurnFraction = math.clamp(horizontalSpeed / math.max(1, state.config.maxSpeed), 0, 1)
			local debugTurnSpeed = state.config.turnSpeedLow + (state.config.turnSpeedHigh - state.config.turnSpeedLow) * debugTurnFraction
			print(string.format("[P5_SPEED] vehicleId=%s speed=%.1f turnRate=%.0f", state.vehicleId, horizontalSpeed, debugTurnSpeed))
```

---

## What Does NOT Change

- **VehicleCamera.luau** — no changes. Camera tracks `VehicleHeading` attribute and model position. The mouse rework changes how `steerX` is produced, not how heading is consumed. The camera will naturally feel smoother because the cursor centering produces smoother steerX values.
- **VehicleVisualSmoother.luau** — no changes.
- **HoverPhysics.luau** — no changes.
- **CollisionHandler.luau** — no changes.
- **VehicleServer input handler** — no changes. It still receives `steerX` as a -1 to +1 value. The server doesn't know or care how the client generated it.
- **Lean system** — unchanged. `leanTurnRate` and `leanSteerDelta` are NOT speed-scaled by this change (they already have their own `leanSpeedFraction` gating). The lean is additive on top of the speed-dependent mouse steering.

---

## Data Flow Summary

```
CLIENT (VehicleClient):
  Mouse locked to center (LockCenter)
  GetMouseDelta() → accumulate into virtualCursorX/Y
  Self-centering: virtualCursor decays toward 0 (rate 4.5)
  Clamp: X ±18% viewport width, Y ±6% viewport height
  steerX = virtualCursorX / maxX (gives -1 to +1)
  HUD: cursor dot drawn at screen center + virtualCursor offset

SERVER (VehicleServer):
  speedFraction = horizontalSpeed / maxSpeed
  effectiveTurnSpeed = lerp(turnSpeedLow, turnSpeedHigh, speedFraction)
  mouseSteerDelta = steerX * effectiveTurnSpeed * steerScale * dt
  heading -= mouseSteerDelta + leanSteerDelta (lean unchanged)

COMBINED FEEL:
  Standstill: 120 deg/s mouse, 0 deg/s lean = 120 total
  Half speed: 82 deg/s mouse, 25 deg/s lean = 107 total
  Max speed: 45 deg/s mouse, 50 deg/s lean = 95 total
  → Lean becomes RELATIVELY more important at high speed (55% of turn at max speed vs 0% at standstill)
  → This naturally incentivizes using A/D for aggressive cornering at speed
```

---

## Test Packet

### AI Build Prints

The existing `[P5_SPEED]` print is updated with `turnRate` (see change 5). No new print tags.

### Pass/Fail Conditions

**Test 1 — Mouse locked on vehicle entry:**
- Setup: Enter the speeder (sit in driver seat)
- PASS if: system cursor disappears, custom cursor dot appears at screen center, mouse physically stays centered (LockCenter behavior)
- FAIL if: system cursor still visible, or cursor dot not visible, or mouse roams freely

**Test 2 — Mouse restored on vehicle exit:**
- Setup: Exit the speeder (press F)
- PASS if: system cursor reappears, cursor dot disappears, mouse roams freely again
- FAIL if: cursor stays locked, or cursor dot remains visible

**Test 3 — Virtual cursor horizontal range:**
- Setup: In speeder, move mouse far to the right
- PASS if: cursor dot stops at the right edge of the defined range (~18% of viewport width from center), does not go further. `steerX` should max at 1.0 in the payload.
- FAIL if: cursor goes to screen edge, or cursor range is visually too wide/narrow

**Test 4 — Self-centering:**
- Setup: In speeder, push mouse right to create steerX ≈ 0.8, then stop moving mouse
- PASS if: cursor dot smoothly drifts back toward center over ~0.5-1 second, speeder gradually straightens
- FAIL if: cursor snaps to center instantly, or cursor stays where it was without returning

**Test 5 — Speed-dependent turn rate:**
- Setup: Drive straight, note how fast the speeder turns when pushing mouse fully right at ~20 studs/s
- Action: Accelerate to ~100 studs/s, push mouse fully right again
- PASS if: turn is noticeably wider (slower angular rate) at high speed. `[P5_SPEED] turnRate` shows ~120 at low speed, ~50 at high speed.
- FAIL if: turn rate feels the same at all speeds, or `turnRate` doesn't change

**Test 6 — Lean remains effective at high speed:**
- Setup: Drive at max speed, full mouse right + hold D
- PASS if: turn rate is noticeably faster with lean than mouse alone. Lean still provides meaningful additional turning at max speed.
- FAIL if: lean adds nothing at high speed, or lean is overpowered

**Test 7 — Low-speed agility:**
- Setup: Drive at ~10 studs/s, turn sharply with mouse
- PASS if: speeder turns tightly (near-pivot), feels agile. Turn rate should be close to 120 deg/s.
- FAIL if: speeder feels sluggish at low speed

### MCP Procedure

Default procedure. No deviations.

### Expected Summary Format

```
[P5_SPEED] vehicleId=<id> speed=<studs/s> turnRate=<deg/s>
```
