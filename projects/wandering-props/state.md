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

## Git Remote

- Repo: `git@github.com:Rebornim/Pipeline.git`
- Branch: `main`
- Latest checkpoint commit on branch: `1bbf359`

## Next Validation Focus

1. Run Studio sessions and watch for new spawn-cycle warning output to identify dominant failure reasons.
2. Run an extended soak test (multi-hour) to confirm animation tracks do not accumulate over pooled NPC reuse.

## Notes

- Do not bulk-rewrite modules.
- Prefer isolated patches + immediate validation.
- Keep handoff files current after every major checkpoint change.
