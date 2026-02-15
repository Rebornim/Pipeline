--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local sharedFolder = ReplicatedStorage:WaitForChild("WanderingProps")
local Config = require(sharedFolder:WaitForChild("Config"))

local Diagnostics = {}

local trailsByNpc: { [string]: { string } } = {}
local healthCounters: { [string]: number } = {
    activeCount = 0,
    totalSpawned = 0,
    totalDespawned = 0,
    seatOccupied = 0,
    seatTotal = 0,
}
local reasonCounters: { [string]: { [string]: number } } = {
    totalDespawned = {},
    totalRejects = {},
}

local function debugEnabled(): boolean
    return Config.DEBUG_MODE == true
end

local function pushTrail(npcId: string, text: string): ()
    local trail = trailsByNpc[npcId]
    if not trail then
        trail = {}
        trailsByNpc[npcId] = trail
    end

    table.insert(trail, text)
    local maxLen = math.max(1, tonumber(Config.DIAG_TRAIL_LENGTH) or 8)
    while #trail > maxLen do
        table.remove(trail, 1)
    end
end

local function printPrefix(): string
    return "[WP]"
end

function Diagnostics.log(npcId: string, action: string, detail: string): ()
    if not debugEnabled() then
        return
    end

    print(('%s npc %s | %s:%s'):format(printPrefix(), npcId, action, detail))
end

function Diagnostics.trail(npcId: string, entry: string): ()
    pushTrail(npcId, entry)

    if not debugEnabled() then
        return
    end

    local trail = trailsByNpc[npcId] or {}
    print(('%s npc %s | %s'):format(printPrefix(), npcId, table.concat(trail, " -> ")))
end

function Diagnostics.getTrail(npcId: string): { string }
    local src = trailsByNpc[npcId] or {}
    local copy = table.create(#src)
    for i, entry in ipairs(src) do
        copy[i] = entry
    end
    return copy
end

function Diagnostics.clearTrail(npcId: string): ()
    trailsByNpc[npcId] = nil
end

function Diagnostics.increment(counter: string, reason: string?): ()
    healthCounters[counter] = (healthCounters[counter] or 0) + 1

    if reason then
        local byReason = reasonCounters[counter]
        if not byReason then
            byReason = {}
            reasonCounters[counter] = byReason
        end
        byReason[reason] = (byReason[reason] or 0) + 1
    end
end

function Diagnostics.decrement(counter: string, reason: string?): ()
    healthCounters[counter] = (healthCounters[counter] or 0) - 1

    if reason then
        local byReason = reasonCounters[counter]
        if byReason then
            byReason[reason] = math.max(0, (byReason[reason] or 0) - 1)
        end
    end
end

function Diagnostics.printHealth(): ()
    if not debugEnabled() then
        return
    end

    local active = healthCounters.activeCount or 0
    local spawned = healthCounters.totalSpawned or 0
    local despawned = healthCounters.totalDespawned or 0
    local rejects = healthCounters.totalRejects or 0

    local despawnByReason = reasonCounters.totalDespawned or {}
    local routeDone = despawnByReason.route_complete or 0
    local stuck = despawnByReason.stuck_despawn or 0

    print(
        ('%s Health | active: %d | spawned: %d | despawned: %d (route:%d stuck:%d) | rejects: %d'):format(
            printPrefix(),
            active,
            spawned,
            despawned,
            routeDone,
            stuck,
            rejects
        )
    )

    local occupied = healthCounters.seatOccupied or 0
    local total = healthCounters.seatTotal or 0
    local pct = if total > 0 then math.floor((occupied / total) * 100 + 0.5) else 0
    print(('%s Seats | %d/%d occupied (%d%%)'):format(printPrefix(), occupied, total, pct))
end

function Diagnostics.printTrail(npcId: string): ()
    if not debugEnabled() then
        return
    end

    local trail = trailsByNpc[npcId] or {}
    print(('%s npc %s trail | %s'):format(printPrefix(), npcId, table.concat(trail, " -> ")))
end

return Diagnostics
