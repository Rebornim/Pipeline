# Pass 4 Design: Targeting System — Combat Framework

**Feature pass:** 4 of 23
**Based on:** feature-passes.md, idea-locked.md
**Existing code:** CombatConfig, CombatTypes, CombatEnums, CombatInit, StartupValidator, HealthManager, ProjectileServer, WeaponServer, WeaponRig, CombatClient, WeaponClient, ProjectileVisuals, CombatHUD
**Critic Status:** PENDING
**Date:** 2026-02-19

---

## What This Pass Adds

Lock-on targeting system for turrets. Players aim near an enemy → "TARGET LOCK READY" appears → press T → weapon auto-aims with lead prediction. Torpedoes now require lock-on to fire. Missiles home toward locked target after launch. Turrets gain rotation arc and elevation limits via config. Enclosed turrets protect their operator from projectile damage.

---

## File Changes

### New Files
| File | Location | Purpose |
|------|----------|---------|
| TargetingServer.luau | Server/Targeting/ | Server-authoritative lock state, lock validation loop, auto-aim lead computation |
| TargetingClient.luau | Client/Targeting/ | Client-side lock candidate detection, lock HUD elements, leading indicator |

### Modified Files
| File | What's Changing | Why |
|------|----------------|-----|
| CombatTypes.luau | Add targeting types (LockState, TargetingConfig fields on WeaponConfig/EntityConfig, homing fields on ProjectileData/ProjectileFiredPayload) | Type definitions for all targeting data |
| CombatConfig.luau | Add lockRange/autoAimSpread/requiresLock/homingTurnRate to weapons, turretExposed to entities, targeting constants | Config values for lock-on, homing, turret exposure |
| CombatInit.server.luau | Create 3 new remotes (RequestLockOn, ClearLockOn, LockOnState), init TargetingServer, publish turret exposure attributes | Wire targeting system into startup |
| WeaponServer.luau | Check requiresLock before firing, apply auto-aim direction when locked, set targetEntityId/homingTurnRate on ProjectileData | Server fire path now respects lock-on |
| ProjectileServer.luau | Add homing branch in stepProjectiles, turret exposure check in applyDamageToHumanoidTarget | Missiles curve toward target, enclosed turrets protect operators |
| CombatClient.client.luau | Connect LockOnState remote, init TargetingClient, forward lock state | Client wiring for targeting |
| WeaponClient.luau | T keybind for lock toggle, requiresLock client check, override desiredAimDirection when locked | Client aim and fire gating |
| ProjectileVisuals.luau | Homing bolt update in onRenderStepped, store target info on ActiveBolt | Visual bolts curve toward target |
| CombatHUD.luau | Lock-ready label, lock reticle bracket, leading indicator dot | HUD elements for targeting |

---

## New/Modified APIs

```lua
-- TargetingServer.luau (NEW)

function TargetingServer.init(remotes: Folder)
-- Stores remote refs (RequestLockOn, ClearLockOn, LockOnState).
-- Connects RequestLockOn.OnServerEvent and ClearLockOn.OnServerEvent.
-- Starts Heartbeat validation loop.

function TargetingServer.getLockState(entityId: string): LockState?
-- Returns current lock state for an entity. Called by WeaponServer before firing.

function TargetingServer.clearLock(entityId: string)
-- Clears lock for entity. Called on entity death/respawn.

function TargetingServer.computeLeadDirection(
    sourcePosition: Vector3,
    targetEntityId: string,
    projectileSpeed: number,
    autoAimSpread: number
): Vector3?
-- Computes lead aim direction using 2-iteration prediction.
-- Returns nil if target is dead or not found.
-- Called by WeaponServer when firing with active lock.
```

```lua
-- TargetingClient.luau (NEW)

function TargetingClient.init(remotes: Folder)
-- Stores LockOnState remote ref, connects OnClientEvent.
-- Starts RenderStepped loop for lock candidate scanning + HUD updates.

function TargetingClient.isLocked(): boolean
-- Returns whether local player has an active lock. Called by WeaponClient.

function TargetingClient.getLockedEntityId(): string?
-- Returns locked entity's ID. Called by WeaponClient for requiresLock check.

function TargetingClient.getLockedModel(): Model?
-- Returns locked target's Model. Called by WeaponClient for aim override.

function TargetingClient.requestLock()
-- Fires RequestLockOn remote with candidate entityId. Called by WeaponClient on T press.

function TargetingClient.requestClearLock()
-- Fires ClearLockOn remote. Called by WeaponClient on T press when locked.

function TargetingClient.onSeatExit()
-- Resets all local targeting state. Called by WeaponClient on turret exit.
```

```lua
-- WeaponServer.luau (MODIFIED)
-- In onFireWeapon, after resolving weaponConfig:
-- 1. If weaponConfig.requiresLock == true, check TargetingServer.getLockState(entityId) ~= nil. Refuse fire if no lock.
-- 2. If TargetingServer.getLockState(entityId) ~= nil and weaponConfig.autoAimSpread ~= nil:
--    call TargetingServer.computeLeadDirection(fireOrigin, lockState.targetEntityId, weaponConfig.projectileSpeed, weaponConfig.autoAimSpread)
--    If result ~= nil, use it as normalizedDirection instead of player-sent direction.

-- In fireSingleProjectile, after building projectileData:
-- If lockState ~= nil and weaponConfig.homingTurnRate > 0:
--    Set projectileData.targetEntityId = lockState.targetEntityId
--    Set projectileData.homingTurnRate = weaponConfig.homingTurnRate
```

```lua
-- ProjectileServer.luau (MODIFIED)

-- In stepProjectiles, for each projectile:
-- If projectile.targetEntityId ~= nil and projectile.homingTurnRate > 0:
--   Look up target model via HealthManager.getHealth(targetEntityId).instance
--   If target alive: compute direction to target center, rotate projectile.direction toward it
--   by at most homingTurnRate * dt degrees. Update projectile.currentPosition.
--   Use currentPosition instead of origin+direction*speed*elapsed for raycast.
-- Else: existing straight-line logic unchanged.

-- New field on ProjectileData: currentPosition (Vector3?) — set on first homing step.

-- In applyDamageToHumanoidTarget, before TakeDamage:
-- If target player is seated in a CombatEntity turret model:
--   Check turret's TurretExposed attribute. If false, block damage and return false.
```

```lua
-- ProjectileVisuals.luau (MODIFIED)

-- ActiveBolt gains: targetEntityId (string?), homingTurnRate (number?), currentPosition (Vector3?)
-- In onRenderStepped, for bolts with targetEntityId and homingTurnRate > 0:
--   Find target model via CollectionService:GetTagged("CombatEntity") + EntityId attribute match.
--   If found: rotate bolt.direction toward target center at homingTurnRate * dt.
--   Update bolt.currentPosition. Use currentPosition for CFrame instead of origin+direction*distance.
-- In onProjectileFired: read payload.targetEntityId and payload.homingTurnRate into ActiveBolt.
```

```lua
-- CombatHUD.luau (MODIFIED)

function CombatHUD.showLockReady(visible: boolean)
-- Shows/hides "TARGET LOCK READY" label above crosshair.

function CombatHUD.showLockReticle(visible: boolean)
-- Shows/hides diamond lock bracket frame.

function CombatHUD.setLockReticleScreenPosition(position: Vector2)
-- Positions lock reticle bracket at screen coordinates.

function CombatHUD.showLeadingIndicator(visible: boolean)
-- Shows/hides lead dot.

function CombatHUD.setLeadingIndicatorScreenPosition(position: Vector2)
-- Positions lead dot at screen coordinates.
```

---

## New Data Structures

```lua
-- CombatTypes.luau additions

export type LockState = {
    attackerEntityId: string,
    targetEntityId: string,
    lockedAt: number,
}

-- Add to WeaponConfig:
    lockRange: number?,         -- max distance to acquire lock. Must be < maxRange.
    autoAimSpread: number?,     -- degrees of random spread added to auto-aim. 0 = perfect.
    requiresLock: boolean?,     -- if true, weapon refuses to fire without active lock.
    homingTurnRate: number?,    -- degrees/sec missile turns toward target. 0 or nil = straight.

-- Add to EntityConfig:
    turretExposed: boolean?,    -- true = operator can be damaged. nil/false = enclosed.

-- Add to ProjectileData:
    targetEntityId: string?,    -- entity ID of homing target (nil = straight projectile)
    homingTurnRate: number?,    -- degrees/sec for homing rotation (nil = straight)
    currentPosition: Vector3?,  -- tracked position for homing projectiles (nil = use origin formula)

-- Add to ProjectileFiredPayload:
    targetEntityId: string?,    -- passed to clients for visual homing
    homingTurnRate: number?,    -- passed to clients for visual homing
```

---

## New Config Values

```lua
-- CombatConfig.luau additions

-- TARGETING
CombatConfig.LockOnScanRadius = 8        -- screen-space radius in degrees for lock candidate detection (client-side)
CombatConfig.LockValidationInterval = 0.2 -- seconds between server lock validation ticks
CombatConfig.LockBreakRange = 1.15       -- multiplier on lockRange for lock break distance (hysteresis)

-- WEAPON UPDATES (add fields to existing entries)
-- blaster_turret: lockRange = 600, autoAimSpread = 1.5
-- blaster_turret_burst: lockRange = 600, autoAimSpread = 1.2
-- turbolaser_turret: lockRange = 1200, autoAimSpread = 0.8
-- ion_turret: lockRange = 600, autoAimSpread = 1.0
-- torpedo_launcher: lockRange = 1000, autoAimSpread = 0, requiresLock = true
-- missile_battery: lockRange = 900, autoAimSpread = 0, requiresLock = true, homingTurnRate = 45

-- ENTITY UPDATES (add turretExposed to existing entries)
-- All current turret entities: turretExposed = true (exposed — player can be hit)
-- turbolaser_turret entity: turretExposed = false (enclosed emplacement)
```

---

## Data Flow for New Behaviors

### Lock-On Flow
1. **Client scan (TargetingClient, every RenderStepped):** While seated in turret, raycast from camera toward crosshair. Check all CombatEntity-tagged models within LockOnScanRadius degrees of aim direction. Filter: must be alive, enemy faction, within lockRange, within turret arc. If valid candidate found → call `CombatHUD.showLockReady(true)`. Store candidateEntityId.
2. **Player presses T (WeaponClient):** If not locked and candidate exists → `TargetingClient.requestLock()` → fires RequestLockOn remote with candidateEntityId and attackerEntityId.
3. **Server validates (TargetingServer, OnServerEvent):** Check: attacker is alive, target is alive, target is enemy, target within lockRange, target within turret arc (via WeaponRig.clampDirectionToMountLimits check). If valid → store LockState, fire LockOnState remote to attacker player with `{attackerEntityId, targetEntityId, locked = true}`.
4. **Client receives lock confirm (TargetingClient, OnClientEvent):** Store locked state. `CombatHUD.showLockReticle(true)`. Begin tracking target position for reticle + leading indicator.
5. **Server validation loop (TargetingServer, Heartbeat every LockValidationInterval):** For each active lock: check target alive, within lockRange * LockBreakRange, within turret arc. If invalid → clear lock, fire LockOnState to player with `{locked = false}`.
6. **Lock cleared (T again, target dies, player exits turret):** TargetingServer clears lock state, client hides lock HUD.

### Auto-Aim When Locked
1. **Player fires (WeaponClient → FireWeapon remote):** Player sends their aim direction as normal.
2. **Server intercepts (WeaponServer.onFireWeapon):** After resolving weaponConfig, check `TargetingServer.getLockState(entityId)`. If locked and autoAimSpread is configured: call `TargetingServer.computeLeadDirection(fireOrigin, targetEntityId, projectileSpeed, autoAimSpread)`. If returns non-nil, replace normalizedDirection with it.
3. **Lead computation (TargetingServer.computeLeadDirection):** Get target model pivot position + `AssemblyLinearVelocity` from target's PrimaryPart (or first BasePart). Iteration 1: time = distance / projectileSpeed, predicted = targetPos + velocity * time. Iteration 2: recalculate with new distance. Add random spread cone (autoAimSpread degrees). Return normalized direction from source to predicted point.
4. **Projectile fires with corrected direction.** No change to projectile physics — it flies straight along the lead direction.

### Homing Missile
1. **Fire (WeaponServer.fireSingleProjectile):** If lock active and homingTurnRate > 0 → set `projectileData.targetEntityId` and `projectileData.homingTurnRate`.
2. **Server tracking (ProjectileServer.stepProjectiles):** Each frame, for homing projectile: look up target via `HealthManager.getHealth(targetEntityId)`. If target alive, compute direction from `projectile.currentPosition` to target pivot. Rotate `projectile.direction` toward target direction by `homingTurnRate * dt` degrees (using slerp-style clamp). Advance `projectile.currentPosition` by `projectile.direction * projectile.speed * dt`. Use `currentPosition` as raycast origin. If target dead → stop homing, fly straight from current position/direction.
3. **Client visual (ProjectileVisuals.onRenderStepped):** Same logic mirrored client-side. Find target model by scanning CombatEntity tags for matching EntityId. Rotate bolt direction + update currentPosition.
4. **Payload (ProjectileServer.fireProjectile):** Send `targetEntityId` and `homingTurnRate` in ProjectileFired payload to clients.

### Turret Exposure Check
1. **Projectile hits player character (ProjectileServer.applyDamageToHumanoidTarget):** Before applying damage, check if target player's Humanoid.SeatPart is a TurretSeat inside a CombatEntity. If yes, read `TurretExposed` attribute from the entity model. If `false` → block damage, return `(false, false, nil, nil, false)`. Log `[P4_ENCLOSED_BLOCK]`.

### Torpedo Requires Lock
1. **Client check (WeaponClient.tryFireCurrentWeapon):** Read `WeaponRequiresLock` attribute from turret model. If true and `TargetingClient.isLocked() == false` → refuse fire, return false.
2. **Server check (WeaponServer.onFireWeapon):** If `weaponConfig.requiresLock == true` and `TargetingServer.getLockState(entityId) == nil` → refuse fire, log `[P4_LOCK_REQUIRED]`, return.

---

## Integration Pass (against real code)

### Data Lifecycle Traces

**LockState**
- **Created by:** TargetingServer on RequestLockOn event handler → LockState
- **Passed via:** Stored in `locksByEntityId: { [string]: LockState }` table in TargetingServer
- **Received by:** WeaponServer calls `TargetingServer.getLockState(entityId)` — returns LockState?
- **Stored in:** TargetingServer module-local table, keyed by attackerEntityId
- **Cleaned up by:** TargetingServer.clearLock(entityId), called on: validation loop break, ClearLockOn event, entity death (via respawn callback in CombatInit), seat exit
- **Verified:** Types match (string entityId keys), timing safe (validation loop runs on Heartbeat), cleanup on all exit paths

**Homing ProjectileData fields**
- **Created by:** WeaponServer.fireSingleProjectile — sets targetEntityId/homingTurnRate on ProjectileData if lock active
- **Passed via:** ProjectileData table stored in activeProjectiles (ProjectileServer)
- **Received by:** ProjectileServer.stepProjectiles reads targetEntityId/homingTurnRate each frame
- **Stored in:** activeProjectiles[projectileId] — lifetime = until hit or maxRange
- **Cleaned up by:** activeProjectiles[projectileId] = nil on hit/expire (existing cleanup, line 341)
- **Verified:** Fields are optional (nil = straight projectile), no change to existing straight-line path

**Client lock state**
- **Created by:** TargetingServer fires LockOnState remote to specific player
- **Passed via:** RemoteEvent:FireClient(player, payload)
- **Received by:** TargetingClient.OnClientEvent handler — stores lockedEntityId, lockedModel
- **Stored in:** TargetingClient module-local variables
- **Cleaned up by:** TargetingClient.onSeatExit() clears all, also cleared on lock-break remote
- **Verified:** Client state is read-only display — server is authoritative

### API Composition Checks (new calls only)

| Caller | Callee | Args Match | Return Handled | Verified Against |
|--------|--------|-----------|----------------|-----------------|
| TargetingServer.validate() | HealthManager.isAlive(entityId: string) | Yes (string) | Yes (boolean) | HealthManager.luau:599 |
| TargetingServer.validate() | HealthManager.getFaction(entityId: string) | Yes (string) | Yes (string?) | HealthManager.luau:604 |
| TargetingServer.validate() | HealthManager.getHealth(entityId: string) | Yes (string) | Yes (HealthState?) | HealthManager.luau:587 |
| TargetingServer.computeLeadDirection() | HealthManager.getHealth(entityId: string) | Yes (string) | Yes (HealthState?) — reads .instance | HealthManager.luau:587 |
| WeaponServer.onFireWeapon() | TargetingServer.getLockState(entityId: string) | Yes (string) | Yes (LockState?) | New module |
| WeaponServer.fireSingleProjectile() | TargetingServer.getLockState(entityId: string) | Yes (string) | Yes (LockState?) | New module |
| WeaponServer.onFireWeapon() | TargetingServer.computeLeadDirection(pos, id, speed, spread) | Yes (Vector3, string, number, number) | Yes (Vector3?) | New module |
| ProjectileServer.stepProjectiles() | HealthManager.getHealth(entityId: string) | Yes (string) | Yes (HealthState?) — reads .instance | HealthManager.luau:587 |
| ProjectileServer.applyDamageToHumanoidTarget() | CollectionService:HasTag(seatPart, "TurretSeat") | Yes (Instance, string) | Yes (boolean) | Roblox API |
| CombatInit | TargetingServer.init(remotes: Folder) | Yes (Folder) | None | New module |
| CombatInit respawnCallback | TargetingServer.clearLock(entityId: string) | Yes (string) | None | New module |
| WeaponClient T keybind | TargetingClient.requestLock() / requestClearLock() | No args | None | New module |
| WeaponClient.tryFireCurrentWeapon() | TargetingClient.isLocked() | No args | Yes (boolean) | New module |
| CombatClient | TargetingClient.init(remotes: Folder) | Yes (Folder) | None | New module |

---

## Diagnostics Updates

### New AI Build Prints
- `[P4_LOCK_ACQUIRED]` — server accepted lock. Includes attackerEntityId, targetEntityId.
- `[P4_LOCK_BROKEN]` — server validation loop broke lock. Includes reason (dead, range, arc).
- `[P4_LOCK_CLEARED]` — player explicitly cleared lock or exited turret.
- `[P4_LOCK_REQUIRED]` — fire refused because weapon requires lock and none active.
- `[P4_AUTO_AIM]` — auto-aim lead direction computed. Includes spread angle applied.
- `[P4_HOMING]` — homing projectile turned toward target this frame. Includes turn angle.
- `[P4_HOMING_LOST]` — homing target died, missile flying straight.
- `[P4_ENCLOSED_BLOCK]` — damage blocked because operator is in enclosed turret.

### New Health Counters
None.

---

## Startup Validator Updates

| Contract | Check | Error Message |
|----------|-------|---------------|
| lockRange < maxRange | For each weapon with lockRange, verify lockRange < weapon's maxRange | `[VALIDATE] Weapon '%s' lockRange (%d) must be less than maxRange (%d)` |
| turretExposed type | If entity config has turretExposed, verify it is boolean | `[VALIDATE] Entity '%s' turretExposed must be boolean` |

---

## Golden Tests for This Pass

### Test 10: Lock-On Flow
- **Setup:** Empire blaster_turret (lockRange=600) at (0, 5, 0). Rebel target_dummy (hullHP=200) at (0, 5, 50). Player seated in turret. TestHarnessEnabled = true.
- **Action:** Player aims at target. Harness calls RequestLockOn with target entity ID. Then fires 3 shots.
- **Expected:** Lock accepted (`[P4_LOCK_ACQUIRED]`). Auto-aim activates — all 3 shots hit despite minor aim offset. Target HP drops from 200 (3 x 40 = 120 damage applied).
- **Pass condition:** 1x `[P4_LOCK_ACQUIRED]` log. 3x `[P4_AUTO_AIM]` logs. 3x `[P1_HIT]` logs. Target HP = 80.

### Test 11: Torpedo Requires Lock
- **Setup:** Empire torpedo_turret (requiresLock=true) at (0, 5, 0). Rebel target_dummy at (0, 5, 50). TestHarnessEnabled = true.
- **Action:** Harness attempts to fire without lock (step 1). Then acquires lock on target (step 2). Then fires (step 3).
- **Expected:** Step 1: fire refused. Step 2: lock acquired. Step 3: torpedo fires and hits.
- **Pass condition:** 1x `[P4_LOCK_REQUIRED]` log (step 1, no `[P1_FIRE]`). 1x `[P4_LOCK_ACQUIRED]` log (step 2). 1x `[P1_FIRE]` + 1x `[P1_HIT]` log (step 3).

### Test 12: Homing Missile Hit
- **Setup:** Empire missile_turret (homingTurnRate=45, lockRange=900) at (0, 5, 0). Rebel target_dummy at (30, 5, 80) — offset laterally so a straight shot would miss. TestHarnessEnabled = true.
- **Action:** Harness acquires lock on target. Fires 1 missile aimed straight ahead (not toward target).
- **Expected:** Missile curves toward target over ~1-2 seconds and hits.
- **Pass condition:** 1x `[P4_LOCK_ACQUIRED]`. Multiple `[P4_HOMING]` logs (missile turning). 1x `[P1_HIT]`. Target takes 80 damage (concussion_missile, 1.0 hull mult).

### Test 13: Enclosed Turret Protection
- **Setup:** Empire turbolaser_turret entity (turretExposed=false) with player seated. Rebel blaster_turret at (0, 5, 60) aimed at the seated player's character. TestHarnessEnabled = true.
- **Action:** Rebel turret fires 3 shots that hit the player character.
- **Expected:** All 3 shots blocked — player takes 0 damage. Turret entity itself can still take damage normally (separate entity HP).
- **Pass condition:** 3x `[P4_ENCLOSED_BLOCK]` logs. Player Humanoid.Health unchanged. 0x `[P1_HIT_PLAYER]` logs for the enclosed player.

### Regression Tests
Re-run Pass 1 Tests 1-4, Pass 2 Tests 5-6, Pass 3 Tests 7-9. All existing combat behaviors must be identical — targeting is additive, no lock = existing manual aim behavior unchanged.

---

## Critic Review Notes
<!-- Filled in after critic review -->
