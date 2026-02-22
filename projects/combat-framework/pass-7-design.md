# Pass 7 Design: Artillery Emplacement

**Depends on:** Passes 1-4
**Source of truth:** Code in `src/` + `state.md` build deltas

---

## Overview

Adds artillery emplacements — fixed indirect-fire weapons with parabolic projectile trajectories, WASD keyboard aiming, and a numbers-based HUD showing elevation, heading, and estimated range. No auto-aim, no lock-on, no arc preview. Pure skill-based indirect fire.

---

## Build Steps

### Step 1: Config + Types

**Files modified:**
- `src/Shared/CombatTypes.luau`
- `src/Shared/CombatConfig.luau`
- `src/Shared/CombatEnums.luau`

**CombatTypes.luau — WeaponConfig additions:**
Add optional fields:
```
artilleryGravity: number?,    -- gravity for parabolic arc (studs/s^2)
artilleryMinElevation: number?, -- minimum elevation in degrees
artilleryMaxElevation: number?, -- maximum elevation in degrees
artilleryAdjustSpeed: number?,  -- normal adjust speed deg/s
artilleryFineAdjustSpeed: number?, -- fine adjust speed deg/s (shift held)
artilleryMinRange: number?,    -- minimum range in studs (server rejects fire below this)
reloadTime: number?,           -- seconds between shots (overrides fireRate for artillery)
```

**CombatTypes.luau — ProjectileData additions:**
Add optional fields:
```
artilleryGravity: number?,    -- if set, projectile uses parabolic stepping
currentVelocity: Vector3?,    -- velocity vector for parabolic projectiles
```

**CombatTypes.luau — ProjectileFiredPayload additions:**
Add optional field:
```
artilleryGravity: number?,    -- sent to clients so they can render the arc
```

**CombatEnums.luau:**
Add to DamageType:
```
ArtilleryShell = "artillery_shell",
```

**CombatConfig.luau — Weapons table:**
Add:
```lua
artillery_emplacement = {
    weaponClass = "artillery",
    damageType = "artillery_shell",
    damage = 150,
    fireRate = 0.2, -- 1 shot per 5 seconds (reload)
    projectileSpeed = 500, -- muzzle velocity
    maxRange = 1200, -- absolute max (safety cutoff, not the arc range)
    splashRadius = 25,
    ammoCapacity = 8,
    artilleryGravity = 300,
    artilleryMinElevation = 5,
    artilleryMaxElevation = 85,
    artilleryAdjustSpeed = 30,
    artilleryFineAdjustSpeed = 5,
    artilleryMinRange = 100,
    boltColor = Color3.fromRGB(255, 160, 40),
},
```

**CombatConfig.luau — Entities table:**
Add:
```lua
artillery_emplacement = {
    hullHP = 200,
    weaponId = "artillery_emplacement",
    turretExposed = true,
    respawnTime = 30,
},
```

**CombatConfig.luau — DamageTypeMultipliers table:**
Add:
```lua
artillery_shell = { shieldMult = 1.5, hullMult = 2.0, bypass = 0 },
```

**Test:** Config loads without errors. `CombatConfig.Weapons.artillery_emplacement` is accessible. No runtime failures.

**AI Build Print:** `[P7_CONFIG] artillery_emplacement weapon loaded: gravity=%d muzzleVel=%d`

---

### Step 2: Server — Parabolic Projectile Physics

**Files modified:**
- `src/Server/Projectiles/ProjectileServer.luau`

**Change to `stepProjectiles()`:**

In the main loop over `activeProjectiles`, after the existing homing block and before the existing straight-line block, add an artillery check:

```
if type(projectile.artilleryGravity) == "number" and projectile.artilleryGravity > 0 then
    -- Parabolic stepping
    previousPosition = projectile.currentPosition or projectile.origin
    local velocity = projectile.currentVelocity
    if velocity == nil then
        velocity = projectile.direction * projectile.speed
        projectile.currentVelocity = velocity
    end

    -- Apply gravity to velocity
    velocity = velocity + Vector3.new(0, -projectile.artilleryGravity * dt, 0)
    projectile.currentVelocity = velocity

    -- Step position
    currentPosition = previousPosition + velocity * dt
    projectile.currentPosition = currentPosition

    -- Update direction for CFrame orientation of the shell visual
    if velocity.Magnitude > 1e-4 then
        projectile.direction = velocity.Unit
    end
```

This goes BEFORE the existing straight-line `else` block. The existing code structure becomes:
1. `if homingActive then` (existing)
2. `elseif artilleryGravity then` (NEW)
3. `else` straight-line (existing)

The rest of the stepping (distance check, raycast hit detection, damage application, splash) all work unchanged — they use `previousPosition` and `currentPosition` which this block sets.

**Change to `ProjectileServer.fireProjectile()`:**

Add `artilleryGravity` to the payload sent to clients:
```lua
projectileRemote:FireAllClients({
    ...existing fields...,
    artilleryGravity = data.artilleryGravity,
})
```

**Test:** Fire an artillery projectile via test harness. Confirm `[P1_FIRE]` log appears. Confirm the projectile follows a parabolic path (should eventually hit the ground and trigger `[P1_HIT]` or `[P1_EXPIRED]`).

**AI Build Print:** `[P7_ARC] projectile=%s gravity=%d velocity=%.1f,%.1f,%.1f`
(Log once at creation, showing initial velocity vector.)

---

### Step 3: Server — Artillery Fire Handling + Seat Registration

**Files modified:**
- `src/Server/Weapons/WeaponServer.luau`
- `src/Server/Authoring/StartupValidator.luau`
- `src/Server/CombatInit.server.luau`

**WeaponServer.luau — `resolvePlayerTurretContext()`:**

Change line 1086 from:
```lua
if seatPart == nil or not CollectionService:HasTag(seatPart, "TurretSeat") then
```
to:
```lua
if seatPart == nil or (not CollectionService:HasTag(seatPart, "TurretSeat") and not CollectionService:HasTag(seatPart, "ArtillerySeat")) then
```

This lets artillery players fire through the same `FireWeapon` remote.

**WeaponServer.luau — `onFireWeapon()` weaponClass routing:**

After the existing `elseif weaponClass == "burst_projectile"` block (line ~1189) and before the `else` fallback (line ~1241), add:

```lua
elseif weaponClass == "artillery" then
    -- Validate minimum range
    local artilleryGravity = weaponConfig.artilleryGravity
    local muzzleVelocity = weaponConfig.projectileSpeed
    if type(artilleryGravity) == "number" and artilleryGravity > 0 and muzzleVelocity > 0 then
        local elevation = math.asin(math.clamp(normalizedDirection.Y, -1, 1))
        local flatRange = muzzleVelocity * muzzleVelocity * math.sin(2 * elevation) / artilleryGravity
        local minRange = weaponConfig.artilleryMinRange or 0
        if flatRange < minRange and minRange > 0 then
            print(string.format("[P7_MIN_RANGE] entity=%s range=%.0f min=%.0f", entityId, flatRange, minRange))
            return
        end
    end
    firedAny = fireArtilleryProjectile(
        entityModel, entityId, healthState, weaponConfig, character, normalizedDirection, cooldown
    )
```

**WeaponServer.luau — new `fireArtilleryProjectile()` function:**

Place this before `onFireWeapon()` (after `fireSingleProjectile()`). Signature:
```lua
local function fireArtilleryProjectile(
    entityModel: Model,
    entityId: string,
    healthState: HealthState,
    weaponConfig: WeaponConfig,
    character: Model,
    normalizedDirection: Vector3,
    cooldown: number
): boolean
```

This function is a simplified variant of `fireSingleProjectile`:
- No heat system (artillery uses ammo only)
- No lock-on / auto-aim / spread
- Sets `artilleryGravity` on ProjectileData
- Sets initial velocity via `direction * speed` (server's ProjectileServer handles the rest)
- Uses existing ammo system

Key logic:
1. Check ammo (same as fireSingleProjectile)
2. Get fire node (same)
3. Clamp direction to mount limits (same)
4. Compute fire origin from muzzle offset (same)
5. Get faction (same)
6. Create ProjectileData with `artilleryGravity = weaponConfig.artilleryGravity`
7. Decrement ammo (same)
8. No heat logic (skip entirely)
9. Call `ProjectileServer.fireProjectile(projectileData)`

**StartupValidator.luau:**

In `StartupValidator.validate()`, the seat search at line 229:
```lua
local seatCandidate = findTaggedDescendant(model, "TurretSeat", "Seat")
```
Change to also search for ArtillerySeat:
```lua
local seatCandidate = findTaggedDescendant(model, "TurretSeat", "Seat")
if seatCandidate == nil then
    seatCandidate = findTaggedDescendant(model, "ArtillerySeat", "Seat")
end
```

And the subsequent validation failure message should mention both seat types:
```lua
if seatCandidate == nil then
    fail(modelName, "has weaponId but no TurretSeat or ArtillerySeat tagged child")
    continue
end
```

**CombatInit.server.luau:**

After the turretSeat handling block (line 211-214), add a parallel block for artillery seats:
```lua
if validatedEntity.turretSeat ~= nil then
    -- Check if this is an artillery seat by looking at weapon config
    local entityConfig = CombatConfig.Entities[validatedEntity.configId]
    local isArtillery = false
    if entityConfig ~= nil and entityConfig.weaponId ~= nil then
        local weaponConfig = CombatConfig.Weapons[entityConfig.weaponId]
        if weaponConfig ~= nil and weaponConfig.weaponClass == "artillery" then
            isArtillery = true
        end
    end

    if isArtillery then
        CollectionService:AddTag(validatedEntity.turretSeat, "ArtillerySeat")
    else
        CollectionService:AddTag(validatedEntity.turretSeat, "TurretSeat")
    end
    addTurretPrompt(validatedEntity.turretSeat, entityId)
end
```

This replaces the existing turretSeat handling. The tag applied depends on weapon class.

**Test:** Place an artillery emplacement model with CombatEntity tag, ConfigId="artillery_emplacement", Faction="empire", a Seat tagged "TurretSeat" (validator finds it), a WeaponMount, MuzzlePoint, and CameraPoint. On playtest, the seat should get re-tagged as "ArtillerySeat". Proximity prompt should appear. When seated, server should accept fire commands and produce parabolic projectiles.

**AI Build Print:** `[P7_FIRE] entity=%s elevation=%.1f heading=%.1f range=%.0f`

---

### Step 4: Client — Artillery Aiming Controls

**New file:** `src/Client/Weapons/ArtilleryClient.luau`

**Module structure:**
```lua
local ArtilleryClient = {}

-- State
local activeArtilleryModel: Model? = nil
local activeSeat: BasePart? = nil
local activeWeaponMount: BasePart? = nil
local activeCameraPoint: Instance? = nil
local heading: number = 0         -- radians, 0 = model forward
local elevation: number = math.rad(45) -- radians, default 45 degrees
local fireWeaponRemote: RemoteEvent? = nil
local updateTurretAimRemote: RemoteEvent? = nil

-- Constants
local AIM_UPDATE_INTERVAL = 1/30
local CAMERA_FALLBACK_LOCAL_OFFSET = Vector3.new(0, 9, 22)
local CAMERA_LOOK_DISTANCE = 500

function ArtilleryClient.init(remotes: Folder)
function ArtilleryClient.isActive(): boolean
```

**Activation flow (called from CombatClient.client.luau):**

ArtilleryClient listens to `Humanoid.Seated`. When the player sits in a seat tagged `ArtillerySeat`:
1. Store `activeArtilleryModel`, `activeSeat`, find `WeaponMount` and `CameraPoint`
2. Initialize `heading` from the model's current forward direction
3. Initialize `elevation` to 45 degrees (midpoint)
4. Switch camera to Scriptable, lock mouse center
5. Bind WASD + Shift + F + MouseButton1 via ContextActionService
6. Start RenderStepped loop

**WASD aiming (per-frame update):**
```
local config = get weapon config from model attributes
local adjustSpeed = config.artilleryAdjustSpeed or 30  -- degrees/sec
local fineSpeed = config.artilleryFineAdjustSpeed or 5
local minElev = math.rad(config.artilleryMinElevation or 5)
local maxElev = math.rad(config.artilleryMaxElevation or 85)
local speed = if shiftHeld then fineSpeed else adjustSpeed
local speedRad = math.rad(speed) * dt

if wHeld then elevation = math.clamp(elevation + speedRad, minElev, maxElev) end
if sHeld then elevation = math.clamp(elevation - speedRad, minElev, maxElev) end
if aHeld then heading = heading + speedRad end
if dHeld then heading = heading - speedRad end
```

Note: heading wraps freely (no limits — 360-degree traverse). Elevation is clamped to min/max.

**Compute aim direction from heading + elevation:**
```lua
local cosElev = math.cos(elevation)
local aimDirection = Vector3.new(
    -math.sin(heading) * cosElev,
    math.sin(elevation),
    -math.cos(heading) * cosElev
).Unit
```

This produces a unit vector that points in the heading direction, elevated by the elevation angle. Same yaw convention as WeaponClient (atan2(-X, -Z)).

**Per-frame update loop:**
1. Read WASD input state, update heading/elevation
2. Compute aimDirection
3. Apply aim to weapon rig (call `WeaponRig.getAimFrame()` to visually tilt barrel) — client-side only for responsiveness
4. Send aim updates to server via `UpdateTurretAim` remote (same as turrets, throttled to 30 Hz)
5. Update camera position/look
6. Update HUD (step 5)

**Camera behavior:**
Camera anchors at CameraPoint, looks in the aim direction. Identical to turret camera but driven by keyboard aim instead of mouse. No recoil/shake (can add later for polish).

**Fire handling:**
MouseButton1 → call `fireWeaponRemote:FireServer(aimDirection.Unit)`. Client checks ammo via model attributes (same as turret). No cooldown prediction needed beyond existing fireRate.

**Exit:** F key → `humanoid.Sit = false` (same as turret exit).

**Deactivation:** When unseated from ArtillerySeat, clear all state, restore camera to Custom, unbind actions.

**Key bindings:**
- `W` — increase elevation
- `S` — decrease elevation
- `A` — rotate heading left (increase yaw)
- `D` — rotate heading right (decrease yaw)
- `LeftShift` — fine adjustment modifier (hold)
- `MouseButton1` — fire
- `F` — exit
- `MouseButton2` — zoom (reuse existing zoom behavior from turrets)

**Read config values from model attributes:**
The server publishes `EffectiveWeaponXxx` attributes via `publishResolvedWeaponAttributes`. Artillery-specific values (gravity, elevation limits, adjust speeds) are NOT in the published set. Read them from CombatConfig directly using the entity's `ConfigId` → `entityConfig.weaponId` → `CombatConfig.Weapons[weaponId]`.

**Test:** Seat in artillery. WASD changes heading/elevation. Barrel visually tilts. Mouse click fires. Shell arcs through air.

**AI Build Print:** `[P7_AIM] heading=%.1f elevation=%.1f range=%.0f` (every 1 second, not every frame)

---

### Step 5: Client — Artillery HUD

**Files modified:**
- `src/Client/HUD/CombatHUD.luau`

Add new HUD elements for artillery mode. Create them in `CombatHUD.init()`:

**New GUI elements:**
- `artilleryFrame` — container frame, bottom-center, visible only in artillery mode
- `elevationLabel` — TextLabel: "ELEV: 45.0"
- `headingLabel` — TextLabel: "HDG: 180.0"
- `rangeLabel` — TextLabel: "RANGE: 416"

Layout: Single dark semi-transparent frame (similar to existing HUD frames), positioned at bottom-center. Three lines of text, Code font, white on dark. Same visual language as Hull/Shield/Heat frames.

**New CombatHUD functions:**
```lua
function CombatHUD.showArtillery(visible: boolean)
function CombatHUD.setArtilleryAim(elevationDeg: number, headingDeg: number, rangeSt: number)
```

`showArtillery(true)` shows the artillery frame and hides turret-specific elements (heat, lock ready, etc.). `showArtillery(false)` hides it.

`setArtilleryAim()` updates the three labels:
```
ELEV: 45.0°
HDG:  180.0°
RANGE: 416
```

**Range computation (client-side, for display only):**
```lua
local v = muzzleVelocity
local g = artilleryGravity
local theta = elevation -- radians
local flatRange = v * v * math.sin(2 * theta) / g
```
This assumes flat ground (level with emplacement). Display as integer studs.

**Heading display:** Convert heading radians to degrees, wrap to 0-360.

**Ammo display:** Reuse existing `CombatHUD.showAmmo()` / `CombatHUD.setAmmo()`. Artillery always shows ammo (no heat).

**Crosshair:** Show cursor dot at screen center (same as turret). No aim-projected crosshair (we don't know where the shell will land without arc preview).

**Test:** Sit in artillery. HUD shows elevation, heading, range. Values update as WASD is pressed. Ammo counter visible.

**AI Build Print:** `[P7_HUD] visible=%s elev=%.1f hdg=%.1f range=%.0f`

---

### Step 6: Client — Shell Arc Visuals

**Files modified:**
- `src/Client/Projectiles/ProjectileVisuals.luau`

**ActiveBolt type — add field:**
```lua
artilleryGravity: number?,
currentVelocity: Vector3?,
```

**`onProjectileFired()` — store artillery data:**
When creating the ActiveBolt entry, add:
```lua
artilleryGravity = if type(payload.artilleryGravity) == "number" then payload.artilleryGravity else nil,
currentVelocity = if type(payload.artilleryGravity) == "number"
    then payload.direction * payload.speed
    else nil,
```

**`onRenderStepped()` — arc stepping:**
In the main bolt update loop, add an artillery check after the homing block and before the straight-line block:

```lua
elseif type(bolt.artilleryGravity) == "number" and bolt.artilleryGravity > 0 then
    previousPosition = bolt.currentPosition or bolt.origin
    local velocity = bolt.currentVelocity
    if velocity == nil then
        velocity = bolt.direction * bolt.speed
        bolt.currentVelocity = velocity
    end

    velocity = velocity + Vector3.new(0, -bolt.artilleryGravity * dt, 0)
    bolt.currentVelocity = velocity
    position = previousPosition + velocity * dt
    bolt.currentPosition = position

    if velocity.Magnitude > 1e-4 then
        bolt.direction = velocity.Unit
    end
```

This mirrors the server-side parabolic stepping exactly, so the client visual matches the server trajectory.

**Visual profile for artillery_shell:**
Add to `DAMAGE_TYPE_VISUAL_PROFILES`:
```lua
artillery_shell = {
    boltLengthScale = 1.8,
    boltWidthScale = 2.2,
    bulletScale = 1.8,
    trailWidthScale = 2.0,
    lightBrightnessScale = 1.5,
    lightRangeScale = 1.4,
    whizPitchScale = 0.6,
    impactScale = 2.0,
    impactEmitScale = 2.0,
},
```

**Smoke trail:** Add `"artillery_shell"` to the `MISSILE_DAMAGE_TYPES` table so shells get smoke trails.

**Test:** Fire artillery. Shell visually arcs through the air with smoke trail. On impact, explosion effect plays.

**AI Build Print:** `[P7_VISUAL] shell=%s created gravity=%d`

---

### Step 7: Integration + Wiring

**Files modified:**
- `src/Client/CombatClient.client.luau`

**Add ArtilleryClient require:**
```lua
local ArtilleryClient = require(clientRoot:WaitForChild("Weapons"):WaitForChild("ArtilleryClient"))
```

**Init call:**
```lua
ArtilleryClient.init(remotesFolder)
```

Place after `WeaponClient.init(remotesFolder)`.

**CombatInit.server.luau — new remote (optional):**
Add `UpdateArtilleryAim` RemoteEvent if needed, or reuse `UpdateTurretAim`. Recommendation: reuse `UpdateTurretAim` — the server doesn't need to distinguish between turret and artillery aim updates since `applyAimToRig` works the same way.

**Test:** Full end-to-end flow. Player approaches artillery emplacement, presses E, enters. WASD controls elevation/heading. HUD shows numbers. Click fires shell. Shell arcs, impacts terrain, splash damage applies to nearby entities. Hitmarker appears for splash hits. F exits.

**AI Build Print:** `[P7_SUMMARY] hit=%s damage=%d splash_count=%d`

---

## Authoring Contract: Artillery Emplacement Model

The map author creates a Model with:
- **Tags:** `CombatEntity` (on Model)
- **Attributes on Model:**
  - `ConfigId` = `"artillery_emplacement"` (string)
  - `Faction` = `"empire"` or `"rebel"` (string)
- **Children:**
  - `PrimaryPart` set (for pivot reference)
  - A `Seat` descendant tagged `TurretSeat` (validator will find it; CombatInit re-tags to `ArtillerySeat` based on weaponClass)
  - A `BasePart` descendant tagged `WeaponMount` (the barrel)
  - A `MuzzlePoint` Attachment inside the WeaponMount (barrel tip)
  - A `CameraPoint` BasePart or Attachment (camera anchor position)
  - `AimAxis` attribute on WeaponMount if the barrel's forward isn't auto-detected

This is identical to a turret model. The only difference is `ConfigId` pointing to an artillery config. The system auto-detects artillery mode from `weaponClass = "artillery"` in the weapon config.

---

## Data Flow

```
[Client: ArtilleryClient]
  WASD → heading, elevation
  → aimDirection = Vector3 from heading+elevation
  → FireWeapon remote (aimDirection)
  → UpdateTurretAim remote (aimDirection, throttled)

[Server: WeaponServer.onFireWeapon]
  → resolvePlayerTurretContext (accepts ArtillerySeat)
  → weaponClass == "artillery"
  → validate min range
  → fireArtilleryProjectile()
    → ProjectileData with artilleryGravity + currentVelocity
    → ProjectileServer.fireProjectile()
      → activeProjectiles[id] = data
      → FireAllClients({...artilleryGravity...})

[Server: ProjectileServer.stepProjectiles]
  → artilleryGravity detected
  → velocity += gravity * dt (downward)
  → position += velocity * dt
  → raycast sweep → hit detection → splash damage

[Client: ProjectileVisuals]
  → artilleryGravity in payload
  → arc stepping each frame (mirrors server)
  → shell visual follows parabolic path
  → on impact: explosion VFX + sound
```

---

## Golden Tests

### Test 17: Artillery Arc + Splash Hit
- **Added in:** Pass 7
- **Setup:** Empire artillery_emplacement at (0, 5, 0). Rebel target_dummy (hullHP=200) at (0, 5, 200). Emplacement aimed at 45 degrees elevation, heading toward target. TestHarnessEnabled = true.
- **Action:** Harness computes aim direction at 45-degree elevation toward target. Fires 1 shot via `WeaponServer.fireTestShot()`.
- **Expected:** Shell arcs through air. Impacts near target location. Splash damage (radius=25) hits target. Target takes damage (150 * 2.0 hull mult = 300, scaled by distance from impact center).
- **Pass condition:**
  - `[P7_FIRE]` log with elevation ~45
  - `[P1_FIRE]` log for the projectile
  - `[P1_HIT]` or splash hit on target
  - `[P1_DAMAGE]` log showing hull damage from artillery_shell type
  - `[P7_SUMMARY]` confirms shell landed, splash applied

### Test 18: Artillery Min Range Rejection
- **Added in:** Pass 7
- **Setup:** Empire artillery_emplacement at (0, 5, 0). Fire at very low elevation (3 degrees) so computed flat range < 100 studs.
- **Action:** Harness attempts fire with elevation = 3 degrees.
- **Expected:** Server rejects fire — computed range below minRange (100).
- **Pass condition:**
  - `[P7_MIN_RANGE]` log with range < 100
  - No `[P1_FIRE]` log

### Test 19: Artillery Ammo Depletion
- **Added in:** Pass 7
- **Setup:** Empire artillery_emplacement (ammoCapacity=8). Target at 200 studs.
- **Action:** Harness fires 9 shots (respecting reload cooldown).
- **Expected:** 8 shots fire successfully. Shot 9 refused (ammo=0).
- **Pass condition:**
  - 8x `[P1_FIRE]` logs
  - 8x `[P3_AMMO]` logs showing ammo 8→7→...→0
  - 1x `[P3_AMMO_EMPTY]` log (shot 9)

### Regression Tests
Re-run Pass 1 Tests 1-4, Pass 2 Tests 5-6, Pass 3 Tests 7-9, Pass 4 Tests 10-13. Key regression risks: resolvePlayerTurretContext change (ArtillerySeat check), ProjectileServer stepping change (new elseif branch), StartupValidator seat search change.

---

## Test Packet

### Step 1: Config + Types
- **Action:** Start playtest in Studio
- **Pass:** Output log contains `[P7_CONFIG] artillery_emplacement weapon loaded` and no `[VALIDATE_FAIL]` errors
- **Fail:** Missing config keys, type errors, validator warnings

### Step 2: Server Parabolic Physics
- **Action:** Place artillery model in Studio. Start playtest. Use `WeaponServer.fireTestShot()` via execute_luau to fire at 45-degree elevation.
- **Pass:** `[P1_FIRE]` log appears. `[P7_ARC]` log shows velocity vector with positive Y component. Projectile eventually hits ground or expires. No errors.
- **Fail:** Projectile travels in straight line, errors in stepProjectiles, no impact

### Step 3: Server Fire Handling + Seat
- **Action:** Place artillery model. Player sits in it. Fires via click.
- **Pass:** `[P7_FIRE]` log appears with elevation/heading/range. Projectile fires. Seat registration works. Proximity prompt appears.
- **Fail:** Fire command rejected, seat not found, ArtillerySeat tag missing

### Step 4: Client Artillery Controls
- **Action:** Sit in artillery. Press WASD. Hold Shift + WASD. Click to fire. Press F to exit.
- **Pass:** Barrel visually tilts with W/S. Heading rotates with A/D. Shift slows adjustment. Click fires. F exits. Camera follows aim direction.
- **Fail:** No barrel movement, controls unresponsive, camera stuck, fire doesn't work

### Step 5: Client HUD
- **Action:** Sit in artillery. Look at bottom of screen.
- **Pass:** Artillery HUD visible with ELEV, HDG, RANGE values. Values update with WASD. Ammo counter visible. No turret-specific HUD elements (heat bar, lock ready).
- **Fail:** HUD missing, values don't update, heat bar visible instead of ammo

### Step 6: Shell Arc Visuals
- **Action:** Fire artillery shell. Watch the projectile.
- **Pass:** Shell visually arcs (not straight line). Smoke trail visible. On impact: explosion VFX + sound. Shell is larger than a standard bolt.
- **Fail:** Shell travels in straight line, no smoke, no impact VFX

### Step 7: Integration
- **Action:** Full flow: approach, enter, aim, fire, observe arc, see impact + hitmarker, exit.
- **Pass:** Complete loop works. Splash damage confirmed on target. Hitmarker appears. No errors.
- **Fail:** Any step in the chain broken

---

## Critic Notes

- **No new RemoteEvents needed.** Reuses FireWeapon and UpdateTurretAim.
- **No lock-on, no auto-aim.** Artillery weaponClass skips all targeting logic.
- **No heat system.** Artillery uses ammo + fireRate for cooldown. heatMax is not set in config, so existing heat code is automatically bypassed.
- **Splash damage reuses existing infrastructure.** Just set splashRadius in weapon config.
- **Seat tag routing is the trickiest integration point.** The server uses the seat tag to validate fire commands. The client uses it to route to the right control module. Both must agree.
- **Client visual arc must match server arc.** Both use the same formula: velocity += gravity*dt downward, position += velocity*dt. Any drift means the client visual won't match where the server detects impact.
