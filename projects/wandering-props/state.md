# Project State

**Project:** wandering-props  
**Phase:** 3  
**Status:** build complete, in Studio refinement/testing  
**Last Updated:** 2026-02-13

## Start Here (For Any New AI Session)

Read in this order:

1. `codex-instructions.md`
2. `projects/wandering-props/architecture-outline.md`
3. `projects/wandering-props/resume-handoff.md`

## Critical Context

- All 10 Phase 3 modules are implemented.
- This repo is currently at a **manual rollback checkpoint**:
  - Restored to the state before the message:
    - `"Sure, and I dont think the scenic POI or social POIs are working..."`
- Several later experiments were intentionally removed and should not be assumed present.

## Current Goals

1. Stabilize spawn reliability in real Studio sessions.
2. Stabilize long-run behavior (10-20+ hour server sessions).
3. Improve realism incrementally without broad rewrites.

## Current Reality

- The system architecture is complete and running modules exist.
- Studio behavior is still inconsistent in some test setups.
- Most recent user intent: continue from rollback baseline with controlled, minimal changes.

## Checkpoint Commits (2026-02-13)

- `c4058c1` - rollback baseline checkpoint before Phase 3 resume work
- `0a8b2f6` - spawn-cycle failure diagnostics added in `PopulationController` (no spawn logic change)
- `648c267` - animation track cleanup hardened in `NPCAnimator` to prevent pooled-model track buildup
- `78067fc` - handoff risk notes aligned with current diagnostics/cleanup behavior
- `1bbf359` - route-build failure detail now included in spawn stall diagnostics (no spawn logic change)
- `77adc88` - spawn stall warnings now require consecutive no-progress cycles to reduce single-cycle noise
- `dbfa3f7` - social seat reservations now allow 1-seat POIs; dead-end POI/despawn routes can backtrack only when no alternative exists
- `55cca66` - ground-snap raycast ignore logic expanded to whole hit models to prevent NPCs climbing onto players
- `01d75f2` - calmer default walk speed + less rigid group formations (alternating offsets with jitter)
- `b5ce7b6` - staged LOD pipeline added: low-rate updates, frozen mid tier, and far-distance cull
- `9424c8b` - POI handling now checks live tags on node parts and randomizes non-seat POI arrival points within the POI part
- `ea324f4` - spawn attempts now retry alternate spawn-route candidates and increase attempt budget when below minimum population
- `fd3c0a3` - active client NPC models are now parented under `Workspace.WanderingPropsActiveNPCs`
- `c5b821f` - low LOD now reduces animation speed (not movement update rate) and default LOD distance thresholds are higher
- `13281b7` - handoff/state docs updated for POI/spawn/LOD follow-up refinement checkpoints
- `54b5695` - handoff docs synced post-push so latest checkpoint refs stay current
- `c3afac7` - POI traversal now skips intermediate social transit nodes, filters spawn/despawn from POI pool, and uses fallback random social seats
- `f1d26b7` - spawn loop now forces solo recovery attempts while below minimum population
- `31f6824` - LOD re-parenting now keeps NPCs under `Workspace.WanderingPropsActiveNPCs`

## Git Remote

- Repo: `git@github.com:Rebornim/Pipeline.git`
- Branch: `main`
- Latest checkpoint commit on branch: `31f6824`

## Next Validation Focus

1. Run Studio sessions and watch for new spawn-cycle warning output to identify dominant failure reasons.
2. Run an extended soak test (multi-hour) to confirm animation tracks do not accumulate over pooled NPC reuse.

## Notes

- Do not bulk-rewrite modules.
- Prefer isolated patches + immediate validation.
- Keep handoff files current after every major checkpoint change.
