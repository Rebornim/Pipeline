--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local sharedRoot = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatConfig = require(sharedRoot:WaitForChild("CombatConfig"))
local CombatEnums = require(sharedRoot:WaitForChild("CombatEnums"))
local CombatTypes = require(sharedRoot:WaitForChild("CombatTypes"))

type EntityConfig = CombatTypes.EntityConfig
type HealthState = CombatTypes.HealthState
type ValidatedEntity = CombatTypes.ValidatedEntity

type PartState = {
	part: BasePart,
	transparency: number,
	canCollide: boolean,
}

type HealthStateInternal = HealthState & {
	partStates: { PartState }?,
}

local HealthManager = {}

local entitiesById: { [string]: HealthStateInternal } = {}
local modelToEntityId: { [Model]: string } = {}

local remotesFolder: Folder? = nil
local damageAppliedRemote: RemoteEvent? = nil
local entityDestroyedRemote: RemoteEvent? = nil
local entityRespawnedRemote: RemoteEvent? = nil

local function getRemotes(): (RemoteEvent, RemoteEvent, RemoteEvent)
	local damageRemote = damageAppliedRemote
	local destroyedRemote = entityDestroyedRemote
	local respawnedRemote = entityRespawnedRemote
	if damageRemote == nil or destroyedRemote == nil or respawnedRemote == nil then
		error("HealthManager not initialized with remotes")
	end
	return damageRemote, destroyedRemote, respawnedRemote
end

local function setModelHealthAttributes(model: Model, currentHP: number, maxHP: number)
	model:SetAttribute("HullHP", currentHP)
	model:SetAttribute("MaxHullHP", maxHP)
end

local function collectAndHideParts(model: Model): { PartState }
	local partStates: { PartState } = {}

	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			table.insert(partStates, {
				part = descendant,
				transparency = descendant.Transparency,
				canCollide = descendant.CanCollide,
			})
			descendant.Transparency = 1
			descendant.CanCollide = false
		end
	end

	return partStates
end

local function restoreParts(state: HealthStateInternal)
	if state.partStates == nil then
		return
	end

	for _, saved in ipairs(state.partStates) do
		if saved.part.Parent ~= nil then
			saved.part.Transparency = saved.transparency
			saved.part.CanCollide = saved.canCollide
		end
	end

	state.partStates = nil
end

local function destroyEntity(state: HealthStateInternal)
	if state.state ~= CombatEnums.EntityState.Active then
		return
	end

	state.state = CombatEnums.EntityState.Destroyed

	local seat = state.instance:FindFirstChildWhichIsA("Seat", true)
	if seat ~= nil and seat.Occupant ~= nil then
		seat.Occupant.Sit = false
	end

	state.partStates = collectAndHideParts(state.instance)

	local _, destroyedRemote = getRemotes()
	destroyedRemote:FireAllClients(state.entityId)
	print(string.format("[P1_DESTROYED] entity=%s tick=%.3f", state.entityId, tick()))

	if state.config.respawnTime ~= nil and state.config.respawnTime > 0 then
		local respawnTime = state.config.respawnTime
		state.respawnTimer = task.spawn(function()
			task.wait(respawnTime)
			if entitiesById[state.entityId] ~= state then
				return
			end

			restoreParts(state)
			state.currentHP = state.maxHP
			state.state = CombatEnums.EntityState.Active
			state.respawnTimer = nil
			setModelHealthAttributes(state.instance, state.currentHP, state.maxHP)

			local _, _, respawnedRemote = getRemotes()
			respawnedRemote:FireAllClients({
				entityId = state.entityId,
				hullHP = state.maxHP,
			})
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
end

function HealthManager.registerEntity(entityId: string, validated: ValidatedEntity)
	local entityConfig: EntityConfig? = CombatConfig.Entities[validated.configId]
	if entityConfig == nil then
		warn(string.format("[P1_REGISTER_FAIL] entity=%s missing config '%s'", entityId, validated.configId))
		return
	end

	local maxHP = entityConfig.hullHP
	local state: HealthStateInternal = {
		entityId = entityId,
		instance = validated.instance,
		faction = validated.faction,
		config = entityConfig,
		currentHP = maxHP,
		maxHP = maxHP,
		state = CombatEnums.EntityState.Active,
		respawnTimer = nil,
		partStates = nil,
	}

	entitiesById[entityId] = state
	modelToEntityId[validated.instance] = entityId
	setModelHealthAttributes(validated.instance, maxHP, maxHP)
end

function HealthManager.applyDamage(
	entityId: string,
	damage: number,
	damageType: string,
	attackerFaction: string,
	hitPosition: Vector3
): boolean
	local state = entitiesById[entityId]
	if state == nil then
		return false
	end

	if state.state ~= CombatEnums.EntityState.Active then
		return false
	end

	if state.faction == attackerFaction then
		print(string.format("[P1_FACTION_BLOCK] attackerFaction=%s targetEntityId=%s", attackerFaction, entityId))
		return false
	end

	local oldHP = state.currentHP
	local nextHP = math.max(0, oldHP - damage)
	state.currentHP = nextHP
	setModelHealthAttributes(state.instance, state.currentHP, state.maxHP)

	local damageRemote = getRemotes()
	damageRemote:FireAllClients({
		entityId = entityId,
		newHP = nextHP,
		maxHP = state.maxHP,
		hitPosition = hitPosition,
	})

	print(string.format("[P1_DAMAGE] entity=%s %d->%d (%s, -%d)", entityId, oldHP, nextHP, damageType, damage))

	if nextHP <= 0 then
		destroyEntity(state)
	end

	return true
end

function HealthManager.getHealth(entityId: string): HealthState?
	return entitiesById[entityId]
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

return HealthManager
