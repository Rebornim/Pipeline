--!strict

local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local sharedRoot = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatConfig = require(sharedRoot:WaitForChild("CombatConfig"))
local WeaponRig = require(sharedRoot:WaitForChild("WeaponRig"))

local combatHUDModule: any = nil

local ArtilleryClient = {}

local localPlayer = Players.LocalPlayer

type RigOverride = {
	mode: string?,
	minYawDeg: number?,
	maxYawDeg: number?,
	minPitchDeg: number?,
	maxPitchDeg: number?,
	pivotName: string?,
	pivotAttachment: Attachment?,
}

type DrivenPartState = {
	part: BasePart,
	neutralAimFrame: CFrame,
	clampOverride: RigOverride?,
}

local activeArtilleryModel: Model? = nil
local activeSeat: BasePart? = nil
local activeWeaponMount: BasePart? = nil
local activeCameraPoint: Instance? = nil
local activeDrivenParts: { DrivenPartState } = {}

local heading: number = 0
local elevation: number = math.rad(45)

local fireWeaponRemote: RemoteEvent? = nil
local updateTurretAimRemote: RemoteEvent? = nil

local stepConnection: RBXScriptConnection? = nil
local seatedConnection: RBXScriptConnection? = nil
local characterAddedConnection: RBXScriptConnection? = nil
local baseFov: number = 70

local wHeld: boolean = false
local sHeld: boolean = false
local aHeld: boolean = false
local dHeld: boolean = false
local shiftHeld: boolean = false
local zoomHeld: boolean = false
local zoomBlend: number = 0

local nextAimUpdateTime: number = 0
local nextClientFireTime: number = 0
local lastAimLogTime: number = 0

local FIRE_ACTION = "ArtilleryFire"
local EXIT_ACTION = "ArtilleryExit"
local ZOOM_ACTION = "ArtilleryZoom"
local AIM_W_ACTION = "ArtilleryAimW"
local AIM_S_ACTION = "ArtilleryAimS"
local AIM_A_ACTION = "ArtilleryAimA"
local AIM_D_ACTION = "ArtilleryAimD"
local SHIFT_ACTION = "ArtilleryShift"

local AIM_UPDATE_INTERVAL = 1 / 30
local CAMERA_FALLBACK_LOCAL_OFFSET = Vector3.new(0, 9, 22)
local CAMERA_LOOK_DISTANCE = 500
local CAMERA_POINT_NAME = "CameraPoint"
local ZOOM_FOV_REDUCTION = 25
local ZOOM_IN_RATE = 6
local ZOOM_OUT_RATE = 8
local MIN_FOV = 30

-- Ghost arc preview constants
-- Freelook constants
local FREELOOK_SENSITIVITY = 0.003
local FREELOOK_PITCH_MIN = -math.rad(60)
local FREELOOK_PITCH_MAX = math.rad(45)
local FREELOOK_DISTANCE = 20

-- Freelook state
local freelookActive: boolean = false
local freelookYaw: number = 0
local freelookPitch: number = 0

local GHOST_ARC_INTERVAL = 3.0
local GHOST_ARC_MAX_TIME = 8.0
local GHOST_ARC_STEP = 1 / 30
local GHOST_ARC_TRANSPARENCY = 0.7
local GHOST_ARC_COLOR = Color3.fromRGB(255, 160, 40)
local GHOST_ARC_TRAIL_COLOR = Color3.fromRGB(255, 120, 20)
local GHOST_ARC_SIZE = Vector3.new(0.4, 0.4, 0.8)

-- Ghost arc state
local ghostPart: BasePart? = nil
local ghostTrail: Trail? = nil
local ghostVelocity: Vector3 = Vector3.zero
local ghostAlive: boolean = false
local ghostTimer: number = 0
local ghostAge: number = 0
local ghostGravity: number = 300

local function getWeaponConfig(model: Model): any
	local configId = model:GetAttribute("ConfigId")
	if type(configId) ~= "string" then
		return nil
	end

	local entityConfig = CombatConfig.Entities[configId]
	if entityConfig == nil or entityConfig.weaponId == nil then
		return nil
	end

	local base = CombatConfig.Weapons[entityConfig.weaponId]
	if base == nil then
		return nil
	end

	-- Read effective (overridden) values from model attributes, fall back to base config
	local function num(attrName: string, fallback: number?): number?
		local v = model:GetAttribute(attrName)
		if type(v) == "number" then
			return v
		end
		return fallback
	end

	return {
		weaponClass = base.weaponClass,
		damageType = base.damageType,
		damage = num("EffectiveWeaponDamage", base.damage),
		fireRate = num("EffectiveWeaponFireRate", base.fireRate),
		projectileSpeed = num("EffectiveWeaponProjectileSpeed", base.projectileSpeed),
		maxRange = num("EffectiveWeaponMaxRange", base.maxRange),
		ammoCapacity = num("EffectiveAmmoCapacity", base.ammoCapacity),
		artilleryGravity = num("EffectiveArtilleryGravity", base.artilleryGravity),
		artilleryMinElevation = num("EffectiveArtilleryMinElevation", base.artilleryMinElevation),
		artilleryMaxElevation = num("EffectiveArtilleryMaxElevation", base.artilleryMaxElevation),
		artilleryAdjustSpeed = num("EffectiveArtilleryAdjustSpeed", base.artilleryAdjustSpeed),
		artilleryFineAdjustSpeed = num("EffectiveArtilleryFineAdjustSpeed", base.artilleryFineAdjustSpeed),
		artilleryMinRange = num("EffectiveArtilleryMinRange", base.artilleryMinRange),
		boltColor = base.boltColor,
	}
end

local function findCameraPoint(model: Model): Instance?
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant.Name == CAMERA_POINT_NAME and (descendant:IsA("BasePart") or descendant:IsA("Attachment")) then
			return descendant
		end
	end
	return nil
end

local function findTaggedDescendant(model: Model, tagName: string, className: string): Instance?
	for _, descendant in ipairs(model:GetDescendants()) do
		if CollectionService:HasTag(descendant, tagName) and descendant:IsA(className) then
			return descendant
		end
	end
	return nil
end

local function getCameraAnchorPosition(cameraPoint: Instance?, seat: BasePart?, mount: BasePart?): Vector3?
	if cameraPoint ~= nil then
		if cameraPoint:IsA("Attachment") then
			return (cameraPoint :: Attachment).WorldPosition
		elseif cameraPoint:IsA("BasePart") then
			return (cameraPoint :: BasePart).Position
		end
	end

	if seat ~= nil then
		return seat.CFrame:PointToWorldSpace(CAMERA_FALLBACK_LOCAL_OFFSET)
	end

	if mount ~= nil then
		return mount.CFrame:PointToWorldSpace(CAMERA_FALLBACK_LOCAL_OFFSET)
	end

	return nil
end

local function computeAimDirection(): Vector3
	local cosElev = math.cos(elevation)
	return Vector3.new(
		-math.sin(heading) * cosElev,
		math.sin(elevation),
		-math.cos(heading) * cosElev
	).Unit
end

local function computeFlatRange(weaponConfig: any): number
	if weaponConfig == nil then
		return 0
	end

	local v = weaponConfig.projectileSpeed or 500
	local g = weaponConfig.artilleryGravity or 300
	if g <= 0 then
		return 0
	end

	return v * v * math.sin(2 * elevation) / g
end

-- Driven parts rigging (same logic as turrets)
local function clearDrivenParts()
	table.clear(activeDrivenParts)
end

local function modeFromFolderName(folderName: string): string?
	local normalized = string.lower(string.gsub(folderName, "[%s_%-]", ""))
	if normalized == "yawonly" or normalized == "yawonlyparts" or normalized == "drivenyawonly" then
		return "yawonly"
	end
	if normalized == "pitchonly" or normalized == "pitchonlyparts" or normalized == "drivenpitchonly" then
		return "pitchonly"
	end
	if normalized == "yawpitch" or normalized == "yawpitchparts" or normalized == "drivenyawpitch" then
		return "yawpitch"
	end
	return nil
end

local function readNumberAttr(inst: Instance, name: string): number?
	local raw = inst:GetAttribute(name)
	if type(raw) == "number" then
		return raw
	end
	if type(raw) == "string" then
		return tonumber(raw)
	end
	return nil
end

local function getClampOverride(folder: Instance, modeFromName: string?): RigOverride?
	local modeFromAttr = folder:GetAttribute("AimMode")
	local mode: string? = modeFromName
	if type(modeFromAttr) == "string" and modeFromAttr ~= "" then
		mode = modeFromAttr
	end

	local minYawDeg = readNumberAttr(folder, "MinYawDeg")
	local maxYawDeg = readNumberAttr(folder, "MaxYawDeg")
	local minPitchDeg = readNumberAttr(folder, "MinPitchDeg")
	local maxPitchDeg = readNumberAttr(folder, "MaxPitchDeg")
	local pivotName: string? = nil
	local pivotNameRaw = folder:GetAttribute("AimPivotName")
	if type(pivotNameRaw) == "string" and string.match(pivotNameRaw, "%S") ~= nil then
		pivotName = pivotNameRaw
	end

	local pivotAttachment: Attachment? = nil
	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("ObjectValue") and child.Value ~= nil and child.Value:IsA("Attachment") then
			local attachedValue = child.Value :: Attachment
			if child.Name == "AimPivotAttachment" or child.Name == "PivotAttachment" then
				pivotAttachment = attachedValue
				break
			end
			if pivotAttachment == nil then
				pivotAttachment = attachedValue
			end
		end
	end

	if mode == nil and minYawDeg == nil and maxYawDeg == nil and minPitchDeg == nil and maxPitchDeg == nil and pivotName == nil and pivotAttachment == nil then
		return nil
	end

	return {
		mode = mode,
		minYawDeg = minYawDeg,
		maxYawDeg = maxYawDeg,
		minPitchDeg = minPitchDeg,
		maxPitchDeg = maxPitchDeg,
		pivotName = pivotName,
		pivotAttachment = pivotAttachment,
	}
end

local function addDrivenPart(part: BasePart, seen: { [BasePart]: boolean }, clampOverride: RigOverride?)
	if activeWeaponMount ~= nil and part == activeWeaponMount then
		return
	end
	if seen[part] then
		return
	end
	seen[part] = true
	table.insert(activeDrivenParts, {
		part = part,
		neutralAimFrame = WeaponRig.getNeutralAimFrame(part),
		clampOverride = clampOverride,
	})
end

local function collectDrivenPartsFromContainer(container: Instance, seen: { [BasePart]: boolean }, clampOverride: RigOverride?)
	for _, descendant in ipairs(container:GetDescendants()) do
		if descendant:IsA("BasePart") then
			addDrivenPart(descendant, seen, clampOverride)
		elseif descendant:IsA("ObjectValue") and descendant.Value ~= nil and descendant.Value:IsA("BasePart") then
			addDrivenPart(descendant.Value, seen, clampOverride)
		end
	end
end

local function rebuildDrivenParts()
	clearDrivenParts()

	local model = activeArtilleryModel
	if model == nil then
		return
	end

	local seen: { [BasePart]: boolean } = {}
	if activeWeaponMount ~= nil then
		seen[activeWeaponMount] = true
	end

	local rigFolder = model:FindFirstChild("TurretRig")
	if rigFolder == nil then
		return
	end

	local drivenPartsFolder = rigFolder:FindFirstChild("DrivenParts")
	if drivenPartsFolder ~= nil then
		local clampOverride = getClampOverride(drivenPartsFolder, nil)
		collectDrivenPartsFromContainer(drivenPartsFolder, seen, clampOverride)
	end

	for _, child in ipairs(rigFolder:GetChildren()) do
		if child:IsA("Folder") and child.Name ~= "DrivenParts" then
			local modeOverride = modeFromFolderName(child.Name)
			local clampOverride = getClampOverride(child, modeOverride)
			if modeOverride ~= nil or clampOverride ~= nil then
				collectDrivenPartsFromContainer(child, seen, clampOverride)
			end
		end
	end
end

local function updateDrivenPartsAim(aimDirection: Vector3)
	if #activeDrivenParts == 0 then
		return
	end

	for index = #activeDrivenParts, 1, -1 do
		local driven = activeDrivenParts[index]
		if driven.part.Parent == nil then
			table.remove(activeDrivenParts, index)
		else
			local drivenDirection = WeaponRig.clampDirectionToMountLimits(driven.part, driven.neutralAimFrame, aimDirection, driven.clampOverride)
			if drivenDirection.Magnitude > 1e-4 then
				driven.part.CFrame = WeaponRig.getAimFrame(driven.part, drivenDirection, driven.clampOverride)
			end
		end
	end
end

local function cleanupGhostArc()
	ghostAlive = false
	if ghostPart ~= nil then
		(ghostPart :: BasePart):Destroy()
		ghostPart = nil
	end
	ghostTrail = nil
end

local function getMuzzleWorldPosition(): Vector3?
	if activeWeaponMount == nil then
		return nil
	end

	-- Look for MuzzlePoint attachment inside the mount
	for _, descendant in ipairs((activeWeaponMount :: BasePart):GetDescendants()) do
		if descendant:IsA("Attachment") then
			local name = descendant.Name
			if name == "MuzzlePoint" or string.sub(name, 1, 11) == "MuzzlePoint" then
				return (descendant :: Attachment).WorldPosition
			end
		end
	end

	-- Fallback: front of the mount
	return (activeWeaponMount :: BasePart).CFrame:PointToWorldSpace(Vector3.new(0, 0, -2))
end

local function spawnGhostArc()
	cleanupGhostArc()

	local muzzlePos = getMuzzleWorldPosition()
	if muzzlePos == nil then
		return
	end

	local weaponConfig = if activeArtilleryModel ~= nil then getWeaponConfig(activeArtilleryModel :: Model) else nil
	if weaponConfig == nil then
		return
	end

	local speed = weaponConfig.projectileSpeed or 500
	ghostGravity = weaponConfig.artilleryGravity or 300
	local aimDir = computeAimDirection()
	ghostVelocity = aimDir * speed

	-- Create the ghost part
	local part = Instance.new("Part")
	part.Name = "GhostArcShell"
	part.Size = GHOST_ARC_SIZE
	part.Shape = Enum.PartType.Ball
	part.Color = GHOST_ARC_COLOR
	part.Material = Enum.Material.Neon
	part.Transparency = GHOST_ARC_TRANSPARENCY
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Position = muzzlePos :: Vector3
	part.Parent = workspace

	-- Create trail attachments
	local att0 = Instance.new("Attachment")
	att0.Name = "TrailAtt0"
	att0.Position = Vector3.new(0, 0, -0.3)
	att0.Parent = part

	local att1 = Instance.new("Attachment")
	att1.Name = "TrailAtt1"
	att1.Position = Vector3.new(0, 0, 0.3)
	att1.Parent = part

	-- Create trail
	local trail = Instance.new("Trail")
	trail.Attachment0 = att0
	trail.Attachment1 = att1
	trail.Color = ColorSequence.new(GHOST_ARC_TRAIL_COLOR)
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4),
		NumberSequenceKeypoint.new(0.5, 0.7),
		NumberSequenceKeypoint.new(1, 1),
	})
	trail.Lifetime = 1.5
	trail.MinLength = 0.1
	trail.WidthScale = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(1, 0.2),
	})
	trail.FaceCamera = true
	trail.Parent = part

	ghostPart = part
	ghostTrail = trail
	ghostAlive = true
	ghostAge = 0
end

local function stepGhostArc(dt: number)
	if not ghostAlive or ghostPart == nil then
		return
	end

	ghostAge += dt

	-- Max flight time reached — clean up
	if ghostAge >= GHOST_ARC_MAX_TIME then
		cleanupGhostArc()
		return
	end

	-- Step parabolic physics (same formula as server)
	ghostVelocity = ghostVelocity + Vector3.new(0, -ghostGravity * dt, 0)
	local part = ghostPart :: BasePart
	local oldPos = part.Position
	local newPos = oldPos + ghostVelocity * dt

	-- Raycast to detect terrain/part hit
	local rayDir = newPos - oldPos
	local rayLength = rayDir.Magnitude
	if rayLength > 0.01 then
		local rayParams = RaycastParams.new()
		local filterList: { Instance } = { part }
		if activeArtilleryModel ~= nil then
			table.insert(filterList, activeArtilleryModel :: Model)
		end
		local character = localPlayer.Character
		if character ~= nil then
			table.insert(filterList, character)
		end
		rayParams.FilterDescendantsInstances = filterList
		rayParams.FilterType = Enum.RaycastFilterType.Exclude
		local result = workspace:Raycast(oldPos, rayDir.Unit * rayLength, rayParams)
		if result ~= nil then
			-- Hit something — place at impact and clean up
			part.Position = result.Position
			-- Let the trail linger briefly before destroying
			task.delay(0.3, function()
				cleanupGhostArc()
			end)
			ghostAlive = false
			return
		end
	end

	-- Fade out over time
	local fadeAlpha = math.clamp(ghostAge / GHOST_ARC_MAX_TIME, 0, 1)
	part.Transparency = GHOST_ARC_TRANSPARENCY + (1 - GHOST_ARC_TRANSPARENCY) * fadeAlpha * 0.5

	-- Orient along velocity
	if ghostVelocity.Magnitude > 1 then
		part.CFrame = CFrame.lookAt(newPos, newPos + ghostVelocity.Unit)
	else
		part.Position = newPos
	end
end

local function onFireAction(_name: string, state: Enum.UserInputState, _input: InputObject)
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end

	if activeArtilleryModel == nil or fireWeaponRemote == nil then
		return Enum.ContextActionResult.Pass
	end

	local now = tick()
	if now < nextClientFireTime then
		return Enum.ContextActionResult.Sink
	end

	local weaponConfig = getWeaponConfig(activeArtilleryModel :: Model)
	if weaponConfig == nil then
		return Enum.ContextActionResult.Sink
	end

	local cooldown = if weaponConfig.fireRate > 0 then 1 / weaponConfig.fireRate else 5
	nextClientFireTime = now + cooldown

	local aimDir = computeAimDirection()
	fireWeaponRemote:FireServer(aimDir)
	return Enum.ContextActionResult.Sink
end

local function onExitAction(_name: string, state: Enum.UserInputState, _input: InputObject)
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end

	local character = localPlayer.Character
	if character ~= nil then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid ~= nil then
			humanoid.Sit = false
		end
	end
	return Enum.ContextActionResult.Sink
end

local function onZoomAction(_name: string, state: Enum.UserInputState, _input: InputObject)
	if state == Enum.UserInputState.Begin then
		zoomHeld = true
	elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
		zoomHeld = false
	end
	return Enum.ContextActionResult.Sink
end

local function makeKeyAction(setter: (boolean) -> ())
	return function(_name: string, state: Enum.UserInputState, _input: InputObject)
		if state == Enum.UserInputState.Begin then
			setter(true)
		elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
			setter(false)
		end
		return Enum.ContextActionResult.Sink
	end
end

local function sendAimUpdate(aimDir: Vector3)
	if updateTurretAimRemote == nil then
		return
	end

	local now = tick()
	if now < nextAimUpdateTime then
		return
	end

	nextAimUpdateTime = now + AIM_UPDATE_INTERVAL
	updateTurretAimRemote:FireServer(aimDir)
end

local function updateArtilleryAndCamera(dt: number)
	if activeArtilleryModel == nil then
		return
	end

	local weaponConfig = getWeaponConfig(activeArtilleryModel :: Model)
	if weaponConfig == nil then
		return
	end

	local camera = workspace.CurrentCamera
	if camera == nil then
		return
	end

	-- Freelook toggle
	local altHeld = UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt)
	if altHeld and not freelookActive then
		freelookActive = true
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
		-- Initialize orbit from current camera position
		local camPos = camera.CFrame.Position
		local pivotPos = if activeArtilleryModel ~= nil then (activeArtilleryModel :: Model):GetPivot().Position else camPos
		local toCamera = camPos - pivotPos
		freelookYaw = math.atan2(toCamera.X, toCamera.Z)
		local horizontalDist = Vector3.new(toCamera.X, 0, toCamera.Z).Magnitude
		freelookPitch = -math.atan2(toCamera.Y, horizontalDist)
		freelookPitch = math.clamp(freelookPitch, FREELOOK_PITCH_MIN, FREELOOK_PITCH_MAX)
	elseif not altHeld and freelookActive then
		freelookActive = false
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		UserInputService.MouseIconEnabled = false
	end

	-- While freelook is active, handle RMB orbit and skip aim/camera updates
	if freelookActive then
		local rmbHeld = UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
		if rmbHeld then
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
			local delta = UserInputService:GetMouseDelta()
			freelookYaw -= delta.X * FREELOOK_SENSITIVITY
			freelookPitch -= delta.Y * FREELOOK_SENSITIVITY
			freelookPitch = math.clamp(freelookPitch, FREELOOK_PITCH_MIN, FREELOOK_PITCH_MAX)
		else
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			UserInputService.MouseIconEnabled = true
		end

		-- Orbit camera around the emplacement
		local pivotPos = if activeArtilleryModel ~= nil then (activeArtilleryModel :: Model):GetPivot().Position else camera.CFrame.Position
		pivotPos = pivotPos + Vector3.new(0, 3, 0)
		local orbitCFrame = CFrame.new(pivotPos)
			* CFrame.Angles(0, freelookYaw, 0)
			* CFrame.Angles(freelookPitch, 0, 0)
			* CFrame.new(0, 0, FREELOOK_DISTANCE)
		camera.CFrame = CFrame.lookAt(orbitCFrame.Position, pivotPos)

		-- Still step ghost arc during freelook
		ghostTimer += dt
		if ghostTimer >= GHOST_ARC_INTERVAL then
			ghostTimer = 0
			spawnGhostArc()
		end
		stepGhostArc(dt)
		return
	end

	-- Read config values
	local adjustSpeed = weaponConfig.artilleryAdjustSpeed or 30
	local fineSpeed = weaponConfig.artilleryFineAdjustSpeed or 5
	local minElev = math.rad(weaponConfig.artilleryMinElevation or 5)
	local maxElev = math.rad(weaponConfig.artilleryMaxElevation or 85)
	local speed = if shiftHeld then fineSpeed else adjustSpeed
	local speedRad = math.rad(speed) * dt

	-- Update heading/elevation from WASD
	if wHeld then
		elevation = math.clamp(elevation + speedRad, minElev, maxElev)
	end
	if sHeld then
		elevation = math.clamp(elevation - speedRad, minElev, maxElev)
	end
	if aHeld then
		heading = heading + speedRad
	end
	if dHeld then
		heading = heading - speedRad
	end

	local aimDirection = computeAimDirection()

	-- Apply aim to weapon rig (visual barrel tilt + driven parts)
	local mount = activeWeaponMount
	if mount ~= nil then
		local neutralAimFrame = WeaponRig.getNeutralAimFrame(mount)
		local clampedDir = WeaponRig.clampDirectionToMountLimits(mount, neutralAimFrame, aimDirection)
		if clampedDir.Magnitude > 1e-4 then
			mount.CFrame = WeaponRig.getAimFrame(mount, clampedDir)
		end
	end
	updateDrivenPartsAim(aimDirection)

	-- Send aim to server (throttled)
	sendAimUpdate(aimDirection)

	-- Update HUD
	if combatHUDModule ~= nil then
		local elevDeg = math.deg(elevation)
		local hdgDeg = math.deg(heading) % 360
		local rangeSt = math.max(0, computeFlatRange(weaponConfig))
		combatHUDModule.setArtilleryAim(elevDeg, hdgDeg, rangeSt)

		-- Update ammo display
		local ammoRaw = (activeArtilleryModel :: Model):GetAttribute("WeaponAmmo")
		local ammoMaxRaw = (activeArtilleryModel :: Model):GetAttribute("WeaponAmmoMax")
		if type(ammoRaw) == "number" and type(ammoMaxRaw) == "number" then
			combatHUDModule.setAmmo(ammoRaw, ammoMaxRaw)
		end
	end

	-- AI build print (throttled to 1/sec)
	local now = tick()
	if now - lastAimLogTime >= 1.0 then
		lastAimLogTime = now
		local elevDeg = math.deg(elevation)
		local hdgDeg = math.deg(heading) % 360
		local rangeSt = math.max(0, computeFlatRange(weaponConfig))
		print(string.format("[P7_AIM] heading=%.1f elevation=%.1f range=%.0f", hdgDeg, elevDeg, rangeSt))
	end

	-- Camera: anchor at CameraPoint, look in aim direction
	local camPos = getCameraAnchorPosition(activeCameraPoint, activeSeat, activeWeaponMount)
	if camPos == nil then
		camPos = camera.CFrame.Position
	end

	-- Zoom
	local zoomTarget = if zoomHeld then 1 else 0
	local zoomRate = if zoomTarget > zoomBlend then ZOOM_IN_RATE else ZOOM_OUT_RATE
	zoomBlend += (zoomTarget - zoomBlend) * math.min(1, dt * zoomRate)
	local zoomFovOffset = -ZOOM_FOV_REDUCTION * zoomBlend
	camera.FieldOfView = math.max(MIN_FOV, baseFov + zoomFovOffset)

	camera.CFrame = CFrame.lookAt(camPos :: Vector3, (camPos :: Vector3) + aimDirection * CAMERA_LOOK_DISTANCE)

	-- Cursor dot at center
	if combatHUDModule ~= nil then
		local center = camera.ViewportSize * 0.5
		combatHUDModule.setCursorDotPosition(Vector2.new(center.X, center.Y))
	end

	-- Ghost arc preview: spawn every GHOST_ARC_INTERVAL seconds
	ghostTimer += dt
	if ghostTimer >= GHOST_ARC_INTERVAL then
		ghostTimer = 0
		spawnGhostArc()
	end

	-- Step the ghost arc if alive
	stepGhostArc(dt)
end

local function activateArtilleryMode(seatPart: BasePart)
	local entityModel = seatPart:FindFirstAncestorWhichIsA("Model")
	if entityModel == nil then
		return
	end

	activeArtilleryModel = entityModel
	activeSeat = seatPart
	activeWeaponMount = findTaggedDescendant(entityModel, "WeaponMount", "BasePart") :: BasePart?
	activeCameraPoint = findCameraPoint(entityModel)
	rebuildDrivenParts()

	-- Initialize heading from model forward
	local modelCF = entityModel:GetPivot()
	local forward = -modelCF.LookVector
	heading = math.atan2(-forward.X, -forward.Z)
	elevation = math.rad(45)

	-- Camera setup
	local camera = workspace.CurrentCamera
	if camera ~= nil then
		baseFov = camera.FieldOfView
		camera.CameraType = Enum.CameraType.Scriptable
	end
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	UserInputService.MouseIconEnabled = false

	-- Reset state
	wHeld = false
	sHeld = false
	aHeld = false
	dHeld = false
	shiftHeld = false
	zoomHeld = false
	zoomBlend = 0
	nextAimUpdateTime = 0
	nextClientFireTime = 0
	lastAimLogTime = 0

	-- Reset freelook
	freelookActive = false
	freelookYaw = 0
	freelookPitch = 0

	-- Ghost arc: reset timer so first ghost fires after a brief delay
	ghostTimer = GHOST_ARC_INTERVAL - 0.5
	cleanupGhostArc()

	-- Bind inputs
	ContextActionService:BindAction(FIRE_ACTION, onFireAction, false, Enum.UserInputType.MouseButton1)
	ContextActionService:BindAction(EXIT_ACTION, onExitAction, false, Enum.KeyCode.F)
	ContextActionService:BindAction(ZOOM_ACTION, onZoomAction, false, Enum.UserInputType.MouseButton2)
	ContextActionService:BindAction(AIM_W_ACTION, makeKeyAction(function(v) wHeld = v end), false, Enum.KeyCode.W)
	ContextActionService:BindAction(AIM_S_ACTION, makeKeyAction(function(v) sHeld = v end), false, Enum.KeyCode.S)
	ContextActionService:BindAction(AIM_A_ACTION, makeKeyAction(function(v) aHeld = v end), false, Enum.KeyCode.A)
	ContextActionService:BindAction(AIM_D_ACTION, makeKeyAction(function(v) dHeld = v end), false, Enum.KeyCode.D)
	ContextActionService:BindAction(SHIFT_ACTION, makeKeyAction(function(v) shiftHeld = v end), false, Enum.KeyCode.LeftShift)

	-- Start render loop
	if stepConnection == nil then
		stepConnection = RunService.RenderStepped:Connect(updateArtilleryAndCamera)
	end

	-- Show HUD
	if combatHUDModule ~= nil then
		combatHUDModule.showCrosshair(true)
		combatHUDModule.showArtillery(true)
		combatHUDModule.showAmmo(true)
		combatHUDModule.showHeat(false)

		local entityId = entityModel:GetAttribute("EntityId")
		if type(entityId) == "string" then
			combatHUDModule.showHP(entityId)
		end
	end

	print(string.format("[P7_ARTILLERY] activated entity=%s", tostring(entityModel:GetAttribute("EntityId"))))
end

local function deactivateArtilleryMode()
	local wasActive = activeArtilleryModel ~= nil

	ContextActionService:UnbindAction(FIRE_ACTION)
	ContextActionService:UnbindAction(EXIT_ACTION)
	ContextActionService:UnbindAction(ZOOM_ACTION)
	ContextActionService:UnbindAction(AIM_W_ACTION)
	ContextActionService:UnbindAction(AIM_S_ACTION)
	ContextActionService:UnbindAction(AIM_A_ACTION)
	ContextActionService:UnbindAction(AIM_D_ACTION)
	ContextActionService:UnbindAction(SHIFT_ACTION)

	if stepConnection ~= nil then
		stepConnection:Disconnect()
		stepConnection = nil
	end

	if wasActive then
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true

		local camera = workspace.CurrentCamera
		if camera ~= nil then
			camera.FieldOfView = baseFov
			camera.CameraType = Enum.CameraType.Custom
			local character = localPlayer.Character
			if character ~= nil then
				local humanoid = character:FindFirstChildOfClass("Humanoid")
				if humanoid ~= nil then
					camera.CameraSubject = humanoid
				end
			end
		end

		if combatHUDModule ~= nil then
			combatHUDModule.showCrosshair(false)
			combatHUDModule.showArtillery(false)
			combatHUDModule.showAmmo(false)
			combatHUDModule.hideHP()
		end

		print("[P7_ARTILLERY] deactivated")
	end

	-- Clean up ghost arc, freelook, and driven parts
	cleanupGhostArc()
	ghostTimer = 0
	freelookActive = false
	freelookYaw = 0
	freelookPitch = 0
	clearDrivenParts()

	activeArtilleryModel = nil
	activeSeat = nil
	activeWeaponMount = nil
	activeCameraPoint = nil
	wHeld = false
	sHeld = false
	aHeld = false
	dHeld = false
	shiftHeld = false
	zoomHeld = false
	zoomBlend = 0
end

local function onHumanoidSeated(isSeated: boolean, seatPart: BasePart?)
	if isSeated and seatPart ~= nil and CollectionService:HasTag(seatPart, "ArtillerySeat") then
		activateArtilleryMode(seatPart)
		return
	end

	if activeArtilleryModel ~= nil then
		deactivateArtilleryMode()
	end
end

local function bindCharacter(character: Model)
	deactivateArtilleryMode()

	if seatedConnection ~= nil then
		seatedConnection:Disconnect()
		seatedConnection = nil
	end

	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	seatedConnection = humanoid.Seated:Connect(onHumanoidSeated)

	if humanoid.SeatPart ~= nil and CollectionService:HasTag(humanoid.SeatPart, "ArtillerySeat") then
		activateArtilleryMode(humanoid.SeatPart)
	end
end

function ArtilleryClient.init(remotes: Folder, hudModule: any)
	fireWeaponRemote = remotes:WaitForChild("FireWeapon") :: RemoteEvent
	updateTurretAimRemote = remotes:WaitForChild("UpdateTurretAim") :: RemoteEvent
	combatHUDModule = hudModule

	if characterAddedConnection == nil then
		characterAddedConnection = localPlayer.CharacterAdded:Connect(bindCharacter)
	end

	local existingCharacter = localPlayer.Character
	if existingCharacter ~= nil then
		bindCharacter(existingCharacter)
	end

	print("[P7_CONFIG] ArtilleryClient initialized")
end

function ArtilleryClient.isActive(): boolean
	return activeArtilleryModel ~= nil
end

return ArtilleryClient
