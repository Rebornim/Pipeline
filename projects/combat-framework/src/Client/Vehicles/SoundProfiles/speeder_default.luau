--!strict

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local clientRoot = Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("CombatFramework")
local sharedRoot = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatConfig = require(sharedRoot:WaitForChild("CombatConfig"))
local VehicleCamera = require(clientRoot:WaitForChild("Vehicles"):WaitForChild("VehicleCamera"))

local profilesFolder = clientRoot:WaitForChild("Vehicles"):WaitForChild("SoundProfiles")
local SoundProfileTypes = require(profilesFolder:WaitForChild("SoundProfileTypes"))
type ProfileController = SoundProfileTypes.ProfileController
type VehicleFrameState = SoundProfileTypes.VehicleFrameState

local speeder_default = {}

--------------------------------------------------------------------------
-- Sound tuning
--------------------------------------------------------------------------

local ENGINE_CLOSE_PEAK_VOL = 0.75
local ENGINE_CLOSE_FADE_END = 0.50
local ENGINE_CLOSE_PITCH_LO = 0.80
local ENGINE_CLOSE_PITCH_HI = 1.30

local ENGINE_NOISE_PEAK_VOL = 0.55
local ENGINE_NOISE_FADE_IN = 0.15
local ENGINE_NOISE_FADE_FULL = 0.45
local ENGINE_NOISE_PITCH_LO = 0.85
local ENGINE_NOISE_PITCH_HI = 1.20

local GEAR_SHIFT_COOLDOWN = 3.0
local GEAR_SHIFT_LEAN_COOLDOWN = 1.0
local GEAR_SHIFT_LEAN_MIN_FRAC = 0.50
local GEAR_SHIFT_VOL = 0.50
local GEAR_SHIFT_LEAN_VOL = 0.30
local MID_SPEED_FRAC = 0.45

local HOWL_MIN_INTERVAL = 8
local HOWL_MAX_INTERVAL = 15
local HOWL_SPEED_FRAC = 0.70

local BROKEN_HP_FRAC = 0.20
local BROKEN_BASE_VOL = 0.30
local BROKEN_SPEED_VOL = 0.20

local BOOST_LOOP_VOL = 0.60
local BOOST_START_VOL = 0.80
local BOOST_END_VOL = 0.70

local ENGINE_START_VOL = 0.70
local ENGINE_STOP_VOL = 0.60

local ENGINE_IDLE_DELAY = 0.4
local ENGINE_IDLE_RAMP = 2.0

local LOCAL_ROLLOFF_MIN = 10
local LOCAL_ROLLOFF_MAX = 200
local REMOTE_ROLLOFF_MIN = 30
local REMOTE_ROLLOFF_MAX = 1500

local LOOP_CROSSFADE = 0.15  -- seconds of overlap at loop boundary (J-cut)

--------------------------------------------------------------------------
-- VFX tuning
--------------------------------------------------------------------------

local DAMAGE_SMOKE_START = 0.6
local DAMAGE_SMOKE_FULL = 0.2
local DUST_MAX_LIFETIME = 1.6
local DEFAULT_DUST_COLOR = Color3.fromRGB(180, 160, 130)
local LEAN_DUST_EMIT_COUNT = 6

local TERRAIN_DUST_COLORS: { [Enum.Material]: Color3 } = {
	[Enum.Material.Grass] = Color3.fromRGB(120, 140, 80),
	[Enum.Material.LeafyGrass] = Color3.fromRGB(100, 130, 60),
	[Enum.Material.Sand] = Color3.fromRGB(194, 178, 128),
	[Enum.Material.Sandstone] = Color3.fromRGB(180, 160, 120),
	[Enum.Material.Ground] = Color3.fromRGB(140, 120, 90),
	[Enum.Material.Mud] = Color3.fromRGB(90, 70, 50),
	[Enum.Material.Rock] = Color3.fromRGB(140, 135, 130),
	[Enum.Material.Slate] = Color3.fromRGB(130, 130, 135),
	[Enum.Material.Basalt] = Color3.fromRGB(80, 80, 85),
	[Enum.Material.Snow] = Color3.fromRGB(220, 225, 230),
	[Enum.Material.Ice] = Color3.fromRGB(200, 215, 225),
	[Enum.Material.Glacier] = Color3.fromRGB(190, 210, 225),
	[Enum.Material.Salt] = Color3.fromRGB(230, 230, 225),
	[Enum.Material.Concrete] = Color3.fromRGB(165, 160, 155),
	[Enum.Material.Pavement] = Color3.fromRGB(155, 150, 145),
	[Enum.Material.Asphalt] = Color3.fromRGB(100, 100, 100),
	[Enum.Material.Limestone] = Color3.fromRGB(190, 185, 170),
	[Enum.Material.CrackedLava] = Color3.fromRGB(60, 40, 35),
	[Enum.Material.Metal] = Color3.fromRGB(160, 155, 150),
	[Enum.Material.DiamondPlate] = Color3.fromRGB(160, 155, 150),
	[Enum.Material.WoodPlanks] = Color3.fromRGB(130, 100, 65),
	[Enum.Material.Wood] = Color3.fromRGB(130, 100, 65),
	[Enum.Material.Brick] = Color3.fromRGB(150, 100, 80),
}

--------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------

local function pick2(a: string, b: string): string
	if math.random() < 0.5 then return a end
	return b
end

local function createDustEmitter(parent: BasePart, color: Color3): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = "rbxassetid://716847870"
	emitter.Color = ColorSequence.new(color)
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.6),
		NumberSequenceKeypoint.new(0.3, 0.7),
		NumberSequenceKeypoint.new(0.7, 0.85),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.0),
		NumberSequenceKeypoint.new(0.3, 3.0),
		NumberSequenceKeypoint.new(0.7, 4.5),
		NumberSequenceKeypoint.new(1, 3.0),
	})
	emitter.Lifetime = NumberRange.new(0.8, 1.6)
	emitter.Speed = NumberRange.new(3, 8)
	emitter.SpreadAngle = Vector2.new(50, 50)
	emitter.Drag = 3
	emitter.Rate = 0
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.LightEmission = 0.1
	emitter.Parent = parent
	return emitter
end

--------------------------------------------------------------------------
-- Controller factory
--------------------------------------------------------------------------

function speeder_default.createController(
	sourceModel: Model,
	targetPart: BasePart,
	maxSpeed: number,
	isLocal: boolean
): ProfileController
	local ms = if maxSpeed > 0 then maxSpeed else 100
	local rolloffMin = if isLocal then LOCAL_ROLLOFF_MIN else REMOTE_ROLLOFF_MIN
	local rolloffMax = if isLocal then LOCAL_ROLLOFF_MAX else REMOTE_ROLLOFF_MAX

	-- Read vehicle config for camera effect parameters
	local landingShakeThreshold: number = 15
	local landingShakeIntensity: number = 0.6
	local fallDamageThreshold: number = 40
	local leanShakeAmplitude: number = 0.2
	local leanShakeDuration: number = 0.15
	do
		local configId = sourceModel:GetAttribute("VehicleCategory")
		if type(configId) ~= "string" then
			configId = sourceModel:GetAttribute("VehicleConfigId")
		end
		if type(configId) == "string" then
			local vehConfig = (CombatConfig.Vehicles :: any)[configId]
			if type(vehConfig) == "table" then
				if type(vehConfig.landingShakeThreshold) == "number" then landingShakeThreshold = vehConfig.landingShakeThreshold end
				if type(vehConfig.landingShakeIntensity) == "number" then landingShakeIntensity = vehConfig.landingShakeIntensity end
				if type(vehConfig.fallDamageThreshold) == "number" then fallDamageThreshold = vehConfig.fallDamageThreshold end
				if type(vehConfig.leanShakeAmplitude) == "number" then leanShakeAmplitude = vehConfig.leanShakeAmplitude end
				if type(vehConfig.leanShakeDuration) == "number" then leanShakeDuration = vehConfig.leanShakeDuration end
			end
		end
	end

	local sounds: { [string]: Sound } = {}
	local connections: { RBXScriptConnection } = {}
	local destroyed = false

	-- Sound state
	local engineIdleRampStart: number = 0
	local lastGearShiftTick: number = 0
	local lastLeanShiftTick: number = 0
	local prevSpeedZone: number = 0
	local nextHowlTick: number = 0
	local boostSoundActive: boolean = false
	local brokenSoundActive: boolean = false
	local brokenSoundName: string? = nil
	local boostShakeAccumulator: number = 0

	-- VFX state
	local hoverDustEntries: { { part: BasePart, emitter: ParticleEmitter } } = {}
	local currentDustColor: Color3? = nil
	local dustRayParams: RaycastParams? = nil
	local damageSmokeEmitter: ParticleEmitter? = nil

	-- SoundGroup with reverb
	local soundGroup = Instance.new("SoundGroup")
	soundGroup.Name = if isLocal then "VehicleSoundGroup" else "RemoteVehicleSoundGroup"
	soundGroup.Volume = 1
	local reverb = Instance.new("ReverbSoundEffect")
	reverb.DecayTime = 1.0
	reverb.Density = 0.6
	reverb.Diffusion = 0.7
	reverb.DryLevel = 0
	reverb.WetLevel = -10
	reverb.Parent = soundGroup
	soundGroup.Parent = SoundService

	--------------------------------------------------------------------
	-- Sound helpers
	--------------------------------------------------------------------

	local function createSound(name: string, looped: boolean, vol: number): Sound?
		local soundTable = CombatConfig.VehicleSounds
		if type(soundTable) ~= "table" then
			return nil
		end
		local assetId = (soundTable :: any)[name]
		if type(assetId) ~= "string" then
			return nil
		end
		local sound = Instance.new("Sound")
		sound.SoundId = assetId
		sound.Name = "Veh_" .. name
		sound.Looped = looped
		sound.Volume = vol
		sound.RollOffMode = Enum.RollOffMode.InverseTapered
		sound.RollOffMinDistance = rolloffMin
		sound.RollOffMaxDistance = rolloffMax
		sound.SoundGroup = soundGroup
		sound.Parent = targetPart
		if looped then
			local function applyLoopTrim()
				if sound.TimeLength > 0.1 then
					pcall(function()
						sound.LoopRegion = NumberRange.new(0.02, sound.TimeLength - 0.02)
					end)
				end
			end
			if sound.IsLoaded then
				applyLoopTrim()
			else
				sound.Loaded:Once(applyLoopTrim)
			end
		end
		sounds[name] = sound
		return sound
	end

	local function playOneShot(name: string, vol: number, pitch: number?)
		local sound = sounds[name]
		if sound == nil then return end
		sound.Volume = vol
		sound.PlaybackSpeed = pitch or 1
		sound:Play()
	end

	local function stopSound(name: string)
		local sound = sounds[name]
		if sound ~= nil and sound.IsPlaying then
			sound:Stop()
		end
	end

	--------------------------------------------------------------------
	-- Crossfade loop pair: two copies alternate with overlap to kill gaps
	--------------------------------------------------------------------

	type LoopPair = {
		a: Sound,
		b: Sound,
		activeIsA: boolean,
		crossfading: boolean,
		crossfadeStart: number,
	}

	local function createLoopPair(name: string): LoopPair?
		local soundTable = CombatConfig.VehicleSounds
		if type(soundTable) ~= "table" then return nil end
		local assetId = (soundTable :: any)[name]
		if type(assetId) ~= "string" then return nil end

		local function makeSound(suffix: string): Sound
			local s = Instance.new("Sound")
			s.SoundId = assetId
			s.Name = "Veh_" .. name .. suffix
			s.Looped = false
			s.Volume = 0
			s.RollOffMode = Enum.RollOffMode.InverseTapered
			s.RollOffMinDistance = rolloffMin
			s.RollOffMaxDistance = rolloffMax
			s.SoundGroup = soundGroup
			s.Parent = targetPart
			return s
		end

		return {
			a = makeSound("_a"),
			b = makeSound("_b"),
			activeIsA = true,
			crossfading = false,
			crossfadeStart = 0,
		}
	end

	local function updateLoopPair(pair: LoopPair?, targetVol: number, targetPitch: number)
		if pair == nil then return end
		local active = if pair.activeIsA then pair.a else pair.b
		local standby = if pair.activeIsA then pair.b else pair.a

		if not active.IsPlaying and not pair.crossfading then
			active.PlaybackSpeed = targetPitch
			active.Volume = targetVol
			active:Play()
		end

		if active.IsPlaying and active.TimeLength > 0.5 then
			local remaining = active.TimeLength - active.TimePosition
			if remaining <= LOOP_CROSSFADE and not pair.crossfading then
				pair.crossfading = true
				pair.crossfadeStart = tick()
				standby.PlaybackSpeed = targetPitch
				standby.Volume = 0
				standby.TimePosition = 0
				standby:Play()
			end
		end

		if pair.crossfading then
			local elapsed = tick() - pair.crossfadeStart
			local blend = math.clamp(elapsed / LOOP_CROSSFADE, 0, 1)
			active.Volume = targetVol * (1 - blend)
			active.PlaybackSpeed = targetPitch
			standby.Volume = targetVol * blend
			standby.PlaybackSpeed = targetPitch
			if blend >= 1 then
				active:Stop()
				pair.activeIsA = not pair.activeIsA
				pair.crossfading = false
			end
		else
			active.Volume = targetVol
			active.PlaybackSpeed = targetPitch
		end
	end

	local function destroyLoopPair(pair: LoopPair?)
		if pair == nil then return end
		if pair.a.IsPlaying then pair.a:Stop() end
		if pair.b.IsPlaying then pair.b:Stop() end
		pair.a:Destroy()
		pair.b:Destroy()
	end

	--------------------------------------------------------------------
	-- VFX helpers
	--------------------------------------------------------------------

	local function setupHoverDust()
		local targetModel = targetPart:FindFirstAncestorOfClass("Model")
		if targetModel == nil then return end
		currentDustColor = DEFAULT_DUST_COLOR
		for _, descendant in ipairs(targetModel:GetDescendants()) do
			if descendant:IsA("BasePart") and CollectionService:HasTag(descendant, "HoverPoint") then
				local emitter = createDustEmitter(descendant, DEFAULT_DUST_COLOR)
				table.insert(hoverDustEntries, { part = descendant, emitter = emitter })
			end
		end
	end

	local function setupDamageSmoke()
		local emitter = Instance.new("ParticleEmitter")
		emitter.Texture = "rbxassetid://716847870"
		emitter.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(40, 40, 40)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(20, 20, 20)),
		})
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.4),
			NumberSequenceKeypoint.new(0.4, 0.6),
			NumberSequenceKeypoint.new(1, 1),
		})
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.5),
			NumberSequenceKeypoint.new(0.3, 2.0),
			NumberSequenceKeypoint.new(1, 4.0),
		})
		emitter.Lifetime = NumberRange.new(1.0, 2.0)
		emitter.Speed = NumberRange.new(2, 6)
		emitter.SpreadAngle = Vector2.new(30, 30)
		emitter.Drag = 1
		emitter.Rate = 0
		emitter.EmissionDirection = Enum.NormalId.Top
		emitter.LightEmission = 0
		emitter.Parent = targetPart
		damageSmokeEmitter = emitter
	end

	local function updateHoverDust(speed: number)
		local targetModel = targetPart:FindFirstAncestorOfClass("Model")
		if targetModel == nil or #hoverDustEntries == 0 then return end

		if dustRayParams == nil then
			dustRayParams = RaycastParams.new()
			dustRayParams.FilterType = Enum.RaycastFilterType.Exclude
		end
		local filter: { Instance } = { targetModel, sourceModel }
		local character = Players.LocalPlayer.Character
		if character ~= nil then
			table.insert(filter, character)
		end
		dustRayParams.FilterDescendantsInstances = filter

		local origin = targetModel:GetPivot().Position
		local rayResult = Workspace:Raycast(origin, Vector3.new(0, -20, 0), dustRayParams)
		local material = if rayResult ~= nil then rayResult.Material else nil
		local dustColor = if material ~= nil then (TERRAIN_DUST_COLORS[material] or DEFAULT_DUST_COLOR) else DEFAULT_DUST_COLOR

		local colorChanged = currentDustColor == nil
			or dustColor.R ~= currentDustColor.R
			or dustColor.G ~= currentDustColor.G
			or dustColor.B ~= currentDustColor.B

		local rate = math.clamp(speed / 6, 0, 20)
		if colorChanged then
			currentDustColor = dustColor
			for _, entry in ipairs(hoverDustEntries) do
				if entry.part.Parent == nil then continue end
				local oldEmitter = entry.emitter
				oldEmitter.Rate = 0
				Debris:AddItem(oldEmitter, DUST_MAX_LIFETIME)
				local newEmitter = createDustEmitter(entry.part, dustColor)
				newEmitter.Rate = rate
				entry.emitter = newEmitter
			end
		else
			for _, entry in ipairs(hoverDustEntries) do
				if entry.emitter.Parent ~= nil then
					entry.emitter.Rate = rate
				end
			end
		end
	end

	local function updateDamageSmoke(hpFraction: number)
		if damageSmokeEmitter == nil then return end
		if hpFraction >= DAMAGE_SMOKE_START then
			damageSmokeEmitter.Rate = 0
			return
		end
		local intensity = math.clamp((DAMAGE_SMOKE_START - hpFraction) / (DAMAGE_SMOKE_START - DAMAGE_SMOKE_FULL), 0, 1)
		damageSmokeEmitter.Rate = intensity * 15
	end

	local function fireDustKick(leanDirection: number)
		local targetModel = targetPart:FindFirstAncestorOfClass("Model")
		if targetModel == nil or #hoverDustEntries == 0 then return end
		local modelCFrame = targetModel:GetPivot()
		for _, entry in ipairs(hoverDustEntries) do
			if entry.part.Parent == nil then continue end
			local localPos = modelCFrame:PointToObjectSpace(entry.part.Position)
			local isOuter = (leanDirection > 0 and localPos.X < -0.3) or (leanDirection < 0 and localPos.X > 0.3)
			if isOuter then
				entry.emitter:Emit(LEAN_DUST_EMIT_COUNT)
			end
		end
	end

	--------------------------------------------------------------------
	-- Create all sounds
	--------------------------------------------------------------------

	local closeLoop = createLoopPair("EngineClose")
	local noiseLoop = createLoopPair("EngineNoise")
	engineIdleRampStart = tick() + ENGINE_IDLE_DELAY

	createSound("EngineStart", false, 0)
	createSound("EngineStop", false, 0)
	createSound("BoostStart", false, 0)
	createSound("BoostLoop", true, 0)
	createSound("BoostEnd", false, 0)
	createSound("GearShift1", false, 0)
	createSound("GearShift2", false, 0)
	createSound("Howl1", false, 0)
	createSound("Howl2", false, 0)
	createSound("Misfire1", false, 0)
	createSound("Misfire2", false, 0)
	createSound("Broken1", true, 0)
	createSound("Broken2", true, 0)

	playOneShot("EngineStart", ENGINE_START_VOL)

	local now = tick()
	nextHowlTick = now + HOWL_MIN_INTERVAL + math.random() * (HOWL_MAX_INTERVAL - HOWL_MIN_INTERVAL)
	lastGearShiftTick = now
	lastLeanShiftTick = now

	-- Setup VFX
	setupHoverDust()
	if isLocal then
		setupDamageSmoke()
	end

	--------------------------------------------------------------------
	-- Controller
	--------------------------------------------------------------------

	local controller = {} :: ProfileController

	function controller.update(_self: ProfileController, dt: number, state: VehicleFrameState)
		if destroyed then return end

		local speedFrac = state.speedFraction

		-- Engine idle ramp
		local idleRampFactor = 1
		local rampElapsed = tick() - engineIdleRampStart
		if rampElapsed < 0 then
			idleRampFactor = 0
		elseif rampElapsed < ENGINE_IDLE_RAMP then
			idleRampFactor = rampElapsed / ENGINE_IDLE_RAMP
		end

		-- Engine layer crossfade (with broken + boost modifiers baked in)
		local closeFrac = math.clamp(1 - speedFrac / ENGINE_CLOSE_FADE_END, 0, 1)
		local closeVol = closeFrac * ENGINE_CLOSE_PEAK_VOL * idleRampFactor
		local closePitch = ENGINE_CLOSE_PITCH_LO + speedFrac * (ENGINE_CLOSE_PITCH_HI - ENGINE_CLOSE_PITCH_LO)

		local noiseRange = ENGINE_NOISE_FADE_FULL - ENGINE_NOISE_FADE_IN
		local noiseFrac = if noiseRange > 0
			then math.clamp((speedFrac - ENGINE_NOISE_FADE_IN) / noiseRange, 0, 1)
			else (if speedFrac >= ENGINE_NOISE_FADE_IN then 1 else 0)
		local noiseVol = noiseFrac * ENGINE_NOISE_PEAK_VOL * idleRampFactor
		local noisePitch = ENGINE_NOISE_PITCH_LO + speedFrac * (ENGINE_NOISE_PITCH_HI - ENGINE_NOISE_PITCH_LO)

		-- Reduce engine volumes when broken sound is playing
		if brokenSoundActive then
			closeVol *= 0.6
			noiseVol *= 0.7
		end

		-- Boost pitch modulation
		if boostSoundActive then
			local bl = sounds["BoostLoop"]
			if bl then
				bl.PlaybackSpeed = 1.0 + speedFrac * 0.15
			end
			closePitch *= 1.08
			noisePitch *= 1.06
			-- Sustained micro-shake during boost
			if isLocal then
				boostShakeAccumulator += dt
				if boostShakeAccumulator >= 0.15 then
					boostShakeAccumulator -= 0.15
					VehicleCamera.pushShake(0.08, 0.1)
				end
			end
			-- Extra dust during boost
			for _, entry in ipairs(hoverDustEntries) do
				if entry.emitter.Parent ~= nil then
					entry.emitter.Rate = math.max(entry.emitter.Rate, 25)
				end
			end
		end

		updateLoopPair(closeLoop, closeVol, closePitch)
		updateLoopPair(noiseLoop, noiseVol, noisePitch)

		-- Gear shift on mid-speed threshold crossing
		local t = tick()
		local currentSpeedZone = if speedFrac >= MID_SPEED_FRAC then 1 else 0
		if currentSpeedZone ~= prevSpeedZone and (t - lastGearShiftTick) >= GEAR_SHIFT_COOLDOWN then
			lastGearShiftTick = t
			playOneShot(pick2("GearShift1", "GearShift2"), GEAR_SHIFT_VOL)
			if isLocal then
				VehicleCamera.pushShake(0.15, 0.12)
				VehicleCamera.pushFOVPunch(2, 0.15)
			end
		end
		prevSpeedZone = currentSpeedZone

		-- Engine howls at high speed
		if speedFrac >= HOWL_SPEED_FRAC and t >= nextHowlTick then
			local howlVol = 0.30 + speedFrac * 0.15
			playOneShot(pick2("Howl1", "Howl2"), howlVol)
			if isLocal then
				VehicleCamera.pushRollWobble(1.5, 0.3)
			end
			nextHowlTick = t + HOWL_MIN_INTERVAL + math.random() * (HOWL_MAX_INTERVAL - HOWL_MIN_INTERVAL)
		end

		-- Broken engine loop (below 20% HP)
		local hpFrac = state.hpFraction
		if hpFrac <= BROKEN_HP_FRAC and hpFrac > 0 and not brokenSoundActive then
			brokenSoundActive = true
			brokenSoundName = pick2("Broken1", "Broken2")
			local bs = sounds[brokenSoundName]
			if bs then
				bs.Volume = BROKEN_BASE_VOL
				bs:Play()
			end
			if isLocal then
				VehicleCamera.setBrokenVibration(true)
			end
		elseif (hpFrac > BROKEN_HP_FRAC or hpFrac <= 0) and brokenSoundActive then
			brokenSoundActive = false
			stopSound("Broken1")
			stopSound("Broken2")
			brokenSoundName = nil
			if isLocal then
				VehicleCamera.setBrokenVibration(false)
			end
		end

		if brokenSoundActive and brokenSoundName ~= nil then
			local bs = sounds[brokenSoundName]
			if bs and bs.IsPlaying then
				bs.Volume = BROKEN_BASE_VOL + speedFrac * BROKEN_SPEED_VOL
			end
		end

		-- VFX updates
		updateHoverDust(state.speed)
		if isLocal then
			updateDamageSmoke(hpFrac)
		end
	end

	function controller.onEvent(_self: ProfileController, event: string, data: any?)
		if destroyed then return end

		if event == "boost_start" then
			boostSoundActive = true
			boostShakeAccumulator = 0
			playOneShot("BoostStart", BOOST_START_VOL)
			local loop = sounds["BoostLoop"]
			if loop then
				loop.Volume = BOOST_LOOP_VOL
				loop:Play()
			end
			if isLocal then
				VehicleCamera.pushShake(0.5, 0.25)
				VehicleCamera.setBoostFOV(true)
			end

		elseif event == "boost_end" then
			boostSoundActive = false
			stopSound("BoostStart")
			stopSound("BoostLoop")
			playOneShot("BoostEnd", BOOST_END_VOL)
			if isLocal then
				VehicleCamera.setBoostFOV(false)
			end

		elseif event == "damage_taken" then
			playOneShot(pick2("Misfire1", "Misfire2"), 0.7, 0.65)
			if isLocal then
				VehicleCamera.pushShake(0.25, 0.12)
				VehicleCamera.pushFOVPunch(-2, 0.1)
			end

		elseif event == "misfire" then
			playOneShot(pick2("Misfire1", "Misfire2"), 0.6)
			if isLocal then
				VehicleCamera.pushShake(0.4, 0.15)
				VehicleCamera.pushFOVPunch(-3, 0.12)
			end
			if damageSmokeEmitter ~= nil then
				damageSmokeEmitter:Emit(8)
			end

		elseif event == "lean_start" then
			local leanData = data :: SoundProfileTypes.LeanStartData?
			if leanData == nil then return end
			if isLocal then
				VehicleCamera.pushShake(leanShakeAmplitude, leanShakeDuration)
			end
			if leanData.speedFraction >= GEAR_SHIFT_LEAN_MIN_FRAC then
				local t = tick()
				if (t - lastLeanShiftTick) >= GEAR_SHIFT_LEAN_COOLDOWN then
					lastLeanShiftTick = t
					playOneShot(pick2("GearShift1", "GearShift2"), GEAR_SHIFT_LEAN_VOL)
					if isLocal then
						VehicleCamera.pushFOVPunch(2, 0.15)
					end
				end
			end
			fireDustKick(leanData.direction)

		elseif event == "landing" then
			local landingData = data :: SoundProfileTypes.LandingData?
			if landingData ~= nil and isLocal then
				local fraction = math.clamp(
					(landingData.impactSpeed - landingShakeThreshold) / math.max(1, fallDamageThreshold - landingShakeThreshold),
					0, 1
				)
				local amplitude = fraction * landingShakeIntensity
				if amplitude > 0.01 then
					VehicleCamera.pushShake(amplitude, 0.2)
				end
			end

		elseif event == "destroyed" then
			-- No special handling — destroy() will be called next
		end
	end

	function controller.destroy(_self: ProfileController)
		if destroyed then return end
		destroyed = true

		for _, conn in ipairs(connections) do
			conn:Disconnect()
		end
		table.clear(connections)

		-- Play engine stop: reparent to source model so it survives render model cleanup
		local engineStop = sounds["EngineStop"]
		if engineStop and sourceModel.Parent ~= nil then
			local primary = sourceModel.PrimaryPart
			if primary ~= nil then
				engineStop.SoundGroup = nil
				engineStop.Parent = primary
				engineStop.Volume = ENGINE_STOP_VOL
				engineStop:Play()
				Debris:AddItem(engineStop, 4)
				sounds["EngineStop"] = nil
			end
		end

		destroyLoopPair(closeLoop)
		destroyLoopPair(noiseLoop)

		for _, sound in pairs(sounds) do
			if sound.IsPlaying then sound:Stop() end
			sound:Destroy()
		end
		table.clear(sounds)

		soundGroup:Destroy()

		-- Cleanup VFX
		for _, entry in ipairs(hoverDustEntries) do
			if entry.emitter.Parent ~= nil then
				entry.emitter:Destroy()
			end
		end
		table.clear(hoverDustEntries)

		if damageSmokeEmitter ~= nil then
			damageSmokeEmitter:Destroy()
			damageSmokeEmitter = nil
		end

		if isLocal then
			VehicleCamera.setBoostFOV(false)
			VehicleCamera.setBrokenVibration(false)
		end
	end

	return controller
end

return speeder_default
