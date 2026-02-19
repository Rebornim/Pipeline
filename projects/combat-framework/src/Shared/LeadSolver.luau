--!strict

local LeadSolver = {}

local EPSILON = 1e-6

function LeadSolver.solveInterceptPoint(
	sourcePosition: Vector3,
	targetPosition: Vector3,
	targetVelocity: Vector3,
	projectileSpeed: number
): (Vector3?, number?)
	if projectileSpeed <= EPSILON then
		return nil, nil
	end

	local relative = targetPosition - sourcePosition
	local relativeDistanceSquared = relative:Dot(relative)
	if relativeDistanceSquared <= EPSILON then
		return targetPosition, 0
	end

	local speedSquared = projectileSpeed * projectileSpeed
	local velocitySquared = targetVelocity:Dot(targetVelocity)
	local relativeVelocityDot = relative:Dot(targetVelocity)

	local a = velocitySquared - speedSquared
	local b = 2 * relativeVelocityDot
	local c = relativeDistanceSquared

	local interceptTime: number? = nil
	if math.abs(a) < EPSILON then
		if math.abs(b) > EPSILON then
			local t = -c / b
			if t > 0 then
				interceptTime = t
			end
		end
	else
		local discriminant = b * b - 4 * a * c
		if discriminant >= 0 then
			local sqrtDiscriminant = math.sqrt(discriminant)
			local inv = 1 / (2 * a)
			local t1 = (-b - sqrtDiscriminant) * inv
			local t2 = (-b + sqrtDiscriminant) * inv
			if t1 > 0 and t2 > 0 then
				interceptTime = math.min(t1, t2)
			elseif t1 > 0 then
				interceptTime = t1
			elseif t2 > 0 then
				interceptTime = t2
			end
		end
	end

	if interceptTime == nil then
		interceptTime = math.sqrt(relativeDistanceSquared) / projectileSpeed
	end

	if interceptTime < 0 then
		interceptTime = 0
	end

	return targetPosition + targetVelocity * interceptTime, interceptTime
end

return LeadSolver
