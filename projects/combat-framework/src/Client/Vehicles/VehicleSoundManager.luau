--!strict

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local sharedRoot = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatConfig = require(sharedRoot:WaitForChild("CombatConfig"))
local CombatTypes = require(sharedRoot:WaitForChild("CombatTypes"))
type VehicleConfig = CombatTypes.VehicleConfig

local clientRoot = Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("CombatFramework")
local VehicleCamera = require(clientRoot:WaitForChild("Vehicles"):WaitForChild("VehicleCamera"))

local VehicleSoundManager = {}

--------------------------------------------------------------------------
-- Tuning constants
--------------------------------------------------------------------------

-- Engine crossfade (speed fractions of maxSpeed)
local ENGINE_CLOSE_PEAK_VOL = 0.75
local ENGINE_CLOSE_FADE_END = 0.50
local ENGINE_CLOSE_PITCH_LO = 0.80
local ENGINE_CLOSE_PITCH_HI = 1.30

local ENGINE_NOISE_PEAK_VOL = 0.55
local ENGINE_NOISE_FADE_IN = 0.15
local ENGINE_NOISE_FADE_FULL = 0.45
local ENGINE_NOISE_PITCH_LO = 0.85
local ENGINE_NOISE_PITCH_HI = 1.20

-- Gear shifts
local GEAR_SHIFT_COOLDOWN = 3.0
local GEAR_SHIFT_LEAN_COOLDOWN = 1.0
local GEAR_SHIFT_LEAN_MIN_FRAC = 0.50
local GEAR_SHIFT_VOL = 0.50
local MID_SPEED_FRAC = 0.45

-- Engine howls
local HOWL_MIN_INTERVAL = 8
local HOWL_MAX_INTERVAL = 15
local HOWL_SPEED_FRAC = 0.70

-- Broken engine
local BROKEN_HP_FRAC = 0.20
local BROKEN_BASE_VOL = 0.30
local BROKEN_SPEED_VOL = 0.20

-- Boost
local BOOST_LOOP_VOL = 0.60
local BOOST_START_VOL = 0.80
local BOOST_END_VOL = 0.70

-- Engine start/stop
local ENGINE_START_VOL = 0.70
local ENGINE_STOP_VOL = 0.60

--------------------------------------------------------------------------
-- Internal state
--------------------------------------------------------------------------

local active = false
local sourceModel: Model? = nil
local renderPart: BasePart? = nil
local maxSpeed: number = 100

local sounds: { [string]: Sound } = {}
local soundGroup: SoundGroup? = nil
local connections: { RBXScriptConnection } = {}

local engineIdleRampStart: number = 0
local ENGINE_IDLE_DELAY = 0.4
local ENGINE_IDLE_RAMP = 2.0

local lastGearShiftTick: number = 0
local lastLeanShiftTick: number = 0
local prevSpeedZone: number = 0
local nextHowlTick: number = 0
local boostSoundActive: boolean = false
local brokenSoundActive: boolean = false
local brokenSoundName: string? = nil
local lastKnownHP: number = -1

--------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------

local function createSound(name: string, parent: BasePart, looped: boolean, vol: number): Sound?
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
	sound.RollOffMinDistance = 10
	sound.RollOffMaxDistance = 200
	if soundGroup ~= nil then
		sound.SoundGroup = soundGroup
	end
	sound.Parent = parent

	-- Trim loop edges to eliminate decoder gap at loop boundaries
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
	if sound == nil then
		return
	end
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

local function pick2(a: string, b: string): string
	if math.random() < 0.5 then
		return a
	end
	return b
end

--------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------

function VehicleSoundManager.activate(source: Model, renderModel: Model, config: VehicleConfig)
	VehicleSoundManager.deactivate()

	sourceModel = source
	local rp = renderModel.PrimaryPart
	if rp == nil then
		return
	end
	renderPart = rp
	maxSpeed = if config.maxSpeed > 0 then config.maxSpeed else 100
	active = true

	-- SoundGroup with subtle reverb
	local group = Instance.new("SoundGroup")
	group.Name = "VehicleSoundGroup"
	group.Volume = 1
	local reverb = Instance.new("ReverbSoundEffect")
	reverb.DecayTime = 1.0
	reverb.Density = 0.6
	reverb.Diffusion = 0.7
	reverb.DryLevel = 0
	reverb.WetLevel = -10
	reverb.Parent = group
	group.Parent = SoundService
	soundGroup = group

	-- Engine loops (start at volume 0, ramp up after engine start sound finishes)
	local ec = createSound("EngineClose", rp, true, 0)
	if ec then
		ec.PlaybackSpeed = ENGINE_CLOSE_PITCH_LO
		ec:Play()
	end
	local en = createSound("EngineNoise", rp, true, 0)
	if en then
		en.PlaybackSpeed = ENGINE_NOISE_PITCH_LO
		en:Play()
	end
	engineIdleRampStart = tick() + ENGINE_IDLE_DELAY

	-- One-shots and conditional loops
	createSound("EngineStart", rp, false, 0)
	createSound("EngineStop", rp, false, 0)
	createSound("BoostStart", rp, false, 0)
	createSound("BoostLoop", rp, true, 0)
	createSound("BoostEnd", rp, false, 0)
	createSound("GearShift1", rp, false, 0)
	createSound("GearShift2", rp, false, 0)
	createSound("Howl1", rp, false, 0)
	createSound("Howl2", rp, false, 0)
	createSound("Misfire1", rp, false, 0)
	createSound("Misfire2", rp, false, 0)
	createSound("Broken1", rp, true, 0)
	createSound("Broken2", rp, true, 0)

	-- Play engine start one-shot
	playOneShot("EngineStart", ENGINE_START_VOL)

	-- Initialize timers
	local now = tick()
	nextHowlTick = now + HOWL_MIN_INTERVAL + math.random() * (HOWL_MAX_INTERVAL - HOWL_MIN_INTERVAL)
	lastGearShiftTick = now
	lastLeanShiftTick = now
	prevSpeedZone = 0
	boostSoundActive = false
	brokenSoundActive = false
	brokenSoundName = nil
	lastKnownHP = -1

	-- Watch boost attribute for one-shot triggers
	table.insert(connections, source:GetAttributeChangedSignal("VehicleBoosting"):Connect(function()
		local isBoosting = source:GetAttribute("VehicleBoosting") == true
		if isBoosting and not boostSoundActive then
			boostSoundActive = true
			playOneShot("BoostStart", BOOST_START_VOL)
			local loop = sounds["BoostLoop"]
			if loop then
				loop.Volume = BOOST_LOOP_VOL
				loop:Play()
			end
		elseif not isBoosting and boostSoundActive then
			boostSoundActive = false
			stopSound("BoostLoop")
			playOneShot("BoostEnd", BOOST_END_VOL)
		end
	end))

	-- Watch misfire attribute from server
	table.insert(connections, source:GetAttributeChangedSignal("VehicleMisfire"):Connect(function()
		if source:GetAttribute("VehicleMisfire") == true then
			playOneShot(pick2("Misfire1", "Misfire2"), 0.6)
			VehicleCamera.pushShake(0.4, 0.15)
			VehicleCamera.pushFOVPunch(-3, 0.12)
		end
	end))
end

function VehicleSoundManager.update(dt: number)
	if not active or sourceModel == nil then
		return
	end

	local source = sourceModel :: Model

	-- Read speed
	local speedAttr = source:GetAttribute("VehicleSpeed")
	local speed: number = if type(speedAttr) == "number" then speedAttr else 0
	local speedFrac = math.clamp(speed / maxSpeed, 0, 1)

	-- Read HP
	local hullHP = source:GetAttribute("HullHP")
	local maxHP = source:GetAttribute("MaxHullHP")
	local hpFrac: number = 1
	if type(hullHP) == "number" and type(maxHP) == "number" and maxHP > 0 then
		hpFrac = math.clamp(hullHP / maxHP, 0, 1)
	end

	-- Damage hit sound: pitched-down misfire for heavier impact feel
	if type(hullHP) == "number" then
		if lastKnownHP >= 0 and hullHP < lastKnownHP then
			playOneShot(pick2("Misfire1", "Misfire2"), 0.7, 0.65)
			VehicleCamera.pushShake(0.25, 0.12)
			VehicleCamera.pushFOVPunch(-2, 0.1)
		end
		lastKnownHP = hullHP
	end

	--------------------------------------------------------------------
	-- Engine idle ramp (wait for engine start sound before fading in loops)
	--------------------------------------------------------------------
	local idleRampFactor = 1
	local rampElapsed = tick() - engineIdleRampStart
	if rampElapsed < 0 then
		idleRampFactor = 0
	elseif rampElapsed < ENGINE_IDLE_RAMP then
		idleRampFactor = rampElapsed / ENGINE_IDLE_RAMP
	end

	--------------------------------------------------------------------
	-- Engine layer crossfade
	--------------------------------------------------------------------
	local ec = sounds["EngineClose"]
	if ec then
		local closeFrac = math.clamp(1 - speedFrac / ENGINE_CLOSE_FADE_END, 0, 1)
		ec.Volume = closeFrac * ENGINE_CLOSE_PEAK_VOL * idleRampFactor
		ec.PlaybackSpeed = ENGINE_CLOSE_PITCH_LO + speedFrac * (ENGINE_CLOSE_PITCH_HI - ENGINE_CLOSE_PITCH_LO)
	end

	local en = sounds["EngineNoise"]
	if en then
		local noiseRange = ENGINE_NOISE_FADE_FULL - ENGINE_NOISE_FADE_IN
		local noiseFrac = if noiseRange > 0
			then math.clamp((speedFrac - ENGINE_NOISE_FADE_IN) / noiseRange, 0, 1)
			else (if speedFrac >= ENGINE_NOISE_FADE_IN then 1 else 0)
		en.Volume = noiseFrac * ENGINE_NOISE_PEAK_VOL * idleRampFactor
		en.PlaybackSpeed = ENGINE_NOISE_PITCH_LO + speedFrac * (ENGINE_NOISE_PITCH_HI - ENGINE_NOISE_PITCH_LO)
	end

	-- Reduce engine volumes when broken sound is playing
	if brokenSoundActive then
		if ec then
			ec.Volume *= 0.6
		end
		if en then
			en.Volume *= 0.7
		end
	end

	--------------------------------------------------------------------
	-- Boost loop pitch modulation
	--------------------------------------------------------------------
	if boostSoundActive then
		local bl = sounds["BoostLoop"]
		if bl then
			bl.PlaybackSpeed = 1.0 + speedFrac * 0.15
		end
		-- Slightly boost engine pitch during boost
		if ec and ec.Volume > 0 then
			ec.PlaybackSpeed *= 1.08
		end
		if en and en.Volume > 0 then
			en.PlaybackSpeed *= 1.06
		end
	end

	--------------------------------------------------------------------
	-- Gear shift on mid-speed threshold crossing
	--------------------------------------------------------------------
	local now = tick()
	local currentSpeedZone = if speedFrac >= MID_SPEED_FRAC then 1 else 0
	if currentSpeedZone ~= prevSpeedZone and (now - lastGearShiftTick) >= GEAR_SHIFT_COOLDOWN then
		lastGearShiftTick = now
		playOneShot(pick2("GearShift1", "GearShift2"), GEAR_SHIFT_VOL)
		VehicleCamera.pushShake(0.15, 0.12)
		VehicleCamera.pushFOVPunch(2, 0.15)
	end
	prevSpeedZone = currentSpeedZone

	--------------------------------------------------------------------
	-- Engine howls at high speed
	--------------------------------------------------------------------
	if speedFrac >= HOWL_SPEED_FRAC and now >= nextHowlTick then
		local howlVol = 0.30 + speedFrac * 0.15
		playOneShot(pick2("Howl1", "Howl2"), howlVol)
		VehicleCamera.pushRollWobble(1.5, 0.3)
		nextHowlTick = now + HOWL_MIN_INTERVAL + math.random() * (HOWL_MAX_INTERVAL - HOWL_MIN_INTERVAL)
	end

	--------------------------------------------------------------------
	-- Broken engine loop (below 20% HP)
	--------------------------------------------------------------------
	if hpFrac <= BROKEN_HP_FRAC and hpFrac > 0 and not brokenSoundActive then
		brokenSoundActive = true
		brokenSoundName = pick2("Broken1", "Broken2")
		local bs = sounds[brokenSoundName]
		if bs then
			bs.Volume = BROKEN_BASE_VOL
			bs:Play()
		end
		VehicleCamera.setBrokenVibration(true)
	elseif (hpFrac > BROKEN_HP_FRAC or hpFrac <= 0) and brokenSoundActive then
		brokenSoundActive = false
		stopSound("Broken1")
		stopSound("Broken2")
		brokenSoundName = nil
		VehicleCamera.setBrokenVibration(false)
	end

	if brokenSoundActive and brokenSoundName ~= nil then
		local bs = sounds[brokenSoundName]
		if bs and bs.IsPlaying then
			bs.Volume = BROKEN_BASE_VOL + speedFrac * BROKEN_SPEED_VOL
		end
	end
end

function VehicleSoundManager.onLeanStarted(speedFraction: number)
	if not active then
		return
	end
	if speedFraction < GEAR_SHIFT_LEAN_MIN_FRAC then
		return
	end
	local now = tick()
	if (now - lastLeanShiftTick) < GEAR_SHIFT_LEAN_COOLDOWN then
		return
	end
	lastLeanShiftTick = now
	playOneShot(pick2("GearShift1", "GearShift2"), GEAR_SHIFT_VOL)
	VehicleCamera.pushFOVPunch(2, 0.15)
end

function VehicleSoundManager.deactivate()
	for _, conn in ipairs(connections) do
		conn:Disconnect()
	end
	table.clear(connections)

	-- Play engine stop: reparent to source model so it survives render model cleanup
	local source = sourceModel
	local engineStop = sounds["EngineStop"]
	if engineStop and source ~= nil and source.Parent ~= nil then
		local primary = source.PrimaryPart
		if primary ~= nil then
			engineStop.SoundGroup = nil
			engineStop.Parent = primary
			engineStop.Volume = ENGINE_STOP_VOL
			engineStop:Play()
			Debris:AddItem(engineStop, 4)
			sounds["EngineStop"] = nil
		end
	end

	-- Stop and destroy remaining sounds
	for _, sound in pairs(sounds) do
		if sound.IsPlaying then
			sound:Stop()
		end
		sound:Destroy()
	end
	table.clear(sounds)

	if soundGroup ~= nil then
		soundGroup:Destroy()
		soundGroup = nil
	end

	VehicleCamera.setBrokenVibration(false)

	sourceModel = nil
	renderPart = nil
	active = false
	boostSoundActive = false
	brokenSoundActive = false
	brokenSoundName = nil
	lastKnownHP = -1
end

return VehicleSoundManager
