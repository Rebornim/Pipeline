local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local sharedFolder = ReplicatedStorage:WaitForChild("WanderingPropsShared")
local Config = require(sharedFolder:WaitForChild("Config"))

local NPCMover = {}

local raycastParams: RaycastParams?
local waypointsFolderRef: Folder?
local activeNPCsFolderRef: Folder?

local function rebuildRaycastFilter()
	if not raycastParams then
		return
	end

	local excludes = {}

	if waypointsFolderRef then
		table.insert(excludes, waypointsFolderRef)
	end
	if activeNPCsFolderRef then
		table.insert(excludes, activeNPCsFolderRef)
	end

	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			table.insert(excludes, player.Character)
		end
	end

	raycastParams.FilterDescendantsInstances = excludes
end

function NPCMover.init(waypointsFolder: Folder, activeNPCsFolder: Folder)
	waypointsFolderRef = waypointsFolder
	activeNPCsFolderRef = activeNPCsFolder

	raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.IgnoreWater = true

	rebuildRaycastFilter()

	for _, player in ipairs(Players:GetPlayers()) do
		player.CharacterAdded:Connect(function()
			rebuildRaycastFilter()
		end)
		player.CharacterRemoving:Connect(function()
			rebuildRaycastFilter()
		end)
	end

	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function()
			rebuildRaycastFilter()
		end)
		player.CharacterRemoving:Connect(function()
			rebuildRaycastFilter()
		end)
		rebuildRaycastFilter()
	end)

	Players.PlayerRemoving:Connect(function()
		rebuildRaycastFilter()
	end)
end

local function calculateFlatPosition(npc)
	local waypoints = npc.waypoints
	local finished = npc.currentLeg >= #waypoints

	if finished then
		return waypoints[#waypoints], waypoints[#waypoints], true
	end

	local from = waypoints[npc.currentLeg]
	local to = waypoints[npc.currentLeg + 1]
	return from:Lerp(to, npc.legProgress), to, false
end

function NPCMover.update(npc, dt: number, stopAtWaypoint: number?, skipRaycast: boolean?)
	local waypoints = npc.waypoints
	if #waypoints <= 1 then
		return true
	end

	local distanceToTravel = math.max(0, dt) * npc.walkSpeed
	while distanceToTravel > 0 and npc.currentLeg < #waypoints do
		if stopAtWaypoint and npc.currentLeg >= stopAtWaypoint then
			break
		end

		local from = waypoints[npc.currentLeg]
		local to = waypoints[npc.currentLeg + 1]
		local legDistance = (to - from).Magnitude

		if legDistance <= 0 then
			npc.currentLeg += 1
			npc.legProgress = 0
		else
			local traveledOnLeg = npc.legProgress * legDistance
			local remainingOnLeg = legDistance - traveledOnLeg

			if distanceToTravel < remainingOnLeg then
				traveledOnLeg += distanceToTravel
				npc.legProgress = traveledOnLeg / legDistance
				distanceToTravel = 0
			else
				distanceToTravel -= remainingOnLeg
				npc.currentLeg += 1
				npc.legProgress = 0
			end
		end
	end

	local flatPosition, nextWaypoint, finished = calculateFlatPosition(npc)

	local snappedY = npc.lastGroundY
	if not skipRaycast then
		local rayOrigin = flatPosition + Vector3.new(0, Config.SnapRayOriginOffset, 0)
		local rayDirection = Vector3.new(0, -Config.SnapRayLength, 0)
		local hitResult = Workspace:Raycast(rayOrigin, rayDirection, raycastParams)
		if hitResult then
			snappedY = hitResult.Position.Y + Config.SnapHipOffset
			npc.lastGroundY = snappedY
		end
	end

	local snappedPosition = Vector3.new(flatPosition.X, snappedY, flatPosition.Z)
	local targetFlat = Vector3.new(nextWaypoint.X, snappedPosition.Y, nextWaypoint.Z)

	local newCFrame
	if (targetFlat - snappedPosition).Magnitude > 0.001 then
		newCFrame = CFrame.lookAt(snappedPosition, targetFlat)
	else
		newCFrame = CFrame.new(snappedPosition)
	end

	if npc.model.PrimaryPart then
		npc.model.PrimaryPart.CFrame = newCFrame
	end

	return finished
end

function NPCMover.calculatePositionAtTime(waypoints: { Vector3 }, walkSpeed: number, elapsed: number)
	if #waypoints == 0 then
		return Vector3.zero, 1, 0
	end

	if #waypoints == 1 then
		return waypoints[1], 0, 1.0
	end

	local distanceCovered = math.max(0, elapsed) * walkSpeed
	for i = 1, #waypoints - 1 do
		local legDist = (waypoints[i + 1] - waypoints[i]).Magnitude
		if legDist <= 0 then
			if distanceCovered <= 0 then
				return waypoints[i + 1], i, 1.0
			end
		else
			if distanceCovered <= legDist then
				local progress = distanceCovered / legDist
				return waypoints[i]:Lerp(waypoints[i + 1], progress), i, progress
			end
			distanceCovered -= legDist
		end
	end

	return waypoints[#waypoints], #waypoints - 1, 1.0
end

return NPCMover
