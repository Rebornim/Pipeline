--!strict

local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local HoverPhysics = {}

function HoverPhysics.step(
	hoverPointPositions: { Vector3 },
	vehicleModel: Model,
	currentVelocityY: number,
	hoverHeight: number,
	springStiffness: number,
	springDamping: number,
	gravity: number,
	_dt: number
): (number, Vector3, number)
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	local filter: { Instance } = { vehicleModel }
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		if character ~= nil then
			table.insert(filter, character)
		end
	end
	rayParams.FilterDescendantsInstances = filter
	rayParams.IgnoreWater = false

	local probeLift = math.max(1, hoverHeight * 0.5)
	local rayMaxDistance = hoverHeight * 3
	local rayLength = rayMaxDistance + probeLift
	local pointCount = math.max(#hoverPointPositions, 1)
	local totalForce = 0
	local normalSum = Vector3.zero
	local groundedCount = 0

	for _, origin in ipairs(hoverPointPositions) do
		local probeOrigin = origin + Vector3.new(0, probeLift, 0)
		local result = Workspace:Raycast(probeOrigin, Vector3.new(0, -rayLength, 0), rayParams)
		if result ~= nil then
			groundedCount += 1
			local correctedDistance = result.Distance - probeLift
			local compression = hoverHeight - correctedDistance
			local clampedCompression = math.clamp(compression, -hoverHeight * 0.5, hoverHeight * 1.8)
			local force = springStiffness * clampedCompression
			if clampedCompression > 0 then
				force -= springDamping * currentVelocityY
			elseif clampedCompression < 0 then
				force -= springDamping * 0.3 * currentVelocityY
			end
			force = math.max(force, -gravity * 0.5)
			totalForce += force
			normalSum += result.Normal
		end
		-- miss = 0 force contribution
	end

	local supportPointCount = pointCount
	local avgForce = totalForce / supportPointCount
	local verticalAccel = avgForce - gravity
	verticalAccel = math.clamp(verticalAccel, -gravity * 1.5, gravity * 1.15)

	local avgNormal = Vector3.yAxis
	if groundedCount > 0 and normalSum.Magnitude > 0.01 then
		avgNormal = normalSum.Unit
	end

	return verticalAccel, avgNormal, groundedCount
end

return HoverPhysics
