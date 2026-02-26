# Pass 10 Fix Design: Fighter Live-Server Stabilization

**Status:** Mid-pass fix. Fighter flight works in Studio, diverges badly on live servers.
**Based on:** pass-10-live-audit.md, critic review (2026-02-25), pass-10-design.md
**Existing code:** FighterServer.luau, FighterClient.luau, RemoteVehicleSmoother.luau, VehicleClient.luau, CombatInit.server.luau, CombatConfig.luau
**Date:** 2026-02-25

---

## What This Pass Fixes

Fighter flight is client-authoritative via BodyMovers + SetNetworkOwner. The architecture is correct but the implementation has 5 blocking issues that cause radically different behavior on live servers vs Studio:

1. Client and server both write the same attributes every frame (replication write war)
2. Server writes 11 attributes at 60 Hz (replication budget exhaustion + incoherent pose assembly)
3. Server heartbeat overrides client BodyMover state every 0.5s (movement deadlock)
4. 0.35s occupant grace period causes false pilot ejections under real latency
5. Clone smoother uses broken attribute pose channel with no interpolation (teleport stutter)

Plus 2 moderate issues: debug prints left in production, runtime StreamingEnabled mutation.

**All issues work fine in Studio** because Studio has no real replication — both sides hit the same DataModel. On live servers with actual network round-trips, every one of these breaks.

---

## File Changes

### Modified Files

| File | What's Changing | Why |
|------|----------------|-----|
| `src/Client/Vehicles/FighterClient.luau` | Remove 3 attribute writes, remove debug prints | Eliminate write war + production noise |
| `src/Server/Vehicles/FighterServer.luau` | Remove BodyMover heartbeat overrides, remove 9 pose attrs, increase grace, remove heartbeat pilot clear | Eliminate movement deadlock + budget exhaustion + false ejections |
| `src/Client/Vehicles/RemoteVehicleSmoother.luau` | Remove fighter attribute pose channel, use physics replication with lerp | Eliminate teleport stutter for remote observers |
| `src/Server/CombatInit.server.luau` | Replace runtime streaming mutation with warning-only check | Fix unreliable streaming toggle |
| `src/Shared/CombatConfig.luau` | Remove `DisableWorkspaceStreaming`, add `FighterTelemetryRate` | Clean up dead config + explicit fighter rate |

No new files.

---

## Build Steps

Steps are ordered smallest-diff-first. Each is independently testable.

---

### Step 1: Remove Pass-10 Debug Prints

**File:** `src/Client/Vehicles/FighterClient.luau`

**Delete the `[P10_ACTIVATE]` block** (currently inside the RenderStepped loop, fires on first frame):
```lua
-- DELETE this entire block:
if lastDebugPrintTick == 0 then
    print(string.format(
        "[P10_ACTIVATE] bv=%s bg=%s vf=%s forceMode=%s maxF=%s",
        ...
    ))
end
```

**Delete the `[P10_SPEED]` / `[P10_ORIENT]` block** (currently at end of RenderStepped loop, fires every 0.5s):
```lua
-- DELETE this entire block:
local now = tick()
if now - lastDebugPrintTick >= 0.5 then
    local pitchDeg = ...
    print(string.format("[P10_SPEED] speed=%.0f throttle=%d", ...))
    print(string.format("[P10_ORIENT] pitch=%.1f yaw=%.1f roll=%.1f", ...))
    lastDebugPrintTick = now
end
```

Also remove the `lastDebugPrintTick` variable declaration and all references to it (declaration, reset in `activate()`, reset in `deactivate()`, reset in `WindowFocusReleased`). It has no other purpose.

**Test criteria:**
- No `[P10_SPEED]`, `[P10_ORIENT]`, or `[P10_ACTIVATE]` in client output during flight.

**AI build prints:**
```
[P10F_S1] debug_prints_removed=true
```
Print once on first FighterClient activation after this change. Remove after step verified.

---

### Step 2: Stop Client Attribute Write War

**File:** `src/Client/Vehicles/FighterClient.luau`

**Delete these 3 lines** from the RenderStepped loop (currently near end of the loop, after physics update):
```lua
-- DELETE:
mdl:SetAttribute("VehicleSpeed", reportedSpeed)
mdl:SetAttribute("VehicleBoosting", boostActive)
local moveLook = physicsOrientation.LookVector
mdl:SetAttribute("VehicleHeading", math.atan2(-moveLook.X, -moveLook.Z))
```

The local HUD already gets speed via `CombatHUD.setSpeed(reportedSpeed)` on the very next line — it does NOT read the attribute. The server is the sole writer of `VehicleSpeed` and `VehicleHeading` via `writeFighterTelemetry`.

**For `VehicleBoosting`:** The server currently only clears this attribute in `disableFighterDrive()` (shutdown path). Remote observers need boost state for sound. Add a single `SetAttribute` call to `writeFighterTelemetry` in FighterServer:

```lua
-- ADD to writeFighterTelemetry, after the VehicleHeading write:
local isBoosting = state.instance:GetAttribute("VehicleBoosting")
-- Note: the client no longer writes this, so we need to replicate it from a
-- different source. For now, use AssemblyLinearVelocity vs config maxSpeed as
-- a proxy. Full boost state requires a client->server remote (future pass).
```

Actually, simpler: **keep only the `VehicleBoosting` client write**. Remove `VehicleSpeed` and `VehicleHeading` client writes. `VehicleBoosting` is a boolean that changes infrequently (state transitions, not every frame) so it has negligible replication cost, and the server doesn't have its own competing write for this attr during flight.

So the final change is: **delete the `VehicleSpeed` and `VehicleHeading` SetAttribute lines from FighterClient**. Keep `VehicleBoosting`.

**Test criteria:**
- Two-player live server: remote fighter sound pitch changes smoothly, no flicker.
- Local HUD still shows correct speed.

**AI build prints:**
```
[P10F_S2] client_attr_writes=boosting_only
```
Print once on activation. Remove after step verified.

---

### Step 3: Remove BodyMover Overrides from Server Heartbeat

**File:** `src/Server/Vehicles/FighterServer.luau`

In `ensurePilotOwnership()`, **delete these 4 lines**:
```lua
-- DELETE from ensurePilotOwnership:
local useForceFlight = state.config.fighterUseForceFlight == true
state.primaryPart.Anchored = false
state.bodyVelocity.MaxForce = if useForceFlight then Vector3.zero else Vector3.new(math.huge, math.huge, math.huge)
state.bodyGyro.MaxTorque = Vector3.new(math.huge, math.huge, math.huge)
state.vectorForce.Enabled = useForceFlight
```

**Keep** only the `SetNetworkOwner` check block that follows:
```lua
-- KEEP (this is the only thing ensurePilotOwnership should do):
local ownerOk, currentOwner = pcall(function()
    return state.primaryPart:GetNetworkOwner()
end)
if not ownerOk or currentOwner ~= pilot then
    pcall(function()
        (state.primaryPart.AssemblyRootPart or state.primaryPart):SetNetworkOwner(pilot)
    end)
end
```

**Why:** BodyMover state is set correctly once at pilot assignment in `updatePilotFromSeat()` (lines 486-494). The server must not re-assert BodyMover properties from a heartbeat — it races with the client's per-frame writes. The heartbeat's only valid job is re-verifying network ownership hasn't drifted.

**Test criteria:**
- Fighter does not freeze or lose control during long flight (>60s).
- Force-flight mode works without `[P10_FORCE]` fallback warning.

**AI build prints:**
```
[P10F_S3] ownership_check pilot=%s owner=%s reassigned=%s
```
Print only when ownership is actually reassigned (not every 0.5s check). Remove after step verified.

---

### Step 4: Harden Pilot Clear Logic

**File:** `src/Server/Vehicles/FighterServer.luau`

**4a: Increase grace period.**

Change:
```lua
local FIGHTER_OCCUPANT_GRACE_SECONDS = 0.35
```
To:
```lua
local FIGHTER_OCCUPANT_GRACE_SECONDS = 1.5
```

**4b: Remove heartbeat-driven pilot clear.**

In the Heartbeat connection, **delete this block**:
```lua
-- DELETE from heartbeat loop:
if state.pilot ~= nil and state.pilotSeat.Occupant == nil then
    updatePilotFromSeat(state)
end
```

Pilot clear is handled by:
- `Occupant` property changed signal (already connected at registration, line 774)
- `PlayerRemoving` handler (line 813)
- `VehicleExitRequest` remote (line 789)

The heartbeat was redundantly polling the same thing the signal already fires for, but with a too-short grace timer that produces false positives under replication jitter.

**Test criteria:**
- High-latency test (250ms emulated RTT): pilot flies 60s without involuntary ejection.
- Normal exit (press F) still works immediately.
- Player disconnect still cleans up pilot state.

**AI build prints:**
```
[P10F_S4] pilot_clear reason=%s entity=%s grace_elapsed=%.2f
```
Print on every pilot clear with the trigger reason (exit_request / occupant_signal / player_removing). Remove after step verified.

---

### Step 5: Remove Attribute Pose Channel, Use Physics Replication

This is the highest-leverage fix. Two files.

#### 5a: FighterServer — Strip Pose Attributes

**File:** `src/Server/Vehicles/FighterServer.luau`

**Delete the 9 `FIGHTER_REP_*` constants:**
```lua
-- DELETE all of these:
local FIGHTER_REP_POS_X = "FighterRepPosX"
local FIGHTER_REP_POS_Y = "FighterRepPosY"
local FIGHTER_REP_POS_Z = "FighterRepPosZ"
local FIGHTER_REP_LOOK_X = "FighterRepLookX"
local FIGHTER_REP_LOOK_Y = "FighterRepLookY"
local FIGHTER_REP_LOOK_Z = "FighterRepLookZ"
local FIGHTER_REP_UP_X = "FighterRepUpX"
local FIGHTER_REP_UP_Y = "FighterRepUpY"
local FIGHTER_REP_UP_Z = "FighterRepUpZ"
```

**Rewrite `writeFighterTelemetry`** to only write 2 scalar attributes:
```lua
local function writeFighterTelemetry(state: FighterRuntimeStateInternal)
    local primaryPart = state.primaryPart
    if primaryPart.Parent == nil then
        return
    end

    local speed = primaryPart.AssemblyLinearVelocity.Magnitude
    local look = primaryPart.CFrame.LookVector

    state.instance:SetAttribute("VehicleSpeed", speed)
    state.instance:SetAttribute("VehicleHeading", math.atan2(-look.X, -look.Z))
end
```

**Delete `clearFighterReplicatedPose` function entirely** (the one that sets 9 attrs to nil). Remove its call sites:
- In `releaseFighterMomentum`: delete `clearFighterReplicatedPose(state.instance)`
- In `cleanupFighterState`: delete `clearFighterReplicatedPose(state.instance)`

**Reduce fighter telemetry rate.** Add a constant:
```lua
local FIGHTER_TELEMETRY_RATE = 15
```

In the Heartbeat loop, change the fighter write interval to use this rate instead of `VehicleReplicationRateActive`:
```lua
-- CHANGE: use fighter-specific rate instead of global VehicleReplicationRateActive
local writeInterval = 1 / FIGHTER_TELEMETRY_RATE
```

The `VehicleReplicationRateActive` config value continues to apply for non-fighter vehicle types in VehicleServer. This change is fighter-heartbeat-local only.

#### 5b: RemoteVehicleSmoother — Use Physics CFrame

**File:** `src/Client/Vehicles/RemoteVehicleSmoother.luau`

**Delete the 9 `FIGHTER_REP_*` constants:**
```lua
-- DELETE:
local FIGHTER_REP_POS_X = "FighterRepPosX"
-- ... (all 9)
```

**Delete the `readFighterReplicatedCFrame` function entirely.**

**In the per-frame update loop**, remove the fighter-specific CFrame override:
```lua
-- DELETE this block:
if entry.isFighter then
    local replicatedCFrame = readFighterReplicatedCFrame(model)
    if replicatedCFrame ~= nil then
        entry.lastReplicatedFighterCFrame = replicatedCFrame
        sourceCFrame = replicatedCFrame
    end
end
```

`sourceCFrame` is already set to `sourcePrimary.CFrame` on the line above. Physics replication via `SetNetworkOwner` delivers this CFrame automatically.

**Remove the no-interpolation fighter fast-path:**
```lua
-- DELETE this block:
if entry.isFighter then
    entry.smoothedCFrame = sourceCFrame
end
```

Fighters now go through the standard lerp smoothing path (the `else` branch that already exists for speeders). The existing `SMOOTHING_ALPHA = 10` with `MAX_SNAP_DISTANCE = 40` is appropriate for a fast vehicle.

**Remove `lastReplicatedFighterCFrame` from the `RemoteVehicleEntry` type** and from the entry constructor. Remove the `isFighter` field if it has no remaining uses after this change. Check: the sound update at lines 1300-1310 branches on `isFighter` to read speed differently. Change that branch to use the same `VehicleSpeed` attribute read for all vehicle types — the server now writes `VehicleSpeed` at 15 Hz for fighters, same as it does for speeders. Delete the `isFighter` fallback that reads `AssemblyLinearVelocity` directly:

```lua
-- CHANGE the isFighter sound speed branch to use the common path:
-- Before:
if entry.isFighter then
    local speedAttr = model:GetAttribute("VehicleSpeed")
    if type(speedAttr) == "number" then
        speed = math.max(0, speedAttr)
    else
        speed = if sourcePrimary ~= nil then sourcePrimary.AssemblyLinearVelocity.Magnitude else 0
    end
-- After: just use the common path that reads VehicleSpeed attribute (already exists in the else branch)
```

After these changes, check if `isFighter` has any remaining uses in RemoteVehicleSmoother. If not, remove the field from the entry type and the `vehicleClass == "fighter"` detection in the activation path.

**Also** check the inline engine loop branch near the end (the `elseif entry.inlineEngineLoop ~= nil and entry.isFighter` block). Change it to not gate on `isFighter` — inline engine loops should work the same for any vehicle type that uses them.

**Test criteria:**
- Two-player live server: non-pilot sees fighter fly smoothly at 200+ studs/s with no teleport stutter.
- Remote fighter sound pitch tracks speed correctly.
- No `FighterRep*` attributes appear on the fighter model during play.

**AI build prints:**
```
[P10F_S5] remote_fighter model=%s using_physics_replication=true smoothing_alpha=%d
```
Print once per remote fighter activation in RemoteVehicleSmoother. Remove after step verified.

---

### Step 6: Fix Streaming Configuration

**File:** `src/Server/CombatInit.server.luau`

**Replace** the runtime mutation block:
```lua
-- DELETE:
if CombatConfig.DisableWorkspaceStreaming == true and Workspace.StreamingEnabled then
    Workspace.StreamingEnabled = false
    print("[COMBAT_INIT] Workspace streaming disabled for deterministic vehicle/fighter runtime")
end
```

**With** a validation-only warning:
```lua
if Workspace.StreamingEnabled then
    warn("[COMBAT_INIT] WARNING: StreamingEnabled is true. Fighter flight requires StreamingEnabled = false in place settings. Fighters may behave incorrectly.")
end
```

**File:** `src/Shared/CombatConfig.luau`

**Delete:**
```lua
CombatConfig.DisableWorkspaceStreaming = true
```

The operator must set `StreamingEnabled = false` in Roblox Studio place settings before publishing.

**Test criteria:**
- Server startup: no `StreamingEnabled` mutation, only a warning if the place setting is wrong.
- `FighterClient` `RequestStreamAroundAsync` branch never fires (gates on `Workspace.StreamingEnabled`).

**AI build prints:**
```
[P10F_S6] streaming_enabled=%s
```
Print once at CombatInit startup. Remove after step verified.

---

## Config Changes

```lua
-- REMOVE from CombatConfig:
CombatConfig.DisableWorkspaceStreaming = true  -- no longer used

-- KEEP (unchanged, still used by VehicleServer for speeders):
CombatConfig.VehicleReplicationRateActive = 60
```

Fighter telemetry rate is now a local constant in FighterServer (`FIGHTER_TELEMETRY_RATE = 15`), not a config value. This is deliberate — it's an implementation detail of the fix, not a tunable.

---

## Integration Pass

### Data Lifecycle: VehicleSpeed attribute

- **Written by:** FighterServer.writeFighterTelemetry() at 15 Hz
- **Read by (local):** NOT read by local client — CombatHUD.setSpeed() uses the local `reportedSpeed` variable directly
- **Read by (remote):** RemoteVehicleSmoother sound controller via `model:GetAttribute("VehicleSpeed")`
- **Cleaned up by:** FighterServer.cleanupFighterState() sets to nil
- **No competing writers** after Step 2 removes client writes

### Data Lifecycle: Fighter CFrame (for remote observers)

- **Written by:** Roblox physics replication (automatic via SetNetworkOwner)
- **Read by:** RemoteVehicleSmoother reads `sourcePrimary.CFrame` — the physics-replicated value
- **Smoothed by:** Standard lerp at SMOOTHING_ALPHA = 10
- **No attribute channel** after Step 5 removes the 9-component pose attrs

### Data Lifecycle: Network ownership

- **Set by:** FighterServer.updatePilotFromSeat() at pilot entry (once)
- **Verified by:** FighterServer.ensurePilotOwnership() every 0.5s (ownership check only, no BodyMover writes)
- **Cleared by:** FighterServer.releaseFighterMomentum() / parkFighter() at exit

---

## Regression Checks

After all 6 steps, verify these still work:

1. **Speeder flight** — speeders are unaffected (they use VehicleServer, not FighterServer)
2. **Walker movement** — walkers are unaffected (they use WalkerServer)
3. **Fighter crash detection** — still runs in FighterServer heartbeat (unchanged)
4. **Fighter destruction/respawn** — still handled by HealthManager callbacks (unchanged)
5. **Fighter seat entry/exit** — ProximityPrompt + Occupant signal still functional
6. **Fighter sound** — local pilot uses FighterClient.updateAudio(); remote uses RemoteVehicleSmoother sound controller reading VehicleSpeed attribute

---

## Live-Server Verification Checklist

All tests must run on a published live server with 2+ real players. Not Studio.

| # | Test | Pass Condition |
|---|------|---------------|
| 1 | Ownership stability | Pilot flies 120s, no ejection. `[P10_OWNER]` prints once. |
| 2 | Remote smoothness | Non-pilot watches fighter at 200+ studs/s — continuous motion, no teleports. |
| 3 | Attribute rate | `AttributeChanged` on fighter model ≤30/s during active flight. |
| 4 | High-latency | 250ms emulated RTT, 60s flight, no false ejection. |
| 5 | Force-flight | No `[P10_FORCE]` fallback warning in client output. |
| 6 | Multi-fighter | 4 simultaneous pilots, server heartbeat under 2ms average. |
| 7 | Exit/re-enter | Exit and re-enter within 1.5s — no ghost state or stuck movers. |
| 8 | Streaming | `RequestStreamAroundAsync` never fires (StreamingEnabled = false in place settings). |
| 9 | Remote sound | Non-pilot hears fighter engine pitch change smoothly with speed. |
