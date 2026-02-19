--!strict

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")

local sharedRoot = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatConfig = require(sharedRoot:WaitForChild("CombatConfig"))
local CombatEnums = require(sharedRoot:WaitForChild("CombatEnums"))
local CombatTypes = require(sharedRoot:WaitForChild("CombatTypes"))

local ServerScriptService = game:GetService("ServerScriptService")
local serverRoot = ServerScriptService:WaitForChild("CombatFramework")
local HealthManager = require(serverRoot:WaitForChild("Health"):WaitForChild("HealthManager"))

type ProjectileData = CombatTypes.ProjectileData
type ProjectileImpactPayload = CombatTypes.ProjectileImpactPayload
type HitConfirmPayload = CombatTypes.HitConfirmPayload

local ProjectileServer = {}

local remotesFolder: Folder? = nil
local projectileFiredRemote: RemoteEvent? = nil
local projectileImpactRemote: RemoteEvent? = nil
local hitConfirmRemote: RemoteEvent? = nil
local heartbeatConnection: RBXScriptConnection? = nil

local activeProjectiles: { [string]: ProjectileData } = {}
local raycastParams = RaycastParams.new()
local raycastExcludeList: { Instance } = {}
local overlapParams = OverlapParams.new()
local projectileIdsToRemove: { string } = {}
local homingLogTimeByProjectileId: { [string]: number } = {}
local homingLostLoggedByProjectileId: { [string]: boolean } = {}

local function distancePointToPartBounds(point: Vector3, part: BasePart): number
	local localPoint = part.CFrame:PointToObjectSpace(point)
	local halfSize = part.Size * 0.5
	local dx = math.max(math.abs(localPoint.X) - halfSize.X, 0)
	local dy = math.max(math.abs(localPoint.Y) - halfSize.Y, 0)
	local dz = math.max(math.abs(localPoint.Z) - halfSize.Z, 0)
	return math.sqrt(dx * dx + dy * dy + dz * dz)
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

local function applyDamageToHumanoidTarget(
	projectile: ProjectileData,
	targetModel: Model,
	hitPosition: Vector3,
	damageAmount: number?
): (boolean, boolean, string?, string?, boolean)
	local humanoid = targetModel:FindFirstChildOfClass("Humanoid")
	if humanoid == nil or humanoid.Health <= 0 then
		return false, false, nil, nil, false
	end

	local targetPlayer = Players:GetPlayerFromCharacter(targetModel)
	if projectile.sourceCharacter ~= nil and targetModel == projectile.sourceCharacter then
		return false, false, nil, nil, false
	end

	if not CombatConfig.FriendlyFireEnabled and targetPlayer ~= nil then
		local attackerFaction = normalizeTeamOrFaction(projectile.faction)
		local targetFaction = normalizeTeamOrFaction(if targetPlayer.Team ~= nil then targetPlayer.Team.Name else nil)
		if attackerFaction ~= nil and targetFaction ~= nil and attackerFaction == targetFaction then
			print(string.format("[P1_FACTION_BLOCK] attackerFaction=%s targetPlayer=%s", attackerFaction, targetPlayer.Name))
			return false, false, nil, nil, false
		end
	end

	local seatPart = humanoid.SeatPart
	if seatPart ~= nil and CollectionService:HasTag(seatPart, "TurretSeat") then
		local seatedTurret = seatPart:FindFirstAncestorWhichIsA("Model")
		if seatedTurret ~= nil and seatedTurret:GetAttribute("TurretExposed") ~= true then
			local turretEntityId = seatedTurret:GetAttribute("EntityId")
			local playerName = if targetPlayer ~= nil then targetPlayer.Name else targetModel.Name
			print(string.format(
				"[P4_ENCLOSED_BLOCK] projectile=%s player=%s turret=%s",
				projectile.projectileId,
				playerName,
				tostring(turretEntityId)
			))
			return false, false, nil, nil, false
		end
	end

	local appliedDamage = math.max(0, damageAmount or projectile.damage)
	if appliedDamage <= 0 then
		return false, false, nil, nil, false
	end

	local previousHealth = humanoid.Health
	humanoid:TakeDamage(appliedDamage)
	local killed = previousHealth > 0 and humanoid.Health <= 0
	local targetId = if targetPlayer ~= nil then ("player_" .. tostring(targetPlayer.UserId)) else targetModel:GetFullName()
	print(
		string.format(
			"[P1_HIT_PLAYER] projectile=%s target=%s %.1f->%.1f",
			projectile.projectileId,
			targetId,
			previousHealth,
			humanoid.Health
		)
	)
	return true, killed, targetId, CombatEnums.ImpactType.Hull, false
end

local function applyDamageToCombatEntity(
	projectile: ProjectileData,
	targetEntityId: string,
	hitPosition: Vector3,
	damageAmount: number?
): (boolean, boolean, string, string?, boolean)
	local previousState = HealthManager.getHealth(targetEntityId)
	local previousHP = if previousState ~= nil then previousState.currentHP else 0
	local appliedDamage = math.max(0, damageAmount or projectile.damage)
	if appliedDamage <= 0 then
		return false, false, targetEntityId, nil, false
	end

	print(string.format("[P1_HIT] projectile=%s target=%s hitPos=%s", projectile.projectileId, targetEntityId, tostring(hitPosition)))
	local didApplyDamage, impactType, didBreakShield = HealthManager.applyDamage(
		targetEntityId,
		appliedDamage,
		projectile.damageType,
		projectile.faction,
		hitPosition
	)
	local nextState = HealthManager.getHealth(targetEntityId)
	local nextHP = if nextState ~= nil then nextState.currentHP else 0
	local didKill = didApplyDamage and previousHP > 0 and nextHP <= 0
	return didApplyDamage, didKill, targetEntityId, impactType, didBreakShield
end

local function applyDamageForHitInstance(
	projectile: ProjectileData,
	hitInstance: Instance,
	hitPosition: Vector3,
	damageAmount: number?
): (boolean, boolean, string?, string?, boolean)
	local targetEntityId = HealthManager.findEntityFromInstance(hitInstance)
	if targetEntityId ~= nil and HealthManager.isAlive(targetEntityId) then
		local didApplyDamage, didKill, targetId, impactType, didBreakShield =
			applyDamageToCombatEntity(projectile, targetEntityId, hitPosition, damageAmount)
		return didApplyDamage, didKill, targetId, impactType, didBreakShield
	end

	local targetModel = hitInstance:FindFirstAncestorOfClass("Model")
	if targetModel ~= nil then
		return applyDamageToHumanoidTarget(projectile, targetModel, hitPosition, damageAmount)
	end

	return false, false, nil, nil, false
end

local function applySplashDamage(
	projectile: ProjectileData,
	hitPosition: Vector3,
	directTargetId: string?,
	directTargetModel: Model?
): (boolean, boolean, string?)
	local radius = if type(projectile.splashRadius) == "number" then projectile.splashRadius else 0
	if radius <= 0 then
		return false, false, nil
	end

	table.clear(raycastExcludeList)
	raycastExcludeList[1] = projectile.sourceInstance
	if projectile.sourceCharacter ~= nil then
		raycastExcludeList[2] = projectile.sourceCharacter
	end
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = raycastExcludeList
	overlapParams.MaxParts = 128

	local nearbyParts = Workspace:GetPartBoundsInRadius(hitPosition, radius, overlapParams)
	local closestDistanceByEntityId: { [string]: number } = {}
	local closestDistanceByModel: { [Model]: number } = {}
	local didAnyDamage = false
	local didAnyKill = false
	local firstTargetId: string? = nil

	for _, part in ipairs(nearbyParts) do
		local distance = distancePointToPartBounds(hitPosition, part)
		if distance > radius then
			continue
		end

		local entityId = HealthManager.findEntityFromInstance(part)
		if entityId ~= nil then
			if entityId ~= directTargetId then
				local previous = closestDistanceByEntityId[entityId]
				if previous == nil or distance < previous then
					closestDistanceByEntityId[entityId] = distance
				end
			end
		else
			local model = part:FindFirstAncestorOfClass("Model")
			if model ~= nil and model ~= directTargetModel then
				local previous = closestDistanceByModel[model]
				if previous == nil or distance < previous then
					closestDistanceByModel[model] = distance
				end
			end
		end
	end

	for entityId, distance in pairs(closestDistanceByEntityId) do
		if HealthManager.isAlive(entityId) then
			local scale = math.clamp(1 - (distance / math.max(radius, 1e-4)), 0, 1)
			local splashDamage = math.max(0, math.floor(projectile.damage * scale + 0.5))
			if splashDamage > 0 then
				local didDamage, didKill, targetId = applyDamageToCombatEntity(projectile, entityId, hitPosition, splashDamage)
				if didDamage then
					didAnyDamage = true
					didAnyKill = didAnyKill or didKill
					if firstTargetId == nil then
						firstTargetId = targetId
					end
				end
			end
		end
	end

	for model, distance in pairs(closestDistanceByModel) do
		local scale = math.clamp(1 - (distance / math.max(radius, 1e-4)), 0, 1)
		local splashDamage = math.max(0, math.floor(projectile.damage * scale + 0.5))
		if splashDamage > 0 then
			local didDamage, didKill, targetId = applyDamageToHumanoidTarget(projectile, model, hitPosition, splashDamage)
			if didDamage then
				didAnyDamage = true
				didAnyKill = didAnyKill or didKill
				if firstTargetId == nil then
					firstTargetId = targetId
				end
			end
		end
	end

	return didAnyDamage, didAnyKill, firstTargetId
end

local function getProjectileRemote(): RemoteEvent
	if projectileFiredRemote == nil then
		error("ProjectileServer not initialized with remotes")
	end
	return projectileFiredRemote
end

local function getProjectileImpactRemote(): RemoteEvent
	if projectileImpactRemote == nil then
		error("ProjectileServer not initialized with impact remote")
	end
	return projectileImpactRemote
end

local function getHitConfirmRemote(): RemoteEvent
	if hitConfirmRemote == nil then
		error("ProjectileServer not initialized with hit confirm remote")
	end
	return hitConfirmRemote
end

local function rotateDirectionToward(currentDirection: Vector3, targetDirection: Vector3, maxTurnRadians: number): Vector3
	if currentDirection.Magnitude < 1e-4 then
		return targetDirection.Unit
	end
	if targetDirection.Magnitude < 1e-4 then
		return currentDirection.Unit
	end
	if maxTurnRadians <= 0 then
		return currentDirection.Unit
	end

	local currentUnit = currentDirection.Unit
	local targetUnit = targetDirection.Unit
	local dot = math.clamp(currentUnit:Dot(targetUnit), -1, 1)
	local angle = math.acos(dot)
	if angle <= maxTurnRadians then
		return targetUnit
	end

	local alpha = maxTurnRadians / math.max(angle, 1e-4)
	return (currentUnit:Lerp(targetUnit, alpha)).Unit
end

local function getTargetPositionForHoming(targetEntityId: string): Vector3?
	if not HealthManager.isAlive(targetEntityId) then
		return nil
	end

	local targetState = HealthManager.getHealth(targetEntityId)
	if targetState == nil or targetState.instance.Parent == nil then
		return nil
	end

	return targetState.instance:GetPivot().Position
end

local function stepProjectiles(dt: number)
	table.clear(projectileIdsToRemove)
	local now = tick()

	for projectileId, projectile in pairs(activeProjectiles) do
		local previousPosition: Vector3
		local currentPosition: Vector3
		local homingActive = type(projectile.targetEntityId) == "string"
			and type(projectile.homingTurnRate) == "number"
			and (projectile.homingTurnRate :: number) > 0

		if homingActive then
			previousPosition = projectile.currentPosition or projectile.origin
			local targetPosition = getTargetPositionForHoming(projectile.targetEntityId :: string)
			if targetPosition ~= nil then
				local toTarget = targetPosition - previousPosition
				if toTarget.Magnitude > 1e-4 then
					local currentDirection = projectile.direction.Unit
					local maxTurnRadians = math.rad(projectile.homingTurnRate :: number) * dt
					local rotatedDirection = rotateDirectionToward(currentDirection, toTarget.Unit, maxTurnRadians)
					projectile.direction = rotatedDirection

					local logGate = homingLogTimeByProjectileId[projectileId]
					if logGate == nil or now - logGate >= 0.2 then
						local turnDot = math.clamp(currentDirection:Dot(rotatedDirection), -1, 1)
						local turnAngleDegrees = math.deg(math.acos(turnDot))
						print(string.format(
							"[P4_HOMING] projectile=%s target=%s turn=%.2f",
							projectileId,
							projectile.targetEntityId :: string,
							turnAngleDegrees
						))
						homingLogTimeByProjectileId[projectileId] = now
					end
				end
			elseif not homingLostLoggedByProjectileId[projectileId] then
				print(string.format(
					"[P4_HOMING_LOST] projectile=%s target=%s",
					projectileId,
					tostring(projectile.targetEntityId)
				))
				homingLostLoggedByProjectileId[projectileId] = true
			end

			currentPosition = previousPosition + projectile.direction.Unit * projectile.speed * dt
			projectile.currentPosition = currentPosition
		else
			local elapsed = now - projectile.createdAt
			local previousElapsed = math.max(0, elapsed - dt)
			currentPosition = projectile.origin + projectile.direction * projectile.speed * elapsed
			previousPosition = projectile.origin + projectile.direction * projectile.speed * previousElapsed
		end

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
		if projectile.sourceCharacter ~= nil then
			raycastExcludeList[2] = projectile.sourceCharacter
		end
		raycastParams.FilterDescendantsInstances = raycastExcludeList

		local hitResult: RaycastResult?
		if CombatConfig.ProjectileRayRadius > 0 then
			hitResult = Workspace:Spherecast(previousPosition, CombatConfig.ProjectileRayRadius, sweepDirection, raycastParams)
		else
			hitResult = Workspace:Raycast(previousPosition, sweepDirection, raycastParams)
		end

		if hitResult ~= nil then
			local hitInstance = hitResult.Instance
			if hitInstance:IsDescendantOf(projectile.sourceInstance)
				or (projectile.sourceCharacter ~= nil and hitInstance:IsDescendantOf(projectile.sourceCharacter))
			then
				continue
			end

			local didApplyDamage, didKill, hitTargetId, impactType, shieldBroken =
				applyDamageForHitInstance(projectile, hitInstance, hitResult.Position, projectile.damage)

			local directTargetModel = hitInstance:FindFirstAncestorOfClass("Model")
			local didSplashDamage, didSplashKill, splashTargetId =
				applySplashDamage(projectile, hitResult.Position, hitTargetId, directTargetModel)
			if didSplashDamage then
				didApplyDamage = true
				didKill = didKill or didSplashKill
				if hitTargetId == nil then
					hitTargetId = splashTargetId
				end
			end

			local impactPayload: ProjectileImpactPayload = {
				projectileId = projectileId,
				hitPosition = hitResult.Position,
				hitNormal = hitResult.Normal,
				impactType = impactType or CombatEnums.ImpactType.Environment,
				shieldBroken = if shieldBroken then true else nil,
			}
			getProjectileImpactRemote():FireAllClients(impactPayload)

			if didApplyDamage and projectile.sourceCharacter ~= nil then
				local shooterPlayer = Players:GetPlayerFromCharacter(projectile.sourceCharacter)
				if shooterPlayer ~= nil then
					local hitConfirmPayload: HitConfirmPayload = {
						targetEntityId = hitTargetId or "unknown",
						hitPosition = hitResult.Position,
						isKill = didKill,
					}
					getHitConfirmRemote():FireClient(shooterPlayer, hitConfirmPayload)
				end
			end

			table.insert(projectileIdsToRemove, projectileId)
		end
	end

	for _, projectileId in ipairs(projectileIdsToRemove) do
		activeProjectiles[projectileId] = nil
		homingLogTimeByProjectileId[projectileId] = nil
		homingLostLoggedByProjectileId[projectileId] = nil
	end
end

function ProjectileServer.init(remotes: Folder)
	remotesFolder = remotes
	projectileFiredRemote = remotesFolder:WaitForChild("ProjectileFired") :: RemoteEvent
	projectileImpactRemote = remotesFolder:WaitForChild("ProjectileImpact") :: RemoteEvent
	hitConfirmRemote = remotesFolder:WaitForChild("HitConfirm") :: RemoteEvent

	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.IgnoreWater = true
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.MaxParts = 128

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
		damageType = data.damageType,
		targetEntityId = data.targetEntityId,
		homingTurnRate = data.homingTurnRate,
		boltColor = data.boltColor,
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
