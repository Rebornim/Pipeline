export type Node = {
	id: string,
	position: Vector3,
	nodeType: "waypoint" | "spawn" | "despawn",
	connections: { string },
	zoneSize: Vector3?,
}

export type POIStopData = {
	type: "scenic" | "busy" | "social",
	waypointIndex: number,
	dwellTime: number,
	viewTarget: Vector3?,
	seatCFrame: CFrame?,
}

export type SeatClaim = {
	poiId: string,
	seatIndex: number,
	releaseTime: number,
}

export type LODTier = "near" | "low" | "mid" | "far"

export type Graph = {
	nodes: { [string]: Node },
	spawns: { string },
	despawns: { string },
	partToId: { [Instance]: string },
}

export type NPCSpawnData = {
	id: string,
	modelName: string,
	modelTemplate: Model?,
	walkSpeed: number,
	waypoints: { Vector3 },
	startTime: number,
	poiStops: { POIStopData }?,
}

export type NPCRecord = {
	id: string,
	modelName: string,
	walkSpeed: number,
	waypoints: { Vector3 },
	startTime: number,
	totalDuration: number,
	modelTemplate: Model?,
	poiStops: { POIStopData }?,
	seatClaims: { SeatClaim }?,
}

export type NPCState = {
	id: string,
	model: Model,
	walkSpeed: number,
	waypoints: { Vector3 },
	currentLeg: number,
	legProgress: number,
	lastGroundY: number,
	expectedDespawnTime: number,
	animator: Animator,
	walkTrack: AnimationTrack,
	idleTrack: AnimationTrack,
	state: "walking" | "dwelling" | "walking_to_seat" | "sitting" | "walking_from_seat" | "finished",
	poiStops: { POIStopData }?,
	nextPoiStopIdx: number,
	dwellEndTime: number?,
	preSeatCFrame: CFrame?,
	seatTargetCFrame: CFrame?,
	sitTrack: AnimationTrack?,
	modelName: string,
	startTime: number,
	lodTier: LODTier,
	raycastPhase: number,
	lastKnownPosition: Vector3,
}

return nil
