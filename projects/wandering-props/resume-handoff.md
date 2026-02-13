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
- The animator change is track lifecycle cleanup (destroy-on-cleanup), not the previously rolled-back track-cache reuse patch.

## Known Risks At This Checkpoint

- Long-run animation stability still needs soak confirmation, but per-NPC track cleanup now destroys stale tracks on reuse.
- Spawn consistency can still degrade when route generation repeatedly returns no usable routes, but cycle-level warnings now include route-level skip/failure breakdowns.
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
