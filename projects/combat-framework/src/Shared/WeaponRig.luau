--!strict

local WeaponRig = {}

local FORWARD_AXIS = Vector3.new(0, 0, -1)
local DEFAULT_PIVOT_ATTACHMENT_NAME = "AimPivot"
local DEFAULT_AIM_MODE = "yawpitch"
local DEFAULT_MIN_YAW_DEG = -180
local DEFAULT_MAX_YAW_DEG = 180
local DEFAULT_MIN_PITCH_DEG = -89
local DEFAULT_MAX_PITCH_DEG = 89

local AXIS_LOOKUP: { [string]: Vector3 } = {
	["x"] = Vector3.new(1, 0, 0),
	["+x"] = Vector3.new(1, 0, 0),
	["-x"] = Vector3.new(-1, 0, 0),
	["y"] = Vector3.new(0, 1, 0),
	["+y"] = Vector3.new(0, 1, 0),
	["-y"] = Vector3.new(0, -1, 0),
	["z"] = Vector3.new(0, 0, 1),
	["+z"] = Vector3.new(0, 0, 1),
	["-z"] = Vector3.new(0, 0, -1),
}

local AXIS_CANONICAL: { [string]: string } = {
	["x"] = "+X",
	["+x"] = "+X",
	["-x"] = "-X",
	["y"] = "+Y",
	["+y"] = "+Y",
	["-y"] = "-Y",
	["z"] = "+Z",
	["+z"] = "+Z",
	["-z"] = "-Z",
}

local AXIS_CANDIDATES = {
	{ label = "+X", vector = Vector3.new(1, 0, 0) },
	{ label = "-X", vector = Vector3.new(-1, 0, 0) },
	{ label = "+Y", vector = Vector3.new(0, 1, 0) },
	{ label = "-Y", vector = Vector3.new(0, -1, 0) },
	{ label = "+Z", vector = Vector3.new(0, 0, 1) },
	{ label = "-Z", vector = Vector3.new(0, 0, -1) },
}

local inferredAimAxisCache = setmetatable({}, { __mode = "k" }) :: { [BasePart]: { vector: Vector3?, label: string? } }

local function trim(raw: string): string
	return string.gsub(raw, "^%s*(.-)%s*$", "%1")
end

local function findAttachmentByName(root: Instance, attachmentName: string): Attachment?
	local matches: { Attachment } = {}
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("Attachment") and descendant.Name == attachmentName then
			table.insert(matches, descendant)
		end
	end

	table.sort(matches, function(a: Attachment, b: Attachment)
		return a:GetFullName() < b:GetFullName()
	end)

	return matches[1]
end

local function parseVector3String(raw: string): Vector3?
	local xRaw, yRaw, zRaw = string.match(raw, "^%s*([%+%-]?[%d%.]+)%s*,%s*([%+%-]?[%d%.]+)%s*,%s*([%+%-]?[%d%.]+)%s*$")
	if xRaw == nil or yRaw == nil or zRaw == nil then
		return nil
	end

	local x = tonumber(xRaw)
	local y = tonumber(yRaw)
	local z = tonumber(zRaw)
	if x == nil or y == nil or z == nil then
		return nil
	end

	return Vector3.new(x, y, z)
end

local function getMountOrModelAttribute(mount: BasePart, attributeName: string): any
	local fromMount = mount:GetAttribute(attributeName)
	if fromMount ~= nil then
		return fromMount
	end

	local model = mount:FindFirstAncestorOfClass("Model")
	if model ~= nil then
		local fromModel = model:GetAttribute(attributeName)
		if fromModel ~= nil then
			return fromModel
		end

		local rigFolder = model:FindFirstChild("TurretRig")
		if rigFolder ~= nil then
			local fromRigFolder = rigFolder:GetAttribute(attributeName)
			if fromRigFolder ~= nil then
				return fromRigFolder
			end
		end
	end

	return nil
end

local function getMountOrModelNumber(mount: BasePart, attributeName: string): number?
	local raw = getMountOrModelAttribute(mount, attributeName)
	if type(raw) == "number" then
		return raw
	end
	if type(raw) == "string" then
		return tonumber(raw)
	end
	return nil
end

local function rotationFromTo(fromDirection: Vector3, toDirection: Vector3): CFrame
	if fromDirection.Magnitude < 1e-4 or toDirection.Magnitude < 1e-4 then
		return CFrame.new()
	end

	local fromUnit = fromDirection.Unit
	local toUnit = toDirection.Unit
	local dot = math.clamp(fromUnit:Dot(toUnit), -1, 1)

	if dot > 0.9999 then
		return CFrame.new()
	end

	if dot < -0.9999 then
		-- Opposite vectors have infinite valid 180-degree axes.
		-- Prefer a stable world axis to avoid unexpected roll/up inversion.
		local preferredAxes = {
			Vector3.new(0, 1, 0),
			Vector3.new(1, 0, 0),
			Vector3.new(0, 0, 1),
		}
		for _, axis in ipairs(preferredAxes) do
			if math.abs(fromUnit:Dot(axis)) < 0.999 then
				return CFrame.fromAxisAngle(axis, math.pi)
			end
		end
		return CFrame.new()
	end

	local axis = fromUnit:Cross(toUnit)
	if axis.Magnitude < 1e-4 then
		return CFrame.new()
	end

	return CFrame.fromAxisAngle(axis.Unit, math.acos(dot))
end

local function isMuzzleAttachment(candidate: Instance): boolean
	if not candidate:IsA("Attachment") then
		return false
	end

	if candidate.Name == "MuzzlePoint" or string.sub(candidate.Name, 1, 11) == "MuzzlePoint" then
		return true
	end

	return false
end

local function findPrimaryMuzzleAttachment(mount: BasePart): Attachment?
	local attachments: { Attachment } = {}
	for _, descendant in ipairs(mount:GetDescendants()) do
		if isMuzzleAttachment(descendant) then
			table.insert(attachments, descendant :: Attachment)
		end
	end

	table.sort(attachments, function(a: Attachment, b: Attachment)
		return a:GetFullName() < b:GetFullName()
	end)

	return attachments[1]
end

local function inferAimAxisFromMuzzle(mount: BasePart): (Vector3?, string?)
	local cached = inferredAimAxisCache[mount]
	if cached ~= nil then
		return cached.vector, cached.label
	end

	local muzzle = findPrimaryMuzzleAttachment(mount)
	if muzzle == nil then
		inferredAimAxisCache[mount] = { vector = nil, label = nil }
		return nil, nil
	end

	-- Attachment authoring direction is its Axis (X), not CFrame.LookVector (-Z).
	local muzzleForward = muzzle.WorldAxis
	if muzzleForward.Magnitude < 1e-4 then
		muzzleForward = muzzle.WorldCFrame.LookVector
	end
	local localLook = mount.CFrame:VectorToObjectSpace(muzzleForward)
	if localLook.Magnitude < 1e-4 then
		inferredAimAxisCache[mount] = { vector = nil, label = nil }
		return nil, nil
	end

	local unitLook = localLook.Unit
	local bestVector: Vector3? = nil
	local bestLabel: string? = nil
	local bestDot = -math.huge
	for _, candidate in ipairs(AXIS_CANDIDATES) do
		local dot = unitLook:Dot(candidate.vector)
		if dot > bestDot then
			bestDot = dot
			bestVector = candidate.vector
			bestLabel = candidate.label
		end
	end

	inferredAimAxisCache[mount] = {
		vector = bestVector,
		label = bestLabel,
	}
	return bestVector, bestLabel
end

local function resolveAimAxisInternal(mount: BasePart): (Vector3?, string?)
	local rawAxis = getMountOrModelAttribute(mount, "AimAxis")
	if type(rawAxis) == "string" then
		local normalized = string.lower(trim(rawAxis))
		local vector = AXIS_LOOKUP[normalized]
		if vector ~= nil then
			return vector, AXIS_CANONICAL[normalized] or string.upper(normalized)
		end
	end

	local inferredVector, inferredLabel = inferAimAxisFromMuzzle(mount)
	if inferredVector ~= nil then
		return inferredVector, inferredLabel
	end

	return nil, nil
end

local function getAimAxis(mount: BasePart): Vector3?
	local axis, _axisLabel = resolveAimAxisInternal(mount)
	return axis
end

local function getAngleOffset(mount: BasePart): CFrame
	local rawOffset = getMountOrModelAttribute(mount, "AimOffsetDegrees")
	local angleDegrees: Vector3? = nil

	if typeof(rawOffset) == "Vector3" then
		angleDegrees = rawOffset :: Vector3
	elseif type(rawOffset) == "string" then
		angleDegrees = parseVector3String(rawOffset)
	end

	if angleDegrees == nil then
		return CFrame.new()
	end

	return CFrame.fromOrientation(math.rad(angleDegrees.X), math.rad(angleDegrees.Y), math.rad(angleDegrees.Z))
end

local function getMountAimOffset(mount: BasePart): CFrame
	local axis = getAimAxis(mount)
	local axisOffset = if axis ~= nil then rotationFromTo(axis, FORWARD_AXIS) else CFrame.new()
	return axisOffset * getAngleOffset(mount)
end

local function getLogicalAimFrameFromMount(mount: BasePart): CFrame
	return mount.CFrame * getMountAimOffset(mount):Inverse()
end

local function directionToYawPitch(direction: Vector3): (number, number)
	local unitDirection = direction.Unit
	local yaw = math.atan2(-unitDirection.X, -unitDirection.Z)
	local pitch = math.asin(math.clamp(unitDirection.Y, -1, 1))
	return yaw, pitch
end

local function yawPitchToDirection(yaw: number, pitch: number): Vector3
	local cosPitch = math.cos(pitch)
	return Vector3.new(-math.sin(yaw) * cosPitch, math.sin(pitch), -math.cos(yaw) * cosPitch).Unit
end

local function getAimMode(mount: BasePart): string
	local raw = getMountOrModelAttribute(mount, "AimMode")
	if type(raw) ~= "string" then
		return DEFAULT_AIM_MODE
	end
	local normalized = string.lower(trim(raw))
	normalized = string.gsub(normalized, "[%s_%-]", "")
	return normalized
end

local function getAimLimitsRadians(
	mount: BasePart,
	minYawDegOverride: number?,
	maxYawDegOverride: number?,
	minPitchDegOverride: number?,
	maxPitchDegOverride: number?
): (number, number, number, number)
	local minYawDeg = minYawDegOverride
	if minYawDeg == nil then
		minYawDeg = getMountOrModelNumber(mount, "MinYawDeg")
	end
	if minYawDeg == nil then
		minYawDeg = DEFAULT_MIN_YAW_DEG
	end

	local maxYawDeg = maxYawDegOverride
	if maxYawDeg == nil then
		maxYawDeg = getMountOrModelNumber(mount, "MaxYawDeg")
	end
	if maxYawDeg == nil then
		maxYawDeg = DEFAULT_MAX_YAW_DEG
	end

	local minPitchDeg = minPitchDegOverride
	if minPitchDeg == nil then
		minPitchDeg = getMountOrModelNumber(mount, "MinPitchDeg")
	end
	if minPitchDeg == nil then
		minPitchDeg = DEFAULT_MIN_PITCH_DEG
	end

	local maxPitchDeg = maxPitchDegOverride
	if maxPitchDeg == nil then
		maxPitchDeg = getMountOrModelNumber(mount, "MaxPitchDeg")
	end
	if maxPitchDeg == nil then
		maxPitchDeg = DEFAULT_MAX_PITCH_DEG
	end

	if minYawDeg > maxYawDeg then
		minYawDeg, maxYawDeg = maxYawDeg, minYawDeg
	end
	if minPitchDeg > maxPitchDeg then
		minPitchDeg, maxPitchDeg = maxPitchDeg, minPitchDeg
	end

	return math.rad(minYawDeg), math.rad(maxYawDeg), math.rad(minPitchDeg), math.rad(maxPitchDeg)
end

type ClampOverrides = {
	mode: string?,
	minYawDeg: number?,
	maxYawDeg: number?,
	minPitchDeg: number?,
	maxPitchDeg: number?,
	pivotName: string?,
	pivotAttachment: Attachment?,
}

local function getPivotAttachment(mount: BasePart): Attachment?
	local nameOverride = getMountOrModelAttribute(mount, "AimPivotName")
	local pivotName = if type(nameOverride) == "string" and trim(nameOverride) ~= ""
		then trim(nameOverride)
		else DEFAULT_PIVOT_ATTACHMENT_NAME

	local attachment = findAttachmentByName(mount, pivotName)
	if attachment ~= nil then
		return attachment
	end

	local model = mount:FindFirstAncestorOfClass("Model")
	if model ~= nil then
		return findAttachmentByName(model, pivotName)
	end

	return nil
end

local function getPivotAttachmentWithOverrides(mount: BasePart, overrides: ClampOverrides?): Attachment?
	if overrides ~= nil then
		if overrides.pivotAttachment ~= nil and overrides.pivotAttachment.Parent ~= nil then
			return overrides.pivotAttachment
		end

		if overrides.pivotName ~= nil then
			local overridePivotName = trim(overrides.pivotName)
			if overridePivotName ~= "" then
				local attachment = findAttachmentByName(mount, overridePivotName)
				if attachment ~= nil then
					return attachment
				end

				local model = mount:FindFirstAncestorOfClass("Model")
				if model ~= nil then
					local modelAttachment = findAttachmentByName(model, overridePivotName)
					if modelAttachment ~= nil then
						return modelAttachment
					end
				end
			end
		end
	end

	return getPivotAttachment(mount)
end

local function getPivotWorldPosition(mount: BasePart, overrides: ClampOverrides?): Vector3
	local pivotAttachment = getPivotAttachmentWithOverrides(mount, overrides)
	if pivotAttachment ~= nil then
		return pivotAttachment.WorldPosition
	end
	return mount.Position
end

local function getPivotLocalOffset(mount: BasePart, overrides: ClampOverrides?): Vector3
	local pivotWorld = getPivotWorldPosition(mount, overrides)
	return mount.CFrame:PointToObjectSpace(pivotWorld)
end

function WeaponRig.getMountAimOffset(mount: BasePart): CFrame
	return getMountAimOffset(mount)
end

function WeaponRig.getAimPivotWorldPosition(mount: BasePart, overrides: ClampOverrides?): Vector3
	return getPivotWorldPosition(mount, overrides)
end

function WeaponRig.resolveAimAxis(mount: BasePart): (Vector3?, string?)
	return resolveAimAxisInternal(mount)
end

function WeaponRig.getCurrentAimDirection(mount: BasePart): Vector3
	return getLogicalAimFrameFromMount(mount).LookVector
end

function WeaponRig.getNeutralAimFrame(mount: BasePart): CFrame
	return getLogicalAimFrameFromMount(mount)
end

function WeaponRig.clampDirectionToMountLimits(
	mount: BasePart,
	neutralAimFrame: CFrame,
	direction: Vector3,
	overrides: ClampOverrides?
): Vector3
	if direction.Magnitude < 1e-4 then
		return direction
	end

	local localDirection = neutralAimFrame:VectorToObjectSpace(direction.Unit)
	local yaw, pitch = directionToYawPitch(localDirection)
	local mode = getAimMode(mount)
	local minYawDegOverride: number? = nil
	local maxYawDegOverride: number? = nil
	local minPitchDegOverride: number? = nil
	local maxPitchDegOverride: number? = nil
	if overrides ~= nil then
		if overrides.mode ~= nil then
			mode = string.lower(trim(overrides.mode))
		end
		mode = string.gsub(mode, "[%s_%-]", "")
		minYawDegOverride = overrides.minYawDeg
		maxYawDegOverride = overrides.maxYawDeg
		minPitchDegOverride = overrides.minPitchDeg
		maxPitchDegOverride = overrides.maxPitchDeg
	end
	local minYaw, maxYaw, minPitch, maxPitch =
		getAimLimitsRadians(mount, minYawDegOverride, maxYawDegOverride, minPitchDegOverride, maxPitchDegOverride)

	if mode == "yawonly" then
		pitch = 0
	elseif mode == "pitchonly" then
		-- Pitch-only parts should still inherit turret yaw.
		-- Keep yaw unconstrained and only apply pitch constraints.
		minYaw = -math.pi
		maxYaw = math.pi
	end

	-- Handle yaw wrap-around when limits exceed ±180°
	local yawRange = maxYaw - minYaw
	if yawRange < 2 * math.pi then
		local midYaw = (minYaw + maxYaw) / 2
		local offset = yaw - midYaw
		yaw = midYaw + math.atan2(math.sin(offset), math.cos(offset))
		yaw = math.clamp(yaw, minYaw, maxYaw)
	end
	pitch = math.clamp(pitch, minPitch, maxPitch)

	local clampedLocalDirection = yawPitchToDirection(yaw, pitch)
	return neutralAimFrame:VectorToWorldSpace(clampedLocalDirection).Unit
end

function WeaponRig.getAimFrame(mount: BasePart, direction: Vector3, overrides: ClampOverrides?): CFrame
	if direction.Magnitude < 1e-4 then
		return mount.CFrame
	end

	local logicalAimFrame = CFrame.lookAt(Vector3.zero, direction.Unit)
	local mountAimFrame = logicalAimFrame * getMountAimOffset(mount)
	local orientationOnly = CFrame.fromMatrix(Vector3.zero, mountAimFrame.XVector, mountAimFrame.YVector, mountAimFrame.ZVector)

	local pivotWorld = getPivotWorldPosition(mount, overrides)
	local pivotLocal = getPivotLocalOffset(mount, overrides)
	return CFrame.new(pivotWorld) * orientationOnly * CFrame.new(-pivotLocal)
end

return WeaponRig
