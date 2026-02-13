-- Wandering Props Configuration
-- Every tunable gameplay value lives here. Adjust these to change game feel
-- without touching code. Reasonable ranges are documented in comments.

return {
    -- ==============================================
    -- POPULATION
    -- ==============================================

    -- Minimum active NPC count. Server spawns to reach this floor.
    -- Range: 5-50. Set equal to MAX for constant population.
    MIN_POPULATION = 20,

    -- Maximum active NPC count. Server stops spawning above this.
    -- Range: 20-100. Performance tested up to 70.
    MAX_POPULATION = 50,

    -- Seconds between spawn cycle checks. Lower = faster population recovery.
    -- Range: 1-10.
    SPAWN_CHECK_INTERVAL = 3,

    -- Max NPCs to spawn per cycle. Prevents burst-spawning 50 NPCs at once.
    -- Range: 1-5.
    SPAWNS_PER_CYCLE = 2,

    -- ==============================================
    -- MOVEMENT
    -- ==============================================

    -- Base NPC walk speed in studs/second.
    -- Range: 4-16. Roblox default Humanoid walk is 16.
    BASE_WALK_SPEED = 8,

    -- +/- random variation added to base speed per NPC.
    -- Range: 0-4. Example: base 8 +/- 2 = speeds from 6 to 10.
    WALK_SPEED_VARIATION = 1,

    -- Speed (studs/sec) at which the walk animation was authored.
    -- Used to scale animation playback rate: animSpeed = npcSpeed / this.
    -- Set this to match your walk animation's natural speed.
    WALK_ANIMATION_NATURAL_SPEED = 10,

    -- A* path turn penalty (cost units). Higher favors straighter routes.
    -- 0 = pure shortest-distance path.
    PATH_TURN_PENALTY = 1.5,

    -- Enable client-side path corner smoothing for walk segments.
    -- Uses arc-length remapping to keep movement speed visually consistent.
    PATH_SMOOTHING_ENABLED = true,

	-- Max control radius in studs for corner smoothing.
	-- Lower = tighter turns, higher = rounder arcs.
	PATH_SMOOTHING_RADIUS = 3.5,

    -- Arc-length sample count for corner smoothing. Higher = more accurate
    -- speed consistency, with slightly higher CPU cost.
    PATH_SMOOTHING_SAMPLES = 12,

    -- Max per-NPC lateral lane offset in studs during walk segments.
    -- 0 disables lane variation (recommended while validating speed consistency).
    PATH_LANE_OFFSET_MAX = 0,

	-- How many studs ahead the NPC looks when turning.
	-- Higher values create earlier, smoother steering through intersections.
	PATH_TURN_LOOKAHEAD = 8,

    -- Steering blend speed for turn smoothing (higher = snappier).
    -- Range: 4-20.
    PATH_TURN_BLEND_SPEED = 10,

	-- If facing dot falls below this threshold, steering snaps to target
	-- direction to avoid long backward-walk moments on hard reversals.
	-- Range: -1 to 1. Lower = fewer snaps.
	PATH_TURN_SNAP_DOT_THRESHOLD = -0.9,

    -- Enable walk-step ground snapping (client-side raycast).
    -- Keeps NPCs grounded when route points span slopes, hills, and ramps.
    GROUND_SNAP_ENABLED = true,

    -- Ray origin height above the interpolated walk position.
    -- Increase for tall elevation changes.
    GROUND_SNAP_RAY_HEIGHT = 40,

    -- Raycast length downward for ground detection.
    -- Must be larger than GROUND_SNAP_RAY_HEIGHT.
    GROUND_SNAP_RAY_LENGTH = 160,

    -- Extra Y offset above detected ground after snapping.
    -- Useful for tiny anti-clipping adjustment.
    GROUND_SNAP_CLEARANCE = 0,

    -- Max number of ignored ray hits before giving up.
    -- Lets the ray skip helper markers and other NPC parts.
    GROUND_SNAP_MAX_IGNORE_HITS = 8,

    -- ==============================================
    -- ROUTES
    -- ==============================================

    -- Min number of POIs per NPC route (before despawn).
    -- Range: 1-3.
    ROUTE_POI_MIN = 1,

    -- Max number of POIs per NPC route.
    -- Range: 1-5.
    ROUTE_POI_MAX = 3,

    -- Chance (0-1) that an NPC deviates to a random nearby node mid-route.
    -- Range: 0-0.5. 0 = never wander, 0.3 = 30% chance per route segment.
    WANDER_CHANCE = 0,

    -- Max graph hops from current node to consider for wander deviation.
    -- Range: 1-4. Higher = NPCs may wander further off path.
    WANDER_MAX_HOPS = 2,

    -- ==============================================
    -- LOD (LEVEL OF DETAIL) / DISTANCE CULLING
    -- ==============================================

    -- Distance in studs for full-rate movement updates + full animation playback.
    -- Beyond this, NPCs move in lower visual update-rate mode first.
    -- Range: 50-300.
    LOD_ANIMATION_DISTANCE = 150,

    -- Distance in studs where NPCs switch from low-rate mode to frozen-animation mode.
    -- Must be >= LOD_ANIMATION_DISTANCE and <= LOD_RENDER_DISTANCE.
    -- Range: 150-800.
    LOD_FREEZE_DISTANCE = 350,

    -- Distance in studs within which NPCs are rendered at all.
    -- Beyond this: model hidden, PivotTo skipped, only route timer runs.
    -- Range: 200-1000. Set to match your map's meaningful play area.
    -- For large maps with towns 1000+ studs apart, 400-500 is ideal.
    -- For small dense maps, set higher (800+) to keep all NPCs visible.
    LOD_RENDER_DISTANCE = 500,

    -- Visual update rate (Hz) for the low-rate LOD tier.
    -- Animations still play; movement/rotation updates are throttled.
    -- Range: 6-30.
    LOD_LOW_UPDATE_RATE = 12,

    -- Visual update rate (Hz) for the frozen-animation LOD tier.
    -- Lower values save more CPU but increase visible stepping.
    -- Range: 2-12.
    LOD_FROZEN_UPDATE_RATE = 4,

    -- Downgrade behind-camera NPCs out of full-detail tier.
    -- They still render, but use reduced LOD behavior until back in view.
    -- true = enabled (recommended). false = only distance-based LOD.
    LOD_FRUSTUM_CULLING = true,

    -- ==============================================
    -- SCENIC POI
    -- ==============================================

    -- Min seconds NPC idles at a scenic POI.
    -- Range: 2-15.
    SCENIC_IDLE_MIN = 3,

    -- Max seconds NPC idles at a scenic POI.
    -- Range: 5-30.
    SCENIC_IDLE_MAX = 8,

    -- ==============================================
    -- SOCIAL POI
    -- ==============================================

    -- Min seconds NPC sits at a social POI.
    -- Range: 5-30.
    SOCIAL_SIT_MIN = 10,

    -- Max seconds NPC sits at a social POI.
    -- Range: 15-60.
    SOCIAL_SIT_MAX = 30,

    -- Weight for preferring seats at tables with existing occupants.
    -- Higher = NPCs more likely to sit near others. 1 = no preference.
    -- Range: 1-5.
    SOCIAL_WEIGHT_OCCUPIED = 3,

    -- Weight for choosing an empty table.
    -- Range: 1-5.
    SOCIAL_WEIGHT_EMPTY = 1,

    -- ==============================================
    -- GROUP SPAWNING
    -- ==============================================

    -- Chance (0-1) that a spawn cycle produces a group instead of solo NPC.
    -- Range: 0-0.5. 0 = groups disabled.
    GROUP_SPAWN_CHANCE = 0.15,

    -- Min group size (including leader).
    -- Range: 2-3.
    GROUP_SIZE_MIN = 2,

    -- Max group size (including leader).
    -- Range: 3-5.
    GROUP_SIZE_MAX = 3,

    -- Lateral offset in studs for group followers relative to path direction.
    -- Range: 2-6. How far apart group members walk side-by-side.
    GROUP_FOLLOWER_OFFSET = 3,

    -- Random per-follower offset jitter in studs to break rigid formations.
    -- Range: 0-2. Set to 0 for deterministic lanes.
    GROUP_FOLLOWER_JITTER = 0.75,

    -- Seconds delay between leader and each successive follower starting movement.
    -- Range: 0.2-1.5. Creates staggered formation feel.
    GROUP_FOLLOWER_DELAY = 0.5,

    -- ==============================================
    -- DAY/NIGHT CYCLE (OPTIONAL)
    -- ==============================================

    -- Enable day/night population scaling. Reads Lighting.ClockTime.
    -- false = constant population regardless of time.
    DAY_NIGHT_ENABLED = false,

    -- Hour (0-24) when night begins. Uses Lighting.ClockTime.
    -- Range: 17-22.
    NIGHT_START_HOUR = 18,

    -- Hour (0-24) when night ends.
    -- Range: 4-8.
    NIGHT_END_HOUR = 6,

    -- Multiplier applied to MAX_POPULATION during night.
    -- Range: 0.1-0.8. 0.4 = 40% of daytime population.
    NIGHT_POPULATION_MULTIPLIER = 0.4,

    -- ==============================================
    -- NPC MODELS AND ANIMATIONS
    -- ==============================================

    -- Legacy setting retained for compatibility with earlier builds.
    -- Runtime now discovers all Model children under ReplicatedStorage.WanderingPropModels.
    -- Child model names can be anything.
    NPC_MODEL_COUNT = 14,

    -- Roblox animation asset IDs.
    -- Hard-coded test IDs to avoid re-pasting during Rojo sync loops.
    ANIM_WALK = "rbxassetid://98082498740442", -- Walk cycle animation
    ANIM_IDLE = "rbxassetid://108108873581082", -- Standing idle animation
    ANIM_SIT = "rbxassetid://103743081006243", -- Seated idle animation

    -- Extra model clones per variant in the client pool.
    -- Prevents pool exhaustion during group spawns (multiple NPCs of same variant).
    -- Range: 2-10.
    MODEL_POOL_BUFFER = 3,

    -- ==============================================
    -- STUCK NPC HANDLING
    -- ==============================================

    -- Grace period in seconds beyond computed route duration before force-despawning.
    -- If an NPC's total route should take 60s and STUCK_TIMEOUT is 30, the NPC is
    -- force-despawned at 90s. Safety net for broken node graphs or timing drift.
    -- Range: 10-60.
    STUCK_TIMEOUT = 30,

    -- NPCs with less than this many seconds of route remaining are excluded from
    -- late-join sync to prevent spawn-then-immediately-despawn flicker.
    -- Range: 3-10.
    SYNC_DESPAWN_THRESHOLD = 5,

    -- ==============================================
    -- DEBUG
    -- ==============================================

    -- Enable debug logging via warn(). Useful for buyers debugging node graph setup.
    -- false = silent (production). true = logs spawn/despawn/route/error events to console.
    DEBUG_ENABLED = false,

    -- ==============================================
    -- COLLECTION SERVICE TAG NAMES
    -- ==============================================

    -- Tag names for workspace Parts. Change these if they conflict with
    -- the buyer's existing tags.
    TAG_WAYPOINT = "WP_Waypoint",
    TAG_SPAWN = "WP_Spawn",
    TAG_DESPAWN = "WP_Despawn",
    TAG_SCENIC = "WP_Scenic",
    TAG_BUSY = "WP_Busy",
    TAG_SOCIAL = "WP_Social",
    TAG_SEAT = "WP_Seat",
}
