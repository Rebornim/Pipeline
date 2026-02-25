# Feature Passes: Combat Framework

**Based on:** idea-locked.md + vehicle-idea-locked.md
**Date:** 2026-02-25 (revised — vehicle client-authority conversion added as pass 11, passes 11+ renumbered)

---

## Pass 1: Core Combat Loop
**What it includes:**
- Ground turret: dev-placed, proximity prompt to enter ("Man Turret"), F to exit
- One weapon type: blaster. Straight-line math-based projectile.
- Server: calculates projectile path (start position, direction, velocity, time), determines hits. No physics objects.
- Client: renders visual-only bolt along calculated path.
- Hull HP only on turret and test target
- Projectile hits target → hull HP decreases → 0 HP = destroyed
- Turret destructible, respawns after config timer
- Manual aim (mouse from turret viewpoint)
- Crosshair HUD
- Server-authoritative hit detection
- Friendly fire prevention (faction check)
- Basic tagging for turret model (weapon mount, seat)
- Basic config: turret HP, fire rate, damage, projectile speed, max range
- Projectiles despawn at max range

**After this pass, the system:**
A player sits in a blaster turret, manually aims and fires. Visible bolts travel from turret to target. Server calculates hits, target hull HP decreases, target destroyed at 0 HP. Turret is destructible and respawns. Same-faction can't be damaged. Just the raw projectile-to-damage pipeline — no shields, no types, no lock-on.

---

## Pass 2: Shield System
**Depends on:** Pass 1
**What it includes:**
- Shield HP layer: absorbs all incoming damage before hull
- Shield regeneration after a no-damage grace period (config-driven delay + rate)
- Config-driven per entity: turrets/targets can be hull-only or have shields
- Shield impact VFX: blue ripple/bounce effect with energy waves at impact point
- Hull impact VFX: fiery explosion effect (no blue energy)
- Distinct shield vs hull impact audio
- HUD additions: shield HP display on own turret
- Config expansion: shield HP, regen rate, regen delay
- Test: blaster turret fires at shielded target → shield HP drops (blue ripple) → shield depletes → hull HP drops (explosion VFX) → target destroyed

**After this pass, the system:**
Two-layer health works. Shields absorb damage first, then hull. Shields regenerate after a grace period. Player can visually and audibly distinguish shield hits (blue ripple) from hull hits (explosion). The core defensive layer of the framework is proven.

---

## Pass 3: Damage Types + Overheat + Ammo
**Depends on:** Pass 2
**What it includes:**
- 5 damage types with mechanically different effects:
  - Laser/Blaster: normal shield + hull (already exists from pass 1)
  - Turbolaser: high shield + high hull, slow fire rate
  - Ion cannon: devastating shield, minimal hull, stun effect on subsystems (stun prepared but not testable until subsystems exist — verify damage multipliers for now)
  - Proton torpedo: partial shield bypass, very high hull damage, slow projectile (fires straight for now — lock requirement added in targeting pass)
  - Concussion missile: moderate damage, homing (straight-line for now — homing added in targeting pass)
- Damage type multiplier system: each weapon type has shield_multiplier and hull_multiplier config values
- Overheat mechanic for energy weapons: fire rate fills heat bar → overheats → forced cooldown period → can fire again
- Finite ammo for physical projectiles (torpedoes, missiles): ammo count → depletes → weapon dead
- Different turret types now possible: blaster turret, turbolaser emplacement, ion turret, torpedo launcher, missile battery
- Weapon range config per weapon type (already had max range, now per-type)
- HUD additions: overheat bar, ammo count
- Config expansion: damage type multipliers, overheat rate, cooldown time, ammo capacity

**After this pass, the system:**
Multiple weapon types exist with mechanically different behavior. Ion cannons devastate shields but barely touch hull. Torpedoes bypass shields. Energy weapons overheat. Physical projectiles run out of ammo. Different turret types can be set up via config. The full damage pipeline is proven.

---

## Pass 4: Targeting System
**Depends on:** Pass 3
**What it includes:**
- Lock-on flow: aim at target → "TARGET LOCK READY" UI appears → press keybind → lock engaged → auto-aim takes over
- Auto-aim: weapon tracks and leads locked target. Generous but NOT 100% — misses at range, against fast targets. Accuracy config-driven.
- Lock-on is optional — manual aim always available
- Lock-on enemy-only (no friendly lock)
- Leading indicator bubble on HUD (where to aim manually)
- Torpedo now requires lock-on to fire
- Concussion missile homing: after launch, tracks locked target
- Lock-on range: shorter than max weapon range (must be closer to lock)
- Turret rotation arc config (360, limited arc, wall-mounted — turret can only lock targets within its arc)
- Turret elevation config (ground-only vs anti-air capable)
- Turret player exposure config (enclosed vs exposed — exposed = player can be hit)
- HUD additions: "TARGET LOCK READY" prompt, lock-on indicator, leading indicator bubble

**After this pass, the system:**
The complete combat framework is proven on ground turrets. Lock-on, auto-aim, torpedoes requiring lock, homing missiles, turret rotation arcs, elevation limits, exposure settings — all working. Every combat mechanic that will later apply to ships is built and tested on the simplest platform.

---

## Pass 5: Speeder Movement
**Depends on:** Passes 1-4
**What it includes:**
- CFrame-based velocity movement system (the core that all vehicles and ships will build on)
- Speeder hover physics: 4 raycasts as virtual springs, terrain-following, surface-normal tilt
- Velocity + momentum + gravity — speeders feel physical, not scripted
- Mouse steering for heading, W/S for throttle, reverse
- Airborne capability: off a cliff edge, gravity takes over, momentum preserved
- Fall damage on hard landing (HP damage based on impact speed, config threshold)
- Collision detection via forward raycasts — hitting a wall kills velocity (no glitch-pushing), applies impact damage
- Speeder-to-speeder collision: both take damage, both bounce, velocity vectors modified
- 3rd person camera following speeder
- Basic platform tagging (driver seat, hover raycast points) + config (speed, hover height, spring stiffness, HP)
- Initial startup validator for vehicle tags
- Placeholder speeder model (box + seat + hover points)
- NO COMBAT — prove the movement system in isolation

**After this pass, the system:**
A player hops on a speeder and drives with mouse + W/S. Speeder hovers over terrain, tilts on slopes, goes airborne off cliffs, lands with impact damage. Hitting a wall stops the speeder and deals damage — no glitching. The CFrame velocity system that everything else builds on is proven.

---

## Pass 6: Speeder Combat
**Depends on:** Pass 5
**What it includes:**
- Weapon mounts on speeder — same turret weapon system from passes 1-4 mounted on a vehicle model
- Driver-fired weapons (left click to fire, weapon fixed forward or on turret mount depending on config)
- Full combat framework on a moving speeder: projectiles, damage types, shields, health, targeting, lock-on
- Vehicle HP + optional shields (config per vehicle)
- Enclosed vs exposed config (speeder bikes = exposed, heavy tanks = enclosed)
- Vehicle destruction: explosion points → explosion → vehicle removed → all occupants die
- Speeder-to-speeder collision damage (extends pass 5 collision with combat damage)
- Dismount behavior: exit moving speeder → speeder continues, decelerates, stops. Player death = same.
- Vehicle theft: empty enemy vehicle, anyone can hop on
- Splash damage affects vehicles as combat entities
- Driver HUD: HP, shield status, speed, weapon overheat/ammo
- Extends validator for weapon mount + combat config on vehicles

**After this pass, the system:**
Armed speeders are fully combat-capable. Driver shoots while driving, locks onto targets, takes damage, gets destroyed. Exposed riders can be shot directly. The combat framework is proven on a moving player-built platform — the same integration pattern ships will use.

---

## Pass 7: Artillery Emplacement
**Depends on:** Passes 1-4
**What it includes:**
- New weaponClass: "artillery" — parabolic projectile trajectory with configurable gravity
- Server-side arc simulation: projectile position/velocity stepped each Heartbeat frame with gravity, collision checked along arc segment via raycasts
- WASD aiming controls: A/D rotates heading (azimuth), W/S adjusts elevation (pitch). No mouse aim.
- Shift + WASD for fine adjustment (slower adjustment rate for precision)
- HUD: elevation angle (degrees with decimals), heading (degrees with decimals), estimated flat-ground range (studs)
- Estimated range formula displayed live: `range = v² × sin(2θ) / g`
- Minimum range enforcement (~100 studs) — elevation angles that produce sub-minimum range are clamped or rejected
- Elevation limits: configurable min/max per weapon (e.g., 15° to 85°)
- Ammo-based with reload timer (not overheat): fire → reload timer → ready. Config-driven ammo capacity and reload duration.
- Splash damage on impact: uses existing explosion damage type with radius falloff (existing splash infrastructure from pass 1)
- Impact feedback: explosion visual effect + hitmarkers for enemies in blast radius (same hitmarker system as turrets)
- No arc preview, no lock-on, no auto-aim — pure manual skill-based indirect fire
- Same ProximityPrompt entry / F exit as turrets
- Artillery entity config in CombatConfig: hull HP, ammo capacity, reload time, muzzle velocity, artillery gravity, splash radius, splash damage, min/max elevation, normal adjust speed, fine adjust speed
- Config starting points: gravity ~300-500, muzzle velocity ~400, splash radius ~25 studs
- Tagging: CombatEntity tag + ArtillerySeat (new seat type), "artillery" weaponClass in config
- Client visual: shell part traveling along the arc (reuses projectile visual system with arc interpolation instead of straight line)

**After this pass, the system:**
A player enters an artillery emplacement, adjusts elevation and heading with WASD (shift for precision), reads the estimated range, and fires. The shell arcs realistically through the air and impacts with splash damage. Pure skill-based indirect fire — no aim assist, no targeting computer. The indirect fire paradigm is proven on a ground emplacement before vehicle-mounted variants.

---

## Pass 8: Biped Walker Movement
**Depends on:** Pass 5 (CFrame velocity system proven on speeders)
**What it includes:**
- **Biped only** — quad walker is a separate future effort (different gait system entirely)
- Walker body CFrame movement: WASD controls relative to body facing (W forward, S reverse slower, A/D strafe), terrain-height following
- Mouse aim turns body (with turn speed limit). Head rotates independently on top of body facing (limited arc, config-driven).
- IK procedural walk cycle: two-bone IK legs, raycasts plant feet on terrain, step triggered by distance threshold, terrain-adaptive
- Procedural secondary body motion: weight shift to planted leg, bob per step, lean into movement, jolt on foot impact, tilt on uneven terrain. Must look hand-animated, not robotic.
- Stop and stand idle (legs planted)
- Biped pivot in place (mouse turn at standstill, feet shuffle)
- Walker off cliff: falls, takes fall damage, IK legs reacquire ground
- Max slope: config per vehicle
- 3rd person camera for walkers (config-driven distance based on walker size)
- Placeholder biped walker model (body + 2 two-segment legs + head + seat)
- Walker-specific tags: IK leg attachments, joint positions, foot targets, head pivot
- NO COMBAT — prove IK walking in isolation. This is the hardest vehicle engineering challenge.

**After this pass, the system:**
A biped walker moves with WASD (forward, reverse, strafe) and turns with mouse. IK legs step on terrain with weight, lean, and bob that looks hand-animated. Head swivels independently within its arc. Legs adapt to slopes and uneven ground. Walker pivots in place. IK biped walking is proven in isolation before combat or quad walkers.

---

## Pass 9: Walker Combat
**Depends on:** Pass 8
**What it includes:**
- Weapons on walkers: head-mounted weapons aimed by mouse (head aim = weapon aim)
- Body-mounted weapons on separate gunner seats (configurable per walker)
- Full combat framework integration (same as speeder combat — projectiles, damage types, shields, health, targeting, lock-on)
- Walker HP + optional shields (config per vehicle)
- Enclosed walker protection (hull must reach 0 to kill crew)
- Walker destruction: explosion points → explosion → walker removed → all occupants die
- Splash damage affects walkers as combat entities
- Walker theft: empty enemy walker, anyone can board
- Extends validator for weapon mount + combat config on walkers

**After this pass, the system:**
Walkers are fully combat-capable. Head weapons aim with mouse, body weapons have independent gunner seats. Both vehicle movement models (hover physics and IK walking) are proven with full combat integration.

---

## Pass 10: Fighter Flight
**Depends on:** Pass 5 (CFrame velocity system proven on speeders)
**What it includes:**
- Fighter flight physics: mouse controls heading + pitch (ship follows mouse with lag), W/S throttle, A/D roll
- Builds on the CFrame velocity system from pass 5 — adds 3D freedom (pitch, roll, yaw) on top of proven movement core
- 3rd person camera following fighter
- Minimum forward velocity in open space (cannot stop/hover)
- Ship boarding: player walks on, sits in pilot seat (seat click, F to exit)
- Basic pilot HUD: speed indicator
- Platform tagging for ships: pilot seat, weapon mounts, explosion points + config (speed, HP, min speed, turn rate)
- Extends startup validator for ship tags
- Placeholder fighter model
- NO COMBAT — prove flight alone. The hardest single engineering challenge.

**After this pass, the system:**
Fighters fly with Battlefront 2 controls. Mouse aims, W/S controls speed, A/D rolls. Ship always moves forward in open space. The flight model is proven in isolation — no combat complexity masking movement bugs.

---

## Pass 11: Vehicle Client-Authority Conversion
**Depends on:** Pass 10 (client-authoritative architecture proven on fighters)
**What it includes:**
- Convert speeder movement from server-authoritative CFrame writes to client-authoritative BodyMover physics (same architecture proven on fighters in pass 10)
- Convert walker movement from server-authoritative CFrame writes to client-authoritative BodyMover physics
- Server becomes lifecycle manager for all vehicles: creates BodyMovers, transfers network ownership to pilot, manages destroy/respawn
- Client drives BodyVelocity + BodyGyro every render frame for all vehicle types
- Speeder: hover physics (4-spring raycasts), collision, fall damage all move from VehicleServer to VehicleClient
- Walker: body movement, gravity, slope blocking move to client. Gait oscillator stays server-side (drives remote IK replication). Server attribute replication simplified.
- RemoteVehicleSmoother: Roblox physics replication handles remote smoothing for all vehicles — eliminate custom CFrame interpolation where possible
- VehicleCamera: simplify vehicle camera branches (no multi-layer 20Hz compensation needed)
- NO combat changes — combat stays server-authoritative for all platforms
- NO new features — same movement behavior, just runs on client at 60Hz+ instead of server at 20Hz

**After this pass, the system:**
All vehicles (speeders, walkers, fighters) use client-authoritative BodyMover physics. Movement is buttery smooth at 60Hz+ with no "fall back and catch up" artifacts. Remote players see smooth movement via Roblox's built-in physics replication. Combat remains fully server-authoritative.

---

## Pass 12: Fighter Combat
**Depends on:** Pass 10
**What it includes:**
- Pilot weapons: left click to fire, 1/2/3 to switch weapon types
- Each weapon type has own overheat/ammo tracking
- Full combat framework applied to fighters (projectiles, damage types, shields, health, targeting, lock-on, auto-aim)
- Ship destruction: explosion points fire sequentially → big final explosion → ship removed → all players inside die
- Fighter collision: collide with solid = fighter destroyed, target takes hull damage
- Crew inside protected from external fire (hull HP protects occupants)
- Pilot HUD: hull HP, shield status, weapon selector, overheat/ammo, lock-on indicators
- Battlefield targeting UI: markers/icons for distant enemy ships

**After this pass, the system:**
Fighters are fully combat-capable. Pilots shoot lasers, switch to torpedoes, lock onto targets, dogfight. Ships take shield and hull damage, get destroyed with explosions, crashing into things is lethal. The combat framework is proven on a flying platform.

---

## Pass 13: Animated Parts
**Depends on:** Passes 5-11 (platforms exist to test on)
**What it includes:**
- Animated external parts system: tagged parts tween between start/end CFrame positions
- Interactive triggers: keybinds or physical buttons activate animations
- Config-driven: which keybind triggers which animation, tween speed, auto-play on events (e.g., landing gear on touchdown)
- Tested on existing platforms: fighter landing gear, walker entry hatches, speeder components
- System is generic — applies to any future platform (transports, cruisers, capital ships)
- Authored via start/end CFrame tags on parts, same tagging convention as all other authoring

**After this pass, the system:**
Platforms have working animated parts. Pilots press keybinds to deploy landing gear, open doors, fold wings. The generic animation system is proven before landing, transport boarding, and troop deployment need it.

---

## Pass 14: Landing System
**Depends on:** Passes 10, 13 (fighter flight + animated parts for landing gear)
**What it includes:**
- Developer-placed landing zones (invisible volumes):
  - Atmosphere zones (large, near planet surfaces)
  - Landing pad zones (specific locations at bases/stations)
  - Hangar approach zones (prep for future — in front of capital ship hangars)
- Landing mode: inside landing zone, minimum speed lifts → pilot decelerates → manual touchdown
- Landing gear animation via pass 12 animated parts system
- Weapons functional while landed
- Space-to-ground transition: atmosphere zone = server boundary → confirmation prompt → intentional-only teleport

**After this pass, the system:**
Fighters can land at designated locations with animated landing gear. Ships can't hover in open space outside zones. Atmosphere boundaries support intentional space-to-ground transitions.

---

## Pass 15: Transport + Cruiser Flight
**Depends on:** Pass 10
**What it includes:**
- Transport flight model: mouse controls yaw only (pitch ignored), E/Q altitude, W/S throttle
- Transport visual sway: ship leans/sways with movement (cosmetic, not player-controlled)
- Cruiser flight model: W/S forward/back, A/D turn (boat-style, NOT strafing), E/Q altitude, large turning radius
- 3rd person camera with pull-back for larger ships
- Multi-crew boarding: multiple players board one ship, each takes a different seat
- Basic multi-crew: pilot flies, passengers ride. No weapon operation yet.
- Entry doors/ramps using pass 12 animated parts system
- Placeholder transport + cruiser models

**After this pass, the system:**
Three ship classes fly with distinct control schemes: fighters (mouse full), transports (mouse yaw + E/Q), cruisers (WASD boat). Multiple players can board and ride. The feel is right — transports sway, cruisers feel heavy.

---

## Pass 16: Relative Motion + Ship Interiors
**Depends on:** Pass 15
**What it includes:**
- Relative motion: players on a moving ship move WITH the ship
- Jump test: jump on moving ship → land in same spot relative to ship
- Applies to transports, cruisers, capital ships (not fighters — always seated). Also applies to walkers with walkable interiors.
- Internal teleporters: proximity prompt at tagged teleporter → instant teleport to paired destination
- Walking inside moving ship without jitter/desync
- Vulnerable boarding: walking up a ramp, player can take external fire

**After this pass, the system:**
Players walk around inside a moving cruiser without falling off or desyncing. Jumping works correctly. Internal teleporters navigate large ships. This must be proven BEFORE manned weapons — gunners need to reliably walk to their stations on a moving ship.

---

## Pass 17: Manned Weapons + Weapon Grouping
**Depends on:** Passes 15, 16
**What it includes:**
- Manned weapons: gunner walks to weapon station → sit → camera moves to weapon viewpoint → aim → fire → F to exit
- Weapon grouping: one player controls multiple guns (e.g., 4 turbolasers = one station)
- Multi-gun fire pattern from config (volley, sequential, spread)
- Full combat framework on manned weapons (all damage types, overheat, ammo, lock-on, auto-aim)
- Crew protection from external fire
- Multi-crew combat loop: pilot flies, gunners independently aim and fire
- Gunner HUD: crosshair, overheat, ammo, lock-on indicators

**After this pass, the system:**
The multi-crew combat loop works. Pilot flies a cruiser while gunners man weapon stations, aiming from their camera viewpoints. Weapon grouping lets one gunner fire multiple guns. The manned-weapon experience is working.

---

## Pass 18: Power Routing
**Depends on:** Pass 17
**What it includes:**
- Squadrons-style 12-pip system: shields (8 max), engines (8 max), weapons (8 max), 12 total budget
- Default: 4/4/4 (balanced). Pilot redistributes via keybinds.
- Shield pips: faster regen. Engine pips: higher max speed. Weapon pips: faster fire rate / reduced overheat for ALL weapons on the ship.
- Applies to ALL piloted platforms (fighters, transports, cruisers, capital ships, vehicles)
- Pilot HUD: power routing interface (3 bars with pip indicators)
- Test on multi-crew: pilot shifts power → gunners feel the fire rate change

**After this pass, the system:**
Every pilot manages power distribution. Tactical depth for every piloted platform. On multi-crew ships, the pilot's decisions directly affect gunner effectiveness.

---

## Pass 19: Capital Ship Flight + Repulsion
**Depends on:** Passes 15, 16
**What it includes:**
- Capital ship flight model: same as cruiser but larger/slower/even wider turning radius
- 3rd person camera pulled way back (show entire capital ship)
- Capital-to-capital repulsion field: invisible bumper pushes large ships apart before physical contact
- Capital ship with full interior, teleporters, manned weapons, power routing (all from previous passes)

**After this pass, the system:**
Capital ships fly with appropriate weight and scale. Two capital ships approaching each other gently push apart instead of clipping/exploding. Capital ships have working interiors, weapons, and power routing from previous passes.

---

## Pass 20: Subsystem Framework
**Depends on:** Pass 19
**What it includes:**
- Targetable subsystems on capital ships: shield generator, hangar bay, weapon batteries, torpedo launchers, engines
- Each subsystem has independent HP pool (does NOT correlate with hull HP)
- Subsystems do NOT regenerate (permanent damage)
- Subsystem destruction effects:
  - Shield generator → shields collapse to 0 immediately, no regen
  - Engines → ship slows to ~20% speed, cannot enter hyperspace
  - Hangar → no more fighter launches/returns
  - Weapon battery → that weapon/group permanently offline
  - Torpedo launcher → no more torpedo capability
- Subsystem targeting: lock onto ship → cycle to subsystem → auto-aim aims at subsystem hitbox
- Ion cannon stun effect: temporarily disables subsystem (duration config-driven)
- Pilot HUD: all subsystem health visible at all times
- Hyperspace integration: destroyed engines block hyperspace entry

**After this pass, the system:**
Capital ships have targetable subsystems with strategic destruction effects. The full Empire at War tactical health model works.

---

## Pass 21: Hangars
**Depends on:** Passes 12, 20
**What it includes:**
- Hangar launch: walk to console → proximity prompt → screen blacks out → spawn in fighter outside hangar
- Hangar return: fly close → docking prompt → confirm → screen blacks out → teleported inside
- Repair + rearm: hull restored, shields restored, ammo refilled. Config-driven timer.
- Hangar as targetable subsystem: destroyed = no launches or returns

**After this pass, the system:**
Capital ships launch and recover fighters. Fighters return to dock, repair, and rearm. Destroying the hangar cuts off all fighter operations.

---

## Pass 22: Ownership + Despawn
**Depends on:** Passes 6, 12 (vehicles and ships must exist)
**What it includes:**
- Crew registry: board → join crew list. Leave when physically exit, die, or disconnect.
- Owner-based persistence: stays while owner in same server
- Despawn timer: owner leaves server + crew empty → grace timer → removed
- **Shared limit: max 2 active across ships AND vehicles per player**
- Despawn-on-spawn: at limit, spawning prompts which to despawn
- Shorter despawn if owner is in another ship/vehicle
- Server transfer: deleted from old server, reconstructed in new

**After this pass, the system:**
Unified ownership across ships and vehicles. Shared 2-limit. Persistence works. Fleet sharing works (anyone can drive/pilot your stuff). Abandoned platforms despawn.

---

## Pass 23: Scanning Station
**Depends on:** Pass 20
**What it includes:**
- Dedicated bridge crew seat
- Scan enemy ship within sensor range (config-driven range, scan duration)
- Reveals: hull HP %, shield HP %, subsystem status, ship class
- Info on scanner's screen AND pilot's tactical HUD
- Info goes stale, must re-scan

**After this pass, the system:**
Capital ships have a dedicated intel role. Coordinated crews with active scanners have a tactical edge.

---

## Pass 24: Upgrades
**Depends on:** Passes 6, 12 (vehicles and ships with config)
**What it includes:**
- 6 upgrade categories: Shields, Hull/Armor, Engines, Weapons (energy), Weapons (ordnance), Sensors
- Tier structure: Mk I (base), Mk II, Mk III
- Per-vehicle/ship caps in config
- Numbers change, identity doesn't
- Combat framework reads upgrade-modified config values at spawn time
- Applies to both ships AND vehicles

**After this pass, the system:**
Players upgrade individual components on ships and vehicles. Per-platform caps preserve identity. The progression layer is working.

---

## Pass 25: Vehicle Transport + Troop Deployment
**Depends on:** Passes 8-9, 13, 15, 16 (walkers, animated parts, transport ships, relative motion)
**What it includes:**
- Small vehicle transport: transport ship approaches ground vehicle, keybind snaps vehicle to predetermined carry position. Same keybind to deploy. Dead stop required.
- Large vehicle transport: spawned at space station with transport ship, visually carried, interior not loaded until deployment. Dead stop to deploy.
- Troop deployment from transport-capable walkers: vehicle at full stop, transport bay doors open (animated), players interact to rappel down (smooth position tween, 2-way)
- Vehicle-in-vehicle: carried vehicle model parented to carrier, activates as independent vehicle when a player sits in it

**After this pass, the system:**
Transport ships carry vehicles between planets. Transport walkers deploy troops via rappel. Small vehicles snap to transport ships for relocation. The full ground force logistics loop works.

---

## Pass 26: Formation Autopilot (Not Committed)
**Depends on:** Pass 15+
**What it includes:**
- Escort ships maintain relative position to flagship via autopilot
- Realistic maneuvering (turn, accelerate, reposition)
- **Cut if performance cost too high**

**After this pass, the system:**
Fleets form up and move together. Escorts automatically maintain position.

---

## Pass 27: Tractor Beams (Not Committed)
**Depends on:** Pass 19
**What it includes:**
- Capital ships emit tractor beam toward target
- Gravitational pull draws target toward source
- **Scope TBD — may be cut**

**After this pass, the system:**
Capital ships pull enemy ships toward them. Blockades become possible.

---

## Final Pass: Optimization
**Depends on:** All previous passes
**What it includes:**
- Object pooling for projectile visuals
- LOD for ships/vehicles at distance
- Network culling (don't replicate irrelevant distant data)
- Projectile batching (group updates into fewer messages)
- Efficient turret rotation via IK Control LookAt
- CFrame movement optimization
- Scale testing: 30+ ships/vehicles, 100 players, hundreds of shots/sec
- Performance profiling + bottleneck fixes
- Scale validation (compress if needed per tiered scale convention)

**After this pass, the system:**
Same behavior, dramatically better performance. Sustains 30+ ships/vehicles, hundreds of shots per second, 100 players.
