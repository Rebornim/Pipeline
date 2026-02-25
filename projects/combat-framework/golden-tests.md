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

## Pass 5: Speeder Movement

### Test 14: Speeder Drives and Hovers
- **Added in:** Pass 5
- **Setup:** Placeholder speeder (empire, light_speeder config, hullHP=100) on flat Baseplate terrain at (0, 10, 0). TestHarnessEnabled = true.
- **Action:** Harness seats a test character in DriverSeat, injects throttle=1 and steerX=0 input for 3 seconds via VehicleServer directly (bypass remote for harness).
- **Expected:** Speeder accelerates from 0 toward maxSpeed (120). Hover height stabilizes at ~4 studs above terrain. Heading stays constant (steer=0).
- **Pass condition:**
  - `[P5_SPEED]` logs at 0.5s intervals showing increasing speed: 0 → ~40 → ~80 → ~110+
  - `[P5_HOVER]` logs showing hover height within ±1 stud of target (4)
  - `[P5_SUMMARY]` confirms: final speed > 100, hover height error < 1 stud, grounded count = 4

### Test 15: Wall Collision + Impact Damage
- **Added in:** Pass 5
- **Setup:** Speeder at (0, 10, 0). Anchored wall part (size 20x20x2) at (0, 10, -80). Speeder facing wall (heading toward -Z). TestHarnessEnabled = true.
- **Action:** Harness injects throttle=1, steerX=0. Wait until collision.
- **Expected:** Speeder accelerates toward wall. On collision: velocity drops to ~0 (slight bounce), HP decreases from impact damage.
- **Pass condition:**
  - `[P5_COLLISION]` log with impactSpeed > collisionDamageThreshold (30) and damage > 0
  - `[P1_DAMAGE]` log showing hull HP decrease (impact damage type)
  - `[P5_SPEED]` log after collision showing speed < 5
  - `[P5_SUMMARY]` confirms: collision detected, damage applied, vehicle stopped

### Test 16: Airborne + Fall Damage
- **Added in:** Pass 5
- **Setup:** Speeder on an elevated platform (anchored part at Y=50, size 40x2x40). Edge of platform at Z=-20. Open air beyond. TestHarnessEnabled = true.
- **Action:** Harness injects throttle=1, steerX=0. Speeder drives off edge.
- **Expected:** Speeder goes airborne when hover raycasts find no ground. Gravity pulls it down. On landing (baseplate at Y=0), fall damage applies based on vertical impact speed.
- **Pass condition:**
  - `[P5_AIRBORNE]` log when grounded count drops to 0
  - `[P5_FALL_DAMAGE]` log with vertical impact speed and damage amount
  - `[P1_DAMAGE]` log showing hull HP decrease (impact damage type)
  - `[P5_SUMMARY]` confirms: went airborne, fell ~50 studs, fall damage applied

### Regression Tests
Re-run Pass 1 Tests 1-4, Pass 2 Tests 5-6, Pass 3 Tests 7-9, Pass 4 Tests 10-13. Vehicle changes must NOT affect turret combat behavior. Key regression risks: HealthManager destroy callback addition, new DamageType "impact", new RemoteEvents.

---

## Pass 6: Speeder Combat

### Test 17: Vehicle Driver Fire
- **Added in:** Pass 6
- **Setup:** Empire armed light speeder (`ConfigId=light_speeder_armed`, `VehicleCategory=light`, blaster_turret weapon) at (0, 10, 0). Rebel target_dummy (hullHP=200) at (0, 5, 50). Player seated in DriverSeat. TestHarnessEnabled = true.
- **Action:** Player fires 3 shots at target.
- **Expected:** All 3 hit. Target HP decreases from 200 to 80 (3 x 40 blaster damage).
- **Pass condition:** 3x `[P6_VEHICLE_FIRE]` logs. 3x `[P1_HIT]` logs. 3x `[P1_DAMAGE]` logs showing -40 each. Target HP = 80.

### Test 18: Vehicle Destruction Kills All Occupants
- **Added in:** Pass 6
- **Setup:** Armed speeder with 2 occupants (driver + 1 passenger in second seat). HullHP = 40. TestHarnessEnabled = true.
- **Action:** Rebel turret fires 1 shot dealing 40+ damage.
- **Expected:** Vehicle destroyed. Both occupants die.
- **Pass condition:** `[P6_VEHICLE_DESTROY]` with occupants=2. `[P1_DESTROYED]` log. Both humanoids Health = 0.

### Test 19: Enclosed Vehicle Rider Protection
- **Added in:** Pass 6
- **Setup:** Empire heavy armed speeder (`turretExposed=false`). Player driving. Rebel turret fires at player character.
- **Expected:** Shots blocked by enclosed protection. Player takes 0 direct damage. Vehicle hull takes damage instead.
- **Pass condition:** `[P4_ENCLOSED_BLOCK]` logs. Player Humanoid.Health unchanged. Vehicle HullHP decreases.

### Regression Tests
Re-run Pass 1 Tests 1-4, Pass 2 Tests 5-6, Pass 3 Tests 7-9, Pass 4 Tests 10-13, Pass 5 Tests 14-16. Vehicle weapon changes must NOT affect existing turret combat or vehicle movement behavior.

---

## Pass 8: Biped Walker Movement

### Test 20: Walker Forward/Back/Strafe Movement
- **Added in:** Pass 8
- **Setup:** Walker model (empire, walker_biped config, hullHP=300) on flat Baseplate terrain. TestHarnessEnabled = true.
- **Action:** Player sits in DriverSeat. Press W (forward), S (reverse), A (strafe left), D (strafe right). Mouse to turn body. Shift to sprint.
- **Expected:** Walker body moves in correct WASD directions relative to body facing. Mouse turns body. Speed matches config (maxSpeed=22 forward, reverseMaxSpeed=7.5 back, strafeMaxSpeed=12 sides, sprintMaxSpeed=62.5). Body stays at walkHeight (~15 studs) above ground. IK feet plant with gait-driven alternation. Body secondary motion visible (sway, bob, lean, jolt).
- **Pass condition:** Visual: walker moves in all 4 directions, body height consistent, IK feet plant on ground, gait-driven stepping, sprint feels faster with different stride.
- **Result (Pass 8 build):** PASS. All movement directions working. Gait oscillator drives step timing. Sprint system functional. Body secondary motion tuned for AT-ST feel.

### Test 21: Cliff Fall + Fall Damage
- **Added in:** Pass 8
- **Setup:** Walker on elevated platform. walkHeight=15, fallDamageThreshold=80, gravity=196. TestHarnessEnabled = true.
- **Action:** Walk off edge.
- **Expected:** Walker falls under gravity. Lands on ground. Fall damage if impact speed > threshold. Walker resumes walking.
- **Pass condition:** Walker visually falls, lands, takes damage if applicable, can move again.
- **Result (Pass 8 build):** PASS. Fall and landing working. IK legs reacquire ground after landing.

### Test 22: IK Foot Placement on Uneven Terrain
- **Added in:** Pass 8
- **Setup:** Walker on terrain with hills and slopes within maxClimbSlope (45 degrees).
- **Action:** Walk across varied terrain for 10+ seconds.
- **Expected:** Feet plant at actual ground height. Body secondary motion visible. Steps adapt to terrain. Head follows mouse within arc limits (±120 yaw).
- **Pass condition:** Visual only. Feet touch ground. No floating feet. Body secondary motion visible. Head tracks mouse.
- **Result (Pass 8 build):** PASS. Feet plant on terrain. Foot surface orientation from 3-point probe. Smooth normal transitions. Intermittent stretch during terrain loading/lag (cosmetic, self-correcting).

### Regression Tests
Re-run Pass 1 Tests 1-4, Pass 2 Tests 5-6, Pass 3 Tests 7-9, Pass 4 Tests 10-13, Pass 5 Tests 14-16, Pass 6 Tests 17-19. Walker changes must NOT affect turret combat, shield system, or speeder movement/combat behavior. Key regression risks: CombatInit entity routing, VehicleClient walker class check, VehicleInput payload backward-compatibility.

---

## Pass 9: Walker Combat

### Test 23: Walker Driver Fire
- **Added in:** Pass 9
- **Setup:** Walker (empire, walker_biped config, hullHP=800, shieldHP=200, weaponId=walker_chin_blaster) on flat terrain. Rebel target_dummy (hullHP=200) at 50 studs distance. Player seated as driver.
- **Action:** Player fires 10 shots at target via left click.
- **Expected:** 10 hits. Target HP decreases by 200 (10 x 20 damage). Fire sound plays (STShoot). Overheat bar visible in HUD.
- **Pass condition:** `[P9_SUMMARY] walkerFires>=10 errors=0`. 10x `[P1_HIT]`. Target HP = 0.

### Test 24: Walker Destruction Kills Occupant
- **Added in:** Pass 9
- **Setup:** Walker (hullHP=800, shieldHP=200). Player seated as driver. External rebel turbolaser (damage=150, turbolaser shield/hull multipliers).
- **Action:** Fire enough shots to deplete shields then hull.
- **Expected:** Shields absorb first. Hull reaches 0 → explosion → driver killed.
- **Pass condition:** `[P9_COMBAT_DESTROY]` with occupants=1. Driver Humanoid.Health = 0.

### Test 25: Walker Enclosed Protection
- **Added in:** Pass 9
- **Setup:** Walker (turretExposed=false) with player driving. External rebel blaster aimed at player character inside cockpit.
- **Action:** Rebel fires 3 shots hitting the player character.
- **Expected:** All blocked by enclosed protection. Player takes 0 damage. Walker hull takes damage.
- **Pass condition:** 3x `[P4_ENCLOSED_BLOCK]`. Player Humanoid.Health unchanged.

### Regression Tests
Re-run Pass 1 Tests 1-4, Pass 2 Tests 5-6, Pass 3 Tests 7-9, Pass 4 Tests 10-13, Pass 5 Tests 14-16, Pass 6 Tests 17-19, Pass 8 Tests 20-22. Walker combat additions must NOT affect turret, speeder, artillery, or walker movement behavior.

---

## Pass 9.5: Bugfix Stabilization

### Test 26: Walker Long-Distance No Ejection
- **Added in:** Pass 9.5
- **Setup:** Walker on flat terrain. Player seated as driver.
- **Action:** Walk forward 200+ studs. Sprint back to start. Repeat.
- **Expected:** Player never ejected from walker. Controls remain responsive.
- **Pass condition:** No seat ejection after 200+ studs of travel.

### Test 27: Remote Walker Full Visual
- **Added in:** Pass 9.5
- **Setup:** Walker with driver (Player A). Second player (Player B) observing from 30 studs.
- **Action:** Player A walks, sprints, aims head, fires weapon.
- **Expected:** Player B sees: legs stepping with IK, head/turret rotating, driver character in cockpit, fire visual from chin muzzles.
- **Pass condition:** Visual inspection — all parts animate for observer.

### Test 28: Lock-On Facing Break
- **Added in:** Pass 9.5
- **Setup:** Turret with lock-on capability (lockRange=600). Rebel target at 50 studs in front.
- **Action:** Lock target. Turn turret/vehicle 180° away from target.
- **Expected:** Lock breaks when target passes 90° from entity forward.
- **Pass condition:** Lock breaks and HUD shows lock-lost cue.

### Test 29: Remote Turret Rotation Visible
- **Added in:** Pass 9.5
- **Setup:** Turret manned by Player A. Player B observing from 20 studs.
- **Action:** Player A aims turret left, right, up, down.
- **Expected:** Player B sees turret barrel and body parts rotating with Player A's aim.
- **Pass condition:** Visual inspection — driven parts rotate for observer.

### Regression Tests
Re-run Pass 1 Tests 1-4, Pass 2 Tests 5-6, Pass 3 Tests 7-9, Pass 4 Tests 10-13, Pass 5 Tests 14-16, Pass 6 Tests 17-19, Pass 8 Tests 20-22, Pass 9 Tests 23-25. Stabilization fixes must NOT break existing combat, vehicle, or walker behavior.

---

## Pass 10: Fighter Flight

### Test 30: Fighter Forward Flight
- **Added in:** Pass 10
- **Setup:** Fighter (empire, fighter config, minSpeed=80, maxSpeed=400) at altitude Y=150. Player in PilotSeat.
- **Action:** Press W for 3 seconds. Release. Press S for 2 seconds.
- **Expected:** Speed increases from 80 toward 400 (W). Maintains speed on release. Decreases toward 80 (S). Never goes below 80. Fighter moves forward continuously.
- **Pass condition:** `[P10_SPEED]` shows speed increasing/decreasing correctly. Speed never < 80 while piloted.

### Test 31: Fighter Turning + Full Loop
- **Added in:** Pass 10 (updated in redesign)
- **Setup:** Fighter in flight at speed 150.
- **Action:** Move mouse right (hold), then left. Then pitch up continuously until completing a full vertical loop.
- **Expected:** Yaw works smoothly. Full vertical loop completes with no control inversion, no gimbal lock, no camera snap. Controls remain consistent through all orientations.
- **Pass condition:** `[P10_ORIENT]` shows pitch passing through 90, 180 (inverted), 270, 360. No errors. Camera smooth throughout.

### Test 32: Fighter Roll + Auto-Level
- **Added in:** Pass 10
- **Setup:** Fighter in flight at speed 150.
- **Action:** Hold A (roll left) for 1 second. Release all input. Wait 3 seconds.
- **Expected:** Ship rolls left while A held. On release, auto-levels gradually back to wings-level (within autoLevelDeadzone). Auto-level rate matches config (30 deg/sec).
- **Pass condition:** `[P10_ORIENT]` roll angle returns toward 0 after A release. Roll stabilizes within +/-5 degrees of level.

### Test 33: Ground Collision
- **Added in:** Pass 10
- **Setup:** Fighter in flight at altitude Y=100, heading downward (nose pitched toward ground).
- **Action:** Fly into terrain.
- **Expected:** Fighter bounces off terrain surface. Does NOT go underground. Speed reduces. Pitch corrected upward.
- **Pass condition:** `[P10_COLLISION]` fires. Fighter Y position never below terrain + collisionRadius.

### Regression Tests
Re-run Pass 1 Tests 1-4, Pass 2 Tests 5-6, Pass 3 Tests 7-9, Pass 4 Tests 10-13, Pass 5 Tests 14-16, Pass 6 Tests 17-19, Pass 8 Tests 20-22, Pass 9 Tests 23-25, Pass 9.5 Tests 26-29. Fighter additions must NOT affect turret, speeder, walker, or artillery behavior. Key regression risks: VehicleInput remote handler changes, CombatInit routing, VehicleClient routing.

---
