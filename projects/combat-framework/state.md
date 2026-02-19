# Combat Framework — State

## Current Stage: Pass 4 Design
## Status: Ready

## History
- **Idea:** Locked 2026-02-18. Full system defined in idea-locked.md.
- **Roadmap:** Locked 2026-02-18. 23 passes + optimization. feature-passes.md + project-protocol.md.
- **Pass 1 Design:** Complete 2026-02-18. Core combat loop — turret, blaster projectile, hull HP, hit detection, destruction/respawn, crosshair HUD, faction check.
- **Pass 1 Build:** Complete 2026-02-18. Includes turret aiming/camera iteration, hit/kill feedback, overheat, splash damage, and turret death explosion.
- **Pass 2 Design:** Complete 2026-02-18. Shield system — shield HP layer, damage absorption with overflow, regen, distinct shield/hull impact VFX+audio, HUD shield bar.
- **Pass 3 Design:** Complete 2026-02-19. Damage types + ammo — 5 damage types with shield/hull/bypass multipliers, finite ammo system, 4 new weapon/entity configs, HUD ammo counter.
- **Pass 3 Build:** Complete 2026-02-19. Damage-type combat behaviors and finite ammo shipped with weapon-specific presentation and live tuning updates.

## Context Files
- Read: `feature-passes.md`, `idea-locked.md`, `project-protocol.md`, `pass-1-design.md`, `pass-2-design.md`, `pass-3-design.md`, `golden-tests.md`, `state.md`
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

### Pass 2 Build Delta
**Built as designed:**
- Shield HP layer is implemented as an optional config-driven health layer with shield-first absorption and overflow to hull.
- Shield regen is implemented server-side with per-entity delay/rate plus default fallback, and shield state is replicated via model attributes/remotes.
- Shield vs hull impact routing is implemented (impactType propagation), with distinct shield VFX/audio hooks and hull fallback behavior.
- Shield HUD support is implemented for seated turret operators, including shield bar visibility and live updates.

**Deviations from design:**
- Shield feel was tuned based on playtesting feedback: `shielded_turret` now uses a stronger/slower profile (`shieldHP=140`, `shieldRegenRate=8`, `shieldRegenDelay=5`).
- Added shield-break signaling (`shieldBroken`) and client-side shield-break audio routing to improve readability at depletion moments.
- Enabled `FriendlyFireEnabled = true` temporarily to support turret-vs-turret test sessions.
- Added out-of-scope combat polish requested during pass execution: turret death explosion SFX/VFX/camera-shake tuning, explosion payload radius/position replication, seat/proximity lockout fixes while destroyed, seat invisibility preserved on respawn, and replicated world overheat smoke/sound for non-operators.

**New runtime contracts:**
- Combat assets now include additional optional folders used by runtime routing: `ReplicatedStorage.CombatAssets.ImpactParticles.shieldHit`, `ReplicatedStorage.CombatAssets.ImpactParticles.turretExplosion`, `ReplicatedStorage.CombatAssets.Audio.ShieldImpact`, `ReplicatedStorage.CombatAssets.Audio.ShieldBreak`, and `ReplicatedStorage.CombatAssets.Audio.Explosion` (with fallback behavior where implemented).
- `EntityDestroyed` payload now supports structured fields (`entityId`, `explosionPosition`, `explosionRadius`) and clients consume these for destruction presentation.
- Turret seat visibility contract changed: tagged `TurretSeat` instances remain invisible through destroy/respawn restore paths.
- Remote clients now render world-space overheat feedback for overheated turrets based on replicated `WeaponOverheated` state.

**Non-blocking follow-ups:**
- Replace fallback/placeholder shield and explosion assets with final authored audio/particle content.
- Decide whether `FriendlyFireEnabled` should remain globally enabled or move to a dedicated test-only toggle path before wider playtests.
- Pass 3 should formalize damage-type behavior against shields/hull now that the shield baseline is stable.

### Pass 3 Build Delta
**Built as designed:**
- Damage-type multipliers are implemented server-side for shield/hull/bypass behavior (`blaster`, `turbolaser`, `ion`, `proton_torpedo`, `concussion_missile`) and applied during hit resolution.
- Finite ammo is implemented for configured weapons with server-authoritative decrement, empty-fire denial, HUD ammo display updates, and ammo reset on lifecycle restore.
- New combat loadouts are live via config (`turbolaser_turret`, `ion_turret`, `torpedo_turret`, `missile_turret`) and wired into existing turret flow.

**Deviations from design:**
- Added `blaster_turret_burst` as an actively playable config variant and tuned its overheat behavior to sustain burst-fire longer (`heatPerShot=4`, `heatDecayPerSecond=10`, `heatRecoverThreshold=45`).
- Added per-damageType projectile presentation tuning (distinct fire SFX routing and visual profiles for bolt/trail/light/impact scaling) so weapon families feel materially different during playtests.
- Retuned long-range combat values based on battlefield feel feedback (notably higher `maxRange` and projectile speeds across weapon classes) beyond initial pass-3 baseline.
- Client reticle probing was changed to segmented `Raycast` logic (1024-stud chunks) to avoid Roblox shapecast distance-limit spam when using long-range weapons.

**New runtime contracts:**
- `ProjectileFired` payload now carries optional `damageType` for client-side weapon-family presentation routing.
- Optional typed fire audio contract: `ReplicatedStorage.CombatAssets.Audio.Fire.<damageType>` (Sound or Folder containing a Sound) with fallback to shared `Audio.Fire`.
- Current long-range weapon baselines are now: blaster/burst `900`, ion `900`, turbolaser `1800`, torpedo `1600`, missile `1400` studs.

**Non-blocking follow-ups:**
- Validate large-map TTK/travel-time feel with multi-client playtests and tune per-weapon range/speed further if needed.
- Replace temporary pass-tagged diagnostics (`[P1_*]`, `[P2_*]`, `[P3_*]`) with final gated diagnostics policy once feature stabilization is complete.
- Pass 4 should formalize lock ranges as a strict subset of weapon ranges after this long-range retune.
