--!strict

local SoundProfileTypes = {}

-- Continuous state passed every frame to profile:update()
export type VehicleFrameState = {
	speed: number,
	maxSpeed: number,
	speedFraction: number,
	hpFraction: number,
	isBoosting: boolean,
	isGrounded: boolean,
	throttle: number,
	steerInput: number,
	isLanding: boolean,
	isLocal: boolean,
	dt: number,
}

-- Discrete event data types
export type DamageTakenData = {
	amount: number,
	newHpFraction: number,
}

export type LeanStartData = {
	speedFraction: number,
	direction: number,
}

export type LandingData = {
	impactSpeed: number,
}

export type CollisionData = {
	impactSpeed: number,
}

export type WeaponFiredData = {
	weaponClass: string,
}

-- The controller interface every profile must implement
export type ProfileController = {
	update: (ProfileController, dt: number, state: VehicleFrameState) -> (),
	onEvent: (ProfileController, event: string, data: any?) -> (),
	destroy: (ProfileController) -> (),
}

-- The module interface every profile ModuleScript must export
export type ProfileModule = {
	createController: (
		sourceModel: Model,
		targetPart: BasePart,
		maxSpeed: number,
		isLocal: boolean
	) -> ProfileController,
}

return SoundProfileTypes
