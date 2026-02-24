--!strict

local Players = game:GetService("Players")

local clientRoot = Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("CombatFramework")
local profilesFolder = clientRoot:WaitForChild("Vehicles"):WaitForChild("SoundProfiles")

local SoundProfileTypes = require(profilesFolder:WaitForChild("SoundProfileTypes"))
type ProfileController = SoundProfileTypes.ProfileController
type ProfileModule = SoundProfileTypes.ProfileModule

local SoundProfileLoader = {}

local DEFAULT_PROFILE = "speeder_default"

-- Cache resolved profile modules to avoid repeated requires
local profileCache: { [string]: ProfileModule? } = {}

local function resolveProfile(profileName: string): ProfileModule?
	if profileCache[profileName] ~= nil then
		return profileCache[profileName]
	end

	local moduleInstance = profilesFolder:FindFirstChild(profileName)
	if moduleInstance == nil or not moduleInstance:IsA("ModuleScript") then
		profileCache[profileName] = nil :: any
		return nil
	end

	local ok, result = pcall(require, moduleInstance)
	if not ok then
		warn(string.format("[SoundProfile] Failed to load profile '%s': %s", profileName, tostring(result)))
		profileCache[profileName] = nil :: any
		return nil
	end

	local profileModule = result :: ProfileModule
	profileCache[profileName] = profileModule
	return profileModule
end

function SoundProfileLoader.createController(
	sourceModel: Model,
	targetPart: BasePart,
	maxSpeed: number,
	isLocal: boolean
): ProfileController?
	-- Read SoundProfile attribute from the source model
	local profileName = sourceModel:GetAttribute("SoundProfile")
	if type(profileName) ~= "string" or profileName == "" then
		return nil
	end

	local profileModule = resolveProfile(profileName)
	if profileModule == nil then
		-- Fallback to default
		if profileName ~= DEFAULT_PROFILE then
			profileModule = resolveProfile(DEFAULT_PROFILE)
		end
	end
	if profileModule == nil then
		warn(string.format("[SoundProfile] No profile found for '%s' and no default available", tostring(profileName)))
		return nil
	end

	local ok, controller = pcall(profileModule.createController, sourceModel, targetPart, maxSpeed, isLocal)
	if not ok then
		warn(string.format("[SoundProfile] Failed to create controller for '%s': %s", tostring(profileName), tostring(controller)))
		return nil
	end

	return controller :: ProfileController
end

return SoundProfileLoader
