--!strict

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local sharedRoot = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatConfig = require(sharedRoot:WaitForChild("CombatConfig"))
local CombatTypes = require(sharedRoot:WaitForChild("CombatTypes"))

local serverRoot = ServerScriptService:WaitForChild("CombatFramework")
local StartupValidator = require(serverRoot:WaitForChild("Authoring"):WaitForChild("StartupValidator"))
local HealthManager = require(serverRoot:WaitForChild("Health"):WaitForChild("HealthManager"))
local ProjectileServer = require(serverRoot:WaitForChild("Projectiles"):WaitForChild("ProjectileServer"))
local WeaponServer = require(serverRoot:WaitForChild("Weapons"):WaitForChild("WeaponServer"))
local Runner = require(serverRoot:WaitForChild("TestHarness"):WaitForChild("Runner"))

type ValidatedEntity = CombatTypes.ValidatedEntity

local function createRemoteEvent(parent: Folder, name: string): RemoteEvent
	local existing = parent:FindFirstChild(name)
	if existing ~= nil then
		if existing:IsA("RemoteEvent") then
			return existing
		end
		existing:Destroy()
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = parent
	return remote
end

local function createRemotesFolder(): Folder
	local existing = ReplicatedStorage:FindFirstChild("CombatRemotes")
	if existing ~= nil and not existing:IsA("Folder") then
		existing:Destroy()
		existing = nil
	end

	local folder = existing :: Folder?
	if folder == nil then
		folder = Instance.new("Folder")
		folder.Name = "CombatRemotes"
		folder.Parent = ReplicatedStorage
	end

	createRemoteEvent(folder, "FireWeapon")
	createRemoteEvent(folder, "ProjectileFired")
	createRemoteEvent(folder, "DamageApplied")
	createRemoteEvent(folder, "EntityDestroyed")
	createRemoteEvent(folder, "EntityRespawned")

	return folder
end

local function addTurretPrompt(turretSeat: Seat, entityId: string)
	local prompt = turretSeat:FindFirstChildOfClass("ProximityPrompt")
	if prompt == nil then
		prompt = Instance.new("ProximityPrompt")
		prompt.Name = "ManTurretPrompt"
		prompt.Parent = turretSeat
	end

	prompt.ActionText = CombatConfig.TurretPromptText
	prompt.ObjectText = "Turret"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = CombatConfig.TurretPromptDistance
	prompt.RequiresLineOfSight = false
	prompt.KeyboardKeyCode = Enum.KeyCode.E

	prompt.Triggered:Connect(function(player: Player)
		if not HealthManager.isAlive(entityId) then
			return
		end

		local character = player.Character
		if character == nil then
			return
		end

		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid == nil then
			return
		end

		turretSeat:Sit(humanoid)
	end)
end

local remotesFolder = createRemotesFolder()

HealthManager.init(remotesFolder)
ProjectileServer.init(remotesFolder)
WeaponServer.init(remotesFolder)

if CombatConfig.TestHarnessEnabled then
	Runner.setup()
end

local validatedEntities: { ValidatedEntity } = StartupValidator.validate()
local nextEntityIndex = 0

for _, validatedEntity in ipairs(validatedEntities) do
	nextEntityIndex += 1
	local entityId = "entity_" .. tostring(nextEntityIndex)

	validatedEntity.instance:SetAttribute("EntityId", entityId)
	HealthManager.registerEntity(entityId, validatedEntity)

	if validatedEntity.turretSeat ~= nil then
		CollectionService:AddTag(validatedEntity.turretSeat, "TurretSeat")
		addTurretPrompt(validatedEntity.turretSeat, entityId)
	end
end

if CombatConfig.TestHarnessEnabled then
	task.spawn(function()
		Runner.run()
	end)
end
