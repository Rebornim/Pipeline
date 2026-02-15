# Pass 4 Design: Optimization — Wandering Props

**Feature pass:** 4 of 4
**Based on:** feature-passes.md, state.md, golden-tests.md, live code in src/
**Existing code:** Config.luau, Types.luau, WaypointGraph.luau, RouteBuilder.luau, Remotes.luau, POIRegistry.luau, PopulationController.server.luau, NPCClient.client.luau, NPCMover.luau, NPCAnimator.luau
**Critic Status:** APPROVED (rev 2)
**Date:** 2026-02-15

---

## What This Pass Adds

Performance optimizations to hit the 70 NPC target:

1. **LOD tiers** — Client skips expensive per-frame work (raycasts, animations, CFrame writes) for NPCs far from the local player. Four tiers: near, low, mid, far.
2. **Model pooling** — Client reuses despawned NPC models instead of Clone()/Destroy() every cycle. Pooled models retain their Animator and loaded AnimationTracks.

All changes are **client-side only**. No server changes, no new RemoteEvents, no changes to the spawn/despawn wire protocol. The server already computes route timing independently of client visuals.

---

## File Changes

### New Files
| File | Location | Purpose |
|------|----------|---------|
| LODController.luau | src/client/ | LOD tier computation and tier-change detection |
| ModelPool.luau | src/client/ | Model reuse pool keyed by modelName |

### Modified Files
| File | What's Changing | Why |
|------|----------------|-----|
| NPCClient.client.luau | Integrate LOD checks and pool acquire/release into heartbeat and spawn/despawn flows | Core integration point for both features |
| NPCMover.luau | Add optional `skipRaycast` parameter to `update()` | Low/mid tier NPCs skip raycasts on some frames |
| NPCAnimator.luau | Add `stopAll(npc)` helper | Clean stop of all tracks on mid/far tier transition |
| Config.luau | Add LOD distance thresholds, raycast skip rates, pool size | Tunable optimization parameters |
| Types.luau | Add LODTier type alias; extend NPCState with lodTier, modelName, startTime, raycastPhase | Client needs these fields for LOD and pool logic |

### Unchanged Files
| File | Why Unchanged |
|------|---------------|
| PopulationController.server.luau | Server route timing is already independent of client visuals |
| POIRegistry.luau | Server-only; no optimization-related changes |
| WaypointGraph.luau | Graph building unchanged |
| RouteBuilder.luau | Route computation unchanged |
| Remotes.luau | No new remotes |

---

## New/Modified APIs

### LODController.luau (NEW)

```lua
local LODController = {}

-- Compute the LOD tier for an NPC based on distance to the local player.
-- Returns: "near" | "low" | "mid" | "far"
-- Called by: NPCClient heartbeat loop, every LODCheckInterval frames.
function LODController.computeTier(npcPosition: Vector3, playerPosition: Vector3): string
    -- Uses Config.LODNearDistance, Config.LODLowDistance, Config.LODMidDistance.
    -- dist <= LODNearDistance → "near"
    -- dist <= LODLowDistance → "low"
    -- dist <= LODMidDistance → "mid"
    -- dist > LODMidDistance → "far"
end

-- Determine whether this NPC should raycast this frame.
-- Returns: true if raycast should happen.
-- near: always true.
-- low: true when (globalFrame + raycastPhase) % LODLowRaycastSkip == 0.
-- mid: true when (globalFrame + raycastPhase) % LODMidRaycastSkip == 0.
-- far: always false.
function LODController.shouldRaycast(tier: string, globalFrame: number, raycastPhase: number): boolean
end

-- Determine whether this NPC should run animation updates this frame.
-- near/low: true. mid/far: false.
function LODController.shouldAnimate(tier: string): boolean
end

-- Determine whether this NPC should run movement+CFrame updates this frame.
-- near/low/mid: true. far: false.
function LODController.shouldMove(tier: string): boolean
end

return LODController
```

### ModelPool.luau (NEW)

```lua
local ModelPool = {}

-- Pool entry type (internal):
-- {
--     model: Model,
--     animator: Animator,
--     walkTrack: AnimationTrack,
--     idleTrack: AnimationTrack,
--     sitTrack: AnimationTrack,
-- }

-- Initialize the pool. Call once during NPCClient startup.
function ModelPool.init(maxPerModel: number)
    -- maxPerModel: maximum pooled models per modelName. Default from Config.PoolMaxPerModel.
end

-- Try to acquire a pooled model for the given modelName.
-- Returns: poolEntry table or nil if pool is empty for this name.
-- The returned model has Parent = nil, all tracks stopped.
-- Caller must: position the model, set Parent to ActiveNPCsFolder, start animations.
function ModelPool.acquire(modelName: string): { model: Model, animator: Animator, walkTrack: AnimationTrack, idleTrack: AnimationTrack, sitTrack: AnimationTrack }?
end

-- Return a model to the pool after despawn or NPC removal.
-- Caller must stop all tracks BEFORE calling this.
-- If pool is full for this modelName, the model is Destroy()'d instead.
-- Sets model.Parent = nil internally.
function ModelPool.release(modelName: string, entry: { model: Model, animator: Animator, walkTrack: AnimationTrack, idleTrack: AnimationTrack, sitTrack: AnimationTrack })
end

-- Returns current pool sizes for diagnostics.
function ModelPool.getStats(): { total: number, perModel: { [string]: number } }
end

return ModelPool
```

### NPCMover.luau (MODIFIED)

```lua
-- MODIFIED: Added optional skipRaycast parameter.
-- When skipRaycast is true, uses npc.lastGroundY instead of doing Workspace:Raycast.
-- Called with skipRaycast=true for low/mid tier NPCs on non-raycast frames.
function NPCMover.update(npc, dt: number, stopAtWaypoint: number?, skipRaycast: boolean?)
```

Implementation change (lines 120-128 of current code):
```lua
-- BEFORE (current):
local rayOrigin = flatPosition + Vector3.new(0, Config.SnapRayOriginOffset, 0)
local rayDirection = Vector3.new(0, -Config.SnapRayLength, 0)
local hitResult = Workspace:Raycast(rayOrigin, rayDirection, raycastParams)
local snappedY = npc.lastGroundY
if hitResult then
    snappedY = hitResult.Position.Y + Config.SnapHipOffset
    npc.lastGroundY = snappedY
end

-- AFTER:
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
```

### NPCAnimator.luau (MODIFIED)

```lua
-- NEW: Stop all animation tracks immediately (fade time = 0).
-- Called when transitioning to mid or far LOD tier, and during pool release.
function NPCAnimator.stopAll(npc)
    if npc.walkTrack.IsPlaying then npc.walkTrack:Stop(0) end
    if npc.idleTrack.IsPlaying then npc.idleTrack:Stop(0) end
    if npc.sitTrack and npc.sitTrack.IsPlaying then npc.sitTrack:Stop(0) end
end
```

---

## New Data Structures

### Types.luau Changes

```lua
-- NEW type alias
export type LODTier = "near" | "low" | "mid" | "far"

-- MODIFIED: NPCState gains 4 new fields
export type NPCState = {
    -- ... all existing fields unchanged ...
    id: string,
    model: Model,
    walkSpeed: number,
    waypoints: { Vector3 },
    currentLeg: number,
    legProgress: number,
    lastGroundY: number,
    expectedDespawnTime: number,
    animator: Animator,
    walkTrack: AnimationTrack,
    idleTrack: AnimationTrack,
    state: "walking" | "dwelling" | "walking_to_seat" | "sitting" | "walking_from_seat" | "finished",
    poiStops: { POIStopData }?,
    nextPoiStopIdx: number,
    dwellEndTime: number?,
    preSeatCFrame: CFrame?,
    seatTargetCFrame: CFrame?,
    sitTrack: AnimationTrack?,

    -- NEW fields for Pass 4:
    modelName: string,                -- Pool key; set from data.modelName on spawn
    startTime: number,                -- Copied from data.startTime; needed for far→near state restoration
    lodTier: LODTier,                 -- Current LOD tier; initialized to "near" on spawn
    raycastPhase: number,             -- Random offset 0..max(LODLowRaycastSkip,LODMidRaycastSkip)-1; stagger raycasts across frames
    lastKnownPosition: Vector3,       -- Last model position before entering far tier; used for LOD distance checks while far
}
```

---

## New Config Values

**Note:** Config values are read at `require()` time and treated as stable for the session. Changing LODEnabled or PoolEnabled at runtime (e.g. via command bar) is unsupported — restart the server to apply changes. This matches existing Config behavior (all passes treat Config as immutable after require).

```lua
-- LOD TIERS
Config.LODEnabled = true
Config.LODNearDistance = 50          -- studs; 0 to this = near tier. Range: 10-200.
Config.LODLowDistance = 100          -- studs; near to this = low tier. Range: 30-300.
Config.LODMidDistance = 200          -- studs; low to this = mid tier. Range: 50-500.
Config.LODCheckInterval = 5         -- frames between LOD tier re-evaluation. Range: 1-30.
Config.LODLowRaycastSkip = 3        -- low tier: raycast every N frames. Range: 1-10.
Config.LODMidRaycastSkip = 6        -- mid tier: raycast every N frames. Range: 1-20.

-- MODEL POOLING
Config.PoolEnabled = true
Config.PoolMaxPerModel = 10         -- max pooled models per modelName. Range: 0-30.
```

---

## Data Flow for New Behaviors

### LOD Tier Assignment and Transition

1. **NPCClient startup**: Store `activeNPCsFolder` reference in module-level variable for LOD show/hide. Initialize `globalFrame = 0`.
2. **Heartbeat (every frame)**: Increment `globalFrame`. Every `LODCheckInterval` frames, get local player character position.
3. **LOD check (per NPC)**: Call `LODController.computeTier(npcPosition, playerPosition)`. Compare against `npc.lodTier`.
4. **Tier unchanged**: No transition work. Continue to per-tier update logic.
5. **Tier changed — entering far**: Store `npc.lastKnownPosition = npc.model.PrimaryPart.Position` (snapshot before hiding). Call `NPCAnimator.stopAll(npc)`. Set `npc.model.Parent = nil` (unparent — removes from rendering but model stays in memory via Lua reference in `activeNPCs`). Update `npc.lodTier = "far"`.
6. **Tier changed — leaving far**: Call `restoreFromFarTier(npc)` (see section 5.4). Set `npc.model.Parent = activeNPCsFolder`. Update `npc.lodTier = newTier`. Start appropriate animations.
7. **Tier changed — entering mid (from near or low)**: Call `NPCAnimator.stopAll(npc)`. Update `npc.lodTier = "mid"`.
8. **Tier changed — leaving mid (to near or low)**: Start appropriate animation via `NPCAnimator.update(npc, npc.state == "walking")`. Update `npc.lodTier = newTier`.
9. **Tier changed — near↔low**: Update `npc.lodTier`. No model/animation changes needed.

**Order invariant for far transition**: Always stop tracks BEFORE unparenting. Always re-parent BEFORE starting tracks.

### LOD-Aware Heartbeat Update (per NPC)

1. **Force-despawn check**: Unchanged — always runs regardless of tier.
2. **If LOD check frame**: Re-evaluate tier, apply transitions (steps 3-9 above).
3. **If tier == "far"**: Skip to next NPC (no movement, no animation, no state machine).
4. **State machine**: Run existing state machine (walking, dwelling, walking_to_seat, sitting, walking_from_seat, finished). Unchanged logic.
5. **Movement**: If state == "walking", call `NPCMover.update(npc, dt, stopAt, skipRaycast)` where `skipRaycast = not LODController.shouldRaycast(npc.lodTier, globalFrame, npc.raycastPhase)`.
6. **Animation**: If `LODController.shouldAnimate(npc.lodTier)`, call `NPCAnimator.update(npc, isMoving)`. Otherwise no-op (tracks already stopped at mid tier).

### Far→Near State Restoration

When an NPC transitions from "far" to any visible tier, its client-side state (currentLeg, legProgress, state, nextPoiStopIdx, dwellEndTime) is stale. Restore it:

```lua
local function restoreFromFarTier(npc)
    local elapsed = Workspace:GetServerTimeNow() - npc.startTime
    local routeState = calculateRouteState(npc.waypoints, npc.walkSpeed, elapsed, npc.poiStops)

    npc.currentLeg = routeState.currentLeg
    npc.legProgress = routeState.legProgress
    npc.state = routeState.state
    npc.nextPoiStopIdx = routeState.nextPoiStopIdx
    npc.dwellEndTime = routeState.dwellEndTime or nil

    -- Ground snap: do one immediate raycast to avoid first-frame Y jump.
    local flatPos = routeState.position
    local rayOrigin = flatPos + Vector3.new(0, Config.SnapRayOriginOffset, 0)
    local rayDirection = Vector3.new(0, -Config.SnapRayLength, 0)
    local hitResult = Workspace:Raycast(rayOrigin, rayDirection, raycastParams)
    if hitResult then
        npc.lastGroundY = hitResult.Position.Y + Config.SnapHipOffset
    end
    local snappedPos = Vector3.new(flatPos.X, npc.lastGroundY, flatPos.Z)

    -- Position model based on restored state.
    if npc.model.PrimaryPart then
        if routeState.state == "sitting" and routeState.seatCFrame then
            npc.model.PrimaryPart.CFrame = routeState.seatCFrame
            npc.preSeatCFrame = CFrame.new(snappedPos)
            npc.seatTargetCFrame = routeState.seatCFrame
        elseif routeState.state == "dwelling" and routeState.viewTarget then
            local flatTarget = Vector3.new(routeState.viewTarget.X, snappedPos.Y, routeState.viewTarget.Z)
            if (flatTarget - snappedPos).Magnitude > 0.01 then
                npc.model.PrimaryPart.CFrame = CFrame.lookAt(snappedPos, flatTarget)
            else
                npc.model.PrimaryPart.CFrame = CFrame.new(snappedPos)
            end
        else
            npc.model.PrimaryPart.CFrame = CFrame.new(snappedPos)
        end
    end

    -- Re-parent model to make it visible (caller does this AFTER this function).
    -- Start appropriate animations (caller does this AFTER re-parenting).
end
```

**Note on walking_to_seat / walking_from_seat**: `calculateRouteState` does not model these micro-states. If the NPC was in walking_to_seat when it entered far tier and the dwell window is still active, calculateRouteState returns "sitting" — the NPC appears at the seat. If the dwell has ended, it returns "walking" past the POI. Both are acceptable visual results for a LOD transition.

### Model Pool Acquire Flow (on spawn)

1. **NPCClient.spawnNPCFromData** receives spawn data from server.
2. Calls `removeNPC(data.id)` to clean up existing NPC (unchanged — but removeNPC now returns model to pool instead of destroying).
3. If `Config.PoolEnabled`, calls `ModelPool.acquire(data.modelName)`.
4. **If pool returns an entry**: Use entry.model, entry.animator, entry.walkTrack, entry.idleTrack, entry.sitTrack. Skip Clone(), skip AnimationController/Animator creation, skip LoadAnimation() calls.
5. **If pool returns nil**: Clone model from template as before. Create Animator. Load all 3 tracks (walk, idle, sit) via NPCAnimator.setup + setupSit. Always pre-load sitTrack regardless of whether this route has social POIs (so the model is pool-compatible for any future route).
6. Position model, parent to ActiveNPCsFolder, build NPC record, apply initial state. Unchanged.

### Model Pool Release Flow (on despawn/removal)

1. **NPCClient.removeNPC** is called (from NPCDespawned remote or force-despawn).
2. Call `NPCAnimator.stopAll(npc)` (stop all tracks immediately).
3. If `Config.PoolEnabled`, call `ModelPool.release(npc.modelName, { model, animator, walkTrack, idleTrack, sitTrack })`.
4. Inside `ModelPool.release`: If pool for this modelName has room, set `model.Parent = nil` and store entry. If full, call `model:Destroy()`.
5. Remove NPC from `activeNPCs`.

### LOD + Pool Interaction

- **Far-tier NPC despawned by server**: `removeNPC` is called. Model is already unparented (far tier). `NPCAnimator.stopAll` still works on unparented model (tracks are Lua objects). Pool release sets Parent = nil (already nil — no-op). Pool stores the entry. Correct.
- **Night drain re-fires NPCSpawned**: `spawnNPCFromData` calls `removeNPC(id)` which pools the old model. Then acquires a new model (possibly the same one from pool). Correct.
- **NPC despawns naturally while far**: Server fires NPCDespawned. Client calls removeNPC. Model is unparented. Pool stores it. Correct.

---

## Integration Pass (against real code)

### Data Lifecycle Traces

**npc.lodTier (LODTier)**
- **Created by:** NPCClient.spawnNPCFromData() → set to "near" on initial spawn
- **Updated by:** NPCClient heartbeat → LODController.computeTier() every LODCheckInterval frames
- **Read by:** NPCClient heartbeat → controls which per-frame work runs (movement, raycast, animation)
- **Stored in:** activeNPCs[id].lodTier; lifetime = NPC client lifetime
- **Cleaned up by:** removeNPC() → NPC removed from activeNPCs
- **Verified:** Field is a string literal; no nil risk since initialized on spawn

**npc.modelName (string)**
- **Created by:** NPCClient.spawnNPCFromData() → set from data.modelName
- **Source:** NPCSpawnData.modelName — set by PopulationController line 319 from `record.modelName`
- **Read by:** NPCClient.removeNPC() → passed to ModelPool.release() as pool key
- **Stored in:** activeNPCs[id].modelName; lifetime = NPC client lifetime
- **Cleaned up by:** removeNPC()
- **Verified:** data.modelName is always a string (PopulationController line 929 sets from model.Name which is always a string)

**npc.startTime (number)**
- **Created by:** NPCClient.spawnNPCFromData() → set from data.startTime
- **Source:** NPCSpawnData.startTime — set by PopulationController line 323 from `record.startTime`
- **Read by:** restoreFromFarTier() → computes elapsed for calculateRouteState
- **Stored in:** activeNPCs[id].startTime; lifetime = NPC client lifetime
- **Cleaned up by:** removeNPC()
- **Verified:** data.startTime is always a number (PopulationController line 917: `Workspace:GetServerTimeNow()`)

**npc.raycastPhase (number)**
- **Created by:** NPCClient.spawnNPCFromData() → `math.random(0, math.max(Config.LODLowRaycastSkip, Config.LODMidRaycastSkip) - 1)`
- **Read by:** NPCClient heartbeat → passed to LODController.shouldRaycast()
- **Stored in:** activeNPCs[id].raycastPhase; lifetime = NPC client lifetime
- **Cleaned up by:** removeNPC()
- **Verified:** Integer >= 0; used only as modulo offset

**npc.lastKnownPosition (Vector3)**
- **Created by:** NPCClient heartbeat → stored from `npc.model.PrimaryPart.Position` when entering far tier
- **Read by:** NPCClient heartbeat → used as npcPos for LODController.computeTier() when npc.lodTier == "far"
- **Updated by:** Only set once on far-tier entry; stale while far but acceptable for LOD distance estimation
- **Stored in:** activeNPCs[id].lastKnownPosition; lifetime = NPC client lifetime
- **Cleaned up by:** removeNPC()
- **Verified:** PrimaryPart.Position is always a Vector3; stored before model is unparented

**Pool entries (table)**
- **Created by:** ModelPool.release() → stores { model, animator, walkTrack, idleTrack, sitTrack }
- **Stored in:** ModelPool internal table keyed by modelName → array of entries
- **Retrieved by:** ModelPool.acquire(modelName) → pops last entry from array
- **Cleaned up by:** ModelPool.release() calls model:Destroy() when pool is full; ModelPool entries are consumed by acquire()
- **Verified:** Model has Parent=nil while pooled; tracks are stopped; Lua references keep model alive

**globalFrame (number)**
- **Created by:** NPCClient startup → `local globalFrame = 0`
- **Updated by:** NPCClient heartbeat → `globalFrame = (globalFrame + 1) % 100000` every frame (wraps to avoid double-precision drift)
- **Read by:** LODController.shouldRaycast(tier, globalFrame, phase)
- **Stored in:** Module-level local in NPCClient
- **Cleaned up by:** N/A (wraps at 100000; modulo operations are stable within this range)

**activeNPCsFolder (Folder reference)**
- **Created by:** NPCClient.startup() → already exists as local variable inside startup() (line 348)
- **Change:** Promote to module-level local (`local activeNPCsFolderRef = nil` at top of file, set during startup). Needed because `restoreFromFarTier()` and the revised `removeNPC()` are file-level local functions defined BEFORE startup(), so they cannot access startup's closure variables. Current code passes `activeNPCsFolder` as a parameter to `spawnNPCFromData` — same pattern works but scope promotion is cleaner for multiple call sites.
- **Read by:** restoreFromFarTier() → `npc.model.Parent = activeNPCsFolderRef`; heartbeat tier transition → same
- **Verified:** Already exists in startup (line 348-353); promotion to module-level is safe (set once, never changes)

### API Composition Checks (new calls only)

| Caller | Callee | Args Match | Return Handled | Verified Against |
|--------|--------|-----------|----------------|-----------------|
| NPCClient heartbeat | LODController.computeTier(npcPos, playerPos) | Vector3, Vector3 → string | Used as tier comparison | New module; types trivially correct |
| NPCClient heartbeat | LODController.shouldRaycast(tier, globalFrame, phase) | string, number, number → boolean | Used as skipRaycast arg | New module; types trivially correct |
| NPCClient heartbeat | LODController.shouldAnimate(tier) | string → boolean | Guards NPCAnimator.update call | New module; types trivially correct |
| NPCClient heartbeat | NPCMover.update(npc, dt, stopAt, skipRaycast) | table, number, number?, boolean? → boolean | Existing return handling unchanged | Real code line 84 currently has 3 params; Pass 4 adds 4th optional boolean. Lua ignores extra args so old call sites remain compatible. |
| NPCClient heartbeat | NPCAnimator.stopAll(npc) | table (NPC record) | void | New function; reads npc.walkTrack, npc.idleTrack, npc.sitTrack — all exist on NPCState |
| NPCClient.removeNPC | ModelPool.release(modelName, entry) | string, table → void | void | New module |
| NPCClient.spawnNPCFromData | ModelPool.acquire(modelName) | string → table? | nil check before use | New module |
| NPCClient.restoreFromFarTier | calculateRouteState(waypoints, walkSpeed, elapsed, poiStops) | {Vector3}, number, number, table? → table | All fields used | Already exists in NPCClient line 94 |
| NPCClient.restoreFromFarTier | Workspace:Raycast(origin, direction, params) | Vector3, Vector3, RaycastParams → RaycastResult? | nil check on result | Same pattern as NPCMover line 123 |

---

## Diagnostics Updates

### New Reason Codes
- `LOD_TRANSITION` — Fires when an NPC changes LOD tier. Format: `[WanderingProps] LOD_TRANSITION %s tier=%s→%s`. Enabled by DiagnosticsEnabled.
- `POOL_ACQUIRE` — Fires when a model is taken from pool. Format: `[WanderingProps] POOL_ACQUIRE model=%s pool_remaining=%d`.
- `POOL_RELEASE` — Fires when a model is returned to pool. Format: `[WanderingProps] POOL_RELEASE model=%s pool_size=%d`.
- `POOL_FULL_DESTROY` — Fires when pool is full and model is destroyed instead. Format: `[WanderingProps] POOL_FULL_DESTROY model=%s max=%d`.

### New Health Counters (client-side, diagnostic only)
- `lodTransitionsTotal` — Total LOD tier changes across all NPCs.
- `poolAcquireHits` — Times a pooled model was reused.
- `poolAcquireMisses` — Times pool was empty and Clone() was needed.
- `poolDestroys` — Times pool was full and model was destroyed.

---

## Startup Validator Updates

No new startup validators needed. All new config values have safe defaults and are client-only tunables. Invalid LOD distances (e.g., LODNearDistance > LODLowDistance) produce a client-side warning but do not fatal — the system falls back to all-near behavior.

```lua
-- Add to NPCClient startup (not PopulationController — this is client-side):
if Config.LODEnabled then
    if Config.LODNearDistance >= Config.LODLowDistance
        or Config.LODLowDistance >= Config.LODMidDistance then
        warn("[WanderingProps] WARNING: LOD distances must be LODNearDistance < LODLowDistance < LODMidDistance. LOD disabled.")
        -- Fall back: treat all NPCs as "near"
    end
end
```

---

## Revised Heartbeat Loop (NPCClient)

This is the core change. The existing heartbeat loop (lines 373-462 of NPCClient.client.luau) is modified to incorporate LOD checks. Pseudocode:

```lua
local globalFrame = 0
local activeNPCsFolderRef  -- set during startup

RunService.Heartbeat:Connect(function(dt)
    globalFrame = (globalFrame + 1) % 100000
    local isLODCheckFrame = Config.LODEnabled and (globalFrame % Config.LODCheckInterval == 0)

    -- Get player position once per frame (not per NPC).
    local playerPosition = nil
    if isLODCheckFrame then
        local character = Players.LocalPlayer and Players.LocalPlayer.Character
        local rootPart = character and character:FindFirstChild("HumanoidRootPart")
        if rootPart then
            playerPosition = rootPart.Position
        end
    end

    for id, npc in pairs(activeNPCs) do
        -- 1. Force-despawn safety (unchanged).
        if Workspace:GetServerTimeNow() > npc.expectedDespawnTime then
            warn(string.format("[WanderingProps] FORCE_DESPAWN %s - server event not received", id))
            removeNPC(id)
            continue
        end

        -- 2. LOD tier re-evaluation.
        if isLODCheckFrame and playerPosition then
            local npcPos = if npc.lodTier == "far"
                then npc.lastKnownPosition or npc.waypoints[npc.currentLeg] or npc.waypoints[1]
                else (npc.model.PrimaryPart and npc.model.PrimaryPart.Position or npc.waypoints[npc.currentLeg] or npc.waypoints[1])
            local newTier = LODController.computeTier(npcPos, playerPosition)

            if newTier ~= npc.lodTier then
                local oldTier = npc.lodTier

                -- Transition: entering far.
                if newTier == "far" then
                    if npc.model.PrimaryPart then
                        npc.lastKnownPosition = npc.model.PrimaryPart.Position
                    end
                    NPCAnimator.stopAll(npc)
                    npc.model.Parent = nil
                -- Transition: leaving far.
                elseif oldTier == "far" then
                    restoreFromFarTier(npc)
                    npc.model.Parent = activeNPCsFolderRef
                    if newTier == "mid" then
                        -- mid: no animation
                    elseif npc.state == "sitting" then
                        NPCAnimator.playSit(npc)
                    else
                        NPCAnimator.update(npc, npc.state == "walking" or npc.state == "walking_to_seat" or npc.state == "walking_from_seat")
                    end
                -- Transition: entering mid (from near or low).
                elseif newTier == "mid" and oldTier ~= "mid" then
                    NPCAnimator.stopAll(npc)
                -- Transition: leaving mid (to near or low).
                elseif oldTier == "mid" and newTier ~= "mid" then
                    if npc.state == "sitting" then
                        NPCAnimator.playSit(npc)
                    else
                        NPCAnimator.update(npc, npc.state == "walking" or npc.state == "walking_to_seat" or npc.state == "walking_from_seat")
                    end
                end
                -- near↔low: no model/animation changes needed.

                npc.lodTier = newTier
                diagnostics(string.format("[WanderingProps] LOD_TRANSITION %s tier=%s→%s", id, oldTier, newTier))
            end
        end

        -- 3. Skip far-tier NPCs entirely.
        if npc.lodTier == "far" then
            continue
        end

        -- 4. State machine (unchanged logic).
        -- ... existing walking/dwelling/walking_to_seat/sitting/walking_from_seat/finished logic ...

        -- 5. Movement: pass skipRaycast based on LOD tier.
        -- Within the "walking" state branch:
        --   local skipRaycast = not LODController.shouldRaycast(npc.lodTier, globalFrame, npc.raycastPhase)
        --   local finished = NPCMover.update(npc, dt, stopAt, skipRaycast)

        -- 6. Animation: only if tier allows it.
        -- Replace every NPCAnimator.update(npc, ...) call with:
        --   if LODController.shouldAnimate(npc.lodTier) then
        --       NPCAnimator.update(npc, ...)
        --   end
        -- Replace NPCAnimator.playSit(npc) calls with same guard.
    end
end)
```

**Key invariants:**
- Far-tier NPCs are skipped after the LOD check. They contribute zero per-frame cost.
- The existing state machine logic is unchanged — just wrapped with LOD guards for animation calls.
- `moveModelTowardCFrame` (used by walking_to_seat/walking_from_seat) does NOT use raycasts, so it runs unmodified at near/low/mid tiers.

---

## Revised spawnNPCFromData (NPCClient)

```lua
local function spawnNPCFromData(data, activeNPCsFolder, modelsFolder)
    removeNPC(data.id)

    local poolEntry = nil
    if Config.PoolEnabled then
        poolEntry = ModelPool.acquire(data.modelName)
    end

    local clonedModel, animator, walkTrack, idleTrack, sitTrack

    if poolEntry then
        clonedModel = poolEntry.model
        animator = poolEntry.animator
        walkTrack = poolEntry.walkTrack
        idleTrack = poolEntry.idleTrack
        sitTrack = poolEntry.sitTrack

        diagnostics(string.format("[WanderingProps] POOL_ACQUIRE model=%s", data.modelName))
    else
        -- Existing clone flow (lines 206-278 of current code).
        -- Find modelTemplate, Clone, validate PrimaryPart,
        -- set Anchored/CanCollide, find/create Animator.
        -- ...

        walkTrack, idleTrack = NPCAnimator.setup(animator)
        sitTrack = NPCAnimator.setupSit(animator)
        -- Always pre-load sitTrack so pool entries are route-agnostic.
    end

    -- Calculate initial state (unchanged).
    local elapsed = Workspace:GetServerTimeNow() - data.startTime
    if elapsed < 0 then elapsed = 0 end
    local routeState = calculateRouteState(data.waypoints, data.walkSpeed, elapsed, data.poiStops)

    -- Position and parent model (unchanged).
    clonedModel.PrimaryPart.CFrame = CFrame.new(routeState.position)
    clonedModel.Parent = activeNPCsFolder

    -- Build NPC record with new fields.
    local npc = {
        -- ... all existing fields ...
        modelName = data.modelName,
        startTime = data.startTime,
        lodTier = "near",
        raycastPhase = math.random(0, math.max(Config.LODLowRaycastSkip, Config.LODMidRaycastSkip) - 1),
        lastKnownPosition = routeState.position,
    }

    -- Apply initial animation state (unchanged).
    -- ...

    activeNPCs[data.id] = npc
end
```

---

## Revised removeNPC (NPCClient)

```lua
local function removeNPC(id: string)
    local npc = activeNPCs[id]
    if not npc then
        return
    end

    NPCAnimator.stopAll(npc)

    if Config.PoolEnabled then
        ModelPool.release(npc.modelName, {
            model = npc.model,
            animator = npc.animator,
            walkTrack = npc.walkTrack,
            idleTrack = npc.idleTrack,
            sitTrack = npc.sitTrack,
        })
    else
        npc.model:Destroy()
    end

    activeNPCs[id] = nil
end
```

---

## Performance Budget

### Estimated Per-Frame Cost Reduction (70 NPCs, typical distribution)

Assumption: Player in one area. ~10 near, ~10 low, ~15 mid, ~35 far.

| Operation | Before (70 NPCs) | After (LOD) | Reduction |
|-----------|------------------|-------------|-----------|
| Workspace:Raycast | 70/frame | ~14/frame (10 near + ~3 low + ~3 mid) | ~80% |
| Animation joint evaluations | ~1050/frame (70 x 15 joints) | ~300/frame (20 animated x 15) | ~71% |
| CFrame writes | 70/frame | 35/frame (near+low+mid) | 50% |
| Lua state machine iterations | 70/frame | 35/frame (skip far) | 50% |

### Model Pool Savings

| Operation | Before | After | Savings |
|-----------|--------|-------|---------|
| Model Clone() | Every spawn | Only on pool miss | ~80-90% fewer clones at steady state |
| Model Destroy() | Every despawn | Only when pool full | ~80-90% fewer destroys |
| AnimationTrack LoadAnimation() | 2-3 per spawn | Only on pool miss | Same as above |

---

## Golden Tests for This Pass

### Test 15: LOD Tier Visual Transitions
- **Setup:** Waypoint graph spanning a large area (>300 studs across). Config: MaxPopulation = 20, LODEnabled = true, LODNearDistance = 50, LODLowDistance = 100, LODMidDistance = 200, DiagnosticsEnabled = true.
- **Action:** Start server. Walk player from one end of the map to the other, moving through clusters of NPCs.
- **Expected:** NPCs near the player walk with full animation. NPCs far away are invisible. As the player moves closer, distant NPCs reappear at their correct route positions with correct animation state. No visual pop-in glitches (NPCs don't appear in wrong positions).
- **Pass condition:** LOD_TRANSITION diagnostics fire as player moves. NPCs restored from far tier are at plausible route positions. No frozen or T-posed NPCs.

### Test 16: Model Pool Reuse
- **Setup:** Config: MaxPopulation = 10, SpawnInterval = 1, PoolEnabled = true, PoolMaxPerModel = 5, DiagnosticsEnabled = true. Use 2 NPC models.
- **Action:** Start server. Wait 60 seconds for several spawn/despawn cycles.
- **Expected:** After the first cycle of despawns, subsequent spawns reuse pooled models. POOL_ACQUIRE diagnostics appear. Model count in memory stays bounded.
- **Pass condition:** POOL_ACQUIRE fires regularly after initial population. No POOL_FULL_DESTROY unless population turnover is very high. NPCs spawned from pool behave identically to cloned NPCs (walk, animate, despawn normally).

### Test 17: LOD + POI State Consistency
- **Setup:** Route includes Scenic and Social POIs. Config: MaxPopulation = 10, LODEnabled = true, LODMidDistance = 30 (short, to trigger far tier easily).
- **Action:** Start server. Walk player far away so NPCs enter far tier while some are dwelling or sitting. Walk back.
- **Expected:** NPCs restored from far tier are in correct state: if dwell/sit time not expired, they appear dwelling/sitting; if expired, they appear walking past the POI.
- **Pass condition:** No NPC is frozen at a POI they should have left. No NPC skips a POI they should be at. Seat animations play correctly after restoration.

### Test 18: LOD Disabled Regression
- **Setup:** Config: LODEnabled = false, PoolEnabled = false, MaxPopulation = 20.
- **Action:** Run all Pass 1-3 golden tests.
- **Expected:** All behavior is identical to pre-Pass-4.
- **Pass condition:** No regressions when optimization features are disabled.

### Regression Tests
Re-run from previous passes:
- **Test 1: Basic Spawn-Walk-Despawn Cycle**
- **Test 2: Late-Join Sync**
- **Test 4: Scenic POI Visit**
- **Test 5: Social POI Sit and Walk In/Out**
- **Test 9: Zone Waypoint Variation**
- **Test 11: Clock-Based Day/Night Hook**
- **Test 12: Night Drain Route Shortening**
- **Test 13: Social Seat Exit During Night Drain**

---

## Critic Review Notes

**Critic run:** 2026-02-15, rev 1 → BLOCKED (8 issues). Analysis: 4 false positives (critic confused design specs for new code with claims about existing code), 1 withdrawn, 3 legitimate concerns.

**False positives dismissed (4):**
1. "removeNPC missing pool logic" — Design section "Revised removeNPC" specifies this as NEW code for Codex to write.
2. "LODController/ModelPool don't exist" — Listed in "New Files" table. That's the point.
3. "NPCMover.update 4th param doesn't exist" — Design section "NPCMover.luau (MODIFIED)" specifies adding it. Clarified API table note.
4. "NPCAnimator.stopAll doesn't exist" — Design section "NPCAnimator.luau (MODIFIED)" specifies adding it.

**Withdrawn (1):**
5. preSeatCFrame correctness — critic verified design is correct and withdrew.

**Legitimate concerns fixed (3):**
6. Config runtime toggle → Added immutability note: Config values are treated as stable after require(). Matches all prior passes.
7. globalFrame overflow → Changed to `(globalFrame + 1) % 100000`. Wraps safely. Modulo operations remain correct.
8. activeNPCsFolder scope → Clarified rationale: restoreFromFarTier and revised removeNPC are file-level locals defined before startup(), so closure access is unavailable. Module-level promotion is the correct fix.

**Non-blocking flags addressed (1):**
- Far-tier NPC position estimate → Added `lastKnownPosition` field to NPCState. Stored from PrimaryPart.Position on far-tier entry. Used for LOD distance checks while far. Full lifecycle trace added.

**Result:** APPROVED (rev 2), 0 blocking issues remaining.
