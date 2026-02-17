# Bug Fix: Social POI Transition Rotation Artifacts

**Target file:** `src/client/NPCClient.client.luau`
**No other files need changes.**

---

## Bug Description

1. Leaving social POI: occasional 180° turn then snap back to intended direction.
2. Entering social POI: occasional ~25° offset then correction.
3. General in/out social movement has visible snap artifacts.

## Root Cause

At every social state transition, the NPC inherits a rotation from the previous state that doesn't match the new state's target direction. `TurnSmoothing` slerps toward the correct direction, but the first several frames show visibly wrong facing while the NPC is moving.

## Fix: Four rotation seeds at social transition points

One concept, four insertion points: at each social state transition, seed the NPC's rotation to face the movement/target direction of the incoming state. The snap happens at a stationary moment (just stopped, just stood up, just arrived).

### Patch 1: Walking → Walking_to_seat

In the `walking` branch, inside the `poi.type == "social"` block, after `npc.seatTargetCFrame = poi.seatCFrame` and before the animation call, add:

```lua
-- Seed rotation to face seat before first walk-to-seat frame
if npc.model.PrimaryPart and poi.seatCFrame then
    local pos = npc.model.PrimaryPart.Position
    local seatPos = poi.seatCFrame.Position
    local dir = Vector3.new(seatPos.X - pos.X, 0, seatPos.Z - pos.Z)
    if dir.Magnitude > 0.01 then
        npc.model.PrimaryPart.CFrame = CFrame.lookAt(pos, pos + dir)
    end
end
```

### Patch 2: Walking_to_seat → Sitting

In the `walking_to_seat` branch, when `reachedSeat` is true, snap to full seat CFrame before playing sit animation. Replace the current arrival block with:

```lua
if reachedSeat then
    npc.state = "sitting"
    if npc.model.PrimaryPart and npc.seatTargetCFrame then
        npc.model.PrimaryPart.CFrame = npc.seatTargetCFrame
    end
    if not lodRuntimeEnabled or LODController.shouldAnimate(npc.lodTier) then
        NPCAnimator.playSit(npc)
    end
end
```

### Patch 3: Sitting → Walking_from_seat

In the `sitting` branch, after `npc.state = "walking_from_seat"` and `npc.dwellEndTime = nil`, add:

```lua
-- Seed rotation to face social waypoint before first walk-back frame
if npc.model.PrimaryPart and npc.preSeatCFrame then
    local pos = npc.model.PrimaryPart.Position
    local wpPos = npc.preSeatCFrame.Position
    local dir = Vector3.new(wpPos.X - pos.X, 0, wpPos.Z - pos.Z)
    if dir.Magnitude > 0.01 then
        npc.model.PrimaryPart.CFrame = CFrame.lookAt(pos, pos + dir)
    end
end
```

### Patch 4: Walking_from_seat → Walking

In the `walking_from_seat` branch, after `npc.seatTargetCFrame = nil` (inside the `reachedWaypoint` block), add:

```lua
-- Seed rotation to face next route waypoint before NPCMover takes over
if npc.model.PrimaryPart then
    local nextIdx = math.min(#npc.waypoints, npc.currentLeg + 1)
    local nextWp = npc.waypoints[nextIdx]
    if nextWp then
        local pos = npc.model.PrimaryPart.Position
        local dir = Vector3.new(nextWp.X - pos.X, 0, nextWp.Z - pos.Z)
        if dir.Magnitude > 0.01 then
            npc.model.PrimaryPart.CFrame = CFrame.lookAt(pos, pos + dir)
        end
    end
end
```

## Boundaries

- Only modify `NPCClient.client.luau`.
- Do NOT change `NPCMover.luau`, `moveModelTowardCFrame`, or any non-social heartbeat code.
- Do NOT change the social state machine flow (walking_to_seat → sitting → walking_from_seat → walking).
- Do NOT add new config values, types, or modules.
- Preserve all existing runtime contracts.
