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

local function resolvePOIWaypointNodeId(poiFolder: Folder, graph): string?
	local poiWaypoint = poiFolder:FindFirstChild("Waypoint")
	if poiWaypoint and poiWaypoint:IsA("BasePart") then
		local poiWaypointNodeId = graph.partToId[poiWaypoint]
		if poiWaypointNodeId and graph.nodes[poiWaypointNodeId] then
			return poiWaypointNodeId
		end
	end

	local candidateNodeIds = {}
	local candidateSet = {}
	local partByNodeId = {}
	for part, nodeId in pairs(graph.partToId) do
		if part and part:IsDescendantOf(poiFolder) then
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
			'[WanderingProps] WARNING: POI "%s" has multiple waypoint candidates inside the POI. Use a BasePart named "Waypoint" to disambiguate.',
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
		warn(string.format(
			'[WanderingProps] WARNING: POI "%s" has multiple ObjectValue links to different waypoints. Keep only one link.',
			poiFolder.Name
		))
		return nil
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

			local waypointNodeId = resolvePOIWaypointNodeId(child, graph)
			if not waypointNodeId or not graph.nodes[waypointNodeId] then
				local printedInvalidTarget = false
				for _, descendant in ipairs(child:GetDescendants()) do
					if descendant:IsA("ObjectValue") and descendant.Value then
						warn(string.format(
							'[WanderingProps] WARNING: POI "%s" link target "%s" from "%s" could not be resolved to a waypoint node.',
							child.Name,
							descendant.Value:GetFullName(),
							descendant:GetFullName()
						))
						printedInvalidTarget = true
					end
				end
				if not printedInvalidTarget then
					local waypointChild = child:FindFirstChild("Waypoint")
					if waypointChild and waypointChild:IsA("BasePart") then
						warn(string.format(
							'[WanderingProps] WARNING: POI "%s" Waypoint part "%s" is not connected to the graph. Link it via ObjectValue to a graph waypoint.',
							child.Name,
							waypointChild:GetFullName()
						))
					else
						warn(string.format(
							'[WanderingProps] WARNING: POI "%s" has no valid waypoint link. Add a Waypoint BasePart in the POI or add an ObjectValue link to a graph waypoint.',
							child.Name
						))
					end
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
			elseif poiType == "social" then
				local dwellMin, dwellMax = resolveDwellRange(child, child.Name, Config.SocialDwellMin, Config.SocialDwellMax)
				poi.dwellMin = dwellMin
				poi.dwellMax = dwellMax
				poi.capacityPercent = resolveNumberAttribute(child, "CapacityPercent", Config.SocialCapacityPercent)
				poi.socialWeight = resolveNumberAttribute(child, "SocialWeight", Config.SocialWeight)

				local seats = {}
				local groups = {}

				for _, groupChild in ipairs(child:GetChildren()) do
					if groupChild:IsA("Folder") or groupChild:IsA("Model") then
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
							table.insert(groups, {
								id = groupChild.Name,
								seatIndices = seatIndices,
								occupiedCount = 0,
							})
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
		return nil, nil
	end

	local seatIndex = emptySeatIndices[math.random(1, #emptySeatIndices)]
	poi.seats[seatIndex].occupiedBy = npcId
	group.occupiedCount += 1
	poi.occupiedCount += 1
	return seatIndex, poi.seats[seatIndex].cframe
end

function POIRegistry.claimSeat(poi, npcId: string)
	if poi.poiType ~= "social" or not poi.seats or not poi.groups then
		return nil, nil
	end

	local totalSeats = poi.totalSeats or #poi.seats
	local capacityPercent = poi.capacityPercent or Config.SocialCapacityPercent
	local occupiedCount = poi.occupiedCount or 0
	if occupiedCount >= math.floor(totalSeats * capacityPercent) then
		return nil, nil
	end

	local socialWeight = poi.socialWeight or Config.SocialWeight
	local preferOccupied = math.random() < socialWeight

	if preferOccupied then
		local socialGroups = {}
		for _, group in ipairs(poi.groups) do
			if group.occupiedCount > 0 and group.occupiedCount < #group.seatIndices then
				table.insert(socialGroups, group)
			end
		end
		if #socialGroups > 0 then
			local group = socialGroups[math.random(1, #socialGroups)]
			local seatIndex, seatCFrame = claimSeatInGroup(poi, group, npcId)
			if seatIndex then
				return seatIndex, seatCFrame
			end
		end
	end

	local emptySeats = {}
	for i, seat in ipairs(poi.seats) do
		if seat.occupiedBy == nil then
			table.insert(emptySeats, i)
		end
	end
	if #emptySeats == 0 then
		return nil, nil
	end

	local seatIndex = emptySeats[math.random(1, #emptySeats)]
	local group = nil
	for _, candidate in ipairs(poi.groups) do
		for _, groupSeatIndex in ipairs(candidate.seatIndices) do
			if groupSeatIndex == seatIndex then
				group = candidate
				break
			end
		end
		if group then
			break
		end
	end

	poi.seats[seatIndex].occupiedBy = npcId
	if group then
		group.occupiedCount += 1
	end
	poi.occupiedCount += 1
	return seatIndex, poi.seats[seatIndex].cframe
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
