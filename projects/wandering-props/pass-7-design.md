# Pass 7 Design: Market POI Type

## Context

Pass 6 added internal POI navigation (internal waypoint graphs, Dijkstra pathfinding, stand points, multi-entrance support). Pass 7 introduces a new `"market"` POI type where NPCs enter a marketplace, visit a random number of stands (browsing with head scanning), then leave.

**Key architectural challenge:** Market is the first POI type that produces **multiple dwell stops** from a single selected POI. One `"market"` entry in `selectedPOIs` expands into N scenic-like entries in `builtPoiStops`.

**User design decisions:**
1. Dwell time per stand: configurable range (`MarketBrowseDwellMin` / `MarketBrowseDwellMax`)
2. Stand visit order: random
3. Capacity overflow: only visit available stands; skip market entirely if none available
4. Repeat visits: allowed (each consumes a capacity slot)
5. Head scan style: slow sinusoidal sweep across ViewTarget bounds

---

## Scope

### In scope (Pass 7)
1. **New POI type: `"market"`** — NPCs enter, visit random stands, browse with head scanning, leave
2. **Stand capacity** — per-stand max occupancy with claim/release lifecycle
3. **Head scanning** — sinusoidal neck yaw sweep during market dwell
4. **Server-side waypoint expansion** — multi-stand visits baked into flat waypoints array

### Out of scope
- Object avoidance within POIs
- Market-specific animations (lean, pick up objects)

---

## Authoring Contract (Roblox Studio)

```
MarketPOI_Bazaar/                   (Folder, POIType="market")
├── InternalWaypoints/              (required — uses Pass 6 internal graph)
│   ├── IW_Entry (BasePart)         (ObjectValue → external graph node)
│   ├── IW_Aisle1 (BasePart)        (ObjectValue → IW_Entry)
│   └── IW_Aisle2 (BasePart)        (ObjectValue → IW_Aisle1)
├── Stands/                         (required — folder of stand subfolders)
│   ├── Stand1/
│   │   ├── StandZone (BasePart, zone-sized for random XZ)
│   │   └── ViewTarget (BasePart, what NPC faces/scans)
│   └── Stand2/
│       ├── StandZone (BasePart)
│       └── ViewTarget (BasePart)
```

- No main `Waypoint` part — uses Pass 6 generalized discovery via internal entry nodes
- `InternalWaypoints` required (markets require internal navigation; skip market if missing)
- Each stand subfolder must contain `StandZone` (BasePart, zone-sized) + `ViewTarget` (BasePart)
- Stands auto-link to closest internal waypoint by distance (no AccessPoint needed)
- `InternalNavigationEnabled = false` → markets are skipped entirely

### Golden test fixture naming
- Market POI folder: `MarketPOI_*` with `POIType = "market"` attribute
- Internal waypoints: `IW_*` BaseParts inside `InternalWaypoints/` folder
- Stand subfolders: any name, each containing `StandZone` and `ViewTarget` children
- Allowed alternate: `ViewTarget` can be named `ViewZone` (consistent with scenic POIs)

---

## Architecture

### Server-side waypoint expansion (multi-stand)

The server inserts stand visit waypoints into the flat `waypoints` array. Each stand visit adds:
1. Internal path from current position (entry or previous stand's access node) → this stand's access node
2. Stand dwell position (random XZ within StandZone footprint)

After all stands: exit path from last stand's access node back to entry.

```
Before: [..., MARKET_ENTRY, ...]
After:  [..., MARKET_ENTRY, IW→stand1_access, stand1_pos, stand1_access→IW→stand2_access, stand2_pos, IW→exit, ...]
```

Each `stand_pos` gets a `"market"` POI stop in `builtPoiStops` with `viewTarget`, `scanTarget`, and `scanExtent`. The client processes these as scenic-like dwells with head scanning added.

### Stand-to-stand pathfinding

Live Dijkstra at spawn time (not cached). Combinatorial stand orderings make caching impractical. Internal graphs are small (<10 nodes) — negligible cost.

The expansion function tracks `currentAccessNodeId` (starting at entry) and for each stand computes `POIRegistry.computeInternalPath(graph, currentAccessNodeId, stand.accessNodeId)`.

### Stand capacity tracking

Each stand has `capacity` (default `Config.MarketStandCapacity`) and `occupiedCount`. Claims at spawn time; releases via `task.delay` (same pattern as social seat claims in PopulationController lines 1527-1538).

---

## File Changes

### 1. `src/shared/Types.luau` (MINOR)

**Add types:**
```lua
export type MarketStand = {
    standZonePosition: Vector3,
    standZoneSize: Vector3,
    standZoneCFrame: CFrame,
    viewTargetPosition: Vector3,
    viewTargetSize: Vector3,
    accessNodeId: string?,
    occupiedCount: number,
    capacity: number,
}

export type MarketStandClaim = {
    poiId: string,
    standIndex: number,
    npcId: string,
    releaseTime: number,
}
```

**Extend `POIStopData`:**
```lua
export type POIStopData = {
    type: "scenic" | "busy" | "social" | "market",  -- add "market"
    waypointIndex: number,
    dwellTime: number,
    viewTarget: Vector3?,
    seatCFrame: CFrame?,
    scanTarget: Vector3?,     -- NEW: center of ViewTarget part
    scanExtent: number?,      -- NEW: half-width of ViewTarget for scan sweep range
}
```

**Add to `NPCState` (after `headLookNextCheckTime`):**
```lua
    scanActive: boolean,
    scanTarget: Vector3?,
    scanExtent: number?,
    scanTime: number,
```

### 2. `src/shared/Config.luau` (MINOR)

**Add market section:**
```lua
-- MARKET POI
Config.MarketStandsMin = 2
Config.MarketStandsMax = 4
Config.MarketStandCapacity = 3
Config.MarketBrowseDwellMin = 4
Config.MarketBrowseDwellMax = 10
Config.MarketWeight = 0.8
Config.MarketHeadScanSpeed = 0.4
```

### 3. `src/server/POIRegistry.luau` (MAJOR)

**New function: `discoverMarketStands(poiFolder: Folder): { MarketStand }?`**
- Looks for `Stands` folder inside POI folder
- For each subfolder: find `StandZone` (BasePart) and `ViewTarget` (BasePart)
- Creates `MarketStand` entry with `occupiedCount = 0`, `capacity = Config.MarketStandCapacity`
- Hides markers, sets CanCollide=false, Anchored=true (same as `discoverStandPoints` line 464-492)
- Returns array or nil if no valid stands found

**New function: `POIRegistry.claimMarketStand(poi, standIndex: number, npcId: string): boolean`**
- Guard: `poi.poiType ~= "market"` or no stands → return false
- Check `stand.occupiedCount < stand.capacity` → return false if full
- Increment `occupiedCount`, return true
- Pattern: follows `claimSeat()` (line 964-1023) but simpler — no groups, no social weighting

**New function: `POIRegistry.releaseMarketStand(poi, standIndex: number)`**
- Decrement `stand.occupiedCount` (guard: > 0)
- Pattern: follows `releaseSeat()` (line 1025-1051)

**Modified: `discover()` (line 610)**
- Accept `"market"` as valid POI type:
  ```lua
  if poiType ~= "scenic" and poiType ~= "busy" and poiType ~= "social" and poiType ~= "market" then
  ```
- Add `elseif poiType == "market"` branch after social (line 735):
  - Require `InternalNavigationEnabled` — warn and skip if disabled
  - Require `precomputedInternalGraph` — warn and skip if no InternalWaypoints folder
  - Call `discoverMarketStands(child)` — warn and skip if no stands
  - Set `poi.dwellMin = Config.MarketBrowseDwellMin`, `poi.dwellMax = Config.MarketBrowseDwellMax`
  - Set `poi.weight` from attribute or `Config.MarketWeight`
  - Store `poi.stands`, `poi.totalStands = #stands`
  - Auto-link each stand to closest internal node: `stand.accessNodeId = findClosestInternalNode(stand.standZonePosition, internalGraph)`
  - Collect unique stand access node IDs, call `buildCachedInternalPaths(poi, standAccessNodeIds)`
  - Set `poi.internalGraph`, `poi.entranceNodeIds` (same entrance pattern as scenic/social)

### 4. `src/server/PopulationController.server.luau` (MODERATE)

**New function: `releaseMarketStandClaim(poiId: string, standIndex: number, expectedNpcId: string?)`**
- Pattern: follows `releaseSeatClaim()` (line 398-431)
- Looks up POI via `POIRegistry.getPOI()`, calls `POIRegistry.releaseMarketStand(poi, standIndex)`

**New function: `expandMarketInternalWaypoints(waypoints, poiWaypointIndex, poi, selectedStandIndices, chosenEntranceNodeId): ({ Vector3 }, { number }, number)`**
- Returns: (new waypoints array, array of per-stand waypoint indices, total inserted count)
- Logic:
  1. Copy waypoints up to and including POI waypoint
  2. Determine entry node (filter by `chosenEntranceNodeId` if multi-entrance, same as `expandSocialInternalWaypoints` lines 822-833)
  3. For each stand index in `selectedStandIndices` (in order):
     - Compute internal path from `currentAccessNodeId` to `stand.accessNodeId` via `POIRegistry.computeInternalPath()` (live, not cached — stand ordering is random)
     - Append path waypoints (skip first if same as current position)
     - Compute random XZ within StandZone footprint → stand dwell position
     - Append stand dwell position → record this index as the stand's waypoint index
     - Update `currentAccessNodeId = stand.accessNodeId`
  4. Compute exit path: `currentAccessNodeId` back to entry node (reverse of approach)
  5. Append exit waypoints + POI waypoint position (return through market entry)
  6. Copy remaining waypoints after original POI waypoint
  7. Return new array, stand waypoint indices, total inserted count

**Modified: POI filtering loop (line 1104-1133)**
- Add `elseif poi.poiType == "market"` branch:
  - Determine stand count: `math.random(Config.MarketStandsMin, Config.MarketStandsMax)`
  - Clamp to `math.min(count, #poi.stands)`
  - Build available stands list: only those where `stand.occupiedCount < stand.capacity`
  - If no available stands → skip market (diagnostics: `POI_SKIP reason=no_available_stands`)
  - If available < requested count → clamp to available
  - Randomly select `count` stands from available list (shuffle and take first N)
  - Claim each selected stand: `POIRegistry.claimMarketStand(poi, standIndex, id)`
  - Store: `marketStandsByPoiId[poi.id] = { standIndices = selectedStandIndices }`
  - `table.insert(filteredPOIs, poi)`

**Modified: Internal navigation expansion (line 1311-1361)**
- Add `elseif poi.poiType == "market"` branch:
  - Get `marketStands = marketStandsByPoiId[poi.id]`
  - Call `expandMarketInternalWaypoints(waypoints, poiWaypointIndices[i], poi, marketStands.standIndices, chosenEntrance)`
  - Update `waypoints`, `poiWaypointIndices[i]`, shift subsequent indices
  - Store `marketStands.standWaypointIndices = standWaypointIndices` (for builtPoiStops)

**Modified: builtPoiStops construction (line 1365-1394)**
- Add `elseif poi.poiType == "market"` branch (before the default stop construction):
  - For each stand in `marketStandsByPoiId[poi.id].standIndices`:
    - Create `"market"` POI stop entry:
      ```lua
      {
          type = "market",
          waypointIndex = standWaypointIndices[standIdx],
          dwellTime = rng:NextNumber(Config.MarketBrowseDwellMin, Config.MarketBrowseDwellMax),
          viewTarget = stand.viewTargetPosition,
          scanTarget = stand.viewTargetPosition,
          scanExtent = stand.viewTargetSize.X / 2,
      }
      ```
  - These N entries replace the single market POI entry in `builtPoiStops`
  - **Index shift:** After inserting N stops where 1 was expected, increment `poiWaypointIndices` for subsequent POIs by `(N - 1)`
  - Build `builtMarketStandClaims` array (parallel to `builtSeatClaims`):
    ```lua
    { poiId = poi.id, standIndex = standIdx, npcId = id, releaseTime = estimatedReleaseTime }
    ```

**Modified: `despawnNPC()` (line 442-446)**
- Add market claim release:
  ```lua
  if record.marketStandClaims then
      for _, claim in ipairs(record.marketStandClaims) do
          releaseMarketStandClaim(claim.poiId, claim.standIndex, claim.npcId)
      end
  end
  ```

**Modified: `trimRouteForNightDrain()` (line 725-730)**
- Add market claim release alongside seat claim release (same pattern)

**Modified: record construction and claim scheduling (line 1520-1538)**
- Add `marketStandClaims` field to `NPCRecord`
- Schedule timed releases via `task.delay` (same pattern as seat claims):
  ```lua
  if record.marketStandClaims then
      for _, claim in ipairs(record.marketStandClaims) do
          task.delay(claim.releaseTime, function()
              local current = activeNPCs[record.id]
              if not current or current.routeVersion ~= scheduledRouteVersion then return end
              releaseMarketStandClaim(claim.poiId, claim.standIndex, claim.npcId)
          end)
      end
  end
  ```

**NPCRecord extension:**
- Add `marketStandClaims: { MarketStandClaim }?` (parallel to `seatClaims`)

### 5. `src/client/HeadLookController.luau` (MODERATE)

**New function: `HeadLookController.startScan(npc, scanTarget: Vector3, scanExtent: number)`**
```
npc.scanActive = true
npc.scanTarget = scanTarget
npc.scanExtent = scanExtent
npc.scanTime = 0
```

**New function: `HeadLookController.stopScan(npc)`**
```
npc.scanActive = false
npc.scanTarget = nil
npc.scanExtent = nil
npc.scanTime = 0
```

**New function: `HeadLookController.applyScan(npc, dt: number)`**
- Guard: `npc.scanActive` must be true, neck motor + originalC0 must exist
- Guard: if `npc.headLookActive` or `(npc.headLookAlpha or 0) > 0.01` → return (player look takes priority)
- `npc.scanTime += dt`
- Compute scan yaw:
  - `distToTarget = (npc.scanTarget - headPos).Magnitude` (headPos from rootPart or Neck Part1)
  - `scanYawRange = math.atan2(npc.scanExtent, math.max(1, distToTarget))`
  - `scanYawRange = math.min(scanYawRange, math.rad(Config.HeadLookMaxYaw))`
  - `yaw = math.sin(npc.scanTime * Config.MarketHeadScanSpeed * 2 * math.pi) * scanYawRange`
- Apply: `neckMotor.C0 = originalC0 * CFrame.Angles(0, -yaw, 0)`
- Cost: one `sin` + one `atan2` + one CFrame per frame — minimal

**Modified: `init(npc, ...)` (line 9-27)**
- Add scan field initialization:
  ```
  npc.scanActive = false
  npc.scanTime = 0
  ```

**Modified: `reset(npc)` (line 125-133)**
- Add scan field cleanup:
  ```
  npc.scanActive = false
  npc.scanTarget = nil
  npc.scanExtent = nil
  npc.scanTime = 0
  ```

### 6. `src/client/NPCClient.client.luau` (MINOR)

**Modified: scenic/market dwell entry (line 1128-1141)**
- After entering `"dwelling"` state, check if `poi.scanTarget ~= nil`:
  ```lua
  if poi.scanTarget then
      HeadLookController.startScan(npc, poi.scanTarget, poi.scanExtent or 2)
  end
  ```
- Market stops use `type = "market"` but enter the same `"dwelling"` state as scenic. The dwell entry branch at line 1128 checks `poi.type ~= "busy"`, so `"market"` stops will enter this branch naturally. **Verify:** the check is `poi.type == "scenic"` — if so, change to `poi.type == "scenic" or poi.type == "market"`, or more robustly: `poi.type ~= "busy" and poi.type ~= "social"`.

**Modified: dwelling state update (line 1184-1208)**
- Add scan update during dwell (after facing target rotation, before dwell-end check):
  ```lua
  if npc.scanActive then
      HeadLookController.applyScan(npc, dt)
  end
  ```

**Modified: dwell exit (line 1199-1207)**
- When dwell ends, stop scan:
  ```lua
  if npc.scanActive then
      HeadLookController.stopScan(npc)
  end
  ```

**Modified: NPC state initialization (line 780-785)**
- Add scan fields to initial state:
  ```lua
  scanActive = false,
  scanTime = 0,
  ```

---

## Integration Pass

### Cross-boundary data flow traces

| Data | Created in | Passed via | Received by | Stored in | Cleaned up |
|---|---|---|---|---|---|
| `MarketStand` | `POIRegistry.discover()` | `poi.stands` array | `PopulationController` filtering | `poi.stands` on registry | Registry lifetime |
| `MarketStandClaim` | `PopulationController` filtering | `marketStandsByPoiId` local | `PopulationController` record | `record.marketStandClaims` | `despawnNPC()`, `trimRouteForNightDrain()`, `task.delay` |
| Stand capacity (`occupiedCount`) | `POIRegistry.discover()` | `poi.stands[i].occupiedCount` | `claimMarketStand`/`releaseMarketStand` | Mutated in-place on stand | `releaseMarketStand()` decrements |
| `scanTarget`/`scanExtent` | `PopulationController` builtPoiStops | NPCSpawnData remote payload (in `poiStops`) | `NPCClient` dwell entry | `npc.scanTarget`, `npc.scanExtent` on NPCState | `stopScan()` on dwell exit, `HeadLookController.reset()` on NPC removal |
| Stand waypoint indices | `expandMarketInternalWaypoints()` return | Local in `spawnNPC()` | builtPoiStops construction | `builtPoiStops[].waypointIndex` | Sent once, no cleanup needed |

### API signature checks against real code

| Call | Real signature | Match? |
|---|---|---|
| `POIRegistry.getPOI(registry, poiId)` | `(registry, poiId: string) → poi?` (line 1053) | Yes |
| `POIRegistry.computeInternalPath(graph, from, to)` | `(internalGraph, fromNodeId: string, toNodeId: string) → {Vector3}?` (line 388) | Yes |
| `POIRegistry.getCachedInternalPath(poi, entry, access)` | `(poi, entryNodeId: string, accessNodeId: string) → {Vector3}? \| false` (line 456) | Yes |
| `findClosestInternalNode(pos, graph)` | `(position: Vector3, internalGraph) → string?` (line 547) | Yes |
| `buildCachedInternalPaths(poi, accessNodeIds)` | `(poi, accessNodeIds: {string}?)` (line 564) | Yes |
| `HeadLookController.init(npc, neck, c0)` | `(npc, neckMotor: Motor6D?, neckOriginalC0: CFrame?)` (line 9) | Yes — add scan init here |
| `HeadLookController.reset(npc)` | `(npc)` (line 125) | Yes — add scan cleanup here |

---

## AI Build Prints (`[P7_TEST]`)

### Tags and data

| Tag | When | Data |
|---|---|---|
| `[P7_TEST] MARKET_DISCOVER` | `discover()` accepts a market POI | `poi=<id> stands=<count> entries=<count>` |
| `[P7_TEST] MARKET_STAND_CLAIM` | Stand claimed during filtering | `poi=<id> stand=<index> npc=<id> occupied=<n>/<capacity>` |
| `[P7_TEST] MARKET_STAND_SKIP` | Stand skipped (full) | `poi=<id> stand=<index> reason=capacity_full` |
| `[P7_TEST] MARKET_POI_SKIP` | Entire market skipped | `poi=<id> reason=no_available_stands` |
| `[P7_TEST] MARKET_EXPAND` | Market waypoints expanded | `npc=<id> poi=<id> stands_visited=<n> inserted=<count>` |
| `[P7_TEST] MARKET_STOP` | builtPoiStops entry created | `npc=<id> stand=<index> waypointIndex=<n> dwellTime=<t> scanExtent=<e>` |
| `[P7_TEST] MARKET_CLAIM_RELEASE` | Stand claim released | `poi=<id> stand=<index> npc=<id> reason=<timer\|despawn\|drain>` |
| `[P7_TEST] SCAN_START` | Client starts head scan | `npc=<id> scanTarget=<pos> scanExtent=<e>` |
| `[P7_TEST] SCAN_STOP` | Client stops head scan | `npc=<id>` |

### Markers and summary

```
-- At start of each MCP test window:
print("[P7_TEST] START READ HERE")

-- At end of each MCP test window (30s):
print(string.format("[P7_TEST] [SUMMARY] markets_discovered=%d stands_claimed=%d stands_released=%d markets_skipped=%d scans_started=%d",
    marketsDiscovered, standsClaimed, standsReleased, marketsSkipped, scansStarted))
print("[P7_TEST] END READ HERE")
```

Server-side counters: `marketsDiscovered`, `standsClaimed`, `standsReleased`, `marketsSkipped`
Client-side counters: `scansStarted`

---

## Diagnostics & Validators

### New diagnostics (guarded by `Config.DiagnosticsEnabled`)
- `[WanderingProps] MARKET_STAND_CLAIM poi=<id> stand=<index> npc=<id> occupied=<n>/<capacity>`
- `[WanderingProps] MARKET_EXPAND <npc_id> poi=<id> stands=<n> inserted=<count>`
- `[WanderingProps] MARKET_CLAIM_RELEASE poi=<id> stand=<index>`

### Startup validator additions
- Market POI without `InternalWaypoints` → warn and skip (already handled by `discover()` requiring `precomputedInternalGraph`)
- Market POI without `Stands` folder → warn: `'POI "<name>" is market type but has no Stands folder. Skipped.'`
- Stand subfolder missing `StandZone` → warn: `'Stand "<name>" in POI "<name>" has no StandZone BasePart. Skipped.'`
- Stand subfolder missing `ViewTarget` → warn: `'Stand "<name>" in POI "<name>" has no ViewTarget BasePart. ViewTarget will be nil.'`

---

## Known Operational Pitfalls

1. **Market dwell uses scenic path, not social.** Market NPCs enter `"dwelling"` state (like scenic), NOT `"walking_to_seat"`. There is no seat CFrame. The NPC walks to the stand position via expanded waypoints, then dwells in place.
2. **1:N expansion shifts all subsequent POI indices.** When a market POI expands into N stops in `builtPoiStops`, all subsequent POI waypoint indices must be shifted by `(N-1)`. Same pattern as the internal navigation expansion offset tracking.
3. **Stand-to-stand paths are computed live, not cached.** Unlike social/scenic where entry→access paths are pre-cached at discover time, market stand-to-stand paths use `computeInternalPath()` live at spawn time because visit order is random. This is fine for small graphs.
4. **Scan yields to player head-look.** `applyScan()` checks `headLookActive` and `headLookAlpha` before applying scan rotation. When a player walks near a scanning NPC, the player-look system takes over seamlessly. Scan resumes when player moves away.
5. **Market requires `InternalNavigationEnabled`.** If disabled, markets are skipped during discovery. This is different from scenic/social where the flag only gates expansion.

---

## Build Order (5 stages)

### Stage 1: Types + Config
- `Types.luau`: add `MarketStand`, `MarketStandClaim`, extend `POIStopData` with `"market"` + scan fields, add scan fields to `NPCState`
- `Config.luau`: add 7 market config values

### Stage 2: POIRegistry — market discovery + claim/release
- New: `discoverMarketStands()`, `claimMarketStand()`, `releaseMarketStand()`
- Modify: `discover()` to accept `"market"` type, discover stands, auto-link to internal nodes, cache paths

### Stage 3: PopulationController — market filtering + expansion + claim lifecycle
- New: `releaseMarketStandClaim()`, `expandMarketInternalWaypoints()`
- Modify: filtering loop, internal navigation expansion, builtPoiStops 1:N construction
- Modify: `despawnNPC()`, `trimRouteForNightDrain()` for market claim release
- Modify: record construction + claim scheduling with `task.delay`

### Stage 4: HeadLookController — scan functions
- New: `startScan()`, `stopScan()`, `applyScan()`
- Modify: `init()` and `reset()` with scan field init/cleanup

### Stage 5: NPCClient — scan integration + market dwell support
- Modify: dwell entry to trigger `startScan()` when `poi.scanTarget ~= nil`
- Modify: dwelling update to call `applyScan(npc, dt)` when `npc.scanActive`
- Modify: dwell exit to call `stopScan()`
- Modify: dwell entry guard to accept `"market"` type (if needed — verify existing check)

---

## Files to Modify
1. `src/shared/Types.luau` — minor (new types, extended POIStopData + NPCState)
2. `src/shared/Config.luau` — minor (7 new config values)
3. `src/server/POIRegistry.luau` — major (market stand discovery, claim/release, discover extension)
4. `src/server/PopulationController.server.luau` — moderate (filtering, expansion, 1:N stops, claim lifecycle)
5. `src/client/HeadLookController.luau` — moderate (scan start/stop/apply, init/reset extension)
6. `src/client/NPCClient.client.luau` — minor (scan trigger in dwell entry/update/exit, market dwell guard)

## Files NOT to Modify
- `src/client/NPCMover.luau`, `src/client/NPCAnimator.luau`, `src/client/LODController.luau`, `src/client/ModelPool.luau` — no changes
- `src/client/PathSmoother.luau` — no changes (bevel protects non-busy stops; market stops are non-busy)
- `src/shared/WaypointGraph.luau`, `src/shared/RouteBuilder.luau` — no changes

## Build Guardrails
- `InternalNavigationEnabled = false` → markets skipped entirely during discovery
- Markets without `Stands/` folder → warned and skipped
- Markets without `InternalWaypoints/` folder → warned and skipped
- When no market POIs are authored → zero behavior change from Pass 6
- No new RemoteEvents
- Preserve all Pass 1-6 behavior and wire contracts
