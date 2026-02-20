--!strict

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local sharedRoot = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatConfig = require(sharedRoot:WaitForChild("CombatConfig"))
local CombatTypes = require(sharedRoot:WaitForChild("CombatTypes"))

local serverRoot = ServerScriptService:WaitForChild("CombatFramework")
local StartupValidator = require(serverRoot:WaitForChild("Authoring"):WaitForChild("StartupValidator"))
local HealthManager = require(serverRoot:WaitForChild("Health"):WaitForChild("HealthManager"))
local ProjectileServer = require(serverRoot:WaitForChild("Projectiles"):WaitForChild("ProjectileServer"))
local TargetingServer = require(serverRoot:WaitForChild("Targeting"):WaitForChild("TargetingServer"))
local TestHarnessRunner = require(serverRoot:WaitForChild("TestHarness"):WaitForChild("Runner"))
local VehicleServer = require(serverRoot:WaitForChild("Vehicles"):WaitForChild("VehicleServer"))
local WeaponServer = require(serverRoot:WaitForChild("Weapons"):WaitForChild("WeaponServer"))

type ValidatedEntity = CombatTypes.ValidatedEntity

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
	createRemoteEvent(folder, "UpdateTurretAim")
	createRemoteEvent(folder, "ProjectileFired")
	createRemoteEvent(folder, "ProjectileImpact")
	createRemoteEvent(folder, "DamageApplied")
	createRemoteEvent(folder, "HitConfirm")
	createRemoteEvent(folder, "EntityDestroyed")
	createRemoteEvent(folder, "EntityRespawned")
	createRemoteEvent(folder, "RequestLockOn")
	createRemoteEvent(folder, "ClearLockOn")
	createRemoteEvent(folder, "LockOnState")
	createRemoteEvent(folder, "VehicleInput")
	createRemoteEvent(folder, "VehicleExitRequest")

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

		local turretFaction = normalizeTeamOrFaction(HealthManager.getFaction(entityId))
		if turretFaction == nil then
			return
		end

		local team = player.Team
		if team == nil then
			print(string.format("[P1_TURRET_DENY] player=%s entity=%s reason=no_team", player.Name, entityId))
			return
		end

		local playerFaction = normalizeTeamOrFaction(team.Name)
		if playerFaction == nil or playerFaction ~= turretFaction then
			print(
				string.format(
					"[P1_TURRET_DENY] player=%s entity=%s team=%s faction=%s reason=faction_mismatch",
					player.Name,
					entityId,
					tostring(team.Name),
					tostring(turretFaction)
				)
			)
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

local function findDriverSeat(model: Model): Seat?
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("Seat") and CollectionService:HasTag(descendant, "DriverSeat") then
			return descendant
		end
	end
	return nil
end

local function collectHoverPoints(model: Model): { BasePart }
	local points: { BasePart } = {}
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") and CollectionService:HasTag(descendant, "HoverPoint") then
			table.insert(points, descendant)
		end
	end

	table.sort(points, function(a: BasePart, b: BasePart)
		return a:GetFullName() < b:GetFullName()
	end)

	return points
end

local remotesFolder = createRemotesFolder()
local harnessEnabled = TestHarnessRunner.isEnabled() or Workspace:GetAttribute("CombatTestHarnessEnabled") == true

HealthManager.init(remotesFolder)
ProjectileServer.init(remotesFolder)
TargetingServer.init(remotesFolder)
WeaponServer.init(remotesFolder)
VehicleServer.init(remotesFolder)
if harnessEnabled then
	TestHarnessRunner.setup()
end
HealthManager.setRespawnCallback(function(entityId: string)
	TargetingServer.clearLock(entityId)
	WeaponServer.resetEntity(entityId)
end)
HealthManager.setDestroyCallback(function(entityId: string)
	VehicleServer.onEntityDestroyed(entityId)
end)

local validatedEntities: { ValidatedEntity } = StartupValidator.validate()
local nextEntityIndex = 0

for _, validatedEntity in ipairs(validatedEntities) do
	nextEntityIndex += 1
	local entityId = "entity_" .. tostring(nextEntityIndex)

	validatedEntity.instance:SetAttribute("EntityId", entityId)
	local entityConfig = CombatConfig.Entities[validatedEntity.configId]
	local turretExposed = false
	if entityConfig ~= nil and entityConfig.turretExposed == true then
		turretExposed = true
	end
	validatedEntity.instance:SetAttribute("TurretExposed", turretExposed)
	HealthManager.registerEntity(entityId, validatedEntity)
	WeaponServer.registerEntity(entityId)
	if CollectionService:HasTag(validatedEntity.instance, "VehicleEntity") then
		local vehicleConfigId = validatedEntity.instance:GetAttribute("VehicleConfigId")
		if type(vehicleConfigId) == "string" and CombatConfig.Vehicles[vehicleConfigId] ~= nil then
			local driverSeat = findDriverSeat(validatedEntity.instance)
			local hoverPoints = collectHoverPoints(validatedEntity.instance)
			if driverSeat ~= nil and #hoverPoints >= 4 then
				VehicleServer.registerVehicle(entityId, validatedEntity.instance, vehicleConfigId, driverSeat, hoverPoints)
			end
		end
	end

	if validatedEntity.turretSeat ~= nil then
		CollectionService:AddTag(validatedEntity.turretSeat, "TurretSeat")
		addTurretPrompt(validatedEntity.turretSeat, entityId)
	end
end

if harnessEnabled then
	task.spawn(function()
		TestHarnessRunner.run()
	end)
end
