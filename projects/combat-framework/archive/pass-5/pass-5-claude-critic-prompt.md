Use the attached handoff dossier and run a critic-style review of the Pass 5 speeder movement stack.

Primary file to read first:
- `projects/combat-framework/pass-5-claude-handoff.md`

Then review these code files:
- `projects/combat-framework/src/Server/Vehicles/HoverPhysics.luau`
- `projects/combat-framework/src/Server/Vehicles/VehicleServer.luau`
- `projects/combat-framework/src/Server/Vehicles/CollisionHandler.luau`

What I need from you:
1. A precise root-cause analysis for:
- crest lock at steep downhill lip
- uphill sink then phase-through
- cliff landing phase-through
- stop-on-uphill void fall

2. A critic report that focuses on invariants:
- where non-penetration invariants fail
- where deterministic ownership of velocity/position fails
- where hover/contact math is internally inconsistent

3. A technical outline to hand back to implementation:
- exact algorithmic changes, not just tuning
- ordered implementation steps
- acceptance tests per step
- explicit "done" criteria

4. Keep fixes realistic for current architecture:
- CFrame-driven server-authoritative movement
- no full system rewrite unless absolutely required

Constraint:
- User requested no MCP playtest runs unless explicitly asked.
