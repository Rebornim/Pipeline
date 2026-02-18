--!strict

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local localPlayer = Players.LocalPlayer
local playerScripts = localPlayer:WaitForChild("PlayerScripts")
local clientRoot = playerScripts:WaitForChild("CombatFramework")

local WeaponClient = require(clientRoot:WaitForChild("Weapons"):WaitForChild("WeaponClient"))
local ProjectileVisuals = require(clientRoot:WaitForChild("Projectiles"):WaitForChild("ProjectileVisuals"))
local CombatHUD = require(clientRoot:WaitForChild("HUD"):WaitForChild("CombatHUD"))

local remotesFolder = ReplicatedStorage:WaitForChild("CombatRemotes") :: Folder
local fireWeaponRemote = remotesFolder:WaitForChild("FireWeapon") :: RemoteEvent
local projectileFiredRemote = remotesFolder:WaitForChild("ProjectileFired") :: RemoteEvent
local damageAppliedRemote = remotesFolder:WaitForChild("DamageApplied") :: RemoteEvent
local entityDestroyedRemote = remotesFolder:WaitForChild("EntityDestroyed") :: RemoteEvent
local entityRespawnedRemote = remotesFolder:WaitForChild("EntityRespawned") :: RemoteEvent

local function findEntityById(entityId: string): Model?
	for _, tagged in ipairs(CollectionService:GetTagged("CombatEntity")) do
		if tagged:IsA("Model") and tagged:GetAttribute("EntityId") == entityId then
			return tagged
		end
	end
	return nil
end

local function onEntityDestroyed(entityId: string)
	if type(entityId) ~= "string" then
		return
	end

	local model = findEntityById(entityId)
	if model ~= nil then
		for _, descendant in ipairs(model:GetDescendants()) do
			if descendant:IsA("BasePart") then
				descendant.Transparency = 1
			end
		end
	end

	CombatHUD.onEntityDestroyed(entityId)
end

local function onEntityRespawned(payload)
	if type(payload) ~= "table" or type(payload.entityId) ~= "string" then
		return
	end

	local model = findEntityById(payload.entityId)
	if model ~= nil then
		for _, descendant in ipairs(model:GetDescendants()) do
			if descendant:IsA("BasePart") then
				descendant.Transparency = 0
			end
		end
	end

	CombatHUD.onEntityRespawned(payload)
end

CombatHUD.init()
WeaponClient.init(remotesFolder)
ProjectileVisuals.init(remotesFolder)

-- Keep references so all required remotes are guaranteed to exist in pass 1.
local _ = fireWeaponRemote
_ = projectileFiredRemote

damageAppliedRemote.OnClientEvent:Connect(function(payload)
	CombatHUD.onDamageApplied(payload)
end)

entityDestroyedRemote.OnClientEvent:Connect(onEntityDestroyed)
entityRespawnedRemote.OnClientEvent:Connect(onEntityRespawned)
