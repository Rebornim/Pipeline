# Wandering Props Phase 3 Handoff

**Project:** `wandering-props`  
**Current phase:** 3 (build complete, refinement/testing)  
**As of:** Friday, February 13, 2026

## Current Checkpoint

- All 10 modules are built and wired.
- We are in Studio validation/refinement.
- **Important:** A manual rollback was completed to the state **before** the message:
  - `"Sure, and I dont think the scenic POI or social POIs are working..."`
- Any changes made after that point were intentionally removed.

## New Checkpoints After Resume (Friday, February 13, 2026)

- `c4058c1` - Git baseline commit for the rollback state before new Phase 3 work.
- `0a8b2f6` - `PopulationController` now records per-cycle spawn failure reasons and emits a throttled warning when a spawn cycle makes zero progress while under target population.
- `648c267` - `NPCAnimator` now destroys animation tracks during setup/cleanup to avoid long-run track accumulation on pooled models.
- `78067fc` - Handoff known-risk section updated to reflect current checkpoint behavior.
- `1bbf359` - `RouteBuilder` now reports empty-route failure detail that `PopulationController` includes in spawn-cycle stall warnings for clearer root-cause diagnostics.
- `77adc88` - `PopulationController` now warns only after consecutive no-progress spawn cycles, reducing noise from occasional sparse-topology miss cycles.
- `dbfa3f7` - Social POIs now allow at least one active seat reservation when capacity cap is positive, and route legs now allow immediate backtrack only as a dead-end fallback.
- `55cca66` - `NPCMover` ground snap now excludes whole hit models (players/NPCs), reducing pop-up elevation when crossing characters.
- `01d75f2` - Group follower offsets now alternate sides with jitter; default movement pacing tuned calmer (`BASE_WALK_SPEED=8`, `GROUP_SIZE_MAX=3`).
- `b5ce7b6` - Client LOD now has three visual stages: low-rate updates (`low`), frozen-animation distant tier (`mid`), then hidden (`far`).
- `9424c8b` - `RouteBuilder` now uses live part tags for Scenic/Social POI behavior and randomizes non-seat POI arrival points within POI part bounds.
- `ea324f4` - `PopulationController` now retries alternate spawn-route candidates per spawn action and increases attempt budget while below minimum population.
- `fd3c0a3` - `NPCClient` now keeps active NPC models under `Workspace.WanderingPropsActiveNPCs`.
- `c5b821f` - LOD low tier now affects animation speed only (no movement-update throttling), and default LOD distances were increased (`300/700/1100`).
- `13281b7` - Handoff/state checkpoint sections updated to include this follow-up refinement pass.
- `54b5695` - Handoff docs synced post-push to keep latest checkpoint refs aligned with branch head.
- `c3afac7` - POI traversal now avoids intermediate social transit stops, excludes spawn/despawn-tagged nodes from POI selection, and supports random-seat social fallback when reservations fail.
- `f1d26b7` - Spawn recovery now forces solo spawns while below minimum population.
- `31f6824` - `NPCMover` now re-parents LOD-restored models to `Workspace.WanderingPropsActiveNPCs` instead of root `Workspace`.
- `d4445f2` - Handoff/state checkpoint lists updated for this social/scenic and spawn-recovery follow-up set.
- `fef5c95` - Handoff/state sync commit after follow-up push.
- `0df5ada` - POI dwell behavior hardened: `RouteBuilder` now inserts explicit `idle`/`sit` dwell steps, and `NPCMover` no longer carries overflow into POI dwell timing.

Validation performed after each patch: `rojo build default.project.json --output /tmp/wandering-props.rbxlx`.

## Git Remote

- Repo: `git@github.com:Rebornim/Pipeline.git`
- Branch: `main`
- Use this for rollback anchors and future checkpoint pushes.

## Files Implemented

- `projects/wandering-props/src/default.project.json`
- `projects/wandering-props/src/src/shared/Config.luau`
- `projects/wandering-props/src/src/shared/Types.luau`
- `projects/wandering-props/src/src/server/NodeGraph.luau`
- `projects/wandering-props/src/src/server/SeatManager.luau`
- `projects/wandering-props/src/src/server/RouteBuilder.luau`
- `projects/wandering-props/src/src/server/NPCRegistry.luau`
- `projects/wandering-props/src/src/server/PopulationController.server.luau`
- `projects/wandering-props/src/src/client/ModelPool.luau`
- `projects/wandering-props/src/src/client/NPCAnimator.luau`
- `projects/wandering-props/src/src/client/NPCMover.luau`
- `projects/wandering-props/src/src/client/NPCClient.client.luau`

## Current Behavior (Post-Rollback)

- Model templates can be named anything; runtime discovers all `Model` children under `ReplicatedStorage.WanderingPropModels`.
- Test animation IDs are hardcoded in `Config.luau`:
  - `ANIM_WALK = "rbxassetid://98082498740442"`
  - `ANIM_IDLE = "rbxassetid://108108873581082"`
  - `ANIM_SIT = "rbxassetid://103743081006243"`
- Node/seat tag discovery only reads tagged parts in `Workspace`.
- Pathfinding is A* with optional turn penalty (`PATH_TURN_PENALTY`).
- Waypoint zone randomization is deterministic unless `RandomizeTravelPoint=true` on waypoint.
- Ground snap exists in `NPCMover` (`GROUND_SNAP_*` config values).
- Turn smoothing system is present in `NPCMover`.
- Immediate waypoint backtracking prevention is present in `RouteBuilder`.

## What Was Rolled Back

These are **not** currently present after rollback:

- Tag-based POI type detection rewrite in `RouteBuilder`.
- Busy POI dwell additions in `RouteBuilder` + `Config`.
- Social default capacity changed to `1` (it is back to `0.75`).
- Added seat-capacity warning logs in `SeatManager`.
- Animator track-cache reuse in `NPCAnimator`.
- Extra animation `pcall` wrapper in `NPCClient` step-change handler.
- Spawn starvation warning diagnostics in `PopulationController`.
- Navigation-health startup warnings in `PopulationController`.
- Route-builder last-resort fallback dwell/despawn patch.
- Increased spawn attempt budget (`12x`) patch.
- Ground-surface top-only zone position patch in `NodeGraph`.
- Idle/sit per-frame pose reapply branch in `NPCMover.update`.

## Current Additions vs Rolled-Back Experiments

- The new spawn instrumentation is diagnostics-only and does not alter spawn attempt budgets or route selection logic.
- Spawn stall warnings now include route-builder context (`no_reachable_despawn`, POIs accepted/skipped counts) when route generation fails.
- Spawn stall warnings now require consecutive no-progress cycles before emitting.
- Dead-end POI/despawn traversal now has a constrained backtrack fallback instead of hard-failing when no alternative exit exists.
- Social seat capacity now supports one-seat POIs when capacity cap is positive.
- Social POI seating now has a fallback random-seat path when timed reservation fails, and non-social route legs skip intermediate social transit nodes.
- POI dwell steps are now explicit route steps, and POI dwell timers reset on entry to avoid immediate skip from prior walk overflow.
- Ground snap ignores whole player/NPC models on hit, reducing climb-on-character artifacts.
- LOD pipeline now supports `near -> low -> mid -> far`; `low` reduces animation speed only, `mid` freezes animation, `far` hides models.
- The animator change is track lifecycle cleanup (destroy-on-cleanup), not the previously rolled-back track-cache reuse patch.

## Known Risks At This Checkpoint

- Long-run animation stability still needs soak confirmation, but per-NPC track cleanup now destroys stale tracks on reuse.
- Spawn consistency can still degrade when route generation repeatedly returns no usable routes, but cycle-level warnings now include route-level skip/failure breakdowns.
- LOD tuning may need map-specific adjustment (`LOD_FREEZE_DISTANCE`, `LOD_LOW_UPDATE_RATE`, `LOD_FROZEN_UPDATE_RATE`) to balance stepping artifacts vs. performance.
- Social/Scenic behavior may still feel inconsistent depending on multi-tag node setup and graph topology.

## Studio Setup Reminders

- Graph edges are `ObjectValue.Value` references to target Part instances (names do not matter).
- Connections are one-way unless you add reverse edges.
- Seat ownership is hierarchy-based: `WP_Seat` must be under a `WP_Social` part.
- Template parts in `Workspace` with live tags will be treated as active nodes.

## Rojo (VM -> Studio)

```bash
cd /home/rebornim/roblox-pipeline/projects/wandering-props/src
rojo serve default.project.json --address 0.0.0.0 --port 34872
```

```bash
hostname -I | awk '{print $1}'
```

Connect Rojo plugin from Studio to `<VM_IP>:34872`.

## Fresh Chat Prompt

`Resuming wandering-props Phase 3 from rollback checkpoint. Read projects/wandering-props/state.md and projects/wandering-props/resume-handoff.md first. Assume all 10 modules exist. Do not re-apply rolled-back experiments unless explicitly requested. Start with targeted diagnostics for spawn reliability and long-run animation track stability.`
