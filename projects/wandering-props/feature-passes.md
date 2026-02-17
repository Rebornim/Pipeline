# Feature Passes: Wandering Props

**Based on:** idea-locked.md
**Date:** 2026-02-14

---

## Pass 1: Bare Bones Core Loop
**What it includes:**
- R15 rigs with AnimationController + Animator (no Humanoid)
- Runtime model discovery from `ReplicatedStorage.WanderingPropModels`
- Node-based waypoint graph using **waypoint spots only** (exact positions)
- Server computes routes: spawn point → chain of waypoint spots → despawn point
- Client-side CFrame interpolation movement
- Walk + idle animations (walk speed scales with movement speed)
- Ground-snap raycasts (ignore tagged nav parts + hit characters)
- Per-NPC walk speed variation
- Anti-backtracking (no immediate reversal on same edge)
- No collision with players or other NPCs
- Population controller: configurable min/max, spawn/despawn at designated hidden points
- Late-joining player sync (receive all active NPC states on join)
- Config module with: population limits, base walk speed + variation range, spawn/despawn rate

**After this pass, the system:**
NPCs spawn at hidden spawn points, walk along a waypoint graph with slight speed variation, and despawn at hidden despawn points. Population stays within configured min/max. Players joining mid-game see all existing NPCs immediately. Movement is smooth with ground snapping. This is the core loop — spawn, walk, despawn, repeat.

---

## Pass 2: Points of Interest
**Depends on:** Pass 1
**What it includes:**
- **Scenic POI:** NPC stops, faces a configurable view zone part, plays idle animation for a random dwell duration, then continues
- **Busy POI:** NPC walks through without stopping (creates higher foot traffic areas)
- **Social POI:** Pre-placed seats grouped into tables/benches. NPCs claim a seat, play sit animation for a random dwell duration, then leave. Social weighting (prefer tables with existing sitters). Configurable capacity cap per POI for seat turnover. Skip if no seats available.
- POI templates — Studio-placeable parts configured via attributes
- Route planning changes: spawn → 2–4 POIs (selected by weight) → despawn point
- POI weight config per instance for density control
- Stuck NPC handling: can't reach POI → attempt despawn point instead; truly stuck → despawn in place
- Dead-end backtracking fallback (allowed on POI/despawn route legs so endpoint nodes stay routable)
- Config additions: POI weights, dwell time ranges (scenic + social), social vs. solo seating weight, social capacity cap percentage

**After this pass, the system:**
NPCs follow purposeful routes through the world. They stop to admire scenic views, create foot traffic through busy areas, and sit together at social spots (preferring company). Routes feel intentional rather than random. Stuck NPCs are handled gracefully without breaking the system.

---

## Pass 3: Organic Movement & Day/Night
**Depends on:** Pass 1, 2
**What it includes:**
- **Waypoint zones:** Area-based nodes where NPCs pick a random point within the zone boundary (complementing the exact-position waypoint spots from Pass 1)
- **Random wandering:** At random intervals mid-route, NPC deviates to a nearby off-path node then resumes its route. Reachability validation — tries two random spots, if neither reachable, continues normally.
- **Day/night cycle hook:** Optional integration point for games with day/night systems. Night = reduced population via configurable multiplier. Works without a day/night cycle (constant population by default).
- Config additions: random wander chance, day/night toggle + night population multiplier

**After this pass, the system:**
Movement feels organic and varied. NPCs don't follow identical paths — waypoint zones create spatial variation, random wandering adds spontaneity. Games with day/night cycles see quieter nighttime streets. The world feels alive and unpredictable.

---

## Pass 4: Optimization
**Depends on:** All previous passes
**What it includes:**
- **LOD tiers** based on distance from local player:
  - `near`: full movement + full animation
  - `low`: full movement + reduced animation frame rate
  - `mid`: movement updates, animation stops
  - `far`: model hidden/unparented, route timing continues server-side
- Model pooling / recycling for spawn/despawn transitions
- Any additional performance tuning needed to hit the **70 NPC target**
- Profiling and benchmarking pass

**After this pass, the system:**
Same behavior as before, but runs smoothly at 70 concurrent NPCs. Distant NPCs cost almost nothing. Models are recycled efficiently instead of created/destroyed.

---

## Pass 5: Visual Polish
**Depends on:** All previous passes
**What it includes:**
- **Corner beveling (curved pathing):** Client-side path smoothing that rounds sharp waypoint corners into natural curves. NPCs follow quadratic Bezier arcs at turns instead of sharp zigzag lines. POI stop waypoints and spawn/despawn endpoints are protected (not beveled).
- **Smooth elevation transitions:** Ground-snap raycast results are lerped over time instead of applied instantly. Steps and slopes produce smooth height changes instead of snapping.
- **Smooth body rotation:** NPC facing direction is slerped each frame instead of snapping via `CFrame.lookAt`. Applies to route walking turns, scenic POI facing, and seat walk-in/walk-out.
- **Head look toward player:** NPCs randomly turn their heads to track nearby players. Smooth Motor6D neck rotation with yaw/pitch clamping. LOD-gated to near tier only.
- **Path lateral offset:** Server-side random perpendicular offset on intermediate waypoints so NPCs don't follow identical ant-trail paths between the same waypoints.
- **Spawn/despawn fade:** Client-side transparency lerp for smooth appear/disappear transitions. Fade-in on spawn, fade-out when route completes. Pool-aware (transparency restored on pool release).
- Config additions: bevel radius/segments, ground snap lerp speed, turn lerp speed, head look distance/chance/duration/limits, lateral offset max, fade durations

**After this pass, the system:**
NPCs move with natural, polished motion. Corners are rounded, elevation changes are smooth, turns are gradual. NPCs occasionally glance at passing players. No two NPCs follow identical paths. Spawning and despawning is graceful with fade transitions. The world feels alive and believable.

---

## Pass 6: Internal POI Navigation (Built)
**Depends on:** Pass 2, 5
**What it includes:**
- Internal waypoint graphs within social and scenic POIs for complex interior layouts, with BFS/Dijkstra pathfinding.
- Seat accessibility constraints via AccessPoint ObjectValues or distance-based matching to internal waypoints.
- Multi-entrance support: multiple internal entry nodes can link to different external graph nodes. NPCs path to the closest entrance.
- Scenic POI stand point collections: multiple zone-sized stand positions, randomly selected per visit with internal routing.
- POIs can be authored without a dedicated Waypoint part — internal entry links to external graph nodes define the POI's graph presence.
- Single config toggle: `InternalNavigationEnabled`.
- Server-side waypoint expansion bakes approach/exit paths into the flat waypoints array. Client processes expanded array identically.

**After this pass, the system:**
Social and scenic POIs work in complex interiors. NPCs navigate through interior waypoint paths to reach seats or stand points, and exit via valid internal routes. Multi-entrance POIs route NPCs to the closest door. POI authoring is flexible — no dedicated waypoint part required when internal entries link to the graph.

---

## Pass 7 (Candidate): Market POI Type
**Depends on:** Pass 6
**What it includes:**
- **New POI type: `market`** — indoor/outdoor marketplace with authored stands
- NPCs enter a market, visit a random number of stands (`MarketStandsMin` to `MarketStandsMax`), browse at each, then leave
- **No sitting** — standing dwell only. NPCs stand in front of stands within a zone-sized StandZone part
- Each stand has a **ViewTarget** part that the NPC faces while browsing
- **Head scanning behavior:** NPC's head smoothly sweeps across the ViewTarget part's bounds while dwelling at a stand. HeadLookController (player tracking) takes priority and interrupts scanning
- Uses Pass 6 internal waypoint navigation for pathfinding between stands
- **No main Waypoint part** — internal entry nodes link directly to external graph nodes (leverages Pass 6 generalized POI discovery)
- **Capacity per stand:** configurable max NPCs browsing one stand simultaneously (`MarketStandCapacity`)
- StandZone is zone-sized — random XZ positioning supports multiple NPCs at the same stand
- Stands auto-link to closest internal waypoint by distance (no AccessPoint ObjectValue needed)
- Authoring layout:
  ```
  MarketPOI_Bazaar/
  ├── InternalWaypoints/
  │   ├── IW_Entry (ObjectValue → external graph node)
  │   ├── IW_Aisle1 (ObjectValue → IW_Entry)
  │   └── IW_Aisle2 (ObjectValue → IW_Aisle1)
  ├── Stands/
  │   ├── Stand1/
  │   │   ├── StandZone (BasePart, zone-sized)
  │   │   └── ViewTarget (BasePart)
  │   └── Stand2/
  │       ├── StandZone (BasePart)
  │       └── ViewTarget (BasePart)
  ```

**Open design questions (to resolve before design phase):**
1. Dwell time per stand — configurable range (`MarketBrowseDwellMin` / `MarketBrowseDwellMax`)?
2. Stand visit order — nearest-first or fully random?
3. All stands at capacity — visit whatever's available and leave, or skip market entirely?
4. Repeat visits — can one NPC visit the same stand twice in one trip?
5. Head scan style — continuous slow sweep or random point jumps across ViewTarget?

**After this pass, the system:**
NPCs browse marketplace stands naturally. They enter a market, wander between stands via internal waypoints, stop to look at merchandise with smooth head scanning, then move on. Markets feel busy and alive with multiple NPCs browsing different stands simultaneously.

---

## Pass 8 (Candidate): External Behavior API
**Depends on:** Pass 4 (spawn queues, batch remotes), Pass 7 (market claims)
**What it includes:**
- **New public API module: `WanderingPropsAPI`** — the only surface other game systems interact with
- **Priority-based behavior modes:** Normal (0), Pause (10), Evacuate (20), Scatter (30). Higher priority overrides lower. Only one mode active at a time.
- **Mode effects (v2 — simplified):** spawn pausing, population cap override, incremental drain rate control. Modes never modify in-flight NPC routes or speed — drain uses the existing `trimRouteForNightDrain` function incrementally.
- **Built-in debounce:** re-triggers of the same mode within `ModeRetriggerCooldown` are silently ignored (cheap — one number comparison)
- **Mode expiry with fallback:** modes have a duration. When the highest-priority mode expires, system falls back to next highest active mode, or normal.
- **Scatter = fast incremental drain** (batch 8, check every 1s) vs evacuate = normal drain (batch 3, check every 2s). No in-flight speed changes.
- **Per-player client desync:** server stops sending NPC data to a specific player. Client wipes all NPCs instantly. Resync sends a bulk sync to repopulate.
- **Shared state module: `PopulationHooks`** — bridges API module and PopulationController (avoids require-cycle since server scripts can't be required)
- **One new RemoteEvent:** `NPCDesync` (desync/resync toggle per player)
- Config additions: `ModeRetriggerCooldown`, `EvacDrainBatchSize`, `EvacDrainCheckInterval`, `ScatterDrainBatchSize`, `ScatterDrainCheckInterval`

**After this pass, the system:**
Other game systems can tell NPCs what to do. A gunshot triggers scatter mode — spawning pauses and NPCs drain to despawn points in large batches, clearing the area quickly. A cutscene triggers pause mode — no new NPCs spawn but current ones finish naturally. A performance spike triggers client desync — that player's NPC rendering stops entirely until resynced. Modes stack by priority so a scatter during a pause still scatters. Everything has built-in debounce so rapid re-triggers are free. No timeline instability — modes never modify in-flight NPC routes or speed.

---

## Feature Coverage Check

All features from idea-locked.md assigned (Passes 1-4). Pass 5 extends beyond the original spec:
| Feature | Pass |
|---|---|
| R15 rigs, AnimationController, no Humanoid | 1 |
| Runtime model discovery | 1 |
| Walk + idle animations | 1 |
| Sit animation | 2 |
| No collision | 1 |
| Waypoint spots | 1 |
| Waypoint zones | 3 |
| Server routes, client movement | 1 |
| Walk speed variation + animation scaling | 1 |
| Ground-snap raycasts | 1 |
| Anti-backtracking + dead-end fallback | 1 (basic), 2 (POI fallback) |
| Random wandering | 3 |
| Scenic POI | 2 |
| Busy POI | 2 |
| Social POI (seats, weighting, capacity) | 2 |
| POI templates | 2 |
| Population controller | 1 |
| Spawn/despawn points | 1 |
| Route: 2–4 POIs → despawn | 2 |
| POI weights | 2 |
| Stuck NPC handling | 2 |
| Late-joining player sync | 1 |
| Day/night cycle hook | 3 |
| LOD tiers | 4 |
| All config surface items | Accumulated 1–4 |
| Corner beveling (curved pathing) | 5 |
| Smooth elevation transitions | 5 |
| Smooth body rotation | 5 |
| Head look toward player | 5 |
| Path lateral offset | 5 |
| Spawn/despawn fade | 5 |
| Internal POI waypoint graphs (social + scenic) | 6 |
| Multi-entrance POI support | 6 |
| Scenic stand point collections | 6 |
| No-main-waypoint POI authoring | 6 |
| Market POI type (stands, browsing, head scanning) | 7 (candidate) |
| External behavior API (modes, client desync) | 8 (candidate) |
