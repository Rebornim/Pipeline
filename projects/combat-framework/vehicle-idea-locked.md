# Ground Vehicle System — Idea (LOCKED)

**Part of:** Combat Framework
**Locked:** 2026-02-19

---

## Overview

Custom-built ground vehicle system, NOT bolted onto any existing system. Shares architecture with ships: anchored models, CFrame-based movement, same tagging/authoring/config patterns, same combat framework integration. Must support any ground vehicle from the Galactic Civil War era.

Weapons on vehicles are the same turret system from passes 1-4 — weapon mounts + seats + config, mounted on a vehicle model. The weapon code doesn't know or care what platform it's on.

---

## Vehicle Classes

| Class | Steering | Head/Aim | Terrain | Examples |
|-------|----------|----------|---------|----------|
| Light | Mouse steer, fast | Fixed forward | Hover springs, airborne capable, crosses water | 74-Z speeder bike, BARC, Gian speeder, Flash speeder |
| Heavy | Mouse steer, slower | Fixed forward | Hover springs, airborne capable, cannot cross water | TX-130 Saber, AAC-1, TX-225 Occupier, ITT |
| Walker (biped) | WASD | Mouse aims head (limited arc, config) | IK legs, can stop, pivot in place | AT-ST, AT-DP |
| Walker (quad) | WASD | Mouse aims head (limited arc, config) | IK legs, can stop, slow pivot | AT-AT, AT-ACT |

**Light** = fast, nimble, exposed or light armor, 1-3 crew. Speeder bikes to light combat speeders.
**Heavy** = slow, armored, enclosed, big guns, 2-6 crew. Medium tanks to heavy assault vehicles and troop carriers.

All repulsorlifts (light + heavy) share the same hover physics code. The difference between vehicles is purely config-driven — speed, HP, weapons, turn rate, etc. are all numbers in the base config or overridden via model attributes.

No tracked/wheeled category — no civil war era vehicles need it.

T-47 Snowspeeder is a fighter (ship class), NOT a ground vehicle — it fundamentally flies.

---

## Movement Architecture

All vehicles: anchored models, CFrame-based movement. No Roblox physics engine. Same core as ships.

### Speeders — Simulated Hover Physics
- 4 raycasts per frame (front, back, left, right) act as virtual springs
- Springs push speeder to target hover height above terrain
- Surface normal from raycasts determines tilt (speeder banks on slopes, tilts uphill/downhill)
- Speeder has velocity + momentum + gravity — feels physical
- Off a cliff edge: springs find no ground, gravity takes over, speeder goes airborne with momentum preserved
- Landing: springs compress on impact, **fall damage applied to vehicle HP based on impact speed** (config-driven threshold)
- Hover height: config per vehicle, with percentage modifier attributes
- Max climbable slope: config per vehicle
- **No altitude control.** Speeder is locked to hover height above terrain — no E/Q, no climbing higher manually.
- All speeders can reverse.
- Light speeders cross water. Heavy speeders slow dramatically in water, must reverse out.

### Speeder Collision Handling (CRITICAL)
Most speeder games break on collision because the internal speed stays constant while collision geometry blocks movement, causing glitching/flinging. Since we own the physics (CFrame-based, no Roblox engine), we solve this:
- **Forward raycasts detect obstacles before contact**
- **Collision directly modifies the velocity vector** — hit a wall, velocity drops to zero or reflects (bounce). No fighting between "engine force" and "wall force" because there is no engine force — just a velocity number we control.
- **Impact damage** based on collision speed — high-speed wall hit = significant HP damage
- **Speeder-to-speeder collision:** both take damage, both bounce off. Velocity vectors modified for both.
- Speeders can pass under tall vehicles (AT-AT legs) if there's clearance.

### Walkers — IK Procedural Walk
- Body moves via CFrame at set height above terrain
- Legs use IK to plant feet on terrain surface via raycasts
- Procedural walk cycle: feet lift in sequence, step to target, plant — terrain-adaptive
- **Mouse aim = body turning** (with turn speed limit). Head rotates independently on top of body facing (limited arc, config-driven).
- **WASD movement relative to body facing:** W = forward, S = reverse (slower), A/D = strafe. All directions supported.
- Can stop and stand still (legs planted, idle pose)
- Bipeds pivot in place freely. Quads pivot in place but slowly (config-driven turn speed).
- Max slope: config per vehicle
- **Walker off cliff edge:** falls, takes fall damage to HP based on drop height. IK legs attempt to reacquire ground.
- **Procedural secondary motion on body:** weight shift to planted leg, bob on each step, lean into movement direction, jolt on foot impact, slight tilt on uneven terrain. Goal: looks hand-animated, not robotic.

### Dismount Behavior
- Player dismounts a moving speeder: speeder continues forward with current velocity, decelerates naturally, stops on its own. Player exits instantly.
- Player dies on a speeder (shot off): same behavior — speeder continues, decelerates, stops.
- Player dies in a walker: walker stops in place (no momentum to carry it).

---

## Combat Integration

- Vehicles use the same combat framework as turrets and ships (projectiles, damage types, overheat, ammo, targeting, lock-on)
- **Weapons = turret mounts.** Same system from passes 1-4 — weapon mount tags + seat tags + config. Mounted on vehicle model. Weapon code is platform-agnostic.
- Vehicle health: Hull HP + optional shields (config per vehicle, lore-accurate — most ground vehicles don't have shields)
- **NO subsystems on vehicles** — just HP + optional shields (Empire at War ground style)
- Pilot-fired weapons and/or separate gunner seats depending on vehicle config
- **Enclosed vehicles** (tanks, AT-ST, AT-AT): crew protected from external fire (hull must reach 0 to kill crew)
- **Exposed vehicles** (speeder bike): rider can be shot directly — no extra code, naturally happens since rider is physically sitting on top
- Vehicle destruction: explosion points → final explosion → vehicle removed → all occupants die
- **Splash damage affects vehicles** — explosions near a vehicle damage it as a combat entity
- **Vehicle theft allowed** — empty enemy vehicle on the battlefield, anyone can hop on and take it

---

## Spawning, Ownership, Despawn

- Vehicles are **player-spawned** (shop system), NOT dev-placed. Turrets are dev-placed.
- **Shared limit: 2 active across ships AND vehicles combined.** If you have 2 ships out, you can't spawn a vehicle until you despawn one.
- **Despawn-on-spawn:** When spawning and at the limit, player is prompted to choose which existing ship/vehicle to despawn.
- Destroyed vehicles are **gone** — no respawn timer, no memory. Spawn a fresh one.
- **No field repair.** Despawn the damaged vehicle, spawn a new one.
- No boost/sprint mechanic.

---

## Entering/Exiting

- **Seats for boarding** (not proximity prompts) — feels more natural for vehicles
- **F key** to exit seat (same as ships/turrets). Exiting is instant.
- Entry method is **per-vehicle, based on model design:**
  - Speeder bike: hop on (seat click)
  - Small tanks/speeders: cockpit seat from outside
  - AT-ST: whatever makes sense for the model (hatch, side door)
  - AT-AT: ramp/hatch into belly, ladder, or model-specific entry
- Entries can be open (always accessible) or animated (doors/ramps open, same system as ships)
- **No one-size-fits-all.** Each vehicle model defines its own entry via tagging.

---

## Interiors

Follows the project-wide two-layer interior convention (idea-locked.md):
- Visual: full MeshPart interiors, CanCollide off
- Collision: invisible simple Parts for walkable surfaces

| Vehicle Type | Interior |
|-------------|----------|
| Speeder bike | None — player sits on it |
| Small speeder/tank | Sealed cockpit — seats only, no walkable space |
| AT-ST | Sealed cockpit — 2 seats (pilot + gunner), no walkable space |
| AT-AT | Full walkable interior — command deck, transport bay (~20 troops) |

---

## Troop Deployment (Vehicles with Transport Bays)

- Vehicle must be at a **full stop** to open transport bay
- Animated doors/ramps open (same animation system as ships)
- Players interact to **rappel/descend** — smooth position tween to ground, no physics rope
- **Rappel is 2-way** — players can go back up the same way
- No arbitrary limit on simultaneous deployment — everyone can go
- AT-AT troops are **passengers only** while inside — seated or standing, no weapons, no actions until deployed

---

## Vehicle Transport in Ships

### Small Vehicles (speeder bikes, small tanks)
- Spawned on planet surface directly
- Transport ship approaches, pilot uses keybind → vehicle **snaps to predetermined carry position** on the ship (config-driven attachment point + orientation)
- Same keybind to deploy/release back to ground
- Ship must be at a **dead stop** for pickup and deployment

### Large Vehicles (AT-AT scale)
- Too large to spawn on planet and pick up
- Spawned at a **space station** where the player's vehicle transport ship is docked
- Vehicle is **visually attached** to the transport ship — physically present as a model
- Vehicle interior **not spawned until deployment** (optimization)
- **Players are NOT inside the carried vehicle during transport** — they ride in the transport ship's passenger seats
- Transport ship flies to planet, comes to dead stop, deploys vehicle
- Deployment: vehicle detaches, drops/lowers to ground, becomes active and driveable

### Vehicle-in-Vehicle (AT-AT carrying speeder bikes)
- Carried vehicle's model becomes **part of the carrier vehicle** (parented to it, not an active vehicle)
- Player sits in the carried vehicle → it detaches, becomes an active vehicle, player drives away
- Same snap-to-position concept as ship transport — predetermined carry slots

---

## Authoring

Same system as ships: **CollectionService tags + config files + startup validator.** Designed so any dev can set up any vehicle without specialized knowledge.

### Standard Tags (same as ships)
- Weapon mount tags (position, type reference)
- Seat tags (driver, gunner, passenger)
- Explosion point tags (min 3)
- Entry point tags (where players board)
- Animated part tags (doors, ramps, landing gear — start/end CFrame)

### Vehicle-Specific Tags
- **Hover point tags** (speeders): where the 4 spring raycasts originate
- **IK leg tags** (walkers): attachment points, joint positions, foot targets
- **Head pivot tag** (walkers): which part rotates for mouse aim
- **Carry slot tags** (transport vehicles): where carried vehicles snap to
- **Transport bay tag** (AT-AT etc.): deployment zone

### Config — Attribute Modifier System

Same pattern as turrets: **two base configs** (`light` and `heavy`) in CombatConfig define sane defaults for each category. Individual vehicles are tuned via **percentage modifier attributes** on the model — no per-vehicle config entries in Lua. Formula: `base * (1 + modifier)` where modifier is a decimal (0.2 = +20%, -0.3 = -30%).

**Identity attributes (required on every vehicle model):**

| Attribute | Type | Example | What to type | Notes |
|-----------|------|---------|-------------|-------|
| `VehicleCategory` | string | `"heavy"` | `light` or `heavy` | Picks which base config to use for all physics/movement values |
| `ConfigId` | string | `"heavy_vehicle"` | `light_vehicle` or `heavy_vehicle` | Entity config for HP/shields/respawn. Light = 150 HP, no shields. Heavy = 500 HP + 200 shields |
| `Faction` | string | `"empire"` | `empire`, `rebel`, or `neutral` | Same as turrets — determines who can drive it and friendly fire rules |
| `ForwardAxis` | string | `"-Z"` | `X`, `-X`, `Z`, or `-Z` | Which of the model's local axes points forward. Use this when the model is axis-aligned. Skip if using ForwardYawOffset |
| `ForwardYawOffset` | number | `135` | Any number (degrees) | Degrees of rotation from the model's local -Z axis. Use this instead of ForwardAxis when the model's forward direction doesn't line up with any axis. `0` = -Z, `90` = +X, `180` = +Z, `-90` = -X. Trial-and-error: set a value, playtest, adjust until the vehicle drives in the correct visual direction. Overrides ForwardAxis if both are set |

**Percentage modifiers (all optional, applied to base config):**

All percentage modifiers are `number` type. The formula is `base * (1 + value)`. Examples:
- `0` = no change (same as not setting it)
- `0.5` = +50% (base 120 becomes 180)
- `-0.3` = -30% (base 120 becomes 84)
- `1.0` = +100% / double (base 120 becomes 240)
- `-0.5` = -50% / half (base 120 becomes 60)

*Movement:*
| Attribute | Type | Config key | Base (light / heavy) | What it tunes | Example |
|-----------|------|-----------|---------------------|--------------|---------|
| `VehicleMaxSpeedMod` | number | maxSpeed | 120 / 55 | Top speed in studs/sec | `0.25` → light goes 150, `-0.2` → heavy goes 44 |
| `VehicleAccelerationMod` | number | acceleration | 80 / 40 | How fast it reaches top speed | `0.5` → 50% quicker acceleration |
| `VehicleDecelerationMod` | number | deceleration | 30 / 20 | Coast-down when releasing throttle | `-0.3` → slides further before stopping |
| `VehicleBrakingMod` | number | brakingDeceleration | 60 / 45 | Active braking force (holding S while moving forward) | `0.5` → stops 50% faster |
| `VehicleReverseSpeedMod` | number | reverseMaxSpeed | 30 / 15 | Top speed in reverse | `1.0` → doubles reverse speed |
| `VehicleTurnSpeedLowMod` | number | turnSpeedLow | 120 / 70 | Turn rate at low speed (deg/sec) | `-0.3` → slower turns at low speed |
| `VehicleTurnSpeedHighMod` | number | turnSpeedHigh | 45 / 25 | Turn rate at high speed (deg/sec) | `0.4` → more responsive at speed |
| `VehicleLateralGripLowMod` | number | lateralGripLow | 10 / 20 | Slide resistance at low speed — higher = less drift | `0.5` → grippier at low speed |
| `VehicleLateralGripHighMod` | number | lateralGripHigh | 4.5 / 12 | Slide resistance at high speed — higher = less drift | `-0.3` → more drift at speed |

*Hover physics:*
| Attribute | Type | Config key | Base (light / heavy) | What it tunes | Example |
|-----------|------|-----------|---------------------|--------------|---------|
| `VehicleHoverHeightMod` | number | hoverHeight | 1 / 1.5 | Float height above ground in studs | `1.0` → doubles hover height, `-0.3` → hovers 30% lower |
| `VehicleSpringStiffnessMod` | number | springStiffness | 250 / 300 | How hard springs push to reach target height — higher = snappier | `0.5` → bouncier suspension |
| `VehicleSpringDampingMod` | number | springDamping | 25 / 30 | Reduces spring oscillation — higher = less bouncy | `0.3` → slightly more damped |
| `VehicleTiltStiffnessMod` | number | tiltStiffness | 100 / 80 | How fast it tilts to match terrain angle | `0.5` → conforms to slopes faster |
| `VehicleTiltDampingMod` | number | tiltDamping | 14 / 16 | Reduces tilt wobble — higher = steadier | `-0.3` → more wobbly on rough terrain |
| `VehicleTerrainConformityMod` | number | terrainConformity | 0.15 / 0.1 | How much it follows terrain slope (0-1 range in base) | `0.5` → tilts more on hills |
| `VehicleMaxClimbSlopeMod` | number | maxClimbSlope | 65 / 50 | Steepest climbable hill in degrees | `0.3` → can climb steeper hills |

*Collision:*
| Attribute | Type | Config key | Base (light / heavy) | What it tunes | Example |
|-----------|------|-----------|---------------------|--------------|---------|
| `VehicleCollisionRadiusMod` | number | collisionRadius | 4 / 6 | Hit detection radius in studs — bigger vehicle = bigger radius | `0.5` → wider collision zone |
| `VehicleCollisionBounceMod` | number | collisionBounce | 0.2 / 0.1 | Wall bounce elasticity (0 = no bounce, 1 = full bounce) | `1.0` → doubles bounce |
| `VehicleCollisionDmgThresholdMod` | number | collisionDamageThreshold | 60 / 80 | Min impact speed (studs/sec) before wall damage applies | `0.5` → needs 50% more speed to take damage |
| `VehicleCollisionDmgScaleMod` | number | collisionDamageScale | 1.2 / 0.8 | HP lost per unit of impact speed above threshold | `-0.5` → takes half the wall damage |

*Fall damage:*
| Attribute | Type | Config key | Base (light / heavy) | What it tunes | Example |
|-----------|------|-----------|---------------------|--------------|---------|
| `VehicleFallDmgThresholdMod` | number | fallDamageThreshold | 160 / 120 | Min fall speed (studs/sec) before landing damage | `0.5` → needs 50% harder landing to take damage |
| `VehicleFallDmgScaleMod` | number | fallDamageScale | 0.5 / 0.4 | HP lost per unit of fall speed above threshold | `-0.5` → takes half the fall damage |

*Camera:*
| Attribute | Type | Config key | Base (light / heavy) | What it tunes | Example |
|-----------|------|-----------|---------------------|--------------|---------|
| `VehicleCameraDistanceMod` | number | cameraDistance | 15 / 22 | How far behind the camera sits in studs | `0.5` → camera 50% further back, `-0.3` → tighter on vehicle |
| `VehicleCameraHeightMod` | number | cameraHeight | 6 / 8 | How high above the vehicle the camera sits | `0.5` → higher camera angle |
| `VehicleCameraLerpMod` | number | cameraLerpSpeed | 0.15 / 0.12 | Camera follow smoothness (0-1, lower = smoother/laggier) | `0.5` → camera follows 50% faster |

*Boost:*
| Attribute | Type | Config key | Base (light / heavy) | What it tunes | Example |
|-----------|------|-----------|---------------------|--------------|---------|
| `VehicleBoostSpeedMod` | number | boostSpeedMultiplier | 1.5 / 1.0 | Multiplier on top speed during boost | `0.3` → boost goes 30% faster than default |
| `VehicleBoostDurationMod` | number | boostDuration | 5 / 0 | How many seconds boost lasts | `-0.4` → boost runs out 40% sooner |
| `VehicleBoostCooldownMod` | number | boostCooldown | 6 / 0 | Seconds before boost can be used again | `0.5` → 50% longer cooldown |

*Lean (light category only — heavy base has these zeroed so modifiers have no effect):*
| Attribute | Type | Config key | Base (light / heavy) | What it tunes | Example |
|-----------|------|-----------|---------------------|--------------|---------|
| `VehicleLeanBankAngleMod` | number | leanBankAngle | 15 / 0 | Max visual lean angle in degrees | `0.5` → leans 22.5 degrees instead of 15 |
| `VehicleLeanTurnRateMod` | number | leanTurnRate | 50 / 0 | Extra turn rate (deg/sec) while leaning | `-0.3` → less turn bonus from leaning |
| `VehicleLeanSpeedPenaltyMod` | number | leanSpeedPenalty | 0.01 / 0 | Fraction of speed lost while leaning | `1.0` → doubles the speed penalty |

*Entity combat stats (percentage modifiers — applies to all combat entities including turrets, not just vehicles):*
| Attribute | Type | Config key | Base (light / heavy) | What it tunes | Example |
|-----------|------|-----------|---------------------|--------------|---------|
| `EntityHullHPMod` | number | hullHP | 150 / 500 | Hull hit points | `0.5` → heavy gets 750 HP, `-0.3` → light gets 105 HP |
| `EntityShieldHPMod` | number | shieldHP | — / 200 | Shield hit points. No effect if base has no shields (light_vehicle) | `0.5` → heavy gets 300 shield HP |
| `EntityShieldRegenRateMod` | number | shieldRegenRate | — / 15 | Shield HP regenerated per second | `-0.5` → heavy regens at 7.5/sec |
| `EntityShieldRegenDelayMod` | number | shieldRegenDelay | — / 5 | Seconds after taking shield damage before regen starts | `0.4` → heavy waits 7 seconds |
| `EntityRespawnTimeMod` | number | respawnTime | 20 / 30 | Seconds to respawn after destruction | `-0.5` → respawns in half the time |

**Absolute boolean overrides (optional, replaces base value entirely — not percentage):**

| Attribute | Type | Default (light / heavy) | What to type | Notes |
|-----------|------|------------------------|-------------|-------|
| `VehicleCanCrossWater` | boolean | true / false | Check or uncheck the checkbox | Light speeders can cross water by default. Heavy can't. Set this to override either way |
| `VehicleBoostEnabled` | boolean | true / false | Check or uncheck the checkbox | Light has boost by default. Heavy doesn't. Set this to override |
| `VehicleLeanEnabled` | boolean | true / false | Check or uncheck the checkbox | Light can lean by default. Heavy can't. Set this to override |

**Not exposed as attributes (stay in base config):**
- Lean sub-parameters (entry/exit durations, yaw boost, counter-steer, camera offset, shake, dust) — 11 values. These define how the lean system feels; tuned per category, not per vehicle.
- `accelerationTaper` / `accelerationMinFactor` — niche tuning
- `landingShakeThreshold` / `landingShakeIntensity` — feel polish
- `gravity` — universal, all vehicles fall at the same speed

**Entity base configs:**
- `ConfigId = "light_vehicle"` — 150 HP, no shields, no weapon, 20s respawn
- `ConfigId = "heavy_vehicle"` — 500 HP, 200 shield HP (15/s regen, 5s delay), no weapon, 30s respawn

**Weapon config:** same as turrets/ships — separate weapon modifier attributes on the turret mount, not the vehicle model. Vehicle weapons use the existing turret framework.

---

## Camera

- **3rd person for all vehicles**
- Tight follow for small vehicles (speeder bikes)
- Pulled back for larger vehicles (AT-AT, heavy tanks) — show whole vehicle
- Same camera controller as ships — mode determined by vehicle class config

---

## Audio & VFX

- Engine sounds per vehicle type (config-driven)
- Impact VFX: same shield/hull system as everything (blue ripple vs explosion)
- Collision VFX/audio on wall hits
- Fall damage: landing thud + damage number
- Full audio (Star Wars movie logic — same as space combat)

---

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| Speeder hits wall at full speed | Velocity drops to zero/bounces, impact damage based on speed |
| Speeder-to-speeder collision | Both take damage, both bounce, velocity vectors modified |
| Speeder over small gap/chasm | Momentum carries it, gravity if gap is wide enough |
| Speeder over water (light) | Crosses normally |
| Speeder over water (heavy) | Massive slowdown, must reverse out |
| Walker off cliff | Falls, takes fall damage, IK reacquires ground |
| Walker on steep slope | Max slope config — can't climb past limit |
| Walker strafing | A/D moves sideways relative to body facing, slower than forward speed |
| Walker reversing | S moves backward relative to body facing, slower than forward speed |
| Driver dies (speeder) | Speeder continues, decelerates, stops |
| Driver dies (walker) | Walker stops in place |
| Empty vehicle on battlefield | Anyone can take it (theft allowed) |
| Vehicle at shared 2-limit | Spawn prompt asks which existing to despawn |
| Splash damage near vehicle | Vehicle takes damage as combat entity |
| Passenger shooting from vehicle | Not designed for — edge case, whatever naturally happens |
| Friendly fire on vehicles | Same faction check as all combat — no friendly damage |

---

## Success Conditions

- **Speeder bike:** Player hops on, mouse steers, zooms across terrain. Hits a ramp/hill, goes airborne, lands with impact. Hits a wall — stops dead, takes damage, no glitching. Drives off cliff — falls with momentum, lands hard. Rider can be shot off by enemies. Dismount at speed — bike keeps going, slows, stops.
- **Heavy speeder/tank:** Same hover physics, slower. Cannot cross deep water. Enclosed — crew protected from direct fire.
- **AT-ST:** WASD movement (forward, reverse, strafe), mouse turns body + aims head (limited arc). IK legs step on terrain with procedural weight/lean/bob. Pivots in place. Fires chin guns. Crew protected. Can be destroyed.
- **AT-AT:** WASD, slow, wide turns. IK legs on 4 points. Mouse aims head (limited arc). Walkable interior with ~20 troop capacity. Full stop to deploy troops via rappel. Transported to planet via carrier ship.
- **Vehicle transport:** Small vehicles snap to transport ship, deployed via keybind at dead stop. Large vehicles spawned at station, carried visibly, deployed to surface.
- **Combat:** All vehicle weapons use turret framework. Damage, shields, targeting, lock-on — all identical to turrets and ships.

---

## What This System Does NOT Include

- No boost/sprint mechanic
- No tracked/wheeled vehicles (no civil war era need)
- No terrain-type interaction (sand vs road vs snow — same speed everywhere)
- No vehicle-specific kill credits (same milsim philosophy as ships)
- No NPC drivers or gunners
- No tow cable mechanic
- No field repair
- No vehicle respawn timers (destroyed = gone)
