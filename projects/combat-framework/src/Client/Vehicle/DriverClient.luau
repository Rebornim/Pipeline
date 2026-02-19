--!strict

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local localPlayer = Players.LocalPlayer
local playerScripts = localPlayer:WaitForChild("PlayerScripts")
local clientRoot = playerScripts:WaitForChild("CombatFramework")

local CombatHUD = require(clientRoot:WaitForChild("HUD"):WaitForChild("CombatHUD"))

local DriverClient = {}

local activeDriverSeat: BasePart? = nil
local activeDriverModel: Model? = nil
local activeDriverEntityId: string? = nil

local seatedConnection: RBXScriptConnection? = nil
local characterAddedConnection: RBXScriptConnection? = nil
local renderConnection: RBXScriptConnection? = nil

local function deactivateDriverMode()
	if activeDriverEntityId ~= nil then
		CombatHUD.hideDriverHUD()
	end
	activeDriverSeat = nil
	activeDriverModel = nil
	activeDriverEntityId = nil
end

local function resolveDriverContextFromSeat(seatPart: BasePart): (Model?, string?)
	if not CollectionService:HasTag(seatPart, "DriverSeat") then
		return nil, nil
	end

	local entityModel = seatPart:FindFirstAncestorWhichIsA("Model")
	if entityModel == nil or not CollectionService:HasTag(entityModel, "CombatEntity") then
		return nil, nil
	end

	local entityId = entityModel:GetAttribute("EntityId")
	if type(entityId) ~= "string" then
		return nil, nil
	end

	return entityModel, entityId
end

local function updateDriverHud()
	local entityModel = activeDriverModel
	local entityId = activeDriverEntityId
	if entityModel == nil or entityId == nil or entityModel.Parent == nil then
		deactivateDriverMode()
		return
	end

	local character = localPlayer.Character
	local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
	local seatPart = if humanoid ~= nil then humanoid.SeatPart else nil
	if seatPart == nil or seatPart ~= activeDriverSeat or not CollectionService:HasTag(seatPart, "DriverSeat") then
		deactivateDriverMode()
		return
	end

	local currentHP = entityModel:GetAttribute("HullHP")
	local maxHP = entityModel:GetAttribute("MaxHullHP")
	if type(currentHP) == "number" and type(maxHP) == "number" then
		CombatHUD.setHP(currentHP, maxHP)
	end

	local currentShield = entityModel:GetAttribute("ShieldHP")
	local maxShield = entityModel:GetAttribute("MaxShieldHP")
	if type(currentShield) == "number" and type(maxShield) == "number" and maxShield > 0 then
		CombatHUD.showShield(true)
		CombatHUD.setShield(currentShield, maxShield)
	else
		CombatHUD.showShield(false)
	end
end

local function activateDriverMode(seatPart: BasePart)
	local entityModel, entityId = resolveDriverContextFromSeat(seatPart)
	if entityModel == nil or entityId == nil then
		deactivateDriverMode()
		return
	end

	activeDriverSeat = seatPart
	activeDriverModel = entityModel
	activeDriverEntityId = entityId
	CombatHUD.showDriverHUD(entityId)
	updateDriverHud()
end

local function onHumanoidSeated(isSeated: boolean, seatPart: BasePart?)
	if isSeated and seatPart ~= nil and CollectionService:HasTag(seatPart, "DriverSeat") then
		activateDriverMode(seatPart)
		return
	end

	deactivateDriverMode()
end

local function bindCharacter(character: Model)
	deactivateDriverMode()

	if seatedConnection ~= nil then
		seatedConnection:Disconnect()
		seatedConnection = nil
	end

	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	seatedConnection = humanoid.Seated:Connect(onHumanoidSeated)

	if humanoid.SeatPart ~= nil and CollectionService:HasTag(humanoid.SeatPart, "DriverSeat") then
		activateDriverMode(humanoid.SeatPart)
	end
end

function DriverClient.init()
	if characterAddedConnection == nil then
		characterAddedConnection = localPlayer.CharacterAdded:Connect(bindCharacter)
	end

	if renderConnection == nil then
		renderConnection = RunService.RenderStepped:Connect(updateDriverHud)
	end

	local existingCharacter = localPlayer.Character
	if existingCharacter ~= nil then
		bindCharacter(existingCharacter)
	end
end

function DriverClient.isDriverSeated(): boolean
	return activeDriverSeat ~= nil and activeDriverEntityId ~= nil and activeDriverModel ~= nil
end

return DriverClient
