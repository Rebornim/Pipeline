--!strict

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local VehicleVisualSmoother = {}

local VISUALS_FOLDER_NAME = "CombatClientVisuals"
local SMOOTHING_ALPHA = 10
local MAX_VISUAL_SNAP_DISTANCE = 40
local EXTRAPOLATION_CAP = 0.15
local SOURCE_CHANGE_POS_THRESHOLD = 0.001
local SOURCE_CHANGE_ROT_THRESHOLD = 0.0001

type PartPair = {
	source: BasePart,
	visual: BasePart,
}

local LOCAL_PLAYER = Players.LocalPlayer

local sourceModel: Model? = nil
local renderModel: Model? = nil
local renderConnection: RBXScriptConnection? = nil
local renderCFrame: CFrame? = nil
local sourceTransparency: { [BasePart]: number } = {}

-- Dead reckoning state
local lastSourceCFrame: CFrame? = nil
local lastSourceChangeTick: number = 0
local estimatedVelocity: Vector3 = Vector3.zero
local hasMoved: boolean = false
local estimatedAngularVelocityY: number = 0
local lastSourceYaw: number? = nil

-- Steer banking (client-side visual only)
local STEER_BANK_MAX_RAD = math.rad(12)
local steerBankTarget: number = 0
local smoothedSteerBank: number = 0

local sourceCharacter: Model? = nil
local visualCharacter: Model? = nil
local sourceCharacterTransparency: { [BasePart]: number } = {}
local sourceCharacterForceFieldVisible: { [ForceField]: boolean } = {}
local characterPartPairs: { PartPair } = {}

local function applyCharacterVisibility(instance: Instance, hidden: boolean)
	if instance:IsA("BasePart") then
		local part = instance
		if hidden then
			if sourceCharacterTransparency[part] == nil then
				sourceCharacterTransparency[part] = part.LocalTransparencyModifier
			end
			part.LocalTransparencyModifier = 1
		else
			local previous = sourceCharacterTransparency[part]
			part.LocalTransparencyModifier = if previous ~= nil then previous else 0
		end
	end

	if instance:IsA("ForceField") then
		local forceField = instance
		if hidden then
			if sourceCharacterForceFieldVisible[forceField] == nil then
				sourceCharacterForceFieldVisible[forceField] = forceField.Visible
			end
			forceField.Visible = false
		else
			local previous = sourceCharacterForceFieldVisible[forceField]
			forceField.Visible = if previous ~= nil then previous else true
		end
	end
end

local function ensureVisualsFolder(): Folder
	local existing = Workspace:FindFirstChild(VISUALS_FOLDER_NAME)
	if existing ~= nil and existing:IsA("Folder") then
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = VISUALS_FOLDER_NAME
	folder.Parent = Workspace
	return folder
end

local function setSourceHidden(model: Model, hidden: boolean)
	for _, descendant in ipairs(model:GetDescendants()) do
		if not descendant:IsA("BasePart") then
			continue
		end

		local part = descendant
		if hidden then
			if sourceTransparency[part] == nil then
				sourceTransparency[part] = part.LocalTransparencyModifier
			end
			part.LocalTransparencyModifier = 1
		else
			local previous = sourceTransparency[part]
			part.LocalTransparencyModifier = if previous ~= nil then previous else 0
		end
	end
	if not hidden then
		table.clear(sourceTransparency)
	end
end

local function setCharacterHidden(model: Model, hidden: boolean)
	for _, descendant in ipairs(model:GetDescendants()) do
		applyCharacterVisibility(descendant, hidden)
	end
	if not hidden then
		table.clear(sourceCharacterTransparency)
		table.clear(sourceCharacterForceFieldVisible)
	end
end

local function cleanupStaleCharacterVisuals()
	local folder = ensureVisualsFolder()
	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("Model") and child:FindFirstChildOfClass("Humanoid") ~= nil then
			child:Destroy()
		end
	end
end

local function stripCloneForVisuals(model: Model)
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("ForceField") then
			descendant:Destroy()
			continue
		end

		if descendant:IsA("Script") or descendant:IsA("LocalScript") or descendant:IsA("ModuleScript") then
			descendant:Destroy()
			continue
		end
		if descendant:IsA("WeldConstraint") then
			descendant:Destroy()
			continue
		end

		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.Massless = true
		end
	end
end

local function getRelativePath(root: Instance, descendant: Instance): { string }
	local path: { string } = {}
	local current: Instance? = descendant
	while current ~= nil and current ~= root do
		table.insert(path, 1, current.Name)
		current = current.Parent
	end
	return path
end

local function findByPath(root: Instance, path: { string }): Instance?
	local current: Instance = root
	for _, segment in ipairs(path) do
		local nextNode = current:FindFirstChild(segment)
		if nextNode == nil then
			return nil
		end
		current = nextNode
	end
	return current
end

local function buildCharacterPartPairs(source: Model, visual: Model): { PartPair }
	local pairs: { PartPair } = {}
	for _, descendant in ipairs(source:GetDescendants()) do
		if not descendant:IsA("BasePart") then
			continue
		end
		local sourcePart = descendant
		local path = getRelativePath(source, sourcePart)
		local visualMatch = findByPath(visual, path)
		if visualMatch ~= nil and visualMatch:IsA("BasePart") then
			table.insert(pairs, {
				source = sourcePart,
				visual = visualMatch,
			})
		end
	end
	return pairs
end

local function stepRender(dt: number)
	local src = sourceModel
	local visual = renderModel
	if src == nil or visual == nil then
		return
	end
	if src.Parent == nil then
		VehicleVisualSmoother.deactivate()
		return
	end

	local sourcePrimary = src.PrimaryPart
	if sourcePrimary == nil then
		return
	end

	local now = tick()
	local sourceCFrame = sourcePrimary.CFrame

	-- Detect when a real replication update arrives (source CFrame actually changed)
	local sourceChanged = false
	if lastSourceCFrame == nil then
		sourceChanged = true
	else
		local posDelta = (sourceCFrame.Position - lastSourceCFrame.Position).Magnitude
		local rotDelta = 1 - sourceCFrame.LookVector:Dot(lastSourceCFrame.LookVector)
		if posDelta > SOURCE_CHANGE_POS_THRESHOLD or rotDelta > SOURCE_CHANGE_ROT_THRESHOLD then
			sourceChanged = true
		end
	end

	if sourceChanged then
		if lastSourceCFrame ~= nil then
			local elapsed = now - lastSourceChangeTick
			if elapsed > 0.01 then
				local newVelocity = (sourceCFrame.Position - lastSourceCFrame.Position) / elapsed
				-- First movement after being stationary: snap visual to avoid startup freeze
				if not hasMoved and newVelocity.Magnitude > 1 then
					hasMoved = true
					renderCFrame = sourceCFrame
				end
				-- Blend with previous estimate to prevent prediction jumps
				if estimatedVelocity.Magnitude > 0.1 then
					estimatedVelocity = estimatedVelocity:Lerp(newVelocity, 0.7)
				else
					estimatedVelocity = newVelocity
				end

				-- Track angular velocity for curved extrapolation during turns
				local lv = sourceCFrame.LookVector
				local currentYaw = math.atan2(lv.X, lv.Z)
				if lastSourceYaw ~= nil then
					local yawDelta = currentYaw - lastSourceYaw
					if yawDelta > math.pi then yawDelta = yawDelta - 2 * math.pi end
					if yawDelta < -math.pi then yawDelta = yawDelta + 2 * math.pi end
					local newAngularVel = yawDelta / elapsed
					if math.abs(estimatedAngularVelocityY) > 0.01 then
						estimatedAngularVelocityY = estimatedAngularVelocityY + (newAngularVel - estimatedAngularVelocityY) * 0.7
					else
						estimatedAngularVelocityY = newAngularVel
					end
				end
				lastSourceYaw = currentYaw
			end
		end
		lastSourceCFrame = sourceCFrame
		lastSourceChangeTick = now
	end

	-- Dead reckoning: predict position between 20Hz replication updates
	local targetCFrame = sourceCFrame
	local speed = src:GetAttribute("VehicleSpeed")
	local isMoving = type(speed) == "number" and speed > 1
	if isMoving and lastSourceCFrame ~= nil then
		local timeSinceUpdate = now - lastSourceChangeTick
		if timeSinceUpdate > 0 and timeSinceUpdate < EXTRAPOLATION_CAP then
			-- Curve the extrapolation path using angular velocity (handles turns)
			local halfAngle = estimatedAngularVelocityY * timeSinceUpdate * 0.5
			local cos = math.cos(halfAngle)
			local sin = math.sin(halfAngle)
			local vx = estimatedVelocity.X * cos - estimatedVelocity.Z * sin
			local vz = estimatedVelocity.X * sin + estimatedVelocity.Z * cos
			local curvedVelocity = Vector3.new(vx, estimatedVelocity.Y, vz)
			local predictedPos = lastSourceCFrame.Position + curvedVelocity * timeSinceUpdate
			targetCFrame = sourceCFrame - sourceCFrame.Position + predictedPos
		end
	end

	local current = renderCFrame
	if current == nil then
		current = targetCFrame
	else
		local clampedDt = math.clamp(dt, 1 / 240, 1 / 20)
		local alpha = 1 - math.exp(-SMOOTHING_ALPHA * clampedDt)
		current = current:Lerp(targetCFrame, alpha)
		if (current.Position - targetCFrame.Position).Magnitude > MAX_VISUAL_SNAP_DISTANCE then
			current = targetCFrame
		end
	end
	-- Steer banking: smooth roll proportional to mouse steer input
	-- Applied only for display — NOT stored in renderCFrame to prevent compounding
	local bankDt = math.clamp(dt, 1 / 240, 1 / 20)
	local bankAlpha = 1 - math.exp(-8 * bankDt)
	smoothedSteerBank += (steerBankTarget - smoothedSteerBank) * bankAlpha

	renderCFrame = current

	local displayCFrame = current
	if math.abs(smoothedSteerBank) > 0.001 then
		local heading = src:GetAttribute("VehicleHeading")
		if type(heading) == "number" then
			local worldForward = Vector3.new(-math.sin(heading), 0, -math.cos(heading))
			local localForward = displayCFrame:VectorToObjectSpace(worldForward)
			if localForward.Magnitude > 1e-4 then
				displayCFrame = displayCFrame * CFrame.fromAxisAngle(localForward.Unit, smoothedSteerBank * STEER_BANK_MAX_RAD)
			end
		end
	end

	visual:PivotTo(displayCFrame)
	visual:SetAttribute("VehicleHeading", src:GetAttribute("VehicleHeading"))
	visual:SetAttribute("VehicleSpeed", src:GetAttribute("VehicleSpeed"))

	local srcCharacter = sourceCharacter
	local visCharacter = visualCharacter
	if srcCharacter ~= nil and visCharacter ~= nil and sourcePrimary.Parent ~= nil then
		setCharacterHidden(srcCharacter, true)
		local delta = displayCFrame * sourcePrimary.CFrame:Inverse()
		for _, pair in ipairs(characterPartPairs) do
			if pair.source.Parent ~= nil and pair.visual.Parent ~= nil then
				pair.visual.CFrame = delta * pair.source.CFrame
			end
		end
	end
end

function VehicleVisualSmoother.setSteerBank(steerX: number, speedFraction: number, leanActive: boolean): ()
	if leanActive then
		steerBankTarget = 0
	else
		steerBankTarget = math.clamp(steerX, -1, 1) * math.clamp(speedFraction, 0, 1)
	end
end

function VehicleVisualSmoother.activate(model: Model): Model
	VehicleVisualSmoother.deactivate()

	sourceModel = model
	setSourceHidden(model, true)

	local clone = model:Clone()
	clone.Name = model.Name .. "_Visual"
	if model.PrimaryPart ~= nil then
		local clonePrimary = clone:FindFirstChild(model.PrimaryPart.Name, true)
		if clonePrimary ~= nil and clonePrimary:IsA("BasePart") then
			clone.PrimaryPart = clonePrimary
		end
	end
	stripCloneForVisuals(clone)
	CollectionService:RemoveTag(clone, "VehicleEntity")
	clone.Parent = ensureVisualsFolder()

	renderModel = clone
	renderCFrame = nil
	lastSourceCFrame = nil
	lastSourceChangeTick = 0
	estimatedVelocity = Vector3.zero
	hasMoved = false
	estimatedAngularVelocityY = 0
	lastSourceYaw = nil
	steerBankTarget = 0
	smoothedSteerBank = 0

	local character = LOCAL_PLAYER.Character
	if character ~= nil then
		sourceCharacter = character
		setCharacterHidden(character, true)
		cleanupStaleCharacterVisuals()

		local prevArchivable = character.Archivable
		character.Archivable = true
		local characterClone = character:Clone()
		character.Archivable = prevArchivable
		characterClone.Name = character.Name .. "_CharacterVisual"
		stripCloneForVisuals(characterClone)
		characterClone.Parent = ensureVisualsFolder()

		visualCharacter = characterClone
		characterPartPairs = buildCharacterPartPairs(character, characterClone)
	else
		sourceCharacter = nil
		visualCharacter = nil
		table.clear(characterPartPairs)
	end

	stepRender(1 / 60)
	renderConnection = RunService.RenderStepped:Connect(stepRender)

	return clone
end

function VehicleVisualSmoother.deactivate()
	if renderConnection ~= nil then
		renderConnection:Disconnect()
		renderConnection = nil
	end

	local src = sourceModel
	if src ~= nil and src.Parent ~= nil then
		setSourceHidden(src, false)
	else
		table.clear(sourceTransparency)
	end

	if renderModel ~= nil then
		renderModel:Destroy()
		renderModel = nil
	end

	if visualCharacter ~= nil then
		visualCharacter:Destroy()
		visualCharacter = nil
	end

	local character = sourceCharacter
	if character ~= nil and character.Parent ~= nil then
		setCharacterHidden(character, false)
	else
		table.clear(sourceCharacterTransparency)
		table.clear(sourceCharacterForceFieldVisible)
	end

	sourceModel = nil
	sourceCharacter = nil
	renderCFrame = nil
	lastSourceCFrame = nil
	lastSourceChangeTick = 0
	estimatedVelocity = Vector3.zero
	hasMoved = false
	estimatedAngularVelocityY = 0
	lastSourceYaw = nil
	steerBankTarget = 0
	smoothedSteerBank = 0
	table.clear(characterPartPairs)
end

return VehicleVisualSmoother
