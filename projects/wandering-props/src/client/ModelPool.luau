local ModelPool = {}

local maxPerModel = 0
local pooledByModelName: { [string]: { any } } = {}

function ModelPool.init(maxCount: number)
	maxPerModel = math.max(0, math.floor(maxCount))
	pooledByModelName = {}
end

local function stopTrack(track: AnimationTrack?)
	if track and track.IsPlaying then
		track:Stop(0)
	end
end

function ModelPool.acquire(modelName: string)
	local pool = pooledByModelName[modelName]
	if not pool or #pool == 0 then
		return nil
	end

	local entry = table.remove(pool)
	if not entry then
		return nil
	end

	stopTrack(entry.walkTrack)
	stopTrack(entry.idleTrack)
	stopTrack(entry.sitTrack)

	if entry.model then
		entry.model.Parent = nil
	end

	return entry
end

function ModelPool.release(modelName: string, entry)
	if not entry or not entry.model then
		return
	end

	if maxPerModel <= 0 then
		entry.model:Destroy()
		return
	end

	local pool = pooledByModelName[modelName]
	if not pool then
		pool = {}
		pooledByModelName[modelName] = pool
	end

	if #pool >= maxPerModel then
		entry.model:Destroy()
		return
	end

	entry.model.Parent = nil
	table.insert(pool, entry)
end

function ModelPool.getStats()
	local total = 0
	local perModel = {}
	for modelName, pool in pairs(pooledByModelName) do
		perModel[modelName] = #pool
		total += #pool
	end
	return {
		total = total,
		perModel = perModel,
	}
end

return ModelPool
