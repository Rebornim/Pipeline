--!strict

local CombatTypes = {}

export type WeaponConfig = {
	damageType: string,
	damage: number,
	fireRate: number,
	projectileSpeed: number,
	maxRange: number,
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
	origin: Vector3,
	direction: Vector3,
	speed: number,
	maxRange: number,
	damage: number,
	damageType: string,
	faction: string,
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
}

export type DamagePayload = {
	entityId: string,
	newHP: number,
	maxHP: number,
	hitPosition: Vector3,
}

export type RespawnedPayload = {
	entityId: string,
	hullHP: number,
}

return CombatTypes
