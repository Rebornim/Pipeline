--!strict

local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local localPlayer = Players.LocalPlayer
local playerScripts = localPlayer:WaitForChild("PlayerScripts")
local clientRoot = playerScripts:WaitForChild("CombatFramework")

local CombatHUD = require(clientRoot:WaitForChild("HUD"):WaitForChild("CombatHUD"))

local WeaponClient = {}

local FIRE_ACTION_NAME = "CombatFireWeapon"
local EXIT_ACTION_NAME = "CombatExitTurret"

local fireWeaponRemote: RemoteEvent? = nil

local activeTurretModel: Model? = nil
local activeSeat: BasePart? = nil
local activeWeaponMount: BasePart? = nil

local seatedConnection: RBXScriptConnection? = nil
local characterAddedConnection: RBXScriptConnection? = nil
local barrelRenderConnection: RBXScriptConnection? = nil

local function findTaggedDescendant(model: Model, tagName: string, className: string?): Instance?
	for _, descendant in ipairs(model:GetDescendants()) do
		if CollectionService:HasTag(descendant, tagName) then
			if className == nil or descendant:IsA(className) then
				return descendant
			end
		end
	end
	return nil
end

local function deactivateTurretMode()
	ContextActionService:UnbindAction(FIRE_ACTION_NAME)
	ContextActionService:UnbindAction(EXIT_ACTION_NAME)

	if barrelRenderConnection ~= nil then
		barrelRenderConnection:Disconnect()
		barrelRenderConnection = nil
	end

	CombatHUD.showCrosshair(false)
	CombatHUD.hideHP()

	activeTurretModel = nil
	activeSeat = nil
	activeWeaponMount = nil
end

local function getAimDirectionFromMouse(origin: Vector3): Vector3?
	local camera = workspace.CurrentCamera
	if camera == nil then
		return nil
	end

	local mousePosition = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(mousePosition.X, mousePosition.Y)
	local targetPoint = ray.Origin + ray.Direction * 1000
	local aimDirection = targetPoint - origin
	if aimDirection.Magnitude < 1e-4 then
		return nil
	end
	return aimDirection.Unit
end

local function updateBarrelRotation()
	if activeTurretModel == nil then
		return
	end

	if activeWeaponMount == nil or activeWeaponMount.Parent == nil then
		local mount = findTaggedDescendant(activeTurretModel, "WeaponMount", "BasePart")
		if mount == nil then
			return
		end
		activeWeaponMount = mount :: BasePart
	end

	local camera = workspace.CurrentCamera
	if camera == nil then
		return
	end

	local mousePosition = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(mousePosition.X, mousePosition.Y)
	local lookTarget = ray.Origin + ray.Direction * 1000
	local barrelPosition = activeWeaponMount.Position
	local horizontalTarget = Vector3.new(lookTarget.X, barrelPosition.Y, lookTarget.Z)

	if (horizontalTarget - barrelPosition).Magnitude < 1e-4 then
		return
	end

	activeWeaponMount.CFrame = CFrame.lookAt(barrelPosition, horizontalTarget)
end

local function onFireAction(_actionName: string, inputState: Enum.UserInputState, _inputObject: InputObject): Enum.ContextActionResult
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end

	if activeTurretModel == nil or fireWeaponRemote == nil then
		return Enum.ContextActionResult.Pass
	end

	if activeWeaponMount == nil or activeWeaponMount.Parent == nil then
		local mount = findTaggedDescendant(activeTurretModel, "WeaponMount", "BasePart")
		if mount == nil then
			return Enum.ContextActionResult.Sink
		end
		activeWeaponMount = mount :: BasePart
	end

	local muzzlePoint = activeWeaponMount:FindFirstChild("MuzzlePoint")
	local origin = activeWeaponMount.Position
	if muzzlePoint ~= nil and muzzlePoint:IsA("Attachment") then
		origin = muzzlePoint.WorldPosition
	end

	local aimDirection = getAimDirectionFromMouse(origin)
	if aimDirection == nil then
		return Enum.ContextActionResult.Sink
	end

	fireWeaponRemote:FireServer(aimDirection)
	return Enum.ContextActionResult.Sink
end

local function onExitAction(_actionName: string, inputState: Enum.UserInputState, _inputObject: InputObject): Enum.ContextActionResult
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end

	local character = localPlayer.Character
	if character ~= nil then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid ~= nil then
			humanoid.Sit = false
		end
	end

	return Enum.ContextActionResult.Sink
end

local function activateTurretMode(turretSeat: BasePart)
	local turretModel = turretSeat:FindFirstAncestorWhichIsA("Model")
	if turretModel == nil then
		return
	end

	activeTurretModel = turretModel
	activeSeat = turretSeat
	activeWeaponMount = findTaggedDescendant(turretModel, "WeaponMount", "BasePart") :: BasePart?

	ContextActionService:BindAction(FIRE_ACTION_NAME, onFireAction, false, Enum.UserInputType.MouseButton1)
	ContextActionService:BindAction(EXIT_ACTION_NAME, onExitAction, false, Enum.KeyCode.F)

	if barrelRenderConnection == nil then
		barrelRenderConnection = RunService.RenderStepped:Connect(updateBarrelRotation)
	end

	CombatHUD.showCrosshair(true)
	local entityId = turretModel:GetAttribute("EntityId")
	if type(entityId) == "string" then
		CombatHUD.showHP(entityId)
	else
		CombatHUD.hideHP()
	end
end

local function onHumanoidSeated(isSeated: boolean, seatPart: BasePart?)
	if isSeated and seatPart ~= nil and CollectionService:HasTag(seatPart, "TurretSeat") then
		activateTurretMode(seatPart)
		return
	end

	deactivateTurretMode()
end

local function bindCharacter(character: Model)
	deactivateTurretMode()

	if seatedConnection ~= nil then
		seatedConnection:Disconnect()
		seatedConnection = nil
	end

	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	seatedConnection = humanoid.Seated:Connect(onHumanoidSeated)

	if humanoid.SeatPart ~= nil and CollectionService:HasTag(humanoid.SeatPart, "TurretSeat") then
		activateTurretMode(humanoid.SeatPart)
	end
end

function WeaponClient.init(remotes: Folder)
	fireWeaponRemote = remotes:WaitForChild("FireWeapon") :: RemoteEvent

	if characterAddedConnection == nil then
		characterAddedConnection = localPlayer.CharacterAdded:Connect(bindCharacter)
	end

	local existingCharacter = localPlayer.Character
	if existingCharacter ~= nil then
		bindCharacter(existingCharacter)
	end
end

return WeaponClient
