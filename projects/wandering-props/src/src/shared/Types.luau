--!strict

local Types = {}

export type POIType = "scenic" | "busy" | "social"
export type NodeType = "spot" | "zone"
export type NodeRole = "waypoint" | "spawn" | "despawn"
export type LODTier = "near" | "low" | "mid" | "far"

export type SeatData = {
    id: string,
    instance: BasePart,
    cframe: CFrame,
    approachNodeId: string?,
}

export type POIData = {
    poiType: POIType,
    weight: number,
    viewZone: BasePart?,
    seats: { SeatData }?,
}

export type NodeData = {
    id: string,
    instance: BasePart,
    position: Vector3,
    nodeType: NodeType,
    nodeRole: NodeRole,
    connections: { string },
    size: Vector3?,
    poi: POIData?,
    socialPOIId: string?,
}

export type RouteStep = {
    type: "walk" | "scenic" | "social" | "despawn",
    targetPosition: Vector3,
    distance: number,
    dwellTime: number?,
    seatCFrame: CFrame?,
    viewPosition: Vector3?,
    poiName: string?,
}

export type AnimatorHandle = {
    animator: Animator,
    walkTrack: AnimationTrack,
    idleTrack: AnimationTrack,
    sitTrack: AnimationTrack,
}

export type NPCData = {
    npcId: string,
    modelIndex: number,
    walkSpeed: number,
    route: { RouteStep },
    stepDurations: { number },
    cumulativeTimes: { number },
    totalDuration: number,
    spawnTime: number,
    currentStepIndex: number,
    state: "active" | "despawning",
    seatClaims: { [number]: string }?,
    startPosition: Vector3,
}

export type ClientNPC = {
    npcId: string,
    model: Model,
    walkSpeed: number,
    route: { RouteStep },
    stepDurations: { number },
    cumulativeTimes: { number },
    startTime: number,
    startPosition: Vector3,
    animatorHandle: AnimatorHandle,
    currentStepType: string,
    virtualPosition: Vector3,
    lodTier: LODTier,
}

export type SeatClaim = {
    seatId: string,
    poiNodeId: string,
    cframe: CFrame,
    approachNodeId: string?,
}

export type SpawnPayload = {
    npcId: string,
    modelIndex: number,
    walkSpeed: number,
    route: { RouteStep },
    startPosition: Vector3,
}

export type BulkSyncEntry = {
    npcId: string,
    modelIndex: number,
    walkSpeed: number,
    route: { RouteStep },
    startPosition: Vector3,
    currentStepIndex: number,
    stepElapsed: number,
}

return Types
