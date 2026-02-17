local Config = {}

-- POPULATION
Config.MaxPopulation = 20
Config.SpawnInterval = 2
Config.InitialSpawnBurst = true
Config.RecycleNPCsEnabled = true
Config.RecycleRespawnDelayMin = 0.35
Config.RecycleRespawnDelayMax = 1.00
Config.RecycleRetryDelayMin = 0.40
Config.RecycleRetryDelayMax = 1.20
Config.SpawnBuildTimeBudgetMs = 1.5

-- MOVEMENT
Config.BaseWalkSpeed = 8
Config.WalkSpeedVariation = 1.5

-- GROUND SNAP
Config.SnapRayOriginOffset = 10
Config.SnapRayLength = 50
Config.SnapHipOffset = 3

-- ANIMATIONS
Config.WalkAnimationId = "rbxassetid://98082498740442"
Config.IdleAnimationId = "rbxassetid://108108873581082"
Config.SitAnimationId = "rbxassetid://103743081006243"
Config.WalkAnimBaseSpeed = 10

-- DESPAWN SAFETY
Config.ClientDespawnBuffer = 10

-- DIAGNOSTICS
Config.DiagnosticsEnabled = false

-- RUNTIME MARKERS
Config.HideMarkersAtRuntime = true

-- POI GENERAL
Config.POICountMin = 2
Config.POICountMax = 4
Config.DefaultPOIWeight = 1.0

-- SCENIC POI
Config.ScenicDwellMin = 5
Config.ScenicDwellMax = 15

-- SOCIAL POI
Config.SocialDwellMin = 10
Config.SocialDwellMax = 30
Config.SocialCapacityPercent = 0.75
Config.SocialWeight = 0.7

-- MARKET POI
Config.MarketStandsMin = 2
Config.MarketStandsMax = 4
Config.MarketStandCapacity = 3
Config.MarketBrowseDwellMin = 4
Config.MarketBrowseDwellMax = 10
Config.MarketWeight = 0.8
Config.MarketHeadScanSpeed = 0.4

-- RANDOM WANDERING (disabled)
Config.WanderChance = 0
Config.WanderMaxDistance = 50

-- DAY/NIGHT
Config.DayNightEnabled = false
Config.NightStartHour = 19
Config.DayStartHour = 6
Config.NightPopulationMultiplier = 0.3
Config.NightPOICountMax = 1
Config.NightPreferNearestDespawn = true
Config.NightDrainEnabled = true
Config.NightDrainCheckInterval = 2
Config.NightDrainBatchSize = 3

-- LOD TIERS
Config.LODEnabled = true
Config.LODNearDistance = 200
Config.LODLowDistance = 500
Config.LODMidDistance = 800
Config.LODCheckInterval = 5
Config.LODLowRaycastSkip = 4
Config.LODMidRaycastSkip = 10
Config.LODLowMoveSkip = 2
Config.LODMidMoveSkip = 4

-- MODEL POOLING
Config.PoolEnabled = true
Config.PoolMaxPerModel = 10
Config.PoolPrewarmPerModel = 2
Config.PoolFallbackAnyModel = true

-- SPAWN LOAD SHEDDING
Config.SpawnFadeDisableAboveCount = 8

-- SPAWN/DESPAWN THROTTLE
Config.SpawnOpsPerHeartbeat = 4
Config.DespawnOpsPerHeartbeat = 8

-- NETWORK EVENT BATCHING
Config.EventBatchingEnabled = true
Config.EventBatchInterval = 0.05

-- CLIENT EVENT APPLICATION THROTTLE
Config.ClientEventOpsPerHeartbeat = 8

-- CORNER BEVELING
Config.BevelEnabled = true
Config.BevelRadius = 3
Config.BevelSegments = 4

-- SMOOTH ELEVATION
Config.GroundSnapSmoothing = true
Config.GroundSnapLerpSpeed = 15

-- SMOOTH ROTATION
Config.TurnSmoothing = true
Config.TurnLerpSpeed = 8

-- HEAD LOOK
Config.HeadLookEnabled = true
Config.HeadLookDistance = 45
Config.HeadLookChance = 0.35
Config.HeadLookDuration = 3
Config.HeadLookCheckInterval = 1.5
Config.HeadLookMaxYaw = 70
Config.HeadLookMaxPitch = 30
Config.HeadLookLerpSpeed = 5
Config.HeadLookDisableAboveCount = 40

-- PATH LATERAL OFFSET
Config.PathLateralOffsetMax = 2

-- INTERNAL POI NAVIGATION
Config.InternalNavigationEnabled = true

-- SPAWN/DESPAWN FADE
Config.FadeEnabled = true
Config.SpawnFadeDuration = 0.8
Config.DespawnFadeDuration = 0.6

return Config
