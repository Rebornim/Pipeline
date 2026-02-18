--!strict

local CombatTypes = {}

export type WeaponConfig = {
	weaponClass: string?,
	damageType: string,
	damage: number,
	fireRate: number,
	projectileSpeed: number,
	maxRange: number,
	boltColor: Color3?,
	splashRadius: number?,
	burstCount: number?,
	burstInterval: number?,
	heatMax: number?,
	heatPerShot: number?,
	heatDecayPerSecond: number?,
	heatRecoverThreshold: number?,
}

export type EntityConfig = {
	hullHP: number,
	weaponId: string?,
	respawnTime: number?,
}

export type HealthState = {
	entityId: string,
	instance: Model,
	faction: string,
	config: EntityConfig,
	currentHP: number,
	maxHP: number,
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
	boltColor: Color3?,
}

export type ProjectileImpactPayload = {
	projectileId: string,
	hitPosition: Vector3,
	hitNormal: Vector3,
}

export type DamagePayload = {
	entityId: string,
	newHP: number,
	maxHP: number,
	hitPosition: Vector3,
}

export type HitConfirmPayload = {
	targetEntityId: string,
	hitPosition: Vector3,
	isKill: boolean,
}

export type RespawnedPayload = {
	entityId: string,
	hullHP: number,
}

return CombatTypes
