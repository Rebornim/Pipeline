# V3 Pipeline Design Context

This file provides background for the Claude conversation designing v3 of the pipeline. Read this before the user gives you the feedback messages.

## What This Pipeline Is

A structured development pipeline for Roblox game systems using two AI models:
- **Claude (Opus 4.6):** Idea validation, technical architecture, code review, critic
- **Codex CLI (GPT 5.3):** Code implementation (the builder)

The human user has minimal Luau/Roblox scripting knowledge. The AI models carry the technical burden. The user orchestrates, tests in Roblox Studio, and tunes Config values.

## Pipeline History

### V1 (see `reference/pipeline-overview.md` for full spec)
- **4-phase pipeline:** Idea → Architecture → Prototype → Production.
- Successfully produced a more complex Roblox system (more features, more complex pathfinding).
- The system worked reliably in Studio.

### V2 (current — what you're reading in the pipeline files)
- More structured: 3-phase pipeline (Idea → Architecture → Build), critic checklist, codex-instructions.md, state.md resume system, ACTION-MAP.md.
- Architecture-as-contract approach: ~1100-line architecture outline with exact API signatures, type definitions, data flows, pseudocode, config extraction.
- 3 critic reviews on the architecture before building.
- Despite all this structure, the resulting system (wandering-props — ambient NPCs) was LESS reliable than the v1 system. Core bugs persisted through refinement: NPCs getting deleted at POIs, cross-module data lifecycle gaps, topology validation failures.

## What V2 Got Right (preserve in v3)

1. **Architecture-as-contract.** Codex follows a validated blueprint, not vibes. Every review was mechanical: does code match spec?
2. **Phase gates.** Idea → Architecture → Build with clear exit criteria.
3. **state.md resume system.** Any AI can pick up mid-phase with zero ambiguity.
4. **Config extraction.** Every tunable value externalized with comments and ranges. User fixes "feels off" problems without AI tokens.
5. **Build order.** Dependency-sequenced mechanic-by-mechanic building.
6. **Critic checklist.** Structured review rubric (security, performance, Roblox best practices, maintainability).
7. **Codex instructions with Claude checkpoints.** Builder AI knows when to stop and send user to reviewer AI.

## What Happened With V2

These are observations, not conclusions. The feedback messages will provide more detail.

1. Critic reviews verified the design was correct. Runtime behavior was validated only through manual Studio testing.
2. Modules were designed and reviewed in isolation. Data flowing across module boundaries was not traced end-to-end. A cross-module data lifecycle gap (npcId) survived 3 critic reviews.
3. When runtime bugs appeared (NPCs deleted at POIs), debugging relied on code patching rather than instrumentation/logging.
4. The workspace setup (tagged Parts, ObjectValue connections, seat ancestry) has implicit contracts that fail silently when violated. No startup validation existed.
5. The architecture included LOD (3 tiers), frustum culling, model pooling, time-based seat reservations, and group follower offsets. These were all architected and built alongside core functionality.
6. Bugfixes, tuning, and architecture changes occurred in the same passes during refinement.
7. A 64-track animation accumulation bug only appeared after extended sessions.

## What The 3 Feedback Messages Cover

The user will give you 3 feedback messages from AI conversations that participated in v2:
1. **Builder AI feedback** — focuses on state management, lack of automated safety nets, mixed change types, long-session blind spots, checkpoint discipline.
2. **Reviewer AI feedback** — focuses on cross-module contract gaps, API composition verification, architecture detail level vs scalability, data lifecycle tracing.
3. **Debugging AI feedback** — focuses on lack of runtime evidence, hidden topology contracts, patch-first vs instrument-first debugging, need for golden test maps and hard release gates.

All three converge on the same core issue: strong design-time validation, weak runtime validation.
