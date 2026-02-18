--!strict

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local sharedRoot = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatConfig = require(sharedRoot:WaitForChild("CombatConfig"))
local CombatTypes = require(sharedRoot:WaitForChild("CombatTypes"))

type ProjectileFiredPayload = CombatTypes.ProjectileFiredPayload
type ProjectileImpactPayload = CombatTypes.ProjectileImpactPayload

type ActiveBolt = {
	boltPart: BasePart,
	bulletPart: BasePart?,
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
local projectileImpactConnection: RBXScriptConnection? = nil
local boltFolder: Folder? = nil
local impactFolder: Folder? = nil
local warnedMissingTemplate = false
local warnedMissingImpactTemplate = false
local warnedMissingFireSoundTemplate = false
local warnedMissingImpactSoundTemplate = false

local IMPACT_BURST_COUNTS: { [string]: number } = {
	Smoke = 18,
	Flash = 2,
	Sparks = 50,
	Explosion = 24,
}

local IMPACT_AUTO_DISABLE_TIME = 0.15
local IMPACT_CLEANUP_TIME = 5

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

local function ensureImpactFolder(): Folder
	if impactFolder ~= nil and impactFolder.Parent ~= nil then
		return impactFolder
	end

	local existing = Workspace:FindFirstChild("CombatImpactVisuals")
	if existing ~= nil and existing:IsA("Folder") then
		impactFolder = existing
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = "CombatImpactVisuals"
	folder.Parent = Workspace
	impactFolder = folder
	return folder
end

local function destroyBolt(projectileId: string)
	local bolt = activeBolts[projectileId]
	if bolt == nil then
		return
	end

	if bolt.boltPart.Parent ~= nil then
		bolt.boltPart:Destroy()
	end
	if bolt.bulletPart ~= nil and bolt.bulletPart.Parent ~= nil then
		bolt.bulletPart:Destroy()
	end
	activeBolts[projectileId] = nil
end

local function getProjectileTemplateFolder(): Folder?
	local combatAssets = ReplicatedStorage:FindFirstChild("CombatAssets")
	if combatAssets == nil or not combatAssets:IsA("Folder") then
		return nil
	end

	local projectileTemplate = combatAssets:FindFirstChild("ProjectileTemplate")
	if projectileTemplate == nil or not projectileTemplate:IsA("Folder") then
		return nil
	end

	return projectileTemplate
end

local function getImpactTemplateFolder(): Folder?
	local combatAssets = ReplicatedStorage:FindFirstChild("CombatAssets")
	if combatAssets == nil or not combatAssets:IsA("Folder") then
		return nil
	end

	local impactParticles = combatAssets:FindFirstChild("ImpactParticles")
	if impactParticles == nil or not impactParticles:IsA("Folder") then
		return nil
	end

	local bulletHitTemplate = impactParticles:FindFirstChild("bulletHit")
	if bulletHitTemplate == nil or not bulletHitTemplate:IsA("Folder") then
		return nil
	end

	return bulletHitTemplate
end

local function getFireSoundTemplate(): Sound?
	local combatAssets = ReplicatedStorage:FindFirstChild("CombatAssets")
	if combatAssets == nil or not combatAssets:IsA("Folder") then
		return nil
	end

	local audioFolder = combatAssets:FindFirstChild("Audio")
	if audioFolder == nil or not audioFolder:IsA("Folder") then
		return nil
	end

	local fireFolder = audioFolder:FindFirstChild("Fire")
	if fireFolder == nil or not fireFolder:IsA("Folder") then
		return nil
	end

	for _, child in ipairs(fireFolder:GetChildren()) do
		if child:IsA("Sound") then
			return child
		end
	end

	return nil
end

local function getImpactSoundTemplates(): { Sound }
	local templates: { Sound } = {}

	local combatAssets = ReplicatedStorage:FindFirstChild("CombatAssets")
	if combatAssets == nil or not combatAssets:IsA("Folder") then
		return templates
	end

	local audioFolder = combatAssets:FindFirstChild("Audio")
	if audioFolder == nil or not audioFolder:IsA("Folder") then
		return templates
	end

	local impactFolderAudio = audioFolder:FindFirstChild("Impact")
	if impactFolderAudio == nil or not impactFolderAudio:IsA("Folder") then
		return templates
	end

	for _, child in ipairs(impactFolderAudio:GetChildren()) do
		if child:IsA("Sound") then
			table.insert(templates, child)
		end
	end

	return templates
end

local function prepareVisualPart(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
end

local function playFireSoundAt(position: Vector3)
	local soundTemplate = getFireSoundTemplate()
	if soundTemplate == nil then
		if not warnedMissingFireSoundTemplate then
			warn("[P1_AUDIO] Missing fire sound template in ReplicatedStorage.CombatAssets.Audio.Fire")
			warnedMissingFireSoundTemplate = true
		end
		return
	end

	local soundPart = Instance.new("Part")
	soundPart.Name = "ShotSound"
	soundPart.Size = Vector3.new(0.25, 0.25, 0.25)
	soundPart.Transparency = 1
	soundPart.Anchored = true
	soundPart.CanCollide = false
	soundPart.CanQuery = false
	soundPart.CanTouch = false
	soundPart.CFrame = CFrame.new(position)
	soundPart.Parent = ensureBoltFolder()

	local shot = soundTemplate:Clone()
	shot.Looped = false
	shot.Parent = soundPart
	shot:Play()

	local cleanupDelay = math.max(1, shot.TimeLength + 0.15)
	Debris:AddItem(soundPart, cleanupDelay)
end

local function playImpactSoundAt(position: Vector3)
	local soundTemplates = getImpactSoundTemplates()
	if #soundTemplates == 0 then
		if not warnedMissingImpactSoundTemplate then
			warn("[P1_AUDIO] Missing impact sound template in ReplicatedStorage.CombatAssets.Audio.Impact")
			warnedMissingImpactSoundTemplate = true
		end
		return
	end

	local soundPart = Instance.new("Part")
	soundPart.Name = "ImpactSound"
	soundPart.Size = Vector3.new(0.25, 0.25, 0.25)
	soundPart.Transparency = 1
	soundPart.Anchored = true
	soundPart.CanCollide = false
	soundPart.CanQuery = false
	soundPart.CanTouch = false
	soundPart.CFrame = CFrame.new(position)
	soundPart.Parent = ensureImpactFolder()

	local cleanupDelay = 1
	for _, soundTemplate in ipairs(soundTemplates) do
		local impact = soundTemplate:Clone()
		impact.Looped = false
		impact.Parent = soundPart
		impact:Play()
		cleanupDelay = math.max(cleanupDelay, impact.TimeLength + 0.15)
	end

	Debris:AddItem(soundPart, cleanupDelay)
end

local function getBurstCount(emitter: ParticleEmitter): number
	local attributeBurstCount = emitter:GetAttribute("EmitCount")
	if type(attributeBurstCount) == "number" then
		return math.max(0, math.floor(attributeBurstCount + 0.5))
	end

	local mapped = IMPACT_BURST_COUNTS[emitter.Name]
	if mapped ~= nil then
		return mapped
	end

	return 12
end

local function spawnImpactEffect(hitPosition: Vector3, hitNormal: Vector3)
	local impactTemplate = getImpactTemplateFolder()
	if impactTemplate == nil then
		if not warnedMissingImpactTemplate then
			warn("[P1_IMPACT] Missing ReplicatedStorage.CombatAssets.ImpactParticles.bulletHit template folder.")
			warnedMissingImpactTemplate = true
		end
		return
	end

	local normal = hitNormal
	if normal.Magnitude <= 0.001 then
		normal = Vector3.new(0, 1, 0)
	else
		normal = normal.Unit
	end

	local effectPart = Instance.new("Part")
	effectPart.Name = "BulletImpact"
	effectPart.Transparency = 1
	effectPart.Size = Vector3.new(2, 2, 2)
	effectPart.Anchored = true
	effectPart.CanCollide = false
	effectPart.CanTouch = false
	effectPart.CanQuery = false
	effectPart.CastShadow = false
	effectPart.CFrame = CFrame.lookAt(hitPosition + normal * 0.05, hitPosition + normal * 1.05)
	effectPart.Parent = ensureImpactFolder()

	local attachmentMap: { [Attachment]: Attachment } = {}
	for _, descendant in ipairs(impactTemplate:GetDescendants()) do
		if descendant:IsA("Attachment") then
			local attachmentClone = descendant:Clone()
			attachmentClone.Parent = effectPart
			attachmentMap[descendant] = attachmentClone
		end
	end

	local spawnedEffects: { Instance } = {}
	for _, descendant in ipairs(impactTemplate:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") or descendant:IsA("Sound") or descendant:IsA("PointLight") then
			local effectClone = descendant:Clone()
			local targetParent: Instance = effectPart
			local templateParent = descendant.Parent
			if templateParent ~= nil and templateParent:IsA("Attachment") then
				local mappedAttachment = attachmentMap[templateParent]
				if mappedAttachment ~= nil then
					targetParent = mappedAttachment
				end
			end

			effectClone.Parent = targetParent
			table.insert(spawnedEffects, effectClone)
		end
	end

	for _, effect in ipairs(spawnedEffects) do
		if effect:IsA("ParticleEmitter") then
			effect:Emit(getBurstCount(effect))
		elseif effect:IsA("Sound") then
			effect:Play()
		elseif effect:IsA("PointLight") then
			effect.Enabled = true
		end
	end

	task.delay(IMPACT_AUTO_DISABLE_TIME, function()
		if effectPart.Parent == nil then
			return
		end

		for _, effect in ipairs(spawnedEffects) do
			if effect.Parent ~= nil and (effect:IsA("ParticleEmitter") or effect:IsA("PointLight")) then
				effect.Enabled = false
			end
		end
	end)

	Debris:AddItem(effectPart, IMPACT_CLEANUP_TIME)
end

local function playWhizSound(part: BasePart)
	local whiz = part:FindFirstChild("Whiz", true)
	if whiz ~= nil and whiz:IsA("Sound") then
		whiz:Play()
	end
end

local function applyBoltVisualColor(boltPart: BasePart, boltColor: Color3?)
	if boltColor == nil then
		return
	end

	boltPart.Color = boltColor
	for _, descendant in ipairs(boltPart:GetDescendants()) do
		if descendant:IsA("Trail") and descendant.Name == "BulletTrailColor" then
			descendant.Color = ColorSequence.new(boltColor)
		elseif descendant:IsA("PointLight") and descendant.Name == "PointLight" then
			descendant.Color = boltColor
		end
	end
end

local function createFallbackBoltPart(projectileId: string, boltColor: Color3?): BasePart
	local boltPart = Instance.new("Part")
	boltPart.Name = "Bolt_" .. projectileId
	boltPart.Size = Vector3.new(CombatConfig.BoltWidth, CombatConfig.BoltWidth, CombatConfig.BoltLength)
	boltPart.Color = if boltColor ~= nil then boltColor else CombatConfig.BoltColor
	boltPart.Material = CombatConfig.BoltMaterial
	prepareVisualPart(boltPart)
	boltPart.Parent = ensureBoltFolder()
	return boltPart
end

local function createVisualPartsFromTemplate(projectileId: string, boltColor: Color3?): (BasePart, BasePart?)
	local templateFolder = getProjectileTemplateFolder()
	if templateFolder == nil then
		if not warnedMissingTemplate then
			warn("[P1_VISUAL] Missing ReplicatedStorage.CombatAssets.ProjectileTemplate. Using fallback bolt.")
			warnedMissingTemplate = true
		end
		return createFallbackBoltPart(projectileId, boltColor), nil
	end

	local boltTemplate = templateFolder:FindFirstChild("Bolt")
	if boltTemplate == nil or not boltTemplate:IsA("BasePart") then
		if not warnedMissingTemplate then
			warn("[P1_VISUAL] Missing template part 'Bolt'. Using fallback bolt.")
			warnedMissingTemplate = true
		end
		return createFallbackBoltPart(projectileId, boltColor), nil
	end

	local boltPart = boltTemplate:Clone()
	boltPart.Name = "Bolt_" .. projectileId
	prepareVisualPart(boltPart)
	boltPart.Parent = ensureBoltFolder()
	applyBoltVisualColor(boltPart, boltColor)
	playWhizSound(boltPart)

	local bulletPart: BasePart? = nil
	local bulletTemplate = templateFolder:FindFirstChild("Bullet")
	if bulletTemplate ~= nil and bulletTemplate:IsA("BasePart") then
		bulletPart = bulletTemplate:Clone()
		bulletPart.Name = "Bullet_" .. projectileId
		prepareVisualPart(bulletPart)
		bulletPart.Parent = ensureBoltFolder()
	end

	return boltPart, bulletPart
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
			local projectileCFrame = CFrame.lookAt(position, position + bolt.direction)
			bolt.boltPart.CFrame = projectileCFrame
			if bolt.bulletPart ~= nil then
				bolt.bulletPart.CFrame = projectileCFrame
			end
		end
	end
end

local function onProjectileFired(payload: ProjectileFiredPayload)
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
	playFireSoundAt(payload.origin)
	local boltColor = if typeof(payload.boltColor) == "Color3" then (payload.boltColor :: Color3) else nil

	local boltPart, bulletPart = createVisualPartsFromTemplate(payload.projectileId, boltColor)

	activeBolts[payload.projectileId] = {
		boltPart = boltPart,
		bulletPart = bulletPart,
		origin = payload.origin,
		direction = payload.direction,
		speed = payload.speed,
		maxRange = payload.maxRange,
		createdAt = tick(),
	}
end

local function onProjectileImpact(payload: ProjectileImpactPayload)
	if type(payload) ~= "table" then
		return
	end

	if type(payload.projectileId) ~= "string"
		or typeof(payload.hitPosition) ~= "Vector3"
		or typeof(payload.hitNormal) ~= "Vector3"
	then
		return
	end

	local bolt = activeBolts[payload.projectileId]
	local impactDelay = 0
	if bolt ~= nil then
		local speed = math.max(1e-4, bolt.speed)
		local travelDistance = (payload.hitPosition - bolt.origin).Magnitude
		local expectedImpactTime = bolt.createdAt + (travelDistance / speed)
		impactDelay = math.max(0, expectedImpactTime - tick())
	end

	if impactDelay > 0 then
		task.delay(impactDelay, function()
			destroyBolt(payload.projectileId)
			playImpactSoundAt(payload.hitPosition)
			spawnImpactEffect(payload.hitPosition, payload.hitNormal)
		end)
		return
	end

	destroyBolt(payload.projectileId)
	playImpactSoundAt(payload.hitPosition)
	spawnImpactEffect(payload.hitPosition, payload.hitNormal)
end

function ProjectileVisuals.init(remotes: Folder)
	if renderConnection == nil then
		renderConnection = RunService.RenderStepped:Connect(onRenderStepped)
	end

	if projectileFiredConnection == nil then
		local projectileFiredRemote = remotes:WaitForChild("ProjectileFired") :: RemoteEvent
		projectileFiredConnection = projectileFiredRemote.OnClientEvent:Connect(onProjectileFired)
	end

	if projectileImpactConnection == nil then
		local projectileImpactRemote = remotes:WaitForChild("ProjectileImpact") :: RemoteEvent
		projectileImpactConnection = projectileImpactRemote.OnClientEvent:Connect(onProjectileImpact)
	end
end

return ProjectileVisuals
