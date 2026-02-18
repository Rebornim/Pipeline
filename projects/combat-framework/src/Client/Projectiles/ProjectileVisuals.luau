--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local sharedRoot = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatConfig = require(sharedRoot:WaitForChild("CombatConfig"))

type ActiveBolt = {
	part: BasePart,
	origin: Vector3,
	direction: Vector3,
	speed: number,
	maxRange: number,
	createdAt: number,
}

local ProjectileVisuals = {}

local activeBolts: { [string]: ActiveBolt } = {}
local renderConnection: RBXScriptConnection? = nil
local projectileFiredConnection: RBXScriptConnection? = nil
local boltFolder: Folder? = nil

local function ensureBoltFolder(): Folder
	if boltFolder ~= nil and boltFolder.Parent ~= nil then
		return boltFolder
	end

	local existing = Workspace:FindFirstChild("CombatBoltVisuals")
	if existing ~= nil and existing:IsA("Folder") then
		boltFolder = existing
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = "CombatBoltVisuals"
	folder.Parent = Workspace
	boltFolder = folder
	return folder
end

local function destroyBolt(projectileId: string)
	local bolt = activeBolts[projectileId]
	if bolt == nil then
		return
	end

	if bolt.part.Parent ~= nil then
		bolt.part:Destroy()
	end
	activeBolts[projectileId] = nil
end

local function onRenderStepped()
	local now = tick()
	for projectileId, bolt in pairs(activeBolts) do
		local elapsed = now - bolt.createdAt
		local distance = bolt.speed * elapsed
		if distance >= bolt.maxRange then
			destroyBolt(projectileId)
		else
			local position = bolt.origin + bolt.direction * distance
			bolt.part.CFrame = CFrame.lookAt(position, position + bolt.direction)
		end
	end
end

local function onProjectileFired(payload)
	if type(payload) ~= "table" then
		return
	end

	if type(payload.projectileId) ~= "string"
		or typeof(payload.origin) ~= "Vector3"
		or typeof(payload.direction) ~= "Vector3"
		or type(payload.speed) ~= "number"
		or type(payload.maxRange) ~= "number"
	then
		return
	end

	destroyBolt(payload.projectileId)

	local boltPart = Instance.new("Part")
	boltPart.Name = "Bolt_" .. payload.projectileId
	boltPart.Size = Vector3.new(CombatConfig.BoltWidth, CombatConfig.BoltWidth, CombatConfig.BoltLength)
	boltPart.Color = CombatConfig.BoltColor
	boltPart.Material = CombatConfig.BoltMaterial
	boltPart.Anchored = true
	boltPart.CanCollide = false
	boltPart.CanQuery = false
	boltPart.CanTouch = false
	boltPart.CastShadow = false
	boltPart.Parent = ensureBoltFolder()

	activeBolts[payload.projectileId] = {
		part = boltPart,
		origin = payload.origin,
		direction = payload.direction,
		speed = payload.speed,
		maxRange = payload.maxRange,
		createdAt = tick(),
	}
end

function ProjectileVisuals.init(remotes: Folder)
	if renderConnection == nil then
		renderConnection = RunService.RenderStepped:Connect(onRenderStepped)
	end

	if projectileFiredConnection == nil then
		local projectileFiredRemote = remotes:WaitForChild("ProjectileFired") :: RemoteEvent
		projectileFiredConnection = projectileFiredRemote.OnClientEvent:Connect(onProjectileFired)
	end
end

return ProjectileVisuals
