--!strict

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local configModule = ReplicatedStorage:WaitForChild("Config", 10)
assert(configModule and configModule:IsA("ModuleScript"), "WanderingProps NPCMover: ReplicatedStorage.Config not found")

local typesModule = ReplicatedStorage:WaitForChild("Types", 10)
assert(typesModule and typesModule:IsA("ModuleScript"), "WanderingProps NPCMover: ReplicatedStorage.Types not found")

local Config = require(configModule)
local Types = require(typesModule)
type ClientNPC = Types.ClientNPC
type RouteStep = Types.RouteStep
type LODTier = Types.LODTier

type StepChangedCallback = (npc: ClientNPC, step: RouteStep) -> ()
type RouteCompleteCallback = (npc: ClientNPC) -> ()

type ActiveRouteState = {
	npc: ClientNPC,
	onStepChanged: StepChangedCallback,
	onRouteComplete: RouteCompleteCallback,
}

local NPCMover = {}

local EPSILON = 0.0001
local activeRoutes: { [string]: ActiveRouteState } = {}
local groundOffsetByNpcId: { [string]: number } = {}
local laneOffsetByNpcId: { [string]: number } = {}

local GROUND_IGNORE_TAGS = {
	Config.TAG_WAYPOINT,
	Config.TAG_SPAWN,
	Config.TAG_DESPAWN,
	Config.TAG_SCENIC,
	Config.TAG_BUSY,
	Config.TAG_SOCIAL,
	Config.TAG_SEAT,
}

local function getWalkSpeedScale(npc: ClientNPC): number
	local natural = tonumber(Config.WALK_ANIMATION_NATURAL_SPEED) or 1
	if natural <= 0 then
		natural = 1
	end
	return npc.speed / natural
end

local function stopAllTracks(npc: ClientNPC): ()
	if npc.walkTrack and npc.walkTrack.IsPlaying then
		npc.walkTrack:Stop(0)
	end
	if npc.idleTrack and npc.idleTrack.IsPlaying then
		npc.idleTrack:Stop(0)
	end
	if npc.sitTrack and npc.sitTrack.IsPlaying then
		npc.sitTrack:Stop(0)
	end
end

local function unfreezeTracks(npc: ClientNPC): ()
	local animator = npc.animator
	if not animator then
		return
	end

	local walkScale = getWalkSpeedScale(npc)
	for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
		if npc.walkTrack and track == npc.walkTrack then
			track:AdjustSpeed(walkScale)
		else
			track:AdjustSpeed(1)
		end
	end
end

local function getCurrentStep(npc: ClientNPC): RouteStep?
	return npc.route[npc.currentStepIndex]
end

local function getLaneOffsetMax(): number
	local raw = tonumber(Config.PATH_LANE_OFFSET_MAX)
	if raw == nil then
		return 0
	end
	return math.max(0, raw)
end

local function ensureLaneOffset(npc: ClientNPC): number
	local cached = laneOffsetByNpcId[npc.id]
	if cached ~= nil then
		return cached
	end

	local maxOffset = getLaneOffsetMax()
	local offset = if maxOffset > 0 then (math.random() * 2 - 1) * maxOffset else 0
	laneOffsetByNpcId[npc.id] = offset
	return offset
end

local function estimateGroundOffset(model: Model): number
	local overrideOffset = model:GetAttribute("WP_GroundOffset")
	if typeof(overrideOffset) == "number" and overrideOffset >= 0 then
		return overrideOffset
	end

	local okPivot, pivot = pcall(function()
		return model:GetPivot()
	end)

	if okPivot then
		local minBottomY: number? = nil
		for _, descendant in ipairs(model:GetDescendants()) do
			if not descendant:IsA("BasePart") then
				continue
			end
			if descendant:FindFirstAncestorOfClass("Accessory") then
				continue
			end

			local halfExtentY = math.abs(descendant.CFrame.XVector.Y) * descendant.Size.X * 0.5
				+ math.abs(descendant.CFrame.YVector.Y) * descendant.Size.Y * 0.5
				+ math.abs(descendant.CFrame.ZVector.Y) * descendant.Size.Z * 0.5
			local bottomY = descendant.Position.Y - halfExtentY
			if minBottomY == nil or bottomY < minBottomY then
				minBottomY = bottomY
			end
		end

		if minBottomY ~= nil then
			local offset = pivot.Position.Y - minBottomY
			return math.clamp(offset, 0.05, 8)
		end
	end

	local okPivot, pivot = pcall(function()
		return model:GetPivot()
	end)
	local okBounds, boundsCFrame, boundsSize = pcall(function()
		return model:GetBoundingBox()
	end)

	if okPivot and okBounds then
		local pivotY = pivot.Position.Y
		local bottomY = boundsCFrame.Position.Y - boundsSize.Y * 0.5
		local offset = pivotY - bottomY
		if offset > EPSILON then
			return offset
		end
	end

	if model.PrimaryPart then
		return math.max(1, model.PrimaryPart.Size.Y * 0.5)
	end

	return 2
end

local function getGroundOffset(npc: ClientNPC): number
	local cached = groundOffsetByNpcId[npc.id]
	if cached ~= nil then
		return cached
	end

	local model = npc.model
	local offset = if model then estimateGroundOffset(model) else 2
	groundOffsetByNpcId[npc.id] = offset
	return offset
end

local function isNavigationMarkerPart(part: BasePart): boolean
	for _, tag in ipairs(GROUND_IGNORE_TAGS) do
		if CollectionService:HasTag(part, tag) then
			return true
		end
	end
	return false
end

local function isPooledNpcPart(part: BasePart): boolean
	local model = part:FindFirstAncestorOfClass("Model")
	if not model then
		return false
	end

	return model:GetAttribute("WP_ModelIndex") ~= nil
end

local function shouldIgnoreGroundHit(hitPart: BasePart): boolean
	if isNavigationMarkerPart(hitPart) or isPooledNpcPart(hitPart) then
		return true
	end

	local model = hitPart:FindFirstAncestorOfClass("Model")
	if model and Players:GetPlayerFromCharacter(model) ~= nil then
		return true
	end

	return false
end

local function cubicBezier(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, alpha: number): Vector3
	local inv = 1 - alpha
	return p0 * (inv * inv * inv)
		+ p1 * (3 * inv * inv * alpha)
		+ p2 * (3 * inv * alpha * alpha)
		+ p3 * (alpha * alpha * alpha)
end

local function getSmoothingSamples(): number
	local raw = tonumber(Config.PATH_SMOOTHING_SAMPLES)
	if raw == nil then
		return 12
	end
	return math.max(4, math.floor(raw))
end

local function getWalkTangentAtStep(npc: ClientNPC, stepIndex: number): Vector3?
	local step = npc.route[stepIndex]
	if not step or step.action ~= "walk" then
		return nil
	end

	local previousStep = npc.route[stepIndex - 1]
	local nextStep = npc.route[stepIndex + 1]

	if previousStep and nextStep and previousStep.action == "walk" and nextStep.action == "walk" then
		local across = nextStep.position - previousStep.position
		if across.Magnitude > EPSILON then
			return across.Unit
		end
	end

	if nextStep and nextStep.action == "walk" then
		local forward = nextStep.position - step.position
		if forward.Magnitude > EPSILON then
			return forward.Unit
		end
	end

	if previousStep and previousStep.action == "walk" then
		local backward = step.position - previousStep.position
		if backward.Magnitude > EPSILON then
			return backward.Unit
		end
	end

	return nil
end

local function getWalkSmoothingControls(
	npc: ClientNPC,
	stepIndex: number
): (Vector3?, Vector3?, Vector3?, Vector3?)
	if not Config.PATH_SMOOTHING_ENABLED then
		return nil
	end

	local step = npc.route[stepIndex]
	local nextStep = npc.route[stepIndex + 1]
	if not step or not nextStep then
		return nil
	end

	if step.action ~= "walk" or nextStep.action ~= "walk" then
		return nil
	end

	local radius = math.max(0, tonumber(Config.PATH_SMOOTHING_RADIUS) or 0)
	if radius <= EPSILON then
		return nil
	end

	local segmentVector = nextStep.position - step.position
	local segmentLength = segmentVector.Magnitude
	if segmentLength <= EPSILON then
		return nil
	end

	local segmentDirection = segmentVector.Unit
	local tangentStart = getWalkTangentAtStep(npc, stepIndex) or segmentDirection
	local tangentEnd = getWalkTangentAtStep(npc, stepIndex + 1) or segmentDirection

	if tangentStart:Dot(segmentDirection) <= 0 then
		tangentStart = segmentDirection
	end
	if tangentEnd:Dot(segmentDirection) <= 0 then
		tangentEnd = segmentDirection
	end

	local localRadius = math.min(radius, segmentLength * 0.6)
	local p0 = step.position
	local p1 = step.position + tangentStart * localRadius
	local p2 = nextStep.position - tangentEnd * localRadius
	local p3 = nextStep.position
	return p0, p1, p2, p3
end

local function approximateBezierLength(
	p0: Vector3,
	p1: Vector3,
	p2: Vector3,
	p3: Vector3
): number
	local samples = getSmoothingSamples()
	local totalLength = 0
	local previousPoint = p0
	for i = 1, samples do
		local t = i / samples
		local point = cubicBezier(p0, p1, p2, p3, t)
		totalLength += (point - previousPoint).Magnitude
		previousPoint = point
	end
	return totalLength
end

local function remapBezierAlphaByArcLength(
	p0: Vector3,
	p1: Vector3,
	p2: Vector3,
	p3: Vector3,
	alpha: number
): number
	local samples = getSmoothingSamples()
	local cumulative = table.create(samples + 1, 0)
	local previousPoint = p0
	local totalLength = 0

	for i = 1, samples do
		local t = i / samples
		local point = cubicBezier(p0, p1, p2, p3, t)
		totalLength += (point - previousPoint).Magnitude
		cumulative[i + 1] = totalLength
		previousPoint = point
	end

	if totalLength <= EPSILON then
		return alpha
	end

	local targetLength = math.clamp(alpha, 0, 1) * totalLength
	for i = 1, samples do
		local startLen = cumulative[i]
		local endLen = cumulative[i + 1]
		if targetLength <= endLen then
			local span = endLen - startLen
			local segmentAlpha = if span > EPSILON then (targetLength - startLen) / span else 0
			return ((i - 1) + segmentAlpha) / samples
		end
	end

	return 1
end

local function maybeSmoothWalkPosition(npc: ClientNPC, stepIndex: number, alpha: number, linearPosition: Vector3): Vector3
	local p0, p1, p2, p3 = getWalkSmoothingControls(npc, stepIndex)
	if not p0 or not p1 or not p2 or not p3 then
		return linearPosition
	end

	local remappedAlpha = remapBezierAlphaByArcLength(p0, p1, p2, p3, alpha)
	return cubicBezier(p0, p1, p2, p3, remappedAlpha)
end

local function getWalkSegmentLength(npc: ClientNPC, stepIndex: number, step: RouteStep, nextStep: RouteStep): number
	local linearLength = (nextStep.position - step.position).Magnitude
	local p0, p1, p2, p3 = getWalkSmoothingControls(npc, stepIndex)
	if not p0 or not p1 or not p2 or not p3 then
		return linearLength
	end

	local curvedLength = approximateBezierLength(p0, p1, p2, p3)
	if curvedLength > EPSILON then
		return curvedLength
	end
	return linearLength
end

local function applyLaneOffsetToWalkPosition(
	npc: ClientNPC,
	stepIndex: number,
	position: Vector3,
	towardPosition: Vector3?
): (Vector3, Vector3?)
	local offset = laneOffsetByNpcId[npc.id] or ensureLaneOffset(npc)
	if math.abs(offset) <= EPSILON then
		return position, towardPosition
	end

	local nextStep = npc.route[stepIndex + 1]
	if not nextStep or nextStep.action ~= "walk" then
		return position, towardPosition
	end

	local directionalTarget = towardPosition or nextStep.position
	local direction = directionalTarget - position
	local flatDirection = Vector3.new(direction.X, 0, direction.Z)
	if flatDirection.Magnitude <= EPSILON then
		return position, towardPosition
	end

	local lateral = Vector3.new(-flatDirection.Unit.Z, 0, flatDirection.Unit.X) * offset
	local shiftedPosition = position + lateral
	local shiftedToward = if towardPosition then towardPosition + lateral else nil
	return shiftedPosition, shiftedToward
end

local function getTurnLookaheadDistance(): number
	local raw = tonumber(Config.PATH_TURN_LOOKAHEAD)
	if raw == nil then
		return 6
	end
	return math.max(0, raw)
end

local function getTurnBlendSpeed(): number
	local raw = tonumber(Config.PATH_TURN_BLEND_SPEED)
	if raw == nil then
		return 10
	end
	return math.max(0, raw)
end

local function getTurnSnapDotThreshold(): number
	local raw = tonumber(Config.PATH_TURN_SNAP_DOT_THRESHOLD)
	if raw == nil then
		return -0.2
	end
	return math.clamp(raw, -1, 1)
end

local function getLookaheadTargetPosition(
	npc: ClientNPC,
	currentStepIndex: number,
	currentPosition: Vector3,
	fallbackToward: Vector3?
): Vector3?
	local remaining = getTurnLookaheadDistance()
	local cursor = currentPosition
	local index = currentStepIndex + 1
	local route = npc.route

	while remaining > EPSILON and index <= #route do
		local step = route[index]
		local target = step.position
		local segment = target - cursor
		local segmentLength = segment.Magnitude

		if segmentLength > EPSILON then
			if segmentLength >= remaining then
				return cursor + segment.Unit * remaining
			end
			remaining -= segmentLength
			cursor = target
		else
			cursor = target
		end

		index += 1
	end

	return fallbackToward
end

local function snapWalkPositionToGround(npc: ClientNPC, rawPosition: Vector3): Vector3
	if not Config.GROUND_SNAP_ENABLED then
		return rawPosition
	end

	local rayHeight = math.max(1, tonumber(Config.GROUND_SNAP_RAY_HEIGHT) or 40)
	local rayLength = math.max(rayHeight + 1, tonumber(Config.GROUND_SNAP_RAY_LENGTH) or 160)
	local clearance = tonumber(Config.GROUND_SNAP_CLEARANCE) or 0
	local maxIgnoreHits = math.max(1, math.floor(tonumber(Config.GROUND_SNAP_MAX_IGNORE_HITS) or 8))

	local ignoredInstances: { Instance } = {}
	if npc.model then
		table.insert(ignoredInstances, npc.model)
	end

	local origin = rawPosition + Vector3.new(0, rayHeight, 0)
	local direction = Vector3.new(0, -rayLength, 0)
	local result: RaycastResult? = nil

	for _ = 1, maxIgnoreHits do
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = ignoredInstances
		params.IgnoreWater = true

		result = Workspace:Raycast(origin, direction, params)
		if not result then
			break
		end

		if shouldIgnoreGroundHit(result.Instance) then
			table.insert(ignoredInstances, result.Instance)
		else
			break
		end
	end

	if not result then
		return rawPosition
	end

	if shouldIgnoreGroundHit(result.Instance) then
		return rawPosition
	end

	local snappedY = result.Position.Y + getGroundOffset(npc) + clearance
	return Vector3.new(rawPosition.X, snappedY, rawPosition.Z)
end

local function getStepDuration(npc: ClientNPC, stepIndex: number): number
	local step = npc.route[stepIndex]
	if not step then
		return 0
	end

	if step.action == "walk" then
		local nextStep = npc.route[stepIndex + 1]
		if not nextStep then
			return 0
		end
		local pathLength = getWalkSegmentLength(npc, stepIndex, step, nextStep)
		return pathLength / math.max(npc.speed, EPSILON)
	end

	if step.action == "idle" or step.action == "sit" then
		return math.max(0, step.duration or 0)
	end

	return 0
end

local function applyStationaryPoseIfNeeded(npc: ClientNPC, step: RouteStep): ()
	local model = npc.model
	if not model or model.Parent == nil or npc.lodTier == "far" then
		if step.action == "idle" and step.faceCFrame then
			npc.lastPosition = step.faceCFrame.Position
		elseif step.action == "sit" and step.sitCFrame then
			npc.lastPosition = step.sitCFrame.Position
		else
			npc.lastPosition = step.position
		end
		return
	end

	if step.action == "idle" then
		if step.faceCFrame then
			model:PivotTo(step.faceCFrame)
			npc.lastPosition = step.faceCFrame.Position
		else
			npc.lastPosition = step.position
		end
	elseif step.action == "sit" then
		if step.sitCFrame then
			model:PivotTo(step.sitCFrame)
			npc.lastPosition = step.sitCFrame.Position
		else
			npc.lastPosition = step.position
		end
	else
		npc.lastPosition = step.position
	end
end

local function completeRoute(state: ActiveRouteState): ()
	activeRoutes[state.npc.id] = nil
	groundOffsetByNpcId[state.npc.id] = nil
	laneOffsetByNpcId[state.npc.id] = nil
	state.onRouteComplete(state.npc)
end

local function advanceRouteByTime(state: ActiveRouteState, nowTime: number): boolean
	local npc = state.npc
	local maxIterations = math.max(1, #npc.route * 2)

	for _ = 1, maxIterations do
		local currentStep = getCurrentStep(npc)
		if not currentStep then
			completeRoute(state)
			return true
		end

		if currentStep.action == "despawn" then
			completeRoute(state)
			return true
		end

		local stepDuration = getStepDuration(npc, npc.currentStepIndex)
		if nowTime - npc.stepStartTime < stepDuration then
			return false
		end

		local overflow = math.max(0, (nowTime - npc.stepStartTime) - stepDuration)
		npc.currentStepIndex += 1
		npc.stepStartTime = nowTime - overflow

		local nextStep = getCurrentStep(npc)
		if not nextStep then
			completeRoute(state)
			return true
		end

		if nextStep.action == "despawn" then
			completeRoute(state)
			return true
		end

		applyStationaryPoseIfNeeded(npc, nextStep)
		if npc.lodTier == "near" then
			state.onStepChanged(npc, nextStep)
		end
	end

	return false
end

local function computeCurrentPosition(npc: ClientNPC, nowTime: number): (RouteStep?, Vector3, Vector3?)
	local step = getCurrentStep(npc)
	if not step then
		return nil, npc.lastPosition, nil
	end

	if step.action == "walk" then
		local nextStep = npc.route[npc.currentStepIndex + 1]
		if nextStep then
			local duration = getStepDuration(npc, npc.currentStepIndex)
			local alpha = if duration <= EPSILON then 1 else math.clamp((nowTime - npc.stepStartTime) / duration, 0, 1)
			local position = step.position:Lerp(nextStep.position, alpha)
			position = maybeSmoothWalkPosition(npc, npc.currentStepIndex, alpha, position)

			local towardAlpha = math.min(1, alpha + 0.06)
			local towardPosition = step.position:Lerp(nextStep.position, towardAlpha)
			towardPosition = maybeSmoothWalkPosition(npc, npc.currentStepIndex, towardAlpha, towardPosition)
			return step, position, towardPosition
		end
	end

	if step.action == "idle" and step.faceCFrame then
		return step, step.faceCFrame.Position, nil
	end
	if step.action == "sit" and step.sitCFrame then
		return step, step.sitCFrame.Position, nil
	end

	return step, step.position, nil
end

local function determineLodTier(lastPosition: Vector3): LODTier
	local camera = Workspace.CurrentCamera
	if not camera then
		return "near"
	end

	local cameraPosition = camera.CFrame.Position
	local toNpc = lastPosition - cameraPosition
	local distance = toNpc.Magnitude
	local lookDot = toNpc:Dot(camera.CFrame.LookVector)
	local behindCamera = Config.LOD_FRUSTUM_CULLING and lookDot < 0
	local animationDistance = tonumber(Config.LOD_ANIMATION_DISTANCE) or 0
	local renderDistance = tonumber(Config.LOD_RENDER_DISTANCE) or 0

	if distance > renderDistance then
		return "far"
	end

	if distance < animationDistance and not behindCamera then
		return "near"
	end

	return "mid"
end

local function applyWalkPivot(
	npc: ClientNPC,
	position: Vector3,
	towardPosition: Vector3?,
	dt: number?,
	movementDirection: Vector3?
): ()
	local model = npc.model
	if not model or model.Parent == nil then
		return
	end

	local desiredFlatDirection: Vector3? = nil
	if movementDirection and movementDirection.Magnitude > EPSILON then
		desiredFlatDirection = movementDirection.Unit
	else
		local lookTarget = getLookaheadTargetPosition(npc, npc.currentStepIndex, position, towardPosition)
		if lookTarget then
			local rawDirection = lookTarget - position
			local flatDirection = Vector3.new(rawDirection.X, 0, rawDirection.Z)
			if flatDirection.Magnitude > EPSILON then
				desiredFlatDirection = flatDirection.Unit
			end
		end
	end

	if desiredFlatDirection then
		local currentLook = model:GetPivot().LookVector
		local currentFlatDirection = Vector3.new(currentLook.X, 0, currentLook.Z)
		local facingDirection = desiredFlatDirection

		if currentFlatDirection.Magnitude > EPSILON and dt and dt > 0 then
			local currentUnit = currentFlatDirection.Unit
			local dot = math.clamp(currentUnit:Dot(desiredFlatDirection), -1, 1)
			if dot <= getTurnSnapDotThreshold() then
				facingDirection = desiredFlatDirection
			else
				local blendAlpha = 1 - math.exp(-getTurnBlendSpeed() * dt)
				local blended = currentUnit:Lerp(desiredFlatDirection, blendAlpha)
				if blended.Magnitude > EPSILON then
					facingDirection = blended.Unit
				end
			end
		end

		model:PivotTo(CFrame.lookAt(position, position + facingDirection))
		return
	end

	model:PivotTo(model:GetPivot().Rotation + position)
end

local function getMovementDirection(previousPosition: Vector3, currentPosition: Vector3): Vector3?
	local delta = currentPosition - previousPosition
	local flatDelta = Vector3.new(delta.X, 0, delta.Z)
	if flatDelta.Magnitude <= EPSILON then
		return nil
	end
	return flatDelta.Unit
end

local function noOpStepChanged(_npc: ClientNPC, _step: RouteStep): ()
end

local function noOpRouteComplete(_npc: ClientNPC): ()
end

function NPCMover.startRoute(
	npc: ClientNPC,
	startStepIndex: number?,
	onStepChanged: StepChangedCallback,
	onRouteComplete: RouteCompleteCallback
): ()
	if #npc.route == 0 then
		return
	end

	local startIndex = if startStepIndex then math.floor(startStepIndex) else 1
	startIndex = math.clamp(startIndex, 1, #npc.route)

	npc.currentStepIndex = startIndex
	if npc.stepStartTime <= 0 then
		npc.stepStartTime = tick()
	end
	npc.lodTier = npc.lodTier or "near"
	getGroundOffset(npc)
	ensureLaneOffset(npc)

	local state: ActiveRouteState = {
		npc = npc,
		onStepChanged = onStepChanged or noOpStepChanged,
		onRouteComplete = onRouteComplete or noOpRouteComplete,
	}
	activeRoutes[npc.id] = state

	local startStep = npc.route[startIndex]
	if startStep.action == "idle" or startStep.action == "sit" then
		applyStationaryPoseIfNeeded(npc, startStep)
	end
end

function NPCMover.stop(npcId: string): ()
	activeRoutes[npcId] = nil
	groundOffsetByNpcId[npcId] = nil
	laneOffsetByNpcId[npcId] = nil
end

function NPCMover.fastForward(npc: ClientNPC): ()
	local nowTime = tick()
	local step, position, toward = computeCurrentPosition(npc, nowTime)
	if not step then
		return
	end

	if step.action == "walk" then
		position, toward = applyLaneOffsetToWalkPosition(npc, npc.currentStepIndex, position, toward)
		position = snapWalkPositionToGround(npc, position)
		npc.lastPosition = position
		applyWalkPivot(npc, position, toward, 1 / 30, nil)
	elseif step.action == "idle" then
		npc.lastPosition = position
		if step.faceCFrame and npc.model and npc.model.Parent ~= nil then
			npc.model:PivotTo(step.faceCFrame)
		end
	elseif step.action == "sit" then
		npc.lastPosition = position
		if step.sitCFrame and npc.model and npc.model.Parent ~= nil then
			npc.model:PivotTo(step.sitCFrame)
		end
	else
		npc.lastPosition = position
	end
end

function NPCMover.update(dt: number): ()
	local nowTime = tick()

	for npcId, state in pairs(activeRoutes) do
		local npc = state.npc

		if advanceRouteByTime(state, nowTime) then
			-- route completed and callback fired
		else
			local step, position, toward = computeCurrentPosition(npc, nowTime)
			if not step then
				completeRoute(state)
			else
				local previousPosition = npc.lastPosition
				local previousTier = npc.lodTier
				local nextTier = determineLodTier(position)

				if step.action == "walk" and nextTier ~= "far" then
					position, toward = applyLaneOffsetToWalkPosition(npc, npc.currentStepIndex, position, toward)
					position = snapWalkPositionToGround(npc, position)
				end

				npc.lastPosition = position

				if previousTier ~= nextTier then
					if (previousTier == "near" or previousTier == "mid") and nextTier == "far" then
						if npc.model then
							npc.model.Parent = nil
						end
						stopAllTracks(npc)
					elseif previousTier == "far" and (nextTier == "mid" or nextTier == "near") then
						if npc.model then
							npc.model.Parent = Workspace
						end
						NPCMover.fastForward(npc)
						if nextTier == "near" then
							state.onStepChanged(npc, step)
							unfreezeTracks(npc)
						else
							stopAllTracks(npc)
						end
					elseif previousTier == "near" and nextTier == "mid" then
						stopAllTracks(npc)
					elseif previousTier == "mid" and nextTier == "near" then
						state.onStepChanged(npc, step)
						unfreezeTracks(npc)
					end

					npc.lodTier = nextTier
				end

					if step.action == "walk" and npc.lodTier ~= "far" then
						if npc.model and npc.model.Parent == nil then
							npc.model.Parent = Workspace
						end
						local movementDirection = getMovementDirection(previousPosition, position)
						applyWalkPivot(npc, position, toward, dt, movementDirection)
					end
				end
			end

		if activeRoutes[npcId] == nil then
			-- removed during callbacks/route completion
		end
	end
end

return NPCMover
