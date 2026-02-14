# Architecture Outline: Wandering Props

**Based on:** idea-locked.md
**Critic Status:** APPROVED
**Date:** 2026-02-13

---

## File Organization

| File | Location | Layer | Purpose |
|------|----------|-------|---------|
| `Config.luau` | shared/ | Infrastructure | All tunable gameplay values + DEBUG_MODE |
| `Types.luau` | shared/ | Infrastructure | Shared type definitions for all modules |
| `Diagnostics.luau` | shared/ | Infrastructure | Lifecycle logging, health counters, entity trails |
| `StartupValidator.luau` | server/ | Infrastructure | Workspace contract validation at boot |
| `NodeGraph.luau` | server/ | Core | Builds waypoint graph from tagged parts, BFS/Dijkstra pathfinding |
| `SeatManager.luau` | server/ | Core | Social POI seat claiming/releasing, capacity enforcement |
| `NPCRegistry.luau` | server/ | Core | Server-side NPC state storage (create/read/update/delete) |
| `RouteBuilder.luau` | server/ | Core | Builds full NPC routes: spawn → POIs → despawn, with wander deviations |
| `PopulationController.server.luau` | server/ | Core | Entry point. Main loop: spawn/despawn decisions, step advancement, RemoteEvent firing |
| `NPCAnimator.luau` | client/ | Core | Loads and plays walk/idle/sit animations, speed scaling |
| `NPCMover.luau` | client/ | Core | CFrame interpolation between route steps, ground-snap raycasts |
| `NPCClient.client.luau` | client/ | Core | Entry point. Listens for RemoteEvents, manages local NPC lifecycle |
| `ModelPool.luau` | client/ | Optimization | Reuses R15 model instances instead of Clone/Destroy |
| `LODController.luau` | client/ | Optimization | Distance-based quality tiers: near/low/mid/far |

**Total: 14 files** (3 shared, 6 server, 3 client core, 2 client optimization)

### Rojo Project Structure

```
src/
├── default.project.json
└── src/
    ├── shared/          → ReplicatedStorage/WanderingProps/
    │   ├── Config.luau
    │   ├── Types.luau
    │   └── Diagnostics.luau
    ├── server/          → ServerScriptService/WanderingProps/
    │   ├── StartupValidator.luau
    │   ├── NodeGraph.luau
    │   ├── SeatManager.luau
    │   ├── NPCRegistry.luau
    │   ├── RouteBuilder.luau
    │   └── PopulationController.server.luau
    └── client/          → StarterPlayer/StarterPlayerScripts/WanderingProps/
        ├── NPCAnimator.luau
        ├── NPCMover.luau
        ├── NPCClient.client.luau
        ├── ModelPool.luau
        └── LODController.luau
```

```json
// default.project.json
{
    "name": "WanderingProps",
    "tree": {
        "$className": "DataModel",
        "ReplicatedStorage": {
            "WanderingProps": {
                "$path": "src/shared"
            }
        },
        "ServerScriptService": {
            "WanderingProps": {
                "$path": "src/server"
            }
        },
        "StarterPlayer": {
            "StarterPlayerScripts": {
                "WanderingProps": {
                    "$path": "src/client"
                }
            }
        }
    }
}
```

---

## Roblox APIs Used

- **RemoteEvents** (3 total, all Server → Client):
  - `WP_Spawn`: sends full NPC data + route to all clients
  - `WP_Despawn`: sends npcId to all clients
  - `WP_BulkSync`: sends all active NPC states to a single joining client
- **CollectionService:** `GetTagged("WP_Node")`, `GetTagged("WP_POI")`, `GetTagged("WP_Seat")`, `GetTagged("WP_ViewZone")` — used by NodeGraph at startup to discover workspace layout
- **RunService:** `Heartbeat` — server tick loop (PopulationController), client movement loop (NPCMover)
- **Players:** `PlayerAdded` — triggers WP_BulkSync for late joiners; character tracking for raycast filtering
- **TweenService:** Not used. All movement is manual CFrame interpolation.
- **PathfindingService:** Not used. Node-based graph with custom BFS/Dijkstra.
- **AnimationController + Animator:** On each R15 rig. NPCAnimator loads/plays AnimationTracks.

### Workspace Tags

| Tag | Applied To | Purpose |
|-----|-----------|---------|
| `WP_Node` | BasePart | Waypoint graph node |
| `WP_POI` | BasePart (also has WP_Node) | Point of interest |
| `WP_Seat` | BasePart (child of social POI) | Sittable seat |
| `WP_ViewZone` | BasePart (child of scenic POI) | What scenic NPCs face |

### Node Attributes

| Attribute | On | Type | Values |
|-----------|----|------|--------|
| `NodeType` | WP_Node | string | `"spot"` or `"zone"` |
| `NodeRole` | WP_Node | string | `"waypoint"`, `"spawn"`, or `"despawn"` |
| `POIType` | WP_POI | string | `"scenic"`, `"busy"`, or `"social"` |
| `POIWeight` | WP_POI | number | Default 1. Higher = more NPC traffic. |

### Node Connections

Each `WP_Node` part has **ObjectValue children** where `Value` points to another `WP_Node` part. Any ObjectValue child whose Value is a tagged `WP_Node` is treated as a graph edge. Connection names don't matter. Connections are **bidirectional** — if Node A has an ObjectValue pointing to Node B, the edge exists in both directions (no need to duplicate).

`WP_Node` names are the node IDs in this architecture and therefore must be unique across all tagged nodes (validated at startup).

### Workspace Layout (buyer sets up)

```
Workspace/
├── WanderingProps/
│   ├── Nodes/
│   │   ├── Spawn1 [Part, WP_Node, NodeType="spot", NodeRole="spawn"]
│   │   │   └── [ObjectValue → Node1]
│   │   ├── Node1 [Part, WP_Node, NodeType="spot", NodeRole="waypoint"]
│   │   │   ├── [ObjectValue → Spawn1]
│   │   │   └── [ObjectValue → Node2]
│   │   ├── Node2 [Part, WP_Node, NodeType="zone", NodeRole="waypoint"]
│   │   │   └── [ObjectValue → Node1]
│   │   ├── CafeView [Part, WP_Node + WP_POI, NodeType="spot", POIType="scenic", POIWeight=2]
│   │   │   ├── [ObjectValue → Node2]
│   │   │   └── ViewTarget [Part, WP_ViewZone]
│   │   ├── ParkBench [Part, WP_Node + WP_POI, NodeType="spot", POIType="social", POIWeight=1]
│   │   │   ├── [ObjectValue → Node2]
│   │   │   └── Seat1 [Part, WP_Seat]
│   │   │   └── Seat2 [Part, WP_Seat]
│   │   └── Despawn1 [Part, WP_Node, NodeType="spot", NodeRole="despawn"]
│   │       └── [ObjectValue → Node2]
│   └── ActiveNPCs/          ← client parents NPC models here (created at runtime)

ReplicatedStorage/
└── WanderingPropModels/     ← buyer places R15 models here
    ├── Villager1 [Model with AnimationController → Animator]
    └── Villager2 [Model with AnimationController → Animator]
```

---

## Script Communication Map

| From | To | Mechanism | Data Sent | Direction |
|------|----|-----------|-----------|-----------|
| `PopulationController` | `Config` | `require()` | Read config values | Server |
| `PopulationController` | `Diagnostics` | `require()` | `.log()`, `.health()`, `.trail()` | Server |
| `PopulationController` | `NodeGraph` | `require()` | `.build()`, `.getSpawnNodes()`, `.getDespawnNodes()` | Server |
| `PopulationController` | `RouteBuilder` | `require()` | `.buildRoute()`, `.buildGroupRoute()` | Server |
| `PopulationController` | `NPCRegistry` | `require()` | `.createNPC()`, `.removeNPC()`, `.getAllNPCs()`, `.getActiveCount()` | Server |
| `PopulationController` | `SeatManager` | `require()` | `.releaseSeat()` | Server |
| `PopulationController` | `StartupValidator` | `require()` | `.validate()` | Server |
| `PopulationController` | `NPCClient` | RemoteEvent: `WP_Spawn` | `{npcId, modelIndex, walkSpeed, route, startPosition}` | Server → All Clients |
| `PopulationController` | `NPCClient` | RemoteEvent: `WP_Despawn` | `{npcId}` | Server → All Clients |
| `PopulationController` | `NPCClient` | RemoteEvent: `WP_BulkSync` | `{npcs: [{npcId, modelIndex, walkSpeed, route, startPosition, currentStepIndex, stepElapsed}]}` | Server → Single Client |
| `RouteBuilder` | `NodeGraph` | `require()` | `.findPath()`, `.getNode()`, `.getPOINodes()`, `.getNodesInRadius()` | Server |
| `RouteBuilder` | `SeatManager` | `require()` | `.claimSeat()` | Server |
| `RouteBuilder` | `Config` | `require()` | Read route config values | Server |
| `SeatManager` | `Config` | `require()` | Read seat config values | Server |
| `StartupValidator` | `NodeGraph` | `require()` | Query graph state for validation | Server |
| `StartupValidator` | `Config` | `require()` | Validate config values | Server |
| `NPCClient` | `NPCMover` | `require()` | `.startMoving()`, `.stopMoving()` | Client |
| `NPCClient` | `NPCAnimator` | `require()` | `.setup()`, `.cleanup()` | Client |
| `NPCClient` | `ModelPool` | `require()` | `.acquire()`, `.release()` | Client (Optimization) |
| `NPCClient` | `LODController` | `require()` | `.register()`, `.unregister()` | Client (Optimization) |
| `NPCMover` | `NPCAnimator` | `require()` | `.playWalk()`, `.playIdle()`, `.playSit()`, `.stopAll()` | Client |
| `NPCMover` | `Config` | `require()` | Read movement config values | Client |
| `LODController` | `NPCMover` | `require()` | `.setLODTier()` | Client (Optimization) |
| `LODController` | `Config` | `require()` | Read LOD config values | Client (Optimization) |

### ModuleScript Dependencies

- **PopulationController** requires: Config, Diagnostics, NodeGraph, RouteBuilder, NPCRegistry, SeatManager, StartupValidator
- **RouteBuilder** requires: Config, Diagnostics, NodeGraph, SeatManager
- **SeatManager** requires: Config, Diagnostics, NodeGraph (via init parameter)
- **NPCRegistry** requires: Diagnostics
- **NodeGraph** requires: Config (for connection settings), Diagnostics
- **StartupValidator** requires: Config, NodeGraph
- **NPCClient** requires: Config, NPCMover, NPCAnimator, ModelPool (opt), LODController (opt)
- **NPCMover** requires: Config, NPCAnimator
- **LODController** requires: Config, NPCMover

---

## Build Order

### Infrastructure (build first — no game logic dependencies)
1. **Config.luau** — zero dependencies
2. **Types.luau** — zero dependencies
3. **Diagnostics.luau** — depends on: Config (for DEBUG_MODE, DIAG_TRAIL_LENGTH)

### Core Server (build in order)
4. **NodeGraph.luau** — depends on: Config, Diagnostics, CollectionService
5. **SeatManager.luau** — depends on: Config, Diagnostics
6. **NPCRegistry.luau** — depends on: Diagnostics
7. **RouteBuilder.luau** — depends on: Config, Diagnostics, NodeGraph, SeatManager
8. **StartupValidator.luau** — depends on: Config, NodeGraph, CollectionService
9. **PopulationController.server.luau** — depends on: all server modules + Config, Diagnostics

### Core Client (build in order)
10. **NPCAnimator.luau** — depends on: Config
11. **NPCMover.luau** — depends on: Config, NPCAnimator
12. **NPCClient.client.luau** — depends on: Config, NPCMover, NPCAnimator

### Optimization (build only after core gate passes)
13. **ModelPool.luau** — wraps: model Clone/Destroy in NPCClient
14. **LODController.luau** — wraps: NPCMover update frequency + NPCAnimator enable/disable + model visibility

---

## Data Structures

```lua
-- Types.luau

-- Node graph types (server only, but defined here for reference)
export type NodeData = {
    id: string,              -- node ID (part.Name, uniqueness enforced by startup validator)
    instance: BasePart,      -- the workspace part itself
    position: Vector3,       -- part.Position (center)
    nodeType: "spot" | "zone",
    nodeRole: "waypoint" | "spawn" | "despawn",
    connections: {string},   -- IDs of connected nodes
    size: Vector3?,          -- for zones: part.Size (boundary for random point picking)
    poi: POIData?,           -- nil if not a POI
}

export type POIData = {
    poiType: "scenic" | "busy" | "social",
    weight: number,          -- POIWeight attribute, default 1
    viewZone: BasePart?,     -- scenic only: the WP_ViewZone child part
    seats: {SeatData}?,      -- social only: list of seat parts
}

export type SeatData = {
    id: string,              -- unique seat identifier (part name or generated)
    instance: BasePart,      -- the WP_Seat part
    cframe: CFrame,          -- seat part CFrame (where NPC sits)
}

-- Route types (shared between server and client via RemoteEvent)
export type RouteStep = {
    type: "walk" | "scenic" | "social" | "despawn",
    targetPosition: Vector3, -- where the NPC moves to
    distance: number,        -- studs from previous step's targetPosition
    dwellTime: number?,      -- seconds to stay (scenic/social only)
    seatCFrame: CFrame?,     -- exact sit position+orientation (social only)
    viewPosition: Vector3?,  -- what to face during dwell (scenic only)
    poiName: string?,        -- for diagnostics: POI instance name (walk-through busy POIs also use this)
}

-- NPC state (server side)
export type NPCData = {
    npcId: string,           -- "wp_1", "wp_2", etc.
    modelIndex: number,      -- 1-based index into WanderingPropModels children
    walkSpeed: number,       -- studs/second (BASE_WALK_SPEED ± variation)
    route: {RouteStep},      -- complete pre-computed route
    stepDurations: {number}, -- pre-computed duration for each step (seconds)
    cumulativeTimes: {number}, -- cumulative time at end of each step
    totalDuration: number,   -- sum of all step durations
    spawnTime: number,       -- os.clock() when NPC was created
    currentStepIndex: number,-- server's tracked step (advanced on tick)
    state: "active" | "despawning",
    seatClaims: {[number]: string}?, -- stepIndex → seatId, for cleanup on force-removal
}

-- Client-side NPC tracking
export type ClientNPC = {
    npcId: string,
    model: Model,
    walkSpeed: number,
    route: {RouteStep},
    stepDurations: {number},
    cumulativeTimes: {number},
    startTime: number,       -- os.clock() when client started this NPC
    animatorHandle: AnimatorHandle,
    currentStepType: string, -- last known step type (for animation transitions)
    virtualPosition: Vector3,-- tracked even when model is hidden (LOD far)
    lodTier: "near" | "low" | "mid" | "far",
}

-- Animator handle (client)
export type AnimatorHandle = {
    animator: Animator,
    walkTrack: AnimationTrack,
    idleTrack: AnimationTrack,
    sitTrack: AnimationTrack,
}

-- Seat occupancy tracking (server)
export type SeatClaim = {
    seatId: string,
    poiNodeId: string,
    cframe: CFrame,
}

-- RemoteEvent payloads
export type SpawnPayload = {
    npcId: string,
    modelIndex: number,
    walkSpeed: number,
    route: {RouteStep},
    startPosition: Vector3,
}

export type BulkSyncEntry = {
    npcId: string,
    modelIndex: number,
    walkSpeed: number,
    route: {RouteStep},
    startPosition: Vector3,
    currentStepIndex: number,
    stepElapsed: number,     -- seconds elapsed in current step
}
```

---

## Data Flow

### 1. System Startup
1. `PopulationController` runs, requires all modules
2. Calls `NodeGraph.build()` — scans `CollectionService:GetTagged("WP_Node")`, builds adjacency graph, discovers POIs/seats
3. Calls `SeatManager.init(nodeGraph)` — indexes all social POI seats from the built graph
4. Calls `StartupValidator.validate(nodeGraph)` — checks all workspace contracts. If any fail → prints errors, returns false → system halts
5. Creates RemoteEvent instances in `ReplicatedStorage.WanderingPropsRemotes/`
6. Connects `Players.PlayerAdded` for late-join sync
7. Starts heartbeat loop

### 2. NPC Spawn
1. `PopulationController` heartbeat detects `activeCount < desiredPopulation`
2. Rolls `GROUP_SPAWN_CHANCE` — if group, picks group size (2–4); otherwise single
3. Calls `RouteBuilder.buildRoute(nodeGraph, seatManager)`:
   a. Picks random spawn node from `nodeGraph.getSpawnNodes()`
   b. Selects 2–4 POIs by weighted random from `nodeGraph.getPOINodes()` (no duplicates)
   c. For each social POI: calls `seatManager.claimSeat(poiNodeId)` → gets `SeatClaim?`. If nil (no seats), skips POI, picks replacement
   d. Picks random despawn node from `nodeGraph.getDespawnNodes()`
   e. For each leg (spawn→POI1, POI1→POI2, ..., lastPOI→despawn): calls `nodeGraph.findPath(fromId, toId, excludeId)` where excludeId = previous approach node (anti-backtracking)
   f. For each walk segment: rolls `WANDER_CHANCE` per intermediate node. If triggered, finds nearby off-path node via `nodeGraph.getNodesInRadius()`, validates reachability (tries 2 candidates), inserts detour steps
   g. Flattens all path segments into a single `{RouteStep}` array with computed positions and distances
   h. For zone nodes: picks random point within zone boundary (part Position ± Size/2, constrained to XZ plane)
   i. Pre-computes `stepDurations` and `cumulativeTimes`
   j. Returns `RouteResult` or nil if route building failed
4. Assigns `npcId` ("wp_" + incrementing counter), picks random `modelIndex`, computes `walkSpeed` (BASE ± random VARIATION)
5. Calls `NPCRegistry.createNPC(npcData)` — stores in registry
6. Fires `WP_Spawn` RemoteEvent to all clients with `SpawnPayload`
7. `Diagnostics.log(npcId, "spawned", spawnNodeName)` + trail entry

### 3. Server Heartbeat (Step Advancement)
1. Runs every `SERVER_TICK_RATE` seconds (time accumulator on Heartbeat)
2. For each NPC in `NPCRegistry.getAllNPCs()`:
   a. `elapsed = os.clock() - npc.spawnTime`
   b. While `elapsed > npc.cumulativeTimes[npc.currentStepIndex]` and more steps remain:
      - If completed step was `"social"`: calls `SeatManager.releaseSeat(step.seatId)`
      - Advances `npc.currentStepIndex += 1`
      - `Diagnostics.trail(npcId, stepDescription)`
   c. If all steps completed (past last cumulative time):
      - Fires `WP_Despawn` to all clients
      - Calls `NPCRegistry.removeNPC(npcId)`
      - `Diagnostics.log(npcId, "despawned", "route_complete")`
3. Maintains `spawnAccumulator += SERVER_TICK_RATE`. When `spawnAccumulator >= SPAWN_INTERVAL`, runs population check/spawn logic once and subtracts `SPAWN_INTERVAL`.

### 4. Client NPC Spawn
1. `NPCClient` receives `WP_Spawn` event
2. **Core path:** Clones model from `modelList[modelIndex]` where `modelList` is built once from `ReplicatedStorage.WanderingPropModels:GetChildren()` and sorted by model name on both server and client
   **Optimization path:** `ModelPool.acquire(modelIndex)` → returns pooled model
3. Sets model `PrimaryPart.Anchored = true`, all BasePart descendants `CanCollide = false`
4. Parents model to `workspace.WanderingProps.ActiveNPCs`
5. Calls `NPCAnimator.setup(model)` → finds AnimationController, gets Animator, loads walk/idle/sit tracks → returns `AnimatorHandle`
6. Pre-computes `stepDurations` and `cumulativeTimes` (same math as server)
7. Records `startTime = os.clock()`
8. Calls `NPCMover.startMoving(npcId, clientNPC)` (spawn path uses defaults: stepIndex=1, stepElapsed=0)
9. **Optimization:** Calls `LODController.register(npcId, model)`

### 5. Client Movement (per-frame)
1. `NPCMover` runs on `RunService.Heartbeat`
2. For each active NPC:
   a. Check LOD tier — skip if update not due this frame (low: every 3 frames, mid: every 6, far: skip entirely)
   b. `elapsed = os.clock() - npc.startTime`
   c. Determine current step: binary search `cumulativeTimes` for the step where `elapsed` falls
   d. If step changed from last frame: handle animation transition (walk→idle, walk→sit, etc.)
   e. Compute `stepProgress` = time-within-step / stepDuration (0.0 → 1.0)
   f. **Walk step:** Lerp position from previous targetPosition to current targetPosition by stepProgress
   g. **Scenic step:** Hold at targetPosition, face viewPosition
   h. **Social step:** Hold at seatCFrame
   i. **Despawn step:** Hold at targetPosition (fade-out handled separately)
   j. **Ground snap** (walk steps only): Raycast from (lerpedX, lerpedY + GROUND_SNAP_HEIGHT, lerpedZ) downward by GROUND_SNAP_DISTANCE. Use filtered RaycastParams. If hit, use hitPosition.Y for final Y.
   k. Set `model:PivotTo(CFrame.lookAt(finalPosition, lookTarget))` where lookTarget = targetPosition for walk, viewPosition for scenic
   l. Update `npc.virtualPosition` (for LOD distance checks)

### 6. Ground Snap Raycast Filter
- `RaycastParams.FilterType = Enum.RaycastFilterType.Exclude`
- `RaycastParams.FilterDescendantsInstances` contains:
  - `workspace.WanderingProps.Nodes` folder (all navigation parts)
  - `workspace.WanderingProps.ActiveNPCs` folder (all NPC models)
  - Each player's `Character` model (added on PlayerAdded/CharacterAdded, removed on removal)
- Filter list is built once at client start, player characters added/removed dynamically

### 7. NPC Despawn (Client)
1. `NPCClient` receives `WP_Despawn` event with npcId
2. Calls `NPCMover.stopMoving(npcId)` — removes from movement loop
3. Calls `NPCAnimator.cleanup(handle)` — stops all tracks
4. **Core path:** `model:Destroy()`
   **Optimization path:** `LODController.unregister(npcId)`, then `ModelPool.release(model)`
5. Removes from local NPC table

### 8. Late-Join Sync
1. `Players.PlayerAdded` fires on server
2. `PopulationController` builds `BulkSyncEntry` for each NPC in registry:
   - `currentStepIndex` = server's tracked step
   - `stepElapsed` = time elapsed within that step
3. Fires `WP_BulkSync` to the joining player only
4. Client receives, creates each NPC as in flow #4, then calls `NPCMover.startMoving(npcId, clientNPC, currentStepIndex, stepElapsed)` so it begins mid-route

### 9. Population Management
1. `desiredPopulation` = lerp between `MIN_POPULATION` and `MAX_POPULATION` (ramps up over first 30s to avoid spawn burst)
2. If `DAY_NIGHT_ENABLED` and `workspace:FindFirstChild(NIGHT_INDICATOR_NAME)` exists and `.Value == true`: multiply desired by `NIGHT_POPULATION_MULTIPLIER`
3. Spawn logic runs when `spawnAccumulator >= SPAWN_INTERVAL` (not every server tick)
4. If `activeCount < desiredPopulation`: spawn (single or group, per config rolls)
5. If `activeCount > desiredPopulation` (night transition): stop spawning, let NPCs naturally despawn via route completion. No forced culling.

---

## Module API Specifications

### Config.luau
```lua
-- Returns a frozen table. All values are constants.
return table.freeze({ ... })  -- see Config File Structure section
```

### Types.luau
```lua
-- Exports all type aliases. No runtime code.
-- See Data Structures section for all types.
```

### Diagnostics.luau
```lua
local Diagnostics = {}

-- Log an action for an NPC. No-op if DEBUG_MODE is false.
function Diagnostics.log(npcId: string, action: string, detail: string): ()

-- Add an entry to an NPC's trail ring buffer.
function Diagnostics.trail(npcId: string, entry: string): ()

-- Get the trail for an NPC (last N entries).
function Diagnostics.getTrail(npcId: string): {string}

-- Clear trail data for an NPC (call on despawn).
function Diagnostics.clearTrail(npcId: string): ()

-- Increment a health counter.
function Diagnostics.increment(counter: string, reason: string?): ()

-- Decrement a health counter.
function Diagnostics.decrement(counter: string, reason: string?): ()

-- Print health summary to output. No-op if DEBUG_MODE is false.
function Diagnostics.printHealth(): ()

-- Print a single NPC's trail to output. No-op if DEBUG_MODE is false.
function Diagnostics.printTrail(npcId: string): ()

return Diagnostics
```

### NodeGraph.luau
```lua
local NodeGraph = {}

-- Scans workspace for WP_Node/WP_POI/WP_Seat/WP_ViewZone tagged parts.
-- Builds adjacency graph. Returns true on success.
function NodeGraph.build(): boolean

-- Dijkstra shortest path from fromId to toId.
-- excludeFirstHop: node ID to exclude from the first hop (anti-backtracking).
-- Returns ordered array of node IDs (including from and to), or nil if no path.
function NodeGraph.findPath(fromId: string, toId: string, excludeFirstHop: string?): {string}?

-- Get node data by ID.
function NodeGraph.getNode(nodeId: string): NodeData?

-- Get all spawn-role nodes.
function NodeGraph.getSpawnNodes(): {NodeData}

-- Get all despawn-role nodes.
function NodeGraph.getDespawnNodes(): {NodeData}

-- Get all POI nodes.
function NodeGraph.getPOINodes(): {NodeData}

-- Get all nodes within radius studs of position (Euclidean distance).
function NodeGraph.getNodesInRadius(position: Vector3, radius: number): {NodeData}

-- Get the position for a node. For zones, returns a random point within the zone boundary.
function NodeGraph.resolvePosition(nodeId: string): Vector3

return NodeGraph
```

### SeatManager.luau
```lua
local SeatManager = {}

-- Initialize from built NodeGraph. Indexes all social POI seats.
function SeatManager.init(nodeGraph: typeof(NodeGraph)): ()

-- Try to claim a seat at a social POI node.
-- Respects SOCIAL_CAPACITY_PERCENT cap.
-- Prefers tables with existing sitters (SOCIAL_GROUP_WEIGHT).
-- Returns SeatClaim with seatId + cframe, or nil if no seat available.
function SeatManager.claimSeat(poiNodeId: string): SeatClaim?

-- Release a previously claimed seat.
function SeatManager.releaseSeat(seatId: string): ()

-- Get occupancy info for a POI (for diagnostics).
function SeatManager.getOccupancy(poiNodeId: string): (number, number) -- (occupied, total)

return SeatManager
```

### NPCRegistry.luau
```lua
local NPCRegistry = {}

-- Add an NPC to the registry.
function NPCRegistry.createNPC(data: NPCData): ()

-- Remove an NPC from the registry.
function NPCRegistry.removeNPC(npcId: string): ()

-- Get a single NPC's data (mutable reference).
function NPCRegistry.getNPC(npcId: string): NPCData?

-- Get all NPCs as {[npcId]: NPCData}.
function NPCRegistry.getAllNPCs(): {[string]: NPCData}

-- Get count of active NPCs.
function NPCRegistry.getActiveCount(): number

-- Generate next NPC ID ("wp_1", "wp_2", ...).
function NPCRegistry.nextId(): string

return NPCRegistry
```

### RouteBuilder.luau
```lua
local RouteBuilder = {}

export type RouteResult = {
    route: {RouteStep},
    stepDurations: {number},
    cumulativeTimes: {number},
    totalDuration: number,
    startPosition: Vector3,
    spawnNodeId: string,
}

-- Build a single NPC route. Returns nil if route building fails.
function RouteBuilder.buildRoute(nodeGraph: typeof(NodeGraph), seatManager: typeof(SeatManager)): RouteResult?

-- Build routes for a group of NPCs (shared POI sequence, varied positions/speeds).
-- Returns nil if route building fails.
function RouteBuilder.buildGroupRoute(
    count: number,
    nodeGraph: typeof(NodeGraph),
    seatManager: typeof(SeatManager)
): {RouteResult}?

return RouteBuilder
```

### PopulationController.server.luau
```lua
-- Script (entry point). No public API.
-- Initialization sequence:
--   1. NodeGraph.build()
--   2. SeatManager.init(nodeGraph)
--   3. StartupValidator.validate(nodeGraph) → halt if fails
--   4. Create RemoteEvents in ReplicatedStorage
--   5. Connect PlayerAdded for bulk sync
--   6. Start heartbeat loop
--
-- Heartbeat loop (every SERVER_TICK_RATE):
--   1. Advance all NPC step timers
--   2. Process step completions (seat releases, despawns)
--   3. Fire WP_Despawn for completed NPCs
--   4. Check population, spawn new NPCs if needed:
--        - Roll GROUP_SPAWN_CHANCE. If group: call buildGroupRoute(count, ...).
--          If buildGroupRoute returns nil, fall back to buildRoute() for a single NPC.
--          If buildRoute also returns nil, increment rejects counter and skip this tick.
--        - If single: call buildRoute(). If nil, increment rejects and skip tick.
--        - Population will catch up on the next tick naturally.
--   5. Fire WP_Spawn for new NPCs
--   6. Periodically print diagnostics health (every 10s if DEBUG_MODE)
```

### StartupValidator.luau
```lua
local StartupValidator = {}

-- Run all workspace contract checks. Returns (passed, errors).
-- If passed is false, errors contains human-readable error messages.
function StartupValidator.validate(nodeGraph: typeof(NodeGraph)): (boolean, {string})

return StartupValidator
```

### NPCAnimator.luau
```lua
local NPCAnimator = {}

-- Find AnimationController+Animator on model, load animation tracks.
-- Returns handle for subsequent calls, or nil if model is malformed.
function NPCAnimator.setup(model: Model): AnimatorHandle?

-- Play walk animation. Speed scales to match movement: track.Speed = walkSpeed / BASE_WALK_SPEED.
function NPCAnimator.playWalk(handle: AnimatorHandle, walkSpeed: number): ()

-- Play idle animation (scenic dwell, waiting).
function NPCAnimator.playIdle(handle: AnimatorHandle): ()

-- Play sit animation (social POI).
function NPCAnimator.playSit(handle: AnimatorHandle): ()

-- Stop all animation tracks.
function NPCAnimator.stopAll(handle: AnimatorHandle): ()

-- Enable/disable animation playback (LOD optimization).
-- When disabled, stops all tracks. When re-enabled, caller must restart appropriate animation.
function NPCAnimator.setEnabled(handle: AnimatorHandle, enabled: boolean): ()

-- Clean up: stop tracks, release references.
function NPCAnimator.cleanup(handle: AnimatorHandle): ()

return NPCAnimator
```

### NPCMover.luau
```lua
local NPCMover = {}

-- Begin moving an NPC through its route. Called on spawn or late-join.
-- stepIndex/stepElapsed are optional for late-join sync (defaults: 1, 0).
function NPCMover.startMoving(
    npcId: string,
    clientNPC: ClientNPC,
    stepIndex: number?,
    stepElapsed: number?
): ()

-- Stop movement for an NPC. Removes from update loop.
function NPCMover.stopMoving(npcId: string): ()

-- Set LOD tier for an NPC (controls update frequency).
function NPCMover.setLODTier(npcId: string, tier: "near" | "low" | "mid" | "far"): ()

-- Called internally every Heartbeat frame. Iterates all moving NPCs.
-- Not a public API — connected to RunService.Heartbeat in module init.

return NPCMover
```

### NPCClient.client.luau
```lua
-- LocalScript (entry point). No public API.
-- Initialization:
--   1. Wait for WanderingPropsRemotes folder in ReplicatedStorage
--   2. Create ActiveNPCs folder in workspace.WanderingProps (if not exists)
--   3. Build raycast filter params
--   4. Connect WP_Spawn, WP_Despawn, WP_BulkSync RemoteEvent listeners
--   5. Connect PlayerAdded/CharacterAdded for raycast filter updates
--
-- On WP_Spawn: create model, setup animator, start mover, register LOD
-- On WP_Despawn: stop mover, cleanup animator, destroy/release model, unregister LOD
-- On WP_BulkSync: create all NPCs with stepIndex/stepElapsed offsets
--
-- Core/Optimization fallback:
--   If ModelPool module exists → use ModelPool.acquire/release for model lifecycle
--   If ModelPool module does NOT exist → fall back to direct Clone/Destroy
--   If LODController module exists → register NPCs for LOD tracking
--   If LODController module does NOT exist → all NPCs run at near-tier quality (full update every frame, all animations active)
```

### ModelPool.luau (Optimization)
```lua
local ModelPool = {}

-- Pre-create pool of model clones at startup. Called once.
-- poolSize: how many of each model to pre-create (default: Config.MAX_POPULATION / modelCount + buffer).
function ModelPool.init(models: {Model}, poolSize: number?): ()

-- Get a model from the pool. Falls back to Clone if pool empty.
function ModelPool.acquire(modelIndex: number): Model

-- Return a model to the pool. Resets CFrame, unparents, stops animations.
function ModelPool.release(model: Model): ()

return ModelPool
```

### LODController.luau (Optimization)
```lua
local LODController = {}

-- Start the LOD check timer. Called once at client startup.
function LODController.init(): ()

-- Register an NPC for LOD tracking.
-- LODController owns tier transitions internally and calls NPCMover.setLODTier().
function LODController.register(npcId: string, model: Model): ()

-- Unregister an NPC from LOD tracking.
function LODController.unregister(npcId: string): ()

-- Update the position used for distance calculation (called by NPCMover each update).
function LODController.updatePosition(npcId: string, position: Vector3): ()

-- Internal: runs every LOD_CHECK_INTERVAL. Checks camera distance, fires callbacks on tier changes.

return LODController
```

---

## Diagnostics Module Design

### Lifecycle Reason Codes
```lua
local ReasonCodes = {
    -- Creation
    SPAWNED = "spawned",              -- single NPC spawn
    SPAWNED_GROUP = "spawned_group",  -- group spawn member

    -- State changes
    STEP_ADVANCE = "step_advance",    -- moved to next route step
    WALK_START = "walk_start",        -- began walking to node
    DWELL_START = "dwell_start",      -- began scenic dwell
    SIT_START = "sit_start",          -- began social sit
    WANDER_DETOUR = "wander_detour",  -- wander deviation inserted

    -- Destruction
    ROUTE_COMPLETE = "route_complete",-- normal route finish at despawn node
    STUCK_DESPAWN = "stuck_despawn",  -- no valid route found, despawned in place

    -- Failures (not NPC destruction, but route-building rejects)
    NO_ROUTE = "no_route",            -- RouteBuilder returned nil
    NO_SEAT = "no_seat",              -- social POI seat claim failed (POI skipped)
    NO_PATH = "no_path",              -- no graph path between two nodes
    WANDER_FAIL = "wander_fail",      -- wander candidates both unreachable
    POI_SKIP = "poi_skip",            -- POI skipped for any reason
}
```

### Health Counters
- `activeCount` — current live NPCs (increment on spawn, decrement on despawn)
- `totalSpawned` — lifetime spawn count
- `totalDespawned` — lifetime, broken down by reason (route_complete, stuck_despawn)
- `totalRejects` — broken down by reason (no_route, no_seat, no_path)
- `seatOccupied` — current total seats occupied across all social POIs
- `seatTotal` — total seats across all social POIs

### Per-Entity Trail
- Ring buffer of last `DIAG_TRAIL_LENGTH` actions per npcId (default 8)
- Format: `"action:detail"` — e.g., `"spawned_at:Spawn1"`, `"walk_to:Node7"`, `"scenic_dwell:CafeView"`, `"sit:ParkBench.Seat2"`, `"despawn:Despawn1"`
- Cleared when NPC is removed

### Output Format
```
[WP] npc wp_42 | spawned_at:Spawn1 → walk_to:Node3 → scenic_dwell:CafeView → walk_to:Node7
[WP] Health | active: 45 | spawned: 123 | despawned: 78 (route:76 stuck:2) | rejects: 5
[WP] Seats | 12/20 occupied (60%)
```

### Toggle
- All logging gated behind `Config.DEBUG_MODE == true`
- When `DEBUG_MODE == false`: all functions are no-ops (zero overhead)
- Health summary auto-prints every 10 seconds when enabled

---

## Startup Validators

| # | Contract | Check | Error Message |
|---|----------|-------|---------------|
| 1 | NPC models exist | `ReplicatedStorage:FindFirstChild("WanderingPropModels")` has ≥1 Model child | `[WP] ERROR: No NPC models found in ReplicatedStorage.WanderingPropModels` |
| 2 | Models have AnimationController | Each Model child has an AnimationController descendant | `[WP] ERROR: Model 'X' missing AnimationController` |
| 3 | Models have PrimaryPart | Each Model child has PrimaryPart set | `[WP] ERROR: Model 'X' has no PrimaryPart set` |
| 4 | Spawn nodes exist | ≥1 WP_Node with NodeRole="spawn" in built graph | `[WP] ERROR: No spawn nodes found. Tag a part WP_Node with NodeRole="spawn"` |
| 5 | Despawn nodes exist | ≥1 WP_Node with NodeRole="despawn" in built graph | `[WP] ERROR: No despawn nodes found. Tag a part WP_Node with NodeRole="despawn"` |
| 6 | POIs exist | ≥1 WP_POI tagged part in built graph | `[WP] ERROR: No points of interest found. Tag a part with WP_POI` |
| 7 | Nodes are BaseParts | All WP_Node tagged instances pass `:IsA("BasePart")` | `[WP] ERROR: 'X' tagged WP_Node is not a BasePart` |
| 8 | Nodes have valid connections | Each WP_Node has ≥1 ObjectValue child whose `.Value` is a BasePart with the `WP_Node` tag | `[WP] ERROR: Node 'X' has no valid connections (add ObjectValue children whose Value points to another WP_Node part)` |
| 9 | No self-connections | No ObjectValue points back to its parent node | `[WP] ERROR: Node 'X' has a self-connection` |
| 10 | Graph connectivity | BFS from any spawn node can reach at least one despawn node | `[WP] ERROR: No path exists from any spawn to any despawn. Check node connections.` |
| 11 | Scenic POIs have ViewZone | Each scenic POI has a child tagged WP_ViewZone | `[WP] ERROR: Scenic POI 'X' missing WP_ViewZone child` |
| 12 | Social POIs have seats | Each social POI has ≥1 child tagged WP_Seat | `[WP] ERROR: Social POI 'X' has no WP_Seat children` |
| 13 | Seats are BaseParts | All WP_Seat tagged instances pass `:IsA("BasePart")` | `[WP] ERROR: Seat 'X' in POI 'Y' is not a BasePart` |
| 14 | Animation IDs configured | Config animation IDs ≠ `"rbxassetid://0"` | `[WP] ERROR: Animation IDs not configured in Config.luau (still using placeholder)` |
| 15 | Config values valid | MIN_POPULATION ≤ MAX_POPULATION, speeds > 0, ranges valid, and `SPAWN_INTERVAL >= SERVER_TICK_RATE` | `[WP] ERROR: Config.MIN_POPULATION (X) > Config.MAX_POPULATION (Y)` or `[WP] ERROR: Config.SPAWN_INTERVAL (X) must be >= Config.SERVER_TICK_RATE (Y)` |
| 16 | POIs reachable | Each POI node can be reached from at least one spawn node AND can reach at least one despawn node (BFS) | `[WP] ERROR: POI 'X' is unreachable from all spawn nodes` or `[WP] ERROR: POI 'X' cannot reach any despawn node` |
| 17 | Node IDs are unique | No duplicate part names among all `WP_Node` tagged BaseParts (since node ID = part.Name) | `[WP] ERROR: Duplicate WP_Node name 'X'. Rename nodes so each WP_Node has a unique Name.` |
| 18 | Model index mapping is deterministic | No duplicate model names under `ReplicatedStorage.WanderingPropModels`; server/client both sort by name before indexing | `[WP] ERROR: Duplicate model name 'X' in WanderingPropModels. Model names must be unique for deterministic modelIndex mapping.` |

Validators run **once** at server start, before the heartbeat loop begins. If any check fails, the error is printed via `warn()` and the system does not start.

---

## Golden Test Scenarios

### Scenario 1: Basic NPC Lifecycle
- **Setup:** 4 spot nodes in a chain: Spawn1 → Node1 → CafeView (scenic POI, POIWeight=1, with WP_ViewZone child) → Despawn1. All connected via ObjectValues. 1 model in WanderingPropModels.
- **Config overrides:** `MIN_POPULATION=1, MAX_POPULATION=1, WANDER_CHANCE=0, GROUP_SPAWN_CHANCE=0, DEBUG_MODE=true`
- **Action:** Start server in Studio (Play Solo).
- **Expected:** Within 5 seconds, 1 NPC spawns at Spawn1, walks to Node1, walks to CafeView, stops and faces ViewZone for 4–10 seconds (scenic dwell), walks to Despawn1, disappears. ~2 seconds later, a new NPC spawns.
- **Pass condition:**
  - Visual: NPC walks smoothly along ground, stops at scenic POI, faces the ViewZone part, then continues and vanishes at despawn
  - Diagnostics output shows: `spawned_at:Spawn1 → walk_to:Node1 → walk_to:CafeView → scenic_dwell:CafeView → walk_to:Despawn1 → despawn:route_complete`
  - Health counter shows active=1, spawned incrementing, despawned incrementing

### Scenario 2: Social POI Seating
- **Setup:** 5 spot nodes in a loop: Spawn1 → Node1 → ParkBench (social POI, 2 WP_Seat children) → Node2 → Despawn1. Node2 also connects back to Node1. 1 model.
- **Config overrides:** `MIN_POPULATION=2, MAX_POPULATION=2, MIN_POIS_PER_ROUTE=1, MAX_POIS_PER_ROUTE=1, WANDER_CHANCE=0, GROUP_SPAWN_CHANCE=0, DEBUG_MODE=true`
- **Action:** Start server. Wait for 2 NPCs to spawn and reach ParkBench.
- **Expected:** Each NPC walks to ParkBench, snaps to a seat CFrame, plays sit animation for 8–20 seconds, then stands and continues to despawn.
- **Pass condition:**
  - Visual: Both NPCs sit in separate seats simultaneously, play sit animation, then leave
  - Diagnostics shows: `sit_start` trail entries for both NPCs with different seat IDs
  - Seats output shows: `2/2 occupied (100%)` while both sitting, then `0/2` after they leave

### Scenario 3: Population Pressure (Steady State)
- **Setup:** 12+ nodes forming a network with 2 spawns, 2 despawns, and 3 POIs (1 scenic, 1 busy, 1 social with 4 seats). Multiple paths between spawns and despawns.
- **Config overrides:** `MIN_POPULATION=5, MAX_POPULATION=10, DEBUG_MODE=true`
- **Action:** Start server. Wait 60 seconds.
- **Expected:** Population ramps to 5–10 within 20 seconds, then stays stable. NPCs cycle continuously through spawn→POI→despawn. No NPCs stuck indefinitely (no stuck_despawn reasons if graph is well-connected).
- **Pass condition:**
  - Health output shows: active count stable between 5–10, spawned/despawned counts both climbing, zero stuck_despawn entries
  - Visual: NPCs distributed across the node graph, some walking, some at scenic POI, some sitting, continuous flow

### Scenario 4: Late-Join Sync
- **Setup:** Same as Scenario 3, but start with 2-player test (Studio local server + 1 client).
- **Config overrides:** `MIN_POPULATION=5, MAX_POPULATION=5, DEBUG_MODE=true`
- **Action:** Start server, wait 30 seconds for NPCs to spread out. Then connect second client.
- **Expected:** Within 1 second of second client connecting, they see all 5 NPCs at their current route positions, mid-walk/dwell. NPCs continue moving from their current positions, not restarting from spawn.
- **Pass condition:**
  - Both clients show same number of NPCs (5)
  - NPC positions are approximately the same on both clients (within 5 studs of drift)
  - No NPCs teleporting or snapping to spawn points on the second client

---

## UI Architecture

This system has **no player-facing UI**. NPCs are purely ambient and non-interactive.

- **Screens/Elements:** None
- **State Management:** N/A
- **Backend Communication:** N/A

Diagnostics output goes to the Roblox Output window (print/warn), visible only in Studio or to developers with console access. No ScreenGui, BillboardGui, or other UI elements.

---

## Security Model

- **Server owns:** NPC population state, route generation, seat claiming/releasing, step advancement timing, spawn/despawn decisions. All game logic is server-authoritative.
- **Client can request:** Nothing. All RemoteEvents are **server → client only**. The client never fires any RemoteEvent to the server for this system.
- **Validation on each RemoteEvent:** N/A — no client → server events exist. The system is purely broadcast (server tells clients what to display).
- **Abuse surface:** Minimal. No player interaction with NPCs. No collision. No way for clients to influence NPC behavior. A malicious client could only affect their own local rendering (which doesn't impact other players).
- **Model security:** NPC models are stored in ReplicatedStorage (visible to clients, required for cloning). This is acceptable — the models are visual assets, not game logic.

---

## Performance Strategy

### Server
- **Tick rate:** PopulationController heartbeat runs every `SERVER_TICK_RATE` (0.5s). Checks all NPCs for step advancement. At 70 NPCs this is ~70 comparisons every 0.5s — negligible.
- **Route building:** Dijkstra pathfinding runs at spawn time only. Graph has ~50-200 nodes (typical buyer setup). Each Dijkstra is O(N log N). At 1-2 spawns per second, this is negligible.
- **Seat management:** O(1) claim/release via dictionary lookup.
- **No physics:** NPCs are moved via client CFrame, not server physics. Server does zero physics work for NPCs.

### Client
- **LOD system (optimization layer):** 4 tiers reduce client workload:
  - `near` (< LOD_NEAR_DISTANCE studs): CFrame update every frame, animation active
  - `low` (< LOD_LOW_DISTANCE): CFrame update every `LOD_LOW_UPDATE_FRAMES` frames, animation active
  - `mid` (< LOD_MID_DISTANCE): CFrame update every `LOD_MID_UPDATE_FRAMES` frames, animation stopped
  - `far` (≥ LOD_MID_DISTANCE): Model unparented (hidden), no CFrame updates, position tracked virtually
- **Model pooling (optimization layer):** ModelPool pre-clones models at startup. Acquire/release avoids per-NPC Clone/Destroy overhead. Pool size = MAX_POPULATION / model count + small buffer.
- **Ground snap raycasts:** Only during walk steps, only when CFrame is being updated (respects LOD skip). One raycast per NPC per update frame.
- **Raycast filter:** Uses folder-level filtering (2 folders + player characters). Not per-part filtering.
- **Animation:** AnimationController + Animator is lightweight without Humanoid. No state machine overhead. Animation tracks are loaded once per model and reused.
- **CFrame updates:** `model:PivotTo()` once per update frame per visible NPC. At 70 NPCs with LOD, worst case ~30 PivotTo calls per frame (near + low tiers).

### Memory
- **NPC models:** At most MAX_POPULATION models in workspace. With ModelPool, total clones = pool size (slightly above MAX_POPULATION).
- **Route data:** ~10-20 RouteStep entries per NPC, ~200 bytes each. 70 NPCs × 200 × 15 = ~210 KB. Negligible.
- **NodeGraph:** Built once, stored as tables. ~200 nodes × ~100 bytes = ~20 KB.

---

## Config File Structure

```lua
-- Config.luau
-- All tunable values for the Wandering Props system.
-- Buyers: edit values here to customize NPC behavior for your game.

return table.freeze({
    -------------------------------------------------------------------
    -- DEBUG
    -------------------------------------------------------------------
    DEBUG_MODE = false,       -- Enable diagnostics output to console. Set true when testing. Range: true/false.
    DIAG_TRAIL_LENGTH = 8,   -- Actions per NPC to keep in diagnostics trail. Range: 3-20.

    -------------------------------------------------------------------
    -- POPULATION
    -------------------------------------------------------------------
    MIN_POPULATION = 40,     -- Minimum NPCs alive at any time. Range: 1-200.
    MAX_POPULATION = 70,     -- Maximum NPCs alive at any time. Range: MIN_POPULATION-200.
    SPAWN_INTERVAL = 2.0,    -- Seconds between spawn attempts while under target population. Must be >= SERVER_TICK_RATE. Range: 0.5-10.
    SPAWN_RAMP_TIME = 30,    -- Seconds to ramp from 0 to MIN_POPULATION at startup. Range: 5-120.

    -------------------------------------------------------------------
    -- MOVEMENT
    -------------------------------------------------------------------
    BASE_WALK_SPEED = 10,    -- Base NPC walk speed in studs/second. Range: 4-20.
    WALK_SPEED_VARIATION = 2,-- +/- random studs/second per NPC. Range: 0-5.
    GROUND_SNAP_HEIGHT = 5,  -- Raycast start height above NPC position (studs). Range: 2-10.
    GROUND_SNAP_DISTANCE = 10,-- Raycast downward distance (studs). Range: 5-20.

    -------------------------------------------------------------------
    -- ROUTES
    -------------------------------------------------------------------
    MIN_POIS_PER_ROUTE = 2,  -- Minimum POI visits per route. Range: 1-6.
    MAX_POIS_PER_ROUTE = 4,  -- Maximum POI visits per route. Range: MIN_POIS-8.
    WANDER_CHANCE = 0.15,    -- Probability per walk segment of a wander detour. Range: 0-1.
    WANDER_MAX_DISTANCE = 30,-- Max distance (studs) to consider wander nodes. Range: 10-100.

    -------------------------------------------------------------------
    -- GROUP SPAWNING
    -------------------------------------------------------------------
    GROUP_SPAWN_CHANCE = 0.2, -- Chance that a spawn creates a group. Range: 0-1.
    GROUP_SIZE_MIN = 2,       -- Minimum NPCs in a group. Range: 2-4.
    GROUP_SIZE_MAX = 4,       -- Maximum NPCs in a group. Range: GROUP_SIZE_MIN-6.
    GROUP_SPEED_VARIATION = 1,-- Speed spread within group (studs/s). Range: 0-3.

    -------------------------------------------------------------------
    -- SCENIC POI
    -------------------------------------------------------------------
    SCENIC_DWELL_MIN = 4.0,  -- Min seconds NPC idles at scenic POI. Range: 1-30.
    SCENIC_DWELL_MAX = 10.0, -- Max seconds NPC idles at scenic POI. Range: SCENIC_DWELL_MIN-60.

    -------------------------------------------------------------------
    -- SOCIAL POI
    -------------------------------------------------------------------
    SOCIAL_DWELL_MIN = 8.0,  -- Min seconds NPC sits at social POI. Range: 2-60.
    SOCIAL_DWELL_MAX = 20.0, -- Max seconds NPC sits at social POI. Range: SOCIAL_DWELL_MIN-120.
    SOCIAL_CAPACITY_PERCENT = 0.75, -- Max fraction of seats that can be occupied per POI. Range: 0.1-1.0.
    SOCIAL_GROUP_WEIGHT = 0.7,      -- Probability of preferring a table with existing sitters. Range: 0-1.

    -------------------------------------------------------------------
    -- ANIMATIONS
    -------------------------------------------------------------------
    WALK_ANIMATION_ID = "rbxassetid://0",  -- Walk animation asset ID. Buyer MUST set this.
    IDLE_ANIMATION_ID = "rbxassetid://0",  -- Idle animation asset ID. Buyer MUST set this.
    SIT_ANIMATION_ID = "rbxassetid://0",   -- Sit animation asset ID. Buyer MUST set this.

    -------------------------------------------------------------------
    -- LOD (Optimization Layer)
    -------------------------------------------------------------------
    LOD_NEAR_DISTANCE = 50,      -- Max studs for near tier (full quality). Range: 20-100.
    LOD_LOW_DISTANCE = 100,      -- Max studs for low tier (reduced update). Range: LOD_NEAR-200.
    LOD_MID_DISTANCE = 200,      -- Max studs for mid tier (no animation). Beyond = far (hidden). Range: LOD_LOW-500.
    LOD_CHECK_INTERVAL = 1.5,    -- Seconds between LOD tier recalculation. Range: 0.5-5.
    LOD_LOW_UPDATE_FRAMES = 3,   -- CFrame update every N frames at low tier. Range: 2-6.
    LOD_MID_UPDATE_FRAMES = 6,   -- CFrame update every N frames at mid tier. Range: 4-12.

    -------------------------------------------------------------------
    -- DAY/NIGHT CYCLE
    -------------------------------------------------------------------
    DAY_NIGHT_ENABLED = false,           -- Enable day/night population scaling. Range: true/false.
    NIGHT_POPULATION_MULTIPLIER = 0.5,   -- Multiply desired population by this at night. Range: 0.1-1.0.
    NIGHT_INDICATOR_NAME = "WP_IsNight", -- Name of BoolValue under workspace. Game's day/night system sets this.

    -------------------------------------------------------------------
    -- TIMING
    -------------------------------------------------------------------
    SERVER_TICK_RATE = 0.5,    -- Seconds between server heartbeat ticks. Range: 0.1-2.0.
    DESPAWN_LINGER = 1.0,      -- Seconds NPC lingers at despawn point before removal. Range: 0-5.
})
```

---

## Integration Points

- **Day/Night Cycle:** The buyer's existing day/night system creates a `BoolValue` named `Config.NIGHT_INDICATOR_NAME` (default: `"WP_IsNight"`) as a child of `workspace`. When `.Value == true`, PopulationController multiplies desired population by `NIGHT_POPULATION_MULTIPLIER`. If `DAY_NIGHT_ENABLED == false` or the BoolValue doesn't exist, population is constant.
- **Other Game Systems:** None. The Wandering Props system is fully isolated. NPCs don't interact with players, other NPCs, or any other game system. No shared state, no shared events, no dependencies.

---

## Integration Pass Results

### Data Lifecycle Traces

**npcId (string: "wp_1", "wp_2", ...)**
- **Created by:** `NPCRegistry.nextId()` → returns `"wp_" .. counter`; counter incremented
- **Passed via:** return value → PopulationController stores in NPCData → sent via WP_Spawn RemoteEvent payload → received by NPCClient
- **Received by:** NPCClient (via RemoteEvent `SpawnPayload.npcId`) → passed to NPCMover.startMoving, LODController.register
- **Stored in:** Server: `NPCRegistry._npcs[npcId]` (lifetime: spawn→despawn). Client: local `_npcs[npcId]` table (lifetime: spawn event→despawn event)
- **Cleaned up by:** Server: `NPCRegistry.removeNPC(npcId)` deletes from `_npcs`. Client: despawn handler deletes from local table. Diagnostics: `Diagnostics.clearTrail(npcId)`.
- **Verified:** Type is string everywhere. Created once, never mutated. Cleanup on both server (removeNPC) and client (despawn handler) covers all paths. Trail cleanup tied to removeNPC call.

**route ({RouteStep})**
- **Created by:** `RouteBuilder.buildRoute()` → returns `RouteResult.route`
- **Passed via:** return value → PopulationController copies into NPCData → sent via WP_Spawn / WP_BulkSync RemoteEvent → received by NPCClient
- **Received by:** NPCClient (via RemoteEvent payload) → passed to NPCMover.startMoving → stored in ClientNPC.route
- **Stored in:** Server: `NPCRegistry._npcs[npcId].route`. Client: `ClientNPC.route`. Both hold the same data (server is source of truth, client receives a copy).
- **Cleaned up by:** Server: deleted with NPCData in `NPCRegistry.removeNPC()`. Client: deleted with ClientNPC in despawn handler.
- **Verified:** RouteStep uses only RemoteEvent-safe types (string, number, Vector3, CFrame, nil). Array of tables serializes cleanly. Both sides compute stepDurations/cumulativeTimes from the same data using the same formula (`distance / walkSpeed` for walk, `dwellTime` for dwell, `DESPAWN_LINGER` for despawn).

**seatClaim (SeatClaim: {seatId, poiNodeId, cframe})**
- **Created by:** `SeatManager.claimSeat(poiNodeId)` → returns `SeatClaim` or nil
- **Passed via:** return value → RouteBuilder embeds `seatClaim.cframe` as `RouteStep.seatCFrame` and `seatClaim.seatId` is stored separately for release tracking
- **Received by:** RouteBuilder (at route-build time). The seatId is stored in a parallel lookup so PopulationController can release it later.
- **Stored in:** `SeatManager._occupied[seatId] = true` (tracks occupancy). The seatId is also stored in the NPCData for release tracking: `NPCData.seatClaims = {[stepIndex] = seatId}`.
- **Cleaned up by:** `SeatManager.releaseSeat(seatId)` called by PopulationController when the social step's cumulative time is passed. Also: if NPC is force-removed (stuck despawn), PopulationController iterates `npc.seatClaims` and releases all remaining.
- **Verified:** claimSeat returns nil if no seats → RouteBuilder handles nil by skipping POI. releaseSeat is idempotent (releasing an unclaimed seat is a no-op). Force-removal cleanup ensures no seat leak on abnormal despawn.

**modelIndex (number: 1-based)**
- **Created by:** PopulationController: `math.random(1, #modelList)` where `modelList` is built once from `ReplicatedStorage.WanderingPropModels:GetChildren()` and sorted by `Name`
- **Passed via:** stored in NPCData → sent via WP_Spawn/WP_BulkSync RemoteEvent → received by NPCClient
- **Received by:** NPCClient → passed to model cloning or `ModelPool.acquire(modelIndex)`
- **Stored in:** Server: `NPCData.modelIndex`. Client: `ClientNPC.modelIndex`.
- **Cleaned up by:** With NPCData/ClientNPC on removal.
- **Verified:** Type is number on both sides. Server/client both sort model lists by name and validator enforces unique model names, so index mapping is deterministic. StartupValidator ensures ≥1 model exists, so index is always valid.

**walkSpeed (number: studs/second)**
- **Created by:** PopulationController: `Config.BASE_WALK_SPEED + random(-VARIATION, VARIATION)`
- **Passed via:** stored in NPCData → sent via RemoteEvent → received by NPCClient → used by NPCMover for interpolation and NPCAnimator for speed scaling
- **Received by:** NPCClient → stored in ClientNPC.walkSpeed → NPCMover reads it for step duration calculation, passes to NPCAnimator.playWalk
- **Stored in:** Server: `NPCData.walkSpeed`. Client: `ClientNPC.walkSpeed`.
- **Cleaned up by:** With NPCData/ClientNPC on removal.
- **Verified:** Type is number everywhere. Used consistently in duration formula: `step.distance / walkSpeed`. Same value used on both server and client ensures timing agreement.

**nodeGraph internal state ({[nodeId]: NodeData})**
- **Created by:** `NodeGraph.build()` — reads CollectionService tags, builds adjacency tables
- **Passed via:** Module reference. RouteBuilder and StartupValidator call NodeGraph functions.
- **Received by:** RouteBuilder (findPath, getNode, getPOINodes, etc.), StartupValidator (validation queries), SeatManager.init (reads social POI seats from graph)
- **Stored in:** `NodeGraph._nodes` (private table), lifetime: server lifetime (never destroyed)
- **Cleaned up by:** Never. Exists for entire server session. Nodes are workspace parts managed by the buyer.
- **Verified:** build() called before any consumers. StartupValidator runs after build to verify graph integrity. All NodeGraph query functions return nil/empty for missing data — callers handle nil.

### API Composition Checks

| # | Caller | Callee | Args Match | Return Handled | Notes |
|---|--------|--------|-----------|----------------|-------|
| 1 | PopulationController | NodeGraph.build() | ✓ (no args) | ✓ bool checked | Halts if false |
| 2 | PopulationController | SeatManager.init(nodeGraph) | ✓ module ref | ✓ void | Called once after build |
| 3 | PopulationController | StartupValidator.validate(nodeGraph) | ✓ module ref | ✓ (bool, {string}) | Halts if false, prints errors |
| 4 | PopulationController | RouteBuilder.buildRoute(nodeGraph, seatManager) | ✓ two module refs | ✓ RouteResult? nil handled | Nil → skip spawn this tick, increment rejects |
| 5 | PopulationController | RouteBuilder.buildGroupRoute(count, nodeGraph, seatManager) | ✓ number + two refs | ✓ {RouteResult}? nil handled | Nil → fall back to single spawn |
| 6 | PopulationController | NPCRegistry.createNPC(npcData) | ✓ NPCData table | ✓ void | |
| 7 | PopulationController | NPCRegistry.removeNPC(npcId) | ✓ string | ✓ void | |
| 8 | PopulationController | NPCRegistry.getAllNPCs() | ✓ no args | ✓ {[string]: NPCData} | Iterated for step advancement |
| 9 | PopulationController | NPCRegistry.getActiveCount() | ✓ no args | ✓ number | Used for population check |
| 10 | PopulationController | SeatManager.releaseSeat(seatId) | ✓ string | ✓ void (idempotent) | Called on social step completion |
| 11 | PopulationController | Diagnostics.log(npcId, action, detail) | ✓ 3 strings | ✓ void | No-op if DEBUG off |
| 12 | RouteBuilder | NodeGraph.findPath(fromId, toId, excludeId?) | ✓ 2 strings + optional | ✓ {string}? nil → try without exclude or skip POI | Anti-backtracking fallback |
| 13 | RouteBuilder | NodeGraph.getNode(nodeId) | ✓ string | ✓ NodeData? nil → skip | |
| 14 | RouteBuilder | NodeGraph.getPOINodes() | ✓ no args | ✓ {NodeData} | Weighted selection |
| 15 | RouteBuilder | NodeGraph.getSpawnNodes() | ✓ no args | ✓ {NodeData} | Random pick |
| 16 | RouteBuilder | NodeGraph.getDespawnNodes() | ✓ no args | ✓ {NodeData} | Random pick |
| 17 | RouteBuilder | NodeGraph.getNodesInRadius(pos, radius) | ✓ Vector3 + number | ✓ {NodeData} | For wander candidates |
| 18 | RouteBuilder | NodeGraph.resolvePosition(nodeId) | ✓ string | ✓ Vector3 | Zone → random point, spot → center |
| 19 | RouteBuilder | SeatManager.claimSeat(poiNodeId) | ✓ string | ✓ SeatClaim? nil → skip POI | |
| 20 | NPCClient | NPCMover.startMoving(npcId, clientNPC, stepIndex?, stepElapsed?) | ✓ required + optional late-join args | ✓ void | Spawn uses defaults (1,0); BulkSync passes explicit offsets |
| 21 | NPCClient | NPCMover.stopMoving(npcId) | ✓ string | ✓ void | |
| 22 | NPCClient | NPCAnimator.setup(model) | ✓ Model | ✓ AnimatorHandle? nil checked | Nil → warn, skip NPC |
| 23 | NPCClient | NPCAnimator.cleanup(handle) | ✓ AnimatorHandle | ✓ void | |
| 24 | NPCMover | NPCAnimator.playWalk(handle, speed) | ✓ handle + number | ✓ void | |
| 25 | NPCMover | NPCAnimator.playIdle(handle) | ✓ handle | ✓ void | |
| 26 | NPCMover | NPCAnimator.playSit(handle) | ✓ handle | ✓ void | |
| 27 | NPCMover | NPCAnimator.stopAll(handle) | ✓ handle | ✓ void | |
| 28 | LODController | NPCMover.setLODTier(npcId, tier) | ✓ string + string | ✓ void | Optimization only |

---

## Critic Review Notes

**Review date:** 2026-02-13
**Result:** APPROVED after 6 specification gap fixes

### Fixes applied (from critic flags):
1. **StartupValidator check #8** — updated to verify ObjectValue.Value is a BasePart with WP_Node tag, not just any ObjectValue
2. **StartupValidator check #16 added** — POI reachability: each POI reachable from spawn AND can reach despawn
3. **NPCData.seatClaims field added** — `{[number]: string}?` mapping stepIndex → seatId for cleanup on force-removal
4. **SeatManager dependency updated** — ModuleScript Dependencies now lists NodeGraph (via init parameter)
5. **NPCClient fallback behavior clarified** — falls back to Clone/Destroy without ModelPool, near-tier quality without LODController
6. **PopulationController group route nil handling clarified** — falls back to single buildRoute, then skips tick if that also fails

### Phase 2 completion addendum (Codex, 2026-02-13):
1. **Late-join contract aligned** — `NPCMover.startMoving` signature now explicitly includes optional `stepIndex`/`stepElapsed`, and BulkSync flow passes those arguments.
2. **LOD register contract aligned** — `LODController.register` signature now matches call sites (`npcId`, `model`) and owns tier transitions internally via `NPCMover.setLODTier`.
3. **Node ID uniqueness made explicit** — architecture now states node ID = `WP_Node` part name, with startup validation that all node names are unique.
4. **Deterministic model indexing specified** — server/client both sort model list by name before index selection/use, with startup validation that model names are unique.
5. **Spawn timing ownership clarified** — server step advancement remains on `SERVER_TICK_RATE`; population spawn attempts are gated by `SPAWN_INTERVAL` via accumulator; validator enforces `SPAWN_INTERVAL >= SERVER_TICK_RATE`.

### Non-blocking notes for Phase 3:
- Consider adding route build time (ms) to diagnostics for large graphs
- Consider adding `Diagnostics.printAllActive()` for stuck-state debugging
- Ensure NPCAnimator.cleanup fully unloads animation tracks (not just stops)
- Document in security model that clients can desync their own rendering but can't affect others
