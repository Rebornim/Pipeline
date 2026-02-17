local PathSmoother = {}

local function quadraticBezier(p0: Vector3, p1: Vector3, p2: Vector3, t: number): Vector3
	local oneMinusT = 1 - t
	return (oneMinusT * oneMinusT) * p0 + (2 * oneMinusT * t) * p1 + (t * t) * p2
end

local function computeAdaptiveCornerSettings(
	baseRadius: number,
	baseSegments: number,
	inDir: Vector3,
	outDir: Vector3,
	inMag: number,
	outMag: number
): (number, number)
	local availableRadius = math.min(inMag * 0.5, outMag * 0.5)
	if availableRadius <= 0.001 then
		return 0, baseSegments
	end

	local dot = math.clamp(inDir:Dot(outDir), -1, 1)
	local sharpness = (1 - dot) * 0.5

	local scaledRadius = baseRadius * (0.85 + sharpness * 1.65)
	local adaptiveRadius = math.min(availableRadius, scaledRadius)

	if sharpness >= 0.6 then
		local blend = (sharpness - 0.6) / 0.4
		local minRatio = 0.55 + math.clamp(blend, 0, 1) * 0.25
		local minRadius = availableRadius * minRatio
		if adaptiveRadius < minRadius then
			adaptiveRadius = minRadius
		end
	end

	local maxSegments = math.max(baseSegments, baseSegments * 3)
	local adaptiveSegments = math.floor(baseSegments + sharpness * baseSegments * 2 + 0.5)
	adaptiveSegments = math.clamp(adaptiveSegments, baseSegments, maxSegments)

	return adaptiveRadius, adaptiveSegments
end

function PathSmoother.bevel(
	waypoints: { Vector3 },
	poiStops: { { waypointIndex: number, [string]: any } }?,
	bevelRadius: number,
	bevelSegments: number
): ({ Vector3 }, { { waypointIndex: number, [string]: any } }?)
	local waypointCount = #waypoints
	if waypointCount <= 2 then
		return waypoints, poiStops
	end

	local radius = math.max(0, bevelRadius or 0)
	local segments = math.max(2, math.floor(bevelSegments or 2))

	local protectedIndices = {
		[1] = true,
		[waypointCount] = true,
	}
	if poiStops then
		for _, stop in ipairs(poiStops) do
			local idx = stop.waypointIndex
			if stop.type ~= "busy" and type(idx) == "number" and idx >= 1 and idx <= waypointCount then
				protectedIndices[idx] = true
			end
		end
	end

	local smoothed = {}
	local indexMap = {}

	indexMap[1] = 1
	table.insert(smoothed, waypoints[1])

	for i = 2, waypointCount - 1 do
		local prev = waypoints[i - 1]
		local current = waypoints[i]
		local nextPos = waypoints[i + 1]
		local inVec = current - prev
		local outVec = nextPos - current
		local inMag = inVec.Magnitude
		local outMag = outVec.Magnitude

		if inMag <= 0.001 or outMag <= 0.001 then
			indexMap[i] = #smoothed + 1
			table.insert(smoothed, current)
		else
			local inDir = inVec / inMag
			local outDir = outVec / outMag
			local clampedRadius, cornerSegments = computeAdaptiveCornerSettings(
				radius,
				segments,
				inDir,
				outDir,
				inMag,
				outMag
			)
			if clampedRadius <= 0.001 then
				indexMap[i] = #smoothed + 1
				table.insert(smoothed, current)
			else
				local approach = current - inDir * clampedRadius
				local depart = current + outDir * clampedRadius

				if protectedIndices[i] then
					local entryControl = (approach + current) * 0.5
					for s = 0, cornerSegments do
						local t = s / cornerSegments
						table.insert(smoothed, quadraticBezier(approach, entryControl, current, t))
					end
					indexMap[i] = #smoothed

					local exitControl = (current + depart) * 0.5
					for s = 1, cornerSegments do
						local t = s / cornerSegments
						table.insert(smoothed, quadraticBezier(current, exitControl, depart, t))
					end
				else
					indexMap[i] = #smoothed + 1 + math.floor(cornerSegments / 2)
					for s = 0, cornerSegments do
						local t = s / cornerSegments
						table.insert(smoothed, quadraticBezier(approach, current, depart, t))
					end
				end
			end
		end
	end

	indexMap[waypointCount] = #smoothed + 1
	table.insert(smoothed, waypoints[waypointCount])

	local updatedPoiStops = nil
	if poiStops then
		updatedPoiStops = {}
		for _, stop in ipairs(poiStops) do
			local copied = table.clone(stop)
			local mappedIndex = indexMap[copied.waypointIndex]
			if mappedIndex then
				copied.waypointIndex = mappedIndex
			end
			table.insert(updatedPoiStops, copied)
		end
	end

	return smoothed, updatedPoiStops
end

return PathSmoother
