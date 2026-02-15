# Pass 3 Design: Organic Movement & Day/Night — Wandering Props

**Feature pass:** 3 of 4
**Based on:** feature-passes.md, idea-locked.md
**Existing code:** PopulationController, NPCClient, NPCMover, NPCAnimator, POIRegistry, WaypointGraph, RouteBuilder, Config, Types, Remotes (all in `src/`)
**Critic Status:** APPROVED (rev 1 — design verified against real code, 0 design flaws)
**Date:** 2026-02-15

---

## What This Pass Adds

NPCs gain spatial variation and spontaneity. **Waypoint zones** are area-based nodes where each NPC picks a random point within the zone boundary, so NPCs spread out naturally instead of converging on a single dot. **Random wandering** inserts mid-route detours — an NPC may walk to a nearby off-path node and back before continuing, making routes feel less rigid. **Day/night cycle hook** lets buyers optionally reduce NPC population at night via a simple attribute on the WanderingProps folder.

All three features are **server-side only**. The client receives waypoint positions as before — it doesn't know whether a position came from a spot, a zone, or a wander detour. No client code changes, no new remotes, no payload structure changes.

---

## File Changes

### New Files
None.

### Modified Files
| File | What's Changing | Why |
|------|----------------|-----|
| `Types.luau` | Add `zoneSize: Vector3?` to `Node` type | Zone nodes need size data for randomization |
| `Config.luau` | Add WanderChance, WanderMaxDistance, DayNightEnabled, NightPopulationMultiplier | New config surface for all 3 features |
| `WaypointGraph.luau` | Read `Zone` attribute from waypoint parts, store `part.Size` as `zoneSize` in node | Zone node discovery at graph build time |
| `PopulationController.server.luau` | Zone-aware position conversion, wander detour insertion, day/night population cap, new diagnostics | All 3 features integrate into the server spawn flow |

### Unchanged Files
| File | Why |
|------|-----|
| `RouteBuilder.luau` | Graph pathfinding unchanged; wander insertion is a post-processing step in PopulationController |
| `POIRegistry.luau` | POI system unchanged |
| `NPCClient.client.luau` | Receives positions — doesn't know about zones or wander |
| `NPCMover.luau` | Walks to positions, unchanged |
| `NPCAnimator.luau` | No new animations |
| `Remotes.luau` | Same 3 remotes, same payload structure |

---

## Workspace Contracts

### Waypoint Zone Nodes

Zone nodes are regular waypoint parts with the `Zone` attribute set. They use the Part's `Size` to define the random area.

```
Workspace/WanderingProps/Waypoints/
  TownSquare (Part)
    Attributes:
      Zone = true                (boolean, optional — defaults to false / spot behavior)
      NodeType = "waypoint"      (string, same as existing)
    -- Part.Size defines the zone boundary:
    --   Size.X = width of zone (studs)
    --   Size.Z = depth of zone (studs)
    --   Size.Y = irrelevant (zone is XZ-plane only)
    -- NPC picks a random point within ±Size.X/2 and ±Size.Z/2 from Part.Position
    -- Part should be a flat block placed at ground level, Anchored, CanCollide false
```

**Rules:**
- `Zone = true` on a BasePart in the Waypoints folder makes it a zone node.
- Parts without `Zone` attribute (or `Zone = false`) are spots — exact position, same as Pass 1/2.
- Spawn and despawn nodes MUST NOT be zones. They are hidden points and need exact positions.
- Zone attribute is ignored on POI waypoint parts (they are always exact-position).
- If `Zone = true` is set on a spawn/despawn node, startup validator emits a warning and treats it as a spot.
- Part `Transparency` and `CanCollide` are still set by the existing `hideWaypointParts()` call.

### Day/Night Hook

Buyers integrate their day/night system by setting a single attribute on the WanderingProps folder.

```
Workspace/WanderingProps (Folder)
  Attributes:
    IsNight = false              (boolean, optional — set by buyer's day/night script)
```

**Rules:**
- Only read when `Config.DayNightEnabled = true`. Otherwise ignored entirely.
- Buyer's external script sets `wanderingFolder:SetAttribute("IsNight", true)` at nightfall and `false` at dawn.
- If the attribute doesn't exist, defaults to `false` (daytime / full population).
- Population reduction is organic — existing NPCs finish their routes normally; the system just stops spawning new ones until population drops below the effective cap.

---

## Modified Data Structures

```lua
-- Types.luau — MODIFICATION

-- Node gains optional zoneSize field
export type Node = {
    id: string,
    position: Vector3,
    nodeType: "waypoint" | "spawn" | "despawn",
    connections: { string },
    zoneSize: Vector3?,  -- NEW: if set, this is a zone node. Size.X/Z define random area.
}
```

No other type changes. NPCSpawnData, NPCRecord, NPCState, POIStopData, SeatClaim, Graph — all unchanged. Zone randomization and wander detours produce different waypoint positions in the existing `{ Vector3 }` array; the type system doesn't need to distinguish them.

---

## New Config Values

```lua
-- Config.luau — ADDITIONS (append after existing POI values, before return)

-- RANDOM WANDERING
Config.WanderChance = 0.15           -- Probability of wander detour per eligible waypoint. Range: 0.0-1.0.
Config.WanderMaxDistance = 50        -- Max distance (studs) to wander target. Range: 10-200.

-- DAY/NIGHT
Config.DayNightEnabled = false       -- Master toggle for day/night population hook.
Config.NightPopulationMultiplier = 0.3  -- Population multiplier when IsNight is true. Range: 0.0-1.0.
```

---

## Modified APIs

### WaypointGraph.luau (MODIFIED)

```lua
-- CHANGE: ensureNodeForPart() now reads the Zone attribute and stores part.Size as zoneSize.
-- This is inside the existing build() function.
--
-- Real code currently (lines 80-85 of ensureNodeForPart):
--   nodes[nodeId] = {
--       id = nodeId,
--       position = part.Position,
--       nodeType = nodeType,
--       connections = {},
--   }
--
-- New:
--   local isZone = part:GetAttribute("Zone") == true
--   nodes[nodeId] = {
--       id = nodeId,
--       position = part.Position,
--       nodeType = nodeType,
--       connections = {},
--       zoneSize = if isZone and nodeType == "waypoint" then part.Size else nil,
--   }
--
-- Zone attribute is only honored for "waypoint" nodeType. Spawn/despawn nodes are never zones.
-- This is the ONLY change to WaypointGraph.luau.
-- Backward compatible: existing consumers ignore the new field.
```

### PopulationController.server.luau (MODIFIED)

```lua
-- STRUCTURAL CHANGES (additions/modifications to existing code):

-- New module-level state (add after existing poiRegistry declaration):
--   local lastIsNightState: boolean? = nil  -- for diagnostics transition logging

-- ============================================================
-- NEW LOCAL FUNCTION: getEffectiveMaxPopulation()
-- ============================================================
-- Returns the current effective max population, accounting for day/night.
-- Called at each spawn cycle and during initial burst.
--
-- function getEffectiveMaxPopulation(wanderingFolder: Folder): number
--     if not Config.DayNightEnabled then
--         return Config.MaxPopulation
--     end
--     local isNight = wanderingFolder:GetAttribute("IsNight")
--     if isNight == nil then
--         isNight = false
--     end
--     -- Log state transitions
--     if isNight ~= lastIsNightState then
--         lastIsNightState = isNight
--         local effectiveMax = Config.MaxPopulation
--         if isNight then
--             effectiveMax = math.max(1, math.floor(Config.MaxPopulation * Config.NightPopulationMultiplier))
--         end
--         diagnostics(string.format(
--             "[WanderingProps] DAYNIGHT_CHANGE isNight=%s effectiveMax=%d",
--             tostring(isNight),
--             effectiveMax
--         ))
--     end
--     if isNight then
--         return math.max(1, math.floor(Config.MaxPopulation * Config.NightPopulationMultiplier))
--     end
--     return Config.MaxPopulation
-- end

-- ============================================================
-- NEW LOCAL FUNCTION: randomizeZonePosition(node)
-- ============================================================
-- Returns a random XZ point within a zone node's boundary, or the exact
-- position for spot nodes. Y is always the node's original Y (ground snap
-- on client handles the rest).
--
-- function randomizeZonePosition(node): Vector3
--     if not node.zoneSize then
--         return node.position
--     end
--     local halfX = node.zoneSize.X / 2
--     local halfZ = node.zoneSize.Z / 2
--     return node.position + Vector3.new(
--         rng:NextNumber(-halfX, halfX),
--         0,
--         rng:NextNumber(-halfZ, halfZ)
--     )
-- end

-- ============================================================
-- MODIFIED: convertNodeIdsToWaypoints()
-- ============================================================
-- Now zone-aware. Zone nodes get randomized positions. POI waypoint
-- positions remain exact (identified by poiWaypointIndexSet).
--
-- Real code currently (lines 262-268):
--   local function convertNodeIdsToWaypoints(pathNodeIds)
--       local waypoints = {}
--       for _, nodeId in ipairs(pathNodeIds) do
--           table.insert(waypoints, graph.nodes[nodeId].position)
--       end
--       return waypoints
--   end
--
-- New signature:
--   local function convertNodeIdsToWaypoints(pathNodeIds: { string }, poiWaypointIndexSet: { [number]: boolean }?)
--
-- New body:
--   local waypoints = {}
--   local indexSet = poiWaypointIndexSet or {}
--   for i, nodeId in ipairs(pathNodeIds) do
--       local node = graph.nodes[nodeId]
--       if node.zoneSize and not indexSet[i] then
--           table.insert(waypoints, randomizeZonePosition(node))
--       else
--           table.insert(waypoints, node.position)
--       end
--   end
--   return waypoints
--
-- Each zone node occurrence gets its own independent random position.
-- If a zone node appears multiple times (e.g., wander return), each gets a
-- different random point within the zone. This is intentional — adds organic feel.

-- ============================================================
-- NEW LOCAL FUNCTION: insertWanderDetours()
-- ============================================================
-- Post-processes a route by inserting mid-route detours to nearby off-path
-- graph neighbors. Adjusts poiWaypointIndices to account for inserted nodes.
--
-- function insertWanderDetours(
--     pathNodeIds: { string },
--     poiWaypointIndices: { number }
-- ): ({ string }, { number })
--
-- Algorithm:
--   1. Build a set of POI waypoint indices (to skip — don't wander at POI stops).
--   2. Build a set of all node IDs currently in the path (off-path = not in this set).
--   3. Walk indices 2 through #pathNodeIds - 1 (skip spawn index 1 and despawn index #pathNodeIds).
--   4. For each eligible index (not a POI waypoint):
--      a. Roll math.random() against Config.WanderChance. If >= chance, skip.
--      b. Get the node's connections. Shuffle them.
--      c. Try up to 2 candidates:
--         - Must not be in the route node set (off-path).
--         - Must be within Config.WanderMaxDistance of the current node position.
--         - If valid, record insertion: {afterIndex = i, wanderNodeId = candidateId}.
--         - Add candidateId to route node set (prevent duplicate wander targets).
--         - Break on first valid candidate.
--   5. Build new pathNodeIds with insertions applied.
--      For each original index i:
--        - Append pathNodeIds[i] to newPath.
--        - If an insertion exists at index i: append wanderNodeId, then pathNodeIds[i] again.
--          (Detour: NPC walks to current waypoint, walks to wander node, walks back.)
--   6. Rebuild poiWaypointIndices using an index mapping (old index → new index).
--
-- Pseudocode:
--   local poiIndexSet = {}
--   for _, idx in ipairs(poiWaypointIndices) do
--       poiIndexSet[idx] = true
--   end
--
--   local routeNodeSet = {}
--   for _, nodeId in ipairs(pathNodeIds) do
--       routeNodeSet[nodeId] = true
--   end
--
--   local insertions = {}  -- afterIndex → wanderNodeId
--   for i = 2, #pathNodeIds - 1 do
--       if poiIndexSet[i] then continue end
--       if math.random() >= Config.WanderChance then continue end
--
--       local node = graph.nodes[pathNodeIds[i]]
--       local connections = node.connections
--       -- Shuffle connections (reuse shuffledCopy pattern from RouteBuilder)
--       local shuffled = {}
--       for _, c in ipairs(connections) do table.insert(shuffled, c) end
--       for k = #shuffled, 2, -1 do
--           local j = math.random(1, k)
--           shuffled[k], shuffled[j] = shuffled[j], shuffled[k]
--       end
--
--       for attempt = 1, math.min(2, #shuffled) do
--           local candidateId = shuffled[attempt]
--           if not routeNodeSet[candidateId] then
--               local candidateNode = graph.nodes[candidateId]
--               if candidateNode then
--                   local dist = (candidateNode.position - node.position).Magnitude
--                   if dist <= Config.WanderMaxDistance then
--                       insertions[i] = candidateId
--                       routeNodeSet[candidateId] = true
--                       break
--                   end
--               end
--           end
--       end
--   end
--
--   -- Build new path with detours
--   local newPath = {}
--   local indexMap = {}  -- oldIndex → newIndex
--   for i = 1, #pathNodeIds do
--       indexMap[i] = #newPath + 1
--       table.insert(newPath, pathNodeIds[i])
--       if insertions[i] then
--           table.insert(newPath, insertions[i])     -- walk to wander node
--           table.insert(newPath, pathNodeIds[i])     -- walk back
--       end
--   end
--
--   -- Remap POI indices
--   local newPoiIndices = {}
--   for _, oldIdx in ipairs(poiWaypointIndices) do
--       table.insert(newPoiIndices, indexMap[oldIdx])
--   end
--
--   return newPath, newPoiIndices

-- ============================================================
-- MODIFIED: spawnNPC() — integrate wander + zone + day/night
-- ============================================================
-- Changes within the existing spawnNPC() function:
--
-- 1. Replace activeCount check (line 271):
--    OLD: if activeCount >= Config.MaxPopulation then return end
--    NEW: if activeCount >= getEffectiveMaxPopulation(wanderingFolder) then return end
--    NOTE: wanderingFolder must be accessible. It is already stored as a local
--    in startup(). Promote it to a module-level variable (add `local wanderingFolder`
--    at module scope, assign in startup() where it's currently declared local).
--
-- 2. After route computation succeeds (after stuck fallback, around line 362):
--    INSERT wander detour step:
--      if Config.WanderChance > 0 and pathNodeIds and poiWaypointIndices then
--          pathNodeIds, poiWaypointIndices = insertWanderDetours(pathNodeIds, poiWaypointIndices)
--      end
--
-- 3. Replace convertNodeIdsToWaypoints call (line 362):
--    OLD: waypoints = convertNodeIdsToWaypoints(pathNodeIds)
--    NEW:
--      local poiWaypointIndexSet = {}
--      for _, idx in ipairs(poiWaypointIndices) do
--          poiWaypointIndexSet[idx] = true
--      end
--      waypoints = convertNodeIdsToWaypoints(pathNodeIds, poiWaypointIndexSet)
--
-- 4. In the fallback path (no-POI route, around line 438):
--    The existing RouteBuilder.buildRoute() returns {waypoints, totalDistance}.
--    Those waypoints are already position-resolved (not node IDs), so no zone
--    randomization happens here.
--    FIX: Change this path to also use node IDs + zone-aware conversion:
--      local routeData = RouteBuilder.buildRoute(graph, walkSpeed)
--    This path returns positions, not node IDs. We have two options:
--      (a) Modify RouteBuilder.buildRoute to return node IDs — invasive.
--      (b) Accept that no-POI routes don't get zone randomization — simple but inconsistent.
--      (c) Duplicate the route-building logic in PopulationController for the no-POI path.
--    CHOSEN: Option (a) is cleanest. Add a new function:
--      RouteBuilder.buildRouteNodeIds(graph): { string }?
--    that returns the node ID array instead of positions. PopulationController
--    handles conversion.
--    See RouteBuilder section below.
--
-- 5. Modify initial spawn burst (line 606):
--    OLD: for _ = 1, Config.MaxPopulation do
--    NEW: for _ = 1, getEffectiveMaxPopulation(wanderingFolder) do
--
-- 6. Modify spawn loop check (line 614):
--    OLD: if activeCount < Config.MaxPopulation then
--    NEW: if activeCount < getEffectiveMaxPopulation(wanderingFolder) then
```

### RouteBuilder.luau (MODIFIED — minimal)

```lua
-- NEW FUNCTION: buildRouteNodeIds()
-- Same logic as existing buildRoute(), but returns node IDs instead of positions.
-- PopulationController uses this for zone-aware position conversion.
--
-- function RouteBuilder.buildRouteNodeIds(graph): { string }?
--     for _ = 1, 3 do
--         local spawnId = RouteBuilder.pickRandomSpawn(graph)
--         local despawnId = RouteBuilder.pickRandomDespawn(graph)
--         local nodeIds = RouteBuilder.computeRoute(graph, spawnId, despawnId)
--         if nodeIds then
--             return nodeIds
--         end
--     end
--     return nil
-- end
--
-- This is the ONLY addition to RouteBuilder.luau.
-- The existing buildRoute() function remains for backward compatibility
-- but is no longer called by PopulationController.
```

---

## Data Flow for New Behaviors

### Zone Randomization Flow

1. **Graph build time** (`WaypointGraph.build()`):
   - For each waypoint part, reads `Zone` attribute.
   - If `Zone == true` and `nodeType == "waypoint"`, stores `part.Size` as `node.zoneSize`.
   - Spawn/despawn nodes: zoneSize always nil regardless of attribute.

2. **Route planning** (`PopulationController.spawnNPC()`):
   - Route is computed as node IDs (unchanged from Pass 2).
   - After wander detour insertion, `convertNodeIdsToWaypoints()` is called.
   - For each node: if `zoneSize` is non-nil and the index is NOT a POI waypoint, pick a random XZ offset within the zone bounds.
   - Each zone node occurrence gets its own independent random position.

3. **Client receives positions** (`NPCSpawnData.waypoints`):
   - Client sees `{ Vector3 }` — doesn't know about zones.
   - Late-join, state machine, despawn timing — all work unchanged on the position array.

### Wander Detour Flow

1. **After multi-segment route succeeds** (in `spawnNPC()`):
   - `insertWanderDetours(pathNodeIds, poiWaypointIndices)` is called.
   - Walks each intermediate waypoint (not spawn, despawn, or POI stop).
   - Rolls `WanderChance` per eligible waypoint.
   - If triggered: picks a random off-path neighbor within `WanderMaxDistance`.
   - Inserts detour into path: `[..., B, W, B, ...]` (walk to wander node, walk back).
   - Adjusts `poiWaypointIndices` for the shifted positions.

2. **Effect on timing:**
   - Wander detours add extra waypoints to the position array.
   - `routeDistance(waypoints)` naturally includes detour distance.
   - `totalDuration` calculation is already based on the final waypoints array.
   - `seatClaims.releaseTime` is calculated from the final waypoints array (runs after insertion).
   - Client `expectedDespawnTime` uses `routeDistance(data.waypoints)` — includes detour distance.
   - Client `calculateRouteState()` works on the final position array — handles longer routes naturally.

3. **No-POI routes:**
   - When no POI registry or empty, use `RouteBuilder.buildRouteNodeIds(graph)`.
   - Apply wander detours to the returned node IDs (with empty poiWaypointIndices).
   - Convert to positions with zone randomization.
   - Timing calculated from final waypoints as before.

### Day/Night Population Cap Flow

1. **Each spawn cycle** (spawn loop + initial burst):
   - `getEffectiveMaxPopulation(wanderingFolder)` reads `IsNight` attribute.
   - If `DayNightEnabled` is false, returns `MaxPopulation` (no change).
   - If `IsNight == true`, returns `max(1, floor(MaxPopulation * NightPopulationMultiplier))`.
   - Compares `activeCount` against effective max.

2. **Population reduction is organic:**
   - When effective max drops (night), no NPCs are force-despawned.
   - NPCs finish their current routes normally.
   - No new NPCs spawn until `activeCount < effectiveMax`.
   - Population decreases naturally through normal despawn attrition.

3. **Population recovery:**
   - When `IsNight` becomes false (dawn), effective max returns to `MaxPopulation`.
   - Normal spawn loop fills population back up at `SpawnInterval` rate.
   - If `InitialSpawnBurst` logic is desired for recovery: NOT added — the existing
     spawn loop at `SpawnInterval` provides smooth recovery. A burst at dawn transition
     would look unnatural.

### Modified spawnNPC() Full Flow (with all 3 features)

This replaces the existing `spawnNPC()` body in PopulationController.

```
1.  effectiveMax = getEffectiveMaxPopulation(wanderingFolder)
2.  if activeCount >= effectiveMax then return end
3.  Pick model, calculate walkSpeed, generate id (unchanged)

--- POI route path (existing, with modifications) ---
4.  If poiRegistry exists and has POIs:
    a. Select POIs, claim seats (unchanged)
    b. Build node sequence (unchanged)
    c. computeMultiSegmentRoute → pathNodeIds, poiWaypointIndices (unchanged)
    d. Stuck fallback (unchanged)
    e. NEW: Insert wander detours:
       if Config.WanderChance > 0 then
           pathNodeIds, poiWaypointIndices = insertWanderDetours(pathNodeIds, poiWaypointIndices)
       end
    f. NEW: Build poiWaypointIndexSet from poiWaypointIndices
    g. NEW: Zone-aware conversion:
       waypoints = convertNodeIdsToWaypoints(pathNodeIds, poiWaypointIndexSet)
    h. totalDistance = routeDistance(waypoints) (unchanged — works on final positions)
    i. Build poiStops, calculate timing, etc. (unchanged — uses final waypoints/indices)

--- No-POI route path (modified) ---
5.  Else (no POI registry or empty):
    a. NEW: nodeIds = RouteBuilder.buildRouteNodeIds(graph)
       if not nodeIds then routeFailures += 1; return end
    b. NEW: Insert wander detours (with empty poiWaypointIndices):
       if Config.WanderChance > 0 then
           nodeIds, _ = insertWanderDetours(nodeIds, {})
       end
    c. NEW: Zone-aware conversion:
       waypoints = convertNodeIdsToWaypoints(nodeIds, nil)
    d. totalDistance = routeDistance(waypoints)

6.  Calculate startTime, totalDwellTime, totalDuration (unchanged)
7.  Create NPCRecord, schedule seat releases, fire spawn, schedule despawn (unchanged)
```

---

## Integration Pass (against real code)

### Data Lifecycle Traces

**Node.zoneSize**
- **Created by:** `WaypointGraph.build()` — reads `Zone` attribute + `part.Size` during `ensureNodeForPart()` (lines 72-94 of real code).
- **Stored in:** Graph.nodes[nodeId].zoneSize. Type: `Vector3?`. Lifetime: server session (static).
- **Read by:** `PopulationController.randomizeZonePosition()` and `convertNodeIdsToWaypoints()`.
- **Never modified** after graph build. Read-only.
- **Verified:** Node type in Types.luau gains `zoneSize: Vector3?`. Graph.nodes stores Nodes. PopulationController accesses `graph.nodes[nodeId]` which returns a Node with the new field.

**wanderingFolder (promoted to module scope)**
- **Currently:** Local variable in `startup()` (line 514 of real code: `local wanderingFolder = Workspace:FindFirstChild("WanderingProps")`).
- **Change:** Declare `local wanderingFolder` at module scope (after line 37). Assign in `startup()`.
- **Read by:** `getEffectiveMaxPopulation()`, `spawnNPC()` (via effective max check), startup spawn loop, initial burst.
- **Verified:** Already exists, just promoted from local to module scope.

**IsNight attribute**
- **Created by:** External buyer script sets `wanderingFolder:SetAttribute("IsNight", true/false)`.
- **Read by:** `getEffectiveMaxPopulation()` via `wanderingFolder:GetAttribute("IsNight")`.
- **Not stored** server-side — read fresh each spawn cycle.
- **Verified:** `GetAttribute` returns nil if not set, handled with `if isNight == nil then isNight = false`.

**Wander detour insertions (pathNodeIds modification)**
- **Created by:** `insertWanderDetours()` — builds new pathNodeIds array with wander nodes inserted.
- **Input:** pathNodeIds from `computeMultiSegmentRoute()` (or `buildRouteNodeIds()`), poiWaypointIndices.
- **Output:** Updated pathNodeIds, updated poiWaypointIndices. Both are `{ string }` and `{ number }`.
- **Consumed by:** `convertNodeIdsToWaypoints()` — converts final node IDs to positions.
- **Lifetime:** Local to `spawnNPC()` — consumed immediately, not stored.
- **Verified:** insertWanderDetours returns same types as input. convertNodeIdsToWaypoints accepts same types.

### API Composition Checks (new calls against real code)

| Caller | Callee | Args Match | Return Handled | Verified Against |
|--------|--------|-----------|----------------|-----------------|
| PopulationController | getEffectiveMaxPopulation(wanderingFolder) | Folder (module scope) | number | New function, internal |
| PopulationController | randomizeZonePosition(node) | Node (from graph.nodes) | Vector3 | New function, internal |
| PopulationController | insertWanderDetours(pathNodeIds, poiWaypointIndices) | {string}, {number} | {string}, {number} | New function, internal |
| PopulationController | convertNodeIdsToWaypoints(pathNodeIds, poiIndexSet) | {string}, {[number]:boolean}? | {Vector3} | Modified existing function (line 262) |
| PopulationController | RouteBuilder.buildRouteNodeIds(graph) | Graph | {string}? — nil means no route | New function in RouteBuilder |
| PopulationController | wanderingFolder:GetAttribute("IsNight") | string key | boolean? (nil if not set) | Roblox Instance API |
| WaypointGraph.build | part:GetAttribute("Zone") | string key | boolean? | Roblox Instance API |
| WaypointGraph.build | part.Size | read property | Vector3 | Roblox BasePart API |

### Cross-Feature Interaction Checks

| Interaction | Status | Notes |
|-------------|--------|-------|
| Zone + POI waypoint | Safe | POI waypoint indices are in poiWaypointIndexSet → skipped during zone randomization |
| Zone + wander detour | Safe | Wander target at a zone node gets randomized during position conversion. Return-to-origin at zone gets independently randomized (organic feel). |
| Wander + POI stops | Safe | Wander detours skip POI waypoint indices. poiWaypointIndices remapped after insertion. |
| Wander + seat release timing | Safe | Seat release timing is calculated AFTER wander insertion, from final waypoints array. |
| Wander + late-join | Safe | Client receives final waypoints (with detours embedded). calculateRouteState handles longer arrays. |
| Wander + social walk-to-seat | Safe | seatCFrame/waypointIndex in poiStops point to correct post-insertion indices. socialSeatTravelDistance uses waypoints[poi.waypointIndex]. |
| Day/night + initial burst | Safe | Initial burst uses getEffectiveMaxPopulation(). If game starts at night, fewer NPCs spawn. |
| Day/night + existing NPCs | Safe | No force-despawn. Population decreases organically via normal despawn. |

---

## Diagnostics Updates

### New Reason Codes
All gated behind `Config.DiagnosticsEnabled`.

- `DAYNIGHT_CHANGE` — Day/night state transition. Includes: isNight, effectiveMax. Only logged on actual transition (not every cycle).
- `WANDER_DETOUR` — Wander detour inserted. Includes: npcId, fromNode, wanderNode, routeIndex.
- `ZONE_ROUTE` — Route includes zone nodes. Includes: npcId, zoneCount (how many zone nodes in the route).

### New Health Counters
Added to PopulationController module-level variables:
- `wanderDetoursTotal` — lifetime wander detours inserted
- `zoneRoutesTotal` — lifetime routes that included at least one zone node

### Diagnostics Format
```
[WanderingProps] DAYNIGHT_CHANGE isNight=true effectiveMax=6
[WanderingProps] DAYNIGHT_CHANGE isNight=false effectiveMax=20
[WanderingProps] WANDER_DETOUR npc_42 from=TownSquare wander=Alley2 idx=4
[WanderingProps] ZONE_ROUTE npc_42 zones=3
```

---

## Startup Validator Updates

Added to PopulationController `startup()`, run after existing validation and graph build.

```lua
-- Insert after graph validation (line 541) and before POI discovery (line 545):

-- Validate zone nodes
for _, node in pairs(graph.nodes) do
    if node.zoneSize and node.nodeType ~= "waypoint" then
        warn(string.format(
            '[WanderingProps] WARNING: Zone attribute on %s node "%s" ignored. Only waypoint nodes can be zones.',
            node.nodeType,
            node.id
        ))
        node.zoneSize = nil  -- clear it to prevent accidental use
    end
    if node.zoneSize and (node.zoneSize.X <= 0 or node.zoneSize.Z <= 0) then
        warn(string.format(
            '[WanderingProps] WARNING: Zone node "%s" has zero or negative Size (%.1f x %.1f). Treating as spot.',
            node.id,
            node.zoneSize.X,
            node.zoneSize.Z
        ))
        node.zoneSize = nil
    end
end

-- Insert after existing validateConfig() additions (or within validateConfig):
if Config.WanderChance < 0 or Config.WanderChance > 1 then
    warn("[WanderingProps] WARNING: WanderChance should be between 0.0 and 1.0.")
end
if Config.WanderMaxDistance < 1 then
    warn("[WanderingProps] WARNING: WanderMaxDistance should be >= 1.")
end
if Config.DayNightEnabled then
    if Config.NightPopulationMultiplier < 0 or Config.NightPopulationMultiplier > 1 then
        warn("[WanderingProps] WARNING: NightPopulationMultiplier should be between 0.0 and 1.0.")
    end
end
```

| Contract | Check | Severity | Error Message |
|----------|-------|----------|---------------|
| Zone not on spawn/despawn | `node.zoneSize and node.nodeType ~= "waypoint"` | WARNING | `Zone attribute on {nodeType} node "{id}" ignored. Only waypoint nodes can be zones.` |
| Zone size positive | `node.zoneSize.X <= 0 or node.zoneSize.Z <= 0` | WARNING | `Zone node "{id}" has zero or negative Size. Treating as spot.` |
| WanderChance range | `Config.WanderChance < 0 or > 1` | WARNING | `WanderChance should be between 0.0 and 1.0.` |
| WanderMaxDistance range | `Config.WanderMaxDistance < 1` | WARNING | `WanderMaxDistance should be >= 1.` |
| NightPopulationMultiplier range | `Config.NightPopulationMultiplier < 0 or > 1` (only if DayNightEnabled) | WARNING | `NightPopulationMultiplier should be between 0.0 and 1.0.` |

---

## Golden Tests for This Pass

### Test 9: Zone Waypoint Variation
- **Setup:** Waypoint graph with spawn, 2 zone nodes (large Parts, Size = 30×1×30), 1 spot node, despawn. Config: MaxPopulation = 10, WanderChance = 0 (disabled), DiagnosticsEnabled = true.
- **Action:** Start server. Wait for 10 NPCs to spawn and walk routes.
- **Expected:** NPCs passing through zone nodes walk to visibly different positions within the zone area. NPCs at the spot node converge on the same point.
- **Pass condition:** Visual: NPCs are spread across the zone area, not clustered at the center. Diagnostics: ZONE_ROUTE shows zone count > 0. No errors.

### Test 10: Random Wander Detour
- **Setup:** Waypoint graph with spawn, 4 waypoints in a line, despawn. One off-path waypoint connected to the second main waypoint. Config: MaxPopulation = 5, WanderChance = 1.0 (always wander), WanderMaxDistance = 100, DiagnosticsEnabled = true.
- **Action:** Start server. Observe NPC routes.
- **Expected:** Every NPC detours to the off-path waypoint when passing the second main waypoint, then walks back before continuing.
- **Pass condition:** Visual: NPCs visibly deviate from the main line. Diagnostics: WANDER_DETOUR logged for each NPC. No errors.

### Test 11: Day/Night Population Cap
- **Setup:** Waypoint graph with spawn, waypoints, despawn. Config: MaxPopulation = 10, DayNightEnabled = true, NightPopulationMultiplier = 0.3, SpawnInterval = 1, DiagnosticsEnabled = true.
- **Action:** Start server (no IsNight attribute set → daytime). Wait for population to reach 10. Set `workspace.WanderingProps:SetAttribute("IsNight", true)` via command bar. Wait 60 seconds. Set `IsNight = false`.
- **Expected:** After setting IsNight, no new NPCs spawn. Population decreases as existing NPCs despawn, stabilizing around 3 (floor(10 * 0.3)). After clearing IsNight, population recovers to 10.
- **Pass condition:** Diagnostics: DAYNIGHT_CHANGE logged on each transition. Population count in SPAWN/DESPAWN messages shows decrease then recovery. No force-despawns during night.

### Test 12: Zone + POI Interaction
- **Setup:** Waypoint graph with spawn, 1 zone node, despawn. A Scenic POI linked to a spot waypoint adjacent to the zone. Config: MaxPopulation = 5, ScenicDwellMin = 3, ScenicDwellMax = 3, WanderChance = 0.
- **Action:** Start server. Observe NPCs visiting the Scenic POI after passing through the zone.
- **Expected:** NPCs spread out in the zone area, then converge on the exact POI waypoint position to dwell (face ViewZone, idle).
- **Pass condition:** Visual: NPCs at the zone are spread; NPCs at the Scenic POI are at the same exact spot. POI dwell behavior works correctly.

### Regression Tests
Re-run from Pass 1 and 2:
- **Test 1: Basic Spawn-Walk-Despawn Cycle** — Verify no-POI routes with WanderChance = 0 still work.
- **Test 2: Late-Join Sync** — Verify late-join handles routes with zone-randomized positions and wander detours.
- **Test 4: Scenic POI Visit** — Verify scenic POI still works with wander detours in the route.
- **Test 5: Social POI Sit** — Verify social walk-to-seat/walk-back still works with wander detours.

---

## Critic Review Notes

**Review 1:** All design verification checks PASSED. No design flaws found. 16 items were flagged as "blocking" but are implementation tasks confirming what the design correctly specifies — not design problems.

**Verified PASS on:**
- Data lifecycle traces for Node.zoneSize, wanderingFolder promotion, IsNight attribute, wander detour insertions
- API composition for all new/modified function calls
- Cross-feature interactions: zone + POI, zone + wander, wander + POI, wander + seat release timing, wander + late-join, wander + social walk-to-seat
- No unbounded loops, no memory leaks, no client authority issues
- Regression safety for Pass 1 and Pass 2 behaviors

**Flagged items (non-blocking, noted):**
1. Wander insertion walks path twice (O(n)) — negligible for typical route lengths (<20 nodes).
2. POI index set construction duplicated between spawnNPC and insertWanderDetours — minor coupling, acceptable.
3. Independent random positions for repeated zone nodes (wander return) — intentional for organic feel, documented in design.
4. ZONE_ROUTE diagnostic shows count but not node IDs — enhancement for later, sufficient for v1.
5. Zone size validation clears zoneSize but leaves node in graph — correct (falls back to spot behavior).
6. Initial spawn burst respects night multiplier if IsNight is true at server start — correct per spec, document for buyers.
