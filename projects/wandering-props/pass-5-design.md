# Pass 5 Design: Visual Polish — Wandering Props

**Feature pass:** 5
**Based on:** feature-passes.md, state.md, golden-tests.md, live code in src/
**Existing code:** Config.luau, Types.luau, WaypointGraph.luau, RouteBuilder.luau, Remotes.luau, POIRegistry.luau, PopulationController.server.luau, NPCClient.client.luau, NPCMover.luau, NPCAnimator.luau, LODController.luau, ModelPool.luau
**Critic Status:** APPROVED (rev 2) — 1 blocking fixed (PathSmoother indexMap completeness), 9 flags noted
**Date:** 2026-02-16

---

## What This Pass Adds

Visual polish to make NPC movement look natural and believable:

1. **Corner beveling** — Client-side path smoothing that rounds sharp waypoint corners into quadratic Bezier arcs. NPCs follow curved paths at turns instead of zigzag lines.
2. **Smooth elevation** — Ground-snap raycast results are lerped over time instead of applied instantly. Steps and slopes produce gradual height changes.
3. **Smooth body rotation** — NPC facing direction is slerped each frame instead of snapping via `CFrame.lookAt`. Applies during route walking, scenic facing, and seat walk-in/out.
4. **Head look toward player** — NPCs randomly turn their heads to track nearby players via Neck Motor6D manipulation. LOD-gated to near tier only.
5. **Path lateral offset** — Server-side random perpendicular offset on intermediate waypoints so NPCs don't follow identical paths.
6. **Spawn/despawn fade** — Client-side transparency lerp for smooth appear/disappear transitions.

Changes are **mostly client-side**. The only server change is the lateral offset computation in `PopulationController.convertNodeIdsToWaypoints`. No new RemoteEvents.

---

## File Changes

### New Files
| File | Location | Purpose |
|------|----------|---------|
| PathSmoother.luau | src/client/ | Bevel raw waypoints into smoothed curves on spawn |
| HeadLookController.luau | src/client/ | Neck Motor6D head-tracking toward nearby players |

### Modified Files
| File | What's Changing | Why |
|------|----------------|-----|
| NPCClient.client.luau | Integrate path smoothing, fade system, head look updates, smooth dwelling-face into heartbeat and spawn/despawn flows | Core integration point for all 6 features |
| NPCMover.luau | Add smooth Y lerp and smooth rotation slerp to `update()` and `moveModelTowardCFrame()` | Elevation and rotation smoothing |
| Config.luau | Add config values for all 6 features | Tunable polish parameters |
| Types.luau | Extend NPCState with fade, head look, and dwell-facing fields | Client needs these fields for new behaviors |
| PopulationController.server.luau | Add lateral offset in `convertNodeIdsToWaypoints` | Path variation between NPCs |

### Unchanged Files
| File | Why Unchanged |
|------|---------------|
| LODController.luau | LOD tier logic unchanged |
| ModelPool.luau | Pool acquire/release unchanged (fade handles transparency reset) |
| NPCAnimator.luau | Animation API unchanged |
| WaypointGraph.luau | Graph building unchanged |
| RouteBuilder.luau | Route computation unchanged |
| Remotes.luau | No new remotes |
| POIRegistry.luau | POI discovery unchanged |

---

## Feature 1: Corner Beveling (Curved Pathing)

### PathSmoother.luau (NEW)

```lua
local PathSmoother = {}

-- Bevel intermediate waypoints into smooth curves.
-- Protected indices (POI stops, first, last) are NOT beveled.
-- Returns: smoothedWaypoints, updatedPoiStops (with shifted waypointIndex values).
--
-- Called by: NPCClient.spawnNPCFromData, after receiving raw waypoints from server.
function PathSmoother.bevel(
    waypoints: { Vector3 },
    poiStops: { { waypointIndex: number, [string]: any } }?,
    bevelRadius: number,
    bevelSegments: number
): ({ Vector3 }, { { waypointIndex: number, [string]: any } }?)
end

return PathSmoother
```

### Algorithm

All five waypoint cases are handled explicitly to ensure `indexMap` is complete:

1. Build a set of **protected indices**: index 1 (spawn), index #waypoints (despawn), and every `poiStop.waypointIndex`.
2. **First waypoint**: `indexMap[1] = 1`. Insert `waypoints[1]` into smoothed array.
3. **For each intermediate waypoint** at index `i` (where `i > 1` and `i < #waypoints`):
   - **Case A — Protected** (POI stop waypoint): Copy position unchanged. Set `indexMap[i] = #smoothed + 1`. Insert into smoothed array.
   - **Case B — Nearly straight** (`dot > 0.95`): Copy position unchanged. Set `indexMap[i] = #smoothed + 1`. Insert into smoothed array. (No bevel needed for gentle angles.)
   - **Case C — Beveled** (sharp corner):
     - Compute incoming direction `dirIn = (waypoints[i] - waypoints[i-1]).Unit` and outgoing direction `dirOut = (waypoints[i+1] - waypoints[i]).Unit`.
     - `radius = math.min(bevelRadius, (waypoints[i] - waypoints[i-1]).Magnitude / 2, (waypoints[i+1] - waypoints[i]).Magnitude / 2)` — clamp to half the shortest adjacent leg to prevent overshoot.
     - `approach = waypoints[i] + (waypoints[i-1] - waypoints[i]).Unit * radius`
     - `depart = waypoints[i] + (waypoints[i+1] - waypoints[i]).Unit * radius`
     - Set `indexMap[i] = #smoothed + 1 + math.floor(bevelSegments / 2)` (maps to the middle of the arc).
     - Generate `bevelSegments + 1` points along a quadratic Bezier: `P(t) = (1-t)^2 * approach + 2*(1-t)*t * waypoints[i] + t^2 * depart` for `t = 0, 1/bevelSegments, 2/bevelSegments, ..., 1`.
     - Insert all Bezier points into smoothed array.
4. **Last waypoint**: Set `indexMap[#waypoints] = #smoothed + 1`. Insert `waypoints[#waypoints]` into smoothed array.
5. **Update poiStops**: For each stop, set `stop.waypointIndex = indexMap[stop.waypointIndex]`. Every `indexMap` entry is guaranteed non-nil because all five cases above set it explicitly.
6. Return smoothed waypoints and updated poiStops.

**Edge cases:**
- 2 waypoints (spawn + despawn, no intermediates): Loop in step 3 doesn't execute. Returns [spawn, despawn] unchanged.
- All intermediates are protected: Each gets copied unchanged with its index mapped. No beveling occurs.
- Adjacent bevels: Each bevel is computed independently. Bevel radius is clamped to half the adjacent leg length, preventing overlap between adjacent bevels.

### Integration with NPCClient.spawnNPCFromData

After receiving raw waypoints from server, before calculating route state:

```lua
local waypoints = data.waypoints
local poiStops = data.poiStops

if Config.BevelEnabled and #waypoints > 2 then
    waypoints, poiStops = PathSmoother.bevel(
        waypoints, poiStops,
        Config.BevelRadius, Config.BevelSegments
    )
end

-- All subsequent code uses smoothed waypoints and updated poiStops.
-- Store smoothed waypoints in the NPC record.
```

The smoothed waypoints are stored on the NPC record. All client-side calculations (`calculateRouteState`, `NPCMover.update`, `restoreFromFarTier`) use the smoothed waypoints. The server continues using raw waypoints for despawn timing — the slight distance difference (curves vs straight) is within `ClientDespawnBuffer`.

---

## Feature 2: Smooth Elevation (Y Lerp)

### NPCMover.luau Changes

Modify the ground-snap raycast block in `NPCMover.update` (current lines 122-129):

```lua
-- BEFORE (current):
local snappedY = npc.lastGroundY
if not skipRaycast then
    local rayOrigin = flatPosition + Vector3.new(0, Config.SnapRayOriginOffset, 0)
    local rayDirection = Vector3.new(0, -Config.SnapRayLength, 0)
    local hitResult = Workspace:Raycast(rayOrigin, rayDirection, raycastParams)
    if hitResult then
        snappedY = hitResult.Position.Y + Config.SnapHipOffset
        npc.lastGroundY = snappedY
    end
end

-- AFTER:
local snappedY = npc.lastGroundY
if not skipRaycast then
    local rayOrigin = flatPosition + Vector3.new(0, Config.SnapRayOriginOffset, 0)
    local rayDirection = Vector3.new(0, -Config.SnapRayLength, 0)
    local hitResult = Workspace:Raycast(rayOrigin, rayDirection, raycastParams)
    if hitResult then
        local targetY = hitResult.Position.Y + Config.SnapHipOffset
        if Config.GroundSnapSmoothing then
            local alpha = math.min(1, dt * Config.GroundSnapLerpSpeed)
            snappedY = npc.lastGroundY + (targetY - npc.lastGroundY) * alpha
        else
            snappedY = targetY
        end
        npc.lastGroundY = snappedY
    end
end
```

**Note:** `restoreFromFarTier` in NPCClient does an immediate raycast for ground snap when restoring from far tier. This should remain an **instant snap** (no lerp) since the NPC is being placed from scratch and needs correct initial Y. No changes to restoreFromFarTier.

---

## Feature 3: Smooth Body Rotation (Facing Slerp)

### NPCMover.luau Changes

Modify the facing/CFrame assignment block in `NPCMover.update` (current lines 135-143):

```lua
-- BEFORE (current):
local newCFrame
if (targetFlat - snappedPosition).Magnitude > 0.001 then
    newCFrame = CFrame.lookAt(snappedPosition, targetFlat)
else
    newCFrame = CFrame.new(snappedPosition)
end
if npc.model.PrimaryPart then
    npc.model.PrimaryPart.CFrame = newCFrame
end

-- AFTER:
local newCFrame
if (targetFlat - snappedPosition).Magnitude > 0.001 then
    local targetCFrame = CFrame.lookAt(snappedPosition, targetFlat)
    if Config.TurnSmoothing and npc.model.PrimaryPart then
        local currentRotation = npc.model.PrimaryPart.CFrame.Rotation
        local targetRotation = targetCFrame.Rotation
        local alpha = math.min(1, dt * Config.TurnLerpSpeed)
        local smoothedRotation = currentRotation:Lerp(targetRotation, alpha)
        newCFrame = smoothedRotation + snappedPosition
    else
        newCFrame = targetCFrame
    end
else
    newCFrame = CFrame.new(snappedPosition)
end
if npc.model.PrimaryPart then
    npc.model.PrimaryPart.CFrame = newCFrame
end
```

**Note on `CFrame.Rotation + Vector3`:** In Roblox, `CFrame.Rotation` returns a CFrame at (0,0,0) with only the rotation component. Adding a Vector3 to a CFrame adds to its position. So `smoothedRotation + snappedPosition` produces a CFrame at `snappedPosition` with the smoothed rotation.

### NPCClient.moveModelTowardCFrame Changes

Apply the same smooth rotation to seat walk-in/walk-out (current lines 79-83):

```lua
-- BEFORE (current):
if flatDirection.Magnitude > 0.001 then
    npc.model.PrimaryPart.CFrame = CFrame.lookAt(newPos, newPos + flatDirection)
else
    npc.model.PrimaryPart.CFrame = CFrame.new(newPos)
end

-- AFTER:
if flatDirection.Magnitude > 0.001 then
    if Config.TurnSmoothing then
        local targetCFrame = CFrame.lookAt(newPos, newPos + flatDirection)
        local currentRotation = npc.model.PrimaryPart.CFrame.Rotation
        local alpha = math.min(1, dt * Config.TurnLerpSpeed)
        local smoothedRotation = currentRotation:Lerp(targetCFrame.Rotation, alpha)
        npc.model.PrimaryPart.CFrame = smoothedRotation + newPos
    else
        npc.model.PrimaryPart.CFrame = CFrame.lookAt(newPos, newPos + flatDirection)
    end
else
    npc.model.PrimaryPart.CFrame = CFrame.new(newPos)
end
```

### Scenic POI Smooth Facing (NPCClient Heartbeat)

Currently when entering dwelling state, the NPC snaps to face the view target instantly. Change to gradual turn:

**When entering dwelling state** (heartbeat walking→dwelling transition):
```lua
if poi.type == "scenic" then
    npc.state = "dwelling"
    npc.dwellEndTime = Workspace:GetServerTimeNow() + poi.dwellTime
    npc.dwellFacingTarget = poi.viewTarget  -- NEW: store target instead of snapping
    -- Do NOT snap CFrame here. Let the dwelling heartbeat slerp handle it.
    if not lodRuntimeEnabled or LODController.shouldAnimate(npc.lodTier) then
        NPCAnimator.update(npc, false)
    end
end
```

**Dwelling heartbeat branch** — add smooth facing per frame:
```lua
elseif npc.state == "dwelling" then
    -- Smooth face toward view target.
    if Config.TurnSmoothing and npc.dwellFacingTarget and npc.model.PrimaryPart then
        local pos = npc.model.PrimaryPart.Position
        local flatTarget = Vector3.new(npc.dwellFacingTarget.X, pos.Y, npc.dwellFacingTarget.Z)
        if (flatTarget - pos).Magnitude > 0.01 then
            local targetRotation = CFrame.lookAt(pos, flatTarget).Rotation
            local currentRotation = npc.model.PrimaryPart.CFrame.Rotation
            local alpha = math.min(1, dt * Config.TurnLerpSpeed)
            local smoothedRotation = currentRotation:Lerp(targetRotation, alpha)
            npc.model.PrimaryPart.CFrame = smoothedRotation + pos
        end
    end
    if not lodRuntimeEnabled or LODController.shouldAnimate(npc.lodTier) then
        NPCAnimator.update(npc, false)
    end
    if npc.dwellEndTime and Workspace:GetServerTimeNow() >= npc.dwellEndTime then
        npc.nextPoiStopIdx += 1
        npc.state = "walking"
        npc.dwellEndTime = nil
        npc.dwellFacingTarget = nil  -- Clear
    end
```

**Late-join / far-tier restore:** When `spawnNPCFromData` or `restoreFromFarTier` places an NPC that is already in dwelling state, it should still snap to the view target instantly (the NPC has been dwelling for a while and should already be facing correctly). Set `npc.dwellFacingTarget = nil` in these cases to prevent further slerping toward an already-achieved target.

---

## Feature 4: Head Look Toward Player

### HeadLookController.luau (NEW)

```lua
local HeadLookController = {}

-- Initialize head-look state for an NPC. Finds the Neck Motor6D and caches original C0.
-- If no Neck Motor6D is found, head-look is silently disabled for this NPC.
-- Called by: NPCClient.spawnNPCFromData, after model is parented.
function HeadLookController.init(npc)
    -- Search model descendants for Motor6D named "Neck".
    -- Store: npc.headLookNeckMotor, npc.headLookOriginalC0
    -- Initialize: npc.headLookActive = false, npc.headLookAlpha = 0,
    --             npc.headLookEndTime = 0, npc.headLookNextCheckTime = 0
end

-- Update head-look each frame. Handles activation checks, smooth lerp, and restoration.
-- Called by: NPCClient heartbeat, for near-tier NPCs only.
-- playerPosition: LocalPlayer HumanoidRootPart position (already fetched for LOD checks).
function HeadLookController.update(npc, playerPosition: Vector3, dt: number)
    -- 1. If no neckMotor cached, return immediately.
    -- 2. Check activation timer: if now >= npc.headLookNextCheckTime:
    --    a. Compute distance to player.
    --    b. If within Config.HeadLookDistance and not already active:
    --       Roll random chance (Config.HeadLookChance).
    --       If success: set npc.headLookActive = true,
    --                   npc.headLookEndTime = now + Config.HeadLookDuration.
    --    c. Set npc.headLookNextCheckTime = now + Config.HeadLookCheckInterval.
    -- 3. If active and now >= npc.headLookEndTime: set npc.headLookActive = false.
    -- 4. Compute target alpha: 1 if active, 0 if not.
    -- 5. Lerp npc.headLookAlpha toward target at Config.HeadLookLerpSpeed.
    -- 6. If alpha < 0.01: restore original C0, return.
    -- 7. Compute look angles:
    --    a. Head position from neckMotor.Part1.Position (or estimated).
    --    b. Direction to player, projected into NPC's local frame.
    --    c. Yaw = atan2(localX, localZ), clamped to Config.HeadLookMaxYaw degrees.
    --    d. Pitch = atan2(-localY, forward), clamped to Config.HeadLookMaxPitch degrees.
    -- 8. Build rotation: CFrame.Angles(pitch * alpha, yaw * alpha, 0).
    -- 9. Apply: neckMotor.C0 = originalC0 * rotation.
end

-- Reset head-look to original state. Restores Neck C0 to cached value.
-- Called by: NPCClient.removeNPC (before pool release), and when entering far tier.
function HeadLookController.reset(npc)
    -- If npc.headLookNeckMotor and npc.headLookOriginalC0:
    --   npc.headLookNeckMotor.C0 = npc.headLookOriginalC0
    -- Set npc.headLookAlpha = 0, npc.headLookActive = false.
end

return HeadLookController
```

### Neck Motor6D Discovery

R15 rig structure: The Neck Motor6D connects UpperTorso (Part0) to Head (Part1). In standard R15, Motor6Ds are parented to Part1 (Head). Search strategy:

```lua
for _, desc in ipairs(npc.model:GetDescendants()) do
    if desc:IsA("Motor6D") and desc.Name == "Neck" then
        npc.headLookNeckMotor = desc
        npc.headLookOriginalC0 = desc.C0
        break
    end
end
```

If the model has no Neck Motor6D (non-R15 rig, prop model, etc.), head-look is silently skipped for that NPC.

### Integration with NPCClient Heartbeat

Head look runs inside the per-NPC loop, **after** movement/state machine updates, **only for near-tier NPCs**:

```lua
-- After state machine and animation updates:
if Config.HeadLookEnabled and npc.lodTier == "near" and playerPosition then
    HeadLookController.update(npc, playerPosition, dt)
elseif npc.headLookAlpha and npc.headLookAlpha > 0 then
    -- NPC left near tier or head look disabled; reset smoothly
    HeadLookController.reset(npc)
end
```

**Note on playerPosition availability:** Currently playerPosition is only fetched on LOD check frames. For head look to work every frame, we need playerPosition every frame for near-tier NPCs. Change: always fetch playerPosition when HeadLookEnabled is true (or cache it across frames):

```lua
local playerPosition = nil
if isLODCheckFrame or Config.HeadLookEnabled then
    local localPlayer = Players.LocalPlayer
    local character = localPlayer and localPlayer.Character
    local rootPart = character and character:FindFirstChild("HumanoidRootPart")
    if rootPart and rootPart:IsA("BasePart") then
        playerPosition = rootPart.Position
    end
end
```

### Pool and Cleanup

- `removeNPC` calls `HeadLookController.reset(npc)` before pool release to restore original Neck C0.
- `restoreFromFarTier` calls `HeadLookController.reset(npc)` to clear stale head-look state.
- Pooled models retain their Neck Motor6D and original C0. On re-acquire, `HeadLookController.init` re-caches (the motor6D and C0 are unchanged).

---

## Feature 5: Path Lateral Offset

### PopulationController.server.luau Changes

Modify `convertNodeIdsToWaypoints` (current lines 431-443):

```lua
-- BEFORE (current):
local function convertNodeIdsToWaypoints(pathNodeIds, poiWaypointIndexSet)
    local waypoints = {}
    local indexSet = poiWaypointIndexSet or {}
    for i, nodeId in ipairs(pathNodeIds) do
        local node = graph.nodes[nodeId]
        if node.zoneSize and not indexSet[i] then
            table.insert(waypoints, randomizeZonePosition(node))
        else
            table.insert(waypoints, node.position)
        end
    end
    return waypoints
end

-- AFTER:
local function convertNodeIdsToWaypoints(pathNodeIds, poiWaypointIndexSet)
    local waypoints = {}
    local indexSet = poiWaypointIndexSet or {}
    local maxOffset = Config.PathLateralOffsetMax or 0
    for i, nodeId in ipairs(pathNodeIds) do
        local node = graph.nodes[nodeId]
        if node.zoneSize and not indexSet[i] then
            table.insert(waypoints, randomizeZonePosition(node))
        elseif maxOffset > 0 and i > 1 and i < #pathNodeIds and not indexSet[i] then
            -- Intermediate, non-zone, non-POI waypoint: add lateral offset.
            local prevPos = graph.nodes[pathNodeIds[i - 1]].position
            local nextPos = graph.nodes[pathNodeIds[i + 1]].position
            local forward = nextPos - prevPos
            local flatForward = Vector3.new(forward.X, 0, forward.Z)
            if flatForward.Magnitude > 0.01 then
                local perpendicular = Vector3.new(-flatForward.Z, 0, flatForward.X).Unit
                local offset = rng:NextNumber(-maxOffset, maxOffset)
                table.insert(waypoints, node.position + perpendicular * offset)
            else
                table.insert(waypoints, node.position)
            end
        else
            table.insert(waypoints, node.position)
        end
    end
    return waypoints
end
```

**Rules:**
- First waypoint (spawn) and last waypoint (despawn): no offset (NPC must arrive at exact spawn/despawn positions).
- POI stop waypoints (`indexSet[i]`): no offset (NPC must arrive at exact POI position for dwell/seat).
- Zone waypoints: already randomized by `randomizeZonePosition`, no additional offset.
- All other intermediate waypoints: perpendicular offset of `[-maxOffset, +maxOffset]` studs.

**Config:** `PathLateralOffsetMax = 2` (studs). Set to 0 to disable.

---

## Feature 6: Spawn/Despawn Fade

### Fade-In (on spawn)

In `NPCClient.spawnNPCFromData`, after parenting the model and before applying initial animation state:

```lua
if Config.FadeEnabled then
    local transparencies = {}
    for _, part in ipairs(clonedModel:GetDescendants()) do
        if part:IsA("BasePart") then
            transparencies[part] = part.Transparency
            part.Transparency = 1
        end
    end
    npc.partTransparencies = transparencies
    npc.fadeDirection = "in"
    npc.fadeProgress = 0
end
```

### Fade-Out (on route completion)

When the NPC enters "finished" state in the heartbeat:

```lua
elseif npc.state == "finished" then
    -- Start fade-out if not already fading.
    if Config.FadeEnabled and npc.fadeDirection ~= "out" then
        npc.fadeDirection = "out"
        npc.fadeProgress = 0
        if not npc.partTransparencies then
            local transparencies = {}
            for _, part in ipairs(npc.model:GetDescendants()) do
                if part:IsA("BasePart") then
                    transparencies[part] = part.Transparency
                end
            end
            npc.partTransparencies = transparencies
        end
    end
    -- ... existing animation update ...
```

### Fade Update (heartbeat, per NPC)

Run near the top of the per-NPC loop, before state machine:

```lua
if npc.fadeDirection then
    local fadeDuration = if npc.fadeDirection == "in"
        then Config.SpawnFadeDuration
        else Config.DespawnFadeDuration
    npc.fadeProgress = math.min(1, npc.fadeProgress + dt / math.max(0.01, fadeDuration))

    -- alpha: 0 = fully transparent, 1 = fully visible.
    local alpha = if npc.fadeDirection == "in"
        then npc.fadeProgress
        else (1 - npc.fadeProgress)

    if npc.partTransparencies then
        for part, original in pairs(npc.partTransparencies) do
            if part and part.Parent then
                -- Lerp between fully transparent (1) and original transparency.
                part.Transparency = 1 - alpha * (1 - original)
            end
        end
    end

    if npc.fadeProgress >= 1 then
        if npc.fadeDirection == "in" then
            -- Restore exact original transparencies.
            if npc.partTransparencies then
                for part, original in pairs(npc.partTransparencies) do
                    if part and part.Parent then
                        part.Transparency = original
                    end
                end
            end
            npc.partTransparencies = nil
        end
        npc.fadeDirection = nil
    end
end
```

### Pool Transparency Cleanup

In `removeNPC`, before pool release, restore original transparencies so pooled models don't have stale transparency:

```lua
-- In removeNPC, before ModelPool.release:
if npc.partTransparencies then
    for part, original in pairs(npc.partTransparencies) do
        if part and part.Parent then
            part.Transparency = original
        end
    end
    npc.partTransparencies = nil
end
```

### Fade + LOD Interaction

- **Entering far tier during fade-in:** Stop fade. Store `lastKnownPosition`. Unparent model. When restored from far tier, the NPC will re-enter spawnNPCFromData logic via `restoreFromFarTier` — do NOT restart fade (NPC has been visible long enough that the fade window has likely passed). Set `npc.fadeDirection = nil` on far-tier entry.
- **Fade-out during far tier:** If NPC is in "finished" state and enters far tier, the server will send despawn event anyway. No special handling needed.

---

## New Data Structures

### Types.luau Changes

```lua
-- MODIFIED: NPCState gains new fields for Pass 5
export type NPCState = {
    -- ... all existing fields unchanged (Pass 1-4) ...

    -- NEW fields for Pass 5:
    dwellFacingTarget: Vector3?,          -- Scenic POI view target for smooth facing slerp
    fadeDirection: "in" | "out" | nil,     -- Current fade direction
    fadeProgress: number,                  -- 0-1 fade progress
    partTransparencies: { [BasePart]: number }?, -- Original part transparencies for fade
    headLookNeckMotor: Motor6D?,          -- Cached Neck Motor6D reference
    headLookOriginalC0: CFrame?,          -- Original Neck C0 for reset
    headLookActive: boolean,              -- Currently looking at player
    headLookEndTime: number,              -- When to stop looking
    headLookAlpha: number,                -- Current look blend weight (0-1)
    headLookNextCheckTime: number,        -- Next random-chance check time
}
```

---

## New Config Values

```lua
-- CORNER BEVELING
Config.BevelEnabled = true
Config.BevelRadius = 3             -- studs; max rounding radius at corners. Range: 0.5-10.
Config.BevelSegments = 4           -- arc segments per bevel. Range: 2-8. Higher = smoother curve.

-- SMOOTH ELEVATION
Config.GroundSnapSmoothing = true
Config.GroundSnapLerpSpeed = 15    -- lerp speed; higher = faster snap to target Y. Range: 5-30.

-- SMOOTH ROTATION
Config.TurnSmoothing = true
Config.TurnLerpSpeed = 8           -- slerp speed; higher = faster turn. Range: 3-20.

-- HEAD LOOK
Config.HeadLookEnabled = true
Config.HeadLookDistance = 30        -- studs; max distance to trigger head look. Range: 10-60.
Config.HeadLookChance = 0.3         -- probability per check. Range: 0-1.
Config.HeadLookDuration = 3         -- seconds to maintain look. Range: 1-8.
Config.HeadLookCheckInterval = 2    -- seconds between random-chance checks. Range: 0.5-5.
Config.HeadLookMaxYaw = 70          -- degrees; max horizontal head turn. Range: 30-90.
Config.HeadLookMaxPitch = 30        -- degrees; max vertical head tilt. Range: 10-45.
Config.HeadLookLerpSpeed = 5        -- smoothing speed for head rotation. Range: 2-10.

-- PATH LATERAL OFFSET
Config.PathLateralOffsetMax = 2     -- studs; max perpendicular offset. Range: 0-5. 0 = disabled.

-- SPAWN/DESPAWN FADE
Config.FadeEnabled = true
Config.SpawnFadeDuration = 0.8      -- seconds; fade-in duration on spawn. Range: 0.2-2.
Config.DespawnFadeDuration = 0.6    -- seconds; fade-out duration on route completion. Range: 0.2-2.
```

---

## Integration Pass (against real code)

### Data Lifecycle Traces

**Smoothed waypoints (client-side)**
- **Created by:** NPCClient.spawnNPCFromData → PathSmoother.bevel(data.waypoints, data.poiStops, ...)
- **Stored in:** npc.waypoints (replaces raw waypoints in NPC record)
- **Read by:** NPCMover.update, calculateRouteState, restoreFromFarTier — all use npc.waypoints
- **Cleaned up by:** removeNPC → NPC removed from activeNPCs
- **Server impact:** None. Server uses raw waypoints for timing. Client expectedDespawnTime calculation uses smoothed waypoints but `ClientDespawnBuffer` of 10s absorbs the tiny distance difference.

**npc.dwellFacingTarget (Vector3?)**
- **Created by:** NPCClient heartbeat, walking→dwelling transition → set from `poi.viewTarget`
- **Read by:** NPCClient heartbeat, dwelling branch → slerp rotation toward target
- **Cleared by:** NPCClient heartbeat, dwelling→walking transition → set to nil
- **Also set to nil by:** restoreFromFarTier (dwelling NPCs restored with instant facing), spawnNPCFromData (same)

**npc.fadeDirection / fadeProgress / partTransparencies**
- **Created by:** NPCClient.spawnNPCFromData (fade-in) or heartbeat finished→fade-out
- **Updated by:** NPCClient heartbeat fade update block
- **Cleared by:** Fade completion (fadeProgress >= 1), or removeNPC (transparency cleanup before pool)
- **Stored in:** NPC record; partTransparencies is a dictionary keyed by BasePart Instance
- **Pool safety:** removeNPC restores original transparencies before pool release

**Head look state (headLookNeckMotor, headLookOriginalC0, headLookActive, headLookAlpha, headLookEndTime, headLookNextCheckTime)**
- **Created by:** HeadLookController.init(npc) → called in spawnNPCFromData after model parented
- **Updated by:** HeadLookController.update(npc, playerPosition, dt) → called in heartbeat for near-tier NPCs
- **Cleaned up by:** HeadLookController.reset(npc) → called in removeNPC (before pool release) and on far-tier entry
- **Pool safety:** Motor6D C0 restored to original on reset. On re-acquire, HeadLookController.init re-caches (same Motor6D, same C0).

**Lateral offset (server-side)**
- **Created by:** PopulationController.convertNodeIdsToWaypoints → perpendicular offset added
- **Passed to:** Client via NPCSpawned remote (baked into waypoints array)
- **Lifetime:** Part of waypoints array; lives with NPC record on both server and client
- **No cleanup needed:** Offset is part of the position data, not a separate field

### API Composition Checks (new calls only)

| Caller | Callee | Args Match | Return Handled | Verified Against |
|--------|--------|-----------|----------------|-----------------|
| NPCClient.spawnNPCFromData | PathSmoother.bevel(waypoints, poiStops, radius, segments) | {Vector3}, table?, number, number → {Vector3}, table? | Both returns stored; nil poiStops handled | New module |
| NPCClient heartbeat | HeadLookController.update(npc, playerPos, dt) | table, Vector3, number → void | void | New module |
| NPCClient.spawnNPCFromData | HeadLookController.init(npc) | table → void | void | New module |
| NPCClient.removeNPC | HeadLookController.reset(npc) | table → void | void | New module |
| NPCMover.update | Config.GroundSnapSmoothing | boolean read | Guards lerp vs snap | Config.luau line new |
| NPCMover.update | Config.TurnSmoothing | boolean read | Guards slerp vs snap | Config.luau line new |
| NPCMover.update | Config.TurnLerpSpeed | number read | Used as lerp alpha multiplier | Config.luau line new |
| NPCMover.update | CFrame.Rotation | CFrame property | Returns rotation-only CFrame | Roblox API: CFrame.Rotation exists |
| NPCMover.update | CFrame:Lerp(target, alpha) | CFrame, CFrame, number → CFrame | Used for rotation slerp | Roblox API: CFrame:Lerp slerps rotation |
| PopulationController.convertNodeIdsToWaypoints | Config.PathLateralOffsetMax | number read | Used as offset bound | Config.luau line new |

---

## Diagnostics Updates

### New Reason Codes
- `BEVEL_PATH` — Fires when path is beveled on spawn. Format: `[WanderingProps] BEVEL_PATH %s raw_legs=%d smoothed_legs=%d`. Enabled by DiagnosticsEnabled.
- `HEAD_LOOK_START` — Fires when NPC starts looking at player. Format: `[WanderingProps] HEAD_LOOK_START %s distance=%.1f`.
- `FADE_IN_START` / `FADE_OUT_START` — Fires on fade begin. Format: `[WanderingProps] FADE_IN_START %s duration=%.2f`.

### New Health Counters (client-side)
- `beveledPathsTotal` — Total paths that were beveled.
- `headLookTriggersTotal` — Total head-look activations.

---

## Startup Validator Updates

### Client-side (NPCClient startup)
```lua
if Config.BevelEnabled then
    if Config.BevelRadius <= 0 then
        warn("[WanderingProps] WARNING: BevelRadius must be > 0. Beveling disabled.")
        -- Fall back: Config.BevelEnabled treated as false.
    end
    if Config.BevelSegments < 2 then
        warn("[WanderingProps] WARNING: BevelSegments must be >= 2. Using 2.")
    end
end

if Config.HeadLookEnabled then
    if Config.HeadLookMaxYaw <= 0 or Config.HeadLookMaxPitch <= 0 then
        warn("[WanderingProps] WARNING: HeadLookMaxYaw and HeadLookMaxPitch must be > 0. Head look disabled.")
    end
end
```

No server-side startup changes needed. `PathLateralOffsetMax` of 0 naturally disables the feature.

---

## Build Guardrails

- All 6 features are independently toggleable via Config flags. When all are disabled, behavior must be identical to Pass 4.
- Do NOT modify LODController, ModelPool, or NPCAnimator APIs.
- Do NOT add new RemoteEvents.
- Server-side changes are limited to `convertNodeIdsToWaypoints` in PopulationController and new Config values.
- PathSmoother must not modify POI stop waypoint positions — only intermediate waypoints get beveled.
- HeadLookController must handle missing Neck Motor6D gracefully (skip, not error).
- Fade must restore original transparencies before pool release — pooled models must have clean transparency state.
