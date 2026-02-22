# Combat Framework — Attribute Reference

Every attribute the combat framework reads from Studio instances. Organized by what you put them on.

---

## How Percentage Modifiers Work

Most tuning attributes use the same formula: **`base * (1 + value)`**

| You type | Effect | Example (base = 100) |
|----------|--------|---------------------|
| `0` | No change | 100 |
| `0.5` | +50% | 150 |
| `1.0` | +100% (double) | 200 |
| `-0.3` | -30% | 70 |
| `-0.5` | -50% (half) | 50 |
| `2.0` | +200% (triple) | 300 |

All percentage modifiers are **number** type in Studio.

---

## 1. Entity Identity (on any CombatEntity model)

These go on the top-level Model that has the `CombatEntity` tag.

| Attribute | Type | Required | What to type | Notes |
|-----------|------|----------|-------------|-------|
| `ConfigId` | string | Yes | `blaster_turret`, `shielded_turret`, `turbolaser_turret`, `ion_turret`, `torpedo_turret`, `missile_turret`, `blaster_turret_burst`, `artillery_emplacement`, `target_dummy`, `shielded_target`, `shield_test_target`, `shield_regen_target`, `ion_test_target`, `torpedo_test_target`, `ammo_test_target`, `light_vehicle`, `heavy_vehicle` | Picks the base entity config — determines HP, shields, weapon, respawn time |
| `Faction` | string | Yes | `empire`, `rebel`, or `neutral` | Determines who can use it and friendly fire rules. Must match a team name (case-insensitive) |

---

## 2. Entity Combat Stats Modifiers (on any CombatEntity model)

Percentage modifiers that tune the base stats from ConfigId. Put these on the same Model as ConfigId.

| Attribute | Type | Config key | What it tunes | Example |
|-----------|------|-----------|--------------|---------|
| `EntityHullHPMod` | number | hullHP | Hull hit points | `0.5` on a `heavy_vehicle` (base 500) → 750 HP. `-0.3` → 350 HP |
| `EntityShieldHPMod` | number | shieldHP | Shield hit points. No effect if base config has no shields | `0.5` on `heavy_vehicle` (base 200) → 300 shields |
| `EntityShieldRegenRateMod` | number | shieldRegenRate | Shield HP regenerated per second | `-0.5` on `heavy_vehicle` (base 15) → 7.5/sec regen |
| `EntityShieldRegenDelayMod` | number | shieldRegenDelay | Seconds after taking shield damage before regen starts | `0.4` on `heavy_vehicle` (base 5) → 7 second delay |
| `EntityRespawnTimeMod` | number | respawnTime | Seconds to respawn after destruction | `-0.5` on `heavy_vehicle` (base 30) → 15 second respawn |

---

## 3. Vehicle Identity (on VehicleEntity models)

These go on the top-level Model that has both `CombatEntity` and `VehicleEntity` tags.

| Attribute | Type | Required | What to type | Notes |
|-----------|------|----------|-------------|-------|
| `VehicleCategory` | string | Yes | `light` or `heavy` | Picks the base movement/physics config. Light = fast/nimble/boost/lean. Heavy = slow/armored/no boost/no lean |
| `ForwardAxis` | string | One of these two | `X`, `-X`, `Z`, or `-Z` | Which of the model's local axes points forward. Use when the model is cleanly axis-aligned. Most models use `-Z` |
| `ForwardYawOffset` | number | is required | Any number (degrees) | Degrees of rotation from the model's local -Z axis. Use instead of ForwardAxis when the model's forward direction is at a weird angle (common with old Unions). `0` = -Z, `90` = +X, `180` = +Z, `-90` = -X. Trial-and-error: set a value, playtest, adjust until it drives correctly. **Overrides ForwardAxis if both are set** |

---

## 4. Vehicle Physics Modifiers (on VehicleEntity models)

Percentage modifiers on the same Model as VehicleCategory. All optional.

### Movement

| Attribute | Type | Base (light / heavy) | What it tunes | Example |
|-----------|------|---------------------|--------------|---------|
| `VehicleMaxSpeedMod` | number | 120 / 55 | Top speed (studs/sec) | `0.25` → light goes 150. `-0.2` → heavy goes 44 |
| `VehicleAccelerationMod` | number | 80 / 40 | How fast it reaches top speed | `0.5` → 50% quicker acceleration |
| `VehicleDecelerationMod` | number | 30 / 20 | Coast-down when releasing throttle | `-0.3` → slides further before stopping |
| `VehicleBrakingMod` | number | 60 / 45 | Active braking force (holding S while moving forward) | `0.5` → stops 50% faster |
| `VehicleReverseSpeedMod` | number | 30 / 15 | Top speed in reverse | `1.0` → doubles reverse speed |
| `VehicleTurnSpeedLowMod` | number | 120 / 70 | Turn rate at low speed (deg/sec) | `-0.3` → slower turns when slow |
| `VehicleTurnSpeedHighMod` | number | 45 / 25 | Turn rate at high speed (deg/sec) | `0.4` → more responsive at speed |
| `VehicleLateralGripLowMod` | number | 10 / 20 | Slide resistance at low speed. Higher = less drift | `0.5` → grippier at low speed |
| `VehicleLateralGripHighMod` | number | 4.5 / 12 | Slide resistance at high speed. Higher = less drift | `-0.3` → more drifty at speed |

### Hover Physics

| Attribute | Type | Base (light / heavy) | What it tunes | Example |
|-----------|------|---------------------|--------------|---------|
| `VehicleHoverHeightMod` | number | 1 / 1.5 | Float height above ground (studs) | `1.0` → doubles hover height. `-0.3` → 30% lower |
| `VehicleSpringStiffnessMod` | number | 250 / 300 | How hard springs push to target height. Higher = snappier | `0.5` → bouncier suspension |
| `VehicleSpringDampingMod` | number | 25 / 30 | Reduces spring oscillation. Higher = less bouncy | `0.3` → slightly more damped |
| `VehicleGravityMod` | number | 150 / 150 | Fall speed / weight feel | `0.5` → falls 50% faster, feels heavier |
| `VehicleTiltStiffnessMod` | number | 100 / 80 | How fast it tilts to match terrain angle | `0.5` → conforms to slopes faster |
| `VehicleTiltDampingMod` | number | 14 / 16 | Reduces tilt wobble. Higher = steadier | `-0.3` → more wobbly on rough terrain |
| `VehicleTerrainConformityMod` | number | 0.15 / 0.1 | How much it follows terrain slope (0-1 in base) | `0.5` → tilts more on hills |
| `VehicleMaxClimbSlopeMod` | number | 65 / 50 | Steepest climbable hill (degrees) | `0.3` → can climb steeper hills |

### Collision

| Attribute | Type | Base (light / heavy) | What it tunes | Example |
|-----------|------|---------------------|--------------|---------|
| `VehicleCollisionRadiusMod` | number | 4 / 6 | Hit detection radius (studs). Bigger vehicle = bigger radius | `0.5` → wider collision zone |
| `VehicleCollisionBounceMod` | number | 0.2 / 0.1 | Wall bounce elasticity. 0 = no bounce, 1 = full bounce | `1.0` → doubles bounce |
| `VehicleCollisionDmgThresholdMod` | number | 60 / 80 | Min impact speed (studs/sec) before wall damage | `0.5` → needs faster hit to take damage |
| `VehicleCollisionDmgScaleMod` | number | 1.2 / 0.8 | HP lost per unit of impact speed above threshold | `-0.5` → takes half wall damage |

### Fall Damage

| Attribute | Type | Base (light / heavy) | What it tunes | Example |
|-----------|------|---------------------|--------------|---------|
| `VehicleFallDmgThresholdMod` | number | 160 / 120 | Min fall speed (studs/sec) before landing damage | `0.5` → needs harder landing to take damage |
| `VehicleFallDmgScaleMod` | number | 0.5 / 0.4 | HP lost per unit of fall speed above threshold | `-0.5` → takes half fall damage |

### Camera

| Attribute | Type | Base (light / heavy) | What it tunes | Example |
|-----------|------|---------------------|--------------|---------|
| `VehicleCameraDistanceMod` | number | 15 / 22 | How far behind the camera sits (studs) | `0.5` → camera 50% further back. `-0.3` → tighter on vehicle |
| `VehicleCameraHeightMod` | number | 6 / 8 | How high above the vehicle the camera sits | `0.5` → higher camera angle |
| `VehicleCameraLerpMod` | number | 0.15 / 0.12 | Camera follow smoothness. Lower = smoother/laggier, higher = snappier | `0.5` → camera follows 50% faster |

### Boost

| Attribute | Type | Base (light / heavy) | What it tunes | Example |
|-----------|------|---------------------|--------------|---------|
| `VehicleBoostSpeedMod` | number | 1.5 / 1.0 | Speed multiplier during boost | `0.3` → boost goes 30% faster than default |
| `VehicleBoostDurationMod` | number | 5 / 0 | How many seconds boost lasts | `-0.4` → boost runs out 40% sooner |
| `VehicleBoostCooldownMod` | number | 6 / 0 | Seconds before boost can be used again | `0.5` → 50% longer cooldown |

### Lean (light only — heavy base values are 0 so modifiers have no effect)

| Attribute | Type | Base (light / heavy) | What it tunes | Example |
|-----------|------|---------------------|--------------|---------|
| `VehicleLeanBankAngleMod` | number | 15 / 0 | Max visual lean angle (degrees) | `0.5` → leans 22.5 degrees instead of 15 |
| `VehicleLeanTurnRateMod` | number | 50 / 0 | Extra turn rate (deg/sec) while leaning | `-0.3` → less turn bonus from leaning |
| `VehicleLeanSpeedPenaltyMod` | number | 0.01 / 0 | Fraction of speed lost while leaning | `1.0` → doubles the speed penalty |

---

## 5. Vehicle Boolean Overrides (on VehicleEntity models)

These replace the base value entirely (not percentage). Put on the same Model as VehicleCategory.

| Attribute | Type | Default (light / heavy) | What to type | Notes |
|-----------|------|------------------------|-------------|-------|
| `VehicleCanCrossWater` | boolean | true / false | Check or uncheck | Light can cross water by default, heavy can't |
| `VehicleBoostEnabled` | boolean | true / false | Check or uncheck | Light has boost by default, heavy doesn't |
| `VehicleLeanEnabled` | boolean | true / false | Check or uncheck | Light can lean by default, heavy can't |

---

## 6. Weapon/Turret Overrides (on CombatEntity turret models)

These go on the turret **Model** (the one with the `CombatEntity` tag). They override or replace values from the weapon config.

### String/Color Overrides (replace base value entirely)

| Attribute | Type | What to type | Notes |
|-----------|------|-------------|-------|
| `WeaponClass` | string | `projectile`, `burst_projectile`, or `artillery` | Changes the weapon's firing behavior entirely. Most turrets don't need this — it's set by ConfigId |
| `WeaponDamageType` | string | `blaster`, `turbolaser`, `ion`, `proton_torpedo`, `concussion_missile`, `artillery_shell` | Changes what damage type the weapon deals. Affects shield/hull multipliers |
| `WeaponBoltColor` | Color3 | Use the Color3 picker in Studio | Changes projectile bolt color. Can also be a string like `"255,0,0"` for red |

### Boolean Overrides

| Attribute | Type | What to type | Notes |
|-----------|------|-------------|-------|
| `WeaponHoldToFire` | boolean | Check or uncheck | When checked, player must hold mouse button to fire continuously instead of clicking each shot |
| `WeaponSplashEnabled` | boolean | Check or uncheck | Force enable/disable splash damage. By default, splash is enabled only if the base weapon config has a splashRadius > 0 |

### Number Overrides (replace base value, not percentage)

| Attribute | Type | What to type | Notes |
|-----------|------|-------------|-------|
| `WeaponSplashRadius` | number | Radius in studs (e.g., `25`) | Overrides the splash damage radius. Only matters if splash is enabled |
| `WeaponScreenShakeModifier` | number | Percentage modifier (e.g., `0.5` = +50% shake, `-0.5` = half shake) | Scales camera shake when this turret fires. Uses the `base * (1 + mod)` formula |
| `WeaponAmmoCapacity` | number | Ammo count (e.g., `16`) | Overrides the ammo capacity entirely. Rounds to nearest integer, minimum 1. Works on any weapon with finite ammo (torpedoes, missiles, artillery) |

### Artillery Overrides (absolute values, on artillery CombatEntity models)

These replace the base artillery config values. Only relevant for models with `ConfigId = "artillery_emplacement"` or `WeaponClass = "artillery"`.

| Attribute | Type | Base | What to type | Notes |
|-----------|------|------|-------------|-------|
| `WeaponArtilleryGravity` | number | 320 | e.g., `200` for floatier shells, `500` for steeper arcs | Controls shell drop. Higher = shorter arc, lower = flatter trajectory. Minimum 1 |
| `WeaponArtilleryMinElevation` | number | 5 | Degrees (e.g., `10`) | Lowest the barrel can aim. Clamped 0-89 |
| `WeaponArtilleryMaxElevation` | number | 85 | Degrees (e.g., `75`) | Highest the barrel can aim. Clamped 1-90 |
| `WeaponArtilleryAdjustSpeed` | number | 30 | Degrees/sec (e.g., `45`) | How fast WASD moves the aim point. Minimum 1 |
| `WeaponArtilleryFineAdjustSpeed` | number | 5 | Degrees/sec (e.g., `3`) | How fast aim moves while holding Shift (precision mode). Minimum 0.1 |
| `WeaponArtilleryMinRange` | number | 100 | Studs (e.g., `50`) | Closest allowed fire distance. Prevents shooting at your own feet. Minimum 0 |

---

## 7. Weapon Percentage Modifiers (on CombatEntity turret models)

Percentage modifiers on the turret **Model**. Same `base * (1 + value)` formula as vehicles.

| Attribute | Type | What it tunes | Example |
|-----------|------|--------------|---------|
| `WeaponDamageModifier` | number | Damage per shot | `0.5` → 50% more damage. `-0.3` → 30% less damage |
| `WeaponDamagePercent` | number | Same as WeaponDamageModifier (alias) | Fallback if WeaponDamageModifier isn't set |
| `WeaponFireRateModifier` | number | Shots per second | `0.5` → fires 50% faster. `-0.3` → fires 30% slower |
| `WeaponProjectileSpeedModifier` | number | Projectile travel speed (studs/sec) | `0.5` → bolts travel 50% faster |
| `WeaponMaxRangeModifier` | number | Max range AND lock range (both scaled together) | `0.5` → 50% more range. `-0.3` → 30% less range |
| `WeaponBurstCountModifier` | number | Shots per burst (burst weapons only) | `0.5` on a 3-burst → rounds to 5 shots per burst |
| `WeaponBurstIntervalModifier` | number | Delay between burst shots | `-0.3` → burst fires 30% faster |
| `WeaponHeatMaxModifier` | number | Max heat capacity before overheat | `0.5` → can fire 50% longer before overheating |
| `WeaponHeatPerShotModifier` | number | Heat generated per shot | `-0.3` → each shot generates 30% less heat |
| `WeaponHeatDecayPerSecondModifier` | number | Heat cooldown speed | `0.5` → cools down 50% faster |
| `WeaponHeatRecoverThresholdModifier` | number | Heat level where overheat clears | `-0.3` → recovers from overheat 30% sooner |

**Base values depend on ConfigId.** Common examples:
- `blaster_turret`: 40 damage, 3 fire rate, 850 speed, 900 range, 100 heat max, 9 heat/shot
- `turbolaser_turret`: 120 damage, 0.5 fire rate, 900 speed, 1800 range
- `torpedo_launcher`: 200 damage, 0.33 fire rate, 300 speed, 1600 range, 6 ammo
- `artillery_emplacement`: 150 damage, 0.2 fire rate, 800 speed, 2000 range, 8 ammo

See `CombatConfig.luau` Weapons table for all base values.

---

## 8. Turret Rig Attributes (on TurretRig folders or WeaponMount parts)

These configure how the turret aims. Put them on the **TurretRig folders** inside the turret model (`YawOnlyParts`, `PitchOnlyParts`, `YawPitchParts`, `DrivenParts`) or on the `WeaponMount` tagged part. The system checks mount first, then falls back to model.

| Attribute | Type | What to type | Notes |
|-----------|------|-------------|-------|
| `AimAxis` | string | `+X`, `-X`, `+Y`, `-Y`, `+Z`, or `-Z` | Which direction the weapon mount "points" in local space. Auto-inferred from MuzzlePoint if not set. Only needed for unusual rig setups |
| `AimMode` | string | `yawonly`, `pitchonly`, or `yawpitch` | Restricts how the rig group moves. `yawonly` = horizontal rotation only. `pitchonly` = vertical only. `yawpitch` = both. Rig folder name also sets this (e.g., a folder named `YawOnlyParts` defaults to yawonly) |
| `MinYawDeg` | number | Degrees (e.g., `-90`) | Minimum yaw angle. Limits how far left the turret can turn |
| `MaxYawDeg` | number | Degrees (e.g., `90`) | Maximum yaw angle. Limits how far right the turret can turn |
| `MinPitchDeg` | number | Degrees (e.g., `-10`) | Minimum pitch angle. Limits how far down the turret can aim |
| `MaxPitchDeg` | number | Degrees (e.g., `45`) | Maximum pitch angle. Limits how far up the turret can aim |
| `AimPivotName` | string | Name of a part (e.g., `"TurretBase"`) | Overrides which part the rig rotates around. By default uses the rig folder's parent or mount |

---

## 9. Moving Target Controller (for testing)

### Workspace-level toggle

| Attribute | Goes on | Type | What to type | Notes |
|-----------|---------|------|-------------|-------|
| `MovingTargetControllerEnabled` | Workspace | boolean | Check to enable | Master switch. Must be true for any moving targets to work |

### Per-target attributes (on CombatEntity models)

| Attribute | Type | Default | What to type | Notes |
|-----------|------|---------|-------------|-------|
| `MovingTargetEnabled` | boolean | false | Check to enable | Enables this specific target for movement |
| `MovingTargetMode` | string | `"side"` | `side`, `circle`, or `random` | `side` = back and forth along an axis. `circle` = continuous loop. `random` = teleports to random points at intervals |
| `MovingTargetSpeed` | number | `25` | Studs per second | How fast the target moves |
| `MovingTargetAmplitude` | number | `16` | Studs | How far it moves from center (used by `side` mode) |
| `MovingTargetAxis` | string | `"X"` | `X`, `Y`, `Z`, `-X`, `-Y`, `-Z`, or a vector like `"1,0,0"` | Which direction the `side` mode oscillates along |
| `MovingTargetRadius` | number | `18` | Studs | Radius of movement area (used by `circle` and `random` modes) |
| `MovingTargetHeight` | number | `10` | Studs | Vertical range of movement (used by `circle` and `random` modes) |
| `MovingTargetInterval` | number | `2.2` | Seconds | How often `random` mode picks a new position |
| `MovingTargetReset` | boolean | false | Check, then uncheck | When set to true, re-centers the target at its current position. Auto-clears after applying |

---

## 10. Available ConfigId Values

### Turrets

| ConfigId | HP | Shields | Weapon | Respawn | Notes |
|----------|----|---------|---------|---------|----|
| `blaster_turret` | 100 | — | blaster_turret | 15s | Basic rapid-fire turret |
| `blaster_turret_burst` | 100 | — | blaster_turret_burst | 15s | 3-round burst fire |
| `shielded_turret` | 100 | 140 (8/s, 5s delay) | blaster_turret | 15s | Blaster with shields |
| `turbolaser_turret` | 150 | 100 (10/s, 4s delay) | turbolaser_turret | 20s | Heavy, slow, shielded, enclosed |
| `ion_turret` | 80 | — | ion_turret | 15s | Anti-shield specialist |
| `torpedo_turret` | 120 | — | torpedo_launcher | 25s | Requires lock, 6 ammo |
| `missile_turret` | 100 | — | missile_battery | 20s | Homing, 12 ammo |
| `artillery_emplacement` | 200 | — | artillery_emplacement | 30s | Indirect fire, parabolic, 8 ammo |

### Vehicles

| ConfigId | HP | Shields | Weapon | Respawn | Notes |
|----------|----|---------|---------|---------|----|
| `light_vehicle` | 150 | — | — | 20s | Fast speeder baseline |
| `heavy_vehicle` | 500 | 200 (15/s, 5s delay) | — | 30s | Armored tank baseline |

### Test Targets

| ConfigId | HP | Shields | Respawn | Notes |
|----------|----|---------|---------|----|
| `target_dummy` | 200 | — | 10s | Basic shooting target |
| `shielded_target` | 200 | 150 (25/s, 3s delay) | 10s | Shield regen test |
| `shield_test_target` | 100 | 60 (no regen) | 10s | Shield without regen |
| `shield_regen_target` | 200 | 100 (50/s, 2s delay) | 10s | Fast regen test |
| `ion_test_target` | 200 | 200 (no regen) | 10s | Ion weapon test |
| `torpedo_test_target` | 500 | 150 (no regen) | 10s | Torpedo/bypass test |
| `ammo_test_target` | 10000 | — | 999s | Ammo depletion test |

---

## 11. Tags Reference

Tags applied via CollectionService in Studio's Tag Editor.

### On Models

| Tag | Where | Required | Notes |
|-----|-------|----------|-------|
| `CombatEntity` | Any combat model | Yes | Registers the model as a combat entity with HP/shields/weapons |
| `VehicleEntity` | Vehicle models | Yes (for vehicles) | Must also have `CombatEntity`. Enables vehicle physics |

### On Parts inside models

| Tag | Where | Required | Notes |
|-----|-------|----------|-------|
| `TurretSeat` | Seat inside turret | Yes (for turrets) | The seat players sit in to operate the turret |
| `ArtillerySeat` | Seat inside artillery | Auto-set | System converts TurretSeat to ArtillerySeat for artillery ConfigIds |
| `WeaponMount` | BasePart inside turret | Yes (for turrets) | The part that aims. Must have MuzzlePoint attachment(s) |
| `DriverSeat` | Seat inside vehicle | Yes (for vehicles) | The seat players sit in to drive |
| `HoverPoint` | 4 BaseParts inside vehicle | Yes (for vehicles) | Where the 4 hover spring raycasts originate. Place at corners of the vehicle |
| `MuzzlePoint` | Attachment on WeaponMount | Recommended | Where projectiles spawn from. Auto-detected by name if tag missing |

### Special parts (by name, not tag)

| Name | Type | Where | Notes |
|------|------|-------|-------|
| `CameraPoint` | BasePart or Attachment | Inside turret model | Where the camera focuses when operating the turret |

---

## 12. Runtime Attributes (read-only — set by the system, don't set manually)

These are written by server/client code during gameplay. Useful for debugging or reading in scripts, but don't set them on models.

| Attribute | Type | Set on | What it means |
|-----------|------|--------|--------------|
| `EntityId` | string | CombatEntity model | Unique ID assigned at startup (e.g., `"entity_7"`) |
| `TurretExposed` | boolean | CombatEntity model | Whether the turret operator can be hit by projectiles |
| `HullHP` | number | CombatEntity model | Current hull HP |
| `MaxHullHP` | number | CombatEntity model | Maximum hull HP |
| `ShieldHP` | number | CombatEntity model | Current shield HP |
| `MaxShieldHP` | number | CombatEntity model | Maximum shield HP |
| `VehicleSpeed` | number | VehicleEntity model | Current horizontal speed (studs/sec) |
| `VehicleHeading` | number | VehicleEntity model | Current heading angle (radians) |
| `VehicleBoosting` | boolean | VehicleEntity model | Whether boost is currently active |
| `VehicleMisfire` | boolean | VehicleEntity model | Engine misfire state (at low HP) |
| `VehicleLandingImpact` | number | VehicleEntity model | Impact speed of last landing |
| `WeaponAmmo` | number | Turret model | Current ammo count |
| `WeaponAmmoMax` | number | Turret model | Maximum ammo capacity |
| `WeaponHeat` | number | Turret model | Current heat level |
| `WeaponOverheated` | boolean | Turret model | Whether weapon is currently overheated |
| `EffectiveWeaponDamage` | number | Turret model | Resolved damage after modifiers |
| `EffectiveWeaponFireRate` | number | Turret model | Resolved fire rate after modifiers |
| `EffectiveWeaponMaxRange` | number | Turret model | Resolved max range after modifiers |
| `EffectiveWeaponLockRange` | number | Turret model | Resolved lock range after modifiers |
| `EffectiveWeaponProjectileSpeed` | number | Turret model | Resolved projectile speed after modifiers |
| `EffectiveWeaponBoltColor` | Color3 | Turret model | Resolved bolt color |
