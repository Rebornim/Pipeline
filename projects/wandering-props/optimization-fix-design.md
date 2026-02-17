# Optimization Fix: Spawn/Despawn Performance

**Goal:** Eliminate spawn/despawn lag by reducing per-spawn computation on both server and client.

**Priority order:** Do optimizations 1-6 first (performance), then 7-10 (cleanup). Test after each optimization — do NOT batch.

---

## Optimization 1: Cache internal paths at POI discovery time

**Problem:** `spawnNPC()` runs Dijkstra 3-6 times per spawn for the same internal graph paths that never change at runtime. `isGroupEligibleForSeatClaim` → `hasReachableInternalPathToAccessNode` → `computeInternalPath`, then `findUnreachableSocialInternalPOIIndex` does it again, then `expandSocialInternalWaypoints` does it a third time.

**Fix in `src/server/POIRegistry.luau`:**

In `discover()`, after building `internalGraph` for a social or scenic POI, pre-compute all paths between every entry node and every access node. Store results on the POI:

```lua
poi.cachedInternalPaths = {}
-- For social POIs: entry → group accessNodeId
-- For scenic POIs: entry → stand accessNodeId
-- Key format: entryNodeId .. ">" .. accessNodeId
-- Value: { Vector3 } path, or false if unreachable
```

Loop over all entry node IDs and all unique access node IDs (from seat groups and stand points). Call `computeInternalPath` once per pair. Store the result (path array or false).

**Then update callers in `src/server/PopulationController.server.luau`:**

- `hasReachableInternalPathToAccessNode` → lookup `poi.cachedInternalPaths[entryId .. ">" .. accessNodeId]`, return true if any entry has a non-false cached path.
- `findUnreachableSocialInternalPOIIndex` → same lookup pattern.
- `expandSocialInternalWaypoints` → lookup best (shortest) cached path instead of calling `computeInternalPath`.
- `expandScenicInternalWaypoints` → same.

**Also update in `src/server/POIRegistry.luau`:**
- `isGroupEligibleForSeatClaim` → use cached paths instead of calling `hasReachableInternalPathToAccessNode` which calls `computeInternalPath`.

**Result:** Zero Dijkstra calls at spawn time. All path lookups are O(1) table reads.

**Test:** Enable DiagnosticsEnabled. Spawn NPCs with social POIs that have InternalWaypoints. Confirm `INTERNAL_NAV_EXPAND` still fires and NPCs walk internal paths correctly. Confirm no `computeInternalPath` calls happen during `spawnNPC` (add a temporary print inside `computeInternalPath` to verify — remove after testing).

---

## Optimization 2: Move path beveling to server

**Problem:** Every client independently runs `PathSmoother.bevel()` on the same waypoints for the same NPC. With 30-50 waypoints after internal expansion, this allocates new arrays and computes Bezier curves per client per spawn.

**Fix:**

**Step A — Move PathSmoother to shared:**
- Move `src/client/PathSmoother.luau` to `src/shared/PathSmoother.luau`.
- Update `default.project.json` if needed so Rojo maps it to shared.

**Step B — Bevel on server in `src/server/PopulationController.server.luau`:**
- Add `local PathSmoother = require(sharedFolder:WaitForChild("PathSmoother"))` at top.
- In `spawnNPC()`, after internal waypoint expansion and POI waypoint randomization (the block ending around line 1279), and after building `builtPoiStops` (around line 1312), apply beveling:

```lua
if bevelEnabled and #waypoints > 2 then
    waypoints, builtPoiStops = PathSmoother.bevel(
        waypoints, builtPoiStops, Config.BevelRadius, Config.BevelSegments
    )
end
```

- Add bevel config validation at server startup (same checks NPCClient currently does for BevelRadius > 0 and BevelSegments >= 2). Store in a local `bevelEnabled` flag.
- The beveled waypoints and updated poiStops are what gets stored in the record and sent via `makeSpawnData`.
- Do the same for `trimRouteForNightDrain` — bevel the new waypoints before broadcasting.

**Step C — Remove bevel from client in `src/client/NPCClient.client.luau`:**
- Remove the `PathSmoother` require.
- Remove the bevel block in `spawnNPCFromData` (lines 616-626).
- Remove `bevelRuntimeEnabled`, `bevelRuntimeRadius`, `bevelRuntimeSegments`, `beveledPathsTotal` variables.
- Remove bevel validation from client `startup()`.

**Result:** Bevel computed once on server, sent pre-beveled to all clients. Eliminates per-client bevel allocation and computation entirely.

**Test:** Spawn NPCs with sharp-turn routes. Confirm NPCs still follow curved paths (visual check). Confirm `BEVEL_PATH` diagnostics now fire on the server output, not client.

---

## Optimization 3: Cache `GetServerTimeNow()` per frame

**Problem:** `Workspace:GetServerTimeNow()` called ~5 times per NPC per frame in the client Heartbeat. At 70 NPCs = ~350 API calls per frame.

**Fix in `src/client/NPCClient.client.luau`:**

At the top of the Heartbeat callback (line 938), add:
```lua
local now = Workspace:GetServerTimeNow()
```

Replace all `Workspace:GetServerTimeNow()` inside the loop body with `now`:
- Line 959: force despawn check
- Line 1082: scenic dwell start
- Line 1096: social dwell start
- Line 1151: dwell end check
- Line 1200: sit end check

**Fix in `src/client/HeadLookController.luau`:**

Change `HeadLookController.update` signature to accept `now: number` as a parameter:
```lua
function HeadLookController.update(npc, playerPosition: Vector3, dt: number, now: number)
```
Replace the two `Workspace:GetServerTimeNow()` calls (lines 37, 45) with the passed `now`.

Update the caller in NPCClient Heartbeat (line 1273) to pass `now`.

**Also fix in `src/server/PopulationController.server.luau`:**

In the main `while true` loop (line 1624), cache `now` at the top of each iteration and pass to `applyNightDrain`. Not critical but consistent.

**Result:** 1 API call per frame instead of ~350.

**Test:** Run with 20+ NPCs. Confirm behavior unchanged. No timing issues with dwell/sit durations.

---

## Optimization 4: Single GetDescendants pass on client spawn

**Problem:** `buildFreshModelFromTemplate` calls `GetDescendants()` for baseParts. Then `HeadLookController.init` calls `GetDescendants()` again to find the Neck Motor6D. Two full hierarchy traversals per spawn.

**Fix in `src/client/NPCClient.client.luau`:**

In `buildFreshModelFromTemplate`, during the existing descendants loop (line 465), also search for the Neck Motor6D:

```lua
local baseParts = {}
local neckMotor = nil
local neckOriginalC0 = nil
for _, descendant in ipairs(clonedModel:GetDescendants()) do
    if descendant:IsA("BasePart") then
        descendant.Anchored = false
        descendant.CanCollide = false
        table.insert(baseParts, descendant)
    elseif descendant:IsA("Motor6D") and descendant.Name == "Neck" and not neckMotor then
        neckMotor = descendant
        neckOriginalC0 = descendant.C0
    end
end
```

Return the neck data in the modelData table:
```lua
return {
    model = clonedModel,
    animator = animator,
    baseParts = baseParts,
    neckMotor = neckMotor,
    neckOriginalC0 = neckOriginalC0,
}
```

**Fix in `src/client/HeadLookController.luau`:**

Change `HeadLookController.init` to accept optional pre-found neck data:
```lua
function HeadLookController.init(npc, neckMotor: Motor6D?, neckOriginalC0: CFrame?)
```

If `neckMotor` is provided, use it directly instead of searching descendants. If nil, fall back to the current search (for pooled models that may not have pre-found neck data).

**Fix in `src/client/NPCClient.client.luau` — `spawnNPCFromData`:**

Pass the pre-found neck data from modelData to HeadLookController.init:
```lua
HeadLookController.init(npc, modelData.neckMotor, modelData.neckOriginalC0)
```

For pooled models: `ModelPool.release` should also store `neckMotor` and `neckOriginalC0` in the pool entry. `ModelPool.acquire` returns them.

**Result:** One GetDescendants call per spawn instead of two.

**Test:** Spawn NPCs. Confirm head look still works (heads turn toward player at near range). Confirm pooled models also have working head look.

---

## Optimization 5: Increase pool prewarm

**Problem:** `PoolPrewarmPerModel = 2` is too low. With `MaxPopulation = 20` and 3 models, each model needs ~7 instances. First 5 spawns per model are expensive `model:Clone()` calls.

**Fix in `src/client/NPCClient.client.luau`:**

In `configureRuntimePoolSizing` (line 536), after computing `expectedPerModel`, also update `poolPrewarmPerModelRuntime`:

```lua
local recommendedPrewarm = math.min(expectedPerModel, poolMaxPerModelRuntime)
if recommendedPrewarm > poolPrewarmPerModelRuntime then
    poolPrewarmPerModelRuntime = recommendedPrewarm
    diagnostics(string.format(
        "[WanderingProps] POOL_PREWARM_AUTOTUNE prewarm_per_model=%d",
        poolPrewarmPerModelRuntime
    ))
end
```

This ensures prewarm fills enough models to cover the expected population without cloning during gameplay.

**Also in `prewarmModelPool`:** Spread prewarm across frames using `task.defer` or `task.wait()` between models to avoid one massive frame hitch at startup:

```lua
for _, child in ipairs(modelsFolder:GetChildren()) do
    -- ... prewarm this model type ...
    task.wait() -- yield one frame between model types
end
```

**Result:** Near-zero pool misses during gameplay. Startup prewarm cost spread across frames.

**Test:** Start server with DiagnosticsEnabled. Confirm `POOL_PREWARM` count matches expected population. During gameplay, confirm `POOL_ACQUIRE` fires (not `POOL_FULL_DESTROY`) and no `model:Clone()` happens after prewarm.

---

## Optimization 6: Replace client `sliceWaypoints` with index-range calculation

**Problem:** Client `calculateRouteState` allocates sub-arrays via `sliceWaypoints`. Server's `calculateServerRouteState` already uses index-range based `calculatePositionAlongWaypoints` without allocation.

**Fix in `src/client/NPCClient.client.luau`:**

Port the server's `calculatePositionAlongWaypoints` function to the client (or move it to a shared module). Replace the client's `calculateRouteState` to use index ranges instead of `sliceWaypoints`.

Specifically:
- Remove the `sliceWaypoints` function.
- Add the `calculatePositionAlongWaypoints` function (copy from PopulationController lines 479-514).
- Rewrite `calculateRouteState` to use `calculatePositionAlongWaypoints(waypoints, walkSpeed, walkElapsed, lastResumeIndex, poi.waypointIndex)` instead of creating sub-arrays.
- Keep the return format identical so callers don't change.

**Result:** Zero table allocations during far-tier restore and late-join spawn.

**Test:** Join server late while NPCs are mid-route and mid-dwell. Confirm NPCs appear at correct positions. Walk far away and back to trigger far-tier restore. Confirm NPC positions/states are correct.

---

## Cleanup 7: Add missing Config values

**Fix in `src/shared/Config.luau`:**

Add after the LOD TIERS section:
```lua
Config.LODLowMoveSkip = 1
Config.LODMidMoveSkip = 1
```

Add after the HEAD LOOK section:
```lua
Config.HeadLookDisableAboveCount = 0
```

These match the current `or` fallback defaults so behavior is unchanged.

---

## Cleanup 8: Fix expansion function return consistency

**Fix in `src/server/PopulationController.server.luau`:**

In `expandSocialInternalWaypoints` — change early returns (lines 754, 758) from:
```lua
return waypoints, poiWaypointIndex
```
to:
```lua
return waypoints, poiWaypointIndex, 0
```

Same for `expandScenicStandWaypoints` early return and `expandScenicInternalWaypoints` early return.

---

## Cleanup 9: Add missing Types.luau fields

**Fix in `src/shared/Types.luau`:**

Add to NPCState type:
```lua
lodPhase: number,
movePhase: number,
moveAccum: number,
baseParts: { BasePart },
```

Add to StandPoint type:
```lua
sourcePart: BasePart?,
```

---

## Cleanup 10: Normalize indentation in NPCClient

**Fix in `src/client/NPCClient.client.luau`:**

Normalize the indentation in the state machine block:
- `walking_to_seat` handler (around lines 1161-1184): align inner blocks to consistent tab depth.
- `sitting` dwell-end transition (around lines 1200-1215): same.
- `walking_from_seat` completion (around lines 1241-1258): same.

Use tabs, match the indentation style of the `walking` and `dwelling` handlers above them.

---

## Build order

1. Optimization 1 (cache internal paths) — server only, test
2. Optimization 2 (server-side bevel) — server + client, test
3. Optimization 3 (cache GetServerTimeNow) — client + HeadLookController, test
4. Optimization 4 (single GetDescendants) — client + HeadLookController + ModelPool, test
5. Optimization 5 (pool prewarm) — client, test
6. Optimization 6 (index-range calculation) — client, test
7-10. Cleanups — all at once, test

## Regression tests to run

After all changes: Golden tests 1, 2, 4, 5, 9, 11, 15, 16, 17, 25, 26, 27, 28.

Key visual checks:
- NPCs still follow curved paths at corners (bevel moved to server)
- Social POI NPCs walk internal waypoints before/after sitting
- Head look still works for fresh and pooled models
- Late-join sync positions are correct
- Spawn burst doesn't hitch (the whole point)
