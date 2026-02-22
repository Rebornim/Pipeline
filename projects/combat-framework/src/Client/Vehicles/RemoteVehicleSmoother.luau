--!strict

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local sharedRoot = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatConfig = require(sharedRoot:WaitForChild("CombatConfig"))

local clientRoot = Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("CombatFramework")
local VehicleSoundManager = require(clientRoot:WaitForChild("Vehicles"):WaitForChild("VehicleSoundManager"))

local RemoteVehicleSmoother = {}

local VISUALS_FOLDER_NAME = "CombatClientVisuals"
local SMOOTHING_ALPHA = 10
local MAX_SNAP_DISTANCE = 40

type PartPair = {
	source: BasePart,
	visual: BasePart,
}

type RemoteCharacterEntry = {
	sourceCharacter: Model,
	visualClone: Model,
	sourceTransparency: { [BasePart]: number },
	partPairs: { PartPair },
}

type RemoteVehicleEntry = {
	sourceModel: Model,
	visualClone: Model,
	sourceTransparency: { [BasePart]: number },
	smoothedCFrame: CFrame,
	isActive: boolean,
	characterEntries: { [Model]: RemoteCharacterEntry },
	soundController: VehicleSoundManager.SoundController?,
	destroyConnection: RBXScriptConnection?,
}

local LOCAL_PLAYER = Players.LocalPlayer

local localVehicleModel: Model? = nil
local trackedVehicles: { [Model]: RemoteVehicleEntry } = {}
local activationWatchers: { [Model]: { RBXScriptConnection } } = {}
local renderConnection: RBXScriptConnection? = nil
local addedConnection: RBXScriptConnection? = nil
local removedConnection: RBXScriptConnection? = nil

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

local function hideSource(model: Model, entry: RemoteVehicleEntry)
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			local part = descendant
			if entry.sourceTransparency[part] == nil then
				entry.sourceTransparency[part] = part.LocalTransparencyModifier
			end
			part.LocalTransparencyModifier = 1
		end
	end
end

local function restoreSource(entry: RemoteVehicleEntry)
	for part, transparency in pairs(entry.sourceTransparency) do
		if part.Parent ~= nil then
			part.LocalTransparencyModifier = transparency
		end
	end
	table.clear(entry.sourceTransparency)
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

local function buildPartPairs(source: Model, visual: Model): { PartPair }
	local result: { PartPair } = {}
	for _, descendant in ipairs(source:GetDescendants()) do
		if not descendant:IsA("BasePart") then
			continue
		end
		local sourcePart = descendant
		local path = getRelativePath(source, sourcePart)
		local visualMatch = findByPath(visual, path)
		if visualMatch ~= nil and visualMatch:IsA("BasePart") then
			table.insert(result, {
				source = sourcePart,
				visual = visualMatch,
			})
		end
	end
	return result
end

local function findSeatedCharacters(model: Model): { Model }
	local characters: { Model } = {}
	for _, descendant in ipairs(model:GetDescendants()) do
		local occupant: Humanoid? = nil
		if descendant:IsA("VehicleSeat") then
			occupant = (descendant :: VehicleSeat).Occupant
		elseif descendant:IsA("Seat") then
			occupant = (descendant :: Seat).Occupant
		end
		if occupant ~= nil then
			local character = occupant.Parent
			if character ~= nil and character:IsA("Model") and character ~= LOCAL_PLAYER.Character then
				table.insert(characters, character)
			end
		end
	end
	return characters
end

local function hideCharacter(charEntry: RemoteCharacterEntry)
	for _, descendant in ipairs(charEntry.sourceCharacter:GetDescendants()) do
		if descendant:IsA("BasePart") then
			local part = descendant
			if charEntry.sourceTransparency[part] == nil then
				charEntry.sourceTransparency[part] = part.LocalTransparencyModifier
			end
			part.LocalTransparencyModifier = 1
		end
	end
end

local function restoreCharacter(charEntry: RemoteCharacterEntry)
	for part, transparency in pairs(charEntry.sourceTransparency) do
		if part.Parent ~= nil then
			part.LocalTransparencyModifier = transparency
		end
	end
	table.clear(charEntry.sourceTransparency)
end

local function activateCharacter(character: Model): RemoteCharacterEntry?
	local prevArchivable = character.Archivable
	character.Archivable = true
	local clone = character:Clone()
	character.Archivable = prevArchivable

	clone.Name = character.Name .. "_RemoteCharVisual"
	stripCloneForVisuals(clone)
	clone.Parent = ensureVisualsFolder()

	local charEntry: RemoteCharacterEntry = {
		sourceCharacter = character,
		visualClone = clone,
		sourceTransparency = {},
		partPairs = buildPartPairs(character, clone),
	}
	hideCharacter(charEntry)
	return charEntry
end

local function deactivateCharacter(charEntry: RemoteCharacterEntry)
	restoreCharacter(charEntry)
	if charEntry.visualClone.Parent ~= nil then
		charEntry.visualClone:Destroy()
	end
end

--------------------------------------------------------------------------
-- Sound controller management
--------------------------------------------------------------------------

local function getMaxSpeedForModel(model: Model): number
	local configId = model:GetAttribute("VehicleCategory")
	if type(configId) ~= "string" then
		configId = model:GetAttribute("VehicleConfigId")
	end
	if type(configId) == "string" then
		local vehConfig = (CombatConfig.Vehicles :: any)[configId]
		if type(vehConfig) == "table" and type(vehConfig.maxSpeed) == "number" then
			local baseSpeed = vehConfig.maxSpeed
			local mod = model:GetAttribute("VehicleMaxSpeedMod")
			if type(mod) == "number" then
				baseSpeed = baseSpeed * (1 + mod)
			end
			return math.max(1, baseSpeed)
		end
	end
	return 120
end

local function createSoundController(entry: RemoteVehicleEntry)
	if entry.soundController ~= nil then return end
	local clonePrimary = entry.visualClone.PrimaryPart
	if clonePrimary == nil then return end
	local ms = getMaxSpeedForModel(entry.sourceModel)
	entry.soundController = VehicleSoundManager.createController(entry.sourceModel, clonePrimary, ms, false)
end

local function destroySoundController(entry: RemoteVehicleEntry)
	if entry.soundController ~= nil then
		entry.soundController:destroy()
		entry.soundController = nil
	end
end

--------------------------------------------------------------------------
-- Entry lifecycle
--------------------------------------------------------------------------

local function deactivateEntry(entry: RemoteVehicleEntry): ()
	if not entry.isActive then
		return
	end
	entry.isActive = false
	destroySoundController(entry)
	if entry.destroyConnection ~= nil then
		entry.destroyConnection:Disconnect()
		entry.destroyConnection = nil
	end
	for _, charEntry in pairs(entry.characterEntries) do
		deactivateCharacter(charEntry)
	end
	table.clear(entry.characterEntries)
	restoreSource(entry)
	if entry.visualClone.Parent ~= nil then
		entry.visualClone:Destroy()
	end
end

local function cleanupWatcher(model: Model)
	local conns = activationWatchers[model]
	if conns ~= nil then
		for _, conn in ipairs(conns) do
			conn:Disconnect()
		end
		activationWatchers[model] = nil
	end
end

local function activateEntry(model: Model): RemoteVehicleEntry?
	local primaryPart = model.PrimaryPart
	if primaryPart == nil then
		return nil
	end

	local clone = model:Clone()
	clone.Name = model.Name .. "_RemoteVisual"
	if model.PrimaryPart ~= nil then
		local clonePrimary = clone:FindFirstChild(model.PrimaryPart.Name, true)
		if clonePrimary ~= nil and clonePrimary:IsA("BasePart") then
			clone.PrimaryPart = clonePrimary
		end
	end
	stripCloneForVisuals(clone)
	CollectionService:RemoveTag(clone, "VehicleEntity")
	clone.Parent = ensureVisualsFolder()

	local entry: RemoteVehicleEntry = {
		sourceModel = model,
		visualClone = clone,
		sourceTransparency = {},
		smoothedCFrame = primaryPart.CFrame,
		isActive = true,
		characterEntries = {},
		soundController = nil,
		destroyConnection = nil,
	}
	hideSource(model, entry)

	-- Track any currently seated characters
	local occupants = findSeatedCharacters(model)
	for _, character in ipairs(occupants) do
		local charEntry = activateCharacter(character)
		if charEntry ~= nil then
			entry.characterEntries[character] = charEntry
		end
	end

	-- Start sounds if someone is already in the vehicle
	if #occupants > 0 then
		createSoundController(entry)
	end

	-- Watch for source model destruction
	entry.destroyConnection = model.Destroying:Connect(function()
		if trackedVehicles[model] ~= nil then
			deactivateEntry(entry)
			trackedVehicles[model] = nil
		end
		cleanupWatcher(model)
	end)

	return entry
end

--------------------------------------------------------------------------
-- Vehicle tracking
--------------------------------------------------------------------------

local function tryActivate(model: Model): boolean
	if model == localVehicleModel then
		return false
	end
	if trackedVehicles[model] ~= nil then
		return true
	end
	local entry = activateEntry(model)
	if entry ~= nil then
		trackedVehicles[model] = entry
		return true
	end
	return false
end

local function onVehicleAdded(instance: Instance)
	if not instance:IsA("Model") then
		return
	end
	local model = instance :: Model
	if model == localVehicleModel then
		return
	end
	if trackedVehicles[model] ~= nil then
		return
	end
	if activationWatchers[model] ~= nil then
		return
	end

	if tryActivate(model) then
		return
	end

	-- Model not ready yet — watch multiple signals for when it becomes ready
	local watchers: { RBXScriptConnection } = {}
	activationWatchers[model] = watchers

	local function onReady()
		if tryActivate(model) then
			cleanupWatcher(model)
		end
	end

	table.insert(watchers, model:GetAttributeChangedSignal("VehicleSpeed"):Connect(onReady))
	table.insert(watchers, model.ChildAdded:Connect(onReady))
	task.defer(onReady)
end

local function onVehicleRemoved(instance: Instance)
	if not instance:IsA("Model") then
		return
	end
	local model = instance :: Model
	cleanupWatcher(model)
	local entry = trackedVehicles[model]
	if entry ~= nil then
		deactivateEntry(entry)
		trackedVehicles[model] = nil
	end
end

local function stepAll(dt: number)
	local clampedDt = math.clamp(dt, 1 / 240, 1 / 20)
	local alpha = 1 - math.exp(-SMOOTHING_ALPHA * clampedDt)

	for model, entry in pairs(trackedVehicles) do
		if not entry.isActive then
			continue
		end
		if model.Parent == nil then
			deactivateEntry(entry)
			trackedVehicles[model] = nil
			continue
		end
		if model == localVehicleModel then
			deactivateEntry(entry)
			trackedVehicles[model] = nil
			continue
		end

		local sourcePrimary = model.PrimaryPart
		if sourcePrimary == nil then
			continue
		end

		local sourceCFrame = sourcePrimary.CFrame
		local posDelta = (entry.smoothedCFrame.Position - sourceCFrame.Position).Magnitude
		if posDelta > MAX_SNAP_DISTANCE then
			entry.smoothedCFrame = sourceCFrame
		else
			entry.smoothedCFrame = entry.smoothedCFrame:Lerp(sourceCFrame, alpha)
		end
		entry.visualClone:PivotTo(entry.smoothedCFrame)

		-- Update character tracking: detect occupant changes
		local currentOccupants = findSeatedCharacters(model)
		local occupied = #currentOccupants > 0

		-- Sound controller: create when occupied, destroy when empty
		if occupied and entry.soundController == nil then
			createSoundController(entry)
		elseif not occupied and entry.soundController ~= nil then
			destroySoundController(entry)
		end

		-- Update sound controller every frame
		if entry.soundController ~= nil then
			entry.soundController:update(dt)
		end

		local currentSet: { [Model]: boolean } = {}
		for _, character in ipairs(currentOccupants) do
			currentSet[character] = true
			if entry.characterEntries[character] == nil then
				local charEntry = activateCharacter(character)
				if charEntry ~= nil then
					entry.characterEntries[character] = charEntry
				end
			end
		end
		for character, charEntry in pairs(entry.characterEntries) do
			if not currentSet[character] or character.Parent == nil then
				deactivateCharacter(charEntry)
				entry.characterEntries[character] = nil
			end
		end

		-- Position character visuals to follow smoothed vehicle
		local cframeDelta = entry.smoothedCFrame * sourceCFrame:Inverse()
		for _, charEntry in pairs(entry.characterEntries) do
			hideCharacter(charEntry)
			for _, pair in ipairs(charEntry.partPairs) do
				if pair.source.Parent ~= nil and pair.visual.Parent ~= nil then
					pair.visual.CFrame = cframeDelta * pair.source.CFrame
				end
			end
		end
	end
end

function RemoteVehicleSmoother.setLocalVehicle(model: Model?): ()
	local previousLocal = localVehicleModel
	localVehicleModel = model

	if model ~= nil then
		local entry = trackedVehicles[model]
		if entry ~= nil then
			deactivateEntry(entry)
			trackedVehicles[model] = nil
		end
	end

	-- Re-track the previous local vehicle as remote now that we've exited it
	if previousLocal ~= nil and previousLocal ~= model and previousLocal.Parent ~= nil then
		if CollectionService:HasTag(previousLocal, "VehicleEntity") and trackedVehicles[previousLocal] == nil then
			local entry = activateEntry(previousLocal)
			if entry ~= nil then
				trackedVehicles[previousLocal] = entry
			end
		end
	end
end

function RemoteVehicleSmoother.init(): ()
	for _, instance in ipairs(CollectionService:GetTagged("VehicleEntity")) do
		onVehicleAdded(instance)
	end

	if addedConnection == nil then
		addedConnection = CollectionService:GetInstanceAddedSignal("VehicleEntity"):Connect(onVehicleAdded)
	end
	if removedConnection == nil then
		removedConnection = CollectionService:GetInstanceRemovedSignal("VehicleEntity"):Connect(onVehicleRemoved)
	end
	if renderConnection == nil then
		renderConnection = RunService.RenderStepped:Connect(stepAll)
	end
end

return RemoteVehicleSmoother
