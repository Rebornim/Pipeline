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
		lockRange = 850,
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
		homingTurnRate = 25,
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
	artillery_emplacement = {
		weaponClass = "artillery",
		damageType = "artillery_shell",
		damage = 150,
		fireRate = 0.2,
		projectileSpeed = 800,
		maxRange = 2000,
		splashRadius = 25,
		ammoCapacity = 8,
		artilleryGravity = 320,
		artilleryMinElevation = 5,
		artilleryMaxElevation = 85,
		artilleryAdjustSpeed = 30,
		artilleryFineAdjustSpeed = 5,
		artilleryMinRange = 100,
		boltColor = Color3.fromRGB(255, 160, 40),
	},
	walker_chin_blaster = {
		weaponClass = "burst_projectile",
		damageType = "blaster",
		damage = 20,
		fireRate = 2,
		burstCount = 2,
		burstInterval = 0.12,
		projectileSpeed = 600,
		maxRange = 600,
		splashRadius = 18,
		lockRange = 500,
		autoAimSpread = 2.0,
		requiresLock = false,
		heatMax = 100,
		heatPerShot = 5,
		heatDecayPerSecond = 20,
		heatRecoverThreshold = 40,
		boltColor = Color3.fromRGB(255, 40, 40),
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
	light_vehicle = {
		hullHP = 150,
		weaponId = nil,
		respawnTime = 20,
	},
	heavy_vehicle = {
		hullHP = 500,
		shieldHP = 200,
		shieldRegenRate = 15,
		shieldRegenDelay = 5,
		weaponId = nil,
		respawnTime = 30,
	},
	light_speeder_armed = {
		hullHP = 100,
		weaponId = "blaster_turret",
		turretExposed = true,
		respawnTime = 20,
	},
	heavy_speeder_armed = {
		hullHP = 500,
		shieldHP = 200,
		shieldRegenRate = 15,
		shieldRegenDelay = 5,
		weaponId = "turbolaser_turret",
		turretExposed = false,
		respawnTime = 30,
	},
	heavy_speeder_gunner = {
		hullHP = 500,
		shieldHP = 200,
		shieldRegenRate = 15,
		shieldRegenDelay = 5,
		weaponId = "blaster_turret",
		turretExposed = false,
		respawnTime = 30,
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
	artillery_emplacement = {
		hullHP = 200,
		weaponId = "artillery_emplacement",
		turretExposed = true,
		respawnTime = 30,
	},
	walker_biped = {
		hullHP = 800,
		weaponId = "walker_chin_blaster",
		turretExposed = false,
		respawnTime = 45,
	},
	fighter = {
		hullHP = 200,
		shieldHP = 100,
		shieldRegenRate = 10,
		shieldRegenDelay = 5,
		weaponId = nil,
		turretExposed = false,
		respawnTime = 15,
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
	artillery_shell = { shieldMult = 1.5, hullMult = 2.0, bypass = 0 },
}

CombatConfig.Vehicles = {
	light = {
		vehicleClass = "light",
		entityConfigId = "light_vehicle",
		maxSpeed = 120,
		acceleration = 80,
		deceleration = 30,
		brakingDeceleration = 60,
		reverseMaxSpeed = 30,
		turnSpeedLow = 120,
		turnSpeedHigh = 45,
		leanEnabled = true,
		leanTurnRate = 50,
		leanBankAngle = 15,
		leanSpeedPenalty = 0.01,
		leanEntryDuration = 0.25,
		leanEntryYawBoost = 0.35,
		leanEntrySpeedBoost = 20,
		leanExitDuration = 0.18,
		leanExitCounterBankDeg = 3.5,
		leanCounterSteerDuration = 0,
		leanCounterSteerRate = 0,
		leanCounterSteerBankDeg = 0,
		leanCameraOffset = 1.5,
		leanShakeAmplitude = 0.2,
		leanShakeDuration = 0.12,
		leanDustEmitCount = 8,
		lateralGripLow = 10,
		lateralGripHigh = 4.5,
		accelerationTaper = 0.5,
		accelerationMinFactor = 0.3,
		tiltStiffness = 100,
		tiltDamping = 14,
		terrainConformity = 0.15,
		landingShakeThreshold = 25,
		landingShakeIntensity = 0.35,
		hoverHeight = 1,
		springStiffness = 250,
		springDamping = 25,
		gravity = 150,
		maxClimbSlope = 65,
		fallDamageThreshold = 160,
		fallDamageScale = 0.5,
		collisionDamageThreshold = 60,
		collisionDamageScale = 1.2,
		collisionBounce = 0.2,
		collisionRadius = 4,
		cameraDistance = 15,
		cameraHeight = 6,
		cameraLerpSpeed = 0.15,
		boostEnabled = true,
		boostSpeedMultiplier = 1.5,
		boostDuration = 5,
		boostCooldown = 6,
		canCrossWater = true,
	},
	heavy = {
		vehicleClass = "heavy",
		entityConfigId = "heavy_vehicle",
		maxSpeed = 55,
		acceleration = 40,
		deceleration = 20,
		brakingDeceleration = 45,
		reverseMaxSpeed = 15,
		turnSpeedLow = 70,
		turnSpeedHigh = 25,
		leanEnabled = false,
		leanTurnRate = 0,
		leanBankAngle = 0,
		leanSpeedPenalty = 0,
		leanEntryDuration = 0,
		leanEntryYawBoost = 0,
		leanEntrySpeedBoost = 0,
		leanExitDuration = 0,
		leanExitCounterBankDeg = 0,
		leanCounterSteerDuration = 0,
		leanCounterSteerRate = 0,
		leanCounterSteerBankDeg = 0,
		leanCameraOffset = 0,
		leanShakeAmplitude = 0,
		leanShakeDuration = 0,
		leanDustEmitCount = 0,
		lateralGripLow = 20,
		lateralGripHigh = 12,
		accelerationTaper = 0.6,
		accelerationMinFactor = 0.25,
		tiltStiffness = 80,
		tiltDamping = 16,
		terrainConformity = 1.0,
		landingShakeThreshold = 30,
		landingShakeIntensity = 0.25,
		hoverHeight = 1.5,
		springStiffness = 300,
		springDamping = 30,
		gravity = 150,
		maxClimbSlope = 50,
		fallDamageThreshold = 120,
		fallDamageScale = 0.4,
		collisionDamageThreshold = 80,
		collisionDamageScale = 0.8,
		collisionBounce = 0.1,
		collisionRadius = 6,
		cameraDistance = 22,
		cameraHeight = 8,
		cameraLerpSpeed = 0.12,
		boostEnabled = false,
		boostSpeedMultiplier = 1.0,
		boostDuration = 0,
		boostCooldown = 0,
		canCrossWater = false,
		-- Gunner-seat accuracy tuning (spread multipliers; lower = tighter grouping)
		gunnerUnlockedSpreadMultiplier = 0.55,
		gunnerAutoAimSpreadMultiplier = 0.7,
	},
	walker_biped = {
		vehicleClass = "walker_biped",
		entityConfigId = "walker_biped",
		-- Movement
		maxSpeed = 22,
		reverseMaxSpeed = 7.5,
		strafeMaxSpeed = 12,
		acceleration = 52.5,
		deceleration = 37.5,
		brakingDeceleration = 60,
		maxStepDown = 6,
		turnSpeed = 35,
		-- Sprint: same walk gait but faster, heavier, more urgent.
		-- AT-ST doesn't change its gait — it just does it harder.
		sprintMaxSpeed = 62.5,
		sprintAcceleration = 15,
		-- Gait timing (0.7s walk → 0.42s sprint half-cycle)
		sprintHalfCycleDuration = 0.42,
		sprintGaitMinSpeedFrac = 0.6,
		-- Stride: foot lands ~12 studs ahead, giving buffer before falling behind.
		sprintStrideLead = 12,
		-- Step: high arc for visible kick-back behind body
		sprintStepHeight = 7,
		-- Bob: small upward during step (pairs with the impact dip)
		sprintBobAmplitude = 3,
		-- Impact jolt: heavy dip on each foot plant (body sinks into the step)
		sprintImpactJoltAmplitude = 5.0,
		-- Sway: LESS than walk (18). At speed the machine has forward momentum,
		-- less time to wobble side-to-side. But still present — it's heavy.
		sprintSwayAmplitude = 10,
		-- Lean: more aggressive forward pitch
		sprintLeanAngle = 12,
			-- Turn: restricted at speed (momentum)
			sprintTurnSpeed = 15,
			-- Weapon handling: very inaccurate while sprinting (server-authoritative).
			weaponSprintSpreadStartFrac = 0.55,
			weaponSprintSpreadMinDeg = 0.8,
			weaponSprintSpreadMaxDeg = 3.5,
			weaponSprintSpreadExponent = 1.6,
			-- Feet slightly more centered (narrower stance at speed)
			sprintFootInwardBias = 1.5,
		-- Head arc (degrees relative to body forward)
		headYawMin = -55,
		headYawMax = 55,
		headPitchMin = -30,
		headPitchMax = 20,
		-- Body
		walkHeight = 15,
		gravity = 196,
		maxClimbSlope = 45,
		-- Fall damage
		fallDamageThreshold = 80,
		fallDamageScale = 0.3,
		-- IK (shared config, used by client)
		legUpperLength = 9,
		legLowerLength = 9,
		footLength = 2.25,
		stepThreshold = 6,
		stepHeight = 4.5,
		stepDuration = 0.5,
		stepAheadTime = 0,
		halfCycleDuration = 0.65,
		gaitMinSpeedFrac = 0.5,
		strideLead = 10,
		homeOffsetForward = 3,
		homeOffsetLateral = 6,
		footInwardBias = 0.9,
		hipAttachForward = -4.5,
		hipAttachVertical = -1.125,
		-- Strut1: fixed-angle upper strut from torso back, down+forward+outward
		strut1AttachForward = -3,
		strut1AttachVertical = -0.75,
		strut1AttachLateral = 3.75,
		strut1Length = 6,
		strut1PitchDeg = 25,
		strut1SpreadDeg = 15,
		-- Strut2: walking-pivot strut from strut1 end backward to hip
		strutAttachForward = 4.5,
		strutAttachVertical = -1.125,
		strutAttachLateral = 4.5,
		strutLength = 7.5,
		stepToeTilt = 10,
		-- Body secondary motion
		bobAmplitude = 4,
		swayAmplitude = 14.0,
		leanMaxAngle = 3,
		impactJoltAmplitude = 0.6,
		impactJoltDecay = 6,
		bodyIdleLean = 0,
		-- Camera
		cameraDistance = 37.5,
		cameraHeight = 18,
		cameraLerpSpeed = 0.1,
		-- Zeroed speeder fields (shared code compatibility)
		turnSpeedLow = 0,
		turnSpeedHigh = 0,
		leanEnabled = false,
		leanTurnRate = 0,
		leanBankAngle = 0,
		leanSpeedPenalty = 0,
		leanEntryDuration = 0,
		leanEntryYawBoost = 0,
		leanEntrySpeedBoost = 0,
		leanExitDuration = 0,
		leanExitCounterBankDeg = 0,
		leanCounterSteerDuration = 0,
		leanCounterSteerRate = 0,
		leanCounterSteerBankDeg = 0,
		leanCameraOffset = 0,
		leanShakeAmplitude = 0,
		leanShakeDuration = 0,
		leanDustEmitCount = 0,
		lateralGripLow = 0,
		lateralGripHigh = 0,
		accelerationTaper = 0,
		accelerationMinFactor = 0,
		tiltStiffness = 0,
		tiltDamping = 0,
		terrainConformity = 0,
		landingShakeThreshold = 0,
		landingShakeIntensity = 0,
		hoverHeight = 1,
		springStiffness = 0,
		springDamping = 0,
		collisionDamageThreshold = 80,
		collisionDamageScale = 0.5,
		collisionBounce = 0.1,
		collisionRadius = 5,
		boostEnabled = false,
		boostSpeedMultiplier = 1,
		boostDuration = 0,
		boostCooldown = 0,
		canCrossWater = false,
	},
		fighter = {
			vehicleClass = "fighter",
			entityConfigId = "fighter",
			maxSpeed = 260,
			minSpeed = 90,
			acceleration = 95,
			deceleration = 70,
		coastDeceleration = 0,
		brakingDeceleration = 0,
		reverseMaxSpeed = 0,
		turnSpeedLow = 0,
		turnSpeedHigh = 0,
		yawRate = 68,
			pitchRate = 150,
		rollRate = 130,
			turnRateSpeedScaleMin = 0.78,
			turnRateSpeedScaleMax = 1.0,
			angularResponsiveness = 6.8,
		autoLevelRate = 30,
		autoLevelDeadzone = 5,
		autoLevelInputGate = 0.3,
		autoBankMaxAngle = 35,
		autoBankYawRateRef = 90,
		autoBankRate = 90,
		fighterMouseSensitivity = 0.42,
		fighterMouseRangeX = 1.0,
		fighterMouseRangeY = 0.8,
		fighterMouseAutoCenter = 3.0,
		fighterMouseDeadzone = 0.075,
		fighterMouseCenterReturnRadius = 0.11,
		fighterCursorLagRate = 18,
		fighterUseForceFlight = true,
		fighterForceVelocityGain = 20.0,
		fighterForceMaxAccel = 1400.0,
			fighterInputExpo = 1.35,
			fighterThrottleSpoolUp = 8.0,
			fighterThrottleSpoolDown = 5.5,
			fighterThrottleDeadzone = 0.03,
			fighterAngularDamping = 3.0,
			fighterYawRateAccelLimit = 115.0,
			fighterPitchRateAccelLimit = 320.0,
			fighterRollRateAccelLimit = 210.0,
			fighterVelocityAlignRate = 7.5,
			fighterVelocityDirAlignBase = 1.6,
			fighterVelocityDirAlignTurnBoost = 8.5,
			fighterTurnAlignBoost = 11.0,
			fighterTurnSpeedPenalty = 0.18,
			fighterSideSlipDamping = 3.5,
			fighterTurnSlipDampingBoost = 8.0,
			fighterVerticalSlipDamping = 2.5,
			fighterTurnVerticalDampingBoost = 6.0,
			fighterTurnEnergyLoss = 7.5,
			fighterForwardAccelLimit = 420.0,
			fighterForwardDecelLimit = 150.0,
			fighterInducedDrag = 22.0,
			fighterWorldGravity = 26.0,
			fighterLiftCoefficient = 0.22,
			fighterBaseDrag = 0.065,
		fighterVisualYawRateGain = 0.09,
		fighterVisualPitchRateGain = 0.08,
		fighterVisualYawAccelGain = 0.015,
		fighterVisualPitchAccelGain = 0.012,
		fighterVisualSlipYawGain = 8.0,
		fighterVisualSlipPitchGain = 6.0,
		fighterVisualRollRateGain = 0.08,
		fighterVisualResponse = 10.0,
		fighterVisualYawMax = 18.0,
		fighterVisualPitchMax = 14.0,
		fighterVisualRollMax = 15.0,
		fighterTakeoffHeight = 12,
		fighterTakeoffDuration = 0.9,
		cameraDistance = 28,
		cameraHeight = 12,
		cameraLerpSpeed = 0.12,
		fighterCameraRollFollow = 1.0,
		fighterCameraAimHeight = 9.5,
		fighterCameraAimHeightSpeedBoost = 4.0,
		fighterCameraLookAhead = 15,
			fighterCameraOrientLag = 8.0,
		collisionRadius = 5,
		hoverHeight = 0,
		springStiffness = 0,
		springDamping = 0,
		gravity = 0,
		maxClimbSlope = 0,
		terrainConformity = 0,
		tiltStiffness = 0,
		tiltDamping = 0,
		lateralGripLow = 0,
		lateralGripHigh = 0,
		accelerationTaper = 0,
		accelerationMinFactor = 0,
		collisionDamageThreshold = 0,
		collisionDamageScale = 0,
		collisionBounce = 0.3,
		fallDamageThreshold = 0,
		fallDamageScale = 0,
		landingShakeThreshold = 0,
		landingShakeIntensity = 0,
		leanEnabled = false,
		leanTurnRate = 0,
		leanBankAngle = 0,
		leanSpeedPenalty = 0,
		leanEntryDuration = 0,
		leanEntryYawBoost = 0,
		leanEntrySpeedBoost = 0,
		leanExitDuration = 0,
		leanExitCounterBankDeg = 0,
		leanCounterSteerDuration = 0,
		leanCounterSteerRate = 0,
		leanCounterSteerBankDeg = 0,
		leanCameraOffset = 0,
		leanShakeAmplitude = 0,
		leanShakeDuration = 0,
		leanDustEmitCount = 0,
		boostEnabled = false,
		boostSpeedMultiplier = 1,
		boostDuration = 0,
		boostCooldown = 0,
		canCrossWater = false,
	},
}

-- Alias for backward compatibility (test harnesses, old models)
CombatConfig.Vehicles.light_speeder = CombatConfig.Vehicles.light

CombatConfig.ProjectileRayRadius = 0.5
CombatConfig.DefaultShieldRegenDelay = 3
CombatConfig.LockOnScanRadius = 20
CombatConfig.LockValidationInterval = 0.2
CombatConfig.LockBreakRange = 1.0
CombatConfig.Targeting = {
	lockFacingHalfAngleDeg = 70,
}
CombatConfig.VehicleInputRate = 60
CombatConfig.VehicleStopThreshold = 0.5
CombatConfig.VehicleCollisionRayCount = 3
CombatConfig.VehicleCollisionLookahead = 2.0
CombatConfig.VehicleMaxTiltLerp = 8.0
CombatConfig.VehicleMouseSensitivity = 0.7
CombatConfig.VehicleMouseRangeX = 0.22
CombatConfig.VehicleMouseRangeY = 0.25
CombatConfig.VehicleMouseCenteringRate = 1.5
CombatConfig.WalkerMouseCenteringRate = 4.0
CombatConfig.VehicleReplicationRateActive = 60
CombatConfig.VehicleReplicationRateSettling = 5
CombatConfig.VehicleReplicationSpeedDeadband = 1.5
CombatConfig.VehicleReplicationHeadingDeadband = 0.03
CombatConfig.VehicleSettlingSpeedDeadband = 3.0
CombatConfig.VehicleSettlingHeadingDeadband = 0.05
CombatConfig.VehicleReplicationRefreshActive = 0.5
CombatConfig.VehicleReplicationRefreshSettling = 1.0
CombatConfig.VehicleDormancyDelay = 2.0
CombatConfig.VehicleCFrameWriteRateActive = 60
CombatConfig.VehicleCFrameWriteRateSettling = 5
CombatConfig.VehicleCFramePositionDeadband = 0.01

CombatConfig.VehicleSounds = {
	EngineClose = "rbxassetid://81523091591629",
	EngineNoise = "rbxassetid://125801987418280",
	EngineStart = "rbxassetid://133156108150442",
	EngineStop = "rbxassetid://130536465269031",
	BoostStart = "rbxassetid://121610140362996",
	BoostLoop = "rbxassetid://108823494358596",
	BoostEnd = "rbxassetid://110378500658798",
	GearShift1 = "rbxassetid://86242827234208",
	GearShift2 = "rbxassetid://90476845102813",
	Howl1 = "rbxassetid://77342888973670",
	Howl2 = "rbxassetid://121442634892704",
	Misfire1 = "rbxassetid://83938697342525",
	Misfire2 = "rbxassetid://84098429703499",
	Broken1 = "rbxassetid://96339590628062",
	Broken2 = "rbxassetid://71789598888160",
	-- Heavy vehicle sounds
	HeavyCloseLoop = "rbxassetid://111281454706755",
	HeavyExteriorLoop = "rbxassetid://93464198465444",
	EngineStartHeavy = "rbxassetid://105408775062483",
	EngineStopHeavy = "rbxassetid://84289558190606",
	HeavyBump1 = "rbxassetid://129609835950988",
	HeavyBump2 = "rbxassetid://74101358528931",
	HeavyBump3 = "rbxassetid://137472475085520",
	HeavyGunOnline1 = "rbxassetid://113447063270284",
	HeavyGunOnline2 = "rbxassetid://115523734938744",
	HeavyGunOffline1 = "rbxassetid://110489599622009",
	HeavyGunOffline2 = "rbxassetid://103802408448011",
}

CombatConfig.WeaponSounds = {
	-- FireSound attribute value → sound group
	ion = {
		fire = {
			"rbxassetid://95548409822347",  -- IonVariation1
			"rbxassetid://80917486965798",  -- IonVariation2
			"rbxassetid://96231487753854",  -- IonVariation3
		},
		whiz = "rbxassetid://120457123062510", -- IonBoltTravelingLoop
		impact = "rbxassetid://108127807949441", -- IonExplosion
	},
	turbolaser = {
		fire = "rbxassetid://73641797672095",  -- TurboLaser
		whiz = "rbxassetid://96548619658793",  -- TurboLaserLoop
		impact = "rbxassetid://98513589644368", -- TurretExplosion
	},
	artillery = {
		fire = "rbxassetid://138091349196514", -- PossibleArtillery
		fireVolume = 1,
		impact = "rbxassetid://138210320", -- Vehicle Explosion
	},
	eweb = {
		fire = {
			"rbxassetid://75402037234962",  -- EWeb1
			"rbxassetid://109329355375513", -- EWeb2
			"rbxassetid://121204413755088", -- EWeb3
			"rbxassetid://90062339482404",  -- EWeb4
		},
		impact = {
			"rbxassetid://166198228",  -- HitSound (old blaster impact)
			"rbxassetid://151130059",  -- Sound (old blaster impact)
		},
	},
	torpedo = {
		fire = {
			"rbxassetid://96233350378598",  -- TorpedoLaunch1
			"rbxassetid://79587639517964",  -- TorpedoLaunch2
		},
		whiz = "rbxassetid://101551285895899", -- TorpedoLoop
		impact = "rbxassetid://99317126567285", -- TorpedoExplosion
	},
	missile = {
		fire = "rbxassetid://118583481685197", -- MissileLaunch
		whiz = "rbxassetid://107693356082764", -- SeekingMissileLoop
		impact = "rbxassetid://76281306654576", -- MissileExplosion
	},
	turret = {
		fire = "rbxassetid://75514182535418", -- TurretShoot
		impact = "rbxassetid://98513589644368", -- TurretExplosion
	},
	walker = {
		fire = "rbxassetid://111375553713809", -- STShoot
		fireVolume = 2.4,
	},
}

CombatConfig.WalkerSounds = {
	STStartup = "rbxassetid://112557440110759",
	STShutdown = "rbxassetid://80165102309777",
	STInteriorEngineLoop = "rbxassetid://91978209349300",
	STExteriorEngineLoop = "rbxassetid://137210780198637",
	STShoot = "rbxassetid://111375553713809",
	HeadTurnLoop = "rbxassetid://118240328653206",
	HeadTurnStop1 = "rbxassetid://127274234943612",
	HeadTurnStop2 = "rbxassetid://95947314422507",
	FootStuck = "rbxassetid://77694437924374",
	FootStomp1 = "rbxassetid://123209633938252",
	FootStomp2 = "rbxassetid://134246852361904",
	FootStomp3 = "rbxassetid://75686405613610",
	FootStomp4 = "rbxassetid://73122570982203",
}

CombatConfig.FighterSounds = {
	engineLoop = "rbxassetid://81523091591629",
	startup = "rbxassetid://133156108150442",
	shutdown = "rbxassetid://130536465269031",
}

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

-- Vehicle destruction explosion tuning (applies to all VehicleEntity classes, including walkers).
CombatConfig.VehicleDeathExplosionRadius = 30
CombatConfig.VehicleDeathExplosionDamage = 220
CombatConfig.VehicleDeathExplosionVisualRadius = 30

-- Temporary testing toggle.
CombatConfig.FriendlyFireEnabled = true
CombatConfig.TestHarnessEnabled = false

return CombatConfig
