--!strict

local Players = game:GetService("Players")

local clientRoot = Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("CombatFramework")
local profilesFolder = clientRoot:WaitForChild("Vehicles"):WaitForChild("SoundProfiles")

local SoundProfileTypes = require(profilesFolder:WaitForChild("SoundProfileTypes"))
type ProfileController = SoundProfileTypes.ProfileController
type ProfileModule = SoundProfileTypes.ProfileModule

local SoundProfileLoader = {}

local DEFAULT_PROFILE = "speeder_default"
local FIGHTER_PROFILE = "fighter_default"
local WALKER_PROFILE = "walker_biped"
local HEAVY_PROFILE = "heavy_default"

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

local function inferProfileName(sourceModel: Model): string
	local explicit = sourceModel:GetAttribute("SoundProfile")
	if type(explicit) == "string" and explicit ~= "" then
		return explicit
	end

	local category = sourceModel:GetAttribute("VehicleCategory")
	if type(category) ~= "string" then
		category = sourceModel:GetAttribute("VehicleConfigId")
	end
	if type(category) == "string" then
		local normalized = string.lower(category)
		if string.find(normalized, "fighter", 1, true) ~= nil then
			return FIGHTER_PROFILE
		end
		if string.find(normalized, "walker", 1, true) ~= nil then
			return WALKER_PROFILE
		end
		if string.find(normalized, "heavy", 1, true) ~= nil then
			return HEAVY_PROFILE
		end
	end

	return DEFAULT_PROFILE
end

function SoundProfileLoader.createController(
	sourceModel: Model,
	targetPart: BasePart,
	maxSpeed: number,
	isLocal: boolean
): ProfileController?
	local profileName = inferProfileName(sourceModel)

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
