# Pass 9 Design: Walker Combat

**Depends on:** Pass 8 (walker movement), Pass 6 (vehicle combat pattern)
**Scope:** Weapons on walkers. Head-mounted driver weapon. Walker HP/shields/destruction. Enclosed protection. Walker theft.

---

## Architecture: Reuse Vehicle Weapon System

The weapon system is already generic. The bridge:
- Entity config has `weaponId` → WeaponServer registers weapon via `WeaponServer.registerEntity(entityId)` (already called for all entities in CombatInit line 219)
- Model has `WeaponMount` tagged parts → `collectFireNodes()` discovers them
- Player in `DriverSeat` inside `VehicleEntity` → `resolvePlayerVehicleWeaponContext()` resolves the weapon
- Client sends `FireWeapon` remote with aimDirection → server fires from mount

**What already works with no code changes:**
- WeaponServer fire handling (resolvePlayerVehicleWeaponContext works for any VehicleEntity + DriverSeat)
- HealthManager occupant kill on destruction (scans ALL seats in model, kills all occupants — lines 427-442)
- Splash damage on walkers (already combat entities)
- Walker theft (DriverSeat is a standard Seat — any player can sit)
- Entity respawn (WalkerServer.onEntityRespawned already works)
- Enclosed protection (turretExposed=false blocks direct player hits, checked by ProjectileServer)

**What needs code:**
1. Config: walker entity weaponId + weapon config + sound
2. WalkerServer: head CFrame update per frame (weapon mounts on head need correct world position for muzzle origin)
3. WalkerClient: weapon fire input + HUD (same pattern as VehicleClient weapon code)
4. Model authoring: WeaponMount tag + muzzle attachments on head

---

## Build Steps

### Step 1: Config

**CombatConfig.luau — Add walker weapon config to `CombatConfig.Weapons`:**

```lua
walker_chin_blaster = {
    damageType = "blaster",
    damage = 20,
    projectileSpeed = 600,
    maxRange = 600,
    fireRate = 8,
    burstCount = 1,
    weaponClass = "projectile",
    requiresLock = false,
    heatPerShot = 5,
    maxHeat = 100,
    heatDecayPerSecond = 20,
    heatRecoverThreshold = 40,
    autoAimSpread = 2.0,
    lockRange = 500,
},
```

Rapid-fire chin blaster: 8 shots/sec at 20 damage each (160 DPS). Lower per-shot than turret blasters but sustained fire. Overheat after 20 consecutive shots.

**CombatConfig.Entities — Update walker_biped:**

```lua
walker_biped = {
    hullHP = 800,
    shieldHP = 200,
    shieldRegenRate = 10,
    shieldRegenDelay = 5,
    weaponId = "walker_chin_blaster",
    turretExposed = false,
    respawnTime = 45,
},
```

Enclosed cockpit (must destroy hull to kill driver). Shields + high hull HP (AT-ST is armored). Longer respawn than speeders.

**CombatConfig.WeaponSounds — walker group already exists (line 636-638).** No changes needed. The `walker` sound group has `fire = "rbxassetid://111375553713809"` (STShoot). The walker model needs `FireSound = "walker"` attribute (set during model authoring step 4).

**Test criteria:** Config compiles, no runtime errors. Walker entity has weaponId in health state.

---

### Step 2: WalkerServer — Head CFrame Update

**Problem:** Weapon mounts are on the walker head. The head rotates with aimYaw (independent of body heading). The server only writes PrimaryPart.CFrame — the head gets its CFrame from PrimaryPart cascade, which doesn't include aimYaw rotation. When WeaponServer reads the weapon mount position for muzzle origin, it gets the wrong position.

**Fix:** In `stepSingleWalker()`, after writing the body CFrame, also write the head CFrame with aimYaw offset.

**File:** `src/Server/Vehicles/WalkerServer.luau`

**In `registerWalker()` — store head base offset:**

Already stored as part of `childPartOffsets`. Add a dedicated field to WalkerRuntimeState:

```lua
headBaseOffset: CFrame,  -- PrimaryPart-relative head CFrame at registration
```

Compute during registration (same pattern as existing childPartOffsets):
```lua
state.headBaseOffset = state.primaryPart.CFrame:Inverse() * state.headPart.CFrame
```

**In `stepSingleWalker()` — write head CFrame after body CFrame write:**

After `state.primaryPart.CFrame = state.simulatedCFrame` (or wherever the body CFrame is written), add:

```lua
-- Update head CFrame with aim rotation (weapon mounts need correct world position)
local aimOffset = state.aimYaw - state.heading
local headYawMin = math.rad(config.headYawMin or -120)
local headYawMax = math.rad(config.headYawMax or 120)
aimOffset = math.clamp(aimOffset, headYawMin, headYawMax)
state.headPart.CFrame = state.simulatedCFrame * state.headBaseOffset * CFrame.Angles(0, aimOffset, 0)
```

This runs at the same rate as the body CFrame write (rate-limited to 20Hz active). The head position will be slightly behind real-time on the client, but close enough for projectile origin accuracy.

**Also in `stepSingleWalker()` — update NeutralAimRX/RY/RZ on weapon mounts:**

When the walker is first registered and the head part has WeaponMount descendants, set neutral aim attributes. WeaponServer uses these to reconstruct the aim frame for rotating platforms.

In `registerWalker()`, after creating the state, for each WeaponMount descendant of headPart:
```lua
local mount = descendant  -- BasePart tagged WeaponMount
local relCF = state.primaryPart.CFrame:Inverse() * mount.CFrame
local rx, ry, rz = relCF:ToOrientation()
mount:SetAttribute("NeutralAimRX", rx)
mount:SetAttribute("NeutralAimRY", ry)
mount:SetAttribute("NeutralAimRZ", rz)
```

These are set once at registration. WeaponServer reads them during fire to reconstruct the neutral aim frame.

**CombatTypes.luau — extend WalkerRuntimeState:**

Add field:
```lua
headBaseOffset: CFrame,
```

**Test criteria:** During playtest, `state.headPart.CFrame` matches aimYaw rotation. WeaponMount parts on head have correct world position.

**AI build prints:**
```
[P9_HEAD_CF] entityId=%s aimOffset=%.2f
```

---

### Step 3: WalkerClient — Weapon Fire Input + HUD

**Pattern:** Follow VehicleClient weapon integration exactly. The walker client needs:
1. Fire on left mouse click
2. Send aim direction to server via FireWeapon remote
3. Play fire sound locally
4. Update weapon HUD (overheat bar, ammo if applicable)

**File:** `src/Client/Vehicles/WalkerClient.luau`

**New module-level state (same pattern as VehicleClient lines 66-80):**

```lua
local activeVehicleHasWeapon: boolean = false
local fireWeaponRemote: RemoteEvent? = nil
local updateTurretAimRemote: RemoteEvent? = nil
local fireSoundPool: { Sound } = {}
local fireSoundIndex: number = 1
local FIRE_POOL_SIZE: number = 6
```

**In `init()` — store weapon remotes:**

```lua
fireWeaponRemote = remotesFolder:WaitForChild("FireWeapon")
updateTurretAimRemote = remotesFolder:WaitForChild("UpdateTurretAim")
```

**In `activate()` — detect weapon and build sound pool:**

After existing activation code, check if entity has a weapon:

```lua
-- Check for weapon
local entityConfigId = model:GetAttribute("ConfigId")
if type(entityConfigId) == "string" then
    local entityConfig = CombatConfig.Entities[entityConfigId]
    if entityConfig ~= nil and entityConfig.weaponId ~= nil then
        activeVehicleHasWeapon = true
        -- Build fire sound pool (same pattern as VehicleClient)
        local groupKey = entityConfig.weaponId
        local raw = model:GetAttribute("FireSound")
        if type(raw) == "string" and raw ~= "" then
            groupKey = raw
        end
        local group = CombatConfig.WeaponSounds[groupKey]
        if group ~= nil then
            -- Build rotating pool of FIRE_POOL_SIZE sounds from group.fire
            -- (Same code as VehicleClient fire sound pool builder)
        end
    end
end
```

**In RenderStepped callback — fire on click + send aim updates:**

After existing IK/rendering code:

```lua
if activeVehicleHasWeapon then
    -- Compute aim direction from camera ray (screen center)
    local camera = Workspace.CurrentCamera
    local aimDirection = camera.CFrame.LookVector

    -- Send continuous aim updates for turret tracking (throttled)
    -- Same throttle pattern as VehicleClient
    if updateTurretAimRemote ~= nil then
        updateTurretAimRemote:FireServer(aimDirection)
    end

    -- Fire on left mouse button
    if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
        -- Rate-limit fires based on weapon config fireRate
        -- Same pattern as VehicleClient fire rate limiter
        if fireWeaponRemote ~= nil then
            fireWeaponRemote:FireServer(aimDirection)
        end
        -- Play local fire sound from pool
        -- Same rotating pool pattern as VehicleClient
    end

    -- Update weapon HUD from model attributes
    local heat = model:GetAttribute("WeaponHeat") or 0
    local maxHeat = model:GetAttribute("WeaponHeatMax") or 100
    local overheated = model:GetAttribute("WeaponOverheated") or false
    CombatHUD.setHeat(heat, maxHeat, overheated)

    local ammo = model:GetAttribute("WeaponAmmo")
    local maxAmmo = model:GetAttribute("WeaponAmmoMax")
    if type(ammo) == "number" and type(maxAmmo) == "number" then
        CombatHUD.setAmmo(ammo, maxAmmo)
    end
end
```

**In `deactivate()` — clean up weapon state:**

```lua
activeVehicleHasWeapon = false
fireSoundPool = {}
fireSoundIndex = 1
CombatHUD.setHeat(0, 100, false)
```

**Important:** The fire rate limiter MUST be client-side to prevent sending excessive remotes. Use `lastFireTick` and `1 / fireRate` interval check. The server also validates fire rate, but the client should self-throttle.

**Import requirements:**
- `CombatConfig` (already imported in some walker files, verify)
- `CombatHUD` (already used for speed display)
- `UserInputService` (add to service requires)

**Test criteria:**
1. Sit in walker → left click fires
2. Bolts originate from head weapon mount (visual)
3. Fire sound plays (STShoot)
4. Overheat bar appears and fills with sustained fire
5. Overheated → forced cooldown → can fire again

**AI build prints:**
```
[P9_WALKER_FIRE] entityId=%s aimDir=%.2f,%.2f,%.2f
[P9_SUMMARY] walkerFires=%d errors=%d
```

**Pass/fail:** PASS if player can fire from walker, bolts hit targets, fire sound plays, overheat works. `[P9_SUMMARY] errors=0 AND walkerFires>=1`.

---

### Step 4: Model Authoring (MCP)

**Walker model changes (via MCP in Studio):**

1. **WeaponMount parts on head:**
   - Find the walker head part (tagged `WalkerHead`)
   - Create 2 BaseParts as weapon mount points (left and right chin guns), parented to the head
   - Tag each with `WeaponMount`
   - Set `AimAxis = "+Z"` attribute (or whatever axis points forward on the head)
   - Set `AimMode = "yawpitch"` attribute
   - Add `MuzzlePoint` Attachment to each mount (at the barrel tip position)

2. **FireSound attribute:**
   - On the walker model (root Model instance): `FireSound = "walker"`

3. **Verify tags exist:**
   - Model: `CombatEntity`, `VehicleEntity`
   - Attributes: `VehicleCategory = "walker_biped"`, `ConfigId = "walker_biped"`, `Faction = "empire"`
   - DriverSeat: `DriverSeat` tag
   - Head: `WalkerHead` tag

**Test criteria:** StartupValidator passes with no warnings. WeaponMount parts discoverable via CollectionService.

---

### Step 5: Verification + Polish

After steps 1-4, verify the full combat loop:

1. **Fire test:** Sit in walker → fire at target dummy → target takes damage
2. **Shield test:** Fire at shielded target → shields absorb first → hull after
3. **Damage received:** External turret fires at walker → walker HP decreases (shields first if configured)
4. **Enclosed protection:** External shot at driver character → blocked, walker hull takes damage instead
5. **Destruction:** Walker HP reaches 0 → explosion → driver killed → walker removed
6. **Respawn:** After respawnTime → walker reappears at spawn CFrame → functional
7. **Theft:** Empire walker empty → rebel player sits in DriverSeat → can drive and fire
8. **Lock-on:** Lock onto walker → auto-aim tracks it → hits land
9. **Splash:** Artillery hits near walker → splash damage applies to walker entity
10. **Remote visual:** Second client sees walker firing (bolt visuals from head mounts)

**AI build prints for verification:**
```
[P9_COMBAT_HIT] entityId=%s damage=%d damageType=%s
[P9_COMBAT_DESTROY] entityId=%s occupants=%d
```

---

## Integration Points Summary

| Existing Module | Change | Why |
|---|---|---|
| CombatConfig.luau | Add `walker_chin_blaster` weapon, update `walker_biped` entity (weaponId, HP, shields, turretExposed) | Weapon + entity config |
| CombatTypes.luau | Add `headBaseOffset: CFrame` to WalkerRuntimeState | Head CFrame tracking |
| WalkerServer.luau | Store headBaseOffset at registration. Write head CFrame with aimYaw in stepSingleWalker. Set NeutralAim attributes on head weapon mounts. | Accurate muzzle origin for server-side projectile spawning |
| WalkerClient.luau | Add weapon fire input (click → FireWeapon remote), fire sound pool, weapon HUD updates, aim direction updates | Driver weapon interaction |
| Model (MCP) | Add WeaponMount parts on head with MuzzlePoint attachments, set FireSound attribute | Weapon authoring |

**No changes needed to:** WeaponServer, WeaponClient, HealthManager, CombatInit, ProjectileServer, ProjectileVisuals, RemoteVehicleSmoother, VehicleClient, StartupValidator (weapon mount validation already exists for VehicleEntity models).

---

## Golden Tests

### Test GT-9.1: Walker Driver Fire
- **Setup:** Walker (empire, walker_biped, hullHP=800) on flat terrain. Rebel target_dummy (hullHP=200) at 50 studs distance.
- **Action:** Player sits in walker. Fires 10 shots at target.
- **Expected:** 10 hits. Target HP decreases by 200 (10 x 20 damage). Fire sound plays. Overheat bar visible.
- **Pass condition:** `[P9_SUMMARY] walkerFires>=10 errors=0`. `[P1_HIT]` x10. Target HP = 0.

### Test GT-9.2: Walker Destruction Kills Occupant
- **Setup:** Walker (hullHP=800, shieldHP=200). Player seated as driver. External rebel turbolaser (damage=150, turbolaser mult 1.5x shield+hull).
- **Action:** Fire enough shots to deplete shields then hull.
- **Expected:** Shields absorb first. Hull reaches 0 → explosion → driver killed.
- **Pass condition:** `[P9_COMBAT_DESTROY]` with occupants=1. Driver Humanoid.Health = 0.

### Test GT-9.3: Enclosed Protection
- **Setup:** Walker (turretExposed=false) with player driving. External rebel blaster aimed at player character inside cockpit.
- **Action:** Rebel fires 3 shots hitting the player character.
- **Expected:** All blocked by enclosed protection. Player takes 0 damage. Walker hull takes damage.
- **Pass condition:** `[P4_ENCLOSED_BLOCK]` x3. Player Humanoid.Health unchanged.

### Regression
Re-run all previous golden tests (GT 1-22). Walker combat additions must not affect turret, speeder, or artillery behavior.

---

## Critic Self-Review

**Cross-Module Contracts:**
- PASS: WeaponServer.resolvePlayerVehicleWeaponContext already handles VehicleEntity + DriverSeat generically. No changes needed.
- PASS: HealthManager occupant kill already scans all seats in model descendants. Works for walker driver + future gunner seats.
- PASS: Enclosed protection already checks turretExposed on entity config. Works for walkers with turretExposed=false.

**Regression Risk:**
- FLAG: WalkerClient adding weapon fire might conflict with existing input bindings. Must ensure left-click fire only activates when walker has a weapon. Same guard pattern as VehicleClient (`activeVehicleHasWeapon` flag).
- FLAG: Head CFrame write in WalkerServer adds one extra CFrame write per frame. Minimal bandwidth impact (single part, rate-limited with body write).

**Security:**
- PASS: Fire goes through existing server-validated WeaponServer path. Rate limiting, overheat, ammo all server-authoritative.
- PASS: Aim direction from client is clamped/validated by WeaponServer same as turrets.

**Performance:**
- PASS: One additional CFrame write per walker (head) per server frame. Negligible.
- PASS: Fire sound pool is pre-created (6 sounds). No per-fire Instance.new.

**Verdict: APPROVED — 0 blocking issues, 2 low-risk flags.**
