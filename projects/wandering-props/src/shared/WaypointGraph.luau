local WaypointGraph = {}

local function getNodeType(part: BasePart): "waypoint" | "spawn" | "despawn"
	local value = part:GetAttribute("NodeType")
	if value == "spawn" then
		return "spawn"
	end
	if value == "despawn" then
		return "despawn"
	end
	return "waypoint"
end

local function ensureConnection(node, targetId: string)
	for _, existingId in ipairs(node.connections) do
		if existingId == targetId then
			return
		end
	end
	table.insert(node.connections, targetId)
end

local function resolveLinkTargetPart(value: Instance?, requiredRoot: Instance?): BasePart?
	local target = value
	if target and target:IsA("ObjectValue") then
		target = target.Value
	end

	local part = nil
	if target and target:IsA("BasePart") then
		part = target
	elseif target and target:IsA("Attachment") then
		local parent = target.Parent
		if parent and parent:IsA("BasePart") then
			part = parent
		end
	end

	if part and requiredRoot and not part:IsDescendantOf(requiredRoot) then
		return nil
	end

	return part
end

function WaypointGraph.build(waypointsFolder: Folder)
	local nodes = {}
	local spawns = {}
	local despawns = {}
	local partToId = {}
	local usedIds = {}
	local wanderingFolder = waypointsFolder.Parent
	local poisFolder = nil
	if wanderingFolder and wanderingFolder:IsA("Folder") then
		local maybePOIs = wanderingFolder:FindFirstChild("POIs")
		if maybePOIs and maybePOIs:IsA("Folder") then
			poisFolder = maybePOIs
		end
	end

	local function makeUniqueId(baseName: string): string
		local id = baseName
		local suffix = 1
		while usedIds[id] do
			suffix += 1
			id = string.format("%s__%d", baseName, suffix)
		end
		usedIds[id] = true
		return id
	end

	local function ensureNodeForPart(part: BasePart, baseName: string, nodeType: "waypoint" | "spawn" | "despawn")
		local existingId = partToId[part]
		if existingId then
			return existingId
		end

		local nodeId = makeUniqueId(baseName)
		partToId[part] = nodeId
		local isZone = part:GetAttribute("Zone") == true
		nodes[nodeId] = {
			id = nodeId,
			position = part.Position,
			nodeType = nodeType,
			connections = {},
			zoneSize = if isZone and nodeType == "waypoint" then part.Size else nil,
		}

		if nodeType == "spawn" then
			table.insert(spawns, nodeId)
		elseif nodeType == "despawn" then
			table.insert(despawns, nodeId)
		end

		return nodeId
	end

	for _, child in ipairs(waypointsFolder:GetChildren()) do
		if child:IsA("BasePart") then
			local nodeId = ensureNodeForPart(child, child.Name, getNodeType(child))
			if nodeId ~= child.Name then
				warn(string.format(
					"[WanderingProps] WARNING: Duplicate waypoint part name \"%s\" detected. Using internal ID \"%s\".",
					child.Name,
					nodeId
				))
			end
		end
	end

	if poisFolder then
		for _, poiChild in ipairs(poisFolder:GetChildren()) do
			if poiChild:IsA("Folder") then
				local poiWaypoint = poiChild:FindFirstChild("Waypoint")
				if poiWaypoint and poiWaypoint:IsA("BasePart") then
					ensureNodeForPart(poiWaypoint, string.format("%s_Waypoint", poiChild.Name), "waypoint")
				end
			end
		end

		-- Support linking from regular waypoints to POI waypoint parts.
		for _, sourcePart in ipairs(waypointsFolder:GetChildren()) do
			if sourcePart:IsA("BasePart") then
				for _, child in ipairs(sourcePart:GetChildren()) do
					if child:IsA("ObjectValue") then
						local targetPart = resolveLinkTargetPart(child.Value, poisFolder)
						if targetPart then
							ensureNodeForPart(targetPart, targetPart.Name, "waypoint")
						end
					end
				end
			end
		end

		-- Support linking from POI waypoint parts to regular graph waypoints.
		for _, poiChild in ipairs(poisFolder:GetChildren()) do
			if poiChild:IsA("Folder") then
				for _, desc in ipairs(poiChild:GetDescendants()) do
					if desc:IsA("ObjectValue") then
						local targetPart = resolveLinkTargetPart(desc.Value, waypointsFolder)
						if targetPart then
							local sourcePart = nil
							if desc.Parent and desc.Parent:IsA("BasePart") and desc.Parent:IsDescendantOf(poiChild) then
								sourcePart = desc.Parent
							else
								local ancestorPart = desc:FindFirstAncestorWhichIsA("BasePart")
								if ancestorPart and ancestorPart:IsDescendantOf(poiChild) then
									sourcePart = ancestorPart
								end
							end

							if sourcePart then
								ensureNodeForPart(sourcePart, sourcePart.Name, "waypoint")
							end
						end
					end
				end
			end
		end
	end

	for sourcePart, nodeId in pairs(partToId) do
		local node = nodes[nodeId]
		for _, child in ipairs(sourcePart:GetChildren()) do
			if child:IsA("ObjectValue") then
				local target = child.Value
				if target and target:IsA("ObjectValue") then
					target = target.Value
				end

				local targetId = nil
				if target and target:IsA("BasePart") then
					targetId = partToId[target]
				elseif target and target:IsA("Attachment") then
					local parentPart = target.Parent
					if parentPart and parentPart:IsA("BasePart") then
						targetId = partToId[parentPart]
					end
				end

				if targetId and nodes[targetId] ~= nil then
					ensureConnection(node, targetId)
					ensureConnection(nodes[targetId], nodeId)
				else
					local valueName = "nil"
					if target and target:IsA("Instance") then
						valueName = target.Name
					end
					warn(string.format(
						"[WanderingProps] WARNING: Node \"%s\" has connection to invalid target \"%s\". Ignored.",
						sourcePart.Name,
						valueName
					))
				end
			end
		end
	end

	local graph = {
		nodes = nodes,
		spawns = spawns,
		despawns = despawns,
		partToId = partToId,
	}

	if #graph.spawns == 0 then
		return nil, "[WanderingProps] FATAL: No spawn nodes found. Set NodeType attribute to \"spawn\"."
	end
	if #graph.despawns == 0 then
		return nil, "[WanderingProps] FATAL: No despawn nodes found. Set NodeType attribute to \"despawn\"."
	end

	return graph, nil
end

function WaypointGraph.validate(graph)
	local queue = {}
	local head = 1
	local visited = {}

	for _, spawnId in ipairs(graph.spawns) do
		visited[spawnId] = true
		table.insert(queue, spawnId)
	end

	while head <= #queue do
		local nodeId = queue[head]
		head += 1

		local node = graph.nodes[nodeId]
		if node then
			if node.nodeType == "despawn" then
				return true, nil
			end

			for _, neighborId in ipairs(node.connections) do
				if not visited[neighborId] then
					visited[neighborId] = true
					table.insert(queue, neighborId)
				end
			end
		end
	end

	return false, "[WanderingProps] FATAL: No valid path from any spawn to any despawn. Check connections."
end

return WaypointGraph
