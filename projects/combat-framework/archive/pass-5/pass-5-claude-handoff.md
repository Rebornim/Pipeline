# Pass 5 Speeder Polish Handoff (Codex -> Claude)

Date: 2026-02-20  
Owner: Codex  
Status: Stabilized baseline achieved; now in polish/tuning

## Current Outcome
- The severe pass-5 blockers are no longer the active state for this branch.
- User-confirmed baseline is now testable and usable for further iteration.
- We are moving from stabilization into polish (feel + tuning), not from scratch rebuild.

## What Was Completed
- Forward movement and camera frame alignment now use the authored forward reference path.
- Camera orientation mismatch and major jitter loops were iterated down to a usable baseline.
- Crest/slope/landing regressions went through multiple rounds of fixes during stabilization.
- Fall and collision damage thresholds were tuned to reduce short-fall instant explosion behavior:
  - `fallDamageThreshold = 80`
  - `fallDamageScale = 0.8`
  - `collisionDamageThreshold = 60`
  - `collisionDamageScale = 1.2`

## Deferred / Next Focus
- Hull HP collision-damage model is intentionally deferred for a later pass.
- Next pass should focus on polish targets the user chooses (camera feel, movement feel, impact feel), not architecture churn.

## Files To Read First
- `projects/combat-framework/state.md`
- `projects/combat-framework/pass-5-debug-log.md`
- `projects/combat-framework/pass-5-critic-report.md` (history/context)
- `projects/combat-framework/src/Server/Vehicles/VehicleServer.luau`
- `projects/combat-framework/src/Server/Vehicles/HoverPhysics.luau`
- `projects/combat-framework/src/Server/Vehicles/CollisionHandler.luau`
- `projects/combat-framework/src/Client/Vehicles/VehicleCamera.luau`
- `projects/combat-framework/src/Client/Vehicles/VehicleVisualSmoother.luau`
- `projects/combat-framework/src/Shared/CombatConfig.luau`

## Operating Constraints
- No MCP testing unless the user explicitly requests it.
- Keep changes small and mechanical per user-selected polish target.
