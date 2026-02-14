# System Idea: [System Name]

## Overall Purpose
<!-- What does this system do from the player's perspective? Why does it exist in the game? -->
To make the game feel more alive and immsersive. From the players perspective the map will feel alive with NPCs that walk around, interact with buildings, almost like the player is intruding on an existing society.

## Player-Facing Behavior
<!-- How do players interact with this? What actions can they take? What feedback do they get? -->
Players shouldnt really be expected to interact with the NPCs, they are there for visual flavor

## UI Requirements
<!-- What screens, HUD elements, or menus does this need? -->
<!-- What information is displayed? How do players interact? When does UI appear/disappear? -->
No UI elements required

## Core Mechanics
<!-- Break the system into specific mechanics. Be concrete. -->
<!-- Example for gun system: Shooting, reloading, damage calc, hit detection, ammo management -->
NPC waypoints, points of interest, random wandering with pathfinding occasionally (as to not run into walls), maybe some kind of hive mind to organize the NPC behavior, but we can work that out in discussion

## Instances & Scope
<!-- How many instances run at once? (one global, per player, per team, etc.) -->
<!-- Does this persist across server restarts? (DataStore needed?) -->
<!-- Is this per-player or shared? -->
many NPCs will be active maybe 15-30 at a time, despawning or spawning in at certain places maybe too. The visuals should probably be consistent for all players too.

## Edge Cases & Abuse Scenarios
<!-- What could go wrong? What will players try to exploit? -->
<!-- Can they spam? Duplicate? Bypass cooldowns? Crash the server? -->
Maybe they try and push NPCs into places they shouldnt, I dont know if we care about that though, they get no benefit from it.

## Integration with Existing Systems
<!-- Does this talk to other systems? Which ones and how? -->
<!-- Shop, spawning, inventory, economy, combat, etc. -->
Probably would be an independent system, we control the spawning in this system etc.

## Security Concerns
<!-- What MUST be server-authoritative? What can't clients be trusted with? -->
not sure for this system

## Performance Concerns
<!-- What could lag the game if not handled carefully? -->
<!-- Too many raycasts? Pathfinding for many AI? UI updates every frame? -->
the path finding 100%, and updating the NPC location etc for each client maybe

## Open Questions
<!-- Anything you're unsure about. List it so the AI can help clarify. -->
how do we make something like this be so well optimized that its hardly noticable, but still looks good, with actual base animations, correct r15 rigs etc.
