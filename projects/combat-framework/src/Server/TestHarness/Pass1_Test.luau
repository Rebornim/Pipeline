--!strict

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local sharedRoot = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatConfig = require(sharedRoot:WaitForChild("CombatConfig"))
local CombatEnums = require(sharedRoot:WaitForChild("CombatEnums"))
local CombatTypes = require(sharedRoot:WaitForChild("CombatTypes"))

local serverRoot = ServerScriptService:WaitForChild("CombatFramework")
local HealthManager = require(serverRoot:WaitForChild("Health"):WaitForChild("HealthManager"))
local ProjectileServer = require(serverRoot:WaitForChild("Projectiles"):WaitForChild("ProjectileServer"))

type HealthState = CombatTypes.HealthState
type ProjectileData = CombatTypes.ProjectileData

local Pass1_Test = {}

local TEST_FOLDER_NAME = "Pass1TestRig"

local testFolder: Folder? = nil
local testProjectileCounter = 0

local entities = {
	mainTurret = nil :: Model?,
	mainTarget = nil :: Model?,
	friendlyTurret = nil :: Model?,
	lowHpTarget = nil :: Model?,
	farTarget = nil :: Model?,
}

local function resetRigFolder()
	local existing = Workspace:FindFirstChild(TEST_FOLDER_NAME)
	if existing ~= nil then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = TEST_FOLDER_NAME
	folder.Parent = Workspace
	testFolder = folder
end

local function ensureTestFolder(): Folder
	if testFolder == nil or testFolder.Parent == nil then
		resetRigFolder()
	end
	return testFolder :: Folder
end

local function createTurret(name: string, basePosition: Vector3, faction: string, configId: string): Model
	local folder = ensureTestFolder()

	local model = Instance.new("Model")
	model.Name = name
	model.Parent = folder
	model:SetAttribute("Faction", faction)
	model:SetAttribute("ConfigId", configId)
	CollectionService:AddTag(model, "CombatEntity")

	local base = Instance.new("Part")
	base.Name = "Base"
	base.Size = Vector3.new(8, 2, 8)
	base.Anchored = true
	base.Position = basePosition
	base.Parent = model

	local barrel = Instance.new("Part")
	barrel.Name = "Barrel"
	barrel.Size = Vector3.new(1, 1, 5)
	barrel.Anchored = true
	barrel.Position = basePosition + Vector3.new(0, 2, -2)
	barrel.Parent = model
	CollectionService:AddTag(barrel, "WeaponMount")

	local muzzle = Instance.new("Attachment")
	muzzle.Name = "MuzzlePoint"
	muzzle.Position = Vector3.new(0, 0, -2.5)
	muzzle.Parent = barrel

	local seat = Instance.new("Seat")
	seat.Name = "Seat"
	seat.Anchored = true
	seat.Size = Vector3.new(2, 1, 2)
	seat.Position = basePosition + Vector3.new(0, 2, 0)
	seat.Parent = model
	CollectionService:AddTag(seat, "TurretSeat")

	model.PrimaryPart = base
	return model
end

local function createTarget(name: string, basePosition: Vector3, faction: string, configId: string): Model
	local folder = ensureTestFolder()

	local model = Instance.new("Model")
	model.Name = name
	model.Parent = folder
	model:SetAttribute("Faction", faction)
	model:SetAttribute("ConfigId", configId)
	CollectionService:AddTag(model, "CombatEntity")

	local body = Instance.new("Part")
	body.Name = "Body"
	body.Size = Vector3.new(4, 6, 4)
	body.Anchored = true
	body.Position = basePosition + Vector3.new(0, 3, 0)
	body.Parent = model

	model.PrimaryPart = body
	return model
end

local function getModelPosition(model: Model): Vector3
	if model.PrimaryPart ~= nil then
		return model.PrimaryPart.Position
	end

	local firstPart = model:FindFirstChildWhichIsA("BasePart", true)
	if firstPart ~= nil then
		return firstPart.Position
	end

	return Vector3.zero
end

local function waitForEntityId(model: Model, timeout: number): string?
	local started = tick()
	while tick() - started < timeout do
		local entityId = model:GetAttribute("EntityId")
		if type(entityId) == "string" and entityId ~= "" then
			return entityId
		end
		task.wait(0.1)
	end

	return nil
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

local function getHealthState(entityModel: Model): HealthState?
	local entityId = entityModel:GetAttribute("EntityId")
	if type(entityId) ~= "string" then
		return nil
	end
	return HealthManager.getHealth(entityId)
end

local function fireProjectileAt(sourceModel: Model, targetPosition: Vector3): boolean
	local sourceEntityId = sourceModel:GetAttribute("EntityId")
	if type(sourceEntityId) ~= "string" then
		warn("[P1_TEST] fire failed: source model missing EntityId")
		return false
	end

	local sourceState = HealthManager.getHealth(sourceEntityId)
	if sourceState == nil or sourceState.config.weaponId == nil then
		warn("[P1_TEST] fire failed: source entity missing weapon config")
		return false
	end

	local weaponConfig = CombatConfig.Weapons[sourceState.config.weaponId]
	if weaponConfig == nil then
		warn("[P1_TEST] fire failed: unknown weapon config")
		return false
	end

	local mountCandidate = findTaggedDescendant(sourceModel, "WeaponMount", "BasePart")
	if mountCandidate == nil then
		warn("[P1_TEST] fire failed: source model missing WeaponMount")
		return false
	end

	local weaponMount = mountCandidate :: BasePart
	local muzzlePoint = weaponMount:FindFirstChild("MuzzlePoint")
	local origin = weaponMount.Position
	if muzzlePoint ~= nil and muzzlePoint:IsA("Attachment") then
		origin = muzzlePoint.WorldPosition
	end

	local aimDirection = targetPosition - origin
	if aimDirection.Magnitude < 1e-4 then
		warn("[P1_TEST] fire failed: invalid direction")
		return false
	end

	testProjectileCounter += 1
	local data: ProjectileData = {
		projectileId = "test_proj_" .. tostring(testProjectileCounter),
		sourceEntityId = sourceEntityId,
		sourceInstance = sourceModel,
		origin = origin,
		direction = aimDirection.Unit,
		speed = weaponConfig.projectileSpeed,
		maxRange = weaponConfig.maxRange,
		damage = weaponConfig.damage,
		damageType = weaponConfig.damageType,
		faction = sourceState.faction,
		createdAt = tick(),
	}

	ProjectileServer.fireProjectile(data)
	return true
end

local function fireBurst(sourceModel: Model, targetModel: Model, shots: number, spacing: number): number
	local targetPosition = getModelPosition(targetModel)
	local fired = 0
	for _ = 1, shots do
		if fireProjectileAt(sourceModel, targetPosition) then
			fired += 1
		end
		task.wait(spacing)
	end
	return fired
end

function Pass1_Test.setup()
	resetRigFolder()

	if CombatConfig.Entities.target_dummy_lowhp == nil then
		CombatConfig.Entities.target_dummy_lowhp = {
			hullHP = 30,
			weaponId = nil,
			respawnTime = 5,
		}
	end

	entities.mainTurret = createTurret("TestTurret", Vector3.new(0, 5, 0), CombatEnums.Faction.Empire, "blaster_turret")
	entities.mainTarget = createTarget("TestTarget", Vector3.new(0, 5, 50), CombatEnums.Faction.Rebel, "target_dummy")
	entities.friendlyTurret = createTurret("FriendlyTurret", Vector3.new(20, 5, 50), CombatEnums.Faction.Empire, "blaster_turret")
	entities.lowHpTarget = createTarget("LowHpTarget", Vector3.new(35, 5, 50), CombatEnums.Faction.Rebel, "target_dummy_lowhp")
	entities.farTarget = createTarget("FarTarget", Vector3.new(300, 5, 700), CombatEnums.Faction.Rebel, "target_dummy")

	print("[P1_TEST] setup complete")
end

function Pass1_Test.run()
	print("========== START READ HERE (P1) ==========")

	for key, model in pairs(entities) do
		if model == nil then
			warn(string.format("[P1_TEST] missing model in setup: %s", key))
			print("[P1_SUMMARY] Shots:0 | Hits:0 | Expired:0 | Kills:0 | Respawns:0 | FactionBlocks:0 | FAIL")
			print("========== END READ HERE (P1) ==========")
			return
		end

		local entityId = waitForEntityId(model, 6)
		if entityId == nil then
			warn(string.format("[P1_TEST] model did not register in time: %s", model.Name))
			print("[P1_SUMMARY] Shots:0 | Hits:0 | Expired:0 | Kills:0 | Respawns:0 | FactionBlocks:0 | FAIL")
			print("========== END READ HERE (P1) ==========")
			return
		end
	end

	local summary = {
		shots = 0,
		hits = 0,
		expired = 0,
		kills = 0,
		respawns = 0,
		factionBlocks = 0,
		passed = true,
	}

	-- Scenario 1: Direct Fire -> Hit -> Damage
	do
		local turret = entities.mainTurret :: Model
		local target = entities.mainTarget :: Model
		local beforeState = getHealthState(target)
		if beforeState == nil then
			summary.passed = false
			warn("[P1_TEST] scenario 1 failed: target health state missing")
		else
			local hpBefore = beforeState.currentHP
			summary.shots += fireBurst(turret, target, 5, 0.4)
			task.wait(1)
			local afterState = getHealthState(target)
			if afterState == nil then
				summary.passed = false
				warn("[P1_TEST] scenario 1 failed: target health state disappeared")
			else
				local hpAfter = afterState.currentHP
				local hits = math.max(0, hpBefore - hpAfter) / 10
				summary.hits += hits
				if hpAfter ~= 150 then
					summary.passed = false
					warn(string.format("[P1_TEST] scenario 1 failed: expected HP 150, got %d", hpAfter))
				else
					print("[P1_TEST] scenario 1 passed")
				end
			end
		end
	end

	-- Scenario 2: Friendly Fire Block
	do
		local source = entities.mainTurret :: Model
		local target = entities.friendlyTurret :: Model
		local beforeState = getHealthState(target)
		if beforeState == nil then
			summary.passed = false
			warn("[P1_TEST] scenario 2 failed: friendly target health state missing")
		else
			local hpBefore = beforeState.currentHP
			summary.shots += fireBurst(source, target, 3, 0.4)
			task.wait(1)
			local afterState = getHealthState(target)
			if afterState == nil then
				summary.passed = false
				warn("[P1_TEST] scenario 2 failed: friendly target health state disappeared")
			elseif afterState.currentHP ~= hpBefore then
				summary.passed = false
				warn(string.format("[P1_TEST] scenario 2 failed: HP changed from %d to %d", hpBefore, afterState.currentHP))
			else
				summary.factionBlocks += 3
				print("[P1_TEST] scenario 2 passed")
			end
		end
	end

	-- Scenario 3: Destruction + Respawn
	do
		local source = entities.mainTurret :: Model
		local target = entities.lowHpTarget :: Model
		local beforeState = getHealthState(target)
		if beforeState == nil then
			summary.passed = false
			warn("[P1_TEST] scenario 3 failed: low HP target health state missing")
		else
			local hpBefore = beforeState.currentHP
			summary.shots += fireBurst(source, target, 3, 0.4)
			task.wait(1)
			local destroyedState = getHealthState(target)
			if destroyedState == nil then
				summary.passed = false
				warn("[P1_TEST] scenario 3 failed: low HP target state missing after shots")
			else
				local hits = math.max(0, hpBefore - destroyedState.currentHP) / 10
				summary.hits += hits
				if destroyedState.state ~= CombatEnums.EntityState.Destroyed then
					summary.passed = false
					warn(string.format("[P1_TEST] scenario 3 failed: expected Destroyed state, got %s", tostring(destroyedState.state)))
				else
					summary.kills += 1
				end
			end

			task.wait(6)
			local respawnedState = getHealthState(target)
			if respawnedState == nil then
				summary.passed = false
				warn("[P1_TEST] scenario 3 failed: low HP target state missing after respawn wait")
			elseif respawnedState.state ~= CombatEnums.EntityState.Active or respawnedState.currentHP ~= 30 then
				summary.passed = false
				warn(string.format(
					"[P1_TEST] scenario 3 failed: expected Active with 30 HP, got state=%s hp=%d",
					tostring(respawnedState.state),
					respawnedState.currentHP
				))
			else
				summary.respawns += 1
				print("[P1_TEST] scenario 3 passed")
			end
		end
	end

	-- Scenario 4: Max Range Expiry
	do
		local source = entities.mainTurret :: Model
		local target = entities.farTarget :: Model
		local beforeState = getHealthState(target)
		if beforeState == nil then
			summary.passed = false
			warn("[P1_TEST] scenario 4 failed: far target health state missing")
		else
			local hpBefore = beforeState.currentHP
			summary.shots += fireBurst(source, target, 3, 0.4)
			task.wait(3)
			local afterState = getHealthState(target)
			if afterState == nil then
				summary.passed = false
				warn("[P1_TEST] scenario 4 failed: far target health state disappeared")
			elseif afterState.currentHP ~= hpBefore then
				summary.passed = false
				warn(string.format("[P1_TEST] scenario 4 failed: far target took damage (%d -> %d)", hpBefore, afterState.currentHP))
			elseif ProjectileServer.getActiveCount() ~= 0 then
				summary.passed = false
				warn(string.format("[P1_TEST] scenario 4 failed: active projectiles still present (%d)", ProjectileServer.getActiveCount()))
			else
				summary.expired += 3
				print("[P1_TEST] scenario 4 passed")
			end
		end
	end

	local status = summary.passed and "PASS" or "FAIL"
	print(string.format(
		"[P1_SUMMARY] Shots:%d | Hits:%d | Expired:%d | Kills:%d | Respawns:%d | FactionBlocks:%d | %s",
		summary.shots,
		summary.hits,
		summary.expired,
		summary.kills,
		summary.respawns,
		summary.factionBlocks,
		status
	))

	print("========== END READ HERE (P1) ==========")
end

return Pass1_Test
