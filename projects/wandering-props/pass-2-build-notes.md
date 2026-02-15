# Pass 2 Build Notes: Wandering Props

**Date:** 2026-02-15
**Pass:** 2 (Points of Interest)
**Build/Test Status:** user-validated in Studio

---

## System Summary
Pass 2 is implemented and validated: NPCs route through Scenic, Busy, and Social POIs with server-side seat claiming/release, POI-aware late-join state, and stuck-route fallback behavior.

## Build Outcome vs Design
Core Pass 2 goals are complete. The following implementation deltas were introduced during live debugging to resolve real setup/runtime issues.

### Delta 1: POI Waypoint Linking Contract (expanded)
Original design assumed POI folder links to graph via a `Waypoint` ObjectValue.

Implemented contract now supports and prefers a concrete POI waypoint part:
- `POIs/<POI>/Waypoint` as a `BasePart` can be used as the actual POI stop node.
- Graph building auto-registers POI waypoint parts as nodes.
- Connection edges support both directions:
  1. POI waypoint part ObjectValue -> main waypoint part
  2. Main waypoint part ObjectValue -> POI waypoint part
- ObjectValue targets support `BasePart`, `Attachment` (parent part), and nested `ObjectValue` indirection.

Why: fixed repeated real-world authoring failures where POI links were rejected or bound to the wrong node.

### Delta 2: Social Movement Behavior (user-requested)
Original Pass 2 design had seat teleport for social POIs.

Implemented behavior now:
- NPC walks from social POI waypoint to seat (`walking_to_seat`)
- NPC sits for dwell duration (`sitting`)
- NPC walks back to POI waypoint (`walking_from_seat`)
- NPC resumes route

Why: required by user; better visual continuity.

### Delta 3: Capacity Percent Interpretation
`CapacityPercent` is interpreted as a fraction `[0.0..1.0]`.
- Example: `0.8` = 80%
- `80` is not valid for 80%

---

## Files Changed in Pass 2 Build

| File | Change |
|------|--------|
| `src/server/POIRegistry.luau` | New module; POI discovery, weighting, seat claim/release, POI waypoint resolution |
| `src/server/PopulationController.server.luau` | POI-aware route planning, seat lifecycle, stuck fallback, POI diagnostics/payloads |
| `src/shared/Types.luau` | POI and seat types, graph `partToId`, expanded NPC state fields |
| `src/shared/Config.luau` | POI config values |
| `src/shared/WaypointGraph.luau` | `partToId` export + POI waypoint node/link integration |
| `src/shared/RouteBuilder.luau` | `computeMultiSegmentRoute()` |
| `src/client/NPCMover.luau` | `update(..., stopAtWaypoint?)` |
| `src/client/NPCAnimator.luau` | sit animation setup/play/stop |
| `src/client/NPCClient.client.luau` | POI state machine, late-join route state, social walk-to-seat/walk-back |

---

## Verified Behaviors (Studio)
- Scenic POI: stop and face ViewZone, then resume.
- Busy POI: walk-through with no dwell.
- Social POI: capacity behavior works, sit dwell works, and NPCs now walk to/from seats.
- POI linking issue resolved for POI waypoint connections after graph/registry adjustments.
- Pass 2 golden test intent covered in user validation.

## Known Constraints
- POI setup is sensitive to ambiguous multiple links; keep one intended waypoint link per POI path.
- `CapacityPercent` must be fractional (`0.8`, not `80`).

## Recommended Input for Pass 3 Planning
When drafting Pass 3 (`Waypoint zones` + organic movement), use this file plus:
- `feature-passes.md`
- `pass-2-design.md`
- `state.md`
- current `src/` code as source of truth

