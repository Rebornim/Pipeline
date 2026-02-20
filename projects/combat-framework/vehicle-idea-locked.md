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
| Speeder (light) | Mouse steer, fast | Fixed forward | Hover springs, airborne capable, crosses water | Speeder bike, BARC speeder |
| Speeder (heavy) | Mouse steer, slower | Fixed forward | Hover springs, airborne capable, cannot cross water | TX-225 tank, AAC-1 |
| Walker (biped) | WASD | Mouse aims head (limited arc, config) | IK legs, can stop, pivot in place | AT-ST, AT-DP |
| Walker (quad) | WASD | Mouse aims head (limited arc, config) | IK legs, can stop, slow pivot | AT-AT, AT-ACT |

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
- Procedural walk cycle: feet lift in sequence, step forward, plant — terrain-adaptive
- Head rotates independently from body, controlled by mouse aim (limited arc, config-driven)
- Can stop and stand still (legs planted, idle pose)
- Bipeds pivot in place freely. Quads pivot in place but slowly (config-driven turn speed).
- **Walkers cannot reverse** — must turn 180 and walk.
- Max slope: config per vehicle
- **Walker off cliff edge:** falls, takes fall damage to HP based on drop height. IK legs attempt to reacquire ground.

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

### Config
- Vehicle stats: speed, hull HP, shield HP (optional), hover height, max slope, turn speed
- Weapon definitions: same as ships/turrets
- Seat-to-weapon mapping: same as ships
- Walker config: leg count, step distance, step height, head arc limits, turn speed
- Speeder config: spring stiffness, damping, max airborne time(?), water behavior
- Per-vehicle upgrade caps (same system as ships)

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
- **AT-ST:** WASD movement, mouse aims head (limited arc). IK legs step on terrain. Pivots in place. Fires chin guns. Crew protected. Can be destroyed.
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
