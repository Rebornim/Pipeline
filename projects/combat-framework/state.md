# Combat Framework — State

## Current Stage: Pass 1 Complete
## Status: Complete

## History
- **Idea:** Locked 2026-02-18. Full system defined in idea-locked.md.
- **Roadmap:** Locked 2026-02-18. 23 passes + optimization. feature-passes.md + project-protocol.md.
- **Pass 1 Design:** Complete 2026-02-18. Core combat loop — turret, blaster projectile, hull HP, hit detection, destruction/respawn, crosshair HUD, faction check.
- **Pass 1 Build:** Complete 2026-02-18. Includes turret aiming/camera iteration, hit/kill feedback, overheat, splash damage, and turret death explosion.

## Context Files
- Read: `feature-passes.md`, `idea-locked.md`, `project-protocol.md`, `pass-1-design.md`, `golden-tests.md`, `state.md`
- Source of truth for current behavior: `src/` code + this file + `golden-tests.md`

## Pass 1 Design Summary
- **Ground turret:** dev-placed, proximity prompt to enter, F to exit
- **Blaster weapon:** math-based projectile, server-authoritative hit detection via spherecast
- **Hull HP:** on turret and target. 0 HP = destroyed. Respawn after config timer.
- **Faction check:** same-faction entities can't damage each other
- **Client visuals:** bolt part along server-provided path, crosshair HUD, HP display
- **Test harness:** 4 automated golden tests (direct hits, friendly fire, destruction/respawn, max range)
- **14 new files** across Shared, Server, Client
- **5 RemoteEvents:** FireWeapon, ProjectileFired, DamageApplied, EntityDestroyed, EntityRespawned
- **Tagging:** CombatEntity, TurretSeat, WeaponMount tags + Faction/ConfigId attributes

### Pass 1 Build Delta
**Built as designed:**
- Server-authoritative turret combat loop is live: seat interaction, projectile simulation, hit detection, hull damage, destruction, and respawn.
- Faction-based damage gating, entity validation, and core remotes are implemented and running through the combat init pipeline.
- Client HUD and projectile visuals are implemented for aiming, hit feedback, health display, and core turret operation.

**Deviations from design:**
- Turret controls and camera behavior were expanded significantly from baseline pass-1 scope (mouse-lag aiming, camera follow tuning, zoom, and firing feedback) based on live iteration feedback.
- Added overheat gameplay, hold-to-fire support, splash damage, turret death explosion damage, and additional local feedback (hitmarker, kill cue, screen shake, heat VFX).
- Added flexible rigging and per-instance tuning via attributes/folder overrides (aim modes, pivot overrides, stat modifiers, bolt color/screen shake modifiers, splash settings, and faction/team usability rules).

**New runtime contracts:**
- Turret models now support attribute-driven weapon modifiers (percent-style stat modifiers plus behavior toggles such as hold-to-fire and splash settings).
- Turret rig supports `TurretRig` folder-driven part groups (`YawOnlyParts`, `PitchOnlyParts`, `YawPitchParts`, `DrivenParts`) with optional per-folder clamp/pivot overrides.
- Visual/audio prefab contracts are now data-driven for muzzle, bolt, impact, fire, overheat, hitmarker, and kill feedback assets.

**Non-blocking follow-ups:**
- Camera onboarding for custom-authored turrets is still sensitive to bad/ambiguous rig authoring; add stricter authoring validator rules and clearer setup guidance in pass 2.
- Review and document a final recommended camera-point authoring contract to reduce first-entry camera mismatch reports.
