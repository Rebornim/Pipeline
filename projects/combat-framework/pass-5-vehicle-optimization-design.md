# Pass 5 Fix Plan: Vehicle Network Optimization (Phase 2)

Date: 2026-02-20
Type: Fix Plan — network/performance (comprehensive)
Scope: VehicleServer.luau, HoverPhysics.luau, VehicleVisualSmoother.luau, new RemoteVehicleSmoother.luau, CombatConfig.luau, CombatTypes.luau

---

## Context

Phase 1 (attribute replication optimization) is already deployed:
- Adaptive attribute replication: 20Hz Active, 5Hz Settling, 0Hz Dormant
- Deadbands, three-state machine, dormancy with physics skip
- Config constants in CombatConfig

Phase 1 results: attribute cost reduced but total bandwidth still **15 KB/s stationary, 30-45 KB/s moving**. Unacceptable.

---

## Root Cause: SetPrimaryPartCFrame Replicates ALL Part CFrames

The dominant bandwidth cost is NOT attributes. It's `SetPrimaryPartCFrame(nextCFrame)` (VehicleServer.luau line 1046).

`SetPrimaryPartCFrame` internally writes `.CFrame` on **every BasePart** in the model to maintain relative positioning. Each `.CFrame` property change on a server-owned Anchored part replicates to all clients.

Cost formula: `N_parts × 60Hz × ~50 bytes_per_CFrame_change = bandwidth`

A speeder model with 10 parts: `10 × 60 × 50 = 30,000 bytes/s = ~30 KB/s`. Matches observation.

Even stationary vehicles generate ~15 KB/s because hover spring micro-oscillation and tilt correction cause continuous small CFrame updates across all parts.

There are 3 `SetPrimaryPartCFrame` call sites:
1. **Line 1046**: Main physics loop — every Heartbeat for every active vehicle
2. **Line 269**: `enforceTerrainFloor` — called after main CFrame write, conditional
3. **Line 1233**: `registerVehicle` — one-time startup lift, negligible

---

## Solution: Three-Step Approach

### Step A — Weld Conversion (server-side, minimal changes, biggest win)

Convert multi-part CFrame replication into single-part replication using WeldConstraints.

**Mechanism:**
- At registration, create a WeldConstraint from PrimaryPart to every other BasePart in the model
- Set non-primary parts: `Anchored = false`, `Massless = true`
- PrimaryPart stays `Anchored = true`
- Replace `SetPrimaryPartCFrame(cf)` with `state.primaryPart.CFrame = cf`
- Roblox constraint solver positions welded parts on each client from stored offsets
- Only PrimaryPart's CFrame replicates. Child parts are positioned locally by the constraint solver.

**Bandwidth after Step A:** 1 part × 60Hz × ~50 bytes = ~3 KB/s active. Down from 30-45.

### Step B — CFrame Rate Cap + Internal Position Tracking (server-side, further reduction)

Decouple 60Hz physics simulation from CFrame writes to the model.

**Mechanism:**
- Physics simulation stores its output in `state.simulatedCFrame` instead of writing to the model every frame
- All physics reads (hover points, position, orientation) use `state.simulatedCFrame` and precomputed local offsets instead of reading from model parts
- CFrame write to `state.primaryPart.CFrame` happens at a rate-capped interval (20Hz Active, 5Hz Settling, 0Hz Dormant)
- A position deadband suppresses CFrame writes when the vehicle hasn't moved significantly

**Bandwidth after Step B:** 1 part × 20Hz × ~50 bytes = ~1 KB/s. Plus attributes ~0.8 KB/s. Total ~2 KB/s active.

### Step C — Remote Vehicle Interpolation (client-side, additive)

Prevent other players' vehicles from looking like a slideshow at 20Hz CFrame updates.

**Mechanism:**
- New client module `RemoteVehicleSmoother` watches for vehicle models via CollectionService ("VehicleEntity" tag)
- For vehicles NOT driven by the local player: create a visual clone, hide the source model, interpolate the clone's CFrame between server snapshots at client frame rate
- Local player's vehicle is unaffected (already handled by existing VehicleVisualSmoother)

**Visual result:** Remote vehicles appear smooth (~60fps) despite receiving CFrame updates at 20Hz.

---

## Step A: Weld Conversion — Detailed Changes

### A1. VehicleServer.luau — registerVehicle: Create WeldConstraints

After the state initializer is created (after line 1308: `settlingStartTick = 0,`), before the seat connection setup, add weld conversion:

```lua
-- Weld Conversion: make only PrimaryPart replicate CFrame.
-- Create WeldConstraints from PrimaryPart to all other BaseParts.
-- Child parts become Anchored=false, Massless=true so the constraint
-- solver positions them locally on each client.
for _, descendant in ipairs(instance:GetDescendants()) do
    if descendant:IsA("BasePart") and descendant ~= primaryPart then
        local weld = Instance.new("WeldConstraint")
        weld.Part0 = primaryPart
        weld.Part1 = descendant
        weld.Parent = descendant
        descendant.Anchored = false
        descendant.Massless = true
    end
end
```

This runs once per vehicle at registration. The WeldConstraint captures the current relative offset between Part0 and Part1 at creation time.

**Important**: This must happen AFTER the startup lift (line 1233) so the offset is captured at the correct position. The current code order already ensures this — the lift happens at line 1233, state creation is at line 1267.

### A2. VehicleServer.luau — Replace SetPrimaryPartCFrame with PrimaryPart.CFrame assignment

Three locations:

**Line 1046** (main physics loop):
```lua
-- OLD:
state.instance:SetPrimaryPartCFrame(nextCFrame)
-- NEW:
state.primaryPart.CFrame = nextCFrame
```

**Line 269** (enforceTerrainFloor):
```lua
-- OLD:
state.instance:SetPrimaryPartCFrame(state.primaryPart.CFrame + Vector3.new(0, correction, 0))
-- NEW:
state.primaryPart.CFrame = state.primaryPart.CFrame + Vector3.new(0, correction, 0)
```

**Line 1233** (registerVehicle startup lift) — keep as `SetPrimaryPartCFrame` because welds haven't been created yet at this point. All parts still Anchored. This is correct.

### A3. VehicleVisualSmoother.luau — stripCloneForVisuals: handle welded parts

The visual clone copies the model including WeldConstraints. Since `stripCloneForVisuals` sets all BaseParts to `Anchored = true`, the WeldConstraints become inert (both parts Anchored). The clone is positioned via `PivotTo` which explicitly moves all parts. No functional change needed.

However, remove the now-inert WeldConstraints from the clone to avoid clutter:

In `stripCloneForVisuals`, add a case:

```lua
if descendant:IsA("WeldConstraint") then
    descendant:Destroy()
    continue
end
```

Add this after the existing `Script`/`LocalScript`/`ModuleScript` destroy block (before the `BasePart` handling).

---

## Step B: CFrame Rate Cap + Internal Position Tracking — Detailed Changes

### B1. VehicleRuntimeStateInternal — New fields

Add to the type definition (after `settlingStartTick: number`):

```lua
simulatedCFrame: CFrame,
lastCFrameWriteTick: number,
hoverPointLocalOffsets: { CFrame },
```

### B2. registerVehicle — Initialize new fields and precompute hover offsets

In the state initializer block (after `settlingStartTick = 0`), add:

```lua
simulatedCFrame = primaryPart.CFrame,
lastCFrameWriteTick = 0,
hoverPointLocalOffsets = {},
```

After the weld conversion block (from Step A), precompute hover point local offsets:

```lua
-- Precompute hover point offsets relative to PrimaryPart.
-- Physics reads these to derive world positions without reading stale model parts.
local localOffsets: { CFrame } = {}
for i, hp in ipairs(sortedHoverPoints) do
    localOffsets[i] = primaryPart.CFrame:Inverse() * hp.CFrame
end
state.hoverPointLocalOffsets = localOffsets
```

### B3. HoverPhysics.luau — Change signature to accept world positions

**Replace entire function signature and position-reading logic.**

Old signature:
```lua
function HoverPhysics.step(
    hoverPoints: { BasePart },
    vehicleModel: Model,
    currentVelocityY: number,
    hoverHeight: number,
    springStiffness: number,
    springDamping: number,
    gravity: number,
    _dt: number
): (number, Vector3, number)
```

New signature:
```lua
function HoverPhysics.step(
    hoverPointPositions: { Vector3 },
    vehicleModel: Model,
    currentVelocityY: number,
    hoverHeight: number,
    springStiffness: number,
    springDamping: number,
    gravity: number,
    _dt: number
): (number, Vector3, number)
```

Inside the function, replace the per-point loop:

Old:
```lua
for _, hp in ipairs((hoverPoints :: { Instance })) do
    local origin: Vector3
    if hp:IsA("Attachment") then
        origin = hp.WorldPosition
    elseif hp:IsA("BasePart") then
        origin = hp.Position
    else
        continue
    end
    local probeOrigin = origin + Vector3.new(0, probeLift, 0)
    -- ... rest unchanged
```

New:
```lua
for _, origin in ipairs(hoverPointPositions) do
    local probeOrigin = origin + Vector3.new(0, probeLift, 0)
    -- ... rest unchanged
```

Also update the point count:
```lua
-- OLD:
local pointCount = math.max(#hoverPoints, 1)
-- NEW:
local pointCount = math.max(#hoverPointPositions, 1)
```

### B4. VehicleServer.luau — Helper to compute hover point world positions

Add a local helper function near the top of the file (after the existing helper functions):

```lua
local function computeHoverPointWorldPositions(state: VehicleRuntimeStateInternal): { Vector3 }
    local positions: { Vector3 } = {}
    for i, localOffset in ipairs(state.hoverPointLocalOffsets) do
        positions[i] = (state.simulatedCFrame * localOffset).Position
    end
    return positions
end
```

### B5. VehicleServer.luau — stepSingleVehicle: Use simulatedCFrame for all position reads

All reads of `state.primaryPart.Position` and `state.primaryPart.CFrame` within `stepSingleVehicle` must change to `state.simulatedCFrame`.

**Specific substitutions inside stepSingleVehicle:**

1. **Line 969** — current position for movement:
```lua
-- OLD:
local currentPosition = state.primaryPart.Position
-- NEW:
local currentPosition = state.simulatedCFrame.Position
```

2. **Line 1000** — tilt computation (unbanked CFrame):
```lua
-- OLD:
local unbankedCurrentCFrame = state.primaryPart.CFrame
-- NEW:
local unbankedCurrentCFrame = state.simulatedCFrame
```

3. **Line 1026** — fallback forward vector:
```lua
-- OLD:
alignedForward = projectVectorOntoPlane(state.primaryPart.CFrame.LookVector, smoothedUp)
-- NEW:
alignedForward = projectVectorOntoPlane(state.simulatedCFrame.LookVector, smoothedUp)
```

4. **HoverPhysics.step call** — pass computed positions instead of BaseParts. Find the existing call (should be in the physics section where `verticalAccel, averageNormal, groundedCount` are assigned) and change:
```lua
-- OLD:
local verticalAccel, averageNormal, groundedCount = HoverPhysics.step(
    state.hoverPoints, state.instance, state.velocity.Y,
    state.config.hoverHeight, state.config.springStiffness, state.config.springDamping,
    state.config.gravity, dt
)
-- NEW:
local hoverPointWorldPositions = computeHoverPointWorldPositions(state)
local verticalAccel, averageNormal, groundedCount = HoverPhysics.step(
    hoverPointWorldPositions, state.instance, state.velocity.Y,
    state.config.hoverHeight, state.config.springStiffness, state.config.springDamping,
    state.config.gravity, dt
)
```

5. **measureAverageHoverPointDistance call** (anti-sink clearance check, around line 975) — pass computed positions. See B7 for the function refactor.

6. **At the end of stepSingleVehicle** — after computing `nextCFrame`, store it and rate-cap the write:

Replace the direct CFrame write from Step A with:

```lua
-- OLD (from Step A):
state.primaryPart.CFrame = nextCFrame

-- NEW:
state.simulatedCFrame = nextCFrame
```

Then, after calling `enforceTerrainFloor` (which now modifies `state.simulatedCFrame` — see B6), add the rate-capped write:

```lua
-- Rate-capped CFrame write to model for replication
local cframeWriteRate = if state.replicationState == "Settling"
    then readConfigNumber("VehicleCFrameWriteRateSettling", 5)
    else readConfigNumber("VehicleCFrameWriteRateActive", 20)
local cframeWriteInterval = 1 / math.max(1, cframeWriteRate)
local now = tick()
if (now - state.lastCFrameWriteTick) >= cframeWriteInterval then
    state.primaryPart.CFrame = state.simulatedCFrame
    state.lastCFrameWriteTick = now
end
```

### B6. VehicleServer.luau — enforceTerrainFloor: Use simulatedCFrame

Replace the body of `enforceTerrainFloor` to read from `state.simulatedCFrame` and hover point offsets, and write to `state.simulatedCFrame` instead of the model:

```lua
local function enforceTerrainFloor(state: VehicleRuntimeStateInternal, rayParams: RaycastParams)
    local probeLift = math.max(1.5, state.config.hoverHeight * 0.8)
    local rayLength = math.max(10, state.config.hoverHeight * 4) + probeLift
    local worstPenetration = 0

    for i, localOffset in ipairs(state.hoverPointLocalOffsets) do
        local hoverWorldPos = (state.simulatedCFrame * localOffset).Position
        local origin = hoverWorldPos + Vector3.new(0, probeLift, 0)
        local hit = Workspace:Raycast(origin, Vector3.new(0, -rayLength, 0), rayParams)
        if hit ~= nil then
            local penetration = math.max(0, hit.Position.Y - hoverWorldPos.Y)
            if penetration > worstPenetration then
                worstPenetration = penetration
            end
        end
    end

    if worstPenetration > 0.01 then
        local correction = worstPenetration + 0.05
        state.simulatedCFrame = state.simulatedCFrame + Vector3.new(0, correction, 0)
        if state.velocity.Y < 0 then
            state.velocity = Vector3.new(state.velocity.X, 0, state.velocity.Z)
        end
    end
end
```

### B7. VehicleServer.luau — measureAverageHoverPointDistance: Accept world positions

Change the function signature and usage:

```lua
-- OLD:
local function measureAverageHoverPointDistance(vehicleModel: Model, hoverPoints: { BasePart }, maxDistance: number): number?
-- NEW:
local function measureAverageHoverPointDistance(vehicleModel: Model, hoverPointPositions: { Vector3 }, maxDistance: number): number?
```

Inside, replace the per-point loop:
```lua
-- OLD:
for _, hoverPoint in ipairs(hoverPoints) do
    local probeOrigin = hoverPoint.Position + Vector3.new(0, probeLift, 0)
-- NEW:
for _, hoverPointPos in ipairs(hoverPointPositions) do
    local probeOrigin = hoverPointPos + Vector3.new(0, probeLift, 0)
```

And the corrected distance:
```lua
-- OLD:
totalDistance += math.max(0, result.Distance - probeLift)
-- (no change needed — Distance is from probe origin, offset already applied)
```

**Update callers:**

In `stepSingleVehicle` (anti-sink clearance, around line 975):
```lua
-- OLD:
local avgHoverDistance = measureAverageHoverPointDistance(state.instance, state.hoverPoints, math.max(12, state.config.hoverHeight * 4))
-- NEW:
local avgHoverDistance = measureAverageHoverPointDistance(state.instance, hoverPointWorldPositions, math.max(12, state.config.hoverHeight * 4))
```

In `registerVehicle` (startup clearance, around line 1229):
```lua
-- OLD:
local averageHoverDistance = measureAverageHoverPointDistance(instance, sortedHoverPoints, math.max(20, vehicleConfig.hoverHeight * 6))
-- NEW (compute positions from actual parts since simulatedCFrame doesn't exist yet):
local registrationHoverPositions: { Vector3 } = {}
for i, hp in ipairs(sortedHoverPoints) do
    registrationHoverPositions[i] = hp.Position
end
local averageHoverDistance = measureAverageHoverPointDistance(instance, registrationHoverPositions, math.max(20, vehicleConfig.hoverHeight * 6))
```

### B8. VehicleServer.luau — Other position reads using simulatedCFrame

These functions read `state.primaryPart.Position` and need to use `state.simulatedCFrame.Position`:

1. **`isWaterSupported`** (line 382):
```lua
-- OLD:
if hasWaterAtPosition(state.primaryPart.Position) then
-- NEW:
if hasWaterAtPosition(state.simulatedCFrame.Position) then
```

Also the secondary raycast in `isWaterSupported` that uses `state.primaryPart.Position`:
```lua
-- OLD:
local result = Workspace:Raycast(state.primaryPart.Position, Vector3.new(0, -maxDistance, 0), params)
-- NEW:
local result = Workspace:Raycast(state.simulatedCFrame.Position, Vector3.new(0, -maxDistance, 0), params)
```

2. **`detectCrest`** (line 502):
```lua
-- OLD:
local origin = state.primaryPart.Position
-- NEW:
local origin = state.simulatedCFrame.Position
```

3. **Driver enter stabilization Y check** (line 881):
```lua
-- OLD:
local currentY = state.primaryPart.Position.Y
-- NEW:
local currentY = state.simulatedCFrame.Position.Y
```

4. **Fall damage position** (line 917) — cosmetic, can stay on `state.primaryPart.Position` or change. Change for consistency:
```lua
-- OLD:
HealthManager.applyDamage(state.entityId, damage, "impact", "", state.primaryPart.Position, true)
-- NEW:
HealthManager.applyDamage(state.entityId, damage, "impact", "", state.simulatedCFrame.Position, true)
```

5. **`measureHoverHeight`** (line 216) — only used for debug prints. Change for consistency:
```lua
-- OLD:
local result = Workspace:Raycast(state.primaryPart.Position, Vector3.new(0, -maxDistance, 0), params)
-- NEW:
local result = Workspace:Raycast(state.simulatedCFrame.Position, Vector3.new(0, -maxDistance, 0), params)
```

### B9. VehicleServer.luau — updateDriverFromSeat: Sync simulatedCFrame on entry

In the driver-entered branch, after `state.driverEnterBaseY = state.primaryPart.Position.Y`, add:

```lua
state.simulatedCFrame = state.primaryPart.CFrame
state.lastCFrameWriteTick = 0
```

This syncs the internal simulation with the model's actual position on re-entry (handles case where model drifted during dormancy or Roblox physics interference).

The `driverEnterBaseY` line should also use simulatedCFrame:
```lua
-- OLD:
state.driverEnterBaseY = state.primaryPart.Position.Y
-- NEW:
state.driverEnterBaseY = state.simulatedCFrame.Position.Y
```

Wait — on re-entry from dormancy, `simulatedCFrame` might be stale (last physics position before dormancy). The model's actual CFrame is the ground truth. So the sync above is necessary: read from model first, then use simulatedCFrame going forward. The order should be:

```lua
state.simulatedCFrame = state.primaryPart.CFrame  -- sync from model
state.driverEnterBaseY = state.simulatedCFrame.Position.Y
state.lastCFrameWriteTick = 0
```

### B10. CollisionHandler.luau — No changes

`CollisionHandler.checkObstacles` and `checkVehicleCollisions` read `state.primaryPart.Position`. With 20Hz CFrame writes, this position is stale by up to 50ms. At max speed (120 studs/s), that's ~6 studs of position error.

This is acceptable for collision detection:
- **Obstacle collisions**: The raycast looks ahead along the velocity vector with a configurable lookahead. The staleness adds a ~6 stud offset to the origin but the lookahead still catches obstacles. At worst, collision response fires one frame late.
- **Vehicle-vehicle collisions**: Both vehicles' positions are stale by similar amounts. Relative position error is small.

No changes needed. If collision quality degrades visibly during testing, the fix would be to pass `state.simulatedCFrame.Position` — but this is unlikely.

### B11. CombatConfig.luau — CFrame rate cap constants

Add after the existing replication constants:

```lua
CombatConfig.VehicleCFrameWriteRateActive = 20
CombatConfig.VehicleCFrameWriteRateSettling = 5
CombatConfig.VehicleCFramePositionDeadband = 0.01
```

---

## Step C: Remote Vehicle Interpolation — Detailed Changes

### C1. New file: src/Client/Vehicles/RemoteVehicleSmoother.luau

Purpose: interpolate non-local vehicle models between server CFrame updates so they appear smooth at client frame rate.

```
--!strict

Module: RemoteVehicleSmoother

Dependencies:
- CollectionService (to watch for "VehicleEntity" tagged models)
- Players (to identify local player's vehicle)
- RunService (RenderStepped)
- Workspace

Module-scoped state:
- trackedVehicles: { [Model]: RemoteVehicleEntry }
- renderConnection: RBXScriptConnection?
- localVehicleModel: Model? (set by VehicleClient when entering/exiting)

Type RemoteVehicleEntry:
    sourceModel: Model
    visualClone: Model
    sourceTransparency: { [BasePart]: number }
    lastSourceCFrame: CFrame
    smoothedCFrame: CFrame
    isActive: boolean
```

**Constants:**
```lua
local SMOOTHING_ALPHA = 16   -- same as VehicleVisualSmoother
local MAX_SNAP_DISTANCE = 40 -- teleport guard
local VISUALS_FOLDER_NAME = "CombatClientVisuals"  -- reuse existing folder
```

**Functions:**

`RemoteVehicleSmoother.setLocalVehicle(model: Model?)`:
- Called by VehicleClient on enter/exit
- Sets `localVehicleModel`
- If model matches a tracked vehicle, deactivate that tracking (it's now local)

`RemoteVehicleSmoother.init()`:
- Get all existing "VehicleEntity" tagged instances, call `onVehicleAdded` for each
- Connect `CollectionService:GetInstanceAddedSignal("VehicleEntity")` → `onVehicleAdded`
- Connect `CollectionService:GetInstanceRemovedSignal("VehicleEntity")` → `onVehicleRemoved`
- Connect `RunService.RenderStepped` → `stepAll`

`local function onVehicleAdded(instance: Instance)`:
- If not a Model, skip
- If instance == localVehicleModel, skip
- Check if model has a PrimaryPart. If not, skip.
- Check if `VehicleSpeed` attribute exists (vehicle is registered). If not, watch for it via `GetAttributeChangedSignal("VehicleSpeed")`.
- Create entry in trackedVehicles but don't create visual clone yet
- When VehicleSpeed first appears (vehicle becomes active): create visual clone

`local function activateRemoteVehicle(entry: RemoteVehicleEntry)`:
- Clone source model
- Strip clone for visuals (Anchored=true, CanCollide=false, CanQuery=false, CanTouch=false, remove scripts, remove WeldConstraints)
- Parent clone to CombatClientVisuals folder
- Hide source model parts via LocalTransparencyModifier = 1
- Store initial CFrame
- Set isActive = true

`local function deactivateRemoteVehicle(entry: RemoteVehicleEntry)`:
- Restore source model part transparency
- Destroy visual clone
- Set isActive = false

`local function onVehicleRemoved(instance: Instance)`:
- If tracked, deactivate and remove from trackedVehicles

`local function stepAll(dt: number)`:
- For each active entry in trackedVehicles:
  - If sourceModel.Parent == nil, deactivate and remove, continue
  - If sourceModel == localVehicleModel, deactivate (local smoother handles it), continue
  - Read source PrimaryPart.CFrame
  - Compute smoothed CFrame: `smoothedCFrame:Lerp(sourceCFrame, 1 - math.exp(-SMOOTHING_ALPHA * clampedDt))`
  - Snap guard: if distance > MAX_SNAP_DISTANCE, snap directly
  - Apply: `visualClone:PivotTo(smoothedCFrame)`

**Key difference from VehicleVisualSmoother:**
- No character cloning (remote player characters are positioned by Roblox)
- No snapshot buffering needed (simpler: just smooth toward latest CFrame)
- Tracks multiple vehicles simultaneously
- No heading/speed attribute forwarding to clone (those are only used by the local camera)

### C2. VehicleClient.luau — Integration

In `enterVehicleMode` (around line 247), after calling `VehicleVisualSmoother.activate`:
```lua
RemoteVehicleSmoother.setLocalVehicle(vehicleModel)
```

In `exitVehicleMode` (around line 175), after calling `VehicleVisualSmoother.deactivate`:
```lua
RemoteVehicleSmoother.setLocalVehicle(nil)
```

### C3. Combat client init — Start RemoteVehicleSmoother

In the client initialization script that sets up VehicleClient (wherever `VehicleClient.init()` is called), add:
```lua
RemoteVehicleSmoother.init()
```

This must run once on client startup. It's independent of whether the local player is in a vehicle.

---

## Bandwidth Summary

| Scenario | Before Phase 1 | After Phase 1 (current) | After Step A | After Step A+B |
|----------|----------------|------------------------|--------------|----------------|
| Active, maneuvering | ~45 KB/s | ~30-45 KB/s | ~3-5 KB/s | ~2 KB/s |
| Active, straight line | ~35 KB/s | ~30-35 KB/s | ~3-4 KB/s | ~1.5 KB/s |
| Stationary on vehicle | ~20 KB/s | ~15 KB/s | ~3 KB/s | ~1 KB/s |
| Parked (dormant) | ~15 KB/s | ~0 KB/s | ~0 KB/s | ~0 KB/s |

Step A provides the largest single improvement (~10x). Step B provides a further ~2x on top. Step C has zero bandwidth impact (client-only visual improvement).

---

## What Does NOT Change

- **VehicleCamera.luau** — no changes. Already staleness-tolerant via heavy smoothing. Reads attributes (rate-capped) and model position (tracks PrimaryPart.CFrame which updates at 20Hz in Step B, but camera smoothing constants 0.2-0.4s are 4-8x longer than the 50ms update interval).
- **VehicleVisualSmoother.luau** — minor: strip WeldConstraints from clone (Step A3). Core interpolation logic unchanged. At 20Hz CFrame input, snapshot buffering with 0.09s delay still works. If smoother feels slightly less responsive, increase `INTERPOLATION_DELAY` from 0.09 to 0.12 via tuning after testing. No code change needed upfront.
- **VehicleClient.luau** — minor: two calls to `RemoteVehicleSmoother.setLocalVehicle` (Step C2). No logic changes.
- **CollisionHandler.luau** — no changes. 50ms position staleness is within collision detection tolerance.
- **CombatTypes.luau** — no changes. New fields are server-internal (`VehicleRuntimeStateInternal`).
- **All existing Phase 1 changes** — attribute replication gating, dormancy state machine, config constants. All remain. Step B adds CFrame rate capping on top.

---

## Fix Sequencing

Build in this order. Each step is independently safe and testable. Stop after any step if bandwidth targets are met.

### Step A: Weld Conversion (changes A1, A2, A3)

**Build order:**
1. Add weld creation in `registerVehicle` (A1)
2. Replace 2 `SetPrimaryPartCFrame` calls with `primaryPart.CFrame =` assignment (A2 — lines 1046, 269)
3. Add WeldConstraint cleanup in `stripCloneForVisuals` (A3)

**Verify:**
- Drive speeder: all physics works identically (hover, steering, collision, lean, tilt)
- Visual: model looks the same (parts don't drift or separate)
- Network: Received stat drops dramatically (expect ~3-5 KB/s active vs ~30-45 before)
- VehicleVisualSmoother: visual clone still works correctly

**Risk:** Very low. WeldConstraints are the standard Roblox approach for multi-part models. Only the replication path changes, not the physics logic.

### Step B: CFrame Rate Cap (changes B1-B11)

**Build order:**
1. Add new state fields and config constants (B1, B11)
2. Initialize new fields in registerVehicle and precompute hover offsets (B2)
3. Add `computeHoverPointWorldPositions` helper (B4)
4. Refactor HoverPhysics.step to accept `{ Vector3 }` (B3)
5. Refactor enforceTerrainFloor to use simulatedCFrame (B6)
6. Refactor measureAverageHoverPointDistance to accept `{ Vector3 }` (B7)
7. Update all position reads in stepSingleVehicle (B5)
8. Update other position reads (B8)
9. Sync simulatedCFrame on driver entry (B9)
10. Add rate-capped CFrame write at end of stepSingleVehicle (B5, final block)

**Verify:**
- Drive speeder: physics feel identical to Step A (same simulation, just CFrame writes are delayed)
- Network: Received stat drops further to ~2 KB/s active
- Camera: smooth, no jitter (VehicleVisualSmoother + VehicleCamera handle 20Hz updates)
- Dormancy: still works, wake from dormancy still works (simulatedCFrame syncs from model on entry)

**Risk:** Moderate. Touches many functions. But changes are mechanical (swap data source, not logic). If something breaks, it's a missed substitution — easy to diagnose via position-mismatch symptoms (vehicle teleporting, hover oscillation, terrain penetration).

### Step C: Remote Vehicle Interpolation (changes C1, C2, C3)

**Build order:**
1. Create RemoteVehicleSmoother.luau (C1)
2. Add integration calls in VehicleClient (C2)
3. Add init call in client startup (C3)

**Verify:**
- Second player's speeder appears smooth from first player's perspective
- Entering/exiting a vehicle doesn't cause visual artifacts on other players' clones
- Multiple remote vehicles tracked simultaneously without issues
- No double-clone conflict with VehicleVisualSmoother (local vehicle excluded via `setLocalVehicle`)

**Risk:** Low. Additive client-side behavior. If RemoteVehicleSmoother fails or has issues, remote vehicles just look like they did before (raw 20Hz updates). No physics or server impact.

---

## Test Packet

### AI Build Prints

Existing: `[P5_DORMANT]` on dormancy entry (already deployed from Phase 1).

Add for Phase 2:
- `[P5_WELD] vehicleId=%s partCount=%d` — print after weld conversion in registerVehicle. `partCount` = number of WeldConstraints created.
- `[P5_CFRAME_WRITE] vehicleId=%s rate=%d` — print once when CFrame write rate changes (on state transition). Helps verify rate cap is active.
- `[P5_REMOTE_SMOOTH] vehicleId=%s activated` / `deactivated` — print in RemoteVehicleSmoother when tracking starts/stops.

### Pass/Fail Conditions

**Test 1 — Step A: Weld integrity:**
- Setup: Spawn speeder, drive at max speed, lean turns, terrain transitions, collisions
- PASS if: model looks visually identical to pre-weld behavior. No parts drifting, separating, or lagging behind PrimaryPart. All physics behavior identical.
- FAIL if: parts separate visually, hover points drift from body, or physics behavior changes

**Test 2 — Step A: Bandwidth reduction:**
- Setup: Drive speeder, check Roblox Received stat
- PASS if: Received ~3-5 KB/s active (down from 30-45). Stationary drops below 5 KB/s.
- FAIL if: Received still above 15 KB/s while driving

**Test 3 — Step B: CFrame rate cap active:**
- Setup: Drive speeder with `[P5_CFRAME_WRITE]` print active
- PASS if: CFrame write rate shows 20Hz. Physics feel identical to Step A. No visual degradation for the local driver.
- FAIL if: vehicle movement feels choppy or jittery to the driver

**Test 4 — Step B: Final bandwidth:**
- Setup: Drive speeder at varying speeds
- PASS if: Received ~2 KB/s active, ~1 KB/s stationary on vehicle, ~0 KB/s dormant
- FAIL if: Received above 5 KB/s while driving

**Test 5 — Step B: Physics accuracy:**
- Setup: Drive speeder over terrain bumps, cliffs, slopes, water, into walls
- PASS if: hover height stable, tilt bobblehead works, landing shake fires, collision deflection works, slope limiting works, water detection works. Identical to pre-rate-cap behavior.
- FAIL if: any physics behavior changes (vehicle sinks into terrain, tilt is wrong, collisions missed)

**Test 6 — Step C: Remote vehicle smoothing:**
- Setup: Two players, one driving. Second player watches.
- PASS if: driving vehicle appears smooth from second player's perspective. No teleporting, no visual clone artifacts.
- FAIL if: remote vehicle looks choppy (20fps stepping visible) or clone artifacts appear

**Test 7 — Step C: Local/remote interaction:**
- Setup: Both players driving simultaneously
- PASS if: each player's own vehicle is smooth (VehicleVisualSmoother), other player's vehicle is smooth (RemoteVehicleSmoother). No conflicts, no double-cloning.
- FAIL if: entering vehicle causes other player's clone to glitch, or local smoother conflicts with remote smoother

**Test 8 — Dormancy still works after full optimization:**
- Setup: Drive, park, wait 3s, re-enter
- PASS if: `[P5_DORMANT]` prints, bandwidth drops to 0, re-entry wakes vehicle immediately, physics resume correctly
- FAIL if: dormancy broken by weld conversion or CFrame rate cap changes

### Network Budget Targets (Final)

| Scenario | Target |
|----------|--------|
| 1 active speeder, maneuvering | < 3 KB/s |
| 1 active speeder, straight line | < 2 KB/s |
| 1 stationary on speeder | < 1.5 KB/s |
| 1 parked speeder (dormant) | ~0 KB/s |
| 1 active + 2 dormant | < 3 KB/s |

### MCP Procedure

Default procedure. No deviations.
