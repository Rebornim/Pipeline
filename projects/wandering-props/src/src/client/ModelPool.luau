--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local configModule = ReplicatedStorage:WaitForChild("Config", 10)
assert(configModule and configModule:IsA("ModuleScript"), "WanderingProps ModelPool: ReplicatedStorage.Config not found")

local Config = require(configModule)

local ModelPool = {}

local MODEL_FOLDER_NAME = "WanderingPropModels"
local MODEL_INDEX_ATTRIBUTE = "WP_ModelIndex"
local STORAGE_CFRAME = CFrame.new(0, -10000, 0)

local initialized = false
local templatesByIndex: { [number]: Model } = {}
local poolByIndex: { [number]: { Model } } = {}

local function debugLog(message: string): ()
	if Config.DEBUG_ENABLED then
		warn(("[WanderingProps/ModelPool] %s"):format(message))
	end
end

local function destroyCurrentPool(): ()
	for _, bucket in pairs(poolByIndex) do
		for _, model in ipairs(bucket) do
			model:Destroy()
		end
	end
end

local function stopModelAnimations(model: Model): ()
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("Animator") then
			for _, track in ipairs(descendant:GetPlayingAnimationTracks()) do
				track:Stop(0)
			end
		end
	end
end

local function enforceNonCollidableModel(model: Model): ()
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
		end
	end
end

local function resetModelForPool(model: Model): ()
	stopModelAnimations(model)
	enforceNonCollidableModel(model)
	pcall(function()
		model:PivotTo(STORAGE_CFRAME)
	end)
	model.Parent = nil
end

local function getPoolSizePerModel(modelCount: number): number
	local maxPopulation = math.max(0, math.floor(tonumber(Config.MAX_POPULATION) or 0))
	local clampedModelCount = math.max(1, modelCount)
	local buffer = math.max(0, math.floor(tonumber(Config.MODEL_POOL_BUFFER) or 0))

	-- Runtime model count is derived from ReplicatedStorage.WanderingPropModels.
	return math.ceil(maxPopulation / clampedModelCount) + buffer
end

local function getTemplate(modelIndex: number): (Model?, number?)
	local direct = templatesByIndex[modelIndex]
	if direct then
		return direct, modelIndex
	end

	for index = 1, #templatesByIndex do
		local template = templatesByIndex[index]
		if not template then
			continue
		end
		return template, index
	end

	return nil, nil
end

local function collectTemplateModels(modelsFolder: Instance): { Model }
	local templateModels: { Model } = {}
	for _, child in ipairs(modelsFolder:GetChildren()) do
		if child:IsA("Model") then
			table.insert(templateModels, child)
		end
	end

	table.sort(templateModels, function(a, b)
		return a.Name < b.Name
	end)

	return templateModels
end

function ModelPool.init(): ()
	destroyCurrentPool()

	templatesByIndex = {}
	poolByIndex = {}
	initialized = false

	local modelsFolder = ReplicatedStorage:FindFirstChild(MODEL_FOLDER_NAME)
	if not modelsFolder then
		warn(("[WanderingProps/ModelPool] ReplicatedStorage.%s not found"):format(MODEL_FOLDER_NAME))
		return
	end

	local templateModels = collectTemplateModels(modelsFolder)
	if #templateModels == 0 then
		warn(("[WanderingProps/ModelPool] ReplicatedStorage.%s has no Model children"):format(MODEL_FOLDER_NAME))
		return
	end

	local modelCount = #templateModels
	local poolSizePerModel = getPoolSizePerModel(modelCount)

	for modelIndex, templateModel in ipairs(templateModels) do
		templatesByIndex[modelIndex] = templateModel
		poolByIndex[modelIndex] = {}

		for _ = 1, poolSizePerModel do
			local clone = templateModel:Clone()
			clone:SetAttribute(MODEL_INDEX_ATTRIBUTE, modelIndex)
			clone.Name = templateModel.Name
			resetModelForPool(clone)
			table.insert(poolByIndex[modelIndex], clone)
		end
	end

	initialized = true
	local variantCount = 0
	for _ in pairs(templatesByIndex) do
		variantCount += 1
	end
	debugLog(("Initialized pools for %d model variants"):format(variantCount))
end

function ModelPool.acquire(modelIndex: number): Model
	if not initialized then
		ModelPool.init()
	end

	local normalizedIndex = math.floor(modelIndex)
	local bucket = poolByIndex[normalizedIndex]
	if bucket and #bucket > 0 then
		local pooledModel = table.remove(bucket)
		enforceNonCollidableModel(pooledModel)
		pooledModel.Parent = Workspace
		return pooledModel
	end

	local template, sourceIndex = getTemplate(normalizedIndex)
	assert(template, "[WanderingProps/ModelPool] No model templates available for acquire()")

	debugLog(("Pool exhausted for model %d; cloning fallback"):format(normalizedIndex))
	local fallback = template:Clone()
	local appliedIndex = sourceIndex or normalizedIndex
	fallback:SetAttribute(MODEL_INDEX_ATTRIBUTE, appliedIndex)
	fallback.Name = template.Name
	enforceNonCollidableModel(fallback)
	fallback.Parent = Workspace
	return fallback
end

function ModelPool.release(model: Model): ()
	if not initialized then
		ModelPool.init()
	end

	resetModelForPool(model)

	local attributeIndex = model:GetAttribute(MODEL_INDEX_ATTRIBUTE)
	local index = if typeof(attributeIndex) == "number" then math.floor(attributeIndex) else nil
	if not index then
		local nameNumber = tonumber(model.Name)
		if nameNumber then
			index = math.floor(nameNumber)
		end
	end
	if not index then
		index = 1
	end

	local bucket = poolByIndex[index]
	if not bucket then
		bucket = {}
		poolByIndex[index] = bucket
	end

	table.insert(bucket, model)
end

return ModelPool
