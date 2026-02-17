# Project State: wandering-props

**Stage:** Pass 8 — Redesign Complete
**Status:** pass_8_ready
**Pipeline Version:** v3 (cyclic)
**Last Updated:** 2026-02-17

## Context Files
- Read: `feature-passes.md`, `idea-locked.md`, `pass-1-design.md`, `pass-2-design.md`, `pass-2-build-notes.md`, `pass-3-design.md`, `pass-4-design.md`, `pass-5-design.md`, `pass-7-design.md`, `pass-8-design.md`, `pass-8-redesign-brief.md`, `golden-tests.md`, `state.md`
- Source of truth for current behavior: `src/` code + this file + `golden-tests.md`

## Pass 1 Outcome
- Core spawn -> walk -> despawn loop implemented and user-validated.
- Instance-safe waypoint graph IDs (duplicate names supported).
- Live code served from project-root `default.project.json` and `src/*`.

## Pass 2 Outcome (Built)
- POI system implemented: Scenic, Busy, Social.
- New module: `src/server/POIRegistry.luau`.
- Existing remotes preserved (`NPCSpawned`, `NPCDespawned`, `NPCBulkSync`), payload extended in-place with `poiStops`.
- Seat claim/release lifecycle implemented server-side with despawn safety release.
- Stuck-route fallback implemented (drop POIs, fallback routes, route-stuck diagnostics).
- Client POI state machine implemented with late-join POI state handling.

## Pass 2 Build Deltas (still active)
- POI waypoint linking contract expanded:
  - POI waypoint `BasePart` nodes are integrated into the graph.
  - Links can be authored either direction via `ObjectValue` (main waypoint <-> POI waypoint).
- Social behavior changed from teleport-to-seat to walk-to-seat and walk-from-seat.
- `CapacityPercent` is fractional (`0.8` = 80%).

## Pass 3 Outcome (Built)
Implemented:
1. **Waypoint zones**
- Waypoint nodes with `Zone=true` use part `Size` for random XZ stand positions.
- Zone behavior is ignored on POI waypoint parts.

2. **Day/night population hook (clock-based)**
- `DayNightEnabled` toggles day/night behavior.
- Night/day state is computed from `Lighting.ClockTime` using:
  - `NightStartHour`
  - `DayStartHour`
- Night population cap uses `NightPopulationMultiplier`.

3. **Night behavior shaping (despawn-point safe)**
- Night spawns can use fewer POIs via `NightPOICountMax`.
- Night routes can prefer nearest despawn via `NightPreferNearestDespawn`.
- Optional night drain shortens active routes while preserving despawn-point rule:
  - NPCs are rerouted to `current position -> next POI (optional) -> despawn waypoint`.
  - No hard force-despawn in place.

4. **Scenic POI standing variation**
- Scenic POIs can randomize stand position within the Scenic waypoint part footprint (when waypoint is inside POI folder).

5. **Runtime marker visibility toggle**
- `HideMarkersAtRuntime` controls runtime invisibility for waypoint/POI helper markers.

## Pass 3 Build Deltas from Original Pass 3 Design
- Random wander detours were removed from runtime behavior by request (Wander config remains disabled; no detour insertion in route flow).
- Day/night integration changed from `WanderingProps.IsNight` attribute input to `Lighting.ClockTime` input.
- Temporary built-in day/night simulator was removed; system now only consumes external time-of-day.
- Night drain and night route-shortening were added for faster visible nighttime reduction while keeping despawn-point behavior.

## Key Files Modified Across Pass 3 Build
- `src/shared/Types.luau`
- `src/shared/Config.luau`
- `src/shared/WaypointGraph.luau`
- `src/server/POIRegistry.luau`
- `src/server/PopulationController.server.luau`

## Live Project Layout
- Rojo project file: `default.project.json` (project root)
- Live code roots: `src/server`, `src/client`, `src/shared`
- Archived older/unused scripts: `v3-archive/src/*`, `v2-archive/*`

## Runtime Contracts To Preserve
- Server authority: lifecycle/routes/timing; client authority: visuals/movement/animation.
- Runtime-created instances remain:
  - `ReplicatedStorage/WanderingPropsRemotes`
  - `Workspace/WanderingProps/ActiveNPCs`
- Keep model-template-first spawn behavior (`modelTemplate` with `modelName` fallback).
- `NPCSpawnData.poiStops` remains optional (`nil` = pure walking route).
- Client state machine states: walking, dwelling, walking_to_seat, sitting, walking_from_seat, finished.
- NPCs must reach route endpoints (despawn waypoints) to despawn.

## Pass 4 Design Summary
- **LOD tiers** (near/low/mid/far) based on distance from local player. Far-tier NPCs are hidden and skip all per-frame work. Mid-tier stops animations. Low-tier reduces raycast frequency.
- **Model pooling** reuses despawned models (with pre-loaded AnimationTracks) instead of Clone()/Destroy() every cycle.
- All changes are **client-side only**. No server changes, no new remotes.
- New modules: `src/client/LODController.luau`, `src/client/ModelPool.luau`.
- Modified modules: `NPCClient.client.luau`, `NPCMover.luau`, `NPCAnimator.luau`, `Config.luau`, `Types.luau`.
- Critic: APPROVED (rev 2). 0 blocking issues.
- Golden tests: Tests 15-18 added. Regression suite covers Tests 1, 2, 4, 5, 9, 11, 12, 13.

## Build Guardrails
- Scope to optimization only. Do not add movement-polish features.
- Preserve current Pass 1-3 behavior and wire contracts.
- LOD and Pool features are independently toggleable via `LODEnabled` and `PoolEnabled` config flags.
- When both are disabled, system must behave identically to Pass 3.

## Pass 4 Outcome (Built)
Implemented as designed:
1. **LOD integration** in client loop with tier transitions, reduced raycast cadence, hidden out-of-range NPCs, and far-tier restore flow.
2. **Model pooling** with acquire/release lifecycle and reuse diagnostics.
3. **Types/Config updates** for LOD + pooling fields and tunables.
4. **Animator/Mover updates** to support LOD-aware animation stop and raycast skipping.

Post-build fixes and stabilization completed:
1. **Initial batch animation bug fix** (fresh models now initialize tracks in the same runtime context as pooled paths).
2. **LOD consistency fix** (`mid` entry now reliably stops tracks).
3. **Config freedom update** (removed hard max/min fatal caps from `PopulationController` validator; retained robust runtime behavior).

## Pass 4 Build Deltas From Original Pass 4 Design
Design deviations introduced by request during stress tuning:
1. **Server-side churn controls added** (design said client-only):
   - Spawn/despawn request queues with per-heartbeat budgets.
   - Batched spawn/despawn remote flushes.
2. **Client-side event apply queue added**:
   - Spawn/despawn payloads are queued and applied under a per-heartbeat budget.
3. **Pool prewarm added**:
   - Client can pre-seed pooled models at startup.
4. **LOD policy tuned**:
   - `mid` tier animation disabled for stronger CPU savings.
   - Distances/raycast skip defaults tuned for heavier optimization profile.

## New Runtime Contracts (Active)
1. `NPCSpawned` remote payload is now either:
   - single spawn data table, or
   - array of spawn data tables (batched).
2. `NPCDespawned` remote payload is now either:
   - single npc id string, or
   - array of npc id strings (batched).
3. Server and client both enforce per-heartbeat operation budgets for churn-heavy spawn/despawn periods.

## Key Files Modified For Pass 4 Build + Stabilization
- `src/client/NPCClient.client.luau`
- `src/client/LODController.luau`
- `src/client/ModelPool.luau`
- `src/client/NPCAnimator.luau`
- `src/client/NPCMover.luau`
- `src/shared/Config.luau`
- `src/shared/Types.luau`
- `src/server/PopulationController.server.luau`

## Pass 4 Post-Build Critic Review
- Full codebase critic review conducted at 4-pass mark (all 12 source files).
- **1 blocking issue found and fixed:** Prewarm model visibility flash (models briefly visible at origin during pool prewarm). Fixed by CFraming off-screen before parenting.
- **3 flags addressed:** Heartbeat LOD indentation reformatted, double `getStats()` removed from `removeNPC`, event queue backlog diagnostic added.
- **4 flags noted (no action needed):** LOD distances tuned wider than design (tuning choice), raycast skip values increased (tuning choice), mid-tier seat slide without animation (acceptable at distance), duplicate RaycastParams setup between NPCClient and NPCMover (minor, future cleanup).
- Verdict: APPROVED. 0 blocking issues remaining.

## Pass 5 Design Summary
- **6 visual polish features:** Corner beveling, smooth elevation, smooth body rotation, head look toward player, path lateral offset, spawn/despawn fade.
- **Changes are mostly client-side.** One server-side change: lateral offset in `PopulationController.convertNodeIdsToWaypoints`.
- **New modules:** `src/client/PathSmoother.luau`, `src/client/HeadLookController.luau`.
- **Modified modules:** `NPCClient.client.luau`, `NPCMover.luau`, `Config.luau`, `Types.luau`, `PopulationController.server.luau`.
- **No new RemoteEvents.** No changes to LODController, ModelPool, NPCAnimator, WaypointGraph, RouteBuilder, Remotes, POIRegistry.
- All 6 features independently toggleable via Config flags. When all disabled, behavior = Pass 4.
- Critic: APPROVED (rev 2). 1 blocking fixed (PathSmoother indexMap completeness), 9 flags noted.
- Golden tests: Tests 19-24 added. Regression suite covers Tests 1, 2, 4, 5, 9, 11, 15, 16, 17.

## Build Guardrails
- All 6 features independently toggleable. When all disabled, identical to Pass 4.
- Do NOT modify LODController, ModelPool, or NPCAnimator APIs.
- Do NOT add new RemoteEvents.
- PathSmoother must not modify POI stop waypoint positions.
- HeadLookController must handle missing Neck Motor6D gracefully (skip, not error).
- Fade must restore original transparencies before pool release.

## Pass 6 Outcome (Built)
Implemented as designed:
1. **Social POI internal waypoint navigation** — internal waypoint graphs within social POIs for complex interior layouts, with BFS pathfinding and approach/exit waypoint expansion baked into the main waypoints array.
2. **Scenic POI stand point collections** — multiple zone-sized stand positions within scenic POIs, randomly selected per visit.
3. **Single config toggle** — `InternalNavigationEnabled` controls all Pass 6 features.

## Pass 6 Build Details
- Core Pass 6 implementation is server-driven waypoint expansion.
- Internal graph discovery in `POIRegistry.discoverInternalGraph()` builds bidirectional mini-graph from `InternalWaypoints` folder children.
- BFS pathfinding in `POIRegistry.computeInternalPath()` for small internal graphs.
- Stand point discovery in `discoverStandPoints()` reads `StandPoints` folder children.
- Seat groups gain `accessNodeId` via `AccessPoint` ObjectValue (fallback: closest internal node by distance).
- `claimSeat()` returns third value: `accessNodeId`.
- `expandSocialInternalWaypoints()` inserts approach/exit paths around POI waypoint in the flat waypoints array.
- Forward-order processing with cumulative index offset tracking for multiple POI expansions.

## Pass 6 Build Deltas From Original Pass 6 Design
Design deviations introduced during prove/fix cycles:
1. **Client changes were added (design originally expected server-only):**
   - `PathSmoother` now excludes `busy` POI stops from protected bevel anchors so busy flow stays smooth.
   - `NPCClient` walking flow now treats `busy` POIs as pass-through checkpoints (no forced stop frame).
   - Why: user-observed hard-turn behavior at busy POIs during Pass 6 prove.
2. **POI waypoint resolver generalized beyond name-specific rules:**
   - Multi-entrance `ObjectValue` links are accepted as valid.
   - Internal-entrance links can define canonical POI entry when no single dedicated POI waypoint part is present.
   - Why: social/scenic multi-entrance authoring produced false ambiguity warnings under strict naming assumptions.
3. **Scenic internal routing extended beyond initial Pass 6 summary:**
   - Scenic POIs can use internal waypoints + stand access nodes for entrance -> stand -> exit flow (not only stand-point selection).
   - Why: align scenic behavior with social interior traversal expectations in authored layouts.

## Pass 6 Prove + Stabilization (2026-02-16)
1. Golden prove runs covered Tests 25-29 intent plus regressions with minimal-log MCP loops and user visual verification.
2. Social/scenic multi-entrance authoring no longer depends on a name-specific waypoint rule.
3. Scenic stand flow now supports entrance/internal path -> stand -> internal path/entrance exit, with stand sampling in part-local space.
4. POI stop anchoring was preserved for scenic/social while allowing busy POIs to remain smooth pass-through waypoints.
5. Busy POIs now randomize stop position within authored POI area parts (when waypoint part is inside POI).
6. Residual non-blocking follow-up: optional client startup ordering improvement to reduce occasional first-visibility delay.

## Key Files Modified For Pass 6 Build
- `src/server/POIRegistry.luau` (major: internal graph discovery, BFS, stand points, accessNodeId)
- `src/server/PopulationController.server.luau` (moderate: waypoint expansion, stand point selection, busy/scenic area randomization)
- `src/client/NPCClient.client.luau` (busy POI pass-through handling)
- `src/client/PathSmoother.luau` (POI-stop protection behavior for smoothing)
- `src/shared/Config.luau` (minor: InternalNavigationEnabled flag)
- `src/shared/Types.luau` (minor: InternalNode, InternalGraph, StandPoint types)

## Build Guardrails
- `InternalNavigationEnabled = false` → skip all expansion, identical to Pass 5.
- POIs without `InternalWaypoints` or `StandPoints` folders → current behavior unchanged.
- No new RemoteEvents. Client-side changes remain limited to busy POI smoothing/pass-through behavior only.
- Preserve all Pass 1-5 behavior and wire contracts.

### Pass 6 Build Delta
**Built as designed:**
- Social POI internal waypoint navigation with internal graph traversal and seat access-node routing.
- Scenic POI stand point collections with random stand selection per visit.
- Single config toggle `InternalNavigationEnabled` governing Pass 6 behavior.

**Deviations from design:**
- Added targeted client/path-smoothing behavior so busy POIs are pass-through checkpoints (fix for observed hard-turn stop behavior).
- Generalized POI waypoint/entrance resolution to support multi-entrance authoring without name-specific waypoint requirements.
- Extended scenic flow to support full entrance -> internal path -> stand -> internal path -> exit behavior.
- Reverted late despawn performance experiments (despawn jitter and client in-place recycle retarget) after user-reported regressions.

**New runtime contracts:**
- Social seat claims now include `accessNodeId` used by internal route expansion.
- Scenic stand points are sampled in part-local space and can route via internal access nodes.
- Busy POIs remain route checkpoints server-side but are handled as pass-through stops client-side.

**Non-blocking follow-ups:**
- Spawn/despawn hitch is still visible at higher NPC populations and is deferred to a dedicated optimization pass.
- Optional startup ordering and spawn/despawn budget tuning are still open.

## Pass 7 Design Summary
- **New POI type: `"market"`** — NPCs enter marketplace, visit random stands (2-4), browse with head scanning, leave.
- **1:N POI-to-stop mapping** — single market POI expands into N scenic-like dwell stops in `builtPoiStops`.
- **Stand capacity** — per-stand `MarketStandCapacity` with claim/release lifecycle (same pattern as social seats).
- **Head scanning** — sinusoidal neck yaw sweep during market dwell via HeadLookController scan functions.
- **Server-side waypoint expansion** — multi-stand visits baked into flat waypoints array using live Dijkstra.
- **Files to modify:** Types.luau, Config.luau, POIRegistry.luau (major), PopulationController.server.luau (moderate), HeadLookController.luau (moderate), NPCClient.client.luau (minor).
- **No new RemoteEvents.** Markets require `InternalNavigationEnabled = true`.
- Golden tests: Tests 30-35 added. Regression suite covers Tests 1, 2, 4, 5, 9, 11, 15, 16, 17, 25, 27.

### Pass 7 Build Delta
**Built as designed:**
- Market POI type is implemented with server-side expansion from one selected market POI into multiple stand browse stops.
- Per-stand market capacity claim/release lifecycle is implemented and integrated with despawn/night-trim cleanup paths.
- Client-side market dwell supports head-look scanning behavior with market stop metadata (`scanTarget`, `scanExtent`) flowing through existing spawn payloads.

**Deviations from design:**
- Market stand authoring was implemented with attribute-based discovery (`MarketStandZone`, `MarketViewTarget`) plus internal-waypoint `ObjectValue` links to stands, replacing name-specific stand child requirements.
- Stand access mapping supports multiple internal access nodes per stand and picks best runtime path, rather than only closest-single-node mapping.
- Head scan behavior was changed from pure sinusoidal sweep to a state-machine gaze pattern (look/hold/look/hold with occasional short glide) per visual feedback.
- Market stand cap was tuned to `2` (from the original Pass 7 design default `3`) per user request.
- Additional movement stability fixes were applied in client mover to eliminate intermittent one-frame rotation snaps at waypoint transitions.

**New runtime contracts:**
- Market stand capacity is globally capped by `Config.MarketStandCapacity` during both stand selection and claim time.
- Market stand access-node resolution accepts one-to-many internal waypoint links, and route expansion chooses best path from current access node.
- Market stand discovery now depends on stand attributes (`MarketStandZone`, optional `MarketViewTarget`) and internal waypoint link graphing to determine stand eligibility.

**Non-blocking follow-ups:**
- If any rare rotation pop remains under extreme waypoint topologies, add temporary heading-delta instrumentation around waypoint boundary frames to isolate route-shape edge cases.
- Optional visual tuning pass can further adjust gaze hold/transition/glide timing without contract changes.

## Pass 8 Design Summary
- **External Behavior API** — public `WanderingPropsAPI` module for other game systems.
- **Priority-based behavior modes:** Normal (0), Pause (10), Evacuate (20), Scatter (30). Higher priority overrides lower.
- **Mode effects:** spawn pausing, walk speed multiplier, reroute-all-to-nearest-despawn.
- **Built-in debounce:** `ModeRetriggerCooldown` prevents repeated same-mode triggers from being expensive.
- **Mode expiry with fallback:** modes have durations. Expiry falls back to next highest active mode or normal.
- **Per-player client desync:** `NPCDesync` remote toggles. Desync wipes all client NPCs instantly. Resync sends bulk sync.
- **Shared state bridge:** `PopulationHooks.luau` connects API module to PopulationController without require-cycle.
- **Files to modify:** Types.luau, Config.luau, Remotes.luau, PopulationHooks.luau (new), WanderingPropsAPI.luau (new), PopulationController.server.luau, NPCClient.client.luau.
- **1 new RemoteEvent:** `NPCDesync`.
- **Zero overhead when unused:** if no script requires WanderingPropsAPI, behavior = Pass 7.
- Golden tests: Tests 36-41 added. Regression suite covers Tests 1, 2, 4, 5, 9, 11, 15, 16, 17, 25, 27, 30.

### Pass 8 Build Attempt Delta (Scrapped)
**Built in attempt:**
- Added `WanderingPropsAPI`, `PopulationHooks`, and `NPCDesync` wiring.
- Integrated server mode effects (pause/reroute/speed) and client desync handling.

**Why this attempt failed:**
- Scatter mode produced visible timeline instability ("time machine" behavior): NPC jumps/rewinds and stale-state reappearance during mode transitions.
- Visual behavior during high-churn mode switches remained unreliable in user playtests.
- Pass quality/regression bar not met; user requested this pass be scrapped and redesigned.

**Decision:**
- Treat previous Pass 8 implementation as failed design execution.
- Keep current repo as source context, but require a new simpler Pass 8 design before additional implementation.

**Redesign focus (required):**
- Simpler server mode model with deterministic transitions.
- Avoid repeated route rewrites/speed rewrites that can invalidate in-flight timeline math.
- Clear testability and rollback criteria for each mode step.

## Pass 8 Redesign Summary (v2)
- **Core principle: never modify in-flight NPC routes or speed.** Modes control only population policy.
- **Removed from v1:** `walkSpeedMultiplier` (in-flight speed changes), `rerouteAllToNearestDespawn` (bulk route rewrites), `rebroadcastAllSpeeds`. These caused the timeline instability.
- **Mode effects limited to:** `spawnPaused` (boolean), `populationOverride` (number or nil), `drainEnabled` + `drainBatchSize` + `drainCheckInterval`.
- **Drain reuses existing `trimRouteForNightDrain`** (line 708-793) which already works reliably. Extracted core logic into `applyDrainBatch()` shared between night drain and mode drain.
- **Scatter = faster drain** (batch 8, interval 1s) vs evacuate (batch 3, interval 2s). No speed boost. Area clears ~3x faster via larger batches.
- **`nightDrainApplied` flag** prevents double-drain when both night and mode drain are active.
- **6 prove gates** for step-by-step validation: pause → evacuate → scatter → priority/debounce → desync → regression.
- **Explicit rollback conditions** for each failure mode.
- **Files:** Types.luau, Config.luau, Remotes.luau, PopulationHooks.luau (new), WanderingPropsAPI.luau (new), PopulationController.server.luau, NPCClient.client.luau.
- **1 new RemoteEvent:** `NPCDesync`.
- Golden tests: Tests 36-42 (replaced v1 tests). Regression suite covers Tests 1, 2, 4, 5, 9, 11, 15, 16, 17, 25, 27, 30.

## Next Step
- Pass 8 redesign complete. Ready for Codex build.

### Pass 8 Build Delta
**Built as designed:**
- Added external behavior API surface in `WanderingPropsAPI` with priority mode resolution, mode expiry/fallback, and per-player desync/resync.
- Added shared mode/desync bridge in `PopulationHooks` and integrated it into `PopulationController` server authority flow.
- Added `NPCDesync` remote handling client-side with desync wipe and resync bulk replay handling.

**Deviations from design:**
- Replaced redesign's incremental drain-only mode execution with one-shot reroute-on-mode-enter (`evacuate`/`scatter`) per user request to keep combat transitions immediate and deterministic.
- Added spawn/recycle queue hard-pausing and queue clearing while `spawnPaused=true` to prevent delayed respawn bursts after mode transitions.
- Added scatter-only reroute speed multiplier and forward-biased reroute start-node selection to reduce mode-entry 180 pivots and provide visibly faster scatter movement.
- Added client in-place route update (`routeVersion` contract) for reroute updates so active NPCs are retargeted without despawn/respawn fade swaps.
- Added client reroute transition smoothing to preserve current visual position at evacuate/scatter entry and avoid visible teleport pops.

**New runtime contracts:**
- `NPCSpawnData` now includes optional `routeVersion`; clients ignore stale route updates and apply latest updates in-place for matching NPC ids.
- New config knobs: `EvacuateRerouteSpeedMultiplier`, `ScatterRerouteSpeedMultiplier`.
- Mode pause contract now hard-stops new spawn/recycle queue consumption and flushes queued spawn/recycle work while paused.

**Non-blocking follow-ups:**
- Rare heading artifacts can still occur on extreme waypoint topologies; if needed, add temporary heading-delta instrumentation around reroute boundary frames for targeted tuning.
- Golden test docs still reference pass-tag log markers from the prove phase and should be refreshed to match post-wrap runtime logging expectations.
