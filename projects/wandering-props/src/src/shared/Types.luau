-- Shared type definitions used by both server and client modules.

local Types = {}

-- Actions an NPC can perform at a route step.
export type Action = "walk" | "idle" | "sit" | "despawn"

-- A single step in an NPC's route.
export type RouteStep = {
    position: Vector3, -- world position to walk to
    action: Action, -- what to do when arriving
    duration: number?, -- seconds to idle/sit (nil for walk/despawn)
    faceCFrame: CFrame?, -- for scenic idle: face this direction
    sitCFrame: CFrame?, -- for sit: exact seated CFrame
}

-- Payload sent via WP_SpawnNPC RemoteEvent.
export type SpawnPayload = {
    id: string, -- unique NPC identifier (e.g., "npc_42")
    modelIndex: number, -- 1-based index into runtime-discovered model templates
    speed: number, -- walk speed in studs/sec (base + variation)
    route: { RouteStep }, -- ordered steps from spawn to despawn
    groupId: string?, -- shared ID for group members, nil for solo
}

-- Per-NPC data stored in NPCRegistry (server only).
export type NPCRecord = {
    id: string,
    modelIndex: number,
    speed: number,
    route: { RouteStep },
    stepTimestamps: { number }, -- cumulative seconds from spawn when each step is reached
    totalDuration: number, -- total route time in seconds
    spawnTime: number, -- tick() when NPC was spawned
    groupId: string?,
    reservedSeats: { Part }, -- seat Parts this NPC has reserved (for cleanup)
}

-- Per-NPC sync data sent via WP_SyncState for late-joining players.
export type SyncNPCData = {
    modelIndex: number,
    speed: number,
    currentPosition: Vector3, -- approximate position right now
    currentAction: Action, -- what NPC is doing right now
    actionTimeRemaining: number, -- seconds left on current idle/sit (0 for walk)
    remainingRoute: { RouteStep }, -- steps after current action completes
    groupId: string?,
}

-- Client-side runtime NPC state (managed by NPCClient/NPCMover).
export type LODTier = "near" | "mid" | "far"

export type ClientNPC = {
    id: string,
    model: Model,
    speed: number,
    route: { RouteStep },
    currentStepIndex: number,
    stepStartTime: number, -- tick() when current step began (client time)
    groupId: string?,
    animator: Animator,
    walkTrack: AnimationTrack,
    idleTrack: AnimationTrack,
    sitTrack: AnimationTrack,
    lodTier: LODTier, -- current LOD tier, updated each frame by NPCMover
    lastPosition: Vector3, -- cached position for distance checks (avoids reading CFrame of hidden models)
}

-- Node graph node (server only, internal to NodeGraph module).
export type GraphNode = {
    part: Part, -- the workspace Part
    tag: string, -- which CollectionService tag
    position: Vector3, -- part.Position
    isZone: boolean, -- if true, NPC picks random point within bounds
    size: Vector3?, -- part.Size (only for zones)
    connections: { GraphNode }, -- adjacent nodes (from ObjectValue children)
    weight: number?, -- POI selection weight
    viewTargets: { Part }?, -- scenic POI: candidate Parts NPC can face
    seats: { Part }?, -- social POI: child Parts tagged WP_Seat
    capacityCap: number?, -- social POI: max fraction of seats usable
}

return Types
