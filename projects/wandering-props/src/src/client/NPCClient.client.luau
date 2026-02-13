--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local configModule = ReplicatedStorage:WaitForChild("Config", 10)
assert(configModule and configModule:IsA("ModuleScript"), "WanderingProps NPCClient: ReplicatedStorage.Config not found")

local typesModule = ReplicatedStorage:WaitForChild("Types", 10)
assert(typesModule and typesModule:IsA("ModuleScript"), "WanderingProps NPCClient: ReplicatedStorage.Types not found")

local moverModule = script.Parent:WaitForChild("NPCMover", 10)
assert(moverModule and moverModule:IsA("ModuleScript"), "WanderingProps NPCClient: NPCMover module not found")

local animatorModule = script.Parent:WaitForChild("NPCAnimator", 10)
assert(animatorModule and animatorModule:IsA("ModuleScript"), "WanderingProps NPCClient: NPCAnimator module not found")

local poolModule = script.Parent:WaitForChild("ModelPool", 10)
assert(poolModule and poolModule:IsA("ModuleScript"), "WanderingProps NPCClient: ModelPool module not found")

local Config = require(configModule)
local Types = require(typesModule)
local NPCMover = require(moverModule)
local NPCAnimator = require(animatorModule)
local ModelPool = require(poolModule)

type RouteStep = Types.RouteStep
type Action = Types.Action
type SpawnPayload = Types.SpawnPayload
type SyncNPCData = Types.SyncNPCData
type ClientNPC = Types.ClientNPC

type SyncPayload = {
	npcs: { [string]: SyncNPCData },
}

type DespawnPayload = {
	id: string,
}

local REMOTES_FOLDER_NAME = "WanderingPropsRemotes"
local SPAWN_EVENT_NAME = "WP_SpawnNPC"
local DESPAWN_EVENT_NAME = "WP_DespawnNPC"
local SYNC_EVENT_NAME = "WP_SyncState"
local ACTIVE_NPCS_FOLDER_NAME = "WanderingPropsActiveNPCs"

local activeNPCs: { [string]: ClientNPC } = {}

local function debugLog(message: string): ()
	if Config.DEBUG_ENABLED then
		warn(("[WanderingProps/NPCClient] %s"):format(message))
	end
end

local function cloneStep(step: RouteStep): RouteStep
	return {
		position = step.position,
		action = step.action,
		duration = step.duration,
		faceCFrame = step.faceCFrame,
		sitCFrame = step.sitCFrame,
	}
end

local function cloneRoute(route: { RouteStep }): { RouteStep }
	local copy: { RouteStep } = table.create(#route)
	for index, step in ipairs(route) do
		copy[index] = cloneStep(step)
	end
	return copy
end

local function ensureActiveNPCsFolder(): Folder
	local existing = Workspace:FindFirstChild(ACTIVE_NPCS_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = ACTIVE_NPCS_FOLDER_NAME
	folder.Parent = Workspace
	return folder
end

local function tryAcquireModel(modelIndex: number): Model?
	local ok, result = pcall(function()
		return ModelPool.acquire(modelIndex)
	end)

	if not ok then
		warn(("[WanderingProps/NPCClient] ModelPool.acquire failed for model %d: %s"):format(modelIndex, tostring(result)))
		return nil
	end

	return result :: Model
end

local function resolveAnimator(model: Model): Animator?
	local animationController = model:FindFirstChild("AnimationController")
	if not animationController or not animationController:IsA("AnimationController") then
		warn(("[WanderingProps/NPCClient] Model %s missing AnimationController"):format(model.Name))
		return nil
	end

	local animator = animationController:FindFirstChild("Animator")
	if not animator or not animator:IsA("Animator") then
		warn(("[WanderingProps/NPCClient] Model %s missing Animator under AnimationController"):format(model.Name))
		return nil
	end

	return animator
end

local function cleanupNPC(npc: ClientNPC): ()
	NPCAnimator.stopAll(npc)
	ModelPool.release(npc.model)
	activeNPCs[npc.id] = nil
	NPCMover.stop(npc.id)
end

local function onRouteComplete(npc: ClientNPC): ()
	local active = activeNPCs[npc.id]
	if active then
		cleanupNPC(active)
	end
end

local function onStepChanged(npc: ClientNPC, step: RouteStep): ()
	if step.action == "walk" then
		NPCAnimator.playWalk(npc, npc.speed)
	elseif step.action == "idle" then
		NPCAnimator.playIdle(npc)
	elseif step.action == "sit" then
		NPCAnimator.playSit(npc)
	end
end

local function buildSyncRoute(syncData: SyncNPCData): { RouteStep }
	if syncData.currentAction == "despawn" then
		return {}
	end

	local currentStep: RouteStep = {
		position = syncData.currentPosition,
		action = syncData.currentAction,
		duration = nil,
		faceCFrame = nil,
		sitCFrame = nil,
	}

	if syncData.currentAction == "idle" or syncData.currentAction == "sit" then
		currentStep.duration = math.max(0, syncData.actionTimeRemaining)
	end

	local route: { RouteStep } = { currentStep }
	for _, step in ipairs(syncData.remainingRoute) do
		table.insert(route, cloneStep(step))
	end
	return route
end

local function buildClientNPC(
	id: string,
	model: Model,
	animator: Animator,
	speed: number,
	route: { RouteStep },
	groupId: string?
): ClientNPC
	local npc: ClientNPC = ({
		id = id,
		model = model,
		speed = speed,
		route = route,
		currentStepIndex = 1,
		stepStartTime = tick(),
		groupId = groupId,
		animator = animator,
		walkTrack = nil,
		idleTrack = nil,
		sitTrack = nil,
		lodTier = "near" :: Types.LODTier,
		lastPosition = route[1].position,
	} :: any) :: ClientNPC

	return npc
end

local function handleSpawn(payload: SpawnPayload): ()
	if #payload.route == 0 then
		debugLog(("Spawn payload for %s has empty route; skipped"):format(payload.id))
		return
	end

	local existing = activeNPCs[payload.id]
	if existing then
		cleanupNPC(existing)
	end

	local model = tryAcquireModel(payload.modelIndex)
	if not model then
		return
	end

	model:PivotTo(CFrame.new(payload.route[1].position))
	model.Parent = ensureActiveNPCsFolder()

	local animator = resolveAnimator(model)
	if not animator then
		ModelPool.release(model)
		return
	end

	local route = cloneRoute(payload.route)
	local npc = buildClientNPC(payload.id, model, animator, payload.speed, route, payload.groupId)
	NPCAnimator.setup(npc)

	activeNPCs[npc.id] = npc
	onStepChanged(npc, route[1])
	NPCMover.startRoute(npc, 1, onStepChanged, onRouteComplete)
end

local function handleDespawn(payload: DespawnPayload): ()
	local npc = activeNPCs[payload.id]
	if npc then
		cleanupNPC(npc)
	end
end

local function handleSync(payload: SyncPayload): ()
	for npcId, syncData in pairs(payload.npcs) do
		local route = buildSyncRoute(syncData)
		if #route == 0 then
			continue
		end

		local existing = activeNPCs[npcId]
		if existing then
			cleanupNPC(existing)
		end

		local model = tryAcquireModel(syncData.modelIndex)
		if not model then
			continue
		end

		model:PivotTo(CFrame.new(syncData.currentPosition))
		model.Parent = ensureActiveNPCsFolder()

		local animator = resolveAnimator(model)
		if not animator then
			ModelPool.release(model)
			continue
		end

		local npc = buildClientNPC(npcId, model, animator, syncData.speed, route, syncData.groupId)
		NPCAnimator.setup(npc)
		activeNPCs[npcId] = npc

		if syncData.currentAction == "walk" then
			NPCAnimator.playWalk(npc, syncData.speed)
		elseif syncData.currentAction == "idle" then
			NPCAnimator.playIdle(npc)
		elseif syncData.currentAction == "sit" then
			NPCAnimator.playSit(npc)
		end

		NPCMover.startRoute(npc, 1, onStepChanged, onRouteComplete)
	end
end

ModelPool.init()
ensureActiveNPCsFolder()

local remotes = ReplicatedStorage:WaitForChild(REMOTES_FOLDER_NAME, 10)
if not remotes or not remotes:IsA("Folder") then
	warn("[WanderingProps/NPCClient] Remote events folder not found. Server may have failed to start.")
	return
end

local spawnRemote = remotes:WaitForChild(SPAWN_EVENT_NAME, 10)
if not spawnRemote or not spawnRemote:IsA("RemoteEvent") then
	warn("[WanderingProps/NPCClient] WP_SpawnNPC RemoteEvent missing.")
	return
end

local despawnRemote = remotes:WaitForChild(DESPAWN_EVENT_NAME, 10)
if not despawnRemote or not despawnRemote:IsA("RemoteEvent") then
	warn("[WanderingProps/NPCClient] WP_DespawnNPC RemoteEvent missing.")
	return
end

local syncRemote = remotes:WaitForChild(SYNC_EVENT_NAME, 10)
if not syncRemote or not syncRemote:IsA("RemoteEvent") then
	warn("[WanderingProps/NPCClient] WP_SyncState RemoteEvent missing.")
	return
end

spawnRemote.OnClientEvent:Connect(handleSpawn)
despawnRemote.OnClientEvent:Connect(handleDespawn)
syncRemote.OnClientEvent:Connect(handleSync)

RunService.Heartbeat:Connect(function(dt)
	NPCMover.update(dt)
end)
