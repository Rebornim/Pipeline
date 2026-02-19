# Pass 5 Design: Armed Ground Vehicles — Combat Framework

**Feature pass:** 5 of 23
**Based on:** feature-passes.md, idea-locked.md
**Existing code:** CombatConfig, CombatTypes, CombatEnums, CombatInit, StartupValidator, HealthManager, ProjectileServer, WeaponServer, WeaponRig, TargetingServer, TargetingClient, LeadSolver, CombatClient, WeaponClient, ProjectileVisuals, CombatHUD, MovingTargetController
**Critic Status:** PENDING
**Date:** 2026-02-19

---

## What This Pass Adds

Armed ground vehicles as combat entities. Vehicles use the existing combat framework for health, weapons, shields, targeting, and destruction. The existing vehicle system continues to handle driving — the combat framework bolts on top via tags and config. A gunner seat operates like any turret weapon mount. A new `DriverSeat` tag identifies the driver, provides enclosed protection, and activates a driver HUD showing vehicle health. Vehicle destruction kills all seated occupants.

**Architecture decision: Bolt-on.** The existing vehicle system is working and separate from this repo. The combat framework adds combat capability to vehicle models through the same CombatEntity tagging pattern used by turrets. No vehicle driving code is written or modified.

---

## File Changes

### New Files
| File | Location | Purpose |
|------|----------|---------|
| DriverClient.luau | Client/Vehicle/ | Detects DriverSeat occupancy, manages driver HUD (vehicle HP + shield display without weapon controls) |

### Modified Files
| File | What's Changing | Why |
|------|----------------|-----|
| CombatTypes.luau | Add `killOccupantsOnDestruction` and `spawnCFrame` to EntityConfig | Vehicle destruction kills crew, respawn restores to original position |
| CombatConfig.luau | Add vehicle entity configs (armed_speeder, shielded_transport, vehicle test targets) | Define vehicle combat stats |
| CombatInit.server.luau | Register DriverSeat tags, store spawn CFrames, restore position on respawn | Vehicle entity setup + respawn position |
| HealthManager.luau | Extend destroyEntity to find ALL seats (Seat + VehicleSeat), kill occupants when configured, store/restore spawn position | Vehicle destruction kills occupants, respawn restores position |
| ProjectileServer.luau | Extend enclosed protection check to include DriverSeat-tagged seats | Protect drivers in enclosed vehicles |
| StartupValidator.luau | Validate DriverSeat presence, warn if vehicle entity missing DriverSeat | Catch authoring errors |
| CombatClient.client.luau | Init DriverClient | Wire driver detection into client |
| CombatHUD.luau | Add driver mode functions (showDriverHUD/hideDriverHUD) showing HP+shield without weapon controls | Driver sees vehicle status |

---

## New/Modified APIs

```lua
-- DriverClient.luau (NEW)

function DriverClient.init()
-- Connects Humanoid.Seated signal to detect DriverSeat occupancy.
-- When seated in a DriverSeat inside a CombatEntity: activates driver HUD.
-- When unseated: deactivates driver HUD.

function DriverClient.isDriverSeated(): boolean
-- Returns whether local player is seated as driver. Called by WeaponClient to avoid
-- conflict (if player is in DriverSeat, WeaponClient should NOT activate turret mode).
```

```lua
-- HealthManager.luau (MODIFIED)

-- destroyEntity (internal, line ~360):
-- CURRENT: FindFirstChildWhichIsA("Seat", true) — finds only one Seat.
-- NEW: Scan ALL descendants for Seat and VehicleSeat instances.
-- For each occupied seat: if config.killOccupantsOnDestruction == true,
--   set occupant.Health = 0 (kill). Otherwise eject as before (occupant.Sit = false).
-- Emit death explosion from entity pivot (not just seat position).

-- respawn path (line ~395):
-- NEW: If spawnCFrame is stored, PivotTo(spawnCFrame) before restoring parts.
-- This restores vehicles to their original dev-placed position on respawn.
```

```lua
-- ProjectileServer.luau (MODIFIED)

-- applyDamageToHumanoidTarget (line ~83):
-- CURRENT: Checks CollectionService:HasTag(seatPart, "TurretSeat") only.
-- NEW: Also check CollectionService:HasTag(seatPart, "DriverSeat").
-- Both tags route through the same TurretExposed attribute check.
-- Replace:
--   if seatPart ~= nil and CollectionService:HasTag(seatPart, "TurretSeat") then
-- With:
--   if seatPart ~= nil and (CollectionService:HasTag(seatPart, "TurretSeat")
--       or CollectionService:HasTag(seatPart, "DriverSeat")) then
```

```lua
-- CombatInit.server.luau (MODIFIED)

-- In entity registration loop:
-- 1. Find DriverSeat: look for VehicleSeat descendants tagged "DriverSeat" (or tag them).
-- 2. Store spawn CFrame: entityModel:GetPivot() at registration time → store on HealthManager
--    via new HealthManager.setSpawnCFrame(entityId, cframe) call.
-- 3. Tag DriverSeat instances with CollectionService if authored via attributes.
```

```lua
-- CombatHUD.luau (MODIFIED)

function CombatHUD.showDriverHUD(entityId: string)
-- Shows HP bar + shield bar (if applicable) positioned for driver view.
-- Reuses existing HP and shield display elements.
-- Hides weapon-specific elements (crosshair, heat, ammo).

function CombatHUD.hideDriverHUD()
-- Hides all driver HUD elements.
```

```lua
-- StartupValidator.luau (MODIFIED)

-- For entities with killOccupantsOnDestruction == true:
-- Warn if no DriverSeat-tagged descendant found (likely authoring mistake).
-- Allow entities without DriverSeat (unmanned weapons on vehicles are valid).
```

---

## New Data Structures

```lua
-- CombatTypes.luau additions

-- Add to EntityConfig:
    killOccupantsOnDestruction: boolean?,  -- true = all seated players die when entity HP reaches 0
```

---

## New Config Values

```lua
-- CombatConfig.luau additions

-- VEHICLE ENTITY CONFIGS
CombatConfig.Entities.armed_speeder = {
    hullHP = 200,
    weaponId = "blaster_turret",
    turretExposed = false,
    killOccupantsOnDestruction = true,
    respawnTime = 30,
}

CombatConfig.Entities.shielded_transport = {
    hullHP = 400,
    shieldHP = 200,
    shieldRegenRate = 20,
    shieldRegenDelay = 4,
    weaponId = "turbolaser_turret",
    turretExposed = false,
    killOccupantsOnDestruction = true,
    respawnTime = 45,
}

-- TEST ENTITY
CombatConfig.Entities.vehicle_test_target = {
    hullHP = 300,
    weaponId = nil,
    killOccupantsOnDestruction = true,
    respawnTime = 10,
}
```

---

## Data Flow for New Behaviors

### Vehicle Entity Registration
1. **Startup (CombatInit):** Iterates all CombatEntity-tagged models. Vehicle models have `ConfigId` set to a vehicle entity config (e.g., `armed_speeder`).
2. **Store spawn CFrame:** `CombatInit` calls `HealthManager.setSpawnCFrame(entityId, model:GetPivot())` immediately after registration. This saves the dev-placed position for respawn.
3. **DriverSeat registration:** `CombatInit` scans entity descendants for VehicleSeat instances with a `DriverSeat` attribute set to `true`. Tags them with `CollectionService:AddTag(seat, "DriverSeat")`. Sets `TurretExposed` attribute on entity model based on config.
4. **TurretSeat registration:** Same as turrets — WeaponMount + TurretSeat already handled. Gunner gets proximity prompt ("Man Turret"). Driver boarding is handled by the existing vehicle system (not combat framework).

### Vehicle Gunner Fire
1. **Player sits in vehicle TurretSeat** — existing turret flow activates. WeaponClient detects TurretSeat, shows weapon HUD, binds fire/aim/lock controls. No difference from a static turret.
2. **Player fires** — FireWeapon remote sent. WeaponServer resolves turret context, fires projectile from weapon mount. The weapon mount is on the vehicle model, which may be moving — projectile origin is correct because it reads mount.CFrame at fire time.
3. **Targeting** — TargetingServer reads weapon mount position each validation tick. Moving vehicles update the lock range check automatically.

### Driver HUD
1. **Player sits in DriverSeat (DriverClient):** DriverClient detects `Humanoid.Seated` event with a `DriverSeat`-tagged seat. Finds ancestor CombatEntity model. Reads `EntityId` attribute.
2. **Activate driver HUD:** `CombatHUD.showDriverHUD(entityId)` — shows HP bar using existing HP frame, shows shield bar if entity has shields. No crosshair, no heat, no ammo.
3. **Per-frame update (DriverClient, RenderStepped):** Reads `HullHP` and `ShieldHP` attributes from entity model. Calls `CombatHUD.setHP(current, max)` and `CombatHUD.setShield(current, max)`. Same attribute-reading pattern as WeaponClient.updateShieldHud.
4. **Player exits DriverSeat:** `CombatHUD.hideDriverHUD()`. Resets all state.

### Vehicle Destruction
1. **HP reaches 0 (HealthManager.destroyEntity):** Entity state → Destroyed.
2. **Find all occupants:** Scan entity model descendants for ALL `Seat` and `VehicleSeat` instances. For each occupied seat (seat.Occupant ~= nil):
   - If `config.killOccupantsOnDestruction == true`: set `occupant.Health = 0` (lethal). Log `[P5_VEHICLE_KILL] player=X entity=Y`.
   - Else: eject occupant (`occupant.Sit = false`) — existing turret behavior.
3. **Death explosion:** `applyTurretDeathExplosion` — same explosion system as turrets. Explosion position = entity pivot.
4. **Hide parts + disable prompts:** Same as turret destruction.
5. **Fire EntityDestroyed remote:** Same as turrets.

### Vehicle Respawn
1. **After respawnTime (HealthManager):** Restore entity.
2. **NEW: Restore position:** If spawnCFrame was stored, `instance:PivotTo(spawnCFrame)` before restoring parts. This moves the vehicle back to its dev-placed location.
3. **Restore HP/shields/weapons:** Same as turret respawn. WeaponServer.resetEntity resets heat+ammo.
4. **Fire EntityRespawned remote:** Same as turrets.

### Driver Enclosed Protection
1. **Projectile hits player character (ProjectileServer.applyDamageToHumanoidTarget):** Check if player's Humanoid.SeatPart has `TurretSeat` OR `DriverSeat` tag.
2. **If tagged:** Find ancestor CombatEntity model. Check `TurretExposed` attribute. If `false` → block damage, log `[P4_ENCLOSED_BLOCK]`. Same behavior as enclosed turret operators.

---

## Integration Pass (against real code)

### Data Lifecycle Traces

**Spawn CFrame**
- **Created by:** CombatInit calls `HealthManager.setSpawnCFrame(entityId, model:GetPivot())` during registration
- **Passed via:** Direct function call
- **Received by:** HealthManager stores in HealthStateInternal as `spawnCFrame: CFrame?`
- **Stored in:** HealthStateInternal field, keyed by entityId
- **Cleaned up by:** Never — persists for entity lifetime (needed for every respawn)
- **Verified:** CFrame value, set once at startup, used in respawn path

**Kill occupants flow**
- **Created by:** HealthManager.destroyEntity reads `config.killOccupantsOnDestruction`
- **Passed via:** Direct descendant scan of entity model for Seat/VehicleSeat instances
- **Received by:** Each occupied seat's `Occupant` humanoid — `Health` set to 0
- **Stored in:** Not stored — immediate action during destroy
- **Cleaned up by:** N/A — player respawns through standard Roblox CharacterAdded flow
- **Verified:** Uses Roblox Seat.Occupant API (returns Humanoid?), kills via Humanoid.Health = 0

**Driver HUD state**
- **Created by:** DriverClient detects Humanoid.Seated with DriverSeat-tagged seat
- **Passed via:** CombatHUD.showDriverHUD(entityId) / hideDriverHUD()
- **Received by:** CombatHUD manages HP/shield frame visibility
- **Stored in:** DriverClient module-locals (activeDriverEntityId, activeDriverModel)
- **Cleaned up by:** DriverClient on unseat event, calls CombatHUD.hideDriverHUD()
- **Verified:** Same pattern as WeaponClient turret activation/deactivation

### API Composition Checks (new calls only)

| Caller | Callee | Args Match | Return Handled | Verified Against |
|--------|--------|-----------|----------------|-----------------|
| CombatInit registration | HealthManager.setSpawnCFrame(entityId, cframe) | (string, CFrame) | None | New function |
| HealthManager.destroyEntity | seat.Occupant.Health = 0 | N/A — property set | N/A | Roblox Humanoid API |
| HealthManager respawn | instance:PivotTo(spawnCFrame) | (CFrame) | None | Roblox Model API |
| DriverClient.init | CombatHUD.showDriverHUD(entityId) | (string) | None | New function |
| DriverClient.init | CombatHUD.hideDriverHUD() | None | None | New function |
| DriverClient RenderStepped | CombatHUD.setHP(current, max) | (number, number) | None | CombatHUD.luau existing |
| DriverClient RenderStepped | CombatHUD.setShield(current, max) | (number, number) | None | CombatHUD.luau existing |
| CombatClient | DriverClient.init() | None | None | New module |
| ProjectileServer | CollectionService:HasTag(seatPart, "DriverSeat") | (Instance, string) | boolean | Roblox API |
| CombatInit | CollectionService:AddTag(vehicleSeat, "DriverSeat") | (Instance, string) | None | Roblox API |

---

## Diagnostics Updates

### New AI Build Prints
- `[P5_VEHICLE_KILL]` — occupant killed during vehicle destruction. Includes player name, entity ID.
- `[P5_DRIVER_SEAT]` — DriverSeat registered for entity. Includes entity ID, seat name.
- `[P5_SPAWN_RESTORE]` — vehicle PivotTo'd to spawn CFrame on respawn. Includes entity ID.

### New Health Counters
None.

---

## Startup Validator Updates

| Contract | Check | Error Message |
|----------|-------|---------------|
| DriverSeat authoring | For entities with `killOccupantsOnDestruction`, warn if no DriverSeat-attributed descendant found | `[VALIDATE_WARN] Entity '%s' has killOccupantsOnDestruction but no DriverSeat found — driver won't be protected from fire` |
| Vehicle weapon mount | For vehicle entities with weaponId, verify WeaponMount exists (existing check) | Existing validator handles this |
| killOccupantsOnDestruction type | If set, must be boolean | `[VALIDATE] Entity '%s' killOccupantsOnDestruction must be boolean` |

---

## Golden Tests for This Pass

### Test 14: Vehicle Gunner Fire From Moving Platform
- **Setup:** Empire armed_speeder (hullHP=200, weaponId=blaster_turret) with TurretSeat. Rebel target_dummy at (0, 5, 80). Vehicle placed at (0, 5, 0). MovingTargetController on vehicle set to mode=side, speed=3. TestHarnessEnabled = true.
- **Action:** Player (or harness) seated in vehicle gunner TurretSeat. Vehicle moves side-to-side. Harness fires 3 shots aimed at target.
- **Expected:** Projectiles originate from the moving vehicle's weapon mount position. At least 2 of 3 hit target (spread + movement may cause misses). Target takes damage.
- **Pass condition:** 3x `[P1_FIRE]` logs with projectile origins that differ between shots (proving fire origin tracks vehicle). At least 2x `[P1_HIT]` logs. Target HP < 200.

### Test 15: Vehicle Destruction Kills Occupants
- **Setup:** Empire vehicle_test_target (hullHP=300, killOccupantsOnDestruction=true) with a DriverSeat (player seated) and a TurretSeat (second player or NPC seated). Rebel blaster_turret at (0, 5, 60). TestHarnessEnabled = true.
- **Action:** Rebel turret fires enough shots to destroy vehicle (300 HP / 40 damage = 8 shots).
- **Expected:** Vehicle destroyed at 0 HP. ALL seated occupants killed (Humanoid.Health = 0). Death explosion fires.
- **Pass condition:** 1x `[P1_DESTROYED]` log. At least 1x `[P5_VEHICLE_KILL]` log per seated occupant. Occupant Humanoid.Health = 0.

### Test 16: Driver Enclosed Protection
- **Setup:** Empire armed_speeder (turretExposed=false, killOccupantsOnDestruction=true) with player seated in DriverSeat. Rebel blaster_turret at (0, 5, 50) aimed at the player character. TestHarnessEnabled = true.
- **Action:** Rebel turret fires 3 shots that hit the driver's player character.
- **Expected:** All 3 shots blocked — driver takes 0 damage. Vehicle entity itself takes no damage either (shots hit the PLAYER, not the vehicle model). Driver is protected.
- **Pass condition:** 3x `[P4_ENCLOSED_BLOCK]` logs. Player Humanoid.Health unchanged.

### Test 17: Vehicle Respawn Restores Position
- **Setup:** Empire armed_speeder (respawnTime=5) placed at (0, 5, 0). MovingTargetController drives it to ~(20, 5, 0). Then vehicle is destroyed. TestHarnessEnabled = true.
- **Action:** Destroy vehicle. Wait 6 seconds for respawn.
- **Expected:** Vehicle respawns at original position (0, 5, 0), not at destruction position. Full HP restored.
- **Pass condition:** 1x `[P1_DESTROYED]` log. 1x `[P5_SPAWN_RESTORE]` log. 1x `[P1_RESPAWNED]` log. Vehicle model pivot within 1 stud of (0, 5, 0). HullHP = 200.

### Regression Tests
Re-run Pass 1 Tests 1-4, Pass 2 Tests 5-6, Pass 3 Tests 7-9, Pass 4 Tests 10-13. Static turrets must behave identically — vehicle changes are additive. DriverSeat protection check extends existing TurretSeat check without changing turret behavior.

---

## Critic Review Notes
<!-- Filled in after critic review -->
