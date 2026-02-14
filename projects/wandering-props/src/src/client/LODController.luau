--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local sharedFolder = ReplicatedStorage:WaitForChild("WanderingProps")
local Config = require(sharedFolder:WaitForChild("Config"))
local NPCMover = require(script.Parent:WaitForChild("NPCMover"))

type LODRecord = {
    model: Model,
    position: Vector3,
    tier: "near" | "low" | "mid" | "far",
}

local LODController = {}

local records: { [string]: LODRecord } = {}
local running = false
local accumulator = 0

local function computeTier(position: Vector3): "near" | "low" | "mid" | "far"
    local camera = Workspace.CurrentCamera
    if not camera then
        return "near"
    end

    local distance = (position - camera.CFrame.Position).Magnitude
    if distance < (tonumber(Config.LOD_NEAR_DISTANCE) or 50) then
        return "near"
    end
    if distance < (tonumber(Config.LOD_LOW_DISTANCE) or 100) then
        return "low"
    end
    local midDistance = math.max(1, tonumber(Config.LOD_MID_DISTANCE) or 200)
    if distance < midDistance then
        return "mid"
    end

    if Config.LOD_ENABLE_FAR_CULL == true then
        local farCullDistance = math.max(midDistance, tonumber(Config.LOD_FAR_CULL_DISTANCE) or 1500)
        if distance >= farCullDistance then
            return "far"
        end
    end

    return "mid"
end

local function tickLOD(): ()
    for npcId, record in pairs(records) do
        local nextTier = computeTier(record.position)
        if nextTier ~= record.tier then
            record.tier = nextTier
            NPCMover.setLODTier(npcId, nextTier)
        end
    end
end

function LODController.init(): ()
    if running then
        return
    end

    running = true
    RunService.Heartbeat:Connect(function(dt)
        accumulator += dt
        local interval = math.max(0.1, tonumber(Config.LOD_CHECK_INTERVAL) or 1.5)
        if accumulator >= interval then
            accumulator = 0
            tickLOD()
        end
    end)
end

function LODController.register(npcId: string, model: Model): ()
    local position = model:GetPivot().Position
    records[npcId] = {
        model = model,
        position = position,
        tier = "near",
    }

    NPCMover.setLODTier(npcId, "near")
end

function LODController.unregister(npcId: string): ()
    records[npcId] = nil
end

function LODController.updatePosition(npcId: string, position: Vector3): ()
    local record = records[npcId]
    if not record then
        return
    end

    record.position = position
end

return LODController
