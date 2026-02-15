# Project State: wandering-props

**Stage:** Pass 4 — Design locked
**Status:** ready_for_pass_4_build
**Pipeline Version:** v3 (cyclic)
**Last Updated:** 2026-02-15

## Context Files
- Read: `feature-passes.md`, `idea-locked.md`, `pass-1-design.md`, `pass-2-design.md`, `pass-2-build-notes.md`, `pass-3-design.md`, `pass-4-design.md`, `golden-tests.md`, `state.md`
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

## Next Step
- Hand `pass-4-design.md` to Codex for build.
