local Config = {}

-- POPULATION
Config.MaxPopulation = 20
Config.SpawnInterval = 2
Config.InitialSpawnBurst = true

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

-- MODEL POOLING
Config.PoolEnabled = true
Config.PoolMaxPerModel = 10
Config.PoolPrewarmPerModel = 2

-- SPAWN/DESPAWN THROTTLE
Config.SpawnOpsPerHeartbeat = 4
Config.DespawnOpsPerHeartbeat = 8

-- NETWORK EVENT BATCHING
Config.EventBatchingEnabled = true
Config.EventBatchInterval = 0.05

-- CLIENT EVENT APPLICATION THROTTLE
Config.ClientEventOpsPerHeartbeat = 8

return Config
