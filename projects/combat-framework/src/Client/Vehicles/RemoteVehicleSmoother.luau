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
local WALKER_LEG_DISCOVERY_INTERVAL = 0.2
local WALKER_OCCUPIED_SMOOTHING_ALPHA = 22
local WALKER_OCCUPIED_MAX_SNAP_DISTANCE = 20
local WALKER_HEAD_TURN_START_THRESHOLD = 0.25
local WALKER_HEAD_TURN_STOP_THRESHOLD = 0.08
local WALKER_HEAD_STOP_COOLDOWN = 1.5
local WALKER_SETTLE_STEP_COUNT = 2
local WALKER_REMOTE_HEAD_LAG_RATE = 3.0

type PartPair = {
	source: BasePart,
	visual: BasePart,
}

type RemoteCharacterEntry = {
	sourceCharacter: Model,
	visualClone: Model,
	sourceTransparency: { [BasePart]: number },
	partPairs: { PartPair },
	rootOffsets: { { visual: BasePart, offset: CFrame } },
	userId: number?,
	seatPath: { string }?,
	seatToRoot: CFrame?,
	watchConnection: RBXScriptConnection?,
	dirty: boolean,
	sourceHidden: boolean,
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

type WalkerMountFollower = {
	part: BasePart,
	offset: CFrame,
}

type WalkerWeaponMountPair = {
	source: BasePart,
	clone: BasePart,
	followers: { WalkerMountFollower },
	smoothedRelativeFrame: CFrame?,
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
	sourceLegsFolder: Instance?,
	ikRayParams: RaycastParams?,
	sourceHeadPart: BasePart?,
	cloneHeadPart: BasePart?,
	headBaseOffset: CFrame?,
	cloneHeadFollowerOffsets: { { part: BasePart, offset: CFrame } },
	walkerWeaponMountPairs: { WalkerWeaponMountPair },
	walkerSmoothedHeadRotation: CFrame?,
	prevSmoothedPos: Vector3?,
	lastSourcePos: Vector3?,
	walkerIdlePoseCount: number,
	walkerIdlePoseTime: number,
	walkerWasOccupied: boolean,
	walkerPreviousGaitActive: boolean,
	walkerPreviousGaitSide: string,
	walkerSettleStepsRemaining: number,
	walkerPreviousAimYaw: number?,
	walkerHeadTurning: boolean,
	walkerLastHeadStopTick: number,
	walkerPreviousHpFraction: number,
	walkerPreviousFootLiftSeq: number?,
	walkerPreviousFootPlantSeq: number?,
	lastSourcePrimaryCFrame: CFrame?,
	sourceStallTime: number,
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
		if descendant:IsA("ProximityPrompt") then
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

local function isWeaponMountPart(instance: Instance): boolean
	return instance:IsA("BasePart") and CollectionService:HasTag(instance, "WeaponMount")
end

local function hasWeaponMountAncestor(instance: Instance): boolean
	local current: Instance? = instance.Parent
	while current ~= nil do
		if isWeaponMountPart(current) then
			return true
		end
		current = current.Parent
	end
	return false
end

local function buildWalkerWeaponMountPairs(sourceModel: Model, cloneModel: Model): { WalkerWeaponMountPair }
	local pairs: { WalkerWeaponMountPair } = {}
	for _, descendant in ipairs(sourceModel:GetDescendants()) do
		if not isWeaponMountPart(descendant) then
			continue
		end
		local sourceMount = descendant :: BasePart
		local path = getRelativePath(sourceModel, sourceMount)
		local cloneMatch = findByPath(cloneModel, path)
		if cloneMatch == nil or not cloneMatch:IsA("BasePart") then
			continue
		end
		local cloneMount = cloneMatch :: BasePart
		local followers: { WalkerMountFollower } = {}
		for _, cloneDesc in ipairs(cloneMount:GetDescendants()) do
			if cloneDesc:IsA("BasePart") and not isWeaponMountPart(cloneDesc) then
				local followerPart = cloneDesc :: BasePart
				local offset = cloneMount.CFrame:Inverse() * followerPart.CFrame
				table.insert(followers, { part = followerPart, offset = offset })
			end
		end
		table.insert(pairs, {
			source = sourceMount,
			clone = cloneMount,
			followers = followers,
			smoothedRelativeFrame = nil,
		})
	end
	return pairs
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

local function getWalkerDriverCharacter(model: Model): Model?
	local vehicleCategory = model:GetAttribute("VehicleCategory")
	if type(vehicleCategory) ~= "string" then
		vehicleCategory = model:GetAttribute("VehicleConfigId")
	end
	if vehicleCategory ~= "walker_biped" then
		return nil
	end

	local rawUserId = model:GetAttribute("WalkerDriverUserId")
	if type(rawUserId) ~= "number" then
		return nil
	end

	local userId = math.floor(rawUserId + 0.5)
	if userId <= 0 then
		return nil
	end

	local player = Players:GetPlayerByUserId(userId)
	if player == nil then
		return nil
	end
	local character = player.Character
	if character ~= nil and character:IsA("Model") then
		return character
	end
	return nil
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

	local walkerDriver = getWalkerDriverCharacter(model)
	if walkerDriver ~= nil then
		return true
	end

	return false
end

local function findSeatedCharacters(model: Model): { Model }
	local characters: { Model } = {}
	local seenCharacters: { [Model]: boolean } = {}
	for _, descendant in ipairs(model:GetDescendants()) do
		local occupant: Humanoid? = nil
		if descendant:IsA("VehicleSeat") then
			occupant = (descendant :: VehicleSeat).Occupant
		elseif descendant:IsA("Seat") then
			occupant = (descendant :: Seat).Occupant
		end
		if occupant ~= nil then
			local character = occupant.Parent
			if
				character ~= nil
				and character:IsA("Model")
				and character ~= LOCAL_PLAYER.Character
				and not seenCharacters[character]
			then
				seenCharacters[character] = true
				table.insert(characters, character)
			end
		end
	end

	local walkerDriver = getWalkerDriverCharacter(model)
	if walkerDriver ~= nil and walkerDriver ~= LOCAL_PLAYER.Character and not seenCharacters[walkerDriver] then
		seenCharacters[walkerDriver] = true
		table.insert(characters, walkerDriver)
	end

	return characters
end

local function findDriverSeatPart(model: Model): BasePart?
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("Seat") or descendant:IsA("VehicleSeat") then
			if CollectionService:HasTag(descendant, "DriverSeat") then
				return descendant :: BasePart
			end
		end
	end
	local namedSeat = model:FindFirstChild("DriverSeat", true)
	if namedSeat ~= nil and (namedSeat:IsA("Seat") or namedSeat:IsA("VehicleSeat")) then
		return namedSeat :: BasePart
	end
	return nil
end

local function tryHydrateWalkerSeatBinding(
	charEntry: RemoteCharacterEntry,
	sourceVehicleModel: Model,
	walkerDriverUserId: number?
)
	if walkerDriverUserId == nil or charEntry.userId == nil or charEntry.userId ~= walkerDriverUserId then
		return
	end
	if charEntry.seatPath ~= nil and charEntry.seatToRoot ~= nil then
		return
	end

	local seatPart = findDriverSeatPart(sourceVehicleModel)
	if seatPart == nil then
		return
	end

	if charEntry.seatPath == nil then
		charEntry.seatPath = getRelativePath(sourceVehicleModel, seatPart)
	end

	if charEntry.seatToRoot == nil then
		local sourceRootInstance = charEntry.sourceCharacter:FindFirstChild("HumanoidRootPart")
		if sourceRootInstance ~= nil and sourceRootInstance:IsA("BasePart") then
			charEntry.seatToRoot = seatPart.CFrame:Inverse() * (sourceRootInstance :: BasePart).CFrame
		end
	end
end

local function hideCharacter(charEntry: RemoteCharacterEntry)
	if charEntry.sourceHidden then
		return
	end
	for _, descendant in ipairs(charEntry.sourceCharacter:GetDescendants()) do
		if descendant:IsA("BasePart") then
			local part = descendant
			if charEntry.sourceTransparency[part] == nil then
				charEntry.sourceTransparency[part] = part.LocalTransparencyModifier
			end
			part.LocalTransparencyModifier = 1
		end
	end
	charEntry.sourceHidden = true
end

local function restoreCharacter(charEntry: RemoteCharacterEntry)
	if not charEntry.sourceHidden then
		return
	end
	for part, transparency in pairs(charEntry.sourceTransparency) do
		if part.Parent ~= nil then
			part.LocalTransparencyModifier = transparency
		end
	end
	table.clear(charEntry.sourceTransparency)
	charEntry.sourceHidden = false
end

local function activateCharacter(character: Model, sourceVehicleModel: Model): RemoteCharacterEntry?
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

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	local sourceRoot = if rootPart ~= nil and rootPart:IsA("BasePart") then rootPart :: BasePart else nil
	local seatPath: { string }? = nil
	local seatToRoot: CFrame? = nil
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid ~= nil then
		local seatPart = humanoid.SeatPart
		if seatPart ~= nil and seatPart:IsDescendantOf(sourceVehicleModel) then
			seatPath = getRelativePath(sourceVehicleModel, seatPart)
			if sourceRoot ~= nil then
				seatToRoot = seatPart.CFrame:Inverse() * sourceRoot.CFrame
			end
		end
	end

	local userId: number? = nil
	local player = Players:GetPlayerFromCharacter(character)
	if player ~= nil then
		userId = player.UserId
	end

	local walkerDriverUserIdRaw = sourceVehicleModel:GetAttribute("WalkerDriverUserId")
	local walkerDriverUserId = if type(walkerDriverUserIdRaw) == "number"
		then math.floor(walkerDriverUserIdRaw + 0.5)
		else nil
	if (seatPath == nil or seatToRoot == nil) and userId ~= nil and walkerDriverUserId ~= nil and userId == walkerDriverUserId then
		local driverSeatPart = findDriverSeatPart(sourceVehicleModel)
		if driverSeatPart ~= nil then
			if seatPath == nil then
				seatPath = getRelativePath(sourceVehicleModel, driverSeatPart)
			end
			if seatToRoot == nil and sourceRoot ~= nil then
				seatToRoot = driverSeatPart.CFrame:Inverse() * sourceRoot.CFrame
			end
		end
	end

	local charEntry: RemoteCharacterEntry = {
		sourceCharacter = character,
		visualClone = clone,
		sourceTransparency = {},
		partPairs = buildPartPairs(character, clone),
		rootOffsets = {},
		userId = userId,
		seatPath = seatPath,
		seatToRoot = seatToRoot,
		watchConnection = nil,
		dirty = false,
		sourceHidden = false,
	}
	if sourceRoot ~= nil then
		for _, pair in ipairs(charEntry.partPairs) do
			table.insert(charEntry.rootOffsets, {
				visual = pair.visual,
				offset = sourceRoot.CFrame:Inverse() * pair.source.CFrame,
			})
		end
	end
	if #charEntry.partPairs > 0 then
		hideCharacter(charEntry)
	end

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

local resetWalkerAudioState: (entry: RemoteVehicleEntry) -> ()
local updateWalkerSoundEvents: (entry: RemoteVehicleEntry, dt: number) -> ()

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
	if entry.soundController ~= nil then
		return
	end
	local clonePrimary = entry.visualClone.PrimaryPart
	if clonePrimary == nil then
		return
	end
	local ms = getMaxSpeedForModel(entry.sourceModel)
	entry.soundController = SoundProfileLoader.createController(entry.sourceModel, clonePrimary, ms, false)
	if entry.isWalker then
		resetWalkerAudioState(entry)
	end
end

local function destroySoundController(entry: RemoteVehicleEntry)
	if entry.soundController ~= nil then
		if entry.isWalker and entry.walkerHeadTurning then
			entry.soundController:onEvent("head_loop_stop")
		end
		entry.soundController:destroy()
		entry.soundController = nil
	end
	if entry.isWalker then
		entry.walkerHeadTurning = false
		entry.walkerPreviousAimYaw = nil
	end
end

local function getEntryEntityId(entry: RemoteVehicleEntry): string
	local raw = entry.sourceModel:GetAttribute("EntityId")
	if type(raw) == "string" and raw ~= "" then
		return raw
	end
	return entry.sourceModel.Name
end

resetWalkerAudioState = function(entry: RemoteVehicleEntry)
	entry.walkerPreviousGaitActive = false
	local gaitSideAttr = entry.sourceModel:GetAttribute("WalkerGaitSide")
	entry.walkerPreviousGaitSide = if type(gaitSideAttr) == "string" then gaitSideAttr else "left"
	entry.walkerSettleStepsRemaining = 0
	entry.walkerPreviousAimYaw = nil
	entry.walkerHeadTurning = false
	entry.walkerLastHeadStopTick = 0
	local liftSeqAttr = entry.sourceModel:GetAttribute("WalkerAudioFootLiftSeq")
	local plantSeqAttr = entry.sourceModel:GetAttribute("WalkerAudioFootPlantSeq")
	entry.walkerPreviousFootLiftSeq = if type(liftSeqAttr) == "number" then math.max(0, math.floor(liftSeqAttr + 0.5)) else nil
	entry.walkerPreviousFootPlantSeq = if type(plantSeqAttr) == "number" then math.max(0, math.floor(plantSeqAttr + 0.5)) else nil
	local hullHP = entry.sourceModel:GetAttribute("HullHP")
	local maxHP = entry.sourceModel:GetAttribute("MaxHullHP")
	if type(hullHP) == "number" and type(maxHP) == "number" and maxHP > 0 then
		entry.walkerPreviousHpFraction = math.clamp(hullHP / maxHP, 0, 1)
	else
		entry.walkerPreviousHpFraction = 1
	end
end

updateWalkerSoundEvents = function(entry: RemoteVehicleEntry, dt: number)
	local controller = entry.soundController
	if controller == nil then
		return
	end

	local model = entry.sourceModel
	local gaitActive = model:GetAttribute("WalkerGaitActive") == true
	local liftSeqAttr = model:GetAttribute("WalkerAudioFootLiftSeq")
	local plantSeqAttr = model:GetAttribute("WalkerAudioFootPlantSeq")
	if type(liftSeqAttr) == "number" and type(plantSeqAttr) == "number" then
		local liftSeq = math.max(0, math.floor(liftSeqAttr + 0.5))
		local plantSeq = math.max(0, math.floor(plantSeqAttr + 0.5))
		if entry.walkerPreviousFootLiftSeq == nil then
			entry.walkerPreviousFootLiftSeq = liftSeq
		end
		if entry.walkerPreviousFootPlantSeq == nil then
			entry.walkerPreviousFootPlantSeq = plantSeq
		end
		local liftDelta = math.max(0, liftSeq - (entry.walkerPreviousFootLiftSeq :: number))
		local plantDelta = math.max(0, plantSeq - (entry.walkerPreviousFootPlantSeq :: number))
		if liftDelta > 0 then
			for _ = 1, math.min(liftDelta, 4) do
				controller:onEvent("foot_lift")
			end
		end
		if plantDelta > 0 then
			local plantEvent = if gaitActive then "foot_plant" else "settle_plant"
			for _ = 1, math.min(plantDelta, 4) do
				controller:onEvent(plantEvent)
			end
		end
		entry.walkerPreviousFootLiftSeq = liftSeq
		entry.walkerPreviousFootPlantSeq = plantSeq
	else
		-- Fallback for legacy walkers without audio sequence attrs.
		local gaitSideAttr = model:GetAttribute("WalkerGaitSide")
		local gaitSide = if type(gaitSideAttr) == "string" then gaitSideAttr else "left"
		if entry.walkerPreviousGaitActive and not gaitActive then
			entry.walkerSettleStepsRemaining = WALKER_SETTLE_STEP_COUNT
		end
		if gaitActive and entry.walkerPreviousGaitSide ~= gaitSide then
			controller:onEvent("foot_lift")
			if entry.walkerSettleStepsRemaining > 0 then
				entry.walkerSettleStepsRemaining -= 1
				controller:onEvent("settle_plant")
			else
				controller:onEvent("foot_plant")
			end
		end
		entry.walkerPreviousGaitActive = gaitActive
		entry.walkerPreviousGaitSide = gaitSide
	end

	local aimYawAttr = model:GetAttribute("WalkerAimYaw")
	if type(aimYawAttr) == "number" then
		local aimYaw = aimYawAttr
		local aimYawRate = 0
		if entry.walkerPreviousAimYaw ~= nil and dt > 0.001 then
			local delta = aimYaw - (entry.walkerPreviousAimYaw :: number)
			delta = ((delta + math.pi) % (math.pi * 2)) - math.pi
			aimYawRate = math.abs(delta / dt)
		end
		entry.walkerPreviousAimYaw = aimYaw
		if aimYawRate > WALKER_HEAD_TURN_START_THRESHOLD and not entry.walkerHeadTurning then
			entry.walkerHeadTurning = true
			controller:onEvent("head_turning")
		elseif aimYawRate <= WALKER_HEAD_TURN_STOP_THRESHOLD and entry.walkerHeadTurning then
			entry.walkerHeadTurning = false
			controller:onEvent("head_loop_stop")
			local now = tick()
			if (now - entry.walkerLastHeadStopTick) >= WALKER_HEAD_STOP_COOLDOWN then
				entry.walkerLastHeadStopTick = now
				controller:onEvent("head_stop")
			end
		end
	elseif entry.walkerHeadTurning then
		entry.walkerHeadTurning = false
		entry.walkerPreviousAimYaw = nil
		controller:onEvent("head_loop_stop")
	else
		entry.walkerPreviousAimYaw = nil
	end

	local hullHP = model:GetAttribute("HullHP")
	local maxHP = model:GetAttribute("MaxHullHP")
	if type(hullHP) == "number" and type(maxHP) == "number" and maxHP > 0 then
		local hpFraction = math.clamp(hullHP / maxHP, 0, 1)
		if hpFraction < entry.walkerPreviousHpFraction then
			controller:onEvent("damage_taken", {
				amount = (entry.walkerPreviousHpFraction - hpFraction) * maxHP,
				newHpFraction = hpFraction,
			})
		end
		entry.walkerPreviousHpFraction = hpFraction
	else
		entry.walkerPreviousHpFraction = 1
	end
end

local function findWalkerLegsFolder(model: Model): Instance?
	local entityId = model:GetAttribute("EntityId")
	if type(entityId) == "string" and entityId ~= "" then
		local byEntityId = Workspace:FindFirstChild(entityId .. "_Legs")
		if byEntityId ~= nil and (byEntityId:IsA("Folder") or byEntityId:IsA("Model")) then
			return byEntityId
		end
	end
	local byName = Workspace:FindFirstChild(model.Name .. "_Legs")
	if byName ~= nil and (byName:IsA("Folder") or byName:IsA("Model")) then
		return byName
	end
	return nil
end

local function parseWalkerLegParts(sourceLegsFolder: Instance): WalkerLegParts?
	local leftLegFolder = sourceLegsFolder:FindFirstChild("LeftLeg")
	local rightLegFolder = sourceLegsFolder:FindFirstChild("RightLeg")
	if leftLegFolder == nil or rightLegFolder == nil then
		return nil
	end

	return {
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

local function forceShowWalkerLegSourceParts(sourceLegsFolder: Instance?)
	if sourceLegsFolder == nil then
		return
	end
	for _, descendant in ipairs(sourceLegsFolder:GetDescendants()) do
		if descendant:IsA("BasePart") and descendant.LocalTransparencyModifier > 0 then
			descendant.LocalTransparencyModifier = 0
		end
	end
end

local function addLegFolderToRaycastFilter(entry: RemoteVehicleEntry, sourceLegsFolder: Instance)
	if entry.ikRayParams == nil then
		return
	end

	local existingFilter = entry.ikRayParams.FilterDescendantsInstances
	for _, instance in ipairs(existingFilter) do
		if instance == sourceLegsFolder then
			return
		end
	end

	local nextFilter: { Instance } = {}
	for _, instance in ipairs(existingFilter) do
		table.insert(nextFilter, instance)
	end
	table.insert(nextFilter, sourceLegsFolder)
	entry.ikRayParams.FilterDescendantsInstances = nextFilter
end

local function setWalkerLegFolder(entry: RemoteVehicleEntry, sourceLegsFolder: Instance): boolean
	local walkerLegParts = parseWalkerLegParts(sourceLegsFolder)
	if walkerLegParts == nil then
		return false
	end

	entry.sourceLegsFolder = sourceLegsFolder
	entry.walkerLegParts = walkerLegParts
	forceShowWalkerLegSourceParts(sourceLegsFolder)
	addLegFolderToRaycastFilter(entry, sourceLegsFolder)
	return true
end

local function scheduleWalkerLegDiscovery(entry: RemoteVehicleEntry)
	task.spawn(function()
		while entry.isActive do
			task.wait(WALKER_LEG_DISCOVERY_INTERVAL)
			local found = findWalkerLegsFolder(entry.sourceModel)
			if found ~= nil then
				if setWalkerLegFolder(entry, found) then
					return
				end
			end
		end
	end)
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
		entry.walkerSmoothedHeadRotation = nil
		table.clear(entry.cloneHeadFollowerOffsets)
		table.clear(entry.walkerWeaponMountPairs)
		entry.prevSmoothedPos = nil
		entry.lastSourcePos = nil
		entry.sourceHeadPart = nil
		entry.sourceLegsFolder = nil
		entry.walkerPreviousGaitActive = false
		entry.walkerPreviousGaitSide = "left"
		entry.walkerSettleStepsRemaining = 0
		entry.walkerPreviousAimYaw = nil
		entry.walkerHeadTurning = false
		entry.walkerLastHeadStopTick = 0
		entry.walkerPreviousHpFraction = 1
		entry.walkerPreviousFootLiftSeq = nil
		entry.walkerPreviousFootPlantSeq = nil
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
		sourceHeadPart = nil,
			cloneHeadPart = nil,
			headBaseOffset = nil,
			cloneHeadFollowerOffsets = {},
			walkerWeaponMountPairs = {},
			walkerSmoothedHeadRotation = nil,
		prevSmoothedPos = nil,
		lastSourcePos = nil,
		walkerIdlePoseCount = 0,
		walkerIdlePoseTime = 0,
		walkerWasOccupied = false,
		walkerPreviousGaitActive = false,
		walkerPreviousGaitSide = "left",
		walkerSettleStepsRemaining = 0,
		walkerPreviousAimYaw = nil,
		walkerHeadTurning = false,
		walkerLastHeadStopTick = 0,
		walkerPreviousHpFraction = 1,
		walkerPreviousFootLiftSeq = nil,
		walkerPreviousFootPlantSeq = nil,
		lastSourcePrimaryCFrame = nil,
		sourceStallTime = 0,
	}
	hideSource(model, entry)

	-- Walker IK setup (detect walker_biped, find legs in Workspace, prepare IK state)
	local vehicleCategory = model:GetAttribute("VehicleCategory")
	if type(vehicleCategory) == "string" then
		local vehConfig = (CombatConfig.Vehicles :: any)[vehicleCategory]
		if type(vehConfig) == "table" and vehConfig.vehicleClass == "fighter" then
			print(string.format(
				"[FIGHTER_REMOTE] model=%s using_physics_replication=true smoothing_alpha=%d",
				model.Name,
				SMOOTHING_ALPHA
			))
		elseif type(vehConfig) == "table" and vehConfig.vehicleClass == "walker_biped" then
			entry.isWalker = true
			entry.walkerConfig = vehConfig
			-- IK state created on-demand when occupied (not at activation)

			-- Find source legs folder (server reparents legs to Workspace/<name>_Legs)
				local sourceLegsFolder: Instance? = nil
				local sourceLegs = findWalkerLegsFolder(model)
				if sourceLegs ~= nil then
					sourceLegsFolder = sourceLegs
					setWalkerLegFolder(entry, sourceLegsFolder)
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

			if sourceLegsFolder == nil or entry.walkerLegParts == nil then
				scheduleWalkerLegDiscovery(entry)
			end

				-- Find source head for authoritative replication.
				for _, desc in ipairs(model:GetDescendants()) do
					if desc:IsA("BasePart") and CollectionService:HasTag(desc, "WalkerHead") then
						entry.sourceHeadPart = desc :: BasePart
						break
					end
				end
				entry.walkerWeaponMountPairs = buildWalkerWeaponMountPairs(model, clone)

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
									if isWeaponMountPart(part) or hasWeaponMountAncestor(part) then
										continue
									end
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
		local charEntry = activateCharacter(character, model)
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
		local anyOccupied = hasAnyOccupant(model)
		local justBecameOccupied = anyOccupied and not entry.walkerWasOccupied
		if entry.isWalker and anyOccupied then
			-- Occupied walkers prioritize authority over smoothing so observers stay in sync.
			entry.smoothedCFrame = sourceCFrame
		else
			local smoothingAlpha = SMOOTHING_ALPHA
			local maxSnapDistance = MAX_SNAP_DISTANCE
			if entry.isWalker then
				smoothingAlpha = WALKER_OCCUPIED_SMOOTHING_ALPHA
				maxSnapDistance = WALKER_OCCUPIED_MAX_SNAP_DISTANCE
			end
			local frameAlpha = 1 - math.exp(-smoothingAlpha * clampedDt)
			local posDelta = (entry.smoothedCFrame.Position - sourceCFrame.Position).Magnitude
			if posDelta > maxSnapDistance then
				entry.smoothedCFrame = sourceCFrame
			else
				entry.smoothedCFrame = entry.smoothedCFrame:Lerp(sourceCFrame, frameAlpha)
			end
		end
			entry.visualClone:PivotTo(entry.smoothedCFrame)
			if entry.isWalker then
				forceShowWalkerLegSourceParts(entry.sourceLegsFolder)
			end

		-- Walker head follows authoritative source transform with local lag filter
		-- so observers see the same heavy head motion feel as the driver.
		if entry.isWalker and entry.cloneHeadPart ~= nil and entry.sourceHeadPart ~= nil and (entry.sourceHeadPart :: BasePart).Parent ~= nil then
			local visualPrimary = entry.visualClone.PrimaryPart
			local visualPrimaryCFrame = if visualPrimary ~= nil then visualPrimary.CFrame else entry.smoothedCFrame
			local modelDelta = visualPrimaryCFrame * sourceCFrame:Inverse()
			local targetHeadCFrame = modelDelta * (entry.sourceHeadPart :: BasePart).CFrame
			local targetHeadRotation = targetHeadCFrame.Rotation
			if entry.walkerSmoothedHeadRotation == nil then
				entry.walkerSmoothedHeadRotation = targetHeadRotation
			else
				local currentRotation = entry.walkerSmoothedHeadRotation :: CFrame
				local alpha = 1 - math.exp(-WALKER_REMOTE_HEAD_LAG_RATE * clampedDt)
				entry.walkerSmoothedHeadRotation = currentRotation:Lerp(targetHeadRotation, alpha)
			end
			local nextHeadCFrame = CFrame.new(targetHeadCFrame.Position) * (entry.walkerSmoothedHeadRotation :: CFrame)
			entry.cloneHeadPart.CFrame = nextHeadCFrame
				for _, follower in ipairs(entry.cloneHeadFollowerOffsets) do
					if follower.part.Parent ~= nil then
						follower.part.CFrame = nextHeadCFrame * follower.offset
					end
				end
				for index = #entry.walkerWeaponMountPairs, 1, -1 do
					local mountPair = entry.walkerWeaponMountPairs[index]
					if mountPair.source.Parent == nil or mountPair.clone.Parent == nil then
						table.remove(entry.walkerWeaponMountPairs, index)
						else
							local sourceHeadCFrame = (entry.sourceHeadPart :: BasePart).CFrame
							local targetRelativeMount = sourceHeadCFrame:Inverse() * mountPair.source.CFrame
							if mountPair.smoothedRelativeFrame == nil then
								mountPair.smoothedRelativeFrame = targetRelativeMount
							else
								local mountAlpha = 1 - math.exp(-WALKER_REMOTE_HEAD_LAG_RATE * clampedDt)
								mountPair.smoothedRelativeFrame =
									(mountPair.smoothedRelativeFrame :: CFrame):Lerp(targetRelativeMount, mountAlpha)
							end
							local nextMountCFrame = nextHeadCFrame * (mountPair.smoothedRelativeFrame :: CFrame)
							mountPair.clone.CFrame = nextMountCFrame
							for followerIndex = #mountPair.followers, 1, -1 do
								local follower = mountPair.followers[followerIndex]
							if follower.part.Parent == nil then
								table.remove(mountPair.followers, followerIndex)
							else
								follower.part.CFrame = nextMountCFrame * follower.offset
							end
						end
					end
				end
				if justBecameOccupied then
					entry.walkerIKState = nil
					entry.lastSourcePos = nil
					entry.walkerSmoothedHeadRotation = nil
					for _, mountPair in ipairs(entry.walkerWeaponMountPairs) do
						mountPair.smoothedRelativeFrame = nil
					end
				end
			end
		entry.walkerWasOccupied = anyOccupied

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
				if entry.isWalker then
					updateWalkerSoundEvents(entry, dt)
				end
				local speedAttr = model:GetAttribute("VehicleSpeed")
				local speed = if type(speedAttr) == "number" then speedAttr else 0
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
					isLanding = false,
					isLocal = false,
					dt = dt,
				}
				entry.soundController:update(dt, frameState)
			end

		local currentSet: { [Model]: boolean } = {}
		for _, character in ipairs(currentOccupants) do
			currentSet[character] = true
			if entry.characterEntries[character] == nil then
				local charEntry = activateCharacter(character, model)
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
					local newEntry = activateCharacter(character, model)
					if newEntry ~= nil then
						entry.characterEntries[character] = newEntry
					else
						entry.characterEntries[character] = nil
					end
				end
			end
		end

		-- Position character visuals to follow smoothed vehicle
		local visualPrimary = entry.visualClone.PrimaryPart
		local visualCFrame = if visualPrimary ~= nil then visualPrimary.CFrame else entry.smoothedCFrame
		local cframeDelta = visualCFrame * sourceCFrame:Inverse()
			local walkerDriverUserIdRaw = model:GetAttribute("WalkerDriverUserId")
			local walkerDriverUserId = if type(walkerDriverUserIdRaw) == "number" then math.floor(walkerDriverUserIdRaw + 0.5) else nil
			for _, charEntry in pairs(entry.characterEntries) do
				local hasRenderablePairs = false
				local usedSeatFollow = false
				if entry.isWalker then
					tryHydrateWalkerSeatBinding(charEntry, model, walkerDriverUserId)
				end
				if
					entry.isWalker
					and walkerDriverUserId ~= nil
				and charEntry.userId == walkerDriverUserId
				and charEntry.seatPath ~= nil
				and charEntry.seatToRoot ~= nil
				and #charEntry.rootOffsets > 0
			then
				local visualSeat = findByPath(entry.visualClone, charEntry.seatPath :: { string })
				if visualSeat ~= nil and visualSeat:IsA("BasePart") then
					usedSeatFollow = true
					hasRenderablePairs = true
					local forcedRootCF = (visualSeat :: BasePart).CFrame * (charEntry.seatToRoot :: CFrame)
					for _, rootOffset in ipairs(charEntry.rootOffsets) do
						if rootOffset.visual.Parent ~= nil then
							rootOffset.visual.CFrame = forcedRootCF * rootOffset.offset
						end
					end
				end
			end
			if not usedSeatFollow then
				for _, pair in ipairs(charEntry.partPairs) do
					if pair.source.Parent ~= nil and pair.visual.Parent ~= nil then
						hasRenderablePairs = true
						pair.visual.CFrame = cframeDelta * pair.source.CFrame
					end
				end
			end
			if hasRenderablePairs then
				hideCharacter(charEntry)
			else
				restoreCharacter(charEntry)
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

	if previousLocal ~= nil and previousLocal ~= model then
		print(string.format("[P10_SMOOTH] setLocalVehicle(nil) previousLocal=%s skipping_retrack=true", previousLocal.Name))
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
