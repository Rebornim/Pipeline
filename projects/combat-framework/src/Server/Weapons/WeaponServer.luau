--!strict

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local sharedRoot = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatConfig = require(sharedRoot:WaitForChild("CombatConfig"))
local CombatTypes = require(sharedRoot:WaitForChild("CombatTypes"))

local serverRoot = ServerScriptService:WaitForChild("CombatFramework")
local HealthManager = require(serverRoot:WaitForChild("Health"):WaitForChild("HealthManager"))
local ProjectileServer = require(serverRoot:WaitForChild("Projectiles"):WaitForChild("ProjectileServer"))

type HealthState = CombatTypes.HealthState
type ProjectileData = CombatTypes.ProjectileData

local WeaponServer = {}

local remotesFolder: Folder? = nil
local fireWeaponRemote: RemoteEvent? = nil
local fireConnection: RBXScriptConnection? = nil
local playerRemovingConnection: RBXScriptConnection? = nil

local lastFireTimeByPlayer: { [Player]: number } = {}
local projectileCounter = 0

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

local function getFireRemote(): RemoteEvent
	if fireWeaponRemote == nil then
		error("WeaponServer not initialized with remotes")
	end
	return fireWeaponRemote
end

local function onFireWeapon(player: Player, aimDirection: Vector3)
	if typeof(aimDirection) ~= "Vector3" then
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

	local seatPart = humanoid.SeatPart
	if seatPart == nil then
		return
	end

	if not CollectionService:HasTag(seatPart, "TurretSeat") then
		return
	end

	local entityModel = seatPart:FindFirstAncestorWhichIsA("Model")
	if entityModel == nil then
		return
	end

	local entityIdAttr = entityModel:GetAttribute("EntityId")
	if type(entityIdAttr) ~= "string" then
		return
	end
	local entityId = entityIdAttr

	if not HealthManager.isAlive(entityId) then
		return
	end

	local healthState: HealthState? = HealthManager.getHealth(entityId)
	if healthState == nil or healthState.config.weaponId == nil then
		return
	end

	local weaponConfig = CombatConfig.Weapons[healthState.config.weaponId]
	if weaponConfig == nil or weaponConfig.fireRate <= 0 then
		return
	end

	local now = tick()
	local cooldown = 1 / weaponConfig.fireRate
	local lastFireTime = lastFireTimeByPlayer[player]
	if lastFireTime ~= nil and now - lastFireTime < cooldown then
		return
	end

	local mountCandidate = findTaggedDescendant(entityModel, "WeaponMount", "BasePart")
	if mountCandidate == nil then
		return
	end
	local weaponMount = mountCandidate :: BasePart

	local muzzlePoint = weaponMount:FindFirstChild("MuzzlePoint")
	local fireOrigin = weaponMount.Position
	if muzzlePoint ~= nil and muzzlePoint:IsA("Attachment") then
		fireOrigin = muzzlePoint.WorldPosition
	end

	if aimDirection.Magnitude < 1e-4 then
		return
	end

	local normalizedDirection = aimDirection.Unit
	local faction = HealthManager.getFaction(entityId)
	if faction == nil then
		return
	end

	projectileCounter += 1
	local projectileId = "proj_" .. tostring(projectileCounter)

	local projectileData: ProjectileData = {
		projectileId = projectileId,
		sourceEntityId = entityId,
		sourceInstance = healthState.instance,
		origin = fireOrigin,
		direction = normalizedDirection,
		speed = weaponConfig.projectileSpeed,
		maxRange = weaponConfig.maxRange,
		damage = weaponConfig.damage,
		damageType = weaponConfig.damageType,
		faction = faction,
		createdAt = now,
	}

	ProjectileServer.fireProjectile(projectileData)
	lastFireTimeByPlayer[player] = now
end

function WeaponServer.init(remotes: Folder)
	remotesFolder = remotes
	fireWeaponRemote = remotesFolder:WaitForChild("FireWeapon") :: RemoteEvent

	if fireConnection == nil then
		fireConnection = getFireRemote().OnServerEvent:Connect(onFireWeapon)
	end

	if playerRemovingConnection == nil then
		playerRemovingConnection = Players.PlayerRemoving:Connect(function(player)
			lastFireTimeByPlayer[player] = nil
		end)
	end
end

return WeaponServer
