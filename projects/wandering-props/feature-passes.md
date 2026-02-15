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

## Feature Coverage Check

All features from idea-locked.md assigned:
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
