# Pass 2 Handoff: Wandering Props

## Goal
Design `pass-2-design.md` (Points of Interest pass) so it integrates with the implemented Pass 1 baseline without regressions.

## Read First
- `projects/wandering-props/feature-passes.md`
- `projects/wandering-props/idea-locked.md`
- `projects/wandering-props/state.md`
- `projects/wandering-props/pass-1-design.md`

## Current Baseline (Implemented)
- Live code is served from:
- `projects/wandering-props/src/server`
- `projects/wandering-props/src/client`
- `projects/wandering-props/src/shared`
- Rojo project file:
- `projects/wandering-props/default.project.json`
- Legacy/unused code archived in:
- `projects/wandering-props/v3-archive/`
- `projects/wandering-props/v2-archive/`

## Integration Truths You Must Preserve
- Server decides lifecycle/routes/timing; client handles visual model, movement, and animation.
- Runtime remotes and names remain in use:
- `NPCSpawned`
- `NPCDespawned`
- `NPCBulkSync`
- Runtime folders remain in use:
- `ReplicatedStorage/WanderingPropsRemotes`
- `Workspace/WanderingProps/ActiveNPCs`
- Waypoint graph identity is instance-safe (not name-unique dependent).
- `NPCSpawnData` currently includes optional `modelTemplate` (instance) + `modelName` fallback.
- Animation baseline currently tuned with `WalkAnimBaseSpeed = 10`.

## Known Implementation Deltas from Original Pass 1 Doc
- Waypoint nodes support duplicate part names via internal generated IDs.
- Model selection uses a shuffled bag strategy to improve per-NPC visual variation.
- Client resolves model template by `modelTemplate` first, then `modelName` fallback.
- Animation setup:
- Model is parented before loading tracks.
- Uses `Humanoid.Animator` when Humanoid exists, else `AnimationController.Animator`.
- Walk/idle tracks are looped and priorities are explicitly set.

## Pass 2 Design Requirements
- Add POI systems (Scenic, Busy, Social) and route expansion per roadmap.
- Define startup contracts for POI authoring in Studio (parts/attributes/object values/etc).
- Specify data contracts and remotes clearly (new vs existing payload changes).
- Include migration-safe behavior for late join and despawn/fallback flows.
- Include startup validator updates and exact fatal/warn messages.
- Include diagnostics updates and health counters.
- Include golden tests for Pass 2 behavior and failure modes.

## Non-Negotiables
- Do not break existing Pass 1 contracts unless explicitly versioned and justified.
- Do not move live code roots out of `src/`.
- Keep design concrete enough for direct Codex implementation.

## Output
- Produce `projects/wandering-props/pass-2-design.md`.
- Make the design self-contained, implementation-ready, and explicit about file-level changes.
