# Pass 5 Fix Plan: Speeder Movement Reset

**Context:** Pass 5 build has 6 coupled failures. Root causes are inverted steering, camera tracking tilted model frame, and unstable hover physics averaging. This is a reset-level fix — replace the broken core, keep the working shell.

---

## Root Causes

**Root A — Heading convention is inverted.** `heading += steerX * turnSpeed * dt`. Positive steerX increases heading, which rotates forward LEFT. Mouse right = turn left.

**Root B — Camera tracks tilted model frame.** `VehicleCamera` reads `vehicleModel:GetPivot().LookVector` — the terrain-tilt-aligned forward. On slopes, camera offset shifts laterally. Lerp ignores `dt` — frame-rate dependent. Noisy tilt target = jitter.

**Root C — Hover physics averages only over grounded rays.** `groundDistanceSum / groundedCount` means when 2 of 4 rays miss, force is concentrated (divided by 2 not 4) → launch spikes. Force clamp at `gravity * 1.25` still allows ~50 studs/sec² net upward. `probeOffset` trick adds measurement complexity.

---

## Fix 1: Forward Axis Attachment (Authoring Contract)

Every VehicleEntity must have an `Attachment` named **`ForwardRef`** on its `PrimaryPart`. Its `WorldCFrame.LookVector` defines forward at registration. Fallback: `PrimaryPart.CFrame.LookVector` + warn.

### StartupValidator.luau

Add a warning check in the VehicleEntity validation section (after existing checks, not a failure):

```
local forwardRef = model.PrimaryPart:FindFirstChild("ForwardRef")
if forwardRef == nil or not forwardRef:IsA("Attachment") then
    warn(string.format("[VALIDATE] VehicleEntity '%s' missing ForwardRef attachment on PrimaryPart", modelName))
end
```

### VehicleServer.registerVehicle

Replace heading initialization:

```lua
-- OLD:
local heading = computeHeadingFromLook(instance:GetPivot().LookVector)

-- NEW:
local forwardRef = primaryPart:FindFirstChild("ForwardRef")
local worldForward: Vector3
if forwardRef and forwardRef:IsA("Attachment") then
    worldForward = forwardRef.WorldCFrame.LookVector
else
    worldForward = instance:GetPivot().LookVector
    warn("[P5_WARN] No ForwardRef on " .. instance.Name .. ", using LookVector")
end
local heading = computeHeadingFromLook(worldForward)
```

### Pass5_Test.createSpeeder

Add ForwardRef attachment to Body after creating it:

```lua
local fwdRef = Instance.new("Attachment")
fwdRef.Name = "ForwardRef"
fwdRef.CFrame = CFrame.new() -- identity = LookVector is -Z in part local space
fwdRef.Parent = body
```

---

## Fix 2: Three Distinct Frames

### 2a. Heading Frame — Fix Steering Sign

In `VehicleServer.stepSingleVehicle`, the steering line:

```lua
-- OLD:
local headingDelta = math.rad(state.inputSteerX * state.config.turnSpeed) * dt
state.heading += headingDelta

-- NEW:
local headingDelta = math.rad(state.inputSteerX * state.config.turnSpeed) * dt
state.heading -= headingDelta  -- subtract: positive steerX = turn right
```

### 2b. Model Frame — No Changes

The CFrame built from heading + terrain tilt via `CFrame.lookAt(pos, pos + alignedForward, smoothedUp)` is correct. Keep as-is. This frame is write-only — nothing reads back from it.

### 2c. Camera Frame — Use Horizontal Heading, Not Tilted LookVector

**Heading replication:** In `VehicleServer`, add `VehicleHeading` attribute alongside `VehicleSpeed`. In the `applySpeedAttributeReplication` function (or alongside its call), add:

```lua
state.instance:SetAttribute("VehicleHeading", state.heading)
```

Same throttle condition — only update when the speed/heading update condition fires.

**Replace VehicleCamera.stepCamera entirely:**

```lua
local function stepCamera(dt: number)
    local vehicleModel = activeVehicleModel
    local config = activeConfig
    local camera = Workspace.CurrentCamera
    if vehicleModel == nil or config == nil or camera == nil then
        return
    end
    if vehicleModel.Parent == nil then
        VehicleCamera.deactivate()
        return
    end

    local vehiclePos = vehicleModel:GetPivot().Position
    local heading = vehicleModel:GetAttribute("VehicleHeading")
    if type(heading) ~= "number" then
        heading = 0
    end

    -- Horizontal forward from heading — NO terrain tilt
    local hFwd = Vector3.new(-math.sin(heading), 0, -math.cos(heading))

    -- Target: fixed height + distance behind along horizontal heading
    local targetPos = vehiclePos
        - hFwd * config.cameraDistance
        + Vector3.new(0, config.cameraHeight, 0)

    local lookAt = vehiclePos + Vector3.new(0, config.cameraHeight * 0.3, 0)

    -- Frame-rate-independent exponential smoothing
    local alpha = 1 - math.exp(-config.cameraLerpSpeed * 60 * dt)

    local cur = currentCameraPosition
    if cur == nil then
        cur = targetPos
    end

    currentCameraPosition = cur:Lerp(targetPos, alpha)
    camera.CFrame = CFrame.lookAt(currentCameraPosition, lookAt)
end
```

Also update `VehicleCamera.activate` to use the same heading-based initial position:

```lua
local heading = vehicleModel:GetAttribute("VehicleHeading")
if type(heading) ~= "number" then heading = 0 end
local hFwd = Vector3.new(-math.sin(heading), 0, -math.cos(heading))
currentCameraPosition = vehicleCF.Position - hFwd * config.cameraDistance + Vector3.new(0, config.cameraHeight, 0)
```

---

## Fix 3: Stable Hover Math

**Replace HoverPhysics.step entirely:**

```lua
function HoverPhysics.step(
    hoverPoints: { BasePart },
    vehicleModel: Model,
    currentVelocityY: number,
    hoverHeight: number,
    springStiffness: number,
    springDamping: number,
    gravity: number,
    _dt: number
): (number, Vector3, number)
    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Exclude
    rayParams.FilterDescendantsInstances = { vehicleModel }
    rayParams.IgnoreWater = true

    local rayMaxDistance = hoverHeight * 3
    local pointCount = math.max(#hoverPoints, 1)
    local totalForce = 0
    local normalSum = Vector3.zero
    local groundedCount = 0

    for _, hp in ipairs(hoverPoints) do
        local origin = hp.WorldPosition  -- WorldPosition, not Position
        local result = Workspace:Raycast(
            origin,
            Vector3.new(0, -rayMaxDistance, 0),
            rayParams
        )
        if result ~= nil then
            groundedCount += 1
            local compression = hoverHeight - result.Distance
            local force = springStiffness * compression
                        - springDamping * currentVelocityY
            totalForce += force
            normalSum += result.Normal
        end
        -- miss = 0 force contribution (NOT excluded from denominator)
    end

    -- ALWAYS divide by total point count (4), not grounded count
    -- Prevents force spikes when some rays miss
    local avgForce = totalForce / pointCount

    local verticalAccel = avgForce - gravity
    -- Bound: max 0.8g upward (recover from drops, never launch)
    -- max 1.5g downward (slightly faster than freefall for responsiveness)
    verticalAccel = math.clamp(verticalAccel, -gravity * 1.5, gravity * 0.8)

    local avgNormal = Vector3.yAxis
    if groundedCount > 0 and normalSum.Magnitude > 0.01 then
        avgNormal = normalSum.Unit
    end

    return verticalAccel, avgNormal, groundedCount
end
```

**What changed vs old code:**
1. No `probeOffset` trick — ray starts from hover point WorldPosition, straight down
2. Divide by `pointCount` (always 4), not `groundedCount` — no force spikes on partial grounding
3. Tighter upward clamp: `gravity * 0.8` prevents launches
4. `WorldPosition` instead of `Position`

---

## Fix 4: Harness Determinism

### 4a. VehicleServer stop check — respect injected input

```lua
-- OLD:
if state.driver == nil and state.velocity.Magnitude < speedThreshold then

-- NEW:
local hasInput = math.abs(state.inputThrottle) > 0 or math.abs(state.inputSteerX) > 0
if state.driver == nil and not hasInput and state.velocity.Magnitude < speedThreshold then
```

This lets the harness inject throttle without a driver. Also correct for gameplay (driverless vehicle with collision-imparted velocity coasts to stop, but injected input is respected).

### 4b. Pass5_Test.measureHover — use WorldPosition

```lua
-- OLD:
local distance = raycastGroundDistance(descendant.Position, model)

-- NEW:
local distance = raycastGroundDistance(descendant.WorldPosition, model)
```

### 4c. Pass5_Test.resetVehicleState — longer settle time

Change `task.wait(0.2)` to `task.wait(0.5)` to give hover physics time to settle the vehicle at hover height before the test timer starts.

---

## File Change Summary

| File | Changes |
|------|---------|
| `Server/Vehicles/VehicleServer.luau` | Fix steering sign (2a), replicate VehicleHeading attribute (2c), fix stop check (4a) |
| `Server/Vehicles/HoverPhysics.luau` | Full rewrite (3) |
| `Client/Vehicles/VehicleCamera.luau` | Full rewrite of stepCamera + activate init (2c) |
| `Server/Authoring/StartupValidator.luau` | Add ForwardRef warning (1) |
| `Server/TestHarness/Pass5_Test.luau` | Add ForwardRef attachment (1), WorldPosition fix (4b), settle time (4c) |

**No changes needed:** `CollisionHandler.luau`, `VehicleClient.luau`, `CombatInit.server.luau`, `CombatHUD.luau`, `CombatConfig.luau`.

---

## Validation

After implementing, run the harness first:

1. `[P5_SUMMARY] test=drive_hover` — `finalSpeed > 100`, `hoverError < 1`, `grounded >= 3`, `result=PASS`
2. `[P5_SUMMARY] test=collision` — `result=PASS`
3. `[P5_SUMMARY] test=fall_damage` — `result=PASS`

Then manual check: W goes forward, mouse right turns right, camera stays behind, no jitter on flat or sloped terrain.
