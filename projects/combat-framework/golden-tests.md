# Golden Tests: Combat Framework

Tests accumulate across passes. Every prove step runs ALL tests, not just the current pass's.

---

## Pass 1: Core Combat Loop

### Test 1: Direct Fire Hits
- **Added in:** Pass 1
- **Setup:** Placeholder turret (empire, blaster_turret config) at (0, 5, 0). Target dummy (rebel, target_dummy config, hullHP=200) at (0, 5, 50). Direct line of sight. TestHarnessEnabled = true.
- **Action:** Harness fires 3 projectiles from turret at target with calculated aim direction.
- **Expected:** All 3 hit. Target HP decreases from 200 to 80 (3 hits x 40 damage each).
- **Pass condition:** 3 `[P1_HIT]` logs, 3 `[P1_DAMAGE]` logs each showing -40 HP, final target HP = 80.

### Test 2: Friendly Fire Prevention
- **Added in:** Pass 1
- **Setup:** Two empire-faction entities, 50 studs apart. TestHarnessEnabled = true.
- **Action:** Harness fires 3 projectiles from one empire entity at the other.
- **Expected:** 0 damage applied. All 3 shots blocked by faction check.
- **Pass condition:** 3 `[P1_FACTION_BLOCK]` logs. 0 `[P1_DAMAGE]` logs for that target. Target HP unchanged.

### Test 3: Destruction + Respawn
- **Added in:** Pass 1
- **Setup:** Target with hullHP=30, respawnTime=5, damage=40 per hit. TestHarnessEnabled = true.
- **Action:** Harness fires 1 shot (lethal), then waits 6 seconds.
- **Expected:** Target destroyed after 1 hit. Respawns ~5 seconds later with full HP.
- **Pass condition:** `[P1_DESTROYED]` log, then `[P1_RESPAWNED]` log 5 +/- 1 seconds later. Target HP restored to 30.

### Test 4: Max Range Expiry
- **Added in:** Pass 1
- **Setup:** Turret at origin. Target at 1000 studs distance. Weapon maxRange = 500. TestHarnessEnabled = true.
- **Action:** Harness fires 3 projectiles toward distant target.
- **Expected:** All 3 expire at ~500 studs. 0 hits registered.
- **Pass condition:** 3 `[P1_EXPIRED]` logs. 0 `[P1_HIT]` logs. `[P1_SUMMARY]` confirms 0 hits.

### Regression Tests
None (first pass).

---

## Pass 2: Shield System

### Test 5: Shield Full Lifecycle
- **Added in:** Pass 2
- **Setup:** Empire blaster_turret (damage=40) at (0, 5, 0). Rebel shield_test_target (shieldHP=60, hullHP=100, no regen) at (0, 5, 50). Direct line of sight. TestHarnessEnabled = true.
- **Action:** Harness fires 4 projectiles sequentially at target.
- **Expected:**
  - Shot 1: shield 60 -> 20, hull 100 unchanged. impactType = "shield".
  - Shot 2: shield 20 -> 0 (absorbed 20), overflow 20 to hull. Hull 100 -> 80. impactType = "shield".
  - Shot 3: shield 0, hull 80 -> 40. impactType = "hull".
  - Shot 4: hull 40 -> 0. Target destroyed. impactType = "hull".
- **Pass condition:** 2x `[P2_SHIELD_ABSORB]`, 1x `[P2_SHIELD_BREAK]`, 1x `[P2_SHIELD_OVERFLOW]` (overflow=20), 3x `[P1_DAMAGE]` for hull, 1x `[P1_DESTROYED]`. ShieldHP=0 after shot 2, HullHP=0 after shot 4.

### Test 6: Shield Regeneration
- **Added in:** Pass 2
- **Setup:** Empire blaster_turret (damage=40) at (0, 5, 0). Rebel shield_regen_target (shieldHP=100, hullHP=200, regenRate=50/sec, regenDelay=2) at (0, 5, 50). TestHarnessEnabled = true.
- **Action:** Harness fires 1 projectile (shield 100 -> 60). Wait 6 seconds.
- **Expected:** After 2s grace, regens at 50/sec. Shield fully restored to 100. Hull untouched at 200.
- **Pass condition:** 1x `[P2_SHIELD_ABSORB]` (100->60), 1x `[P2_REGEN_FULL]` within 3-5s of hit. ShieldHP attribute = 100. HullHP attribute = 200.

### Regression Tests
Re-run Pass 1 Tests 1-4. Unshielded entities must behave identically.

---

## Pass 3: Damage Types + Ammo

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

## Pass 4: Targeting System

### Test 10: Lock-On Flow
- **Added in:** Pass 4
- **Setup:** Empire blaster_turret (lockRange=600, autoAimSpread=1.5) at (0, 5, 0). Rebel target_dummy (hullHP=200) at (0, 5, 50). Player seated in turret. TestHarnessEnabled = true.
- **Action:** Player aims at target. Harness calls RequestLockOn with target entity ID. Then fires 3 shots.
- **Expected:** Lock accepted. Auto-aim activates — all 3 shots hit despite minor aim offset. Target HP drops by 120 (3 x 40 damage).
- **Pass condition:** 1x `[P4_LOCK_ACQUIRED]` log. 3x `[P4_AUTO_AIM]` logs. 3x `[P1_HIT]` logs. Target HP = 80.

### Test 11: Torpedo Requires Lock
- **Added in:** Pass 4
- **Setup:** Empire torpedo_turret (requiresLock=true) at (0, 5, 0). Rebel target_dummy at (0, 5, 50). TestHarnessEnabled = true.
- **Action:** Step 1: Harness attempts fire without lock. Step 2: Harness acquires lock on target. Step 3: Harness fires.
- **Expected:** Step 1: fire refused. Step 2: lock acquired. Step 3: torpedo fires and hits.
- **Pass condition:** 1x `[P4_LOCK_REQUIRED]` log (step 1, no `[P1_FIRE]`). 1x `[P4_LOCK_ACQUIRED]` log (step 2). 1x `[P1_FIRE]` + 1x `[P1_HIT]` log (step 3).

### Test 12: Homing Missile Hit
- **Added in:** Pass 4
- **Setup:** Empire missile_turret (homingTurnRate=45, lockRange=900) at (0, 5, 0). Rebel target_dummy at (30, 5, 80) — offset laterally so a straight shot would miss. TestHarnessEnabled = true.
- **Action:** Harness acquires lock on target. Fires 1 missile aimed straight ahead (not toward target).
- **Expected:** Missile curves toward target and hits.
- **Pass condition:** 1x `[P4_LOCK_ACQUIRED]`. Multiple `[P4_HOMING]` logs. 1x `[P1_HIT]`. Target takes 80 damage (concussion_missile, 1.0 hull mult).

### Test 13: Enclosed Turret Protection
- **Added in:** Pass 4
- **Setup:** Empire turbolaser_turret entity (turretExposed=false) with player seated. Rebel blaster_turret at (0, 5, 60) aimed at the seated player's character. TestHarnessEnabled = true.
- **Action:** Rebel turret fires 3 shots that hit the player character.
- **Expected:** All 3 shots blocked — player takes 0 damage. Turret entity itself can still take damage normally.
- **Pass condition:** 3x `[P4_ENCLOSED_BLOCK]` logs. Player Humanoid.Health unchanged. 0x `[P1_HIT_PLAYER]` logs for the enclosed player.

### Regression Tests
Re-run Pass 1 Tests 1-4, Pass 2 Tests 5-6, Pass 3 Tests 7-9. All existing combat behaviors must be identical — targeting is additive, no lock = existing manual aim behavior unchanged.

---

## Pass 5: Armed Ground Vehicles

### Test 14: Vehicle Gunner Fire From Moving Platform
- **Added in:** Pass 5
- **Setup:** Empire armed_speeder (hullHP=200, weaponId=blaster_turret) with TurretSeat. Rebel target_dummy at (0, 5, 80). Vehicle at (0, 5, 0). MovingTargetController on vehicle: mode=side, speed=3. TestHarnessEnabled = true.
- **Action:** Player seated in vehicle gunner TurretSeat. Vehicle moves side-to-side. Harness fires 3 shots aimed at target.
- **Expected:** Projectiles originate from moving vehicle's weapon mount. At least 2 of 3 hit target. Target takes damage.
- **Pass condition:** 3x `[P1_FIRE]` logs with differing projectile origins. At least 2x `[P1_HIT]` logs. Target HP < 200.

### Test 15: Vehicle Destruction Kills Occupants
- **Added in:** Pass 5
- **Setup:** Empire vehicle_test_target (hullHP=300, killOccupantsOnDestruction=true) with DriverSeat (player seated) and TurretSeat (second occupant). Rebel blaster_turret at (0, 5, 60). TestHarnessEnabled = true.
- **Action:** Rebel turret fires 8 shots to destroy vehicle (300 HP / 40 damage = 7.5, round up).
- **Expected:** Vehicle destroyed. All seated occupants killed (Humanoid.Health = 0).
- **Pass condition:** 1x `[P1_DESTROYED]` log. At least 1x `[P5_VEHICLE_KILL]` log per occupant. Occupant Humanoid.Health = 0.

### Test 16: Driver Enclosed Protection
- **Added in:** Pass 5
- **Setup:** Empire armed_speeder (turretExposed=false) with player in DriverSeat. Rebel blaster_turret at (0, 5, 50) aimed at player character. TestHarnessEnabled = true.
- **Action:** Rebel turret fires 3 shots hitting the driver's character.
- **Expected:** All 3 blocked. Driver takes 0 damage.
- **Pass condition:** 3x `[P4_ENCLOSED_BLOCK]` logs. Player Humanoid.Health unchanged.

### Test 17: Vehicle Respawn Restores Position
- **Added in:** Pass 5
- **Setup:** Empire armed_speeder (respawnTime=5) at (0, 5, 0). MovingTargetController drives it to ~(20, 5, 0). Vehicle destroyed. TestHarnessEnabled = true.
- **Action:** Destroy vehicle. Wait 6 seconds.
- **Expected:** Vehicle respawns at original (0, 5, 0), not at destruction position. Full HP restored.
- **Pass condition:** 1x `[P1_DESTROYED]`. 1x `[P5_SPAWN_RESTORE]`. 1x `[P1_RESPAWNED]`. Vehicle pivot within 1 stud of (0, 5, 0). HullHP = 200.

### Regression Tests
Re-run Pass 1 Tests 1-4, Pass 2 Tests 5-6, Pass 3 Tests 7-9, Pass 4 Tests 10-13. Static turrets must behave identically. DriverSeat check extends existing TurretSeat check without changing turret behavior.

---
