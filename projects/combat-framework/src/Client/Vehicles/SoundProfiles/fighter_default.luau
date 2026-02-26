--!strict

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local sharedRoot = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatConfig = require(sharedRoot:WaitForChild("CombatConfig"))

local clientRoot = Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("CombatFramework")
local profilesFolder = clientRoot:WaitForChild("Vehicles"):WaitForChild("SoundProfiles")
local SoundProfileTypes = require(profilesFolder:WaitForChild("SoundProfileTypes"))
local VehicleCamera = require(clientRoot:WaitForChild("Vehicles"):WaitForChild("VehicleCamera"))
type ProfileController = SoundProfileTypes.ProfileController
type VehicleFrameState = SoundProfileTypes.VehicleFrameState

local fighter_default = {}

--------------------------------------------------------------------------------
-- Interior engine loop (cockpit / close layer)
--------------------------------------------------------------------------------
local INT_BASE_PITCH = 0.55
local INT_SPEED_PITCH = 0.15
local INT_BOOST_PITCH = 0.03
local INT_LOCAL_MIN_VOL = 0.12
local INT_LOCAL_MAX_VOL = 0.3
local INT_REMOTE_MIN_VOL = 0.03
local INT_REMOTE_MAX_VOL = 0.1
local INT_LOCAL_ROLL_MIN = 20
local INT_LOCAL_ROLL_MAX = 500
local INT_REMOTE_ROLL_MIN = 60
local INT_REMOTE_ROLL_MAX = 1800

--------------------------------------------------------------------------------
-- Exterior engine loop (outside / distant layer)
--------------------------------------------------------------------------------
local EXT_BASE_PITCH = 0.6
local EXT_SPEED_PITCH = 0.35
local EXT_BOOST_PITCH = 0.05
local EXT_LOCAL_MIN_VOL = 0.08
local EXT_LOCAL_MAX_VOL = 0.35
local EXT_REMOTE_MIN_VOL = 0.1
local EXT_REMOTE_MAX_VOL = 0.32
local EXT_LOCAL_ROLL_MIN = 40
local EXT_LOCAL_ROLL_MAX = 900
local EXT_REMOTE_ROLL_MIN = 100
local EXT_REMOTE_ROLL_MAX = 3000

--------------------------------------------------------------------------------
-- Acceleration / deceleration overlays (10s non-looped)
--------------------------------------------------------------------------------
local AD_LOCAL_MAX_VOL = 0.55
local AD_REMOTE_MAX_VOL = 0.25
local AD_BLEND_RATE = 3
local AD_PLAY_THRESHOLD = 0.08
local SPEED_DELTA_THRESHOLD = 0.03

--------------------------------------------------------------------------------
-- Boost
--------------------------------------------------------------------------------
local BOOST_BLEND_RATE = 8
local BOOST_VOL_LOCAL = 0.85
local BOOST_VOL_REMOTE = 0.4

--------------------------------------------------------------------------------
-- Engine kill
--------------------------------------------------------------------------------
local EK_BLEND_RATE = 6
local EK_ENGINE_VOL_FLOOR = 0.15
local EK_ENGINE_PITCH_DROP = 0.25
local WIND_LOCAL_MAX_VOL = 0.65
local WIND_REMOTE_MAX_VOL = 0.3
local WIND_FADE_RATE = 3

--------------------------------------------------------------------------------
-- Weapons
--------------------------------------------------------------------------------
local SHOOT_VOL_LOCAL = 0.7
local SHOOT_VOL_REMOTE = 0.35
local TORPEDO_VOL_LOCAL = 0.8
local TORPEDO_VOL_REMOTE = 0.4

--------------------------------------------------------------------------------
-- Turn whoosh (boost start sound repurposed)
--------------------------------------------------------------------------------
local WHOOSH_COOLDOWN = 0.7
local WHOOSH_STEER_THRESHOLD = 0.4
local WHOOSH_VOL_LOCAL = 0.5
local WHOOSH_VOL_REMOTE = 0.25

--------------------------------------------------------------------------------
-- G-force stress (decel sound at low pitch = metallic groan)
--------------------------------------------------------------------------------
local STRESS_PITCH = 0.5
local STRESS_LOCAL_MAX_VOL = 0.3
local STRESS_REMOTE_MAX_VOL = 0.15
local STRESS_BLEND_RATE = 4
local STRESS_SPEED_FLOOR = 0.35
local STRESS_STEER_FLOOR = 0.25

--------------------------------------------------------------------------------
-- Camera effects (local only)
--------------------------------------------------------------------------------
local SPEED_FOV_MAX = 5
local SPEED_SHAKE_MAX = 0.15
local BOOST_SHAKE = 0.3
local BOOST_FOV_PUNCH = 5
local TURN_SHAKE_MAX = 0.12

--------------------------------------------------------------------------------
-- Landing
--------------------------------------------------------------------------------
local LANDING_VOL_LOCAL = 0.9
local LANDING_VOL_REMOTE = 0.5

--------------------------------------------------------------------------------
-- Flyby (1s punch — boost engage, engine re-engage)
--------------------------------------------------------------------------------
local FLYBY_VOL_LOCAL = 0.8
local FLYBY_VOL_REMOTE = 0.4

--------------------------------------------------------------------------------
-- Startup / shutdown
--------------------------------------------------------------------------------
local STARTUP_VOL_LOCAL = 1.0
local STARTUP_VOL_REMOTE = 0.6
local SHUTDOWN_VOL_LOCAL = 1.0

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------
local function getSoundId(name: string): string?
	local sounds = CombatConfig.FighterSounds
	if type(sounds) ~= "table" then
		return nil
	end
	local raw = (sounds :: any)[name]
	if type(raw) ~= "string" or raw == "" or raw == "rbxassetid://0" then
		return nil
	end
	return raw
end

local function makeSound(
	name: string,
	soundId: string,
	parent: Instance,
	looped: boolean,
	volume: number,
	pitch: number,
	rollMin: number,
	rollMax: number,
	group: SoundGroup
): Sound
	local s = Instance.new("Sound")
	s.Name = name
	s.SoundId = soundId
	s.Looped = looped
	s.Volume = volume
	s.PlaybackSpeed = pitch
	s.RollOffMode = Enum.RollOffMode.InverseTapered
	s.RollOffMinDistance = rollMin
	s.RollOffMaxDistance = rollMax
	s.SoundGroup = group
	s.Parent = parent
	return s
end

local function playOneShot(soundId: string, parent: Instance, volume: number, pitch: number)
	local s = Instance.new("Sound")
	s.Name = "FighterOneShot"
	s.SoundId = soundId
	s.Looped = false
	s.Volume = volume
	s.PlaybackSpeed = pitch
	s.RollOffMode = Enum.RollOffMode.InverseTapered
	s.Parent = parent
	s:Play()
	Debris:AddItem(s, 8)
end

--------------------------------------------------------------------------------
-- Profile
--------------------------------------------------------------------------------
function fighter_default.createController(
	sourceModel: Model,
	targetPart: BasePart,
	maxSpeed: number,
	isLocal: boolean
): ProfileController
	local ms = math.max(1, maxSpeed)

	local intMinVol = if isLocal then INT_LOCAL_MIN_VOL else INT_REMOTE_MIN_VOL
	local intMaxVol = if isLocal then INT_LOCAL_MAX_VOL else INT_REMOTE_MAX_VOL
	local intRollMin = if isLocal then INT_LOCAL_ROLL_MIN else INT_REMOTE_ROLL_MIN
	local intRollMax = if isLocal then INT_LOCAL_ROLL_MAX else INT_REMOTE_ROLL_MAX

	local extMinVol = if isLocal then EXT_LOCAL_MIN_VOL else EXT_REMOTE_MIN_VOL
	local extMaxVol = if isLocal then EXT_LOCAL_MAX_VOL else EXT_REMOTE_MAX_VOL
	local extRollMin = if isLocal then EXT_LOCAL_ROLL_MIN else EXT_REMOTE_ROLL_MIN
	local extRollMax = if isLocal then EXT_LOCAL_ROLL_MAX else EXT_REMOTE_ROLL_MAX

	local adMaxVol = if isLocal then AD_LOCAL_MAX_VOL else AD_REMOTE_MAX_VOL
	local boostVol = if isLocal then BOOST_VOL_LOCAL else BOOST_VOL_REMOTE
	local windMaxVol = if isLocal then WIND_LOCAL_MAX_VOL else WIND_REMOTE_MAX_VOL
	local shootVol = if isLocal then SHOOT_VOL_LOCAL else SHOOT_VOL_REMOTE
	local torpVol = if isLocal then TORPEDO_VOL_LOCAL else TORPEDO_VOL_REMOTE
	local stressMaxVol = if isLocal then STRESS_LOCAL_MAX_VOL else STRESS_REMOTE_MAX_VOL
	local landingVol = if isLocal then LANDING_VOL_LOCAL else LANDING_VOL_REMOTE
	local flybyVol = if isLocal then FLYBY_VOL_LOCAL else FLYBY_VOL_REMOTE
	local whooshVol = if isLocal then WHOOSH_VOL_LOCAL else WHOOSH_VOL_REMOTE

	-- State
	local destroyed = false
	local boostBlend = 0
	local accelBlend = 0
	local decelBlend = 0
	local prevSpeedFraction = 0
	local engineKilled = false
	local ekBlend = 0
	local windPlaying = false
	local startupClock = 0
	local stressBlend = 0
	local prevSteerForWhoosh = 0
	local lastWhooshTime = 0
	local startupBlend = 0
	local crossfadeReady = false

	-- Sound group
	local soundGroup = Instance.new("SoundGroup")
	soundGroup.Name = if isLocal then "FighterSoundGroup" else "RemoteFighterSoundGroup"
	soundGroup.Volume = 1
	soundGroup.Parent = SoundService

	-- Engine startup delay
	local ENGINE_START_DELAY = 1.0
	local ENGINE_FADE_IN_RATE = 2.0

	----------------------------------------------------------------------------
	-- Crossfade engine loops: two copies per layer, offset by half duration.
	-- Each copy runs at half the target volume so the sum equals the target.
	-- When copy A hits its loop seam, copy B is mid-playback (smooth).
	----------------------------------------------------------------------------
	local engineIntA: Sound? = nil
	local engineIntB: Sound? = nil
	local intId = getSoundId("engineLoop")
	if intId ~= nil then
		engineIntA = makeSound("XWingEngineIntA", intId, targetPart, true, 0, INT_BASE_PITCH, intRollMin, intRollMax, soundGroup)
		engineIntB = makeSound("XWingEngineIntB", intId, targetPart, true, 0, INT_BASE_PITCH, intRollMin, intRollMax, soundGroup)
	end

	local engineExtA: Sound? = nil
	local engineExtB: Sound? = nil
	local extId = getSoundId("engineLoopExt")
	if extId ~= nil then
		engineExtA = makeSound("XWingEngineExtA", extId, targetPart, true, 0, EXT_BASE_PITCH, extRollMin, extRollMax, soundGroup)
		engineExtB = makeSound("XWingEngineExtB", extId, targetPart, true, 0, EXT_BASE_PITCH, extRollMin, extRollMax, soundGroup)
	end

	-- Acceleration overlay (non-looped, managed)
	local accelSound: Sound? = nil
	local accelId = getSoundId("acceleration")
	if accelId ~= nil then
		accelSound = makeSound("XWingAccel", accelId, targetPart, false, 0, 1, intRollMin, intRollMax, soundGroup)
	end

	-- Deceleration overlay (non-looped, managed)
	local decelSound: Sound? = nil
	local decelId = getSoundId("deceleration")
	if decelId ~= nil then
		decelSound = makeSound("XWingDecel", decelId, targetPart, false, 0, 1, intRollMin, intRollMax, soundGroup)
	end

	-- Engine kill wind rush (non-looped)
	local windSound: Sound? = nil
	local windId = getSoundId("engineKillWind")
	if windId ~= nil then
		windSound = makeSound("XWingWind", windId, targetPart, false, 0, 1, intRollMin, intRollMax, soundGroup)
	end

	-- G-force stress (decel sound at low pitch = metallic groan during hard turns)
	local stressSound: Sound? = nil
	if decelId ~= nil then
		stressSound = makeSound("XWingStress", decelId, targetPart, false, 0, STRESS_PITCH, intRollMin, intRollMax, soundGroup)
	end

	-- Startup one-shot
	local startupId = getSoundId("startup")
	if startupId ~= nil then
		playOneShot(startupId, targetPart, if isLocal then STARTUP_VOL_LOCAL else STARTUP_VOL_REMOTE, 1)
	end

	----------------------------------------------------------------------------
	local controller = {} :: any

	function controller.update(_self: ProfileController, dt: number, state: VehicleFrameState)
		if destroyed then
			return
		end

		local safeDt = math.max(dt, 1 / 240)
		local speedFrac = math.clamp(state.speed / ms, 0, 1)

		-- Startup delay + fade-in
		startupClock += safeDt
		if startupClock >= ENGINE_START_DELAY then
			startupBlend = math.min(1, startupBlend + ENGINE_FADE_IN_RATE * safeDt)

			-- Start A copies on first frame past delay
			if engineIntA ~= nil then
				local s = engineIntA :: Sound
				if not s.IsPlaying then s:Play() end
			end
			if engineExtA ~= nil then
				local s = engineExtA :: Sound
				if not s.IsPlaying then s:Play() end
			end

			-- Start B copies offset by half once TimeLength is known
			if not crossfadeReady then
				local intLen = if engineIntA ~= nil then (engineIntA :: Sound).TimeLength else 0
				local extLen = if engineExtA ~= nil then (engineExtA :: Sound).TimeLength else 0
				if intLen > 0 or extLen > 0 then
					crossfadeReady = true
					if engineIntB ~= nil and intLen > 0 then
						local s = engineIntB :: Sound
						s.TimePosition = intLen / 2
						s:Play()
					end
					if engineExtB ~= nil and extLen > 0 then
						local s = engineExtB :: Sound
						s.TimePosition = extLen / 2
						s:Play()
					end
				end
			end
		end

		-- Smooth blends
		boostBlend += ((if state.isBoosting then 1 else 0) - boostBlend)
			* (1 - math.exp(-BOOST_BLEND_RATE * safeDt))

		ekBlend += ((if engineKilled then 1 else 0) - ekBlend)
			* (1 - math.exp(-EK_BLEND_RATE * safeDt))

		-- Engine kill multipliers: volume drops to floor, pitch drops
		local ekVolMult = 1 - ekBlend * (1 - EK_ENGINE_VOL_FLOOR)
		local ekPitchDrop = ekBlend * EK_ENGINE_PITCH_DROP

		-- Interior engine (both A and B copies at half target volume)
		local intPitch = math.max(0.1, INT_BASE_PITCH + speedFrac * INT_SPEED_PITCH + boostBlend * INT_BOOST_PITCH - ekPitchDrop)
		local intVol = (intMinVol + (intMaxVol - intMinVol) * speedFrac + boostBlend * 0.04) * ekVolMult * startupBlend * 0.5
		if engineIntA ~= nil then
			local s = engineIntA :: Sound
			s.PlaybackSpeed = intPitch
			s.Volume = intVol
		end
		if engineIntB ~= nil then
			local s = engineIntB :: Sound
			s.PlaybackSpeed = intPitch
			s.Volume = intVol
		end

		-- Exterior engine (both A and B copies at half target volume)
		local extPitch = math.max(0.1, EXT_BASE_PITCH + speedFrac * EXT_SPEED_PITCH + boostBlend * EXT_BOOST_PITCH - ekPitchDrop)
		local extVol = (extMinVol + (extMaxVol - extMinVol) * speedFrac + boostBlend * 0.03) * ekVolMult * startupBlend * 0.5
		if engineExtA ~= nil then
			local s = engineExtA :: Sound
			s.PlaybackSpeed = extPitch
			s.Volume = extVol
		end
		if engineExtB ~= nil then
			local s = engineExtB :: Sound
			s.PlaybackSpeed = extPitch
			s.Volume = extVol
		end

		-- Accel/decel detection via speed change rate
		local speedDelta = (speedFrac - prevSpeedFraction) / safeDt
		prevSpeedFraction = speedFrac

		local accelTarget = 0
		local decelTarget = 0
		if not engineKilled then
			if speedDelta > SPEED_DELTA_THRESHOLD then
				accelTarget = math.clamp(speedDelta / 0.3, 0, 1)
			elseif speedDelta < -SPEED_DELTA_THRESHOLD then
				decelTarget = math.clamp(-speedDelta / 0.3, 0, 1)
			end
		end

		accelBlend += (accelTarget - accelBlend) * (1 - math.exp(-AD_BLEND_RATE * safeDt))
		decelBlend += (decelTarget - decelBlend) * (1 - math.exp(-AD_BLEND_RATE * safeDt))

		if accelSound ~= nil then
			local s = accelSound :: Sound
			s.Volume = accelBlend * adMaxVol
			if accelBlend >= AD_PLAY_THRESHOLD and not s.IsPlaying then
				s.TimePosition = 0
				s:Play()
			elseif accelBlend < AD_PLAY_THRESHOLD * 0.5 and s.IsPlaying then
				s:Stop()
			end
		end

		if decelSound ~= nil then
			local s = decelSound :: Sound
			s.Volume = decelBlend * adMaxVol
			if decelBlend >= AD_PLAY_THRESHOLD and not s.IsPlaying then
				s.TimePosition = 0
				s:Play()
			elseif decelBlend < AD_PLAY_THRESHOLD * 0.5 and s.IsPlaying then
				s:Stop()
			end
		end

		-- Wind sound fade after engine kill ends
		if windSound ~= nil then
			local ws = windSound :: Sound
			if windPlaying then
				if not engineKilled then
					local newVol = ws.Volume - WIND_FADE_RATE * safeDt * windMaxVol
					if newVol <= 0.01 then
						ws:Stop()
						windPlaying = false
						ws.Volume = 0
					else
						ws.Volume = newVol
					end
				end
				if not ws.IsPlaying then
					windPlaying = false
				end
			end
		end

		-- G-force stress (metallic groan during high-speed turns) — suppressed during landing
		if stressSound ~= nil then
			local ss = stressSound :: Sound
			local steerMag = math.abs(state.steerInput)
			local stressTarget = 0
			if speedFrac > STRESS_SPEED_FLOOR and steerMag > STRESS_STEER_FLOOR and not engineKilled and not state.isLanding then
				local speedFactor = (speedFrac - STRESS_SPEED_FLOOR) / (1 - STRESS_SPEED_FLOOR)
				local steerFactor = (steerMag - STRESS_STEER_FLOOR) / (1 - STRESS_STEER_FLOOR)
				stressTarget = math.clamp(speedFactor * steerFactor, 0, 1)
			end
			stressBlend += (stressTarget - stressBlend) * (1 - math.exp(-STRESS_BLEND_RATE * safeDt))
			ss.Volume = stressBlend * stressMaxVol
			if stressBlend >= 0.05 and not ss.IsPlaying then
				ss.TimePosition = 0
				ss:Play()
			elseif stressBlend < 0.02 and ss.IsPlaying then
				ss:Stop()
			end
		end

		-- Turn whoosh (boost start sound repurposed as maneuvering swoosh) — suppressed during landing
		if isLocal and not engineKilled and not state.isLanding then
			local steerDelta = math.abs(state.steerInput - prevSteerForWhoosh)
			local now = os.clock()
			if steerDelta > WHOOSH_STEER_THRESHOLD and now - lastWhooshTime > WHOOSH_COOLDOWN and speedFrac > 0.2 then
				local whooshId = getSoundId("boostStart")
				if whooshId ~= nil then
					local pitch = 0.7 + math.random() * 0.5
					local vol = whooshVol * math.clamp(speedFrac, 0.3, 1)
					playOneShot(whooshId, targetPart, vol, pitch)
					lastWhooshTime = now
				end
			end
		end
		prevSteerForWhoosh = state.steerInput

		-- Camera effects (local only)
		if isLocal then
			local shakeAmp = speedFrac * SPEED_SHAKE_MAX + boostBlend * BOOST_SHAKE + math.abs(state.steerInput) * speedFrac * TURN_SHAKE_MAX
			if shakeAmp > 0.01 then
				VehicleCamera.pushShake(shakeAmp, 0.15)
			end
			VehicleCamera.setExternalFOVOffset(speedFrac * SPEED_FOV_MAX)
		end
	end

	function controller.onEvent(_self: ProfileController, event: string, data: any?)
		if destroyed then
			return
		end

		if event == "boost_start" then
			local id = getSoundId("boostStart")
			if id ~= nil then
				playOneShot(id, targetPart, boostVol, 1)
			end
			local fb = getSoundId("flyby")
			if fb ~= nil then
				playOneShot(fb, targetPart, flybyVol, 1)
			end
			if isLocal then
				VehicleCamera.setBoostFOV(true)
				VehicleCamera.pushFOVPunch(BOOST_FOV_PUNCH, 0.3)
				VehicleCamera.pushRollWobble(3, 0.4)
			end

		elseif event == "boost_end" then
			local id = getSoundId("boostEnd")
			if id ~= nil then
				playOneShot(id, targetPart, boostVol * 0.8, 1)
			end
			if isLocal then
				VehicleCamera.setBoostFOV(false)
			end

		elseif event == "engine_kill_on" then
			engineKilled = true
			if windSound ~= nil then
				local ws = windSound :: Sound
				local sf = 0.5
				if type(data) == "table" and type((data :: any).speedFraction) == "number" then
					sf = (data :: any).speedFraction
				end
				ws.Volume = math.clamp(sf, 0.2, 1) * windMaxVol
				ws.TimePosition = 0
				ws:Play()
				windPlaying = true
			end

		elseif event == "engine_kill_off" then
			engineKilled = false
			local fb = getSoundId("flyby")
			if fb ~= nil then
				playOneShot(fb, targetPart, flybyVol * 0.9, 1.1)
			end

		elseif event == "auto_land_start" then
			local id = getSoundId("landing")
			if id ~= nil then
				playOneShot(id, targetPart, landingVol, 1)
			end

		elseif event == "fire_primary" then
			local id = getSoundId("shoot")
			if id ~= nil then
				local pitch = 0.95 + math.random() * 0.1
				playOneShot(id, targetPart, shootVol, pitch)
			end

		elseif event == "fire_secondary" then
			local id = getSoundId("torpedo")
			if id ~= nil then
				playOneShot(id, targetPart, torpVol, 1)
			end
		end
	end

	function controller.destroy(_self: ProfileController)
		if destroyed then
			return
		end
		destroyed = true

		local function stopAndDestroy(s: Sound?)
			if s ~= nil then
				local snd = s :: Sound
				if snd.IsPlaying then
					snd:Stop()
				end
				snd:Destroy()
			end
		end

		stopAndDestroy(engineIntA)
		stopAndDestroy(engineIntB)
		stopAndDestroy(engineExtA)
		stopAndDestroy(engineExtB)
		stopAndDestroy(accelSound)
		stopAndDestroy(decelSound)
		stopAndDestroy(windSound)
		stopAndDestroy(stressSound)
		engineIntA = nil
		engineIntB = nil
		engineExtA = nil
		engineExtB = nil
		accelSound = nil
		decelSound = nil
		windSound = nil
		stressSound = nil

		if isLocal then
			VehicleCamera.setBoostFOV(false)
			VehicleCamera.setExternalFOVOffset(0)
		end

		local shutdownId = getSoundId("shutdown")
		if isLocal and shutdownId ~= nil then
			local shutdownParent = sourceModel.PrimaryPart
			if shutdownParent ~= nil and shutdownParent.Parent ~= nil then
				playOneShot(shutdownId, shutdownParent, SHUTDOWN_VOL_LOCAL, 1)
			end
		end

		soundGroup:Destroy()
	end

	return controller :: ProfileController
end

return fighter_default
