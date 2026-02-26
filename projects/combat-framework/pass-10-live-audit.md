# Pass 10 Mid-Pass Audit: Studio vs Live Divergence

Date: 2026-02-25
Scope: `projects/combat-framework/src/` fighter flight stack

## Executive Summary

The current fighter implementation is running multiple authority layers at once:

1. Client-authoritative physics (intended)
2. Server ownership/telemetry heartbeat
3. Remote clone/smoothing pipeline (designed for old 20 Hz server vehicles)

This works "okay" in Studio (low latency, no real replication pressure), but diverges in live servers where seat replication, attribute replication budgets, and streaming behavior are stricter.

## Findings (ordered by severity)

1. Double-writer telemetry race (`VehicleSpeed` / `VehicleHeading`)
- Client writes every render frame in `FighterClient`.
- Server also writes every heartbeat in `FighterServer`.
- This creates write contention and unnecessary replication churn.
- Evidence:
  - `src/Client/Vehicles/FighterClient.luau` lines 1567-1570
  - `src/Server/Vehicles/FighterServer.luau` lines 74-75 and 823-851

2. Per-fighter 60 Hz attribute flood for pose replication
- Server writes 11 attributes (`speed`, `heading`, position/look/up vectors) at 60 Hz per piloted fighter.
- In live servers this is likely throttled, delayed, or dropped under load/distance, causing freeze/stall artifacts not seen in Studio.
- Evidence:
  - `src/Server/Vehicles/FighterServer.luau` lines 74-84 and 823-851
  - `src/Shared/CombatConfig.luau` line 705

3. Force-flight mode + fallback mismatch can dead-drive movement
- Config defaults to force mode (`fighterUseForceFlight = true`).
- Client can fallback to BodyVelocity mode if `VectorForce` is unavailable/tardy.
- Server ownership heartbeat still enforces force mode (sets BodyVelocity MaxForce to zero), which can neutralize fallback control.
- Evidence:
  - `src/Shared/CombatConfig.luau` line 591
  - `src/Client/Vehicles/FighterClient.luau` lines 775-791 and 1459-1484
  - `src/Server/Vehicles/FighterServer.luau` lines 420-424

4. Seat-occupant transient handling is too aggressive for live latency
- Pilot clear path depends on seat occupancy visibility and a short grace window.
- Live replication jitter can produce transient nil occupancy and forced release/ownership churn.
- Evidence:
  - `src/Server/Vehicles/FighterServer.luau` lines 513-533
  - `src/Server/Vehicles/FighterServer.luau` lines 59-60
  - `src/Server/Vehicles/FighterServer.luau` lines 835-837

5. Fighter still routed through visual clone smoother stack
- Fighters are still cloned, source hidden locally, and updated through remote smoothing infra.
- That path was built for server-stepped vehicles; for client-owned fighters it adds extra state and failure modes.
- Evidence:
  - `src/Client/Vehicles/RemoteVehicleSmoother.luau` lines 935-997
  - `src/Client/Vehicles/RemoteVehicleSmoother.luau` lines 1190-1202

6. Runtime streaming toggle is brittle as a live mitigation
- Server tries to disable workspace streaming at runtime.
- Even when this succeeds, relying on runtime mutation is less deterministic than place-level configuration.
- Evidence:
  - `src/Server/CombatInit.server.luau` lines 185-188
  - `src/Shared/CombatConfig.luau` line 704

7. Flight sim dt clamp can diverge by framerate class
- Physics integration clamps dt to `1/30`; low-FPS clients simulate less real-time motion than intended.
- This worsens "feels different in game" across device/perf classes.
- Evidence:
  - `src/Client/Vehicles/FighterClient.luau` line 1000

## Exact Fix Sequence (minimal risk first)

1. Remove duplicate telemetry writers
- Keep local UI speed internal; stop client frame-by-frame `SetAttribute` for speed/heading/boost.
- Keep only server-owned attributes that are strictly required for non-owner clients, at reduced cadence.

2. Disable force-flight mode for pass 10 stabilization
- Set fighter default to BodyVelocity mode (`fighterUseForceFlight = false`).
- Remove server-side force-mode enforcement conflict in `ensurePilotOwnership`.

3. Reduce/remove fighter pose attribute replication
- Preferred: stop writing replicated fighter pose attrs entirely and use physics replication.
- If temporary fallback needed, cap pose writes to <= 10-15 Hz with deadband and sequence.

4. Harden pilot clear logic for live replication jitter
- Increase occupancy grace substantially (>= 1.25s).
- Prioritize explicit exit request + humanoid seated state over transient seat occupant nil.
- Do not clear pilot on one-frame occupancy misses.

5. Bypass clone smoother for fighters
- Do not create visual clone for fighter models.
- Track fighter sound directly on source model/PrimaryPart for non-local observers.

6. Move streaming decision out of runtime
- Set place-level StreamingEnabled intentionally.
- At runtime, only detect and warn if the place value is not what pass 10 expects.

7. Normalize fighter simulation step
- Replace simple dt clamp with fixed-step accumulator (e.g. 60 Hz sim with capped catch-up substeps).

## Expected Outcome

After steps 1-5, Studio and live behavior should converge materially because:
- There is one movement authority path.
- Replication budget pressure drops sharply.
- Live seat/ownership jitter no longer tears control state.
- Remote fighters no longer depend on a second synthetic pose channel.
