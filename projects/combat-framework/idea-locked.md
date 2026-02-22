# System Idea: Combat Framework (LOCKED)

## Overall Purpose

A unified combat framework for large-scale Star Wars galactic battles. Weapons, projectiles, damage, shields, and targeting work identically regardless of platform (static turret, ground vehicle, starfighter, capital ship). The system must support 30+ active ships with hundreds of blaster shots per second in servers of up to 100 players.

The framework sits on top of the existing blaster system and vehicle system, extending them into multi-platform combat.

This system facilitates large-scale galactic warfare — faction-driven, player-focused (milsim philosophy), almost RTS-like but where players ARE the units. Victory is faction-based mission completion, not individual kill counts.

---

## Ground Installations (Build Foundation)

Static ground turrets/emplacements. First platform — entire combat framework proven here before ships.

- Pre-placed by developers in the world
- Player walks up, **proximity prompt** to enter ("Man Turret"), sits in, aims manually, fires
- **F key** to exit turret
- Most turrets: hull HP only (no shields), config-driven per turret so shielded variants are possible
- Destructible — respawn after a configurable timer
- Weapon type depends on the turret (blaster, turbolaser, ion, etc.)
- Rotation arc: developer-configured per turret (360, limited arc, wall-mounted, etc.)
- Player exposure: developer-configured per turret (enclosed armored housing vs open mounted gun)
- Anti-air capability: developer-configured per turret (some can aim upward at ships, some ground-only)
- Pass 1: manual aim only

**Success condition:** Player sits in turret, fires at a target dummy, target takes correct damage type to shields/hull. Turret takes return fire, hull decreases, turret is destroyed, respawns after timer. Player presses F to exit turret voluntarily.

---

## Artillery Emplacements

Fixed-position indirect fire weapons. Fundamentally different from turrets — arcing projectile trajectories, manual angle/heading adjustment, area denial. No auto-aim, no lock-on, no arc preview. Pure skill.

- Pre-placed by developers in the world
- Player walks up, **proximity prompt** to enter, **F key** to exit (same as turrets)
- **WASD aiming**: A/D rotates heading (azimuth), W/S adjusts elevation (pitch). No mouse aim.
- **Shift + WASD**: fine adjustment mode for precision aiming
- **HUD**: three numbers — Elevation (degrees with decimals), Heading (degrees with decimals), Estimated Range (studs, assuming target is level with you)
- Estimated range calculated live from current elevation: `range = v² × sin(2θ) / g`
- **Parabolic projectile**: shell arcs through the air with gravity, fully server-simulated
- **Splash damage** on impact — area-of-effect with falloff, not direct hit
- **Ammo-based** with reload between shots (not overheat) — load, fire, wait, load next
- **Minimum range**: ~100 studs — prevents firing at targets directly in front
- **Custom gravity**: config-tunable per weapon, starting at ~400-500 (heavier than Roblox default 196.2 for satisfying punchy arcs)
- **Impact feedback**: explosion visual + hitmarkers (same hitmarker system as turrets)
- **No arc preview** — player reads estimated range, fires, observes where shell lands, adjusts
- Destructible — hull HP, respawns after config timer (same as turrets)
- Later: mountable on vehicles (heavy speeders, walkers) when vehicle passes are complete

**Success condition:** Player enters artillery emplacement, adjusts elevation and heading with WASD (shift for precision), reads estimated range display, fires. Shell arcs realistically through the air, impacts terrain/target, deals splash damage to everything in blast radius. Player sees explosion, gets hitmarkers on enemies hit. Player adjusts angle based on observed impact point. Shift-aiming allows fine degree adjustments for precision.

---

## Ship Classes

Four classes. Every ship individually tuned — unique stats, weapons, seats. No generic class defaults.

### Flight Control Models

| Class | Heading | Pitch | Altitude | Speed | Roll | Camera |
|---|---|---|---|---|---|---|
| Fighter | Mouse | Mouse | (via pitch) | W/S throttle | A/D | 3rd person |
| Transport | Mouse | **Ignored** | E/Q | W/S throttle | None (visual sway only) | 3rd person |
| Cruiser | A/D turn | **Ignored** | E/Q | W/S throttle | None | 3rd person (pulled back, whole ship) |
| Capital Ship | A/D turn | **Ignored** | E/Q | W/S throttle | None | 3rd person (pulled way back, whole ship) |

### Fighter
- Mouse-controlled flight (Battlefront 2 2005/2017 inspired) — ship follows where mouse points with some lag
- W/S for throttle (speed up/slow down), A/D for roll
- **Minimum forward velocity in open space** — fighters cannot hover/stop during flight
- **Landing mode:** when entering a developer-placed landing zone (near planet surface, hangar approach, landing pad), fighters can decelerate below minimum speed, transition to landing, and stop. Outside landing zones, minimum speed is enforced.
- Can land on surfaces (planets, capital ship hangars, landing pads)
- Manual landing (player lines up and touches down)
- **Weapons functional while landed** — rear gunners, turrets, etc. can still fire from a grounded ship
- Agile, dogfighting-focused
- Lore-accurate seats — solo fighters (TIE) fully capable alone, multi-seat (ARC-170) need full crew
- Pilot can fire weapons if lore-accurate for that ship
- **Weapon switching:** pilot presses 1, 2, etc. to switch between weapon types (lasers, torpedoes, etc.)
- No NPC wingmen or AI pilots — all ships are player-operated

### Transport
- Mouse steers heading (yaw), pitch input **ignored** — ship does NOT pitch with mouse
- E/Q for altitude (ascend/descend), W/S for throttle
- Ship leans/sways visually with movement (cosmetic, not player-controlled)
- Carries players primarily
- End-game: vehicle transport variants carry ground vehicles to planet surfaces

### Cruiser
- W/S forward/back, A/D turn (like a boat — NOT strafing)
- Large turning radius, E/Q for altitude
- Multi-crew

### Capital Ship
- Same control scheme as Cruiser but larger/slower/even wider turning radius
- Multi-crew: pilot seat, weapon stations, bridge, walkable interior with internal teleporters for large ships
- Can have hangars that launch pre-loaded fighters
- Pilot controls flight ONLY — no weapons
- Pilot has power routing

### All Ships
- **F key** to enter seats (proximity prompt) and exit seats
- **Power routing** available to all pilots (see Power Routing section)
- 3rd person camera for all ship types

**Success conditions:**
- Fighter: player enters, takes off with W, flies with mouse + A/D roll, cannot stop in open space, enters landing zone → can decelerate and land manually. Multi-seat fighter: second player boards, mans rear gun, fires independently.
- Transport: player flies with mouse (yaw only, no pitch response), uses E/Q for altitude, W/S for speed, ship visually sways. Passengers board and ride.
- Cruiser/Capital: W/S speed, A/D turn (boat-like), large turning radius, E/Q altitude. Feels heavy and deliberate. 3rd person shows full ship.

---

## Interiors — Convention (Applies to All Ships & Vehicles)

### Two-Layer Interior Architecture
All walkable interiors use a two-layer approach:
- **Visual layer:** Full detailed MeshPart interiors (corridors, consoles, panels, pipes, lights). All set to `CanCollide = false`. These are cosmetic only.
- **Collision layer:** Invisible simple Parts (boxes, wedges, cylinders) placed over every walkable/collidable surface — floors, walls, ramps, doorways, railings. These handle all physics collision.

Players walk on the invisible collision parts, see the detailed mesh around them. This gives full visual fidelity with cheap, reliable collision.

### Why Not Mesh Collision?
Roblox's PreciseConvexDecomposition breaks meshes into multiple convex hulls. Even simple mesh floors become expensive — more hulls = more physics checks per frame. With 100 players walking in multiple ship interiors on moving platforms, collision must be as cheap as possible. A single invisible box Part is one convex shape — near-zero cost.

### Authoring Requirement
Every ship/vehicle with a walkable interior must have both layers. This is a one-time cost per model. The startup validator should warn if a tagged interior zone has no collision parts.

### Which Platforms Need Interiors
- **No interior:** Speeder bikes, single-seat fighters (TIE, X-wing) — player is always seated, sealed cockpit
- **Minimal interior (cockpit only):** AT-ST, small transports — a few seats, no walkable space, just proximity prompts
- **Full walkable interior:** AT-AT, capital ships, large transports, cruisers — troops walk around, multiple rooms, teleporters

---

## Ship Interiors & Boarding

- Ships have full interiors. Players physically walk onto ships via doors, ramps, hatches.
- Walk to pilot seat, gunner stations, etc. **Proximity prompt** to sit (tells player what they're sitting at — "Man Turbolaser," "Pilot Seat," etc.). **F key** to exit.
- Players are **vulnerable while boarding** — walking up a ramp on a battlefield, you can take fire. No special boarding protection.
- **Crew inside ships are protected from external fire** — ship hull HP must reach 0 to kill crew. You cannot snipe individuals through windows or target crew directly. Exception: ground turrets with "exposed" config may leave the operator vulnerable.
- Large ships have **internal teleporters:** proximity prompt at each teleporter → click → instant teleport to paired destination. Dev sets up paired locations via tagging.
- No ejection mechanic — players cannot exit a ship mid-flight. Ship must land, or player resets/respawns.

### Relative Motion (Must-Have)
- When standing on a moving ship, players move WITH the ship.
- If you jump on a moving capital ship, you land where you jumped from relative to the ship — not get left behind.
- Applies to ships without pitch control that don't roll much (transports, cruisers, capital ships). Fighters may not need this (players are always seated).
- This is a known hard problem in Roblox and a critical technical challenge.

**Success condition:** Player stands on the deck of a moving capital ship. Ship turns and accelerates. Player stays in place relative to the ship. Player jumps and lands on the same spot on the deck, not offset.

---

## Landing Zones

- Developer-placed invisible volumes in the world that define where fighters can decelerate and land
- **Types:**
  - **Atmosphere zones:** large volumes near planet surfaces (the transition boundary between space and ground)
  - **Hangar approach zones:** volumes in front of capital ship hangar bays
  - **Landing pad zones:** specific docking/landing locations at bases, stations, etc.
- When a fighter enters a landing zone, minimum speed restriction is lifted — pilot can decelerate to a stop and land manually
- Outside all landing zones, fighters maintain minimum forward velocity

### Space-to-Ground Transition
- The atmosphere zone doubles as the server transition boundary (if space/ground are split servers)
- Transition must be **intentional** — flying near the boundary does NOT auto-teleport
- Player enters atmosphere zone → prompt appears ("Enter atmosphere? Press [key]") → only confirmed transitions trigger teleport
- Prevents accidental server transfers during dogfights near the boundary

**Success condition:** Fighter enters landing zone, can slow down and land. Fighter near atmosphere boundary without confirming: stays in space. Fighter confirms transition: teleports to ground server with ship.

---

## Ship Setup System (CRITICAL PATH)

Current ship setup is too painful — only the creator can configure ships. New system must let ANY dev set up ANY ship without specialized knowledge.

### What Needs Setup Per Ship
- **Animated external parts:** landing gear, entry doors/ramps, X-wing foil folding, Imperial transport wing folding, etc. — start/end positions
- **Interactive triggers:** physical buttons on hull, or pilot-seat keybinds to toggle animations (open doors, lower landing gear, etc.)
- **Weapon mounts:** position, type, firing arc, seat assignment
- **Weapon grouping:** multiple guns → one control group (4 port turbolasers on ISD = 1 gunner station; ~5 players man all ~20 turbolasers)
- **Multi-gun fire pattern:** config per group — simultaneous volley, sequential rapid fire, or spread. Developer chooses.
- **Seats:** pilot, co-pilot, gunner, passenger — what each controls (all via proximity prompt + F to exit)
- **Internal teleporters:** paired locations for large ship navigation
- **Hangar bay:** launch zones (dev-defined spawn points outside hangar for launching fighters), fighter capacity, docking trigger zone
- **Explosion points:** min 3 per ship, pre-placed for destruction sequence
- **Subsystem locations:** which model parts are targetable subsystems
- **Per-ship stats:** speed, hull HP, shield HP, turn radius, shield regen delay, subsystem HP, weapon stats — all config-driven
- **Upgrade caps:** per-component max tier (see Ship Upgrades)

### Approach
- Studio tagging conventions for spatial setup (CollectionService tags / naming conventions on parts)
- Config files for stats, weapon tuning, grouping, animation definitions
- Startup validator verifies ship model is correctly tagged and configured

**Success condition:** A dev who didn't build the ship can take a tagged/configured ship model, read the config, understand the full setup, and modify it (add a weapon, change a stat) without asking the original creator.

---

## Projectile System

### Architecture (Optimized for Scale)
- **Server:** simulates projectile paths using math (start position, direction, velocity, time). No physics objects. Server determines hits. All hit detection is **server-authoritative** — clients cannot fake hits.
- **Client:** renders visual-only bolt effects along the calculated path. Clients see bolts travel with correct speed and direction, but the bolt is not a replicated physics object.
- Turns each projectile from a heavy replicated object into a small set of numbers. Critical for supporting hundreds of shots per second.
- Efficient turret rotation via engine-level systems (IK Control LookAt) rather than heavy scripted rotation + replication.

### Projectile Behavior by Type
- **Lasers/Blasters/Turbolasers/Ion:** straight-line travel, config speed per weapon type, despawn at max range
- **Torpedoes:** slower projectile, straight-line toward locked target. Needs lock-on to fire.
- **Concussion missiles:** homing capability, tracks target after launch. Slower than lasers but follows target.
- **Artillery shells:** parabolic arc trajectory with configurable gravity. No lock-on — manual aim only. Server-simulated arc with per-frame collision checks. Splash damage on impact.

**Success conditions:**
- Player fires blaster: visible bolt travels from weapon to target at correct speed. Server registers hit. No physics object created.
- 50+ weapons firing simultaneously: no significant performance drop. Server tracks all paths mathematically.
- Torpedo fired without lock-on: cannot fire (requires lock). With lock: projectile travels toward locked target.

---

## Health & Damage System (Empire at War Inspired)

### Two-Layer Health
- **Shield HP:** absorbs all incoming damage first. Regenerates after a no-damage grace period.
- **Hull HP:** takes damage after shields depleted. 0 Hull HP = destroyed.
- Config-driven per platform — turrets can be hull-only, fighters can have shields, etc.

### Shield Behavior
- Shields are one unified pool (NOT directional — no front/back facing)
- Shields are **invisible** until hit — no visible bubble/shimmer around the ship
- Shield impacts show distinct visual: blue ripple/bounce effect with energy waves at the impact point
- Hull impacts show fiery explosion effect (no blue energy) — player can visually tell shields are down
- Players see shield status in HUD; 3rd person camera shows impacts on ship; distinct shield impact sounds
- Sound in space: **full audio** (Star Wars movie logic — engines, blasters, explosions all audible)
- Power routing affects shield regen rate (see Power Routing section)

### Targetable Subsystems (Larger Ships)
- Strategic targets: shield generators, hangar bays, weapon batteries, torpedo launchers, engines
- Each has its own independent HP pool, does NOT correlate with Hull HP
- Subsystems do NOT regenerate (permanent damage)
- **Pilot can see ALL subsystem health at all times** on their HUD. In 3rd person, pilot can visually see where impacts are hitting the ship.
- 0 Hull HP destroys everything regardless of subsystem state

### Subsystem Destruction Effects
| Subsystem | Effect |
|---|---|
| Shield generator | **Shields collapse entirely** — shield HP drops to 0 immediately, no regeneration possible |
| Engines | Ship slows to ~20% max speed. Cannot enter hyperspace. |
| Hangar bay | No more fighter launches or returns |
| Weapon battery | That weapon/group permanently offline |
| Torpedo launcher | No more torpedo capability |

### Damage Types (Typed Model — Lore-Accurate)
| Weapon Type | Shield Dmg | Hull Dmg | Special |
|---|---|---|---|
| Laser/Blaster | Normal | Normal | Standard workhorse, good fire rate |
| Turbolaser | High | High | Slow fire rate, capital-class |
| Ion cannon | Devastating | Minimal | Temporarily disables (stuns) subsystems. Duration config-driven. |
| Proton torpedo | Partial bypass | Very high | Slow projectile, limited ammo, needs lock-on |
| Concussion missile | Normal | Moderate | Homing, limited ammo |

### Ammo & Overheat
- **Energy weapons** (lasers, turbolasers, ion cannons) = **overheat mechanic**. Infinite ammo, fire too fast → weapon overheats → forced cooldown period.
- **Physical projectiles** (torpedoes, missiles) = **finite ammo**. No overheat. When empty, weapon is dead until rearmed (return to capital ship hangar).

Exact values config-tunable per ship per weapon.

**Success conditions:**
- Blaster hits shielded target: shield HP decreases (blue ripple VFX), hull unaffected. Shields deplete: next shot damages hull (explosion VFX). Player can visually tell the difference.
- Ion cannon hits shielded target: shield drops much faster than blaster. Hits subsystem: subsystem temporarily disabled (stun duration config-driven).
- Torpedo hits target: partially bypasses remaining shields, deals heavy hull damage.
- Shield regen: after no damage for X seconds, shields begin regenerating.
- Shield generator destroyed: shields instantly drop to 0 and never come back.
- Subsystem destroyed: specific effect activates (engines → 20% speed + no hyperspace, etc).
- Weapon overheats: forced cooldown, cannot fire until cooled.
- Torpedo ammo depleted: weapon cannot fire, player sees empty ammo count. Must rearm at hangar.

---

## Weapons System (Galaxy at War Inspired)

### Manned Weapons
- Each weapon battery manned by a player to fire
- Player enters gun via proximity prompt → camera moves to pre-defined optimal viewpoint → F to exit
- Player aims with mouse from that perspective
- Weapon grouping: multiple guns = one control group (fire pattern config-driven)
- No NPC gunners — unmanned weapons sit idle

### Pilot Weapons (Fighters)
- Pilot switches between weapon types with keybinds (1 = lasers, 2 = torpedoes, etc.)
- Fires with left click
- Each weapon type has its own overheat/ammo tracking

### Target Lock & Auto-Aim
- **Lock-on flow:** player aims at target manually → "TARGET LOCK READY" UI indicator appears → player presses keybind to engage lock → auto-aim takes over, weapons track and lead the target automatically → player left-clicks to fire
- Player can look around freely while locked on
- Auto-aim is generous but NOT 100% — misses at range, against fast targets
- Lock-on is optional — player can always aim and fire manually
- **Lock-on only works on enemy ships** — cannot lock onto friendlies
- Leading indicator bubble on HUD for manual aim assist
- Can lock onto a specific ship, then optionally cycle to target a specific subsystem

### Target Information & Scanning Station
- No built-in target info on enemy ships — no health bars visible by default
- **Scanning station** (capital ships): a dedicated bridge crew seat. Scanner operator selects an enemy ship within sensor range and initiates a scan (takes a few seconds). Reveals: hull HP %, shield HP %, subsystem status (intact/damaged/destroyed), ship class. Info appears on scanner's screen AND captain's tactical display. Info persists for a duration then goes stale (re-scan needed). Range-limited.
- Creates an intel role: "Their Star Destroyer's shield generator is down, focus fire on hull!"
- Scanning station is a later-pass feature but designed into the framework from the start

### Weapon Range
- All weapons have a maximum range (config per weapon type per ship)
- Projectiles despawn past max range
- Lock-on only available within targeting range (shorter than max weapon range)
- Lore-accurate ranges where applicable

**Success conditions:**
- Player mans a weapon, aims at target, sees "TARGET LOCK READY," presses lock keybind, auto-aim tracks target, fires, shots land near target (not 100%).
- Player fires at target beyond max range: bolt despawns before reaching it.
- Player locks onto a ship, cycles to subsystem targeting: shots aim for that subsystem.
- Player fires without lock-on: manual aim, leading indicator helps, still effective at short range.
- Fighter pilot: switches from lasers (1) to torpedoes (2), fires torpedo at locked target, switches back to lasers.
- Scanner operator scans enemy ship: info appears after scan delay, shows health/shield/subsystem status. Info goes stale after duration.

---

## Ship Ownership & Occupancy

### Ownership
- Ships and vehicles spawned via the existing shop system (buy, own forever, spawn at dealer sites)
- **Max 2 active across ships AND vehicles combined per player.** If at the limit, spawning a new one prompts the player to choose which existing one to despawn.
- Any player can sit in any unoccupied seat — no ownership lock on controls (allows fleet sharing, vehicle theft)
- Owner designation is for despawn logic only

### Occupancy & Despawn
- **Crew registry:** boarding the ship (walking through a door/ramp or sitting in a seat) adds you to the crew list. You leave the crew list when you physically exit, die, or disconnect.
- Ship persists as long as the owner is in the same server, regardless of crew count. Owner lands on Tatooine, walks away for an hour — ship stays.
- **If owner is piloting a different ship they own:** the unoccupied ship despawns on a **shorter timer** than normal (owner is clearly not using it)
- Owner leaves the server (disconnect or teleport away) AND crew count is 0 → despawn grace timer → ship removed.
- Server transfer while piloting: ship is deleted from old server, reconstructed in new server. No duplicates.

**Success condition:** Player lands ship, exits, walks far away, comes back 10 minutes later — ship is there. Player spawns second ship and flies it — first ship (empty) despawns on shorter timer. Player disconnects from server, no crew aboard second ship — it despawns after grace period.

---

## Ship Upgrades

### Philosophy
- Individual component upgrades, not flat ship levels
- **Numbers change, ship identity does not** — a TIE never becomes tanky, an ISD never becomes fast
- Creates meaningful choices (invest in firepower vs survivability)
- Upgrade tiers modify base config values for that component

### Upgrade Categories
| Category | What Improves Per Tier |
|---|---|
| **Shields** | Max shield HP, regen rate, shorter regen delay |
| **Hull/Armor** | Max hull HP, slight damage resistance |
| **Engines** | Max speed, acceleration, turn rate |
| **Weapons (energy)** | Damage, overheat threshold (fire longer), faster cooldown |
| **Weapons (ordnance)** | Torpedo/missile damage, ammo capacity, faster lock-on |
| **Sensors** | Targeting range, lock-on speed, auto-aim accuracy |

### Tier Structure
- **Max Mk III** for any category
- Some ships/categories cap at **Mk II** (defined in per-ship config)
- One bucket per category — upgrading "shields" improves all shield stats proportionally, not individual sub-stats
- Per-ship upgrade caps create ship identity even after upgrades

### Integration
- Upgrade data stored in the upgrade/shop system (separate)
- Combat framework reads upgrade-modified config values at ship spawn time
- Ship setup config defines which categories are available and max tier per ship

**Success condition:** Player upgrades shields from Mk I to Mk II on their X-wing. Next time they spawn it, shield HP and regen rate are noticeably better. Engine stats unchanged. Player tries to upgrade shields to Mk III on a ship capped at Mk II — blocked.

---

## Power Routing (All Piloted Ships)

- Applies to **all piloted ships** — fighters, transports, cruisers, capital ships
- **Squadrons-style system:** 3 systems (shields, engines, weapons), each with 8 pips. Total power budget of 12 pips.
- Default: 4/4/4 (balanced)
- Pilot redistributes freely — crank shields to 8 means engines and weapons share the remaining 4
- **Shields:** more pips = faster regen rate
- **Engines:** more pips = higher max speed
- **Weapons:** more pips = faster fire rate / reduced overheat for ALL manned weapons on the ship
- Gives pilot an active tactical role ("divert all power to shields!")

**Success condition:** Pilot starts at 4/4/4. Shifts to 8/2/2 shields. Shield regen rate visibly increases. Ship speed noticeably drops. Gunners feel slower fire rate. Pilot shifts to 2/8/2 — speed jumps, shields regen slowly, weapons still sluggish.

---

## Hangar System

- Capital ships with hangars launch fighters
- Pre-loaded with configurable number of fighter slots
- **Launching:** fighters spawn at dev-defined spawn points outside the hangar bay (not inside — avoids crashing into the ship). Player walks to a launch console/seat in the hangar, activates, screen blacks out, they spawn in the fighter outside ready to fly.
- Ideally restricted to pilot-role faction members
- Hangar is a targetable subsystem — destroyed = no more launches OR returns

### Hangar Return, Repair & Rearm
- Fighter flies close to capital ship hangar → docking prompt appears → player presses keybind → screen blacks out → fighter teleported inside hangar
- Inside hangar: fighter repairs (hull HP restored, subsystem damage repaired, shields restored) and rearms (torpedo/missile ammo refilled)
- Repair/rearm takes time (not instant, config-driven duration)
- Player waits in hangar during repair (can walk around or stay in fighter)
- Same launch process to go back out
- Adds tactical depth: retreat to rearm, or stay in the fight with what you have?

**Success conditions:**
- Player in hangar activates launch → screen blacks out → spawns in fighter outside hangar, ready to fly.
- Hangar destroyed: launch blocked, player gets message.
- Fighter flies near hangar, docking prompt, confirms → screen blacks out → inside hangar. Repair/rearm timer starts. Timer completes → fighter restored. Player launches again.
- Fighter tries to return to destroyed hangar: cannot dock.

---

## Hyperspace & Retreat

- Ships can enter hyperspace to retreat from combat at any time
- **Requirement:** engines must be functional. Destroyed engines = no hyperspace.
- Hyperspace is the existing travel system between planets — combat framework just needs to allow/block entry based on engine status.
- Space is infinite — no boundaries. Ships can fly as far as they want without hitting walls.

**Success condition:** Ship with working engines activates hyperspace — jumps away. Ship with destroyed engines tries to hyperspace — blocked, cannot escape.

---

## Ship Collisions

### Fighter Collisions
- Fighter collides with anything solid = fighter is destroyed (instant death)
- Target takes some hull damage scaled to the fighter's mass (TIE hitting a Star Destroyer = a scratch)
- Fighter hitting a small part (antenna, sensor dish) = fighter dies, subsystem/part takes damage

### Capital/Cruiser Collisions
- Repulsion field: large ships have an invisible bumper that pushes other large ships away before physical contact
- Prevents Roblox's horrible large-model collision physics from ever triggering
- No damage from large-ship proximity — just prevention

**Success condition:** Two capital ships approach each other — gently push apart, no physics jank. Fighter flies into cruiser — fighter explodes, cruiser takes minor hull damage.

---

## Ship Destruction

- Explosion points pre-placed on each model (min 3, more on larger ships)
- Sequence: explosions at pre-set points → large final explosion masks despawn → model removed
- No persistent debris/wreckage
- All players inside instantly die (no special death cam — just death)
- Respawning handled by separate spawn system

**Success condition:** Ship reaches 0 hull HP. Explosions fire sequentially at pre-placed points. Final big explosion, ship disappears. All players inside are dead.

---

## Ship Scale

### Base Reference
- Player character = 5 studs tall ≈ 2 meters → **1 meter = 2.5 studs**

### Tiered Scale Convention
Fighters stay true to lore. Larger ships progressively compress to keep capital ships within Roblox's rendering and engagement distance limits while still feeling massive.

| Class | Scale Factor | Example | Lore Size | In-Game Size |
|-------|-------------|---------|-----------|-------------|
| Fighter | 1:1 (2.5 st/m) | X-wing | 12.5m | ~31 studs |
| Transport | 1:1 (2.5 st/m) | Millennium Falcon | 34m | ~85 studs |
| Cruiser | 1:1.5 | Nebulon-B Frigate | 300m | ~500 studs |
| Capital | 1:2 | Star Destroyer | 1,600m | ~2,000 studs |

- Scale factor is per-ship config — individual ships can be tuned within their class range
- Fighters and transports at true scale preserves cockpit/interior proportions relative to players
- Capital ships at 1:2 are still enormous (2,000 studs = 4x default baseplate length) but keep engagement distances under ~5,000 studs where ships remain visible as 3D objects
- Distant ships beyond visual range use **targeting UI markers/icons** for battlefield awareness
- Performance depends on **part count per ship**, not stud dimensions — a 2,000-stud ship with 80 MeshParts performs fine; the same ship built from 3,000 parts does not
- Exact scale validated empirically during fighter pass (pass 9) — if performance issues appear at these scales, compress further

---

## Edge Cases & Abuse

| Scenario | Behavior |
|---|---|
| Friendly fire | No. Weapons cannot damage same-faction entities. |
| Friendly lock-on | No. Lock-on only works on enemy ships. |
| Boarding enemy ships | No designed mechanic. Emergent only. |
| Ramming (fighters) | Fighter dies, target takes minor hull damage. |
| Ramming (large ships) | Repulsion field prevents contact. |
| Spawn camping hangars | No system protection — tactical problem for fleets to solve. |
| Player disconnect (pilot) | Ship drifts, another crew member can take pilot seat. |
| Player disconnect (owner, no crew) | Despawn after grace timer. |
| Player disconnect (owner, crew aboard) | Ship stays, crew keeps operating. |
| Solo capital ship | Flies fine, zero firepower. Their problem. |
| All crew dead but ship intact | Ship drifts until owner status triggers despawn or someone boards. |
| Capital ship destroyed with docked fighters | Fighters inside destroyed. Players inside die. |
| Kill credit / scoring | None. Victory is faction-based mission completion. |
| Ship spam (player spawns many) | Max 2 active ships. Unoccupied ship despawns faster if owner is in another ship. |
| Accidental server transfer | Atmosphere boundary requires confirmation prompt — no accidental teleports. |

---

## Fleet Mechanics (Late Passes — Not Committed)

### Formation Autopilot
- Intelligent autopilot, NOT welds
- Escort ships maintain relative position to flagship via maneuvering (turn, accelerate, reposition, match heading)
- Cut if performance cost too high

### Tractor Beams
- Gravitational pull toward source ship's hangar
- Enables blockades / ship capture
- Escape mechanics TBD
- Late pass

---

## Server Architecture (SEPARATE SYSTEM)

- Per-planet servers, likely space/ground split per planet
- Global chat, cross-server data transfer (ship state, inventory, passengers, cargo)
- Separate system — noted here because it affects performance budget
- Combat framework just needs to work within a single server
- Space-to-ground transition handled via atmosphere landing zones (see Landing Zones)

---

## Security

- All combat-critical logic is **server-authoritative**: hit detection, damage calculation, health/shield values, subsystem status, power routing effects, despawn logic
- Clients only render visuals (projectile bolts, VFX, UI)
- Clients cannot fake hits, inflate damage, or manipulate health values

---

## Scale & Performance

- Up to 100 players per server
- 30+ ships active simultaneously
- Hundreds of blaster shots per second
- All ships player-operated (no NPC ships or crews)
- Math-based projectile simulation (no physics objects for projectiles)
- Math-based ship movement (anchored models, CFrame positioning, no Roblox physics engine for large ships)
- Efficient turret rotation via engine-level systems (IK Control LookAt) rather than heavy scripted rotation
- Object pooling, LOD, network culling
- Full audio in space (Star Wars movie logic)
- This is the hardest constraint and shapes every decision

---

## UI Summary

| Context | Elements |
|---|---|
| Gunner (turret/ship weapon) | Crosshair, overheat display, ammo count (physical weapons), leading indicator bubble, "TARGET LOCK READY" prompt, lock-on indicator, own weapon subsystem health |
| Artillery operator | Elevation angle (degrees), heading (degrees), estimated range (studs). No crosshair, no lock-on. Ammo count, reload indicator. |
| Pilot (fighter) | Hull HP, shield status, speed, weapon selector (1/2/3), weapon overheat/ammo, power routing (3 bars, 8 pips, 12 budget), 3rd person view |
| Pilot (cruiser/capital) | Hull HP, shield status, speed, power routing interface, **all subsystem health visible at all times**, 3rd person pulled back |
| Scanner operator | Scan target selector, scan progress, scanned ship info (hull/shield/subsystem status) |
| Vehicle driver | Hull HP, shield status (if applicable), speed. No weapon controls (unless pilot-fired). 3rd person. |
| Vehicle gunner | Same as turret gunner — crosshair, overheat, ammo, lock-on. Camera at weapon viewpoint. |
| Passenger | Minimal — maybe ship/vehicle health |
| All ship contexts | Targeting UI markers/icons for distant ships on the battlefield |

---

## Integration with Existing Systems

| System | Integration |
|---|---|
| Blaster system | Visual match (bolt style, feel). Shared projectile rendering where possible. |
| Vehicle system | **Custom-built from scratch** (existing system scrapped). Full vehicle idea locked in vehicle-idea-locked.md. Shares architecture with ships. |
| Faction system | Warfare, navy organization, crew roles, pilot restrictions. Mission-based victory. |
| Spawn system | Handles respawning after death. Separate. |
| Shop system | Ships bought/spawned via shop. Separate. |
| Upgrade system | Component upgrades modify combat framework config values. Tier structure defined above. |

---

## Platforms (Build Order)

1. **Static ground turret** — combat framework foundation (weapons, math-based projectiles, damage types, targeting, health)
2. **Armed ground vehicle (speeders)** — custom hover physics, CFrame velocity system
3. **Artillery emplacement** — indirect fire, parabolic projectiles, WASD aiming
4. **Armed ground vehicle (walkers)** — IK procedural legs, head-mounted weapons
5. **Starfighter** — flight physics + combat framework + landing zones + relative motion + power routing
6. **Capital ship** — multi-seat, subsystems, hangars (launch + return + repair/rearm), weapon grouping, power routing, scanning station, full scale

---

## Open Questions

None. Idea locked by user approval.
