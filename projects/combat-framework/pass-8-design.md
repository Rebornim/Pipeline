# Pass 8 Design: Biped Walker Movement

**Depends on:** Pass 5 (CFrame velocity system), Passes 1-4 (entity/health infrastructure)
**Scope:** Biped walker only. No quad walkers, no combat, no weapons.

---

## Architecture Decision: Separate WalkerServer

VehicleServer.luau is deeply coupled to hover physics (springs, hover points, crest detection, bank angles, lean, lateral grip, water interaction). Walkers share none of that. Rather than bloat VehicleServer with conditional branching, walkers get a parallel module:

- **WalkerServer.luau** — server-side body physics (heading, movement, ground following, gravity, slope)
- **WalkerClient.luau** — client-side input, activation, camera, head rotation
- **WalkerIK.luau** — shared IK module (foot placement, step animation, body secondary motion)

Walkers reuse: the VehicleInput remote, HealthManager, entity lifecycle, StartupValidator, VehicleCamera.

---

## Build Steps

### Step 1: Config + Types + Validator

**CombatConfig.luau — add walker_biped vehicle config:**

```lua
CombatConfig.Vehicles.walker_biped = {
    vehicleClass = "walker_biped",
    entityConfigId = "walker_biped",
    -- Movement
    maxSpeed = 25,
    reverseMaxSpeed = 12,
    strafeMaxSpeed = 15,
    acceleration = 35,
    deceleration = 25,
    brakingDeceleration = 40,
    turnSpeed = 90,            -- deg/sec body turn rate from mouse
    -- Head arc (degrees relative to body forward)
    headYawMin = -120,
    headYawMax = 120,
    headPitchMin = -30,
    headPitchMax = 20,
    -- Body
    walkHeight = 12,           -- studs, body center above ground
    gravity = 196,
    maxClimbSlope = 45,
    -- Fall damage
    fallDamageThreshold = 80,
    fallDamageScale = 0.3,
    -- IK (shared config, used by client)
    legUpperLength = 6,
    legLowerLength = 6,
    footLength = 1.5,
    stepThreshold = 3,         -- studs from home position to trigger step
    stepHeight = 2,            -- peak foot arc height during step
    stepDuration = 0.35,       -- seconds per step
    stepAheadTime = 0.2,       -- seconds to predict ahead for step target
    homeOffsetForward = 0,     -- foot home forward offset from body center
    homeOffsetLateral = 4,     -- foot home lateral offset from body center
    -- Body secondary motion
    bobAmplitude = 0.3,        -- studs of vertical bob per step
    swayAmplitude = 0.4,       -- studs of lateral weight shift per step
    leanMaxAngle = 3,          -- degrees of lean into movement direction
    impactJoltAmplitude = 0.15,-- studs of downward jolt on foot plant
    impactJoltDecay = 12,      -- exponential decay rate for jolt
    -- Camera
    cameraDistance = 25,
    cameraHeight = 12,
    cameraLerpSpeed = 0.1,
    -- Unused speeder fields (zeroed so shared code doesn't break)
    reverseMaxSpeed = 12,
    leanEnabled = false,
    leanTurnRate = 0,
    leanBankAngle = 0,
    leanSpeedPenalty = 0,
    leanEntryDuration = 0,
    leanEntryYawBoost = 0,
    leanEntrySpeedBoost = 0,
    leanExitDuration = 0,
    leanExitCounterBankDeg = 0,
    leanCounterSteerDuration = 0,
    leanCounterSteerRate = 0,
    leanCounterSteerBankDeg = 0,
    leanCameraOffset = 0,
    leanShakeAmplitude = 0,
    leanShakeDuration = 0,
    leanDustEmitCount = 0,
    lateralGripLow = 0,
    lateralGripHigh = 0,
    accelerationTaper = 0,
    accelerationMinFactor = 0,
    tiltStiffness = 0,
    tiltDamping = 0,
    terrainConformity = 0,
    landingShakeThreshold = 0,
    landingShakeIntensity = 0,
    hoverHeight = 1,
    springStiffness = 0,
    springDamping = 0,
    collisionDamageThreshold = 999,
    collisionDamageScale = 0,
    collisionBounce = 0,
    collisionRadius = 0,
    boostEnabled = false,
    boostSpeedMultiplier = 1,
    boostDuration = 0,
    boostCooldown = 0,
    canCrossWater = false,
}
```

**CombatConfig.Entities — add walker_biped entity:**

```lua
walker_biped = {
    hullHP = 300,
    weaponId = nil,    -- no weapons in pass 8
    respawnTime = 30,
},
```

**CombatTypes.luau — extend VehicleInputPayload:**

```lua
export type VehicleInputPayload = {
    throttle: number,
    steerX: number,
    lean: number,
    boost: boolean,
    strafe: number?,  -- NEW: A/D strafe for walkers (-1 to 1)
    aimYaw: number?,  -- NEW: world heading where player is looking (radians)
}
```

**CombatTypes.luau — add WalkerRuntimeState:**

```lua
export type WalkerRuntimeState = {
    walkerId: string,
    entityId: string,
    instance: Model,
    primaryPart: BasePart,
    driverSeat: Seat,
    headPart: BasePart,
    hipAttachments: { left: Attachment, right: Attachment },
    legParts: {
        left: { upper: BasePart, lower: BasePart, foot: BasePart },
        right: { upper: BasePart, lower: BasePart, foot: BasePart },
    },
    config: VehicleConfig,  -- reuse VehicleConfig type (walker fields are extra)
    driver: Player?,
    velocity: Vector3,
    heading: number,         -- body heading in radians
    aimYaw: number,          -- where the player is looking in radians
    isAirborne: boolean,
    lastGroundedTick: number,
    lastVerticalSpeed: number,
    inputThrottle: number,
    inputStrafe: number,
    inputSteerX: number,
    connections: { RBXScriptConnection },
    childPartOffsets: { { part: BasePart, offset: CFrame } },
    -- Replication
    replicationState: string,
    settlingStartTick: number,
    simulatedCFrame: CFrame,
    lastCFrameWriteTick: number,
    lastSpeedUpdateTick: number,
    lastReplicatedSpeed: number,
    lastReplicatedHeading: number,
    wasStopped: boolean,
}
```

**StartupValidator.luau — walker validation (add to vehicle entity validation block):**

When `vehicleConfig.vehicleClass == "walker_biped"`:
- Skip HoverPoint check (walkers don't have hover points)
- Require `WalkerHead` tagged BasePart (exactly 1)
- Require `WalkerHip` tagged Attachments (exactly 2), must be children of PrimaryPart or a descendant of the body
- Require `LeftLeg` and `RightLeg` named Folders, each containing `UpperLeg`, `LowerLeg`, `Foot` named BaseParts
- PrimaryPart and Anchored checks remain (shared with speeders)
- ForwardAxis / ForwardYawOffset check remains (shared)

**Test criteria for step 1:** No runtime test. Validator should accept a correctly-tagged walker model and reject one missing tags. Verify by placing a walker model in Studio and checking for warnings.

---

### Step 2: WalkerServer + WalkerClient (Body Movement)

This step proves the body moves correctly. The walker will be a sliding box — no IK legs yet.

#### WalkerServer.luau (`src/Server/Vehicles/WalkerServer.luau`)

**Module API:**
```lua
WalkerServer.registerWalker(entityId: string, instance: Model, driverSeat: Seat): ()
WalkerServer.getWalkerByEntityId(entityId: string): WalkerRuntimeState?
WalkerServer.getWalkerByDriver(player: Player): WalkerRuntimeState?
WalkerServer.onEntityDestroyed(entityId: string): ()
WalkerServer.onEntityRespawned(entityId: string): ()
WalkerServer.init(remotesFolder: Folder): ()
```

**Registration (`registerWalker`):**
1. Resolve config via `resolveVehicleConfig(instance)` (same function as VehicleServer, or duplicated — since it reads from same CombatConfig.Vehicles)
2. Find PrimaryPart, headPart (tagged WalkerHead), hip attachments (tagged WalkerHip), leg folders+parts
3. Store all child part offsets relative to PrimaryPart (same pattern as VehicleServer: anchor all parts, store CFrame offsets)
4. Connect DriverSeat.Occupant changed → updateDriverFromSeat
5. Compute initial heading from ForwardAxis/ForwardYawOffset (same logic as VehicleServer)
6. Create WalkerRuntimeState, store in walkersByEntityId and walkersByWalkerId maps

**Input handling (`init`):**
Listen on VehicleInput remote (same remote as speeders). In the handler:
1. Look up driver in `driverToWalkerId` map
2. If not found, return (driver is on a speeder or not in a walker)
3. Read `throttle`, `steerX` from payload (same as speeder)
4. Read `strafe` from payload (new field, default 0)
5. Read `aimYaw` from payload (new field, used for head replication)
6. Clamp and store: `state.inputThrottle`, `state.inputStrafe`, `state.inputSteerX`, `state.aimYaw`

**Physics step (`stepSingleWalker`, called from Heartbeat):**

```
stepSingleWalker(state, dt):
    -- Guards (same as VehicleServer)
    if not alive, or parent nil, or void: handle and return

    -- 1. Heading update from mouse
    local turnSpeed = math.rad(config.turnSpeed)  -- convert deg/sec to rad/sec
    local headingDelta = state.inputSteerX * turnSpeed * dt
    state.heading = state.heading + headingDelta

    -- 2. Compute movement direction from WASD relative to heading
    local forward = Vector3.new(-math.sin(heading), 0, -math.cos(heading))
    local right = Vector3.new(forward.Z, 0, -forward.X)  -- perpendicular
    local moveDir = forward * state.inputThrottle + right * state.inputStrafe
    if moveDir.Magnitude > 1 then
        moveDir = moveDir.Unit
    end

    -- 3. Compute target speed
    -- Forward/back speed differs from strafe speed
    local maxSpeed = config.maxSpeed
    if state.inputThrottle < 0 then
        maxSpeed = config.reverseMaxSpeed
    end
    if state.inputStrafe ~= 0 and state.inputThrottle == 0 then
        maxSpeed = config.strafeMaxSpeed
    end
    -- Diagonal: blend speeds
    if state.inputStrafe ~= 0 and state.inputThrottle ~= 0 then
        local fwdFrac = math.abs(state.inputThrottle) / (math.abs(state.inputThrottle) + math.abs(state.inputStrafe))
        maxSpeed = maxSpeed * fwdFrac + config.strafeMaxSpeed * (1 - fwdFrac)
    end

    -- 4. Acceleration/deceleration
    local currentHorizontalSpeed = Vector3.new(state.velocity.X, 0, state.velocity.Z).Magnitude
    local targetSpeed: number
    if moveDir.Magnitude > 0.01 then
        targetSpeed = math.min(currentHorizontalSpeed + config.acceleration * dt, maxSpeed)
    else
        targetSpeed = math.max(currentHorizontalSpeed - config.deceleration * dt, 0)
    end
    -- Apply to velocity
    if moveDir.Magnitude > 0.01 then
        local horizontalVelocity = moveDir * targetSpeed
        state.velocity = Vector3.new(horizontalVelocity.X, state.velocity.Y, horizontalVelocity.Z)
    else
        -- Decelerate existing horizontal velocity
        local hVel = Vector3.new(state.velocity.X, 0, state.velocity.Z)
        if hVel.Magnitude > 0.01 then
            local decelDir = hVel.Unit
            local newSpeed = math.max(hVel.Magnitude - config.deceleration * dt, 0)
            state.velocity = decelDir * newSpeed + Vector3.new(0, state.velocity.Y, 0)
        else
            state.velocity = Vector3.new(0, state.velocity.Y, 0)
        end
    end

    -- 5. Ground detection (center raycast)
    local pos = state.simulatedCFrame.Position
    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Exclude
    rayParams.FilterDescendantsInstances = { state.instance, ...playerCharacters }
    local probeHeight = config.walkHeight * 0.5
    local rayOrigin = pos + Vector3.new(0, probeHeight, 0)
    local rayLength = config.walkHeight * 3
    local result = Workspace:Raycast(rayOrigin, Vector3.new(0, -rayLength, 0), rayParams)

    if result then
        local groundY = result.Position.Y
        local slopeAngle = math.deg(math.acos(math.clamp(result.Normal:Dot(Vector3.yAxis), -1, 1)))

        -- Slope check
        if slopeAngle > config.maxClimbSlope and state.velocity.Y <= 0 then
            -- Block horizontal movement uphill
            local uphill = Vector3.new(result.Normal.X, 0, result.Normal.Z)
            if uphill.Magnitude > 0.01 then
                uphill = uphill.Unit
                local dot = Vector3.new(state.velocity.X, 0, state.velocity.Z):Dot(uphill)
                if dot > 0 then
                    state.velocity = state.velocity - uphill * dot
                end
            end
        end

        local targetY = groundY + config.walkHeight
        if state.isAirborne then
            -- Landing
            if pos.Y <= targetY + 0.5 then
                -- Check fall damage
                local fallSpeed = math.abs(state.lastVerticalSpeed)
                if fallSpeed > config.fallDamageThreshold then
                    local excess = fallSpeed - config.fallDamageThreshold
                    local damage = math.floor(excess * config.fallDamageScale)
                    if damage > 0 then
                        local faction = HealthManager.getFaction(state.entityId) or ""
                        HealthManager.applyDamage(state.entityId, damage, "impact", faction, pos, true)
                    end
                end
                state.velocity = Vector3.new(state.velocity.X, 0, state.velocity.Z)
                state.isAirborne = false
                state.lastGroundedTick = tick()
            end
        else
            -- Grounded: snap to walk height
            state.velocity = Vector3.new(state.velocity.X, 0, state.velocity.Z)
            pos = Vector3.new(pos.X, targetY, pos.Z)
        end
    else
        -- No ground: airborne
        if not state.isAirborne then
            state.isAirborne = true
        end
    end

    -- 6. Gravity when airborne
    if state.isAirborne then
        state.velocity = state.velocity + Vector3.new(0, -config.gravity * dt, 0)
    end
    state.lastVerticalSpeed = state.velocity.Y

    -- 7. Apply velocity
    pos = pos + state.velocity * dt
    state.simulatedCFrame = CFrame.new(pos) * CFrame.Angles(0, state.heading, 0)

    -- 8. Position child parts (rigid offsets — no IK on server)
    for _, entry in ipairs(state.childPartOffsets) do
        entry.part.CFrame = state.simulatedCFrame * entry.offset
    end

    -- 9. Replicate attributes (same pattern as VehicleServer)
    state.instance:SetAttribute("VehicleSpeed", currentHorizontalSpeed)
    state.instance:SetAttribute("VehicleHeading", state.heading)
    state.instance:SetAttribute("WalkerAimYaw", state.aimYaw)

    -- 10. Write CFrame (rate-limited same as VehicleServer)
    state.primaryPart.CFrame = state.simulatedCFrame
```

**Replication state machine:** Same as VehicleServer — Active (driver present, full rate), Settling (driver left, reduced rate), Dormant (stopped, no writes).

**Death/respawn:** Same as VehicleServer. Walker stops on driver death (no coasting). On destruction: same explosion/health path. On respawn: re-register at spawn CFrame.

#### WalkerClient.luau (`src/Client/Vehicles/WalkerClient.luau`)

**Activation flow:** VehicleClient.luau currently detects DriverSeat occupancy. Modify VehicleClient:
- In the activation path, after finding the vehicle model, read `VehicleCategory`
- If config's `vehicleClass == "walker_biped"`, call `WalkerClient.activate(model, entityId, config)` and return without activating speeder systems
- On deactivation, if walker is active, call `WalkerClient.deactivate()`

**WalkerClient API:**
```lua
WalkerClient.activate(model: Model, entityId: string, config: VehicleConfig): ()
WalkerClient.deactivate(): ()
WalkerClient.init(remotesFolder: Folder): ()
```

**Input (in RenderStepped connection):**
```
-- WASD reads (same ContextActionService pattern as VehicleClient)
local throttle = 0
if W held then throttle += 1
if S held then throttle -= 1
local strafe = 0
if A held then strafe -= 1
if D held then strafe += 1

-- Mouse: accumulate virtualCursorX from delta (same as VehicleClient)
-- steerX = virtualCursorX normalized to -1..1

-- Send payload to VehicleInput remote (throttled at VehicleInputRate)
{ throttle = throttle, steerX = steerX, lean = 0, boost = false, strafe = strafe, aimYaw = aimYaw }
```

**Mouse behavior:**
- Lock mouse to center (MouseBehavior = LockCenter)
- Accumulate mouse delta X into `aimYaw` (radians): `aimYaw += deltaX * sensitivity`
- `steerX` sent to server = normalized difference between aimYaw and current body heading, clamped to -1..1
- Body heading (from server) gradually catches up to aimYaw via turnSpeed

**Camera:** Call `VehicleCamera.activate(model, config)` — same camera module as speeders. Walker config has appropriate cameraDistance/cameraHeight values. Freelook (ALT toggle) works the same way.

**Head rotation (client-side visual):**
```
local bodyHeading = model:GetAttribute("VehicleHeading") or 0
local headYawOffset = aimYaw - bodyHeading  -- how far head is turned from body
headYawOffset = clamp(headYawOffset, rad(config.headYawMin), rad(config.headYawMax))
-- Position head part with additional yaw rotation
local headBaseOffset = childPartOffsets[headPart]
local headCFrame = simulatedCFrame * headBaseOffset * CFrame.Angles(0, headYawOffset, 0)
headPart.CFrame = headCFrame
```

**Test criteria for step 2:**
1. Place walker model in Studio with correct tags
2. Sit in DriverSeat → camera activates, mouse locked
3. W/S moves body forward/back, A/D strafes, mouse turns body
4. Body follows terrain height
5. Walk off cliff edge → falls, takes fall damage on landing
6. Steep slope → blocked from climbing
7. Head visually turns toward mouse within arc limits
8. The walker will be a sliding box with rigid child parts — no leg animation yet

**AI build prints for step 2:**
```
[P8_WALKER_REG] entityId=%s walkerId=%s model=%s
[P8_WALKER_INPUT] throttle=%.1f strafe=%.1f steerX=%.2f aimYaw=%.2f
[P8_WALKER_STEP] pos=%.1f,%.1f,%.1f heading=%.2f speed=%.1f airborne=%s
[P8_WALKER_FALL] entityId=%s fallSpeed=%.1f damage=%d
[P8_SUMMARY] walkers=%d errors=%d
```

**Pass/fail:** PASS if `[P8_SUMMARY] errors=0 AND walkers>=1`. Player visually confirms body moves in WASD directions, mouse turns, terrain following works, falls off edge.

---

### Step 3: WalkerIK — Legs + Body Secondary Motion

This is the hard step. Makes the walker look alive.

#### WalkerIK.luau (`src/Client/Vehicles/WalkerIK.luau`)

Pure computation module. No state ownership — called each frame with current data, returns positions.

**Module API:**
```lua
export type WalkerIKState = {
    leftFoot: FootState,
    rightFoot: FootState,
    stepPhase: number,     -- 0 to 1, cycles
    bodyOffset: CFrame,    -- secondary motion offset to apply to body
    lastStepSide: string,  -- "left" | "right"
}

export type FootState = {
    plantedPosition: Vector3,  -- where foot is currently planted on ground
    targetPosition: Vector3,   -- where foot is stepping to (during step)
    state: string,             -- "planted" | "stepping"
    stepProgress: number,      -- 0 to 1 during step
    homePosition: Vector3,     -- where foot "wants" to be
}

WalkerIK.createState(config: VehicleConfig): WalkerIKState
WalkerIK.update(
    ikState: WalkerIKState,
    bodyCFrame: CFrame,
    velocity: Vector3,
    config: VehicleConfig,
    dt: number,
    rayParams: RaycastParams
): (
    CFrame,   -- modified body CFrame (with secondary motion)
    CFrame,   -- left upper leg CFrame
    CFrame,   -- left lower leg CFrame
    CFrame,   -- left foot CFrame
    CFrame,   -- right upper leg CFrame
    CFrame,   -- right lower leg CFrame
    CFrame    -- right foot CFrame
)
```

**Foot home position computation:**
```
local forward = bodyCFrame.LookVector
local right = bodyCFrame.RightVector
-- Left foot home: body position + forward * homeOffsetForward - right * homeOffsetLateral
-- Right foot home: body position + forward * homeOffsetForward + right * homeOffsetLateral
-- Project down via raycast to find ground Y
```

**Step trigger logic:**
```
for each foot:
    compute homePosition (project from body center onto ground)
    distance = (plantedPosition - homePosition).Magnitude
    if distance > config.stepThreshold and foot.state == "planted":
        if other foot is also planted (don't lift both):
            foot.state = "stepping"
            foot.targetPosition = homePosition + horizontalVelocity * config.stepAheadTime
            raycast down to find ground at targetPosition
            foot.stepProgress = 0
```

**Gait priority:** If both feet need to step, step the one that's further from its home position first. Never allow both feet to step simultaneously.

**Step animation (foot arc):**
```
foot.stepProgress += dt / config.stepDuration
if foot.stepProgress >= 1:
    foot.plantedPosition = foot.targetPosition
    foot.state = "planted"
    foot.stepProgress = 0
    -- trigger impact jolt on body
else:
    -- Interpolate foot position along arc
    local t = foot.stepProgress
    local horizontal = plantedPosition:Lerp(targetPosition, t)
    -- Vertical arc: sine curve, peak at t=0.5
    local arcHeight = math.sin(t * math.pi) * config.stepHeight
    foot.currentPosition = horizontal + Vector3.new(0, arcHeight, 0)
```

**Two-bone IK solver (per leg):**
Given: hipPosition (from WalkerHip attachment world position), footPosition (from step logic), upperLength, lowerLength.

```
function solveTwoBoneIK(hip, foot, upperLen, lowerLen, kneeForward)
    local toFoot = foot - hip
    local dist = toFoot.Magnitude
    -- Clamp to reachable range
    dist = math.clamp(dist, math.abs(upperLen - lowerLen) + 0.01, upperLen + lowerLen - 0.01)

    -- Law of cosines for knee angle
    local cosKnee = (upperLen^2 + lowerLen^2 - dist^2) / (2 * upperLen * lowerLen)
    cosKnee = math.clamp(cosKnee, -1, 1)
    local kneeAngle = math.acos(cosKnee)

    -- Hip angle
    local cosHip = (upperLen^2 + dist^2 - lowerLen^2) / (2 * upperLen * dist)
    cosHip = math.clamp(cosHip, -1, 1)
    local hipAngle = math.acos(cosHip)

    -- Build CFrames
    local hipToFoot = (foot - hip).Unit
    -- Knee bends forward (kneeForward hint)
    -- ... standard two-bone IK CFrame construction
    return upperLegCFrame, lowerLegCFrame, footCFrame
end
```

The exact CFrame construction for two-bone IK:
1. Compute the IK plane (hip, foot, kneeForward form the plane)
2. Upper leg: starts at hip, rotates by hipAngle in the IK plane
3. Lower leg: starts at knee (end of upper leg), rotates by kneeAngle
4. Foot: at foot position, oriented flat to ground normal (from raycast)

**Body secondary motion:**

All computed as CFrame offsets applied to the server body CFrame.

1. **Weight shift (lateral sway):** When one foot is stepping, body shifts toward the planted foot.
```
local swayTarget = 0
if leftFoot.state == "stepping" then swayTarget = config.swayAmplitude   -- shift right
if rightFoot.state == "stepping" then swayTarget = -config.swayAmplitude -- shift left
smoothedSway = lerp(smoothedSway, swayTarget, 1 - math.exp(-8 * dt))
bodyOffset *= CFrame.new(smoothedSway, 0, 0)
```

2. **Bob (vertical):** Body dips during mid-step, rises at plant.
```
local bobPhase = currentSteppingFoot.stepProgress
local bob = -math.sin(bobPhase * math.pi) * config.bobAmplitude
bodyOffset *= CFrame.new(0, bob, 0)
```

3. **Lean (tilt into movement):** Body tilts in movement direction proportional to speed.
```
local speed = velocity.Magnitude
local leanFraction = math.clamp(speed / config.maxSpeed, 0, 1)
local moveAngle = math.atan2(velocity.X, velocity.Z) - heading
bodyOffset *= CFrame.Angles(0, 0, -math.sin(moveAngle) * rad(config.leanMaxAngle) * leanFraction)
    * CFrame.Angles(-math.cos(moveAngle) * rad(config.leanMaxAngle) * leanFraction * 0.5, 0, 0)
```

4. **Impact jolt:** On foot plant, a sharp downward impulse that decays exponentially.
```
when foot plants:
    joltValue = config.impactJoltAmplitude
each frame:
    joltValue *= math.exp(-config.impactJoltDecay * dt)
    bodyOffset *= CFrame.new(0, -joltValue, 0)
```

5. **Terrain tilt:** Slight body tilt based on angle between the two foot positions.
```
local footDelta = rightFoot.plantedPosition - leftFoot.plantedPosition
local tiltAngle = math.atan2(footDelta.Y, footDelta.Magnitude) * 0.3  -- 30% conformity
bodyOffset *= CFrame.Angles(0, 0, tiltAngle)
```

**Integration into WalkerClient:**
Each RenderStepped frame:
1. Read server body CFrame from model
2. Call `WalkerIK.update(ikState, bodyCFrame, velocity, config, dt, rayParams)`
3. Returns: modified body CFrame + 6 leg part CFrames
4. Position all parts

**Integration into RemoteVehicleSmoother (for remote walkers):**
When a remote vehicle has `vehicleClass == "walker_biped"`:
1. Create a WalkerIKState for it
2. Each frame, compute velocity from position deltas
3. Call WalkerIK.update with smoothed body CFrame and inferred velocity
4. Position leg parts

**Test criteria for step 3:**
1. Walk forward on flat ground → feet alternate stepping, smooth arcs
2. Walk on sloped terrain → feet plant at different heights, body tilts slightly
3. Stand still → both feet planted, body still (no drift)
4. Start moving → first step triggers, body shifts weight
5. Change direction (strafe) → feet adjust target positions, smooth transition
6. Impact jolt visible on each foot plant
7. Bob visible — body dips mid-step, rises at plant
8. Weight shift visible — body sways toward planted foot

**AI build prints for step 3:**
```
[P8_IK_STEP] side=%s from=%.1f,%.1f,%.1f to=%.1f,%.1f,%.1f
[P8_IK_PLANT] side=%s pos=%.1f,%.1f,%.1f
[P8_IK_BODY] bob=%.3f sway=%.3f jolt=%.3f lean=%.2f
```

**Pass/fail:** Visual only — user confirms feet plant on terrain, body has visible secondary motion, transitions between movements look smooth. No quantitative pass/fail for IK feel.

---

### Step 4: Head Rotation + Remote Walker Visuals + Placeholder Polish

**Head rotation (already in step 2, verify working):**
- Head yaw replicated via `WalkerAimYaw` attribute (server sets from input)
- Local client: computes head CFrame from aimYaw vs bodyHeading
- Remote clients: read `WalkerAimYaw` attribute, compute head CFrame

**Remote walker IK:**
- RemoteVehicleSmoother.luau: detect `walker_biped` class via `VehicleCategory` attribute
- Create WalkerIKState per remote walker
- Each frame: read smoothed position, infer velocity, call WalkerIK.update, position leg parts
- Read `WalkerAimYaw` for head rotation
- Leg parts are excluded from the rigid childPartOffset positioning (they're IK-driven instead)

**Placeholder model specification:**

```
WalkerPlaceholder (Model, PrimaryPart = Body)
  Tags: CombatEntity, VehicleEntity
  Attributes: VehicleCategory="walker_biped", ConfigId="walker_biped",
              Faction="empire", ForwardAxis="-Z"
  ├── Body (Part, 4x6x4 studs, Anchored)
  │   ├── DriverSeat (Seat, inside Body, Tag: DriverSeat)
  │   ├── LeftHip (Attachment, Position = -2, -3, 0, Tag: WalkerHip)
  │   └── RightHip (Attachment, Position = 2, -3, 0, Tag: WalkerHip)
  ├── Head (Part, 3x2x3 studs, Tag: WalkerHead)
  │   └── positioned on front-bottom of Body
  ├── LeftLeg (Folder)
  │   ├── UpperLeg (Part, 1x6x1 studs)
  │   ├── LowerLeg (Part, 1x6x1 studs)
  │   └── Foot (Part, 1.5x0.5x2 studs)
  └── RightLeg (Folder)
      ├── UpperLeg (Part, 1x6x1 studs)
      ├── LowerLeg (Part, 1x6x1 studs)
      └── Foot (Part, 1.5x0.5x2 studs)
```

Body center sits at walkHeight (12) above ground. Hips at -3 from body center = 9 studs above ground. Upper leg (6) + lower leg (6) = 12 studs total reach. With hips at 9 studs up, legs can reach the ground at 9 studs below hip, with 3 studs of spare reach for uneven terrain and step arcs.

**Test criteria for step 4:**
1. Second client joins → sees the walker moving with IK legs (not rigid)
2. Remote walker head turns based on local client's aim direction
3. Placeholder model proportions look reasonable
4. Walking on varied terrain (hills, flat, edges) looks natural from both local and remote perspective

---

## Integration Points with Existing Code

| Existing module | Change | Why |
|---|---|---|
| CombatInit.server.luau | Add WalkerServer.init() call. Detect `walker_biped` vehicleClass, call WalkerServer.registerWalker instead of VehicleServer.registerVehicle. Add WalkerServer to destroy/respawn callbacks. | Walker registration |
| VehicleClient.luau | In activation path, check vehicleClass. If `walker_biped`, delegate to WalkerClient.activate() and return. | Walker client routing |
| CombatClient.client.luau | Require and init WalkerClient | Module loading |
| RemoteVehicleSmoother.luau | Detect walker_biped for remote walkers. Create WalkerIKState. Run IK instead of rigid positioning for leg parts. | Remote walker visuals |
| StartupValidator.luau | Walker-specific validation (skip HoverPoint, require WalkerHead + WalkerHip + leg structure) | Model validation |
| CombatConfig.luau | New vehicle config + entity config | Config |
| CombatTypes.luau | WalkerRuntimeState, extended VehicleInputPayload | Types |
| HealthManager | No changes. Walker entities register same as any entity. | - |
| VehicleCamera | No changes. Walker passes its own cameraDistance/cameraHeight. | - |

## Cross-Module Data Flow

1. **Input:** Player presses WASD/mouse → WalkerClient reads → sends VehicleInput remote with {throttle, steerX, strafe, aimYaw} → WalkerServer receives, stores on state
2. **Physics:** WalkerServer.Heartbeat → stepSingleWalker → updates simulatedCFrame, writes to PrimaryPart.CFrame, sets attributes (VehicleSpeed, VehicleHeading, WalkerAimYaw)
3. **Local visuals:** WalkerClient.RenderStepped → reads body CFrame → calls WalkerIK.update → positions leg parts + applies body secondary motion + rotates head
4. **Remote visuals:** RemoteVehicleSmoother.RenderStepped → reads replicated CFrame → smooths → calls WalkerIK.update → positions leg parts + rotates head
5. **Health:** HealthManager tracks walker entity. Fall damage: WalkerServer calls HealthManager.applyDamage. Destruction/respawn callbacks routed to WalkerServer.

## New Config Values Summary

All in `CombatConfig.Vehicles.walker_biped` (tunable via Rojo sync):

| Key | Default | What it controls |
|---|---|---|
| maxSpeed | 25 | Forward walk speed (studs/s) |
| reverseMaxSpeed | 12 | Backward speed |
| strafeMaxSpeed | 15 | Sideways speed |
| acceleration | 35 | How fast it reaches target speed |
| deceleration | 25 | Coast-down speed |
| brakingDeceleration | 40 | Active stop speed |
| turnSpeed | 90 | Body turn rate from mouse (deg/s) |
| headYawMin / headYawMax | -120 / 120 | Head horizontal arc (deg) |
| headPitchMin / headPitchMax | -30 / 20 | Head vertical arc (deg) |
| walkHeight | 12 | Body center above ground (studs) |
| gravity | 196 | Fall acceleration |
| maxClimbSlope | 45 | Steepest walkable slope (deg) |
| fallDamageThreshold | 80 | Min fall speed for damage |
| fallDamageScale | 0.3 | HP per unit fall speed |
| legUpperLength | 6 | Upper leg bone length |
| legLowerLength | 6 | Lower leg bone length |
| stepThreshold | 3 | Distance to trigger new step |
| stepHeight | 2 | Peak foot arc height |
| stepDuration | 0.35 | Seconds per step |
| stepAheadTime | 0.2 | Predictive step target |
| homeOffsetForward | 0 | Foot home forward from body |
| homeOffsetLateral | 4 | Foot home lateral from center |
| bobAmplitude | 0.3 | Body vertical bob (studs) |
| swayAmplitude | 0.4 | Body lateral sway (studs) |
| leanMaxAngle | 3 | Body lean angle (deg) |
| impactJoltAmplitude | 0.15 | Step impact jolt (studs) |
| impactJoltDecay | 12 | Jolt decay rate |
| cameraDistance | 25 | Camera pullback |
| cameraHeight | 12 | Camera elevation |
| cameraLerpSpeed | 0.1 | Camera follow smoothness |

## Golden Tests

### Test GT-8.1: Walker Forward/Back/Strafe Movement
- **Setup:** Walker model (walker_biped config, empire) on flat terrain.
- **Action:** Player sits in DriverSeat. Press W (forward), S (reverse), A (strafe left), D (strafe right). Mouse to turn.
- **Expected:** Walker body moves in correct WASD directions relative to body facing. Mouse turns body. Speed matches config values approximately. Body stays at walkHeight above ground.
- **Pass condition:** `[P8_SUMMARY] walkers>=1 errors=0`. Visual: walker moves in all 4 directions, body height consistent.

### Test GT-8.2: Cliff Fall + Fall Damage
- **Setup:** Walker on elevated platform (20+ studs above ground). walkHeight=12, fallDamageThreshold=80, gravity=196.
- **Action:** Walk off edge.
- **Expected:** Walker falls under gravity. Lands on ground below. Fall damage applied if impact speed exceeds threshold. Walker resumes walking.
- **Pass condition:** `[P8_WALKER_FALL]` log shows damage > 0 if fall was high enough. Walker visually lands and can move again.

### Test GT-8.3: IK Foot Placement on Uneven Terrain
- **Setup:** Walker on terrain with hills and slopes within maxClimbSlope.
- **Action:** Walk across varied terrain.
- **Expected:** Feet plant at actual ground height (not floating or clipping). Body bobs and sways. Steps adapt to terrain. Head follows mouse within arc.
- **Pass condition:** Visual only. Feet touch ground. No floating feet. Body secondary motion visible.

### Regression
- Re-run: speeder tests (GT-5.x) to verify VehicleServer is unaffected
- Re-run: turret tests (GT-1.1 through GT-4.x) to verify entity system unchanged

---

## Critic Self-Review

**Cross-Module Contracts:**
- PASS: WalkerServer uses same HealthManager API as VehicleServer (applyDamage, isAlive, getFaction). No signature changes.
- PASS: VehicleInput remote payload is backward-compatible (strafe/aimYaw are optional fields, existing clients don't send them, server defaults to 0/nil).
- PASS: WalkerIK is a pure computation module with no dependencies on remotes or server state.

**Regression Risk:**
- FLAG: VehicleClient now has a routing check for walker_biped. Must ensure the check only triggers for walker class and falls through cleanly for speeders. Test: sit in a speeder after adding walker code, verify speeder still works.
- FLAG: CombatInit adds new module init and registration path. Must ensure walker registration doesn't interfere with vehicle registration (separate maps, separate heartbeat).

**Security:**
- PASS: Walker input goes through same server-validated VehicleInput remote. strafe/aimYaw clamped server-side. Head direction is server-replicated (not client-set attribute).

**Performance:**
- PASS: WalkerIK runs per-walker per-client. 2 raycasts (foot targets) + 2 IK solves per walker per frame. With 2-4 walkers on screen, negligible.
- PASS: Server walker step is simpler than speeder step (1 center raycast vs 4 hover raycasts).

**Startup Validation:**
- PASS: New walker-specific checks added to StartupValidator. Skip HoverPoint for walkers. Require WalkerHead, WalkerHip, leg structure.

**Verdict: APPROVED — 0 blocking issues, 2 flags (both low-risk).**
