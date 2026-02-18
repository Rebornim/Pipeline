--!strict

local CombatConfig = {}

CombatConfig.Weapons = {
	blaster_turret = {
		damageType = "blaster",
		damage = 10,
		fireRate = 3,
		projectileSpeed = 300,
		maxRange = 500,
	},
}

CombatConfig.Entities = {
	blaster_turret = {
		hullHP = 100,
		weaponId = "blaster_turret",
		respawnTime = 15,
	},
	target_dummy = {
		hullHP = 200,
		weaponId = nil,
		respawnTime = 10,
	},
}

CombatConfig.ProjectileRayRadius = 0.5

CombatConfig.TurretPromptText = "Man Turret"
CombatConfig.TurretPromptDistance = 10

CombatConfig.BoltLength = 2
CombatConfig.BoltWidth = 0.2
CombatConfig.BoltColor = Color3.fromRGB(255, 0, 0)
CombatConfig.BoltMaterial = Enum.Material.Neon

CombatConfig.TestHarnessEnabled = true
CombatConfig.ActiveTestPass = 1

return CombatConfig
