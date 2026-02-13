--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local configModule = ReplicatedStorage:WaitForChild("Config", 10)
assert(configModule and configModule:IsA("ModuleScript"), "WanderingProps NPCRegistry: ReplicatedStorage.Config not found")

local typesModule = ReplicatedStorage:WaitForChild("Types", 10)
assert(typesModule and typesModule:IsA("ModuleScript"), "WanderingProps NPCRegistry: ReplicatedStorage.Types not found")

local Config = require(configModule)
local Types = require(typesModule)
type NPCRecord = Types.NPCRecord
type SyncNPCData = Types.SyncNPCData
type RouteStep = Types.RouteStep
type Action = Types.Action

local NPCRegistry = {}

local records: { [string]: NPCRecord } = {}
local count = 0

local function cloneRouteStep(step: RouteStep): RouteStep
	return {
		position = step.position,
		action = step.action,
		duration = step.duration,
		faceCFrame = step.faceCFrame,
		sitCFrame = step.sitCFrame,
	}
end

local function cloneRouteSlice(route: { RouteStep }, startIndex: number): { RouteStep }
	local result: { RouteStep } = {}
	for i = startIndex, #route do
		table.insert(result, cloneRouteStep(route[i]))
	end
	return result
end

local function getStepWindow(record: NPCRecord, stepIndex: number): (number, number)
	local startTime = record.stepTimestamps[stepIndex] or 0
	local endTime = record.stepTimestamps[stepIndex + 1] or record.totalDuration
	if endTime < startTime then
		endTime = startTime
	end
	return startTime, endTime
end

local function getCurrentStepIndex(record: NPCRecord, elapsed: number): number
	local route = record.route
	if #route == 0 then
		return 0
	end

	for i = 1, #route do
		local _, endTime = getStepWindow(record, i)
		if elapsed < endTime then
			return i
		end
	end

	return #route
end

function NPCRegistry.register(record: NPCRecord): ()
	local existing = records[record.id]
	if existing == nil then
		count += 1
	end
	records[record.id] = record
end

function NPCRegistry.unregister(npcId: string): ()
	if records[npcId] ~= nil then
		records[npcId] = nil
		count -= 1
	end
end

function NPCRegistry.getAll(): { [string]: NPCRecord }
	return records
end

function NPCRegistry.getCount(): number
	return count
end

function NPCRegistry.getSyncData(): { [string]: SyncNPCData }
	local now = tick()
	local threshold = math.max(0, tonumber(Config.SYNC_DESPAWN_THRESHOLD) or 0)
	local syncDataById: { [string]: SyncNPCData } = {}

	for npcId, record in pairs(records) do
		local route = record.route
		if #route == 0 then
			continue
		end

		local elapsed = math.max(0, now - record.spawnTime)
		local remainingTime = record.totalDuration - elapsed
		if remainingTime < threshold then
			continue
		end

		local clampedElapsed = math.clamp(elapsed, 0, record.totalDuration)
		local currentStepIndex = getCurrentStepIndex(record, clampedElapsed)
		if currentStepIndex <= 0 then
			continue
		end

		local currentStep = route[currentStepIndex]
		local currentAction: Action = currentStep.action
		local currentPosition = currentStep.position
		local actionTimeRemaining = 0
		local remainingRoute = cloneRouteSlice(route, currentStepIndex + 1)

		if currentAction == "walk" then
			local nextStep = route[currentStepIndex + 1]
			if nextStep then
				local stepStart, stepEnd = getStepWindow(record, currentStepIndex)
				local stepDuration = stepEnd - stepStart
				if stepDuration > 0 then
					local alpha = math.clamp((clampedElapsed - stepStart) / stepDuration, 0, 1)
					currentPosition = currentStep.position:Lerp(nextStep.position, alpha)
				else
					currentPosition = nextStep.position
				end
			end
		elseif currentAction == "idle" or currentAction == "sit" then
			local _, stepEnd = getStepWindow(record, currentStepIndex)
			actionTimeRemaining = math.max(0, stepEnd - clampedElapsed)
		end

		syncDataById[npcId] = {
			modelIndex = record.modelIndex,
			speed = record.speed,
			currentPosition = currentPosition,
			currentAction = currentAction,
			actionTimeRemaining = actionTimeRemaining,
			remainingRoute = remainingRoute,
			groupId = record.groupId,
		}
	end

	return syncDataById
end

return NPCRegistry
