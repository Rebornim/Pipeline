local ReplicatedStorage = game:GetService("ReplicatedStorage")

local sharedFolder = ReplicatedStorage:WaitForChild("WanderingPropsShared")
local Config = require(sharedFolder:WaitForChild("Config"))

local POIRegistry = {}

local function makeUniqueId(baseName: string, usedIds)
	local id = baseName
	local suffix = 1
	while usedIds[id] do
		suffix += 1
		id = string.format("%s__%d", baseName, suffix)
	end
	usedIds[id] = true
	return id
end

local function resolveNumberAttribute(instance: Instance, name: string, fallback: number): number
	local value = instance:GetAttribute(name)
	if type(value) == "number" then
		return value
	end
	return fallback
end

local function resolveDwellRange(poiFolder: Folder, poiName: string, defaultMin: number, defaultMax: number)
	local dwellMin = resolveNumberAttribute(poiFolder, "DwellMin", defaultMin)
	local dwellMax = resolveNumberAttribute(poiFolder, "DwellMax", defaultMax)
	if dwellMin > dwellMax then
		warn(string.format('[WanderingProps] WARNING: POI "%s" DwellMin > DwellMax. Using DwellMin for both.', poiName))
		dwellMax = dwellMin
	end
	return dwellMin, dwellMax
end

local function resolveWaypointNodeIdFromTarget(target: Instance?, graph): string?
	if not target then
		return nil
	end

	if target:IsA("ObjectValue") then
		return resolveWaypointNodeIdFromTarget(target.Value, graph)
	end

	if target:IsA("BasePart") then
		local directId = graph.partToId[target]
		if directId then
			return directId
		end
	end

	if target:IsA("Attachment") then
		local parentPart = target.Parent
		if parentPart and parentPart:IsA("BasePart") then
			local parentId = graph.partToId[parentPart]
			if parentId then
				return parentId
			end
		end
	end

	return nil
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

local function resolvePOIWaypointNodeId(poiFolder: Folder, graph): string?
	local attributedCandidates = {}
	for _, descendant in ipairs(poiFolder:GetDescendants()) do
		if descendant:IsA("BasePart") and descendant:GetAttribute("POIWaypoint") == true then
			local nodeId = graph.partToId[descendant]
			if nodeId and graph.nodes[nodeId] then
				table.insert(attributedCandidates, nodeId)
			end
		end
	end
	if #attributedCandidates == 1 then
		return attributedCandidates[1]
	end
	if #attributedCandidates > 1 then
		warn(string.format(
			'[WanderingProps] WARNING: POI "%s" has multiple parts with Attribute POIWaypoint=true. Keep exactly one.',
			poiFolder.Name
		))
		return nil
	end

	local poiWaypoint = poiFolder:FindFirstChild("Waypoint")
	if poiWaypoint and poiWaypoint:IsA("BasePart") then
		local poiWaypointNodeId = graph.partToId[poiWaypoint]
		if poiWaypointNodeId and graph.nodes[poiWaypointNodeId] then
			return poiWaypointNodeId
		end
	end

	local internalWaypointsFolder = poiFolder:FindFirstChild("InternalWaypoints")
	local candidateNodeIds = {}
	local candidateSet = {}
	local partByNodeId = {}
	for part, nodeId in pairs(graph.partToId) do
		if part and part:IsDescendantOf(poiFolder) then
			if internalWaypointsFolder and part:IsDescendantOf(internalWaypointsFolder) then
				continue
			end
			if not candidateSet[nodeId] then
				candidateSet[nodeId] = true
				table.insert(candidateNodeIds, nodeId)
			end
			partByNodeId[nodeId] = part
		end
	end

	if #candidateNodeIds == 1 then
		return candidateNodeIds[1]
	end
	if #candidateNodeIds > 1 then
		local directChildCandidates = {}
		local directChildSet = {}
		for _, nodeId in ipairs(candidateNodeIds) do
			local part = partByNodeId[nodeId]
			if part and part.Parent == poiFolder and not directChildSet[nodeId] then
				directChildSet[nodeId] = true
				table.insert(directChildCandidates, nodeId)
			end
		end
		if #directChildCandidates == 1 then
			return directChildCandidates[1]
		end

		local linkedCandidates = {}
		local linkedSet = {}
		for _, nodeId in ipairs(candidateNodeIds) do
			local part = partByNodeId[nodeId]
			if part then
				for _, child in ipairs(part:GetChildren()) do
					if child:IsA("ObjectValue") then
						local target = child.Value
						if target and target:IsA("ObjectValue") then
							target = target.Value
						end

						local targetPart = nil
						if target and target:IsA("BasePart") then
							targetPart = target
						elseif target and target:IsA("Attachment") then
							local parentPart = target.Parent
							if parentPart and parentPart:IsA("BasePart") then
								targetPart = parentPart
							end
						end

						if targetPart and graph.partToId[targetPart] and not targetPart:IsDescendantOf(poiFolder) then
							if not linkedSet[nodeId] then
								linkedSet[nodeId] = true
								table.insert(linkedCandidates, nodeId)
							end
							break
						end
					end
				end
			end
		end

		if #linkedCandidates == 1 then
			return linkedCandidates[1]
		end

		warn(string.format(
			'[WanderingProps] WARNING: POI "%s" has multiple waypoint candidates inside the POI. Set exactly one part Attribute POIWaypoint=true to disambiguate.',
			poiFolder.Name
		))
		return nil
	end

	local resolvedByObjectValue = {}
	local resolvedByObjectValueSet = {}
	for _, descendant in ipairs(poiFolder:GetDescendants()) do
		if descendant:IsA("ObjectValue") then
			local resolvedId = resolveWaypointNodeIdFromTarget(descendant.Value, graph)
			if resolvedId and graph.nodes[resolvedId] and not resolvedByObjectValueSet[resolvedId] then
				resolvedByObjectValueSet[resolvedId] = true
				table.insert(resolvedByObjectValue, resolvedId)
			end
		end
	end

	if #resolvedByObjectValue == 1 then
		return resolvedByObjectValue[1]
	end
	if #resolvedByObjectValue > 1 then
		-- Multiple external links can be intentional (multi-entrance POIs).
		-- Use first as fallback; caller may still choose a better entrance later.
		return resolvedByObjectValue[1]
	end

	return nil
end

local function resolveWaypointPartByNodeId(graph, waypointNodeId: string): BasePart?
	for part, nodeId in pairs(graph.partToId) do
		if nodeId == waypointNodeId and part and part:IsA("BasePart") then
			return part
		end
	end
	return nil
end

local function discoverInternalGraph(poiFolder: Folder, graph): any?
	local iwFolder = poiFolder:FindFirstChild("InternalWaypoints")
	if not iwFolder then
		warn(string.format(
			'[WanderingProps] WARNING: POI "%s" has no InternalWaypoints folder. Internal graph disabled for this POI.',
			poiFolder.Name
		))
		return nil
	end
	if not iwFolder:IsA("Folder") then
		warn(string.format(
			'[WanderingProps] WARNING: POI "%s" InternalWaypoints must be a Folder (got %s). Internal graph disabled.',
			poiFolder.Name,
			iwFolder.ClassName
		))
		return nil
	end

	local nodes = {}
	local entryNodeIds = {}
	local partToInternalId = {}
	local entryToEntranceMap = {}
	local usedInternalIds = {}
	local poiWaypoint = poiFolder:FindFirstChild("Waypoint")
	local poiWaypointPart = if poiWaypoint and poiWaypoint:IsA("BasePart") then poiWaypoint else nil
	local poiWaypointNodeId = if poiWaypointPart then graph.partToId[poiWaypointPart] else nil

	local function markEntryNode(internalNodeId: string, graphNodeId: string)
		nodes[internalNodeId].isEntry = true
		if not table.find(entryNodeIds, internalNodeId) then
			table.insert(entryNodeIds, internalNodeId)
		end
		entryToEntranceMap[internalNodeId] = graphNodeId
	end

	for _, child in ipairs(iwFolder:GetChildren()) do
		if child:IsA("BasePart") then
			local nodeId = makeUniqueId(child.Name, usedInternalIds)
			nodes[nodeId] = {
				id = nodeId,
				position = child.Position,
				connections = {},
				isEntry = false,
			}
			partToInternalId[child] = nodeId

			if Config.HideMarkersAtRuntime then
				child.Transparency = 1
			end
			child.CanCollide = false
			child.Anchored = true
		end
	end

	if next(nodes) == nil then
		warn(string.format(
			'[WanderingProps] WARNING: POI "%s" InternalWaypoints has no BasePart children. Internal graph disabled.',
			poiFolder.Name
		))
		return nil
	end

	-- Resolve ObjectValue links between internal nodes and to external entrances.
	for _, child in ipairs(iwFolder:GetChildren()) do
		if child:IsA("BasePart") then
			local fromId = partToInternalId[child]
			if fromId then
				for _, ov in ipairs(child:GetDescendants()) do
					if ov:IsA("ObjectValue") and ov.Value then
						local targetPart = resolveLinkTargetPart(ov.Value, nil)
						if targetPart then
							local targetInternalId = partToInternalId[targetPart]
							if targetInternalId then
								if not table.find(nodes[fromId].connections, targetInternalId) then
									table.insert(nodes[fromId].connections, targetInternalId)
								end
								if not table.find(nodes[targetInternalId].connections, fromId) then
									table.insert(nodes[targetInternalId].connections, fromId)
								end
							else
								local graphNodeId = graph.partToId[targetPart]
								if graphNodeId then
									markEntryNode(fromId, graphNodeId)
								else
									warn(string.format(
										'[WanderingProps] WARNING: POI "%s" internal link "%s" targets "%s", which is not an internal node or graph waypoint.',
										poiFolder.Name,
										ov:GetFullName(),
										targetPart:GetFullName()
									))
								end
							end
						else
							warn(string.format(
								'[WanderingProps] WARNING: POI "%s" internal link "%s" has unresolved target.',
								poiFolder.Name,
								ov:GetFullName()
							))
						end
					end
				end
			end
		end
	end

	-- Support reverse link direction: POI Waypoint -> internal node.
	if poiWaypointPart and poiWaypointNodeId then
		for _, ov in ipairs(poiWaypointPart:GetDescendants()) do
			if ov:IsA("ObjectValue") and ov.Value then
				local targetPart = resolveLinkTargetPart(ov.Value, iwFolder)
				if targetPart then
					local targetInternalId = partToInternalId[targetPart]
					if targetInternalId then
						markEntryNode(targetInternalId, poiWaypointNodeId)
					end
				end
			end
		end
	end

	if #entryNodeIds == 0 then
		warn(string.format(
			'[WanderingProps] WARNING: POI "%s" InternalWaypoints has no entry nodes linked to a graph waypoint. Internal graph ignored.',
			poiFolder.Name
		))
		for nodeId, node in pairs(nodes) do
			local connList = table.concat(node.connections, ",")
			warn(string.format(
				'  node="%s" connections=[%s] isEntry=%s',
				nodeId,
				connList,
				tostring(node.isEntry)
			))
		end
		return nil
	end

	local nodeCount = 0
	for _ in pairs(nodes) do
		nodeCount += 1
	end
	if Config.DiagnosticsEnabled then
		local entryList = table.concat(entryNodeIds, ",")
		print(string.format(
			'[WanderingProps] INTERNAL_GRAPH_BUILT poi="%s" nodes=%d entries=[%s]',
			poiFolder.Name,
			nodeCount,
			entryList
		))
	end

	return {
		nodes = nodes,
		entryNodeIds = entryNodeIds,
		entryToEntranceMap = entryToEntranceMap,
		partToInternalId = partToInternalId,
	}
end
function POIRegistry.computeInternalPath(internalGraph, fromNodeId: string, toNodeId: string): { Vector3 }?
	if not internalGraph or not internalGraph.nodes[fromNodeId] or not internalGraph.nodes[toNodeId] then
		return nil
	end
	if fromNodeId == toNodeId then
		return { internalGraph.nodes[fromNodeId].position }
	end

	-- Dijkstra on the internal graph (weighted by edge distance).
	local distances = {}
	local parent = {}
	local unvisited = {}

	for nodeId in pairs(internalGraph.nodes) do
		distances[nodeId] = math.huge
		unvisited[nodeId] = true
	end
	distances[fromNodeId] = 0

	while true do
		local current = nil
		local currentDist = math.huge
		for nodeId in pairs(unvisited) do
			local d = distances[nodeId] or math.huge
			if d < currentDist then
				currentDist = d
				current = nodeId
			end
		end

		if not current or currentDist == math.huge then
			break
		end
		if current == toNodeId then
			break
		end

		unvisited[current] = nil
		local node = internalGraph.nodes[current]
		if node then
			for _, neighborId in ipairs(node.connections) do
				if unvisited[neighborId] and internalGraph.nodes[neighborId] then
					local neighborNode = internalGraph.nodes[neighborId]
					local edgeDistance = (neighborNode.position - node.position).Magnitude
					local candidateDist = currentDist + edgeDistance
					if candidateDist < (distances[neighborId] or math.huge) then
						distances[neighborId] = candidateDist
						parent[neighborId] = current
					end
				end
			end
		end
	end

	if (distances[toNodeId] or math.huge) == math.huge then
		return nil
	end

	-- Reconstruct path
	local path = {}
	local current = toNodeId
	while current do
		table.insert(path, 1, internalGraph.nodes[current].position)
		current = parent[current]
	end
	return path
end

function POIRegistry.getCachedInternalPath(poi, entryNodeId: string, accessNodeId: string): ({ Vector3 } | false)?
	if not poi or not poi.cachedInternalPaths then
		return nil
	end
	local key = entryNodeId .. ">" .. accessNodeId
	return poi.cachedInternalPaths[key]
end

local function discoverStandPoints(poiFolder: Folder): { any }?
	local spFolder = poiFolder:FindFirstChild("StandPoints")
	if not spFolder or not spFolder:IsA("Folder") then
		return nil
	end

	local standPoints = {}
	for _, child in ipairs(spFolder:GetChildren()) do
		if child:IsA("BasePart") then
			table.insert(standPoints, {
				position = child.Position,
				size = child.Size,
				cframe = child.CFrame,
				sourcePart = child,
			})

			if Config.HideMarkersAtRuntime then
				child.Transparency = 1
			end
			child.CanCollide = false
			child.Anchored = true
		end
	end

	if #standPoints == 0 then
		return nil
	end
	return standPoints
end

local function resolveGroupAccessNodeId(groupFolder: Instance, internalGraph, partToInternalId: { [Instance]: string }): string?
	-- Look for AccessPoint ObjectValue in the group
	local accessPoint = groupFolder:FindFirstChild("AccessPoint")
	if accessPoint and accessPoint:IsA("ObjectValue") and accessPoint.Value then
		local targetPart = resolveLinkTargetPart(accessPoint.Value, nil)
		if targetPart then
			local targetId = partToInternalId[targetPart]
			if targetId and internalGraph.nodes[targetId] then
				return targetId
			end
			warn(string.format(
				'[WanderingProps] WARNING: Social group "%s" AccessPoint target "%s" is not a valid internal waypoint.',
				groupFolder:GetFullName(),
				targetPart:GetFullName()
			))
		else
			warn(string.format(
				'[WanderingProps] WARNING: Social group "%s" AccessPoint has unresolved target.',
				groupFolder:GetFullName()
			))
		end
	end
	return nil
end

local function resolveStandPointAccessNodeId(
	standPointPart: BasePart,
	internalGraph,
	partToInternalId: { [Instance]: string }
): string?
	local accessPoint = standPointPart:FindFirstChild("AccessPoint")
	if accessPoint and accessPoint:IsA("ObjectValue") and accessPoint.Value then
		local targetPart = resolveLinkTargetPart(accessPoint.Value, nil)
		if targetPart then
			local targetId = partToInternalId[targetPart]
			if targetId and internalGraph.nodes[targetId] then
				return targetId
			end
			warn(string.format(
				'[WanderingProps] WARNING: Scenic stand point "%s" AccessPoint target "%s" is not a valid internal waypoint.',
				standPointPart:GetFullName(),
				targetPart:GetFullName()
			))
		else
			warn(string.format(
				'[WanderingProps] WARNING: Scenic stand point "%s" AccessPoint has unresolved target.',
				standPointPart:GetFullName()
			))
		end
	end
	return nil
end

local function findClosestInternalNode(position: Vector3, internalGraph): string?
	local closestId = nil
	local closestDist = math.huge
	for nodeId, node in pairs(internalGraph.nodes) do
		local dist = (node.position - position).Magnitude
		if dist < closestDist then
			closestDist = dist
			closestId = nodeId
		end
	end
	return closestId
end

local function makeInternalPathCacheKey(entryNodeId: string, accessNodeId: string): string
	return entryNodeId .. ">" .. accessNodeId
end

local function buildCachedInternalPaths(poi, accessNodeIds: { string }?)
	if not poi.internalGraph or not poi.internalGraph.entryNodeIds then
		return
	end
	if not accessNodeIds or #accessNodeIds == 0 then
		return
	end

	local uniqueAccessNodeIds = {}
	local accessSet = {}
	for _, accessNodeId in ipairs(accessNodeIds) do
		if accessNodeId and not accessSet[accessNodeId] then
			accessSet[accessNodeId] = true
			table.insert(uniqueAccessNodeIds, accessNodeId)
		end
	end
	if #uniqueAccessNodeIds == 0 then
		return
	end

	local cachedInternalPaths = {}
	for _, entryNodeId in ipairs(poi.internalGraph.entryNodeIds) do
		for _, accessNodeId in ipairs(uniqueAccessNodeIds) do
			local key = makeInternalPathCacheKey(entryNodeId, accessNodeId)
			local path = POIRegistry.computeInternalPath(poi.internalGraph, entryNodeId, accessNodeId)
			cachedInternalPaths[key] = path or false
		end
	end

	poi.cachedInternalPaths = cachedInternalPaths
end

function POIRegistry.discover(poisFolder: Folder, graph)
	if not poisFolder then
		return nil
	end

	local registry = {
		pois = {},
		totalWeight = 0,
	}
	local usedIds = {}

	for _, child in ipairs(poisFolder:GetChildren()) do
		if child:IsA("Folder") then
			local poiType = child:GetAttribute("POIType")
			if poiType ~= "scenic" and poiType ~= "busy" and poiType ~= "social" then
				warn(string.format('[WanderingProps] WARNING: POI "%s" has invalid or missing POIType. Skipped.', child.Name))
				continue
			end

			local hasInternalWaypoints = child:FindFirstChild("InternalWaypoints") ~= nil
			local precomputedInternalGraph = nil
			if hasInternalWaypoints and (poiType == "social" or poiType == "scenic") then
				precomputedInternalGraph = discoverInternalGraph(child, graph)
			end

			local fallbackEntrances = nil
			if precomputedInternalGraph and precomputedInternalGraph.entryToEntranceMap then
				local entranceSet = {}
				local entranceNodeIds = {}
				for _, entranceId in pairs(precomputedInternalGraph.entryToEntranceMap) do
					if not entranceSet[entranceId] then
						entranceSet[entranceId] = true
						table.insert(entranceNodeIds, entranceId)
					end
				end
				if #entranceNodeIds > 0 then
					fallbackEntrances = entranceNodeIds
				end
			end

			local waypointNodeId = resolvePOIWaypointNodeId(child, graph)
			if (not waypointNodeId or not graph.nodes[waypointNodeId]) and fallbackEntrances and #fallbackEntrances > 0 then
				-- Internal-graph entrances can fully define POI entry without a dedicated "Waypoint" part.
				waypointNodeId = fallbackEntrances[1]
			end

			if not waypointNodeId or not graph.nodes[waypointNodeId] then
				local waypointChild = child:FindFirstChild("Waypoint")
				if waypointChild and waypointChild:IsA("BasePart") then
					warn(string.format(
						'[WanderingProps] WARNING: POI "%s" Waypoint part "%s" is not connected to the graph. Link it via ObjectValue to a graph waypoint.',
						child.Name,
						waypointChild:GetFullName()
					))
				elseif hasInternalWaypoints then
					warn(string.format(
						'[WanderingProps] WARNING: POI "%s" has InternalWaypoints but no valid external entrance links were found.',
						child.Name
					))
				else
					warn(string.format(
						'[WanderingProps] WARNING: POI "%s" has no valid waypoint link. Add a POI waypoint link to the graph.',
						child.Name
					))
				end
				warn(string.format('[WanderingProps] WARNING: POI "%s" has no valid Waypoint link. Skipped.', child.Name))
				continue
			end

			local poi = {
				id = makeUniqueId(child.Name, usedIds),
				instance = child,
				poiType = poiType,
				weight = resolveNumberAttribute(child, "Weight", Config.DefaultPOIWeight),
				waypointNodeId = waypointNodeId,
				waypointPosition = graph.nodes[waypointNodeId].position,
				waypointSize = nil,
				waypointIsInsidePOI = false,
			}
			local waypointPart = resolveWaypointPartByNodeId(graph, waypointNodeId)
			if waypointPart then
				poi.waypointSize = waypointPart.Size
				poi.waypointIsInsidePOI = waypointPart:IsDescendantOf(child)
			end

				if poiType == "scenic" then
				local dwellMin, dwellMax = resolveDwellRange(child, child.Name, Config.ScenicDwellMin, Config.ScenicDwellMax)
				poi.dwellMin = dwellMin
				poi.dwellMax = dwellMax

				local viewZone = child:FindFirstChild("ViewZone")
				if viewZone and viewZone:IsA("BasePart") then
					if Config.HideMarkersAtRuntime then
						viewZone.Transparency = 1
					end
					viewZone.CanCollide = false
					poi.viewTarget = viewZone.Position
				else
					warn(string.format('[WanderingProps] WARNING: Scenic POI "%s" has no ViewZone child. Will face arrival direction.', child.Name))
				end

				local internalGraph = precomputedInternalGraph
				poi.internalGraph = internalGraph

				if internalGraph and internalGraph.entryToEntranceMap then
					local entranceSet = {}
					local entranceNodeIds = {}
					for _, entranceId in pairs(internalGraph.entryToEntranceMap) do
						if not entranceSet[entranceId] then
							entranceSet[entranceId] = true
							table.insert(entranceNodeIds, entranceId)
						end
					end
					if #entranceNodeIds > 0 then
						poi.entranceNodeIds = entranceNodeIds
					end
				end

				local partToInternalId = if internalGraph and internalGraph.partToInternalId
					then internalGraph.partToInternalId
					else {}
					poi.standPoints = discoverStandPoints(child)
					if poi.standPoints and internalGraph then
						local standAccessNodeIds = {}
						for _, standPoint in ipairs(poi.standPoints) do
							local standPointPart = standPoint.sourcePart
							if standPointPart and standPointPart:IsA("BasePart") then
							local accessNodeId = resolveStandPointAccessNodeId(standPointPart, internalGraph, partToInternalId)
							if not accessNodeId then
								accessNodeId = findClosestInternalNode(standPointPart.Position, internalGraph)
								end
								standPoint.accessNodeId = accessNodeId
								if accessNodeId then
									table.insert(standAccessNodeIds, accessNodeId)
								end
							end
						end
						buildCachedInternalPaths(poi, standAccessNodeIds)
					end
				elseif poiType == "social" then
				local dwellMin, dwellMax = resolveDwellRange(child, child.Name, Config.SocialDwellMin, Config.SocialDwellMax)
				poi.dwellMin = dwellMin
				poi.dwellMax = dwellMax
				poi.capacityPercent = resolveNumberAttribute(child, "CapacityPercent", Config.SocialCapacityPercent)
				poi.socialWeight = resolveNumberAttribute(child, "SocialWeight", Config.SocialWeight)
				poi.hasInternalWaypoints = hasInternalWaypoints

				local internalGraph = precomputedInternalGraph
				poi.internalGraph = internalGraph

				-- Collect all unique external entrance node IDs
				if internalGraph and internalGraph.entryToEntranceMap then
					local entranceSet = {}
					local entranceNodeIds = {}
					for _, entranceId in pairs(internalGraph.entryToEntranceMap) do
						if not entranceSet[entranceId] then
							entranceSet[entranceId] = true
							table.insert(entranceNodeIds, entranceId)
						end
					end
					if #entranceNodeIds > 0 then
						poi.entranceNodeIds = entranceNodeIds
					end
				end

				local partToInternalId = if internalGraph and internalGraph.partToInternalId
					then internalGraph.partToInternalId
					else {}

					local seats = {}
					local groups = {}
					local groupAccessNodeIds = {}

				for _, groupChild in ipairs(child:GetChildren()) do
					if (groupChild:IsA("Folder") or groupChild:IsA("Model"))
						and groupChild.Name ~= "InternalWaypoints" then
						local seatIndices = {}
						for _, seatChild in ipairs(groupChild:GetChildren()) do
							if seatChild:IsA("BasePart") then
								if Config.HideMarkersAtRuntime then
									seatChild.Transparency = 1
								end
								seatChild.CanCollide = false
								seatChild.Anchored = true

								table.insert(seats, {
									cframe = seatChild.CFrame,
									groupIndex = #groups + 1,
									occupiedBy = nil,
								})
								table.insert(seatIndices, #seats)
							end
						end

							if #seatIndices > 0 then
								-- Resolve access node ID for this group.
								-- Fallback to nearest internal node if no explicit AccessPoint is authored.
								local groupAccessNodeId = nil
								if internalGraph then
									groupAccessNodeId = resolveGroupAccessNodeId(groupChild, internalGraph, partToInternalId)
									if not groupAccessNodeId then
										local centroid = Vector3.zero
										for _, seatIndex in ipairs(seatIndices) do
											local seat = seats[seatIndex]
											if seat then
												centroid += seat.cframe.Position
											end
										end
										centroid /= #seatIndices
										groupAccessNodeId = findClosestInternalNode(centroid, internalGraph)
									end
								end

									table.insert(groups, {
										id = groupChild.Name,
										seatIndices = seatIndices,
										occupiedCount = 0,
										accessNodeId = groupAccessNodeId,
									})
									if groupAccessNodeId then
										table.insert(groupAccessNodeIds, groupAccessNodeId)
									end
								end
							end
						end

				if #seats == 0 then
					warn(string.format('[WanderingProps] WARNING: Social POI "%s" has no valid seats. Skipped.', child.Name))
					continue
				end

					poi.seats = seats
					poi.groups = groups
					poi.totalSeats = #seats
					poi.occupiedCount = 0
					buildCachedInternalPaths(poi, groupAccessNodeIds)
				end

			table.insert(registry.pois, poi)
			registry.totalWeight += poi.weight
		end
	end

	return registry
end

local function weightedUniqueSelect(pois, count: number)
	local pool = table.clone(pois)
	local selected = {}

	local poolWeight = 0
	for _, poi in ipairs(pool) do
		poolWeight += poi.weight
	end

	for _ = 1, count do
		if #pool == 0 then
			break
		end

		if poolWeight <= 0 then
			local idx = math.random(1, #pool)
			local fallbackPoi = table.remove(pool, idx)
			table.insert(selected, fallbackPoi)
		else
			local roll = math.random() * poolWeight
			local acc = 0
			local chosenIdx = 1
			for i, poi in ipairs(pool) do
				acc += poi.weight
				if roll <= acc then
					chosenIdx = i
					break
				end
			end

			local chosenPoi = table.remove(pool, chosenIdx)
			table.insert(selected, chosenPoi)
			poolWeight -= chosenPoi.weight
		end
	end

	return selected
end

function POIRegistry.selectPOIs(registry, count: number, spawnPosition: Vector3)
	if not registry or count <= 0 then
		return {}
	end

	local selected = weightedUniqueSelect(registry.pois, count)
	local ordered = {}
	local remaining = table.clone(selected)
	local cursor = spawnPosition

	while #remaining > 0 do
		local nearestIndex = 1
		local nearestDist = (remaining[1].waypointPosition - cursor).Magnitude
		for i = 2, #remaining do
			local dist = (remaining[i].waypointPosition - cursor).Magnitude
			if dist < nearestDist then
				nearestDist = dist
				nearestIndex = i
			end
		end

		local poi = table.remove(remaining, nearestIndex)
		table.insert(ordered, poi)
		cursor = poi.waypointPosition
	end

	return ordered
end

local function claimSeatInGroup(poi, group, npcId: string)
	local emptySeatIndices = {}
	for _, seatIndex in ipairs(group.seatIndices) do
		if poi.seats[seatIndex].occupiedBy == nil then
			table.insert(emptySeatIndices, seatIndex)
		end
	end

	if #emptySeatIndices == 0 then
		return nil, nil, nil
	end

	local seatIndex = emptySeatIndices[math.random(1, #emptySeatIndices)]
	poi.seats[seatIndex].occupiedBy = npcId
	group.occupiedCount += 1
	poi.occupiedCount += 1
	return seatIndex, poi.seats[seatIndex].cframe, group.accessNodeId
end

local function hasReachableInternalPathToAccessNode(poi, accessNodeId: string?): boolean
	if not accessNodeId or not poi.internalGraph then
		return false
	end

	local entryNodeIds = poi.internalGraph.entryNodeIds
	if not entryNodeIds or #entryNodeIds == 0 then
		return false
	end

	for _, entryId in ipairs(entryNodeIds) do
		local candidatePath = POIRegistry.getCachedInternalPath(poi, entryId, accessNodeId)
		if candidatePath and #candidatePath >= 2 then
			return true
		end
	end

	return false
end

local function isGroupEligibleForSeatClaim(poi, group): boolean
	if Config.InternalNavigationEnabled then
		if poi.internalGraph then
			if group.accessNodeId == nil then
				return false
			end
			return hasReachableInternalPathToAccessNode(poi, group.accessNodeId)
		end
		if poi.hasInternalWaypoints then
			return false
		end
	end
	return true
end

function POIRegistry.claimSeat(poi, npcId: string)
	if poi.poiType ~= "social" or not poi.seats or not poi.groups then
		return nil, nil, nil
	end

	local totalSeats = poi.totalSeats or #poi.seats
	local capacityPercent = poi.capacityPercent or Config.SocialCapacityPercent
	local occupiedCount = poi.occupiedCount or 0
	if occupiedCount >= math.floor(totalSeats * capacityPercent) then
		return nil, nil, nil
	end

	local socialWeight = poi.socialWeight or Config.SocialWeight
	local preferOccupied = math.random() < socialWeight

	if preferOccupied then
		local socialGroups = {}
		for _, group in ipairs(poi.groups) do
			if group.occupiedCount > 0
				and group.occupiedCount < #group.seatIndices
				and isGroupEligibleForSeatClaim(poi, group) then
				table.insert(socialGroups, group)
			end
		end
		if #socialGroups > 0 then
			local group = socialGroups[math.random(1, #socialGroups)]
			local seatIndex, seatCFrame, accessNodeId = claimSeatInGroup(poi, group, npcId)
			if seatIndex then
				return seatIndex, seatCFrame, accessNodeId
			end
		end
	end

	local emptySeats = {}
	for i, seat in ipairs(poi.seats) do
		if seat.occupiedBy == nil then
			local seatGroup = poi.groups[seat.groupIndex]
			if seatGroup and isGroupEligibleForSeatClaim(poi, seatGroup) then
				table.insert(emptySeats, i)
			end
		end
	end
	if #emptySeats == 0 then
		return nil, nil, nil
	end

	local seatIndex = emptySeats[math.random(1, #emptySeats)]
	local group = nil
	local chosenSeat = poi.seats[seatIndex]
	if chosenSeat then
		group = poi.groups[chosenSeat.groupIndex]
	end

	poi.seats[seatIndex].occupiedBy = npcId
	if group then
		group.occupiedCount += 1
	end
	poi.occupiedCount += 1
	return seatIndex, poi.seats[seatIndex].cframe, if group then group.accessNodeId else nil
end

function POIRegistry.releaseSeat(poi, seatIndex: number)
	if poi.poiType ~= "social" or not poi.seats or not poi.groups then
		return
	end

	local seat = poi.seats[seatIndex]
	if not seat then
		return
	end

	if seat.occupiedBy ~= nil then
		seat.occupiedBy = nil
		for _, group in ipairs(poi.groups) do
			for _, groupSeatIndex in ipairs(group.seatIndices) do
				if groupSeatIndex == seatIndex then
					if group.occupiedCount > 0 then
						group.occupiedCount -= 1
					end
					break
				end
			end
		end
		if poi.occupiedCount and poi.occupiedCount > 0 then
			poi.occupiedCount -= 1
		end
	end
end

function POIRegistry.getPOI(registry, poiId: string)
	if not registry then
		return nil
	end

	for _, poi in ipairs(registry.pois) do
		if poi.id == poiId then
			return poi
		end
	end
	return nil
end

return POIRegistry
