--!strict

local Debris = game:GetService("Debris")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local localPlayer = Players.LocalPlayer
local playerScripts = localPlayer:WaitForChild("PlayerScripts")
local clientRoot = playerScripts:WaitForChild("CombatFramework")

local sharedRoot = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatConfig = require(sharedRoot:WaitForChild("CombatConfig"))
local CombatTypes = require(sharedRoot:WaitForChild("CombatTypes"))
local TargetingClient = require(clientRoot:WaitForChild("Targeting"):WaitForChild("TargetingClient"))
local WeaponClient = require(clientRoot:WaitForChild("Weapons"):WaitForChild("WeaponClient"))
local DriverClient = require(clientRoot:WaitForChild("Vehicle"):WaitForChild("DriverClient"))
local ProjectileVisuals = require(clientRoot:WaitForChild("Projectiles"):WaitForChild("ProjectileVisuals"))
local CombatHUD = require(clientRoot:WaitForChild("HUD"):WaitForChild("CombatHUD"))

type EntityDestroyedPayload = CombatTypes.EntityDestroyedPayload
type ActiveShakeBurst = {
	age: number,
	duration: number,
	magnitude: number,
	frequency: number,
	seed: number,
}
type OverheatWorldEffect = {
	model: Model,
	mount: BasePart,
	muzzleLocalOffset: Vector3,
	attachment: Attachment,
	smoke: ParticleEmitter,
	soundPart: BasePart?,
}

local remotesFolder = ReplicatedStorage:WaitForChild("CombatRemotes") :: Folder
local fireWeaponRemote = remotesFolder:WaitForChild("FireWeapon") :: RemoteEvent
local projectileFiredRemote = remotesFolder:WaitForChild("ProjectileFired") :: RemoteEvent
local projectileImpactRemote = remotesFolder:WaitForChild("ProjectileImpact") :: RemoteEvent
local damageAppliedRemote = remotesFolder:WaitForChild("DamageApplied") :: RemoteEvent
local hitConfirmRemote = remotesFolder:WaitForChild("HitConfirm") :: RemoteEvent
local entityDestroyedRemote = remotesFolder:WaitForChild("EntityDestroyed") :: RemoteEvent
local entityRespawnedRemote = remotesFolder:WaitForChild("EntityRespawned") :: RemoteEvent

local warnedMissingTurretExplosionSound = false
local warnedMissingTurretExplosionParticles = false
local destructionEffectsFolder: Folder? = nil
local activeShakeBursts: { ActiveShakeBurst } = {}
local cameraShakeBound = false
local cameraShakeConnection: RBXScriptConnection? = nil
local overheatSyncConnection: RBXScriptConnection? = nil
local overheatEffectsByEntityId: { [string]: OverheatWorldEffect } = {}
local overheatSyncAccumulator = 0
local warnedMissingOverheatWorldSound = false

local EXPLOSION_BURST_COUNTS: { [string]: number } = {
	Smoke = 36,
	Flash = 4,
	Sparks = 90,
	Explosion = 42,
}
local OVERHEAT_SYNC_INTERVAL = 0.1

local function isMuzzleAttachment(candidate: Instance): boolean
	if not candidate:IsA("Attachment") then
		return false
	end

	if CollectionService:HasTag(candidate, "MuzzlePoint") then
		return true
	end

	return candidate.Name == "MuzzlePoint" or string.sub(candidate.Name, 1, 11) == "MuzzlePoint"
end

local function getPrimaryMuzzleLocalOffset(weaponMount: BasePart): Vector3
	local attachments: { Attachment } = {}
	for _, descendant in ipairs(weaponMount:GetDescendants()) do
		if isMuzzleAttachment(descendant) then
			table.insert(attachments, descendant :: Attachment)
		end
	end

	table.sort(attachments, function(a: Attachment, b: Attachment)
		return a:GetFullName() < b:GetFullName()
	end)

	local muzzlePoint = attachments[1]
	if muzzlePoint ~= nil then
		return weaponMount.CFrame:PointToObjectSpace(muzzlePoint.WorldPosition)
	end

	return Vector3.new(0, 0, -weaponMount.Size.Z * 0.5)
end

local function readConfigNumber(name: string, defaultValue: number): number
	local raw = CombatConfig[name]
	if type(raw) == "number" then
		return raw
	end
	return defaultValue
end

local function ensureDestructionEffectsFolder(): Folder
	if destructionEffectsFolder ~= nil and destructionEffectsFolder.Parent ~= nil then
		return destructionEffectsFolder
	end

	local existing = Workspace:FindFirstChild("CombatDestructionEffects")
	if existing ~= nil and existing:IsA("Folder") then
		destructionEffectsFolder = existing
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = "CombatDestructionEffects"
	folder.Parent = Workspace
	destructionEffectsFolder = folder
	return folder
end

local function getOverheatWorldSoundTemplate(): Sound?
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

local function getExplosionSoundTemplates(): { Sound }
	local templates: { Sound } = {}
	local combatAssets = ReplicatedStorage:FindFirstChild("CombatAssets")
	if combatAssets == nil or not combatAssets:IsA("Folder") then
		return templates
	end

	local audioFolder = combatAssets:FindFirstChild("Audio")
	if audioFolder == nil or not audioFolder:IsA("Folder") then
		return templates
	end

	local explosionFolder = audioFolder:FindFirstChild("Explosion")
	if explosionFolder ~= nil and explosionFolder:IsA("Folder") then
		for _, child in ipairs(explosionFolder:GetChildren()) do
			if child:IsA("Sound") then
				table.insert(templates, child)
			end
		end
	end

	if #templates == 0 then
		local impactFolder = audioFolder:FindFirstChild("Impact")
		if impactFolder ~= nil and impactFolder:IsA("Folder") then
			for _, child in ipairs(impactFolder:GetChildren()) do
				if child:IsA("Sound") then
					table.insert(templates, child)
				end
			end
		end
	end

	return templates
end

local function playTurretExplosionSoundAt(position: Vector3)
	local soundTemplates = getExplosionSoundTemplates()
	if #soundTemplates == 0 then
		if not warnedMissingTurretExplosionSound then
			warn("[P2_AUDIO] Missing turret explosion sound templates in ReplicatedStorage.CombatAssets.Audio.Explosion")
			warnedMissingTurretExplosionSound = true
		end
		return
	end

	local soundPart = Instance.new("Part")
	soundPart.Name = "TurretExplosionSound"
	soundPart.Size = Vector3.new(0.25, 0.25, 0.25)
	soundPart.Transparency = 1
	soundPart.Anchored = true
	soundPart.CanCollide = false
	soundPart.CanQuery = false
	soundPart.CanTouch = false
	soundPart.CFrame = CFrame.new(position)
	soundPart.Parent = ensureDestructionEffectsFolder()

	local cleanupDelay = 1
	for _, soundTemplate in ipairs(soundTemplates) do
		local sound = soundTemplate:Clone()
		sound.Looped = false
		sound.Parent = soundPart
		sound:Play()
		cleanupDelay = math.max(cleanupDelay, sound.TimeLength + 0.2)
	end

	Debris:AddItem(soundPart, cleanupDelay)
end

local function getExplosionParticleTemplateFolder(): Folder?
	local combatAssets = ReplicatedStorage:FindFirstChild("CombatAssets")
	if combatAssets == nil or not combatAssets:IsA("Folder") then
		return nil
	end

	local impactParticles = combatAssets:FindFirstChild("ImpactParticles")
	if impactParticles == nil or not impactParticles:IsA("Folder") then
		return nil
	end

	local turretTemplate = impactParticles:FindFirstChild("turretExplosion")
	if turretTemplate ~= nil and turretTemplate:IsA("Folder") then
		return turretTemplate
	end

	local fallback = impactParticles:FindFirstChild("bulletHit")
	if fallback ~= nil and fallback:IsA("Folder") then
		return fallback
	end

	return nil
end

local function getBurstCount(emitter: ParticleEmitter): number
	local attributeBurstCount = emitter:GetAttribute("EmitCount")
	if type(attributeBurstCount) == "number" then
		return math.max(0, math.floor(attributeBurstCount + 0.5))
	end

	local mapped = EXPLOSION_BURST_COUNTS[emitter.Name]
	if mapped ~= nil then
		return mapped
	end

	return 18
end

local function scaleNumberSequence(sequence: NumberSequence, scale: number): NumberSequence
	local keypoints = sequence.Keypoints
	local scaled: { NumberSequenceKeypoint } = table.create(#keypoints)
	for index, keypoint in ipairs(keypoints) do
		scaled[index] = NumberSequenceKeypoint.new(
			keypoint.Time,
			keypoint.Value * scale,
			keypoint.Envelope * scale
		)
	end
	return NumberSequence.new(scaled)
end

local function spawnTurretExplosionEffect(position: Vector3)
	local template = getExplosionParticleTemplateFolder()
	if template == nil then
		if not warnedMissingTurretExplosionParticles then
			warn("[P2_IMPACT] Missing ReplicatedStorage.CombatAssets.ImpactParticles.turretExplosion (or bulletHit fallback).")
			warnedMissingTurretExplosionParticles = true
		end
		return
	end

	local particleScale = math.max(0.1, readConfigNumber("TurretDeathExplosionParticleScale", 1.8))
	local emitMultiplier = math.max(0.1, readConfigNumber("TurretDeathExplosionParticleEmitMultiplier", 2.2))
	local speedScale = math.max(0.1, 0.85 + particleScale * 0.4)

	local effectPart = Instance.new("Part")
	effectPart.Name = "TurretExplosionEffect"
	effectPart.Transparency = 1
	effectPart.Size = Vector3.new(8, 8, 8)
	effectPart.Anchored = true
	effectPart.CanCollide = false
	effectPart.CanTouch = false
	effectPart.CanQuery = false
	effectPart.CastShadow = false
	effectPart.CFrame = CFrame.new(position)
	effectPart.Parent = ensureDestructionEffectsFolder()

	local attachmentMap: { [Attachment]: Attachment } = {}
	for _, descendant in ipairs(template:GetDescendants()) do
		if descendant:IsA("Attachment") then
			local attachmentClone = descendant:Clone()
			attachmentClone.Parent = effectPart
			attachmentMap[descendant] = attachmentClone
		end
	end

	local spawnedEffects: { Instance } = {}
	for _, descendant in ipairs(template:GetDescendants()) do
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

			if effectClone:IsA("ParticleEmitter") then
				effectClone.Size = scaleNumberSequence(effectClone.Size, particleScale)
				effectClone.Speed = NumberRange.new(effectClone.Speed.Min * speedScale, effectClone.Speed.Max * speedScale)
			elseif effectClone:IsA("PointLight") then
				effectClone.Range *= particleScale
			end

			effectClone.Parent = targetParent
			table.insert(spawnedEffects, effectClone)
		end
	end

	for _, effect in ipairs(spawnedEffects) do
		if effect:IsA("ParticleEmitter") then
			local emitCount = math.max(1, math.floor(getBurstCount(effect) * emitMultiplier + 0.5))
			effect:Emit(emitCount)
		elseif effect:IsA("PointLight") then
			effect.Enabled = true
		end
	end

	task.delay(0.18, function()
		if effectPart.Parent == nil then
			return
		end
		for _, effect in ipairs(spawnedEffects) do
			if effect.Parent ~= nil and (effect:IsA("ParticleEmitter") or effect:IsA("PointLight")) then
				effect.Enabled = false
			end
		end
	end)

	Debris:AddItem(effectPart, 6)
end

local function ensureCameraShakeStep()
	if cameraShakeBound then
		return
	end
	cameraShakeBound = true

	cameraShakeConnection = RunService.RenderStepped:Connect(function(dt)
		local camera = Workspace.CurrentCamera
		if camera == nil or #activeShakeBursts == 0 then
			return
		end

		local totalOffset = Vector3.zero
		local totalRoll = 0

		for index = #activeShakeBursts, 1, -1 do
			local burst = activeShakeBursts[index]
			burst.age += dt

			local remaining = 1 - (burst.age / math.max(burst.duration, 1e-4))
			if remaining <= 0 then
				table.remove(activeShakeBursts, index)
			else
				local intensity = burst.magnitude * remaining * remaining
				local phase = burst.age * burst.frequency + burst.seed
				totalOffset += Vector3.new(
					math.sin(phase * 1.23 + burst.seed * 0.71),
					math.sin(phase * 1.89 + burst.seed * 0.43),
					math.sin(phase * 2.57 + burst.seed * 0.29)
				) * intensity
				totalRoll += math.sin(phase * 2.17 + burst.seed) * intensity * 2.8
			end
		end

		if totalOffset.Magnitude > 1e-4 or math.abs(totalRoll) > 1e-4 then
			camera.CFrame = camera.CFrame * CFrame.new(totalOffset * 1.45) * CFrame.Angles(0, 0, math.rad(totalRoll * 1.75))
		end
	end)
end

local function pushExplosionCameraShake(explosionPosition: Vector3, explosionRadius: number?)
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end

	local configuredRadius = math.max(1, readConfigNumber("TurretDeathExplosionShakeRadius", 60))
	local radius = if type(explosionRadius) == "number" and explosionRadius > 0
		then math.max(configuredRadius, explosionRadius * 2)
		else configuredRadius
	local distance = (camera.CFrame.Position - explosionPosition).Magnitude
	if distance > radius then
		return
	end

	local distanceAlpha = math.clamp(1 - (distance / radius), 0, 1)
	local baseStrength = math.max(0, readConfigNumber("TurretDeathExplosionShakeStrength", 0.45))
	local magnitude = baseStrength * distanceAlpha * distanceAlpha
	if magnitude <= 1e-4 then
		return
	end

	table.insert(activeShakeBursts, {
		age = 0,
		duration = math.max(0.05, readConfigNumber("TurretDeathExplosionShakeDuration", 0.42)),
		magnitude = magnitude,
		frequency = 22 + math.random() * 8,
		seed = math.random() * 1000,
	})
	ensureCameraShakeStep()
end

local function findEntityById(entityId: string): Model?
	for _, tagged in ipairs(CollectionService:GetTagged("CombatEntity")) do
		if tagged:IsA("Model") and tagged:GetAttribute("EntityId") == entityId then
			return tagged
		end
	end
	return nil
end

local function findWeaponMount(entityModel: Model): BasePart?
	for _, descendant in ipairs(entityModel:GetDescendants()) do
		if descendant:IsA("BasePart") and CollectionService:HasTag(descendant, "WeaponMount") then
			return descendant
		end
	end
	return nil
end

local function isLocalPlayerSeatedInModel(entityModel: Model): boolean
	local character = localPlayer.Character
	if character == nil then
		return false
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return false
	end

	local seatPart = humanoid.SeatPart
	if seatPart == nil then
		return false
	end

	return seatPart:IsDescendantOf(entityModel)
end

local function destroyOverheatWorldEffect(entityId: string)
	local effect = overheatEffectsByEntityId[entityId]
	if effect == nil then
		return
	end

	if effect.attachment.Parent ~= nil then
		effect.attachment:Destroy()
	end
	if effect.soundPart ~= nil and effect.soundPart.Parent ~= nil then
		effect.soundPart:Destroy()
	end
	overheatEffectsByEntityId[entityId] = nil
end

local function ensureOverheatWorldEffect(entityId: string, entityModel: Model)
	local mount = findWeaponMount(entityModel)
	if mount == nil then
		destroyOverheatWorldEffect(entityId)
		return
	end

	local existing = overheatEffectsByEntityId[entityId]
	if existing ~= nil and (existing.mount.Parent == nil or not existing.mount:IsDescendantOf(entityModel)) then
		destroyOverheatWorldEffect(entityId)
		existing = nil
	end

	if existing == nil then
		local muzzleLocalOffset = getPrimaryMuzzleLocalOffset(mount)

		local attachment = Instance.new("Attachment")
		attachment.Name = "OverheatWorldFX"
		attachment.Position = muzzleLocalOffset
		attachment.Parent = mount

		local smoke = Instance.new("ParticleEmitter")
		smoke.Name = "OverheatSmoke"
		smoke.Enabled = true
		smoke.Rate = 34
		smoke.Speed = NumberRange.new(0.45, 1.6)
		smoke.Lifetime = NumberRange.new(0.55, 1.3)
		smoke.SpreadAngle = Vector2.new(18, 18)
		smoke.RotSpeed = NumberRange.new(-25, 25)
		smoke.Rotation = NumberRange.new(0, 360)
		smoke.Acceleration = Vector3.new(0, 4, 0)
		smoke.Texture = "rbxassetid://716847870"
		smoke.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.48),
			NumberSequenceKeypoint.new(0.5, 1.25),
			NumberSequenceKeypoint.new(1, 2.1),
		})
		smoke.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.42),
			NumberSequenceKeypoint.new(1, 1),
		})
		smoke.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(132, 132, 132)),
			ColorSequenceKeypoint.new(0.35, Color3.fromRGB(88, 88, 88)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(42, 42, 42)),
		})
		smoke.Parent = attachment

		local soundPart = Instance.new("Part")
		soundPart.Name = "OverheatWorldSound"
		soundPart.Size = Vector3.new(0.25, 0.25, 0.25)
		soundPart.Transparency = 1
		soundPart.Anchored = true
		soundPart.CanCollide = false
		soundPart.CanTouch = false
		soundPart.CanQuery = false
		soundPart.CFrame = mount.CFrame * CFrame.new(muzzleLocalOffset)
		soundPart.Parent = ensureDestructionEffectsFolder()

		local soundTemplate = getOverheatWorldSoundTemplate()
		if soundTemplate ~= nil then
			local sound = soundTemplate:Clone()
			sound.Looped = true
			sound.Parent = soundPart
			sound:Play()
		elseif not warnedMissingOverheatWorldSound then
			warn("[P1_AUDIO] Missing overheat world sound template in ReplicatedStorage.CombatAssets.Audio.Overheat")
			warnedMissingOverheatWorldSound = true
		end

		existing = {
			model = entityModel,
			mount = mount,
			muzzleLocalOffset = muzzleLocalOffset,
			attachment = attachment,
			smoke = smoke,
			soundPart = soundPart,
		}
		overheatEffectsByEntityId[entityId] = existing
	end

	if existing.soundPart ~= nil and existing.soundPart.Parent ~= nil and existing.mount.Parent ~= nil then
		existing.soundPart.CFrame = existing.mount.CFrame * CFrame.new(existing.muzzleLocalOffset)
	end
end

local function syncOverheatWorldEffects()
	local seenEntityIds: { [string]: boolean } = {}
	for _, tagged in ipairs(CollectionService:GetTagged("CombatEntity")) do
		if tagged:IsA("Model") then
			local entityModel = tagged :: Model
			local entityIdAttr = entityModel:GetAttribute("EntityId")
			if type(entityIdAttr) == "string" then
				local entityId = entityIdAttr
				seenEntityIds[entityId] = true

				local overheated = entityModel:GetAttribute("WeaponOverheated") == true
				local localSeated = isLocalPlayerSeatedInModel(entityModel)
				if overheated and not localSeated then
					ensureOverheatWorldEffect(entityId, entityModel)
				else
					destroyOverheatWorldEffect(entityId)
				end
			end
		end
	end

	for entityId, effect in pairs(overheatEffectsByEntityId) do
		if not seenEntityIds[entityId] or effect.model.Parent == nil then
			destroyOverheatWorldEffect(entityId)
		end
	end
end

local function normalizeEntityDestroyedPayload(payload: any): EntityDestroyedPayload?
	if type(payload) == "string" then
		return {
			entityId = payload,
		}
	end
	if type(payload) ~= "table" then
		return nil
	end

	local entityId = payload.entityId
	if type(entityId) ~= "string" then
		return nil
	end

	local normalized: EntityDestroyedPayload = {
		entityId = entityId,
	}

	if typeof(payload.explosionPosition) == "Vector3" then
		normalized.explosionPosition = payload.explosionPosition
	end
	if type(payload.explosionRadius) == "number" then
		normalized.explosionRadius = payload.explosionRadius
	end

	return normalized
end

local function onEntityDestroyed(rawPayload: any)
	local payload = normalizeEntityDestroyedPayload(rawPayload)
	if payload == nil then
		return
	end

	local model = findEntityById(payload.entityId)
	local explosionPosition = payload.explosionPosition
	if explosionPosition == nil and model ~= nil then
		explosionPosition = model:GetPivot().Position
	end

	if model ~= nil then
		for _, descendant in ipairs(model:GetDescendants()) do
			if descendant:IsA("BasePart") then
				descendant.Transparency = 1
			end
		end
	end

	if explosionPosition ~= nil then
		playTurretExplosionSoundAt(explosionPosition)
		spawnTurretExplosionEffect(explosionPosition)
		pushExplosionCameraShake(explosionPosition, payload.explosionRadius)
	end

	destroyOverheatWorldEffect(payload.entityId)
	CombatHUD.onEntityDestroyed(payload.entityId)
end

local function onEntityRespawned(payload)
	if type(payload) ~= "table" or type(payload.entityId) ~= "string" then
		return
	end

	local model = findEntityById(payload.entityId)
	if model ~= nil then
		for _, descendant in ipairs(model:GetDescendants()) do
			if descendant:IsA("BasePart") then
				if descendant:IsA("Seat") and CollectionService:HasTag(descendant, "TurretSeat") then
					descendant.Transparency = 1
				else
					descendant.Transparency = 0
				end
			end
		end
	end

	destroyOverheatWorldEffect(payload.entityId)
	CombatHUD.onEntityRespawned(payload)
end

CombatHUD.init()
TargetingClient.init(remotesFolder)
DriverClient.init()
WeaponClient.init(remotesFolder)
ProjectileVisuals.init(remotesFolder)

-- Keep references so all required remotes are guaranteed to exist in pass 1.
local _ = fireWeaponRemote
_ = projectileFiredRemote
_ = projectileImpactRemote
_ = hitConfirmRemote

damageAppliedRemote.OnClientEvent:Connect(function(payload)
	CombatHUD.onDamageApplied(payload)
end)

hitConfirmRemote.OnClientEvent:Connect(function(payload)
	CombatHUD.onHitConfirm(payload)
end)

entityDestroyedRemote.OnClientEvent:Connect(onEntityDestroyed)
entityRespawnedRemote.OnClientEvent:Connect(onEntityRespawned)

if overheatSyncConnection == nil then
	overheatSyncConnection = RunService.Heartbeat:Connect(function(dt)
		overheatSyncAccumulator += dt
		if overheatSyncAccumulator < OVERHEAT_SYNC_INTERVAL then
			return
		end
		overheatSyncAccumulator = 0
		syncOverheatWorldEffects()
	end)
end
