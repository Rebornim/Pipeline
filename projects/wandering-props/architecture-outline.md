# Architecture Outline: Wandering Props

**Based on:** idea-locked.md
**Critic Status:** APPROVED
**Date:** 2026-02-12

---

## File Organization

```
src/
├── shared/
│   ├── Config.luau          -- All tunable gameplay values
│   └── Types.luau           -- Shared type definitions (route steps, NPC data)
├── server/
│   ├── PopulationController.server.luau  -- Main server script: lifecycle, spawn/despawn timing
│   ├── NodeGraph.luau                    -- Loads tagged Parts from workspace, builds adjacency graph, BFS pathfinding
│   ├── RouteBuilder.luau                 -- Builds NPC routes: spawn → POIs → despawn, wander deviations
│   ├── SeatManager.luau                  -- Time-based seat reservations for Social POIs
│   └── NPCRegistry.luau                 -- Tracks all active NPCs: routes, timing, groups, sync data
├── client/
│   ├── NPCClient.client.luau            -- Main client script: listens to RemoteEvents, manages NPC lifecycle
│   ├── NPCMover.luau                    -- CFrame interpolation on Heartbeat, moves NPCs along route
│   ├── NPCAnimator.luau                 -- Animation loading, playback, walk speed scaling
│   └── ModelPool.luau                   -- Pools and recycles NPC model clones
```

| File | Location | Purpose |
|------|----------|---------|
| `Config.luau` | shared/ | Every tunable gameplay value with defaults and comments |
| `Types.luau` | shared/ | Type definitions shared by server and client (RouteStep, NPCSyncData) |
| `PopulationController.server.luau` | server/ | Main server script. Manages NPC population: periodic spawn/despawn, day/night scaling, creates RemoteEvents on startup |
| `NodeGraph.luau` | server/ | Server ModuleScript. On `init()`: reads all CollectionService-tagged Parts, builds adjacency list from ObjectValue children. Exposes `getPath(fromNode, toNode)` via BFS, `getNearbyNodes(node, maxHops)`, `getRandomPointInZone(node)`, `getAllByTag(tag)` |
| `RouteBuilder.luau` | server/ | Server ModuleScript. `buildRoute(spawnNode, poiCount)`: selects POIs by weight, finds paths between them via NodeGraph, optionally injects wander deviations, appends despawn. `buildGroupRoute(spawnNode, poiCount, groupSize)`: builds a shared route, then derives follower routes with lateral offsets |
| `SeatManager.luau` | server/ | Server ModuleScript. Time-based seat reservation system. `reserveSeat(socialPOI, arrivalTime, duration)` → returns seat Part or nil. `releaseSeat(npcId)`. Respects capacity cap and social-weight preference (prefer tables with existing occupants) |
| `NPCRegistry.luau` | server/ | Server ModuleScript. Stores all active NPC state. `register(npcData)`, `unregister(npcId)`, `getAll()`, `getSyncDataForPlayer()` — computes current position/state from timing for late-join sync |
| `NPCClient.client.luau` | client/ | Main LocalScript. Connects to `WP_SpawnNPC`, `WP_DespawnNPC`, `WP_SyncState` RemoteEvents. Delegates to NPCMover/NPCAnimator/ModelPool. Runs main update loop on Heartbeat |
| `NPCMover.luau` | client/ | Client ModuleScript. `startRoute(npc, route, speed)`: begins stepping through route. `update(dt)`: called each Heartbeat, advances all active NPCs via CFrame lerp. Handles walk/idle/sit/despawn step types |
| `NPCAnimator.luau` | client/ | Client ModuleScript. `setup(model)`: loads walk/idle/sit AnimationTracks from IDs in Config. `playWalk(npc, speed)`: plays walk animation scaled to movement speed. `playIdle(npc)`, `playSit(npc)`, `stopAll(npc)` |
| `ModelPool.luau` | client/ | Client ModuleScript. Pre-clones NPC models from ReplicatedStorage. `acquire(modelIndex)` → returns a Model, `release(model)` → returns it to pool. Avoids clone/destroy churn for 70 NPCs |

---

## Roblox APIs Used

- **CollectionService:** Server reads tagged workspace Parts to discover nodes, spawn points, despawn points, and POIs at startup. Tags: `WP_Waypoint`, `WP_Spawn`, `WP_Despawn`, `WP_Scenic`, `WP_Busy`, `WP_Social`, `WP_Seat`
- **ReplicatedStorage:** Stores NPC model templates (Folder: `WanderingPropModels`) and RemoteEvents (Folder: `WanderingPropsRemotes`, created by server at startup)
- **RemoteEvents:** 3 events for server→client communication (see Script Communication Map)
- **RunService.Heartbeat (client):** Drives NPC movement interpolation each frame
- **Animator / AnimationController:** Each NPC model has AnimationController → Animator. Client loads AnimationTracks and controls playback
- **task library:** `task.wait()`, `task.spawn()`, `task.delay()` for all async operations (no deprecated `wait()`/`spawn()`/`delay()`)
- **Lighting.ClockTime:** Read by server for optional day/night population scaling

**NOT used (by design per Phase 1):**
- PathfindingService (too expensive at 70 NPCs, replaced by node graph)
- Humanoid (too expensive, replaced by AnimationController + manual CFrame movement)
- TweenService (CFrame lerp in Heartbeat is simpler and gives frame-by-frame control)

---

## Script Communication Map (Critical for Phase 3)

### RemoteEvents (Server → Client only, no client→server traffic)

| Event Name | Direction | Payload | When Fired |
|------------|-----------|---------|------------|
| `WP_SpawnNPC` | Server → All Clients | `SpawnPayload` (see Data Structures) | When server spawns a new NPC |
| `WP_DespawnNPC` | Server → All Clients | `{ id: string }` | When server despawns an NPC (reached despawn point or stuck) |
| `WP_SyncState` | Server → Single Client | `{ npcs: { [string]: SyncNPCData } }` | When a player joins (FireClient to that player only) |

**Zero client→server RemoteEvents.** This system is purely visual with no player interaction. Clients have no reason to send anything to the server. This eliminates the entire attack surface.

### ModuleScript Dependencies

**Server-side:**
- `PopulationController.server.luau` requires: `Config`, `Types`, `NodeGraph`, `RouteBuilder`, `SeatManager`, `NPCRegistry`
- `NodeGraph.luau` requires: `Config` (for tag name constants)
- `RouteBuilder.luau` requires: `Config`, `Types`, `NodeGraph`, `SeatManager`
- `SeatManager.luau` requires: `Config`, `Types`
- `NPCRegistry.luau` requires: `Config`, `Types`

**Client-side:**
- `NPCClient.client.luau` requires: `Config`, `Types`, `NPCMover`, `NPCAnimator`, `ModelPool`
- `NPCMover.luau` requires: `Config`, `Types`
- `NPCAnimator.luau` requires: `Config`
- `ModelPool.luau` requires: `Config`

**Cross-boundary (RemoteEvent only):**

```
PopulationController ──WP_SpawnNPC──→ NPCClient
PopulationController ──WP_DespawnNPC──→ NPCClient
PopulationController ──WP_SyncState──→ NPCClient (per-player on join)
```

### Full Dependency Graph

```
shared/Config ←── (everything requires this)
shared/Types  ←── (server + client modules require this)

Server side:
  NodeGraph ← RouteBuilder ← PopulationController
  SeatManager ← RouteBuilder        ↑
  NPCRegistry ←────────────── PopulationController

Client side:
  ModelPool  ← NPCClient
  NPCMover   ← NPCClient
  NPCAnimator ← NPCClient

Cross-boundary:
  PopulationController ──[RemoteEvents]──→ NPCClient
```

---

## Data Flow

### Flow 1: NPC Spawn (Steady State)

1. **Server (PopulationController):** Spawn timer fires. Checks `currentPopulation < targetPopulation`.
2. **Server (PopulationController):** Decides solo vs group spawn (weighted by `GROUP_SPAWN_CHANCE`).
3. **Server (RouteBuilder):** Builds route — picks random spawn node, selects 1–3 POIs by weight, finds BFS paths between nodes, resolves zone positions, injects wander deviations, selects despawn node. For Social POIs, calls SeatManager to reserve seats.
4. **Server (NPCRegistry):** Registers NPC with full route data + pre-computed step timestamps.
5. **Server (PopulationController):** Fires `WP_SpawnNPC:FireAllClients(spawnPayload)`.
6. **Client (NPCClient):** Receives event. Calls `ModelPool.acquire(modelIndex)` to get a model.
7. **Client (NPCClient):** Positions model at route[1].position. Calls `NPCMover.startRoute(npc, route, speed)` and `NPCAnimator.playWalk(npc, speed)`.
8. **Client (NPCMover):** Each Heartbeat: lerps NPC CFrame toward current target. When target reached, advances to next route step, triggers appropriate animation via callback.
9. **Client (NPCMover):** When final step (action="despawn") reached, fires a callback. NPCClient calls `NPCAnimator.stopAll(npc)`, `ModelPool.release(model)`.

### Flow 2: NPC Despawn (Server-Driven)

1. **Server (PopulationController):** Periodic check. For each NPC, compares `tick()` against pre-computed total route duration (`spawnTime + totalDuration`).
2. **Server:** When NPC should have reached despawn: fires `WP_DespawnNPC:FireAllClients({ id = npcId })`, calls `NPCRegistry.unregister(npcId)`, calls `SeatManager.releaseSeat(npcId)`.
3. **Client (NPCClient):** Receives despawn event. If NPC still exists locally (client might have already cleaned up from reaching end of route), destroys it and returns model to pool.

**Why both client and server track despawn:** The client executes the route and cleans up when done. The server tracks timing and sends a despawn event as the authoritative signal. The client handles both: its own route-end cleanup AND the server's despawn event (whichever comes first). This handles clock skew gracefully.

### Flow 3: Late-Joining Player Sync

1. **Server (PopulationController):** Listens for `Players.PlayerAdded`.
2. **Server (NPCRegistry):** `getSyncDataForPlayer()` iterates all active NPCs. For each NPC, calculates current state from timing: which route step they're on, their approximate current position (lerped from step timing), time remaining on current action.
3. **Server:** Fires `WP_SyncState:FireClient(player, syncData)`.
4. **Client (NPCClient):** Receives sync. For each NPC in payload: acquires model, positions at `currentPosition`, starts executing `remainingRoute` from current action state.

### Flow 4: Group Spawn

1. **Server (PopulationController):** Group roll succeeds. Picks group size (2–4 from config).
2. **Server (RouteBuilder):** `buildGroupRoute(spawnNode, poiCount, groupSize)`:
   - Builds one leader route normally.
   - For each follower: copies the leader route but offsets each position perpendicular to the path direction. Offset magnitude from Config (`GROUP_FOLLOWER_OFFSET`).
3. **Server:** Assigns a shared `groupId` to all members. Fires `WP_SpawnNPC` for the leader immediately. For each follower, uses `task.delay(Config.GROUP_FOLLOWER_DELAY * followerIndex, ...)` to stagger the `WP_SpawnNPC` events. This staggers both the network traffic and the client-side model clones.
4. **Client:** Spawns each member independently as events arrive. Group members have offset positions baked into their routes, so they naturally walk in formation. The staggered spawn timing creates a natural trailing effect.

### Flow 5: Social POI Interaction

1. **Server (RouteBuilder):** Route includes a Social POI. Calls `SeatManager.reserveSeat(poi, estimatedArrivalTime, dwellDuration)`.
2. **SeatManager:** Checks available seats at estimated time. Applies social weight (prefer seats at tables with other reservations in the same time window). Checks capacity cap. Returns a seat Part or nil.
3. If seat returned: route step is `{ action = "sit", position = seatPart.Position, sitCFrame = seatPart.CFrame, duration = dwellDuration }`. If nil: POI is skipped, route continues to next waypoint.
4. **Client (NPCMover):** When reaching a "sit" step: walks NPC to `position`, then sets model CFrame to `sitCFrame`. NPCAnimator plays sit animation for `duration` seconds, then stops sit, plays walk, continues route.

---

## Data Structures

```lua
-- Types.luau

-- Actions an NPC can perform at a route step
export type Action = "walk" | "idle" | "sit" | "despawn"

-- A single step in an NPC's route
export type RouteStep = {
    position: Vector3,      -- world position to walk to
    action: Action,         -- what to do when arriving
    duration: number?,      -- seconds to idle/sit (nil for walk/despawn)
    faceCFrame: CFrame?,    -- for scenic idle: face this direction
    sitCFrame: CFrame?,     -- for sit: exact seated CFrame
}

-- Payload sent via WP_SpawnNPC RemoteEvent
export type SpawnPayload = {
    id: string,             -- unique NPC identifier (e.g., "npc_42")
    modelIndex: number,     -- 1-based index into Config.NPC_MODELS
    speed: number,          -- walk speed in studs/sec (base + variation)
    route: { RouteStep },   -- ordered steps from spawn to despawn
    groupId: string?,       -- shared ID for group members, nil for solo
}

-- Per-NPC data stored in NPCRegistry (server only)
export type NPCRecord = {
    id: string,
    modelIndex: number,
    speed: number,
    route: { RouteStep },
    stepTimestamps: { number },  -- cumulative seconds from spawn when each step is reached
    totalDuration: number,       -- total route time in seconds
    spawnTime: number,           -- tick() when NPC was spawned
    groupId: string?,
    reservedSeats: { Part },     -- seat Parts this NPC has reserved (for cleanup)
}

-- Per-NPC sync data sent via WP_SyncState for late-joining players
export type SyncNPCData = {
    modelIndex: number,
    speed: number,
    currentPosition: Vector3,       -- approximate position right now
    currentAction: Action,          -- what NPC is doing right now
    actionTimeRemaining: number,    -- seconds left on current idle/sit (0 for walk)
    remainingRoute: { RouteStep },  -- steps after current action completes
    groupId: string?,
}

-- Client-side runtime NPC state (managed by NPCClient/NPCMover)
export type LODTier = "near" | "mid" | "far"

export type ClientNPC = {
    id: string,
    model: Model,
    speed: number,
    route: { RouteStep },
    currentStepIndex: number,
    stepStartTime: number,          -- tick() when current step began (client time)
    groupId: string?,
    animator: Animator,
    walkTrack: AnimationTrack,
    idleTrack: AnimationTrack,
    sitTrack: AnimationTrack,
    lodTier: LODTier,               -- current LOD tier, updated each frame by NPCMover
    lastPosition: Vector3,          -- cached position for distance checks (avoids reading CFrame of hidden models)
}

-- Node graph node (server only, internal to NodeGraph module)
export type GraphNode = {
    part: Part,                     -- the workspace Part
    tag: string,                    -- which CollectionService tag
    position: Vector3,              -- part.Position
    isZone: boolean,                -- if true, NPC picks random point within bounds
    size: Vector3?,                 -- part.Size (only for zones)
    connections: { GraphNode },     -- adjacent nodes (from ObjectValue children)
    -- POI-specific fields:
    weight: number?,                -- POI selection weight
    viewTarget: Part?,              -- scenic POI: Part NPC faces
    seats: { Part }?,               -- social POI: child Parts tagged WP_Seat
    capacityCap: number?,           -- social POI: max fraction of seats usable
}
```

---

## Workspace Setup (Buyer-Facing)

Buyers place these tagged Parts in workspace. The server discovers them via CollectionService at startup.

### Tags and Attributes

| Tag | Part Type | Attributes | Notes |
|-----|-----------|------------|-------|
| `WP_Waypoint` | Part (any shape) | `IsZone: boolean (default false)` | Navigation node. If IsZone=true, NPC picks random point within Part bounds. |
| `WP_Spawn` | Part | (none) | Where NPCs appear. Place inside buildings or out of player view. |
| `WP_Despawn` | Part | (none) | Where NPCs disappear. Place out of player view. |
| `WP_Scenic` | Part | `Weight: number (default 1)` | Scenic POI. NPC stops and faces the ViewTarget. Must have one ObjectValue child named `ViewTarget` pointing to the Part NPC should face. |
| `WP_Busy` | Part | `Weight: number (default 1)` | Busy POI. NPC walks through without stopping. Creates foot traffic. |
| `WP_Social` | Part | `Weight: number (default 1)`, `CapacityCap: number (default 0.75)` | Social POI. Parent of seat Parts. |
| `WP_Seat` | Part | (none) | Child of a WP_Social Part. Each seat's CFrame defines the NPC's sitting position and orientation. |

### Node Connections

Each node Part (WP_Waypoint, WP_Spawn, WP_Despawn, WP_Scenic, WP_Busy, WP_Social) can have **ObjectValue children** whose `Value` property points to connected nodes. These define the edges of the navigation graph.

Example: WaypointA has an ObjectValue child with `Value = WaypointB`. This means NPCs can walk from A to B. Connections are **one-directional** — add ObjectValues on both Parts for bidirectional travel.

### NPC Models

Folder `ReplicatedStorage.WanderingPropModels` containing R15 rig Models indexed 1–14. Each model must have:
- `PrimaryPart` set (HumanoidRootPart)
- `AnimationController` with child `Animator`
- **No Humanoid**
- CanCollide = false on all parts (NPCs don't collide with anything)
- **PrimaryPart (HumanoidRootPart): Anchored = true. All other parts: Anchored = false.** The anchored root prevents the assembly from falling due to gravity. Children are unanchored so Motor6D joints can be driven by the Animator — if all parts were individually anchored, each would be its own fixed body and Motor6D joints between them would have no effect (animations wouldn't play). With only the root anchored, children are constrained to the root via Motor6D, the Animator can freely modify joint transforms, and `Model:PivotTo()` moves the whole assembly.
- `Animator.AnimationReplicationMode` = `Enum.AnimationReplicationMode.None` — set on the **Animator** instance (child of AnimationController), NOT on AnimationController. Animations are driven client-side only. Disabling replication avoids wasted network bandwidth for 70 NPCs.

---

## UI Architecture

**This system has no UI.** Wandering Props is a purely visual ambient system. No ScreenGuis, no Frames, no player-facing interface. NPCs are rendered as 3D models in the workspace.

---

## Security Model

**Minimal attack surface by design.**

- **Server owns:** NPC population count, route generation, seat assignments, spawn/despawn decisions. All game logic is server-side.
- **Client can request:** Nothing. Zero client→server RemoteEvents.
- **Client receives:** NPC spawn data, despawn signals, initial sync state. All server→client.
- **Validation on RemoteEvents:** None needed — there are no client→server events to validate.
- **Exploit impact:** A malicious client could refuse to render NPCs (no impact on others), render them incorrectly (no impact on others), or inspect route data (no sensitive information). There is nothing a client can do to affect server state or other players' experience.

---

## Performance Strategy

### Server
- **No per-frame work.** Server runs on a timer (`task.wait(SPAWN_CHECK_INTERVAL)`). Checks population, spawns/despawns as needed. No Heartbeat connection.
- **Pre-computed timing.** Route durations calculated at spawn time. Despawn checks compare `tick()` against pre-computed timestamps — O(1) per NPC.
- **Batched initial sync.** Late-joining players receive one `WP_SyncState` call with all NPC data, not individual spawn events.
- **O(n) population check.** Iterates active NPCs once per cycle. At 70 NPCs this is trivial.

### Client
- **Single Heartbeat connection with stationary skip + LOD + frustum culling.** One `RunService.Heartbeat` handler iterates all active NPCs. For each NPC, two cheap checks determine the LOD tier:
  1. **Distance:** `(npc.lastPosition - camera.CFrame.Position).Magnitude`
  2. **Frustum:** `(npc.lastPosition - camera.CFrame.Position):Dot(camera.CFrame.LookVector)` — if negative, NPC is behind the camera.

  NPCs behind the camera are promoted to **at minimum Mid tier** regardless of distance (animation frozen, model still visible). This means when the player turns around, the NPC is already there — they just see animation resume on the next frame (16ms at 60fps, imperceptible).

  | LOD Tier | Condition | PivotTo | Animation | Model Visible |
  |----------|-----------|---------|-----------|---------------|
  | **Near** | distance < `LOD_ANIMATION_DISTANCE` AND in front of camera | Every frame (walk steps only; idle/sit skip) | Full playback, speed-scaled | Yes |
  | **Mid** | distance < `LOD_RENDER_DISTANCE` AND (behind camera OR beyond animation distance) | Every frame (walk steps only; idle/sit skip) | **Frozen** (`AnimationTrack.Speed = 0`) | Yes |
  | **Far** | distance > `LOD_RENDER_DISTANCE` | **Skipped entirely** | **Stopped** | **No** (model parented to nil) |

  **Near tier** is the full experience — animation + PivotTo for walking NPCs, timer-only for stationary.
  **Mid tier** keeps the NPC visually moving (PivotTo still runs for walkers) but freezes limb animation. Used for two cases: NPCs at medium distance, and NPCs behind the camera at any distance. At distance or behind the player, frozen limbs are invisible.
  **Far tier** hides the model completely. NPCMover tracks route progress via timer only (no CFrame work). When an NPC transitions from Far→Mid (player approaches), NPCMover **fast-forwards** the NPC's position: calculates current route step and position from elapsed time (same math as late-join sync), calls PivotTo to place the model, re-parents to workspace. This transition is seamless — the NPC appears at its correct position, already mid-route.

  **Per-frame cost at 70 NPCs on a large map:** If the player is in one area with 20 nearby NPCs (10 in front, 10 behind) and 50 are distant, the Heartbeat loop runs: 10 PivotTo + animation calls (near, in front), 10 PivotTo-only calls (mid, behind camera), ~10 PivotTo-only calls (mid, distance), 40 timer-only checks (far). That's ~30 PivotTo calls and only ~10 animation evaluations per frame — very light.

- **Model pooling.** `ModelPool` pre-clones models on startup and recycles them. Avoids Instance.new/Clone/Destroy churn during gameplay. Pool size per model = `math.ceil(Config.MAX_POPULATION / Config.NPC_MODEL_COUNT) + Config.MODEL_POOL_BUFFER`.
- **Animation reuse.** AnimationTracks are loaded once per model acquire, reused across the NPC's lifetime, stopped on release.
- **No per-frame RemoteEvents.** All communication is event-driven (spawn, despawn, sync). Zero network traffic during steady-state NPC movement.

### Scaling Notes
- 70 NPCs × 15 parts (R15) = 1050 parts. With CanCollide=false, no Humanoid, client-side CFrame, and LOD culling, this is well within Roblox performance budgets.
- LOD culling is the primary performance lever. On large maps, most NPCs will be in the Far tier (zero rendering cost). Only nearby NPCs consume frame time.
- For buyers with very large maps: set `LOD_RENDER_DISTANCE` lower (e.g., 300) to aggressively cull. For small/dense maps: set it higher or equal to map size to keep all NPCs visible.
- Beyond 100 NPCs: the LOD system handles the scaling naturally. The bottleneck shifts to how many NPCs are simultaneously in the Near tier (on-screen, close to camera). Recommend keeping near-tier count under 50 for smooth 60fps.

---

## Config File Structure (Critical for Phase 3)

```lua
-- Config.luau
-- Wandering Props Configuration
-- Every tunable gameplay value lives here. Adjust these to change game feel
-- without touching code. Reasonable ranges noted in comments.

return {
    -- ══════════════════════════════════════════════
    -- POPULATION
    -- ══════════════════════════════════════════════

    -- Minimum active NPC count. Server spawns to reach this floor.
    -- Range: 5-50. Set equal to MAX for constant population.
    MIN_POPULATION = 20,

    -- Maximum active NPC count. Server stops spawning above this.
    -- Range: 20-100. Performance tested up to 70.
    MAX_POPULATION = 50,

    -- Seconds between spawn cycle checks. Lower = faster population recovery.
    -- Range: 1-10.
    SPAWN_CHECK_INTERVAL = 3,

    -- Max NPCs to spawn per cycle. Prevents burst-spawning 50 NPCs at once.
    -- Range: 1-5.
    SPAWNS_PER_CYCLE = 2,

    -- ══════════════════════════════════════════════
    -- MOVEMENT
    -- ══════════════════════════════════════════════

    -- Base NPC walk speed in studs/second.
    -- Range: 4-16. Roblox default Humanoid walk is 16.
    BASE_WALK_SPEED = 8,

    -- +/- random variation added to base speed per NPC.
    -- Range: 0-4. Example: base 8 ± 2 = speeds from 6 to 10.
    WALK_SPEED_VARIATION = 1.5,

    -- Speed (studs/sec) at which the walk animation was authored.
    -- Used to scale animation playback rate: animSpeed = npcSpeed / this.
    -- Set this to match your walk animation's natural speed.
    WALK_ANIMATION_NATURAL_SPEED = 8,

    -- ══════════════════════════════════════════════
    -- ROUTES
    -- ══════════════════════════════════════════════

    -- Min number of POIs per NPC route (before despawn).
    -- Range: 1-3.
    ROUTE_POI_MIN = 1,

    -- Max number of POIs per NPC route.
    -- Range: 1-5.
    ROUTE_POI_MAX = 3,

    -- Chance (0-1) that an NPC deviates to a random nearby node mid-route.
    -- Range: 0-0.5. 0 = never wander, 0.3 = 30% chance per route segment.
    WANDER_CHANCE = 0.15,

    -- Max graph hops from current node to consider for wander deviation.
    -- Range: 1-4. Higher = NPCs may wander further off path.
    WANDER_MAX_HOPS = 2,

    -- ══════════════════════════════════════════════
    -- LOD (Level of Detail) / DISTANCE CULLING
    -- ══════════════════════════════════════════════

    -- Distance in studs within which NPCs get full animation playback.
    -- Beyond this but within LOD_RENDER_DISTANCE: model visible, animation frozen.
    -- Range: 50-300. Lower = better performance, less visual fidelity at mid-range.
    LOD_ANIMATION_DISTANCE = 150,

    -- Distance in studs within which NPCs are rendered at all.
    -- Beyond this: model hidden, PivotTo skipped, only route timer runs.
    -- Range: 200-1000. Set to match your map's meaningful play area.
    -- For large maps with towns 1000+ studs apart, 400-500 is ideal.
    -- For small dense maps, set higher (800+) to keep all NPCs visible.
    LOD_RENDER_DISTANCE = 500,

    -- Freeze animations for NPCs behind the camera (promotes to Mid tier).
    -- NPCs behind you get their limbs frozen but model stays visible.
    -- When you turn around, animation resumes instantly (1 frame, imperceptible).
    -- true = enabled (recommended). false = only distance-based LOD.
    LOD_FRUSTUM_CULLING = true,

    -- ══════════════════════════════════════════════
    -- SCENIC POI
    -- ══════════════════════════════════════════════

    -- Min seconds NPC idles at a scenic POI.
    -- Range: 2-15.
    SCENIC_IDLE_MIN = 3,

    -- Max seconds NPC idles at a scenic POI.
    -- Range: 5-30.
    SCENIC_IDLE_MAX = 8,

    -- ══════════════════════════════════════════════
    -- SOCIAL POI
    -- ══════════════════════════════════════════════

    -- Min seconds NPC sits at a social POI.
    -- Range: 5-30.
    SOCIAL_SIT_MIN = 10,

    -- Max seconds NPC sits at a social POI.
    -- Range: 15-60.
    SOCIAL_SIT_MAX = 30,

    -- Weight for preferring seats at tables with existing occupants.
    -- Higher = NPCs more likely to sit near others. 1 = no preference.
    -- Range: 1-5.
    SOCIAL_WEIGHT_OCCUPIED = 3,

    -- Weight for choosing an empty table.
    -- Range: 1-5.
    SOCIAL_WEIGHT_EMPTY = 1,

    -- ══════════════════════════════════════════════
    -- GROUP SPAWNING
    -- ══════════════════════════════════════════════

    -- Chance (0-1) that a spawn cycle produces a group instead of solo NPC.
    -- Range: 0-0.5. 0 = groups disabled.
    GROUP_SPAWN_CHANCE = 0.15,

    -- Min group size (including leader).
    -- Range: 2-3.
    GROUP_SIZE_MIN = 2,

    -- Max group size (including leader).
    -- Range: 3-5.
    GROUP_SIZE_MAX = 4,

    -- Lateral offset in studs for group followers relative to path direction.
    -- Range: 2-6. How far apart group members walk side-by-side.
    GROUP_FOLLOWER_OFFSET = 3,

    -- Seconds delay between leader and each successive follower starting movement.
    -- Range: 0.2-1.5. Creates staggered formation feel.
    GROUP_FOLLOWER_DELAY = 0.5,

    -- ══════════════════════════════════════════════
    -- DAY/NIGHT CYCLE (OPTIONAL)
    -- ══════════════════════════════════════════════

    -- Enable day/night population scaling. Reads Lighting.ClockTime.
    -- false = constant population regardless of time.
    DAY_NIGHT_ENABLED = false,

    -- Hour (0-24) when night begins. Uses Lighting.ClockTime.
    -- Range: 17-22.
    NIGHT_START_HOUR = 18,

    -- Hour (0-24) when night ends.
    -- Range: 4-8.
    NIGHT_END_HOUR = 6,

    -- Multiplier applied to MAX_POPULATION during night.
    -- Range: 0.1-0.8. 0.4 = 40% of daytime population.
    NIGHT_POPULATION_MULTIPLIER = 0.4,

    -- ══════════════════════════════════════════════
    -- NPC MODELS & ANIMATIONS
    -- ══════════════════════════════════════════════

    -- Number of NPC model variants in ReplicatedStorage.WanderingPropModels.
    -- Models are children named "1", "2", ..., "N".
    NPC_MODEL_COUNT = 14,

    -- Roblox animation asset IDs. Replace with your uploaded animation IDs.
    -- WARNING: The defaults (rbxassetid://0) will error on load. You MUST replace
    -- these with valid animation asset IDs before running the system.
    ANIM_WALK = "rbxassetid://0",       -- Walk cycle animation
    ANIM_IDLE = "rbxassetid://0",       -- Standing idle animation
    ANIM_SIT  = "rbxassetid://0",       -- Seated idle animation

    -- Extra model clones per variant in the client pool.
    -- Prevents pool exhaustion during group spawns (multiple NPCs of same variant).
    -- Range: 2-10.
    MODEL_POOL_BUFFER = 3,

    -- ══════════════════════════════════════════════
    -- STUCK NPC HANDLING
    -- ══════════════════════════════════════════════

    -- Grace period in seconds beyond computed route duration before force-despawning.
    -- If an NPC's total route should take 60s and STUCK_TIMEOUT is 30, the NPC is
    -- force-despawned at 90s. Safety net for broken node graphs or timing drift.
    -- Range: 10-60.
    STUCK_TIMEOUT = 30,

    -- NPCs with less than this many seconds of route remaining are excluded from
    -- late-join sync to prevent spawn-then-immediately-despawn flicker.
    -- Range: 3-10.
    SYNC_DESPAWN_THRESHOLD = 5,

    -- ══════════════════════════════════════════════
    -- DEBUG
    -- ══════════════════════════════════════════════

    -- Enable debug logging via warn(). Useful for buyers debugging node graph setup.
    -- false = silent (production). true = logs spawn/despawn/route/error events to console.
    DEBUG_ENABLED = false,

    -- ══════════════════════════════════════════════
    -- COLLECTION SERVICE TAG NAMES
    -- ══════════════════════════════════════════════

    -- Tag names for workspace Parts. Change these if they conflict with
    -- the buyer's existing tags.
    TAG_WAYPOINT = "WP_Waypoint",
    TAG_SPAWN    = "WP_Spawn",
    TAG_DESPAWN  = "WP_Despawn",
    TAG_SCENIC   = "WP_Scenic",
    TAG_BUSY     = "WP_Busy",
    TAG_SOCIAL   = "WP_Social",
    TAG_SEAT     = "WP_Seat",
}
```

---

## Module API Specifications

### NodeGraph.luau

```lua
local NodeGraph = {}

-- Call once at server startup. Reads all CollectionService-tagged Parts,
-- builds adjacency list from ObjectValue children on each Part.
-- Stores internal graph: { [Part]: GraphNode }
function NodeGraph.init(): ()

-- BFS shortest path from one node Part to another.
-- Returns ordered array of GraphNode from start to goal (inclusive), or nil if unreachable.
function NodeGraph.getPath(from: Part, to: Part): { GraphNode }?

-- Returns all graph nodes reachable within maxHops from the given node.
-- Used for wander deviation candidate selection.
function NodeGraph.getNearbyNodes(node: Part, maxHops: number): { GraphNode }

-- For zone nodes (IsZone=true): returns a random Vector3 within the Part's bounding box.
-- For spot nodes: returns Part.Position.
function NodeGraph.resolvePosition(node: GraphNode): Vector3

-- Returns all nodes with a specific tag (e.g., all spawn points).
function NodeGraph.getNodesByTag(tag: string): { GraphNode }

-- Returns the GraphNode for a given Part, or nil.
function NodeGraph.getNode(part: Part): GraphNode?

return NodeGraph
```

### RouteBuilder.luau

```lua
local RouteBuilder = {}

-- Builds a solo NPC route.
-- 1. Picks random POIs (count from ROUTE_POI_MIN to ROUTE_POI_MAX) weighted by POI weight.
-- 2. Finds BFS path from spawnNode through each POI to a despawn node.
-- 3. Resolves zone positions. Injects wander deviations (WANDER_CHANCE per segment).
-- 4. For Social POIs, calls SeatManager.reserveSeat(). If no seat: skips that POI.
-- 5. Returns { RouteStep } array and reserved seat list.
function RouteBuilder.buildRoute(
    spawnNode: GraphNode
): ({ RouteStep }, { Part })

-- Builds routes for a group.
-- 1. Calls buildRoute() for the leader.
-- 2. For each follower: copies leader route, offsets each position perpendicular
--    to the walk direction by GROUP_FOLLOWER_OFFSET * follower index.
-- Returns array of { route: {RouteStep}, reservedSeats: {Part} } per member.
function RouteBuilder.buildGroupRoute(
    spawnNode: GraphNode,
    groupSize: number
): { { route: { RouteStep }, reservedSeats: { Part } } }

return RouteBuilder
```

### SeatManager.luau

```lua
local SeatManager = {}

-- Call once at startup. Reads all WP_Social and WP_Seat tagged Parts,
-- builds internal seat tracking tables.
function SeatManager.init(): ()

-- Reserves a seat at the given Social POI.
-- Checks: capacity cap, time-window availability, social weighting.
-- Capacity cap math: maxOccupied = math.floor(#seats * capacityCap).
-- Example: 3 seats × 0.75 cap = math.floor(2.25) = 2 max occupied.
-- Returns the seat Part if successful, nil if no seat available.
function SeatManager.reserveSeat(
    socialPOI: Part,         -- the WP_Social tagged Part
    arrivalTime: number,     -- expected tick() of NPC arrival
    duration: number         -- seconds NPC will sit
): Part?

-- Releases all seat reservations for a given NPC.
-- Called when NPC despawns (normal or stuck).
function SeatManager.releaseByNPC(npcId: string): ()

return SeatManager
```

### NPCRegistry.luau

```lua
local NPCRegistry = {}

-- Register a new NPC with its full state.
function NPCRegistry.register(record: NPCRecord): ()

-- Remove an NPC from the registry.
function NPCRegistry.unregister(npcId: string): ()

-- Get all active NPC records (for iteration).
function NPCRegistry.getAll(): { [string]: NPCRecord }

-- Get current NPC count.
function NPCRegistry.getCount(): number

-- Compute sync data for a late-joining player.
-- For each NPC: calculates current route step, position, and remaining route
-- based on elapsed time since spawn.
-- IMPORTANT: Excludes NPCs whose remaining route time < SYNC_DESPAWN_THRESHOLD (5 seconds).
-- This prevents a race condition where the client spawns an NPC that immediately despawns,
-- wasting a model clone and causing visual flicker.
function NPCRegistry.getSyncData(): { [string]: SyncNPCData }

return NPCRegistry
```

### NPCMover.luau (Client)

```lua
local NPCMover = {}

-- Register an NPC for movement. Starts executing route from the given step index.
-- onStepChanged callback fires when NPC transitions between route steps
-- (used by NPCClient to trigger animation changes).
-- onRouteComplete callback fires when NPC reaches the final step.
function NPCMover.startRoute(
    npc: ClientNPC,
    startStepIndex: number?,  -- default 1, for late-join sync may start mid-route
    onStepChanged: (npc: ClientNPC, step: RouteStep) -> (),
    onRouteComplete: (npc: ClientNPC) -> ()
): ()

-- Stop tracking an NPC (on despawn).
function NPCMover.stop(npcId: string): ()

-- Called every frame from NPCClient's Heartbeat connection.
-- For each active NPC:
--   1. Compute direction vector: camera to NPC (from npc.lastPosition).
--   2. Compute distance (.Magnitude) and frustum check (.Dot with LookVector).
--      Both derived from the same direction vector — no extra work.
--   3. Determine LOD tier:
--      NEAR: distance < LOD_ANIMATION_DISTANCE AND (in front of camera OR frustum culling disabled)
--      MID:  distance < LOD_RENDER_DISTANCE AND (behind camera OR beyond animation distance)
--      FAR:  distance > LOD_RENDER_DISTANCE
--   4. Apply tier behavior:
--      NEAR: Full update. Walk steps → PivotTo + animation. Idle/sit → timer only.
--      MID:  Walk steps → PivotTo (model moves). Idle/sit → timer only.
--            Animation is frozen (handled by NPCAnimator.freeze/unfreeze via callback).
--      FAR:  Skip PivotTo entirely. Track route progress via timer only.
--            Model is hidden (parented to nil). No rendering cost.
--   5. On tier transitions:
--      Far→Mid/Near: call fastForward(npc), PivotTo to correct position, re-parent model.
--      Near→Mid: call NPCAnimator.freeze(npc).
--      Mid→Near: call NPCAnimator.unfreeze(npc).
--      Mid/Near→Far: parent model to nil, call NPCAnimator.stopAll(npc).
--
-- Stationary skip still applies within Near/Mid tiers: idle/sit NPCs
-- skip PivotTo regardless of distance.
function NPCMover.update(dt: number): ()

-- Computes an NPC's current route step and position from elapsed time.
-- Used for: (1) Far→Mid/Near LOD transitions (player approaches distant NPC),
-- (2) late-join sync on client side.
-- Same math: stepStartTime + step distances / speed → derive current position.
function NPCMover.fastForward(npc: ClientNPC): ()

return NPCMover
```

### NPCAnimator.luau (Client)

```lua
local NPCAnimator = {}

-- Load all three AnimationTracks onto the NPC's Animator.
-- Call once after acquiring model from pool.
-- VALIDATION: If any Config.ANIM_* ID is "rbxassetid://0", log a clear error
-- ("Animation IDs not configured in Config.luau — replace ANIM_WALK/IDLE/SIT with valid IDs")
-- and skip animation setup. NPCs will still move but won't animate.
-- Returns the loaded tracks on the ClientNPC (mutates npc.walkTrack, etc.).
function NPCAnimator.setup(npc: ClientNPC): ()

-- Play walk animation. Scales playback speed to match movement speed.
-- speed: the NPC's walk speed in studs/sec.
function NPCAnimator.playWalk(npc: ClientNPC, speed: number): ()

-- Play idle animation (for scenic POI stops).
function NPCAnimator.playIdle(npc: ClientNPC): ()

-- Play sit animation (for social POI seats).
function NPCAnimator.playSit(npc: ClientNPC): ()

-- Freeze all playing animations in place (set Speed = 0 on active tracks).
-- Used for Mid LOD tier: NPC body still moves via PivotTo, but limbs don't animate.
-- Tracks remain "playing" at speed 0 so they resume from the same pose.
function NPCAnimator.freeze(npc: ClientNPC): ()

-- Unfreeze animations (restore Speed to normal values).
-- Used when NPC transitions from Mid → Near LOD tier.
-- Walk animation speed is restored to the movement-scaled value.
function NPCAnimator.unfreeze(npc: ClientNPC): ()

-- Stop all animations (on despawn/release).
function NPCAnimator.stopAll(npc: ClientNPC): ()

return NPCAnimator
```

### ModelPool.luau (Client)

```lua
local ModelPool = {}

-- Pre-clone models from ReplicatedStorage.WanderingPropModels.
-- Creates POOL_SIZE_PER_MODEL clones of each model variant, stored offscreen.
-- POOL_SIZE_PER_MODEL = math.ceil(Config.MAX_POPULATION / Config.NPC_MODEL_COUNT) + buffer.
function ModelPool.init(): ()

-- Acquire a model of the given variant index (1-based).
-- Returns a Model moved from the pool, parented to Workspace.
-- If pool exhausted for that variant, clones a new one (fallback).
function ModelPool.acquire(modelIndex: number): Model

-- Release a model back to the pool.
-- Stops animations, moves model offscreen, re-parents to nil.
function ModelPool.release(model: Model): ()

return ModelPool
```

---

## PopulationController Logic (Server Main Loop)

```
-- ID generator: simple incrementing counter. Unique per server session.
local npcIdCounter = 0
local function generateId(): string
    npcIdCounter += 1
    return "npc_" .. tostring(npcIdCounter)
end

on server start:
    NodeGraph.init()
    SeatManager.init()
    create RemoteEvents folder in ReplicatedStorage
    create WP_SpawnNPC, WP_DespawnNPC, WP_SyncState RemoteEvents

    Players.PlayerAdded:Connect(onPlayerAdded)

    -- Main loop
    while true do
        task.wait(Config.SPAWN_CHECK_INTERVAL)

        targetPop = getTargetPopulation()  -- applies day/night multiplier if enabled
        currentPop = NPCRegistry.getCount()

        -- Despawn check: remove NPCs past their route duration + stuck grace period
        for id, record in NPCRegistry.getAll() do
            if tick() - record.spawnTime >= record.totalDuration + Config.STUCK_TIMEOUT then
                WP_DespawnNPC:FireAllClients({ id = id })
                SeatManager.releaseByNPC(id)
                NPCRegistry.unregister(id)
            end
        end

        -- Spawn check
        spawned = 0
        while NPCRegistry.getCount() < targetPop and spawned < Config.SPAWNS_PER_CYCLE do
            if math.random() < Config.GROUP_SPAWN_CHANCE then
                spawnGroup()
            else
                spawnSolo()
            end
            spawned += 1   -- counts group as 1 spawn action
        end
    end

function onPlayerAdded(player):
    -- Small delay to let client scripts load
    task.wait(1)
    WP_SyncState:FireClient(player, { npcs = NPCRegistry.getSyncData() })

function getTargetPopulation():
    if not Config.DAY_NIGHT_ENABLED then
        return Config.MAX_POPULATION
    end
    local hour = game:GetService("Lighting").ClockTime
    local isNight = hour >= Config.NIGHT_START_HOUR or hour < Config.NIGHT_END_HOUR
    if isNight then
        return math.floor(Config.MAX_POPULATION * Config.NIGHT_POPULATION_MULTIPLIER)
    end
    return Config.MAX_POPULATION

function spawnSolo():
    local spawnNodes = NodeGraph.getNodesByTag(Config.TAG_SPAWN)
    local spawnNode = spawnNodes[math.random(#spawnNodes)]
    local modelIndex = math.random(Config.NPC_MODEL_COUNT)
    local speed = Config.BASE_WALK_SPEED + (math.random() * 2 - 1) * Config.WALK_SPEED_VARIATION
    local route, seats = RouteBuilder.buildRoute(spawnNode)

    if #route == 0 then return end  -- broken graph, skip

    local npcId = generateId()
    local stepTimestamps, totalDuration = computeTimestamps(route, speed)

    NPCRegistry.register({
        id = npcId, modelIndex = modelIndex, speed = speed,
        route = route, stepTimestamps = stepTimestamps,
        totalDuration = totalDuration, spawnTime = tick(),
        groupId = nil, reservedSeats = seats,
    })

    WP_SpawnNPC:FireAllClients({
        id = npcId, modelIndex = modelIndex,
        speed = speed, route = route, groupId = nil,
    })

function spawnGroup():
    -- similar to spawnSolo but uses RouteBuilder.buildGroupRoute()
    -- assigns shared groupId to all members
    -- fires WP_SpawnNPC for each member

function computeTimestamps(route, speed):
    -- Iterates route[1] through route[#route]. For each step i:
    --   walk: duration = (route[i+1].position - route[i].position).Magnitude / speed
    --         (looks ahead to next step's position for distance)
    --   idle/sit: duration = step.duration
    --   despawn: duration = 0 (terminal step)
    -- stepTimestamps[i] = cumulative seconds from spawn to reaching step i.
    -- stepTimestamps[1] = 0 (NPC starts at first step).
    -- Returns (stepTimestamps array, totalDuration number).
```

---

## NPCClient Logic (Client Main Script)

```
on client start:
    ModelPool.init()

    local remotes = ReplicatedStorage:WaitForChild("WanderingPropsRemotes", 10)
    if not remotes then
        warn("[WanderingProps] Remote events folder not found. Server may have failed to start.")
        return
    end
    local spawnEvent = remotes:WaitForChild("WP_SpawnNPC", 10)
    local despawnEvent = remotes:WaitForChild("WP_DespawnNPC", 10)
    local syncEvent = remotes:WaitForChild("WP_SyncState", 10)

    local activeNPCs: { [string]: ClientNPC } = {}

    spawnEvent.OnClientEvent:Connect(function(payload: SpawnPayload)
        local model = ModelPool.acquire(payload.modelIndex)
        model:PivotTo(CFrame.new(payload.route[1].position))
        model.Parent = workspace

        local npc: ClientNPC = {
            id = payload.id,
            model = model,
            speed = payload.speed,
            route = payload.route,
            currentStepIndex = 1,
            stepStartTime = tick(),
            groupId = payload.groupId,
            animator = model.AnimationController.Animator,
            walkTrack = nil, idleTrack = nil, sitTrack = nil,
        }

        NPCAnimator.setup(npc)
        activeNPCs[npc.id] = npc

        NPCMover.startRoute(npc, 1, onStepChanged, onRouteComplete)
    end)

    despawnEvent.OnClientEvent:Connect(function(data)
        local npc = activeNPCs[data.id]
        if npc then
            cleanupNPC(npc)
        end
    end)

    syncEvent.OnClientEvent:Connect(function(data)
        for npcId, syncData in data.npcs do
            -- Create NPC at current position, start from remaining route
            local model = ModelPool.acquire(syncData.modelIndex)
            model:PivotTo(CFrame.new(syncData.currentPosition))
            model.Parent = workspace

            local npc = buildClientNPCFromSync(syncData, model, npcId)
            NPCAnimator.setup(npc)
            activeNPCs[npcId] = npc

            -- Start appropriate animation for current action
            if syncData.currentAction == "walk" then
                NPCAnimator.playWalk(npc, syncData.speed)
            elseif syncData.currentAction == "idle" then
                NPCAnimator.playIdle(npc)
            elseif syncData.currentAction == "sit" then
                NPCAnimator.playSit(npc)
            end

            NPCMover.startRoute(npc, 1, onStepChanged, onRouteComplete)
        end
    end)

    RunService.Heartbeat:Connect(function(dt)
        NPCMover.update(dt)
    end)

function onStepChanged(npc, step):
    if step.action == "walk" then
        NPCAnimator.playWalk(npc, npc.speed)
    elseif step.action == "idle" then
        NPCAnimator.playIdle(npc)
    elseif step.action == "sit" then
        NPCAnimator.playSit(npc)
    end

function onRouteComplete(npc):
    cleanupNPC(npc)

function cleanupNPC(npc):
    NPCAnimator.stopAll(npc)
    ModelPool.release(npc.model)
    activeNPCs[npc.id] = nil
    NPCMover.stop(npc.id)
```

---

## Build Order (Critical for Phase 3)

Codex should build in this order. Each step depends on the ones before it.

| Step | Files | Depends On | Description |
|------|-------|------------|-------------|
| 1 | `Config.luau`, `Types.luau` | Nothing | Foundation. All constants and type definitions. |
| 2 | `NodeGraph.luau` | Config | Graph data structure. Reads workspace tags, builds adjacency list, BFS pathfinding. Can be tested independently with tagged Parts in a test place. |
| 3 | `SeatManager.luau` | Config, Types | Seat reservation system. Can be unit-tested with mock POI data. |
| 4 | `RouteBuilder.luau` | Config, Types, NodeGraph, SeatManager | Route generation. The most complex server module. Requires NodeGraph and SeatManager to be working. |
| 5 | `NPCRegistry.luau` | Config, Types | NPC state tracking. Mostly data management, relatively simple. |
| 6 | `ModelPool.luau` | Config | Client-side model pooling. Independent of server logic. Can be tested with models in ReplicatedStorage. |
| 7 | `NPCAnimator.luau` | Config | Client-side animation management. Independent of movement logic. |
| 8 | `NPCMover.luau` | Config, Types | Client-side CFrame interpolation. Core movement engine. |
| 9 | `PopulationController.server.luau` | All server modules | Server orchestrator. Wires everything together. Build last on server side. |
| 10 | `NPCClient.client.luau` | All client modules, Types | Client orchestrator. Wires everything together. Build last on client side. |

**Steps 6-8 can be built in parallel with steps 2-5** since client and server modules are independent.

---

## Integration Points

- **Day/Night Cycle:** Reads `Lighting.ClockTime`. Works automatically with any day/night system that updates this property (most Roblox day/night systems do). Toggled via `DAY_NIGHT_ENABLED` in Config. No other external dependencies.
- **Other Game Systems:** None. Wandering Props is fully isolated. No shared state, no shared events, no dependencies on other systems.

---

## Stuck NPC Handling (Detail)

Built into RouteBuilder and PopulationController:

1. **RouteBuilder:** When building a route, if BFS returns nil for a path to a selected POI → skip that POI, try next. If no POIs are reachable → attempt path directly to any despawn node. If no despawn reachable → return empty route.
2. **PopulationController:** If RouteBuilder returns empty route → don't spawn (log warning). If an NPC's `totalDuration` elapses and the server hasn't received a natural despawn → force despawn via `WP_DespawnNPC`. The `STUCK_TIMEOUT` config adds a grace period beyond the computed total duration.
3. **Client:** If a despawn event arrives for an NPC the client is still rendering → immediately clean up (stop animation, return model to pool).

---

## Edge Cases Handled

| Edge Case | Handling |
|-----------|----------|
| Disconnected node graph | BFS returns nil → POI skipped or NPC not spawned |
| All seats at Social POI taken | SeatManager returns nil → POI skipped in route |
| Player joins with 70 NPCs active | Single WP_SyncState event with batch payload |
| NPC model missing from ReplicatedStorage | ModelPool.acquire logs warning, returns nil. NPCClient skips that NPC. |
| Zero spawn/despawn points tagged | PopulationController logs error, does not spawn. Doesn't crash. |
| Clock time between NIGHT_END and NIGHT_START (daytime) | Normal population |
| Group size exceeds remaining population capacity | Reduce group size to fit, or skip group and spawn solo |

---

## Critic Review Notes

### Review 1 (2026-02-12)
**Verdict:** APPROVED (0 blocking, 9 flags)

Flags addressed: AnimationReplication property, GROUP_FOLLOWER_DELAY timing, computeTimestamps loop clarity, DEBUG_ENABLED config flag.

### Review 2 (2026-02-12) — Fresh second pass focused on optimization
**Verdict:** Initially BLOCKED (5 blocking), all 5 fixed. Now APPROVED.

**Blocking issues fixed:**
1. **AnimationReplication API** — Corrected from `AnimationController.AnimationReplication` to `Animator.AnimationReplicationMode` (the property lives on Animator, not AnimationController)
2. **Anchored=true breaks Motor6D animations** — Changed to `Anchored=false` on all parts. With no Humanoid and CanCollide=false, unanchored parts don't physically simulate. PivotTo still works for positioning.
3. **PivotTo on 70 NPCs every frame** — Added stationary-skip optimization: only NPCs in "walk" steps call PivotTo. Idle/sitting NPCs skip CFrame updates (timer only). Cuts per-frame PivotTo calls from 70 to ~30-50.
4. **Late-join sync race condition** — Added `SYNC_DESPAWN_THRESHOLD` (5s). NPCs with <5s remaining are excluded from sync data, preventing spawn-then-immediately-despawn flicker.
5. **MODEL_POOL_BUFFER missing** — Added `MODEL_POOL_BUFFER = 3` to Config. Pool size formula now explicit.

**Additional fixes from flags:**
- STUCK_TIMEOUT now actually used in despawn check: `totalDuration + Config.STUCK_TIMEOUT`
- `generateId()` function defined (incrementing counter)
- WaitForChild calls now have 10-second timeout with graceful error handling
- Animation asset ID defaults have WARNING comment about needing replacement

**Acknowledged flags (conscious decisions):**
- Late-join sync payload (~14KB-210KB for 70 NPCs) is under RemoteEvent limits. Chunking needed only above 100 NPCs.
- BFS pathfinding at spawn time is fast for graphs <200 nodes. Documented as scaling guidance.
- Type annotations are in API specs; Codex must match in implementation.

### Review 3 (2026-02-12) — Fresh blind pass, general opinion
**Verdict:** APPROVED (0 blocking, 6 flags)

Critic praised: config extraction, zero client→server traffic, documentation depth, stationary-skip optimization. Confidence score: 8.5/10 for implementation readiness.

**Post-review additions:**
- **LOD system added to v1** (previously deferred). Three-tier distance culling: Near (full anim + PivotTo), Mid (PivotTo only, anim frozen), Far (model hidden, timer only). Config: `LOD_ANIMATION_DISTANCE`, `LOD_RENDER_DISTANCE`. Essential for large maps where buyers spread NPCs across thousands of studs.
- NPCMover.update() now includes LOD tier check per NPC and `fastForward()` for Far→Near transitions.
- NPCAnimator gains `freeze()`/`unfreeze()` for Mid-tier animation pausing.
- ClientNPC type gains `lodTier` and `lastPosition` fields.
- NPCAnimator.setup() validates animation IDs and fails early with clear error if still at `rbxassetid://0`.
- SeatManager.reserveSeat() explicitly documents `math.floor(#seats * capacityCap)` for fractional seat counts.

### Post-Review 3 additions
- **Anchoring corrected:** PrimaryPart Anchored=true, all other parts Anchored=false. Fixes gravity bug (unanchored NPCs would fall through map during idle/sit). Motor6D animations work because only the root is anchored — children are constrained via joints and can be driven by Animator.
- **Frustum culling added to LOD system.** NPCs behind the camera are promoted to Mid tier (animation frozen, model visible). One dot product per NPC per frame (derived from same direction vector as distance check — zero extra cost). Config: `LOD_FRUSTUM_CULLING = true`.
