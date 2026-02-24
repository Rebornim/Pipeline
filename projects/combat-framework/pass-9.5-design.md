# Pass 9.5 Design: Bugfix Stabilization

**Depends on:** Pass 9 (walker combat), Passes 1-8
**Scope:** 6 bugs — walker remote visuals, walker seat ejection, lock-on angle break, remote turret rotation, ion whiz sound, heavy vehicle phantom fire.

---

## Bug Root Cause Summary

| # | Bug | Root Cause | Files |
|---|-----|-----------|-------|
| 1 | Remote walker visuals broken (driver floating, head detached, legs frozen) | RemoteVehicleSmoother: leg folder race condition (client activates before server reparents legs to Workspace), PivotTo cascading head back, character clone not following seat | RemoteVehicleSmoother.luau |
| 2 | Walker kicks player out at ~60 studs from spawn | WalkerClient anchors HRP — seat weld can't reposition anchored part, server-side weld stretches as model moves, Roblox ejects at internal distance threshold | WalkerClient.luau, WalkerServer.luau |
| 3 | Lock-on persists when facing away from target | No facing-angle check in TargetingServer — only checks range, mount arc, and LoS | TargetingServer.luau |
| 4 | Remote turret parts don't rotate for other players | WeaponServer writes mount CFrame (replicates), but driven parts (YawOnlyParts, PitchOnlyParts, YawPitchParts, DrivenParts) are only written by WeaponClient (local-only, doesn't replicate) | WeaponServer.luau, WeaponClient.luau |
| 5 | Ion whiz sound plays for shooter on fire | playWhizSound() in ProjectileVisuals has no shooter exclusion — whiz loops on bolt part for all clients including the shooter. Ion whiz asset is particularly loud/noticeable | ProjectileVisuals.luau |
| 6 | Heavy vehicle driver clicks = fire sound + crosshair with no weapon | VehicleClient weapon detection checks entity-level weaponId (includes gunner weapons), doesn't verify the DRIVER specifically has a weapon | VehicleClient.luau |

---

## Build Steps

### Step 1: Walker Seat Stability (Bug 2)

**Problem:** WalkerClient anchors the driver's HumanoidRootPart on activation. When the server writes `PrimaryPart.CFrame` (which cascades to DriverSeat), the seat moves but the anchored HRP stays put. The SeatWeld connecting HRP-to-Seat stretches. Roblox detects the overstretched weld and ejects the character at a distance threshold (~60 studs of accumulated drift).

**File:** `src/Client/Vehicles/WalkerClient.luau`

**Fix: Remove HRP anchoring. Replace with physics suppression.**

In `activate()`, where the code currently does `hrp.Anchored = true`:
1. Remove `hrp.Anchored = true`
2. Instead, suppress the humanoid's self-movement:
   ```lua
   humanoid.PlatformStand = true
   ```
   This disables the humanoid state machine (no running, jumping, falling) without anchoring. The SeatWeld remains functional and positions the character at the seat naturally.

In `deactivate()`, restore:
```lua
humanoid.PlatformStand = false
```

**Also in `activate()`** — after `PlatformStand = true`, zero the character's velocity to prevent any residual physics:
```lua
hrp.AssemblyLinearVelocity = Vector3.zero
hrp.AssemblyAngularVelocity = Vector3.zero
```

**File:** `src/Server/Vehicles/WalkerServer.luau`

In `updateDriverFromSeat()`, when a new driver is detected, set server-side network ownership to nil on the character's HRP. This makes the server authoritative over character position, which is correct since the walker is server-driven:
```lua
local character = player.Character
if character then
    local hrp = character:FindFirstChild("HumanoidRootPart")
    if hrp and hrp:IsA("BasePart") then
        hrp:SetNetworkOwner(nil)
    end
end
```

In `clearDriver()`, when the driver leaves, restore network ownership to the player:
```lua
if state.driver ~= nil then
    local character = state.driver.Character
    if character then
        local hrp = character:FindFirstChild("HumanoidRootPart")
        if hrp and hrp:IsA("BasePart") then
            hrp:SetNetworkOwnerAuto()
        end
    end
end
```

**Client-side character rendering:** The existing client character smoothing code that writes `torsoCF` each render frame should continue working. With HRP unanchored but PlatformStand = true, the HRP follows the seat weld (at server write rate ~20Hz). The client's per-frame CFrame writes to the character provide visual smoothing on top of the seat-weld base position. These local CFrame writes are rendering overrides that don't fight the weld — the weld establishes the base position, and local CFrame writes adjust the visual.

**Test criteria:**
1. Walk 100+ studs from spawn — NOT ejected
2. Sprint 200+ studs — NOT ejected
3. Character visible and smooth while driving
4. Exit walker — character drops naturally, can walk

**AI build prints:**
```
[P95_SEAT] entityId=%s driver=%s platformStand=%s networkOwner=%s
```
Print on driver enter/exit.

---

### Step 2: Remote Walker Visuals (Bug 1)

**Problem:** Three sub-issues in RemoteVehicleSmoother for walker entries:

**2a: Legs not found (race condition)**
Client entry activation fires when `VehicleEntity` tag is detected. The server reparents walker legs to a Workspace folder during `registerWalker()`. If the client activates before the server's reparent replicates, `Workspace:FindFirstChild(model.Name .. "_Legs")` returns nil and legs never get IK'd.

**2b: Head not following body correctly**
`visualClone:PivotTo(modCockpitCF)` cascades all model children including the cloned head. Then `cloneHeadPart.CFrame = nextHeadCFrame` overrides — but if the head's CHILDREN (turret geometry, weapon mounts) are affected by the cascade and NOT individually re-positioned, they end up at wrong offsets.

**2c: Driver character floating**
With bug 2 fixed (HRP unanchored, seat weld works), the source character now follows the seat naturally. The character visual clone in RemoteVehicleSmoother should track correctly since `pair.visual.CFrame = cframeDelta * pair.source.CFrame` uses the source's current position (which is now at the seat, not frozen at spawn).

**File:** `src/Client/Vehicles/RemoteVehicleSmoother.luau`

**Fix 2a — Deferred leg discovery:**

In the walker entry activation path (where `sourceLegsFolder` is looked up), if the folder is not found, schedule a deferred retry:

```lua
local sourceLegsFolder = Workspace:FindFirstChild(model.Name .. "_Legs")
if sourceLegsFolder == nil then
    -- Legs not yet reparented by server. Poll until found (max 3 seconds).
    task.spawn(function()
        local timeout = 3
        local elapsed = 0
        while elapsed < timeout do
            task.wait(0.2)
            elapsed += 0.2
            sourceLegsFolder = Workspace:FindFirstChild(model.Name .. "_Legs")
            if sourceLegsFolder ~= nil then
                break
            end
        end
        if sourceLegsFolder ~= nil then
            -- Parse leg parts and store in entry (same code as current parsing block)
            entry.sourceLegsFolder = sourceLegsFolder
            -- ... populate entry.walkerLegParts from the folder
        end
    end)
end
```

The polling runs in a separate thread. The entry continues to exist (head/body render). Once legs are found, IK starts writing them.

**Fix 2b — Head follower repositioning after PivotTo:**

After `visualClone:PivotTo(modCockpitCF)` and after `cloneHeadPart.CFrame = nextHeadCFrame`, also reposition the head's follower parts using the stored offsets (this code likely already exists — verify `cloneHeadFollowerOffsets` loop runs AFTER both writes). The issue may be that follower offsets are computed relative to the old head CFrame (before PivotTo). They should be computed relative to the NEW head CFrame:

```lua
-- After setting head CFrame
for _, follower in ipairs(entry.cloneHeadFollowerOffsets) do
    if follower.part.Parent ~= nil then
        follower.part.CFrame = nextHeadCFrame * follower.offset
    end
end
```

If this loop already exists (the earlier code analysis suggests it does), verify:
1. `follower.offset` is the part's CFrame relative to the HEAD, not relative to PrimaryPart
2. The loop runs AFTER `cloneHeadPart.CFrame = nextHeadCFrame`, not before
3. All visual turret geometry parts (WeaponMount children, barrel meshes) are included in `cloneHeadFollowerOffsets`

If some head-descended parts are NOT in the follower list (e.g., parts added by pass 9 for chin turret), they'll be positioned by PivotTo cascade and NOT corrected. **Add them to the follower list during entry initialization.**

**Fix 2c — Driver character (should auto-fix):**
With bug 2's seat stability fix, the source character follows the seat via weld. The existing `cframeDelta * pair.source.CFrame` character clone positioning should now work correctly because `pair.source.CFrame` reflects the actual seat position (not a frozen anchor position).

**Verify** that `hideCharacter()` is being called for the remote walker driver's character (transparency = 1 on source, visual clone rendered instead). If the source character is visible AND the visual clone is visible, you get double rendering (floating appearance).

**Test criteria:**
1. Second player sees walker legs animating (stepping, IK)
2. Second player sees walker head/turret rotating with driver's aim
3. Second player sees driver character seated in cockpit (not floating)
4. Legs appear within 1 second of walker spawning (deferred discovery)

**AI build prints:**
```
[P95_REMOTE_LEGS] entityId=%s found=%s elapsed=%.1f
[P95_REMOTE_HEAD] entityId=%s headOffset=%.2f,%.2f,%.2f
```

---

### Step 3: Lock-On Angle Break (Bug 3)

**Problem:** `validateLockCandidate()` in TargetingServer checks range, mount arc, line-of-sight, and faction — but never checks whether the target is within the player's forward facing arc. A player can lock a target behind them and keep shooting backwards.

**File:** `src/Server/Targeting/TargetingServer.luau`

**Fix: Add facing-angle check to lock validation.**

In `validateLockCandidate()`, after the existing range check and before returning true, add:

```lua
-- Break lock if target is outside forward facing arc
local LOCK_FACING_HALF_ANGLE = math.rad(90) -- 90° half-angle = 180° total cone
local weaponForward = mount.CFrame.LookVector
-- For walkers/vehicles, use the vehicle's forward direction instead of mount's
-- because the mount might be a fixed-forward chin blaster
local entityModel = mount:FindFirstAncestorOfClass("Model")
if entityModel and entityModel.PrimaryPart then
    weaponForward = entityModel.PrimaryPart.CFrame.LookVector
end
local toTarget = (targetPosition - mount.Position).Unit
local facingAngle = math.acos(math.clamp(weaponForward:Dot(toTarget), -1, 1))
if facingAngle > LOCK_FACING_HALF_ANGLE then
    return false, "ARC"  -- or whatever the existing rejection reason format is
end
```

**Important:** This check should use the ENTITY's forward direction (PrimaryPart.LookVector), not the mount's direction. The mount might be a fixed-forward weapon (like the walker chin blaster), whose LookVector follows the head aim. We want to check if the target is in front of the vehicle/walker body, not the aiming direction.

For standalone turrets (no VehicleEntity parent), use the mount's own forward — turrets can already only aim within their arc limits, so this is redundant but harmless.

Also add the same check to the periodic lock maintenance loop (wherever the server re-validates existing locks). The lock should break with reason `"ARC"` when the target leaves the 180° forward cone. The client already has HUD support for lock-loss cues (`CombatHUD.onLockLostCue(reason)`).

**Config:** The 90° half-angle (180° total cone) should be a config value in CombatConfig, not a magic number:
```lua
CombatConfig.Targeting = CombatConfig.Targeting or {}
CombatConfig.Targeting.lockFacingHalfAngleDeg = 90
```

**Test criteria:**
1. Lock onto target in front → stays locked
2. Turn 180° away → lock breaks, HUD shows "ARC LOST"
3. Turn back → can re-lock
4. Lock and strafe sideways (target at 89°) → stays locked
5. Lock and strafe past 90° → breaks

**AI build prints:**
```
[P95_LOCK_FACING] entityId=%s angle=%.1f threshold=%.1f result=%s
```

---

### Step 4: Remote Turret Rotation (Bug 4)

**Problem:** WeaponServer writes `mount.CFrame` via `WeaponRig.getAimFrame()` when receiving aim updates — this replicates to all clients. But the visual turret parts (driven parts in TurretRig folders: `YawOnlyParts`, `PitchOnlyParts`, `YawPitchParts`, `DrivenParts`) are only written by WeaponClient on the local player's client. Remote players see the mount rotate (small part) but the visual turret stays frozen.

**File:** `src/Server/Weapons/WeaponServer.luau`

**Fix: Server writes driven part CFrames alongside mount CFrame.**

**At registration time** (when a turret entity is initialized), parse the TurretRig folder structure and store driven part references per entity. Same structure as WeaponClient:

```lua
-- In entity/station registration
local rigFolder = model:FindFirstChild("TurretRig")
if rigFolder then
    local drivenParts = {} -- { { part: BasePart, mode: string, neutralCFrame: CFrame } }
    for _, groupFolder in ipairs(rigFolder:GetChildren()) do
        if groupFolder:IsA("Folder") then
            local mode = string.lower(groupFolder.Name)
            -- mode is "yawonlyparts", "pitchonlyparts", "yawpitchparts", "drivenparts"
            for _, part in ipairs(groupFolder:GetChildren()) do
                if part:IsA("BasePart") then
                    table.insert(drivenParts, {
                        part = part,
                        mode = mode,
                        neutralCFrame = part.CFrame, -- store initial CFrame as neutral
                    })
                end
            end
        end
    end
    -- Store drivenParts in the entity/station state
end
```

**In `applyAimToRig()`** (or `onUpdateTurretAim()` after writing mount CFrame), also write driven part CFrames:

For each driven part, compute its CFrame based on the mount's rotation:
- Extract yaw and pitch from the mount's clamped direction relative to the neutral aim frame
- `YawOnlyParts`: rotate by yaw only around Y axis
- `PitchOnlyParts`: rotate by pitch only
- `YawPitchParts`: rotate by both yaw and pitch
- `DrivenParts`: same as YawPitchParts (full rotation)

The rotation is applied relative to each part's neutral CFrame (stored at registration):

```lua
local neutralAimFrame = getRotatingNeutralFrame(mount, model) -- existing function
local localDir = neutralAimFrame:VectorToObjectSpace(clampedDirection.Unit)
local yaw = math.atan2(-localDir.X, -localDir.Z)
local pitch = math.asin(math.clamp(localDir.Y, -1, 1))

for _, driven in ipairs(drivenParts) do
    local rotation
    if driven.mode == "yawonlyparts" then
        rotation = CFrame.Angles(0, yaw, 0)
    elseif driven.mode == "pitchonlyparts" then
        rotation = CFrame.Angles(pitch, 0, 0)
    elseif driven.mode == "yawpitchparts" or driven.mode == "drivenparts" then
        rotation = CFrame.Angles(pitch, yaw, 0)
    else
        rotation = CFrame.new()
    end

    -- Rotate around the part's own center relative to its neutral pose
    local pivotWorld = driven.neutralCFrame.Position
    local neutralRotation = driven.neutralCFrame - driven.neutralCFrame.Position
    driven.part.CFrame = CFrame.new(pivotWorld) * CFrame.Angles(0, yaw, 0) * neutralRotation
    -- Note: actual rotation math should mirror WeaponClient's updateDrivenParts() exactly.
    -- Read WeaponClient's implementation and replicate the same transform.
end
```

**Important:** The driven part rotation math MUST match WeaponClient's `updateDrivenParts()` exactly. Read that function and copy the transform logic. Don't invent a different rotation scheme — it will cause visual mismatch between local and remote players.

**Performance:** This adds CFrame writes per driven part per aim update (30Hz). For a typical turret with 3-6 driven parts, that's 90-180 extra CFrame writes per second per active turret. Acceptable for a handful of active turrets. If you have 20+ simultaneously active turrets, consider rate-limiting driven part writes to 10Hz.

**Test criteria:**
1. Player A aims turret → Player B sees turret rotating
2. Turret barrel tracks aim direction smoothly
3. Walker head rotation visible to other players (head parts are driven parts)

**AI build prints:**
```
[P95_TURRET_DRIVEN] entityId=%s parts=%d direction=%.2f,%.2f,%.2f
```

---

### Step 5: Whiz Sound Shooter Exclusion (Bug 5)

**Problem:** `playWhizSound()` in ProjectileVisuals creates a looping whiz sound on the bolt part that plays for ALL clients, including the shooter. The ion cannon's whiz asset is particularly loud, making this noticeable.

**File:** `src/Client/Projectiles/ProjectileVisuals.luau`

**Fix: Skip whiz sound for local player's own shots.**

The bolt metadata already carries `shooterUserId` (or similar field identifying who fired the shot). In the code that calls `playWhizSound()`, add a check:

```lua
-- Before calling playWhizSound():
local localPlayer = Players.LocalPlayer
if localPlayer and boltData.shooterUserId == localPlayer.UserId then
    -- Don't play whiz for own shots
else
    playWhizSound(boltPart, fireSound)
end
```

Find where `playWhizSound()` is called during bolt creation. The bolt's metadata (stored in `activeBolts`) should have the shooter info from the `ProjectileFired` remote payload.

If `shooterUserId` is not already in the bolt metadata, it needs to be added:
- `ProjectileFired` remote payload already carries the entity ID of the shooter
- The entity can be mapped to a player via seat occupancy
- OR: add `shooterUserId` to the `ProjectileFired` payload from the server

The simplest approach: check if the `ProjectileFired` payload already includes a player/user ID. If not, add `shooterPlayerId` to the payload in WeaponServer's fire broadcast, and store it in the bolt metadata in ProjectileVisuals.

**Test criteria:**
1. Fire ion cannon → no whiz sound for shooter
2. Stand near someone firing ion cannon → hear whiz as bolts pass
3. Other weapon types also don't play whiz for shooter

**AI build prints:**
```
[P95_WHIZ_SKIP] boltId=%s reason=localShooter
```

---

### Step 6: Heavy Vehicle Phantom Fire (Bug 6)

**Problem:** VehicleClient's weapon detection checks if the entity has ANY weapon (`entityConfig.weaponId`), which is true when gunner seats have weapons. The driver gets a crosshair and can click to play fire sounds even though the driver has no weapon.

**File:** `src/Client/Vehicles/VehicleClient.luau`

**Fix: Only enable driver weapon if the driver's own context resolves a weapon.**

The existing weapon detection (in `enterVehicleMode()` or wherever `activeVehicleHasWeapon` is set) currently checks:
```lua
local entityConfig = CombatConfig.Entities[configId]
if entityConfig and entityConfig.weaponId then
    activeVehicleHasWeapon = true
```

Replace this with a check that specifically verifies the DRIVER has a weapon. The server-side logic for this is `resolvePlayerVehicleWeaponContext()` in WeaponServer — it checks if the player is in a DriverSeat AND the entity config has a weaponId. On the client, mirror this logic:

```lua
-- Only enable weapon for driver if entity config has weaponId AND player is in DriverSeat
local isDriver = false
local driverSeat = nil
for _, descendant in ipairs(vehicleModel:GetDescendants()) do
    if descendant:HasTag("DriverSeat") and descendant:IsA("Seat") or descendant:IsA("VehicleSeat") then
        driverSeat = descendant
        break
    end
end
if driverSeat and driverSeat.Occupant then
    local seatCharacter = driverSeat.Occupant.Parent
    if seatCharacter == localPlayer.Character then
        isDriver = true
    end
end

local entityConfig = CombatConfig.Entities[configId]
if isDriver and entityConfig and entityConfig.weaponId then
    activeVehicleHasWeapon = true
    -- Build fire sound pool, etc.
else
    activeVehicleHasWeapon = false
end
```

**Also:** Only show crosshair when `activeVehicleHasWeapon == true`. Find where `CombatHUD.showCrosshair(true)` is called during vehicle activation and gate it behind the weapon check. If the driver has no weapon, no crosshair, no fire sound pool, no fire response to left click.

**Note:** This does NOT affect gunner seats. Gunner weapon activation is handled by WeaponClient (separate code path via TurretSeat/GunnerSeat detection). This fix only changes the DRIVER's weapon detection in VehicleClient.

**Test criteria:**
1. Drive heavy vehicle with no driver weapon → no crosshair, clicking does nothing
2. Drive armed speeder (driver has weapon) → crosshair appears, firing works
3. Gunner in heavy vehicle → weapon works normally (separate code path)

**AI build prints:**
```
[P95_DRIVER_WEAPON] entityId=%s isDriver=%s hasWeapon=%s
```

---

## Integration Points Summary

| File | Change | Why |
|---|---|---|
| WalkerClient.luau | Remove HRP anchoring, use PlatformStand instead | Fix seat ejection (bug 2) |
| WalkerServer.luau | SetNetworkOwner(nil) on driver HRP, restore on exit | Prevent character physics interference |
| RemoteVehicleSmoother.luau | Deferred leg discovery, verify head follower positioning | Fix remote walker visuals (bug 1) |
| TargetingServer.luau | Add facing-angle check to lock validation | Fix rear lock-on (bug 3) |
| WeaponServer.luau | Parse TurretRig, write driven part CFrames on aim update | Fix remote turret rotation (bug 4) |
| ProjectileVisuals.luau | Skip whiz sound for local shooter's bolts | Fix ion whiz (bug 5) |
| VehicleClient.luau | Check driver-specific weapon context, gate crosshair | Fix phantom fire (bug 6) |
| CombatConfig.luau | Add `lockFacingHalfAngleDeg = 90` to Targeting config | Config for lock angle break |

---

## Golden Tests

### Test GT-9.5.1: Walker Long-Distance No Ejection
- **Setup:** Walker on flat terrain. Player seated.
- **Action:** Walk forward 200+ studs. Sprint back to start. Repeat.
- **Expected:** Player never ejected. Walker controls remain responsive.
- **Pass condition:** No seat ejection after 200+ studs of travel. `[P95_SEAT]` shows stable driver throughout.

### Test GT-9.5.2: Remote Walker Full Visual
- **Setup:** Walker with driver. Second player observing from 30 studs.
- **Action:** Driver walks, sprints, aims head, fires weapon.
- **Expected:** Observer sees: legs stepping with IK, head/turret rotating with aim, driver character in cockpit, fire visual from muzzle.
- **Pass condition:** Visual inspection — all walker parts animate correctly for observer. `[P95_REMOTE_LEGS]` shows found=true.

### Test GT-9.5.3: Lock-On Facing Break
- **Setup:** Turret with lock-on capability. Target at 50 studs in front.
- **Action:** Lock target. Turn turret 180° away (facing opposite direction from target).
- **Expected:** Lock breaks when target passes 90° from forward.
- **Pass condition:** `[P95_LOCK_FACING]` shows angle > 90 and result=break. HUD shows lock-lost cue.

### Test GT-9.5.4: Remote Turret Rotation Visible
- **Setup:** Turret manned by Player A. Player B observing from 20 studs.
- **Action:** Player A aims turret left, right, up, down.
- **Expected:** Player B sees turret barrel and body parts rotating.
- **Pass condition:** Visual inspection — driven parts rotate for observer. `[P95_TURRET_DRIVEN]` fires on aim updates.

### Regression
Re-run GT 1-25. Stabilization fixes must not break existing turret, speeder, artillery, or walker behavior.

---

## Critic Self-Review

**Cross-Module Contracts:**
- FLAG (medium): Step 1 changes character ownership. If other systems depend on the player owning their character's HRP while in a walker (e.g., camera, local rendering), SetNetworkOwner(nil) could cause issues. Verify VehicleCamera and WalkerClient don't rely on client-owned HRP physics. They use CFrame reads only (no physics simulation), so this should be safe.
- FLAG (medium): Step 4 adds server-side driven part writes at 30Hz. If WeaponClient also writes driven parts for the local player, both server and client write the same parts. Local client writes override server writes for the local player (client has render priority). For remote players, server writes take effect. This is the correct behavior — no conflict.
- PASS: Step 3 lock angle check uses entity PrimaryPart forward, not mount forward. Correct — mount forward changes with aim, entity forward changes with body rotation.

**Regression Risk:**
- FLAG (low): Step 1 PlatformStand may cause visual ragdoll effect on the character while seated. If it does, alternative is to disable individual humanoid states instead: `humanoid:SetStateEnabled(Enum.HumanoidStateType.Running, false)` etc. PlatformStand is simpler but test visuals.
- FLAG (low): Step 5 whiz exclusion needs shooter ID in bolt metadata. If not already there, adding it to ProjectileFired payload changes the remote contract. Ensure all clients handle the new field gracefully (nil-safe).

**Security:**
- PASS: All fixes are visual/UX. No gameplay-authoritative changes except step 3 (lock angle check), which is server-side and restrictive (breaks lock — doesn't grant advantage).

**Performance:**
- FLAG (low): Step 4 driven part CFrame writes add ~90-180 writes/sec per active turret. Monitor if >10 turrets active simultaneously.
- PASS: Step 2 deferred leg discovery uses task.spawn + polling (0.2s interval, 3s timeout). Minimal overhead.

**Verdict: APPROVED — 0 blocking issues, 5 low-medium flags. All flags are testable during build.**
