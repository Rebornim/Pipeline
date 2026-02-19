--!strict

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local sharedRoot = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatConfig = require(sharedRoot:WaitForChild("CombatConfig"))
local CombatEnums = require(sharedRoot:WaitForChild("CombatEnums"))
local CombatTypes = require(sharedRoot:WaitForChild("CombatTypes"))

type EntityConfig = CombatTypes.EntityConfig
type HealthState = CombatTypes.HealthState
type ValidatedEntity = CombatTypes.ValidatedEntity
type EntityDestroyedPayload = CombatTypes.EntityDestroyedPayload
type DamageTypeMultiplier = CombatTypes.DamageTypeMultiplier

type PartState = {
	part: BasePart,
	transparency: number,
	canCollide: boolean,
	canTouch: boolean,
}

type PromptState = {
	prompt: ProximityPrompt,
	enabled: boolean,
}

type HealthStateInternal = HealthState & {
	partStates: { PartState }?,
	promptStates: { PromptState }?,
	lastShieldDamageTime: number,
}

local HealthManager = {}

local entitiesById: { [string]: HealthStateInternal } = {}
local modelToEntityId: { [Model]: string } = {}

local remotesFolder: Folder? = nil
local damageAppliedRemote: RemoteEvent? = nil
local entityDestroyedRemote: RemoteEvent? = nil
local entityRespawnedRemote: RemoteEvent? = nil
local explosionOverlapParams = OverlapParams.new()
local heartbeatConnection: RBXScriptConnection? = nil
local respawnCallback: ((string) -> ())? = nil

local function readConfigNumber(name: string, defaultValue: number): number
	local raw = CombatConfig[name]
	if type(raw) == "number" then
		return raw
	end
	return defaultValue
end

local function distancePointToPartBounds(point: Vector3, part: BasePart): number
	local localPoint = part.CFrame:PointToObjectSpace(point)
	local halfSize = part.Size * 0.5
	local dx = math.max(math.abs(localPoint.X) - halfSize.X, 0)
	local dy = math.max(math.abs(localPoint.Y) - halfSize.Y, 0)
	local dz = math.max(math.abs(localPoint.Z) - halfSize.Z, 0)
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function computeExplosionFalloffScale(distance: number, radius: number): number
	local safeRadius = math.max(radius, 1e-4)
	local normalized = math.clamp(distance / safeRadius, 0, 1)
	local exponent = math.max(0.1, readConfigNumber("TurretDeathExplosionFalloffExponent", 1.6))
	local minScale = math.clamp(readConfigNumber("TurretDeathExplosionMinDamageScale", 0.12), 0, 1)
	local curved = math.clamp(1 - math.pow(normalized, exponent), 0, 1)
	return math.max(minScale, curved)
end

local function getRemotes(): (RemoteEvent, RemoteEvent, RemoteEvent)
	local damageRemote = damageAppliedRemote
	local destroyedRemote = entityDestroyedRemote
	local respawnedRemote = entityRespawnedRemote
	if damageRemote == nil or destroyedRemote == nil or respawnedRemote == nil then
		error("HealthManager not initialized with remotes")
	end
	return damageRemote, destroyedRemote, respawnedRemote
end

local function setModelHealthAttributes(
	model: Model,
	currentHP: number,
	maxHP: number,
	currentShieldHP: number,
	maxShieldHP: number
)
	model:SetAttribute("HullHP", currentHP)
	model:SetAttribute("MaxHullHP", maxHP)
	model:SetAttribute("ShieldHP", currentShieldHP)
	model:SetAttribute("MaxShieldHP", maxShieldHP)
end

local function getShieldRegenRate(config: EntityConfig): number
	if type(config.shieldRegenRate) == "number" and config.shieldRegenRate > 0 then
		return config.shieldRegenRate
	end
	return 0
end

local function getShieldRegenDelay(config: EntityConfig): number
	if type(config.shieldRegenDelay) == "number" and config.shieldRegenDelay >= 0 then
		return config.shieldRegenDelay
	end
	return math.max(0, readConfigNumber("DefaultShieldRegenDelay", 3))
end

local function getDamageTypeMultiplier(damageType: string): DamageTypeMultiplier
	local defaults: DamageTypeMultiplier = {
		shieldMult = 1,
		hullMult = 1,
		bypass = 0,
	}

	local allMultipliers = CombatConfig.DamageTypeMultipliers
	if type(allMultipliers) ~= "table" then
		return defaults
	end

	local raw = allMultipliers[damageType]
	if type(raw) ~= "table" then
		return defaults
	end

	local shieldMult = if type(raw.shieldMult) == "number" then math.max(0, raw.shieldMult) else defaults.shieldMult
	local hullMult = if type(raw.hullMult) == "number" then math.max(0, raw.hullMult) else defaults.hullMult
	local bypass = if type(raw.bypass) == "number" then math.clamp(raw.bypass, 0, 1) else defaults.bypass

	return {
		shieldMult = shieldMult,
		hullMult = hullMult,
		bypass = bypass,
	}
end

local function stepShieldRegen(dt: number)
	if dt <= 0 then
		return
	end

	local now = tick()
	for _, state in pairs(entitiesById) do
		if state.state ~= CombatEnums.EntityState.Active then
			continue
		end
		if state.maxShieldHP <= 0 or state.currentShieldHP >= state.maxShieldHP then
			continue
		end

		local regenRate = getShieldRegenRate(state.config)
		if regenRate <= 0 then
			continue
		end

		local regenDelay = getShieldRegenDelay(state.config)
		if now - state.lastShieldDamageTime < regenDelay then
			continue
		end

		local previousShieldHP = state.currentShieldHP
		local nextShieldHP = math.min(state.maxShieldHP, previousShieldHP + regenRate * dt)
		if nextShieldHP == previousShieldHP then
			continue
		end

		state.currentShieldHP = nextShieldHP
		setModelHealthAttributes(state.instance, state.currentHP, state.maxHP, state.currentShieldHP, state.maxShieldHP)

	end
end

local function collectAndHideParts(model: Model): { PartState }
	local partStates: { PartState } = {}

	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			table.insert(partStates, {
				part = descendant,
				transparency = descendant.Transparency,
				canCollide = descendant.CanCollide,
				canTouch = descendant.CanTouch,
			})
			descendant.Transparency = 1
			descendant.CanCollide = false
			descendant.CanTouch = false
		end
	end

	return partStates
end

local function collectAndDisablePrompts(model: Model): { PromptState }
	local promptStates: { PromptState } = {}

	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("ProximityPrompt") then
			table.insert(promptStates, {
				prompt = descendant,
				enabled = descendant.Enabled,
			})
			descendant.Enabled = false
		end
	end

	return promptStates
end

local function restoreParts(state: HealthStateInternal)
	if state.partStates == nil then
		return
	end

	for _, saved in ipairs(state.partStates) do
		if saved.part.Parent ~= nil then
			local restoredTransparency = saved.transparency
			if saved.part:IsA("Seat") and CollectionService:HasTag(saved.part, "TurretSeat") then
				restoredTransparency = 1
			end
			saved.part.Transparency = restoredTransparency
			saved.part.CanCollide = saved.canCollide
			saved.part.CanTouch = saved.canTouch
		end
	end

	state.partStates = nil
end

local function restorePrompts(state: HealthStateInternal)
	if state.promptStates == nil then
		return
	end

	for _, saved in ipairs(state.promptStates) do
		if saved.prompt.Parent ~= nil then
			saved.prompt.Enabled = saved.enabled
		end
	end

	state.promptStates = nil
end

local function findEntityIdFromInstance(instance: Instance): string?
	local current: Instance? = instance
	while current ~= nil do
		if current:IsA("Model") then
			local knownEntityId = modelToEntityId[current]
			if knownEntityId ~= nil then
				return knownEntityId
			end

			local attributeId = current:GetAttribute("EntityId")
			if type(attributeId) == "string" and entitiesById[attributeId] ~= nil then
				return attributeId
			end
		end
		current = current.Parent
	end

	return nil
end

local function applyTurretDeathExplosion(state: HealthStateInternal, turretSeat: Seat?, operatorHumanoid: Humanoid?)
	if turretSeat == nil then
		return
	end

	local damageRadius = math.max(0, readConfigNumber("TurretDeathExplosionRadius", 22))
	local visualRadius = math.max(
		damageRadius,
		readConfigNumber("TurretDeathExplosionVisualRadius", damageRadius > 0 and damageRadius * 1.35 or 30)
	)
	local maxDamage = math.max(0, readConfigNumber("TurretDeathExplosionDamage", 220))
	if damageRadius <= 0 or maxDamage <= 0 then
		return
	end

	local center = turretSeat.Position
	local explosionVisual = Instance.new("Explosion")
	explosionVisual.Position = center
	explosionVisual.BlastRadius = visualRadius
	explosionVisual.BlastPressure = 0
	explosionVisual.DestroyJointRadiusPercent = 0
	explosionVisual.Parent = Workspace

	-- The turret operator always dies when their turret is destroyed.
	if operatorHumanoid ~= nil and operatorHumanoid.Health > 0 then
		operatorHumanoid:TakeDamage(1_000_000)
	end

	explosionOverlapParams.FilterType = Enum.RaycastFilterType.Exclude
	explosionOverlapParams.FilterDescendantsInstances = { state.instance }
	explosionOverlapParams.MaxParts = 256
	local nearbyParts = Workspace:GetPartBoundsInRadius(center, damageRadius, explosionOverlapParams)
	local closestDistanceByEntityId: { [string]: number } = {}
	local closestDistanceByModel: { [Model]: number } = {}

	for _, part in ipairs(nearbyParts) do
		local distance = distancePointToPartBounds(center, part)
		if distance > damageRadius then
			continue
		end

		local targetEntityId = findEntityIdFromInstance(part)
		if targetEntityId ~= nil then
			if targetEntityId ~= state.entityId and HealthManager.isAlive(targetEntityId) then
				local previous = closestDistanceByEntityId[targetEntityId]
				if previous == nil or distance < previous then
					closestDistanceByEntityId[targetEntityId] = distance
				end
			end
		else
			local model = part:FindFirstAncestorOfClass("Model")
			if model ~= nil then
				local previous = closestDistanceByModel[model]
				if previous == nil or distance < previous then
					closestDistanceByModel[model] = distance
				end
			end
		end
	end

	for targetEntityId, distance in pairs(closestDistanceByEntityId) do
		local scale = computeExplosionFalloffScale(distance, damageRadius)
		local damage = math.max(0, math.floor(maxDamage * scale + 0.5))
		if damage > 0 then
			HealthManager.applyDamage(targetEntityId, damage, "explosion", state.faction, center, true)
		end
	end

	for model, distance in pairs(closestDistanceByModel) do
		if model ~= state.instance then
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			if humanoid ~= nil and humanoid.Health > 0 then
				local scale = computeExplosionFalloffScale(distance, damageRadius)
				local damage = math.max(0, math.floor(maxDamage * scale + 0.5))
				if damage > 0 then
					humanoid:TakeDamage(damage)
				end
			end
		end
	end

	print(
		string.format(
			"[P1_TURRET_EXPLOSION] entity=%s damageRadius=%.1f visualRadius=%.1f maxDamage=%.1f",
			state.entityId,
			damageRadius,
			visualRadius,
			maxDamage
		)
	)
end

local function destroyEntity(state: HealthStateInternal)
	if state.state ~= CombatEnums.EntityState.Active then
		return
	end

	state.state = CombatEnums.EntityState.Destroyed

	local seat = state.instance:FindFirstChildWhichIsA("Seat", true)
	local operatorHumanoid: Humanoid? = nil
	if seat ~= nil and seat.Occupant ~= nil then
		operatorHumanoid = seat.Occupant
		seat.Occupant.Sit = false
	end
	applyTurretDeathExplosion(state, seat, operatorHumanoid)

	state.partStates = collectAndHideParts(state.instance)
	state.promptStates = collectAndDisablePrompts(state.instance)

	local _, destroyedRemote = getRemotes()
	local destroyPayload: EntityDestroyedPayload = {
		entityId = state.entityId,
		explosionPosition = if seat ~= nil then seat.Position else state.instance:GetPivot().Position,
		explosionRadius = readConfigNumber("TurretDeathExplosionRadius", 22),
	}
	destroyedRemote:FireAllClients(destroyPayload)
	print(string.format("[P1_DESTROYED] entity=%s tick=%.3f", state.entityId, tick()))

	if state.config.respawnTime ~= nil and state.config.respawnTime > 0 then
		local respawnTime = state.config.respawnTime
		state.respawnTimer = task.spawn(function()
			task.wait(respawnTime)
			if entitiesById[state.entityId] ~= state then
				return
			end

			restoreParts(state)
			restorePrompts(state)
			state.currentHP = state.maxHP
				state.currentShieldHP = state.maxShieldHP
				state.lastShieldDamageTime = tick()
				state.state = CombatEnums.EntityState.Active
				state.respawnTimer = nil
				setModelHealthAttributes(state.instance, state.currentHP, state.maxHP, state.currentShieldHP, state.maxShieldHP)
				if respawnCallback ~= nil then
					local ok, callbackErr = pcall(respawnCallback, state.entityId)
					if not ok then
						warn(string.format("[P3_RESPAWN_CALLBACK] entity=%s error=%s", state.entityId, tostring(callbackErr)))
					end
				end

				local _, _, respawnedRemote = getRemotes()
			local payload: CombatTypes.RespawnedPayload = {
				entityId = state.entityId,
				hullHP = state.maxHP,
				shieldHP = if state.maxShieldHP > 0 then state.maxShieldHP else nil,
			}
			respawnedRemote:FireAllClients(payload)
			print(string.format("[P1_RESPAWNED] entity=%s hullHP=%d tick=%.3f", state.entityId, state.maxHP, tick()))
		end)
	end
end

function HealthManager.init(remotes: Folder)
	remotesFolder = remotes
	damageAppliedRemote = remotesFolder:WaitForChild("DamageApplied") :: RemoteEvent
	entityDestroyedRemote = remotesFolder:WaitForChild("EntityDestroyed") :: RemoteEvent
	entityRespawnedRemote = remotesFolder:WaitForChild("EntityRespawned") :: RemoteEvent

	Players.PlayerRemoving:Connect(function(_player)
		-- No per-player state in pass 1.
	end)

	if heartbeatConnection == nil then
		heartbeatConnection = RunService.Heartbeat:Connect(stepShieldRegen)
	end
end

function HealthManager.registerEntity(entityId: string, validated: ValidatedEntity)
	local entityConfig: EntityConfig? = CombatConfig.Entities[validated.configId]
	if entityConfig == nil then
		warn(string.format("[P1_REGISTER_FAIL] entity=%s missing config '%s'", entityId, validated.configId))
		return
	end

	local maxHP = entityConfig.hullHP
	local maxShieldHP = 0
	if type(entityConfig.shieldHP) == "number" then
		maxShieldHP = math.max(0, entityConfig.shieldHP)
	end
	local state: HealthStateInternal = {
		entityId = entityId,
		instance = validated.instance,
		faction = validated.faction,
		config = entityConfig,
		currentHP = maxHP,
		maxHP = maxHP,
		currentShieldHP = maxShieldHP,
		maxShieldHP = maxShieldHP,
		state = CombatEnums.EntityState.Active,
		respawnTimer = nil,
		partStates = nil,
		promptStates = nil,
		lastShieldDamageTime = 0,
	}

	entitiesById[entityId] = state
	modelToEntityId[validated.instance] = entityId
	setModelHealthAttributes(validated.instance, maxHP, maxHP, maxShieldHP, maxShieldHP)
end

function HealthManager.applyDamage(
	entityId: string,
	damage: number,
	damageType: string,
	attackerFaction: string,
	hitPosition: Vector3,
	ignoreFactionCheck: boolean?
): (boolean, string?, boolean)
	local state = entitiesById[entityId]
	if state == nil then
		return false, nil, false
	end

	if state.state ~= CombatEnums.EntityState.Active then
		return false, nil, false
	end

	if not ignoreFactionCheck and not CombatConfig.FriendlyFireEnabled and state.faction == attackerFaction then
		print(string.format("[P1_FACTION_BLOCK] attackerFaction=%s targetEntityId=%s", attackerFaction, entityId))
		return false, nil, false
	end

	local appliedDamage = math.max(0, damage)
	if appliedDamage <= 0 then
		return false, nil, false
	end

	local multiplier = getDamageTypeMultiplier(damageType)
	local shieldMult = multiplier.shieldMult
	local hullMult = multiplier.hullMult
	local bypassFraction = if type(multiplier.bypass) == "number" then multiplier.bypass else 0
	if math.abs(shieldMult - 1) > 1e-4 or math.abs(hullMult - 1) > 1e-4 or bypassFraction > 1e-4 then
		print(
			string.format(
				"[P3_MULT] entity=%s type=%s shieldM=%.2f hullM=%.2f bypass=%.0f%%",
				entityId,
				damageType,
				shieldMult,
				hullMult,
				bypassFraction * 100
			)
		)
	end

	local impactType = CombatEnums.ImpactType.Hull
	local didBreakShield = false
	local oldShieldHP = state.currentShieldHP
	local oldHP = state.currentHP
	local hullDamage = 0
	if oldShieldHP > 0 then
		impactType = CombatEnums.ImpactType.Shield
		local bypassBase = appliedDamage * bypassFraction
		local shieldFacingBase = appliedDamage * (1 - bypassFraction)
		local shieldDamage = shieldFacingBase * shieldMult
		local absorbedShieldDamage = math.min(oldShieldHP, shieldDamage)
		state.currentShieldHP = math.max(0, oldShieldHP - absorbedShieldDamage)

		local overflowShieldDamage = math.max(0, shieldDamage - absorbedShieldDamage)
		local overflowBase = overflowShieldDamage / math.max(shieldMult, 0.001)
		local bypassHullDamage = bypassBase * hullMult
		local overflowHullDamage = overflowBase * hullMult
		hullDamage = math.max(0, bypassHullDamage + overflowHullDamage)

		if absorbedShieldDamage > 0 then
			state.lastShieldDamageTime = tick()
		end
		if bypassHullDamage > 0 then
			print(string.format("[P3_BYPASS] entity=%s bypassDmg=%.1f", entityId, bypassHullDamage))
		end

		if state.currentShieldHP <= 0 then
			didBreakShield = true
		end
	else
		hullDamage = math.max(0, appliedDamage * hullMult)
	end

	local nextHP = oldHP
	if hullDamage > 0 then
		nextHP = math.max(0, oldHP - hullDamage)
		state.currentHP = nextHP
		print(
			string.format(
				"[P1_DAMAGE] entity=%s %d->%d (%s, -%d)",
				entityId,
				math.floor(oldHP + 0.5),
				math.floor(nextHP + 0.5),
				damageType,
				math.floor(hullDamage + 0.5)
			)
		)
	end

	setModelHealthAttributes(state.instance, state.currentHP, state.maxHP, state.currentShieldHP, state.maxShieldHP)

	local damageRemote = getRemotes()
	local payload: CombatTypes.DamagePayload = {
		entityId = entityId,
		newHP = nextHP,
		maxHP = state.maxHP,
		hitPosition = hitPosition,
		newShieldHP = if state.maxShieldHP > 0 then state.currentShieldHP else nil,
		maxShieldHP = if state.maxShieldHP > 0 then state.maxShieldHP else nil,
	}
	damageRemote:FireAllClients(payload)

	if nextHP <= 0 then
		destroyEntity(state)
	end

	return true, impactType, didBreakShield
end

function HealthManager.setRespawnCallback(callback: (string) -> ())
	respawnCallback = callback
end

function HealthManager.getHealth(entityId: string): HealthState?
	return entitiesById[entityId]
end

function HealthManager.getShieldHP(entityId: string): (number?, number?)
	local state = entitiesById[entityId]
	if state == nil then
		return nil, nil
	end
	return state.currentShieldHP, state.maxShieldHP
end

function HealthManager.isAlive(entityId: string): boolean
	local state = entitiesById[entityId]
	return state ~= nil and state.state == CombatEnums.EntityState.Active
end

function HealthManager.getFaction(entityId: string): string?
	local state = entitiesById[entityId]
	if state == nil then
		return nil
	end
	return state.faction
end

function HealthManager.findEntityFromInstance(instance: Instance): string?
	return findEntityIdFromInstance(instance)
end

return HealthManager
