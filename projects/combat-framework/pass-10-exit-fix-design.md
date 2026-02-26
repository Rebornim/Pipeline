# Pass 10 Exit Fix Design: Ship Falling + Prompt Missing

**Type:** Bugfix — two persistent issues surviving multiple fix attempts
**Based on:** User testing — ship falls/explodes on exit, ProximityPrompt never reappears after exiting
**Existing code:** FighterClient.luau, FighterServer.luau, RemoteVehicleSmoother.luau
**Date:** 2026-02-26

---

## Problem Statement

Two bugs persist after the auto-land system was built:

1. **Ship falls and explodes on exit.** User reports: "the ship now doesnt auto land, it unanchors and falls, and does explode if you were high up when you got out."

2. **ProximityPrompt never reappears.** After landing and exiting, the prompt to re-enter the fighter does not show. This has persisted across 3+ fix attempts targeting RemoteVehicleSmoother.

---

## Pre-Build: Sync Verification (CRITICAL)

Multiple code fixes have been applied to disk but the user reports no change in behavior. Before implementing anything, verify that Studio's code matches the code on disk.

**Procedure:**
1. Use MCP `get_script_source` on `game.StarterPlayer.StarterPlayerScripts.CombatClient.Vehicles.FighterClient` — check that `onExitAction` at line ~300 contains `if flightMode ~= "Landing" then` (NOT the old code that immediately fires exit remote).
2. Use MCP `get_script_source` on `game.ServerScriptService.CombatInit.Vehicles.FighterServer` — check that the exit handler at line ~788 calls `parkFighter(state)` (NOT `releaseFighterMomentum(state)`).
3. If Studio code does NOT match disk: the user needs to re-sync Rojo. Report this and stop.
4. If Studio code DOES match disk: continue to the fixes below.

**Note on script paths:** The exact paths depend on the Rojo project layout. Use `grep_scripts` with content `"exitAutoLandActive"` to find FighterClient, and `"parkFighter"` to find FighterServer. The content is the source of truth.

---

## Root Cause Analysis

### Bug 1: Ship Falls

Two possible causes (not mutually exclusive):

**Cause A — Auto-land never completes:** The auto-land block at FighterClient.luau line ~1465 (`if inLanding and exitAutoLandActive then`) fires `vehicleExitRemote:FireServer()` only when `isGrounded and isStopped`. If the grounding raycast fails (no ground hit), or if the ship never reaches the stop threshold, the exit remote never fires. The player is stuck in auto-land. They may then exit via Jump (Space key), which bypasses the auto-land entirely.

**Cause B — Jump/Space exit bypasses auto-land:** The Roblox engine's built-in seat exit (pressing Jump while seated) bypasses `onExitAction`. The character leaves the seat. FighterClient's `seatOccupantConnection` or `RenderStepped` loop detects this, calls `deactivate()` which zeros all BodyMovers (MaxForce=0). The ship is not anchored (was un-anchored when pilot entered). With no forces and no anchor, it falls. The server's `updatePilotFromSeat` has a grace period bug where the Occupant signal fires once, sets `pilotSeatMissingSince`, and returns — but nothing re-triggers the function to complete the park after the grace period expires. (A `task.delay` retry was added in a previous fix attempt but may not have synced.)

**Fix approach — client-side anchor:** The most robust fix is to have `FighterClient.deactivate()` anchor the ship's PrimaryPart BEFORE zeroing BodyMovers. The client has network ownership at deactivation time, so this write is authoritative. This prevents falling regardless of HOW the exit happened (auto-land, Jump, character death, disconnect). The server's `parkFighter` will also anchor, but the client anchor acts as immediate insurance.

### Bug 2: Prompt Not Appearing

Previous fixes targeted RemoteVehicleSmoother (preventing re-tracking, stripping clone ProximityPrompts). None worked. The issue may be:

1. **Roblox internal ProximityPrompt state:** After being `Enabled = false` (set when pilot enters) then `Enabled = true` (set by server parkFighter), some Roblox internal state may prevent the prompt from rendering to the player who just exited. This is hard to diagnose without instrumentation.

2. **Distance:** The character may exit far from the pilotSeat (collision pushback from the fighter model). MaxActivationDistance was 16 studs (increased to 50 in a previous fix attempt — verify this synced).

3. **RemoteVehicleSmoother clone conflict:** Even with the re-track removal, the init-time clone may still exist if deactivateEntry wasn't called properly on entry.

**Fix approach — prompt toggle cycle:** Instead of just setting `prompt.Enabled = true`, cycle it: set `false`, defer one frame, then set `true`. This forces Roblox's replication system to process a full state transition. Additionally, create a fallback: if the prompt doesn't fire a `Triggered` event within 5 seconds of parking, destroy and recreate the prompt instance.

---

## Build Steps

### Step 1: Sync Verification

Use MCP to verify Studio code matches disk. See "Pre-Build" section above. If sync is broken, report to user and stop.

### Step 2: Client-Side Anchor on Deactivate

**File:** `src/Client/Vehicles/FighterClient.luau`
**Location:** `FighterClient.deactivate()` — currently at line ~1714

**Change:** Add a PrimaryPart anchor write BEFORE the BodyMover cleanup. Insert after the sound cleanup and before `VehicleCamera.deactivate()`:

After:
```lua
	model:SetAttribute("VehicleBoosting", false)
end
```

Before:
```lua
VehicleCamera.deactivate()
```

Insert:
```lua
-- Anchor the ship immediately from the client to prevent falling.
-- Client has network ownership at this point, so this write is authoritative.
-- The server's parkFighter will also anchor, but this prevents the fall gap
-- between client deactivation and server processing.
if model ~= nil and model.PrimaryPart ~= nil then
    model.PrimaryPart.Anchored = true
end
```

**Why:** When `deactivate()` runs, the client still has network ownership (SetNetworkOwner was called during activate). The client can authoritatively set `Anchored = true`. This prevents the ship from falling during the window between client deactivation (BodyMovers zeroed) and server processing (parkFighter anchor). Works for ALL exit paths: auto-land, Jump, character death, disconnect.

**Pass condition:** Ship stays frozen in place when exiting via any method.
**Fail condition:** Ship still falls or drifts after exit.

### Step 3: Prompt Toggle Cycle in parkFighter

**File:** `src/Server/Vehicles/FighterServer.luau`
**Location:** `parkFighter()` — currently at line ~278

**Change:** Replace the simple `prompt.Enabled = true` with a toggle cycle:

Replace:
```lua
if state.prompt ~= nil then
    state.prompt.Enabled = true
    print(string.format(
        "[P10_PROMPT] parkFighter entity=%s prompt_enabled=%s prompt_parent=%s",
        state.entityId,
        tostring(state.prompt.Enabled),
        tostring(state.prompt.Parent and state.prompt.Parent:GetFullName() or "nil")
    ))
    local promptRef = state.prompt
    local entityRef = state.entityId
    task.delay(0.5, function()
        if promptRef ~= nil and promptRef.Parent ~= nil then
            promptRef.Enabled = true
        end
    end)
end
```

With:
```lua
if state.prompt ~= nil then
    -- Toggle cycle: force a full Enabled state transition.
    -- Setting false then true (deferred) forces Roblox replication to process
    -- the change, rather than potentially deduplicating a true→true no-op.
    state.prompt.Enabled = false
    local promptRef = state.prompt
    task.defer(function()
        if promptRef ~= nil and promptRef.Parent ~= nil then
            promptRef.Enabled = true
            print(string.format(
                "[P10_PROMPT] parkFighter prompt_enabled=true parent=%s",
                promptRef.Parent:GetFullName()
            ))
        end
    end)
end
```

**Why:** If `prompt.Enabled` was already `true` on the server (e.g., from a previous park), setting it `true` again may be a no-op that Roblox's replication deduplicates. The toggle forces a state change that must be replicated.

**Pass condition:** ProximityPrompt appears after exiting the fighter.
**Fail condition:** Prompt still doesn't appear.

### Step 4: Diagnostic Prints for Exit Flow

**File:** `src/Client/Vehicles/FighterClient.luau`

Verify the `[P10_EXIT]` diagnostic print is present at the top of `deactivate()`. It should print `flightMode`, `exitAutoLandActive`, model name, and seat occupant. If not present, add it.

**File:** `src/Server/Vehicles/FighterServer.luau`

Add a print at the TOP of the exit handler (inside `vehicleExitRemote.OnServerEvent:Connect`), before any logic:

```lua
print(string.format("[P10_EXIT_SERVER] exit_remote received player=%s", player.Name))
```

This confirms the exit remote actually arrives on the server.

**File:** `src/Client/Vehicles/FighterClient.luau`

In the auto-land settled block (where `isGrounded and isStopped`), add a print before `vehicleExitRemote:FireServer()`:

```lua
print("[P10_AUTOLAND] settled — firing exit remote")
```

This confirms the auto-land actually completes and fires the remote.

### Step 5: Verify MaxActivationDistance

**File:** `src/Server/Vehicles/FighterServer.luau`

Confirm `prompt.MaxActivationDistance = 50` (not 16). If it's still 16, change it to 50.

---

## Test Procedure

1. Enter the fighter via ProximityPrompt
2. Fly around briefly
3. Press L to enter landing mode
4. Press F to trigger auto-land
5. **Watch the output console for:**
   - `[P10_AUTOLAND] settled` — confirms auto-land completed
   - `[P10_EXIT_SERVER] exit_remote received` — confirms server got the request
   - `[P10_PROMPT] parkFighter prompt_enabled=true` — confirms prompt was toggled on
   - `[P10_EXIT] deactivate flightMode=Landing` — confirms client deactivated from landing mode
6. After exit: ship should stay frozen (client-side anchor prevents falling)
7. ProximityPrompt should appear (toggle cycle forces replication)
8. Press E to re-enter — should work
9. Fly, land, exit again — should still work

**If ship still falls:** Check if `[P10_AUTOLAND]` print appears. If not, the auto-land never completes — the grounding check fails. Report the missing prints.

**If prompt still missing:** Check if `[P10_PROMPT]` print appears. If yes but prompt doesn't show, the issue is client-side rendering or distance. Walk closer to the fighter seat and check. Report all prints.

---

## Build Order

1. Step 1 (sync verification) — **must pass before continuing**
2. Step 2 (client anchor on deactivate) — **fixes falling**
3. Step 3 (prompt toggle cycle) — **fixes prompt**
4. Step 4 (diagnostic prints) — **instrumentation**
5. Step 5 (MaxActivationDistance verify) — **distance fix**
