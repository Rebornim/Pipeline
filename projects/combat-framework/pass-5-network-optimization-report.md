# Pass 5 Network/Perf Report (Vehicle Runtime)

Date: 2026-02-20
Source: live user playtest feedback + current server/client code audit

## 1) User-Observed Repro

- On entering a speeder, Roblox "Received" network stat spikes immediately.
- It then hovers around ~16 (units as shown in Roblox stats panel).
- After riding multiple different speeders in one session, received climbs further (example: ~30 after two speeders).
- Camera hiccuping is temporally correlated with this heavy runtime state.

## 2) Most Likely Primary Driver

### 2.1 Unconditional 60 Hz attribute replication

File: `projects/combat-framework/src/Server/Vehicles/VehicleServer.luau`
Function: `applySpeedAttributeReplication`

Current behavior:
- For every active vehicle, attributes are replicated if:
  - `(now - lastSpeedUpdateTick) >= (1/60)` **OR**
  - speed delta > 0.05 **OR**
  - heading delta > 0.1 deg

Because of the first condition, this effectively forces ~60 Hz replication even when delta is tiny.
This is likely the dominant baseline network cost during vehicle runtime.

## 3) Secondary Possible Contributors

### 3.1 Vehicles not reaching a fully dormant replication state

File: `projects/combat-framework/src/Server/Vehicles/VehicleServer.luau`

- Dismounted idle logic was changed to preserve vertical settling:
  - `state.velocity = Vector3.new(0, state.velocity.Y, 0)` in stop block.
- If vertical oscillation persists around hover equilibrium, vehicles may continue subtle state churn.
- Combined with unconditional 60 Hz replication, this keeps all such vehicles chatty.

### 3.2 Per-vehicle continuous debug attribute churn exposure

- `VehicleSpeed` + `VehicleHeading` are model attributes used by client camera/smoother.
- Every replicated attribute update is visible to all relevant clients.
- No adaptive rate or dormancy band currently exists.

## 4) What Was Checked / Not Primary

### 4.1 Client-side signal leak suspicion (landing shake)

Files:
- `projects/combat-framework/src/Client/Vehicles/VehicleClient.luau`
- `projects/combat-framework/src/Server/Vehicles/VehicleServer.luau`

- `landingShakeConnection` is module-scoped and disconnected in `exitVehicleMode`.
- This does not look like the main network receive scaling source.

### 4.2 Visual smoother clones

File: `projects/combat-framework/src/Client/Vehicles/VehicleVisualSmoother.luau`

- Mostly local-side render and clone management.
- Not an obvious direct source of server->client network growth pattern.

## 5) Requested Claude Deliverable

Design a **full vehicle runtime optimization pass** with:

1. **Replication budget policy** for `VehicleSpeed` / `VehicleHeading`:
- adaptive rate by state (driver active, coasting, parked)
- deadbands for speed/heading
- dormancy mode for parked/unoccupied vehicles

2. **Runtime state machine** (Active / Settling / Dormant) with explicit transitions.

3. **Client camera/smoothing contract** under lower replication rates:
- expected interpolation horizon
- max tolerable stale window
- fallback behavior when updates are sparse

4. **Instrumentation/Test Packet**:
- concrete pass/fail thresholds for Roblox network receive while driving 1, 2, 3 speeders sequentially
- camera hitch checks tied to replication cadence

5. **Fix sequencing**:
- smallest safe order of implementation to avoid destabilizing movement physics.

## 6) Immediate Hotspot Pointer

First fix to evaluate:
- Replace unconditional `(now - lastSpeedUpdateTick) >= 1/60` push model with adaptive + deadbanded replication.

