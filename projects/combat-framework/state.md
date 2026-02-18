# Combat Framework — State

## Current Stage: Pass 1 Build
## Status: Ready

## History
- **Idea:** Locked 2026-02-18. Full system defined in idea-locked.md.
- **Roadmap:** Locked 2026-02-18. 23 passes + optimization. feature-passes.md + project-protocol.md.
- **Pass 1 Design:** Complete 2026-02-18. Core combat loop — turret, blaster projectile, hull HP, hit detection, destruction/respawn, crosshair HUD, faction check.

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
