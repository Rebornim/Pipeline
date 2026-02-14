# V3 Pipeline Plan

## What V3 Fixes

V2 had strong design-time validation (critic reviews, architecture-as-contract) but weak runtime validation. Modules were reviewed in isolation, so cross-module data gaps survived 3 critic reviews. The only way to know if the system worked was staring at it in Studio and guessing. Optimizations were entangled with core behavior, making bugs hard to attribute. Debugging was speculation-based.

V3 keeps what worked (architecture-as-contract, config extraction, phase gates, state.md resume, build order) and adds what was missing (cross-module data tracing, runtime observability, layered builds, deterministic test criteria).

## Changes By Phase

### Phase 2: Architecture

1. **Integration pass.** After all module APIs are designed, trace every piece of data that crosses a module boundary: where it's created, how it's passed, who receives it, where it's stored, when it's cleaned up. This is a single dedicated pass — not per-module, but per-data-flow. This directly prevents the npcId class of bug.

2. **Core/optimization split.** Architecture separates core behavior (the thing the system does) from optimizations (LOD, pooling, culling, caching). Core is designed to work standalone. Optimizations are designed as layers that wrap or enhance core without changing its contracts. Build order reflects this: all core modules first, then optimization modules.

3. **Golden test scenarios.** 3-4 specific test scenarios defined during architecture with exact setup and expected outcomes. Example: "4 spawn points, 2 POIs, 1 despawn zone. Start server. Expect: 4 NPCs spawn within 10s, at least 1 visits POI within 60s, population holds at 4 for 5 minutes." These become the pass/fail criteria in Phase 3.

4. **Diagnostics module designed.** Every system's architecture includes a diagnostics module: lifecycle reason codes, health counters, per-entity action trails. Designed here so Codex builds it first.

5. **Startup validator designed.** Every system's architecture includes a startup validation function that checks workspace contracts (tags, hierarchy, configuration) and fails loud with clear error messages.

### Phase 3: Build

1. **Build order change.** Diagnostics module is built first (step 1). Startup validators built early (step 2 or 3). Then core modules in dependency order. Then optimization modules last. This means diagnostics are available from the first real module test.

2. **Batch independent modules.** If modules have no dependencies on each other, Codex builds them in the same step and Claude reviews them together. Cuts round-trip count.

3. **Core gate.** After all core modules are built and passing golden test scenarios, that's the gate. Only then do optimization modules get built. If core doesn't work, optimizations don't start.

4. **Instrument-first debugging.** When a bug appears during testing, the first response is to check diagnostics output (or add more logging if needed), not to speculatively patch code. Codex instructions enforce this.

5. **One change type per iteration.** During refinement, each Codex interaction is either a bugfix OR a tuning change OR an architecture change. Never mixed. This makes regressions attributable.

### Critic Checklist Additions

1. **Data lifecycle trace.** For every piece of data created by module A and consumed by module B: does A's output type match B's input parameter? Is the data available when B needs it? Is it cleaned up when done? Check this across every module boundary, not within individual modules.

2. **API composition check.** For every call site where module A calls module B: does A pass the right number of arguments? Do the types match? Does A handle B's return value correctly? Verify the modules actually fit together as called, not just as defined.

3. **Startup validation coverage.** Does the startup validator check every workspace contract the system depends on? Any implicit assumption about tags, hierarchy, or configuration that isn't validated is a silent failure waiting to happen.

### Codex Instructions Additions

1. Build diagnostics module first, before any game logic.
2. Build startup validators early.
3. When fixing bugs: read diagnostics output first, instrument if needed, then patch. Never speculative patches.
4. One change type per commit during refinement.
5. Re-read files from disk before every fix (carried over from v2, still critical).

### Refinement Behavioral Gates

Before shipping, these must pass:
- Startup validators pass with zero errors
- All golden test scenarios pass
- Clean play session (length appropriate to system complexity) with no unexplained behavior
- Diagnostics log shows no anomalies (no leaked entities, no accumulating resources, no rejected operations that should succeed)

## What's NOT Changing

- 3-phase structure: Idea → Architecture → Build
- Architecture-as-contract approach
- Config extraction as first-class concern
- state.md resume system
- Phase gates with exit criteria
- Codex builds, Claude reviews
- ACTION-MAP for the human user

## What's Being Removed/Simplified

- No 3 separate critic reviews in Phase 2. One review that includes the integration pass is worth more than 3 that review modules in isolation. Additional passes only if blocking issues are found and fixed.
- Architecture detail level stays precise on APIs and data flows but doesn't need pseudocode for every function body. Codex is good at implementation — it needs exact contracts, not line-by-line translation guides.

## Files To Write/Update

- `pipeline/phases/phase1-idea.md` — Minor updates (golden test scenario seeds)
- `pipeline/phases/phase2-architecture.md` — Integration pass, core/opt split, golden tests, diagnostics/validator design
- `pipeline/phases/phase3-build.md` — New build order, batching, core gate, instrument-first, change-type discipline, behavioral gates
- `pipeline/checklists/critic-checklist.md` — Data lifecycle trace, API composition, startup validation coverage
- `codex-instructions.md` — Diagnostics-first, instrument-before-patch, one-change-type rule
- `CLAUDE.md` — Update to reflect v3 structure
- `ACTION-MAP.md` — Update testing steps to reference golden tests and diagnostics
- `pipeline/templates/architecture-outline.md` — Add sections for diagnostics, startup validators, golden tests, core/opt split
