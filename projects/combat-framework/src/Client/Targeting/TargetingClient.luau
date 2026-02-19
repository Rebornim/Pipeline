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

local function findTaggedDescendant(model: Model, tagName: string, className: string?): Instance?
	for _, descendant in ipairs(model:GetDescendants()) do
		if CollectionService:HasTag(descendant, tagName) then
			if className == nil or descendant:IsA(className) then
				return descendant
			end
		end
	end
	return nil
end

local function findEntityModelById(entityId: string): Model?
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
	if seatPart == nil or not CollectionService:HasTag(seatPart, "TurretSeat") then
		return nil, nil, nil, nil
	end

	local turretModel = seatPart:FindFirstAncestorWhichIsA("Model")
	if turretModel == nil then
		return nil, nil, nil, nil
	end

	local weaponMount = findTaggedDescendant(turretModel, "WeaponMount", "BasePart")
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

local function isDirectionWithinMountArc(weaponMount: BasePart, desiredDirection: Vector3): boolean
	if desiredDirection.Magnitude < 1e-4 then
		return false
	end
	local neutralAimFrame = WeaponRig.getNeutralAimFrame(weaponMount)
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
	local rootPart = targetModel.PrimaryPart
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

	local targetPosition = targetModel:GetPivot().Position
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

	local targetPosition = activeLockedModel:GetPivot().Position
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

local function updateLockCandidate(camera: Camera, turretModel: Model, weaponMount: BasePart, lockRange: number)
	local cameraPosition = camera.CFrame.Position
	local cameraLook = camera.CFrame.LookVector
	local turretFaction = normalizeTeamOrFaction(turretModel:GetAttribute("Faction"))
	local maxDot = math.cos(math.rad(CombatConfig.LockOnScanRadius))

	local bestDot = maxDot
	local bestEntityId: string? = nil
	local bestModel: Model? = nil

	for _, tagged in ipairs(CollectionService:GetTagged("CombatEntity")) do
		if tagged:IsA("Model") then
			local targetModel = tagged :: Model
			if targetModel ~= turretModel then
				local targetEntityId = targetModel:GetAttribute("EntityId")
				if type(targetEntityId) == "string" then
					local hullHP = targetModel:GetAttribute("HullHP")
					if type(hullHP) == "number" and hullHP > 0 then
						local targetFaction = normalizeTeamOrFaction(targetModel:GetAttribute("Faction"))
						if turretFaction == nil or targetFaction == nil or targetFaction ~= turretFaction then
							local targetPosition = targetModel:GetPivot().Position
							local toTarget = targetPosition - cameraPosition
							local distance = toTarget.Magnitude
							if distance > 1e-4 and distance <= lockRange then
								local direction = toTarget.Unit
								local dot = cameraLook:Dot(direction)
								if dot >= bestDot and isDirectionWithinMountArc(weaponMount, targetPosition - weaponMount.Position) then
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
			if reason == "range" or reason == "arc" or reason == "dead" or reason == "missing" or reason == "missing_target" then
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
