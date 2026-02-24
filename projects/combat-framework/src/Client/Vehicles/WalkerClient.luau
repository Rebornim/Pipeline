--!strict

local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local localPlayer = Players.LocalPlayer
local playerScripts = localPlayer:WaitForChild("PlayerScripts")
local clientRoot = playerScripts:WaitForChild("CombatFramework")

local sharedRoot = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatConfig = require(sharedRoot:WaitForChild("CombatConfig"))
local CombatTypes = require(sharedRoot:WaitForChild("CombatTypes"))
local WeaponRig = require(sharedRoot:WaitForChild("WeaponRig"))

local CombatHUD = require(clientRoot:WaitForChild("HUD"):WaitForChild("CombatHUD"))
local TargetingClient = require(clientRoot:WaitForChild("Targeting"):WaitForChild("TargetingClient"))
local RemoteVehicleSmoother = require(clientRoot:WaitForChild("Vehicles"):WaitForChild("RemoteVehicleSmoother"))
local VehicleCamera = require(clientRoot:WaitForChild("Vehicles"):WaitForChild("VehicleCamera"))
local WalkerIK = require(clientRoot:WaitForChild("Vehicles"):WaitForChild("WalkerIK"))
local SoundProfileLoader = require(clientRoot:WaitForChild("Vehicles"):WaitForChild("SoundProfiles"):WaitForChild("SoundProfileLoader"))
local SoundProfileTypes = require(clientRoot:WaitForChild("Vehicles"):WaitForChild("SoundProfiles"):WaitForChild("SoundProfileTypes"))

type VehicleConfig = CombatTypes.VehicleConfig
type VehicleInputPayload = CombatTypes.VehicleInputPayload

local WalkerClient = {}

local EXIT_ACTION_NAME = "CombatExitWalker"
local LOCK_ACTION_NAME = "CombatWalkerLock"

local vehicleInputRemote: RemoteEvent? = nil
local vehicleExitRemote: RemoteEvent? = nil
local renderConnection: RBXScriptConnection? = nil
local scrollConnection: RBXScriptConnection? = nil

local activeEntityId: string? = nil
local activeModel: Model? = nil
local activeConfig: VehicleConfig? = nil
local activeHeadPart: BasePart? = nil
local activeHeadBaseOffset: CFrame? = nil
local activeHeadFollowerOffsets: { { part: BasePart, offset: CFrame } } = {}
local activeWeaponMountStates: { { mount: BasePart, neutralOffsetFromHead: CFrame } } = {}
local activeIKState: WalkerIK.WalkerIKState? = nil
local activeLegParts: {
	leftStrut1: BasePart?,
	leftStrut2: BasePart?,
	leftUpper: BasePart?,
	leftLower: BasePart?,
	leftFoot: BasePart?,
	rightStrut1: BasePart?,
	rightStrut2: BasePart?,
	rightUpper: BasePart?,
	rightLower: BasePart?,
	rightFoot: BasePart?,
}? = nil
local activeRayParams: RaycastParams? = nil
local activeDriverSeat: BasePart? = nil
local seatCharacterOffset: CFrame? = nil
local seatOffsetNeedsRecalc: boolean = false
local ikPrevPosition: Vector3? = nil
local smoothedBodyPos: Vector3? = nil
local lastWrittenPos: Vector3? = nil
local serverTargetPos: Vector3? = nil
type LegVisualState = {
	source: BasePart,
	visual: BasePart,
}
type LegPoseSnapshot = {
	time: number,
	poses: { [BasePart]: CFrame },
}
local legVisualStateByPart: { [BasePart]: LegVisualState } = {}
local legSourceTransparency: { [BasePart]: number } = {}
local legVisualsFolder: Folder? = nil
local legPoseSnapshots: { LegPoseSnapshot } = {}

local inputAccumulator: number = 0
local savedMouseBehavior: Enum.MouseBehavior? = nil
local savedMouseIconEnabled: boolean? = nil
local freelookActive: boolean = false

local virtualCursorX: number = 0
local virtualCursorY: number = 0
local smoothedAimYaw: number? = nil

-- Sound profile state
local activeProfileController: SoundProfileTypes.ProfileController? = nil
local previousHpFraction: number = 1
local previousAimYaw: number? = nil
local headTurning: boolean = false
local HEAD_TURN_START_THRESHOLD = 0.25 -- rad/s to start turning sound (ignores slow/micro turns)
local HEAD_TURN_STOP_THRESHOLD = 0.08 -- rad/s to stop (hysteresis)
local HEAD_STOP_COOLDOWN = 1.5 -- min seconds between head stop sounds
local lastHeadStopTick: number = 0
local previousGaitActive: boolean = false
local previousGaitSide: string = "left"
local settleStepsRemaining: number = 0
local previousFootLiftSeq: number? = nil
local previousFootPlantSeq: number? = nil

-- Walker weapon state
local activeVehicleHasWeapon: boolean = false
local fireWeaponRemote: RemoteEvent? = nil
local updateTurretAimRemote: RemoteEvent? = nil
local fireSoundPool: { Sound } = {}
local fireSoundIndex: number = 1
local FIRE_POOL_SIZE: number = 6
local WALKER_AIM_MAX_ELEVATION = 15 -- degrees up/down from horizontal
local WALKER_ZOOM_FOV_REDUCTION = 14
local WALKER_ZOOM_IN_RATE = 14
local WALKER_ZOOM_OUT_RATE = 10
local walkerFireInterval: number = 0
local lastWalkerFireTick: number = 0
local lastWalkerHeatRecoverCueId: number = 0
local walkerFireCount: number = 0
local walkerFireErrors: number = 0
local walkerAimRayParams: RaycastParams? = nil
local walkerFireButtonHeld: boolean = false
local walkerBurstCount: number = 1
local walkerBurstInterval: number = 0
local walkerZoomBlend: number = 0
local walkerCrosshairSmoothedPos: Vector2? = nil
local WALKER_CROSSHAIR_SMOOTH_RATE = 14
local WALKER_CROSSHAIR_DEADZONE_PX = 2.0
local WALKER_AIM_SEND_RATE = 30
local WALKER_AIM_SEND_REFRESH = 0.2
local WALKER_AIM_SEND_ANGLE_EPS = math.rad(0.35)
local lastWalkerAimSendTick: number = 0
local lastWalkerAimDirection: Vector3? = nil

local lastSentThrottle: number = 0
local lastSentStrafe: number = 0
local lastSentSteerX: number = 0
local lastSentTick: number = 0
local INPUT_REFRESH_INTERVAL = 1.0
local INPUT_STEER_DEADBAND = 0.02
local LEG_VISUAL_INTERP_DELAY = 1 / 24
local LEG_VISUAL_SERVER_POS_EPS = 0.002
local LEG_VISUAL_SERVER_ANGLE_EPS = math.rad(0.08)

local function destroyFireSoundPool()
	for _, sound in ipairs(fireSoundPool) do
		sound:Destroy()
	end
	table.clear(fireSoundPool)
	fireSoundIndex = 1
end

local function buildFireSoundPool(model: Model, defaultGroupKey: string?)
	destroyFireSoundPool()

	local groupKey = defaultGroupKey
	local raw = model:GetAttribute("FireSound")
	if type(raw) == "string" and raw ~= "" then
		groupKey = raw
	end
	if type(groupKey) ~= "string" or groupKey == "" then
		if model:GetAttribute("VehicleCategory") == "walker_biped" then
			groupKey = "walker"
		else
			return
		end
	end

	local group = CombatConfig.WeaponSounds[groupKey]
	if type(group) ~= "table" and type(defaultGroupKey) == "string" and string.find(string.lower(defaultGroupKey), "walker") ~= nil then
		group = CombatConfig.WeaponSounds.walker
	end
	if type(group) ~= "table" then
		return
	end

	local entry = (group :: any).fire
	local rawVolume = (group :: any).fireVolume
	local volume: number = if type(rawVolume) == "number" then rawVolume else 1
	local soundIds: { string } = {}
	if type(entry) == "string" and entry ~= "" then
		table.insert(soundIds, entry)
	elseif type(entry) == "table" then
		for _, id in ipairs(entry) do
			if type(id) == "string" and id ~= "" then
				table.insert(soundIds, id)
			end
		end
	end
	if #soundIds == 0 then
		return
	end

	local parent: Instance = if model.PrimaryPart ~= nil then model.PrimaryPart else model
	for _ = 1, FIRE_POOL_SIZE do
		for _, soundId in ipairs(soundIds) do
			local sound = Instance.new("Sound")
			sound.SoundId = soundId
			sound.Volume = volume
			sound.Looped = false
			sound.Parent = parent
			table.insert(fireSoundPool, sound)
		end
	end
end

local function playFireSound()
	if #fireSoundPool == 0 then
		return
	end
	local sound = fireSoundPool[fireSoundIndex]
	fireSoundIndex += 1
	if fireSoundIndex > #fireSoundPool then
		fireSoundIndex = 1
	end
	sound.TimePosition = 0
	sound:Play()
end

local function playBurstFireSounds()
	local count = math.max(1, walkerBurstCount)
	local interval = math.max(0, walkerBurstInterval)
	playFireSound()
	if count <= 1 then
		return
	end
	for shotIndex = 2, count do
		local delaySeconds = (shotIndex - 1) * interval
		task.delay(delaySeconds, playFireSound)
	end
end

local function updateWalkerWeaponHUD(model: Model)
	local heatValue = model:GetAttribute("WeaponHeat")
	local heatMaxAttr = model:GetAttribute("WeaponHeatMax")
	local maxHeat = if type(heatMaxAttr) == "number" and heatMaxAttr > 0 then heatMaxAttr else 100
	local overheated = model:GetAttribute("WeaponOverheated") == true
	local displayHeat = 0
	if type(heatValue) == "number" then
		displayHeat = math.clamp(heatValue, 0, maxHeat)
		local heatDecayPerSecond = model:GetAttribute("WeaponHeatDecayPerSecond")
		local heatUpdatedAt = model:GetAttribute("WeaponHeatUpdatedAt")
		if type(heatDecayPerSecond) == "number" and heatDecayPerSecond > 0 and type(heatUpdatedAt) == "number" then
			local elapsed = math.max(0, Workspace:GetServerTimeNow() - heatUpdatedAt)
			local coolingRate = heatDecayPerSecond / maxHeat
			displayHeat = math.max(0, displayHeat * math.exp(-coolingRate * elapsed))
		end
	end
	CombatHUD.setWeaponHeat(displayHeat, maxHeat, overheated)

	local cueId = model:GetAttribute("WeaponHeatRecoverCueId")
	if type(cueId) == "number" then
		local cueCounter = math.floor(cueId)
		if cueCounter > lastWalkerHeatRecoverCueId then
			lastWalkerHeatRecoverCueId = cueCounter
			CombatHUD.onWeaponRecoveredCue()
		end
	end

	local ammoMaxRaw = model:GetAttribute("WeaponAmmoMax")
	if type(ammoMaxRaw) == "number" and ammoMaxRaw > 0 then
		local ammoRaw = model:GetAttribute("WeaponAmmo")
		local ammoCurrent = if type(ammoRaw) == "number" then ammoRaw else ammoMaxRaw
		CombatHUD.setAmmo(ammoCurrent, ammoMaxRaw)
	end

	local maxShieldRaw = model:GetAttribute("MaxShieldHP")
	if type(maxShieldRaw) == "number" and maxShieldRaw > 0 then
		local shieldRaw = model:GetAttribute("ShieldHP")
		local shieldCurrent = if type(shieldRaw) == "number" then shieldRaw else maxShieldRaw
		CombatHUD.setShield(shieldCurrent, maxShieldRaw)
	end
end

local function computeWalkerAimDirection(aimYaw: number): Vector3
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return Vector3.new(-math.sin(aimYaw), 0, -math.cos(aimYaw)).Unit
	end
	local rangeY = CombatConfig.VehicleMouseRangeY
	if type(rangeY) ~= "number" or rangeY <= 0 then
		rangeY = 0.06
	end
	local maxY = camera.ViewportSize.Y * rangeY
	local yFraction = if maxY > 0 then math.clamp(-virtualCursorY / maxY, -1, 1) else 0
	local elevationRad = math.rad(yFraction * WALKER_AIM_MAX_ELEVATION)
	local cosE = math.cos(elevationRad)
	local sinE = math.sin(elevationRad)
	local flat = Vector3.new(-math.sin(aimYaw), 0, -math.cos(aimYaw))
	return Vector3.new(flat.X * cosE, sinE, flat.Z * cosE).Unit
end

local function findWalkerLegsFolder(model: Model, entityIdOverride: string?): Instance?
	local entityId = entityIdOverride
	if type(entityId) ~= "string" or entityId == "" then
		local attr = model:GetAttribute("EntityId")
		if type(attr) == "string" and attr ~= "" then
			entityId = attr
		end
	end
	if type(entityId) == "string" and entityId ~= "" then
		local byEntityId = Workspace:FindFirstChild(entityId .. "_Legs")
		if byEntityId ~= nil then
			return byEntityId
		end
	end
	return Workspace:FindFirstChild(model.Name .. "_Legs")
end

local function ensureLegVisualsFolder(): Folder
	if legVisualsFolder ~= nil and legVisualsFolder.Parent ~= nil then
		return legVisualsFolder
	end
	local existing = Workspace:FindFirstChild("CombatWalkerLocalLegVisuals")
	if existing ~= nil and existing:IsA("Folder") then
		legVisualsFolder = existing
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "CombatWalkerLocalLegVisuals"
	folder.Parent = Workspace
	legVisualsFolder = folder
	return folder
end

local function clearLegVisualSmoothing()
	for sourcePart, transparency in pairs(legSourceTransparency) do
		pcall(function()
			sourcePart.LocalTransparencyModifier = transparency
		end)
	end
	table.clear(legSourceTransparency)
	for _, state in pairs(legVisualStateByPart) do
		if state.visual.Parent ~= nil then
			state.visual:Destroy()
		end
	end
	table.clear(legVisualStateByPart)
	if legVisualsFolder ~= nil and legVisualsFolder.Parent ~= nil and #legVisualsFolder:GetChildren() == 0 then
		legVisualsFolder:Destroy()
	end
	legVisualsFolder = nil
	table.clear(legPoseSnapshots)
end

local function getCFrameAngleDelta(a: CFrame, b: CFrame): number
	local lookDot = math.clamp(a.LookVector:Dot(b.LookVector), -1, 1)
	local upDot = math.clamp(a.UpVector:Dot(b.UpVector), -1, 1)
	local lookAngle = math.acos(lookDot)
	local upAngle = math.acos(upDot)
	return math.max(lookAngle, upAngle)
end

local function primeLegVisualState(part: BasePart)
	local cf = part.CFrame
	if legSourceTransparency[part] == nil then
		legSourceTransparency[part] = part.LocalTransparencyModifier
	end
	part.LocalTransparencyModifier = 1
	local visual = part:Clone()
	for _, desc in ipairs(visual:GetDescendants()) do
		if desc:IsA("Script") or desc:IsA("LocalScript") or desc:IsA("ModuleScript") then
			desc:Destroy()
		end
	end
	visual.Anchored = true
	visual.CanCollide = false
	visual.CanQuery = false
	visual.CanTouch = false
	visual.Massless = true
	visual.CFrame = cf
	visual.Parent = ensureLegVisualsFolder()
	legVisualStateByPart[part] = {
		source = part,
		visual = visual,
	}
end

local function captureLegSnapshot(now: number)
	local poses: { [BasePart]: CFrame } = {}
	local count = 0
	for sourcePart, state in pairs(legVisualStateByPart) do
		if sourcePart.Parent ~= nil and state.visual.Parent ~= nil then
			poses[sourcePart] = sourcePart.CFrame
			count += 1
		end
	end
	if count == 0 then
		return
	end

	local previousSnapshot = legPoseSnapshots[#legPoseSnapshots]
	if previousSnapshot ~= nil then
		local changed = false
		for sourcePart, nextCF in pairs(poses) do
			local previousCF = previousSnapshot.poses[sourcePart]
			if previousCF == nil then
				changed = true
				break
			end
			local posDelta = (nextCF.Position - previousCF.Position).Magnitude
			local angleDelta = getCFrameAngleDelta(nextCF, previousCF)
			if posDelta > LEG_VISUAL_SERVER_POS_EPS or angleDelta > LEG_VISUAL_SERVER_ANGLE_EPS then
				changed = true
				break
			end
		end
		if not changed then
			return
		end
	end

	table.insert(legPoseSnapshots, {
		time = now,
		poses = poses,
	})
	while #legPoseSnapshots > 4 do
		table.remove(legPoseSnapshots, 1)
	end
end

local function resolveLegSnapshotWindow(renderTime: number): (LegPoseSnapshot, LegPoseSnapshot, number)
	local snapshotCount = #legPoseSnapshots
	if snapshotCount == 1 then
		local single = legPoseSnapshots[1]
		return single, single, 1
	end

	local firstSnapshot = legPoseSnapshots[1]
	local latestSnapshot = legPoseSnapshots[snapshotCount]
	if renderTime <= firstSnapshot.time then
		return firstSnapshot, firstSnapshot, 1
	end
	if renderTime >= latestSnapshot.time then
		local previous = legPoseSnapshots[snapshotCount - 1]
		return previous, latestSnapshot, 1
	end

	for index = 1, snapshotCount - 1 do
		local older = legPoseSnapshots[index]
		local newer = legPoseSnapshots[index + 1]
		if renderTime >= older.time and renderTime <= newer.time then
			local duration = math.max(1 / 240, newer.time - older.time)
			local alpha = math.clamp((renderTime - older.time) / duration, 0, 1)
			return older, newer, alpha
		end
	end

	local fallback = latestSnapshot
	return fallback, fallback, 1
end

local function smoothDriverLegVisuals(_dt: number)
	for sourcePart, state in pairs(legVisualStateByPart) do
		if sourcePart.Parent == nil or state.visual.Parent == nil then
			legVisualStateByPart[sourcePart] = nil
		end
	end
	if next(legVisualStateByPart) == nil then
		return
	end

	local now = tick()
	captureLegSnapshot(now)
	if #legPoseSnapshots == 0 then
		return
	end

	local renderTime = now - LEG_VISUAL_INTERP_DELAY
	local olderSnapshot, newerSnapshot, alpha = resolveLegSnapshotWindow(renderTime)
	for sourcePart, state in pairs(legVisualStateByPart) do
		local olderCF = olderSnapshot.poses[sourcePart]
		local newerCF = newerSnapshot.poses[sourcePart]
		local visualCF: CFrame
		if olderCF ~= nil and newerCF ~= nil then
			visualCF = olderCF:Lerp(newerCF, alpha)
		elseif newerCF ~= nil then
			visualCF = newerCF
		elseif olderCF ~= nil then
			visualCF = olderCF
		else
			visualCF = sourcePart.CFrame
		end
		state.visual.CFrame = visualCF
	end
end

local function updateWalkerCrosshairPosition(model: Model, aimDirection: Vector3, dt: number)
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end

	local flatForward = Vector3.new(aimDirection.X, 0, aimDirection.Z)
	if flatForward.Magnitude < 1e-4 then
		return
	end
	local forward = flatForward.Unit
	local origin = model:GetPivot().Position + forward * 8
	if activeHeadPart ~= nil then
		origin = (activeHeadPart :: BasePart).Position + forward * 4
	end

	if walkerAimRayParams == nil then
		walkerAimRayParams = RaycastParams.new()
		walkerAimRayParams.FilterType = Enum.RaycastFilterType.Exclude
		walkerAimRayParams.IgnoreWater = true
	end
	local filterList: { Instance } = { model }
	local legsFolder = findWalkerLegsFolder(model, nil)
	if legsFolder ~= nil then
		table.insert(filterList, legsFolder)
	end
	local localCharacter = localPlayer.Character
	if localCharacter ~= nil then
		table.insert(filterList, localCharacter)
	end
	walkerAimRayParams.FilterDescendantsInstances = filterList

	local maxDist = 1000
	local result = Workspace:Raycast(origin, aimDirection * maxDist, walkerAimRayParams)
	local hitPoint = if result ~= nil then result.Position else origin + aimDirection * maxDist
	local screenPos, onScreen = camera:WorldToViewportPoint(hitPoint)
	if onScreen then
		local targetPos = Vector2.new(screenPos.X, screenPos.Y)
		if walkerCrosshairSmoothedPos == nil then
			walkerCrosshairSmoothedPos = targetPos
		else
			local delta = targetPos - (walkerCrosshairSmoothedPos :: Vector2)
			if delta.Magnitude > WALKER_CROSSHAIR_DEADZONE_PX then
				local alpha = 1 - math.exp(-WALKER_CROSSHAIR_SMOOTH_RATE * math.clamp(dt, 1 / 240, 1 / 20))
				walkerCrosshairSmoothedPos = (walkerCrosshairSmoothedPos :: Vector2):Lerp(targetPos, math.clamp(alpha, 0, 1))
			end
		end
		CombatHUD.setCrosshairPosition(walkerCrosshairSmoothedPos :: Vector2)
	end
end

local function applyLocalWalkerMountAim(headCFrame: CFrame, desiredDirection: Vector3?)
	for _, mountState in ipairs(activeWeaponMountStates) do
		local mount = mountState.mount
		if mount.Parent == nil then
			continue
		end
		local neutralFrame = headCFrame * mountState.neutralOffsetFromHead
		local heldDirection = WeaponRig.getCurrentAimDirection(mount)
		mount.CFrame = neutralFrame * WeaponRig.getMountAimOffset(mount)
		local direction = desiredDirection
		if direction == nil or direction.Magnitude < 1e-4 then
			direction = heldDirection
		end
		if direction.Magnitude < 1e-4 then
			continue
		end
		local clamped = WeaponRig.clampDirectionToMountLimits(mount, neutralFrame, direction.Unit)
		if clamped.Magnitude > 1e-4 then
			mount.CFrame = WeaponRig.getAimFrame(mount, clamped)
		end
	end
end

local function getInputRate(): number
	local raw = CombatConfig.VehicleInputRate
	if type(raw) ~= "number" or raw <= 0 then
		return 20
	end
	return raw
end

local function activateMouse()
	savedMouseBehavior = UserInputService.MouseBehavior
	savedMouseIconEnabled = UserInputService.MouseIconEnabled
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	UserInputService.MouseIconEnabled = false
end

local function restoreMouse()
	UserInputService.MouseBehavior = savedMouseBehavior or Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = if savedMouseIconEnabled ~= nil then savedMouseIconEnabled else true
	savedMouseBehavior = nil
	savedMouseIconEnabled = nil
end

local function onExitAction(_name: string, inputState: Enum.UserInputState, _inputObject: InputObject): Enum.ContextActionResult
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end

	if vehicleExitRemote ~= nil and activeEntityId ~= nil then
		vehicleExitRemote:FireServer()
	end

	return Enum.ContextActionResult.Sink
end

function WalkerClient.activate(model: Model, entityId: string, config: VehicleConfig): ()
	if activeEntityId == entityId then
		return
	end

	WalkerClient.deactivate()

	activeEntityId = entityId
	activeModel = model
	activeConfig = config
	smoothedAimYaw = nil
	RemoteVehicleSmoother.setLocalVehicle(model)

	-- Find head part and driver seat
	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("BasePart") and CollectionService:HasTag(desc, "WalkerHead") then
			activeHeadPart = desc :: BasePart
		end
		if (desc:IsA("Seat") or desc:IsA("VehicleSeat")) and CollectionService:HasTag(desc, "DriverSeat") then
			activeDriverSeat = desc :: BasePart
		end
	end

	-- Compute head offset relative to PrimaryPart for cockpit rotation
	if activeHeadPart ~= nil and model.PrimaryPart ~= nil then
		activeHeadBaseOffset = model.PrimaryPart.CFrame:Inverse() * activeHeadPart.CFrame
		for _, descendant in ipairs((activeHeadPart :: BasePart):GetDescendants()) do
			if descendant:IsA("BasePart") then
				local part = descendant :: BasePart
				if CollectionService:HasTag(part, "WeaponMount") then
					local neutralWorld = WeaponRig.getNeutralAimFrame(part)
					local neutralOffsetFromHead = (activeHeadPart :: BasePart).CFrame:Inverse() * neutralWorld
					table.insert(activeWeaponMountStates, { mount = part, neutralOffsetFromHead = neutralOffsetFromHead })
				else
					local offset = (activeHeadPart :: BasePart).CFrame:Inverse() * part.CFrame
					table.insert(activeHeadFollowerOffsets, { part = part, offset = offset })
				end
			end
		end
	end

	-- Capture character offset relative to seat for stable rider positioning.
	-- Keep seat weld active (no anchoring), but suppress humanoid self-movement.
	seatOffsetNeedsRecalc = true
	if model.PrimaryPart ~= nil then
		local character = localPlayer.Character
		if character ~= nil then
			local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if hrp ~= nil then
				if activeDriverSeat ~= nil and activeDriverSeat.Parent ~= nil then
					seatCharacterOffset = (activeDriverSeat :: BasePart).CFrame:Inverse() * hrp.CFrame
				else
					seatCharacterOffset = model.PrimaryPart.CFrame:Inverse() * hrp.CFrame
				end
				hrp.AssemblyLinearVelocity = Vector3.zero
				hrp.AssemblyAngularVelocity = Vector3.zero
			end
		end
	end

	-- Find leg parts (server reparents them to Workspace/<name>_Legs)
	local legsFolder = findWalkerLegsFolder(model, entityId)
	if legsFolder == nil then
		-- Fallback: try inside model (in case server hasn't reparented yet)
		legsFolder = model
	end
	local leftLegFolder = legsFolder:FindFirstChild("LeftLeg")
	local rightLegFolder = legsFolder:FindFirstChild("RightLeg")
	if leftLegFolder ~= nil and rightLegFolder ~= nil then
		activeLegParts = {
			leftStrut1 = leftLegFolder:FindFirstChild("Strut1") :: BasePart?,
			leftStrut2 = leftLegFolder:FindFirstChild("HipStrut") :: BasePart?,
			leftUpper = leftLegFolder:FindFirstChild("UpperLeg") :: BasePart?,
			leftLower = leftLegFolder:FindFirstChild("LowerLeg") :: BasePart?,
			leftFoot = leftLegFolder:FindFirstChild("Foot") :: BasePart?,
			rightStrut1 = rightLegFolder:FindFirstChild("Strut1") :: BasePart?,
			rightStrut2 = rightLegFolder:FindFirstChild("HipStrut") :: BasePart?,
			rightUpper = rightLegFolder:FindFirstChild("UpperLeg") :: BasePart?,
			rightLower = rightLegFolder:FindFirstChild("LowerLeg") :: BasePart?,
			rightFoot = rightLegFolder:FindFirstChild("Foot") :: BasePart?,
		}
		clearLegVisualSmoothing()
		local legs = activeLegParts
		if legs.leftStrut1 ~= nil then primeLegVisualState(legs.leftStrut1 :: BasePart) end
		if legs.leftStrut2 ~= nil then primeLegVisualState(legs.leftStrut2 :: BasePart) end
		if legs.leftUpper ~= nil then primeLegVisualState(legs.leftUpper :: BasePart) end
		if legs.leftLower ~= nil then primeLegVisualState(legs.leftLower :: BasePart) end
		if legs.leftFoot ~= nil then primeLegVisualState(legs.leftFoot :: BasePart) end
		if legs.rightStrut1 ~= nil then primeLegVisualState(legs.rightStrut1 :: BasePart) end
		if legs.rightStrut2 ~= nil then primeLegVisualState(legs.rightStrut2 :: BasePart) end
		if legs.rightUpper ~= nil then primeLegVisualState(legs.rightUpper :: BasePart) end
		if legs.rightLower ~= nil then primeLegVisualState(legs.rightLower :: BasePart) end
		if legs.rightFoot ~= nil then primeLegVisualState(legs.rightFoot :: BasePart) end
	else
		clearLegVisualSmoothing()
	end

	-- Create IK state and raycast params
	activeIKState = WalkerIK.createState()
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.IgnoreWater = true
	local filterList: { Instance } = { model }
	local localCharacter = localPlayer.Character
	if localCharacter ~= nil then
		table.insert(filterList, localCharacter)
	end
	if legsFolder ~= nil and legsFolder ~= model then
		table.insert(filterList, legsFolder)
	end
	rayParams.FilterDescendantsInstances = filterList
	activeRayParams = rayParams

	virtualCursorX = 0
	virtualCursorY = 0
	inputAccumulator = 0
	lastSentThrottle = 0
	lastSentStrafe = 0
	lastSentSteerX = 0
	lastSentTick = 0
	freelookActive = false
	activeVehicleHasWeapon = false
	walkerFireInterval = 0
	lastWalkerFireTick = 0
	lastWalkerHeatRecoverCueId = 0
	walkerAimRayParams = nil
	walkerFireCount = 0
	walkerFireErrors = 0
	walkerFireButtonHeld = false
	walkerBurstCount = 1
	walkerBurstInterval = 0
	walkerZoomBlend = 0
	walkerCrosshairSmoothedPos = nil
	destroyFireSoundPool()

	-- Weapon detection and local fire/SFX setup
	local weaponId: string? = nil
	local effectiveClass = model:GetAttribute("EffectiveWeaponClass")
	if type(effectiveClass) == "string" and effectiveClass ~= "" then
		activeVehicleHasWeapon = true
	end
	local entityConfigId = model:GetAttribute("ConfigId")
	if type(entityConfigId) == "string" then
		local entityConfig = CombatConfig.Entities[entityConfigId]
		if entityConfig ~= nil and type(entityConfig.weaponId) == "string" then
			weaponId = entityConfig.weaponId
			activeVehicleHasWeapon = true
		end
	end
	local fireRate = model:GetAttribute("EffectiveWeaponFireRate")
	if type(fireRate) ~= "number" or fireRate <= 0 then
		if weaponId ~= nil then
			local weaponConfig = CombatConfig.Weapons[weaponId]
			if weaponConfig ~= nil and type(weaponConfig.fireRate) == "number" and weaponConfig.fireRate > 0 then
				fireRate = weaponConfig.fireRate
			end
		end
	end
	if type(fireRate) == "number" and fireRate > 0 then
		walkerFireInterval = 1 / fireRate
	end
	local burstCountRaw = model:GetAttribute("EffectiveWeaponBurstCount")
	if type(burstCountRaw) == "number" then
		walkerBurstCount = math.max(1, math.floor(burstCountRaw + 0.5))
	elseif weaponId ~= nil then
		local weaponConfig = CombatConfig.Weapons[weaponId]
		if weaponConfig ~= nil and type(weaponConfig.burstCount) == "number" then
			walkerBurstCount = math.max(1, math.floor(weaponConfig.burstCount + 0.5))
		end
	end
	local burstIntervalRaw = model:GetAttribute("EffectiveWeaponBurstInterval")
	if type(burstIntervalRaw) == "number" then
		walkerBurstInterval = math.max(0, burstIntervalRaw)
	elseif weaponId ~= nil then
		local weaponConfig = CombatConfig.Weapons[weaponId]
		if weaponConfig ~= nil and type(weaponConfig.burstInterval) == "number" then
			walkerBurstInterval = math.max(0, weaponConfig.burstInterval)
		end
	end
	buildFireSoundPool(model, weaponId)

	activateMouse()
	CombatHUD.setZoomVignette(0)
	VehicleCamera.setExternalFOVOffset(0)

	-- Camera
	VehicleCamera.activate(model, config)

	-- Sound profile
	previousHpFraction = 1
	previousAimYaw = nil
	headTurning = false
	lastHeadStopTick = 0
	previousGaitActive = false
	previousGaitSide = "left"
	settleStepsRemaining = 0
	local footLiftSeqAttr = model:GetAttribute("WalkerAudioFootLiftSeq")
	local footPlantSeqAttr = model:GetAttribute("WalkerAudioFootPlantSeq")
	previousFootLiftSeq = if type(footLiftSeqAttr) == "number" then math.max(0, math.floor(footLiftSeqAttr + 0.5)) else nil
	previousFootPlantSeq = if type(footPlantSeqAttr) == "number" then math.max(0, math.floor(footPlantSeqAttr + 0.5)) else nil
	if model.PrimaryPart ~= nil then
		activeProfileController = SoundProfileLoader.createController(model, model.PrimaryPart, config.maxSpeed, true)
	end

	-- HUD
	CombatHUD.showHP(entityId)
	CombatHUD.showSpeed(true)
	CombatHUD.showVehicleCursor(true)
	if activeVehicleHasWeapon then
		CombatHUD.showCrosshair(true)
		local ammoMax = model:GetAttribute("WeaponAmmoMax")
		if type(ammoMax) == "number" and ammoMax > 0 then
			CombatHUD.showAmmo(true)
			CombatHUD.showHeat(false)
		else
			CombatHUD.showHeat(true)
			CombatHUD.showAmmo(false)
		end
		local maxShield = model:GetAttribute("MaxShieldHP")
		if type(maxShield) == "number" and maxShield > 0 then
			CombatHUD.showShield(true)
		else
			CombatHUD.showShield(false)
		end
	else
		CombatHUD.showCrosshair(false)
		CombatHUD.showHeat(false)
		CombatHUD.showAmmo(false)
		CombatHUD.showShield(false)
	end

	-- Input loop
	local sendInterval = 1 / getInputRate()
	renderConnection = RunService.RenderStepped:Connect(function(dt)
		if activeEntityId == nil or activeModel == nil then
			return
		end

		local mdl = activeModel :: Model
		if mdl.Parent == nil then
			WalkerClient.deactivate()
			return
		end

		local cfg = activeConfig :: VehicleConfig
		local frameAimDirection: Vector3? = nil

		-- Freelook toggle (ALT)
		local altHeld = UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt)
		if altHeld and not freelookActive then
			freelookActive = true
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			UserInputService.MouseIconEnabled = true
			VehicleCamera.setFreelook(true)
			CombatHUD.showVehicleCursor(false)
		elseif not altHeld and freelookActive then
			freelookActive = false
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
			UserInputService.MouseIconEnabled = false
			VehicleCamera.setFreelook(false)
			virtualCursorX = 0
			virtualCursorY = 0
			CombatHUD.showVehicleCursor(true)
		end

		-- Virtual cursor (same system as vehicles)
		if not freelookActive then
			local mouseDelta = UserInputService:GetMouseDelta()
			local sensitivity = CombatConfig.VehicleMouseSensitivity
			if type(sensitivity) ~= "number" or sensitivity <= 0 then
				sensitivity = 0.7
			end

			virtualCursorX += mouseDelta.X * sensitivity
			virtualCursorY += mouseDelta.Y * sensitivity

			local camera = Workspace.CurrentCamera
			if camera ~= nil then
				local rangeX = CombatConfig.VehicleMouseRangeX
				if type(rangeX) ~= "number" or rangeX <= 0 then
					rangeX = 0.18
				end
				local rangeY = CombatConfig.VehicleMouseRangeY
				if type(rangeY) ~= "number" or rangeY <= 0 then
					rangeY = 0.06
				end

				local maxX = camera.ViewportSize.X * rangeX
				local maxY = camera.ViewportSize.Y * rangeY
				virtualCursorX = math.clamp(virtualCursorX, -maxX, maxX)
				virtualCursorY = math.clamp(virtualCursorY, -maxY, maxY)

				-- Auto-center (walker uses its own faster rate)
				local centeringRate = CombatConfig.WalkerMouseCenteringRate
				if type(centeringRate) ~= "number" or centeringRate <= 0 then
					centeringRate = 4.0
				end
				local deflectionX = if maxX > 0 then math.abs(virtualCursorX) / maxX else 0
				local centerStrengthX = math.clamp(1 - deflectionX / 0.9, 0, 1)
				local centerAlpha = 1 - math.exp(-centeringRate * dt)
				virtualCursorX -= virtualCursorX * centerAlpha * centerStrengthX

				local screenCenter = camera.ViewportSize * 0.5
				CombatHUD.setCursorDotPosition(Vector2.new(screenCenter.X + virtualCursorX, screenCenter.Y + virtualCursorY))

				-- Cursor X drives steerX (normalized -1..1)
				local steerFractionX = if maxX > 0 then math.clamp(virtualCursorX / maxX, -1, 1) else 0

				-- Derive aimYaw from body heading + cursor offset
				local bodyHeading = mdl:GetAttribute("VehicleHeading")
				if type(bodyHeading) ~= "number" then
					bodyHeading = 0
				end
				local maxAimArc = math.rad(cfg.headYawMax or 120)
				local aimYaw = (bodyHeading :: number) - steerFractionX * maxAimArc
				-- Cockpit rotation happens after IK (rotates entire PrimaryPart)
			end
		elseif freelookActive then
			local rmbHeld = UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
			if rmbHeld then
				UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
				local delta = UserInputService:GetMouseDelta()
				VehicleCamera.addFreelookInput(delta.X, delta.Y)
			else
				UserInputService.MouseBehavior = Enum.MouseBehavior.Default
				UserInputService.MouseIconEnabled = true
			end
		end

		-- WASD input
		local throttle = 0
		if UserInputService:IsKeyDown(Enum.KeyCode.W) then
			throttle = 1
		elseif UserInputService:IsKeyDown(Enum.KeyCode.S) then
			throttle = -1
		end

		local strafe = 0
		if UserInputService:IsKeyDown(Enum.KeyCode.A) then
			strafe = -1
		elseif UserInputService:IsKeyDown(Enum.KeyCode.D) then
			strafe = 1
		end

		local sprint = throttle > 0 and UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)

		-- steerX from virtual cursor (for network payload)
		local steerX = 0
		local aimYaw = mdl:GetAttribute("VehicleHeading") or 0
		do
			local camera = Workspace.CurrentCamera
			if camera ~= nil then
				local rangeX = CombatConfig.VehicleMouseRangeX
				if type(rangeX) ~= "number" or rangeX <= 0 then
					rangeX = 0.18
				end
				local maxX = camera.ViewportSize.X * rangeX
				steerX = if maxX > 0 then math.clamp(virtualCursorX / maxX, -1, 1) else 0

				local bodyHeading = mdl:GetAttribute("VehicleHeading")
				if type(bodyHeading) ~= "number" then
					bodyHeading = 0
				end
				local maxAimArc = math.rad((activeConfig :: VehicleConfig).headYawMax or 120)
				aimYaw = (bodyHeading :: number) - steerX * maxAimArc
			end
		end

		-- Update speed HUD
		local speed = mdl:GetAttribute("VehicleSpeed")
		if type(speed) == "number" then
			CombatHUD.setSpeed(speed)
		else
			CombatHUD.setSpeed(0)
		end

		if activeVehicleHasWeapon then
			updateWalkerWeaponHUD(mdl)
			local zoomHeld = (not freelookActive) and UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
			local zoomTarget = if zoomHeld then 1 else 0
			local zoomRate = if zoomTarget > walkerZoomBlend then WALKER_ZOOM_IN_RATE else WALKER_ZOOM_OUT_RATE
			walkerZoomBlend += (zoomTarget - walkerZoomBlend) * math.min(1, dt * zoomRate)
			local zoomFovOffset = -WALKER_ZOOM_FOV_REDUCTION * walkerZoomBlend
			VehicleCamera.setExternalFOVOffset(zoomFovOffset)
			CombatHUD.setZoomVignette(walkerZoomBlend)
				if not freelookActive then
					local aimDirection = computeWalkerAimDirection(aimYaw)
					frameAimDirection = aimDirection
					updateWalkerCrosshairPosition(mdl, aimDirection, dt)
					if updateTurretAimRemote ~= nil then
						local nowAim = tick()
						local sinceLastAimSend = nowAim - lastWalkerAimSendTick
						local interval = 1 / WALKER_AIM_SEND_RATE
						local shouldSend = lastWalkerAimDirection == nil
						if (not shouldSend) and lastWalkerAimDirection ~= nil then
							local dot = math.clamp((lastWalkerAimDirection :: Vector3):Dot(aimDirection), -1, 1)
							local angle = math.acos(dot)
							shouldSend = angle >= WALKER_AIM_SEND_ANGLE_EPS
						end
						if sinceLastAimSend >= interval and (shouldSend or sinceLastAimSend >= WALKER_AIM_SEND_REFRESH) then
							updateTurretAimRemote:FireServer(aimDirection)
							lastWalkerAimSendTick = nowAim
							lastWalkerAimDirection = aimDirection
						end
					end
					local mousePressed = UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
				local justPressed = mousePressed and not walkerFireButtonHeld
				if justPressed then
					local nowFire = tick()
					local canFire = walkerFireInterval <= 0 or (nowFire - lastWalkerFireTick) >= walkerFireInterval
					if canFire then
						lastWalkerFireTick = nowFire
						if fireWeaponRemote ~= nil then
							fireWeaponRemote:FireServer(aimDirection)
							walkerFireCount += 1
							playBurstFireSounds()
						else
							walkerFireErrors += 1
						end
					end
				end
				walkerFireButtonHeld = mousePressed
			else
				walkerFireButtonHeld = UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
			end
		end
			if not activeVehicleHasWeapon then
				walkerZoomBlend = 0
				VehicleCamera.setExternalFOVOffset(0)
				CombatHUD.setZoomVignette(0)
			end

			-- Pilot-side render smoothing over authoritative server pose (no local IK synthesis).
			local torsoCF: CFrame? = nil
			if mdl.PrimaryPart ~= nil then
				local rawBodyCF = mdl.PrimaryPart.CFrame
				local rawBodyPos = rawBodyCF.Position
				if lastWrittenPos ~= nil and (rawBodyPos - (lastWrittenPos :: Vector3)).Magnitude > 0.02 then
					serverTargetPos = rawBodyPos
				elseif serverTargetPos == nil then
					serverTargetPos = rawBodyPos
				end
				if smoothedBodyPos == nil then
					smoothedBodyPos = serverTargetPos :: Vector3
				else
					local bodyAlpha = 1 - math.exp(-18 * dt)
					smoothedBodyPos = (smoothedBodyPos :: Vector3):Lerp(serverTargetPos :: Vector3, bodyAlpha)
				end

				local bodyHeadingAttr = mdl:GetAttribute("VehicleHeading")
				local bodyHeading = if type(bodyHeadingAttr) == "number" then bodyHeadingAttr else 0
				local targetAimYawAttr = mdl:GetAttribute("WalkerAimYaw")
				local targetAimYaw = if type(targetAimYawAttr) == "number" then targetAimYawAttr else bodyHeading
				if smoothedAimYaw == nil then
					smoothedAimYaw = targetAimYaw
				end
				local yawDelta = targetAimYaw - (smoothedAimYaw :: number)
				yawDelta = ((yawDelta + math.pi) % (math.pi * 2)) - math.pi
				local headLagSpeed = 3
				smoothedAimYaw = (smoothedAimYaw :: number) + yawDelta * (1 - math.exp(-headLagSpeed * dt))

					local headingForTilt = bodyHeading
					local horizontalForward = Vector3.new(rawBodyCF.LookVector.X, 0, rawBodyCF.LookVector.Z)
					if horizontalForward.Magnitude > 1e-4 then
						local unitForward = horizontalForward.Unit
						headingForTilt = math.atan2(-unitForward.X, -unitForward.Z)
					end
					local headingFrame = CFrame.new(rawBodyPos) * CFrame.Angles(0, headingForTilt, 0)
					local tiltFrame = headingFrame:Inverse() * rawBodyCF
					local _, tiltPitchRaw, tiltRollRaw = tiltFrame:ToEulerAnglesYXZ()
					local tiltPitch = math.clamp(tiltPitchRaw, math.rad(-35), math.rad(35))
					local tiltRoll = math.clamp(tiltRollRaw, math.rad(-35), math.rad(35))
					torsoCF = CFrame.new(smoothedBodyPos :: Vector3)
						* CFrame.Angles(0, smoothedAimYaw :: number, 0)
						* CFrame.Angles(tiltPitch, 0, tiltRoll)
				mdl.PrimaryPart.CFrame = torsoCF
				lastWrittenPos = smoothedBodyPos :: Vector3
			end

			if activeHeadPart ~= nil and activeHeadBaseOffset ~= nil and torsoCF ~= nil then
				local headBaseCF = CFrame.new((torsoCF :: CFrame).Position) * CFrame.Angles(0, smoothedAimYaw :: number, 0)
				local nextHeadCFrame = headBaseCF * (activeHeadBaseOffset :: CFrame)
				activeHeadPart.CFrame = nextHeadCFrame
				for _, follower in ipairs(activeHeadFollowerOffsets) do
					if follower.part.Parent ~= nil then
						follower.part.CFrame = nextHeadCFrame * follower.offset
					end
				end
				applyLocalWalkerMountAim(nextHeadCFrame, frameAimDirection)
			elseif activeHeadPart ~= nil then
				applyLocalWalkerMountAim(activeHeadPart.CFrame, frameAimDirection)
			end
			smoothDriverLegVisuals(dt)

				if seatOffsetNeedsRecalc and activeDriverSeat ~= nil then
					local character = localPlayer.Character
					if character ~= nil then
						local humanoid = character:FindFirstChildOfClass("Humanoid")
						local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
						if humanoid ~= nil and hrp ~= nil and humanoid.SeatPart == activeDriverSeat then
							seatCharacterOffset = (activeDriverSeat :: BasePart).CFrame:Inverse() * hrp.CFrame
							seatOffsetNeedsRecalc = false
						end
					end
				end

				if seatCharacterOffset ~= nil then
					local character = localPlayer.Character
					if character ~= nil then
						local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
						local anchorCF: CFrame? = nil
						if activeDriverSeat ~= nil and activeDriverSeat.Parent ~= nil then
							anchorCF = (activeDriverSeat :: BasePart).CFrame
						elseif torsoCF ~= nil then
							anchorCF = torsoCF :: CFrame
						end
						if hrp ~= nil and anchorCF ~= nil then
							local targetRootCF = (anchorCF :: CFrame) * (seatCharacterOffset :: CFrame)
							if (hrp.Position - targetRootCF.Position).Magnitude > 0.1 then
								hrp.CFrame = targetRootCF
							end
						end
					end
				end

				if activeProfileController ~= nil then
					local gaitActiveAttr = mdl:GetAttribute("WalkerGaitActive") == true
					local footLiftSeqAttrNow = mdl:GetAttribute("WalkerAudioFootLiftSeq")
					local footPlantSeqAttrNow = mdl:GetAttribute("WalkerAudioFootPlantSeq")
					if type(footLiftSeqAttrNow) == "number" and type(footPlantSeqAttrNow) == "number" then
						local liftSeq = math.max(0, math.floor(footLiftSeqAttrNow + 0.5))
						local plantSeq = math.max(0, math.floor(footPlantSeqAttrNow + 0.5))
						if previousFootLiftSeq == nil then
							previousFootLiftSeq = liftSeq
						end
						if previousFootPlantSeq == nil then
							previousFootPlantSeq = plantSeq
						end
						local liftDelta = math.max(0, liftSeq - (previousFootLiftSeq :: number))
						local plantDelta = math.max(0, plantSeq - (previousFootPlantSeq :: number))
						if liftDelta > 0 then
							for _ = 1, math.min(liftDelta, 4) do
								activeProfileController:onEvent("foot_lift")
							end
						end
						if plantDelta > 0 then
							local plantEvent = if gaitActiveAttr then "foot_plant" else "settle_plant"
							for _ = 1, math.min(plantDelta, 4) do
								activeProfileController:onEvent(plantEvent)
							end
						end
						previousFootLiftSeq = liftSeq
						previousFootPlantSeq = plantSeq
					else
						-- Fallback for legacy walkers without audio sequence attrs.
						local gaitSideAttr = mdl:GetAttribute("WalkerGaitSide")
						local currentGaitSide = if type(gaitSideAttr) == "string" then gaitSideAttr else "left"
						if previousGaitActive and not gaitActiveAttr then
							settleStepsRemaining = 2
						end
						if gaitActiveAttr and previousGaitSide ~= currentGaitSide then
							activeProfileController:onEvent("foot_lift")
							if settleStepsRemaining > 0 then
								settleStepsRemaining -= 1
								activeProfileController:onEvent("settle_plant")
							else
								activeProfileController:onEvent("foot_plant")
							end
						end
						previousGaitActive = gaitActiveAttr
						previousGaitSide = currentGaitSide
					end

					local replicatedAimYaw = mdl:GetAttribute("WalkerAimYaw")
				local visualAimYaw = if type(smoothedAimYaw) == "number"
					then smoothedAimYaw :: number
					else (if type(replicatedAimYaw) == "number" then replicatedAimYaw else aimYaw)
				local aimYawRate = 0
				if previousAimYaw ~= nil and dt > 0.001 then
					local delta = visualAimYaw - (previousAimYaw :: number)
					delta = ((delta + math.pi) % (math.pi * 2)) - math.pi
					aimYawRate = math.abs(delta / dt)
				end
				previousAimYaw = visualAimYaw
				if aimYawRate > HEAD_TURN_START_THRESHOLD and not headTurning then
					headTurning = true
					activeProfileController:onEvent("head_turning")
				elseif aimYawRate <= HEAD_TURN_STOP_THRESHOLD and headTurning then
					headTurning = false
					activeProfileController:onEvent("head_loop_stop")
					local now = tick()
					if (now - lastHeadStopTick) >= HEAD_STOP_COOLDOWN then
						lastHeadStopTick = now
						activeProfileController:onEvent("head_stop")
					end
				end

				local speedAttr = mdl:GetAttribute("VehicleSpeed")
				local currentSpeed: number = if type(speedAttr) == "number" then speedAttr else 0
				local hullHP = mdl:GetAttribute("HullHP")
				local maxHP = mdl:GetAttribute("MaxHullHP")
				local hpFrac: number = 1
				if type(hullHP) == "number" and type(maxHP) == "number" and maxHP > 0 then
					hpFrac = math.clamp(hullHP / maxHP, 0, 1)
				end
				if hpFrac < previousHpFraction then
					activeProfileController:onEvent("damage_taken", {
						amount = (previousHpFraction - hpFrac) * (if type(maxHP) == "number" then maxHP else 100),
						newHpFraction = hpFrac,
					})
				end
				previousHpFraction = hpFrac

				local frameState: SoundProfileTypes.VehicleFrameState = {
					speed = currentSpeed,
					maxSpeed = cfg.maxSpeed,
					speedFraction = if cfg.maxSpeed > 0 then math.clamp(currentSpeed / cfg.maxSpeed, 0, 1) else 0,
					hpFraction = hpFrac,
					isBoosting = sprint,
					isGrounded = true,
					throttle = throttle,
					steerInput = steerX,
					isLocal = true,
					dt = dt,
				}
				activeProfileController:update(dt, frameState)
			end

		-- Send input
		inputAccumulator += dt
		if inputAccumulator < sendInterval then
			return
		end
		while inputAccumulator >= sendInterval do
			inputAccumulator -= sendInterval
		end

		local now = tick()
		local throttleChanged = throttle ~= lastSentThrottle
		local strafeChanged = strafe ~= lastSentStrafe
		local steerChanged = math.abs(steerX - lastSentSteerX) > INPUT_STEER_DEADBAND
		local refreshNeeded = (now - lastSentTick) >= INPUT_REFRESH_INTERVAL

		if throttleChanged or strafeChanged or steerChanged or refreshNeeded then
			if vehicleInputRemote ~= nil then
				local payload: VehicleInputPayload = {
					throttle = throttle,
					steerX = steerX,
					lean = 0,
					boost = sprint,
					strafe = strafe,
					aimYaw = aimYaw,
				}
				vehicleInputRemote:FireServer(payload)
			end
			lastSentThrottle = throttle
			lastSentStrafe = strafe
			lastSentSteerX = steerX
			lastSentTick = now
		end
	end)

	ContextActionService:BindAction(EXIT_ACTION_NAME, onExitAction, false, Enum.KeyCode.F)
	if activeVehicleHasWeapon then
		ContextActionService:BindAction(LOCK_ACTION_NAME, function(_name: string, inputState: Enum.UserInputState)
			if inputState ~= Enum.UserInputState.Begin then
				return Enum.ContextActionResult.Pass
			end
			if TargetingClient.isLocked() then
				TargetingClient.requestClearLock()
			else
				TargetingClient.requestLock()
			end
			return Enum.ContextActionResult.Sink
		end, false, Enum.KeyCode.T)
	end
	scrollConnection = UserInputService.InputChanged:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseWheel then
			VehicleCamera.applyScrollZoom(-input.Position.Z)
		end
	end)
end

function WalkerClient.deactivate(): ()
	if renderConnection ~= nil then
		renderConnection:Disconnect()
		renderConnection = nil
	end
	ContextActionService:UnbindAction(EXIT_ACTION_NAME)
	ContextActionService:UnbindAction(LOCK_ACTION_NAME)
	TargetingClient.onSeatExit()
	if scrollConnection ~= nil then
		scrollConnection:Disconnect()
		scrollConnection = nil
	end

	if activeProfileController ~= nil then
		activeProfileController:destroy()
		activeProfileController = nil
	end
	previousHpFraction = 1
	previousAimYaw = nil
	headTurning = false
	lastHeadStopTick = 0
	previousGaitActive = false
	previousGaitSide = "left"
	settleStepsRemaining = 0
	previousFootLiftSeq = nil
	previousFootPlantSeq = nil

	VehicleCamera.deactivate()
	restoreMouse()
	RemoteVehicleSmoother.setLocalVehicle(nil)

	CombatHUD.hideHP()
	CombatHUD.showSpeed(false)
	CombatHUD.showVehicleCursor(false)
	CombatHUD.showCrosshair(false)
	CombatHUD.showHeat(false)
	CombatHUD.showAmmo(false)
	CombatHUD.showShield(false)
	CombatHUD.setWeaponHeat(0, 100, false)
	VehicleCamera.setExternalFOVOffset(0)
	CombatHUD.setZoomVignette(0)
	destroyFireSoundPool()

	activeEntityId = nil
	activeModel = nil
	activeConfig = nil
	activeHeadPart = nil
	activeHeadBaseOffset = nil
	table.clear(activeHeadFollowerOffsets)
	table.clear(activeWeaponMountStates)
	activeDriverSeat = nil
	seatCharacterOffset = nil
	seatOffsetNeedsRecalc = false
	activeIKState = nil
	activeLegParts = nil
	clearLegVisualSmoothing()
	activeRayParams = nil
	ikPrevPosition = nil
	smoothedBodyPos = nil
	lastWrittenPos = nil
	serverTargetPos = nil
	virtualCursorX = 0
	virtualCursorY = 0
	inputAccumulator = 0
	freelookActive = false
	activeVehicleHasWeapon = false
	walkerFireInterval = 0
	lastWalkerFireTick = 0
	lastWalkerHeatRecoverCueId = 0
	walkerAimRayParams = nil
	walkerFireCount = 0
	walkerFireErrors = 0
	walkerFireButtonHeld = false
	walkerBurstCount = 1
	walkerBurstInterval = 0
	walkerZoomBlend = 0
	walkerCrosshairSmoothedPos = nil
	lastWalkerAimSendTick = 0
	lastWalkerAimDirection = nil
	lastSentThrottle = 0
	lastSentStrafe = 0
	lastSentSteerX = 0
	lastSentTick = 0
end

function WalkerClient.isActive(): boolean
	return activeEntityId ~= nil
end

function WalkerClient.init(remotesFolder: Folder): ()
	vehicleInputRemote = remotesFolder:WaitForChild("VehicleInput") :: RemoteEvent
	vehicleExitRemote = remotesFolder:WaitForChild("VehicleExitRequest") :: RemoteEvent
	fireWeaponRemote = remotesFolder:WaitForChild("FireWeapon") :: RemoteEvent
	updateTurretAimRemote = remotesFolder:WaitForChild("UpdateTurretAim") :: RemoteEvent
end

return WalkerClient
