local PopulationHooks = {}

PopulationHooks.spawnPaused = false
PopulationHooks.walkSpeedMultiplier = 1.0
PopulationHooks.desyncedPlayers = {}

PopulationHooks.rerouteAllToNearestDespawn = nil
PopulationHooks.rebroadcastAllSpeeds = nil
PopulationHooks.sendBulkSyncToPlayer = nil

return PopulationHooks
