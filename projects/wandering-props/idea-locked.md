# Wandering Props — Locked Idea

## Purpose
Ambient NPC system that makes game worlds feel alive. NPCs wander, visit points of interest, and sit at social areas. Purely visual — no player interaction, no combat, no health. Designed as a **configurable product for sale** on the Creator Marketplace.

**Performance target:** 70 NPCs running smoothly.

---

## NPC Rigs & Visuals
- R15 rigs with AnimationController + Animator, **no Humanoid**
- 14 pre-built NPC models, randomly selected at spawn
- Animations: walk, idle, sit
- No collision with players or other NPCs
- No sound (v1)
- Not killable — no health system

## Movement System
- **Node-based waypoint graph** — no PathfindingService
- Two node types:
  - **Waypoint zones:** Area-based. NPC picks a random point within the zone boundary.
  - **Waypoint spots:** Precise position. NPC walks to exact point.
- **Server decides routes, clients handle movement and animation locally** to minimize replication overhead
- Slight walk speed variation per NPC for natural feel
- **Random wandering:** At random intervals mid-route, an NPC may deviate to a nearby off-path node, then resume its route. Validates reachability before committing — tries two random spots, if neither reachable, continues normal route.

## Points of Interest (3 types)

### Scenic POI
- NPC stops and faces a configurable "view zone" part
- Plays idle animation for a random duration (configurable range)
- Then moves on

### Busy POI
- NPC walks through without stopping
- Creates areas of higher foot traffic

### Social POI
- Pre-placed seats grouped into tables/benches
- NPCs prefer tables with existing NPCs sitting (weighted chance — more likely to be social, can also sit alone)
- NPC claims a seat, plays sit animation for a random duration (configurable range), then leaves
- Configurable capacity cap per POI to ensure seat turnover
- If no seats available, NPC skips the POI and continues route

Each POI type has a **template** — a pre-built part buyers place in Studio and configure via attributes/config.

## Population Controller
- Central server script managing NPC population
- Configurable min/max population
- NPCs spawn at designated **spawn points** (hidden from view — e.g., inside buildings)
- NPCs despawn at designated **despawn points** (also hidden)
- Each NPC spawns with a route: 1–3 POIs (selected by weight), then walks to a despawn point
- POI weights create natural density — more popular POIs attract more NPCs

## Group Spawning
- Configurable chance for a group (2–4 NPCs) to spawn together
- Groups share a route and walk in formation (leader-follower with offsets so they look like an intentional group, not NPCs that happen to be walking together)
- Uncommon compared to solo NPCs (configurable ratio)

## Day/Night Cycle (Optional)
- Configurable hook for games with day/night systems
- At night: reduced population (configurable multiplier)
- Works without a day/night cycle — constant population by default

## Stuck NPC Handling
- NPC can't reach a POI → attempts to reach a despawn point instead
- NPC truly stuck (can't reach any despawn point) → despawns in place

## Late-Joining Players
- On join, client receives current state of all active NPCs (position, current destination, progress along route) and syncs up

## Edge Cases & Abuse
- No player interaction = minimal abuse surface
- No collision = no physics exploits
- Social POI capacity cap prevents permanently full tables
- Node graph keeps NPCs on valid paths (no walking through walls)
- Misconfigured node graph (dead ends, disconnected nodes) handled by stuck-NPC despawn logic
- Players cannot push, block, or interfere with NPCs in any way

## Integration
- Fully isolated system. No dependencies on other game systems.
- Only external connection: optional day/night cycle hook via config

## Key Design Decisions (established in Phase 1)
These were discussed and decided during idea validation. Phase 2 should build on these, not re-litigate them:

- **No Humanoid** was chosen specifically for performance at 70 NPCs. Humanoid replication, state machines, and physics are too expensive at that scale. AnimationController + Animator on R15 rigs is the approach.
- **Client-side movement** is essential for 70 NPCs. Server sends route data (node IDs, timing). Clients handle CFrame interpolation and animation playback locally. This eliminates replication overhead. Slight desync between players is acceptable for ambient NPCs.
- **Node-based movement over PathfindingService** because: (a) PathfindingService is too expensive for 70 NPCs, (b) node-based gives product buyers artistic control over NPC paths, (c) it's deterministic and predictable across any map geometry including multi-level.
- **Walk animation speed should scale with movement speed** so feet don't slide (NPCs have slight speed variation).
- **User has minimal Luau/Roblox scripting knowledge.** The technical burden is on the architect and Codex. Architecture must be clear enough for Codex to build without ambiguity.

## Config Surface (all buyer-configurable)
- Min/max population
- NPC model list
- Base walk speed + variation range
- POI weights (per POI instance)
- Group spawn chance + group size range (2–4)
- Dwell time ranges for scenic and social POIs
- Social POI capacity cap (percentage)
- Social vs. solo seating weight
- Random wander chance
- Day/night toggle + night population multiplier
- Spawn/despawn rate
