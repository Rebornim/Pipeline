--!strict

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local localPlayer = Players.LocalPlayer

local CombatHUD = {}

local screenGui: ScreenGui? = nil
local crosshairLabel: TextLabel? = nil
local hitmarkerFrame: Frame? = nil
local hitmarkerLines: { Frame } = {}
local hitmarkerTween: Tween? = nil
local cursorDot: Frame? = nil
local hpFrame: Frame? = nil
local hpLabel: TextLabel? = nil
local shieldFrame: Frame? = nil
local shieldFill: Frame? = nil
local shieldLabel: TextLabel? = nil
local ammoFrame: Frame? = nil
local ammoLabel: TextLabel? = nil
local heatFrame: Frame? = nil
local heatFill: Frame? = nil
local heatLabel: TextLabel? = nil
local readyLabel: TextLabel? = nil
local vignetteEdges: { Frame } = {}
local hitmarkerToken = 0
local readyCueToken = 0
local warnedMissingHitmarkerSoundTemplate = false
local warnedMissingKillSoundTemplate = false
local warnedMissingOverheatSoundTemplate = false
local warnedMissingOverheatWarningSoundTemplate = false
local lastOverheatWarningAt = 0
local wasOverheatedLastUpdate = false

local VIGNETTE_MAX_OPACITY = 0.45
local VIGNETTE_EDGE_SIZE_SCALE = 0.24
local HEAT_WARNING_THRESHOLD = 0.85
local HEAT_WARNING_SOUND_COOLDOWN = 0.7
local HEAT_PULSE_SPEED = 12
local SHIELD_LOW_THRESHOLD = 0.25
local SHIELD_PULSE_SPEED = 8
local SHIELD_HEALTHY_COLOR = Color3.fromRGB(80, 140, 255)
local SHIELD_LOW_COLOR = Color3.fromRGB(90, 240, 255)

local currentEntityId: string? = nil
local hpCache: { [string]: { currentHP: number, maxHP: number } } = {}
local shieldCache: { [string]: { currentShield: number, maxShield: number } } = {}

local function getHitmarkerSoundTemplate(): Sound?
	local combatAssets = ReplicatedStorage:FindFirstChild("CombatAssets")
	if combatAssets == nil or not combatAssets:IsA("Folder") then
		return nil
	end

	local audioFolder = combatAssets:FindFirstChild("Audio")
	if audioFolder == nil or not audioFolder:IsA("Folder") then
		return nil
	end

	local hitmarkerFolder = audioFolder:FindFirstChild("Hitmarker")
	if hitmarkerFolder == nil or not hitmarkerFolder:IsA("Folder") then
		return nil
	end

	for _, child in ipairs(hitmarkerFolder:GetChildren()) do
		if child:IsA("Sound") then
			return child
		end
	end

	return nil
end

local function getKillSoundTemplate(): Sound?
	local combatAssets = ReplicatedStorage:FindFirstChild("CombatAssets")
	if combatAssets == nil or not combatAssets:IsA("Folder") then
		return nil
	end

	local audioFolder = combatAssets:FindFirstChild("Audio")
	if audioFolder == nil or not audioFolder:IsA("Folder") then
		return nil
	end

	local killFolder = audioFolder:FindFirstChild("KillConfirm")
	if killFolder == nil or not killFolder:IsA("Folder") then
		return nil
	end

	for _, child in ipairs(killFolder:GetChildren()) do
		if child:IsA("Sound") then
			return child
		end
	end

	return nil
end

local function getOverheatWarningSoundTemplate(): Sound?
	local combatAssets = ReplicatedStorage:FindFirstChild("CombatAssets")
	if combatAssets == nil or not combatAssets:IsA("Folder") then
		return nil
	end

	local audioFolder = combatAssets:FindFirstChild("Audio")
	if audioFolder == nil or not audioFolder:IsA("Folder") then
		return nil
	end

	local warningFolder = audioFolder:FindFirstChild("OverheatWarning")
	if warningFolder == nil or not warningFolder:IsA("Folder") then
		return nil
	end

	for _, child in ipairs(warningFolder:GetChildren()) do
		if child:IsA("Sound") then
			return child
		end
	end

	return nil
end

local function getOverheatSoundTemplate(): Sound?
	local combatAssets = ReplicatedStorage:FindFirstChild("CombatAssets")
	if combatAssets == nil or not combatAssets:IsA("Folder") then
		return nil
	end

	local audioFolder = combatAssets:FindFirstChild("Audio")
	if audioFolder == nil or not audioFolder:IsA("Folder") then
		return nil
	end

	local overheatFolder = audioFolder:FindFirstChild("Overheat")
	if overheatFolder == nil or not overheatFolder:IsA("Folder") then
		return nil
	end

	for _, child in ipairs(overheatFolder:GetChildren()) do
		if child:IsA("Sound") then
			return child
		end
	end

	return nil
end

local function playGuiSound(soundTemplate: Sound)
	local gui = screenGui
	if gui == nil then
		return
	end

	local hitSound = soundTemplate:Clone()
	hitSound.Looped = false
	hitSound.Parent = gui
	hitSound:Play()
	local cleanupDelay = math.max(1, hitSound.TimeLength + 0.15)
	task.delay(cleanupDelay, function()
		if hitSound.Parent ~= nil then
			hitSound:Destroy()
		end
	end)
end

local function playHitmarkerSound()
	local soundTemplate = getHitmarkerSoundTemplate()
	if soundTemplate == nil then
		if not warnedMissingHitmarkerSoundTemplate then
			warn("[P1_AUDIO] Missing hitmarker sound template in ReplicatedStorage.CombatAssets.Audio.Hitmarker")
			warnedMissingHitmarkerSoundTemplate = true
		end
		return
	end

	playGuiSound(soundTemplate)
end

local function playKillConfirmSound()
	local soundTemplate = getKillSoundTemplate()
	if soundTemplate == nil then
		if not warnedMissingKillSoundTemplate then
			warn("[P1_AUDIO] Missing kill-confirm sound template in ReplicatedStorage.CombatAssets.Audio.KillConfirm")
			warnedMissingKillSoundTemplate = true
		end
		return
	end

	playGuiSound(soundTemplate)
end

local function playOverheatSound()
	local soundTemplate = getOverheatSoundTemplate()
	if soundTemplate == nil then
		if not warnedMissingOverheatSoundTemplate then
			warn("[P1_AUDIO] Missing overheat sound template in ReplicatedStorage.CombatAssets.Audio.Overheat")
			warnedMissingOverheatSoundTemplate = true
		end
		return
	end

	playGuiSound(soundTemplate)
end

local function playOverheatWarningSound()
	local soundTemplate = getOverheatWarningSoundTemplate()
	if soundTemplate == nil then
		if not warnedMissingOverheatWarningSoundTemplate then
			warn("[P1_AUDIO] Missing overheat warning sound template in ReplicatedStorage.CombatAssets.Audio.OverheatWarning")
			warnedMissingOverheatWarningSoundTemplate = true
		end
		return
	end

	playGuiSound(soundTemplate)
end

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
	gui.IgnoreGuiInset = true
	gui.Parent = playerGui

	table.clear(vignetteEdges)
	table.clear(hitmarkerLines)

	local function createVignetteEdge(name: string, size: UDim2, position: UDim2, anchorPoint: Vector2, rotation: number): Frame
		local edge = Instance.new("Frame")
		edge.Name = name
		edge.Size = size
		edge.Position = position
		edge.AnchorPoint = anchorPoint
		edge.BackgroundColor3 = Color3.new(0, 0, 0)
		edge.BackgroundTransparency = 1
		edge.BorderSizePixel = 0
		edge.Visible = false
		edge.ZIndex = 0
		edge.Parent = gui

		local gradient = Instance.new("UIGradient")
		gradient.Rotation = rotation
		gradient.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(1, 1),
		})
		gradient.Parent = edge

		table.insert(vignetteEdges, edge)
		return edge
	end

	createVignetteEdge(
		"VignetteTop",
		UDim2.fromScale(1, VIGNETTE_EDGE_SIZE_SCALE),
		UDim2.fromScale(0.5, 0),
		Vector2.new(0.5, 0),
		90
	)
	createVignetteEdge(
		"VignetteBottom",
		UDim2.fromScale(1, VIGNETTE_EDGE_SIZE_SCALE),
		UDim2.fromScale(0.5, 1),
		Vector2.new(0.5, 1),
		-90
	)
	createVignetteEdge(
		"VignetteLeft",
		UDim2.fromScale(VIGNETTE_EDGE_SIZE_SCALE, 1),
		UDim2.fromScale(0, 0.5),
		Vector2.new(0, 0.5),
		0
	)
	createVignetteEdge(
		"VignetteRight",
		UDim2.fromScale(VIGNETTE_EDGE_SIZE_SCALE, 1),
		UDim2.fromScale(1, 0.5),
		Vector2.new(1, 0.5),
		180
	)

	local crosshair = Instance.new("TextLabel")
	crosshair.Name = "Crosshair"
	crosshair.AnchorPoint = Vector2.new(0.5, 0.5)
	crosshair.Position = UDim2.fromScale(0.5, 0.5)
	crosshair.Size = UDim2.fromOffset(22, 22)
	crosshair.BackgroundTransparency = 1
	crosshair.Text = "+"
	crosshair.TextColor3 = Color3.new(1, 1, 1)
	crosshair.TextScaled = true
	crosshair.Visible = false
	crosshair.ZIndex = 5
	crosshair.Parent = gui

	local hitmarker = Instance.new("Frame")
	hitmarker.Name = "HitMarker"
	hitmarker.AnchorPoint = Vector2.new(0.5, 0.5)
	hitmarker.Position = UDim2.fromScale(0.5, 0.5)
	hitmarker.Size = UDim2.fromOffset(28, 28)
	hitmarker.BackgroundTransparency = 1
	hitmarker.Visible = false
	hitmarker.ZIndex = 6
	hitmarker.Parent = gui

	local function createHitLine(name: string, xScale: number, yScale: number, rotation: number)
		local line = Instance.new("Frame")
		line.Name = name
		line.AnchorPoint = Vector2.new(0.5, 0.5)
		line.Position = UDim2.fromScale(xScale, yScale)
		line.Size = UDim2.fromOffset(3, 11)
		line.BackgroundColor3 = Color3.new(1, 1, 1)
		line.BorderSizePixel = 0
		line.Rotation = rotation
		line.ZIndex = 6
		line.Parent = hitmarker
		table.insert(hitmarkerLines, line)
	end

	createHitLine("TopLeft", 0.31, 0.31, -45)
	createHitLine("TopRight", 0.69, 0.31, 45)
	createHitLine("BottomLeft", 0.31, 0.69, 45)
	createHitLine("BottomRight", 0.69, 0.69, -45)

	local dot = Instance.new("Frame")
	dot.Name = "CursorDot"
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.Position = UDim2.fromScale(0.5, 0.5)
	dot.Size = UDim2.fromOffset(6, 6)
	dot.BackgroundColor3 = Color3.new(1, 1, 1)
	dot.BorderSizePixel = 0
	dot.Visible = false
	dot.ZIndex = 6
	dot.Parent = gui

	local dotCorner = Instance.new("UICorner")
	dotCorner.CornerRadius = UDim.new(1, 0)
	dotCorner.Parent = dot

	local frame = Instance.new("Frame")
	frame.Name = "HullFrame"
	frame.AnchorPoint = Vector2.new(0.5, 1)
	frame.Position = UDim2.new(0.5, 0, 1, -86)
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

	local shieldStatusFrame = Instance.new("Frame")
	shieldStatusFrame.Name = "ShieldFrame"
	shieldStatusFrame.AnchorPoint = Vector2.new(0.5, 1)
	shieldStatusFrame.Position = UDim2.new(0.5, 0, 1, -122)
	shieldStatusFrame.Size = UDim2.fromOffset(220, 28)
	shieldStatusFrame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	shieldStatusFrame.BackgroundTransparency = 0.35
	shieldStatusFrame.Visible = false
	shieldStatusFrame.Parent = gui

	local shieldBar = Instance.new("Frame")
	shieldBar.Name = "ShieldBar"
	shieldBar.Position = UDim2.fromOffset(8, 7)
	shieldBar.Size = UDim2.fromOffset(204, 14)
	shieldBar.BackgroundColor3 = Color3.fromRGB(22, 26, 42)
	shieldBar.BorderSizePixel = 0
	shieldBar.Parent = shieldStatusFrame

	local shieldBarFill = Instance.new("Frame")
	shieldBarFill.Name = "Fill"
	shieldBarFill.Size = UDim2.fromScale(0, 1)
	shieldBarFill.BackgroundColor3 = SHIELD_HEALTHY_COLOR
	shieldBarFill.BorderSizePixel = 0
	shieldBarFill.Parent = shieldBar

	local shieldText = Instance.new("TextLabel")
	shieldText.Name = "ShieldLabel"
	shieldText.AnchorPoint = Vector2.new(1, 0.5)
	shieldText.Position = UDim2.fromScale(1, 0.5)
	shieldText.Size = UDim2.fromOffset(140, 24)
	shieldText.BackgroundTransparency = 1
	shieldText.TextColor3 = Color3.fromRGB(160, 196, 255)
	shieldText.TextScaled = false
	shieldText.TextSize = 14
	shieldText.Font = Enum.Font.Code
	shieldText.TextXAlignment = Enum.TextXAlignment.Right
	shieldText.Text = "Shield: -- / --"
	shieldText.Parent = shieldStatusFrame

	local weaponHeatFrame = Instance.new("Frame")
	weaponHeatFrame.Name = "HeatFrame"
	weaponHeatFrame.AnchorPoint = Vector2.new(0.5, 1)
	weaponHeatFrame.Position = UDim2.new(0.5, 0, 1, -46)
	weaponHeatFrame.Size = UDim2.fromOffset(220, 28)
	weaponHeatFrame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	weaponHeatFrame.BackgroundTransparency = 0.35
	weaponHeatFrame.Visible = false
	weaponHeatFrame.Parent = gui

	local heatBar = Instance.new("Frame")
	heatBar.Name = "HeatBar"
	heatBar.Position = UDim2.fromOffset(8, 7)
	heatBar.Size = UDim2.fromOffset(204, 14)
	heatBar.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
	heatBar.BorderSizePixel = 0
	heatBar.Parent = weaponHeatFrame

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = Color3.fromRGB(230, 230, 230)
	fill.BorderSizePixel = 0
	fill.Parent = heatBar

	local heatText = Instance.new("TextLabel")
	heatText.Name = "HeatLabel"
	heatText.AnchorPoint = Vector2.new(1, 0.5)
	heatText.Position = UDim2.fromScale(1, 0.5)
	heatText.Size = UDim2.fromOffset(120, 24)
	heatText.BackgroundTransparency = 1
	heatText.TextColor3 = Color3.new(1, 1, 1)
	heatText.TextScaled = false
	heatText.TextSize = 14
	heatText.Font = Enum.Font.Code
	heatText.TextXAlignment = Enum.TextXAlignment.Right
	heatText.Text = "Heat: 0%"
	heatText.Parent = weaponHeatFrame

	local weaponAmmoFrame = Instance.new("Frame")
	weaponAmmoFrame.Name = "AmmoFrame"
	weaponAmmoFrame.AnchorPoint = Vector2.new(0.5, 1)
	weaponAmmoFrame.Position = UDim2.new(0.5, 0, 1, -46)
	weaponAmmoFrame.Size = UDim2.fromOffset(220, 28)
	weaponAmmoFrame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	weaponAmmoFrame.BackgroundTransparency = 0.35
	weaponAmmoFrame.Visible = false
	weaponAmmoFrame.Parent = gui

	local ammoText = Instance.new("TextLabel")
	ammoText.Name = "AmmoLabel"
	ammoText.Size = UDim2.fromScale(1, 1)
	ammoText.BackgroundTransparency = 1
	ammoText.TextColor3 = Color3.fromRGB(235, 235, 235)
	ammoText.TextScaled = false
	ammoText.TextSize = 14
	ammoText.Font = Enum.Font.Code
	ammoText.TextXAlignment = Enum.TextXAlignment.Center
	ammoText.Text = "Ammo: -- / --"
	ammoText.Parent = weaponAmmoFrame

	local weaponsReadyLabel = Instance.new("TextLabel")
	weaponsReadyLabel.Name = "WeaponsReadyLabel"
	weaponsReadyLabel.AnchorPoint = Vector2.new(0.5, 1)
	weaponsReadyLabel.Position = UDim2.new(0.5, 0, 1, -104)
	weaponsReadyLabel.Size = UDim2.fromOffset(300, 32)
	weaponsReadyLabel.BackgroundTransparency = 1
	weaponsReadyLabel.Text = "WEAPONS READY"
	weaponsReadyLabel.TextColor3 = Color3.fromRGB(134, 255, 155)
	weaponsReadyLabel.TextTransparency = 1
	weaponsReadyLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
	weaponsReadyLabel.TextStrokeTransparency = 0.45
	weaponsReadyLabel.Font = Enum.Font.GothamBold
	weaponsReadyLabel.TextScaled = true
	weaponsReadyLabel.Visible = false
	weaponsReadyLabel.ZIndex = 8
	weaponsReadyLabel.Parent = gui

	screenGui = gui
	crosshairLabel = crosshair
	hitmarkerFrame = hitmarker
	cursorDot = dot
	hpFrame = frame
	hpLabel = label
	shieldFrame = shieldStatusFrame
	shieldFill = shieldBarFill
	shieldLabel = shieldText
	ammoFrame = weaponAmmoFrame
	ammoLabel = ammoText
	heatFrame = weaponHeatFrame
	heatFill = fill
	heatLabel = heatText
	readyLabel = weaponsReadyLabel
end

function CombatHUD.setZoomVignette(intensity: number)
	local clamped = math.clamp(intensity, 0, 1)
	local edgeOpacity = clamped * VIGNETTE_MAX_OPACITY
	local edgeTransparency = 1 - edgeOpacity
	local visible = clamped > 0.01

	for _, edge in ipairs(vignetteEdges) do
		edge.Visible = visible
		edge.BackgroundTransparency = edgeTransparency
	end
end

function CombatHUD.showCrosshair(visible: boolean)
	if crosshairLabel ~= nil then
		crosshairLabel.Visible = visible
		if not visible then
			crosshairLabel.TextColor3 = Color3.new(1, 1, 1)
		end
	end
	if cursorDot ~= nil then
		cursorDot.Visible = visible
		if not visible then
			cursorDot.BackgroundColor3 = Color3.new(1, 1, 1)
		end
	end
end

function CombatHUD.setCrosshairPosition(screenPosition: Vector2)
	if crosshairLabel == nil then
		return
	end

	crosshairLabel.Position = UDim2.fromOffset(math.floor(screenPosition.X + 0.5), math.floor(screenPosition.Y + 0.5))
end

function CombatHUD.setCursorDotPosition(screenPosition: Vector2)
	if cursorDot == nil then
		return
	end

	cursorDot.Position = UDim2.fromOffset(math.floor(screenPosition.X + 0.5), math.floor(screenPosition.Y + 0.5))
end

function CombatHUD.showHP(entityId: string)
	currentEntityId = entityId
	if hpFrame ~= nil then
		hpFrame.Visible = true
	end
	updateHpLabel(entityId)

	local shieldData = shieldCache[entityId]
	if shieldData ~= nil then
		CombatHUD.setShield(shieldData.currentShield, shieldData.maxShield)
	end
end

function CombatHUD.hideHP()
	currentEntityId = nil
	if hpFrame ~= nil then
		hpFrame.Visible = false
	end
end

function CombatHUD.showShield(visible: boolean)
	if shieldFrame ~= nil then
		shieldFrame.Visible = visible
	end
end

function CombatHUD.showAmmo(visible: boolean)
	if ammoFrame ~= nil then
		ammoFrame.Visible = visible
	end
end

function CombatHUD.setAmmo(currentAmmo: number, maxAmmo: number)
	local label = ammoLabel
	if label == nil then
		return
	end

	local clampedMax = math.max(0, math.floor(maxAmmo + 0.5))
	local clampedCurrent = math.clamp(math.floor(currentAmmo + 0.5), 0, math.max(clampedMax, 0))
	if clampedCurrent <= 0 then
		label.Text = string.format("Ammo: 0 / %d (EMPTY)", clampedMax)
		label.TextColor3 = Color3.fromRGB(255, 110, 110)
	else
		label.Text = string.format("Ammo: %d / %d", clampedCurrent, clampedMax)
		label.TextColor3 = Color3.fromRGB(235, 235, 235)
	end
end

function CombatHUD.setShield(currentShield: number, maxShield: number)
	local fill = shieldFill
	local label = shieldLabel
	if fill == nil or label == nil then
		return
	end

	local clampedMax = math.max(1, maxShield)
	local clampedCurrent = math.clamp(currentShield, 0, clampedMax)
	local ratio = math.clamp(clampedCurrent / clampedMax, 0, 1)
	fill.Size = UDim2.fromScale(ratio, 1)

	local fillColor = SHIELD_HEALTHY_COLOR
	if ratio < SHIELD_LOW_THRESHOLD then
		local pulse = 0.5 + 0.5 * math.sin(tick() * SHIELD_PULSE_SPEED)
		fillColor = SHIELD_HEALTHY_COLOR:Lerp(SHIELD_LOW_COLOR, pulse)
	end
	fill.BackgroundColor3 = fillColor

	label.Text = string.format("Shield: %d / %d", math.floor(clampedCurrent + 0.5), math.floor(clampedMax + 0.5))
end

function CombatHUD.showHeat(visible: boolean)
	if heatFrame ~= nil then
		heatFrame.Visible = visible
	end
	if not visible and readyLabel ~= nil then
		readyLabel.Visible = false
		lastOverheatWarningAt = 0
		wasOverheatedLastUpdate = false
	end
end

function CombatHUD.setWeaponHeat(currentHeat: number, maxHeat: number, overheated: boolean)
	local fill = heatFill
	local label = heatLabel
	if fill == nil or label == nil then
		return
	end

	local clampedMax = math.max(1, maxHeat)
	local ratio = math.clamp(currentHeat / clampedMax, 0, 1)
	fill.Size = UDim2.fromScale(ratio, 1)

	local fillColor = Color3.fromRGB(228, 228, 228)
	if overheated then
		fillColor = Color3.fromRGB(255, 80, 80)
	elseif ratio >= 0.8 then
		fillColor = Color3.fromRGB(255, 150, 66)
	elseif ratio >= 0.55 then
		fillColor = Color3.fromRGB(255, 214, 102)
	end
	fill.BackgroundColor3 = fillColor

	local percentage = math.floor(ratio * 100 + 0.5)
	if overheated then
		label.Text = string.format("Heat: %d%% (OVERHEAT)", percentage)
		label.TextColor3 = Color3.fromRGB(255, 120, 120)
	else
		label.Text = string.format("Heat: %d%%", percentage)
		label.TextColor3 = Color3.fromRGB(235, 235, 235)
	end

	if heatFrame ~= nil then
		if overheated then
			heatFrame.BackgroundTransparency = 0.16
		elseif ratio >= HEAT_WARNING_THRESHOLD then
			local pulse = 0.5 + 0.5 * math.sin(tick() * HEAT_PULSE_SPEED)
			heatFrame.BackgroundTransparency = math.clamp(0.34 - pulse * 0.14, 0.18, 0.46)
		else
			heatFrame.BackgroundTransparency = 0.35
		end
	end

	local criticalAlpha = math.clamp((ratio - HEAT_WARNING_THRESHOLD) / (1 - HEAT_WARNING_THRESHOLD), 0, 1)
	local crosshairColor = Color3.new(1, 1, 1)
	if overheated then
		crosshairColor = Color3.fromRGB(255, 78, 78)
	elseif criticalAlpha > 0 then
		local g = math.floor(245 - criticalAlpha * 135 + 0.5)
		local b = math.floor(240 - criticalAlpha * 185 + 0.5)
		crosshairColor = Color3.fromRGB(255, math.clamp(g, 70, 255), math.clamp(b, 55, 255))
	end

	if crosshairLabel ~= nil then
		crosshairLabel.TextColor3 = crosshairColor
	end
	if cursorDot ~= nil then
		cursorDot.BackgroundColor3 = crosshairColor
	end

	if ratio >= HEAT_WARNING_THRESHOLD and not overheated then
		local now = tick()
		if now - lastOverheatWarningAt >= HEAT_WARNING_SOUND_COOLDOWN then
			lastOverheatWarningAt = now
			playOverheatWarningSound()
		end
	end

	if overheated and not wasOverheatedLastUpdate then
		playOverheatSound()
	end
	wasOverheatedLastUpdate = overheated
end

function CombatHUD.onWeaponRecoveredCue()
	local label = readyLabel
	if label == nil then
		return
	end

	playOverheatWarningSound()

	readyCueToken += 1
	local token = readyCueToken
	label.Visible = true
	label.TextTransparency = 1
	label.TextStrokeTransparency = 1

	local fadeIn = TweenService:Create(label, TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		TextTransparency = 0.05,
		TextStrokeTransparency = 0.35,
	})
	fadeIn:Play()

	task.delay(0.55, function()
		if token ~= readyCueToken or label.Parent == nil then
			return
		end
		local fadeOut = TweenService:Create(label, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			TextTransparency = 1,
			TextStrokeTransparency = 1,
		})
		fadeOut:Play()
		fadeOut.Completed:Connect(function()
			if token == readyCueToken and label.Parent ~= nil then
				label.Visible = false
			end
		end)
	end)
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

	local newShieldHP = payload.newShieldHP
	local maxShieldHP = payload.maxShieldHP
	if type(newShieldHP) == "number" and type(maxShieldHP) == "number" and maxShieldHP > 0 then
		shieldCache[entityId] = {
			currentShield = newShieldHP,
			maxShield = maxShieldHP,
		}
		if currentEntityId == entityId then
			CombatHUD.setShield(newShieldHP, maxShieldHP)
		end
	end

	if currentEntityId == entityId then
		updateHpLabel(entityId)
	end
end

function CombatHUD.onEntityDestroyed(entityId: string)
	if currentEntityId == entityId and hpLabel ~= nil then
		hpLabel.Text = "Hull: DESTROYED"
	end
	if currentEntityId == entityId then
		local existingShield = shieldCache[entityId]
		if existingShield ~= nil then
			CombatHUD.setShield(0, existingShield.maxShield)
		end
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

	local shieldHP = payload.shieldHP
	if type(shieldHP) == "number" and shieldHP > 0 then
		shieldCache[entityId] = {
			currentShield = shieldHP,
			maxShield = shieldHP,
		}
		if currentEntityId == entityId then
			CombatHUD.setShield(shieldHP, shieldHP)
		end
	end

	if currentEntityId == entityId then
		updateHpLabel(entityId)
	end
end

function CombatHUD.onHitConfirm(payload)
	if type(payload) ~= "table" then
		return
	end

	local isKill = payload.isKill
	if type(isKill) ~= "boolean" then
		isKill = false
	end

	playHitmarkerSound()
	if isKill then
		playKillConfirmSound()
	end

	local marker = hitmarkerFrame
	if marker == nil then
		return
	end

	if crosshairLabel ~= nil then
		marker.Position = crosshairLabel.Position
	else
		marker.Position = UDim2.fromScale(0.5, 0.5)
	end

	local markerColor = if isKill then Color3.fromRGB(255, 110, 110) else Color3.fromRGB(245, 245, 245)
	for _, line in ipairs(hitmarkerLines) do
		line.BackgroundColor3 = markerColor
	end

	if hitmarkerTween ~= nil then
		hitmarkerTween:Cancel()
	end
	marker.Size = UDim2.fromOffset(36, 36)
	hitmarkerTween = TweenService:Create(marker, TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = UDim2.fromOffset(28, 28),
	})
	hitmarkerTween:Play()
	marker.Visible = true

	hitmarkerToken += 1
	local token = hitmarkerToken
	task.delay(0.1, function()
		if token == hitmarkerToken and marker.Parent ~= nil then
			marker.Visible = false
		end
	end)
end

return CombatHUD
