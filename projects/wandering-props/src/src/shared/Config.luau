--!strict

return table.freeze({
    BUILD_SIGNATURE = "wandering-props-v3-2026-02-14-0040",
    -------------------------------------------------------------------
    -- DEBUG
    -------------------------------------------------------------------
    DEBUG_MODE = false,
    DIAG_TRAIL_LENGTH = 8,
    CONTROLLER_DEBUG_MODE = false,
    CONTROLLER_DEBUG_INTERVAL = 10.0,
    CLIENT_DEBUG_MODE = false,
    CLIENT_RECONCILE_INTERVAL = 5.0,

    -------------------------------------------------------------------
    -- POPULATION
    -------------------------------------------------------------------
    MIN_POPULATION = 70,
    MAX_POPULATION = 70,
    SPAWN_INTERVAL = 3.5,
    SPAWN_RAMP_TIME = 30,
    MAINTAIN_MIN_POPULATION = true,
    SPAWN_BURST_PER_PASS = 8,
    SPAWN_MAX_ATTEMPTS_PER_PASS = 16,

    -------------------------------------------------------------------
    -- MOVEMENT
    -------------------------------------------------------------------
    BASE_WALK_SPEED = 10,
    WALK_SPEED_VARIATION = 0.8,
    GROUND_SNAP_HEIGHT = 10,
    GROUND_SNAP_DISTANCE = 64,
    GROUND_SNAP_CLEARANCE = 0.05,
    PATH_LATERAL_OFFSET_MAX = 0.9,
    PATH_CURVE_STRENGTH = 0.0,
    PATH_CURVE_SAMPLES = 18,
    PATH_LOOKAHEAD_FRACTION = 0.14,
    PATH_CORNER_BEVEL_DISTANCE = 7.5,
    PATH_CORNER_BEVEL_SEGMENTS = 4,
    TURN_SMOOTH_SPEED = 10,

    -------------------------------------------------------------------
    -- ROUTES
    -------------------------------------------------------------------
    MIN_POIS_PER_ROUTE = 3,
    MAX_POIS_PER_ROUTE = 5,
    ALLOW_POI_REPEATS = false,
    POI_REPEAT_CHANCE = 0.0,
    POI_AVOID_IMMEDIATE_REPEAT = true,
    WANDER_CHANCE = 0.15,
    WANDER_MAX_DISTANCE = 30,

    -------------------------------------------------------------------
    -- GROUP SPAWNING
    -------------------------------------------------------------------
    GROUP_SPAWN_CHANCE = 0.2,
    GROUP_SIZE_MIN = 2,
    GROUP_SIZE_MAX = 4,
    GROUP_SPEED_VARIATION = 0.4,

    -------------------------------------------------------------------
    -- SCENIC POI
    -------------------------------------------------------------------
    SCENIC_DWELL_MIN = 4.0,
    SCENIC_DWELL_MAX = 10.0,

    -------------------------------------------------------------------
    -- SOCIAL POI
    -------------------------------------------------------------------
    SOCIAL_DWELL_MIN = 8.0,
    SOCIAL_DWELL_MAX = 20.0,
    SOCIAL_CAPACITY_PERCENT = 0.75,
    SOCIAL_GROUP_WEIGHT = 0.7,
    SOCIAL_SEAT_HEIGHT_OFFSET = -2.25,

    -------------------------------------------------------------------
    -- ANIMATIONS
    -------------------------------------------------------------------
    WALK_ANIMATION_ID = "rbxassetid://98082498740442",
    IDLE_ANIMATION_ID = "rbxassetid://108108873581082",
    SIT_ANIMATION_ID = "rbxassetid://103743081006243",

    -------------------------------------------------------------------
    -- LOD (Optimization Layer)
    -------------------------------------------------------------------
    LOD_NEAR_DISTANCE = 150,
    LOD_LOW_DISTANCE = 325,
    LOD_MID_DISTANCE = 700,
    LOD_FAR_CULL_DISTANCE = 1500,
    LOD_CHECK_INTERVAL = 1.5,
    LOD_LOW_UPDATE_FRAMES = 3,
    LOD_MID_UPDATE_FRAMES = 6,
    LOD_LOW_ANIMATION_FPS = 10,
    LOD_ENABLE_FAR_CULL = true,

    -------------------------------------------------------------------
    -- DAY/NIGHT CYCLE
    -------------------------------------------------------------------
    DAY_NIGHT_ENABLED = false,
    NIGHT_POPULATION_MULTIPLIER = 0.5,
    NIGHT_INDICATOR_NAME = "WP_IsNight",

    -------------------------------------------------------------------
    -- TIMING
    -------------------------------------------------------------------
    SERVER_TICK_RATE = 0.5,
    DESPAWN_LINGER = 0.0,
    DESPAWN_DWELL_MIN = 0.5,
    DESPAWN_DWELL_MAX = 2.5,

    -------------------------------------------------------------------
    -- TAGS / RUNTIME NAMES
    -------------------------------------------------------------------
    TAG_NODE = "WP_Node",
    TAG_POI = "WP_POI",
    TAG_SEAT = "WP_Seat",
    TAG_VIEW_ZONE = "WP_ViewZone",

    MODELS_FOLDER_NAME = "WanderingPropModels",
    REMOTES_FOLDER_NAME = "WanderingPropsRemotesV3",
    REMOTE_SPAWN_NAME = "WP_Spawn",
    REMOTE_DESPAWN_NAME = "WP_Despawn",
    REMOTE_BULK_SYNC_NAME = "WP_BulkSync",

    WORKSPACE_ROOT_NAME = "WanderingPropsRuntimeV3",
    WORKSPACE_NODES_FOLDER_NAME = "Nodes",
    WORKSPACE_ACTIVE_NPCS_FOLDER_NAME = "ActiveNPCsV3",
    MODEL_TEMPLATE_INDEX_ATTRIBUTE = "WP_TemplateIndex",

    MODEL_POOL_ENABLED = false,
    MODEL_POOL_BUFFER = 2,
})
