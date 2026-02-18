--!strict

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local sharedRoot = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatConfig = require(sharedRoot:WaitForChild("CombatConfig"))
local CombatTypes = require(sharedRoot:WaitForChild("CombatTypes"))

local ServerScriptService = game:GetService("ServerScriptService")
local serverRoot = ServerScriptService:WaitForChild("CombatFramework")
local HealthManager = require(serverRoot:WaitForChild("Health"):WaitForChild("HealthManager"))

type ProjectileData = CombatTypes.ProjectileData

local ProjectileServer = {}

local remotesFolder: Folder? = nil
local projectileFiredRemote: RemoteEvent? = nil
local heartbeatConnection: RBXScriptConnection? = nil

local activeProjectiles: { [string]: ProjectileData } = {}
local raycastParams = RaycastParams.new()
local raycastExcludeList: { Instance } = {}
local projectileIdsToRemove: { string } = {}

local function getProjectileRemote(): RemoteEvent
	if projectileFiredRemote == nil then
		error("ProjectileServer not initialized with remotes")
	end
	return projectileFiredRemote
end

local function stepProjectiles(dt: number)
	table.clear(projectileIdsToRemove)
	local now = tick()

	for projectileId, projectile in pairs(activeProjectiles) do
		local elapsed = now - projectile.createdAt
		local previousElapsed = math.max(0, elapsed - dt)
		local currentPosition = projectile.origin + projectile.direction * projectile.speed * elapsed
		local previousPosition = projectile.origin + projectile.direction * projectile.speed * previousElapsed
		local traveledDistance = (currentPosition - projectile.origin).Magnitude

		if traveledDistance >= projectile.maxRange then
			print(string.format("[P1_EXPIRED] projectile=%s distance=%.2f", projectileId, traveledDistance))
			table.insert(projectileIdsToRemove, projectileId)
			continue
		end

		local sweepDirection = currentPosition - previousPosition
		if sweepDirection.Magnitude <= 0 then
			continue
		end

		table.clear(raycastExcludeList)
		raycastExcludeList[1] = projectile.sourceInstance
		raycastParams.FilterDescendantsInstances = raycastExcludeList

		local hitResult: RaycastResult?
		if CombatConfig.ProjectileRayRadius > 0 then
			hitResult = Workspace:Spherecast(previousPosition, CombatConfig.ProjectileRayRadius, sweepDirection, raycastParams)
		else
			hitResult = Workspace:Raycast(previousPosition, sweepDirection, raycastParams)
		end

		if hitResult ~= nil then
			local targetEntityId = HealthManager.findEntityFromInstance(hitResult.Instance)
			if targetEntityId ~= nil and HealthManager.isAlive(targetEntityId) then
				print(string.format("[P1_HIT] projectile=%s target=%s hitPos=%s", projectileId, targetEntityId, tostring(hitResult.Position)))
				HealthManager.applyDamage(
					targetEntityId,
					projectile.damage,
					projectile.damageType,
					projectile.faction,
					hitResult.Position
				)
			end

			table.insert(projectileIdsToRemove, projectileId)
		end
	end

	for _, projectileId in ipairs(projectileIdsToRemove) do
		activeProjectiles[projectileId] = nil
	end
end

function ProjectileServer.init(remotes: Folder)
	remotesFolder = remotes
	projectileFiredRemote = remotesFolder:WaitForChild("ProjectileFired") :: RemoteEvent

	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.IgnoreWater = true

	if heartbeatConnection == nil then
		heartbeatConnection = RunService.Heartbeat:Connect(stepProjectiles)
	end
end

function ProjectileServer.fireProjectile(data: ProjectileData)
	activeProjectiles[data.projectileId] = data

	local projectileRemote = getProjectileRemote()
	projectileRemote:FireAllClients({
		projectileId = data.projectileId,
		origin = data.origin,
		direction = data.direction,
		speed = data.speed,
		maxRange = data.maxRange,
	})

	print(string.format(
		"[P1_FIRE] projectile=%s source=%s dir=%s speed=%d",
		data.projectileId,
		data.sourceEntityId,
		tostring(data.direction),
		data.speed
	))
end

function ProjectileServer.getActiveCount(): number
	local count = 0
	for _ in pairs(activeProjectiles) do
		count += 1
	end
	return count
end

return ProjectileServer
