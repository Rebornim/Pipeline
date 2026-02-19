# Pass 2 Design: Shield System — Combat Framework

**Feature pass:** 2 of 23
**Based on:** feature-passes.md, idea-locked.md
**Existing code:** CombatTypes, CombatConfig, CombatEnums, WeaponRig (Shared); CombatInit, StartupValidator, HealthManager, ProjectileServer, WeaponServer (Server); CombatClient, WeaponClient, ProjectileVisuals, CombatHUD (Client)
**Critic Status:** PENDING
**Date:** 2026-02-18

---

## What This Pass Adds

- Shield HP layer on entities. Config-driven, optional — entities without `shieldHP` in their config remain hull-only.
- Shields absorb all incoming damage before hull. If damage exceeds remaining shield, the overflow bleeds to hull.
- Shield regeneration after a configurable no-damage grace period (delay + rate per second).
- Distinct impact VFX: blue energy ripple for shield hits, existing fiery explosion for hull hits.
- Distinct impact audio: energy crackle for shield hits, existing metallic impact for hull hits.
- HUD shield HP bar when seated in a shielded turret.
- New shielded entity configs for gameplay and testing.

---

## File Changes

### New Files

None. All changes integrate into existing modules.

### Modified Files

| File | What's Changing | Why |
|------|----------------|-----|
| `Shared/CombatTypes.luau` | Add shield fields to EntityConfig, HealthState, DamagePayload, ProjectileImpactPayload, RespawnedPayload | Types must reflect shield data flowing through the system |
| `Shared/CombatConfig.luau` | Add shielded entity configs + DefaultShieldRegenDelay | New entity types with shields; shared default for regen grace period |
| `Shared/CombatEnums.luau` | Add ImpactType enum | Consistent string constants for shield/hull/environment impact routing |
| `Server/Health/HealthManager.luau` | Shield damage absorption, shield regen Heartbeat, model attributes, modified applyDamage return | Core shield logic lives here |
| `Server/Projectiles/ProjectileServer.luau` | Reorder impact remote to fire AFTER damage; propagate impactType through return chain | Need impactType from HealthManager before sending to clients |
| `Client/Projectiles/ProjectileVisuals.luau` | Route impact VFX + audio based on impactType | Shield vs hull visual/audio distinction |
| `Client/HUD/CombatHUD.luau` | Add shield bar UI, update from damage payloads + entity destroyed/respawned | Player needs to see their turret's shield status |
| `Client/Weapons/WeaponClient.luau` | Read ShieldHP/MaxShieldHP model attributes per frame, call CombatHUD.setShield/showShield | Drive shield HUD updates while seated (matches existing heat pattern) |

---

## New/Modified APIs

```lua
-- HealthManager.luau
-- MODIFIED: now returns impactType as second value
function HealthManager.applyDamage(
    entityId: string,
    damage: number,
    damageType: string,
    attackerFaction: string,
    hitPosition: Vector3,
    ignoreFactionCheck: boolean?
): (boolean, string?)
-- Returns: (didApplyDamage, impactType)
-- impactType: "shield" if target had shield > 0 when hit (even if damage overflowed to hull)
--             "hull" if target had shield == 0 when hit
--             nil if damage was not applied (dead, faction blocked, etc.)

-- NEW
function HealthManager.getShieldHP(entityId: string): (number, number)?
-- Returns (currentShieldHP, maxShieldHP) or nil if entity not found
-- Called by: nothing in pass 2 (available for future passes)
```

```lua
-- ProjectileServer.luau
-- MODIFIED return types (internal functions)
local function applyDamageToCombatEntity(
    projectile: ProjectileData,
    targetEntityId: string,
    hitPosition: Vector3,
    damageAmount: number?
): (boolean, boolean, string, string?)
-- Returns: (didApply, didKill, targetEntityId, impactType)
-- 4th return is impactType from HealthManager.applyDamage

local function applyDamageForHitInstance(
    projectile: ProjectileData,
    hitInstance: Instance,
    hitPosition: Vector3,
    damageAmount: number?
): (boolean, boolean, string?, string?)
-- Returns: (didApply, didKill, targetId, impactType)
-- For humanoid targets: impactType = "hull" when damage applied
-- For CombatEntity targets: impactType from HealthManager
-- For environment hits: impactType = nil
```

```lua
-- ProjectileVisuals.luau
-- MODIFIED: internal functions gain impactType parameter
local function spawnImpactEffect(hitPosition: Vector3, hitNormal: Vector3, impactType: string?)
-- "shield" -> use shieldHit template; anything else -> use existing bulletHit template

local function playImpactSoundAt(position: Vector3, impactType: string?)
-- "shield" -> use ShieldImpact audio folder; anything else -> use existing Impact folder
```

```lua
-- CombatHUD.luau
-- NEW
function CombatHUD.showShield(visible: boolean)
-- Shows/hides shield frame. Called on seat enter/exit.

-- NEW
function CombatHUD.setShield(currentShield: number, maxShield: number)
-- Updates shield bar fill + text label. Called per-frame while seated.
-- Text format: "Shield: X / Y"
-- Bar color: blue (Color3.fromRGB(80, 140, 255)) when healthy,
--            pulsing cyan when low (<25%)
```

---

## New Data Structures

```lua
-- CombatTypes.luau

-- MODIFIED EntityConfig (added 3 optional fields)
export type EntityConfig = {
    hullHP: number,
    shieldHP: number?,            -- nil or 0 = no shield
    shieldRegenRate: number?,     -- HP per second. nil or 0 = no regen.
    shieldRegenDelay: number?,    -- Seconds after last shield damage before regen starts.
    weaponId: string?,
    respawnTime: number?,
}

-- MODIFIED HealthState (added 2 fields)
export type HealthState = {
    entityId: string,
    instance: Model,
    faction: string,
    config: EntityConfig,
    currentHP: number,
    maxHP: number,
    currentShieldHP: number,      -- 0 if entity has no shield
    maxShieldHP: number,          -- 0 if entity has no shield
    state: string,
    respawnTimer: thread?,
}

-- MODIFIED DamagePayload (added 2 optional fields)
export type DamagePayload = {
    entityId: string,
    newHP: number,
    maxHP: number,
    hitPosition: Vector3,
    newShieldHP: number?,         -- Present only if entity has shields
    maxShieldHP: number?,         -- Present only if entity has shields
}

-- MODIFIED ProjectileImpactPayload (added 1 optional field)
export type ProjectileImpactPayload = {
    projectileId: string,
    hitPosition: Vector3,
    hitNormal: Vector3,
    impactType: string?,          -- "shield" | "hull" | "environment"
}

-- MODIFIED RespawnedPayload (added 1 optional field)
export type RespawnedPayload = {
    entityId: string,
    hullHP: number,
    shieldHP: number?,            -- Present only if entity has shields
}
```

```lua
-- HealthManager.luau (internal only, not exported)

-- MODIFIED HealthStateInternal (added 1 field)
type HealthStateInternal = HealthState & {
    partStates: { PartState }?,
    lastShieldDamageTime: number,   -- tick() of last shield damage. Init to 0.
}
```

---

## New Config Values

```lua
-- CombatConfig.luau

-- DEFAULT SHIELD REGEN DELAY
CombatConfig.DefaultShieldRegenDelay = 3  -- Seconds. Used when entity config omits shieldRegenDelay.

-- NEW ENTITY CONFIGS (gameplay)
CombatConfig.Entities.shielded_target = {
    hullHP = 200,
    shieldHP = 150,
    shieldRegenRate = 25,
    shieldRegenDelay = 3,
    weaponId = nil,
    respawnTime = 10,
}

CombatConfig.Entities.shielded_turret = {
    hullHP = 100,
    shieldHP = 80,
    shieldRegenRate = 15,
    shieldRegenDelay = 4,
    weaponId = "blaster_turret",
    respawnTime = 15,
}

-- NEW ENTITY CONFIGS (test-only)
CombatConfig.Entities.shield_test_target = {
    hullHP = 100,
    shieldHP = 60,
    shieldRegenRate = 0,
    shieldRegenDelay = 999,
    weaponId = nil,
    respawnTime = 10,
}

CombatConfig.Entities.shield_regen_target = {
    hullHP = 200,
    shieldHP = 100,
    shieldRegenRate = 50,
    shieldRegenDelay = 2,
    weaponId = nil,
    respawnTime = 10,
}
```

---

## Data Flow for New Behaviors

### Shield Damage Absorption

1. **ProjectileServer.stepProjectiles**: projectile hits target via spherecast
2. **ProjectileServer.applyDamageForHitInstance**: identifies CombatEntity, calls `applyDamageToCombatEntity`
3. **HealthManager.applyDamage**: checks entity is alive + faction gate (unchanged). Then:
   - If `currentShieldHP > 0`: impactType = `"shield"`. If `damage <= currentShieldHP`, shield absorbs all (hull untouched). If `damage > currentShieldHP`, shield goes to 0, overflow damages hull. Prints `[P2_SHIELD_ABSORB]`. If shield hits 0, prints `[P2_SHIELD_BREAK]` and `[P2_SHIELD_OVERFLOW]` with overflow amount.
   - If `currentShieldHP == 0`: impactType = `"hull"`. Hull takes full damage (existing behavior).
   - Updates model attributes (both ShieldHP and HullHP).
   - Sets `lastShieldDamageTime = tick()` whenever shield absorbs any damage.
   - Fires DamageApplied remote with `newShieldHP` and `maxShieldHP` fields included.
   - Returns `(true, impactType)`.
4. **ProjectileServer.stepProjectiles**: receives impactType, builds `ProjectileImpactPayload` with `impactType` field, fires `ProjectileImpact` remote to all clients.
5. **ProjectileVisuals.onProjectileImpact**: reads `impactType`. Routes to `shieldHit` VFX template + `ShieldImpact` audio if `"shield"`, or existing `bulletHit` + `Impact` audio otherwise.
6. **CombatHUD.onDamageApplied**: reads `newShieldHP` and `maxShieldHP` from payload. If seated in the damaged entity, updates shield display.

### Shield Regeneration

1. **HealthManager.init**: connects `RunService.Heartbeat` to a regen step function.
2. **Heartbeat step**: iterates all entities. For each entity where `state == Active` AND `maxShieldHP > 0` AND `currentShieldHP < maxShieldHP`:
   - Reads `shieldRegenDelay` from entity config (fallback: `CombatConfig.DefaultShieldRegenDelay`).
   - If `tick() - lastShieldDamageTime >= regenDelay`:
     - `currentShieldHP = min(maxShieldHP, currentShieldHP + regenRate * dt)`
     - Updates `ShieldHP` model attribute.
     - If `currentShieldHP >= maxShieldHP`: prints `[P2_REGEN_FULL]`.
3. **Client (WeaponClient)**: reads `ShieldHP` model attribute per-frame while seated, calls `CombatHUD.setShield`. Shield bar updates smoothly as attribute changes from server regen.

### Entity Respawn with Shield

1. **HealthManager.destroyEntity**: entity state = Destroyed (existing). Shield irrelevant while dead.
2. **Respawn timer fires**: `currentHP = maxHP` (existing). **NEW:** `currentShieldHP = maxShieldHP`. `lastShieldDamageTime = tick()` (prevents immediate regen flicker).
3. **Model attributes**: both HullHP/MaxHullHP and ShieldHP/MaxShieldHP updated.
4. **EntityRespawned remote**: payload includes `shieldHP` field.
5. **CombatHUD.onEntityRespawned**: reads `shieldHP` from payload, resets shield display.

---

## Integration Pass (against real code)

### Data Lifecycle Traces

**Shield HP (server state)**
- **Created by:** `HealthManager.registerEntity()` — reads `config.shieldHP` (or 0), sets `currentShieldHP` and `maxShieldHP` on `HealthStateInternal`
- **Stored in:** `entitiesById[entityId].currentShieldHP`, `.maxShieldHP`, `.lastShieldDamageTime`
- **Mutated by:** `applyDamage()` (decrements shield, sets lastShieldDamageTime), Heartbeat regen (increments shield), respawn (resets to max)
- **Published via:** Model attributes (`ShieldHP`, `MaxShieldHP`) — updated on every mutation. `DamageApplied` remote (newShieldHP, maxShieldHP fields). `EntityRespawned` remote (shieldHP field).
- **Received by:** `CombatHUD.onDamageApplied()` — reads optional shield fields. `WeaponClient` per-frame update — reads model attributes. `CombatHUD.onEntityRespawned()` — reads shieldHP.
- **Cleaned up by:** entity destruction (state becomes Destroyed, regen loop skips). Respawn resets to max.
- **Verified:** HealthState type includes new fields. DamagePayload includes optional fields. Client code nil-checks optional fields.

**Impact Type (transient)**
- **Created by:** `HealthManager.applyDamage()` — returns `"shield"` or `"hull"` as 2nd value
- **Passed via:** return chain: `HealthManager.applyDamage` → `applyDamageToCombatEntity` (4th return) → `applyDamageForHitInstance` (4th return) → `stepProjectiles`
- **Published via:** `ProjectileImpact` remote — `impactType` field in payload
- **Received by:** `ProjectileVisuals.onProjectileImpact()` — reads `impactType`, routes VFX/audio
- **Lifetime:** single frame, per-hit. No storage, no cleanup needed.
- **Verified:** `ProjectileImpactPayload` type has optional `impactType` field. Client nil-checks before routing (nil defaults to existing bulletHit behavior).

### API Composition Checks (new calls only)

| Caller | Callee | Args Match | Return Handled | Verified Against |
|--------|--------|-----------|----------------|-----------------|
| `ProjectileServer.applyDamageToCombatEntity()` | `HealthManager.applyDamage(entityId, damage, damageType, faction, hitPos)` | Yes (args unchanged) | Now captures 2nd return `impactType` | `HealthManager.luau:283` — existing 5-arg call |
| `ProjectileServer.stepProjectiles()` | `applyDamageForHitInstance(proj, inst, pos, dmg)` | Yes (args unchanged) | Now captures 4th return `impactType` | `ProjectileServer.luau:304-305` — existing 4-arg call |
| `ProjectileServer.stepProjectiles()` | `getProjectileImpactRemote():FireAllClients(payload)` | Yes — payload now includes `impactType` field | N/A (remote fire) | `ProjectileServer.luau:297-302` — existing call, moved after damage |
| `WeaponClient` per-frame update | `CombatHUD.setShield(currentShield, maxShield)` | Yes — both numbers from model attributes | void | New call site matches new API |
| `WeaponClient` seat enter/exit | `CombatHUD.showShield(visible)` | Yes — boolean | void | New call site matches new API |
| `HealthManager` Heartbeat | `RunService.Heartbeat:Connect(fn)` | Yes — requires `RunService` (new require) | Connection stored | HealthManager.luau currently does NOT require RunService — must add |

---

## Diagnostics Updates

### New Build Prints

- `[P2_SHIELD_ABSORB] entity=%s shield=%d->%d damage=%d` — shield absorbed damage (fires on every shield hit)
- `[P2_SHIELD_BREAK] entity=%s` — shield depleted to 0
- `[P2_SHIELD_OVERFLOW] entity=%s overflow=%d` — damage that overflowed from depleted shield to hull
- `[P2_REGEN_FULL] entity=%s shield=%d/%d` — shield fully regenerated to max

### Existing Prints Preserved

- `[P1_DAMAGE]` still fires when hull takes damage (including overflow from shield)
- `[P1_DESTROYED]`, `[P1_RESPAWNED]`, `[P1_FACTION_BLOCK]` — unchanged
- `[P1_HIT]`, `[P1_EXPIRED]`, `[P1_FIRE]` — unchanged

---

## Startup Validator Updates

No new validation needed. Shield is purely config-driven via `CombatConfig.Entities`. Entities without `shieldHP` in their config simply have `maxShieldHP = 0`. No new tags, no new model structure requirements.

---

## CombatAssets Templates (placed in Studio)

| Template Path | Contents | Fallback |
|--------------|----------|----------|
| `CombatAssets/ImpactParticles/shieldHit` | Folder with blue/cyan ParticleEmitters (energy ripple), PointLight (blue), Attachment(s) | Falls back to existing `bulletHit` template with one-time `[P2_IMPACT]` warning |
| `CombatAssets/Audio/ShieldImpact` | Folder with shield impact Sound(s) (electric/energy crackle) | Falls back to existing `Impact` audio folder with one-time `[P2_AUDIO]` warning |

Codex creates the template folders with placeholder emitters/sounds. Actual authored VFX/audio will be tuned in Studio later.

---

## Golden Tests for This Pass

### Test 5: Shield Full Lifecycle

- **Added in:** Pass 2
- **Setup:** Empire blaster_turret (damage=40) at (0, 5, 0). Rebel shield_test_target (shieldHP=60, hullHP=100, no regen) at (0, 5, 50). Direct line of sight. TestHarnessEnabled = true.
- **Action:** Harness fires 4 projectiles sequentially at target.
- **Expected:**
  - Shot 1: shield 60 -> 20, hull 100 unchanged. impactType = "shield".
  - Shot 2: shield 20 -> 0 (absorbed 20), overflow 20 to hull. Hull 100 -> 80. impactType = "shield".
  - Shot 3: shield 0, hull 80 -> 40. impactType = "hull".
  - Shot 4: hull 40 -> 0. Target destroyed. impactType = "hull".
- **Pass condition:**
  - 2x `[P2_SHIELD_ABSORB]` logs (shots 1-2)
  - 1x `[P2_SHIELD_BREAK]` log (shot 2)
  - 1x `[P2_SHIELD_OVERFLOW]` log with overflow=20 (shot 2)
  - 3x `[P1_DAMAGE]` logs for hull hits (shots 2, 3, 4 — shot 2 is overflow)
  - 1x `[P1_DESTROYED]` log
  - Target ShieldHP attribute = 0 after shot 2
  - Target HullHP attribute = 0 after shot 4

### Test 6: Shield Regeneration

- **Added in:** Pass 2
- **Setup:** Empire blaster_turret (damage=40) at (0, 5, 0). Rebel shield_regen_target (shieldHP=100, hullHP=200, regenRate=50/sec, regenDelay=2) at (0, 5, 50). TestHarnessEnabled = true.
- **Action:** Harness fires 1 projectile (shield 100 -> 60). Then waits 6 seconds.
- **Expected:** After 2s grace period, shield regens at 50/sec for 4 seconds. 60 + 200 = 260, clamped to max 100. Shield fully restored.
- **Pass condition:**
  - 1x `[P2_SHIELD_ABSORB]` log (shield 100 -> 60)
  - 1x `[P2_REGEN_FULL]` log within 3-5 seconds after the hit
  - Target ShieldHP model attribute = 100 at end of test
  - Target HullHP model attribute = 200 (untouched)

### Regression Tests

Re-run all Pass 1 golden tests (Tests 1-4). Unshielded entities (`blaster_turret`, `target_dummy`) must behave identically — hull-only damage, faction blocking, destruction/respawn, max range expiry. No shield logic triggers for entities with `shieldHP = nil`.

---

## Critical Implementation Notes

1. **Impact remote reorder in ProjectileServer.stepProjectiles**: Currently `ProjectileImpact` fires at line 297-302 BEFORE damage at line 304-305. Reverse this: apply damage first (to get impactType), then fire `ProjectileImpact` with impactType included. Both happen in the same Heartbeat frame so client timing is unaffected.

2. **HealthManager requires RunService**: Currently `HealthManager.luau` does not require `RunService`. Add it for the Heartbeat shield regen connection.

3. **Model attribute names**: Server publishes `ShieldHP` and `MaxShieldHP` as model attributes (alongside existing `HullHP`, `MaxHullHP`). Client reads these. Do NOT set shield attributes on entities that have `maxShieldHP == 0`.

4. **Nil-safe client code**: All new payload fields (`newShieldHP`, `maxShieldHP`, `shieldHP`, `impactType`) are optional. Client code must nil-check before use. Existing clients that don't understand these fields continue to work.

5. **Regen logging discipline**: Do NOT log every Heartbeat frame during regen. Only log `[P2_REGEN_FULL]` when shield reaches max. Keep regen silent otherwise to avoid log flooding.

6. **Splash damage and shield**: Splash damage calls `HealthManager.applyDamage` the same as direct hits. Shield absorbs splash damage identically. The impactType returned from splash damage calls is NOT sent to clients (no per-splash impact VFX exists). Only the direct hit's impactType goes to the `ProjectileImpact` remote.

---

## Critic Review Notes
<!-- Filled in after critic review -->
