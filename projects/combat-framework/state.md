# Combat Framework — State

## Current Stage: Pass 9 Design Complete — Ready to Build
## Status: Pass 9 (Walker Combat) designed. Walker gets chin blaster weapon, head CFrame tracking for muzzle origin, client fire input + HUD. Reuses existing vehicle weapon pipeline — no changes to WeaponServer, HealthManager, ProjectileServer.

### Pass 9 Build Delta
**Built as designed:**
- Walker combat is active on `walker_biped` with driver-fired chin weapon through existing `FireWeapon`/`UpdateTurretAim` remotes.
- Walker head/chin weapon rig follows the moving head transform correctly and supports lock-on and weapon HUD/crosshair flow while piloting.
- Walker model authoring now includes physical chin turret geometry with two muzzle-capable barrel mounts under the head.

**Deviations from design:**
- Walker weapon was tuned to a click-fired 2-shot burst pair (`burst_projectile`) with configurable intra-burst delay and cooldown behavior.
- AT-ST weapon tuning expanded beyond baseline: red bolts, splash radius added/increased, louder walker fire audio, and shield layer removed from walker entity config.
- Added RMB aim behavior on walkers (zoom vignette + FOV push-in) and additional smoothing passes for zoom/FOV and crosshair movement to remove jitter/choppiness.
- Multiple iterative UX/combat polish fixes were applied during live playtest feedback (horizontal-only cursor recentering, overlapping burst audio timing, turret/head local follow fixes).

**New runtime contracts:**
- `walker_chin_blaster` now uses burst + splash parameters (`weaponClass = "burst_projectile"`, `burstCount`, `burstInterval`, `splashRadius`, `boltColor`).
- `WeaponSounds.walker.fireVolume` is now explicitly authored and used for walker fire loudness tuning.
- `VehicleCamera` now supports `setExternalFOVOffset(offset)` for feature-specific camera FOV offsets without direct camera-write contention.
- `walker_biped` entity config no longer includes shield stats; walkers are hull-only.

**Non-blocking follow-ups:**
- Pass 9.5 should focus on bugfix stabilization for walker edge cases and remaining regressions across adjacent passes.
- Validate final walker combat feel in multi-user scenarios (crosshair smoothness under latency, burst audio perception, splash balance).

### Pass 5 Stabilization Build Delta (2026-02-22, emergency builder mode)

**Critical bugs fixed:**
- **Slope system was entirely broken:** `uphillDirection` used raw `averageNormal.X/Z` (points downhill) instead of negated (points uphill). `BlockedClimb` never triggered, slope speed penalties applied to wrong direction, CrestRelease fired going uphill instead of downhill. Fixed by negating horizontal normal components in both `stepSingleVehicle` and `applySlopeLimit`.
- **Client attribute name mismatch:** VehicleClient.luau and RemoteVehicleSmoother.luau read `VehicleConfigId` (old name) instead of `VehicleCategory` (new name). Vehicles wouldn't initiate when player sat in driver seat. Fixed with VehicleCategory-first fallback in both files.
- **Client never applied attribute modifiers:** `resolveVehicleConfig` only existed server-side. Client read raw base configs, so `VehicleCameraDistanceMod`, `VehicleMaxSpeedMod`, and all other percentage modifiers were ignored client-side. Fixed by duplicating full resolver to VehicleClient.
- **Heavy vehicles could A/D lean:** Client input gathering read A/D lean keys without checking `leanEnabled`. Server blocked it but client still sent input. Fixed by wrapping lean input in `leanEnabled` check.
- **Tilt conformity had pitch/roll swapped:** `rollAmount = averageNormal:Dot(tiltForward)` measured the pitch component (forward projection), not roll. Code removed pitch and preserved roll — opposite of intent. Fixed by computing `tiltRight = tiltForward:Cross(Vector3.yAxis)` and using `averageNormal:Dot(tiltRight)` for actual roll measurement.
- **Bank axis wrong for non-default forward axes:** `attachmentRollAxisLocal = forwardAxisLocal` caused bank rotation around wrong axis for ForwardAxis = "X", "Z", or ForwardYawOffset models. Fixed to always use `Vector3.new(0, 0, -1)` (CFrame.lookAt local forward).
- **Flat-ground vertical bobbing:** Hard velocity dead zone (`abs < 2 → 0`) prevented hover springs from making micro-corrections while moving, causing error accumulation then snap correction. Replaced with smooth frame-rate-independent exponential damping (`math.exp(-12 * dt)` upward, `math.exp(-6 * dt)` downward).

**Features added:**
- **ForwardYawOffset attribute:** Number attribute (degrees from local -Z) for vehicles with non-axis-aligned forward directions. Overrides ForwardAxis string. Computes `forwardAxisLocal` via `Vector3.new(math.sin(rad), 0, -math.cos(rad))`. Added to VehicleServer registration and StartupValidator.
- **RemoteVehicleSmoother maxSpeed modifier:** `getMaxSpeedForModel` now applies `VehicleMaxSpeedMod` for correct remote vehicle sound pitch.

**Config changes:**
- Heavy vehicle `terrainConformity`: 0.1 → 1.0 (full terrain conformity on both pitch and roll).

**Documentation added:**
- `attribute-reference.md`: Comprehensive standalone reference for all combat framework attributes (vehicles, turrets, artillery, moving target controller) with types, examples, base values.
- `vehicle-idea-locked.md`: Expanded attribute modifier section with detailed types and examples.

**Files modified:**
- `src/Server/Vehicles/VehicleServer.luau` — uphillDirection fix, ForwardYawOffset, rollAxis, tilt conformity fix, smooth vertical damping
- `src/Client/Vehicles/VehicleClient.luau` — VehicleCategory fallback, resolveVehicleConfig, lean gating
- `src/Client/Vehicles/RemoteVehicleSmoother.luau` — VehicleCategory fallback, maxSpeed modifier
- `src/Server/Authoring/StartupValidator.luau` — ForwardYawOffset validation
- `src/Shared/CombatConfig.luau` — heavy terrainConformity = 1.0

### Sound System + Artillery Polish Build Delta (2026-02-23, emergency builder mode)

**Weapon sound system expanded:**
- Added 4 new weapon sound groups to `CombatConfig.WeaponSounds`: `eweb` (4 fire variations), `torpedo` (2 fire + whiz), `missile` (fire + whiz), `turret` (fire)
- Impact sounds added to ALL groups: ion, turbolaser, artillery (vehicle explosion sound), eweb (2 old blaster hit sounds, layered), torpedo, missile, turret
- `fireVolume` per-group override (artillery = 1)
- Rotating sound pool: 6 pre-created Sound instances per variation, random selection (`math.random`). Eliminates per-fire `Instance.new` latency while supporting overlap.
- Burst-class-aware scheduling: only `EffectiveWeaponClass == "burst_projectile"` gets burst sound scheduling (was incorrectly applying to all weapons due to `DEFAULT_BURST_COUNT = 3`)
- `resolveAllGroupSounds()`: returns ALL entries in a list for impact sound layering (eweb plays both hit sounds together). `resolveGroupSound()` still picks one randomly for fire variation.
- Bolt metadata retention: `destroyBolt` keeps `activeBolts` entry alive for 2 seconds via `task.delay` so impact handler can read `fireSound` after visual destruction.

**Sound rolloff and reverb tuning:**
- Whiz: `Looped = true`, `InverseTapered` rolloff min 100/max 1200, reverb removed (moving sound makes static reverb wrong)
- Fire: `InverseTapered` rolloff min 60/max 1000
- Impact/explosion: `InverseTapered` rolloff min 10/max 2100 (fast drop + long tail so artillery shooter can hear distant impacts faintly)
- Reverb range: start 100, max 900

**Impact VFX + sound merged:**
- `spawnImpactEffect` returns the effectPart. `playImpactSoundAt` accepts optional parentPart to share the Part and avoid creating duplicate instances.

**Vehicle gunner sound activation:**
- `RemoteVehicleSmoother.luau`: added `hasAnyOccupant()` that checks all seats INCLUDING local player. Previously `findSeatedCharacters()` excluded local player, so a lone gunner (no driver) got no engine sound.

**Artillery improvements:**
- Ammo/overheat checks added to `onFireAction` — no more firing sound when empty or overheated
- Freelook changed from hold-based (ALT held) to toggle-based (ALT press toggles). WASD still adjusts aim during freelook. HUD updates, driven parts, and aim server sync all function during freelook.

**Studio cleanup (via MCP):**
- Deleted `ReplicatedStorage.CombatAssets.Audio.Impact` (old, replaced by config-driven system)
- Deleted `ReplicatedStorage.CombatAssets.Audio.ShieldImpact` (old, replaced by config-driven system)
- Deleted `ReplicatedStorage.CombatAssets.Audio.Fire` (old, replaced by config-driven system)
- Deleted `ProjectileTemplate.Bolt.Whiz` (old baked-in whiz, replaced by config-driven system)

**Files modified:**
- `src/Client/Vehicles/RemoteVehicleSmoother.luau` — hasAnyOccupant for gunner sound activation
- `src/Shared/CombatConfig.luau` — 4 new sound groups, impact sounds on all groups, fireVolume
- `src/Client/Projectiles/ProjectileVisuals.luau` — rotating pool, resolveAllGroupSounds, bolt metadata retention, rolloff/reverb tuning, impact VFX+sound merge
- `src/Client/Weapons/WeaponClient.luau` — rotating pool, random selection, burst-class-aware scheduling
- `src/Client/Vehicles/VehicleClient.luau` — rotating pool, random selection
- `src/Client/Weapons/ArtilleryClient.luau` — rotating pool, random selection, ammo/overheat checks, freelook toggle

### Pass 8 Build Delta (2026-02-24, emergency builder mode)

**Built as designed:**
- Separate WalkerServer.luau with WASD+mouse body movement, gravity, slope blocking, fall damage, replication state machine (Active/Settling/Dormant)
- WalkerClient.luau with input gathering, activation/deactivation, camera, head rotation
- WalkerIK.luau as pure computation module — foot placement, step animation, 2-bone IK solver, body secondary motion
- RemoteVehicleSmoother integration for remote walker IK
- StartupValidator walker-specific checks (WalkerHead, WalkerHip, leg structure)
- CombatInit routing for walker registration, destroy/respawn callbacks
- VehicleClient walker class routing
- Config + types (walker_biped vehicle config, WalkerRuntimeState type, VehicleInputPayload extensions)

**Major deviations from design:**
- **3-segment legs with strut suspension:** Design specified simple hip-to-foot 2-bone IK. Build added pivoting strut system (Strut1 rigid from body at configurable pitch/spread, Strut2 pivoting to hip constrained at strutLength). Much more realistic AT-ST leg geometry.
- **Server-side gait oscillator:** Design specified client-side distance-based step triggers only. Build added server gait oscillator (sinusoidal speed profile, halfCycleDuration, gaitSide alternation) replicated via attributes. Client uses gait side changes as primary step trigger, with distance-based fallback for idle/no-driver.
- **Sprint system:** Not in design. Added sprint with separate config values for speed (62.5), stride lead (12), bob (3), sway (10), step height (7), half-cycle (0.42s), forward lean (12°), gait min speed fraction (0.6). Sprint step fraction 92% (brief ground contact vs walk's 70%).
- **Extensive body secondary motion:** Design had basic bob/sway/lean/jolt. Build added: sway as spring-damper with impulse (not lerp), figure-8 lobe push, sway-induced torso roll, servo vibration (Perlin noise), idle breathing, sprint forward lean, terrain tilt from foot height difference.
- **Sound profile:** Engine loops (interior short rolloff + exterior long rolloff, both Looped=true with LoopRegion), 4 random footstomps on plant, head turn loop/stop sounds, startup/shutdown, wall collision stuck sound. Uses `walker_biped.luau` sound profile loaded by SoundProfileLoader.
- **Config values heavily retuned:** walkHeight 15 (vs 12), leg lengths 9/9 (vs 6/6), sway 14.0 (vs 0.4), bob 4 (vs 0.3), stride lead 10/12 (vs design baseline), camera 37.5/18 (vs 25/12), maxSpeed 22 (vs 25), plus ~30 additional config keys for struts, sprint, and secondary motion.

**Polish and fixes applied during build:**
- **Gait-based home offset:** Foot homes zero when idle, full when walking. Prevents feet resting too far forward when stopped.
- **First-step trigger system:** Two-layer trigger (pre-gait velocity detection + gait activation transition) with `forceFirstStep()` helper that uses half-stride lead.
- **Two-shot idle pose:** On exit, IK runs once immediately (fresh state, no residual motion), then again 3 seconds later after server settles. Eliminates permanent head tilt after dismount.
- **Client character smoothing:** HRP anchored while seated, CFrame applied from smoothed torsoCF each render frame via stored offset. Prevents 60Hz character replication bandwidth and ensures smooth rider movement.
- **Network optimization:** Removed per-frame individual child part CFrame writes during active walking. PrimaryPart cascade (20Hz) handles cockpit children, client IK handles legs. Saves ~25 KB/s recv.
- **Engine loop fix:** Changed from manual crossfade (Looped=false) to Looped=true with LoopRegion trim. Eliminates sound gaps from missed crossfade windows during lag.
- **Hip absorption for IK overextension:** When body bob raises hip beyond IK chain reach, hip is pulled DOWN toward foot (simulating strut compression). Prevents leg stretching without causing ground-level bobbing.

**New runtime contracts:**
- Walker attributes: `WalkerGaitPhase` (number), `WalkerGaitSide` (string "left"/"right"), `WalkerGaitActive` (boolean), `WalkerAimYaw` (number radians), `WalkerSprintFrac` (number 0-1). Written by server on discrete changes.
- Walker tags: `WalkerHead` (BasePart), `WalkerHip` (Attachment x2), `DriverSeat` (Seat), leg folders with `UpperLeg`/`LowerLeg`/`Foot` parts. Leg parts reparented to Workspace Folder at runtime (freed from PrimaryPart cascade).
- Strut tags: `WalkerStrut1Left`/`WalkerStrut1Right`/`WalkerStrut2Left`/`WalkerStrut2Right` (BaseParts for visual strut segments).
- Sound profile: `SoundProfiles/walker_biped.luau` exports `createController(sourceModel, targetPart, maxSpeed, isLocal)`.

**Known issues (deferred):**
- Water interaction: walker entering water causes ejection + flatten + despawn. Ground detection raycasts through water surface. Needs water detection or swim-mode for future pass.
- Intermittent leg stretch during terrain loading / lag spikes (IK chain limit reached briefly). Cosmetic, resolves within 1-2 step cycles.

**Files created:**
- `src/Server/Vehicles/WalkerServer.luau`
- `src/Client/Vehicles/WalkerClient.luau`
- `src/Client/Vehicles/WalkerIK.luau`
- `src/Client/Vehicles/SoundProfiles/walker_biped.luau`

**Files modified:**
- `src/Shared/CombatConfig.luau` — walker_biped vehicle + entity config, WalkerSounds
- `src/Shared/CombatTypes.luau` — WalkerRuntimeState, VehicleInputPayload extensions
- `src/Server/CombatInit.server.luau` — walker registration, destroy/respawn routing
- `src/Server/Authoring/StartupValidator.luau` — walker validation (skip HoverPoint, require walker tags)
- `src/Client/Vehicles/RemoteVehicleSmoother.luau` — remote walker IK, two-shot idle pose, head rotation
- `src/Client/Vehicles/VehicleClient.luau` — walker class routing to WalkerClient
- `src/Client/Vehicles/VehicleCamera.luau` — walker camera support
- `src/Client/HUD/CombatHUD.luau` — speed display for walkers

## History
- **Idea:** Locked 2026-02-18. Full system defined in idea-locked.md.
- **Roadmap:** Locked 2026-02-18. Originally 23 passes. Revised 2026-02-19 (see below).
- **Pass 1 Design:** Complete 2026-02-18. Core combat loop — turret, blaster projectile, hull HP, hit detection, destruction/respawn, crosshair HUD, faction check.
- **Pass 1 Build:** Complete 2026-02-18. Includes turret aiming/camera iteration, hit/kill feedback, overheat, splash damage, and turret death explosion.
- **Pass 2 Design:** Complete 2026-02-18. Shield system — shield HP layer, damage absorption with overflow, regen, distinct shield/hull impact VFX+audio, HUD shield bar.
- **Pass 3 Design:** Complete 2026-02-19. Damage types + ammo — 5 damage types with shield/hull/bypass multipliers, finite ammo system, 4 new weapon/entity configs, HUD ammo counter.
- **Pass 3 Build:** Complete 2026-02-19. Damage-type combat behaviors and finite ammo shipped with weapon-specific presentation and live tuning updates.
- **Pass 4 Design:** Complete 2026-02-19. Targeting system — lock-on flow, auto-aim with lead prediction, torpedo requires lock, missile homing, turret arc/exposure config, 4 golden tests.
- **Pass 4 Build:** Complete 2026-02-19. Full lock-on targeting flow, auto-aim with spread, homing missiles, enclosed turret protection, lock-loss UX cues.
- **Pass 5 Design:** SCRAPPED 2026-02-19. Bolt-on vehicle approach abandoned — existing vehicle system not worth using.
- **Vehicle Idea:** Locked 2026-02-19. Custom vehicle system defined in vehicle-idea-locked.md. Shares architecture with ships. 4 vehicle classes (light speeder, heavy speeder, biped walker, quad walker). Hover physics, IK legs, CFrame-based movement.
- **Roadmap Revision:** Complete 2026-02-19. Passes 5+ rebuilt for custom vehicle system. Walker split (pass 7 movement, pass 8 combat). Animated parts moved to pass 11 (before landing). 25 passes + optimization. AT-AT/AT-ST not configured during development — system supports walkers generically.
- **Roadmap Revision 2:** 2026-02-21. Artillery emplacement added as pass 7 (indirect fire, parabolic projectiles, WASD aiming). Passes 7+ renumbered (+1). Walkers now passes 8-9, fighters 10-11, etc. 26 passes + optimization.
- **Pass 5 Design:** Complete 2026-02-19. Speeder movement — CFrame velocity system, hover physics (4-spring raycasts), mouse steering, collision detection + damage, fall damage, 3rd person camera, VehicleEntity/DriverSeat/HoverPoint tagging, placeholder speeder, speed HUD. No combat.
- **Pass 5 Build:** Failed 2026-02-19. 6 coupled failures: inverted steering, camera side-rotation/jitter, random airborne launches, harness grounded=0. Root causes: heading sign convention, camera tracking tilted model frame, hover physics averaging only over grounded rays. Fix plan archived at `archive/pass-5/pass-5-fix-plan.md`.
- **Pass 5 Recovery/Debug:** Iterated 2026-02-20. Post-fix baseline accepted by user for continued testing; remaining work is polish/tuning and deferred hull-damage model follow-up.
- **Pass 5 Build (emergency):** Complete 2026-02-22. Speeder movement stabilized. Slope physics, crest launches, sound, camera, collisions all working. See pass-5 stabilization build delta above.
- **Pass 6 Design:** Complete 2026-02-21. Speeder combat — weapon mounts on vehicles, driver-fired weapons, vehicle HP/shields, destruction, dismount, vehicle theft, splash damage, driver HUD.
- **Pass 6 Build (emergency):** Complete 2026-02-23. Speeder combat + weapon sound system expansion. See sound system build delta above.
- **Pass 7 Design:** Complete 2026-02-21. Artillery emplacement — parabolic projectile, WASD aiming, elevation/heading HUD, ammo-based, splash damage.
- **Pass 7 Build (emergency):** Complete 2026-02-23. Artillery built + freelook toggle + ammo/overheat checks. See sound system build delta above.
- **Pass 8 Design:** Complete 2026-02-23. Biped walker movement — separate WalkerServer, WASD+mouse, IK procedural legs, body secondary motion, head rotation, remote IK.
- **Pass 8 Build (emergency):** Complete 2026-02-24. Walker movement built + extensive polish. See pass-8 build delta below.
- **Pass 9 Design:** Complete 2026-02-24. Walker combat — chin blaster weapon, head CFrame for muzzle origin, client fire input + HUD, model authoring (WeaponMount on head).

## Context Files
- Read: `feature-passes.md`, `idea-locked.md`, `vehicle-idea-locked.md`, `attribute-reference.md`, `golden-tests.md`, `state.md`
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

### Pass 4 Build Delta
**Built as designed:**
- Lock-on targeting flow is implemented end-to-end (candidate scan, `T` lock toggle, server validation, lock replication, lock reticle/lead indicator HUD).
- Locked fire uses server-side lead prediction with auto-aim spread, torpedoes enforce `requiresLock`, and missiles use homing guidance.
- Turret lock validation enforces faction, arc, alive-state, and effective lock range checks with server-authoritative lock clear.
- Enclosed turret protection behavior is wired through turret exposure and validated in pass harness runs.

**Deviations from design:**
- Added player-facing lock UX polish based on playtests: lock camera/lead indicator smoothing and lock-loss HUD cues (`OUT OF RANGE`, `ARC LOST`, `TARGET LOST`).
- Tuned weapon spread values upward for both unlocked and locked fire so turrets are intentionally less accurate overall.
- Changed lock break behavior from hysteresis-based break range to strict effective range delock (immediate clear once out of range).
- Added/iterated a studio moving-target controller utility for local lock/lead feel testing (mode/speed/interval driven via attributes).

**New runtime contracts:**
- `LockOnState` payload now carries optional `reason` on unlock/break events.
- Client HUD now surfaces transient lock-loss status cues through `CombatHUD.onLockLostCue(reason)`.
- Studio-only helper `WeaponServer.fireTestShot(entityId, direction, applyAimSpreadForTest?)` now supports optional spread/auto-aim application for harness realism.
- Updated spread baselines are now part of weapon config behavior for all playable turret weapon types.

**Non-blocking follow-ups:**
- Re-run multiplayer feel tests and fine-tune spread/auto-aim spread by weapon role (point defense vs heavy artillery) before pass 5 balancing.
- Decide whether moving-target controller should stay as a permanent authoring utility or move to a separate dev/test package.
- Replace remaining always-on pass-tagged runtime prints (`[P4_*]`) with a diagnostics-gated logging policy during stabilization.
