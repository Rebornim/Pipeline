--!strict

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local sharedRoot = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatConfig = require(sharedRoot:WaitForChild("CombatConfig"))
local CombatEnums = require(sharedRoot:WaitForChild("CombatEnums"))
local CombatTypes = require(sharedRoot:WaitForChild("CombatTypes"))

type ValidatedEntity = CombatTypes.ValidatedEntity

local StartupValidator = {}

local validFactionSet = {
	[CombatEnums.Faction.Empire] = true,
	[CombatEnums.Faction.Rebel] = true,
	[CombatEnums.Faction.Neutral] = true,
}

local function fail(modelName: string, message: string)
	warn(string.format("[VALIDATE_FAIL] %s: %s", modelName, message))
end

local function findTaggedDescendant(model: Model, tagName: string, className: string?): Instance?
	for _, descendant in ipairs(model:GetDescendants()) do
		if CollectionService:HasTag(descendant, tagName) then
			if className == nil or descendant:IsA(className) then
				return descendant
			end
		end
	end
	return nil
end

function StartupValidator.validate(): { ValidatedEntity }
	local validated: { ValidatedEntity } = {}
	local entities = CollectionService:GetTagged("CombatEntity")

	for _, instance in ipairs(entities) do
		if not instance:IsA("Model") then
			fail(instance:GetFullName(), "CombatEntity tag must be on a Model")
			continue
		end

		local model = instance
		local modelName = model.Name
		local faction = model:GetAttribute("Faction")
		local configId = model:GetAttribute("ConfigId")

		if type(faction) ~= "string" then
			fail(modelName, "missing Faction attribute")
			continue
		end

		if not validFactionSet[faction] then
			fail(modelName, string.format("invalid Faction '%s'", tostring(faction)))
			continue
		end

		if type(configId) ~= "string" then
			fail(modelName, "missing ConfigId attribute")
			continue
		end

		local entityConfig = CombatConfig.Entities[configId]
		if entityConfig == nil then
			fail(modelName, string.format("unknown ConfigId '%s'", configId))
			continue
		end

		local weaponMount: BasePart? = nil
		local muzzlePoint: Attachment? = nil
		local turretSeat: Seat? = nil

		if entityConfig.weaponId ~= nil then
			if CombatConfig.Weapons[entityConfig.weaponId] == nil then
				fail(modelName, string.format("weaponId '%s' not found in CombatConfig.Weapons", entityConfig.weaponId))
				continue
			end

			local mountCandidate = findTaggedDescendant(model, "WeaponMount", "BasePart")
			if mountCandidate == nil then
				fail(modelName, "has weaponId but no WeaponMount tagged child")
				continue
			end

			weaponMount = mountCandidate :: BasePart
			local muzzle = weaponMount:FindFirstChild("MuzzlePoint")
			if muzzle ~= nil and muzzle:IsA("Attachment") then
				muzzlePoint = muzzle
			end

			local seatCandidate = findTaggedDescendant(model, "TurretSeat", "Seat")
			if seatCandidate == nil then
				fail(modelName, "has weaponId but no TurretSeat tagged child")
				continue
			end

			turretSeat = seatCandidate :: Seat
		end

		table.insert(validated, {
			instance = model,
			configId = configId,
			faction = faction,
			weaponMount = weaponMount,
			muzzlePoint = muzzlePoint,
			turretSeat = turretSeat,
		})

		local seatStatus = turretSeat and "seat OK" or "no seat required"
		local mountStatus = weaponMount and "mount OK" or "no mount required"
		print(string.format("[P1_VALIDATE] %s: PASS (%s, %s, %s, %s)", modelName, faction, configId, seatStatus, mountStatus))
	end

	return validated
end

return StartupValidator
