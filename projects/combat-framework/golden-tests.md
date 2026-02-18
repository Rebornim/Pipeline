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
