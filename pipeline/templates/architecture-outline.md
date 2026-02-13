# Architecture Outline: [System Name]

**Based on:** idea-locked.md
**Critic Status:** [APPROVED / PENDING]
**Date:** [date]

---

## File Organization

| File | Location | Purpose |
|------|----------|---------|
| `ExampleServer.server.luau` | server/ | [what it does] |
| `ExampleClient.client.luau` | client/ | [what it does] |
| `ExampleModule.luau` | shared/ | [what it does] |
| `Config.luau` | shared/ | [configurable values] |

---

## Roblox APIs Used
<!-- List every service/API and what it's used for -->
- **RemoteEvents:** [list each one, what it sends, direction]
- **DataStores:** [if used — key structure, what's stored]
- **Services:** [CollectionService, PathfindingService, TweenService, etc.]

---

## Script Communication Map (Critical for Phase 3)

AI hallucinates most when scripts depend on each other through RemoteEvents, ModuleScripts, and service calls. Every connection must be explicit here so Codex doesn't guess.

<!-- For each script, list what it requires/communicates with -->
<!-- Format: Script → Mechanism → Script (what data, which direction) -->

| From | To | Mechanism | Data Sent | Direction |
|------|----|-----------|-----------|-----------|
| `ExampleClient` | `ExampleServer` | RemoteEvent: `EventName` | `{arg1: type, arg2: type}` | Client → Server |
| `ExampleServer` | `ExampleModule` | `require()` | function calls | Server-side |

### ModuleScript Dependencies
<!-- Which scripts require which modules -->
- `ExampleServer` requires: `Config`, `ExampleModule`
- `ExampleClient` requires: `Config`

---

## Build Order (Critical for Phase 3)

<!-- Sequence mechanics by dependency. Foundation first, dependents after. -->
<!-- This determines the order Codex builds in Phase 3. -->

1. [Foundation: Config + shared modules] — no dependencies
2. [Mechanic A] — depends on: Config
3. [Mechanic B] — depends on: Mechanic A
4. ...

---

## Data Flow
<!-- How information moves: client → server → storage → UI -->
<!-- Describe the flow for each major operation -->

### [Operation Name] (e.g., "Player Fires Weapon")
1. Client: [what happens]
2. RemoteEvent: [what's sent, what arguments]
3. Server: [what's validated, what's processed]
4. Server → Client: [what's sent back]
5. UI: [what updates]

---

## Data Structures
<!-- What tables/objects look like -->

```lua
-- Example: Player data structure
{
    playerId = number,
    -- add fields
}
```

---

## UI Architecture
<!-- ScreenGuis, Frames, how they update, state management -->
- **Screens/Elements:** [list]
- **State Management:** [how UI knows what to display]
- **Backend Communication:** [RemoteEvents? BindableEvents? Direct module calls?]

---

## Security Model
<!-- What's server-authoritative, what validation happens -->
- **Server owns:** [list what server controls]
- **Client can request:** [list what client can ask for]
- **Validation on each RemoteEvent:** [what gets checked]

---

## Performance Strategy
- **Caching:** [what's cached and how]
- **Throttling:** [what's rate-limited]
- **Update frequency:** [what runs on heartbeat vs events]

---

## Config File Structure (Critical for Phase 3)

Every tunable gameplay value must be here. During building, the user adjusts these directly to fix "feels off" issues without burning AI tokens. Be aggressive — if it might need tweaking, extract it.

```lua
-- Config.luau
return {
    -- [CATEGORY]
    -- VALUE_NAME = default, -- What it controls. Reasonable range: X-Y.

    -- Example:
    -- WALK_SPEED = 8, -- NPC walking speed in studs/sec. Range: 4-16.
    -- IDLE_DURATION = {min = 2, max = 5}, -- Seconds NPC idles before moving. Range: 1-10.
    -- DETECTION_RANGE = 30, -- Studs at which NPC reacts to player. Range: 10-60.
}
```

---

## Integration Points
<!-- How this talks to other systems -->
- **[System Name]:** [how they communicate, what's shared]

---

## Critic Review Notes
<!-- Filled in after critic review passes -->
<!-- What was changed based on critic feedback -->
