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

local heavy_default = {}

--------------------------------------------------------------------------
-- Sound tuning
--------------------------------------------------------------------------

local CLOSE_PEAK_VOL = 0.80
local CLOSE_FADE_END = 0.45
local CLOSE_PITCH_LO = 0.70
local CLOSE_PITCH_HI = 1.10

local EXTERIOR_PEAK_VOL = 0.60
local EXTERIOR_FADE_IN = 0.10
local EXTERIOR_FADE_FULL = 0.40
local EXTERIOR_PITCH_LO = 0.75
local EXTERIOR_PITCH_HI = 1.05

local BROKEN_HP_FRAC = 0.25

local ENGINE_START_VOL = 0.75
local ENGINE_STOP_VOL = 0.65
local GUN_ONLINE_VOL = 0.50
local BUMP_VOL = 0.65

local ENGINE_IDLE_DELAY = 0.5
local ENGINE_IDLE_RAMP = 2.5

-- Steering groan: bump sound when steering hard
local STEER_GROAN_THRESHOLD = 0.4        -- min |steerInput| to trigger
local STEER_GROAN_COOLDOWN = 1.8         -- seconds between groans
local STEER_GROAN_VOL = 0.30
local STEER_GROAN_PITCH_LO = 0.60
local STEER_GROAN_PITCH_HI = 0.80
local STEER_GROAN_MIN_SPEED_FRAC = 0.08  -- must be moving a bit

-- Speed threshold: GunOnline at high speed, GunOffline when dropping back
local SPEED_HIGH_THRESHOLD = 0.45         -- fraction to trigger "full power" (early so lead-in lands right)
local SPEED_LOW_THRESHOLD = 0.35          -- fraction to trigger "powering down"
local SPEED_THRESHOLD_VOL = 0.20

-- Throttle punch: bump when slamming throttle from idle
local THROTTLE_PUNCH_THRESHOLD = 0.8      -- throttle value to trigger
local THROTTLE_PUNCH_IDLE_MAX = 0.15      -- previous speedFraction must be below this
local THROTTLE_PUNCH_COOLDOWN = 3.0
local THROTTLE_PUNCH_VOL = 0.30
local THROTTLE_PUNCH_PITCH = 0.65

local LOCAL_ROLLOFF_MIN = 10
local LOCAL_ROLLOFF_MAX = 200
local REMOTE_ROLLOFF_MIN = 30
local REMOTE_ROLLOFF_MAX = 1500

local LOOP_CROSSFADE = 0.15  -- seconds of overlap at loop boundary (J-cut)

--------------------------------------------------------------------------
-- VFX tuning
--------------------------------------------------------------------------

local DAMAGE_SMOKE_START = 0.55
local DAMAGE_SMOKE_FULL = 0.15
local DUST_MAX_LIFETIME = 1.6
local DEFAULT_DUST_COLOR = Color3.fromRGB(180, 160, 130)

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
	[Enum.Material.Ice] = Color3.fromRGB(200, 215, 230),
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

local function pickBump(): string
	local roll = math.random(1, 3)
	if roll == 1 then return "HeavyBump1" end
	if roll == 2 then return "HeavyBump2" end
	return "HeavyBump3"
end

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
		NumberSequenceKeypoint.new(0, 1.5),
		NumberSequenceKeypoint.new(0.3, 4.0),
		NumberSequenceKeypoint.new(0.7, 5.5),
		NumberSequenceKeypoint.new(1, 4.0),
	})
	emitter.Lifetime = NumberRange.new(1.0, 2.0)
	emitter.Speed = NumberRange.new(4, 10)
	emitter.SpreadAngle = Vector2.new(55, 55)
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

function heavy_default.createController(
	sourceModel: Model,
	targetPart: BasePart,
	maxSpeed: number,
	isLocal: boolean
): ProfileController
	local ms = if maxSpeed > 0 then maxSpeed else 80
	local rolloffMin = if isLocal then LOCAL_ROLLOFF_MIN else REMOTE_ROLLOFF_MIN
	local rolloffMax = if isLocal then LOCAL_ROLLOFF_MAX else REMOTE_ROLLOFF_MAX

	-- Read vehicle config for camera effect parameters
	local landingShakeThreshold: number = 10
	local landingShakeIntensity: number = 0.8
	local fallDamageThreshold: number = 35
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
			end
		end
	end

	local sounds: { [string]: Sound } = {}
	local connections: { RBXScriptConnection } = {}
	local destroyed = false

	-- Sound state
	local engineIdleRampStart: number = 0
	local brokenActive: boolean = false
	local lastSteerGroanTick: number = 0
	local prevSteerSign: number = 0          -- -1, 0, or 1
	local speedHighActive: boolean = false
	local lastThrottlePunchTick: number = 0

	-- VFX state
	local hoverDustEntries: { { part: BasePart, emitter: ParticleEmitter } } = {}
	local currentDustColor: Color3? = nil
	local dustRayParams: RaycastParams? = nil
	local damageSmokeEmitter: ParticleEmitter? = nil

	-- SoundGroup with reverb
	local soundGroup = Instance.new("SoundGroup")
	soundGroup.Name = if isLocal then "HeavyVehicleSoundGroup" else "RemoteHeavyVehicleSoundGroup"
	soundGroup.Volume = 1
	local reverb = Instance.new("ReverbSoundEffect")
	reverb.DecayTime = 1.2
	reverb.Density = 0.7
	reverb.Diffusion = 0.6
	reverb.DryLevel = 0
	reverb.WetLevel = -8
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

		-- Start active if nothing is playing
		if not active.IsPlaying and not pair.crossfading then
			active.PlaybackSpeed = targetPitch
			active.Volume = targetVol
			active:Play()
		end

		-- Near end → begin crossfade into standby
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
			NumberSequenceKeypoint.new(0, 0.8),
			NumberSequenceKeypoint.new(0.3, 3.0),
			NumberSequenceKeypoint.new(1, 5.0),
		})
		emitter.Lifetime = NumberRange.new(1.2, 2.5)
		emitter.Speed = NumberRange.new(2, 5)
		emitter.SpreadAngle = Vector2.new(35, 35)
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

		local rate = math.clamp(speed / 5, 0, 25)
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
		damageSmokeEmitter.Rate = intensity * 20
	end

	--------------------------------------------------------------------
	-- Create all sounds
	--------------------------------------------------------------------

	local closeLoop = createLoopPair("HeavyCloseLoop")
	local exteriorLoop = createLoopPair("HeavyExteriorLoop")
	engineIdleRampStart = tick() + ENGINE_IDLE_DELAY

	createSound("EngineStartHeavy", false, 0)
	createSound("EngineStopHeavy", false, 0)
	createSound("HeavyBump1", false, 0)
	createSound("HeavyBump2", false, 0)
	createSound("HeavyBump3", false, 0)
	createSound("HeavyGunOnline1", false, 0)
	createSound("HeavyGunOnline2", false, 0)
	createSound("HeavyGunOffline1", false, 0)
	createSound("HeavyGunOffline2", false, 0)

	-- Startup sequence: engine start only (no gun online — that plays when gunners sit)
	playOneShot("EngineStartHeavy", ENGINE_START_VOL)

	-- Setup VFX
	setupHoverDust()
	if isLocal then
		setupDamageSmoke()
	end

	-- Monitor gunner seats: play GunOnline when occupied, GunOffline when vacated
	for _, descendant in ipairs(sourceModel:GetDescendants()) do
		if descendant:IsA("Seat") and (CollectionService:HasTag(descendant, "TurretSeat") or CollectionService:HasTag(descendant, "ArtillerySeat")) then
			local seat = descendant :: Seat
			local wasOccupied = seat.Occupant ~= nil
			local conn = seat:GetPropertyChangedSignal("Occupant"):Connect(function()
				if destroyed then return end
				local occupied = seat.Occupant ~= nil
				if occupied and not wasOccupied then
					playOneShot(pick2("HeavyGunOnline1", "HeavyGunOnline2"), GUN_ONLINE_VOL)
				elseif not occupied and wasOccupied then
					playOneShot(pick2("HeavyGunOffline1", "HeavyGunOffline2"), GUN_ONLINE_VOL)
				end
				wasOccupied = occupied
			end)
			table.insert(connections, conn)
		end
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

		-- Engine layer crossfade: close dominant at low speed, exterior at high
		local closeFrac = math.clamp(1 - speedFrac / CLOSE_FADE_END, 0, 1)
		local closeVol = closeFrac * CLOSE_PEAK_VOL * idleRampFactor
		local closePitch = CLOSE_PITCH_LO + speedFrac * (CLOSE_PITCH_HI - CLOSE_PITCH_LO)
		updateLoopPair(closeLoop, closeVol, closePitch)

		local extRange = EXTERIOR_FADE_FULL - EXTERIOR_FADE_IN
		local extFrac = if extRange > 0
			then math.clamp((speedFrac - EXTERIOR_FADE_IN) / extRange, 0, 1)
			else (if speedFrac >= EXTERIOR_FADE_IN then 1 else 0)
		local extVol = extFrac * EXTERIOR_PEAK_VOL * idleRampFactor
		local extPitch = EXTERIOR_PITCH_LO + speedFrac * (EXTERIOR_PITCH_HI - EXTERIOR_PITCH_LO)
		updateLoopPair(exteriorLoop, extVol, extPitch)

		-- Broken state: camera vibration at low HP
		local hpFrac = state.hpFraction
		if hpFrac <= BROKEN_HP_FRAC and hpFrac > 0 and not brokenActive then
			brokenActive = true
			if isLocal then
				VehicleCamera.setBrokenVibration(true)
			end
		elseif (hpFrac > BROKEN_HP_FRAC or hpFrac <= 0) and brokenActive then
			brokenActive = false
			if isLocal then
				VehicleCamera.setBrokenVibration(false)
			end
		end

		-- Steering groans: play a low bump when steering hard while moving
		local steer = state.steerInput
		local steerSign = if steer > STEER_GROAN_THRESHOLD then 1
			elseif steer < -STEER_GROAN_THRESHOLD then -1
			else 0
		if steerSign ~= 0 and steerSign ~= prevSteerSign and speedFrac >= STEER_GROAN_MIN_SPEED_FRAC then
			local t = tick()
			if (t - lastSteerGroanTick) >= STEER_GROAN_COOLDOWN then
				lastSteerGroanTick = t
				local bumpName = pickBump()
				local pitch = STEER_GROAN_PITCH_LO + math.random() * (STEER_GROAN_PITCH_HI - STEER_GROAN_PITCH_LO)
				playOneShot(bumpName, STEER_GROAN_VOL, pitch)
				if isLocal then
					VehicleCamera.pushShake(0.08, 0.12)
				end
			end
		end
		prevSteerSign = steerSign

		-- Speed threshold: "full power" at high speed, "powering down" when dropping
		if speedFrac >= SPEED_HIGH_THRESHOLD and not speedHighActive then
			speedHighActive = true
			playOneShot(pick2("HeavyGunOnline1", "HeavyGunOnline2"), SPEED_THRESHOLD_VOL)
		elseif speedFrac <= SPEED_LOW_THRESHOLD and speedHighActive then
			speedHighActive = false
			playOneShot(pick2("HeavyGunOffline1", "HeavyGunOffline2"), SPEED_THRESHOLD_VOL)
		end

		-- Throttle punch: bump when slamming throttle from near-idle
		local throttle = state.throttle
		if throttle >= THROTTLE_PUNCH_THRESHOLD and speedFrac < THROTTLE_PUNCH_IDLE_MAX then
			local t = tick()
			if (t - lastThrottlePunchTick) >= THROTTLE_PUNCH_COOLDOWN then
				lastThrottlePunchTick = t
				playOneShot(pickBump(), THROTTLE_PUNCH_VOL, THROTTLE_PUNCH_PITCH)
				if isLocal then
					VehicleCamera.pushShake(0.12, 0.15)
					VehicleCamera.pushFOVPunch(1.5, 0.2)
				end
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
			-- Heavy vehicles don't boost, but handle gracefully
			return

		elseif event == "boost_end" then
			return

		elseif event == "damage_taken" then
			local bumpName = pickBump()
			playOneShot(bumpName, BUMP_VOL, 0.85 + math.random() * 0.2)
			if isLocal then
				VehicleCamera.pushShake(0.35, 0.18)
				VehicleCamera.pushFOVPunch(-2.5, 0.12)
			end

		elseif event == "misfire" then
			local bumpName = pickBump()
			playOneShot(bumpName, BUMP_VOL, 0.80 + math.random() * 0.15)
			if isLocal then
				VehicleCamera.pushShake(0.5, 0.2)
				VehicleCamera.pushFOVPunch(-3, 0.15)
			end
			if damageSmokeEmitter ~= nil then
				damageSmokeEmitter:Emit(10)
			end

		elseif event == "lean_start" then
			-- Heavy vehicles don't lean
			return

		elseif event == "landing" then
			local landingData = data :: SoundProfileTypes.LandingData?
			if landingData ~= nil then
				local bumpName = pickBump()
				local fraction = math.clamp(
					(landingData.impactSpeed - landingShakeThreshold) / math.max(1, fallDamageThreshold - landingShakeThreshold),
					0, 1
				)
				local bumpPitch = 0.80 + fraction * 0.25
				playOneShot(bumpName, BUMP_VOL + fraction * 0.2, bumpPitch)
				if isLocal then
					local amplitude = fraction * landingShakeIntensity
					if amplitude > 0.01 then
						VehicleCamera.pushShake(amplitude, 0.25)
					end
				end
			end

		elseif event == "collision" then
			local collisionData = data :: SoundProfileTypes.CollisionData?
			if collisionData ~= nil then
				local bumpName = pickBump()
				local intensity = math.clamp(collisionData.impactSpeed / 40, 0.3, 1)
				playOneShot(bumpName, BUMP_VOL * intensity, 0.75 + intensity * 0.3)
				if isLocal then
					VehicleCamera.pushShake(0.3 * intensity, 0.15)
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
		local engineStop = sounds["EngineStopHeavy"]
		if engineStop and sourceModel.Parent ~= nil then
			local primary = sourceModel.PrimaryPart
			if primary ~= nil then
				engineStop.SoundGroup = nil
				engineStop.Parent = primary
				engineStop.Volume = ENGINE_STOP_VOL
				engineStop:Play()
				Debris:AddItem(engineStop, 4)
				sounds["EngineStopHeavy"] = nil
			end
		end

		destroyLoopPair(closeLoop)
		destroyLoopPair(exteriorLoop)

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

return heavy_default
