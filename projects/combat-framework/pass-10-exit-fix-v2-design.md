# Pass 10 Exit Fix v2 — Three Bugs

**Type:** Bugfix — persistent issues surviving multiple fix attempts
**Date:** 2026-02-26

---

## Bug Summary

1. **Ship falls and explodes on exit.** Auto-land does not work. Ship unanchors and falls when player exits.
2. **ProximityPrompt never reappears.** After exiting, the E prompt to re-enter the fighter does not show. Has persisted across 5+ fix attempts.
3. **E enters other ship while seated.** While piloting Ship A, pressing E near Ship B transfers the player into Ship B. Should not be possible.

---

## CRITICAL: Sync Verification (Step 0 — BLOCKING)

Multiple code fixes have been applied to disk files but the user reports ZERO change in behavior. The most likely explanation is that Rojo sync is broken — Studio is running old code.

**Procedure:**

1. Use MCP `grep_scripts` with pattern `"[P10_EXIT]"` and `path = "game.StarterPlayer"` — this diagnostic print was added to `FighterClient.deactivate()`. If NOT found, sync is broken.
2. Use MCP `grep_scripts` with pattern `"[P10_PROMPT]"` and `path = "game.ServerScriptService"` — this was added to `FighterServer.parkFighter()`. If NOT found, sync is broken.
3. Use MCP `grep_scripts` with pattern `"model.PrimaryPart.Anchored = true"` and `path = "game.StarterPlayer"` — this is the client-side anchor in deactivate. If NOT found, sync is broken.

**If ANY of the above are NOT found:**
- Print: `[P10_SYNC] SYNC FAILURE — Studio code does not match disk. Please re-sync Rojo and restart.`
- **STOP. Do not continue to subsequent steps. Report this to the user.**

**If ALL three are found:** Continue to Step 1.

---

## Root Cause Analysis

### Bug 1: Ship Falls

The code on disk already has client-side `model.PrimaryPart.Anchored = true` in `deactivate()` (FighterClient line 1751) and server-side anchoring in `parkFighter()`. If sync is confirmed working and the ship STILL falls, the remaining cause is:

**Jump/Space exit bypasses auto-land.** Roblox's built-in seat exit fires when the player presses Space (Jump). This unseats the character instantly — `seatOccupantConnection` fires, `isLocalPilotStillValid()` returns false, `deactivate()` runs. The client-side anchor SHOULD prevent falling, but there may be a network ownership race where the server takes ownership before the client's anchor write propagates. The fix is to prevent Jump exit entirely — force all exits through the F-key auto-land system.

### Bug 2: ProximityPrompt Not Appearing

`parkFighter()` does a toggle cycle (false → defer → true) which should force replication. If this still doesn't work after sync is confirmed, the remaining possibility is that `task.defer` runs too early (before the false state fully replicates) or that Roblox's ProximityPrompt has internal rendering state that isn't reset by Enabled toggles.

Nuclear fix: destroy the old ProximityPrompt and create a fresh one. This forces Roblox to create an entirely new rendering context. Since the Triggered connection lives on `state.connections` and references `state`, we can safely destroy the old prompt and wire up a new one.

### Bug 3: E Enters Other Ship While Seated

The `prompt.Triggered` handler (FighterServer line 715) checks `state.pilot ~= nil` (is THIS ship occupied?) and `getFighterByPilot(player)` (is the player piloting a DIFFERENT fighter?). If the player pilots Ship A and triggers Ship B's prompt, the handler ejects from Ship A and seats in Ship B. This is the vehicle-swap behavior.

The user does not want this. A seated player should never trigger a fighter prompt.

---

## Build Steps

### Step 1: Block Jump Exit While Piloting (Client)

**File:** `src/Client/Vehicles/FighterClient.luau`

**Constant:** Add near line 45 (with other constant names):
```lua
local BLOCK_JUMP_ACTION_NAME = "BlockFighterJump"
```

**In `FighterClient.activate()`:** After the `ContextActionService:BindAction(EXIT_ACTION_NAME, ...)` call (line 1704), add:
```lua
ContextActionService:BindAction(BLOCK_JUMP_ACTION_NAME, function()
    return Enum.ContextActionResult.Sink
end, false, Enum.KeyCode.Space)
```

This binds Space to a sink handler, preventing Roblox's built-in Jump-to-exit-seat behavior. The player MUST use F to exit (which triggers auto-land).

**In `FighterClient.deactivate()`:** After the `ContextActionService:UnbindAction(EXIT_ACTION_NAME)` call (line 1740), add:
```lua
ContextActionService:UnbindAction(BLOCK_JUMP_ACTION_NAME)
```

**Why:** Without this, Space/Jump bypasses the auto-land entirely. The character unseats instantly, leaving the ship in an uncontrolled state. Even with client-side anchoring, there's a network ownership race. Blocking Jump forces all exits through the F → auto-land → exit remote → server parkFighter path, which is fully controlled.

**Pass condition:** Player cannot exit the fighter by pressing Space. Only F key works (and only during Landing mode).
**Fail condition:** Player can still Jump out of the fighter.

### Step 2: Prevent Seated Players from Triggering Prompts (Server)

**File:** `src/Server/Vehicles/FighterServer.luau`
**Location:** `prompt.Triggered` handler, inside `registerFighter()` — currently line 715

**Change:** After the humanoid nil check (line 727), add a seated check:

After:
```lua
if humanoid == nil then
    return
end
```

Before:
```lua
local currentState = getFighterByPilot(player)
```

Insert:
```lua
if humanoid.Sit then
    return
end
```

**Why:** If `humanoid.Sit == true`, the player is currently seated in some seat (fighter, turret, vehicle, or anything). A seated player should not be able to trigger a ProximityPrompt to enter a different ship. This prevents accidental ship-swapping while flying.

**Also:** Remove the entire vehicle-swap block (lines 730-744) since seated players are now rejected. This dead code handled the `currentState ~= nil and currentState ~= state` case, which can no longer occur because a piloting player always has `humanoid.Sit == true`.

Replace lines 730-744:
```lua
local currentState = getFighterByPilot(player)
local needsDeferredSit = false
if currentState ~= nil and currentState ~= state then
    needsDeferredSit = true
    clearPilot(currentState)
    currentState.bodyVelocity.MaxForce = Vector3.zero
    currentState.bodyVelocity.Velocity = Vector3.zero
    currentState.bodyGyro.MaxTorque = Vector3.zero
    currentState.vectorForce.Enabled = false
    currentState.vectorForce.Force = Vector3.zero
    parkFighter(currentState)
    if currentState.pilotSeat.Occupant == humanoid then
        humanoid.Sit = false
    end
end
```

With:
```lua
local needsDeferredSit = false
```

And also remove the `needsDeferredSit` branching (lines 746-761) since it's always false now. Replace:
```lua
if needsDeferredSit then
    task.defer(function()
        if humanoid.Parent == nil then
            return
        end
        if state.pilot ~= nil then
            return
        end
        if pilotSeat.Occupant ~= nil and pilotSeat.Occupant ~= humanoid then
            return
        end
        pilotSeat:Sit(humanoid)
    end)
else
    pilotSeat:Sit(humanoid)
end
```

With:
```lua
pilotSeat:Sit(humanoid)
```

**Pass condition:** While in Ship A, pressing E near Ship B does nothing.
**Fail condition:** Player can still enter Ship B while seated in Ship A.

### Step 3: Prompt Nuclear Recreate in parkFighter (Server)

**File:** `src/Server/Vehicles/FighterServer.luau`
**Location:** `parkFighter()` — line 278

**Change:** Replace the prompt toggle cycle with a full destroy-and-recreate. This eliminates any possibility of stale ProximityPrompt internal state.

Replace the existing prompt block (lines 286-299):
```lua
if state.prompt ~= nil then
    -- Force a replicated state transition instead of true->true no-op.
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

With:
```lua
if state.prompt ~= nil then
    local oldPrompt = state.prompt
    local parent = oldPrompt.Parent
    local objectText = oldPrompt.ObjectText
    local actionText = oldPrompt.ActionText
    local maxDist = oldPrompt.MaxActivationDistance
    local keyCode = oldPrompt.KeyboardKeyCode
    local holdDuration = oldPrompt.HoldDuration
    local requiresLOS = oldPrompt.RequiresLineOfSight

    oldPrompt:Destroy()

    local newPrompt = Instance.new("ProximityPrompt")
    newPrompt.ObjectText = objectText
    newPrompt.ActionText = actionText
    newPrompt.MaxActivationDistance = maxDist
    newPrompt.KeyboardKeyCode = keyCode
    newPrompt.HoldDuration = holdDuration
    newPrompt.RequiresLineOfSight = requiresLOS
    newPrompt.Enabled = true
    newPrompt.Parent = parent

    state.prompt = newPrompt

    -- Rewire the Triggered connection for the new prompt
    table.insert(state.connections, newPrompt.Triggered:Connect(function(player: Player)
        if state.pilot ~= nil then
            return
        end
        if not HealthManager.isAlive(state.entityId) then
            return
        end
        local character = player.Character
        if character == nil then
            return
        end
        local humanoid = character:FindFirstChildOfClass("Humanoid")
        if humanoid == nil then
            return
        end
        if humanoid.Sit then
            return
        end
        state.pilotSeat:Sit(humanoid)
    end))

    print(string.format(
        "[P10_PROMPT] parkFighter recreated prompt parent=%s enabled=%s",
        tostring(parent and parent:GetFullName() or "nil"),
        tostring(newPrompt.Enabled)
    ))
end
```

**Why:** The toggle cycle (false → defer → true) has failed across 5+ attempts. Roblox's ProximityPrompt may have internal rendering state that doesn't reset on Enabled toggles. Destroying and recreating the prompt instance is guaranteed to produce a fresh prompt with no stale state. The Triggered handler is duplicated here intentionally — it must include the `humanoid.Sit` check from Step 2.

**Important:** The new Triggered handler does NOT include the old vehicle-swap logic (which was removed in Step 2). It's simplified: check pilot, check alive, check character, check humanoid, check not seated, then seat.

**Pass condition:** ProximityPrompt appears after exiting the fighter. Can press E to re-enter.
**Fail condition:** Prompt still doesn't appear.

### Step 4: Diagnostic Prints

**File:** `src/Client/Vehicles/FighterClient.luau`

Verify the existing `[P10_EXIT]` print is present at top of `deactivate()` (it should be — was added previously). No change needed if present.

Add a print at the top of the auto-land block (after line 1465 `if inLanding and exitAutoLandActive then`):
```lua
print(string.format("[P10_AUTOLAND] active altError=%.2f hSpeed=%.2f vSpeed=%.2f",
    (targetAltitude or 0) - base.Position.Y,
    Vector3.new(physicalVelocity.X, 0, physicalVelocity.Z).Magnitude,
    physicalVelocity.Y))
```

Actually, `targetAltitude` is computed later in the block. Place this print AFTER the targetAltitude computation (after line 1488) and BEFORE the settled check (line 1510):
```lua
print(string.format("[P10_AUTOLAND] altError=%.2f hSpeed=%.2f vSpeed=%.2f",
    altError, horizontalVelocity.Magnitude, math.abs(nextVerticalSpeed)))
```

Wait — this would print every frame during auto-land, which is too spammy. Instead, only print once when settled:

The existing `[P10_AUTOLAND] settled` print at line 1524 is sufficient.

**File:** `src/Server/Vehicles/FighterServer.luau`

Verify the existing `[P10_EXIT_SERVER]` print is present at line 780. No change needed if present.

### Step 5: Clean Up releaseFighterMomentum Reference

**File:** `src/Server/Vehicles/FighterServer.luau`
**Location:** `playerRemovingConnection` handler — line 816

Currently calls `releaseFighterMomentum(state)` which sets `Anchored = false` — this is wrong for player removal. Should call `parkFighter(state)` instead (which anchors).

Replace line 816:
```lua
releaseFighterMomentum(state)
```

With:
```lua
parkFighter(state)
```

**Why:** When a player disconnects while piloting, the ship should park (anchor), not release momentum (unanchor and drift). `releaseFighterMomentum` unanchors the ship, which causes it to fall.

---

## Test Procedure

1. Sync Rojo. Verify sync via MCP (Step 0).
2. Enter fighter via E prompt.
3. Fly around briefly.
4. Press L to enter landing mode.
5. Press Space — should NOT exit. Ship stays in landing mode.
6. Press F to trigger auto-land.
7. Watch console for `[P10_AUTOLAND] settled` → `[P10_EXIT_SERVER] exit_remote received` → `[P10_PROMPT] parkFighter recreated prompt`.
8. After exit: ship frozen in place (anchored). No falling.
9. ProximityPrompt visible. Press E to re-enter. Should work.
10. Fly near another parked fighter. Press E while seated — nothing happens (Bug 3 fixed).
11. Land, exit, re-enter — prompt works repeatedly.

**If ship still falls after sync is confirmed:** Check console for `[P10_EXIT]` print. Report the `flightMode` and `exitAutoLandActive` values.
**If prompt still missing after sync is confirmed:** Check console for `[P10_PROMPT]` print. If the print appears but prompt doesn't show, the issue is client-side. Report.

---

## Build Order

1. **Step 0** — Sync verification. MUST pass before continuing.
2. **Step 1** — Block Jump exit (client). Prevents uncontrolled exits.
3. **Step 2** — Seated player check (server). Prevents Bug 3.
4. **Step 3** — Prompt nuclear recreate (server). Fixes Bug 2.
5. **Step 4** — Diagnostic prints (verify existing).
6. **Step 5** — Fix playerRemoving to use parkFighter.

---

## Files Modified

- `src/Client/Vehicles/FighterClient.luau` — Jump block bind/unbind, diagnostic verify
- `src/Server/Vehicles/FighterServer.luau` — seated check, prompt recreate, playerRemoving fix
