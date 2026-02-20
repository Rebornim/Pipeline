# Pass 5 Design: Speeder Movement

**Depends on:** Passes 1-4 (combat framework on turrets)
**Scope:** CFrame-based velocity movement, hover physics, collision, fall damage, camera, placeholder speeder. **NO COMBAT.**

---

## 1. Architecture Overview

Pass 5 introduces the vehicle movement core. Speeders are anchored models positioned via CFrame every Heartbeat — no Roblox physics engine. The same architecture ships will use.

**Server-authoritative movement:** Server runs physics, sets model CFrame. Client sends input, runs camera. If driver feel is poor due to network latency, client-side prediction can be added as a follow-up — the physics module (`HoverPhysics`) is shared-requireable for this purpose.

**Entity integration:** Vehicles are CombatEntity models (HealthManager tracks HP). They also have a `VehicleEntity` tag for vehicle-specific discovery. No weapons, no shields this pass.

---

## 2. New Types (CombatTypes.luau)

Add after existing types:

```luau
export type VehicleConfig = {
    vehicleClass: string,            -- "light_speeder" | "heavy_speeder" | "biped_walker" | "quad_walker"
    entityConfigId: string,          -- key into CombatConfig.Entities (for HP)
    maxSpeed: number,                -- studs/sec
    acceleration: number,            -- studs/sec^2
    deceleration: number,            -- studs/sec^2 (natural coast-down when no throttle)
    brakingDeceleration: number,     -- studs/sec^2 (pressing reverse while moving forward)
    reverseMaxSpeed: number,         -- studs/sec
    turnSpeed: number,               -- degrees/sec at max steer input
    hoverHeight: number,             -- studs above ground
    springStiffness: number,         -- spring constant (force per stud of compression)
    springDamping: number,           -- damping coefficient
    gravity: number,                 -- studs/sec^2 downward
    maxClimbSlope: number,           -- degrees
    fallDamageThreshold: number,     -- vertical studs/sec before damage starts
    fallDamageScale: number,         -- HP per stud/sec over threshold
    collisionDamageThreshold: number,-- forward studs/sec before collision damage
    collisionDamageScale: number,    -- HP per stud/sec over threshold
    collisionBounce: number,         -- velocity reflection coefficient 0-1
    collisionRadius: number,         -- studs, for vehicle-to-vehicle detection
    cameraDistance: number,          -- studs behind vehicle
    cameraHeight: number,            -- studs above vehicle
    cameraLerpSpeed: number,         -- 0-1, camera follow smoothing per frame
}

export type VehicleInputPayload = {
    throttle: number,  -- -1, 0, or 1
    steerX: number,    -- -1 to 1 (mouse X relative to screen center)
}

export type VehicleRuntimeState = {
    vehicleId: string,
    entityId: string,
    instance: Model,
    primaryPart: BasePart,
    driverSeat: Seat,
    hoverPoints: { BasePart },    -- 4 tagged hover point parts
    config: VehicleConfig,
    driver: Player?,
    velocity: Vector3,
    heading: number,               -- radians (yaw)
    isAirborne: boolean,
    lastGroundedTick: number,
    lastVerticalSpeed: number,     -- for fall damage on landing
    inputThrottle: number,
    inputSteerX: number,
    connections: { RBXScriptConnection },
}
```

---

## 3. New Enums (CombatEnums.luau)

```luau
CombatEnums.VehicleClass = {
    LightSpeeder = "light_speeder",
    HeavySpeeder = "heavy_speeder",
    BipedWalker = "biped_walker",
    QuadWalker = "quad_walker",
}

CombatEnums.DamageType.Impact = "impact"   -- add to existing DamageType table
```

---

## 4. New Config (CombatConfig.luau)

### New damage type multiplier

Add to `CombatConfig.DamageTypeMultipliers`:
```luau
impact = { shieldMult = 1.0, hullMult = 1.0, bypass = 0 },
```

### New entity config

Add to `CombatConfig.Entities`:
```luau
light_speeder = {
    hullHP = 100,
    weaponId = nil,
    respawnTime = nil,  -- vehicles don't respawn
},
```

### New vehicles section

```luau
CombatConfig.Vehicles = {
    light_speeder = {
        vehicleClass = "light_speeder",
        entityConfigId = "light_speeder",
        maxSpeed = 120,
        acceleration = 80,
        deceleration = 30,
        brakingDeceleration = 60,
        reverseMaxSpeed = 30,
        turnSpeed = 120,
        hoverHeight = 4,
        springStiffness = 300,
        springDamping = 40,
        gravity = 196.2,
        maxClimbSlope = 45,
        fallDamageThreshold = 40,
        fallDamageScale = 0.5,
        collisionDamageThreshold = 30,
        collisionDamageScale = 1.0,
        collisionBounce = 0.2,
        collisionRadius = 4,
        cameraDistance = 15,
        cameraHeight = 6,
        cameraLerpSpeed = 0.15,
    },
}
```

### New global config values

```luau
CombatConfig.VehicleInputRate = 30            -- max input sends per second
CombatConfig.VehicleStopThreshold = 0.5       -- studs/sec, below this = stopped
CombatConfig.VehicleCollisionRayCount = 3     -- rays for forward collision
CombatConfig.VehicleCollisionLookahead = 2.0  -- frames ahead to check
CombatConfig.VehicleMaxTiltLerp = 8.0         -- tilt alignment speed (per sec)
```

---

## 5. New Files

### 5a. Server/Vehicles/VehicleServer.luau

Manages all vehicle lifecycle and movement.

**Public API:**

```luau
function VehicleServer.init(remotesFolder: Folder): ()
-- Wires VehicleInput and VehicleExitRequest remotes.
-- Starts Heartbeat movement loop.

function VehicleServer.registerVehicle(
    entityId: string,
    instance: Model,
    vehicleConfigId: string,
    driverSeat: Seat,
    hoverPoints: { BasePart }
): ()
-- Creates VehicleRuntimeState entry.
-- Connects driverSeat.Changed to detect occupant enter/exit.
-- Sets initial heading from model's current CFrame yaw.
-- Sets initial velocity to Vector3.zero.

function VehicleServer.onEntityDestroyed(entityId: string): ()
-- Cleans up vehicle state: disconnects all connections,
-- ejects driver (Humanoid.Sit = false), removes from active table.

function VehicleServer.getVehicleByEntityId(entityId: string): VehicleRuntimeState?

function VehicleServer.getVehicleByDriver(player: Player): VehicleRuntimeState?
-- Internal storage: driverToVehicleId: { [Player]: string } map.
-- Populated on driver enter (seat occupant detection), cleared on driver exit/disconnect.
```

**Internal — Heartbeat loop** (`stepVehicles(dt)`):

For each registered vehicle:

1. **Read input:** Use stored `inputThrottle` / `inputSteerX` (last received from client).

2. **Run hover physics:** Call `HoverPhysics.step(state, dt)` → returns `verticalAccel: number, targetTilt: CFrame, groundedCount: number`.

3. **Determine grounded:** `groundedCount >= 2` means grounded, else airborne.

4. **Apply steering (grounded only):**
   ```
   headingDelta = steerX * turnSpeed * dt (in radians)
   heading += headingDelta
   ```

5. **Apply throttle (grounded only):**
   ```
   forwardDir = Vector3.new(-sin(heading), 0, -cos(heading))
   currentForwardSpeed = velocity:Dot(forwardDir)

   if throttle > 0:
       -- accelerate forward, cap at maxSpeed
       targetSpeed = min(currentForwardSpeed + acceleration * dt, maxSpeed)
   elseif throttle < 0:
       if currentForwardSpeed > 0:
           -- braking
           targetSpeed = max(currentForwardSpeed - brakingDeceleration * dt, 0)
       else:
           -- reversing, cap at reverseMaxSpeed
           targetSpeed = max(currentForwardSpeed - acceleration * dt, -reverseMaxSpeed)
   else:
       -- coasting, decelerate toward 0
       if currentForwardSpeed > 0:
           targetSpeed = max(currentForwardSpeed - deceleration * dt, 0)
       elseif currentForwardSpeed < 0:
           targetSpeed = min(currentForwardSpeed + deceleration * dt, 0)

   velocity = forwardDir * targetSpeed + Vector3.new(0, velocity.Y, 0)
   ```

6. **Apply vertical physics:**
   ```
   velocity = velocity + Vector3.new(0, verticalAccel * dt, 0)
   ```

7. **Fall damage check:** If was airborne and now grounded:
   ```
   impactSpeed = abs(lastVerticalSpeed)
   if impactSpeed > fallDamageThreshold:
       damage = floor((impactSpeed - fallDamageThreshold) * fallDamageScale + 0.5)
       HealthManager.applyDamage(entityId, damage, "impact", "", position, true)
       print "[P5_FALL_DAMAGE] ..."
   ```

8. **Collision detection:** Call `CollisionHandler.checkObstacles(state, dt)` → may modify `velocity`, may apply damage.

9. **Vehicle-to-vehicle collision:** Call `CollisionHandler.checkVehicleCollisions(state, allVehicles)` → may modify both vehicles' velocities, may apply damage.

10. **Slope check (grounded):** If terrain slope > maxClimbSlope, prevent forward velocity in that direction. Vehicle slides back.

11. **Apply position:**
    ```
    position = primaryPart.Position + velocity * dt
    ```

12. **Apply orientation:** Lerp current up-vector toward `targetTilt`'s up-vector at `VehicleMaxTiltLerp * dt`. Build CFrame from heading + tilted up.

13. **Set model CFrame:** `instance:PivotTo(newCFrame)`.

14. **Update state:** Store new position, velocity, airborne flag, lastVerticalSpeed.

15. **Stop check:** If no driver and `velocity.Magnitude < VehicleStopThreshold`, set velocity to zero (fully stopped).

16. **Attribute replication (throttled):** Update `instance:SetAttribute("VehicleSpeed", horizontalSpeed)` only every 6th frame (10Hz) or when speed delta > 1 stud/sec since last update. Track `lastSpeedUpdateTick` and `lastReplicatedSpeed` per vehicle.

**Seat occupant detection** (per vehicle, connected during `registerVehicle`):

```luau
driverSeat:GetPropertyChangedSignal("Occupant"):Connect(function()
    local humanoid = driverSeat.Occupant
    if humanoid then
        local character = humanoid.Parent
        local player = Players:GetPlayerFromCharacter(character)
        if player then
            state.driver = player
            state.inputThrottle = 0
            state.inputSteerX = 0
            print("[P5_DRIVER_ENTER] vehicleId=%s player=%s", entityId, player.Name)
        end
    else
        local previousDriver = state.driver
        state.driver = nil
        state.inputThrottle = 0
        state.inputSteerX = 0
        print("[P5_DRIVER_EXIT] vehicleId=%s player=%s", entityId,
            previousDriver and previousDriver.Name or "unknown")
    end
end)
```

**VehicleInput handler:**

```luau
vehicleInputRemote.OnServerEvent:Connect(function(player, payload)
    -- Validate payload shape
    if type(payload) ~= "table" then return end
    local throttle = payload.throttle
    local steerX = payload.steerX
    if type(throttle) ~= "number" or type(steerX) ~= "number" then return end

    local state = getVehicleByDriver(player)
    if state == nil then return end

    state.inputThrottle = math.clamp(math.round(throttle), -1, 1)
    state.inputSteerX = math.clamp(steerX, -1, 1)
end)
```

**VehicleExitRequest handler:**

```luau
vehicleExitRemote.OnServerEvent:Connect(function(player)
    local state = getVehicleByDriver(player)
    if state == nil then return end

    local character = player.Character
    if character then
        local humanoid = character:FindFirstChildOfClass("Humanoid")
        if humanoid then
            humanoid.Sit = false
        end
    end
end)
```

**PlayerRemoving cleanup:**

```luau
Players.PlayerRemoving:Connect(function(player)
    local state = getVehicleByDriver(player)
    if state then
        state.driver = nil
        state.inputThrottle = 0
        state.inputSteerX = 0
    end
end)
```

---

### 5b. Server/Vehicles/HoverPhysics.luau

Pure math module. No side effects, no state mutation beyond return values.

**Public API:**

```luau
function HoverPhysics.step(
    hoverPoints: { BasePart },
    currentPosition: Vector3,
    currentVelocityY: number,
    hoverHeight: number,
    springStiffness: number,
    springDamping: number,
    gravity: number,
    maxTiltLerp: number,
    currentUpVector: Vector3,
    dt: number
): (number, CFrame, number)
-- Returns:
--   verticalAccel: number (net vertical acceleration including gravity)
--   targetTilt: CFrame (orientation-only CFrame for terrain-aligned tilt)
--   groundedCount: number (how many of the 4 points found ground, 0-4)
```

**Internal logic:**

```
rayParams = RaycastParams.new()
rayParams.FilterType = Exclude
rayParams.FilterDescendantsInstances = { vehicleModel }
rayMaxDistance = hoverHeight * 3

totalSpringForce = 0
normalSum = Vector3.zero
groundedCount = 0

for each hoverPoint in hoverPoints:
    origin = hoverPoint.WorldPosition
    result = workspace:Raycast(origin, Vector3.new(0, -rayMaxDistance, 0), rayParams)

    if result:
        groundedCount += 1
        distToGround = result.Distance
        compression = hoverHeight - distToGround
        springForce = springStiffness * compression - springDamping * currentVelocityY
        totalSpringForce += springForce
        normalSum += result.Normal
    -- else: no ground = no spring force at this point

averageForce = totalSpringForce / 4  -- average across all 4 points
verticalAccel = averageForce - gravity

if groundedCount > 0:
    averageNormal = normalSum.Unit
    targetTilt = CFrame from aligning Y-axis to averageNormal (using heading as forward reference)
else:
    targetTilt = level (Y-up)

return verticalAccel, targetTilt, groundedCount
```

The RaycastParams filter must include the vehicle model itself. Pass the model instance or filter list as parameter. Adjust the signature:

```luau
function HoverPhysics.step(
    hoverPoints: { BasePart },
    vehicleModel: Model,
    currentVelocityY: number,
    hoverHeight: number,
    springStiffness: number,
    springDamping: number,
    gravity: number,
    dt: number
): (number, Vector3, number)
-- Returns:
--   verticalAccel: number
--   averageGroundNormal: Vector3 (Vector3.yAxis if airborne)
--   groundedCount: number
```

The tilt math is done by VehicleServer using the returned normal — keeps HoverPhysics pure math. Tilt aligns the vehicle's up-vector with the terrain normal while preserving heading (yaw). The vehicle tilts on slopes (pitch/roll from terrain) but the forward direction stays locked to the heading angle. VehicleServer builds the final CFrame from heading yaw + terrain-aligned up-vector.

---

### 5c. Client/Vehicles/VehicleClient.luau

Handles input capture and vehicle mode activation on the client.

**Public API:**

```luau
function VehicleClient.init(remotesFolder: Folder): ()
-- Caches remotes. Watches Humanoid.SeatPart for DriverSeat detection.
-- Inits VehicleCamera.
```

**Internal state:**

```luau
local activeVehicleEntityId: string? = nil
local activeVehicleConfig: VehicleConfig? = nil
local inputConnection: RBXScriptConnection? = nil
local seatConnection: RBXScriptConnection? = nil
local inputAccumulator: number = 0
```

**Seat detection logic** (connected on init, watches `Humanoid.SeatPart`):

```luau
-- On character added / humanoid available:
humanoid:GetPropertyChangedSignal("SeatPart"):Connect(function()
    local seatPart = humanoid.SeatPart
    if seatPart and CollectionService:HasTag(seatPart, "DriverSeat") then
        local vehicleModel = findVehicleModelFromSeat(seatPart)
        if vehicleModel then
            local entityId = vehicleModel:GetAttribute("EntityId")
            local vehicleConfigId = vehicleModel:GetAttribute("VehicleConfigId")
            if entityId and vehicleConfigId then
                local config = CombatConfig.Vehicles[vehicleConfigId]
                if config then
                    enterVehicleMode(entityId, vehicleModel, config)
                end
            end
        end
    elseif activeVehicleEntityId then
        exitVehicleMode()
    end
end)
```

**`findVehicleModelFromSeat(seat: Seat): Model?`**

Walk up ancestors until finding a Model with `VehicleEntity` tag. Return it or nil.

**Guard in render loop:** If `vehicleModel.Parent == nil`, call `exitVehicleMode()` immediately (vehicle was destroyed/removed mid-drive).

**`enterVehicleMode(entityId, model, config)`:**

1. Set `activeVehicleEntityId`, `activeVehicleConfig`
2. Start input loop (RenderStepped):
   - Read W/S → throttle (-1, 0, 1)
   - Read mouse X position → normalize to -1..1 relative to screen center
   - Throttle send rate to `VehicleInputRate` per second
   - Fire `VehicleInput` remote with `{ throttle = throttle, steerX = steerX }`
3. Bind F key (Enum.KeyCode.F) → fire `VehicleExitRequest` remote
4. Activate VehicleCamera with config
5. Show HUD: `CombatHUD.showHP(entityId)`, `CombatHUD.showSpeed(true)`
6. Hide weapon HUD: `CombatHUD.showCrosshair(false)`, `CombatHUD.showHeat(false)`, `CombatHUD.showAmmo(false)`

**`exitVehicleMode()`:**

1. Disconnect input loop
2. Unbind F key
3. Deactivate VehicleCamera (restores default camera)
4. Hide HUD: `CombatHUD.hideHP()`, `CombatHUD.showSpeed(false)`
5. Clear `activeVehicleEntityId`, `activeVehicleConfig`

**Input capture details:**

```luau
-- Mouse steer: normalized horizontal offset from screen center
local mousePos = UserInputService:GetMouseLocation()
local viewportSize = workspace.CurrentCamera.ViewportSize
local screenCenterX = viewportSize.X / 2
local steerX = math.clamp((mousePos.X - screenCenterX) / (screenCenterX * 0.7), -1, 1)
-- The 0.7 factor means mouse at 70% from center = full turn. Tunable.

-- Throttle from keyboard
local throttle = 0
if UserInputService:IsKeyDown(Enum.KeyCode.W) then throttle = 1
elseif UserInputService:IsKeyDown(Enum.KeyCode.S) then throttle = -1 end
```

---

### 5d. Client/Vehicles/VehicleCamera.luau

3rd person follow camera for vehicles.

**Public API:**

```luau
function VehicleCamera.activate(vehicleModel: Model, config: VehicleConfig): ()
-- Saves current camera.CameraType to module-scope savedCameraType.
-- Sets camera.CameraType to Enum.CameraType.Scriptable.
-- Stores RenderStepped connection in module-scope cameraConnection.
-- Starts camera update loop.

function VehicleCamera.deactivate(): ()
-- Disconnects cameraConnection (if not nil).
-- Restores camera.CameraType to savedCameraType.
-- Clears module-scope refs (cameraConnection = nil, savedCameraType = nil).
```

**Camera update logic** (RenderStepped):

```luau
local vehicleCF = vehicleModel:GetPivot()
local vehiclePos = vehicleCF.Position
local vehicleLook = vehicleCF.LookVector

local targetCamPos = vehiclePos
    - vehicleLook * config.cameraDistance
    + Vector3.new(0, config.cameraHeight, 0)

local targetLookAt = vehiclePos + Vector3.new(0, config.cameraHeight * 0.3, 0)

-- Smooth follow
currentCamPos = currentCamPos:Lerp(targetCamPos, config.cameraLerpSpeed)
camera.CFrame = CFrame.lookAt(currentCamPos, targetLookAt)
```

On `activate()`, set `currentCamPos` to the initial target position (no lerp on first frame).

---

### 5e. Server/Vehicles/CollisionHandler.luau

Handles obstacle and vehicle-to-vehicle collision detection for the vehicle step loop. Stateless — reads vehicle state, returns results, callers apply changes.

**Dependencies:** `CombatConfig` (for global collision ray settings), `HealthManager` (for applying collision damage).

**Public API:**

```luau
function CollisionHandler.checkObstacles(
    state: VehicleRuntimeState,
    dt: number,
    rayParams: RaycastParams
): ()
-- Casts forward rays to detect walls/terrain ahead of the vehicle.
-- If an obstacle is within stopping distance, modifies state.velocity
-- (bounce reflection) and applies collision damage via HealthManager.
-- Mutates state.velocity directly.
```

**checkObstacles internal logic:**

```
forwardDir = Vector3.new(-sin(state.heading), 0, -cos(state.heading))
forwardSpeed = state.velocity:Dot(forwardDir)
if forwardSpeed < 5 then return end  -- skip if barely moving

lookaheadDist = forwardSpeed * CombatConfig.VehicleCollisionLookahead * dt * 60
-- dt * 60 normalizes frames; lookahead is in "frames at 60fps" units

rayOrigin = state.primaryPart.Position
rayCount = CombatConfig.VehicleCollisionRayCount  -- default 3

-- Cast rays in a horizontal fan: center, left offset, right offset
-- Offsets spread across vehicle width (collisionRadius)
for i = 1, rayCount:
    offset = spread based on i  -- center ray + side rays
    origin = rayOrigin + rightVector * offset
    result = workspace:Raycast(origin, forwardDir * lookaheadDist, rayParams)

    if result:
        -- Obstacle hit
        impactSpeed = forwardSpeed
        if impactSpeed > state.config.collisionDamageThreshold:
            damage = floor((impactSpeed - state.config.collisionDamageThreshold) * state.config.collisionDamageScale + 0.5)
            if damage > 0:
                HealthManager.applyDamage(state.entityId, damage, "impact", "", state.primaryPart.Position, true)
                print("[P5_COLLISION] vehicleId=%s impactSpeed=%.1f damage=%d", state.vehicleId, impactSpeed, damage)

        -- Bounce: reflect forward velocity, scale by bounce coefficient
        bounceVel = forwardDir * (-forwardSpeed * state.config.collisionBounce)
        state.velocity = Vector3.new(bounceVel.X, state.velocity.Y, bounceVel.Z)
        break  -- one collision per frame is enough
```

**rayParams note:** The caller (VehicleServer.stepVehicles) creates one `RaycastParams` per frame with `FilterDescendantsInstances` set to all active vehicle models (so vehicles don't collide with themselves or other vehicles via raycasts — vehicle-to-vehicle is handled separately). Pass this as a parameter to avoid recreating it per vehicle.

```luau
function CollisionHandler.checkVehicleCollisions(
    state: VehicleRuntimeState,
    allVehicles: { VehicleRuntimeState }
): ()
-- Distance-based vehicle-to-vehicle collision detection.
-- For each other vehicle, if distance < sum of both collisionRadii,
-- applies bounce to both vehicles and damage to both.
-- Mutates state.velocity and otherState.velocity directly.
```

**checkVehicleCollisions internal logic:**

```
myPos = state.primaryPart.Position
myRadius = state.config.collisionRadius

for _, other in allVehicles:
    if other.vehicleId == state.vehicleId then continue end
    if other == already checked this frame then continue end
    -- Note: caller should only call this once per unordered pair.
    -- Simple approach: only check if state.vehicleId < other.vehicleId (string compare)
    -- to avoid double-processing. Both vehicles get modified in one call.

    otherPos = other.primaryPart.Position
    combinedRadius = myRadius + other.config.collisionRadius
    delta = otherPos - myPos
    dist = delta.Magnitude

    if dist < combinedRadius and dist > 0:
        -- Collision detected
        normal = delta.Unit  -- direction from my vehicle toward other
        relativeVel = state.velocity - other.velocity
        relativeSpeed = relativeVel:Dot(normal)

        if relativeSpeed <= 0 then continue end  -- moving apart, skip

        -- Apply bounce: push vehicles apart along collision normal
        avgBounce = (state.config.collisionBounce + other.config.collisionBounce) / 2
        impulse = normal * relativeSpeed * avgBounce

        state.velocity = state.velocity - impulse * 0.5
        other.velocity = other.velocity + impulse * 0.5

        -- Damage both based on relative speed
        avgThreshold = (state.config.collisionDamageThreshold + other.config.collisionDamageThreshold) / 2
        if relativeSpeed > avgThreshold:
            avgScale = (state.config.collisionDamageScale + other.config.collisionDamageScale) / 2
            damage = floor((relativeSpeed - avgThreshold) * avgScale + 0.5)
            if damage > 0:
                HealthManager.applyDamage(state.entityId, damage, "impact", "", myPos, true)
                HealthManager.applyDamage(other.entityId, damage, "impact", "", otherPos, true)
                print("[P5_VEHICLE_COLLISION] vehicleA=%s vehicleB=%s relativeSpeed=%.1f",
                    state.vehicleId, other.vehicleId, relativeSpeed)
```

**Performance note:** Vehicle-to-vehicle checks are O(n^2) but n is small (max ~10-20 vehicles in a server). The string-compare guard ensures each pair is checked once. If vehicle count ever becomes a concern (unlikely for this game), spatial hashing can be added later.

---

## 6. Modified Files

### 6a. Shared/CombatTypes.luau

Add the new types from section 2 (VehicleConfig, VehicleInputPayload, VehicleRuntimeState) after existing types.

### 6b. Shared/CombatConfig.luau

Add:
- `impact` entry to `DamageTypeMultipliers`
- `light_speeder` entry to `Entities`
- `Vehicles` table (section 4)
- Global vehicle config values (section 4)

### 6c. Shared/CombatEnums.luau

Add:
- `VehicleClass` table
- `Impact = "impact"` to `DamageType`

### 6d. Server/CombatInit.server.luau

**Changes:**

1. Require VehicleServer:
   ```luau
   local VehicleServer = require(serverRoot:WaitForChild("Vehicles"):WaitForChild("VehicleServer"))
   ```

2. Add new RemoteEvents in `createRemotesFolder()`:
   ```luau
   createRemoteEvent(folder, "VehicleInput")
   createRemoteEvent(folder, "VehicleExitRequest")
   ```

3. Init VehicleServer after existing inits:
   ```luau
   VehicleServer.init(remotesFolder)
   ```

4. Add destroy callback to HealthManager:
   ```luau
   HealthManager.setDestroyCallback(function(entityId: string)
       VehicleServer.onEntityDestroyed(entityId)
   end)
   ```

5. In the entity registration loop, after registering with HealthManager and WeaponServer, check for VehicleEntity tag and register with VehicleServer:
   ```luau
   if CollectionService:HasTag(validatedEntity.instance, "VehicleEntity") then
       local vehicleConfigId = validatedEntity.instance:GetAttribute("VehicleConfigId")
       if type(vehicleConfigId) == "string" and CombatConfig.Vehicles[vehicleConfigId] then
           local driverSeat = findTaggedDescendant(validatedEntity.instance, "DriverSeat", "Seat")
           local hoverPoints = collectTaggedDescendants(validatedEntity.instance, "HoverPoint", "BasePart")
           if driverSeat and #hoverPoints >= 4 then
               VehicleServer.registerVehicle(
                   entityId,
                   validatedEntity.instance,
                   vehicleConfigId,
                   driverSeat :: Seat,
                   hoverPoints
               )
           end
       end
   end
   ```

   Note: `findTaggedDescendant` and `collectTaggedDescendants` are currently local to `StartupValidator.luau`. For CombatInit to use them, either:
   - Duplicate the helper (simple, 5 lines each), or
   - Call `CollectionService:GetTagged()` filtered to descendants

   Prefer inline search in CombatInit — keep it self-contained:
   ```luau
   local function findDriverSeat(model: Model): Seat?
       for _, d in model:GetDescendants() do
           if d:IsA("Seat") and CollectionService:HasTag(d, "DriverSeat") then
               return d
           end
       end
       return nil
   end

   local function collectHoverPoints(model: Model): { BasePart }
       local pts = {}
       for _, d in model:GetDescendants() do
           if d:IsA("BasePart") and CollectionService:HasTag(d, "HoverPoint") then
               table.insert(pts, d)
           end
       end
       return pts
   end
   ```

### 6e. Server/Health/HealthManager.luau

**Add destroy callback** (same pattern as `setRespawnCallback`):

Add at module scope:
```luau
local destroyCallback: ((string) -> ())? = nil
```

Add public function:
```luau
function HealthManager.setDestroyCallback(callback: (string) -> ())
    destroyCallback = callback
end
```

In `destroyEntity()`, call the callback after the entity is marked Destroyed (after `state.state = CombatEnums.EntityState.Destroyed` and before hiding parts):

```luau
if destroyCallback ~= nil then
    local ok, err = pcall(destroyCallback, state.entityId)
    if not ok then
        warn(string.format("[P5_DESTROY_CALLBACK] entity=%s error=%s", state.entityId, tostring(err)))
    end
end
```

### 6f. Server/Authoring/StartupValidator.luau

**Add vehicle validation** in `StartupValidator.validate()`:

After existing CombatEntity validation, add a second pass for VehicleEntity-tagged models:

```luau
local vehicleEntities = CollectionService:GetTagged("VehicleEntity")
for _, instance in ipairs(vehicleEntities) do
    if not instance:IsA("Model") then
        fail(instance:GetFullName(), "VehicleEntity tag must be on a Model")
        continue
    end

    local model = instance
    local modelName = model.Name

    -- Must also be a CombatEntity
    if not CollectionService:HasTag(model, "CombatEntity") then
        fail(modelName, "VehicleEntity must also have CombatEntity tag")
        continue
    end

    -- Must have VehicleConfigId
    local vehicleConfigId = model:GetAttribute("VehicleConfigId")
    if type(vehicleConfigId) ~= "string" then
        fail(modelName, "VehicleEntity missing VehicleConfigId attribute")
        continue
    end

    local vehicleConfig = CombatConfig.Vehicles[vehicleConfigId]
    if vehicleConfig == nil then
        fail(modelName, string.format("unknown VehicleConfigId '%s'", vehicleConfigId))
        continue
    end

    -- Must have DriverSeat
    local driverSeat = findTaggedDescendant(model, "DriverSeat", "Seat")
    if driverSeat == nil then
        fail(modelName, "VehicleEntity missing DriverSeat tagged Seat")
        continue
    end

    -- Must have 4 HoverPoints (for speeders)
    local hoverPoints = collectTaggedDescendants(model, "HoverPoint", "BasePart")
    if vehicleConfig.vehicleClass == "light_speeder" or vehicleConfig.vehicleClass == "heavy_speeder" then
        if #hoverPoints < 4 then
            fail(modelName, string.format("Speeder needs 4 HoverPoint tagged parts, found %d", #hoverPoints))
            continue
        end
    end

    -- Must have PrimaryPart set
    if model.PrimaryPart == nil then
        fail(modelName, "VehicleEntity must have PrimaryPart set")
        continue
    end

    -- PrimaryPart must be Anchored
    if not model.PrimaryPart.Anchored then
        fail(modelName, "VehicleEntity PrimaryPart must be Anchored")
        continue
    end
end
```

Also add vehicle config validation in `validateConfigContracts()`:

```luau
if type(CombatConfig.Vehicles) == "table" then
    for vehicleId, vc in pairs(CombatConfig.Vehicles) do
        if type(vc.entityConfigId) ~= "string" then
            warn(string.format("[VALIDATE] Vehicle '%s' missing entityConfigId", vehicleId))
            hasFailure = true
        elseif CombatConfig.Entities[vc.entityConfigId] == nil then
            warn(string.format("[VALIDATE] Vehicle '%s' entityConfigId '%s' not found", vehicleId, vc.entityConfigId))
            hasFailure = true
        end
        if type(vc.maxSpeed) ~= "number" or vc.maxSpeed <= 0 then
            warn(string.format("[VALIDATE] Vehicle '%s' maxSpeed must be > 0", vehicleId))
            hasFailure = true
        end
        if type(vc.hoverHeight) ~= "number" or vc.hoverHeight <= 0 then
            warn(string.format("[VALIDATE] Vehicle '%s' hoverHeight must be > 0", vehicleId))
            hasFailure = true
        end
    end
end
```

### 6g. Client/CombatClient.client.luau

**Add VehicleClient initialization:**

1. Require:
   ```luau
   local VehicleClient = require(clientRoot:WaitForChild("Vehicles"):WaitForChild("VehicleClient"))
   ```

2. Init after existing inits:
   ```luau
   VehicleClient.init(remotesFolder)
   ```

### 6h. Client/HUD/CombatHUD.luau

**Add speed display:**

Add module-scope variables:
```luau
local speedFrame: Frame? = nil
local speedLabel: TextLabel? = nil
```

In `CombatHUD.init()`, create speed UI (below hull frame):
```luau
local vehicleSpeedFrame = Instance.new("Frame")
vehicleSpeedFrame.Name = "SpeedFrame"
vehicleSpeedFrame.AnchorPoint = Vector2.new(0.5, 1)
vehicleSpeedFrame.Position = UDim2.new(0.5, 0, 1, -46)
vehicleSpeedFrame.Size = UDim2.fromOffset(160, 28)
vehicleSpeedFrame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
vehicleSpeedFrame.BackgroundTransparency = 0.35
vehicleSpeedFrame.Visible = false
vehicleSpeedFrame.Parent = gui

local vehicleSpeedLabel = Instance.new("TextLabel")
vehicleSpeedLabel.Name = "SpeedLabel"
vehicleSpeedLabel.Size = UDim2.fromScale(1, 1)
vehicleSpeedLabel.BackgroundTransparency = 1
vehicleSpeedLabel.TextColor3 = Color3.fromRGB(220, 220, 220)
vehicleSpeedLabel.TextScaled = false
vehicleSpeedLabel.TextSize = 16
vehicleSpeedLabel.Font = Enum.Font.Code
vehicleSpeedLabel.TextXAlignment = Enum.TextXAlignment.Center
vehicleSpeedLabel.Text = "Speed: 0"
vehicleSpeedLabel.Parent = vehicleSpeedFrame

speedFrame = vehicleSpeedFrame
speedLabel = vehicleSpeedLabel
```

Add public functions:
```luau
function CombatHUD.showSpeed(visible: boolean)
    if speedFrame then
        speedFrame.Visible = visible
    end
end

function CombatHUD.setSpeed(speed: number)
    if speedLabel then
        speedLabel.Text = string.format("Speed: %d", math.floor(speed + 0.5))
    end
end
```

VehicleClient calls `CombatHUD.setSpeed()` every frame using the vehicle model's velocity attribute (replicated via model attribute from server).

**For speed replication:** VehicleServer sets `instance:SetAttribute("VehicleSpeed", horizontalSpeed)` throttled to 10Hz (every 6th Heartbeat, or only when speed changes by > 1 stud/sec). Attribute replication to all clients is expensive at 60Hz — throttling avoids unnecessary network load. VehicleClient reads this attribute on the client to update the HUD. This avoids a dedicated remote for speed.

---

## 7. New RemoteEvents

| Name | Direction | Payload | Rate |
|------|-----------|---------|------|
| `VehicleInput` | client → server | `{ throttle: number, steerX: number }` | Up to 30/sec while driving |
| `VehicleExitRequest` | client → server | (none) | On F key press |

Total RemoteEvent count after this pass: 13 (was 11).

---

## 8. Integration Pass

### 8a. VehicleServer ↔ HealthManager

**Call:** `HealthManager.applyDamage(entityId, damage, "impact", "", hitPosition, true)`
- `entityId`: string — from VehicleRuntimeState.entityId
- `damage`: number — calculated from fall/collision speed
- `"impact"`: string — new DamageType, must exist in DamageTypeMultipliers
- `""`: string — empty faction (environmental damage, no attacker)
- `hitPosition`: Vector3 — vehicle's current position
- `true`: boolean — ignoreFactionCheck (environmental damage always applies)
- **Returns:** `(boolean, string?, boolean)` — success, impactType, didBreakShield. VehicleServer only checks the first return (did damage apply).
- **Side effect:** If HP reaches 0, HealthManager calls `destroyEntity()` which calls `destroyCallback` → `VehicleServer.onEntityDestroyed(entityId)`.

**Check:** HealthManager.applyDamage signature matches: `(entityId: string, damage: number, damageType: string, attackerFaction: string, hitPosition: Vector3, ignoreFactionCheck: boolean?)`. **Confirmed match.**

**Check:** HealthManager.isAlive(entityId) returns boolean. VehicleServer checks this before processing movement. **Confirmed match.**

### 8b. CombatInit ↔ VehicleServer

**Call:** `VehicleServer.registerVehicle(entityId, model, vehicleConfigId, driverSeat, hoverPoints)`
- All params sourced from validated entity + attribute reads in CombatInit.
- `entityId` is generated by CombatInit's existing numbering (`"entity_" .. index`).
- Must be called AFTER `HealthManager.registerEntity()` so the entity exists in health tracking.

**Call:** `VehicleServer.onEntityDestroyed(entityId)` via HealthManager destroy callback.
- Must handle case where entityId is not a vehicle (return silently).

### 8c. VehicleClient ↔ CombatHUD

**Calls:**
- `CombatHUD.showHP(entityId)` — existing function, takes string. Works for any entity. **Confirmed.**
- `CombatHUD.hideHP()` — existing, no params. **Confirmed.**
- `CombatHUD.showCrosshair(false)` — existing, takes boolean. **Confirmed.**
- `CombatHUD.showHeat(false)` — existing, takes boolean. **Confirmed.**
- `CombatHUD.showAmmo(false)` — existing, takes boolean. **Confirmed.**
- `CombatHUD.showSpeed(true/false)` — **NEW**, defined in section 6h.
- `CombatHUD.setSpeed(number)` — **NEW**, defined in section 6h.

### 8d. VehicleClient seat detection ↔ existing turret system

**Potential conflict:** WeaponClient also watches seat state for turret activation. When a player sits in a `DriverSeat`, WeaponClient must NOT activate turret mode. When a player sits in a `TurretSeat`, VehicleClient must NOT activate vehicle mode.

**Resolution:** Each client module checks for its own tag:
- WeaponClient activates when `SeatPart` has `TurretSeat` tag
- VehicleClient activates when `SeatPart` has `DriverSeat` tag

Verify WeaponClient uses TurretSeat tag detection (based on CombatInit code which tags seats with `TurretSeat` — confirmed line 165 of CombatInit). VehicleClient uses `DriverSeat` tag. **No conflict.**

### 8e. Speed replication

VehicleServer calls `instance:SetAttribute("VehicleSpeed", speed)` each Heartbeat. VehicleClient reads `vehicleModel:GetAttribute("VehicleSpeed")` in its render loop. Roblox attribute replication is automatic for models in Workspace. **No extra remotes needed.**

---

## 9. Placeholder Speeder Model

Generated by test harness setup. Structure:

```
Model "TestSpeeder"
  PrimaryPart → Body
  Attributes:
    Faction = "empire"
    ConfigId = "light_speeder"
    VehicleConfigId = "light_speeder"
  Tags: CombatEntity, VehicleEntity

  BasePart "Body" (anchored, size 6x2x10, position at test origin)
    Material = SmoothPlastic, Color = gray

  Seat "DriverSeat" (size 2x1x2, welded on top of Body toward front)
    Tags: DriverSeat

  BasePart "HoverFL" (size 0.5x0.5x0.5, welded at front-left bottom of Body)
    Tags: HoverPoint
    Transparency = 1

  BasePart "HoverFR" (size 0.5x0.5x0.5, welded at front-right bottom of Body)
    Tags: HoverPoint
    Transparency = 1

  BasePart "HoverBL" (size 0.5x0.5x0.5, welded at back-left bottom of Body)
    Tags: HoverPoint
    Transparency = 1

  BasePart "HoverBR" (size 0.5x0.5x0.5, welded at back-right bottom of Body)
    Tags: HoverPoint
    Transparency = 1
```

Hover point positions relative to Body center: FL = (-2.5, -1, -4), FR = (2.5, -1, -4), BL = (-2.5, -1, 4), BR = (2.5, -1, 4).

All parts welded to PrimaryPart (Body). Body is anchored. Entire assembly moves as one unit via `PivotTo()`.

---

## 10. Golden Tests

### Test 14: Speeder Drives and Hovers

- **Setup:** Placeholder speeder on flat Baseplate terrain at (0, 10, 0). TestHarnessEnabled = true.
- **Action:** Harness simulates: seat a test character in DriverSeat, inject throttle=1 and steerX=0 input for 3 seconds via VehicleServer directly (bypass remote for harness).
- **Expected:** Speeder accelerates from 0 toward maxSpeed (120). Hover height stabilizes at ~4 studs above terrain. Heading stays constant (steer=0).
- **Pass condition:**
  - `[P5_SPEED]` log at 0.5s intervals showing increasing speed: 0 → ~40 → ~80 → ~110+
  - `[P5_HOVER]` log showing hover height within ±1 stud of target (4)
  - `[P5_SUMMARY]` confirms: final speed > 100, hover height error < 1 stud, grounded count = 4

### Test 15: Wall Collision + Impact Damage

- **Setup:** Speeder at (0, 10, 0). Anchored wall part (size 20x20x2) at (0, 10, -80). Speeder facing wall (heading toward -Z). TestHarnessEnabled = true.
- **Action:** Harness injects throttle=1, steerX=0. Wait until collision.
- **Expected:** Speeder accelerates toward wall. On collision: velocity drops to ~0 (slight bounce), HP decreases from impact damage.
- **Pass condition:**
  - `[P5_COLLISION]` log with impactSpeed > collisionDamageThreshold (30) and damage > 0
  - `[P1_DAMAGE]` log showing hull HP decrease (impact damage type)
  - `[P5_SPEED]` log after collision showing speed < 5
  - `[P5_SUMMARY]` confirms: collision detected, damage applied, vehicle stopped

### Test 16: Airborne + Fall Damage

- **Setup:** Speeder on an elevated platform (anchored part at Y=50, size 40x2x40). Edge of platform at Z=-20. Open air beyond. TestHarnessEnabled = true.
- **Action:** Harness injects throttle=1, steerX=0. Speeder drives off edge.
- **Expected:** Speeder goes airborne when hover raycasts find no ground. Gravity pulls it down. On landing (baseplate at Y=0), fall damage applies based on vertical impact speed.
- **Pass condition:**
  - `[P5_AIRBORNE]` log when grounded count drops to 0
  - `[P5_FALL_DAMAGE]` log with vertical impact speed and damage amount
  - `[P1_DAMAGE]` log showing hull HP decrease (impact damage type)
  - `[P5_SUMMARY]` confirms: went airborne, fell ~50 studs, fall damage applied

### Regression Tests

Re-run Pass 1 Tests 1-4, Pass 2 Tests 5-6, Pass 3 Tests 7-9, Pass 4 Tests 10-13. Vehicle changes must NOT affect turret combat behavior. Key regression risks: HealthManager destroy callback addition, new DamageType "impact", new RemoteEvents in folder.

---

## 11. AI Build Prints

### Tags for this pass

| Tag | When | Data |
|-----|------|------|
| `[P5_SPEED]` | Every 0.5s while vehicle has driver | `vehicleId=%s speed=%.1f` |
| `[P5_HOVER]` | Every 0.5s while vehicle has driver | `vehicleId=%s height=%.2f target=%.2f grounded=%d` |
| `[P5_DRIVER_ENTER]` | Player sits in DriverSeat | `vehicleId=%s player=%s` |
| `[P5_DRIVER_EXIT]` | Player leaves DriverSeat | `vehicleId=%s player=%s` |
| `[P5_AIRBORNE]` | Vehicle transitions to airborne | `vehicleId=%s verticalSpeed=%.1f` |
| `[P5_GROUNDED]` | Vehicle transitions to grounded | `vehicleId=%s verticalSpeed=%.1f` |
| `[P5_COLLISION]` | Forward obstacle collision | `vehicleId=%s impactSpeed=%.1f damage=%d` |
| `[P5_FALL_DAMAGE]` | Fall damage on landing | `vehicleId=%s verticalSpeed=%.1f damage=%d` |
| `[P5_VEHICLE_COLLISION]` | Vehicle-to-vehicle collision | `vehicleA=%s vehicleB=%s relativeSpeed=%.1f` |
| `[P5_STOPPED]` | Driverless vehicle fully stops | `vehicleId=%s` |
| `[P5_REGISTERED]` | Vehicle registered at startup | `vehicleId=%s configId=%s` |
| `[P5_DESTROYED]` | Vehicle destroyed (HP=0) | `vehicleId=%s` |

### Markers

Place in VehicleServer.stepVehicles:
```
-- START READ HERE (P5 VEHICLE STEP)
... heartbeat loop ...
-- END READ HERE (P5 VEHICLE STEP)
```

### Summary line

At end of each test harness run:
```
[P5_SUMMARY] test=<name> finalSpeed=<n> hoverError=<n> collisions=<n> fallDamage=<n> result=<PASS|FAIL>
```

---

## 12. Cleanup Paths

### VehicleServer per-vehicle cleanup (on entity destroy or server shutdown)

1. Disconnect all entries in `state.connections` (seat occupant watcher)
2. If driver exists, `driver.Character.Humanoid.Sit = false`
3. Remove from active vehicles table
4. Remove model attributes (`VehicleSpeed`)

### VehicleClient cleanup (on exit vehicle mode)

1. Disconnect input RenderStepped connection
2. Unbind F key handler
3. Deactivate VehicleCamera (restores camera type)
4. Hide vehicle HUD elements

### PlayerRemoving

VehicleServer: clear driver from any vehicle the player was driving. VehicleClient: handled by humanoid SeatPart becoming nil on character removal.

### Leak check (test harness)

After each test: log count of active vehicle entries, active connections. Must be 0 after all vehicles are destroyed/cleaned up.

---

## 13. Exit Checklist

- [x] All new/modified modules specified with exact APIs
- [x] Integration pass complete — every cross-boundary data flow traced against real code
- [x] Golden tests defined (3 tests: drive+hover, collision, airborne+fall)
- [x] AI build prints specified (12 tags + markers + summary)
- [x] Regression tests identified (passes 1-4)
- [x] Diagnostics/validators updated (vehicle validation added)
- [x] Config values extracted (VehicleConfig, global vehicle tunables)
- [x] Cleanup paths defined
- [x] Critic signed off (self-critique + haiku agent — zero blocking issues remaining)
- [x] Codex handoff prompt produced (below)

---

## Codex Handoff

```
Read: codex-instructions.md, projects/combat-framework/project-protocol.md, projects/combat-framework/state.md, projects/combat-framework/pass-5-design.md. Then read code in projects/combat-framework/src/. Build pass 5.
```
