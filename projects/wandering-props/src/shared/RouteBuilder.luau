local RouteBuilder = {}

local function shuffledCopy(list)
	local out = table.clone(list)
	for i = #out, 2, -1 do
		local j = math.random(1, i)
		out[i], out[j] = out[j], out[i]
	end
	return out
end

function RouteBuilder.computeRoute(graph, spawnId: string, despawnId: string)
	if graph.nodes[spawnId] == nil or graph.nodes[despawnId] == nil then
		return nil
	end

	local queue = { spawnId }
	local head = 1
	local visited = { [spawnId] = true }
	local previous = {}

	while head <= #queue do
		local nodeId = queue[head]
		head += 1

		if nodeId == despawnId then
			local path = { despawnId }
			local current = despawnId
			while current ~= spawnId do
				current = previous[current]
				if current == nil then
					return nil
				end
				table.insert(path, 1, current)
			end
			return path
		end

		local node = graph.nodes[nodeId]
		if node then
			for _, neighborId in ipairs(shuffledCopy(node.connections)) do
				if not visited[neighborId] then
					visited[neighborId] = true
					previous[neighborId] = nodeId
					table.insert(queue, neighborId)
				end
			end
		end
	end

	return nil
end

function RouteBuilder.pickRandomSpawn(graph)
	return graph.spawns[math.random(1, #graph.spawns)]
end

function RouteBuilder.pickRandomDespawn(graph)
	return graph.despawns[math.random(1, #graph.despawns)]
end

function RouteBuilder.buildRoute(graph, walkSpeed: number)
	for _ = 1, 3 do
		local spawnId = RouteBuilder.pickRandomSpawn(graph)
		local despawnId = RouteBuilder.pickRandomDespawn(graph)
		local nodeIds = RouteBuilder.computeRoute(graph, spawnId, despawnId)
		if nodeIds then
			local waypoints = {}
			for _, nodeId in ipairs(nodeIds) do
				table.insert(waypoints, graph.nodes[nodeId].position)
			end

			local totalDistance = 0
			for i = 1, #waypoints - 1 do
				totalDistance += (waypoints[i + 1] - waypoints[i]).Magnitude
			end

			return {
				waypoints = waypoints,
				totalDistance = totalDistance,
			}
		end
	end

	return nil
end

function RouteBuilder.computeMultiSegmentRoute(graph, nodeSequence: { string })
	local fullPath = {}
	local poiIndices = {}

	for i = 1, #nodeSequence - 1 do
		local segment = RouteBuilder.computeRoute(graph, nodeSequence[i], nodeSequence[i + 1])
		if not segment then
			return nil, nil
		end

		local startJ = 1
		if #fullPath > 0 then
			startJ = 2
		end

		for j = startJ, #segment do
			table.insert(fullPath, segment[j])
		end

		if i < #nodeSequence - 1 then
			table.insert(poiIndices, #fullPath)
		end
	end

	return fullPath, poiIndices
end

return RouteBuilder
