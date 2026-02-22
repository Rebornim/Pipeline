--!strict

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

-- Optional global kill switch:
--   workspace:SetAttribute("MovingTargetControllerEnabled", false)
local didWarnControllerDisabled = false
local function isControllerEnabled(): boolean
	local enabled = Workspace:GetAttribute("MovingTargetControllerEnabled")
	if enabled == nil then
		Workspace:SetAttribute("MovingTargetControllerEnabled", true)
		enabled = true
	end

	if enabled == false then
		if not didWarnControllerDisabled then
			warn("[P4_MOVE] MovingTargetController disabled via workspace.MovingTargetControllerEnabled=false")
			didWarnControllerDisabled = true
		end
		return false
	end

	didWarnControllerDisabled = false
	return true
end

type TargetState = {
	baseCFrame: CFrame,
	lastRandomSwap: number,
	lastUpdateTime: number,
	currentOffset: Vector3,
	randomDirection: Vector3,
	travelSign: number,
	orbitAngle: number,
	activeMode: string,
}

local MODE_ATTR = "MovingTargetMode"
local ENABLED_ATTR = "MovingTargetEnabled"
local RESET_ATTR = "MovingTargetReset"
local SPEED_ATTR = "MovingTargetSpeed"
local AMPLITUDE_ATTR = "MovingTargetAmplitude"
local RADIUS_ATTR = "MovingTargetRadius"
local HEIGHT_ATTR = "MovingTargetHeight"
local INTERVAL_ATTR = "MovingTargetInterval"
local AXIS_ATTR = "MovingTargetAxis"

local MODE_SIDE = "side"
local MODE_CIRCLE = "circle"
local MODE_RANDOM = "random"

local DEFAULT_SPEED = 25
local DEFAULT_AMPLITUDE = 16
local DEFAULT_RADIUS = 18
local DEFAULT_HEIGHT = 10
local DEFAULT_INTERVAL = 2.2

local statesByModel: { [Model]: TargetState } = {}
local warnedInvalidModeByModel: { [Model]: boolean } = {}
local rng = Random.new()

local function readNumberAttribute(instance: Instance, name: string, defaultValue: number): number
	local raw = instance:GetAttribute(name)
	if type(raw) == "number" then
		return raw
	end
	if type(raw) == "string" then
		local parsed = tonumber(raw)
		if parsed ~= nil then
			return parsed
		end
	end
	return defaultValue
end

local function normalizeMode(raw: any): string
	if type(raw) ~= "string" then
		return MODE_SIDE
	end
	local normalized = string.lower(string.match(raw, "^%s*(.-)%s*$") or "")
	if normalized == MODE_SIDE or normalized == MODE_CIRCLE or normalized == MODE_RANDOM then
		return normalized
	end
	return ""
end

local function parseAxis(raw: any): Vector3
	if type(raw) ~= "string" then
		return Vector3.new(1, 0, 0)
	end

	local normalized = string.upper(string.match(raw, "^%s*(.-)%s*$") or "")
	if normalized == "X" then
		return Vector3.new(1, 0, 0)
	end
	if normalized == "Y" then
		return Vector3.new(0, 1, 0)
	end
	if normalized == "Z" then
		return Vector3.new(0, 0, 1)
	end
	if normalized == "-X" then
		return Vector3.new(-1, 0, 0)
	end
	if normalized == "-Y" then
		return Vector3.new(0, -1, 0)
	end
	if normalized == "-Z" then
		return Vector3.new(0, 0, -1)
	end

	local xRaw, yRaw, zRaw =
		string.match(normalized, "^([%+%-]?[%d%.]+)%s*,%s*([%+%-]?[%d%.]+)%s*,%s*([%+%-]?[%d%.]+)$")
	if xRaw ~= nil and yRaw ~= nil and zRaw ~= nil then
		local x = tonumber(xRaw)
		local y = tonumber(yRaw)
		local z = tonumber(zRaw)
		if x ~= nil and y ~= nil and z ~= nil then
			local vec = Vector3.new(x, y, z)
			if vec.Magnitude > 1e-4 then
				return vec.Unit
			end
		end
	end

	return Vector3.new(1, 0, 0)
end

local function randomUnitDirection2D(): Vector3
	for _ = 1, 8 do
		local x = rng:NextNumber(-1, 1)
		local z = rng:NextNumber(-1, 1)
		local flat = Vector2.new(x, z)
		if flat.Magnitude > 1e-4 then
			local unit = flat.Unit
			local y = rng:NextNumber(-0.3, 0.3)
			return Vector3.new(unit.X, y, unit.Y).Unit
		end
	end
	return Vector3.new(1, 0, 0)
end

local function ensureAttributes(model: Model)
	if model:GetAttribute(MODE_ATTR) == nil then
		model:SetAttribute(MODE_ATTR, MODE_SIDE)
	end
	if model:GetAttribute(SPEED_ATTR) == nil then
		model:SetAttribute(SPEED_ATTR, DEFAULT_SPEED)
	end
	if model:GetAttribute(AMPLITUDE_ATTR) == nil then
		model:SetAttribute(AMPLITUDE_ATTR, DEFAULT_AMPLITUDE)
	end
	if model:GetAttribute(RADIUS_ATTR) == nil then
		model:SetAttribute(RADIUS_ATTR, DEFAULT_RADIUS)
	end
	if model:GetAttribute(HEIGHT_ATTR) == nil then
		model:SetAttribute(HEIGHT_ATTR, DEFAULT_HEIGHT)
	end
	if model:GetAttribute(INTERVAL_ATTR) == nil then
		model:SetAttribute(INTERVAL_ATTR, DEFAULT_INTERVAL)
	end
	if model:GetAttribute(AXIS_ATTR) == nil then
		model:SetAttribute(AXIS_ATTR, "X")
	end
end

local attributesInitialized: { [Model]: boolean } = {}

local function getOrCreateState(model: Model, now: number): TargetState
	if not attributesInitialized[model] then
		ensureAttributes(model)
		attributesInitialized[model] = true
		print(string.format(
			"[P4_MOVE] Initialized %s: mode=%s speed=%.1f radius=%.0f",
			model.Name,
			tostring(model:GetAttribute(MODE_ATTR)),
			readNumberAttribute(model, SPEED_ATTR, DEFAULT_SPEED),
			readNumberAttribute(model, RADIUS_ATTR, DEFAULT_RADIUS)
		))
	end

	local state = statesByModel[model]
	if state ~= nil then
		return state
	end

	state = {
		baseCFrame = model:GetPivot(),
		lastRandomSwap = now,
		lastUpdateTime = now,
		currentOffset = Vector3.zero,
		randomDirection = randomUnitDirection2D(),
		travelSign = if rng:NextNumber() >= 0.5 then 1 else -1,
		orbitAngle = rng:NextNumber(0, math.pi * 2),
		activeMode = "",
	}
	statesByModel[model] = state
	return state
end

local function resetState(model: Model, now: number)
	statesByModel[model] = {
		baseCFrame = model:GetPivot(),
		lastRandomSwap = now,
		lastUpdateTime = now,
		currentOffset = Vector3.zero,
		randomDirection = randomUnitDirection2D(),
		travelSign = if rng:NextNumber() >= 0.5 then 1 else -1,
		orbitAngle = rng:NextNumber(0, math.pi * 2),
		activeMode = "",
	}
	model:SetAttribute(RESET_ATTR, nil)
end

local function stepIntervalSwaps(state: TargetState, now: number, interval: number, onSwap: () -> ())
	local elapsed = now - state.lastRandomSwap
	if elapsed < interval then
		return
	end

	local swaps = math.floor(elapsed / interval)
	if swaps <= 0 then
		return
	end

	state.lastRandomSwap += swaps * interval
	for _ = 1, swaps do
		onSwap()
	end
end

local function getMotionOffset(model: Model, state: TargetState, now: number): Vector3?
	local mode = normalizeMode(model:GetAttribute(MODE_ATTR))
	if mode == "" then
		if not warnedInvalidModeByModel[model] then
			warn(string.format("[P4_MOVE] Invalid %s on %s", MODE_ATTR, model:GetFullName()))
			warnedInvalidModeByModel[model] = true
		end
		return nil
	end

	-- Interval is the time in seconds between direction changes for all modes.
	local interval = math.max(0.2, readNumberAttribute(model, INTERVAL_ATTR, DEFAULT_INTERVAL))
	if state.activeMode ~= mode then
		state.activeMode = mode
		state.lastRandomSwap = now
		state.lastUpdateTime = now
		state.currentOffset = Vector3.zero
		state.randomDirection = randomUnitDirection2D()
		if mode == MODE_CIRCLE then
			state.orbitAngle = rng:NextNumber(0, math.pi * 2)
		end
	end

	local speed = math.max(0, readNumberAttribute(model, SPEED_ATTR, DEFAULT_SPEED))
	local dt = math.max(0, now - state.lastUpdateTime)
	state.lastUpdateTime = now

	if mode == MODE_SIDE then
		local axis = parseAxis(model:GetAttribute(AXIS_ATTR))
		stepIntervalSwaps(state, now, interval, function()
			state.travelSign *= -1
		end)

		if speed <= 0 or dt <= 0 then
			return state.currentOffset
		end

		state.currentOffset += axis * (state.travelSign * speed * dt)
		return state.currentOffset
	end

	if mode == MODE_CIRCLE then
		local radius = math.max(0, readNumberAttribute(model, RADIUS_ATTR, DEFAULT_RADIUS))
		local height = math.max(0, readNumberAttribute(model, HEIGHT_ATTR, DEFAULT_HEIGHT * 0.35))
		stepIntervalSwaps(state, now, interval, function()
			state.travelSign *= -1
		end)

		if speed <= 0 or dt <= 0 then
			return state.currentOffset
		end

		local flat = Vector2.new(state.currentOffset.X, state.currentOffset.Z)
		if flat.Magnitude < 1e-4 then
			flat = Vector2.new(if radius > 0 then radius else 1, 0)
		end

		local radial = flat.Unit
		local tangent = Vector2.new(-radial.Y, radial.X) * state.travelSign
		local nextFlat = flat + tangent * (speed * dt)
		if radius > 0 and nextFlat.Magnitude > 1e-4 then
			nextFlat = nextFlat.Unit * radius
		end

		local y = 0
		if height > 0 then
			state.orbitAngle += state.travelSign * speed * dt / math.max(radius, 1)
			y = math.sin(state.orbitAngle * 0.8) * height
		end

		state.currentOffset = Vector3.new(nextFlat.X, y, nextFlat.Y)
		return state.currentOffset
	end

	-- Random mode: identical to side mode but on a random axis.
	-- At each interval: flips travel direction AND picks a new random axis.
	stepIntervalSwaps(state, now, interval, function()
		state.randomDirection = randomUnitDirection2D()
		state.travelSign *= -1
	end)

	if speed <= 0 or dt <= 0 then
		return state.currentOffset
	end

	state.currentOffset += state.randomDirection * (state.travelSign * speed * dt)
	return state.currentOffset
end

local function applyMotion(model: Model, state: TargetState, offset: Vector3)
	local base = state.baseCFrame
	local baseRotation = base.Rotation
	local targetPosition = base.Position + offset
	model:PivotTo(CFrame.new(targetPosition) * baseRotation)
end

RunService.Heartbeat:Connect(function()
	if not isControllerEnabled() then
		table.clear(statesByModel)
		table.clear(warnedInvalidModeByModel)
		return
	end

	local now = tick()

	for _, tagged in ipairs(CollectionService:GetTagged("CombatEntity")) do
		if tagged:IsA("Model") then
			local model = tagged :: Model
			if model.Parent == nil then
				continue
			end
			if model:GetAttribute(ENABLED_ATTR) ~= true then
				continue
			end
			if model:GetAttribute("HullHP") ~= nil and model:GetAttribute("HullHP") == 0 then
				continue
			end

			if model:GetAttribute(RESET_ATTR) == true then
				resetState(model, now)
			end

			local state = getOrCreateState(model, now)
			local offset = getMotionOffset(model, state, now)
			if offset ~= nil then
				applyMotion(model, state, offset)
			end
		end
	end

	for model, _state in pairs(statesByModel) do
		if model.Parent == nil or model:GetAttribute(ENABLED_ATTR) ~= true then
			statesByModel[model] = nil
			warnedInvalidModeByModel[model] = nil
			attributesInitialized[model] = nil
		end
	end
end)

print("[P4_MOVE] MovingTargetController enabled")
