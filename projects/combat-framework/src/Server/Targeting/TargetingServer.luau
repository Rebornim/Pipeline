--!strict

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local PLAYER_TARGET_PREFIX = "player_"

local sharedRoot = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatConfig = require(sharedRoot:WaitForChild("CombatConfig"))
local CombatTypes = require(sharedRoot:WaitForChild("CombatTypes"))
local LeadSolver = require(sharedRoot:WaitForChild("LeadSolver"))
local WeaponRig = require(sharedRoot:WaitForChild("WeaponRig"))

local ServerScriptService = game:GetService("ServerScriptService")
local serverRoot = ServerScriptService:WaitForChild("CombatFramework")
local HealthManager = require(serverRoot:WaitForChild("Health"):WaitForChild("HealthManager"))

type HealthState = CombatTypes.HealthState
type LockState = CombatTypes.LockState

type RuntimeLockState = LockState & {
	player: Player?,
}

type TargetVelocitySample = {
	lastPosition: Vector3,
	lastTime: number,
	velocity: Vector3,
}

local TargetingServer = {}

local requestLockRemote: RemoteEvent? = nil
local clearLockRemote: RemoteEvent? = nil
local lockOnStateRemote: RemoteEvent? = nil
local requestLockConnection: RBXScriptConnection? = nil
local clearLockConnection: RBXScriptConnection? = nil
local heartbeatConnection: RBXScriptConnection? = nil
local playerRemovingConnection: RBXScriptConnection? = nil

local locksByEntityId: { [string]: RuntimeLockState } = {}
local lockedEntityByPlayer: { [Player]: string } = {}
local velocitySamplesByEntityId: { [string]: TargetVelocitySample } = {}
local validationAccumulator = 0
local MIN_SAMPLE_DT = 1 / 240
local VELOCITY_SMOOTH_ALPHA = 0.35
local losRaycastParams = RaycastParams.new()
losRaycastParams.FilterType = Enum.RaycastFilterType.Exclude
losRaycastParams.IgnoreWater = true

local function getLockOnStateRemote(): RemoteEvent
	if lockOnStateRemote == nil then
		error("TargetingServer not initialized")
	end
	return lockOnStateRemote
end

local function isPlayerTargetId(targetId: string): boolean
	return string.sub(targetId, 1, #PLAYER_TARGET_PREFIX) == PLAYER_TARGET_PREFIX
end

local function getPlayerFromTargetId(targetId: string): Player?
	if not isPlayerTargetId(targetId) then
		return nil
	end
	local userIdStr = string.sub(targetId, #PLAYER_TARGET_PREFIX + 1)
	local userId = tonumber(userIdStr)
	if userId == nil then
		return nil
	end
	for _, player in ipairs(Players:GetPlayers()) do
		if player.UserId == userId then
			return player
		end
	end
	return nil
end

local function getPlayerCharacterAlive(player: Player): Model?
	local character = player.Character
	if character == nil then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil or humanoid.Health <= 0 then
		return nil
	end
	return character
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

local function getPlayerFaction(player: Player): string?
	local team = player.Team
	if team == nil then
		return nil
	end
	return normalizeTeamOrFaction(team.Name)
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

local function getPlayerTurretContext(player: Player): (string?, HealthState?, BasePart?)
	local character = player.Character
	if character == nil then
		return nil, nil, nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return nil, nil, nil
	end

	local seatPart = humanoid.SeatPart
	if seatPart == nil or not CollectionService:HasTag(seatPart, "TurretSeat") then
		return nil, nil, nil
	end

	local turretModel = seatPart:FindFirstAncestorWhichIsA("Model")
	if turretModel == nil then
		return nil, nil, nil
	end

	local entityIdAttr = turretModel:GetAttribute("EntityId")
	if type(entityIdAttr) ~= "string" then
		return nil, nil, nil
	end

	local attackerEntityId = entityIdAttr
	local attackerHealthState = HealthManager.getHealth(attackerEntityId)
	if attackerHealthState == nil or not HealthManager.isAlive(attackerEntityId) then
		return nil, nil, nil
	end

	local weaponMount = findTaggedDescendant(attackerHealthState.instance, "WeaponMount", "BasePart")
	if weaponMount == nil then
		return nil, nil, nil
	end

	return attackerEntityId, attackerHealthState, weaponMount :: BasePart
end

local function getEffectiveLockRange(attackerHealthState: HealthState): number?
	local attackerModel = attackerHealthState.instance
	local effectiveAttr = attackerModel:GetAttribute("EffectiveWeaponLockRange")
	if type(effectiveAttr) == "number" and effectiveAttr > 0 then
		return effectiveAttr
	end

	if type(attackerHealthState.config.weaponId) ~= "string" then
		return nil
	end
	local weaponConfig = CombatConfig.Weapons[attackerHealthState.config.weaponId]
	if weaponConfig == nil or type(weaponConfig.lockRange) ~= "number" or weaponConfig.lockRange <= 0 then
		return nil
	end
	return weaponConfig.lockRange
end

local function estimateAssemblyVelocity(targetModel: Model): Vector3
	local rootPart = targetModel.PrimaryPart
	if rootPart == nil then
		rootPart = targetModel:FindFirstChildWhichIsA("BasePart", true)
	end
	if rootPart == nil then
		return Vector3.zero
	end
	return rootPart.AssemblyLinearVelocity
end

local function resolveTargetModel(targetEntityId: string): Model?
	if isPlayerTargetId(targetEntityId) then
		local player = getPlayerFromTargetId(targetEntityId)
		if player == nil then
			return nil
		end
		return getPlayerCharacterAlive(player)
	end
	local targetState = HealthManager.getHealth(targetEntityId)
	if targetState == nil then
		return nil
	end
	return targetState.instance
end

local function getTargetPositionAndVelocity(targetEntityId: string, targetModel: Model): (Vector3?, Vector3)
	if targetModel.Parent == nil then
		velocitySamplesByEntityId[targetEntityId] = nil
		return nil, Vector3.zero
	end

	local now = tick()
	local targetPosition = getModelAimPosition(targetModel)
	local velocity = estimateAssemblyVelocity(targetModel)

	local sample = velocitySamplesByEntityId[targetEntityId]
	if sample == nil then
		velocitySamplesByEntityId[targetEntityId] = {
			lastPosition = targetPosition,
			lastTime = now,
			velocity = velocity,
		}
		return targetPosition, velocity
	end

	local dt = now - sample.lastTime
	if dt >= MIN_SAMPLE_DT then
		local observedVelocity = (targetPosition - sample.lastPosition) / dt
		sample.velocity = sample.velocity:Lerp(observedVelocity, VELOCITY_SMOOTH_ALPHA)
		sample.lastPosition = targetPosition
		sample.lastTime = now
	end

	return targetPosition, sample.velocity
end

local function isDirectionWithinMountArc(weaponMount: BasePart, desiredDirection: Vector3): boolean
	if desiredDirection.Magnitude < 1e-4 then
		return false
	end

	local neutralAimFrame = WeaponRig.getNeutralAimFrame(weaponMount)
	local clampedDirection = WeaponRig.clampDirectionToMountLimits(weaponMount, neutralAimFrame, desiredDirection.Unit)
	if clampedDirection.Magnitude < 1e-4 then
		return false
	end

	local dot = math.clamp(clampedDirection:Dot(desiredDirection.Unit), -1, 1)
	return dot >= math.cos(math.rad(1.5))
end

local function sendLockState(
	player: Player,
	attackerEntityId: string,
	targetEntityId: string?,
	locked: boolean,
	reason: string?
)
	getLockOnStateRemote():FireClient(player, {
		attackerEntityId = attackerEntityId,
		targetEntityId = targetEntityId,
		locked = locked,
		reason = reason,
	})
end

local function getRequestTargetEntityId(rawPayload: any): string?
	if type(rawPayload) == "string" then
		return rawPayload
	end
	if type(rawPayload) == "table" then
		local tableTarget = rawPayload.targetEntityId
		if type(tableTarget) == "string" then
			return tableTarget
		end
	end
	return nil
end

local function validateLockCandidate(
	attackerEntityId: string,
	attackerHealthState: HealthState,
	weaponMount: BasePart,
	targetEntityId: string,
	rangeMultiplier: number
): (boolean, string?)
	if targetEntityId == attackerEntityId then
		return false, "self"
	end

	local targetModel: Model?
	local targetFaction: string?

	if isPlayerTargetId(targetEntityId) then
		local targetPlayer = getPlayerFromTargetId(targetEntityId)
		if targetPlayer == nil then
			return false, "missing"
		end
		local character = getPlayerCharacterAlive(targetPlayer)
		if character == nil then
			return false, "dead"
		end
		targetModel = character
		targetFaction = getPlayerFaction(targetPlayer)
	else
		if not HealthManager.isAlive(targetEntityId) then
			return false, "dead"
		end
		local targetState = HealthManager.getHealth(targetEntityId)
		if targetState == nil then
			return false, "missing"
		end
		targetModel = targetState.instance
		targetFaction = HealthManager.getFaction(targetEntityId)
	end

	local attackerFaction = HealthManager.getFaction(attackerEntityId)
	if not CombatConfig.FriendlyFireEnabled and attackerFaction ~= nil and targetFaction ~= nil and attackerFaction == targetFaction then
		return false, "friendly"
	end

	local lockRange = getEffectiveLockRange(attackerHealthState)
	if lockRange == nil then
		return false, "no_lock_range"
	end

	local targetPosition, _targetVelocity = getTargetPositionAndVelocity(targetEntityId, targetModel :: Model)
	if targetPosition == nil then
		return false, "missing_target"
	end
	local sourcePosition = weaponMount.Position
	local toTarget = targetPosition - sourcePosition
	local distance = toTarget.Magnitude
	if distance <= 1e-4 then
		return false, "distance"
	end

	if distance > lockRange * rangeMultiplier then
		return false, "range"
	end

	if not isDirectionWithinMountArc(weaponMount, toTarget.Unit) then
		return false, "arc"
	end

	-- Line-of-sight check: raycast from mount to target, blocked if geometry intervenes
	losRaycastParams.FilterDescendantsInstances = { attackerHealthState.instance }
	local losResult = Workspace:Raycast(sourcePosition, toTarget, losRaycastParams)
	if losResult ~= nil and not losResult.Instance:IsDescendantOf(targetModel :: Model) then
		return false, "los"
	end

	return true, nil
end

local function clearLockInternal(attackerEntityId: string, reason: string, eventTag: string)
	local existing = locksByEntityId[attackerEntityId]
	if existing == nil then
		return
	end

	locksByEntityId[attackerEntityId] = nil
	if existing.player ~= nil and lockedEntityByPlayer[existing.player] == attackerEntityId then
		lockedEntityByPlayer[existing.player] = nil
	end

	if existing.player ~= nil then
		sendLockState(existing.player, attackerEntityId, nil, false, reason)
	end

	if eventTag == "broken" then
		print(string.format("[P4_LOCK_BROKEN] attacker=%s target=%s reason=%s", attackerEntityId, existing.targetEntityId, reason))
	else
		print(string.format("[P4_LOCK_CLEARED] attacker=%s reason=%s", attackerEntityId, reason))
	end
end

local function onRequestLock(player: Player, rawPayload: any)
	local targetEntityId = getRequestTargetEntityId(rawPayload)
	if targetEntityId == nil then
		return
	end

	local attackerEntityId, attackerHealthState, weaponMount = getPlayerTurretContext(player)
	if attackerEntityId == nil or attackerHealthState == nil or weaponMount == nil then
		return
	end

	local ok, reason = validateLockCandidate(attackerEntityId, attackerHealthState, weaponMount, targetEntityId, 1)
	if not ok then
		if reason == "friendly" then
			return
		end
		return
	end

	local previousForPlayer = lockedEntityByPlayer[player]
	if previousForPlayer ~= nil and previousForPlayer ~= attackerEntityId then
		clearLockInternal(previousForPlayer, "switch", "cleared")
	end

	locksByEntityId[attackerEntityId] = {
		attackerEntityId = attackerEntityId,
		targetEntityId = targetEntityId,
		lockedAt = tick(),
		player = player,
	}
	lockedEntityByPlayer[player] = attackerEntityId

	sendLockState(player, attackerEntityId, targetEntityId, true, nil)
	print(string.format("[P4_LOCK_ACQUIRED] attacker=%s target=%s", attackerEntityId, targetEntityId))
end

local function onClearLock(player: Player, _payload: any)
	local attackerEntityId = lockedEntityByPlayer[player]
	if attackerEntityId == nil then
		local contextEntityId = getPlayerTurretContext(player)
		if contextEntityId ~= nil then
			attackerEntityId = contextEntityId
		end
	end
	if attackerEntityId == nil then
		return
	end

	clearLockInternal(attackerEntityId, "manual", "cleared")
end

local function runValidationTick()
	for attackerEntityId, lockState in pairs(locksByEntityId) do
		local attackerHealthState: HealthState?
		local weaponMount: BasePart?
		if lockState.player ~= nil then
			local currentEntityId, playerHealthState, playerWeaponMount = getPlayerTurretContext(lockState.player)
			if currentEntityId == nil or playerHealthState == nil or playerWeaponMount == nil then
				clearLockInternal(attackerEntityId, "seat", "broken")
				continue
			end
			if currentEntityId ~= attackerEntityId then
				clearLockInternal(attackerEntityId, "seat", "broken")
				continue
			end
			attackerHealthState = playerHealthState
			weaponMount = playerWeaponMount
		else
			attackerHealthState = HealthManager.getHealth(attackerEntityId)
			if attackerHealthState ~= nil then
				local mountInstance = findTaggedDescendant(attackerHealthState.instance, "WeaponMount", "BasePart")
				if mountInstance ~= nil then
					weaponMount = mountInstance :: BasePart
				end
			end
			if attackerHealthState == nil or weaponMount == nil then
				clearLockInternal(attackerEntityId, "missing_attacker", "broken")
				continue
			end
		end

		local ok, reason = validateLockCandidate(
			attackerEntityId,
			attackerHealthState,
			weaponMount,
			lockState.targetEntityId,
			1
		)
		if not ok then
			clearLockInternal(attackerEntityId, reason or "invalid", "broken")
		end
	end
end

local function applySpread(direction: Vector3, spreadDegrees: number): Vector3
	if spreadDegrees <= 0 then
		return direction.Unit
	end

	local spreadRadians = math.rad(spreadDegrees)
	local yaw = (math.random() * 2 - 1) * spreadRadians
	local pitch = (math.random() * 2 - 1) * spreadRadians
	local lookFrame = CFrame.lookAt(Vector3.zero, direction.Unit)
	return (lookFrame * CFrame.Angles(pitch, yaw, 0)).LookVector.Unit
end

function TargetingServer.init(remotes: Folder)
	requestLockRemote = remotes:WaitForChild("RequestLockOn") :: RemoteEvent
	clearLockRemote = remotes:WaitForChild("ClearLockOn") :: RemoteEvent
	lockOnStateRemote = remotes:WaitForChild("LockOnState") :: RemoteEvent

	if requestLockConnection == nil then
		requestLockConnection = requestLockRemote.OnServerEvent:Connect(onRequestLock)
	end
	if clearLockConnection == nil then
		clearLockConnection = clearLockRemote.OnServerEvent:Connect(onClearLock)
	end
	if heartbeatConnection == nil then
		heartbeatConnection = RunService.Heartbeat:Connect(function(dt)
			validationAccumulator += dt
			if validationAccumulator < CombatConfig.LockValidationInterval then
				return
			end
			validationAccumulator = 0
			runValidationTick()
		end)
	end
	if playerRemovingConnection == nil then
		playerRemovingConnection = Players.PlayerRemoving:Connect(function(player)
			local attackerEntityId = lockedEntityByPlayer[player]
			if attackerEntityId ~= nil then
				clearLockInternal(attackerEntityId, "player_left", "cleared")
			end
			lockedEntityByPlayer[player] = nil
		end)
	end
end

function TargetingServer.getLockState(entityId: string): LockState?
	local runtimeState = locksByEntityId[entityId]
	if runtimeState == nil then
		return nil
	end

	return {
		attackerEntityId = runtimeState.attackerEntityId,
		targetEntityId = runtimeState.targetEntityId,
		lockedAt = runtimeState.lockedAt,
	}
end

function TargetingServer.clearLock(entityId: string)
	clearLockInternal(entityId, "clear", "cleared")
end

function TargetingServer.computeLeadDirection(
	sourcePosition: Vector3,
	targetEntityId: string,
	projectileSpeed: number,
	autoAimSpread: number
): Vector3?
	if projectileSpeed <= 0 then
		return nil
	end

	local targetModel = resolveTargetModel(targetEntityId)
	if targetModel == nil then
		return nil
	end

	local targetPosition, targetVelocity = getTargetPositionAndVelocity(targetEntityId, targetModel)
	if targetPosition == nil then
		return nil
	end

	local predicted, _travelTime =
		LeadSolver.solveInterceptPoint(sourcePosition, targetPosition, targetVelocity, projectileSpeed)
	if predicted == nil then
		return nil
	end

	local direction = predicted - sourcePosition
	if direction.Magnitude < 1e-4 then
		return nil
	end

	return applySpread(direction.Unit, math.max(0, autoAimSpread))
end

-- Studio-only helper for harness automation.
function TargetingServer.requestLockForTest(attackerEntityId: string, targetEntityId: string): boolean
	if not RunService:IsStudio() then
		return false
	end

	local runtimeState = locksByEntityId[attackerEntityId]
	local player = if runtimeState ~= nil then runtimeState.player else nil
	if player == nil then
		for candidatePlayer, lockedEntityId in pairs(lockedEntityByPlayer) do
			if lockedEntityId == attackerEntityId then
				player = candidatePlayer
				break
			end
		end
	end

	local attackerState = HealthManager.getHealth(attackerEntityId)
	if attackerState == nil or not HealthManager.isAlive(attackerEntityId) then
		return false
	end
	local weaponMount = findTaggedDescendant(attackerState.instance, "WeaponMount", "BasePart")
	if weaponMount == nil then
		return false
	end

	local ok = validateLockCandidate(attackerEntityId, attackerState, weaponMount :: BasePart, targetEntityId, 1)
	if not ok then
		return false
	end

	if runtimeState == nil then
		runtimeState = {
			attackerEntityId = attackerEntityId,
			targetEntityId = targetEntityId,
			lockedAt = tick(),
			player = player,
		}
	end
	runtimeState.targetEntityId = targetEntityId
	runtimeState.lockedAt = tick()
	locksByEntityId[attackerEntityId] = runtimeState
	if runtimeState.player ~= nil then
		lockedEntityByPlayer[runtimeState.player] = attackerEntityId
		sendLockState(runtimeState.player, attackerEntityId, targetEntityId, true, nil)
	end

	print(string.format("[P4_LOCK_ACQUIRED] attacker=%s target=%s", attackerEntityId, targetEntityId))
	return true
end

return TargetingServer
