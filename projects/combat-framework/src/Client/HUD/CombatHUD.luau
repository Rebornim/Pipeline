--!strict

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local localPlayer = Players.LocalPlayer

local CombatHUD = {}

local screenGui: ScreenGui? = nil
local crosshairLabel: TextLabel? = nil
local hpFrame: Frame? = nil
local hpLabel: TextLabel? = nil

local currentEntityId: string? = nil
local hpCache: { [string]: { currentHP: number, maxHP: number } } = {}

local function findEntityById(entityId: string): Model?
	for _, tagged in ipairs(CollectionService:GetTagged("CombatEntity")) do
		if tagged:IsA("Model") then
			local taggedEntityId = tagged:GetAttribute("EntityId")
			if taggedEntityId == entityId then
				return tagged
			end
		end
	end
	return nil
end

local function updateHpLabel(entityId: string)
	if hpLabel == nil then
		return
	end

	local hpData = hpCache[entityId]
	if hpData ~= nil then
		hpLabel.Text = string.format("Hull: %d / %d", hpData.currentHP, hpData.maxHP)
		return
	end

	local model = findEntityById(entityId)
	if model ~= nil then
		local currentHP = model:GetAttribute("HullHP")
		local maxHP = model:GetAttribute("MaxHullHP")
		if type(currentHP) == "number" and type(maxHP) == "number" then
			hpCache[entityId] = {
				currentHP = currentHP,
				maxHP = maxHP,
			}
			hpLabel.Text = string.format("Hull: %d / %d", currentHP, maxHP)
			return
		end
	end

	hpLabel.Text = "Hull: -- / --"
end

function CombatHUD.init()
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	local existing = playerGui:FindFirstChild("CombatHUD")
	if existing ~= nil and existing:IsA("ScreenGui") then
		existing:Destroy()
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "CombatHUD"
	gui.ResetOnSpawn = false
	gui.Enabled = true
	gui.Parent = playerGui

	local crosshair = Instance.new("TextLabel")
	crosshair.Name = "Crosshair"
	crosshair.AnchorPoint = Vector2.new(0.5, 0.5)
	crosshair.Position = UDim2.fromScale(0.5, 0.5)
	crosshair.Size = UDim2.fromOffset(30, 30)
	crosshair.BackgroundTransparency = 1
	crosshair.Text = "+"
	crosshair.TextColor3 = Color3.new(1, 1, 1)
	crosshair.TextScaled = true
	crosshair.Visible = false
	crosshair.Parent = gui

	local frame = Instance.new("Frame")
	frame.Name = "HullFrame"
	frame.Position = UDim2.fromOffset(16, 16)
	frame.Size = UDim2.fromOffset(200, 40)
	frame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	frame.BackgroundTransparency = 0.35
	frame.Visible = false
	frame.Parent = gui

	local label = Instance.new("TextLabel")
	label.Name = "HullLabel"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextScaled = false
	label.TextSize = 20
	label.Font = Enum.Font.Code
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = "Hull: -- / --"
	label.Parent = frame

	screenGui = gui
	crosshairLabel = crosshair
	hpFrame = frame
	hpLabel = label
end

function CombatHUD.showCrosshair(visible: boolean)
	if crosshairLabel ~= nil then
		crosshairLabel.Visible = visible
	end
end

function CombatHUD.showHP(entityId: string)
	currentEntityId = entityId
	if hpFrame ~= nil then
		hpFrame.Visible = true
	end
	updateHpLabel(entityId)
end

function CombatHUD.hideHP()
	currentEntityId = nil
	if hpFrame ~= nil then
		hpFrame.Visible = false
	end
end

function CombatHUD.onDamageApplied(payload)
	if type(payload) ~= "table" then
		return
	end

	local entityId = payload.entityId
	local newHP = payload.newHP
	local maxHP = payload.maxHP
	if type(entityId) ~= "string" or type(newHP) ~= "number" or type(maxHP) ~= "number" then
		return
	end

	hpCache[entityId] = {
		currentHP = newHP,
		maxHP = maxHP,
	}

	if currentEntityId == entityId then
		updateHpLabel(entityId)
	end
end

function CombatHUD.onEntityDestroyed(entityId: string)
	if currentEntityId == entityId and hpLabel ~= nil then
		hpLabel.Text = "Hull: DESTROYED"
	end
end

function CombatHUD.onEntityRespawned(payload)
	if type(payload) ~= "table" then
		return
	end

	local entityId = payload.entityId
	local hullHP = payload.hullHP
	if type(entityId) ~= "string" or type(hullHP) ~= "number" then
		return
	end

	local existing = hpCache[entityId]
	hpCache[entityId] = {
		currentHP = hullHP,
		maxHP = existing and existing.maxHP or hullHP,
	}

	if currentEntityId == entityId then
		updateHpLabel(entityId)
	end
end

return CombatHUD
