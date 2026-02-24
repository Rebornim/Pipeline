--!strict

local ContentProvider = game:GetService("ContentProvider")
local Debris = game:GetService("Debris")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
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
	lastUpdatedAt: number,
	damageType: string?,
	targetEntityId: string?,
	homingTurnRate: number?,
	currentPosition: Vector3?,
	artilleryGravity: number?,
	currentVelocity: Vector3?,
	fireSound: string?,
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

local PLAYER_TARGET_PREFIX = "player_"
local clientVisualRaycastParams = RaycastParams.new()
clientVisualRaycastParams.FilterType = Enum.RaycastFilterType.Exclude
clientVisualRaycastParams.IgnoreWater = true

local IMPACT_BURST_COUNTS: { [string]: number } = {
	Smoke = 18,
	Flash = 2,
	Sparks = 50,
	Explosion = 24,
}

local IMPACT_AUTO_DISABLE_TIME = 0.15
local IMPACT_CLEANUP_TIME = 5

local REVERB_START_DISTANCE = 100
local REVERB_MAX_DISTANCE = 900
local REVERB_DRY_LEVEL_CLOSE = 0
local REVERB_DRY_LEVEL_FAR = -6
local REVERB_WET_LEVEL_CLOSE = -20
local REVERB_WET_LEVEL_FAR = 0
local REVERB_DECAY_CLOSE = 0.5
local REVERB_DECAY_FAR = 2.5
local DEFAULT_VISUAL_PROFILE: ProjectileVisualProfile = {
	boltLengthScale = 1.0,
	boltWidthScale = 1.0,
	bulletScale = 1.0,
	trailWidthScale = 1.0,
	lightBrightnessScale = 1.0,
	lightRangeScale = 1.0,
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
		impactScale = 1.45,
		impactEmitScale = 1.5,
	},
	artillery_shell = {
		boltLengthScale = 5.0,
		boltWidthScale = 5.0,
		bulletScale = 4.0,
		trailWidthScale = 5.0,
		lightBrightnessScale = 3.0,
		lightRangeScale = 3.5,
		impactScale = 4.0,
		impactEmitScale = 4.0,
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
	-- Keep metadata alive briefly so impact handler can read fireSound/damageType
	-- even if the visual was destroyed before the impact event arrives
	task.delay(2, function()
		if activeBolts[projectileId] == bolt then
			activeBolts[projectileId] = nil
		end
	end)
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



local MISSILE_DAMAGE_TYPES: { [string]: boolean } = {
	proton_torpedo = true,
	concussion_missile = true,
	artillery_shell = true,
}
local SMOKE_TRAIL_TEXTURE = "rbxassetid://716847870"

local function prepareVisualPart(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
end

local function applyDistanceReverb(sound: Sound, soundPosition: Vector3)
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end
	local distance = (soundPosition - camera.CFrame.Position).Magnitude
	if distance < REVERB_START_DISTANCE then
		return
	end
	local alpha = math.clamp((distance - REVERB_START_DISTANCE) / (REVERB_MAX_DISTANCE - REVERB_START_DISTANCE), 0, 1)
	local reverb = Instance.new("ReverbSoundEffect")
	reverb.DryLevel = REVERB_DRY_LEVEL_CLOSE + alpha * (REVERB_DRY_LEVEL_FAR - REVERB_DRY_LEVEL_CLOSE)
	reverb.WetLevel = REVERB_WET_LEVEL_CLOSE + alpha * (REVERB_WET_LEVEL_FAR - REVERB_WET_LEVEL_CLOSE)
	reverb.DecayTime = REVERB_DECAY_CLOSE + alpha * (REVERB_DECAY_FAR - REVERB_DECAY_CLOSE)
	reverb.Density = 0.5 + alpha * 0.5
	reverb.Diffusion = 0.5 + alpha * 0.5
	reverb.Parent = sound
end

local function resolveGroupSound(groupKey: string?, field: string): (string?, number)
	if type(groupKey) ~= "string" or groupKey == "" then
		return nil, 1
	end
	local group = CombatConfig.WeaponSounds[groupKey]
	if type(group) ~= "table" then
		return nil, 1
	end
	local volumeKey = field .. "Volume"
	local rawVolume = (group :: any)[volumeKey]
	local volume: number = if type(rawVolume) == "number" then rawVolume else 1

	local entry = (group :: any)[field]
	if type(entry) == "string" and entry ~= "" then
		return entry, volume
	end
	if type(entry) == "table" and #entry > 0 then
		return entry[math.random(1, #entry)], volume
	end
	return nil, 1
end

local function resolveAllGroupSounds(groupKey: string?, field: string): ({ string }, number)
	if type(groupKey) ~= "string" or groupKey == "" then
		return {}, 1
	end
	local group = CombatConfig.WeaponSounds[groupKey]
	if type(group) ~= "table" then
		return {}, 1
	end
	local volumeKey = field .. "Volume"
	local rawVolume = (group :: any)[volumeKey]
	local volume: number = if type(rawVolume) == "number" then rawVolume else 1

	local entry = (group :: any)[field]
	if type(entry) == "string" and entry ~= "" then
		return { entry }, volume
	end
	if type(entry) == "table" and #entry > 0 then
		local result: { string } = {}
		for _, id in ipairs(entry) do
			if type(id) == "string" and id ~= "" then
				table.insert(result, id)
			end
		end
		return result, volume
	end
	return {}, 1
end

local function playFireSoundAt(position: Vector3, damageType: string?, fireSound: string?)
	local fireAsset, volume = resolveGroupSound(fireSound, "fire")
	if fireAsset == nil then
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

	local shot = Instance.new("Sound")
	shot.SoundId = fireAsset
	shot.Volume = volume
	shot.Looped = false
	shot.RollOffMode = Enum.RollOffMode.InverseTapered
	shot.RollOffMinDistance = 60
	shot.RollOffMaxDistance = 1000
	applyDistanceReverb(shot, position)
	shot.Parent = soundPart
	shot:Play()

	Debris:AddItem(soundPart, 5)
end

local function playImpactSoundAt(position: Vector3, impactType: string?, fireSound: string?, parentPart: BasePart?)
	local impactAssets, volume = resolveAllGroupSounds(fireSound, "impact")
	if #impactAssets == 0 then
		return
	end

	local host: BasePart = parentPart :: any
	if host == nil then
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
		Debris:AddItem(soundPart, 5)
		host = soundPart
	end

	for _, assetId in ipairs(impactAssets) do
		local shot = Instance.new("Sound")
		shot.SoundId = assetId
		shot.Volume = volume
		shot.Looped = false
		shot.RollOffMode = Enum.RollOffMode.InverseTapered
		shot.RollOffMinDistance = 10
		shot.RollOffMaxDistance = 2100
		applyDistanceReverb(shot, position)
		shot.Parent = host
		shot:Play()
	end
end

local function playShieldBreakSoundAt(position: Vector3, fireSound: string?)
	local shieldBreakAsset, volume = resolveGroupSound(fireSound, "shieldBreak")
	if shieldBreakAsset == nil then
		return
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

	local breakSound = Instance.new("Sound")
	breakSound.SoundId = shieldBreakAsset
	breakSound.Volume = volume
	breakSound.Looped = false
	applyDistanceReverb(breakSound, position)
	breakSound.Parent = soundPart
	breakSound:Play()

	Debris:AddItem(soundPart, 5)
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

local function spawnImpactEffect(hitPosition: Vector3, hitNormal: Vector3, impactType: string?, damageType: string?): Part?
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
		return nil
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
		if descendant:IsA("ParticleEmitter") or descendant:IsA("PointLight") then
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
	return effectPart
end

local function playWhizSound(part: BasePart, fireSound: string?)
	local whizAsset, volume = resolveGroupSound(fireSound, "whiz")
	if whizAsset == nil then
		return
	end

	local whizSound = Instance.new("Sound")
	whizSound.Name = "Whiz"
	whizSound.SoundId = whizAsset
	whizSound.Volume = volume
	whizSound.Looped = true
	whizSound.RollOffMode = Enum.RollOffMode.InverseTapered
	whizSound.RollOffMinDistance = 100
	whizSound.RollOffMaxDistance = 1200
	whizSound.Parent = part
	whizSound:Play()
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

local function attachSmokeTrail(boltPart: BasePart, damageType: string?)
	if damageType == nil or not MISSILE_DAMAGE_TYPES[damageType] then
		return
	end

	local smoke = Instance.new("ParticleEmitter")
	smoke.Name = "SmokeTrail"
	smoke.Texture = SMOKE_TRAIL_TEXTURE
	smoke.EmissionDirection = Enum.NormalId.Back
	smoke.Rate = 35
	smoke.Lifetime = NumberRange.new(0.5, 1.2)
	smoke.Speed = NumberRange.new(0.5, 2.5)
	smoke.SpreadAngle = Vector2.new(12, 12)
	smoke.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4),
		NumberSequenceKeypoint.new(0.3, 1.0),
		NumberSequenceKeypoint.new(1, 2.5),
	})
	smoke.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(0.4, 0.45),
		NumberSequenceKeypoint.new(1, 1),
	})
	smoke.Color = ColorSequence.new(Color3.fromRGB(220, 220, 220), Color3.fromRGB(120, 120, 120))
	smoke.RotSpeed = NumberRange.new(-60, 60)
	smoke.Rotation = NumberRange.new(0, 360)
	smoke.LightEmission = 0
	smoke.LightInfluence = 1
	smoke.Parent = boltPart
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
	damageType: string?,
	fireSound: string?
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
	playWhizSound(boltPart, fireSound)

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

local function getModelAimPosition(model: Model): Vector3
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid ~= nil then
		local rootPart = humanoid.RootPart
		if rootPart ~= nil then
			return rootPart.Position
		end
	end
	return model:GetPivot().Position
end

local function findEntityModelById(entityId: string): Model?
	if string.sub(entityId, 1, #PLAYER_TARGET_PREFIX) == PLAYER_TARGET_PREFIX then
		local userIdStr = string.sub(entityId, #PLAYER_TARGET_PREFIX + 1)
		local userId = tonumber(userIdStr)
		if userId == nil then
			return nil
		end
		for _, player in ipairs(Players:GetPlayers()) do
			if player.UserId == userId then
				local character = player.Character
				if character ~= nil then
					return character
				end
				return nil
			end
		end
		return nil
	end

	for _, tagged in ipairs(CollectionService:GetTagged("CombatEntity")) do
		if tagged:IsA("Model") and tagged:GetAttribute("EntityId") == entityId then
			return tagged
		end
	end
	return nil
end

local function rotateDirectionToward(currentDirection: Vector3, targetDirection: Vector3, maxTurnRadians: number): Vector3
	if currentDirection.Magnitude < 1e-4 then
		return targetDirection.Unit
	end
	if targetDirection.Magnitude < 1e-4 then
		return currentDirection.Unit
	end
	if maxTurnRadians <= 0 then
		return currentDirection.Unit
	end

	local currentUnit = currentDirection.Unit
	local targetUnit = targetDirection.Unit
	local dot = math.clamp(currentUnit:Dot(targetUnit), -1, 1)
	local angle = math.acos(dot)
	if angle <= maxTurnRadians then
		return targetUnit
	end

	local alpha = maxTurnRadians / math.max(angle, 1e-4)
	return (currentUnit:Lerp(targetUnit, alpha)).Unit
end

local function onRenderStepped()
	local now = tick()

	local excludeList: { Instance } = {}
	if boltFolder ~= nil and boltFolder.Parent ~= nil then
		table.insert(excludeList, boltFolder)
	end
	if impactFolder ~= nil and impactFolder.Parent ~= nil then
		table.insert(excludeList, impactFolder)
	end
	clientVisualRaycastParams.FilterDescendantsInstances = excludeList

	for projectileId, bolt in pairs(activeBolts) do
		-- Skip metadata-only entries (visual destroyed, waiting for impact event)
		if bolt.boltPart.Parent == nil then
			continue
		end
		local dt = math.max(0, now - bolt.lastUpdatedAt)
		bolt.lastUpdatedAt = now
		local position: Vector3
		local previousPosition: Vector3

		local homingActive = type(bolt.targetEntityId) == "string"
			and type(bolt.homingTurnRate) == "number"
			and (bolt.homingTurnRate :: number) > 0
		if homingActive then
			previousPosition = bolt.currentPosition or bolt.origin
			local targetModel = findEntityModelById(bolt.targetEntityId :: string)
			if targetModel ~= nil then
				local toTarget = getModelAimPosition(targetModel) - previousPosition
				if toTarget.Magnitude > 1e-4 then
					bolt.direction = rotateDirectionToward(
						bolt.direction.Unit,
						toTarget.Unit,
						math.rad(bolt.homingTurnRate :: number) * dt
					)
				end
			end

			position = previousPosition + bolt.direction.Unit * bolt.speed * dt
			bolt.currentPosition = position
		elseif type(bolt.artilleryGravity) == "number" and (bolt.artilleryGravity :: number) > 0 then
			previousPosition = bolt.currentPosition or bolt.origin
			local velocity = bolt.currentVelocity
			if velocity == nil then
				velocity = bolt.direction * bolt.speed
				bolt.currentVelocity = velocity
			end

			velocity = velocity + Vector3.new(0, -(bolt.artilleryGravity :: number) * dt, 0)
			bolt.currentVelocity = velocity
			position = previousPosition + velocity * dt
			bolt.currentPosition = position

			if velocity.Magnitude > 1e-4 then
				bolt.direction = velocity.Unit
			end
		else
			local elapsed = now - bolt.createdAt
			local previousElapsed = math.max(0, elapsed - dt)
			previousPosition = bolt.origin + bolt.direction * bolt.speed * previousElapsed
			position = bolt.origin + bolt.direction * bolt.speed * elapsed
		end

		local traveledDistance = (position - bolt.origin).Magnitude
		if traveledDistance >= bolt.maxRange then
			destroyBolt(projectileId)
		else
			-- Client-side wall collision: stop bolt at geometry instead of phasing through
			local sweep = position - previousPosition
			if sweep.Magnitude > 1e-4 then
				local hitResult = Workspace:Raycast(previousPosition, sweep, clientVisualRaycastParams)
				if hitResult ~= nil then
					destroyBolt(projectileId)
					continue
				end
			end

			local projectileCFrame = CFrame.lookAt(position, position + bolt.direction)
			bolt.boltPart.CFrame = projectileCFrame
			if bolt.bulletPart ~= nil then
				bolt.bulletPart.CFrame = projectileCFrame
			end

			-- Missile/torpedo bolt pulse: transparency throbs while in flight (skip artillery — part is hidden)
			if bolt.damageType ~= nil and MISSILE_DAMAGE_TYPES[bolt.damageType] and bolt.damageType ~= "artillery_shell" then
				local elapsed = now - bolt.createdAt
				bolt.boltPart.Transparency = math.sin(elapsed * 14) * 0.2 + 0.2
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
	local fireSound = if type(payload.fireSound) == "string" then payload.fireSound else nil
	-- Skip fire sound for local player (already played instantly on click)
	local isLocalShot = type(payload.shooterUserId) == "number"
		and Players.LocalPlayer ~= nil
		and payload.shooterUserId == Players.LocalPlayer.UserId
	if not isLocalShot then
		playFireSoundAt(payload.origin, damageType, fireSound)
	end
	local boltColor = if typeof(payload.boltColor) == "Color3" then (payload.boltColor :: Color3) else nil

	local boltPart, bulletPart = createVisualPartsFromTemplate(payload.projectileId, boltColor, damageType, fireSound)
	attachSmokeTrail(boltPart, damageType)

	activeBolts[payload.projectileId] = {
		boltPart = boltPart,
		bulletPart = bulletPart,
		origin = payload.origin,
		direction = payload.direction,
		speed = payload.speed,
		maxRange = payload.maxRange,
		createdAt = tick(),
		lastUpdatedAt = tick(),
		damageType = damageType,
		targetEntityId = if type(payload.targetEntityId) == "string" then payload.targetEntityId else nil,
		homingTurnRate = if type(payload.homingTurnRate) == "number" then payload.homingTurnRate else nil,
		currentPosition = payload.origin,
		artilleryGravity = if type(payload.artilleryGravity) == "number" then payload.artilleryGravity else nil,
		currentVelocity = if type(payload.artilleryGravity) == "number" then payload.direction * payload.speed else nil,
		fireSound = fireSound,
	}

	if type(payload.artilleryGravity) == "number" then
		boltPart.Transparency = 1
		if bulletPart ~= nil then
			bulletPart.Transparency = 1
		end
		print(string.format("[P7_VISUAL] shell=%s created gravity=%d", payload.projectileId, payload.artilleryGravity))
	end
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
	local boltFireSound = if bolt ~= nil then bolt.fireSound else nil
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
			local effectPart = spawnImpactEffect(payload.hitPosition, payload.hitNormal, impactType, damageType)
			playImpactSoundAt(payload.hitPosition, impactType, boltFireSound, effectPart)
			if impactType == "shield" and shieldBroken then
				playShieldBreakSoundAt(payload.hitPosition, boltFireSound)
			end
		end)
		return
	end

	destroyBolt(payload.projectileId)
	local effectPart = spawnImpactEffect(payload.hitPosition, payload.hitNormal, impactType, damageType)
	playImpactSoundAt(payload.hitPosition, impactType, boltFireSound, effectPart)
	if impactType == "shield" and shieldBroken then
		playShieldBreakSoundAt(payload.hitPosition, boltFireSound)
	end
end

function ProjectileVisuals.init(remotes: Folder)
	-- Preload all weapon sound assets so they're cached before first shot
	local preloadIds: { [string]: boolean } = {}
	for _, group in pairs(CombatConfig.WeaponSounds) do
		if type(group) == "table" then
			for _, entry in pairs(group) do
				if type(entry) == "string" and entry ~= "" then
					preloadIds[entry] = true
				elseif type(entry) == "table" then
					for _, id in ipairs(entry) do
						if type(id) == "string" and id ~= "" then
							preloadIds[id] = true
						end
					end
				end
			end
		end
	end
	local toPreload: { any } = {}
	for id in pairs(preloadIds) do
		table.insert(toPreload, id)
	end
	if #toPreload > 0 then
		task.spawn(function()
			ContentProvider:PreloadAsync(toPreload)
		end)
	end

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
