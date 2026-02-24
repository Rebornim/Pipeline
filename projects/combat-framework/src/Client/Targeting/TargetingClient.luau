--!strict

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local localPlayer = Players.LocalPlayer
local playerScripts = localPlayer:WaitForChild("PlayerScripts")
local clientRoot = playerScripts:WaitForChild("CombatFramework")

local CombatHUD = require(clientRoot:WaitForChild("HUD"):WaitForChild("CombatHUD"))
local sharedRoot = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatConfig = require(sharedRoot:WaitForChild("CombatConfig"))
local LeadSolver = require(sharedRoot:WaitForChild("LeadSolver"))
local WeaponRig = require(sharedRoot:WaitForChild("WeaponRig"))

local PLAYER_TARGET_PREFIX = "player_"

local TargetingClient = {}

local requestLockRemote: RemoteEvent? = nil
local clearLockRemote: RemoteEvent? = nil
local lockOnStateRemote: RemoteEvent? = nil
local renderConnection: RBXScriptConnection? = nil
local lockOnStateConnection: RBXScriptConnection? = nil

local candidateEntityId: string? = nil
local candidateModel: Model? = nil

local lockedEntityId: string? = nil
local lockedModel: Model? = nil
local lockedAttackerEntityId: string? = nil
local velocitySampleByModel: { [Model]: { lastPosition: Vector3, lastTime: number, velocity: Vector3 } } = {}
local smoothedLockScreenPos: Vector2? = nil
local smoothedLeadScreenPos: Vector2? = nil
local smoothedVisualLeadPoint: Vector3? = nil
local lastRenderTimestamp: number = 0

local MIN_SAMPLE_DT = 1 / 60
local VELOCITY_SMOOTH_ALPHA = 0.2
local LOCK_UI_SMOOTH_RATE = 14
local LOCK_UI_DEADZONE_PX = 2.5
local LEAD_WORLD_SMOOTH_RATE = 12
local LEAD_WORLD_DEADZONE_STUDS = 0.35

local function isPlayerTargetId(targetId: string): boolean
	return string.sub(targetId, 1, #PLAYER_TARGET_PREFIX) == PLAYER_TARGET_PREFIX
end

local function getModelAimPosition(model: Model): Vector3
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid ~= nil then
		local rootPart = humanoid.RootPart
		if rootPart ~= nil then
			return rootPart.Position
		end
	end
	return model:GetPivot().Position
end

local function normalizeTeamOrFaction(raw: string?): string?
	if raw == nil then
		return nil
	end
	local trimmed = string.match(raw, "^%s*(.-)%s*$")
	if trimmed == nil or trimmed == "" then
		return nil
	end
	return string.lower(trimmed)
end

local function findTaggedDescendant(model: Model, tagName: string, className: string?, excludeInsideFolders: boolean?): Instance?
	for _, descendant in ipairs(model:GetDescendants()) do
		if CollectionService:HasTag(descendant, tagName) then
			if className == nil or descendant:IsA(className) then
				if excludeInsideFolders then
					local insideFolder = false
					local current = descendant.Parent
					while current ~= nil and current ~= model do
						if current:IsA("Folder") then
							insideFolder = true
							break
						end
						current = current.Parent
					end
					if insideFolder then
						continue
					end
				end
				return descendant
			end
		end
	end
	return nil
end

local function findEntityModelById(entityId: string): Model?
	if isPlayerTargetId(entityId) then
		local userIdStr = string.sub(entityId, #PLAYER_TARGET_PREFIX + 1)
		local userId = tonumber(userIdStr)
		if userId == nil then
			return nil
		end
		for _, player in ipairs(Players:GetPlayers()) do
			if player.UserId == userId then
				local character = player.Character
				if character ~= nil then
					return character
				end
				return nil
			end
		end
		return nil
	end

	for _, tagged in ipairs(CollectionService:GetTagged("CombatEntity")) do
		if tagged:IsA("Model") and tagged:GetAttribute("EntityId") == entityId then
			return tagged
		end
	end
	return nil
end

local function resolveLockedModel(): Model?
	if lockedEntityId == nil then
		return nil
	end
	if lockedModel ~= nil and lockedModel.Parent ~= nil then
		return lockedModel
	end
	lockedModel = findEntityModelById(lockedEntityId)
	return lockedModel
end

local function getCurrentTurretContext(): (Model?, BasePart?, string?, number?)
	local character = localPlayer.Character
	if character == nil then
		return nil, nil, nil, nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return nil, nil, nil, nil
	end

	local seatPart = humanoid.SeatPart
	if seatPart == nil then
		return nil, nil, nil, nil
	end
	local isTurretSeat = CollectionService:HasTag(seatPart, "TurretSeat") or CollectionService:HasTag(seatPart, "ArtillerySeat")
	local isDriverSeat = CollectionService:HasTag(seatPart, "DriverSeat")
	if not isTurretSeat and not isDriverSeat then
		return nil, nil, nil, nil
	end

	local turretModel: Model? = nil
	if isTurretSeat then
		turretModel = seatPart:FindFirstAncestorWhichIsA("Model")
	else
		-- Walk up to find VehicleEntity-tagged model
		local current: Instance? = seatPart
		while current ~= nil do
			if current:IsA("Model") and CollectionService:HasTag(current, "VehicleEntity") then
				turretModel = current
				break
			end
			current = current.Parent
		end
	end
	if turretModel == nil then
		return nil, nil, nil, nil
	end

	-- Scope weapon mount search to the gunner's station folder (if in one)
	-- to avoid finding the wrong mount on multi-station vehicles.
	local mountSearchScope: Instance = turretModel
	if isTurretSeat then
		local seatParent = seatPart.Parent
		if seatParent ~= nil and seatParent:IsA("Folder") and seatParent ~= turretModel then
			mountSearchScope = seatParent
		end
	end
	-- Driver on a vehicle: skip mounts inside station folders (those belong to gunners)
	local excludeStationMounts = isDriverSeat
	local weaponMount = findTaggedDescendant(mountSearchScope :: Model, "WeaponMount", "BasePart", excludeStationMounts)
	if weaponMount == nil then
		return turretModel, nil, nil, nil
	end

	local attackerEntityId = turretModel:GetAttribute("EntityId")
	local lockRange = turretModel:GetAttribute("EffectiveWeaponLockRange")
	if type(lockRange) ~= "number" or lockRange <= 0 then
		lockRange = nil
	end

	return turretModel, weaponMount :: BasePart, if type(attackerEntityId) == "string" then attackerEntityId else nil, lockRange
end

local function getRotatingNeutralFrame(mount: BasePart): CFrame
	local rx = mount:GetAttribute("NeutralAimRX")
	local ry = mount:GetAttribute("NeutralAimRY")
	local rz = mount:GetAttribute("NeutralAimRZ")
	if type(rx) == "number" and type(ry) == "number" and type(rz) == "number" then
		local model = mount:FindFirstAncestorOfClass("Model")
		if model ~= nil and model.PrimaryPart ~= nil then
			return model.PrimaryPart.CFrame * CFrame.fromOrientation(rx, ry, rz)
		end
	end
	return WeaponRig.getNeutralAimFrame(mount)
end

local function isDirectionWithinMountArc(weaponMount: BasePart, desiredDirection: Vector3): boolean
	if desiredDirection.Magnitude < 1e-4 then
		return false
	end
	local neutralAimFrame = getRotatingNeutralFrame(weaponMount)
	local clamped = WeaponRig.clampDirectionToMountLimits(weaponMount, neutralAimFrame, desiredDirection.Unit)
	if clamped.Magnitude < 1e-4 then
		return false
	end
	return math.clamp(clamped:Dot(desiredDirection.Unit), -1, 1) >= math.cos(math.rad(1.5))
end

local function getProjectileSpeedForTurret(turretModel: Model): number?
	local effectiveSpeed = turretModel:GetAttribute("EffectiveWeaponProjectileSpeed")
	if type(effectiveSpeed) == "number" and effectiveSpeed > 0 then
		return effectiveSpeed
	end
	return nil
end

local function estimateTargetVelocity(targetModel: Model, targetPosition: Vector3): Vector3
	local now = tick()
	local fallbackVelocity = Vector3.zero
	local humanoid = targetModel:FindFirstChildOfClass("Humanoid")
	local rootPart: BasePart? = nil
	if humanoid ~= nil and humanoid.RootPart ~= nil then
		rootPart = humanoid.RootPart
	else
		rootPart = targetModel.PrimaryPart
	end
	if rootPart == nil then
		rootPart = targetModel:FindFirstChildWhichIsA("BasePart", true)
	end
	if rootPart ~= nil then
		fallbackVelocity = rootPart.AssemblyLinearVelocity
	end

	local sample = velocitySampleByModel[targetModel]
	if sample == nil then
		velocitySampleByModel[targetModel] = {
			lastPosition = targetPosition,
			lastTime = now,
			velocity = fallbackVelocity,
		}
		return fallbackVelocity
	end

	local dt = now - sample.lastTime
	if dt >= MIN_SAMPLE_DT then
		local observedVelocity = (targetPosition - sample.lastPosition) / dt
		sample.velocity = sample.velocity:Lerp(observedVelocity, VELOCITY_SMOOTH_ALPHA)
		sample.lastPosition = targetPosition
		sample.lastTime = now
	end

	return sample.velocity
end

local function computeLeadPoint(source: Vector3, targetModel: Model, projectileSpeed: number): Vector3?
	if projectileSpeed <= 0 then
		return nil
	end

	local targetPosition = getModelAimPosition(targetModel)
	local targetVelocity = estimateTargetVelocity(targetModel, targetPosition)
	local predicted, _travelTime = LeadSolver.solveInterceptPoint(source, targetPosition, targetVelocity, projectileSpeed)
	return predicted
end

local function smoothScreenPosition(current: Vector2?, target: Vector2, dt: number): Vector2
	if current == nil then
		return target
	end

	local delta = target - current
	if delta.Magnitude <= LOCK_UI_DEADZONE_PX then
		return current
	end

	local alpha = 1 - math.exp(-LOCK_UI_SMOOTH_RATE * dt)
	return current:Lerp(target, math.clamp(alpha, 0, 1))
end

local function smoothWorldPosition(current: Vector3?, target: Vector3, dt: number): Vector3
	if current == nil then
		return target
	end

	local delta = target - current
	if delta.Magnitude <= LEAD_WORLD_DEADZONE_STUDS then
		return current
	end

	local alpha = 1 - math.exp(-LEAD_WORLD_SMOOTH_RATE * dt)
	return current:Lerp(target, math.clamp(alpha, 0, 1))
end

local function resetHudSmoothing()
	smoothedLockScreenPos = nil
	smoothedLeadScreenPos = nil
	smoothedVisualLeadPoint = nil
end

local function computeSmoothedVisualLeadPoint(
	sourcePosition: Vector3,
	targetModel: Model,
	projectileSpeed: number,
	dt: number
): Vector3?
	local rawLeadPoint = computeLeadPoint(sourcePosition, targetModel, projectileSpeed)
	if rawLeadPoint == nil then
		smoothedVisualLeadPoint = nil
		return nil
	end

	local clampedDt = math.clamp(dt, 1 / 240, 0.12)
	smoothedVisualLeadPoint = smoothWorldPosition(smoothedVisualLeadPoint, rawLeadPoint, clampedDt)
	return smoothedVisualLeadPoint
end

local function updateLockedHud(camera: Camera, turretModel: Model, weaponMount: BasePart, dt: number)
	local activeLockedEntityId = lockedEntityId
	if activeLockedEntityId == nil then
		CombatHUD.showLockReticle(false)
		CombatHUD.showLeadingIndicator(false)
		resetHudSmoothing()
		return
	end

	local activeLockedModel = resolveLockedModel()
	if activeLockedModel == nil then
		CombatHUD.showLockReticle(false)
		CombatHUD.showLeadingIndicator(false)
		resetHudSmoothing()
		return
	end

	local targetPosition = getModelAimPosition(activeLockedModel)
	local targetViewport, targetOnScreen = camera:WorldToViewportPoint(targetPosition)
	if targetOnScreen then
		local rawTargetScreen = Vector2.new(targetViewport.X, targetViewport.Y)
		smoothedLockScreenPos = smoothScreenPosition(smoothedLockScreenPos, rawTargetScreen, dt)
		CombatHUD.showLockReticle(true)
		CombatHUD.setLockReticleScreenPosition(smoothedLockScreenPos :: Vector2)
	else
		CombatHUD.showLockReticle(false)
		smoothedLockScreenPos = nil
	end

	local projectileSpeed = getProjectileSpeedForTurret(turretModel)
	if projectileSpeed == nil then
		CombatHUD.showLeadingIndicator(false)
		smoothedLeadScreenPos = nil
		smoothedVisualLeadPoint = nil
		return
	end

	local leadPoint = computeSmoothedVisualLeadPoint(weaponMount.Position, activeLockedModel, projectileSpeed, dt)
	if leadPoint == nil then
		CombatHUD.showLeadingIndicator(false)
		smoothedLeadScreenPos = nil
		return
	end

	local leadViewport, leadOnScreen = camera:WorldToViewportPoint(leadPoint)
	if not leadOnScreen then
		CombatHUD.showLeadingIndicator(false)
		smoothedLeadScreenPos = nil
		return
	end

	local rawLeadScreen = Vector2.new(leadViewport.X, leadViewport.Y)
	smoothedLeadScreenPos = smoothScreenPosition(smoothedLeadScreenPos, rawLeadScreen, dt)

	CombatHUD.showLeadingIndicator(true)
	CombatHUD.setLeadingIndicatorScreenPosition(smoothedLeadScreenPos :: Vector2)
end

local losRaycastParams = RaycastParams.new()
losRaycastParams.FilterType = Enum.RaycastFilterType.Exclude
losRaycastParams.IgnoreWater = true

local function hasLineOfSight(weaponMount: BasePart, turretModel: Model, targetPosition: Vector3, targetModel: Model): boolean
	losRaycastParams.FilterDescendantsInstances = { turretModel }
	local toTarget = targetPosition - weaponMount.Position
	local losResult = Workspace:Raycast(weaponMount.Position, toTarget, losRaycastParams)
	if losResult == nil then
		return true
	end
	return losResult.Instance:IsDescendantOf(targetModel)
end

local function getEntityAimDirection(turretModel: Model, weaponMount: BasePart, camera: Camera): Vector3
	-- For VehicleEntity with driver-fired weapon: use the vehicle's forward direction.
	-- For turrets and vehicle gunner seats: use the camera look direction.
	if CollectionService:HasTag(turretModel, "VehicleEntity") and turretModel.PrimaryPart ~= nil then
		-- Check if the local player is in a DriverSeat (fixed gun → vehicle forward)
		local character = localPlayer.Character
		local isDriverSeat = false
		if character ~= nil then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if humanoid ~= nil and humanoid.SeatPart ~= nil and CollectionService:HasTag(humanoid.SeatPart, "DriverSeat") then
				isDriverSeat = true
			end
		end

		if isDriverSeat then
			local forwardAxisRaw = turretModel:GetAttribute("ForwardAxis")
			local forwardAxisLocal: Vector3
			if forwardAxisRaw == "X" then
				forwardAxisLocal = Vector3.new(1, 0, 0)
			elseif forwardAxisRaw == "-X" then
				forwardAxisLocal = Vector3.new(-1, 0, 0)
			elseif forwardAxisRaw == "Z" then
				forwardAxisLocal = Vector3.new(0, 0, 1)
			else
				forwardAxisLocal = Vector3.new(0, 0, -1)
			end
			local worldForward = turretModel.PrimaryPart.CFrame:VectorToWorldSpace(forwardAxisLocal)
			local horizontal = Vector3.new(worldForward.X, 0, worldForward.Z)
			if horizontal.Magnitude > 1e-4 then
				return horizontal.Unit
			end
		end
	end
	return camera.CFrame.LookVector
end

local function updateLockCandidate(camera: Camera, turretModel: Model, weaponMount: BasePart, lockRange: number)
	local scanOrigin = weaponMount.Position
	-- Use camera position for the "is the player looking at this?" cone check,
	-- since the camera may be far from the weapon mount (vehicle chase cam).
	local cameraOrigin = camera.CFrame.Position
	local scanDirection = getEntityAimDirection(turretModel, weaponMount, camera)
	local turretFaction = normalizeTeamOrFaction(turretModel:GetAttribute("Faction"))
	local maxDot = math.cos(math.rad(CombatConfig.LockOnScanRadius))

	local bestDot = maxDot
	local bestEntityId: string? = nil
	local bestModel: Model? = nil

	-- Scan CombatEntity tagged models (turrets, vehicles, target dummies)
	for _, tagged in ipairs(CollectionService:GetTagged("CombatEntity")) do
		if tagged:IsA("Model") then
			local targetModel = tagged :: Model
			if targetModel ~= turretModel then
				local targetEntityId = targetModel:GetAttribute("EntityId")
				if type(targetEntityId) == "string" then
					local hullHP = targetModel:GetAttribute("HullHP")
					if type(hullHP) == "number" and hullHP > 0 then
						local targetFaction = normalizeTeamOrFaction(targetModel:GetAttribute("Faction"))
						if CombatConfig.FriendlyFireEnabled or turretFaction == nil or targetFaction == nil or targetFaction ~= turretFaction then
							local targetPosition = getModelAimPosition(targetModel)
							local toTargetFromGun = targetPosition - scanOrigin
							local distanceFromGun = toTargetFromGun.Magnitude
							if distanceFromGun > 1e-4 and distanceFromGun <= lockRange then
								local toTargetFromCam = targetPosition - cameraOrigin
								local direction = if toTargetFromCam.Magnitude > 1e-4 then toTargetFromCam.Unit else toTargetFromGun.Unit
								local dot = scanDirection:Dot(direction)
								local inArc = isDirectionWithinMountArc(weaponMount, targetPosition - weaponMount.Position)
								if dot >= bestDot and inArc then
									if hasLineOfSight(weaponMount, turretModel, targetPosition, targetModel) then
										bestDot = dot
										bestEntityId = targetEntityId
										bestModel = targetModel
									end
								end
							end
						end
					end
				end
			end
		end
	end

	-- Scan player characters
	local localCharacter = localPlayer.Character
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= localPlayer then
			local character = player.Character
			if character ~= nil and character ~= localCharacter then
				local humanoid = character:FindFirstChildOfClass("Humanoid")
				if humanoid ~= nil and humanoid.Health > 0 then
					local targetFaction: string? = nil
					local team = player.Team
					if team ~= nil then
						targetFaction = normalizeTeamOrFaction(team.Name)
					end
					if CombatConfig.FriendlyFireEnabled or turretFaction == nil or targetFaction == nil or targetFaction ~= turretFaction then
						local targetPosition = getModelAimPosition(character)
						local toTargetFromGun = targetPosition - scanOrigin
						local distanceFromGun = toTargetFromGun.Magnitude
						if distanceFromGun > 1e-4 and distanceFromGun <= lockRange then
							local toTargetFromCam = targetPosition - cameraOrigin
							local direction = if toTargetFromCam.Magnitude > 1e-4 then toTargetFromCam.Unit else toTargetFromGun.Unit
							local dot = scanDirection:Dot(direction)
							if dot >= bestDot and isDirectionWithinMountArc(weaponMount, targetPosition - weaponMount.Position) then
								if hasLineOfSight(weaponMount, turretModel, targetPosition, character) then
									bestDot = dot
									bestEntityId = PLAYER_TARGET_PREFIX .. tostring(player.UserId)
									bestModel = character
								end
							end
						end
					end
				end
			end
		end
	end

	candidateEntityId = bestEntityId
	candidateModel = bestModel
end

local function onRenderStepped()
	for model, _sample in pairs(velocitySampleByModel) do
		if model.Parent == nil then
			velocitySampleByModel[model] = nil
		end
	end

	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end

	local now = tick()
	local dt = if lastRenderTimestamp > 0 then math.clamp(now - lastRenderTimestamp, 1 / 240, 0.12) else 1 / 60
	lastRenderTimestamp = now

	local turretModel, weaponMount, attackerEntityId, lockRange = getCurrentTurretContext()
	if turretModel == nil or weaponMount == nil or attackerEntityId == nil or lockRange == nil then
		candidateEntityId = nil
		candidateModel = nil
		CombatHUD.showLockReady(false)
		CombatHUD.showLockReticle(false)
		CombatHUD.showLeadingIndicator(false)
		resetHudSmoothing()
		return
	end

	updateLockCandidate(camera, turretModel, weaponMount, lockRange)
	if lockedEntityId == nil then
		CombatHUD.showLockReady(candidateEntityId ~= nil)
		CombatHUD.showLockReticle(false)
		CombatHUD.showLeadingIndicator(false)
		resetHudSmoothing()
	else
		CombatHUD.showLockReady(false)
		updateLockedHud(camera, turretModel, weaponMount, dt)
	end
end

local function onLockOnState(payload: any)
	if type(payload) ~= "table" then
		return
	end

	local previousLockedEntityId = lockedEntityId
	local attackerEntityId = payload.attackerEntityId
	if type(attackerEntityId) == "string" then
		lockedAttackerEntityId = attackerEntityId
	end

	if payload.locked == true and type(payload.targetEntityId) == "string" then
		lockedEntityId = payload.targetEntityId
		lockedModel = findEntityModelById(payload.targetEntityId)
	else
		local reason = payload.reason
		if previousLockedEntityId ~= nil and type(reason) == "string" then
			if reason == "range" or reason == "arc" or reason == "dead" or reason == "missing" or reason == "missing_target" or reason == "los" then
				CombatHUD.onLockLostCue(reason)
			end
		end
		lockedEntityId = nil
		lockedModel = nil
		resetHudSmoothing()
	end
end

function TargetingClient.init(remotes: Folder)
	requestLockRemote = remotes:WaitForChild("RequestLockOn") :: RemoteEvent
	clearLockRemote = remotes:WaitForChild("ClearLockOn") :: RemoteEvent
	lockOnStateRemote = remotes:WaitForChild("LockOnState") :: RemoteEvent

	if lockOnStateConnection == nil then
		lockOnStateConnection = lockOnStateRemote.OnClientEvent:Connect(onLockOnState)
	end

	if renderConnection == nil then
		renderConnection = RunService.RenderStepped:Connect(onRenderStepped)
	end
end

function TargetingClient.isLocked(): boolean
	return lockedEntityId ~= nil
end

function TargetingClient.getLockedEntityId(): string?
	return lockedEntityId
end

function TargetingClient.getLockedModel(): Model?
	return resolveLockedModel()
end

function TargetingClient.getLockedLeadPoint(sourcePosition: Vector3, turretModel: Model): Vector3?
	local activeLockedModel = resolveLockedModel()
	if activeLockedModel == nil then
		return nil
	end

	local projectileSpeed = getProjectileSpeedForTurret(turretModel)
	if projectileSpeed == nil then
		return nil
	end

	return computeLeadPoint(sourcePosition, activeLockedModel, projectileSpeed)
end

function TargetingClient.getLockedVisualLeadPoint(sourcePosition: Vector3, turretModel: Model, dt: number): Vector3?
	local activeLockedModel = resolveLockedModel()
	if activeLockedModel == nil then
		smoothedVisualLeadPoint = nil
		return nil
	end

	local projectileSpeed = getProjectileSpeedForTurret(turretModel)
	if projectileSpeed == nil then
		smoothedVisualLeadPoint = nil
		return nil
	end

	return computeSmoothedVisualLeadPoint(sourcePosition, activeLockedModel, projectileSpeed, dt)
end

function TargetingClient.requestLock()
	if requestLockRemote == nil then
		return
	end
	if candidateEntityId == nil then
		return
	end
	requestLockRemote:FireServer({
		targetEntityId = candidateEntityId,
		attackerEntityId = lockedAttackerEntityId,
	})
end

function TargetingClient.requestClearLock()
	if clearLockRemote == nil then
		return
	end
	clearLockRemote:FireServer()
end

function TargetingClient.onSeatExit()
	if lockedEntityId ~= nil then
		TargetingClient.requestClearLock()
	end

	candidateEntityId = nil
	candidateModel = nil
	lockedEntityId = nil
	lockedModel = nil
	lockedAttackerEntityId = nil
	table.clear(velocitySampleByModel)
	resetHudSmoothing()
	lastRenderTimestamp = 0
	CombatHUD.showLockReady(false)
	CombatHUD.showLockReticle(false)
	CombatHUD.showLeadingIndicator(false)
end

return TargetingClient
