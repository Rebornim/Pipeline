--!strict

local CombatConfig = {}

CombatConfig.Weapons = {
	blaster_turret = {
		weaponClass = "projectile",
		damageType = "blaster",
		damage = 40,
		fireRate = 3,
		projectileSpeed = 600,
		maxRange = 500,
		heatMax = 100,
		heatPerShot = 9,
		heatDecayPerSecond = 8,
		heatRecoverThreshold = 50,
	},
	blaster_turret_burst = {
		weaponClass = "burst_projectile",
		damageType = "blaster",
		damage = 32,
		fireRate = 1.8,
		projectileSpeed = 600,
		maxRange = 500,
		burstCount = 3,
		burstInterval = 0.08,
		heatMax = 100,
		heatPerShot = 8,
		heatDecayPerSecond = 8,
		heatRecoverThreshold = 50,
	},
}

CombatConfig.Entities = {
	blaster_turret = {
		hullHP = 100,
		weaponId = "blaster_turret",
		respawnTime = 15,
	},
	blaster_turret_burst = {
		hullHP = 100,
		weaponId = "blaster_turret_burst",
		respawnTime = 15,
	},
	shielded_turret = {
		hullHP = 100,
		shieldHP = 140,
		shieldRegenRate = 8,
		shieldRegenDelay = 5,
		weaponId = "blaster_turret",
		respawnTime = 15,
	},
	target_dummy = {
		hullHP = 200,
		weaponId = nil,
		respawnTime = 10,
	},
	shielded_target = {
		hullHP = 200,
		shieldHP = 150,
		shieldRegenRate = 25,
		shieldRegenDelay = 3,
		weaponId = nil,
		respawnTime = 10,
	},
	shield_test_target = {
		hullHP = 100,
		shieldHP = 60,
		shieldRegenRate = 0,
		shieldRegenDelay = 999,
		weaponId = nil,
		respawnTime = 10,
	},
	shield_regen_target = {
		hullHP = 200,
		shieldHP = 100,
		shieldRegenRate = 50,
		shieldRegenDelay = 2,
		weaponId = nil,
		respawnTime = 10,
	},
}

CombatConfig.ProjectileRayRadius = 0.5
CombatConfig.DefaultShieldRegenDelay = 3

CombatConfig.TurretPromptText = "Man Turret"
CombatConfig.TurretPromptDistance = 10

CombatConfig.BoltLength = 2
CombatConfig.BoltWidth = 0.2
CombatConfig.BoltColor = Color3.fromRGB(255, 0, 0)
CombatConfig.BoltMaterial = Enum.Material.Neon

-- Turret destruction explosion tuning.
CombatConfig.TurretDeathExplosionRadius = 30
CombatConfig.TurretDeathExplosionDamage = 220
CombatConfig.TurretDeathExplosionFalloffExponent = 1.6
CombatConfig.TurretDeathExplosionMinDamageScale = 0.12
CombatConfig.TurretDeathExplosionVisualRadius = 30
CombatConfig.TurretDeathExplosionShakeRadius = 85
CombatConfig.TurretDeathExplosionShakeStrength = 1.1
CombatConfig.TurretDeathExplosionShakeDuration = 0.55
CombatConfig.TurretDeathExplosionParticleScale = 1.8
CombatConfig.TurretDeathExplosionParticleEmitMultiplier = 2.2

-- Temporary testing toggle.
CombatConfig.FriendlyFireEnabled = true

return CombatConfig
