# Pass 6 Design: Speeder Combat

## Overview

Armed speeders become fully combat-capable. Drivers fire weapons while driving, take damage as combat entities, get destroyed with explosion VFX, and the full combat framework (projectiles, damage types, shields, targeting, lock-on) works on a moving vehicle. This proves the same integration pattern that ships will use.

---

## Step 1: Driver-to-Weapon Binding (Server)

**Goal:** Let the driver of a vehicle fire the vehicle's weapon through the existing WeaponServer fire flow.

### Problem

`WeaponServer.onFireWeapon` calls `resolvePlayerTurretContext`, which requires `humanoid.SeatPart` to have the `TurretSeat` or `ArtillerySeat` tag. Vehicle drivers sit in a `DriverSeat`-tagged seat, so fire requests from drivers are silently discarded.

### Solution

Add a parallel resolution path: `resolvePlayerVehicleWeaponContext`. If turret context fails, try vehicle context.

**File: `src/Server/Weapons/WeaponServer.luau`**

Add new function after `resolvePlayerTurretContext` (~line 1250):

```
local function resolvePlayerVehicleWeaponContext(player: Player): (Model?, Model?, string?, HealthState?)
    local character = player.Character
    if character == nil then return nil, nil, nil, nil end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if humanoid == nil then return nil, nil, nil, nil end
    local seatPart = humanoid.SeatPart
    if seatPart == nil or not CollectionService:HasTag(seatPart, "DriverSeat") then
        return nil, nil, nil, nil
    end
    -- Walk up to find VehicleEntity model
    local entityModel: Model? = nil
    local current: Instance? = seatPart
    while current ~= nil do
        if current:IsA("Model") and CollectionService:HasTag(current, "VehicleEntity") then
            entityModel = current
            break
        end
        current = current.Parent
    end
    if entityModel == nil then return nil, nil, nil, nil end
    local entityIdAttr = entityModel:GetAttribute("EntityId")
    if type(entityIdAttr) ~= "string" then return nil, nil, nil, nil end
    local entityId = entityIdAttr
    if not HealthManager.isAlive(entityId) then return nil, nil, nil, nil end
    local healthState: HealthState? = HealthManager.getHealth(entityId)
    if healthState == nil or healthState.config.weaponId == nil then
        return nil, nil, nil, nil
    end
    return character, entityModel, entityId, healthState
end
```

Modify `onFireWeapon` (~line 1274):

Change the resolution to try turret first, then vehicle:
```lua
local character, entityModel, entityId, healthState = resolvePlayerTurretContext(player)
if character == nil then
    character, entityModel, entityId, healthState = resolvePlayerVehicleWeaponContext(player)
end
if character == nil or entityModel == nil or entityId == nil or healthState == nil then
    return
end
```

Modify `onUpdateTurretAim` (~line 1252):

Same fallback:
```lua
local _character, entityModel, entityId, _healthState = resolvePlayerTurretContext(player)
if entityModel == nil then
    _character, entityModel, entityId, _healthState = resolvePlayerVehicleWeaponContext(player)
end
if entityModel == nil or entityId == nil then
    return
end
```

### Weapon Mount on Vehicles

Vehicles that have weapons need a `WeaponMount`-tagged BasePart with optional `MuzzlePoint` attachment(s), identical to turrets. The mount can be a child of the vehicle model. For fixed-forward weapons, the mount faces the vehicle's forward direction. WeaponServer's existing `collectFireNodes`, `applyAimToRig`, etc. all work as-is because they operate on the entity model regardless of platform.

### Config

Vehicles that carry weapons must have `weaponId` set in their entity config. Currently `light_vehicle` and `heavy_vehicle` have `weaponId = nil`.

**File: `src/Shared/CombatConfig.luau`**

Add two new armed vehicle entity configs (leave existing unarmed ones):

```lua
light_speeder_armed = {
    hullHP = 100,
    weaponId = "blaster_turret",
    turretExposed = true,
    respawnTime = 20,
},
heavy_speeder_armed = {
    hullHP = 500,
    shieldHP = 200,
    shieldRegenRate = 15,
    shieldRegenDelay = 5,
    weaponId = "turbolaser_turret",
    turretExposed = false,
    respawnTime = 30,
},
```

Add vehicle config entries that reference these:

```lua
light_armed = CombatConfig.Vehicles.light, -- same movement, different entityConfigId
```

Wait — simpler approach. Don't create new vehicle movement configs. Instead, let the vehicle model's `ConfigId` attribute (CombatEntity config) determine the weapon independently. The vehicle already has dual registration:
- `ConfigId` attribute → selects EntityConfig (health, weapon, etc.)
- `VehicleCategory` attribute → selects VehicleConfig (movement)

These are already independent. A vehicle model with `ConfigId = "light_speeder_armed"` and `VehicleCategory = "light"` gets armed light speeder health/weapon + light speeder movement. No new vehicle movement configs needed.

**New entity configs in CombatConfig.Entities:**

```lua
light_speeder_armed = {
    hullHP = 100,
    weaponId = "blaster_turret",
    turretExposed = true,
    respawnTime = 20,
},
heavy_speeder_armed = {
    hullHP = 500,
    shieldHP = 200,
    shieldRegenRate = 15,
    shieldRegenDelay = 5,
    weaponId = "turbolaser_turret",
    turretExposed = false,
    respawnTime = 30,
},
```

No changes to `CombatConfig.Vehicles` needed.

### Validator Update

**File: `src/Server/Authoring/StartupValidator.luau`**

The existing validator already checks for `WeaponMount` + `TurretSeat` when `weaponId ~= nil`. For vehicle-mounted weapons, the seat is a `DriverSeat`, not a `TurretSeat`. The validator needs to accept `DriverSeat` as a valid weapon seat for vehicle entities.

In the weapon validation block (~line 229-243), after checking for TurretSeat/ArtillerySeat, add:

```lua
if seatCandidate == nil and CollectionService:HasTag(model, "VehicleEntity") then
    seatCandidate = findTaggedDescendant(model, "DriverSeat", "Seat")
end
```

This allows armed vehicles to pass validation using their DriverSeat instead of requiring a separate TurretSeat.

### CombatInit Registration

**File: `src/Server/CombatInit.server.luau`**

Currently, `WeaponServer.registerEntity(entityId)` is called for all validated entities. Since armed vehicles have `weaponId` in their entity config, WeaponServer will automatically discover the `WeaponMount` and register fire nodes. No changes needed to CombatInit — the dual registration already works.

However, the existing code at line 215-240 adds a `TurretSeat` prompt and tags. For armed vehicles, we do NOT want a ProximityPrompt on the weapon (the driver enters via the DriverSeat, which has no prompt — the player walks up and presses E on the seat directly).

Add a guard before the turret seat/prompt block:

```lua
-- Only add turret prompts for non-vehicle weapon entities
if validatedEntity.turretSeat ~= nil and not CollectionService:HasTag(validatedEntity.instance, "VehicleEntity") then
    -- existing turret prompt code...
end
```

Wait — actually, the validator already skips setting `turretSeat` if it can't find a `TurretSeat` tag. If the vehicle only has a `DriverSeat` (no `TurretSeat`), `validatedEntity.turretSeat` will be nil unless we patched the validator above. Actually let me reconsider the validator patch. We need the validator to NOT reject armed vehicles for lacking a TurretSeat. But we also don't want to set `turretSeat` to the DriverSeat, because CombatInit would add a ProximityPrompt to it.

Better approach: In the validator, when `weaponId ~= nil` and the model is a VehicleEntity, don't require a TurretSeat or ArtillerySeat. Just skip that check. The weapon mount + muzzle checks still apply.

**Revised validator change** (~line 229-243):

```lua
if seatCandidate == nil then
    -- Armed vehicles use DriverSeat, not TurretSeat — skip seat requirement
    if not CollectionService:HasTag(model, "VehicleEntity") then
        fail(modelName, "has weaponId but no TurretSeat or ArtillerySeat tagged child")
        continue
    end
end
```

And skip the camera point check for vehicles too (~line 240-243):

```lua
if not hasCameraPoint(model) and not CollectionService:HasTag(model, "VehicleEntity") then
    fail(modelName, "has weaponId but no CameraPoint part/attachment")
    continue
end
```

With this, `validatedEntity.turretSeat` stays nil for armed vehicles, so CombatInit won't add a prompt.

---

## Step 2: Client Vehicle Weapon HUD + Fire Input

**Goal:** When the driver is in an armed vehicle, show weapon HUD (crosshair, heat/ammo, shield) and send fire requests on left click.

### File: `src/Client/Vehicles/VehicleClient.luau`

**Changes to `enterVehicleMode` (~line 648):**

After the existing HUD setup (lines 801-808), check if the vehicle has a weapon:

```lua
-- Check if this vehicle has a weapon
local vehicleWeaponId = vehicleModel:GetAttribute("EffectiveWeaponClass")
local hasWeapon = type(vehicleWeaponId) == "string" and vehicleWeaponId ~= ""
if hasWeapon then
    CombatHUD.showCrosshair(true)
    -- Show heat or ammo depending on weapon type
    local ammoMax = vehicleModel:GetAttribute("WeaponAmmoMax")
    if type(ammoMax) == "number" and ammoMax > 0 then
        CombatHUD.showAmmo(true)
    else
        CombatHUD.showHeat(true)
    end
    -- Show shield if vehicle has shields
    local maxShield = vehicleModel:GetAttribute("MaxShieldHP")
    if type(maxShield) == "number" and maxShield > 0 then
        CombatHUD.showShield(true)
    end
end
```

**Add weapon state module variables near the top:**

```lua
local activeVehicleHasWeapon: boolean = false
local weaponHeatConnection: RBXScriptConnection? = nil
local weaponAmmoConnection: RBXScriptConnection? = nil
local fireWeaponRemote: RemoteEvent? = nil
local updateTurretAimRemote: RemoteEvent? = nil
```

**In `VehicleClient.init`:**

```lua
fireWeaponRemote = remotesFolder:WaitForChild("FireWeapon") :: RemoteEvent
updateTurretAimRemote = remotesFolder:WaitForChild("UpdateTurretAim") :: RemoteEvent
```

**Fire input in the RenderStepped loop:**

Inside the existing `inputConnection` RenderStepped callback, after `updateBoostVisuals(dt)`, add weapon update logic:

```lua
if activeVehicleHasWeapon then
    -- Update weapon HUD from model attributes
    updateVehicleWeaponHUD()

    -- Send aim direction to server (vehicle forward + mouse offset)
    local aimDirection = computeVehicleAimDirection()
    if aimDirection ~= nil then
        updateTurretAimRemote:FireServer(aimDirection)
    end

    -- Fire on left mouse button (held = continuous fire)
    if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) and not freelookActive then
        if aimDirection ~= nil then
            fireWeaponRemote:FireServer(aimDirection)
        end
    end
end
```

**New helper: `computeVehicleAimDirection`:**

```lua
local function computeVehicleAimDirection(): Vector3?
    local renderModel = activeVehicleRenderModel
    if renderModel == nil or renderModel.PrimaryPart == nil then
        return nil
    end
    local camera = Workspace.CurrentCamera
    if camera == nil then
        return nil
    end
    -- Aim along the camera look direction (reticle probe from camera through crosshair)
    -- Use the crosshair screen position to cast a ray
    local screenCenter = camera.ViewportSize * 0.5
    local aimScreenPos = Vector2.new(screenCenter.X + virtualCursorX, screenCenter.Y + virtualCursorY)
    local ray = camera:ViewportPointToRay(aimScreenPos.X, aimScreenPos.Y)
    return ray.Direction.Unit
end
```

**New helper: `updateVehicleWeaponHUD`:**

```lua
local function updateVehicleWeaponHUD()
    local model = activeVehicleModel
    if model == nil then return end

    -- Heat
    local heat = model:GetAttribute("WeaponHeat")
    local heatMax = model:GetAttribute("WeaponHeatMax")
    local overheated = model:GetAttribute("WeaponOverheated") == true
    if type(heat) == "number" and type(heatMax) == "number" and heatMax > 0 then
        -- Client-side heat prediction (same exponential decay as server)
        local heatUpdatedAt = model:GetAttribute("WeaponHeatUpdatedAt")
        local decayRate = model:GetAttribute("WeaponHeatDecayPerSecond")
        if type(heatUpdatedAt) == "number" and type(decayRate) == "number" and decayRate > 0 then
            local elapsed = math.max(0, Workspace:GetServerTimeNow() - heatUpdatedAt)
            local coolingRate = decayRate / heatMax
            heat = math.clamp(heat * math.exp(-coolingRate * elapsed), 0, heatMax)
        end
        CombatHUD.setWeaponHeat(heat, heatMax, overheated)
    end

    -- Ammo
    local ammo = model:GetAttribute("WeaponAmmo")
    local ammoMax = model:GetAttribute("WeaponAmmoMax")
    if type(ammo) == "number" and type(ammoMax) == "number" then
        CombatHUD.setAmmo(ammo, ammoMax)
    end

    -- Shield
    local shieldHP = model:GetAttribute("ShieldHP")
    local maxShieldHP = model:GetAttribute("MaxShieldHP")
    if type(shieldHP) == "number" and type(maxShieldHP) == "number" and maxShieldHP > 0 then
        CombatHUD.setShield(shieldHP, maxShieldHP)
    end

    -- Weapon ready cue
    local recoverCueId = model:GetAttribute("WeaponHeatRecoverCueId")
    -- (track last seen cue ID to fire recovery notification)
end
```

**Cleanup in `exitVehicleMode`:**

```lua
activeVehicleHasWeapon = false
if weaponHeatConnection ~= nil then
    weaponHeatConnection:Disconnect()
    weaponHeatConnection = nil
end
if weaponAmmoConnection ~= nil then
    weaponAmmoConnection:Disconnect()
    weaponAmmoConnection = nil
end
CombatHUD.showCrosshair(false)
CombatHUD.showHeat(false)
CombatHUD.showAmmo(false)
CombatHUD.showShield(false)
```

### Crosshair Position

The vehicle cursor dot already tracks the virtual cursor. The crosshair should be at the same position (screen center + virtual cursor offset). In `enterVehicleMode`, set crosshair visible and keep it synced in the render loop:

```lua
CombatHUD.setCrosshairPosition(Vector2.new(screenCenter.X + virtualCursorX, screenCenter.Y + virtualCursorY))
```

This line goes inside the existing `updateVirtualCursor` flow, after `CombatHUD.setCursorDotPosition(...)`.

---

## Step 3: Vehicle Destruction + Occupant Death

**Goal:** When a vehicle's HP reaches 0, it explodes, all occupants die, and the vehicle enters destroyed state.

### Current Behavior

`HealthManager.destroyEntity` already:
1. Calls `destroyCallback` → `VehicleServer.onEntityDestroyed` → `cleanupVehicleState` (unseats driver)
2. Finds a single seat, ejects + kills the operator
3. Fires death explosion
4. Hides all parts
5. Fires `EntityDestroyed` to all clients

### Problem

The current seat search only finds ONE seat (first `Seat` descendant) and only kills that one occupant. Vehicles can have multiple seats (DriverSeat + passenger seats). Also, the kill logic uses `humanoid.Sit = false` then `humanoid:TakeDamage(1_000_000)` — but `VehicleServer.cleanupVehicleState` already unseats the driver via `humanoid.Sit = false`, which may race with HealthManager's logic.

### Solution

**File: `src/Server/Health/HealthManager.luau`**

Modify `destroyEntity` (~line 412) to kill ALL seated occupants, not just one:

Replace the single-seat logic block:
```lua
local seat = state.instance:FindFirstChildWhichIsA("Seat", true)
local operatorHumanoid: Humanoid? = nil
if seat ~= nil and seat.Occupant ~= nil then
    operatorHumanoid = seat.Occupant
    seat.Occupant.Sit = false
end
applyTurretDeathExplosion(state, seat, operatorHumanoid)
```

With a multi-occupant version:
```lua
-- Collect all seated occupants before unseat/cleanup
local allOccupantHumanoids: { Humanoid } = {}
local explosionSeat: Seat? = nil
for _, descendant in ipairs(state.instance:GetDescendants()) do
    if (descendant:IsA("Seat") or descendant:IsA("VehicleSeat")) and descendant.Occupant ~= nil then
        table.insert(allOccupantHumanoids, descendant.Occupant)
        if explosionSeat == nil then
            explosionSeat = descendant :: Seat
        end
    end
end

-- Unseat all occupants
for _, humanoid in ipairs(allOccupantHumanoids) do
    humanoid.Sit = false
end
```

Then modify `applyTurretDeathExplosion` call to pass `allOccupantHumanoids`:

Change the function signature:
```lua
local function applyTurretDeathExplosion(state: HealthStateInternal, explosionSeat: Seat?, occupantHumanoids: { Humanoid })
```

And inside it, kill ALL occupants:
```lua
-- All occupants die when their vehicle/turret is destroyed
for _, humanoid in ipairs(occupantHumanoids) do
    if humanoid.Health > 0 then
        humanoid:TakeDamage(1_000_000)
    end
end
```

### Exposed vs Enclosed

The `turretExposed` config field on entity configs determines if occupants can be directly shot. This already works for turrets via `ProjectileServer` hit detection (Pass 4). For vehicles:

- `turretExposed = true` (light speeder): driver can be hit by projectiles. Existing projectile hit detection checks character humanoids in the spherecast path and deals damage directly.
- `turretExposed = false` (heavy tank): driver is protected. Projectile hits the vehicle hull instead.

The existing Pass 4 enclosed turret protection logic in `ProjectileServer` checks `TurretExposed` attribute on the entity model. This attribute is already set by `CombatInit` at registration time. No changes needed — it works for vehicles too because the check is model-level, not platform-specific.

---

## Step 4: Dismount Behavior (Ghost Vehicle)

**Goal:** When a driver exits a moving vehicle (F key or death), the vehicle continues moving, decelerates, and stops on its own.

### Current Behavior

`clearDriver` in VehicleServer already sets `inputThrottle = 0, inputSteerX = 0, inputLean = 0, inputBoost = false`. The vehicle continues to be stepped in `stepSingleVehicle` even without a driver (it decelerates naturally via `deceleration` config). The replication state transitions to "Settling" then "Dormant".

This is already correct behavior. The vehicle coasts to a stop after the driver exits.

### Missing: Prevent Immediate Stop

Currently, `cleanupVehicleState` (called on entity destruction) unseats the driver and removes the vehicle from tracking entirely. But for normal dismount (F key exit), the vehicle should keep running.

Check the exit flow in VehicleServer. The `VehicleExitRequest` remote handler unseats the driver. The `driverSeat.Occupant` changed connection calls `clearDriver`. This flow already preserves the vehicle's velocity — it just zeroes input.

**Confirmed: No code changes needed for dismount behavior.** The vehicle already coasts to a stop when the driver exits via F key or death.

### Player Death While Driving

When a player dies, their character respawns. The `Humanoid.SeatPart` becomes nil (character destroyed). The `driverSeat.Occupant` changed connection fires, calling `clearDriver`. Same flow as F key exit — vehicle coasts to a stop.

**Confirmed: No code changes needed for player death while driving.**

---

## Step 5: Vehicle Theft

**Goal:** Any player can enter an unoccupied enemy vehicle.

### Current Behavior

The `DriverSeat` is a normal Roblox `Seat`. Walking up and pressing the seat interaction enters the player without any faction check. There is no ProximityPrompt on the DriverSeat (unlike turrets which have a faction-gated prompt).

**Confirmed: Vehicle theft already works by default.** Any player can sit in any unoccupied DriverSeat. The VehicleServer `driverSeat.Occupant` changed connection will assign the new driver regardless of faction.

### Combat Identity on Theft

When an enemy steals a vehicle, the vehicle keeps its original faction (set at registration). This means:

- The thief can fire the vehicle's weapon, but projectiles carry the VEHICLE's faction, not the player's faction.
- Same-faction vehicles won't damage each other (unless FriendlyFireEnabled).
- The thief is shooting "as" the enemy faction.

This is acceptable for now. If needed later, a faction-swap-on-theft system can be added. No changes needed.

---

## Step 6: Splash Damage on Vehicles

**Goal:** Explosion/splash damage from turret destruction, artillery, and splash weapons affects vehicles.

### Current Behavior

`HealthManager.applyExplosionDamage` (via `applyTurretDeathExplosion`) already searches for nearby entities by `EntityId` and applies damage. Since vehicles ARE registered combat entities with EntityId, they already receive splash damage.

**Confirmed: No code changes needed.** Splash damage on vehicles already works through the existing entity damage system.

---

## Step 7: Lock-On Targeting for Vehicles

**Goal:** Vehicle drivers can lock onto targets and use auto-aim/homing weapons.

### Current Behavior

`TargetingClient` handles lock-on UI and sends `RequestLockOn` / `ClearLockOn` remotes. `TargetingServer` validates locks against entity state (faction, range, arc, alive).

The client-side lock targeting in `WeaponClient` sends lock requests when `T` is pressed, based on the seated turret context. Vehicle drivers need the same pathway.

### File: `src/Client/Weapons/WeaponClient.luau`

Need to check how WeaponClient resolves which entity the player is controlling. Let me check the lock input flow.

Actually, `TargetingClient` handles the T key input. It finds the player's entity by checking the `SeatPart` for a `TurretSeat` tag, then walking up to find the entity model. For vehicles, it needs to also check for `DriverSeat`.

**File: `src/Client/Targeting/TargetingClient.luau`**

Modify the entity resolution to also check DriverSeat:

Wherever TargetingClient resolves the local player's entity (to determine if they can lock), add fallback:

```lua
-- Check turret seat first, then driver seat
if seatPart ~= nil then
    if CollectionService:HasTag(seatPart, "TurretSeat") or CollectionService:HasTag(seatPart, "ArtillerySeat") then
        -- existing turret entity resolution
    elseif CollectionService:HasTag(seatPart, "DriverSeat") then
        -- walk up to VehicleEntity model, get EntityId
    end
end
```

### Server-Side Lock Validation

**File: `src/Server/Targeting/TargetingServer.luau`**

The `RequestLockOn` handler resolves the player's entity context. Same issue — it checks for TurretSeat/ArtillerySeat. Add DriverSeat fallback.

Wherever `TargetingServer` resolves player context from SeatPart, add:

```lua
if not CollectionService:HasTag(seatPart, "TurretSeat") and not CollectionService:HasTag(seatPart, "ArtillerySeat") then
    if CollectionService:HasTag(seatPart, "DriverSeat") then
        -- walk up to VehicleEntity model
    else
        return  -- not in any weapon seat
    end
end
```

---

## Integration Points Summary

### Files Modified

| File | Changes |
|------|---------|
| `src/Server/Weapons/WeaponServer.luau` | Add `resolvePlayerVehicleWeaponContext`, modify `onFireWeapon` + `onUpdateTurretAim` to fallback to vehicle context |
| `src/Server/Health/HealthManager.luau` | Multi-occupant kill on entity destruction |
| `src/Server/Authoring/StartupValidator.luau` | Skip TurretSeat/CameraPoint requirement for armed VehicleEntity models |
| `src/Server/CombatInit.server.luau` | Guard turret prompt block to skip VehicleEntity models |
| `src/Shared/CombatConfig.luau` | Add `light_speeder_armed` and `heavy_speeder_armed` entity configs |
| `src/Client/Vehicles/VehicleClient.luau` | Weapon HUD, fire input, aim direction for armed vehicles |
| `src/Client/Targeting/TargetingClient.luau` | DriverSeat entity resolution for lock-on input |
| `src/Server/Targeting/TargetingServer.luau` | DriverSeat entity resolution for lock validation |
| `src/Shared/CombatTypes.luau` | No changes needed |

### Files NOT Modified

- `src/Server/Vehicles/VehicleServer.luau` — dismount/coast behavior already works
- `src/Server/Projectiles/ProjectileServer.luau` — splash damage and exposed/enclosed already work
- `src/Client/Vehicles/RemoteVehicleSmoother.luau` — no changes
- `src/Client/HUD/CombatHUD.luau` — all needed functions already exist

### New RemoteEvents

None. All existing remotes (`FireWeapon`, `UpdateTurretAim`, `RequestLockOn`, `ClearLockOn`, `LockOnState`) are reused.

### New Tags / Attributes

None. All existing tags (`DriverSeat`, `VehicleEntity`, `CombatEntity`, `WeaponMount`, `MuzzlePoint`, `HoverPoint`) are reused. New entity configs use existing attribute contracts (`ConfigId`, `VehicleCategory`, `Faction`, `EntityId`).

---

## Authoring Contract for Armed Vehicles

An armed speeder model requires:

1. **Tags on the model:** `CombatEntity` + `VehicleEntity`
2. **Attributes on the model:** `ConfigId = "light_speeder_armed"` (or `heavy_speeder_armed`), `VehicleCategory = "light"` (or `heavy"`), `Faction = "empire"` (or `rebel`)
3. **PrimaryPart:** Set, Anchored
4. **DriverSeat:** A `Seat` descendant with `DriverSeat` tag
5. **HoverPoints:** 4+ `BasePart` descendants with `HoverPoint` tag
6. **WeaponMount:** A `BasePart` descendant with `WeaponMount` tag
7. **MuzzlePoint:** An `Attachment` descendant of WeaponMount named `MuzzlePoint` (or tagged `MuzzlePoint`)
8. **ForwardAxis or ForwardYawOffset:** Attribute on model

No `TurretSeat`, no `CameraPoint`, no `ProximityPrompt` needed.

---

## Test Packet

### Step 1 Test: Driver Fire

**AI build prints:**
- `[P6_VEHICLE_FIRE] entity=%s player=%s weaponClass=%s` — on successful vehicle weapon fire
- `[P6_VEHICLE_AIM] entity=%s` — on aim update from vehicle driver (throttled to 1/sec for readability)

**Setup:** Armed light speeder (`ConfigId=light_speeder_armed`, `VehicleCategory=light`) and a rebel target dummy at (0, 5, 80). Player seated in driver seat.

**Pass conditions:**
- Left click produces `[P6_VEHICLE_FIRE]` logs
- Projectile fires from weapon mount muzzle position
- Target takes damage on hit
- `[P1_HIT]` and `[P1_DAMAGE]` logs appear

**Fail conditions:**
- Left click produces no fire log
- Fire request silently discarded (no resolution context)
- Projectile origin is wrong (fires from vehicle center instead of muzzle)

### Step 2 Test: Vehicle Weapon HUD

**AI build prints:**
- `[P6_HUD_ARMED] entity=%s weaponClass=%s` — when vehicle weapon HUD activates

**Pass conditions:**
- Entering armed vehicle shows crosshair + heat bar (or ammo counter)
- Heat increases on fire, heat bar updates
- Shield bar visible if vehicle has shields
- HP display shows vehicle hull HP

**Fail conditions:**
- No crosshair/heat HUD on entering armed vehicle
- HUD shows but never updates
- Entering unarmed vehicle incorrectly shows weapon HUD

### Step 3 Test: Vehicle Destruction

**AI build prints:**
- `[P6_VEHICLE_DESTROY] entity=%s occupants=%d` — before destruction processing

**Setup:** Armed speeder with player driving. Take damage until HP = 0.

**Pass conditions:**
- Vehicle explodes (VFX + sound)
- Driver dies (humanoid health = 0)
- Vehicle model hidden
- `[P1_DESTROYED]` log
- Vehicle respawns after `respawnTime`

**Fail conditions:**
- Driver survives destruction
- No explosion VFX
- Vehicle doesn't respawn

### Step 4 Test: Dismount Coast

**No new AI build prints.** Existing `[P5_SPEED]` logs sufficient.

**Pass conditions:**
- Press F while moving → driver exits, vehicle continues moving, decelerates to stop
- Driver death while moving → same behavior

**Fail conditions:**
- Vehicle instantly stops when driver exits
- Vehicle keeps accelerating with no driver

### Step 5 Test: Vehicle Lock-On

**AI build prints:**
- `[P6_VEHICLE_LOCK] entity=%s target=%s` — when vehicle driver acquires lock

**Pass conditions:**
- Press T while driving → lock acquired on target
- Locked fire uses auto-aim
- `[P4_AUTO_AIM]` logs appear

**Fail conditions:**
- T key does nothing while driving
- Lock request silently discarded

---

## Golden Tests

### Test 17: Vehicle Driver Fire
- **Added in:** Pass 6
- **Setup:** Empire armed light speeder (`ConfigId=light_speeder_armed`, `VehicleCategory=light`, blaster_turret weapon) at (0, 10, 0). Rebel target_dummy (hullHP=200) at (0, 5, 50). Player seated in DriverSeat. TestHarnessEnabled = true.
- **Action:** Player fires 3 shots at target.
- **Expected:** All 3 hit. Target HP decreases from 200 to 80 (3 x 40 blaster damage).
- **Pass condition:** 3x `[P6_VEHICLE_FIRE]` logs. 3x `[P1_HIT]` logs. 3x `[P1_DAMAGE]` logs showing -40 each. Target HP = 80.

### Test 18: Vehicle Destruction Kills All Occupants
- **Added in:** Pass 6
- **Setup:** Armed speeder with 2 occupants (driver + 1 passenger in second seat). HullHP = 40. TestHarnessEnabled = true.
- **Action:** Rebel turret fires 1 shot dealing 40+ damage.
- **Expected:** Vehicle destroyed. Both occupants die.
- **Pass condition:** `[P6_VEHICLE_DESTROY]` with occupants=2. `[P1_DESTROYED]` log. Both humanoids Health = 0.

### Test 19: Enclosed Vehicle Rider Protection
- **Added in:** Pass 6
- **Setup:** Empire heavy armed speeder (`turretExposed=false`). Player driving. Rebel turret fires at player character.
- **Expected:** Shots blocked by enclosed protection. Player takes 0 direct damage. Vehicle hull takes damage instead.
- **Pass condition:** `[P4_ENCLOSED_BLOCK]` logs. Player Humanoid.Health unchanged. Vehicle HullHP decreases.

### Regression Tests
Re-run ALL Pass 1-5 Tests (1-16). Vehicle weapon changes must NOT affect existing turret combat behavior.
