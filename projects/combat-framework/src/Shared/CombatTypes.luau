--!strict

local CombatTypes = {}

export type DamageTypeMultiplier = {
	shieldMult: number,
	hullMult: number,
	bypass: number?,
}

export type WeaponConfig = {
	weaponClass: string?,
	damageType: string,
	damage: number,
	fireRate: number,
	projectileSpeed: number,
	maxRange: number,
	lockRange: number?,
	unlockedSpread: number?,
	autoAimSpread: number?,
	requiresLock: boolean?,
	homingTurnRate: number?,
	boltColor: Color3?,
	splashRadius: number?,
	burstCount: number?,
	burstInterval: number?,
	heatMax: number?,
	heatPerShot: number?,
	heatDecayPerSecond: number?,
	heatRecoverThreshold: number?,
	ammoCapacity: number?,
}

export type EntityConfig = {
	hullHP: number,
	shieldHP: number?,
	shieldRegenRate: number?,
	shieldRegenDelay: number?,
	weaponId: string?,
	turretExposed: boolean?,
	respawnTime: number?,
}

export type LockState = {
	attackerEntityId: string,
	targetEntityId: string,
	lockedAt: number,
}

export type HealthState = {
	entityId: string,
	instance: Model,
	faction: string,
	config: EntityConfig,
	currentHP: number,
	maxHP: number,
	currentShieldHP: number,
	maxShieldHP: number,
	state: string,
	respawnTimer: thread?,
}

export type ProjectileData = {
	projectileId: string,
	sourceEntityId: string,
	sourceInstance: Model,
	sourceCharacter: Model?,
	origin: Vector3,
	direction: Vector3,
	speed: number,
	maxRange: number,
	damage: number,
	damageType: string,
	faction: string,
	boltColor: Color3?,
	splashRadius: number?,
	targetEntityId: string?,
	homingTurnRate: number?,
	currentPosition: Vector3?,
	createdAt: number,
}

export type ValidatedEntity = {
	instance: Model,
	configId: string,
	faction: string,
	weaponMount: BasePart?,
	muzzlePoint: Attachment?,
	turretSeat: Seat?,
}

export type ProjectileFiredPayload = {
	projectileId: string,
	origin: Vector3,
	direction: Vector3,
	speed: number,
	maxRange: number,
	damageType: string?,
	targetEntityId: string?,
	homingTurnRate: number?,
	boltColor: Color3?,
}

export type ProjectileImpactPayload = {
	projectileId: string,
	hitPosition: Vector3,
	hitNormal: Vector3,
	impactType: string?,
	shieldBroken: boolean?,
}

export type DamagePayload = {
	entityId: string,
	newHP: number,
	maxHP: number,
	hitPosition: Vector3,
	newShieldHP: number?,
	maxShieldHP: number?,
}

export type HitConfirmPayload = {
	targetEntityId: string,
	hitPosition: Vector3,
	isKill: boolean,
}

export type EntityDestroyedPayload = {
	entityId: string,
	explosionPosition: Vector3?,
	explosionRadius: number?,
}

export type RespawnedPayload = {
	entityId: string,
	hullHP: number,
	shieldHP: number?,
}

export type VehicleConfig = {
	vehicleClass: string,
	entityConfigId: string,
	maxSpeed: number,
	acceleration: number,
	deceleration: number,
	brakingDeceleration: number,
	reverseMaxSpeed: number,
	turnSpeedLow: number,
	turnSpeedHigh: number,
	leanTurnRate: number,
	leanBankAngle: number,
	leanSpeedPenalty: number,
	leanEntryDuration: number,
	leanEntryYawBoost: number,
	leanEntrySpeedBoost: number,
	leanExitDuration: number,
	leanExitCounterBankDeg: number,
	leanCameraOffset: number,
	leanShakeAmplitude: number,
	leanShakeDuration: number,
	leanDustEmitCount: number,
	lateralGripLow: number,
	lateralGripHigh: number,
	accelerationTaper: number,
	accelerationMinFactor: number,
	tiltStiffness: number,
	tiltDamping: number,
	landingShakeThreshold: number,
	landingShakeIntensity: number,
	hoverHeight: number,
	springStiffness: number,
	springDamping: number,
	gravity: number,
	maxClimbSlope: number,
	fallDamageThreshold: number,
	fallDamageScale: number,
	collisionDamageThreshold: number,
	collisionDamageScale: number,
	collisionBounce: number,
	collisionRadius: number,
	cameraDistance: number,
	cameraHeight: number,
	cameraLerpSpeed: number,
}

export type VehicleInputPayload = {
	throttle: number,
	steerX: number,
	lean: number,
}

export type VehicleRuntimeState = {
	vehicleId: string,
	entityId: string,
	instance: Model,
	primaryPart: BasePart,
	driverSeat: Seat,
	hoverPoints: { BasePart },
	config: VehicleConfig,
	driver: Player?,
	velocity: Vector3,
	heading: number,
	isAirborne: boolean,
	lastGroundedTick: number,
	lastVerticalSpeed: number,
	inputThrottle: number,
	inputSteerX: number,
	inputLean: number,
	connections: { RBXScriptConnection },
}

return CombatTypes
