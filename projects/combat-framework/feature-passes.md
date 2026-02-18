# Feature Passes: Combat Framework

**Based on:** idea-locked.md
**Date:** 2026-02-18

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

## Pass 5: Armed Ground Vehicles
**Depends on:** Passes 1-4
**What it includes:**
- Bolt combat framework onto existing vehicle system (decision pending: bolt-on vs rebuild — evaluate current system, decide at design time)
- Vehicle health: hull HP + optional shields (config-driven)
- Vehicle-mounted weapons: same framework (projectiles, damage types, overheat, ammo, targeting)
- Vehicle destruction: 0 HP → explosion → removed → player dies
- Vehicle weapon aiming (manual aim + lock-on)
- Multi-crew ground vehicles if applicable (driver + gunner — depends on existing system)
- Config for vehicle combat stats

**After this pass, the system:**
Combat framework works on moving ground platforms. Vehicles have health, shields, weapons, targeting, and can be destroyed. The framework is proven platform-agnostic before we touch ships.

---

## Pass 6: Ship Authoring — Core
**Depends on:** Passes 1-4 (combat framework must exist for config schema to reference)
**What it includes:**
- CollectionService tagging convention for ship models:
  - Weapon mount tags (position, type reference)
  - Seat tags (pilot, gunner, passenger — what each controls)
  - Explosion point tags (min 3 per ship)
- Config schema — core:
  - Ship stats: speed, hull HP, shield HP, turn radius, min speed, shield regen delay
  - Weapon definitions: type, fire rate, damage, overheat rate, ammo, projectile speed, range, firing arc
  - Seat-to-weapon mapping: which seat fires which weapon
- Startup validator: checks tags exist, config is valid, seats map to real weapons. Fails loud with clear errors.
- This is the minimum authoring needed to build and test a fighter

**After this pass, the system:**
A dev can tag a fighter model's weapon mounts, seats, and explosion points, write a config with stats and weapon definitions, and the validator confirms it's correct. The authoring pipeline exists — no gameplay yet, just tooling.

---

## Pass 7: Fighter Flight Model
**Depends on:** Pass 6
**What it includes:**
- Fighter flight physics: mouse controls heading + pitch (ship follows mouse with lag), W/S throttle, A/D roll
- 3rd person camera following the fighter
- Minimum forward velocity in open space (cannot stop/hover)
- Ship spawning: existing shop system spawns the tagged + configured ship model
- Ship boarding: player walks onto ship via door/ramp, proximity prompt ("Pilot Seat"), F to exit
- Basic pilot HUD: speed indicator
- NO COMBAT in this pass — just flight. Prove the flight model works in isolation.

**After this pass, the system:**
Fighters fly with Battlefront 2 controls. Mouse aims, W/S controls speed, A/D rolls. Ship always moves forward in open space. Players board by walking on and sitting in the pilot seat. The flight model — the hardest engineering challenge — is proven without combat complexity on top.

---

## Pass 8: Fighter Combat
**Depends on:** Pass 7
**What it includes:**
- Pilot weapons: left click to fire, 1/2/3 to switch weapon types
- Each weapon type has own overheat/ammo tracking
- Full combat framework applied to fighters (projectiles, damage types, shields, health, targeting, lock-on, auto-aim — all from passes 1-4)
- Ship destruction: explosion points fire sequentially → big final explosion → ship removed → all players inside die
- Fighter collision: collide with solid = fighter destroyed, target takes hull damage scaled to fighter mass
- Crew inside protected from external fire (hull HP protects occupants)
- Pilot HUD: hull HP, shield status, weapon selector, overheat/ammo, lock-on indicators
- Battlefield targeting UI: markers/icons for distant enemy ships

**After this pass, the system:**
Fighters are fully combat-capable. Pilots shoot lasers, switch to torpedoes, lock onto targets, dogfight. Ships take shield and hull damage, get destroyed with explosions, crashing into things is lethal. The combat framework is proven on a flying platform.

---

## Pass 9: Landing System
**Depends on:** Pass 7
**What it includes:**
- Developer-placed landing zones (invisible volumes):
  - Atmosphere zones (large, near planet surfaces)
  - Landing pad zones (specific locations at bases/stations)
  - Hangar approach zones (prep for future — in front of capital ship hangars)
- Landing mode: inside landing zone, minimum speed lifts → pilot decelerates → manual touchdown
- Weapons functional while landed (gunners can fire from grounded ship)
- Space-to-ground transition: atmosphere zone = server boundary → player enters → confirmation prompt ("Enter atmosphere? Press [key]") → intentional-only teleport

**After this pass, the system:**
Fighters can land at designated locations. Landing requires a dev-placed zone. Ships can't hover in open space outside zones. Atmosphere boundaries support intentional space-to-ground transitions. Weapons work while grounded.

---

## Pass 10: Ship Authoring — Extended
**Depends on:** Pass 6
**What it includes:**
- Additional tags:
  - Animated external part tags (landing gear, doors, ramps, foils — start/end CFrame positions)
  - Interactive trigger tags (physical buttons, keybind-activated)
  - Subsystem location tags (shield generator, engines, hangar, weapon batteries, torpedo launchers)
  - Internal teleporter pair tags
  - Hangar zone tags (launch points outside, docking trigger, capacity)
- Config schema — extended:
  - Weapon grouping: which mounts form one control group
  - Multi-gun fire pattern per group (volley, sequential, spread)
  - Animation definitions (start/end CFrames, trigger keybinds)
  - Subsystem HP values
  - Upgrade caps per component (max Mk II or Mk III)
- Validator extensions: checks grouping, animations, subsystems, teleporter pairs
- The full authoring system needed for multi-crew and capital ships

**After this pass, the system:**
The complete ship authoring pipeline is done. Devs can configure any ship from fighter to Star Destroyer: weapons, grouping, animations, subsystems, teleporters, hangars, upgrades — all via tags and config. Any dev can set up any ship without specialized knowledge.

---

## Pass 11: Transport + Cruiser Flight
**Depends on:** Pass 7, Pass 10
**What it includes:**
- Transport flight model: mouse controls yaw only (pitch ignored), E/Q altitude, W/S throttle
- Transport visual sway: ship leans/sways with movement (cosmetic, not player-controlled)
- Cruiser flight model: W/S forward/back, A/D turn (boat-style, NOT strafing), E/Q altitude, large turning radius
- 3rd person camera with pull-back for larger ships (show whole ship)
- Multi-crew boarding: multiple players board one ship, each takes a different seat via proximity prompt
- Basic multi-crew: pilot flies, passengers ride. No weapon operation yet — just prove multiple people can be on one moving ship.

**After this pass, the system:**
Three ship classes fly with distinct control schemes: fighters (mouse full), transports (mouse yaw + E/Q), cruisers (WASD boat). Multiple players can board a cruiser. The feel is right — transports sway, cruisers feel heavy and deliberate.

---

## Pass 12: Manned Weapons + Weapon Grouping
**Depends on:** Pass 11
**What it includes:**
- Manned weapons: gunner walks to weapon station → proximity prompt → sit → camera moves to pre-defined optimal viewpoint → aim with mouse → fire → F to exit
- Weapon grouping: one player controls multiple guns (e.g., 4 turbolasers = one station)
- Multi-gun fire pattern from config (volley, sequential, spread)
- Full combat framework on manned weapons (all damage types, overheat, ammo, lock-on, auto-aim)
- Crew protection from external fire (ship hull protects everyone inside)
- Multi-crew combat loop: pilot flies, gunners independently aim and fire from their stations
- Gunner HUD: crosshair, overheat, ammo, lock-on indicators, own weapon subsystem health (prep for subsystems)

**After this pass, the system:**
The multi-crew combat loop works. Pilot flies a cruiser while gunners man weapon stations, aiming from their camera viewpoints. Weapon grouping lets one gunner fire multiple guns. The Galaxy at War manned-weapon experience is working.

---

## Pass 13: Power Routing
**Depends on:** Pass 12 (need pilot + gunners to test weapon pip effects on crew)
**What it includes:**
- Squadrons-style 12-pip system: shields (8 max), engines (8 max), weapons (8 max), 12 total budget
- Default: 4/4/4 (balanced)
- Pilot redistributes via keybinds
- Shield pips: more = faster regen rate
- Engine pips: more = higher max speed
- Weapon pips: more = faster fire rate / reduced overheat for ALL manned weapons on the ship
- Applies to ALL piloted ships (fighters, transports, cruisers, capital ships)
- Pilot HUD: power routing interface (3 bars with pip indicators)
- Test on multi-crew: pilot shifts power → gunners feel the fire rate change

**After this pass, the system:**
Every pilot manages power distribution. Cranking shields to max speeds regen but slows the ship and weakens weapons. On a multi-crew cruiser, the pilot's decisions directly affect gunner effectiveness. Tactical depth for every pilot.

---

## Pass 14: Relative Motion + Ship Interiors
**Depends on:** Pass 11 (multi-crew ships with walkable interiors)
**What it includes:**
- Relative motion: players on a moving ship move WITH the ship
- Jump test: jump on moving ship → land in same spot relative to ship
- Applies to transports, cruisers, capital ships (not fighters — players always seated)
- Internal teleporters: proximity prompt at tagged teleporter → instant teleport to paired destination
- Walking inside moving ship without jitter/desync
- Vulnerable boarding: walking up a ramp, player can take external fire

**After this pass, the system:**
Players walk around inside a moving cruiser without falling off or desyncing. Jumping works correctly. Internal teleporters navigate large ships. The walkable-ship experience is ready for capital ships.

---

## Pass 15: Capital Ship Flight + Repulsion
**Depends on:** Passes 11, 14
**What it includes:**
- Capital ship flight model: same as cruiser but larger/slower/even wider turning radius
- 3rd person camera pulled way back (show entire capital ship)
- Capital-to-capital repulsion field: invisible bumper pushes large ships apart before physical contact
- No collision physics jank — repulsion prevents Roblox from ever calculating large-model collisions
- Capital ship with full interior, teleporters, manned weapons, power routing (all from previous passes)

**After this pass, the system:**
Capital ships fly with appropriate weight and scale. Camera pulls way back to show the massive ship. Two capital ships approaching each other gently push apart instead of clipping/exploding. Capital ships have working interiors, weapons, and power routing from previous passes.

---

## Pass 16: Subsystem Framework
**Depends on:** Pass 15
**What it includes:**
- Targetable subsystems on capital ships: shield generator, hangar bay, weapon batteries, torpedo launchers, engines
- Each subsystem has independent HP pool (does NOT correlate with hull HP)
- Subsystems do NOT regenerate (permanent damage)
- Subsystem destruction effects:
  - Shield generator → shields collapse to 0 immediately, no regen possible
  - Engines → ship slows to ~20% speed, cannot enter hyperspace
  - Hangar → no more fighter launches/returns (prep for hangar pass)
  - Weapon battery → that weapon/group permanently offline
  - Torpedo launcher → no more torpedo capability
- Subsystem targeting: lock onto ship → cycle to target specific subsystem → auto-aim aims at subsystem hitbox
- Ion cannon stun effect: temporarily disables subsystem without destroying it (duration config-driven)
- Pilot HUD: all subsystem health visible at all times
- Hyperspace integration: destroyed engines block hyperspace entry

**After this pass, the system:**
Capital ships have targetable subsystems with strategic destruction effects. Destroying the shield generator collapses shields. Crippling engines prevents escape. Ion cannons temporarily disable subsystems. The full Empire at War tactical health model works.

---

## Pass 17: Hangars
**Depends on:** Passes 8, 16 (need fighters + capital ships with subsystems)
**What it includes:**
- Hangar launch: player walks to console in hangar → proximity prompt → screen blacks out → spawns in fighter at dev-defined point outside hangar, ready to fly
- Hangar return: fighter flies close to hangar → docking prompt → confirm → screen blacks out → teleported inside
- Repair + rearm: inside hangar, hull HP restored, shields restored, subsystems repaired, ammo refilled. Takes config-driven time. Player waits.
- Re-launch: same process as initial launch
- Hangar as targetable subsystem: destroyed = no launches or returns
- Pilot-role restriction: ideally only pilot-role faction members can launch (faction integration point)

**After this pass, the system:**
Capital ships launch and recover fighters. Fighters return to dock, repair, and rearm on a timer. Destroying the hangar cuts off all fighter operations. The full carrier gameplay loop works.

---

## Pass 18: Ship Ownership + Despawn
**Depends on:** Pass 8+ (ships must exist)
**What it includes:**
- Crew registry: board ship → join crew list. Leave when physically exit, die, or disconnect.
- Owner-based persistence: ship stays while owner in same server
- Despawn timer: owner leaves server + crew empty → grace timer → ship removed
- Max 2 active ships per player
- Shorter despawn: if owner is piloting their OTHER ship, unoccupied one despawns faster
- Server transfer: ship deleted from old server, reconstructed in new when owner teleports while piloting

**After this pass, the system:**
Ship persistence works. Land and walk away — ship stays. Fleet sharing works (anyone can pilot your ship). Abandoned ships despawn. Max 2 ships prevents spam. Server transfers don't duplicate ships.

---

## Pass 19: Scanning Station
**Depends on:** Pass 16 (capital ships with subsystems)
**What it includes:**
- Dedicated bridge crew seat (tagged + configured)
- Scanner selects enemy ship within sensor range
- Scan takes a few seconds (config-driven)
- Reveals: hull HP %, shield HP %, subsystem status (intact/damaged/destroyed), ship class
- Info on scanner's screen AND captain/pilot's tactical HUD
- Info persists for duration then goes stale (must re-scan)
- Range-limited (config-driven sensor range)
- Scanner operator HUD: target selector, scan progress, scanned info panel

**After this pass, the system:**
Capital ships have a dedicated intel role. Scanner crew scans enemies to reveal health, shields, and subsystem damage. Info appears for the scanner and captain. Stale data must be refreshed. Coordinated crews with active scanners have a tactical edge.

---

## Pass 20: Ship Upgrades
**Depends on:** Pass 6 (ship authoring with upgrade cap config)
**What it includes:**
- 6 upgrade categories: Shields, Hull/Armor, Engines, Weapons (energy), Weapons (ordnance), Sensors
- Tier structure: Mk I (base), Mk II, Mk III
- Per-ship caps in config (some ships max at Mk II for certain categories)
- One bucket per category (upgrade "shields" → all shield stats improve proportionally)
- Numbers change, identity doesn't (TIE never becomes tanky)
- Combat framework reads upgrade-modified config values at ship spawn time
- Integration: upgrade data from separate shop/upgrade system

**After this pass, the system:**
Players upgrade individual ship components. Mk II shields noticeably improve HP and regen. Per-ship caps preserve identity. The progression layer is working.

---

## Pass 21: Animated Ship Parts
**Depends on:** Pass 10 (extended authoring with animation tags)
**What it includes:**
- Animated external parts system: tagged parts tween between start/end CFrame positions
- Interactive triggers: physical buttons on hull or pilot-seat keybinds activate animations
- Landing gear deploy/retract
- Entry doors/ramps open/close
- X-wing foil folding, Imperial transport wings, etc.
- Config-driven: which keybind triggers which animation, tween speed

**After this pass, the system:**
Ships have working animated parts. Pilots press keybinds to deploy landing gear, open doors, fold wings. Entry ramps lower for boarding. Ships feel alive instead of static models.

---

## Pass 22: Formation Autopilot (Not Committed)
**Depends on:** Pass 11+ (multiple ships flying)
**What it includes:**
- Escort ships maintain relative position to flagship via autopilot
- Displaced ships maneuver back: turn, accelerate, reposition, match heading/speed
- Realistic maneuvering (no teleporting to position)
- **Cut if performance cost too high**

**After this pass, the system:**
Fleets form up and move together. Escorts automatically maintain position. Flagship turns → escorts maneuver to stay in formation.

---

## Pass 23: Tractor Beams (Not Committed)
**Depends on:** Pass 15 (capital ships)
**What it includes:**
- Capital ships emit tractor beam toward target
- Gravitational pull draws target toward source hangar
- Enables blockades / ship capture
- Escape mechanics TBD
- **Scope TBD — may be cut**

**After this pass, the system:**
Capital ships pull enemy ships toward them with tractor beams. Blockades become possible.

---

## Final Pass: Optimization
**Depends on:** All previous passes
**What it includes:**
- Object pooling for projectile visuals
- LOD for ships at distance
- Network culling (don't replicate irrelevant distant data)
- Projectile batching (group updates into fewer messages)
- Efficient turret rotation via IK Control LookAt
- Math-based ship movement optimization (CFrame, minimize physics)
- Scale testing: 30+ ships, 100 players, hundreds of shots/sec
- Performance profiling + bottleneck fixes
- True-to-scale validation (compress if needed)

**After this pass, the system:**
Same behavior, dramatically better performance. Sustains 30+ ships, hundreds of shots per second, 100 players. LOD, pooling, and culling keep client and server in budget.
