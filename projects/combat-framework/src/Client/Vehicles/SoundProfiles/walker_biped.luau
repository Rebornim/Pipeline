--!strict

local ContentProvider = game:GetService("ContentProvider")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local clientRoot = Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("CombatFramework")
local sharedRoot = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatConfig = require(sharedRoot:WaitForChild("CombatConfig"))
local VehicleCamera = require(clientRoot:WaitForChild("Vehicles"):WaitForChild("VehicleCamera"))

local profilesFolder = clientRoot:WaitForChild("Vehicles"):WaitForChild("SoundProfiles")
local SoundProfileTypes = require(profilesFolder:WaitForChild("SoundProfileTypes"))
type ProfileController = SoundProfileTypes.ProfileController
type VehicleFrameState = SoundProfileTypes.VehicleFrameState

local walker_biped = {}

--------------------------------------------------------------------------
-- Sound tuning
--------------------------------------------------------------------------

local INTERIOR_PEAK_VOL = 0.70
local INTERIOR_ROLLOFF_MIN = 5
local INTERIOR_ROLLOFF_MAX = 30

local EXTERIOR_PEAK_VOL = 0.55
local EXTERIOR_ROLLOFF_MIN = 20
local EXTERIOR_ROLLOFF_MAX = 300

local ENGINE_IDLE_DELAY = 0.5
local ENGINE_IDLE_RAMP = 2.0
local ENGINE_IDLE_VOL_FRAC = 0.3 -- engines audible at idle (machine is always running)
local ENGINE_SPRINT_PITCH = 1.10 -- fixed pitch bump while sprinting

local STARTUP_VOL = 0.80
local SHUTDOWN_VOL = 0.70

local FOOT_STOMP_VOL = 0.75
local FOOT_STOMP_PITCH_LO = 0.90
local FOOT_STOMP_PITCH_HI = 1.10

local HEAD_TURN_LOOP_VOL = 0.40
local HEAD_TURN_STOP_VOL = 0.50

local FOOT_STUCK_VOL = 0.65
local FOOT_STUCK_COOLDOWN = 5.0

local LOOP_CROSSFADE = 0.15

--------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------

local function pick2(a: string, b: string): string
	if math.random() < 0.5 then return a end
	return b
end

local FOOT_LIFT_VOL = 0.55
local WALK_STOP_VOL = 0.60

--------------------------------------------------------------------------
-- Controller factory
--------------------------------------------------------------------------

function walker_biped.createController(
	sourceModel: Model,
	targetPart: BasePart,
	maxSpeed: number,
	isLocal: boolean
): ProfileController
	local ms = if maxSpeed > 0 then maxSpeed else 60

	local sounds: { [string]: Sound } = {}
	local connections: { RBXScriptConnection } = {}
	local destroyed = false

	-- Sound state
	local engineIdleRampStart: number = 0
	local smoothedEnginePitch: number = 1
	local headTurnLoopActive: boolean = false
	local lastFootStuckTick: number = 0
	local settleUseAlt: boolean = false

	-- SoundGroup with reverb
	local soundGroup = Instance.new("SoundGroup")
	soundGroup.Name = if isLocal then "WalkerSoundGroup" else "RemoteWalkerSoundGroup"
	soundGroup.Volume = 1
	local reverb = Instance.new("ReverbSoundEffect")
	reverb.DecayTime = 1.4
	reverb.Density = 0.8
	reverb.Diffusion = 0.5
	reverb.DryLevel = 0
	reverb.WetLevel = -6
	reverb.Parent = soundGroup
	soundGroup.Parent = SoundService

	--------------------------------------------------------------------
	-- Sound helpers
	--------------------------------------------------------------------

	local function createSoundCustom(name: string, looped: boolean, vol: number, rollMin: number, rollMax: number): Sound?
		local soundTable = CombatConfig.WalkerSounds
		if type(soundTable) ~= "table" then
			return nil
		end
		local assetId = (soundTable :: any)[name]
		if type(assetId) ~= "string" then
			return nil
		end
		local sound = Instance.new("Sound")
		sound.SoundId = assetId
		sound.Name = "Wlk_" .. name
		sound.Looped = looped
		sound.Volume = vol
		sound.RollOffMode = Enum.RollOffMode.InverseTapered
		sound.RollOffMinDistance = rollMin
		sound.RollOffMaxDistance = rollMax
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

	local function createSound(name: string, looped: boolean, vol: number): Sound?
		-- Default rolloff: exterior range (most walker sounds carry)
		return createSoundCustom(name, looped, vol, EXTERIOR_ROLLOFF_MIN, EXTERIOR_ROLLOFF_MAX)
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
	-- Crossfade loop pair (same as heavy_default)
	--------------------------------------------------------------------

	type LoopPair = {
		a: Sound,
		b: Sound,
		activeIsA: boolean,
		crossfading: boolean,
		crossfadeStart: number,
	}

	local function createLoopPairCustom(name: string, rollMin: number, rollMax: number): LoopPair?
		local soundTable = CombatConfig.WalkerSounds
		if type(soundTable) ~= "table" then return nil end
		local assetId = (soundTable :: any)[name]
		if type(assetId) ~= "string" then return nil end

		local function makeSound(suffix: string): Sound
			local s = Instance.new("Sound")
			s.SoundId = assetId
			s.Name = "Wlk_" .. name .. suffix
			s.Looped = true
			s.Volume = 0
			s.RollOffMode = Enum.RollOffMode.InverseTapered
			s.RollOffMinDistance = rollMin
			s.RollOffMaxDistance = rollMax
			s.SoundGroup = soundGroup
			s.Parent = targetPart
			-- Trim loop endpoints to minimize loop click
			local function applyLoopTrim()
				if s.TimeLength > 0.1 then
					pcall(function()
						s.LoopRegion = NumberRange.new(0.02, s.TimeLength - 0.02)
					end)
				end
			end
			if s.IsLoaded then
				applyLoopTrim()
			else
				s.Loaded:Once(applyLoopTrim)
			end
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
		-- With Looped=true + LoopRegion trim, just keep one sound playing.
		-- The B copy is a spare if we ever need crossfade, but the loop handles it.
		local active = pair.a
		if not active.IsPlaying then
			active.PlaybackSpeed = targetPitch
			active.Volume = targetVol
			active:Play()
		else
			active.Volume = targetVol
			active.PlaybackSpeed = targetPitch
		end
		-- Ensure standby is off
		if pair.b.IsPlaying then
			pair.b:Stop()
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
	-- Create all sounds
	--------------------------------------------------------------------

	-- Engine loop pairs: both play simultaneously with different rolloff
	local interiorLoop = createLoopPairCustom("STInteriorEngineLoop", INTERIOR_ROLLOFF_MIN, INTERIOR_ROLLOFF_MAX)
	local exteriorLoop = createLoopPairCustom("STExteriorEngineLoop", EXTERIOR_ROLLOFF_MIN, EXTERIOR_ROLLOFF_MAX)
	engineIdleRampStart = tick() + ENGINE_IDLE_DELAY

	-- One-shot sounds
	createSound("STStartup", false, 0)
	createSound("STShutdown", false, 0)
	createSoundCustom("HeadTurnLoop", true, 0, INTERIOR_ROLLOFF_MIN, EXTERIOR_ROLLOFF_MAX)
	createSound("HeadTurnStop1", false, 0)
	createSound("HeadTurnStop2", false, 0)
	createSound("FootStuck", false, 0)
	createSound("FootStomp3", false, 0)
	createSound("FootStomp4", false, 0)

	-- Second copy of stop sound for the other leg
	local stopSound2: Sound? = nil
	do
		local soundTable = CombatConfig.WalkerSounds
		local stopId = if type(soundTable) == "table" then (soundTable :: any)["FootStomp3"] else nil
		if type(stopId) == "string" then
			local s = Instance.new("Sound")
			s.SoundId = stopId
			s.Name = "Wlk_FootStomp3_b"
			s.Looped = false
			s.Volume = 0
			s.RollOffMode = Enum.RollOffMode.InverseTapered
			s.RollOffMinDistance = EXTERIOR_ROLLOFF_MIN
			s.RollOffMaxDistance = EXTERIOR_ROLLOFF_MAX
			s.SoundGroup = soundGroup
			s.Parent = targetPart
			stopSound2 = s
		end
	end

	-- Impact pool: 3 copies each of Stomp1+Stomp2 so rapid steps never cut off
	local STOMP_POOL_SIZE = 3
	local stompPool1: { Sound } = {}
	local stompPool2: { Sound } = {}
	local stompPoolIndex: number = 0
	do
		local soundTable = CombatConfig.WalkerSounds
		local id1 = if type(soundTable) == "table" then (soundTable :: any)["FootStomp1"] else nil
		local id2 = if type(soundTable) == "table" then (soundTable :: any)["FootStomp2"] else nil
		for i = 1, STOMP_POOL_SIZE do
			if type(id1) == "string" then
				local s = Instance.new("Sound")
				s.SoundId = id1
				s.Name = "Wlk_FootStomp1_" .. i
				s.Looped = false
				s.Volume = 0
				s.RollOffMode = Enum.RollOffMode.InverseTapered
				s.RollOffMinDistance = EXTERIOR_ROLLOFF_MIN
				s.RollOffMaxDistance = EXTERIOR_ROLLOFF_MAX
				s.SoundGroup = soundGroup
				s.Parent = targetPart
				table.insert(stompPool1, s)
			end
			if type(id2) == "string" then
				local s = Instance.new("Sound")
				s.SoundId = id2
				s.Name = "Wlk_FootStomp2_" .. i
				s.Looped = false
				s.Volume = 0
				s.RollOffMode = Enum.RollOffMode.InverseTapered
				s.RollOffMinDistance = EXTERIOR_ROLLOFF_MIN
				s.RollOffMaxDistance = EXTERIOR_ROLLOFF_MAX
				s.SoundGroup = soundGroup
				s.Parent = targetPart
				table.insert(stompPool2, s)
			end
		end
	end

	-- Preload stomp assets so they're ready for first step
	task.spawn(function()
		local toPreload: { Instance } = {}
		for _, s in ipairs(stompPool1) do table.insert(toPreload, s) end
		for _, s in ipairs(stompPool2) do table.insert(toPreload, s) end
		if sounds["FootStomp3"] then table.insert(toPreload, sounds["FootStomp3"]) end
		if sounds["FootStomp4"] then table.insert(toPreload, sounds["FootStomp4"]) end
		if #toPreload > 0 then
			ContentProvider:PreloadAsync(toPreload)
		end
	end)

	-- Startup sound
	playOneShot("STStartup", STARTUP_VOL)

	--------------------------------------------------------------------
	-- Controller
	--------------------------------------------------------------------

	local controller = {} :: ProfileController

	function controller.update(_self: ProfileController, dt: number, state: VehicleFrameState)
		if destroyed then return end

		local speedFrac = state.speedFraction

		-- Engine idle ramp (gradual engine spool after mount)
		local idleRampFactor = 1
		local rampElapsed = tick() - engineIdleRampStart
		if rampElapsed < 0 then
			idleRampFactor = 0
		elseif rampElapsed < ENGINE_IDLE_RAMP then
			idleRampFactor = rampElapsed / ENGINE_IDLE_RAMP
		end

		-- Both engine loops play simultaneously; pitch smoothly ramps when sprinting
		local targetPitch = if state.isBoosting then ENGINE_SPRINT_PITCH else 1
		smoothedEnginePitch += (targetPitch - smoothedEnginePitch) * (1 - math.exp(-4 * dt))
		local enginePitch = smoothedEnginePitch
		-- Volume: idle baseline + speed-scaled portion
		local intVol = (ENGINE_IDLE_VOL_FRAC + (1 - ENGINE_IDLE_VOL_FRAC) * speedFrac) * INTERIOR_PEAK_VOL * idleRampFactor
		updateLoopPair(interiorLoop, intVol, enginePitch)

		local extVol = (ENGINE_IDLE_VOL_FRAC + (1 - ENGINE_IDLE_VOL_FRAC) * speedFrac) * EXTERIOR_PEAK_VOL * idleRampFactor
		updateLoopPair(exteriorLoop, extVol, enginePitch)
	end

	function controller.onEvent(_self: ProfileController, event: string, data: any?)
		if destroyed then return end

		if event == "foot_plant" then
			-- Impact: both stomp sounds play together from pool
			stompPoolIndex = (stompPoolIndex % STOMP_POOL_SIZE) + 1
			local pitch = FOOT_STOMP_PITCH_LO + math.random() * (FOOT_STOMP_PITCH_HI - FOOT_STOMP_PITCH_LO)
			local s1 = stompPool1[stompPoolIndex]
			local s2 = stompPool2[stompPoolIndex]
			if s1 then
				s1.Volume = FOOT_STOMP_VOL
				s1.PlaybackSpeed = pitch
				s1.TimePosition = 0
				s1:Play()
			end
			if s2 then
				s2.Volume = FOOT_STOMP_VOL
				s2.PlaybackSpeed = pitch
				s2.TimePosition = 0
				s2:Play()
			end
			if isLocal then
				VehicleCamera.pushShake(0.15, 0.12)
			end

		elseif event == "foot_lift" then
			-- Foot pickup sound
			playOneShot("FootStomp4", FOOT_LIFT_VOL)

		elseif event == "settle_plant" then
			-- Settle step: impact + stop sound layered together
			stompPoolIndex = (stompPoolIndex % STOMP_POOL_SIZE) + 1
			local pitch = FOOT_STOMP_PITCH_LO + math.random() * (FOOT_STOMP_PITCH_HI - FOOT_STOMP_PITCH_LO)
			local s1 = stompPool1[stompPoolIndex]
			local s2 = stompPool2[stompPoolIndex]
			if s1 then
				s1.Volume = FOOT_STOMP_VOL
				s1.PlaybackSpeed = pitch
				s1.TimePosition = 0
				s1:Play()
			end
			if s2 then
				s2.Volume = FOOT_STOMP_VOL
				s2.PlaybackSpeed = pitch
				s2.TimePosition = 0
				s2:Play()
			end
			-- Delayed stop sound so impact doesn't mask it
			local useAlt = settleUseAlt
			settleUseAlt = not settleUseAlt
			task.delay(0.15, function()
				if destroyed then return end
				if useAlt and stopSound2 ~= nil then
					local ss = stopSound2 :: Sound
					ss.Volume = WALK_STOP_VOL
					ss.PlaybackSpeed = 0.95 + math.random() * 0.1
					ss.TimePosition = 0
					ss:Play()
				else
					playOneShot("FootStomp3", WALK_STOP_VOL)
				end
			end)
			if isLocal then
				VehicleCamera.pushShake(0.15, 0.12)
			end

		elseif event == "head_turning" then
			if not headTurnLoopActive then
				headTurnLoopActive = true
				local s = sounds["HeadTurnLoop"]
				if s ~= nil then
					s.Volume = HEAD_TURN_LOOP_VOL
					if not s.IsPlaying then
						s:Play()
					end
				end
			end

		elseif event == "head_loop_stop" then
			-- Fade out the turn loop (overlaps with stop sound)
			if headTurnLoopActive then
				headTurnLoopActive = false
				local loopSound = sounds["HeadTurnLoop"]
				if loopSound and loopSound.IsPlaying then
					task.spawn(function()
						local fadeTime = 0.3
						local startVol = loopSound.Volume
						local elapsed = 0
						while elapsed < fadeTime and loopSound.IsPlaying do
							elapsed += task.wait()
							loopSound.Volume = startVol * (1 - math.clamp(elapsed / fadeTime, 0, 1))
						end
						if loopSound.IsPlaying then loopSound:Stop() end
						loopSound.Volume = HEAD_TURN_LOOP_VOL
					end)
				end
			end

		elseif event == "head_stop" then
			-- Play stop sound (loop fade is handled by head_loop_stop)
			playOneShot(pick2("HeadTurnStop1", "HeadTurnStop2"), HEAD_TURN_STOP_VOL)

		elseif event == "wall_collision" then
			local now = tick()
			if (now - lastFootStuckTick) >= FOOT_STUCK_COOLDOWN then
				lastFootStuckTick = now
				playOneShot("FootStuck", FOOT_STUCK_VOL)
				if isLocal then
					VehicleCamera.pushShake(0.2, 0.15)
				end
			end

		elseif event == "damage_taken" then
			if isLocal then
				VehicleCamera.pushShake(0.3, 0.15)
				VehicleCamera.pushFOVPunch(-2, 0.1)
			end

		elseif event == "destroyed" then
			-- destroy() will be called next
		end
	end

	function controller.destroy(_self: ProfileController)
		if destroyed then return end
		destroyed = true

		for _, conn in ipairs(connections) do
			conn:Disconnect()
		end
		table.clear(connections)

		-- Play shutdown: reparent to source model so it survives cleanup
		local shutdownSound = sounds["STShutdown"]
		if shutdownSound and sourceModel.Parent ~= nil then
			local primary = sourceModel.PrimaryPart
			if primary ~= nil then
				shutdownSound.SoundGroup = nil
				shutdownSound.Parent = primary
				shutdownSound.Volume = SHUTDOWN_VOL
				shutdownSound:Play()
				Debris:AddItem(shutdownSound, 4)
				sounds["STShutdown"] = nil
			end
		end

		-- Stop head turn if active
		headTurnLoopActive = false

		destroyLoopPair(interiorLoop)
		destroyLoopPair(exteriorLoop)

		for _, s in ipairs(stompPool1) do
			if s.IsPlaying then s:Stop() end
			s:Destroy()
		end
		table.clear(stompPool1)
		for _, s in ipairs(stompPool2) do
			if s.IsPlaying then s:Stop() end
			s:Destroy()
		end
		table.clear(stompPool2)

		if stopSound2 ~= nil then
			if stopSound2.IsPlaying then stopSound2:Stop() end
			stopSound2:Destroy()
			stopSound2 = nil
		end

		for _, sound in pairs(sounds) do
			if sound.IsPlaying then sound:Stop() end
			sound:Destroy()
		end
		table.clear(sounds)

		soundGroup:Destroy()
	end

	return controller
end

return walker_biped
