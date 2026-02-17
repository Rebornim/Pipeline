# Pass 8 Redesign Brief (Post-Failure Reset)

## Outcome of Prior Attempt
- Prior Pass 8 build attempt is considered failed and scrapped.
- User-observed failures centered on mode-transition instability, especially scatter:
  - NPC jump/rewind artifacts
  - stale-looking respawn/reappearance during transitions
  - unreliable visual behavior under rapid route/mode churn

## Redesign Goal
Design a simpler, safer Pass 8 focused on server modes that is easy to reason about and hard to break in live playtests.

## Hard Requirements for New Plan
1. Keep server mode transitions deterministic and minimal.
2. Prevent timeline rewrites that can cause route-state rewinds.
3. Define strict sequencing for reroute vs speed changes.
4. Keep testing simple with clear pass/fail markers per mode.
5. Include rollback conditions if any regression appears in existing movement/POI behavior.

## Priority Guidance
- Prefer correctness and predictability over feature richness.
- It is acceptable to reduce scope (for example, simplify scatter behavior) if that removes instability and preserves user-facing quality.
