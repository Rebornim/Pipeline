--!strict

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local sharedRoot = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatConfig = require(sharedRoot:WaitForChild("CombatConfig"))
local CombatEnums = require(sharedRoot:WaitForChild("CombatEnums"))
local CombatTypes = require(sharedRoot:WaitForChild("CombatTypes"))
local WeaponRig = require(sharedRoot:WaitForChild("WeaponRig"))

type ValidatedEntity = CombatTypes.ValidatedEntity

local StartupValidator = {}

local validFactionSet = {
	[CombatEnums.Faction.Empire] = true,
	[CombatEnums.Faction.Rebel] = true,
	[CombatEnums.Faction.Neutral] = true,
}

local function normalizeFaction(rawFaction: string): string
	return string.lower(string.gsub(rawFaction, "^%s*(.-)%s*$", "%1"))
end

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

local function collectTaggedDescendants(model: Model, tagName: string, className: string?): { Instance }
	local tagged: { Instance } = {}
	for _, descendant in ipairs(model:GetDescendants()) do
		if CollectionService:HasTag(descendant, tagName) then
			if className == nil or descendant:IsA(className) then
				table.insert(tagged, descendant)
			end
		end
	end

	table.sort(tagged, function(a: Instance, b: Instance)
		return a:GetFullName() < b:GetFullName()
	end)

	return tagged
end

local function isMuzzleAttachment(candidate: Instance): boolean
	if not candidate:IsA("Attachment") then
		return false
	end

	if CollectionService:HasTag(candidate, "MuzzlePoint") then
		return true
	end

	return candidate.Name == "MuzzlePoint" or string.sub(candidate.Name, 1, 11) == "MuzzlePoint"
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

		local normalizedFaction = normalizeFaction(faction)
		if not validFactionSet[normalizedFaction] then
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
		local mountCount = 0

		if entityConfig.weaponId ~= nil then
			if CombatConfig.Weapons[entityConfig.weaponId] == nil then
				fail(modelName, string.format("weaponId '%s' not found in CombatConfig.Weapons", entityConfig.weaponId))
				continue
			end

			local mountCandidates = collectTaggedDescendants(model, "WeaponMount", "BasePart")
			mountCount = #mountCandidates
			if mountCount == 0 then
				fail(modelName, "has weaponId but no WeaponMount tagged child")
				continue
			end

			weaponMount = mountCandidates[1] :: BasePart
			local resolvedAimAxis, _aimAxisLabel = WeaponRig.resolveAimAxis(weaponMount)
			if resolvedAimAxis == nil then
				fail(
					modelName,
					string.format(
						"mount '%s' has no resolved facing; set AimAxis (+X/-X/+Y/-Y/+Z/-Z) or orient MuzzlePoint.Axis forward",
						weaponMount:GetFullName()
					)
				)
				continue
			end

			for _, mount in ipairs(mountCandidates) do
				for _, descendant in ipairs((mount :: Instance):GetDescendants()) do
					if isMuzzleAttachment(descendant) then
						if muzzlePoint == nil then
							muzzlePoint = descendant :: Attachment
						end
					end
				end
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
			faction = normalizedFaction,
			weaponMount = weaponMount,
			muzzlePoint = muzzlePoint,
			turretSeat = turretSeat,
		})
	end

	return validated
end

return StartupValidator
