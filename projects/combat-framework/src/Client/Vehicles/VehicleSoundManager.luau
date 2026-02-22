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
local GEAR_SHIFT_LEAN_VOL = 0.30
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

-- Idle ramp
local ENGINE_IDLE_DELAY = 0.4
local ENGINE_IDLE_RAMP = 2.0

-- Spatial rolloff
local LOCAL_ROLLOFF_MIN = 10
local LOCAL_ROLLOFF_MAX = 200
local REMOTE_ROLLOFF_MIN = 30
local REMOTE_ROLLOFF_MAX = 1500

--------------------------------------------------------------------------
-- Controller type
--------------------------------------------------------------------------

export type SoundController = {
	update: (SoundController, dt: number) -> (),
	onLeanStarted: (SoundController, speedFraction: number) -> (),
	destroy: (SoundController) -> (),
}

--------------------------------------------------------------------------
-- Controller factory
--------------------------------------------------------------------------

function VehicleSoundManager.createController(
	source: Model,
	part: BasePart,
	ms: number,
	isLocal: boolean
): SoundController
	local maxSpeed = if ms > 0 then ms else 100
	local rolloffMin = if isLocal then LOCAL_ROLLOFF_MIN else REMOTE_ROLLOFF_MIN
	local rolloffMax = if isLocal then LOCAL_ROLLOFF_MAX else REMOTE_ROLLOFF_MAX

	local sounds: { [string]: Sound } = {}
	local connections: { RBXScriptConnection } = {}
	local destroyed = false

	local engineIdleRampStart: number = 0
	local lastGearShiftTick: number = 0
	local lastLeanShiftTick: number = 0
	local prevSpeedZone: number = 0
	local nextHowlTick: number = 0
	local boostSoundActive: boolean = false
	local brokenSoundActive: boolean = false
	local brokenSoundName: string? = nil
	local lastKnownHP: number = -1

	-- SoundGroup with subtle reverb
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
	-- Helpers (closed over this controller's state)
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
		sound.Parent = part
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

	local function pick2(a: string, b: string): string
		if math.random() < 0.5 then return a end
		return b
	end

	--------------------------------------------------------------------
	-- Create all sounds
	--------------------------------------------------------------------

	local ec = createSound("EngineClose", true, 0)
	if ec then
		ec.PlaybackSpeed = ENGINE_CLOSE_PITCH_LO
		ec:Play()
	end
	local en = createSound("EngineNoise", true, 0)
	if en then
		en.PlaybackSpeed = ENGINE_NOISE_PITCH_LO
		en:Play()
	end
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

	-- Watch boost attribute
	table.insert(connections, source:GetAttributeChangedSignal("VehicleBoosting"):Connect(function()
		if destroyed then return end
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
			stopSound("BoostStart")
			stopSound("BoostLoop")
			playOneShot("BoostEnd", BOOST_END_VOL)
		end
	end))

	-- Watch misfire attribute
	table.insert(connections, source:GetAttributeChangedSignal("VehicleMisfire"):Connect(function()
		if destroyed then return end
		if source:GetAttribute("VehicleMisfire") == true then
			playOneShot(pick2("Misfire1", "Misfire2"), 0.6)
			if isLocal then
				VehicleCamera.pushShake(0.4, 0.15)
				VehicleCamera.pushFOVPunch(-3, 0.12)
			end
		end
	end))

	--------------------------------------------------------------------
	-- Controller methods
	--------------------------------------------------------------------

	local controller = {} :: SoundController

	function controller.update(_self: SoundController, dt: number)
		if destroyed then return end

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

		-- Damage hit sound
		if type(hullHP) == "number" then
			if lastKnownHP >= 0 and hullHP < lastKnownHP then
				playOneShot(pick2("Misfire1", "Misfire2"), 0.7, 0.65)
				if isLocal then
					VehicleCamera.pushShake(0.25, 0.12)
					VehicleCamera.pushFOVPunch(-2, 0.1)
				end
			end
			lastKnownHP = hullHP
		end

		-- Engine idle ramp
		local idleRampFactor = 1
		local rampElapsed = tick() - engineIdleRampStart
		if rampElapsed < 0 then
			idleRampFactor = 0
		elseif rampElapsed < ENGINE_IDLE_RAMP then
			idleRampFactor = rampElapsed / ENGINE_IDLE_RAMP
		end

		-- Engine layer crossfade
		local ecS = sounds["EngineClose"]
		if ecS then
			local closeFrac = math.clamp(1 - speedFrac / ENGINE_CLOSE_FADE_END, 0, 1)
			ecS.Volume = closeFrac * ENGINE_CLOSE_PEAK_VOL * idleRampFactor
			ecS.PlaybackSpeed = ENGINE_CLOSE_PITCH_LO + speedFrac * (ENGINE_CLOSE_PITCH_HI - ENGINE_CLOSE_PITCH_LO)
		end

		local enS = sounds["EngineNoise"]
		if enS then
			local noiseRange = ENGINE_NOISE_FADE_FULL - ENGINE_NOISE_FADE_IN
			local noiseFrac = if noiseRange > 0
				then math.clamp((speedFrac - ENGINE_NOISE_FADE_IN) / noiseRange, 0, 1)
				else (if speedFrac >= ENGINE_NOISE_FADE_IN then 1 else 0)
			enS.Volume = noiseFrac * ENGINE_NOISE_PEAK_VOL * idleRampFactor
			enS.PlaybackSpeed = ENGINE_NOISE_PITCH_LO + speedFrac * (ENGINE_NOISE_PITCH_HI - ENGINE_NOISE_PITCH_LO)
		end

		-- Reduce engine volumes when broken sound is playing
		if brokenSoundActive then
			if ecS then ecS.Volume *= 0.6 end
			if enS then enS.Volume *= 0.7 end
		end

		-- Boost loop pitch modulation
		if boostSoundActive then
			local bl = sounds["BoostLoop"]
			if bl then
				bl.PlaybackSpeed = 1.0 + speedFrac * 0.15
			end
			if ecS and ecS.Volume > 0 then
				ecS.PlaybackSpeed *= 1.08
			end
			if enS and enS.Volume > 0 then
				enS.PlaybackSpeed *= 1.06
			end
		end

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
	end

	function controller.onLeanStarted(_self: SoundController, speedFraction: number)
		if destroyed then return end
		if speedFraction < GEAR_SHIFT_LEAN_MIN_FRAC then return end
		local t = tick()
		if (t - lastLeanShiftTick) < GEAR_SHIFT_LEAN_COOLDOWN then return end
		lastLeanShiftTick = t
		playOneShot(pick2("GearShift1", "GearShift2"), GEAR_SHIFT_LEAN_VOL)
		if isLocal then
			VehicleCamera.pushFOVPunch(2, 0.15)
		end
	end

	function controller.destroy(_self: SoundController)
		if destroyed then return end
		destroyed = true

		for _, conn in ipairs(connections) do
			conn:Disconnect()
		end
		table.clear(connections)

		-- Play engine stop: reparent to source model so it survives render model cleanup
		local engineStop = sounds["EngineStop"]
		if engineStop and source.Parent ~= nil then
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

		for _, sound in pairs(sounds) do
			if sound.IsPlaying then sound:Stop() end
			sound:Destroy()
		end
		table.clear(sounds)

		soundGroup:Destroy()

		if isLocal then
			VehicleCamera.setBrokenVibration(false)
		end
	end

	return controller
end

--------------------------------------------------------------------------
-- Singleton API (backwards compatible — wraps a single local controller)
--------------------------------------------------------------------------

local localController: SoundController? = nil

function VehicleSoundManager.activate(source: Model, renderModel: Model, config: VehicleConfig)
	VehicleSoundManager.deactivate()
	local rp = renderModel.PrimaryPart
	if rp == nil then return end
	localController = VehicleSoundManager.createController(source, rp, config.maxSpeed, true)
end

function VehicleSoundManager.update(dt: number)
	if localController ~= nil then
		localController:update(dt)
	end
end

function VehicleSoundManager.onLeanStarted(speedFraction: number)
	if localController ~= nil then
		localController:onLeanStarted(speedFraction)
	end
end

function VehicleSoundManager.deactivate()
	if localController ~= nil then
		localController:destroy()
		localController = nil
	end
end

return VehicleSoundManager
