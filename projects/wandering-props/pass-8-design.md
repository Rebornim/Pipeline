# Pass 8 Design: External Behavior API (v2 — Redesign)

## Context

Passes 1-7 built the NPC system's internal behavior. Pass 8 adds **external integration ports** so other game systems can control NPC behavior without understanding internals.

### Why this is a redesign

The first Pass 8 attempt failed in playtesting. The root cause was **timeline instability** when modifying in-flight NPCs:
- `rerouteAllToNearestDespawn()` rewrote routes for ALL active NPCs simultaneously — massive churn
- `setWalkSpeedMultiplier()` changed `walkSpeed` on in-flight NPCs and rebroadcast — the client recalculated position from the new timeline, which didn't match visual position, causing jumps/rewinds
- Rapid mode transitions compounded both problems

### Core principle of the redesign

**Never modify in-flight NPCs' routes or speed.** Modes control only population policy — spawn pausing, effective population cap, and drain rate. The existing `trimRouteForNightDrain` (line 708-793) handles incremental drain and already works reliably with seated NPCs, claim releases, and rebroadcasts.

---

## Scope

### In scope (Pass 8 v2)
1. **New server module: `WanderingPropsAPI.luau`** — public API surface for other scripts
2. **Behavior modes:** Normal (0), Pause (10), Evacuate (20), Scatter (30)
3. **Mode effects limited to:** spawn pausing, population cap override, drain rate control
4. **Per-player client desync/resync**
5. **Built-in debounce** on mode re-triggers
6. **Prove gates** — step-by-step build with testable checkpoints

### Explicitly out of scope (removed from v1 to prevent instability)
- Walk speed changes on in-flight NPCs — **never rebroadcast speed to active NPCs**
- Bulk route rewrites (`rerouteAllToNearestDespawn`) — use incremental drain instead
- Custom user-defined modes
- Client-side mode awareness (client just sees normal spawn/despawn/drain effects)

---

## Architecture

### Behavior Mode Controller

**Mode definitions** (hardcoded in the API module):

| Mode | Priority | spawnPaused | populationOverride | drainEnabled | drainBatchSize | drainCheckInterval |
|---|---|---|---|---|---|---|
| `normal` | 0 | false | nil (use Config) | false | — | — |
| `pause` | 10 | true | nil | false | — | — |
| `evacuate` | 20 | true | 0 | true | `Config.EvacDrainBatchSize` (3) | `Config.EvacDrainCheckInterval` (2) |
| `scatter` | 30 | true | 0 | true | `Config.ScatterDrainBatchSize` (8) | `Config.ScatterDrainCheckInterval` (1) |

**How each mode works:**

- **Normal:** Default. Everything runs as Pass 7.
- **Pause:** Spawning stops. Active NPCs finish their routes and despawn naturally. Population drops to zero over time. Good for cutscenes.
- **Evacuate:** Spawning stops. Population cap set to 0. Drain loop activates with normal batch size (3 per cycle, every 2s). NPCs get shortened routes to despawn via the existing `trimRouteForNightDrain` function. Orderly clearing.
- **Scatter:** Same as evacuate but faster. Larger batch size (8 per cycle, every 1s). Area clears roughly 3x faster than evacuate. Good for combat.

**Why scatter doesn't change walk speed:** Changing speed on in-flight NPCs caused the timeline instability in v1. Instead, scatter drains more NPCs per cycle and checks more frequently. The visual effect is "many NPCs turning toward exits simultaneously" rather than "NPCs running faster." This is stable and deterministic.

**Mode state is a simple stack:** only the highest-priority active mode applies. When a mode expires, the system falls back to the next highest active mode, or `normal`.

**Mode activation flow:**
1. `SetMode("scatter", 300)` called by external script
2. API checks debounce: if `scatter` was triggered within `ModeRetriggerCooldown` seconds, ignore
3. API sets `scatter` active with expiry = `now + 300`
4. API evaluates: scatter (30) > current active (e.g., pause at 10) → scatter becomes active mode
5. API writes to PopulationHooks:
   - `spawnPaused = true`
   - `populationOverride = 0`
   - `drainEnabled = true`
   - `drainBatchSize = Config.ScatterDrainBatchSize`
   - `drainCheckInterval = Config.ScatterDrainCheckInterval`
6. PopulationController reads PopulationHooks each frame — spawn loop stops, drain loop activates
7. When scatter expires (or is manually cleared):
   - Fall back to next active mode (pause?) or normal
   - Re-evaluate and write new PopulationHooks values

**Mode transition safety:** Transitions only write PopulationHooks values. No route rewrites, no speed rebroadcasts. The drain loop picks up new values on its next cycle. NPCs mid-drain-route continue at their original speed on their already-shortened route. Deterministic.

### Client Desync Controller

Unchanged from v1 design. Per-player toggle. Independent from behavior modes.

- `DesyncPlayer(player)`: add to `desyncedPlayers` set, fire `NPCDesync` remote with `true`
- `ResyncPlayer(player)`: remove from set, fire `NPCDesync` with `false`, send bulk sync after 1 frame
- While desynced: `flushQueuedRemoteEvents` skips that player. `onPlayerAdded` skips that player.

**Client side:** On `true`, wipe all NPC visuals and ignore all incoming remotes. On `false`, re-enable and wait for bulk sync.

---

## File Changes

### 1. `src/shared/Types.luau` (MINOR)

**Add types:**
```lua
export type BehaviorMode = {
    name: string,
    priority: number,
    spawnPaused: boolean,
    populationOverride: number?,
    drainEnabled: boolean,
    drainBatchSize: number,
    drainCheckInterval: number,
}

export type ActiveMode = {
    name: string,
    expiresAt: number,
    lastTriggeredAt: number,
}
```

### 2. `src/shared/Config.luau` (MINOR)

**Add behavior API section (after existing MARKET POI section):**
```lua
-- BEHAVIOR API
Config.ModeRetriggerCooldown = 2
Config.EvacDrainBatchSize = 3
Config.EvacDrainCheckInterval = 2
Config.ScatterDrainBatchSize = 8
Config.ScatterDrainCheckInterval = 1
```

### 3. `src/shared/Remotes.luau` (MINOR)

**Add new remote name:**
```lua
Remotes.NPCDesync = "NPCDesync"
```

### 4. `src/server/PopulationHooks.luau` (NEW — SMALL)

Shared state module between WanderingPropsAPI and PopulationController. Avoids require-cycle (server scripts can't be required; this ModuleScript can).

```lua
local PopulationHooks = {}

-- Mode effects (written by WanderingPropsAPI, read by PopulationController)
PopulationHooks.spawnPaused = false
PopulationHooks.populationOverride = nil  -- nil = use Config/night logic
PopulationHooks.drainEnabled = false
PopulationHooks.drainBatchSize = 3
PopulationHooks.drainCheckInterval = 2

-- Desync state (written by WanderingPropsAPI, read by PopulationController)
PopulationHooks.desyncedPlayers = {}  -- { [Player]: true }

-- Callback ref (set by PopulationController at startup, called by WanderingPropsAPI)
PopulationHooks.sendBulkSyncToPlayer = nil  -- function(player: Player)

return PopulationHooks
```

**Location:** `src/server/PopulationHooks.luau`

### 5. `src/server/WanderingPropsAPI.luau` (NEW — MAJOR)

Public API module. The **only surface** other scripts interact with.

**Location:** `src/server/WanderingPropsAPI.luau`

**Requires:**
```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local sharedFolder = ReplicatedStorage:WaitForChild("WanderingPropsShared")
local Config = require(sharedFolder:WaitForChild("Config"))
local Remotes = require(sharedFolder:WaitForChild("Remotes"))
local PopulationHooks = require(script.Parent:WaitForChild("PopulationHooks"))
```

**Mode definitions** (internal table):
```lua
local MODE_DEFS = {
    normal   = { priority = 0,  spawnPaused = false, populationOverride = nil,  drainEnabled = false, drainBatchSize = 0, drainCheckInterval = 0 },
    pause    = { priority = 10, spawnPaused = true,  populationOverride = nil,  drainEnabled = false, drainBatchSize = 0, drainCheckInterval = 0 },
    evacuate = { priority = 20, spawnPaused = true,  populationOverride = 0,    drainEnabled = true,  drainBatchSize = Config.EvacDrainBatchSize, drainCheckInterval = Config.EvacDrainCheckInterval },
    scatter  = { priority = 30, spawnPaused = true,  populationOverride = 0,    drainEnabled = true,  drainBatchSize = Config.ScatterDrainBatchSize, drainCheckInterval = Config.ScatterDrainCheckInterval },
}
```

**State:**
```lua
local activeModes: { [string]: ActiveMode } = {}
local currentModeName: string = "normal"
local npcDesyncRemote = nil  -- created on init
```

**Public API functions:**

`WanderingPropsAPI.SetMode(modeName: string, duration: number)`
- Validate `modeName` exists in `MODE_DEFS` and is not `"normal"` (normal can't be set manually)
- Guard: `duration > 0`
- Check debounce: if `activeModes[modeName]` exists and `(now - lastTriggeredAt) < Config.ModeRetriggerCooldown`, return early
- Set/update `activeModes[modeName] = { name = modeName, expiresAt = now + duration, lastTriggeredAt = now }`
- Call `evaluateActiveMode()`
- Schedule expiry: `task.delay(duration, function() expireMode(modeName, now + duration) end)`

`WanderingPropsAPI.ClearMode(modeName: string)`
- Remove `activeModes[modeName]`
- Call `evaluateActiveMode()`

`WanderingPropsAPI.GetActiveMode(): string`
- Returns `currentModeName`

`WanderingPropsAPI.DesyncPlayer(player: Player)`
- `PopulationHooks.desyncedPlayers[player] = true`
- Fire `npcDesyncRemote` to player with `true`

`WanderingPropsAPI.ResyncPlayer(player: Player)`
- `PopulationHooks.desyncedPlayers[player] = nil`
- Fire `npcDesyncRemote` to player with `false`
- After 1-frame delay (`task.defer`), call `PopulationHooks.sendBulkSyncToPlayer(player)` if callback exists

**Internal functions:**

`evaluateActiveMode()`
- Scan `activeModes` for highest-priority mode (skip expired entries where `expiresAt < now`)
- If no active non-expired modes → apply `MODE_DEFS.normal`
- If active mode changed from `currentModeName`:
  - Write new mode's effects to PopulationHooks:
    ```
    PopulationHooks.spawnPaused = modeDef.spawnPaused
    PopulationHooks.populationOverride = modeDef.populationOverride
    PopulationHooks.drainEnabled = modeDef.drainEnabled
    PopulationHooks.drainBatchSize = modeDef.drainBatchSize
    PopulationHooks.drainCheckInterval = modeDef.drainCheckInterval
    ```
  - Update `currentModeName`
  - Diagnostics: `MODE_CHANGE from=<old> to=<new> priority=<n>`

`expireMode(modeName: string, expectedExpiresAt: number)`
- If `activeModes[modeName]` doesn't exist → return (already cleared)
- If `activeModes[modeName].expiresAt ~= expectedExpiresAt` → return (re-triggered, new timer owns it)
- Remove `activeModes[modeName]`
- Call `evaluateActiveMode()`

**Initialization** (at module load):
- Create `NPCDesync` RemoteEvent in the remotes folder
- Connect `Players.PlayerRemoving` to clean up `desyncedPlayers`

### 6. `src/server/PopulationController.server.luau` (MODERATE)

**New require (after existing requires, line ~14):**
```lua
local PopulationHooks = require(script.Parent:WaitForChild("PopulationHooks"))
```

**Modified: `getEffectiveMaxPopulation()` (line 302-323)**
Add mode override check at the top, before night logic:
```lua
local function getEffectiveMaxPopulation(): number
    local modeOverride = PopulationHooks.populationOverride
    if modeOverride ~= nil then
        return math.max(0, math.floor(modeOverride))
    end

    -- existing night logic unchanged below...
```
When a mode sets `populationOverride = 0`, this returns 0 immediately. When mode clears (`populationOverride = nil`), night logic resumes normally.

**New function: `applyDrainBatch(now: number, batchSize: number)` (extract from `applyNightDrain`)**
Extract the core drain logic (lines 806-829) into a shared helper:
```lua
local function applyDrainBatch(now: number, batchSize: number, diagnosticTag: string)
    local effectiveMax = getEffectiveMaxPopulation()
    local excess = activeCount - effectiveMax
    if excess <= 0 then
        return
    end

    local candidates = {}
    for _, record in pairs(activeNPCs) do
        local despawnAt = record.despawnAt or (record.startTime + record.totalDuration)
        local remaining = math.max(0, despawnAt - now)
        table.insert(candidates, {
            record = record,
            remaining = remaining,
        })
    end
    table.sort(candidates, function(a, b)
        return a.remaining > b.remaining
    end)

    local target = math.min(excess, math.max(1, math.floor(batchSize)))
    local drained = 0
    for _, candidate in ipairs(candidates) do
        if drained >= target then
            break
        end
        if trimRouteForNightDrain(candidate.record, now) then
            drained += 1
        end
    end

    if drained > 0 then
        diagnostics(string.format(
            "[WanderingProps] %s trimmed=%d excess=%d active=%d target=%d",
            diagnosticTag,
            drained,
            excess,
            activeCount,
            effectiveMax
        ))
    end
end
```

**Modified: `applyNightDrain()` (line 795-840)**
Simplify to call the shared helper:
```lua
local function applyNightDrain(now: number)
    if not Config.NightDrainEnabled or not isNightNow() then
        return
    end
    applyDrainBatch(now, math.max(1, math.floor(Config.NightDrainBatchSize)), "NIGHT_DRAIN")
end
```

**New function: `applyModeDrain(now: number)`**
```lua
local function applyModeDrain(now: number)
    if not PopulationHooks.drainEnabled then
        return
    end
    applyDrainBatch(now, PopulationHooks.drainBatchSize, "MODE_DRAIN")
end
```

**Modified: `processSpawnDespawnQueues()` (line 1933-2016)**
Add spawn pause guard. In the spawn processing loop (line 1955-2010), add at the top of the while loop:
```lua
if PopulationHooks.spawnPaused then
    break
end
```
This prevents any spawns (fresh or recycled) while a mode has paused spawning.

**Modified: main `while true` loop (line 2195-2207)**
Add spawn pause guard before `requestSpawn(1)`:
```lua
if not PopulationHooks.spawnPaused and pendingTotal < effectiveMax then
    requestSpawn(1)
end
```

Add mode drain check alongside night drain:
```lua
local nextModeDrainAt = 0
-- Inside the while true loop, after the night drain check (line 2198-2201):
if PopulationHooks.drainEnabled and now >= nextModeDrainAt then
    applyModeDrain(now)
    nextModeDrainAt = now + math.max(0.1, PopulationHooks.drainCheckInterval)
end
```

**Modified: `flushQueuedRemoteEvents()` (line 187-217)**
Add desync-aware remote firing. Replace the two `FireAllClients` calls:
```lua
-- Before: npcDespawnedRemote:FireAllClients(despawnPayload)
-- After:
local hasDesynced = next(PopulationHooks.desyncedPlayers) ~= nil
if hasDesynced then
    for _, player in ipairs(Players:GetPlayers()) do
        if not PopulationHooks.desyncedPlayers[player] then
            npcDespawnedRemote:FireClient(player, despawnPayload)
        end
    end
else
    npcDespawnedRemote:FireAllClients(despawnPayload)
end
```
Same pattern for the `npcSpawnedRemote:FireAllClients(spawnPayload)` call (line 212).

When no players are desynced (common case), `next(desyncedPlayers) == nil` and `FireAllClients` is used — zero overhead.

**Modified: `onPlayerAdded()` (line 2018-2026)**
Add desync guard:
```lua
local function onPlayerAdded(player: Player)
    if PopulationHooks.desyncedPlayers[player] then
        return
    end
    -- existing bulk sync logic unchanged...
end
```

**Modified: `startup()` (line 2028)**
Register the bulk sync callback for WanderingPropsAPI resync:
```lua
-- After setupRemotes() (line 2164):
PopulationHooks.sendBulkSyncToPlayer = function(player: Player)
    local bulk = {}
    for _, record in pairs(activeNPCs) do
        table.insert(bulk, makeSpawnData(record))
    end
    npcBulkSyncRemote:FireClient(player, bulk)
    diagnostics(string.format("[WanderingProps] RESYNC_BULK_SEND player=%s npcs_sent=%d", player.Name, #bulk))
end
```

**Modified: `setupRemotes()` (line 170-181)**
Add creation of NPCDesync remote:
```lua
local npcDesyncRemote = createRemoteEvent(remotesFolder, Remotes.NPCDesync)
```
Note: This remote is created by the server but fired by `WanderingPropsAPI`. Since both run on the server, the API module can find the remote via the remotes folder. Alternatively, have WanderingPropsAPI create it directly (simpler — the API module already requires Remotes). **Recommended: WanderingPropsAPI creates it in its own initialization**, keeping remote creation close to the module that uses it.

### 7. `src/client/NPCClient.client.luau` (MINOR)

**New: desync remote handler**

After existing remote handler setup (where `NPCSpawned`, `NPCDespawned`, `NPCBulkSync` handlers are connected):

```lua
local desynced = false

local npcDesyncRemote = remotesFolder:WaitForChild(Remotes.NPCDesync, 10)
if npcDesyncRemote then
    npcDesyncRemote.OnClientEvent:Connect(function(isDesynced: boolean)
        if isDesynced then
            desynced = true
            -- Wipe all active NPCs
            for npcId, npc in pairs(activeNPCs) do
                removeNPC(npcId)
            end
        else
            desynced = false
            -- Bulk sync will arrive shortly and repopulate
        end
    end)
end
```

**Modified: existing remote handlers**

Add early return guard to `NPCSpawned`, `NPCDespawned`, and `NPCBulkSync` handlers:
```lua
if desynced then return end
```
This prevents processing any NPC data while the player is desynced.

**WaitForChild timeout:** Use `WaitForChild(name, 10)` with a 10-second timeout. If `NPCDesync` remote doesn't exist (API module not loaded), the handler simply isn't connected — zero impact. This makes the desync feature fully optional.

---

## Integration Pass

### Cross-boundary data flow traces

| Data | Created in | Passed via | Received by | Stored in | Cleaned up |
|---|---|---|---|---|---|
| Mode state (`activeModes`) | `WanderingPropsAPI.SetMode()` | Internal to API module | `evaluateActiveMode()` | `activeModes` table | `expireMode()`, `ClearMode()` |
| `spawnPaused` | `WanderingPropsAPI` writes to `PopulationHooks` | Shared module field | `PopulationController` spawn loops read it | `PopulationHooks.spawnPaused` | Mode evaluation resets on transition |
| `populationOverride` | `WanderingPropsAPI` writes to `PopulationHooks` | Shared module field | `getEffectiveMaxPopulation()` reads it | `PopulationHooks.populationOverride` | Mode evaluation sets nil on normal |
| `drainEnabled` + batch/interval | `WanderingPropsAPI` writes to `PopulationHooks` | Shared module field | `applyModeDrain()` reads it | `PopulationHooks.drainEnabled/drainBatchSize/drainCheckInterval` | Mode evaluation resets on transition |
| `desyncedPlayers` | `WanderingPropsAPI.DesyncPlayer()` | `PopulationHooks.desyncedPlayers` | `flushQueuedRemoteEvents()`, `onPlayerAdded()` | `PopulationHooks.desyncedPlayers` | `ResyncPlayer()`, `PlayerRemoving` |
| Desync signal | `WanderingPropsAPI` | `NPCDesync` RemoteEvent | `NPCClient` handler | Local `desynced` boolean | `ResyncPlayer()` sends `false` |
| Bulk sync callback | `PopulationController.startup()` | `PopulationHooks.sendBulkSyncToPlayer` | `WanderingPropsAPI.ResyncPlayer()` | Function ref on PopulationHooks | Lifetime of server |

### API signature checks against real code

| Call | Real signature (line) | Match? |
|---|---|---|
| `getEffectiveMaxPopulation()` | `(): number` (line 302) | Yes — adding mode override at top |
| `trimRouteForNightDrain(record, now)` | `(record, now: number): boolean` (line 708) | Yes — reused as-is by drain helper |
| `applyNightDrain(now)` | `(now: number)` (line 795) | Yes — refactored to call `applyDrainBatch` |
| `processSpawnDespawnQueues()` | `()` (line 1933) | Yes — adding spawn pause guard |
| `makeSpawnData(record)` | `(record): table` (line 386) | Yes — used by `sendBulkSyncToPlayer` |
| `onPlayerAdded(player)` | `(player: Player)` (line 2018) | Yes — adding desync guard |
| `flushQueuedRemoteEvents(force)` | `(force: boolean?)` (line 187) | Yes — adding desync-aware firing |
| `removeNPC(npcId)` (client) | `(npcId: string)` | Yes — called in desync wipe |

### Key safety properties

1. **No timeline rewrites.** Modes never call `makeSpawnData` to rebroadcast or change `startTime`/`walkSpeed`/`waypoints` on active NPCs. Only `trimRouteForNightDrain` does this (during drain), and it already works.
2. **Drain reuses proven code.** `applyDrainBatch` extracts the core logic from `applyNightDrain` (lines 806-829). The only change is parameterized `batchSize` and `diagnosticTag`. No new route manipulation logic.
3. **`nightDrainApplied` flag prevents double-drain.** `trimRouteForNightDrain` checks this flag (line 709). An NPC drained by mode drain won't be drained again by night drain or vice versa.
4. **Mode transitions are state writes only.** `evaluateActiveMode` sets 5 fields on `PopulationHooks`. No loops over `activeNPCs`, no rebroadcasts, no route rewrites. The drain loop picks up changes on its next cycle.
5. **Desync is independent.** Desyncing a player doesn't affect modes. Mode changes don't affect desynced players.

---

## AI Build Prints (`[P8_TEST]`)

### Tags and data

| Tag | When | Data |
|---|---|---|
| `[P8_TEST] MODE_SET` | `SetMode()` called | `mode=<name> duration=<s> priority=<n>` |
| `[P8_TEST] MODE_DEBOUNCE` | Re-trigger ignored by debounce | `mode=<name> cooldown_remaining=<s>` |
| `[P8_TEST] MODE_CHANGE` | Active mode changed | `from=<old> to=<new> priority=<n>` |
| `[P8_TEST] MODE_EXPIRE` | Mode timer expired | `mode=<name>` |
| `[P8_TEST] MODE_CLEAR` | `ClearMode()` called | `mode=<name>` |
| `[P8_TEST] MODE_DRAIN` | Mode drain batch executed | `trimmed=<n> excess=<n> active=<n> target=<n>` |
| `[P8_TEST] SPAWN_PAUSED` | Spawn paused state changed | `state=<true\|false>` |
| `[P8_TEST] DESYNC` | Player desynced | `player=<name>` |
| `[P8_TEST] RESYNC` | Player resynced | `player=<name> npcs_sent=<count>` |

### Markers and summary

```
print("[P8_TEST] START READ HERE")
-- At end of 30s test window:
print(string.format("[P8_TEST] [SUMMARY] mode_sets=%d mode_changes=%d mode_expires=%d debounces=%d mode_drains=%d desyncs=%d resyncs=%d",
    modeSets, modeChanges, modeExpires, debounces, modeDrains, desyncs, resyncs))
print("[P8_TEST] END READ HERE")
```

Server-side counters: `modeSets`, `modeChanges`, `modeExpires`, `debounces`, `modeDrains`
Client-side counters: `desyncs`, `resyncs`

---

## Diagnostics & Validators

### New diagnostics (guarded by `Config.DiagnosticsEnabled`)
- `[WanderingProps] MODE_CHANGE from=<old> to=<new> priority=<n>`
- `[WanderingProps] MODE_DRAIN trimmed=<n> excess=<n> active=<n> target=<n>`
- `[WanderingProps] SPAWN_PAUSED state=<true|false>`
- `[WanderingProps] DESYNC player=<name>`
- `[WanderingProps] RESYNC_BULK_SEND player=<name> npcs_sent=<n>`

### Startup validator additions
- None required. API module is optional — if nothing requires it, zero impact.

---

## Known Operational Pitfalls

1. **Drain is incremental, not instant.** When scatter activates, the area doesn't clear instantly. NPCs are drained in batches each cycle. With `ScatterDrainBatchSize=8` and `ScatterDrainCheckInterval=1`, 20 NPCs clear in ~3 cycles (~3 seconds of drain scheduling + remaining walk time). This is intentional — incremental drain is what prevents timeline instability.

2. **`nightDrainApplied` flag prevents double-drain.** An NPC drained by mode drain won't be drained again by night drain. This is correct — the NPC already has a shortened route to despawn. The flag is checked at `trimRouteForNightDrain` line 709.

3. **Night drain and mode drain are independent loops.** Both call `applyDrainBatch` which uses `getEffectiveMaxPopulation()`. If a mode sets `populationOverride=0` AND it's night, both loops compute `excess = activeCount - 0` and both try to drain. The `nightDrainApplied` flag prevents double-draining the same NPC. In practice, mode drain runs first (it checks every 1-2s), night drain finds nothing left.

4. **Mode expiry uses `task.delay`.** If a mode is re-triggered before expiry, the old `task.delay` callback checks `expiresAt` match and no-ops (same pattern as seat claim releases, line 1894-1898).

5. **`FireAllClients` optimization.** When no players are desynced (common case), `next(desyncedPlayers) == nil` → `FireAllClients` as before. Zero overhead. The per-player loop only activates when at least one player is desynced.

6. **Desync wipes all client NPCs instantly.** No fade-out. This is intentional — desync is for performance emergencies. Bulk sync on resync fades in normally if `FadeEnabled` is true.

7. **Optional dependency.** If no script requires `WanderingPropsAPI`, PopulationHooks stays at defaults (`spawnPaused=false`, `populationOverride=nil`, `drainEnabled=false`, `desyncedPlayers={}`). PopulationController reads these defaults and behavior is identical to Pass 7.

---

## Rollback Conditions

If ANY of these are observed during testing, **revert the change that caused it** before proceeding:

1. **NPC jumps/teleports during mode transitions** — indicates timeline rewrite leaked in. The design explicitly avoids this; if it appears, something was implemented incorrectly.
2. **Seated NPC snaps to waypoint during drain** — `trimRouteForNightDrain` skips seated NPCs (line 715-718). If snapping occurs, the skip guard is broken.
3. **Mode expiry doesn't restore normal behavior** — after all modes expire, `spawnPaused` must be `false`, `populationOverride` must be `nil`, `drainEnabled` must be `false`. If spawning doesn't resume, the state reset is broken.
4. **Client desync leaves orphaned NPC visuals** — desync wipe must clean up all NPCs. If visuals remain, `removeNPC` isn't being called for all entries.
5. **Existing golden tests 1-35 fail** — any regression in base behavior means the pass touched something it shouldn't have.

---

## Golden Tests (36-42)

**Test 36: Pause mode — spawning stops, NPCs finish naturally**
- Setup: MaxPopulation = 10, NPCs walking routes. Config: ModeRetriggerCooldown = 2, DiagnosticsEnabled = true.
- Action: Wait for 10 NPCs to be active. External script calls `WanderingPropsAPI.SetMode("pause", 30)`.
- Expected: No new NPCs spawn. Existing NPCs continue walking their routes and despawn normally at route endpoints. Population drops to 0 over time. After 30s, spawning resumes.
- Pass: `[P8_TEST] MODE_CHANGE to=pause`, `[P8_TEST] SPAWN_PAUSED state=true`. No new `[WanderingProps] SPAWN` during pause period. After 30s: `[P8_TEST] MODE_EXPIRE mode=pause`, `[P8_TEST] MODE_CHANGE to=normal`. New spawns resume.

**Test 37: Evacuate mode — drain clears area**
- Setup: MaxPopulation = 10, NPCs walking routes. Config: EvacDrainBatchSize = 3, EvacDrainCheckInterval = 2.
- Action: External script calls `WanderingPropsAPI.SetMode("evacuate", 60)`.
- Expected: No new spawns. Drain loop trims 3 NPCs per cycle every 2s. NPCs get shortened routes to despawn. Active count drops to 0.
- Pass: `[P8_TEST] MODE_CHANGE to=evacuate`, `[P8_TEST] MODE_DRAIN` logs every ~2s with `trimmed=3`. Active count reaches 0. **No NPC jumps or teleports** — NPCs walk shortened routes smoothly.

**Test 38: Scatter mode — fast drain clears area quickly**
- Setup: MaxPopulation = 10, NPCs walking routes. Config: ScatterDrainBatchSize = 8, ScatterDrainCheckInterval = 1.
- Action: External script calls `WanderingPropsAPI.SetMode("scatter", 60)`.
- Expected: Same as evacuate but clears faster. Drain trims 8 per cycle every 1s. Area clears in ~2-3 cycles.
- Pass: `[P8_TEST] MODE_DRAIN` shows `trimmed=8` (or remaining count). Active count reaches 0 noticeably faster than evacuate. **No NPC jumps or teleports.**

**Test 39: Mode priority override**
- Setup: NPCs active.
- Action: Call `SetMode("pause", 60)`, then `SetMode("scatter", 30)`.
- Expected: Scatter overrides pause (priority 30 > 10). Drain activates. After scatter expires (30s), system falls back to pause (still active for 30 more seconds — no drain, just paused spawning). After pause expires, returns to normal.
- Pass: `[P8_TEST] MODE_CHANGE to=pause`, then `[P8_TEST] MODE_CHANGE to=scatter`. After 30s: `[P8_TEST] MODE_CHANGE to=pause`. After 60s total: `[P8_TEST] MODE_CHANGE to=normal`.

**Test 40: Debounce re-trigger**
- Setup: Config: ModeRetriggerCooldown = 2.
- Action: Call `SetMode("scatter", 30)`. Wait 0.5s. Call `SetMode("scatter", 30)` again.
- Expected: Second call is ignored (within 2s debounce window).
- Pass: `[P8_TEST] MODE_DEBOUNCE mode=scatter` logged on second call. Only one `[P8_TEST] MODE_SET` logged total.

**Test 41: Client desync/resync**
- Setup: MaxPopulation = 10, NPCs visible on client.
- Action: Call `WanderingPropsAPI.DesyncPlayer(player)`. Wait 5s. Call `WanderingPropsAPI.ResyncPlayer(player)`.
- Expected: On desync: all NPCs disappear from that client immediately. Server continues normally. On resync: NPCs reappear via bulk sync.
- Pass: `[P8_TEST] DESYNC` logged. Client NPC count drops to 0. `[P8_TEST] RESYNC` logged. Client NPC count matches server active count after bulk sync.

**Test 42: No regression when API unused**
- Setup: No script requires WanderingPropsAPI. MaxPopulation = 10. Run all Pass 1-7 golden test scenarios.
- Expected: Behavior identical to Pass 7. PopulationHooks defaults have zero effect.
- Pass: All existing golden tests pass without change.

**Regression suite:** Tests 1, 2, 4, 5, 9, 11, 15, 16, 17, 25, 27, 30

---

## Build Order with Prove Gates

### Stage 1: Foundation (Types + Config + Remotes)
- `Types.luau`: add `BehaviorMode`, `ActiveMode` types
- `Config.luau`: add 5 behavior API config values
- `Remotes.luau`: add `NPCDesync` remote name

### Stage 2: PopulationHooks shared state module
- New: `PopulationHooks.luau` with 5 mode fields, `desyncedPlayers`, `sendBulkSyncToPlayer` callback ref

### Stage 3: WanderingPropsAPI + PopulationController spawn guard
- New: `WanderingPropsAPI.luau` with `SetMode`, `ClearMode`, `GetActiveMode`, mode definitions, debounce, expiry, `evaluateActiveMode`
- Modify: `PopulationController` — require `PopulationHooks`, add spawn pause guards in `processSpawnDespawnQueues()` and main loop

**Prove Gate 1: Pause mode works.**
- Set `pause` mode → verify no new spawns → verify NPCs finish naturally → verify mode expiry restores spawning.
- This tests: PopulationHooks read path, spawn pause guard, mode lifecycle (set/evaluate/expire).

### Stage 4: Population override + mode drain
- Modify: `PopulationController.getEffectiveMaxPopulation()` — add `populationOverride` check
- New: `applyDrainBatch()` — extracted from `applyNightDrain`
- Modify: `applyNightDrain()` — call `applyDrainBatch`
- New: `applyModeDrain()` — calls `applyDrainBatch` with PopulationHooks values
- Modify: main loop — add mode drain check alongside night drain

**Prove Gate 2: Evacuate mode works.**
- Set `evacuate` → verify drain activates → verify NPCs get shortened routes → verify area clears → verify no NPC jumps.
- Verify `trimRouteForNightDrain` is the only route manipulation function called (no new route rewrite paths).

**Prove Gate 3: Scatter mode works.**
- Set `scatter` → verify faster drain (larger batch) → verify area clears faster → verify no NPC jumps.
- Also test: night drain + mode drain coexistence (both active, no double-drain due to `nightDrainApplied` flag).

### Stage 5: Priority + expiry + debounce
- These are already in WanderingPropsAPI from Stage 3 but need multi-mode testing.

**Prove Gate 4: Priority override + expiry fallback.**
- Set pause → set scatter → verify scatter active → expire scatter → verify fallback to pause → expire pause → verify normal.
- Test debounce: re-trigger same mode within cooldown → verify ignored.

### Stage 6: Client desync/resync
- Modify: `PopulationController.flushQueuedRemoteEvents()` — desync-aware firing
- Modify: `PopulationController.onPlayerAdded()` — desync guard
- Modify: `PopulationController.startup()` — register `sendBulkSyncToPlayer` callback
- Add: `WanderingPropsAPI.DesyncPlayer()`, `ResyncPlayer()` (already in module from Stage 3)
- Modify: `NPCClient.client.luau` — desync remote handler, early return guards

**Prove Gate 5: Desync/resync works.**
- Desync player → verify client wipes NPCs → verify server continues → resync → verify bulk sync restores NPCs.

### Stage 7: Full regression

**Prove Gate 6: No regressions.**
- Run all Pass 1-7 golden test scenarios. Verify no behavioral changes when WanderingPropsAPI is not required by any script.

---

## Files to Modify
1. `src/shared/Types.luau` — minor (2 new types)
2. `src/shared/Config.luau` — minor (5 new config values)
3. `src/shared/Remotes.luau` — minor (1 new remote name)
4. `src/server/PopulationHooks.luau` — new, small (shared state module)
5. `src/server/WanderingPropsAPI.luau` — new, major (public API, mode management, desync)
6. `src/server/PopulationController.server.luau` — moderate (spawn guards, population override, drain extraction, mode drain loop, desync-aware remotes, callback registration)
7. `src/client/NPCClient.client.luau` — minor (desync remote handler, early return guards)

## Files NOT to Modify
- `src/server/POIRegistry.luau` — no changes
- `src/client/NPCMover.luau`, `src/client/NPCAnimator.luau`, `src/client/LODController.luau`, `src/client/ModelPool.luau` — no changes
- `src/client/HeadLookController.luau`, `src/client/PathSmoother.luau` — no changes
- `src/shared/WaypointGraph.luau`, `src/shared/RouteBuilder.luau` — no changes

## Build Guardrails
- If no script ever requires `WanderingPropsAPI`, the system behaves identically to Pass 7 (zero overhead)
- `spawnPaused` and `populationOverride` default to `false` and `nil` — no behavior change unless a mode is activated
- `drainEnabled` defaults to `false` — drain loop exits immediately
- `desyncedPlayers` defaults to empty — `FireAllClients` path unchanged
- No changes to existing remote payloads or names
- All Pass 1-7 behavior and wire contracts preserved
- One new RemoteEvent: `NPCDesync`
- **NEVER modify in-flight NPC `walkSpeed`, `waypoints`, or `startTime`** except via the existing `trimRouteForNightDrain` function during drain

---

## Codex Handoff Prompt

```
Read: codex-instructions.md, projects/wandering-props/state.md, projects/wandering-props/pass-8-design.md. Then read code in projects/wandering-props/src/. Build pass 8.
```
