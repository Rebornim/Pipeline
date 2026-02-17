# Pass 8 Human Test Kit

Use this to test Pass 8 behavior API manually in Studio Play mode.

## 1) One-time helper setup (Server Command Bar)

In Studio:
1. Start Play (`F5`)
2. Open Command Bar
3. Switch Command Bar context to **Server**
4. Paste this:

```lua
local Players = game:GetService("Players")
local api = require(game.ServerScriptService.WanderingProps.WanderingPropsAPI)

local function findPlayer(name)
	if not name or name == "" then
		return Players:GetPlayers()[1]
	end
	name = string.lower(name)
	for _, p in ipairs(Players:GetPlayers()) do
		if string.find(string.lower(p.Name), name, 1, true) then
			return p
		end
	end
	return nil
end

_G.WP8 = {
	status = function()
		print("ActiveMode =", api.GetActiveMode())
	end,
	pause = function(duration)
		api.SetMode("pause", duration or 10)
	end,
	evac = function(duration)
		api.SetMode("evacuate", duration or 15)
	end,
	scatter = function(duration)
		api.SetMode("scatter", duration or 15)
	end,
	clear = function(modeName)
		if modeName then
			api.ClearMode(modeName)
		else
			api.ClearMode("scatter")
			api.ClearMode("evacuate")
			api.ClearMode("pause")
		end
	end,
	desync = function(playerName)
		local p = findPlayer(playerName)
		if p then
			api.DesyncPlayer(p)
		else
			warn("Player not found")
		end
	end,
	resync = function(playerName)
		local p = findPlayer(playerName)
		if p then
			api.ResyncPlayer(p)
		else
			warn("Player not found")
		end
	end,
}

print("WP8 helper ready. Try: _G.WP8.scatter(10), _G.WP8.desync(), _G.WP8.resync(), _G.WP8.status()")
```

## 2) Quick manual test flow

Run these in Server Command Bar:

```lua
_G.WP8.pause(8)
```
- Expect: new spawns pause, existing NPCs continue their current routes.

```lua
_G.WP8.scatter(10)
```
- Expect: overrides pause, NPCs reroute to nearest despawn and move faster.

```lua
_G.WP8.scatter(10)
```
- Immediately rerun this within 2s.
- Expect: debounce (second call ignored).

Wait for scatter to expire:
- Expect: falls back to pause if pause still active, then later normal.

```lua
_G.WP8.desync()
```
- Expect on your client: all NPCs disappear immediately.

```lua
_G.WP8.resync()
```
- Expect: NPCs reappear via bulk sync.

```lua
_G.WP8.status()
```
- Expect: prints current active mode (`normal`, `pause`, `evacuate`, `scatter`).

## 3) Optional targeted checks

```lua
_G.WP8.evac(12)
```
- Expect: reroute to nearest despawn at normal speed (orderly exit), with spawns paused.

```lua
_G.WP8.clear()
```
- Force clear all modes back to normal.
