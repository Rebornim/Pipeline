local PopulationHooks = {}

PopulationHooks.spawnPaused = false
PopulationHooks.populationOverride = nil
PopulationHooks.drainEnabled = false
PopulationHooks.drainBatchSize = 3
PopulationHooks.drainCheckInterval = 2

PopulationHooks.desyncedPlayers = {}

PopulationHooks.sendBulkSyncToPlayer = nil
PopulationHooks.rerouteAllToNearestDespawn = nil

return PopulationHooks
