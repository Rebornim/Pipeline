# Pass 5 Context (Active)

Date: 2026-02-20
Owner: Codex
Phase: Post-fix stabilization (polish/tuning)

## Current Status
- Working baseline is accepted for ongoing manual playtests.
- Pass 5 is no longer in blocker triage mode; active work is polish/tuning.
- No MCP testing unless explicitly requested by user.

## Confirmed Outcomes
- Speeder movement/camera frame alignment follows authored forward reference.
- Major camera orientation mismatch and severe jitter loops were reduced to a usable baseline.
- Crest/slope/landing regressions were iterated through stabilization.

## Current Crash/Fall Tuning
- `fallDamageThreshold = 80`
- `fallDamageScale = 0.8`
- `collisionDamageThreshold = 60`
- `collisionDamageScale = 1.2`

## Deferred
- Full hull HP collision-damage model (later pass).

## Primary Runtime Files
- `src/Server/Vehicles/VehicleServer.luau`
- `src/Server/Vehicles/HoverPhysics.luau`
- `src/Server/Vehicles/CollisionHandler.luau`
- `src/Client/Vehicles/VehicleCamera.luau`
- `src/Client/Vehicles/VehicleVisualSmoother.luau`
- `src/Shared/CombatConfig.luau`

## Archive
- `archive/pass-5/pass-5-design.md`
- `archive/pass-5/pass-5-fix-plan.md`
- `archive/pass-5/pass-5-critic-report.md`
- `archive/pass-5/pass-5-debug-log.md`
- `archive/pass-5/pass-5-claude-handoff.md`
- `archive/pass-5/pass-5-claude-critic-prompt.md`
