# V3 Pipeline Redesign: Cyclic Development

## The Problem With The Current Structure

The current pipeline is a waterfall: Idea → Full Architecture → Full Build → Open Refinement. Even with core/optimization split and integration passes, the architecture is designed entirely upfront against specs, not against working code. By the time you're building module 10, the spec was written before modules 1-9 existed as real tested code. The gap between specced behavior and actual behavior compounds, and open refinement becomes an unstructured death spiral where changes are ad-hoc and regressions compound.

## The Fix: Cyclic Feature Passes

Same rigor, smaller scope per cycle. Every code change goes through architect → build → prove. No unstructured refinement.

## Pipeline Structure

### Phase 1: Idea Lock (unchanged)
- Capture all features, mechanics, edge cases, UI requirements
- Lock the idea in idea-locked.md
- Output: idea-locked.md (same as current)

### Phase 2: Feature Pass Planning (NEW — happens once)
Claude reads idea-locked.md and divides all features into ordered feature passes:

- **Pass 1 is always "bare bones"** — the minimum system that demonstrates the core loop works end-to-end. No polish, no optimization, no secondary features. Just: does the fundamental thing work?
- **Each subsequent pass adds one layer** — a coherent chunk of related functionality
- **Later passes depend on earlier passes** — the order matters
- **Optimizations are always last** — LOD, pooling, culling, caching are final passes

Output: `feature-passes.md` — a document listing each pass with:
- Pass number and name
- What features/mechanics it includes
- What it depends on (which earlier passes)
- What the system should do after this pass is complete (plain language)

This document is the roadmap. It gets written once and referenced throughout.

### Cycle (repeat for each feature pass):

#### Step 1: Architect This Pass
Claude designs the detailed architecture for THIS PASS ONLY:
- New modules being added
- Modifications to existing modules (if any)
- New data structures, RemoteEvents, config values
- Integration with existing TESTED CODE (not specs — Claude reads the actual built code from previous passes)
- Golden test scenarios for this pass
- Updated startup validators if needed
- Critic review: integration pass traces new data flows against real code

Output: `pass-N-architecture.md` in the project folder

Key difference from current pipeline: the integration pass checks new modules against REAL CODE from previous passes, not against other architecture specs. This is fundamentally more reliable.

#### Step 2: Build This Pass
Codex reads the pass architecture and builds it:
- Same discipline: follow the blueprint exactly, diagnostics logging, one module at a time
- Claude reviews each module against the pass architecture
- Codex has access to existing working code on disk

#### Step 3: Prove This Pass Works
- Run this pass's golden test scenarios
- Run ALL previous passes' golden test scenarios (regression check)
- Diagnostics clean, no anomalies
- Startup validators pass

If something breaks: fix it within this cycle. If a previous pass's golden test regresses, that's a blocking issue — fix before moving to next pass.

#### Step 4: Lock This Pass
- Mark pass as complete in state.md
- The code on disk is now proven foundation for the next pass
- Move to next pass's architecture step

### Ship
When all feature passes are complete and all golden tests pass, the system is done.

## File Structure Per Project

```
projects/<name>/
├── state.md                    # Current pass, status, resume point
├── idea-locked.md              # Phase 1 output (all features)
├── feature-passes.md           # Pass plan (written once, referenced throughout)
├── pass-1-architecture.md      # Bare bones architecture
├── pass-2-architecture.md      # Second feature pass architecture
├── pass-N-architecture.md      # ...
├── golden-tests.md             # Accumulating golden tests from all passes
├── build-notes.md              # Final output
├── src/                        # One codebase, growing with each pass
```

## What This Kills

1. **Open refinement death spiral.** Gone entirely. Every change goes through architect → build → prove. No more "hey Codex, I want X" without a plan.
2. **Speculative architecture.** Each pass's architecture is designed against real, tested code from previous passes, not against other specs.
3. **Premature optimization.** Optimizations are explicitly later passes that can only start after core is proven.
4. **Irreversible breakage.** Each pass is small enough that if something breaks, the blast radius is bounded. And regression tests from previous passes catch it immediately.
5. **Compound regressions.** The "modules 1-7 work, module 8 breaks module 3, fixing module 3 breaks module 1" pattern can't happen because pass boundaries enforce stability checkpoints.

## What Stays The Same

- Architecture-as-contract (Codex builds from a validated blueprint)
- Integration pass (traces cross-module data flows, now against real code)
- Diagnostics module (built in pass 1, available for all testing)
- Startup validators (built in pass 1, enhanced in later passes)
- Golden test scenarios (defined per pass, accumulate as regression tests)
- Config extraction (values added each pass as needed)
- Critic review (each pass gets reviewed)
- State.md resume system
- Codex instructions (build from blueprint, checkpoints, one-change-type discipline)

## What Changes

- No more single massive architecture-outline.md designed upfront
- No more "Phase 3" as a monolithic build-everything phase
- No more open refinement
- Architecture docs are per-pass, not per-project
- Each cycle's architecture is informed by real code, not by specs for unbuilt modules
- Golden tests accumulate and serve as regression tests across passes

## Example: Wandering Props Feature Passes

This is roughly how wandering-props would be divided:

**Pass 1 — Bare Bones (core loop)**
Config, Types, Diagnostics, StartupValidator, NodeGraph, NPCRegistry, simple RouteBuilder (spawn → waypoints → despawn, no POIs), PopulationController (basic spawn/despawn loop), NPCClient (clone model, show in workspace), NPCMover (basic CFrame walk).
Result: NPCs spawn at spawn nodes, walk along waypoints, despawn at despawn nodes, new ones spawn. Population stays stable.

**Pass 2 — POI Visits + Animation**
RouteBuilder enhanced with POI selection and pathing. Scenic POI dwell behavior. NPCAnimator added. Walk/idle animations.
Result: NPCs visit scenic POIs, stop and look around, then continue to despawn. Walk and idle animations play.

**Pass 3 — Social Seating**
SeatManager added. RouteBuilder enhanced with seat claiming. Sit animation. Social POI dwell.
Result: NPCs sit at social POI seats, play sit animation, release seat on leave.

**Pass 4 — Route Variety**
Wander detours, group spawning, day/night population scaling, zone nodes (random positions within boundaries).
Result: NPCs wander off-path sometimes, spawn in groups, population varies with day/night.

**Pass 5 — Optimization**
ModelPool (model reuse), LODController (distance-based quality tiers).
Result: Same behavior, better performance. No visual or behavioral regressions.

Each pass is small, testable, and builds on proven code.

## Open Questions

1. **Config tuning between passes** — should config tweaks still be "free" (no cycle needed) since they don't change code? I think yes — config is explicitly designed for no-AI tuning.

2. **Bugfixes within a pass** — if a bug is found during Step 3 (prove), does it need its own mini-architecture, or is it just a fix? I think: simple bugs get fixed directly (same as current). Architecture-level issues get a mini-architecture update to the current pass doc.

3. **Changing earlier passes** — what if pass 3's requirements force a change to pass 1's code? The pass architecture should note what's changing and why. Critic review covers it. All previous golden tests must still pass after the change.

4. **How much detail in feature-passes.md** — is it just a list of features per pass, or does it include rough module assignments? I think: features + what the system should do after the pass. Module assignments happen in the per-pass architecture step.

5. **Codex instructions** — do they change significantly? Codex still builds from a blueprint and follows the same rules. The main change: it reads a pass-specific architecture doc instead of a full architecture-outline.md. It also reads existing code on disk as the source of truth for already-built functionality.
