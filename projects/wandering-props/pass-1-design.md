# Pass 1 Design: Bare Bones Core Loop — Wandering Props

**Feature pass:** 1 of 4
**Based on:** feature-passes.md, idea-locked.md
**Existing code:** None (first pass)
**Critic Status:** APPROVED (rev 2 — 8 blockers fixed)
**Date:** 2026-02-14

---

## What This Pass Adds

NPCs spawn at hidden spawn points, walk along a waypoint graph with slight speed variation, and despawn at hidden despawn points. The server controls population and route planning. Clients handle all visual work — model creation, CFrame movement, ground snapping, and animation. New players joining mid-game see all existing NPCs at their correct positions. This is the core loop: spawn → walk → despawn → repeat.

---

## File Changes

### New Files
| File | Location | Purpose |
|------|----------|---------|
| `PopulationController.server.luau` | `src/server/` | Server entry point. Manages NPC lifecycle, population, routes, remotes. |
| `NPCClient.client.luau` | `src/client/` | Client entry point. Listens for remotes, manages NPC instances. |
| `NPCMover.luau` | `src/client/` | Client module. CFrame interpolation, ground-snap raycasts. |
| `NPCAnimator.luau` | `src/client/` | Client module. Animation loading and playback. |
| `WaypointGraph.luau` | `src/shared/` | Reads workspace waypoints, builds adjacency graph. |
| `RouteBuilder.luau` | `src/shared/` | Computes paths through the waypoint graph. |
| `Config.luau` | `src/shared/` | All configurable values. |
| `Types.luau` | `src/shared/` | Shared type definitions. |
| `Remotes.luau` | `src/shared/` | Remote event name constants. Prevents string typo bugs. |
| `default.project.json` | `src/` | Rojo project file. |

### Modified Files
None (first pass).

---

## Rojo Project Structure

```json
{
  "name": "WanderingProps",
  "tree": {
    "$className": "DataModel",
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
    },
    "ReplicatedStorage": {
      "WanderingPropsShared": {
        "$path": "src/shared"
      }
    }
  }
}
```

Rojo maps:
- `src/server/` → `ServerScriptService.WanderingProps`
- `src/client/` → `StarterPlayer.StarterPlayerScripts.WanderingProps`
- `src/shared/` → `ReplicatedStorage.WanderingPropsShared`

---

## Workspace Contracts

The buyer sets up the following in Studio. The system validates these at startup.

### Waypoint Graph
```
Workspace/
  WanderingProps/
    Waypoints/
      WP_Town1       (Part, Attribute NodeType = "waypoint")
        Connection1   (ObjectValue, Value → WP_Town2)
        Connection2   (ObjectValue, Value → WP_Market)
      WP_Town2       (Part, Attribute NodeType = "waypoint")
        Connection1   (ObjectValue, Value → WP_Town1)
      SpawnAlley     (Part, Attribute NodeType = "spawn")
        Connection1   (ObjectValue, Value → WP_Town1)
      DespawnDock    (Part, Attribute NodeType = "despawn")
        Connection1   (ObjectValue, Value → WP_Town2)
```

**Rules:**
- Every child of `Waypoints` is a `BasePart` representing a node.
- Each node has a string attribute `NodeType` with value `"waypoint"`, `"spawn"`, or `"despawn"`. Defaults to `"waypoint"` if missing.
- Connections are defined by `ObjectValue` children whose `Value` references another node Part within the same `Waypoints` folder.
- **All connections are bidirectional.** If node A has an ObjectValue pointing to node B, NPCs can walk A→B and B→A. You only need to define the connection on one side (though defining both is fine and recommended for clarity).
- Waypoint parts are **invisible at runtime** — the server sets `Transparency = 1` on all waypoint parts at startup. Buyers can keep them visible in Studio for editing.
- Waypoint parts should have `CanCollide = false` and `Anchored = true`.

### NPC Models
```
ReplicatedStorage/
  WanderingPropModels/
    NPCModel1    (Model — R15 rig, no Humanoid)
    NPCModel2    (Model — R15 rig, no Humanoid)
    ...
```

**Rules:**
- Each child is a `Model` with a `PrimaryPart` set (typically `HumanoidRootPart`).
- Models should be R15 rigs. **No Humanoid** — the system adds `AnimationController` + `Animator` at runtime if not present.
- At least 1 model must exist.

### Runtime-Created Structure
The system creates at runtime:
```
Workspace/
  WanderingProps/
    ActiveNPCs/         (Folder — created by client, holds NPC model clones)

ReplicatedStorage/
  WanderingPropsRemotes/
    NPCSpawned          (RemoteEvent)
    NPCDespawned        (RemoteEvent)
    NPCBulkSync         (RemoteEvent)
```

---

## New Data Structures

```lua
-- Types.luau

-- A node in the waypoint graph
export type Node = {
    id: string,             -- Part.Name (unique within Waypoints folder)
    position: Vector3,      -- Part.Position
    nodeType: "waypoint" | "spawn" | "despawn",
    connections: {string},  -- list of connected node IDs
}

-- The full waypoint graph
export type Graph = {
    nodes: {[string]: Node},  -- keyed by node ID
    spawns: {string},         -- list of spawn node IDs
    despawns: {string},       -- list of despawn node IDs
}

-- NPC data sent from server to client (spawn + bulk sync)
export type NPCSpawnData = {
    id: string,               -- unique NPC identifier (e.g. "npc_42")
    modelName: string,        -- name of model in WanderingPropModels
    walkSpeed: number,        -- studs per second for this NPC
    waypoints: {Vector3},     -- ordered positions: [1]=spawn, [N]=despawn
    startTime: number,        -- workspace:GetServerTimeNow() when NPC started
}

-- Server-side NPC record (not sent to clients)
export type NPCRecord = {
    id: string,
    modelName: string,
    walkSpeed: number,
    waypoints: {Vector3},     -- ordered positions
    startTime: number,        -- workspace:GetServerTimeNow() at spawn
    totalDuration: number,    -- calculated: total route distance / walkSpeed
}

-- Client-side NPC state (per active NPC)
export type NPCState = {
    id: string,
    model: Model,             -- the cloned model instance
    walkSpeed: number,
    waypoints: {Vector3},     -- ordered positions
    currentLeg: number,       -- index: walking from waypoints[currentLeg] to waypoints[currentLeg + 1]
    legProgress: number,      -- 0..1 progress along current leg
    lastGroundY: number,      -- last successful ground-snap Y; fallback if raycast misses
    expectedDespawnTime: number, -- workspace:GetServerTimeNow() when route should end + buffer
    animator: Animator,
    walkTrack: AnimationTrack,
    idleTrack: AnimationTrack,
}
```

---

## New Config Values

```lua
-- Config.luau
local Config = {}

-- POPULATION
Config.MaxPopulation = 20         -- Target number of active NPCs. Range: 1-70.
Config.SpawnInterval = 2          -- Seconds between spawn attempts. Range: 0.5-10.
Config.InitialSpawnBurst = true   -- If true, rapidly fills to MaxPopulation on startup.

-- MOVEMENT
Config.BaseWalkSpeed = 8          -- Base walk speed in studs/second. Range: 4-16.
Config.WalkSpeedVariation = 1.5   -- +/- variation from base. Range: 0-4.
                                  -- Actual speed = Base + random(-Variation, +Variation)

-- GROUND SNAP
Config.SnapRayOriginOffset = 10   -- Studs above NPC position to start raycast. Range: 5-20.
Config.SnapRayLength = 50         -- Studs downward for ground raycast. Range: 20-100.
Config.SnapHipOffset = 3          -- Studs above ground hit point to place NPC root. Range: 1-5.
                                  -- Should match half the rig height from feet to root.

-- ANIMATIONS
Config.WalkAnimationId = ""       -- rbxassetid:// for walk animation. REQUIRED.
Config.IdleAnimationId = ""       -- rbxassetid:// for idle animation. REQUIRED.
Config.WalkAnimBaseSpeed = 8      -- The walk speed the walk animation was authored for.
                                  -- Animation .Speed is scaled: actualSpeed / WalkAnimBaseSpeed.
                                  -- Range: 4-16.

-- DESPAWN SAFETY
Config.ClientDespawnBuffer = 10   -- Extra seconds past expected route duration before client
                                  -- force-despawns an NPC locally (safety net for lost events).
                                  -- Range: 5-30.

-- DIAGNOSTICS
Config.DiagnosticsEnabled = false -- Print lifecycle events to output. Toggle for debugging.

return Config
```

---

## New/Modified APIs

### WaypointGraph.luau

```lua
local WaypointGraph = {}

-- Reads all Parts under the given folder, builds an adjacency graph.
-- Connections are bidirectional: if A→B exists, B→A is implied even without explicit ObjectValue.
-- Returns nil + error string if validation fails (no spawns, no despawns, etc.)
function WaypointGraph.build(waypointsFolder: Folder): (Types.Graph?, string?)

-- Returns true if there is at least one valid path from any spawn to any despawn.
-- Uses BFS. Called during startup validation.
function WaypointGraph.validate(graph: Types.Graph): (boolean, string?)

return WaypointGraph
```

### RouteBuilder.luau

```lua
local RouteBuilder = {}

-- Computes a path from spawnId to despawnId using BFS with randomized neighbor ordering.
-- Returns ordered list of node IDs from spawn to despawn, or nil if no path exists.
-- Anti-backtracking is inherent in BFS (no cycles in shortest path).
function RouteBuilder.computeRoute(graph: Types.Graph, spawnId: string, despawnId: string): {string}?

-- Picks a random spawn node ID from the graph.
function RouteBuilder.pickRandomSpawn(graph: Types.Graph): string

-- Picks a random despawn node ID from the graph.
function RouteBuilder.pickRandomDespawn(graph: Types.Graph): string

-- Convenience function: picks random spawn + despawn, computes route, resolves positions.
-- Returns NPCSpawnData-shaped result (minus id/modelName/startTime), or nil if no path.
-- Retries up to 3 spawn/despawn combos before returning nil.
function RouteBuilder.buildRoute(graph: Types.Graph, walkSpeed: number): {waypoints: {Vector3}, totalDistance: number}?

return RouteBuilder
```

### PopulationController.server.luau

```lua
-- Server script. No public API — entry point only.
-- On startup:
--   1. Reads Config. Validates config values (see Startup Validator).
--   2. Validates workspace structure (WanderingProps folder, Waypoints folder, Models folder).
--   3. Caches valid model list: filters WanderingPropModels children to those with PrimaryPart set.
--      Stores as local `validModels: {Model}` — reused for all spawn attempts, never re-queried.
--   4. Builds waypoint graph via WaypointGraph.build()
--   5. Runs WaypointGraph.validate() — errors halt startup
--   6. Hides waypoint parts (Transparency = 1)
--   7. Creates RemoteEvent instances under ReplicatedStorage.WanderingPropsRemotes
--      using Remotes.luau constants for names. These persist for server lifetime (no shutdown cleanup needed).
--   8. Connects Players.PlayerAdded for late-join sync
--   9. Begins spawn loop

-- Spawn loop (steady state):
--   while true: task.wait(Config.SpawnInterval)
--     if activeCount < Config.MaxPopulation:
--       spawn one NPC (see Data Flow below)
--
-- Initial burst (if Config.InitialSpawnBurst):
--   for i = 1, Config.MaxPopulation:
--     spawnNPC()
--     RunService.Heartbeat:Wait()  -- yield one frame between spawns to avoid freezing
--   Then enters steady-state loop above.

-- Despawn:
--   For each spawned NPC, schedule task.delay(totalDuration, despawnNPC)
--   despawnNPC removes from registry, fires NPCDespawned to all clients

-- Late-join sync:
--   On PlayerAdded: fire NPCBulkSync to that player with all active NPCSpawnData records
```

### NPCClient.client.luau

```lua
-- Client script. No public API — entry point only.
-- On startup:
--   1. Waits for ReplicatedStorage.WanderingPropsRemotes (server creates these)
--   2. Gets reference to Workspace.WanderingProps.Waypoints folder (for NPCMover.init)
--   3. Creates Workspace.WanderingProps.ActiveNPCs folder (for NPC model parenting)
--   4. Calls NPCMover.init(waypointsFolder, activeNPCsFolder) to set up raycast params
--   5. Connects to NPCSpawned, NPCDespawned, NPCBulkSync RemoteEvents
--      using Remotes.luau constants for names
--   6. Connects RunService.Heartbeat for movement updates

-- NPCSpawned handler:
--   Receives NPCSpawnData. Creates NPC model, initializes NPCState, starts movement.
--   For late-join sync data: calculates current position from elapsed time.

-- NPCDespawned handler:
--   Receives npcId: string. Destroys model, removes from active state.

-- Heartbeat:
--   For each active NPC:
--     1. Check client-side despawn timeout: if workspace:GetServerTimeNow() > npc.expectedDespawnTime,
--        force-despawn locally with warning "[WanderingProps] FORCE_DESPAWN {id} — server event not received"
--     2. Otherwise: calls NPCMover.update() and NPCAnimator.update()
```

### NPCMover.luau

```lua
local NPCMover = {}

-- Sets up raycast params (exclude waypoint parts folder, ActiveNPCs folder, player characters).
-- Called once during NPCClient startup.
function NPCMover.init(waypointsFolder: Folder, activeNPCsFolder: Folder): ()

-- Moves an NPC toward its next waypoint. Updates currentLeg and legProgress.
-- Applies ground-snap raycast. Sets model PrimaryPart CFrame.
-- Returns true if NPC has reached its final waypoint (route complete).
function NPCMover.update(npc: Types.NPCState, dt: number): boolean

-- Calculates the interpolated position for an NPC given elapsed time since spawn.
-- Used for late-join sync to place NPC at correct mid-route position.
-- Returns: position (Vector3), currentLeg (number), legProgress (number)
--
-- Algorithm:
--   local distanceCovered = elapsed * walkSpeed
--   for i = 1, #waypoints - 1 do
--     local legDist = (waypoints[i + 1] - waypoints[i]).Magnitude
--     if distanceCovered <= legDist then
--       local progress = distanceCovered / legDist
--       return waypoints[i]:Lerp(waypoints[i + 1], progress), i, progress
--     end
--     distanceCovered -= legDist
--   end
--   -- Past end of route: return final waypoint
--   return waypoints[#waypoints], #waypoints - 1, 1.0
function NPCMover.calculatePositionAtTime(waypoints: {Vector3}, walkSpeed: number, elapsed: number): (Vector3, number, number)

return NPCMover
```

### Remotes.luau

```lua
-- Shared constants for RemoteEvent names. Used by both server and client
-- to prevent string typo bugs.
local Remotes = {
    NPCSpawned = "NPCSpawned",
    NPCDespawned = "NPCDespawned",
    NPCBulkSync = "NPCBulkSync",
}
return Remotes
```

### NPCAnimator.luau

```lua
local NPCAnimator = {}

-- Loads walk and idle animations onto the given Animator.
-- Returns walkTrack, idleTrack.
function NPCAnimator.setup(animator: Animator): (AnimationTrack, AnimationTrack)

-- Updates animation state based on whether the NPC is moving.
-- Adjusts walk animation speed based on NPC walk speed vs Config.WalkAnimBaseSpeed.
-- isMoving = true: play walk, stop idle. isMoving = false: play idle, stop walk.
function NPCAnimator.update(npc: Types.NPCState, isMoving: boolean): ()

return NPCAnimator
```

---

## RemoteEvent Protocol

All remotes are created by the server under `ReplicatedStorage.WanderingPropsRemotes/`.

### NPCSpawned
**Direction:** Server → All Clients
**Payload:** `(NPCSpawnData)` — single table matching the `NPCSpawnData` type.
**When:** Server spawns a new NPC.

### NPCDespawned
**Direction:** Server → All Clients
**Payload:** `(npcId: string)`
**When:** NPC reaches end of route (despawn timer fires).

### NPCBulkSync
**Direction:** Server → Specific Client
**Payload:** `({NPCSpawnData})` — array of all active NPC spawn data records.
**When:** A player joins (PlayerAdded). The `startTime` fields let the client calculate each NPC's current position.

---

## Data Flow for New Behaviors

### NPC Spawn Flow
1. **PopulationController** checks `activeCount < MaxPopulation`.
2. Picks a random model name from the cached `validModels` list (built once at startup, filtered to models with PrimaryPart).
3. Calculates walk speed: `Config.BaseWalkSpeed + (math.random() * 2 - 1) * Config.WalkSpeedVariation`.
4. Calls `RouteBuilder.buildRoute(graph, walkSpeed)` → gets `{waypoints, totalDistance}`.
5. If nil (no valid route found), logs warning, skips this spawn attempt.
6. Generates unique NPC ID: `"npc_" .. nextId`; increments counter.
7. Calculates `totalDuration = totalDistance / walkSpeed`.
8. Creates `NPCRecord`, stores in `activeNPCs[id]`.
9. Fires `NPCSpawned:FireAllClients(spawnData)` with `startTime = workspace:GetServerTimeNow()`.
10. Schedules `task.delay(totalDuration, despawnNPC, id)` for automatic despawn.
11. If `Config.DiagnosticsEnabled`: prints `[WP] Spawned {id} model={modelName} speed={walkSpeed} legs={#waypoints-1} duration={totalDuration}s`.

### NPC Despawn Flow
1. `task.delay` fires after `totalDuration` seconds.
2. **PopulationController** checks `activeNPCs[id]` exists (guards against double-despawn).
3. Removes entry from `activeNPCs`.
4. Fires `NPCDespawned:FireAllClients(id)`.
5. If `Config.DiagnosticsEnabled`: prints `[WP] Despawned {id}`.

### Client Receives NPCSpawned
1. **NPCClient** receives `NPCSpawnData`.
2. Finds the model template: `ReplicatedStorage.WanderingPropModels:FindFirstChild(data.modelName)`.
3. If nil (model missing), warns `[WanderingProps] Model not found: {modelName}` and ignores this NPC.
4. Clones the model via `pcall`. If clone fails, warns `[WanderingProps] Failed to clone model {modelName} for NPC {id}` and ignores this NPC.
5. Validates `clone.PrimaryPart ~= nil`. If nil, warns `[WanderingProps] Model {modelName} has no PrimaryPart` and destroys clone, ignores this NPC.
6. Sets `PrimaryPart.Anchored = true`.
7. Sets `CanCollide = false` on all `BasePart` descendants.
8. Checks for `AnimationController` child on the clone. If missing, creates one.
9. Checks for `Animator` under `AnimationController`. If missing, creates one.
10. Calls `NPCAnimator.setup(animator)` → gets `walkTrack`, `idleTrack`.
11. Calculates elapsed time: `workspace:GetServerTimeNow() - data.startTime`.
12. If elapsed > 0 (late-join): calls `NPCMover.calculatePositionAtTime(data.waypoints, data.walkSpeed, elapsed)` → gets position, currentLeg, legProgress.
13. If elapsed ≤ 0 (just spawned): position = `data.waypoints[1]`, currentLeg = 1, legProgress = 0.
14. Sets model `PrimaryPart.CFrame = CFrame.new(position)`.
15. Parents model to `Workspace.WanderingProps.ActiveNPCs`.
16. Calculates total route distance (sum of leg magnitudes), then `expectedDespawnTime = data.startTime + (totalDistance / data.walkSpeed) + Config.ClientDespawnBuffer`.
17. Creates `NPCState` record (including `lastGroundY = position.Y`, `expectedDespawnTime`), adds to active NPC table.

### Client Heartbeat Loop
1. For each active NPC in the state table:
2. Check timeout: if `workspace:GetServerTimeNow() > npc.expectedDespawnTime`, force-despawn locally (destroy model, remove from table, warn `[WanderingProps] FORCE_DESPAWN {id}`). Continue to next NPC.
3. `finished = NPCMover.update(npc, dt)` — moves NPC, returns true if at final waypoint.
4. `NPCAnimator.update(npc, not finished)` — walk if moving, idle if finished.
5. If `finished`: NPC stays at final position playing idle until server fires `NPCDespawned`.
   (The server's `task.delay` is the authority on despawn timing. The client may arrive slightly before or after due to ground-snap path differences — this is fine. The timeout in step 2 is a safety net for lost RemoteEvents, not normal flow.)

### Client Receives NPCDespawned
1. **NPCClient** receives `npcId`.
2. Looks up NPC in active table.
3. Stops all animation tracks.
4. Calls `model:Destroy()`.
5. Removes from active table.

### Late-Join Sync Flow
1. Player joins → `Players.PlayerAdded` fires on server.
2. **PopulationController** builds an array of `NPCSpawnData` from all `activeNPCs` entries.
3. Fires `NPCBulkSync:FireClient(player, dataArray)`.
4. **NPCClient** receives array. For each entry, runs the same logic as "Client Receives NPCSpawned" (steps 2-15). The `startTime` field + `calculatePositionAtTime` handles correct mid-route placement.

### Ground-Snap Raycast (inside NPCMover.update)
1. Calculate desired flat position: move from current toward next waypoint at `walkSpeed * dt`.
2. Raycast origin: `flatPosition + Vector3.new(0, Config.SnapRayOriginOffset, 0)`.
3. Raycast direction: `Vector3.new(0, -Config.SnapRayLength, 0)`.
4. Raycast params: Exclude `Workspace.WanderingProps.Waypoints`, `Workspace.WanderingProps.ActiveNPCs`, and all player character models.
5. If hit: snap NPC Y to `hit.Position.Y + Config.SnapHipOffset`. Update `npc.lastGroundY` to this Y value.
6. If no hit: use `npc.lastGroundY` as Y position (don't fall through world). `lastGroundY` is initialized to `waypoints[1].Y` when the NPCState is created.
7. Face NPC toward next waypoint: `CFrame.lookAt(snappedPosition, nextWaypointFlat)` where `nextWaypointFlat` uses the same Y as `snappedPosition` to prevent tilting.

---

## Integration Pass

Since this is Pass 1 with no existing code, the integration pass verifies internal consistency across the new modules.

### Data Lifecycle Traces

**NPCSpawnData**
- **Created by:** `PopulationController` spawn logic → assembles table from route + config values
- **Passed via:** `NPCSpawned` RemoteEvent (FireAllClients) and `NPCBulkSync` RemoteEvent (FireClient)
- **Received by:** `NPCClient` event handlers → reads all fields to create model and NPCState
- **Stored in:** Server: `activeNPCs[id]` as NPCRecord (superset). Client: used to build NPCState, then spawn data itself is not stored.
- **Cleaned up by:** Server: removed from `activeNPCs` in despawnNPC. Client: NPCState removed on NPCDespawned event.
- **Verified:** Types match across server creation and client consumption. All fields populated before fire.

**NPCState (client-side)**
- **Created by:** `NPCClient` on receiving NPCSpawned/NPCBulkSync → builds from NPCSpawnData + cloned model + animation tracks
- **Passed via:** Direct table reference in client-local `activeNPCs` table
- **Received by:** `NPCMover.update()` and `NPCAnimator.update()` each Heartbeat
- **Stored in:** Client-local `activeNPCs[id]` table, lifetime = spawn to despawn
- **Cleaned up by:** `NPCClient` NPCDespawned handler → destroys model, removes from table
- **Verified:** model:Destroy() cleans up all Instance children (AnimationController, Animator, tracks). Table entry removal prevents stale references.

**Graph**
- **Created by:** `WaypointGraph.build()` at server startup
- **Passed via:** Local variable in PopulationController, passed as argument to RouteBuilder functions
- **Received by:** `RouteBuilder.computeRoute()`, `RouteBuilder.pickRandomSpawn/Despawn()`
- **Stored in:** PopulationController local scope, lifetime = server lifetime
- **Cleaned up by:** Never — lives for the server session. Static data, no mutation after build.
- **Verified:** Graph is read-only after build. RouteBuilder only reads `nodes`, `spawns`, `despawns` fields.

### API Composition Checks

| Caller | Callee | Args Match | Return Handled | Notes |
|--------|--------|-----------|----------------|-------|
| PopulationController | WaypointGraph.build(folder) | Folder instance | Graph? + string? — nil check before proceeding | First call in startup |
| PopulationController | WaypointGraph.validate(graph) | Graph table | boolean + string? — false halts startup | Second call in startup |
| PopulationController | RouteBuilder.buildRoute(graph, walkSpeed) | Graph + number | nil-checked: skip spawn on nil | Called each spawn attempt |
| NPCClient | NPCMover.init(wpFolder, npcFolder) | Folder, Folder | void | Called once at startup |
| NPCClient | NPCMover.update(npc, dt) | NPCState + number | boolean returned, drives animator | Called per NPC per Heartbeat |
| NPCClient | NPCMover.calculatePositionAtTime(wps, speed, elapsed) | {Vector3}, number, number | Vector3, number, number | Late-join only |
| NPCClient | NPCAnimator.setup(animator) | Animator instance | AnimTrack, AnimTrack | Called per NPC at spawn |
| NPCClient | NPCAnimator.update(npc, isMoving) | NPCState + boolean | void | Called per NPC per Heartbeat |

All argument types and return types are internally consistent across the module boundaries defined in this design.

---

## Diagnostics Updates

### New Reason Codes
All diagnostics are gated behind `Config.DiagnosticsEnabled`.

- `SPAWN` — NPC spawned. Includes: id, modelName, walkSpeed, legCount, totalDuration.
- `DESPAWN` — NPC despawned (route complete). Includes: id.
- `SPAWN_FAIL` — Route computation failed (no valid path). Includes: attempted spawn/despawn pair.
- `BULK_SYNC` — Late-join sync fired. Includes: player name, NPC count sent.
- `GRAPH_BUILT` — Waypoint graph built. Includes: node count, spawn count, despawn count, edge count.
- `VALIDATION_FAIL` — Startup validation failed. Includes: error message.
- `FORCE_DESPAWN` — Client-side safety despawn (server event not received within timeout). Includes: id.

### New Health Counters
Tracked in PopulationController, printed on `SPAWN`/`DESPAWN` if diagnostics enabled:
- `npcsActive` — current live NPC count
- `npcsSpawnedTotal` — lifetime spawn count
- `npcsDespawnedTotal` — lifetime despawn count
- `routeFailures` — lifetime route computation failures

### Diagnostics Format
```
[WanderingProps] SPAWN npc_42 model=Villager speed=7.3 legs=4 duration=28.1s active=15/20 total=42
[WanderingProps] DESPAWN npc_38 active=14/20 total_despawned=28
[WanderingProps] SPAWN_FAIL no path from SpawnAlley to DespawnDock failures=3
[WanderingProps] BULK_SYNC player=Player1 npcs_sent=15
[WanderingProps] GRAPH_BUILT nodes=12 spawns=2 despawns=2 edges=18
[WanderingProps] FORCE_DESPAWN npc_38 — server event not received
```

---

## Startup Validator Updates

Run by PopulationController at server start, before the spawn loop begins. Any BLOCKING check that fails halts the system with an error.

| Contract | Check | Severity | Error Message |
|----------|-------|----------|---------------|
| WanderingProps folder exists | `Workspace:FindFirstChild("WanderingProps")` ~= nil | BLOCKING | `[WanderingProps] FATAL: Workspace.WanderingProps folder not found. Create it in Studio.` |
| Models folder exists | `ReplicatedStorage:FindFirstChild("WanderingPropModels")` ~= nil | BLOCKING | `[WanderingProps] FATAL: ReplicatedStorage.WanderingPropModels folder not found.` |
| Models folder has models | `#modelsFolder:GetChildren() > 0` | BLOCKING | `[WanderingProps] FATAL: No models found in WanderingPropModels.` |
| Models have PrimaryPart | Each model child checked; models without PrimaryPart excluded from cached `validModels` | WARNING | `[WanderingProps] WARNING: Model "{name}" has no PrimaryPart set. It will be skipped.` |
| At least 1 valid model | `#validModels > 0` after filtering | BLOCKING | `[WanderingProps] FATAL: No valid models (all missing PrimaryPart).` |
| Waypoints folder exists | `Workspace.WanderingProps:FindFirstChild("Waypoints")` ~= nil | BLOCKING | `[WanderingProps] FATAL: Workspace.WanderingProps.Waypoints folder not found.` |
| At least 1 spawn node | `#graph.spawns > 0` | BLOCKING | `[WanderingProps] FATAL: No spawn nodes found. Set NodeType attribute to "spawn".` |
| At least 1 despawn node | `#graph.despawns > 0` | BLOCKING | `[WanderingProps] FATAL: No despawn nodes found. Set NodeType attribute to "despawn".` |
| Graph connectivity | At least one spawn can reach at least one despawn | BLOCKING | `[WanderingProps] FATAL: No valid path from any spawn to any despawn. Check connections.` |
| ObjectValue targets valid | Each ObjectValue points to a Part within the Waypoints folder | WARNING | `[WanderingProps] WARNING: Node "{name}" has connection to invalid target "{valueName}". Ignored.` |
| Animation IDs set | `Config.WalkAnimationId ~= ""` and `Config.IdleAnimationId ~= ""` | BLOCKING | `[WanderingProps] FATAL: Animation IDs not set in Config. Set WalkAnimationId and IdleAnimationId.` |
| MaxPopulation in range | `Config.MaxPopulation >= 1 and Config.MaxPopulation <= 70` | BLOCKING | `[WanderingProps] FATAL: MaxPopulation must be between 1 and 70.` |
| SpawnInterval in range | `Config.SpawnInterval >= 0.5 and Config.SpawnInterval <= 10` | BLOCKING | `[WanderingProps] FATAL: SpawnInterval must be between 0.5 and 10.` |
| BaseWalkSpeed in range | `Config.BaseWalkSpeed >= 4 and Config.BaseWalkSpeed <= 16` | BLOCKING | `[WanderingProps] FATAL: BaseWalkSpeed must be between 4 and 16.` |
| WalkSpeedVariation in range | `Config.WalkSpeedVariation >= 0 and Config.WalkSpeedVariation <= 4` | WARNING | `[WanderingProps] WARNING: WalkSpeedVariation should be between 0 and 4.` |

---

## Performance Notes

- **No server-side models.** Models exist only on clients. Server tracks only route data (small tables).
- **RemoteEvents are sparse.** Only fired on spawn, despawn, and player join — never per-frame.
- **Client Heartbeat loop** iterates all active NPCs. At 70 NPCs, this is ~70 CFrame sets + ground raycasts per frame. This is the main performance cost and will be addressed by LOD tiers in Pass 4.
- **Ground-snap raycasts** are the most expensive per-frame operation. The exclude list uses folder references (not individual parts) to keep filter setup cheap.
- **Animation tracks** are lightweight on Roblox. 70 AnimationTracks playing simultaneously is within engine capabilities.

---

## Golden Tests for This Pass

### Test 1: Basic Spawn-Walk-Despawn Cycle
- **Setup:** Waypoint graph with 2 spawn nodes, 4 waypoint nodes, 2 despawn nodes, connected in a simple chain. 3 NPC models in WanderingPropModels. Config: MaxPopulation = 5, SpawnInterval = 1, DiagnosticsEnabled = true.
- **Action:** Start the server. Wait 10 seconds.
- **Expected:** 5 NPCs appear over the first few seconds, walk along the waypoint chain, and despawn at despawn nodes. As NPCs despawn, new ones spawn to maintain population of 5. Diagnostics output shows SPAWN and DESPAWN events with incrementing IDs.
- **Pass condition:** Visual: NPCs walk smoothly along the waypoint path without floating or clipping through ground. Diagnostics: `npcsActive` stays at or near 5. No SPAWN_FAIL messages. No errors in output.

### Test 2: Late-Join Sync
- **Setup:** Same waypoint graph as Test 1. Config: MaxPopulation = 10.
- **Action:** Start server. Wait 15 seconds for NPCs to populate and be mid-route. Join with a second client.
- **Expected:** Second client immediately sees all active NPCs at their current mid-route positions (not at spawn points). NPCs continue walking from their synced positions.
- **Pass condition:** Visual: NPCs on the second client appear at mid-route positions matching approximately where the first client sees them. Diagnostics: BULK_SYNC event fires with correct NPC count. No NPCs appear at spawn points on late join.

### Test 3: Walk Speed Variation and Ground Snap
- **Setup:** Waypoint graph with a sloped ramp between two nodes. Config: BaseWalkSpeed = 8, WalkSpeedVariation = 3, MaxPopulation = 10.
- **Action:** Start server. Observe NPCs walking over the ramp section.
- **Expected:** NPCs walk at visibly different speeds. All NPCs follow the ground slope smoothly — no floating above or clipping below the ramp surface. Walk animation speed matches movement speed (no foot sliding).
- **Pass condition:** Visual: NPCs stay grounded on slopes. Multiple NPCs walking at noticeably different speeds. Animation feet match ground contact. No NPCs falling through terrain.

### Regression Tests
None (first pass).

---

## Critic Review Notes

### Rev 1 — 8 Blocking Issues (all fixed in rev 2)
1. **NPCMover.init() contract** — Added explicit client startup step showing waypointsFolder retrieval.
2. **Config validation missing** — Added MaxPopulation, SpawnInterval, BaseWalkSpeed, WalkSpeedVariation checks to startup validator.
3. **InitialSpawnBurst unbounded loop** — Changed to `RunService.Heartbeat:Wait()` between spawns.
4. **RemoteEvent cleanup** — Documented: persists for server lifetime, no shutdown in Pass 1.
5. **String remote names** — Added `Remotes.luau` shared constants module.
6. **Model clone failure** — Added pcall + PrimaryPart nil check in client spawn flow.
7. **Memory leak on lost despawn event** — Added `expectedDespawnTime` field + client-side timeout fallback.
8. **Workspace.WanderingProps folder check** — Added to startup validator.

### Flagged Items (non-blocking, noted for builder)
- Cache model list at startup (done — `validModels` in PopulationController).
- `lastGroundY` field added to NPCState for raycast-miss fallback.
- `calculatePositionAtTime` algorithm documented inline.
- Per-NPC movement logging deferred to Pass 2+.
- Bulk sync payload size acceptable for 70 NPCs (~5KB).
- CollectionService vs folder-based waypoints: folder chosen for buyer simplicity. Revisit if requested.
