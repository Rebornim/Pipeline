# Pass 1 Design: Core Combat Loop — Combat Framework

**Feature pass:** 1 of 23+
**Based on:** feature-passes.md, idea-locked.md
**Existing code:** None (greenfield)
**Critic Status:** APPROVED (self-review, first pass)
**Date:** 2026-02-18

---

## What This Pass Adds

A player sits in a ground turret, aims with the mouse, and fires blaster bolts. Server calculates projectile paths mathematically (no physics objects), detects hits via raycasts, and applies hull damage. Targets and turrets have hull HP. 0 HP = destroyed, respawn after a timer. Same-faction entities can't damage each other. Clients render visual-only bolts. A basic crosshair HUD appears when seated.

The entire combat pipeline is proven: input → fire → projectile → hit detection → damage → destruction → respawn.

---

## Rojo Project File

**File:** `projects/combat-framework/default.project.json`

```json
{
  "name": "CombatFramework",
  "tree": {
    "$className": "DataModel",
    "ReplicatedStorage": {
      "CombatFramework": {
        "$path": "src/Shared"
      }
    },
    "ServerScriptService": {
      "CombatFramework": {
        "$path": "src/Server"
      }
    },
    "StarterPlayer": {
      "StarterPlayerScripts": {
        "CombatFramework": {
          "$path": "src/Client"
        }
      }
    }
  }
}
```

This means:
- `src/Shared/*` → `ReplicatedStorage.CombatFramework.*`
- `src/Server/*` → `ServerScriptService.CombatFramework.*`
- `src/Client/*` → `StarterPlayer.StarterPlayerScripts.CombatFramework.*`

Require paths use absolute service references (not relative `script.Parent` chains).

---

## File Changes

### New Files

| File | Location | Purpose |
|------|----------|---------|
| `src/Shared/CombatTypes.luau` | ReplicatedStorage | All shared type definitions |
| `src/Shared/CombatConfig.luau` | ReplicatedStorage | All config values, sectioned |
| `src/Shared/CombatEnums.luau` | ReplicatedStorage | Enum tables for damage types, factions, states |
| `src/Server/CombatInit.server.luau` | ServerScriptService | Server entry point: creates remotes, inits modules, registers entities, runs test harness |
| `src/Server/Projectiles/ProjectileServer.luau` | ServerScriptService | Server-side projectile math, stepping, hit detection |
| `src/Server/Health/HealthManager.luau` | ServerScriptService | Entity registration, hull HP, damage application, destruction, respawn |
| `src/Server/Weapons/WeaponServer.luau` | ServerScriptService | Fire request validation, rate limiting, projectile creation |
| `src/Server/Authoring/StartupValidator.luau` | ServerScriptService | Scans workspace for tagged entities, validates tags/attributes/children |
| `src/Server/TestHarness/Runner.luau` | ServerScriptService | Test orchestrator — runs active pass tests |
| `src/Server/TestHarness/Pass1_Test.luau` | ServerScriptService | Pass 1 test scenarios |
| `src/Client/CombatClient.client.luau` | StarterPlayerScripts | Client entry point: waits for remotes, inits client modules |
| `src/Client/Projectiles/ProjectileVisuals.luau` | StarterPlayerScripts | Renders visual-only bolt parts along server-provided paths |
| `src/Client/Weapons/WeaponClient.luau` | StarterPlayerScripts | Seat detection, input binding, fire requests, barrel rotation, F-key exit |
| `src/Client/HUD/CombatHUD.luau` | StarterPlayerScripts | Creates ScreenGui, crosshair element, HP display |

### Modified Files

None (greenfield).

---

## Tagging Convention

Combat entities in workspace use CollectionService tags and attributes.

**Tags (CollectionService):**
- `CombatEntity` — on the root Model of any entity that participates in combat (turrets, targets, ships)
- `TurretSeat` — on the Seat part inside a turret model
- `WeaponMount` — on the BasePart/Attachment where projectiles originate

**Attributes (on the CombatEntity Model):**
- `Faction: string` — `"empire"`, `"rebel"`, or `"neutral"`
- `ConfigId: string` — key into `CombatConfig.Entities` (e.g., `"blaster_turret"`, `"target_dummy"`)

**Entity IDs:** Auto-generated at runtime by the server (`entity_1`, `entity_2`, ...). Stored as an attribute `EntityId: string` on the model so clients can read it.

**Placeholder model structure (turret):**
```
BlasterTurret (Model) [Tag: CombatEntity] {Faction: "empire", ConfigId: "blaster_turret"}
├── Base (Part) — anchored block, turret platform
├── Barrel (Part) — cylinder, rotates visually on client [Tag: WeaponMount]
│   └── MuzzlePoint (Attachment) — at barrel tip, projectile origin
└── Seat (Seat) [Tag: TurretSeat] — player sits here
    └── ProximityPrompt — added programmatically by server at startup
```

**Placeholder model structure (target):**
```
TargetDummy (Model) [Tag: CombatEntity] {Faction: "rebel", ConfigId: "target_dummy"}
├── Body (Part) — anchored block, the hitbox
└── (no seat, no weapon mount)
```

---

## New Data Structures

```lua
-- CombatTypes.luau

-- === WEAPON CONFIG ===
export type WeaponConfig = {
    damageType: string,       -- CombatEnums.DamageType value
    damage: number,           -- HP removed per hit
    fireRate: number,         -- max rounds per second
    projectileSpeed: number,  -- studs per second
    maxRange: number,         -- studs, projectile despawns beyond this
}

-- === ENTITY CONFIG ===
export type EntityConfig = {
    hullHP: number,           -- max hull HP
    weaponId: string?,        -- key into CombatConfig.Weapons (nil = unarmed)
    respawnTime: number?,     -- seconds until respawn after destruction (nil = no respawn)
}

-- === RUNTIME STATE ===
export type HealthState = {
    entityId: string,
    instance: Model,
    faction: string,
    config: EntityConfig,
    currentHP: number,
    maxHP: number,
    state: string,            -- CombatEnums.EntityState value
    respawnTimer: thread?,    -- active respawn coroutine (nil if not respawning)
}

-- === PROJECTILE ===
export type ProjectileData = {
    projectileId: string,
    sourceEntityId: string,   -- entity that fired
    sourceInstance: Model,    -- model to exclude from raycasts
    origin: Vector3,          -- world-space start position
    direction: Vector3,       -- unit vector
    speed: number,            -- studs/sec
    maxRange: number,         -- studs
    damage: number,
    damageType: string,
    faction: string,          -- shooter's faction
    createdAt: number,        -- tick() at creation
}

-- === VALIDATED ENTITY (startup output) ===
export type ValidatedEntity = {
    instance: Model,
    configId: string,
    faction: string,
    weaponMount: BasePart?,   -- nil for unarmed entities
    muzzlePoint: Attachment?, -- nil if no MuzzlePoint attachment on weapon mount
    turretSeat: Seat?,        -- nil for non-turret entities
}

-- === REMOTE PAYLOADS ===
-- FireWeapon (Client -> Server)
-- Arg: aimDirection: Vector3 (unit vector from client camera ray)

-- ProjectileFired (Server -> AllClients)
export type ProjectileFiredPayload = {
    projectileId: string,
    origin: Vector3,
    direction: Vector3,
    speed: number,
    maxRange: number,
}

-- DamageApplied (Server -> AllClients)
export type DamagePayload = {
    entityId: string,
    newHP: number,
    maxHP: number,
    hitPosition: Vector3,
}

-- EntityDestroyed (Server -> AllClients)
-- Arg: entityId: string

-- EntityRespawned (Server -> AllClients)
export type RespawnedPayload = {
    entityId: string,
    hullHP: number,
}
```

```lua
-- CombatEnums.luau

local CombatEnums = {}

CombatEnums.DamageType = {
    Blaster = "blaster",
    -- Future passes add: Turbolaser, Ion, Torpedo, Missile
}

CombatEnums.Faction = {
    Empire = "empire",
    Rebel = "rebel",
    Neutral = "neutral",
}

CombatEnums.EntityState = {
    Active = "active",
    Destroyed = "destroyed",
    Respawning = "respawning",
}

return CombatEnums
```

---

## New Config Values

```lua
-- CombatConfig.luau

local CombatConfig = {}

-- === WEAPON DEFINITIONS ===
-- Each key is a weaponId referenced by EntityConfig.weaponId
CombatConfig.Weapons = {
    blaster_turret = {
        damageType = "blaster",
        damage = 10,              -- HP per hit
        fireRate = 3,             -- shots/sec (cooldown = 1/fireRate = 0.333s)
        projectileSpeed = 300,    -- studs/sec
        maxRange = 500,           -- studs
    },
}

-- === ENTITY DEFINITIONS ===
-- Each key is a configId referenced by model attribute
CombatConfig.Entities = {
    blaster_turret = {
        hullHP = 100,
        weaponId = "blaster_turret",
        respawnTime = 15,         -- seconds
    },
    target_dummy = {
        hullHP = 200,
        weaponId = nil,           -- unarmed
        respawnTime = 10,         -- seconds
    },
}

-- === PROJECTILE SETTINGS ===
CombatConfig.ProjectileRayRadius = 0.5   -- studs, spherecast radius for hit detection. 0 = raycast.

-- === TURRET SETTINGS ===
CombatConfig.TurretPromptText = "Man Turret"
CombatConfig.TurretPromptDistance = 10    -- studs, proximity prompt activation range

-- === VISUAL SETTINGS (client) ===
CombatConfig.BoltLength = 2              -- studs
CombatConfig.BoltWidth = 0.2             -- studs
CombatConfig.BoltColor = Color3.fromRGB(255, 0, 0)  -- red blaster bolt
CombatConfig.BoltMaterial = Enum.Material.Neon

-- === TEST HARNESS ===
CombatConfig.TestHarnessEnabled = false  -- set true to run automated tests on startup
CombatConfig.ActiveTestPass = 1          -- which pass's tests to run

return CombatConfig
```

---

## RemoteEvents

All created by CombatInit.server.luau inside a Folder at `ReplicatedStorage.CombatRemotes`.

| Name | Direction | Payload | Purpose |
|------|-----------|---------|---------|
| `FireWeapon` | Client → Server | `aimDirection: Vector3` | Player requests to fire |
| `ProjectileFired` | Server → All Clients | `ProjectileFiredPayload` table | Client renders visual bolt |
| `DamageApplied` | Server → All Clients | `DamagePayload` table | Client updates HP display |
| `EntityDestroyed` | Server → All Clients | `entityId: string` | Client shows destruction |
| `EntityRespawned` | Server → All Clients | `RespawnedPayload` table | Client restores visuals |

Total: 5 RemoteEvents. 1 inbound, 4 outbound.

---

## New/Modified APIs

### CombatInit.server.luau

No public API — this is the server entry point script.

Internal flow:
```lua
-- 1. Create ReplicatedStorage.CombatRemotes folder with all 5 RemoteEvents
-- 2. Call StartupValidator.validate() → get list of ValidatedEntity
-- 3. Call HealthManager.init(remotesFolder)
-- 4. Call ProjectileServer.init(remotesFolder)
-- 5. Call WeaponServer.init(remotesFolder)
-- 6. For each ValidatedEntity:
--      a. Generate entityId ("entity_1", "entity_2", ...)
--      b. Set entity.instance:SetAttribute("EntityId", entityId)
--      c. Call HealthManager.registerEntity(entityId, validatedEntity)
--      d. If entity has turretSeat: add ProximityPrompt to seat
-- 7. If CombatConfig.TestHarnessEnabled:
--      Call Runner.run()
```

### StartupValidator.luau

```lua
local StartupValidator = {}

-- Scans workspace for all models tagged "CombatEntity" via CollectionService.
-- For each: validates Faction attribute, ConfigId attribute, ConfigId exists in CombatConfig.Entities.
-- If ConfigId has a weaponId: validates WeaponMount tagged child exists.
-- If entity type has a seat: validates TurretSeat tagged child exists.
-- Prints [P1_VALIDATE] for each entity (pass or fail).
-- Returns only entities that pass all checks. Failing entities are skipped with warnings.
function StartupValidator.validate(): { CombatTypes.ValidatedEntity }
```

### HealthManager.luau

```lua
local HealthManager = {}

-- Stores reference to remotes folder. Creates internal state tables.
function HealthManager.init(remotes: Folder): ()

-- Registers a combat entity. Creates HealthState entry.
-- Sets initial HP from config. State = Active.
function HealthManager.registerEntity(entityId: string, validated: CombatTypes.ValidatedEntity): ()

-- Applies damage to an entity.
-- Returns false if: entity not found, entity not alive, same faction (friendly fire).
-- On success: decrements HP, fires DamageApplied remote.
-- If HP <= 0: calls internal destroy flow.
function HealthManager.applyDamage(
    entityId: string,
    damage: number,
    damageType: string,
    attackerFaction: string,
    hitPosition: Vector3
): boolean

-- Returns current HealthState for an entity, or nil if not registered.
function HealthManager.getHealth(entityId: string): CombatTypes.HealthState?

-- Returns true if entity exists and state == Active.
function HealthManager.isAlive(entityId: string): boolean

-- Returns faction string for entity, or nil if not registered.
function HealthManager.getFaction(entityId: string): string?

-- Given a workspace Instance (from a raycast hit), walks up parent chain
-- to find a registered CombatEntity model. Returns entityId or nil.
function HealthManager.findEntityFromInstance(instance: Instance): string?
```

**Internal destroy flow (private):**
1. Set state to `Destroyed`
2. If turretSeat has Occupant: force `Humanoid.Sit = false` to eject player
3. Set all BasePart descendants to `Transparency = 1` and `CanCollide = false` (store originals for respawn)
4. Fire `EntityDestroyed:FireAllClients(entityId)`
5. If config.respawnTime: spawn coroutine → `task.wait(respawnTime)` → call internal respawn flow

**Internal respawn flow (private):**
1. Restore all BasePart descendants to original Transparency and CanCollide values
2. Reset currentHP to maxHP, state to Active
3. Fire `EntityRespawned:FireAllClients({ entityId = entityId, hullHP = maxHP })`

**Cleanup:** `Players.PlayerRemoving` — no per-player state in HealthManager for Pass 1.

### ProjectileServer.luau

```lua
local ProjectileServer = {}

-- Stores remotes reference. Connects single Heartbeat listener for projectile stepping.
-- Creates shared RaycastParams (Exclude filter type).
function ProjectileServer.init(remotes: Folder): ()

-- Adds projectile to active table. Fires ProjectileFired remote to all clients.
function ProjectileServer.fireProjectile(data: CombatTypes.ProjectileData): ()

-- Returns count of currently active projectiles (for diagnostics).
function ProjectileServer.getActiveCount(): number
```

**Internal Heartbeat step loop (private):**
For each active projectile every frame:
1. Calculate elapsed time: `tick() - proj.createdAt`
2. Calculate current position: `proj.origin + proj.direction * proj.speed * elapsed`
3. Calculate previous position: same formula with `(elapsed - dt)`
4. Check distance from origin: if `>= proj.maxRange`, remove projectile, log `[P1_EXPIRED]`
5. Set RaycastParams filter to exclude `proj.sourceInstance` descendants
6. Spherecast from prevPos toward currentPos (radius = `CombatConfig.ProjectileRayRadius`)
7. If hit:
   - Call `HealthManager.findEntityFromInstance(rayResult.Instance)`
   - If entity found and alive: call `HealthManager.applyDamage(entityId, proj.damage, proj.damageType, proj.faction, rayResult.Position)`
   - Remove projectile from active table
8. Collect IDs to remove, then batch-remove after iteration (avoid mutating during iteration)

**Cleanup:** Heartbeat connection disconnected if module is ever cleaned up (not expected in Pass 1).

### WeaponServer.luau

```lua
local WeaponServer = {}

-- Stores remotes reference. Connects FireWeapon remote listener.
-- Creates per-player cooldown tracking table.
function WeaponServer.init(remotes: Folder): ()
```

**Internal FireWeapon handler (private):**
When `FireWeapon` remote fires from a client:
1. Get player's Character → Humanoid → check `Humanoid.SeatPart`
2. If not seated: reject (return silently)
3. Check if seatPart has tag `TurretSeat`: if not, reject
4. Walk up from seatPart to find parent Model with `EntityId` attribute → get entityId
5. Check `HealthManager.isAlive(entityId)`: if not, reject
6. Check fire rate cooldown: `lastFireTime[player]` must be at least `1/weaponConfig.fireRate` ago. If too soon, reject.
7. Get weapon config: `CombatConfig.Weapons[entityConfig.weaponId]`
8. Get fire origin: MuzzlePoint attachment WorldPosition (from WeaponMount child), or WeaponMount Position if no attachment
9. Validate aimDirection is a unit vector (normalize it server-side regardless)
10. Create `ProjectileData`:
    - `projectileId`: `"proj_" .. incrementing counter`
    - `sourceEntityId`: entityId
    - `sourceInstance`: entity model
    - `origin`: fire origin position
    - `direction`: aimDirection (normalized)
    - `speed`, `maxRange`, `damage`, `damageType`: from weapon config
    - `faction`: entity's faction
    - `createdAt`: `tick()`
11. Call `ProjectileServer.fireProjectile(data)`
12. Update `lastFireTime[player] = tick()`

**Cleanup:** `Players.PlayerRemoving` → remove player from `lastFireTime` table.

### CombatClient.client.luau

No public API — this is the client entry point script.

Internal flow:
```lua
-- 1. Wait for ReplicatedStorage.CombatRemotes folder to exist
-- 2. Get references to all 5 RemoteEvents
-- 3. Call WeaponClient.init(remotes)
-- 4. Call ProjectileVisuals.init(remotes)
-- 5. Call CombatHUD.init()
-- 6. Connect remote listeners:
--      DamageApplied → CombatHUD.onDamageApplied(payload)
--      EntityDestroyed → CombatHUD.onEntityDestroyed(entityId) + visual fade
--      EntityRespawned → CombatHUD.onEntityRespawned(payload) + visual restore
```

**EntityDestroyed client handling:**
- Find the Model in workspace by iterating CombatEntity-tagged models and checking EntityId attribute
- Set all BasePart descendants to Transparency = 1 (same as server)

**EntityRespawned client handling:**
- Find the Model, restore Transparency to 0 (reset to visible)
- CombatHUD updates HP if player is seated in that entity

### WeaponClient.luau

```lua
local WeaponClient = {}

-- Stores remote reference. Connects Humanoid.Seated listener for turret detection.
function WeaponClient.init(remotes: Folder): ()
```

**Internal seat detection (private):**
```
Humanoid.Seated:Connect(function(isSeated, seatPart)
    if isSeated and seatPart has tag "TurretSeat":
        activeTurret = seatPart parent Model
        Bind mouse click → onFire()
        Bind F key → onExitTurret()
        Connect RenderStepped → updateBarrelRotation()
        CombatHUD.showCrosshair(true)
        CombatHUD.showHP(activeTurret EntityId)
    else if was in turret:
        Unbind mouse click
        Unbind F key
        Disconnect barrel rotation
        CombatHUD.showCrosshair(false)
        CombatHUD.hideHP()
        activeTurret = nil
```

**onFire (private):**
1. Get mouse position via `UserInputService:GetMouseLocation()`
2. Cast ray from camera through screen point: `Camera:ViewportPointToRay(mousePos.X, mousePos.Y)`
3. Calculate aim direction: unit vector from WeaponMount world position toward a point far along the camera ray
4. Fire `FireWeapon:FireServer(aimDirection)`

**onExitTurret (private):**
1. `localPlayer.Character.Humanoid.Sit = false`

**updateBarrelRotation (private, RenderStepped):**
1. Get camera look target: camera ray from mouse position, intersect with a plane far away
2. Set barrel part CFrame to `CFrame.lookAt(barrelPosition, lookTarget)` (Y-axis rotation only for horizontal turret)
3. Purely cosmetic — does not affect server calculations

**Cleanup:** All input binds use ContextActionService or store connection references. Disconnected on seat exit.

### ProjectileVisuals.luau

```lua
local ProjectileVisuals = {}

-- Connects ProjectileFired remote listener.
function ProjectileVisuals.init(remotes: Folder): ()
```

**Internal onProjectileFired handler (private):**
1. Receive `ProjectileFiredPayload` from server
2. Create bolt Part:
   - Size: `Vector3.new(BoltWidth, BoltWidth, BoltLength)` from config
   - Color: `CombatConfig.BoltColor`
   - Material: `CombatConfig.BoltMaterial`
   - Anchored = true, CanCollide = false, CanQuery = false, CanTouch = false
   - CastShadow = false
   - Parent: workspace (or a dedicated Folder for cleanup)
3. Store bolt data: `{ part, origin, direction, speed, maxRange, createdAt = tick() }`
4. Bolt is updated in a single RenderStepped connection (shared across all active bolts):
   - Calculate position: `origin + direction * speed * elapsed`
   - Update CFrame: `CFrame.lookAt(position, position + direction)` (bolt points along travel direction)
   - If distance from origin >= maxRange: destroy part, remove from active list
5. Active bolt table cleaned up as bolts expire

**Cleanup:** RenderStepped connection is a single persistent connection. Individual bolt Parts are destroyed on expiry.

### CombatHUD.luau

```lua
local CombatHUD = {}

-- Creates ScreenGui with crosshair and HP display elements. Hidden by default.
function CombatHUD.init(): ()

-- Shows/hides the crosshair (centered screen dot/cross).
function CombatHUD.showCrosshair(visible: boolean): ()

-- Shows HP display for the entity the player is seated in.
-- Reads current HP from entity's attributes or from cached remote data.
function CombatHUD.showHP(entityId: string): ()

-- Hides the HP display.
function CombatHUD.hideHP(): ()

-- Called when DamageApplied remote fires. Updates HP bar if this entity matches.
function CombatHUD.onDamageApplied(payload: CombatTypes.DamagePayload): ()

-- Called when EntityDestroyed remote fires.
function CombatHUD.onEntityDestroyed(entityId: string): ()

-- Called when EntityRespawned remote fires.
function CombatHUD.onEntityRespawned(payload: CombatTypes.RespawnedPayload): ()
```

**HUD Elements (programmer-art):**
- `ScreenGui "CombatHUD"` → parented to `PlayerGui`
- Crosshair: `TextLabel` centered on screen, text = `"+"`, size 30x30, white, no background. Hidden by default.
- HP Display: `Frame` at top-left.
  - `TextLabel` showing `"Hull: 90 / 100"` — updates on DamageApplied
  - Simple, functional. No health bar graphics for Pass 1.

---

## Data Flow for New Behaviors

### Player Enters Turret
1. Player walks near turret → sees ProximityPrompt "Man Turret"
2. Player presses E → ProximityPrompt.Triggered fires on server
3. Server: `seat:Sit(player.Character.Humanoid)` — seats the player
4. Client: `Humanoid.Seated` event fires with `(true, seatPart)`
5. WeaponClient detects TurretSeat tag → activates turret mode
6. CombatHUD shows crosshair + HP display
7. WeaponClient binds mouse click, F key, barrel rotation

### Player Fires
1. Client: mouse click → WeaponClient calculates aim direction from camera ray
2. Client: fires `FireWeapon:FireServer(aimDirection)`
3. Server: WeaponServer validates (seated, alive, cooldown) → creates ProjectileData
4. Server: `ProjectileServer.fireProjectile(data)` → adds to active table → fires `ProjectileFired:FireAllClients(payload)`
5. Client (all): ProjectileVisuals creates bolt Part, steps it each frame
6. Server: Heartbeat steps projectile, spherecasts for hits

### Projectile Hits Target
1. Server: ProjectileServer spherecast hits a Part
2. Server: `HealthManager.findEntityFromInstance(hitPart)` → returns entityId
3. Server: `HealthManager.applyDamage(entityId, damage, damageType, faction, hitPos)` → returns true
4. Server: HealthManager decrements HP → fires `DamageApplied:FireAllClients(payload)`
5. Client (all): CombatHUD.onDamageApplied updates HP display if player is in that entity

### Target Destruction
1. Server: HP reaches 0 inside applyDamage → internal destroy flow
2. Server: eject seated player (if any), set parts transparent/non-collidable
3. Server: fires `EntityDestroyed:FireAllClients(entityId)`
4. Server: starts respawn timer coroutine
5. Client (all): fade entity model (transparency)

### Target Respawn
1. Server: respawn timer completes → internal respawn flow
2. Server: restore parts, reset HP, state = Active
3. Server: fires `EntityRespawned:FireAllClients(payload)`
4. Client (all): restore entity model visibility

### Player Exits Turret
1. Client: player presses F → `Humanoid.Sit = false`
2. Character stands up from seat
3. Client: `Humanoid.Seated` fires with `(false, nil)`
4. WeaponClient deactivates, unbinds input, disconnects barrel rotation
5. CombatHUD hides crosshair + HP display

---

## Integration Pass

Since this is a greenfield pass, integration checks focus on cross-module consistency.

### Data Lifecycle Traces

**EntityId**
- **Created by:** CombatInit generates `"entity_1"`, `"entity_2"`, etc.
- **Passed via:** Set as attribute on Model (`SetAttribute("EntityId", id)`), passed as arg to `HealthManager.registerEntity`
- **Received by:** HealthManager stores in internal table. WeaponServer reads from model attribute. Client reads from model attribute.
- **Stored in:** HealthManager `entities` table (keyed by entityId). Model attribute persists on Instance.
- **Cleaned up by:** Entity is permanent in Pass 1 (respawns forever). Table entry never removed.

**ProjectileData**
- **Created by:** WeaponServer.onFireWeapon handler
- **Passed via:** Direct function call to `ProjectileServer.fireProjectile(data)`
- **Received by:** ProjectileServer, added to `activeProjectiles` table
- **Stored in:** `activeProjectiles[projectileId]`, lifetime = until hit or max range
- **Cleaned up by:** ProjectileServer Heartbeat loop removes on hit/expiry

**ProjectileFiredPayload**
- **Created by:** ProjectileServer.fireProjectile — extracts subset of ProjectileData
- **Passed via:** `ProjectileFired:FireAllClients(payload)` remote
- **Received by:** ProjectileVisuals.onProjectileFired handler
- **Stored in:** `activeBolts` table on client, lifetime = until visual reaches max range
- **Cleaned up by:** RenderStepped loop destroys Part and removes from table on expiry

**DamagePayload**
- **Created by:** HealthManager.applyDamage — after successful damage
- **Passed via:** `DamageApplied:FireAllClients(payload)` remote
- **Received by:** CombatClient → CombatHUD.onDamageApplied
- **Stored in:** Not stored — applied immediately to HUD text
- **Cleaned up by:** N/A (transient)

### API Composition Checks

| Caller | Callee | Args Match | Return Handled | Notes |
|--------|--------|-----------|----------------|-------|
| CombatInit | StartupValidator.validate() | No args | Returns {ValidatedEntity} — iterated | Greenfield, both new |
| CombatInit | HealthManager.registerEntity(id, validated) | string, ValidatedEntity | void | Greenfield |
| WeaponServer handler | ProjectileServer.fireProjectile(data) | ProjectileData | void | Types defined in shared |
| ProjectileServer step | HealthManager.findEntityFromInstance(inst) | Instance | string? — nil checked | Parent walk, nil = ignore hit |
| ProjectileServer step | HealthManager.isAlive(id) | string | boolean | Dead entities ignored |
| ProjectileServer step | HealthManager.applyDamage(id, dmg, type, faction, pos) | string, number, string, string, Vector3 | boolean — true = applied | Faction check inside |

### Remote Payload Consistency

| Remote | Server sends | Client expects | Match |
|--------|-------------|----------------|-------|
| ProjectileFired | table with projectileId, origin, direction, speed, maxRange | Same fields read by ProjectileVisuals | Yes |
| DamageApplied | table with entityId, newHP, maxHP, hitPosition | Same fields read by CombatHUD | Yes |
| EntityDestroyed | string entityId | string received by CombatClient | Yes |
| EntityRespawned | table with entityId, hullHP | Same fields read by CombatClient/CombatHUD | Yes |
| FireWeapon | Vector3 aimDirection from client | Vector3 received by WeaponServer | Yes |

---

## Diagnostics / AI Build Prints

### Tags

All Pass 1 prints use `[P1_TEST]` prefix or specific sub-tags:

| Tag | When | Data |
|-----|------|------|
| `[P1_VALIDATE]` | Startup entity validation | entity name, pass/fail, reason |
| `[P1_FIRE]` | Projectile created | projectileId, sourceEntityId, direction, speed |
| `[P1_HIT]` | Projectile hits entity | projectileId, targetEntityId, hitPosition |
| `[P1_DAMAGE]` | Damage applied | entityId, oldHP → newHP, damageType |
| `[P1_FACTION_BLOCK]` | Damage blocked by faction | sourceEntityId → targetEntityId, faction |
| `[P1_DESTROYED]` | Entity destroyed | entityId, tick |
| `[P1_RESPAWNED]` | Entity respawned | entityId, hullHP, tick |
| `[P1_EXPIRED]` | Projectile reached max range | projectileId, distance |
| `[P1_SUMMARY]` | Test run complete | totals for shots, hits, kills, respawns, faction blocks, pass/fail |

### Marker Format

```
========== START READ HERE (P1) ==========
[P1_VALIDATE] BlasterTurret: PASS (empire, blaster_turret, seat OK, mount OK)
[P1_VALIDATE] TargetDummy: PASS (rebel, target_dummy, no seat required, no mount required)
[P1_FIRE] proj_1: from entity_1, dir=(0.00, 0.00, 1.00), speed=300
[P1_HIT] proj_1: hit entity_2 at (0.00, 5.00, 50.00)
[P1_DAMAGE] entity_2: 200 -> 190 (blaster, -10)
...
[P1_SUMMARY] Shots:20 | Hits:15 | Expired:5 | Kills:1 | Respawns:1 | FactionBlocks:3 | PASS
========== END READ HERE (P1) ==========
```

### Where to Place Prints

- `[P1_VALIDATE]`: StartupValidator.validate(), one per entity
- `[P1_FIRE]`: ProjectileServer.fireProjectile()
- `[P1_HIT]`: ProjectileServer Heartbeat loop, on successful hit
- `[P1_DAMAGE]`: HealthManager.applyDamage(), on successful damage
- `[P1_FACTION_BLOCK]`: HealthManager.applyDamage(), on faction rejection
- `[P1_DESTROYED]`: HealthManager internal destroy flow
- `[P1_RESPAWNED]`: HealthManager internal respawn flow
- `[P1_EXPIRED]`: ProjectileServer Heartbeat loop, on max range
- `[P1_SUMMARY]`: Pass1_Test.luau, after all test scenarios complete

---

## Startup Validator Checks

| Contract | Check | Error Message |
|----------|-------|---------------|
| CombatEntity has Faction attribute | `model:GetAttribute("Faction") ~= nil` | `"[VALIDATE_FAIL] {name}: missing Faction attribute"` |
| CombatEntity has ConfigId attribute | `model:GetAttribute("ConfigId") ~= nil` | `"[VALIDATE_FAIL] {name}: missing ConfigId attribute"` |
| ConfigId exists in CombatConfig.Entities | `CombatConfig.Entities[configId] ~= nil` | `"[VALIDATE_FAIL] {name}: unknown ConfigId '{configId}'"` |
| Armed entity has WeaponMount child | If config has weaponId: tagged child exists | `"[VALIDATE_FAIL] {name}: has weaponId but no WeaponMount tagged child"` |
| Turret entity has TurretSeat child | If config has weaponId: tagged child exists | `"[VALIDATE_FAIL] {name}: has weaponId but no TurretSeat tagged child"` |
| Faction value is valid | Value is in CombatEnums.Faction values | `"[VALIDATE_FAIL] {name}: invalid Faction '{faction}'"` |
| WeaponId exists in CombatConfig.Weapons | If config.weaponId: exists in Weapons table | `"[VALIDATE_FAIL] {name}: weaponId '{weaponId}' not found in CombatConfig.Weapons"` |

---

## Test Harness

### Runner.luau

```lua
-- Called by CombatInit when CombatConfig.TestHarnessEnabled == true.
-- Reads CombatConfig.ActiveTestPass to determine which test module to run.
-- Pass 1: requires Pass1_Test and calls Pass1_Test.run()

function Runner.run(): ()
```

### Pass1_Test.luau

Creates placeholder models in workspace, waits for CombatInit to register them, then runs test scenarios.

**Setup phase:**
1. Create placeholder turret model (empire faction) at `Vector3.new(0, 5, 0)`
2. Create placeholder target model (rebel faction) at `Vector3.new(0, 5, 50)`
3. Tag both with `CombatEntity`, set attributes, tag children
4. Print `START READ HERE (P1)` marker
5. Wait one frame for CombatInit entity registration to process them (use CollectionService.GetInstanceAddedSignal or a short yield)

**Actually — the test harness creates placeholder models BEFORE CombatInit registers entities.** Better flow: CombatInit should call Runner AFTER registering all initially-present entities. The harness creates additional test entities, then manually calls registration through a test API or by adding them to workspace so CollectionService picks them up.

Revised: CombatInit registers existing workspace entities first. Then runs test harness. Test harness creates placeholder models, adds CombatEntity tag, and CombatInit's CollectionService listener picks them up and registers them. OR: the test harness handles its own entity setup.

**Simplest approach:** The test harness IS the placeholder setup. If `TestHarnessEnabled`, the harness creates and tags placeholder models BEFORE CombatInit scans for entities. So the flow in CombatInit is:

```
1. Create remotes
2. Init modules
3. If TestHarnessEnabled: Runner.setup() -- creates placeholder models in workspace
4. StartupValidator.validate() -- finds all tagged models including harness placeholders
5. Register all validated entities
6. If TestHarnessEnabled: Runner.run() -- runs test scenarios against registered entities
```

**Test scenarios (in Pass1_Test.run()):**

**Scenario 1: Direct Fire → Hit → Damage**
1. Get turret entityId and target entityId from their model attributes
2. Calculate direction: `(targetPos - turretMuzzlePos).Unit`
3. Create 5 ProjectileData entries (spaced 0.4s apart to respect fire rate)
4. For each: call `ProjectileServer.fireProjectile(data)`, wait for Heartbeat steps
5. After all projectiles resolved: read target HP from `HealthManager.getHealth(targetEntityId)`
6. Assert: target HP == 200 - (5 * 10) == 150
7. Log result

**Scenario 2: Friendly Fire Block**
1. Create second turret model, same faction as first turret (both empire)
2. Register it (tag it, let validator pick it up — OR call HealthManager.registerEntity directly for test simplicity)
3. Fire 3 projectiles from turret 1 at turret 2 (same faction)
4. Assert: turret 2 HP unchanged, [P1_FACTION_BLOCK] logs appeared
5. Clean up second turret

**Scenario 3: Destruction + Respawn**
1. Override target config or use a low-HP target (hullHP = 30, damage = 10 → 3 hits to kill)
2. Fire 3 projectiles, wait for all to resolve
3. Assert: target state == Destroyed
4. Wait for respawnTime + 1 second buffer
5. Assert: target state == Active, HP == 30
6. Log result

**Scenario 4: Max Range Expiry**
1. Create a far target at distance 1000 (max range = 500)
2. Fire 3 projectiles toward it
3. Wait for projectiles to travel max range (500/300 = ~1.67 seconds)
4. Assert: 0 hits on far target, [P1_EXPIRED] logs for all 3 projectiles
5. Clean up far target

**After all scenarios:** Print `[P1_SUMMARY]` with aggregated counts. Print `END READ HERE (P1)`.

---

## Golden Tests for This Pass

### Test 1: Direct Fire Hits
- **Setup:** Placeholder turret (empire, blaster_turret) at (0, 5, 0). Target (rebel, target_dummy, hullHP=200) at (0, 5, 50). Direct line of sight. Test harness enabled.
- **Action:** Harness fires 5 projectiles from turret at target with correct aim direction.
- **Expected:** All 5 hit. Target HP decreases from 200 to 150 (5 hits × 10 damage).
- **Pass condition:** 5 `[P1_HIT]` logs, 5 `[P1_DAMAGE]` logs each showing -10, target HP reads 150.

### Test 2: Friendly Fire Prevention
- **Setup:** Two empire-faction entities. Harness fires from one at the other.
- **Action:** 3 fire attempts, same faction.
- **Expected:** 0 damage applied. All blocked.
- **Pass condition:** 3 `[P1_FACTION_BLOCK]` logs. 0 `[P1_DAMAGE]` logs for that target. Target HP unchanged.

### Test 3: Destruction + Respawn
- **Setup:** Target with hullHP=30, respawnTime=5. Turret with damage=10.
- **Action:** Harness fires 3 shots (enough to kill). Waits 6 seconds.
- **Expected:** Target destroyed after 3 hits. Respawns ~5 seconds later with full HP.
- **Pass condition:** `[P1_DESTROYED]` log, then `[P1_RESPAWNED]` log 5±1 seconds later. Target HP back to 30.

### Test 4: Max Range Expiry
- **Setup:** Target at 1000 studs from turret. Weapon max range = 500.
- **Action:** 3 shots fired toward distant target.
- **Expected:** All 3 projectiles expire at ~500 studs. 0 hits.
- **Pass condition:** 3 `[P1_EXPIRED]` logs. 0 `[P1_HIT]` logs. Summary confirms 0 hits.

### Regression Tests
None (first pass).

---

## Prove Step: User Visual Checks

After the test harness passes, the user should manually verify in Studio:

1. **Enter turret:** Walk to turret, see "Man Turret" prompt, press E, sit down
2. **Crosshair:** Centered "+" appears on screen. HP display appears.
3. **Fire:** Click mouse — visible red bolt travels from turret toward where you aimed
4. **Bolt visual:** Bolt is visible, moves at reasonable speed, disappears at max range
5. **Hit:** Aim at target, fire — bolt hits, HP display on target updates (if visible)
6. **Exit:** Press F — stand up, crosshair disappears
7. **Barrel rotation:** While seated, move mouse — barrel visually follows aim direction

---

## Security Boundaries

- **Server-authoritative hit detection.** Client sends only aim direction. Server calculates projectile path, performs raycasts, determines hits. Client cannot fake hits.
- **Server-authoritative damage.** HealthManager runs only on server. Client cannot modify HP values.
- **Fire rate enforced server-side.** WeaponServer enforces cooldown regardless of how fast client sends FireWeapon.
- **Aim direction normalized server-side.** Even if client sends a non-unit vector, server normalizes it.
- **Faction check server-side.** No client can bypass friendly fire prevention.

---

## Performance Notes

- **One Heartbeat connection** for all projectiles (not per-projectile). Iterates active table.
- **One RenderStepped connection** on client for all bolt visuals. Iterates active bolts table.
- **No physics objects** for projectiles. Math-only paths.
- **Spherecast, not Part collision.** Lightweight hit detection.
- **Bolt Parts are simple:** Anchored, no collision, no shadow, neon material. Minimal rendering cost.
- **Pass 1 scale:** 1 turret, 1 target, few projectiles at a time. Performance is not a concern yet. Architecture is sound for scaling later.

---

## Critic Review Notes

Self-reviewed against critic-checklist principles for Pass 1:

- **No circular dependencies.** Module graph: CombatInit → {StartupValidator, HealthManager, ProjectileServer, WeaponServer}. WeaponServer → {ProjectileServer, HealthManager}. ProjectileServer → {HealthManager}. All arrows point one direction.
- **No per-frame allocations in hot paths.** Projectile step loop reuses RaycastParams, collects removals in pre-allocated table.
- **Cleanup paths defined.** Player fire cooldown cleaned on PlayerRemoving. Projectiles cleaned on hit/expiry. Bolt visuals cleaned on expiry.
- **No replicated physics objects.** Projectiles are math + remotes.
- **Security boundaries clear.** All authority on server.
- **Single responsibility per module.** HealthManager doesn't render. ProjectileVisuals doesn't calculate damage.

No blocking issues identified.
