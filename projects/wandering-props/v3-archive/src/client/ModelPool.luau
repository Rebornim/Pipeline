--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local sharedFolder = ReplicatedStorage:WaitForChild("WanderingProps")
local Config = require(sharedFolder:WaitForChild("Config"))

local ModelPool = {}

local templates: { Model } = {}
local buckets: { [number]: { Model } } = {}
local inUse: { [Model]: boolean } = {}
local inBucket: { [Model]: boolean } = {}
local initialized = false

local function stopAnimations(model: Model): ()
    for _, descendant in ipairs(model:GetDescendants()) do
        if descendant:IsA("Animator") then
            for _, track in ipairs(descendant:GetPlayingAnimationTracks()) do
                track:Stop(0)
            end
        end
    end
end

local function resetModel(model: Model): ()
    stopAnimations(model)

    for _, descendant in ipairs(model:GetDescendants()) do
        if descendant:IsA("BasePart") then
            descendant.Anchored = true
            descendant.CanCollide = false
            descendant.CanTouch = false
            descendant.CanQuery = false
            descendant.LocalTransparencyModifier = 0
            descendant.AssemblyLinearVelocity = Vector3.zero
            descendant.AssemblyAngularVelocity = Vector3.zero
        end
    end

    model.Parent = nil
end

local function cloneTemplate(index: number): Model
    local template = templates[index] or templates[1]
    assert(template, "[WP/ModelPool] No model templates available")

    local clone = template:Clone()
    clone:SetAttribute("WP_ModelIndex", index)
    resetModel(clone)
    return clone
end

function ModelPool.init(models: { Model }, poolSize: number?): ()
    templates = {}
    buckets = {}
    inUse = {}
    inBucket = {}

    for i, model in ipairs(models) do
        templates[i] = model
        buckets[i] = {}
    end

    if #templates == 0 then
        initialized = false
        return
    end

    local requestedPoolSize = poolSize
    if requestedPoolSize == nil then
        local maxPop = math.max(1, math.floor(tonumber(Config.MAX_POPULATION) or 1))
        requestedPoolSize = math.ceil(maxPop / #templates) + math.max(0, math.floor(tonumber(Config.MODEL_POOL_BUFFER) or 2))
    end

    local sizePerModel = math.max(1, math.floor(requestedPoolSize))
    for index = 1, #templates do
        local bucket = buckets[index]
        for _ = 1, sizePerModel do
            local clone = cloneTemplate(index)
            table.insert(bucket, clone)
            inBucket[clone] = true
        end
    end

    initialized = true
end

function ModelPool.acquire(modelIndex: number): Model
    if not initialized then
        ModelPool.init(templates)
    end

    local index = math.max(1, math.floor(modelIndex))
    local bucket = buckets[index]
    if bucket then
        while #bucket > 0 do
            local model = table.remove(bucket)
            inBucket[model] = nil
            if inUse[model] then
                warn("[WP/ModelPool] Duplicate pooled model reference detected; discarding stale entry.")
            else
                inUse[model] = true
                return model
            end
        end
    end

    local created = cloneTemplate(index)
    inUse[created] = true
    return created
end

function ModelPool.release(model: Model): ()
    if not initialized then
        model:Destroy()
        return
    end

    if inBucket[model] then
        warn("[WP/ModelPool] Double release ignored (model already in pool).")
        return
    end

    if not inUse[model] then
        warn("[WP/ModelPool] Release received for model not tracked as in use; destroying to avoid aliasing.")
        model:Destroy()
        return
    end

    inUse[model] = nil

    local attr = model:GetAttribute("WP_ModelIndex")
    local index = if typeof(attr) == "number" then math.max(1, math.floor(attr)) else 1

    if not buckets[index] then
        buckets[index] = {}
    end

    resetModel(model)
    table.insert(buckets[index], model)
    inBucket[model] = true
end

return ModelPool
