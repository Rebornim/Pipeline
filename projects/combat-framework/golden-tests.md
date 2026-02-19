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
