--!strict

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local sharedRoot = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatConfig = require(sharedRoot:WaitForChild("CombatConfig"))

local clientRoot = Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("CombatFramework")
local SoundProfileLoader = require(clientRoot:WaitForChild("Vehicles"):WaitForChild("SoundProfiles"):WaitForChild("SoundProfileLoader"))
local SoundProfileTypes = require(clientRoot:WaitForChild("Vehicles"):WaitForChild("SoundProfiles"):WaitForChild("SoundProfileTypes"))
local WalkerIK = require(clientRoot:WaitForChild("Vehicles"):WaitForChild("WalkerIK"))

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
	watchConnection: RBXScriptConnection?,
	dirty: boolean,
}

type WalkerLegParts = {
	leftStrut1: BasePart?,
	leftStrut2: BasePart?,
	leftUpper: BasePart?,
	leftLower: BasePart?,
	leftFoot: BasePart?,
	rightStrut1: BasePart?,
	rightStrut2: BasePart?,
	rightUpper: BasePart?,
	rightLower: BasePart?,
	rightFoot: BasePart?,
}

type RemoteVehicleEntry = {
	sourceModel: Model,
	visualClone: Model,
	sourceTransparency: { [BasePart]: number },
	smoothedCFrame: CFrame,
	isActive: boolean,
	characterEntries: { [Model]: RemoteCharacterEntry },
	soundController: SoundProfileTypes.ProfileController?,
	destroyConnection: RBXScriptConnection?,
	-- Walker-specific (nil for speeders)
	isWalker: boolean,
	walkerIKState: WalkerIK.WalkerIKState?,
	walkerConfig: any?,
	walkerLegParts: WalkerLegParts?,
	sourceLegsFolder: Folder?,
	ikRayParams: RaycastParams?,
	cloneHeadPart: BasePart?,
	headBaseOffset: CFrame?,
	cloneHeadFollowerOffsets: { { part: BasePart, offset: CFrame } },
	prevSmoothedPos: Vector3?,
	walkerIdlePoseCount: number,
	walkerIdlePoseTime: number,
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

local function hasAnyOccupant(model: Model): boolean
	for _, descendant in ipairs(model:GetDescendants()) do
		local occupant: Humanoid? = nil
		if descendant:IsA("VehicleSeat") then
			occupant = (descendant :: VehicleSeat).Occupant
		elseif descendant:IsA("Seat") then
			occupant = (descendant :: Seat).Occupant
		end
		if occupant ~= nil then
			return true
		end
	end
	return false
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

	if clone == nil then
		return nil
	end

	clone.Name = character.Name .. "_RemoteCharVisual"
	stripCloneForVisuals(clone)
	clone.Parent = ensureVisualsFolder()

	local charEntry: RemoteCharacterEntry = {
		sourceCharacter = character,
		visualClone = clone,
		sourceTransparency = {},
		partPairs = buildPartPairs(character, clone),
		watchConnection = nil,
		dirty = false,
	}
	hideCharacter(charEntry)

	-- Watch for late-loading body parts / accessories
	charEntry.watchConnection = character.DescendantAdded:Connect(function(desc)
		if desc:IsA("BasePart") then
			charEntry.dirty = true
		end
	end)

	return charEntry
end

local function deactivateCharacter(charEntry: RemoteCharacterEntry)
	if charEntry.watchConnection ~= nil then
		charEntry.watchConnection:Disconnect()
		charEntry.watchConnection = nil
	end
	restoreCharacter(charEntry)
	-- Safety sweep: reset any parts that were missed (late-loaded accessories, etc.)
	if charEntry.sourceCharacter.Parent ~= nil then
		for _, descendant in ipairs(charEntry.sourceCharacter:GetDescendants()) do
			if descendant:IsA("BasePart") and descendant.LocalTransparencyModifier > 0.99 then
				descendant.LocalTransparencyModifier = 0
			end
		end
	end
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
	entry.soundController = SoundProfileLoader.createController(entry.sourceModel, clonePrimary, ms, false)
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
	-- Walker cleanup: clear IK state (source legs stay as-is, server handles positioning)
	if entry.isWalker then
		entry.walkerIKState = nil
		entry.walkerLegParts = nil
		entry.walkerConfig = nil
		entry.ikRayParams = nil
		entry.cloneHeadPart = nil
		entry.headBaseOffset = nil
		table.clear(entry.cloneHeadFollowerOffsets)
		entry.prevSmoothedPos = nil
		entry.sourceLegsFolder = nil
	end
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

	local prevArchivable = model.Archivable
	model.Archivable = true
	local clone = model:Clone()
	model.Archivable = prevArchivable

	if clone == nil then
		return nil
	end

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
		isWalker = false,
		walkerIKState = nil,
		walkerConfig = nil,
		walkerLegParts = nil,
		sourceLegsFolder = nil,
		ikRayParams = nil,
		cloneHeadPart = nil,
		headBaseOffset = nil,
		cloneHeadFollowerOffsets = {},
		prevSmoothedPos = nil,
		walkerIdlePoseCount = 0, walkerIdlePoseTime = 0,
	}
	hideSource(model, entry)

	-- Walker IK setup (detect walker_biped, find legs in Workspace, prepare IK state)
	local vehicleCategory = model:GetAttribute("VehicleCategory")
	if type(vehicleCategory) == "string" then
		local vehConfig = (CombatConfig.Vehicles :: any)[vehicleCategory]
		if type(vehConfig) == "table" and vehConfig.vehicleClass == "walker_biped" then
			entry.isWalker = true
			entry.walkerConfig = vehConfig
			-- IK state created on-demand when occupied (not at activation)

			-- Find source legs folder (server reparents legs to Workspace/<name>_Legs)
			local sourceLegsFolder = Workspace:FindFirstChild(model.Name .. "_Legs")
			entry.sourceLegsFolder = sourceLegsFolder

			if sourceLegsFolder ~= nil then
				local leftLegFolder = sourceLegsFolder:FindFirstChild("LeftLeg")
				local rightLegFolder = sourceLegsFolder:FindFirstChild("RightLeg")
				if leftLegFolder ~= nil and rightLegFolder ~= nil then
					entry.walkerLegParts = {
						leftStrut1 = leftLegFolder:FindFirstChild("Strut1") :: BasePart?,
						leftStrut2 = leftLegFolder:FindFirstChild("HipStrut") :: BasePart?,
						leftUpper = leftLegFolder:FindFirstChild("UpperLeg") :: BasePart?,
						leftLower = leftLegFolder:FindFirstChild("LowerLeg") :: BasePart?,
						leftFoot = leftLegFolder:FindFirstChild("Foot") :: BasePart?,
						rightStrut1 = rightLegFolder:FindFirstChild("Strut1") :: BasePart?,
						rightStrut2 = rightLegFolder:FindFirstChild("HipStrut") :: BasePart?,
						rightUpper = rightLegFolder:FindFirstChild("UpperLeg") :: BasePart?,
						rightLower = rightLegFolder:FindFirstChild("LowerLeg") :: BasePart?,
						rightFoot = rightLegFolder:FindFirstChild("Foot") :: BasePart?,
					}
				end
			end

			-- IK raycast filter (exclude source model, clone, legs folder, local character)
			local ikRayParams = RaycastParams.new()
			ikRayParams.FilterType = Enum.RaycastFilterType.Exclude
			local filterList: { Instance } = { model, clone }
			if sourceLegsFolder ~= nil then
				table.insert(filterList, sourceLegsFolder)
			end
			local localChar = LOCAL_PLAYER.Character
			if localChar ~= nil then
				table.insert(filterList, localChar)
			end
			ikRayParams.FilterDescendantsInstances = filterList
			entry.ikRayParams = ikRayParams

			-- Find clone head part for head rotation
			for _, desc in ipairs(clone:GetDescendants()) do
				if desc:IsA("BasePart") and CollectionService:HasTag(desc, "WalkerHead") then
					entry.cloneHeadPart = desc :: BasePart
					local clonePrimary = clone.PrimaryPart
					if clonePrimary ~= nil then
						entry.headBaseOffset = clonePrimary.CFrame:Inverse() * desc.CFrame
						for _, headDescendant in ipairs((desc :: BasePart):GetDescendants()) do
							if headDescendant:IsA("BasePart") then
								local part = headDescendant :: BasePart
								local offset = (desc :: BasePart).CFrame:Inverse() * part.CFrame
								table.insert(entry.cloneHeadFollowerOffsets, { part = part, offset = offset })
							end
						end
					end
					break
				end
			end
		end
	end

	-- Track any currently seated characters
	local occupants = findSeatedCharacters(model)
	for _, character in ipairs(occupants) do
		local charEntry = activateCharacter(character)
		if charEntry ~= nil then
			entry.characterEntries[character] = charEntry
		end
	end

	-- Start sounds if anyone is in the vehicle (including local player as gunner)
	if hasAnyOccupant(model) then
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

		-- Deactivate visual clone when entity is destroyed (HealthManager hides parts)
		if sourcePrimary.Transparency >= 0.99 then
			deactivateEntry(entry)
			trackedVehicles[model] = nil
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

		local anyOccupied = hasAnyOccupant(model)

		-- Walker IK
		if entry.isWalker and entry.walkerLegParts ~= nil and entry.ikRayParams ~= nil and entry.walkerConfig ~= nil then
			-- Two-shot idle pose: once on exit, again 3s later for final settle
			local needsIdlePose = false
			if not anyOccupied then
				if entry.walkerIdlePoseCount == 0 then
					needsIdlePose = true
				elseif entry.walkerIdlePoseCount == 1 and (tick() - entry.walkerIdlePoseTime) >= 3 then
					needsIdlePose = true
				end
			end
			local runIK = anyOccupied or needsIdlePose

			if runIK then
				-- Fresh IK state when idle-posing (no residual sway/lean from pilot)
				if entry.walkerIKState == nil or needsIdlePose then
					entry.walkerIKState = WalkerIK.createState()
					entry.prevSmoothedPos = entry.smoothedCFrame.Position
				end

				local currentPos = entry.smoothedCFrame.Position
				local prevPos = entry.prevSmoothedPos or currentPos
				local velocity = if clampedDt > 0.001 then (currentPos - prevPos) / clampedDt else Vector3.zero
				velocity = Vector3.new(velocity.X, 0, velocity.Z)
				local wConfig = entry.walkerConfig :: any
				local maxVel = (if wConfig then wConfig.maxSpeed or 25 else 25) * 1.5
				if velocity.Magnitude > maxVel then
					velocity = velocity.Unit * maxVel
				end
				entry.prevSmoothedPos = currentPos

				local moveHeading = model:GetAttribute("VehicleHeading")
				if type(moveHeading) ~= "number" then moveHeading = 0 end
				local ikBodyCFrame = CFrame.new(currentPos) * CFrame.Angles(0, moveHeading :: number, 0)

				local gaitPhaseAttr = model:GetAttribute("WalkerGaitPhase") or 0
				local gaitSideAttr = model:GetAttribute("WalkerGaitSide") or "left"
				local gaitActiveAttr = model:GetAttribute("WalkerGaitActive") or false
				local sprintFracAttr = model:GetAttribute("WalkerSprintFrac") or 0

				local modBodyCF, lStrut1CF, lStrut2CF, lUpperCF, lLowerCF, lFootCF, rStrut1CF, rStrut2CF, rUpperCF, rLowerCF, rFootCF =
					WalkerIK.update(entry.walkerIKState, ikBodyCFrame, velocity, wConfig, clampedDt, entry.ikRayParams, gaitPhaseAttr, gaitSideAttr, gaitActiveAttr, sprintFracAttr, true)

				local legs = entry.walkerLegParts :: WalkerLegParts
				if legs.leftStrut1 ~= nil then legs.leftStrut1.CFrame = lStrut1CF end
				if legs.leftStrut2 ~= nil then legs.leftStrut2.CFrame = lStrut2CF end
				if legs.leftUpper ~= nil then legs.leftUpper.CFrame = lUpperCF end
				if legs.leftLower ~= nil then legs.leftLower.CFrame = lLowerCF end
				if legs.leftFoot ~= nil then legs.leftFoot.CFrame = lFootCF end
				if legs.rightStrut1 ~= nil then legs.rightStrut1.CFrame = rStrut1CF end
				if legs.rightStrut2 ~= nil then legs.rightStrut2.CFrame = rStrut2CF end
				if legs.rightUpper ~= nil then legs.rightUpper.CFrame = rUpperCF end
				if legs.rightLower ~= nil then legs.rightLower.CFrame = rLowerCF end
				if legs.rightFoot ~= nil then legs.rightFoot.CFrame = rFootCF end

				local secondaryOff = ikBodyCFrame:Inverse() * modBodyCF
				local _, tiltPitch, tiltRoll = secondaryOff:ToEulerAnglesYXZ()
				local modCockpitCF = entry.smoothedCFrame * CFrame.new(secondaryOff.Position) * CFrame.Angles(tiltPitch, 0, tiltRoll)
				entry.visualClone:PivotTo(modCockpitCF)
				if entry.cloneHeadPart ~= nil and entry.headBaseOffset ~= nil then
					local headBase = entry.smoothedCFrame * CFrame.new(secondaryOff.Position)
					local nextHeadCFrame = headBase * (entry.headBaseOffset :: CFrame)
					entry.cloneHeadPart.CFrame = nextHeadCFrame
					for _, follower in ipairs(entry.cloneHeadFollowerOffsets) do
						if follower.part.Parent ~= nil then
							follower.part.CFrame = nextHeadCFrame * follower.offset
						end
					end
				end

				-- Track idle pose snapshots
				if needsIdlePose then
					entry.walkerIdlePoseCount += 1
					entry.walkerIdlePoseTime = tick()
				end
			end

			-- Reset when someone gets in so idle pose reruns on next exit
			if anyOccupied then
				entry.walkerIdlePoseCount = 0
				entry.walkerIdlePoseTime = 0
				entry.walkerIKState = nil
			end
		end

		-- Update character tracking: detect occupant changes
		local currentOccupants = findSeatedCharacters(model)

		-- Sound controller: create when ANY seat occupied (incl. local player as gunner), destroy when empty
		if anyOccupied and entry.soundController == nil then
			createSoundController(entry)
		elseif not anyOccupied and entry.soundController ~= nil then
			destroySoundController(entry)
		end

		-- Update sound controller every frame
		if entry.soundController ~= nil then
			local speedAttr = model:GetAttribute("VehicleSpeed")
			local speed: number = if type(speedAttr) == "number" then speedAttr else 0
			local ms = getMaxSpeedForModel(model)
			local hullHP = model:GetAttribute("HullHP")
			local maxHP = model:GetAttribute("MaxHullHP")
			local hpFrac: number = 1
			if type(hullHP) == "number" and type(maxHP) == "number" and maxHP > 0 then
				hpFrac = math.clamp(hullHP / maxHP, 0, 1)
			end
			local frameState: SoundProfileTypes.VehicleFrameState = {
				speed = speed,
				maxSpeed = ms,
				speedFraction = if ms > 0 then math.clamp(speed / ms, 0, 1) else 0,
				hpFraction = hpFrac,
				isBoosting = model:GetAttribute("VehicleBoosting") == true,
				isGrounded = true,
				throttle = 0,
				steerInput = 0,
				isLocal = false,
				dt = dt,
			}
			entry.soundController:update(dt, frameState)
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
		local toRebuild: { Model }? = nil
		for character, charEntry in pairs(entry.characterEntries) do
			if not currentSet[character] or character.Parent == nil then
				deactivateCharacter(charEntry)
				entry.characterEntries[character] = nil
			elseif charEntry.dirty then
				if toRebuild == nil then toRebuild = {} end
				table.insert(toRebuild, character)
			end
		end

		-- Rebuild character clones that gained new parts (late-loaded accessories)
		if toRebuild ~= nil then
			for _, character in ipairs(toRebuild) do
				local oldEntry = entry.characterEntries[character]
				if oldEntry ~= nil then
					deactivateCharacter(oldEntry)
					local newEntry = activateCharacter(character)
					if newEntry ~= nil then
						entry.characterEntries[character] = newEntry
					else
						entry.characterEntries[character] = nil
					end
				end
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

function RemoteVehicleSmoother.getVisualClone(sourceModel: Model): Model?
	local entry = trackedVehicles[sourceModel]
	if entry == nil or not entry.isActive then
		return nil
	end
	return entry.visualClone
end

return RemoteVehicleSmoother
