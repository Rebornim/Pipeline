# Pass 3 Design: Damage Types + Ammo — Combat Framework

**Feature pass:** 3 of 23
**Based on:** feature-passes.md, idea-locked.md
**Existing code:** All 13 modules from passes 1-2. Overheat fully implemented (pass 1 pull-forward). Shield system fully implemented (pass 2).
**Critic Status:** PENDING
**Date:** 2026-02-19

---

## What This Pass Adds

- **Damage type multiplier system.** Each damage type has `shieldMult`, `hullMult`, and `bypass` values that modify how damage interacts with shields and hull. Lookup table in CombatConfig, applied inside HealthManager.applyDamage.
- **5 damage types** with mechanically distinct behaviors:
  - **Blaster** (existing): 1x shield, 1x hull, 0 bypass. Standard.
  - **Turbolaser**: 1.5x shield, 1.5x hull, 0 bypass. Slow but hard-hitting.
  - **Ion**: 3x shield, 0.15x hull, 0 bypass. Devastates shields, scratches hull.
  - **Proton torpedo**: 0.3x shield, 2.5x hull, 0.7 bypass. 70% bypasses shield → hull. Slow projectile. Finite ammo.
  - **Concussion missile**: 1x shield, 1x hull, 0 bypass. Moderate. Finite ammo. (Homing deferred to targeting pass.)
- **Finite ammo system** for physical weapons (torpedo, missile). Ammo depletes on fire, weapon dead at 0. Ammo resets on entity respawn.
- **4 new weapon configs + 4 new entity configs** for turbolaser, ion, torpedo, and missile turrets.
- **HUD ammo counter** for ammo-based weapons (replaces heat bar position — mutually exclusive with overheat).

**Not in this pass:** Overheat is already complete. Ion stun effect deferred until subsystems pass. Torpedo lock-on and missile homing deferred to targeting pass. All projectiles fly straight.

---

## File Changes

### New Files

None.

### Modified Files

| File | What's Changing | Why |
|------|----------------|-----|
| `Shared/CombatTypes.luau` | Add `DamageTypeMultiplier` type; add `ammoCapacity` to `WeaponConfig` | New types for multiplier table and ammo tracking |
| `Shared/CombatConfig.luau` | Add `DamageTypeMultipliers` table; 4 new weapon configs; 4 new entity configs; test entity configs | Damage type definitions, new turret types |
| `Shared/CombatEnums.luau` | Expand `DamageType` with Turbolaser, Ion, ProtonTorpedo, ConcussionMissile | All 5 damage types need enum entries |
| `Server/Health/HealthManager.luau` | Apply damage type multipliers + bypass in `applyDamage`; add `setRespawnCallback` for ammo reset | Core damage math changes; callback for weapon reset on respawn |
| `Server/Weapons/WeaponServer.luau` | Ammo tracking per entity; ammo check on fire; ammo model attributes; `resetEntity` for respawn; publish ammo attributes | Ammo system lives here alongside existing heat system |
| `Server/CombatInit.server.luau` | Wire respawn callback: `HealthManager.setRespawnCallback → WeaponServer.resetEntity` | Loose coupling between health and weapon modules |
| `Client/HUD/CombatHUD.luau` | New ammo frame (same position as heat frame, mutually exclusive); `showAmmo`/`setAmmo` functions | Players need to see ammo count for torpedo/missile turrets |
| `Client/Weapons/WeaponClient.luau` | Read `WeaponAmmo`/`WeaponAmmoMax` attributes; show ammo or heat based on weapon type | Drive ammo HUD while seated |

---

## New/Modified APIs

```lua
-- HealthManager.luau

-- NEW: register a callback invoked on entity respawn (before remote fires)
function HealthManager.setRespawnCallback(callback: (entityId: string) -> ())
-- Called by CombatInit to wire weapon reset without circular dependency.
-- Invoked inside respawn timer, after HP/shield restore, before EntityRespawned remote.
```

```lua
-- HealthManager.applyDamage (MODIFIED internals, same signature)
-- Now looks up CombatConfig.DamageTypeMultipliers[damageType] and applies:
--   bypass fraction → direct hull damage
--   shield-facing damage with shieldMult
--   hull damage with hullMult (including overflow conversion)
-- Default multipliers (1, 1, 0) when damageType not found in table.
```

```lua
-- WeaponServer.luau

-- NEW: reset weapon state on entity respawn
function WeaponServer.resetEntity(entityId: string)
-- Resets heat to 0, overheated to false, ammo to max.
-- Updates model attributes for heat and ammo.
-- Called by respawn callback wired through CombatInit.
```

```lua
-- CombatHUD.luau

-- NEW
function CombatHUD.showAmmo(visible: boolean)
-- Shows/hides ammo frame. Mutually exclusive with heat frame.

-- NEW
function CombatHUD.setAmmo(currentAmmo: number, maxAmmo: number)
-- Updates ammo text label. Format: "Ammo: X / Y"
-- Text turns red when currentAmmo == 0.
```

---

## New Data Structures

```lua
-- CombatTypes.luau

-- NEW type
export type DamageTypeMultiplier = {
    shieldMult: number,     -- multiplier on damage to shields
    hullMult: number,       -- multiplier on damage to hull
    bypass: number?,        -- fraction (0-1) of damage bypassing shields. Default 0.
}

-- MODIFIED WeaponConfig (added 1 field)
export type WeaponConfig = {
    -- ... all existing fields unchanged ...
    ammoCapacity: number?,  -- nil or 0 = infinite (energy weapon, uses heat). > 0 = finite ammo.
}
```

```lua
-- WeaponServer.luau (internal only)

-- NEW per-entity ammo state
type AmmoState = {
    current: number,
    max: number,
}

local ammoStateByEntityId: { [string]: AmmoState } = {}
```

---

## New Config Values

```lua
-- CombatConfig.luau

-- DAMAGE TYPE MULTIPLIERS (NEW TABLE)
CombatConfig.DamageTypeMultipliers = {
    blaster    = { shieldMult = 1.0,  hullMult = 1.0,  bypass = 0   },
    turbolaser = { shieldMult = 1.5,  hullMult = 1.5,  bypass = 0   },
    ion        = { shieldMult = 3.0,  hullMult = 0.15, bypass = 0   },
    proton_torpedo     = { shieldMult = 0.3, hullMult = 2.5, bypass = 0.7 },
    concussion_missile = { shieldMult = 1.0, hullMult = 1.0, bypass = 0   },
    explosion  = { shieldMult = 1.0,  hullMult = 1.0,  bypass = 0   },
}

-- NEW WEAPON CONFIGS
CombatConfig.Weapons.turbolaser_turret = {
    weaponClass = "projectile",
    damageType = "turbolaser",
    damage = 120,
    fireRate = 0.5,
    projectileSpeed = 450,
    maxRange = 700,
    heatMax = 100,
    heatPerShot = 25,
    heatDecayPerSecond = 6,
    heatRecoverThreshold = 40,
    boltColor = Color3.fromRGB(0, 255, 0),
}

CombatConfig.Weapons.ion_turret = {
    weaponClass = "projectile",
    damageType = "ion",
    damage = 60,
    fireRate = 1.5,
    projectileSpeed = 500,
    maxRange = 450,
    heatMax = 100,
    heatPerShot = 18,
    heatDecayPerSecond = 7,
    heatRecoverThreshold = 45,
    boltColor = Color3.fromRGB(100, 140, 255),
}

CombatConfig.Weapons.torpedo_launcher = {
    weaponClass = "projectile",
    damageType = "proton_torpedo",
    damage = 200,
    fireRate = 0.33,
    projectileSpeed = 200,
    maxRange = 600,
    ammoCapacity = 6,
    boltColor = Color3.fromRGB(255, 200, 60),
}

CombatConfig.Weapons.missile_battery = {
    weaponClass = "projectile",
    damageType = "concussion_missile",
    damage = 80,
    fireRate = 1.0,
    projectileSpeed = 300,
    maxRange = 500,
    ammoCapacity = 12,
    boltColor = Color3.fromRGB(255, 120, 40),
}

-- NEW ENTITY CONFIGS (gameplay)
CombatConfig.Entities.turbolaser_turret = {
    hullHP = 150,
    shieldHP = 100,
    shieldRegenRate = 10,
    shieldRegenDelay = 4,
    weaponId = "turbolaser_turret",
    respawnTime = 20,
}

CombatConfig.Entities.ion_turret = {
    hullHP = 80,
    weaponId = "ion_turret",
    respawnTime = 15,
}

CombatConfig.Entities.torpedo_turret = {
    hullHP = 120,
    weaponId = "torpedo_launcher",
    respawnTime = 25,
}

CombatConfig.Entities.missile_turret = {
    hullHP = 100,
    weaponId = "missile_battery",
    respawnTime = 20,
}

-- NEW ENTITY CONFIGS (test-only)
CombatConfig.Entities.ion_test_target = {
    hullHP = 200,
    shieldHP = 200,
    shieldRegenRate = 0,
    shieldRegenDelay = 999,
    weaponId = nil,
    respawnTime = 10,
}

CombatConfig.Entities.torpedo_test_target = {
    hullHP = 500,
    shieldHP = 150,
    shieldRegenRate = 0,
    shieldRegenDelay = 999,
    weaponId = nil,
    respawnTime = 10,
}

CombatConfig.Entities.ammo_test_target = {
    hullHP = 10000,
    weaponId = nil,
    respawnTime = 999,
}
```

---

## Data Flow for New Behaviors

### Damage Type Multipliers

1. **ProjectileServer.stepProjectiles**: projectile hits target. Calls `applyDamageForHitInstance` with `projectile.damage` and `projectile.damageType` (unchanged).
2. **HealthManager.applyDamage**: receives `damage` (base) and `damageType` (string). Looks up `CombatConfig.DamageTypeMultipliers[damageType]`. If not found, uses default `{shieldMult=1, hullMult=1, bypass=0}`.
3. **Multiplied damage math** (replaces current raw subtraction):
   ```
   bypassFraction = multipliers.bypass or 0
   bypassBase = baseDamage * bypassFraction
   shieldFacingBase = baseDamage * (1 - bypassFraction)

   if currentShield > 0:
       impactType = "shield"
       shieldDamage = shieldFacingBase * shieldMult
       absorbed = min(currentShield, shieldDamage)
       currentShield -= absorbed
       overflowShieldDmg = shieldDamage - absorbed
       overflowBase = overflowShieldDmg / max(shieldMult, 0.001)
       hullDamage = (bypassBase + overflowBase) * hullMult
   else:
       impactType = "hull"
       hullDamage = baseDamage * hullMult

   currentHull -= hullDamage
   ```
4. DamageApplied remote fires with updated HP values (unchanged payload structure).

### Finite Ammo

1. **WeaponServer.registerEntity**: reads `weaponConfig.ammoCapacity`. If > 0, creates `AmmoState { current = ammoCapacity, max = ammoCapacity }` in `ammoStateByEntityId`. Sets model attributes `WeaponAmmo` and `WeaponAmmoMax`.
2. **WeaponServer.fireSingleProjectile**: before heat check, checks ammo. If `ammoState ~= nil and ammoState.current <= 0`, refuses fire (returns false). After successful fire, decrements `ammoState.current`. Updates `WeaponAmmo` model attribute.
3. **WeaponServer.resetEntity**: called on entity respawn via callback. Resets `ammoState.current = ammoState.max`. Resets heat to 0. Updates model attributes.
4. **HealthManager respawn path**: after restoring HP/shield, calls `respawnCallback(entityId)` if set. CombatInit wires this to `WeaponServer.resetEntity`.
5. **Client HUD**: WeaponClient reads `WeaponAmmoMax` attribute. If > 0, shows ammo display (hides heat). Reads `WeaponAmmo` per-frame and calls `CombatHUD.setAmmo(current, max)`.

### Ammo vs Heat Display (mutually exclusive)

1. **WeaponClient seat enter**: reads `WeaponAmmoMax` from turret model.
   - If `> 0`: calls `CombatHUD.showAmmo(true)`, `CombatHUD.showHeat(false)`.
   - Else: calls `CombatHUD.showHeat(true)`, `CombatHUD.showAmmo(false)` (existing behavior).
2. **WeaponClient per-frame update**:
   - Ammo weapon: reads `WeaponAmmo`/`WeaponAmmoMax`, calls `CombatHUD.setAmmo`.
   - Heat weapon: reads heat attributes, calls `CombatHUD.setWeaponHeat` (existing).
3. **WeaponClient seat exit**: `CombatHUD.showAmmo(false)`, `CombatHUD.showHeat(false)`.

---

## Integration Pass (against real code)

### Data Lifecycle Traces

**Damage Type Multipliers**
- **Defined in:** `CombatConfig.DamageTypeMultipliers` — static table, keyed by damageType string
- **Read by:** `HealthManager.applyDamage()` — looks up `damageType` arg (already passed in, line 436)
- **Used for:** shield/hull damage calculation inside applyDamage
- **No storage, no cleanup:** multiplier config is read-only, looked up per-hit
- **Verified:** damageType string flows: `CombatConfig.Weapons[x].damageType` → `ProjectileData.damageType` → `HealthManager.applyDamage(_, _, damageType, _)`. Chain confirmed in real code: `WeaponServer:892` → `ProjectileServer:362` → `ProjectileServer:117` → `HealthManager:433`.

**Ammo State (server)**
- **Created by:** `WeaponServer.registerEntity()` — if `weaponConfig.ammoCapacity > 0`
- **Stored in:** `ammoStateByEntityId[entityId]` — `{current, max}`
- **Mutated by:** `fireSingleProjectile` (decrements current), `resetEntity` (resets to max)
- **Published via:** Model attributes `WeaponAmmo`, `WeaponAmmoMax` — updated on every mutation
- **Received by client:** WeaponClient reads model attributes per-frame while seated
- **Cleaned up by:** entity ammo state persists in table (lightweight). Reset on respawn via callback.
- **Verified:** `registerEntity` already accesses weaponConfig at line 1080-1084. ammoCapacity is a new optional field — nil check is safe.

**Respawn Callback**
- **Registered by:** `CombatInit.server.luau` — calls `HealthManager.setRespawnCallback(fn)` after both modules init
- **Stored in:** `HealthManager` module local `respawnCallback`
- **Invoked by:** `HealthManager` respawn timer (inside `destroyEntity`'s `task.spawn`, line 358-382)
- **Calls:** `WeaponServer.resetEntity(entityId)`
- **Verified:** CombatInit already initializes HealthManager (line 134) then WeaponServer (line 136). Callback registration goes after both.

### API Composition Checks

| Caller | Callee | Args Match | Return Handled | Verified Against |
|--------|--------|-----------|----------------|-----------------|
| `HealthManager.applyDamage()` | `CombatConfig.DamageTypeMultipliers[damageType]` | String key lookup | Nil-safe (defaults to 1/1/0) | New table in CombatConfig |
| `CombatInit` | `HealthManager.setRespawnCallback(fn)` | `(string) -> ()` | N/A | New function |
| `HealthManager` respawn path | `respawnCallback(entityId)` | String | N/A | Called at line ~370 area |
| `CombatInit` respawn callback | `WeaponServer.resetEntity(entityId)` | String | N/A | New function |
| `WeaponServer.fireSingleProjectile` | `ammoStateByEntityId[entityId]` | String key | Nil = no ammo tracking (heat weapon) | New internal table |
| `WeaponClient` per-frame | `CombatHUD.setAmmo(current, max)` | Two numbers from attributes | void | New function |
| `WeaponClient` seat enter | `CombatHUD.showAmmo(visible)` | boolean | void | New function |

---

## Diagnostics Updates

### New Build Prints

- `[P3_MULT] entity=%s type=%s shieldM=%.2f hullM=%.2f bypass=%.0f%%` — logged in applyDamage when multipliers differ from 1/1/0 defaults
- `[P3_BYPASS] entity=%s bypassDmg=%.1f` — logged when bypass sends damage directly to hull through shields
- `[P3_AMMO] entity=%s ammo=%d/%d` — logged on each ammo-consuming fire
- `[P3_AMMO_EMPTY] entity=%s` — logged when fire refused due to 0 ammo
- `[P3_AMMO_RESET] entity=%s ammo=%d` — logged on respawn ammo refill

### Existing Prints Preserved

All `[P1_*]` and existing prints unchanged. `[P1_DAMAGE]` still fires for hull damage — the damage number now reflects multiplied values.

---

## Startup Validator Updates

No new validation needed. All new weapon/entity types use existing tag contracts (CombatEntity, WeaponMount, TurretSeat, Faction, ConfigId). New ConfigId values resolve through CombatConfig.Entities as before.

---

## CombatAssets Templates

No new template folders needed for this pass. New weapon types use existing bolt visual templates (color differentiated via `boltColor` config). Torpedo and missile projectile visuals will be authored separately — fallback to existing bolt template is fine.

---

## Golden Tests for This Pass

### Test 7: Ion Cannon Shield Devastation

- **Added in:** Pass 3
- **Setup:** Empire ion_turret (damage=60, damageType="ion") at (0, 5, 0). Rebel ion_test_target (shieldHP=200, hullHP=200, no regen) at (0, 5, 50). TestHarnessEnabled = true. DamageTypeMultipliers.ion: shieldMult=3.0, hullMult=0.15, bypass=0.
- **Action:** Harness fires 2 shots.
- **Expected:**
  - Shot 1: shieldDamage = 60 * 3.0 = 180. Shield: 200 -> 20. Hull untouched. impactType = "shield".
  - Shot 2: shieldDamage = 60 * 3.0 = 180. Shield absorbed 20, overflow = 160. overflowBase = 160/3.0 = 53.33. hullDamage = 53.33 * 0.15 = 8.0. Shield: 0. Hull: 200 -> 192. impactType = "shield".
- **Pass condition:**
  - Shield depleted in 2 shots (ion devastating to shields)
  - Hull barely scratched: 200 -> 192 (ion minimal to hull)
  - `[P3_MULT]` logs showing ion multipliers
  - `[P1_DAMAGE]` shows hull only dropped by ~8

### Test 8: Proton Torpedo Shield Bypass

- **Added in:** Pass 3
- **Setup:** Empire torpedo_turret (damage=200, damageType="proton_torpedo") at (0, 5, 0). Rebel torpedo_test_target (shieldHP=150, hullHP=500, no regen) at (0, 5, 50). TestHarnessEnabled = true. DamageTypeMultipliers.proton_torpedo: shieldMult=0.3, hullMult=2.5, bypass=0.7.
- **Action:** Harness fires 1 shot.
- **Expected:**
  - bypassBase = 200 * 0.7 = 140. shieldFacingBase = 200 * 0.3 = 60.
  - shieldDamage = 60 * 0.3 = 18. Shield: 150 -> 132 (barely scratched).
  - hullDamage = 140 * 2.5 = 350. Hull: 500 -> 150.
- **Pass condition:**
  - Shield only lost 18 (torpedo barely touches shields)
  - Hull lost 350 in one hit (bypass + hull multiplier = devastating)
  - `[P3_BYPASS]` log showing bypass damage
  - `[P3_MULT]` log showing torpedo multipliers

### Test 9: Ammo Depletion

- **Added in:** Pass 3
- **Setup:** Empire torpedo_turret (ammoCapacity=6) at (0, 5, 0). Rebel ammo_test_target (hullHP=10000) at (0, 5, 50). TestHarnessEnabled = true.
- **Action:** Harness attempts 8 fire commands.
- **Expected:** 6 shots fire successfully. Shots 7-8 refused (ammo=0).
- **Pass condition:**
  - 6x `[P1_FIRE]` logs
  - 6x `[P3_AMMO]` logs showing ammo 6->5->4->3->2->1->0
  - 2x `[P3_AMMO_EMPTY]` logs (shots 7-8)
  - `WeaponAmmo` model attribute = 0 after shot 6

### Regression Tests

Re-run Pass 1 Tests 1-4 and Pass 2 Tests 5-6. Blaster damage type has multipliers {1, 1, 0} — behavior must be identical to pre-multiplier math. Unshielded entities unaffected. Shield regen unaffected.

---

## Critical Implementation Notes

1. **Damage math replaces current shield subtraction.** The existing raw shield absorption in HealthManager.applyDamage (lines 460-491) is replaced by the multiplier+bypass math. When damageType is `"blaster"` with default multipliers {1,1,0}, the math produces identical results to the current code. **Verify this equivalence in testing.**

2. **Default multipliers for unknown damage types.** If `CombatConfig.DamageTypeMultipliers[damageType]` returns nil, use `{shieldMult=1, hullMult=1, bypass=0}`. This ensures existing code (`damageType="explosion"` from turret death) continues to work even if the "explosion" entry is missing.

3. **Ammo and heat are mutually exclusive by config, not by code.** Torpedo configs have `ammoCapacity=6` and no `heatMax`. Blaster configs have `heatMax=100` and no `ammoCapacity`. If somehow both are set, both systems apply (ammo decrements AND heat builds). Don't add enforcement — just configure correctly.

4. **Ammo check comes BEFORE heat check in fireSingleProjectile.** Sequence: ammo check → heat recovery check → overheat check → fire → decrement ammo → add heat → publish attributes.

5. **WeaponServer.resetEntity on respawn.** Heat resets to 0, overheated to false, recoverToken incremented (cancels pending recovery cues). Ammo resets to max. Model attributes updated. Called via loose callback wired in CombatInit, NOT by direct module dependency.

6. **HUD ammo frame reuses heat frame position.** Same Y position (`UDim2.new(0.5, 0, 1, -46)`), same general styling. Text-only display: "Ammo: X / Y". No bar needed — count is more readable for low-quantity ammo (6 torpedoes, 12 missiles). When `currentAmmo == 0`, text turns red and reads "Ammo: 0 / Y (EMPTY)".

7. **Overflow conversion math.** When shield breaks from a high-shieldMult hit (e.g., ion), the overflow converts back to base damage before applying hullMult: `overflowBase = overflowShieldDmg / shieldMult`. This prevents ion overflow from dealing full hull damage — ion's hullMult of 0.15 keeps hull damage tiny even on overflow.

---

## Critic Review Notes
<!-- Filled in after critic review -->
