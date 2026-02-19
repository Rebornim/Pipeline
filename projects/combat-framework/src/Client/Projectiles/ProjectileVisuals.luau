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

type ProjectileVisualProfile = {
	boltLengthScale: number,
	boltWidthScale: number,
	bulletScale: number,
	trailWidthScale: number,
	lightBrightnessScale: number,
	lightRangeScale: number,
	whizPitchScale: number,
	impactScale: number,
	impactEmitScale: number,
}

type ActiveBolt = {
	boltPart: BasePart,
	bulletPart: BasePart?,
	origin: Vector3,
	direction: Vector3,
	speed: number,
	maxRange: number,
	createdAt: number,
	damageType: string?,
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
local warnedMissingShieldImpactTemplate = false
local warnedMissingFireSoundTemplate = false
local warnedMissingFireSoundTemplateByDamageType: { [string]: boolean } = {}
local warnedMissingImpactSoundTemplate = false
local warnedMissingShieldImpactSoundTemplate = false
local warnedMissingShieldBreakSoundTemplate = false

local IMPACT_BURST_COUNTS: { [string]: number } = {
	Smoke = 18,
	Flash = 2,
	Sparks = 50,
	Explosion = 24,
}

local IMPACT_AUTO_DISABLE_TIME = 0.15
local IMPACT_CLEANUP_TIME = 5
local DEFAULT_VISUAL_PROFILE: ProjectileVisualProfile = {
	boltLengthScale = 1.0,
	boltWidthScale = 1.0,
	bulletScale = 1.0,
	trailWidthScale = 1.0,
	lightBrightnessScale = 1.0,
	lightRangeScale = 1.0,
	whizPitchScale = 1.0,
	impactScale = 1.0,
	impactEmitScale = 1.0,
}
local DAMAGE_TYPE_VISUAL_PROFILES: { [string]: ProjectileVisualProfile } = {
	blaster = DEFAULT_VISUAL_PROFILE,
	turbolaser = {
		boltLengthScale = 1.55,
		boltWidthScale = 1.8,
		bulletScale = 1.25,
		trailWidthScale = 1.9,
		lightBrightnessScale = 1.45,
		lightRangeScale = 1.35,
		whizPitchScale = 0.82,
		impactScale = 1.25,
		impactEmitScale = 1.35,
	},
	ion = {
		boltLengthScale = 1.15,
		boltWidthScale = 1.1,
		bulletScale = 1.05,
		trailWidthScale = 1.2,
		lightBrightnessScale = 1.25,
		lightRangeScale = 1.2,
		whizPitchScale = 1.2,
		impactScale = 1.1,
		impactEmitScale = 1.15,
	},
	proton_torpedo = {
		boltLengthScale = 2.2,
		boltWidthScale = 2.55,
		bulletScale = 2.0,
		trailWidthScale = 2.65,
		lightBrightnessScale = 1.95,
		lightRangeScale = 1.6,
		whizPitchScale = 0.7,
		impactScale = 1.85,
		impactEmitScale = 1.85,
	},
	concussion_missile = {
		boltLengthScale = 1.75,
		boltWidthScale = 2.0,
		bulletScale = 1.55,
		trailWidthScale = 2.2,
		lightBrightnessScale = 1.65,
		lightRangeScale = 1.45,
		whizPitchScale = 0.85,
		impactScale = 1.45,
		impactEmitScale = 1.5,
	},
}

local function getVisualProfileForDamageType(damageType: string?): ProjectileVisualProfile
	if type(damageType) == "string" then
		local mapped = DAMAGE_TYPE_VISUAL_PROFILES[damageType]
		if mapped ~= nil then
			return mapped
		end
	end
	return DEFAULT_VISUAL_PROFILE
end

local function scaleNumberSequence(sequence: NumberSequence, scale: number): NumberSequence
	local keypoints = sequence.Keypoints
	local scaledPoints: { NumberSequenceKeypoint } = table.create(#keypoints)
	for index, point in ipairs(keypoints) do
		scaledPoints[index] =
			NumberSequenceKeypoint.new(point.Time, math.max(0, point.Value * scale), math.max(0, point.Envelope * scale))
	end
	return NumberSequence.new(scaledPoints)
end

local function applyProjectilePartVisualProfile(
	part: BasePart,
	profile: ProjectileVisualProfile,
	isBolt: boolean
)
	if isBolt then
		part.Size = Vector3.new(
			part.Size.X * profile.boltWidthScale,
			part.Size.Y * profile.boltWidthScale,
			part.Size.Z * profile.boltLengthScale
		)
	else
		part.Size *= profile.bulletScale
	end

	for _, descendant in ipairs(part:GetDescendants()) do
		if descendant:IsA("Trail") then
			descendant.WidthScale = scaleNumberSequence(descendant.WidthScale, profile.trailWidthScale)
		elseif descendant:IsA("PointLight") then
			descendant.Brightness *= profile.lightBrightnessScale
			descendant.Range *= profile.lightRangeScale
		end
	end
end

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

local function getImpactTemplateFolder(impactType: string?): Folder?
	local combatAssets = ReplicatedStorage:FindFirstChild("CombatAssets")
	if combatAssets == nil or not combatAssets:IsA("Folder") then
		return nil
	end

	local impactParticles = combatAssets:FindFirstChild("ImpactParticles")
	if impactParticles == nil or not impactParticles:IsA("Folder") then
		return nil
	end

	local templateName = if impactType == "shield" then "shieldHit" else "bulletHit"
	local template = impactParticles:FindFirstChild(templateName)
	if template == nil or not template:IsA("Folder") then
		return nil
	end

	return template
end

local function getFirstSoundDescendant(folder: Folder): Sound?
	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("Sound") then
			return child
		end
	end

	return nil
end

local function getFireSoundTemplate(damageType: string?): Sound?
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

	if type(damageType) == "string" and damageType ~= "" then
		local damageTypeNode = fireFolder:FindFirstChild(damageType)
		if damageTypeNode ~= nil then
			if damageTypeNode:IsA("Sound") then
				return damageTypeNode
			end
			if damageTypeNode:IsA("Folder") then
				local typedSound = getFirstSoundDescendant(damageTypeNode)
				if typedSound ~= nil then
					return typedSound
				end
			end
		end
	end

	return getFirstSoundDescendant(fireFolder)
end

local function getImpactSoundTemplates(impactType: string?): { Sound }
	local templates: { Sound } = {}

	local combatAssets = ReplicatedStorage:FindFirstChild("CombatAssets")
	if combatAssets == nil or not combatAssets:IsA("Folder") then
		return templates
	end

	local audioFolder = combatAssets:FindFirstChild("Audio")
	if audioFolder == nil or not audioFolder:IsA("Folder") then
		return templates
	end

	local folderName = if impactType == "shield" then "ShieldImpact" else "Impact"
	local impactFolderAudio = audioFolder:FindFirstChild(folderName)
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

local function getShieldBreakSoundTemplates(): { Sound }
	local templates: { Sound } = {}

	local combatAssets = ReplicatedStorage:FindFirstChild("CombatAssets")
	if combatAssets == nil or not combatAssets:IsA("Folder") then
		return templates
	end

	local audioFolder = combatAssets:FindFirstChild("Audio")
	if audioFolder == nil or not audioFolder:IsA("Folder") then
		return templates
	end

	local breakFolder = audioFolder:FindFirstChild("ShieldBreak")
	if breakFolder == nil or not breakFolder:IsA("Folder") then
		return templates
	end

	for _, child in ipairs(breakFolder:GetChildren()) do
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

local function playFireSoundAt(position: Vector3, damageType: string?)
	local soundTemplate = getFireSoundTemplate(damageType)
	if soundTemplate == nil then
		local damageTypeKey = if type(damageType) == "string" and damageType ~= "" then damageType else "default"
		if damageTypeKey ~= "default" then
			if not warnedMissingFireSoundTemplateByDamageType[damageTypeKey] then
				warn(string.format(
					"[P3_AUDIO] Missing fire sound for damageType '%s' in ReplicatedStorage.CombatAssets.Audio.Fire.%s (or shared Audio.Fire fallback)",
					damageTypeKey,
					damageTypeKey
				))
				warnedMissingFireSoundTemplateByDamageType[damageTypeKey] = true
			end
		elseif not warnedMissingFireSoundTemplate then
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

local function playImpactSoundAt(position: Vector3, impactType: string?)
	local soundTemplates = getImpactSoundTemplates(impactType)
	if #soundTemplates == 0 then
		if impactType == "shield" then
			if not warnedMissingShieldImpactSoundTemplate then
				warn("[P2_AUDIO] Missing shield impact sound template in ReplicatedStorage.CombatAssets.Audio.ShieldImpact")
				warnedMissingShieldImpactSoundTemplate = true
			end
		elseif not warnedMissingImpactSoundTemplate then
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

local function playShieldBreakSoundAt(position: Vector3)
	local soundTemplates = getShieldBreakSoundTemplates()
	if #soundTemplates == 0 then
		soundTemplates = getImpactSoundTemplates("shield")
		if #soundTemplates == 0 then
			if not warnedMissingShieldBreakSoundTemplate then
				warn("[P2_AUDIO] Missing shield break sound template in ReplicatedStorage.CombatAssets.Audio.ShieldBreak")
				warnedMissingShieldBreakSoundTemplate = true
			end
			return
		end
	end

	local soundPart = Instance.new("Part")
	soundPart.Name = "ShieldBreakSound"
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
		local breakSound = soundTemplate:Clone()
		breakSound.Looped = false
		breakSound.Parent = soundPart
		breakSound:Play()
		cleanupDelay = math.max(cleanupDelay, breakSound.TimeLength + 0.15)
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

local function spawnImpactEffect(hitPosition: Vector3, hitNormal: Vector3, impactType: string?, damageType: string?)
	local visualProfile = getVisualProfileForDamageType(damageType)
	local impactTemplate = getImpactTemplateFolder(impactType)
	if impactTemplate == nil then
		if impactType == "shield" then
			if not warnedMissingShieldImpactTemplate then
				warn("[P2_IMPACT] Missing ReplicatedStorage.CombatAssets.ImpactParticles.shieldHit template folder.")
				warnedMissingShieldImpactTemplate = true
			end
		elseif not warnedMissingImpactTemplate then
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
	effectPart.Name = if impactType == "shield" then "ShieldImpact" else "BulletImpact"
	effectPart.Transparency = 1
	effectPart.Size = Vector3.new(2, 2, 2) * visualProfile.impactScale
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
			effect.Size = scaleNumberSequence(effect.Size, visualProfile.impactScale)
			effect:Emit(math.max(0, math.floor(getBurstCount(effect) * visualProfile.impactEmitScale + 0.5)))
		elseif effect:IsA("Sound") then
			effect:Play()
		elseif effect:IsA("PointLight") then
			effect.Range *= visualProfile.impactScale
			effect.Brightness *= visualProfile.lightBrightnessScale
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

local function playWhizSound(part: BasePart, profile: ProjectileVisualProfile)
	local whiz = part:FindFirstChild("Whiz", true)
	if whiz ~= nil and whiz:IsA("Sound") then
		whiz.PlaybackSpeed *= profile.whizPitchScale
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

local function createFallbackBoltPart(
	projectileId: string,
	boltColor: Color3?,
	visualProfile: ProjectileVisualProfile
): BasePart
	local boltPart = Instance.new("Part")
	boltPart.Name = "Bolt_" .. projectileId
	boltPart.Size = Vector3.new(CombatConfig.BoltWidth, CombatConfig.BoltWidth, CombatConfig.BoltLength)
	boltPart.Color = if boltColor ~= nil then boltColor else CombatConfig.BoltColor
	boltPart.Material = CombatConfig.BoltMaterial
	prepareVisualPart(boltPart)
	applyProjectilePartVisualProfile(boltPart, visualProfile, true)
	boltPart.Parent = ensureBoltFolder()
	return boltPart
end

local function createVisualPartsFromTemplate(
	projectileId: string,
	boltColor: Color3?,
	damageType: string?
): (BasePart, BasePart?)
	local visualProfile = getVisualProfileForDamageType(damageType)
	local templateFolder = getProjectileTemplateFolder()
	if templateFolder == nil then
		if not warnedMissingTemplate then
			warn("[P1_VISUAL] Missing ReplicatedStorage.CombatAssets.ProjectileTemplate. Using fallback bolt.")
			warnedMissingTemplate = true
		end
		return createFallbackBoltPart(projectileId, boltColor, visualProfile), nil
	end

	local boltTemplate = templateFolder:FindFirstChild("Bolt")
	if boltTemplate == nil or not boltTemplate:IsA("BasePart") then
		if not warnedMissingTemplate then
			warn("[P1_VISUAL] Missing template part 'Bolt'. Using fallback bolt.")
			warnedMissingTemplate = true
		end
		return createFallbackBoltPart(projectileId, boltColor, visualProfile), nil
	end

	local boltPart = boltTemplate:Clone()
	boltPart.Name = "Bolt_" .. projectileId
	prepareVisualPart(boltPart)
	applyProjectilePartVisualProfile(boltPart, visualProfile, true)
	boltPart.Parent = ensureBoltFolder()
	applyBoltVisualColor(boltPart, boltColor)
	playWhizSound(boltPart, visualProfile)

	local bulletPart: BasePart? = nil
	local bulletTemplate = templateFolder:FindFirstChild("Bullet")
	if bulletTemplate ~= nil and bulletTemplate:IsA("BasePart") then
		bulletPart = bulletTemplate:Clone()
		bulletPart.Name = "Bullet_" .. projectileId
		prepareVisualPart(bulletPart)
		applyProjectilePartVisualProfile(bulletPart, visualProfile, false)
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
	local damageType = if type(payload.damageType) == "string" then payload.damageType else nil
	playFireSoundAt(payload.origin, damageType)
	local boltColor = if typeof(payload.boltColor) == "Color3" then (payload.boltColor :: Color3) else nil

	local boltPart, bulletPart = createVisualPartsFromTemplate(payload.projectileId, boltColor, damageType)

	activeBolts[payload.projectileId] = {
		boltPart = boltPart,
		bulletPart = bulletPart,
		origin = payload.origin,
		direction = payload.direction,
		speed = payload.speed,
		maxRange = payload.maxRange,
		createdAt = tick(),
		damageType = damageType,
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
	local impactType = if type(payload.impactType) == "string" then payload.impactType else nil
	local damageType = if bolt ~= nil then bolt.damageType else nil
	local shieldBroken = payload.shieldBroken == true
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
			playImpactSoundAt(payload.hitPosition, impactType)
			if impactType == "shield" and shieldBroken then
				playShieldBreakSoundAt(payload.hitPosition)
			end
			spawnImpactEffect(payload.hitPosition, payload.hitNormal, impactType, damageType)
		end)
		return
	end

	destroyBolt(payload.projectileId)
	playImpactSoundAt(payload.hitPosition, impactType)
	if impactType == "shield" and shieldBroken then
		playShieldBreakSoundAt(payload.hitPosition)
	end
	spawnImpactEffect(payload.hitPosition, payload.hitNormal, impactType, damageType)
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
