--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local sharedFolder = ReplicatedStorage:WaitForChild("WanderingProps")
local Diagnostics = require(sharedFolder:WaitForChild("Diagnostics"))

type NPCData = {
    npcId: string,
    modelIndex: number,
    walkSpeed: number,
    route: { any },
    stepDurations: { number },
    cumulativeTimes: { number },
    totalDuration: number,
    spawnTime: number,
    currentStepIndex: number,
    state: "active" | "despawning",
    seatClaims: { [number]: string }?,
}

local NPCRegistry = {}

local npcs: { [string]: NPCData } = {}
local npcCounter = 0

function NPCRegistry.createNPC(data: NPCData): ()
    local existing = npcs[data.npcId]
    if not existing then
        Diagnostics.increment("activeCount")
        Diagnostics.increment("totalSpawned")
    end
    npcs[data.npcId] = data
end

function NPCRegistry.removeNPC(npcId: string): ()
    if npcs[npcId] then
        npcs[npcId] = nil
        Diagnostics.decrement("activeCount")
    end
end

function NPCRegistry.getNPC(npcId: string): NPCData?
    return npcs[npcId]
end

function NPCRegistry.getAllNPCs(): { [string]: NPCData }
    return npcs
end

function NPCRegistry.getActiveCount(): number
    local count = 0
    for _ in pairs(npcs) do
        count += 1
    end
    return count
end

function NPCRegistry.nextId(): string
    npcCounter += 1
    return "wp_" .. tostring(npcCounter)
end

return NPCRegistry
