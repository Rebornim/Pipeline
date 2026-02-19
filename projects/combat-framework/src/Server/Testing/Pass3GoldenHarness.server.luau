--!strict

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

if not RunService:IsStudio() then
	return
end

if Workspace:GetAttribute("CombatTestHarnessEnabled") ~= true then
	return
end

local sharedRoot = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatConfig = require(sharedRoot:WaitForChild("CombatConfig"))
local CombatTypes = require(sharedRoot:WaitForChild("CombatTypes"))

local serverRoot = ServerScriptService:WaitForChild("CombatFramework")
local HealthManager = require(serverRoot:WaitForChild("Health"):WaitForChild("HealthManager"))
local ProjectileServer = require(serverRoot:WaitForChild("Projectiles"):WaitForChild("ProjectileServer"))
local WeaponServer = require(serverRoot:WaitForChild("Weapons"):WaitForChild("WeaponServer"))

type ProjectileData = CombatTypes.ProjectileData

local HARNESS_TAG = "[P3_TEST]"
local HARNESS_SUMMARY_TAG = "[P3_SUMMARY]"

local function makeEntityModel(name: string, position: Vector3, includeWeaponMount: boolean): (Model, BasePart?, Attachment?)
	local model = Instance.new("Model")
	model.Name = name

	local core = Instance.new("Part")
	core.Name = "Core"
	core.Size = Vector3.new(14, 14, 14)
	core.Anchored = true
	core.CanCollide = true
	core.Position = position
	core.Parent = model
	model.PrimaryPart = core

	local mount: BasePart? = nil
	local muzzle: Attachment? = nil
	if includeWeaponMount then
		local weaponMount = Instance.new("Part")
		weaponMount.Name = "WeaponMount"
		weaponMount.Size = Vector3.new(4, 4, 8)
		weaponMount.Anchored = true
		weaponMount.CanCollide = false
		weaponMount.Position = position
		weaponMount.Parent = model
		CollectionService:AddTag(weaponMount, "WeaponMount")

		local muzzlePoint = Instance.new("Attachment")
		muzzlePoint.Name = "MuzzlePoint"
		muzzlePoint.Position = Vector3.new(0, 0, -weaponMount.Size.Z * 0.5)
		muzzlePoint.Parent = weaponMount
		CollectionService:AddTag(muzzlePoint, "MuzzlePoint")

		mount = weaponMount
		muzzle = muzzlePoint
	end

	return model, mount, muzzle
end

local function createHarnessEntity(
	parent: Instance,
	entityName: string,
	entityId: string,
	position: Vector3,
	configId: string,
	faction: string,
	includeWeaponMount: boolean?
): Model
	local wantsMount = includeWeaponMount == true
	local model, mount, muzzle = makeEntityModel(entityName, position, wantsMount)
	model:SetAttribute("ConfigId", configId)
	model:SetAttribute("Faction", faction)
	model:SetAttribute("EntityId", entityId)
	model.Parent = parent

	HealthManager.registerEntity(entityId, {
		instance = model,
		configId = configId,
		faction = faction,
		weaponMount = mount,
		muzzlePoint = muzzle,
		turretSeat = nil,
	})
	WeaponServer.registerEntity(entityId)

	return model
end

local function fireHarnessProjectile(
	projectileId: string,
	sourceEntityId: string,
	sourceModel: Model,
	targetPosition: Vector3,
	weaponId: string,
	faction: string?
)
	local sourcePart = sourceModel.PrimaryPart
	if sourcePart == nil then
		return
	end

	local weaponConfig = CombatConfig.Weapons[weaponId]
	if weaponConfig == nil then
		return
	end

	local direction = (targetPosition - sourcePart.Position).Unit
	local projectile: ProjectileData = {
		projectileId = projectileId,
		sourceEntityId = sourceEntityId,
		sourceInstance = sourceModel,
		sourceCharacter = nil,
		origin = sourcePart.Position,
		direction = direction,
		speed = weaponConfig.projectileSpeed,
		maxRange = weaponConfig.maxRange,
		damage = weaponConfig.damage,
		damageType = weaponConfig.damageType,
		faction = faction or "empire",
		boltColor = weaponConfig.boltColor,
		splashRadius = weaponConfig.splashRadius,
		createdAt = tick(),
	}
	ProjectileServer.fireProjectile(projectile)
end

local function readHealth(model: Model): (number, number)
	local hull = model:GetAttribute("HullHP")
	local shield = model:GetAttribute("ShieldHP")
	return if type(hull) == "number" then hull else -1, if type(shield) == "number" then shield else -1
end

local function readAmmo(model: Model): (number, number)
	local current = model:GetAttribute("WeaponAmmo")
	local max = model:GetAttribute("WeaponAmmoMax")
	return if type(current) == "number" then current else -1, if type(max) == "number" then max else -1
end

task.spawn(function()
	task.wait(2)
	print("========== START READ HERE ==========")

	local harnessRoot = Workspace:FindFirstChild("CombatHarnessTemp")
	if harnessRoot ~= nil then
		harnessRoot:Destroy()
	end
	harnessRoot = Instance.new("Folder")
	harnessRoot.Name = "CombatHarnessTemp"
	harnessRoot.Parent = Workspace

	local timestamp = tostring(math.floor(tick() * 1000))
	CombatConfig.Entities.p1_respawn_target = {
		hullHP = 30,
		weaponId = nil,
		respawnTime = 5,
	}

	local function runShotSeries(
		testTag: string,
		sourceEntityId: string,
		sourceModel: Model,
		targetModel: Model,
		weaponId: string,
		shotCount: number,
		waitSeconds: number
	)
		for shot = 1, shotCount do
			local projectileId = string.format("%s_%s_%d", testTag, timestamp, shot)
			fireHarnessProjectile(projectileId, sourceEntityId, sourceModel, (targetModel.PrimaryPart :: BasePart).Position, weaponId)
			task.wait(waitSeconds)
			local hull, shield = readHealth(targetModel)
			print(string.format("%s test=%s shot=%d hull=%d shield=%d", HARNESS_TAG, testTag, shot, hull, shield))
		end
	end

	-- Pass 2 regression: Test 5.
	local sourceEntityId = "p3_src_" .. timestamp
	local sourceModel = createHarnessEntity(
		harnessRoot,
		"P3BlasterSource",
		sourceEntityId,
		Vector3.new(0, 8, 0),
		"blaster_turret",
		"empire",
		false
	)
	local t5Target = createHarnessEntity(
		harnessRoot,
		"P2ShieldLifecycleTarget",
		"p3_t5_target_" .. timestamp,
		Vector3.new(0, 8, -35),
		"shield_test_target",
		"rebel",
		false
	)
	print(string.format("%s test=5 begin", HARNESS_TAG))
	runShotSeries("5", sourceEntityId, sourceModel, t5Target, "blaster_turret", 4, 0.6)
	local t5Hull, t5Shield = readHealth(t5Target)
	print(string.format("%s test=5 end hull=%d shield=%d", HARNESS_TAG, t5Hull, t5Shield))

	-- Pass 2 regression: Test 6.
	local t6Target = createHarnessEntity(
		harnessRoot,
		"P2ShieldRegenTarget",
		"p3_t6_target_" .. timestamp,
		Vector3.new(16, 8, -35),
		"shield_regen_target",
		"rebel",
		false
	)
	print(string.format("%s test=6 begin", HARNESS_TAG))
	fireHarnessProjectile("p3_t6_" .. timestamp, sourceEntityId, sourceModel, (t6Target.PrimaryPart :: BasePart).Position, "blaster_turret")
	task.wait(0.6)
	local t6HullAfterHit, t6ShieldAfterHit = readHealth(t6Target)
	print(string.format("%s test=6 afterHit hull=%d shield=%d", HARNESS_TAG, t6HullAfterHit, t6ShieldAfterHit))
	task.wait(6)
	local t6HullFinal, t6ShieldFinal = readHealth(t6Target)
	print(string.format("%s test=6 end hull=%d shield=%d", HARNESS_TAG, t6HullFinal, t6ShieldFinal))

	-- Pass 1 regression: Test 1.
	local r1SourceId = "p3_t1_src_" .. timestamp
	local r1Source = createHarnessEntity(
		harnessRoot,
		"P1RDirectSource",
		r1SourceId,
		Vector3.new(-36, 8, 0),
		"blaster_turret",
		"empire",
		false
	)
	local r1Target = createHarnessEntity(
		harnessRoot,
		"P1RDirectTarget",
		"p3_t1_target_" .. timestamp,
		Vector3.new(-36, 8, -35),
		"target_dummy",
		"rebel",
		false
	)
	print(string.format("%s test=1 begin", HARNESS_TAG))
	runShotSeries("1", r1SourceId, r1Source, r1Target, "blaster_turret", 3, 0.6)
	local r1Hull = (readHealth(r1Target))
	print(string.format("%s test=1 end hull=%d expected=80", HARNESS_TAG, r1Hull))

	-- Pass 1 regression: Test 2.
	local expectedFriendlyHull = if CombatConfig.FriendlyFireEnabled then 80 else 200
	local r2SourceId = "p3_t2_src_" .. timestamp
	local r2Source = createHarnessEntity(
		harnessRoot,
		"P1RFriendlySource",
		r2SourceId,
		Vector3.new(36, 8, 0),
		"blaster_turret",
		"empire",
		false
	)
	local r2Target = createHarnessEntity(
		harnessRoot,
		"P1RFriendlyTarget",
		"p3_t2_target_" .. timestamp,
		Vector3.new(36, 8, -35),
		"target_dummy",
		"empire",
		false
	)
	print(string.format("%s test=2 begin", HARNESS_TAG))
	runShotSeries("2", r2SourceId, r2Source, r2Target, "blaster_turret", 3, 0.6)
	local r2Hull = (readHealth(r2Target))
	print(string.format("%s test=2 end hull=%d expected=%d", HARNESS_TAG, r2Hull, expectedFriendlyHull))

	-- Pass 1 regression: Test 3.
	local r3SourceId = "p3_t3_src_" .. timestamp
	local r3Source = createHarnessEntity(
		harnessRoot,
		"P1RRespawnSource",
		r3SourceId,
		Vector3.new(-72, 8, 0),
		"blaster_turret",
		"empire",
		false
	)
	local r3Target = createHarnessEntity(
		harnessRoot,
		"P1RRespawnTarget",
		"p3_t3_target_" .. timestamp,
		Vector3.new(-72, 8, -35),
		"p1_respawn_target",
		"rebel",
		false
	)
	print(string.format("%s test=3 begin", HARNESS_TAG))
	fireHarnessProjectile("p3_t3_" .. timestamp, r3SourceId, r3Source, (r3Target.PrimaryPart :: BasePart).Position, "blaster_turret")
	task.wait(0.8)
	local r3HullAfterHit = (readHealth(r3Target))
	task.wait(6)
	local r3HullAfterRespawn = (readHealth(r3Target))
	print(
		string.format(
			"%s test=3 end hullAfterHit=%d hullAfterRespawn=%d expectedRespawn=30",
			HARNESS_TAG,
			r3HullAfterHit,
			r3HullAfterRespawn
		)
	)

	-- Pass 1 regression: Test 4.
	local r4SourceId = "p3_t4_src_" .. timestamp
	local r4Source = createHarnessEntity(
		harnessRoot,
		"P1RRangeSource",
		r4SourceId,
		Vector3.new(72, 8, 0),
		"blaster_turret",
		"empire",
		false
	)
	local r4Target = createHarnessEntity(
		harnessRoot,
		"P1RRangeTarget",
		"p3_t4_target_" .. timestamp,
		Vector3.new(72, 8, -700),
		"target_dummy",
		"rebel",
		false
	)
	print(string.format("%s test=4 begin", HARNESS_TAG))
	runShotSeries("4", r4SourceId, r4Source, r4Target, "blaster_turret", 3, 2.3)
	local r4Hull = (readHealth(r4Target))
	print(string.format("%s test=4 end hull=%d expected=200", HARNESS_TAG, r4Hull))

	-- Pass 3: Test 7.
	local t7SourceId = "p3_t7_src_" .. timestamp
	local t7Source = createHarnessEntity(
		harnessRoot,
		"P3IonSource",
		t7SourceId,
		Vector3.new(-108, 8, 0),
		"ion_turret",
		"empire",
		false
	)
	local t7Target = createHarnessEntity(
		harnessRoot,
		"P3IonTarget",
		"p3_t7_target_" .. timestamp,
		Vector3.new(-108, 8, -35),
		"ion_test_target",
		"rebel",
		false
	)
	print(string.format("%s test=7 begin", HARNESS_TAG))
	runShotSeries("7", t7SourceId, t7Source, t7Target, "ion_turret", 2, 0.7)
	local t7Hull, t7Shield = readHealth(t7Target)
	print(string.format("%s test=7 end hull=%d shield=%d", HARNESS_TAG, t7Hull, t7Shield))

	-- Pass 3: Test 8.
	local t8SourceId = "p3_t8_src_" .. timestamp
	local t8Source = createHarnessEntity(
		harnessRoot,
		"P3TorpedoSource",
		t8SourceId,
		Vector3.new(108, 8, 0),
		"torpedo_turret",
		"empire",
		false
	)
	local t8Target = createHarnessEntity(
		harnessRoot,
		"P3TorpedoTarget",
		"p3_t8_target_" .. timestamp,
		Vector3.new(108, 8, -35),
		"torpedo_test_target",
		"rebel",
		false
	)
	print(string.format("%s test=8 begin", HARNESS_TAG))
	fireHarnessProjectile("p3_t8_" .. timestamp, t8SourceId, t8Source, (t8Target.PrimaryPart :: BasePart).Position, "torpedo_launcher")
	task.wait(0.9)
	local t8Hull, t8Shield = readHealth(t8Target)
	print(string.format("%s test=8 end hull=%d shield=%d", HARNESS_TAG, t8Hull, t8Shield))

	-- Pass 3: Test 9.
	local t9SourceId = "p3_t9_src_" .. timestamp
	local t9Source = createHarnessEntity(
		harnessRoot,
		"P3AmmoSource",
		t9SourceId,
		Vector3.new(0, 8, 72),
		"torpedo_turret",
		"empire",
		true
	)
	local t9Target = createHarnessEntity(
		harnessRoot,
		"P3AmmoTarget",
		"p3_t9_target_" .. timestamp,
		Vector3.new(0, 8, 30),
		"ammo_test_target",
		"rebel",
		false
	)
	print(string.format("%s test=9 begin", HARNESS_TAG))
	local t9Direction = ((t9Target.PrimaryPart :: BasePart).Position - (t9Source.PrimaryPart :: BasePart).Position).Unit
	local t9FiredCount = 0
	for shot = 1, 8 do
		local fired = WeaponServer.fireTestShot(t9SourceId, t9Direction)
		if fired then
			t9FiredCount += 1
		end
		task.wait(0.45)
		local ammoCurrent, ammoMax = readAmmo(t9Source)
		print(string.format("%s test=9 shot=%d fired=%s ammo=%d/%d", HARNESS_TAG, shot, tostring(fired), ammoCurrent, ammoMax))
	end
	local t9AmmoCurrent, t9AmmoMax = readAmmo(t9Source)
	print(string.format("%s test=9 end fired=%d ammo=%d/%d", HARNESS_TAG, t9FiredCount, t9AmmoCurrent, t9AmmoMax))

	print(
		string.format(
			"%s t1_hull=%d t2_hull=%d t3_respawn=%d t4_hull=%d t5_hull=%d t5_shield=%d t6_hull=%d t6_shield=%d t7_hull=%d t7_shield=%d t8_hull=%d t8_shield=%d t9_fired=%d t9_ammo=%d/%d friendlyFire=%s",
			HARNESS_SUMMARY_TAG,
			r1Hull,
			r2Hull,
			r3HullAfterRespawn,
			r4Hull,
			t5Hull,
			t5Shield,
			t6HullFinal,
			t6ShieldFinal,
			t7Hull,
			t7Shield,
			t8Hull,
			t8Shield,
			t9FiredCount,
			t9AmmoCurrent,
			t9AmmoMax,
			tostring(CombatConfig.FriendlyFireEnabled)
		)
	)
	print("========== END READ HERE ==========")
end)
