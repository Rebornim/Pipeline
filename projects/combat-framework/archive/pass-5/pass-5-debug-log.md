# Pass 5 Debug Log (Stabilization)

## Scope
- This log tracks iterative fixes after initial Pass 5 build failure.
- Focus areas: steering frame alignment, camera stability, hover/slope behavior, crest/drop transitions, local visual smoothing.

## Major Changes Landed
- Heading/forward alignment:
  - Vehicle heading initialized from `ForwardRef` attachment axis on registration.
  - Server movement uses heading-based forward; camera yaw now uses replicated `VehicleHeading`.
- Camera:
  - Reworked to smoother rate-limited follow model.
  - Added collision-distance smoothing and reduced hard clamp behavior.
  - Camera now tracks render-smoothed vehicle model in vehicle mode.
- Visual smoothing:
  - Added vehicle visual clone interpolation.
  - Added rider visual clone flow and source-character hiding.
  - ForceField handling fixed to avoid duplicate spawn bubbles.
- Hover physics:
  - Lift uses probe-lifted raycasts from hover points.
  - Spring force is support-only (no negative spring force pulling down).
  - Force averaging uses grounded supports to avoid partial-contact launch spikes.
- Slope/terrain behavior:
  - Added climb speed limiting and too-steep rollback handling.
  - Added terrain sweep resolution before final movement apply.
  - Added crest/drop detection and downhill release path.
  - Obstacle filtering updated to reduce false frontal blocks on descending transitions.

## Current Status
- Previous pass-5 blockers are no longer tracked as active blockers for this branch.
- System is now in polish mode (camera feel + movement tuning), not root-cause stabilization mode.
- Manual user verification is the active acceptance signal unless MCP testing is explicitly requested.

## 2026-02-20: Terrain-Intent Refactor Landed
- `VehicleServer.stepSingleVehicle` now routes movement through one explicit intent each tick:
  - `NormalDrive`
  - `BlockedClimb`
  - `CrestRelease`
- Added sticky crest-release timer usage (`crestReleaseUntil`) as a stateful transition aid instead of ad-hoc booleans.
- Replaced repeated throttle/accel blocks with shared `computeTargetSpeed(...)` helper for deterministic speed resolution.
- Post-step normalization now respects intent:
  - post-ground vertical clamp/slope limit only in `NormalDrive`
  - hover clearance assist only in `BlockedClimb`
  - crest release enforces gravity-dominant vertical behavior (prevents lip lock)
- This change removes the previous multi-writer conflict where downhill transition, climb rollback, and post-ground clamps could all fight over velocity in a single frame.

## 2026-02-20: Crest + Climb Follow-up Tuning
- Crest release entry broadened:
  - Added `oversteepDownhill` trigger (`downhillAlignment + over-max slope`) to force `CrestRelease` even when crest-drop probe is ambiguous.
  - Extended crest release timer window to 0.3s for cleaner crest exit continuity.
- Terrain sweep downhill bypass relaxed for valid downhill continuation:
  - Increased tolerated positive vertical speed during cresting.
  - Lowered ahead-drop threshold and added terrain-shape guards to avoid wall pass-through.
- Climb sink regression addressed:
  - Reintroduced clearance assist during steep active climbs in `NormalDrive` (not only `BlockedClimb`).
  - Kept clearance assist disabled in `CrestRelease` to preserve gravity-dominant descent.
- Obstacle collision decoupling:
  - `CollisionHandler.checkObstacles` now ignores terrain-like normals (`Normal.Y > 0.08`), so steep ground transitions are handled by movement intent/sweep instead of frontal collision braking.

## 2026-02-20: Landing Anti-Phase + Priority Fixes
- Terrain sweep drop-off bypass now only applies when travel is not strongly downward (`travelDir.Y` gates), preventing cliff-fall ground hits from being skipped.
- Sweep drivable-slope bypass tightened (`maxClimbSlope + 4`, plus explicit hit slope check) so too-steep uphill contact resolves instead of being treated as pass-through terrain.
- Crest intent priority updated so `crestCandidate` now wins over `BlockedClimb` when drop-ahead + forward-carry are present.
- Climb clearance assist strengthened (earlier slope trigger, higher floor, slightly larger correction) to reduce uphill sink and phase-through risk.

## 2026-02-20: Escalation Handoff Prepared
- Created detailed handoff dossier for Claude + critic workflow:
  - `pass-5-claude-handoff.md`
- Created copy-paste prompt to request critic analysis + technical outline:
  - `pass-5-claude-critic-prompt.md`

## 2026-02-20: Critic 6-Step Plan Implemented + Verified
- Implemented Step 1 -> Step 6 in strict order from `pass-5-critic-report.md`.
- Added server-side verification harness:
  - `src/Server/TestHarness/Pass5_CriticVerify.luau`
  - Runner routing via `Workspace.P5CriticVerifyEnabled` in `src/Server/TestHarness/Runner.luau`
- Verification procedure after each step:
  - Enabled `Workspace.CombatTestHarnessEnabled = true`
  - Enabled `Workspace.P5CriticVerifyEnabled = true`
  - Ran playtest once and read `[P5_CRIT]` + `[P5_CRIT_SUMMARY]`
- Outcome after every step (1 through 6):
  - `crest_lock`: FAIL (`crossed=false`)
  - `uphill_sink`: FAIL (`void=true`)
  - `cliff_landing`: FAIL (`air=true, land=true, void=true`)
  - `stop_on_uphill`: FAIL (`void=true`)
  - Summary: `[P5_CRIT_SUMMARY] result=FAIL scenarios=4`

## 2026-02-20: Post-Critic Manual Iteration Outcome
- Additional non-critic iteration continued after the strict 6-step sequence.
- User confirmed working baseline after these follow-up fixes (camera/orientation/hover movement no longer in failed state for active testing).
- This supersedes the "all four fail" snapshot above as the current branch status for day-to-day development.

## 2026-02-20: Crash/Fall Damage Tuning Pass
- Applied config-only tuning to reduce short-fall and moderate-impact instant explosions:
  - `fallDamageThreshold = 80`
  - `fallDamageScale = 0.8`
  - `collisionDamageThreshold = 60`
  - `collisionDamageScale = 1.2`
- Deferred by user for later:
  - Add full hull HP collision-damage integration model.

## Files Most Likely To Change Next
- `src/Server/Vehicles/VehicleServer.luau`:
  - crest detection thresholds/timer window tuning (`crestReleaseUntil`)
  - blocked-climb rollback strength tuning
  - intent-specific vertical clamps (normal vs crest release)
- `src/Server/Vehicles/CollisionHandler.luau`:
  - descending transition obstacle ignore thresholds
- `src/Server/Vehicles/HoverPhysics.luau`:
  - only if suspension response regresses after crest changes

## Testing Notes
- Manual in-Studio testing only unless user explicitly requests MCP testing.
- Core repro map shape: uphill ramp to sharp crest into steep downhill triangle face.
