# Pass 2 Design: Points of Interest — Wandering Props

**Feature pass:** 2 of 4
**Based on:** feature-passes.md, idea-locked.md
**Existing code:** PopulationController, NPCClient, NPCMover, NPCAnimator, WaypointGraph, RouteBuilder, Config, Types, Remotes (all in `src/`)
**Critic Status:** APPROVED (rev 2 — 10 blocking issues fixed)
**Date:** 2026-02-14

---

## What This Pass Adds

NPCs now follow purposeful routes through Points of Interest instead of random walks. Three POI types: Scenic (stop and look), Busy (walk through for foot traffic), and Social (sit at grouped seats). Routes become spawn → 2–4 weighted POIs → despawn. Social POIs have server-managed seat claiming with capacity caps and social-preference weighting. Stuck NPCs (unreachable POI) gracefully fall back to despawn routing.

---

## File Changes

### New Files
| File | Location | Purpose |
|------|----------|---------|
| `POIRegistry.luau` | `src/server/` | Discovers POIs from workspace at startup, builds registry. Server-only module. |

### Modified Files
| File | What's Changing | Why |
|------|----------------|-----|
| `Types.luau` | Add `POIStopData` type, extend `NPCSpawnData` with `poiStops`, extend `NPCState` with POI state fields, add `partToId` to `Graph` | Route data now carries POI behavior |
| `Config.luau` | Add POI config values (dwell ranges, capacity, social weight, POI count) | Buyer-configurable POI settings |
| `WaypointGraph.luau` | Add `partToId` map to returned `Graph` table | POIRegistry needs to resolve workspace Part references to graph node IDs |
| `RouteBuilder.luau` | Add `computeMultiSegmentRoute()` function | Multi-leg pathfinding through POI waypoints |
| `PopulationController.server.luau` | POI registry init, POI-aware route planning, seat claim/release, stuck fallback, new diagnostics | Core server changes for POI system |
| `NPCClient.client.luau` | NPC state machine (walking/dwelling/sitting/finished), POI-aware late-join, sit animation | Client handles POI visual behaviors |
| `NPCMover.luau` | Add optional `stopAtWaypoint` parameter to `update()` | NPC must stop at POI waypoints instead of walking past |
| `NPCAnimator.luau` | Add `setupSit()`, `playSit()`, `stopSit()` functions | Sit animation for Social POIs |
| `Remotes.luau` | **Unchanged** | Existing 3 remotes are sufficient; `NPCSpawnData` payload extended in-place |

---

## Workspace Contracts (POI Setup)

Buyers create POIs under `Workspace/WanderingProps/POIs/`. Each POI is a **Folder** with attributes and children specific to its type. Every POI links to a waypoint in the existing graph via an ObjectValue.

### Scenic POI
```
Workspace/WanderingProps/POIs/
  CliffView (Folder)
    Attributes:
      POIType = "scenic"          (string, REQUIRED)
      Weight  = 2.0               (number, optional — defaults to Config.DefaultPOIWeight)
      DwellMin = 5                (number, optional — defaults to Config.ScenicDwellMin)
      DwellMax = 15               (number, optional — defaults to Config.ScenicDwellMax)
    Waypoint (ObjectValue, Value → a Part in Workspace/WanderingProps/Waypoints)
    ViewZone (BasePart — invisible marker positioned where NPC should look)
```
**Rules:**
- `Waypoint` ObjectValue MUST point to a valid Part in the Waypoints folder.
- `ViewZone` child must be a BasePart. NPC faces `ViewZone.Position` during dwell.
- If `ViewZone` is missing, NPC faces the direction it arrived from (fallback, with warning).

### Busy POI
```
Workspace/WanderingProps/POIs/
  MarketStreet (Folder)
    Attributes:
      POIType = "busy"            (string, REQUIRED)
      Weight  = 3.0               (number, optional)
    Waypoint (ObjectValue, Value → a Part in Waypoints folder)
```
**Rules:**
- No extra children needed. NPC walks through without stopping.
- Weight controls foot traffic density (higher weight → more NPCs routed through).

### Social POI
```
Workspace/WanderingProps/POIs/
  CafeTables (Folder)
    Attributes:
      POIType = "social"          (string, REQUIRED)
      Weight  = 2.0               (number, optional)
      DwellMin = 10               (number, optional — defaults to Config.SocialDwellMin)
      DwellMax = 30               (number, optional — defaults to Config.SocialDwellMax)
      CapacityPercent = 0.75      (number, optional — defaults to Config.SocialCapacityPercent)
      SocialWeight = 0.7          (number, optional — defaults to Config.SocialWeight)
    Waypoint (ObjectValue, Value → a Part in Waypoints folder)
    Table1 (Folder)               — a "group" (table/bench)
      Seat1 (BasePart)            — invisible seat marker, CFrame = sit position + facing direction
      Seat2 (BasePart)
    Table2 (Folder)
      Seat1 (BasePart)
      Seat2 (BasePart)
    Bench1 (Folder)
      Seat1 (BasePart)
```
**Rules:**
- Each direct Folder or Model child of the Social POI is a **group** (table/bench).
- Each BasePart child of a group is a **seat**. The seat's `CFrame` defines where the NPC sits and which direction it faces.
- Seat parts should be invisible markers (`Transparency = 1`, `CanCollide = false`, `Anchored = true`). The system enforces this at startup.
- Social weighting: with probability `SocialWeight`, the system prefers seats at groups that already have NPCs sitting. Otherwise picks any available seat.
- `CapacityPercent`: only this fraction of total seats can be occupied simultaneously. Ensures seat turnover.

### Runtime Hiding
At startup, the server sets `Transparency = 1` and `CanCollide = false` on all ViewZone parts and all seat marker parts (same treatment as waypoint parts in Pass 1).

---

## New Data Structures

```lua
-- Types.luau — ADDITIONS

-- POI stop information sent from server to client per NPC
export type POIStopData = {
    type: "scenic" | "busy" | "social",
    waypointIndex: number,     -- index in NPCSpawnData.waypoints where this POI is located
    dwellTime: number,         -- seconds to dwell (0 for busy)
    viewTarget: Vector3?,      -- scenic only: position to face
    seatCFrame: CFrame?,       -- social only: where NPC sits
}

-- Server-only: tracks a claimed seat for release scheduling
export type SeatClaim = {
    poiId: string,
    seatIndex: number,         -- index into the POI's flat seat list
    releaseTime: number,       -- workspace:GetServerTimeNow() when seat should be freed
}
```

```lua
-- Types.luau — MODIFICATIONS

-- Graph gains partToId mapping
export type Graph = {
    nodes: { [string]: Node },
    spawns: { string },
    despawns: { string },
    partToId: { [Instance]: string },  -- NEW: workspace Part → node ID
}

-- NPCSpawnData gains optional poiStops (backward compatible — nil = no POIs)
export type NPCSpawnData = {
    id: string,
    modelName: string,
    modelTemplate: Model?,
    walkSpeed: number,
    waypoints: { Vector3 },
    startTime: number,
    poiStops: { POIStopData }?,       -- NEW
}

-- NPCRecord gains POI tracking (server-side)
export type NPCRecord = {
    id: string,
    modelName: string,
    walkSpeed: number,
    waypoints: { Vector3 },
    startTime: number,
    totalDuration: number,
    modelTemplate: Model?,             -- existing (from real code)
    poiStops: { POIStopData }?,        -- NEW
    seatClaims: { SeatClaim }?,        -- NEW: for release on despawn
}

-- NPCState gains POI state machine fields (client-side)
export type NPCState = {
    id: string,
    model: Model,
    walkSpeed: number,
    waypoints: { Vector3 },
    currentLeg: number,
    legProgress: number,
    lastGroundY: number,
    expectedDespawnTime: number,
    animator: Animator,
    walkTrack: AnimationTrack,
    idleTrack: AnimationTrack,
    -- NEW FIELDS:
    state: "walking" | "dwelling" | "sitting" | "finished",
    poiStops: { POIStopData }?,
    nextPoiStopIdx: number,            -- 1-indexed into poiStops, tracks next unvisited POI
    dwellEndTime: number?,             -- GetServerTimeNow() when current dwell/sit ends
    preSeatCFrame: CFrame?,            -- social: model CFrame before sitting, to return to
    sitTrack: AnimationTrack?,         -- sit animation track (loaded if social POIs in route)
}
```

---

## New Config Values

```lua
-- Config.luau — ADDITIONS (append after existing values, before return)

-- POI GENERAL
Config.POICountMin = 2              -- Min POIs per NPC route. Range: 0-4.
Config.POICountMax = 4              -- Max POIs per NPC route. Range: 1-6.
Config.DefaultPOIWeight = 1.0       -- Default weight when POI has no Weight attribute. Range: 0.1-10.

-- SCENIC POI
Config.ScenicDwellMin = 5           -- Default min dwell seconds. Range: 1-30.
Config.ScenicDwellMax = 15          -- Default max dwell seconds. Range: 5-60.

-- SOCIAL POI
Config.SocialDwellMin = 10          -- Default min dwell seconds. Range: 5-60.
Config.SocialDwellMax = 30          -- Default max dwell seconds. Range: 10-120.
Config.SocialCapacityPercent = 0.75 -- Default max fraction of seats occupied. Range: 0.1-1.0.
Config.SocialWeight = 0.7           -- Default probability of preferring occupied groups. Range: 0.0-1.0.
```

**Per-instance overrides:** If a POI Folder has `DwellMin`, `DwellMax`, `CapacityPercent`, or `SocialWeight` attributes, those override the Config defaults for that specific POI.

---

## New/Modified APIs

### POIRegistry.luau (NEW — `src/server/`)

```lua
local POIRegistry = {}

-- Internal types (server-only, not exported to Types.luau)
--
-- type SeatInfo = {
--     cframe: CFrame,
--     groupIndex: number,     -- which group this seat belongs to
--     occupiedBy: string?,    -- NPC ID or nil
-- }
--
-- type GroupInfo = {
--     id: string,             -- folder Name (for diagnostics)
--     seatIndices: {number},  -- indices into the POI's seats array
--     occupiedCount: number,
-- }
--
-- type POIInfo = {
--     id: string,             -- unique ID (Folder instance-based, like waypoint IDs)
--     instance: Folder,       -- the workspace Folder
--     poiType: "scenic" | "busy" | "social",
--     weight: number,
--     waypointNodeId: string, -- graph node ID of the linked waypoint
--     waypointPosition: Vector3,
--     dwellMin: number?,      -- scenic/social
--     dwellMax: number?,      -- scenic/social
--     viewTarget: Vector3?,   -- scenic only
--     seats: {SeatInfo}?,     -- social only (flat array)
--     groups: {GroupInfo}?,   -- social only
--     totalSeats: number?,    -- social only
--     occupiedCount: number?, -- social only (current total occupied seats)
--     capacityPercent: number?, -- social only
--     socialWeight: number?,  -- social only
-- }
--
-- type Registry = {
--     pois: {POIInfo},        -- all valid POIs
--     totalWeight: number,    -- sum of all weights (for weighted selection)
-- }

-- Scans Workspace/WanderingProps/POIs/ folder. For each valid POI child:
--   - Reads POIType attribute
--   - Resolves Waypoint ObjectValue to graph node ID via graph.partToId
--   - Reads type-specific children (ViewZone, seat groups)
--   - Reads per-instance attribute overrides (Weight, DwellMin, etc.)
-- Skips invalid POIs with warnings. Returns nil if POIs folder doesn't exist.
-- Also hides ViewZone and seat marker parts (Transparency=1, CanCollide=false).
function POIRegistry.discover(poisFolder: Folder, graph: Graph): Registry?

-- Selects `count` unique POIs by weighted random. No duplicates.
-- Returns ordered array of POIInfo (ordered by nearest-neighbor from spawnPosition
-- for more natural route shapes).
function POIRegistry.selectPOIs(registry: Registry, count: number, spawnPosition: Vector3): {POIInfo}

-- Attempts to claim a seat at a Social POI.
-- With probability socialWeight: prefer groups with at least 1 occupied seat.
-- Otherwise: pick any available seat.
-- Checks capacity cap before claiming.
-- Returns seat index and CFrame, or nil if no seat available (capacity full).
function POIRegistry.claimSeat(poi: POIInfo, npcId: string): (number?, CFrame?)

-- Releases a previously claimed seat. Decrements occupiedCount.
-- IDEMPOTENT: If seat is already unoccupied (occupiedBy == nil), this is a no-op.
-- Guards: check seat.occupiedBy ~= nil before decrementing group.occupiedCount and
-- poi.occupiedCount. This safely handles double-release from both task.delay and despawn.
function POIRegistry.releaseSeat(poi: POIInfo, seatIndex: number): ()

-- Returns the POIInfo for a given POI id. Used for seat release on despawn.
function POIRegistry.getPOI(registry: Registry, poiId: string): POIInfo?

return POIRegistry
```

### WaypointGraph.luau (MODIFIED)

```lua
-- CHANGE: build() now includes partToId in the returned graph table.
-- This is the ONLY change to this file.
--
-- File: src/shared/WaypointGraph.luau
-- Modify line 95 of the real code. Change:
--   local graph = { nodes = nodes, spawns = spawns, despawns = despawns }
-- To:
--   local graph = { nodes = nodes, spawns = spawns, despawns = despawns, partToId = partToId }
--
-- `partToId` is already a local variable declared at line 27 of build().
-- It maps each waypoint Part instance to its generated node ID string.
-- This change just exposes it in the return table.
-- Backward compatible: existing consumers (RouteBuilder, PopulationController) ignore the new field.
```

### RouteBuilder.luau (MODIFIED)

```lua
-- EXISTING FUNCTIONS: computeRoute, pickRandomSpawn, pickRandomDespawn, buildRoute — ALL UNCHANGED.
-- Pass 1 NPCs (no POIs) continue to use buildRoute() exactly as before.

-- NEW FUNCTION:

-- Computes a route through an ordered sequence of graph nodes.
-- nodeSequence: {spawnId, poi1WaypointId, poi2WaypointId, ..., despawnId}
-- Runs BFS (computeRoute) between each consecutive pair, concatenates results.
-- Removes duplicate nodes at segment joins.
--
-- Returns:
--   pathNodeIds: flat ordered list of node IDs from spawn to despawn
--   poiWaypointIndices: array where poiWaypointIndices[i] = index in pathNodeIds
--                       where the i-th POI waypoint is located (excludes spawn and despawn)
--   Returns nil if any segment has no valid path.
--
-- Algorithm:
--   local fullPath = {}
--   local poiIndices = {}
--   for i = 1, #nodeSequence - 1 do
--     local segment = computeRoute(graph, nodeSequence[i], nodeSequence[i + 1])
--     if not segment then return nil end
--     for j = 1, #segment do
--       if j == 1 and #fullPath > 0 then
--         -- skip duplicate at join (previous segment's last = this segment's first)
--       else
--         table.insert(fullPath, segment[j])
--       end
--     end
--     -- Record POI location (all intermediate stops, not spawn/despawn)
--     if i >= 2 then
--       -- nodeSequence[i] was a POI waypoint; it's now at the join point
--       -- which is fullPath[#fullPath - (#segment - 1)] ... actually it's simpler:
--       -- the POI node is at the END of the previous iteration's contribution.
--     end
--   end
--
-- Cleaner approach: record indices explicitly:
--   After processing segment i (from nodeSequence[i] to nodeSequence[i+1]):
--     The POI at nodeSequence[i+1] is at fullPath[#fullPath]
--     But we only record intermediate POIs (indices 2 through #nodeSequence-1).
--
--   local fullPath = {}
--   local poiIndices = {}
--   for i = 1, #nodeSequence - 1 do
--     local segment = RouteBuilder.computeRoute(graph, nodeSequence[i], nodeSequence[i + 1])
--     if not segment then return nil end
--     local startJ = 1
--     if #fullPath > 0 then startJ = 2 end  -- skip duplicate
--     for j = startJ, #segment do
--       table.insert(fullPath, segment[j])
--     end
--     -- After this segment, nodeSequence[i+1] is at fullPath[#fullPath].
--     -- Record it if it's a POI (not the final despawn).
--     if i < #nodeSequence - 1 then
--       table.insert(poiIndices, #fullPath)
--     end
--   end
--   return fullPath, poiIndices
function RouteBuilder.computeMultiSegmentRoute(
    graph: Graph,
    nodeSequence: { string }
): ({ string }?, { number }?)
```

### PopulationController.server.luau (MODIFIED)

```lua
-- STRUCTURAL CHANGES (additions to existing code):

-- New requires (add after existing requires):
--   local POIRegistry = require(script.Parent:WaitForChild("POIRegistry"))

-- New module-level state:
--   local poiRegistry = nil  -- set during startup after POI discovery

-- MODIFIED: startup() function — add after hideWaypointParts():
--   local poisFolder = wanderingFolder:FindFirstChild("POIs")
--   if poisFolder then
--       poiRegistry = POIRegistry.discover(poisFolder, graph)
--       -- diagnostics: log POI counts
--   else
--       warn("[WanderingProps] WARNING: No POIs folder found. NPCs will walk random routes.")
--   end

-- MODIFIED: spawnNPC() function — POI-aware route planning:
--   (See "NPC Spawn Flow with POIs" in Data Flow section below for exact logic)

-- MODIFIED: despawnNPC() function — release any remaining seat claims:
--   Before removing from activeNPCs:
--     if record.seatClaims then
--       for _, claim in ipairs(record.seatClaims) do
--         local poi = POIRegistry.getPOI(poiRegistry, claim.poiId)
--         if poi then POIRegistry.releaseSeat(poi, claim.seatIndex) end
--       end
--     end

-- MODIFIED: makeSpawnData() — include poiStops in payload:
--   return {
--     id = record.id,
--     modelName = record.modelName,
--     modelTemplate = record.modelTemplate,
--     walkSpeed = record.walkSpeed,
--     waypoints = record.waypoints,
--     startTime = record.startTime,
--     poiStops = record.poiStops,  -- NEW (nil for no-POI routes, backward-compatible)
--   }
--   NOTE: record.poiStops is set during spawnNPC() step 9 (before makeSpawnData is called
--   in step 13). When no POIs are selected, record.poiStops is nil — this is safe because
--   the client state machine treats nil poiStops as pure walking (Pass 1 behavior).
```

### NPCMover.luau (MODIFIED)

```lua
-- CHANGE: update() gains optional stopAtWaypoint parameter.
--
-- Real code currently (line 84):
--   function NPCMover.update(npc, dt: number)
--
-- New signature:
--   function NPCMover.update(npc, dt: number, stopAtWaypoint: number?): boolean
--
-- Inside the while loop (line 91), add check BEFORE advancing:
--
--   while distanceToTravel > 0 and npc.currentLeg < #waypoints do
--       -- NEW: stop at POI waypoint
--       if stopAtWaypoint and npc.currentLeg >= stopAtWaypoint then
--           break
--       end
--       -- ... existing leg advancement logic unchanged ...
--   end
--
-- When stopAtWaypoint is nil, behavior is identical to Pass 1.
-- When stopAtWaypoint is set, the NPC halts at that waypoint index.
-- At halt: npc.currentLeg == stopAtWaypoint, npc.legProgress == 0.
--
-- INVARIANT: npc.currentLeg is the 1-indexed FROM waypoint of the current leg.
--   When currentLeg == K and legProgress == 0, the NPC is at waypoints[K].
--   The `>=` check works because the while loop advances currentLeg when a leg
--   completes. When currentLeg reaches stopAtWaypoint, legProgress is 0 (just
--   arrived at that waypoint), so the NPC position = waypoints[stopAtWaypoint].
--
-- WORKED EXAMPLE: waypoints = {A, B, C, D, E}, stopAtWaypoint = 3 (waypoint C):
--   NPC walks leg 1 (A→B): currentLeg advances from 1 to 2, legProgress = 0
--   NPC walks leg 2 (B→C): currentLeg advances from 2 to 3, legProgress = 0
--   Loop check: currentLeg (3) >= stopAtWaypoint (3) → break
--   NPC position = waypoints[3] = C ✓
--
-- This is the ONLY change to NPCMover.luau.
```

### NPCAnimator.luau (MODIFIED)

```lua
-- EXISTING: setup() and update() — UNCHANGED.

-- NEW FUNCTIONS:

-- Loads sit animation track onto the given Animator.
-- Uses Config.SitAnimationId. Returns the AnimationTrack.
-- Called once per NPC, only when the NPC's route includes a social POI.
function NPCAnimator.setupSit(animator: Animator): AnimationTrack
-- Implementation:
--   local sitAnim = Instance.new("Animation")
--   sitAnim.AnimationId = Config.SitAnimationId
--   local sitTrack = animator:LoadAnimation(sitAnim)
--   sitTrack.Looped = true
--   sitTrack.Priority = Enum.AnimationPriority.Action
--   return sitTrack

-- Transitions NPC to sitting. Stops walk and idle tracks, plays sit track.
function NPCAnimator.playSit(npc): ()
-- Implementation:
--   if npc.walkTrack.IsPlaying then npc.walkTrack:Stop(0.15) end
--   if npc.idleTrack.IsPlaying then npc.idleTrack:Stop(0.15) end
--   if npc.sitTrack and not npc.sitTrack.IsPlaying then npc.sitTrack:Play(0.15) end

-- Transitions NPC from sitting back to walking. Stops sit track.
function NPCAnimator.stopSit(npc): ()
-- Implementation:
--   if npc.sitTrack and npc.sitTrack.IsPlaying then npc.sitTrack:Stop(0.15) end
```

### NPCClient.client.luau (MODIFIED)

```lua
-- MAJOR CHANGES: The Heartbeat handler becomes a state machine.
-- spawnNPCFromData() gains POI state initialization and sit track setup.
-- Late-join placement accounts for POI dwell times.
--
-- See "Client State Machine" and "Late-Join with POI State" in Data Flow section
-- for exact logic.
--
-- STRUCTURAL CHANGES to spawnNPCFromData():
--   After creating NPCState (existing line 123-135), add:
--     state = "walking",
--     poiStops = data.poiStops,
--     nextPoiStopIdx = 1,
--     dwellEndTime = nil,
--     preSeatCFrame = nil,
--     sitTrack = nil,
--
--   If data.poiStops contains any "social" type:
--     npc.sitTrack = NPCAnimator.setupSit(animator)
--
--   Late-join state calculation must account for POI dwell times
--   (see calculateRouteState algorithm below).
--
--   expectedDespawnTime calculation must include total dwell time:
--     local totalDwellTime = 0
--     for _, poi in ipairs(data.poiStops or {}) do
--       totalDwellTime += poi.dwellTime
--     end
--     expectedDespawnTime = data.startTime + walkTime + totalDwellTime + Config.ClientDespawnBuffer
```

---

## Data Flow for New Behaviors

### NPC Spawn Flow with POIs

Replaces the existing `spawnNPC()` body in PopulationController (lines 201-255).

1. Check `activeCount < MaxPopulation` (unchanged).
2. Pick model via `pickRandomModel()` (unchanged).
3. Calculate walk speed (unchanged).
4. **Pick POIs:** If `poiRegistry` exists and `poiRegistry.pois` is non-empty:
   a. `count = math.random(Config.POICountMin, Config.POICountMax)`
   b. `count = math.min(count, #poiRegistry.pois)`
   c. Pick spawn: `spawnId = RouteBuilder.pickRandomSpawn(graph)`
   d. `selectedPOIs = POIRegistry.selectPOIs(poiRegistry, count, graph.nodes[spawnId].position)`
      (Nearest-neighbor ordering from spawn position for natural routes.)
   e. For each selected Social POI: attempt `POIRegistry.claimSeat(poi, npcId)`.
      If returns nil (capacity full), remove this POI from the selected list.
5. **Build node sequence:** `{spawnId, poi1.waypointNodeId, poi2.waypointNodeId, ..., despawnId}`
   where `despawnId = RouteBuilder.pickRandomDespawn(graph)`.
6. **Compute multi-segment route:**
   `pathNodeIds, poiWaypointIndices = RouteBuilder.computeMultiSegmentRoute(graph, nodeSequence)`
7. **Stuck fallback** if route fails:
   a. Retry with fewer POIs: drop last POI, recompute. Repeat until 0 POIs.
   b. If 0-POI route (direct spawn→despawn) also fails, try other despawn points.
   c. If all despawns unreachable: log `ROUTE_STUCK`, don't spawn this NPC.
   d. Release any seats claimed for this failed attempt.
8. **Convert path to positions:** Map `pathNodeIds` to `graph.nodes[id].position`.
9. **Build poiStops and seatClaims arrays together** (MUST happen before NPCRecord creation):
   ```
   local poiStops = {}
   local seatClaims = {}
   for i, poi in ipairs(selectedPOIs) do
       poiStops[i] = {
           type = poi.poiType,
           waypointIndex = poiWaypointIndices[i],
           dwellTime = randomized dwell or 0 for busy,
           viewTarget = poi.viewTarget (scenic) or nil,
           seatCFrame = claimed seat CFrame (social) or nil,
       }
       -- Track seat claims for release scheduling (social only)
       if poi.poiType == "social" and poiStops[i].seatCFrame then
           table.insert(seatClaims, {
               poiId = poi.id,
               seatIndex = claimedSeatIndex,  -- from step 4e claimSeat result
               releaseTime = 0,  -- calculated in step 12
           })
       end
   end
   ```
   NOTE: Seat claiming (step 4e) happens BEFORE this step. This step collects the
   results into the arrays. `seatClaims` is built here so it's ready for the NPCRecord.
10. **Calculate total duration:**
    ```
    totalWalkDistance = sum of (waypoints[i+1] - waypoints[i]).Magnitude
    totalDwellTime = sum of poiStops[i].dwellTime
    totalDuration = totalWalkDistance / walkSpeed + totalDwellTime
    ```
11. Create `NPCRecord` with `poiStops` and `seatClaims` (both already built in step 9).
12. Schedule **seat releases** via `task.delay`:
    For each social POI seat claim at poiStops index `i`:
    ```
    -- Calculate walk time as sum of leg distances (NOT straight-line):
    arrivalTime = 0
    lastResumeIdx = 1  -- waypoint index where NPC resumes walking after previous stop
    for p = 1, i do
        local poi = poiStops[p]
        -- Sum leg distances from lastResumeIdx to this POI's waypoint
        local walkDist = 0
        for w = lastResumeIdx, poi.waypointIndex - 1 do
            walkDist += (waypoints[w + 1] - waypoints[w]).Magnitude
        end
        arrivalTime += walkDist / walkSpeed
        if p < i then
            arrivalTime += poi.dwellTime  -- add dwell time of previous POIs
        end
        lastResumeIdx = poi.waypointIndex
    end
    releaseTime = arrivalTime + poiStops[i].dwellTime
    task.delay(releaseTime, function()
        POIRegistry.releaseSeat(poi, seatIndex)
    end)
    ```
    Also store claims in `record.seatClaims` for safety release on despawn.
13. Fire `NPCSpawned:FireAllClients(makeSpawnData(record))`.
14. Schedule `task.delay(totalDuration, despawnNPC)`.
15. **Fallback path (no POIs):** If `poiRegistry` is nil or empty, use existing `RouteBuilder.buildRoute(graph, walkSpeed)` exactly as Pass 1. `poiStops` = nil in the payload.

### NPC Despawn Flow (Modified)

Same as Pass 1, with one addition before removing from `activeNPCs`:

1. `task.delay` fires (unchanged).
2. Guard: check `activeNPCs[id]` exists (unchanged).
3. **NEW:** Release remaining seat claims:
   ```
   if record.seatClaims then
       for _, claim in ipairs(record.seatClaims) do
           local poi = POIRegistry.getPOI(poiRegistry, claim.poiId)
           if poi then POIRegistry.releaseSeat(poi, claim.seatIndex) end
       end
   end
   ```
   (Safety net — most seats will already be released by their scheduled `task.delay`. This catches edge cases like early despawn.)
4. Remove from `activeNPCs`, fire `NPCDespawned` (unchanged).

### Client State Machine (Heartbeat Handler)

Replaces the existing Heartbeat handler in NPCClient (lines 174-184).

```
for id, npc in pairs(activeNPCs) do
    -- Timeout check (existing, unchanged)
    if GetServerTimeNow() > npc.expectedDespawnTime then
        force-despawn
        continue
    end

    if npc.state == "walking" then
        -- Determine next stop point
        local stopAt = nil
        if npc.poiStops and npc.nextPoiStopIdx <= #npc.poiStops then
            stopAt = npc.poiStops[npc.nextPoiStopIdx].waypointIndex
        end

        local finished = NPCMover.update(npc, dt, stopAt)

        -- Check if arrived at POI waypoint
        if stopAt and npc.currentLeg >= stopAt then
            local poi = npc.poiStops[npc.nextPoiStopIdx]

            if poi.type == "scenic" then
                npc.state = "dwelling"
                npc.dwellEndTime = GetServerTimeNow() + poi.dwellTime
                -- Face ViewTarget
                if poi.viewTarget and npc.model.PrimaryPart then
                    local pos = npc.model.PrimaryPart.Position
                    local flatTarget = Vector3.new(poi.viewTarget.X, pos.Y, poi.viewTarget.Z)
                    if (flatTarget - pos).Magnitude > 0.01 then
                        npc.model.PrimaryPart.CFrame = CFrame.lookAt(pos, flatTarget)
                    end
                end
                NPCAnimator.update(npc, false)  -- idle animation

            elseif poi.type == "social" then
                npc.state = "sitting"
                npc.dwellEndTime = GetServerTimeNow() + poi.dwellTime
                npc.preSeatCFrame = npc.model.PrimaryPart.CFrame
                if poi.seatCFrame then
                    npc.model.PrimaryPart.CFrame = poi.seatCFrame
                end
                NPCAnimator.playSit(npc)

            elseif poi.type == "busy" then
                -- Walk through — no stop, just advance to next POI
                npc.nextPoiStopIdx += 1
                NPCAnimator.update(npc, true)  -- keep walking
            end

        elseif finished then
            npc.state = "finished"
            NPCAnimator.update(npc, false)  -- idle
        else
            NPCAnimator.update(npc, true)  -- walking
        end

    elseif npc.state == "dwelling" then
        -- Scenic: stay facing ViewTarget, play idle
        if GetServerTimeNow() >= npc.dwellEndTime then
            npc.nextPoiStopIdx += 1
            npc.state = "walking"
            npc.dwellEndTime = nil
        end

    elseif npc.state == "sitting" then
        -- Social: stay seated, play sit animation
        if GetServerTimeNow() >= npc.dwellEndTime then
            -- Return to pre-seat position
            if npc.preSeatCFrame and npc.model.PrimaryPart then
                npc.model.PrimaryPart.CFrame = npc.preSeatCFrame
            end
            NPCAnimator.stopSit(npc)
            npc.nextPoiStopIdx += 1
            npc.state = "walking"
            npc.dwellEndTime = nil
            npc.preSeatCFrame = nil
        end

    elseif npc.state == "finished" then
        -- No-op: idle animation was set on transition to "finished" state.
        -- NPCAnimator.update(npc, false) has IsPlaying guards so extra calls are
        -- harmless, but skipping avoids unnecessary work for every frame until despawn.
    end
end
```

### Late-Join with POI State

When a late-joining client receives NPCSpawnData (via `NPCBulkSync` or `NPCSpawned` with elapsed > 0), it must calculate the NPC's current state, not just position.

**Algorithm (`calculateRouteState`):**

This replaces the existing late-join logic in `spawnNPCFromData()` (lines 78-88).

```
Input: waypoints, walkSpeed, elapsed, poiStops (may be nil)

If poiStops is nil or empty:
    -- Pure walking route (Pass 1 behavior, unchanged)
    position, currentLeg, legProgress = NPCMover.calculatePositionAtTime(waypoints, walkSpeed, elapsed)
    return { state = "walking", position, currentLeg, legProgress, nextPoiStopIdx = 1 }

timeConsumed = 0
lastResumeIndex = 1  -- waypoint index where the NPC resumes walking after a stop

for poiIdx = 1, #poiStops do
    local poi = poiStops[poiIdx]

    -- Calculate walk time from lastResumeIndex to poi.waypointIndex
    local walkDist = 0
    for w = lastResumeIndex, poi.waypointIndex - 1 do
        walkDist += (waypoints[w + 1] - waypoints[w]).Magnitude
    end
    local walkTime = if walkSpeed > 0 then walkDist / walkSpeed else 0

    if elapsed < timeConsumed + walkTime then
        -- NPC is walking toward this POI
        local walkElapsed = elapsed - timeConsumed
        local subWaypoints = slice(waypoints, lastResumeIndex, poi.waypointIndex)
        position, subLeg, subProgress = NPCMover.calculatePositionAtTime(subWaypoints, walkSpeed, walkElapsed)
        currentLeg = lastResumeIndex + subLeg - 1
        legProgress = subProgress
        return { state = "walking", position, currentLeg, legProgress, nextPoiStopIdx = poiIdx }
    end
    timeConsumed += walkTime

    -- Check if NPC is dwelling/sitting at this POI
    if poi.type ~= "busy" and poi.dwellTime > 0 then
        if elapsed < timeConsumed + poi.dwellTime then
            local dwellElapsed = elapsed - timeConsumed
            local dwellRemaining = poi.dwellTime - dwellElapsed
            position = waypoints[poi.waypointIndex]

            if poi.type == "scenic" then
                return {
                    state = "dwelling",
                    position = position,
                    currentLeg = poi.waypointIndex,
                    legProgress = 0,
                    nextPoiStopIdx = poiIdx,
                    dwellEndTime = GetServerTimeNow() + dwellRemaining,
                    viewTarget = poi.viewTarget,
                }
            elseif poi.type == "social" then
                -- NOTE: position is a Vector3. The merge code (see "Merge into NPCState"
                -- above) constructs preSeatCFrame via CFrame.new(position) before seating.
                return {
                    state = "sitting",
                    position = position,  -- Vector3, converted to CFrame during merge
                    currentLeg = poi.waypointIndex,
                    legProgress = 0,
                    nextPoiStopIdx = poiIdx,
                    dwellEndTime = GetServerTimeNow() + dwellRemaining,
                    seatCFrame = poi.seatCFrame,
                }
            end
        end
        timeConsumed += poi.dwellTime
    end

    lastResumeIndex = poi.waypointIndex
end

-- After all POIs: walking toward despawn
local walkDist = 0
for w = lastResumeIndex, #waypoints - 1 do
    walkDist += (waypoints[w + 1] - waypoints[w]).Magnitude
end
local walkTime = if walkSpeed > 0 then walkDist / walkSpeed else 0

if elapsed < timeConsumed + walkTime then
    local walkElapsed = elapsed - timeConsumed
    local subWaypoints = slice(waypoints, lastResumeIndex, #waypoints)
    position, subLeg, subProgress = NPCMover.calculatePositionAtTime(subWaypoints, walkSpeed, walkElapsed)
    currentLeg = lastResumeIndex + subLeg - 1
    legProgress = subProgress
    return { state = "walking", position, currentLeg, legProgress, nextPoiStopIdx = #poiStops + 1 }
end

return { state = "finished", position = waypoints[#waypoints], currentLeg = #waypoints - 1, legProgress = 1.0, nextPoiStopIdx = #poiStops + 1 }
```

**Where this lives:** Implement as a local function `calculateRouteState()` in NPCClient.client.luau. Called from `spawnNPCFromData()` to initialize NPCState fields.

**Merge into NPCState:** The return table is merged into the NPC state during `spawnNPCFromData()`:
```lua
local routeState = calculateRouteState(data.waypoints, data.walkSpeed, elapsed, data.poiStops)
-- Apply returned fields to the NPCState:
npc.state = routeState.state
npc.currentLeg = routeState.currentLeg
npc.legProgress = routeState.legProgress
npc.nextPoiStopIdx = routeState.nextPoiStopIdx
if routeState.dwellEndTime then npc.dwellEndTime = routeState.dwellEndTime end
if routeState.state == "sitting" and routeState.seatCFrame then
    npc.preSeatCFrame = CFrame.new(routeState.position)  -- CFrame from Vector3 (see Fix #8)
    npc.model.PrimaryPart.CFrame = routeState.seatCFrame
    NPCAnimator.playSit(npc)
elseif routeState.state == "dwelling" and routeState.viewTarget then
    local pos = routeState.position
    local flatTarget = Vector3.new(routeState.viewTarget.X, pos.Y, routeState.viewTarget.Z)
    if (flatTarget - pos).Magnitude > 0.01 then
        npc.model.PrimaryPart.CFrame = CFrame.lookAt(pos, flatTarget)
    end
    NPCAnimator.update(npc, false)  -- idle
else
    -- walking or finished: set model position via calculatePositionAtTime (already handled)
    NPCAnimator.update(npc, routeState.state == "walking")
end
```

### Social Seat Claiming (Server-Side Detail)

Inside `POIRegistry.claimSeat(poi, npcId)`:

```
1. Check capacity: if poi.occupiedCount >= math.floor(poi.totalSeats * poi.capacityPercent) then
       return nil  -- capacity full
   end

2. Roll social preference: local preferOccupied = math.random() < poi.socialWeight

3. If preferOccupied:
       -- Find groups with at least 1 occupied seat AND at least 1 empty seat
       local socialGroups = filter(poi.groups, function(g)
           return g.occupiedCount > 0 and g.occupiedCount < #g.seatIndices
       end)
       if #socialGroups > 0 then
           -- Pick a random social group, then a random empty seat in it
           local group = socialGroups[math.random(1, #socialGroups)]
           local emptySeatIndices = filter(group.seatIndices, function(si)
               return poi.seats[si].occupiedBy == nil
           end)
           local seatIdx = emptySeatIndices[math.random(1, #emptySeatIndices)]
           poi.seats[seatIdx].occupiedBy = npcId
           group.occupiedCount += 1
           poi.occupiedCount += 1
           return seatIdx, poi.seats[seatIdx].cframe
       end
       -- Fall through to any-seat logic if no suitable social group

4. Pick any empty seat:
       local emptySeats = filter indices where poi.seats[i].occupiedBy == nil
       if #emptySeats == 0 then return nil end
       local seatIdx = emptySeats[math.random(1, #emptySeats)]
       local group = find group containing seatIdx
       poi.seats[seatIdx].occupiedBy = npcId
       group.occupiedCount += 1
       poi.occupiedCount += 1
       return seatIdx, poi.seats[seatIdx].cframe
```

### Stuck NPC Fallback (Server-Side Detail)

When `RouteBuilder.computeMultiSegmentRoute()` returns nil:

```
1. Remove the last POI from the selection, retry route.
2. Repeat until no POIs remain.
3. With 0 POIs, try direct spawn → despawn via existing RouteBuilder.buildRoute().
4. If that also fails, try each despawn point individually:
       for _, despawnId in ipairs(graph.despawns) do
           local path = RouteBuilder.computeRoute(graph, spawnId, despawnId)
           if path then use this route; break end
       end
5. If all fail: log ROUTE_STUCK, release any claimed seats, don't spawn.
```

---

## Integration Pass (against real code)

### Data Lifecycle Traces

**poiStops (POI stop data per NPC)**
- **Created by:** `PopulationController.spawnNPC()` → builds from selected POIs + randomized dwell times + claimed seat CFrames
- **Passed via:** `NPCSpawned` RemoteEvent as field in NPCSpawnData table (FireAllClients), and `NPCBulkSync` (FireClient)
- **Received by:** `NPCClient.spawnNPCFromData()` → reads `data.poiStops`, stores in NPCState
- **Stored in:** Server: `activeNPCs[id].poiStops`. Client: `activeNPCs[id].poiStops`
- **Cleaned up by:** Server: removed with NPCRecord on despawn. Client: removed with NPCState on despawn/force-despawn.
- **Verified:** Types match. Field is optional (`{POIStopData}?`), nil-safe in both server makeSpawnData and client state machine.

**Seat occupancy state**
- **Created by:** `POIRegistry.discover()` initializes all seats as unoccupied. `POIRegistry.claimSeat()` marks a seat as occupied.
- **Passed via:** Direct mutation of POIInfo tables in the registry (server-local, no network).
- **Received by:** `POIRegistry.claimSeat()` reads occupancy to decide availability. `POIRegistry.releaseSeat()` clears occupancy.
- **Stored in:** `POIRegistry` internal state within `POIInfo.seats[i].occupiedBy` and `POIInfo.occupiedCount`. Lifetime = server session.
- **Cleaned up by:** `POIRegistry.releaseSeat()` called via (a) scheduled `task.delay` at dwell end, or (b) `despawnNPC()` safety net. Both paths verified.
- **Verified:** Double-release safe — `releaseSeat()` checks `seat.occupiedBy ~= nil` before decrementing. Claim and release operations are atomic (single-threaded Luau).

**Graph.partToId**
- **Created by:** `WaypointGraph.build()` — existing local variable `partToId` (line 27 of real code), now included in returned Graph table.
- **Passed via:** Graph table, passed to `POIRegistry.discover(poisFolder, graph)`.
- **Received by:** `POIRegistry.discover()` uses `graph.partToId[waypointObjValue.Value]` to resolve Part references to node IDs.
- **Stored in:** Graph table, lifetime = server session. Read-only after build.
- **Cleaned up by:** Never — static data, same as Graph.
- **Verified:** `partToId` is a `{[Instance]: string}` map. POIRegistry lookups handle nil (invalid ObjectValue target) with warnings.

### API Composition Checks (new calls against real code)

| Caller | Callee | Args Match | Return Handled | Verified Against |
|--------|--------|-----------|----------------|-----------------|
| PopulationController | POIRegistry.discover(poisFolder, graph) | Folder + Graph (with partToId) | Registry? — nil means no POIs, non-fatal | New module, types verified |
| PopulationController | POIRegistry.selectPOIs(registry, count, spawnPos) | Registry + number + Vector3 | {POIInfo} array | New module |
| PopulationController | POIRegistry.claimSeat(poi, npcId) | POIInfo + string | (number?, CFrame?) — nil = capacity full, handled | New module |
| PopulationController | POIRegistry.releaseSeat(poi, seatIndex) | POIInfo + number | void | New module |
| PopulationController | RouteBuilder.computeMultiSegmentRoute(graph, nodeSeq) | Graph + {string} | ({string}?, {number}?) — nil handled by stuck fallback | New function in existing module |
| NPCClient Heartbeat | NPCMover.update(npc, dt, stopAt) | NPCState + number + number? | boolean (unchanged return type) | Real code line 84, optional param added |
| NPCClient | NPCAnimator.setupSit(animator) | Animator instance | AnimationTrack | New function in existing module |
| NPCClient | NPCAnimator.playSit(npc) | NPCState (has sitTrack field) | void | New function, checks sitTrack ~= nil |
| NPCClient | NPCAnimator.stopSit(npc) | NPCState | void | New function, checks sitTrack ~= nil |
| NPCClient | NPCMover.calculatePositionAtTime(subWaypoints, speed, elapsed) | {Vector3}, number, number | Vector3, number, number | Real code line 144, unchanged |

---

## Diagnostics Updates

### New Reason Codes
All gated behind `Config.DiagnosticsEnabled`.

- `POI_REGISTRY_BUILT` — Startup. Includes: scenic count, busy count, social count, total seats.
- `POI_ROUTE` — NPC spawned with POI route. Includes: npcId, POI count, POI types list.
- `POI_SKIP` — POI skipped during route planning. Includes: npcId, poiId, reason (capacity_full / no_path).
- `SEAT_CLAIM` — Seat claimed. Includes: poiId, seatIndex, npcId, occupiedCount/totalSeats.
- `SEAT_RELEASE` — Seat released. Includes: poiId, seatIndex, occupiedCount/totalSeats.
- `ROUTE_STUCK` — All route attempts failed. Includes: npcId, spawnId.

### New Health Counters
Added to PopulationController module-level variables:
- `poiRoutesTotal` — lifetime routes planned with POIs
- `poiSkips` — lifetime POI skips
- `seatsOccupiedNow` — current total occupied seats (increment on claim, decrement on release)
- `routeStuckTotal` — lifetime stuck fallback failures

### Diagnostics Format
```
[WanderingProps] POI_REGISTRY_BUILT scenic=3 busy=2 social=2 seats=12
[WanderingProps] POI_ROUTE npc_42 pois=3 types=scenic,busy,social
[WanderingProps] POI_SKIP npc_43 poi=CafeTables reason=capacity_full
[WanderingProps] SEAT_CLAIM poi=CafeTables seat=3 npc=npc_42 occupied=5/12
[WanderingProps] SEAT_RELEASE poi=CafeTables seat=3 occupied=4/12
[WanderingProps] ROUTE_STUCK npc_44 spawn=SpawnAlley
```

---

## Startup Validator Updates

Added to PopulationController `startup()`, run immediately after `POIRegistry.discover()` returns.

```lua
-- Insert after: poiRegistry = POIRegistry.discover(poisFolder, graph)
if poiRegistry then
    -- Check SitAnimationId if any social POIs exist
    local hasSocial = false
    for _, poi in ipairs(poiRegistry.pois) do
        if poi.poiType == "social" then hasSocial = true; break end
    end
    if hasSocial and (Config.SitAnimationId == nil or Config.SitAnimationId == "") then
        error("[WanderingProps] FATAL: Social POIs found but SitAnimationId not set in Config.")
    end
    -- Validate POI config ranges
    if Config.POICountMin > Config.POICountMax then
        error("[WanderingProps] FATAL: POICountMin must be ≤ POICountMax.")
    end
end
```

| Contract | Check | Severity | Error Message |
|----------|-------|----------|---------------|
| POIs folder exists | `wanderingFolder:FindFirstChild("POIs")` | WARNING | `[WanderingProps] WARNING: No POIs folder found. NPCs will walk random routes.` |
| Each POI has valid type | `POIType` attribute is "scenic", "busy", or "social" | WARNING | `[WanderingProps] WARNING: POI "{name}" has invalid or missing POIType. Skipped.` |
| Each POI has Waypoint link | ObjectValue named "Waypoint" with Value in Waypoints folder | WARNING | `[WanderingProps] WARNING: POI "{name}" has no valid Waypoint link. Skipped.` |
| Scenic has ViewZone | Child BasePart named "ViewZone" | WARNING | `[WanderingProps] WARNING: Scenic POI "{name}" has no ViewZone child. Will face arrival direction.` |
| Social has seats | At least 1 group folder with at least 1 BasePart child | WARNING | `[WanderingProps] WARNING: Social POI "{name}" has no valid seats. Skipped.` |
| SitAnimationId set (if social POIs exist) | `Config.SitAnimationId ~= ""` | BLOCKING | `[WanderingProps] FATAL: Social POIs found but SitAnimationId not set in Config.` |
| POICountMin ≤ POICountMax | `Config.POICountMin <= Config.POICountMax` | BLOCKING | `[WanderingProps] FATAL: POICountMin must be ≤ POICountMax.` |
| DwellMin ≤ DwellMax (per POI) | Per-instance or config defaults | WARNING | `[WanderingProps] WARNING: POI "{name}" DwellMin > DwellMax. Using DwellMin for both.` |

---

## Golden Tests for This Pass

### Test 1: Scenic POI Visit
- **Setup:** Waypoint graph with spawn, 3 waypoints, despawn. One Scenic POI linked to the middle waypoint, with a ViewZone part offset 20 studs to the right. Config: MaxPopulation = 3, ScenicDwellMin = 5, ScenicDwellMax = 5 (fixed), DiagnosticsEnabled = true.
- **Action:** Start server. Wait for an NPC to reach the Scenic POI waypoint.
- **Expected:** NPC stops walking, turns to face the ViewZone position, plays idle animation for 5 seconds, then resumes walking toward despawn.
- **Pass condition:** Visual: NPC clearly stops and faces the ViewZone direction, then resumes. Diagnostics: POI_ROUTE shows scenic POI selected. No errors in output.

### Test 2: Social POI Sit
- **Setup:** Waypoint graph with spawn, waypoints, despawn. One Social POI linked to a waypoint, with 2 groups of 2 seats each (4 total). Config: MaxPopulation = 5, SocialDwellMin = 8, SocialDwellMax = 8, CapacityPercent = 0.75 (3 of 4 seats max). SitAnimationId set. DiagnosticsEnabled = true.
- **Action:** Start server. Wait for NPCs to reach the Social POI.
- **Expected:** First 3 NPCs claim seats, play sit animation, sit for 8 seconds, then leave. 4th NPC skips the POI (capacity cap = 3). NPCs with social weighting should prefer sitting at groups with existing sitters.
- **Pass condition:** Visual: NPCs teleport to seat positions and play sit animation. After dwell, they return to the waypoint and continue walking. Diagnostics: SEAT_CLAIM events for first 3, POI_SKIP for 4th. Seat counts correct.

### Test 3: Busy POI Walk-Through
- **Setup:** Waypoint graph with spawn, waypoints, despawn. One Busy POI linked to a waypoint. Config: MaxPopulation = 5.
- **Action:** Start server. Observe NPCs passing through the Busy POI waypoint.
- **Expected:** NPCs walk through the Busy POI waypoint without stopping. No dwell, no animation change.
- **Pass condition:** Visual: NPCs don't pause at the Busy POI waypoint. Diagnostics: POI_ROUTE includes busy type.

### Test 4: Stuck NPC Fallback
- **Setup:** Waypoint graph where one POI's linked waypoint is on a disconnected island (no path from spawn). Other POIs are reachable. Config: MaxPopulation = 3, DiagnosticsEnabled = true.
- **Action:** Start server. Wait for NPCs to be assigned routes.
- **Expected:** When the unreachable POI is selected, the system drops it from the route and continues with remaining POIs. If no POIs reachable, falls back to direct spawn→despawn route.
- **Pass condition:** Diagnostics: POI_SKIP with reason=no_path for the unreachable POI. NPCs still spawn and complete routes. No ROUTE_STUCK (since direct route should work). No errors.

### Test 5: Late-Join with POI State
- **Setup:** Same as Test 1 (Scenic POI with 5s dwell). Config: MaxPopulation = 5.
- **Action:** Start server. Wait 10s for NPCs to be mid-route (some dwelling). Join with a second client.
- **Expected:** Late-joining client sees NPCs at correct positions: walking NPCs mid-route, dwelling NPCs at the Scenic POI facing ViewZone, finished NPCs near despawn.
- **Pass condition:** Visual: NPC at Scenic POI on second client is facing ViewZone and playing idle (not walking). Diagnostics: BULK_SYNC fires. No NPCs at wrong positions.

### Regression Tests
Re-run from Pass 1:
- **Test 1: Basic Spawn-Walk-Despawn Cycle** — Verify NPCs without POIs (empty POIs folder or 0 POIs selected) still walk and despawn correctly.
- **Test 2: Late-Join Sync** — Verify late-join still works for walking-only NPCs.
- **Test 3: Walk Speed Variation and Ground Snap** — Verify ground snapping and speed variation unaffected.

---

## Critic Review Notes

**Review 1:** 10 blocking issues, 5 flagged items. All blocking issues resolved in rev 2:

1. **NPCRecord modelTemplate** — Already documented at type definition (line 158 rev 1). No change.
2. **makeSpawnData nil-safety** — Added note clarifying record.poiStops may be nil and ordering guarantee (set in step 9, used in step 13).
3. **stopAtWaypoint off-by-one** — Added invariant documentation and worked example proving currentLeg/legProgress semantics are correct.
4. **Seat release timing** — Replaced ambiguous "distance from route start" with explicit segment-by-segment walk distance loop matching calculateRouteState logic.
5. **SitAnimationId validation location** — Added explicit pseudocode block showing where in startup() the check runs (after POIRegistry.discover()).
6. **Heartbeat finished-state waste** — Changed "finished" branch to no-op (idle already set on transition). NPCAnimator.update IsPlaying guards make extra calls harmless but unnecessary.
7. **calculateRouteState return type** — Added full merge pseudocode showing how returned table fields are applied to NPCState, including animation and CFrame setup per state.
8. **preSeatCFrame Vector3→CFrame** — Late-join sitting state returns Vector3 position; merge code constructs CFrame via CFrame.new(position) before assigning to preSeatCFrame.
9. **WaypointGraph.build() line reference** — Made explicit: "line 95 of WaypointGraph.luau", named the file and variable.
10. **seatClaims race condition** — Restructured step 9 to build both poiStops and seatClaims arrays together, before NPCRecord creation in step 11.

**Flagged items (non-blocking, noted):**
- POI selection nearest-neighbor O(n²) — acceptable for <20 POIs per registry.
- calculateRouteState complexity — added merge pseudocode for clarity.
- releaseSeat idempotency — added explicit guard documentation to API definition.
- ViewZone Y-level — buyer guidance in workspace contracts (ViewZone is a BasePart marker).
- Fail-open POI validation — accepted design approach, invalid POIs skipped with warnings.
