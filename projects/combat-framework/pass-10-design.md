# Pass 10 Redesign: Fighter Flight (Client-Authoritative)

**Status:** Second redesign. Architecture changed from server-authoritative CFrame writes to client-authoritative BodyMover physics based on analysis of a proven smooth ship system.

**Scope:** Fighter flight physics, no combat. Fighters only — future pass converts speeders/walkers.

**User requirements:**
- Full 360° freedom (loops, barrel rolls, inverted flight)
- Local-frame controls (roll changes the turn plane)
- Heavy angular inertia feel
- Full camera follow with cinematic trailing
- Ground takeoff sequence
- Buttery smooth movement (no "fall back and catch up" artifacts)

---

## Architecture: Client-Authoritative Flight

**Why the old approach was never going to be smooth:**

Server-authoritative CFrame writes at 20Hz create discrete position jumps. No amount of client-side smoothing can fully hide 20Hz stepping — the camera reads a part that only updates 20 times per second. Every smoothing layer adds latency or artifacts.

**The new approach (same as the reference ship system):**

1. Server creates BodyVelocity + BodyGyro on the fighter's Base part
2. When pilot sits: server calls `Base:SetNetworkOwner(pilot)` — pilot's client now owns the physics
3. Client sets `BodyVelocity.Velocity` and `BodyGyro.CFrame` every render frame (60Hz+)
4. Roblox's physics engine handles movement, collisions, and replication to other clients
5. When pilot exits: server calls `Base:SetNetworkOwner(nil)`, disables BodyMovers — ship falls naturally under gravity

**Why this is smooth:**
- Physics runs at render framerate (60Hz+), not server tick rate (20Hz)
- Roblox automatically interpolates network-owned physics for remote clients
- Camera reads a part that updates every frame — zero stepping artifacts
- No custom smoothing code needed

**Security tradeoff:**
- Movement is client-authoritative — a cheater could fly at modified speed or clip through things
- Combat remains fully server-authoritative — damage, hit detection, health, destruction are all validated server-side
- This is the same model as default Roblox character movement (already client-authoritative)

**Future scope:** Pass 10 converts fighters only. A future pass will convert speeders and walkers to the same architecture for consistent smooth movement across all vehicles.

---

## Sign Convention Reference

**CFrame.Angles(rx, ry, rz) in local frame (-Z forward, +Y up):**
- Positive rx: nose DOWN. Negative rx: nose UP.
- Positive ry: yaw LEFT. Negative ry: yaw RIGHT.
- Positive rz: roll LEFT. Negative rz: roll RIGHT.

**Input mapping (preserved from current code, MUST NOT CHANGE):**
- Mouse right → `yawInput` negative → yaw RIGHT
- Mouse down → `pitchInput` negative → nose UP (pull back)
- A key → `rollInput` positive → roll LEFT
- D key → `rollInput` negative → roll RIGHT

---

## Build Steps

### Step 1: FighterServer — Simplify to Lifecycle Manager

**File:** `src/Server/Vehicles/FighterServer.luau`

**MAJOR SIMPLIFICATION.** The server no longer runs flight physics, replicates CFrames, or processes input. It only manages lifecycle and network ownership.

**DELETE these functions/variables entirely (no longer needed):**
- `applyFlightStep` — physics moves to client
- `stepFighters` — no server physics loop
- `safeLookAt` — not needed
- `clampForwardPitch` — not needed
- `extractRollAngle` — not needed on server (client uses its own)
- `computeHeadingFromLook` — not needed
- `shortestAngleDelta` — not needed
- `buildFighterRayParams` — not needed
- `appendPlayerCharacters` — not needed
- `writeFighterCFrame` — Roblox handles replication
- `applySpeedAttributeReplication` — Roblox handles replication
- `readConfigNumber` — only used by replication code
- `heartbeatConnection` and Heartbeat listener in `init()`
- `inputConnection` and VehicleInput listener in `init()`
- `lastSummaryPrintTick`, `fighterErrorCount`, `getFighterCount`, `getErrorCount`

**DELETE these fields from the internal state type:**
- `speed`, `simulatedCFrame`, `currentPitchRate/YawRate/RollRate`
- `inputThrottle/Yaw/Pitch/Roll`
- `takeoffActive/Remaining/TargetY/LiftSpeed`
- `replicationState`, `settlingStartTick`, `lastCFrameWriteTick`, `lastSpeedUpdateTick`
- `lastReplicatedSpeed`, `lastReplicatedHeading`, `wasStopped`, `lastDebugPrintTick`
- `childPartOffsets`

**KEEP these functions (they still work):**
- `resolveVehicleConfig`, `getVehicleConfig`, `readNumberAttribute`, `readBoolAttribute`, `applyPercentModifier` — config resolution
- `getFighterByPilot`, `setPilotCharacterControl` — pilot management
- `onEntityDestroyed`, `onEntityRespawned`, `cleanupFighterState` — lifecycle
- VehicleExitRequest listener in `init()`
- PlayerRemoving listener in `init()`
- ProximityPrompt setup

**MODIFY `registerFighter`** — replace childPartOffsets/anchoring with BodyMover creation and welding:

```lua
function FighterServer.registerFighter(entityId, instance, vehicleConfigId, pilotSeat)
    -- [existing cleanup + config resolution + spawn data + primaryPart check stays the same]

    -- NEW: Unanchor Base and weld all child parts
    primaryPart.Anchored = false
    for _, descendant in ipairs(instance:GetDescendants()) do
        if descendant:IsA("BasePart") and descendant ~= primaryPart then
            descendant.Anchored = false
            if not descendant:FindFirstChildOfClass("WeldConstraint") then
                local weld = Instance.new("WeldConstraint")
                weld.Part0 = descendant
                weld.Part1 = primaryPart
                weld.Parent = descendant
            end
        end
    end

    -- NEW: Create BodyVelocity if not present
    local bodyVel = primaryPart:FindFirstChildOfClass("BodyVelocity")
    if not bodyVel then
        bodyVel = Instance.new("BodyVelocity")
        bodyVel.Name = "BodyVelocity"
        bodyVel.MaxForce = Vector3.zero  -- disabled until pilot enters
        bodyVel.Velocity = Vector3.zero
        bodyVel.P = 10000
        bodyVel.Parent = primaryPart
    else
        bodyVel.MaxForce = Vector3.zero
        bodyVel.Velocity = Vector3.zero
    end

    -- NEW: Create BodyGyro if not present
    local bodyGyro = primaryPart:FindFirstChildOfClass("BodyGyro")
    if not bodyGyro then
        bodyGyro = Instance.new("BodyGyro")
        bodyGyro.Name = "BodyGyro"
        bodyGyro.MaxTorque = Vector3.zero  -- disabled until pilot enters
        bodyGyro.CFrame = primaryPart.CFrame
        bodyGyro.P = 50000
        bodyGyro.D = 1000
        bodyGyro.Parent = primaryPart
    else
        bodyGyro.MaxTorque = Vector3.zero
        bodyGyro.CFrame = primaryPart.CFrame
    end

    -- NEW: Keep Base in place until pilot enters (temporary anchor via BodyPosition or zero velocity)
    -- The BodyVelocity with MaxForce=0 means no force applied, but the part is unanchored.
    -- To prevent it from falling before pilot enters, re-anchor it temporarily.
    primaryPart.Anchored = true

    local state = {
        fighterId = entityId,
        entityId = entityId,
        instance = instance,
        primaryPart = primaryPart,
        pilotSeat = pilotSeat,
        config = config,
        pilot = nil,
        bodyVelocity = bodyVel,
        bodyGyro = bodyGyro,
        connections = {},
        prompt = nil,
    }

    -- [ProximityPrompt setup, seat occupant listener, register in tables — same as before]
end
```

**MODIFY `updatePilotFromSeat`** — add network ownership transfer and BodyMover enable/disable:

```lua
local function updatePilotFromSeat(state)
    local occupant = state.pilotSeat.Occupant
    if occupant ~= nil then
        local character = occupant.Parent
        local player = if character then Players:GetPlayerFromCharacter(character) else nil
        if player ~= nil then
            -- [existing pilot swap logic stays]

            state.pilot = player
            pilotToFighterId[player] = state.fighterId

            -- NEW: Unanchor, give network ownership, enable BodyMovers
            state.primaryPart.Anchored = false
            pcall(function()
                state.primaryPart:SetNetworkOwner(player)
            end)
            state.bodyVelocity.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
            state.bodyGyro.MaxTorque = Vector3.new(math.huge, math.huge, math.huge)
            state.bodyGyro.CFrame = state.primaryPart.CFrame

            setPilotCharacterControl(player, true)
            if state.prompt then state.prompt.Enabled = false end
            return
        end
    end

    -- Pilot exited
    local previousPilot = state.pilot
    if previousPilot then
        clearPilot(state)
    end

    -- NEW: Disable BodyMovers, take back ownership — ship falls naturally
    state.bodyVelocity.MaxForce = Vector3.zero
    state.bodyGyro.MaxTorque = Vector3.zero
    pcall(function()
        state.primaryPart:SetNetworkOwner(nil)
    end)
    -- Don't re-anchor — let physics engine handle the fall/settling

    if state.prompt then state.prompt.Enabled = true end
end
```

**MODIFY `clearPilot`** — add BodyMover disable:

```lua
local function clearPilot(state)
    local previousPilot = state.pilot
    if previousPilot and pilotToFighterId[previousPilot] == state.fighterId then
        pilotToFighterId[previousPilot] = nil
        setPilotCharacterControl(previousPilot, false)
    end
    state.pilot = nil
end
```

**MODIFY `init`** — remove VehicleInput listener and Heartbeat connection. Keep only VehicleExitRequest and PlayerRemoving:

```lua
function FighterServer.init(remotesFolder)
    vehicleExitRemote = remotesFolder:WaitForChild("VehicleExitRequest")

    if exitConnection == nil then
        exitConnection = vehicleExitRemote.OnServerEvent:Connect(function(player)
            local state = getFighterByPilot(player)
            if state == nil then return end
            local character = player.Character
            if character then
                local humanoid = character:FindFirstChildOfClass("Humanoid")
                if humanoid then humanoid.Sit = false end
            end
        end)
    end

    if playerRemovingConnection == nil then
        playerRemovingConnection = Players.PlayerRemoving:Connect(function(player)
            local state = getFighterByPilot(player)
            if state == nil then return end
            clearPilot(state)
            state.bodyVelocity.MaxForce = Vector3.zero
            state.bodyGyro.MaxTorque = Vector3.zero
            pcall(function()
                state.primaryPart:SetNetworkOwner(nil)
            end)
        end)
    end

    -- NO heartbeat connection (client handles physics)
    -- NO VehicleInput listener (client drives BodyMovers directly)
end
```

**MODIFY `cleanupFighterState`** — clean up BodyMovers:

```lua
local function cleanupFighterState(state)
    -- [existing connection cleanup + pilot cleanup stays]
    state.bodyVelocity.MaxForce = Vector3.zero
    state.bodyGyro.MaxTorque = Vector3.zero
    -- Don't destroy BodyMovers (model template may need them for respawn)
    -- [existing table cleanup stays]
end
```

**Test criteria:** Server registers fighter, transfers network ownership on seat entry, takes it back on exit. No physics loop on server.

---

### Step 2: FighterClient — Drive Physics via BodyMovers

**File:** `src/Client/Vehicles/FighterClient.luau`

**MAJOR EXPANSION.** Client now computes flight physics and drives BodyMovers every frame. Remove VehicleInput sending.

**ADD module-level state variables:**

```lua
-- Flight physics state (persistent across frames)
local currentSpeed: number = 0
local desiredOrientation: CFrame = CFrame.new()
local smoothedPitchRate: number = 0
local smoothedYawRate: number = 0
local smoothedRollRate: number = 0
local bodyVelocity: BodyVelocity? = nil
local bodyGyro: BodyGyro? = nil
local takeoffActive: boolean = false
local takeoffRemaining: number = 0
local takeoffTargetY: number = 0
local takeoffLiftSpeed: number = 0
local flightRayParams: RaycastParams? = nil
```

**DELETE** the VehicleInput sending code from the render loop. Client no longer sends input to server.

**DELETE** these variables that were for server communication:
- `lastSentThrottle`, `lastSentYaw`, `lastSentPitch`, `lastSentRoll`, `lastSentTick`
- `INPUT_REFRESH_INTERVAL`, `SEND_RATE`, `INPUT_DEADBAND`
- `inputAccumulator`
- `vehicleInputRemote` reference

**ADD helper function for roll extraction:**

```lua
local function extractRollAngle(cf: CFrame): number
    return math.atan2(-cf.RightVector.Y, cf.UpVector.Y)
end
```

**MODIFY `activate()`:**

After existing setup, add BodyMover acquisition and physics state init:

```lua
function FighterClient.activate(model, entityId, config)
    -- [existing setup code stays: deactivate, store state, mouse lock, sound, camera, HUD]

    -- NEW: Acquire BodyMover references
    local primary = model.PrimaryPart
    bodyVelocity = primary:FindFirstChildOfClass("BodyVelocity")
    bodyGyro = primary:FindFirstChildOfClass("BodyGyro")

    -- NEW: Initialize flight state
    desiredOrientation = primary.CFrame - primary.CFrame.Position  -- rotation only
    currentSpeed = 0
    smoothedPitchRate = 0
    smoothedYawRate = 0
    smoothedRollRate = 0

    -- NEW: Build raycast params for ground/obstacle checks
    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Exclude
    rayParams.FilterDescendantsInstances = {model, localPlayer.Character}
    rayParams.IgnoreWater = true
    flightRayParams = rayParams

    -- NEW: Start takeoff
    local takeoffHeight = config.fighterTakeoffHeight
    if type(takeoffHeight) ~= "number" or takeoffHeight <= 0 then takeoffHeight = 12 end
    local takeoffDuration = config.fighterTakeoffDuration
    if type(takeoffDuration) ~= "number" or takeoffDuration <= 0 then takeoffDuration = 0.9 end
    takeoffActive = true
    takeoffRemaining = takeoffDuration
    takeoffTargetY = primary.Position.Y + takeoffHeight
    takeoffLiftSpeed = takeoffHeight / takeoffDuration
    currentSpeed = 0

    -- NEW: Connect render loop WITH physics
    renderConnection = RunService.RenderStepped:Connect(function(dt)
        -- [existing validity checks stay]
        local cfg = activeConfig :: VehicleConfig
        local mdl = activeModel :: Model
        local base = mdl.PrimaryPart
        if base == nil then FighterClient.deactivate() return end

        -- Freelook handling [existing code stays]

        -- Virtual cursor + keyboard input [existing updateCursorAndInputs stays]
        local throttle, yawInput, pitchInput, rollInput = updateCursorAndInputs(dt, cfg)

        -- ========================
        -- FLIGHT PHYSICS (runs every frame on client)
        -- ========================
        local clampedDt = math.min(dt, 1/30)
        local minSpeed = math.max(0, cfg.minSpeed or 0)
        local maxSpeed = math.max(minSpeed, cfg.maxSpeed)

        if takeoffActive then
            -- Vertical lift, no rotation
            if bodyVelocity then
                bodyVelocity.Velocity = Vector3.new(0, takeoffLiftSpeed, 0)
            end
            takeoffRemaining = takeoffRemaining - clampedDt
            if takeoffRemaining <= 0 or base.Position.Y >= takeoffTargetY - 0.5 then
                takeoffActive = false
                currentSpeed = minSpeed
            end
        else
            -- SPEED
            if throttle > 0 then
                currentSpeed = math.min(currentSpeed + cfg.acceleration * clampedDt, maxSpeed)
            elseif throttle < 0 then
                currentSpeed = math.max(currentSpeed - (cfg.deceleration or 60) * clampedDt, minSpeed)
            end

            -- TURN RATES WITH INERTIA
            local speedRange = math.max(1, maxSpeed - minSpeed)
            local speedFrac = math.clamp((currentSpeed - minSpeed) / speedRange, 0, 1)
            local turnScaleMin = cfg.turnRateSpeedScaleMin or 0.6
            local turnScaleMax = cfg.turnRateSpeedScaleMax or 1.0
            local turnScale = turnScaleMax + (turnScaleMin - turnScaleMax) * speedFrac

            local desiredYaw = yawInput * (cfg.yawRate or 90) * turnScale
            local desiredPitch = pitchInput * (cfg.pitchRate or 70) * turnScale
            local desiredRoll = rollInput * (cfg.rollRate or 120)

            local resp = math.max(0.01, cfg.angularResponsiveness or 8)
            local alpha = 1 - math.exp(-resp * clampedDt)
            smoothedYawRate += (desiredYaw - smoothedYawRate) * alpha
            smoothedPitchRate += (desiredPitch - smoothedPitchRate) * alpha
            smoothedRollRate += (desiredRoll - smoothedRollRate) * alpha

            -- ROTATION: Pure CFrame multiplication in local frame
            local rotDelta = CFrame.Angles(
                math.rad(smoothedPitchRate) * clampedDt,
                math.rad(smoothedYawRate) * clampedDt,
                math.rad(smoothedRollRate) * clampedDt
            )
            desiredOrientation = desiredOrientation * rotDelta

            -- AUTO-LEVEL (post-rotation correction)
            local autoLevelGate = cfg.autoLevelInputGate or 0.3
            if rollInput == 0
                and math.abs(yawInput) < autoLevelGate
                and math.abs(pitchInput) < autoLevelGate
            then
                local rollAngle = extractRollAngle(desiredOrientation)
                local deadzoneRad = math.rad(cfg.autoLevelDeadzone or 5)
                if math.abs(rollAngle) > deadzoneRad then
                    local maxCorr = math.rad(cfg.autoLevelRate or 30) * clampedDt
                    local corr = -math.sign(rollAngle) * math.min(math.abs(rollAngle), maxCorr)
                    desiredOrientation = desiredOrientation * CFrame.Angles(0, 0, corr)
                end
            end

            -- VELOCITY (forward in actual ship direction)
            local desiredVelocity = base.CFrame.LookVector * currentSpeed

            -- GROUND COLLISION CHECK
            if flightRayParams then
                local collisionRadius = math.max(0, cfg.collisionRadius or 5)
                local groundRay = Workspace:Raycast(
                    base.Position + Vector3.new(0, 50, 0),
                    Vector3.new(0, -100, 0),
                    flightRayParams
                )
                if groundRay then
                    local minAlt = groundRay.Position.Y + collisionRadius + 2
                    if base.Position.Y < minAlt then
                        desiredVelocity = Vector3.new(
                            desiredVelocity.X,
                            math.max(desiredVelocity.Y, 30),
                            desiredVelocity.Z
                        )
                        currentSpeed = math.max(currentSpeed * 0.7, minSpeed)
                        desiredOrientation = desiredOrientation * CFrame.Angles(math.rad(-5), 0, 0)
                    end
                end
            end

            -- SET BODY MOVERS
            if bodyVelocity then
                bodyVelocity.Velocity = desiredVelocity
            end
        end

        -- BodyGyro always tracks desired orientation
        if bodyGyro then
            bodyGyro.CFrame = CFrame.new(base.Position) * desiredOrientation
        end

        -- HUD
        CombatHUD.setSpeed(currentSpeed)
        updateAudio(dt, currentSpeed, cfg.maxSpeed, throttle, yawInput)
    end)

    -- [rest of activate stays: exit binding, scroll zoom]
end
```

**MODIFY `deactivate()`** — reset physics state:

```lua
function FighterClient.deactivate()
    -- [existing cleanup stays]
    currentSpeed = 0
    desiredOrientation = CFrame.new()
    smoothedPitchRate = 0
    smoothedYawRate = 0
    smoothedRollRate = 0
    bodyVelocity = nil
    bodyGyro = nil
    takeoffActive = false
    flightRayParams = nil
    -- [rest of existing cleanup stays]
end
```

**MODIFY `updateCursorAndInputs`** — fix auto-center (same as previous redesign):

Replace the near-center-only auto-center block with proportional decay:
```lua
local centerAlpha = 1 - math.exp(-autoCenter * dt)
virtualCursorX = virtualCursorX * (1 - centerAlpha)
virtualCursorY = virtualCursorY * (1 - centerAlpha)
if math.abs(virtualCursorX) < deadzone * 0.5 then virtualCursorX = 0 end
if math.abs(virtualCursorY) < deadzone * 0.5 then virtualCursorY = 0 end
```

**MODIFY `init()`** — only need VehicleExitRequest remote, not VehicleInput:

```lua
function FighterClient.init(remotesFolder)
    vehicleExitRemote = remotesFolder:WaitForChild("VehicleExitRequest") :: RemoteEvent
    -- NO vehicleInputRemote — client drives physics directly
end
```

**Test criteria:** Ship moves smoothly at 60Hz+. No "fall back and catch up" artifacts. Remote players see smooth movement via Roblox's physics replication.

---

### Step 3: VehicleCamera — Simplified Fighter Mode

**File:** `src/Client/Vehicles/VehicleCamera.luau`

**REPLACE the `isFighterMode` branch in `stepCamera`.** Since Base updates at 60Hz (client-owned physics), no multi-layer smoothing is needed. Camera just follows with aesthetic damping.

```lua
    if isFighterMode then
        local targetCF = if primaryPart ~= nil then primaryPart.CFrame else vehicleModel:GetPivot()

        -- Smooth ship CFrame for cinematic trailing (aesthetic, not compensating for stepping)
        if smoothedShipCFrame == nil then
            smoothedShipCFrame = targetCF
        else
            smoothedShipCFrame = (smoothedShipCFrame :: CFrame):Lerp(targetCF, computeAlpha(8, clampedDt))
        end

        local smoothCF = smoothedShipCFrame :: CFrame
        local shipFwd = smoothCF.LookVector
        local shipUp = smoothCF.UpVector
        local shipPos = smoothCF.Position

        -- Camera: behind + above in smoothed ship frame
        local desiredCamPos = shipPos - shipFwd * config.cameraDistance + shipUp * config.cameraHeight
        if smoothedCameraPos == nil then
            smoothedCameraPos = desiredCamPos
        else
            smoothedCameraPos = (smoothedCameraPos :: Vector3):Lerp(desiredCamPos, computeAlpha(12, clampedDt))
        end

        -- Collision avoidance
        local minDist = math.max(config.cameraDistance * 0.6, 6)
        local allowedDist = measureAllowedCameraDistance(shipPos, smoothedCameraPos :: Vector3, vehicleModel, minDist)
        local camDir = (smoothedCameraPos :: Vector3) - shipPos
        if camDir.Magnitude > 0.01 and camDir.Magnitude > allowedDist then
            smoothedCameraPos = shipPos + camDir.Unit * allowedDist
        end

        -- Look target: ahead of ship
        local lookAhead = config.fighterCameraLookAhead or 15
        local desiredLook = shipPos + shipFwd * lookAhead
        local lookAt = currentLookAtPosition
        if lookAt == nil then
            lookAt = desiredLook
        else
            lookAt = lookAt:Lerp(desiredLook, computeAlpha(10, clampedDt))
        end
        currentLookAtPosition = lookAt
        currentCameraPosition = smoothedCameraPos

        -- Camera up = ship up (full follow through inversions)
        camera.CFrame = CFrame.lookAt(smoothedCameraPos :: Vector3, lookAt, shipUp)

        -- Speed FOV
        local speed = if type(vehicleModel:GetAttribute("VehicleSpeed")) == "number"
            then math.max(0, vehicleModel:GetAttribute("VehicleSpeed")) else 0
        local speedFrac = math.clamp(speed / math.max(1, config.maxSpeed), 0, 1)
        local baseFov = savedFieldOfView or camera.FieldOfView
        camera.FieldOfView += (baseFov + speedFrac * SPEED_FOV_MAX + externalFOVOffset - camera.FieldOfView)
            * computeAlpha(8.5, clampedDt)
        return
    end
```

**Why stiffness 8 for camera orientation (not 5 like previous redesign):** With 60Hz physics updates, there's no 20Hz stepping to hide. Stiffness 8 gives a noticeable but not excessive cinematic trailing. Stiffness 5 would feel too sluggish now that the underlying data is smooth.

**Note about speed HUD:** The client now knows `currentSpeed` directly (it computes it). But the camera reads `VehicleSpeed` attribute for speed FOV. The client should write this attribute from FighterClient for consistency:

```lua
-- In FighterClient render loop, after computing currentSpeed:
mdl:SetAttribute("VehicleSpeed", currentSpeed)
```

This also makes the speed available to RemoteVehicleSmoother for remote player engine sound pitch.

**Test criteria:** Camera follows smoothly through loops, barrel rolls, and inversions. Cinematic trailing visible during sharp maneuvers. No snapping.

---

### Step 4: Config Changes

**File:** `src/Shared/CombatConfig.luau`

In the `fighter` vehicle config:

```lua
-- CHANGE:
fighterCameraRollFollow = 1.0,          -- was 0.35 (full follow now)

-- ADD:
fighterCameraOrientLag = 8.0,           -- camera orientation smoothing stiffness

-- REMOVE:
-- fighterCameraPitchFollow = 0.8,      -- DELETE (no longer used)
```

All other fighter config values stay as-is.

---

### Step 5: CombatTypes Changes

**File:** `src/Shared/CombatTypes.luau`

**REPLACE `FighterRuntimeState`** with simplified server-only version:

```lua
export type FighterRuntimeState = {
    fighterId: string,
    entityId: string,
    instance: Model,
    primaryPart: BasePart,
    pilotSeat: Seat,
    config: VehicleConfig,
    pilot: Player?,
    bodyVelocity: BodyVelocity,
    bodyGyro: BodyGyro,
    connections: { RBXScriptConnection },
}
```

All physics fields removed (client handles physics with module-level variables).

---

### Step 6: Integration

**6a: RemoteVehicleSmoother** — For fighters, Roblox's physics replication handles smoothing automatically. The smoother should still:
- Detect fighters via `isFighter` flag (already exists)
- Create engine sound for remote fighters (already works)
- Skip custom CFrame smoothing for fighters (let Roblox handle it)

No code changes needed — the existing `isFighter = true` path already skips walker IK and the standard CFrame smoothing via PivotTo should work fine since the source CFrame updates smoothly from network replication.

**6b: StartupValidator** — Add check for BodyVelocity and BodyGyro on fighter models. Warn if missing (server creates them, but authoring should include them).

**6c: VehicleClient** — Fighter routing to FighterClient stays unchanged.

**6d: CombatInit** — Fighter routing to FighterServer stays unchanged.

---

### Step 7: Model Authoring

The fighter model needs:
1. **Base part (PrimaryPart):** Can be anchored in Studio (server unanchors on registration)
2. **BodyVelocity** on Base: `MaxForce = (0,0,0)`, `P = 10000`
3. **BodyGyro** on Base: `MaxTorque = (0,0,0)`, `P = 50000`, `D = 1000`
4. **PilotSeat** tagged `DriverSeat`
5. **All child parts:** Will be welded to Base on registration (server handles this)
6. Tags: `CombatEntity`, `VehicleEntity`
7. Attributes: `VehicleCategory = "fighter"`, `ConfigId = "fighter"`, `Faction`, `ForwardAxis`

If the model doesn't have BodyVelocity/BodyGyro, the server creates them during registration. But pre-placing them allows tuning P and D values per model.

---

### Step 8: Verification

1. **Mount/dismount:** Sit → takeoff. F → exit → ship falls under gravity.
2. **Takeoff:** Fighter lifts vertically ~12 studs over ~0.9s, then transitions to flight at minSpeed.
3. **Throttle:** W increases speed. S decreases. No input = maintain speed.
4. **Yaw:** Mouse left/right turns ship. Cursor auto-centers.
5. **Pitch:** Mouse up/down pitches. Cursor auto-centers.
6. **Roll:** A/D rolls. Release → auto-levels.
7. **Banked turn:** Roll + pitch = banked turn (local frame rotation).
8. **Full loop:** Pitch up continuously → complete loop. No gimbal lock. No control inversion.
9. **Barrel roll:** Roll + pitch → barrel roll. Controls consistent.
10. **Inverted flight:** Roll 180°. Controls work correctly. Camera follows inverted.
11. **Speed affects turn rate:** Wider turns at maxSpeed.
12. **Angular inertia:** Smooth ramp into turns.
13. **Minimum speed:** Can't go below minSpeed.
14. **Ground collision:** Ship bounces up when hitting terrain.
15. **Camera trailing:** Camera visibly lags during maneuvers, catches up smoothly.
16. **Camera inversions:** No snaps or discontinuities through loops/inversions.
17. **Remote player:** Second player sees smooth fighter movement (Roblox physics replication).
18. **Speed HUD:** Shows speed, updates in real time.
19. **Settling:** Exit mid-flight → ship continues with momentum, falls under gravity, stops on ground.
20. **Freelook (Alt):** Orbit camera works.

**AI build prints:**
```
[P10_SPEED] speed=%.0f throttle=%d
[P10_ORIENT] pitch=%.1f yaw=%.1f roll=%.1f
[P10_COLLISION] type=%s speed=%.0f
```

Note: build prints come from the CLIENT now (not server). Print them every 0.5s.

**Pass/fail:** PASS if all 20 items work. Smooth movement with no 20Hz stepping artifacts.

---

## Summary of Changes

| File | Action | What |
|---|---|---|
| FighterServer.luau | MAJOR SIMPLIFICATION | Remove all physics, replication, input handling. Keep lifecycle + network ownership. |
| FighterClient.luau | MAJOR EXPANSION | Add flight physics computation, BodyMover driving. Remove VehicleInput sending. |
| VehicleCamera.luau | SIMPLIFY fighter branch | Single-layer CFrame lerp (no multi-layer 20Hz compensation). |
| CombatConfig.luau | Minor | `fighterCameraRollFollow=1.0`, add `fighterCameraOrientLag=8.0`, remove `fighterCameraPitchFollow`. |
| CombatTypes.luau | Simplify FighterRuntimeState | Remove all physics fields. Add `bodyVelocity`, `bodyGyro`. |

**No changes to:** CombatInit, VehicleClient, RemoteVehicleSmoother, StartupValidator (minor warn), HealthManager, WeaponServer, or any non-fighter modules.

---

## Critic Self-Review

**Smoothness:**
- PASS: Client-owned physics at 60Hz+ eliminates all 20Hz stepping artifacts by design.
- PASS: Roblox's built-in physics replication handles remote player smoothing automatically.
- PASS: Camera reads from a part that updates every frame — no interpolation layers needed.

**Flight Physics:**
- PASS: Pure CFrame multiplication — no vector decomposition, no gimbal lock.
- PASS: Auto-level as post-rotation correction — no angular velocity oscillation.
- PASS: Full 360° freedom — no pitch clamping.

**Security:**
- FLAG (medium): Movement is client-authoritative. Cheater could modify speed/position. Mitigation: combat (damage, health, hit detection) remains fully server-authoritative. Same security model as default Roblox character movement.

**Regression Risk:**
- PASS: Changes confined to fighter-specific code. Speeder/walker paths completely untouched.
- FLAG (low): FighterRuntimeState type changes — any code referencing old fields will break. Search for usages.
- FLAG (low): FighterClient no longer sends VehicleInput. If FighterServer still has the listener, it harmlessly no-ops (getFighterByPilot returns nil since pilot state is simplified).

**Verdict: APPROVED — 0 blocking issues, 3 low-medium flags.**
