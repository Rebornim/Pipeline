--!strict

local CombatConfig = {}

CombatConfig.Weapons = {
	blaster_turret = {
		weaponClass = "projectile",
		damageType = "blaster",
		damage = 40,
		fireRate = 3,
		projectileSpeed = 850,
		maxRange = 900,
		lockRange = 600,
		unlockedSpread = 2.4,
		autoAimSpread = 0.9,
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
		projectileSpeed = 850,
		maxRange = 900,
		lockRange = 600,
		unlockedSpread = 2.9,
		autoAimSpread = 1.1,
		burstCount = 3,
		burstInterval = 0.08,
		heatMax = 100,
		heatPerShot = 4,
		heatDecayPerSecond = 10,
		heatRecoverThreshold = 45,
	},
	turbolaser_turret = {
		weaponClass = "projectile",
		damageType = "turbolaser",
		damage = 120,
		fireRate = 0.5,
		projectileSpeed = 900,
		maxRange = 1800,
		lockRange = 1200,
		unlockedSpread = 1.4,
		autoAimSpread = 0.55,
		heatMax = 100,
		heatPerShot = 25,
		heatDecayPerSecond = 6,
		heatRecoverThreshold = 40,
		boltColor = Color3.fromRGB(0, 255, 0),
	},
	ion_turret = {
		weaponClass = "projectile",
		damageType = "ion",
		damage = 60,
		fireRate = 1.5,
		projectileSpeed = 800,
		maxRange = 900,
		lockRange = 600,
		unlockedSpread = 2.0,
		autoAimSpread = 0.75,
		heatMax = 100,
		heatPerShot = 18,
		heatDecayPerSecond = 7,
		heatRecoverThreshold = 45,
		boltColor = Color3.fromRGB(100, 140, 255),
	},
	torpedo_launcher = {
		weaponClass = "projectile",
		damageType = "proton_torpedo",
		damage = 200,
		fireRate = 0.33,
		projectileSpeed = 300,
		maxRange = 1600,
		lockRange = 1000,
		autoAimSpread = 0.65,
		requiresLock = true,
		ammoCapacity = 6,
		boltColor = Color3.fromRGB(255, 200, 60),
	},
	missile_battery = {
		weaponClass = "projectile",
		damageType = "concussion_missile",
		damage = 80,
		fireRate = 1.0,
		projectileSpeed = 340,
		maxRange = 1400,
		lockRange = 900,
		unlockedSpread = 2.2,
		autoAimSpread = 0.45,
		requiresLock = true,
		homingTurnRate = 45,
		ammoCapacity = 12,
		boltColor = Color3.fromRGB(255, 120, 40),
	},
}

CombatConfig.Entities = {
	blaster_turret = {
		hullHP = 100,
		weaponId = "blaster_turret",
		turretExposed = true,
		respawnTime = 15,
	},
	blaster_turret_burst = {
		hullHP = 100,
		weaponId = "blaster_turret_burst",
		turretExposed = true,
		respawnTime = 15,
	},
	shielded_turret = {
		hullHP = 100,
		shieldHP = 140,
		shieldRegenRate = 8,
		shieldRegenDelay = 5,
		weaponId = "blaster_turret",
		turretExposed = true,
		respawnTime = 15,
	},
	turbolaser_turret = {
		hullHP = 150,
		shieldHP = 100,
		shieldRegenRate = 10,
		shieldRegenDelay = 4,
		weaponId = "turbolaser_turret",
		turretExposed = false,
		respawnTime = 20,
	},
	ion_turret = {
		hullHP = 80,
		weaponId = "ion_turret",
		turretExposed = true,
		respawnTime = 15,
	},
	torpedo_turret = {
		hullHP = 120,
		weaponId = "torpedo_launcher",
		turretExposed = true,
		respawnTime = 25,
	},
	missile_turret = {
		hullHP = 100,
		weaponId = "missile_battery",
		turretExposed = true,
		respawnTime = 20,
	},
	light_speeder = {
		hullHP = 100,
		weaponId = nil,
		respawnTime = nil,
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
	ion_test_target = {
		hullHP = 200,
		shieldHP = 200,
		shieldRegenRate = 0,
		shieldRegenDelay = 999,
		weaponId = nil,
		respawnTime = 10,
	},
	torpedo_test_target = {
		hullHP = 500,
		shieldHP = 150,
		shieldRegenRate = 0,
		shieldRegenDelay = 999,
		weaponId = nil,
		respawnTime = 10,
	},
	ammo_test_target = {
		hullHP = 10000,
		weaponId = nil,
		respawnTime = 999,
	},
}

CombatConfig.DamageTypeMultipliers = {
	blaster = { shieldMult = 1.0, hullMult = 1.0, bypass = 0 },
	turbolaser = { shieldMult = 1.5, hullMult = 1.5, bypass = 0 },
	ion = { shieldMult = 3.0, hullMult = 0.15, bypass = 0 },
	proton_torpedo = { shieldMult = 0.3, hullMult = 2.5, bypass = 0.7 },
	concussion_missile = { shieldMult = 1.0, hullMult = 1.0, bypass = 0 },
	explosion = { shieldMult = 1.0, hullMult = 1.0, bypass = 0 },
	impact = { shieldMult = 1.0, hullMult = 1.0, bypass = 0 },
}

CombatConfig.Vehicles = {
	light_speeder = {
		vehicleClass = "light_speeder",
		entityConfigId = "light_speeder",
		maxSpeed = 120,
		acceleration = 80,
		deceleration = 30,
		brakingDeceleration = 60,
		reverseMaxSpeed = 30,
		turnSpeedLow = 120,
		turnSpeedHigh = 45,
		leanTurnRate = 50,
		leanBankAngle = 15,
		leanSpeedPenalty = 0.01,
		leanEntryDuration = 0.25,
		leanEntryYawBoost = 0.35,
		leanEntrySpeedBoost = 20,
		leanExitDuration = 0.18,
		leanExitCounterBankDeg = 3.5,
		leanCameraOffset = 1.5,
		leanShakeAmplitude = 0.2,
		leanShakeDuration = 0.12,
		leanDustEmitCount = 8,
		lateralGripLow = 10,
		lateralGripHigh = 4.5,
		accelerationTaper = 0.0,
		accelerationMinFactor = 1.0,
		tiltStiffness = 100,
		tiltDamping = 14,
		landingShakeThreshold = 25,
		landingShakeIntensity = 0.35,
		hoverHeight = 1,
		springStiffness = 250,
		springDamping = 25,
		gravity = 150,
		maxClimbSlope = 45,
		fallDamageThreshold = 80,
		fallDamageScale = 0.8,
		collisionDamageThreshold = 60,
		collisionDamageScale = 1.2,
		collisionBounce = 0.2,
		collisionRadius = 4,
		cameraDistance = 15,
		cameraHeight = 6,
		cameraLerpSpeed = 0.15,
	},
}

CombatConfig.ProjectileRayRadius = 0.5
CombatConfig.DefaultShieldRegenDelay = 3
CombatConfig.LockOnScanRadius = 8
CombatConfig.LockValidationInterval = 0.2
CombatConfig.LockBreakRange = 1.0
CombatConfig.VehicleInputRate = 20
CombatConfig.VehicleStopThreshold = 0.5
CombatConfig.VehicleCollisionRayCount = 3
CombatConfig.VehicleCollisionLookahead = 2.0
CombatConfig.VehicleMaxTiltLerp = 8.0
CombatConfig.VehicleMouseSensitivity = 0.7
CombatConfig.VehicleMouseRangeX = 0.22
CombatConfig.VehicleMouseRangeY = 0.06
CombatConfig.VehicleMouseCenteringRate = 1.5
CombatConfig.VehicleReplicationRateActive = 20
CombatConfig.VehicleReplicationRateSettling = 5
CombatConfig.VehicleReplicationSpeedDeadband = 1.5
CombatConfig.VehicleReplicationHeadingDeadband = 0.03
CombatConfig.VehicleSettlingSpeedDeadband = 3.0
CombatConfig.VehicleSettlingHeadingDeadband = 0.05
CombatConfig.VehicleReplicationRefreshActive = 0.5
CombatConfig.VehicleReplicationRefreshSettling = 1.0
CombatConfig.VehicleDormancyDelay = 2.0
CombatConfig.VehicleCFrameWriteRateActive = 20
CombatConfig.VehicleCFrameWriteRateSettling = 5
CombatConfig.VehicleCFramePositionDeadband = 0.01

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
CombatConfig.TestHarnessEnabled = false

return CombatConfig
