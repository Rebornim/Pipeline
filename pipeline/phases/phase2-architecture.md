# Phase 2: Technical Architecture

## What You're Doing
Designing the technical blueprint that Codex CLI (GPT 5.3) will implement. This must be detailed enough that Codex can write code from it without guessing any technical decisions.

## Input
Read `projects/<name>/idea-locked.md` before starting. That's your source of truth for WHAT to build.

## Process

### Step 1: Generate Architecture Plan
Cover ALL of the following:

- **File organization:** Exact script names and locations (server/client/shared). What each file does.
- **Roblox APIs:** Specific services to use (RemoteEvents, DataStores, CollectionService, PathfindingService, TweenService, etc.)
- **Data flow:** How information moves between client, server, storage, and UI. Diagram-style if helpful.
- **Data structures:** What tables/objects look like. What RemoteEvents carry as arguments.
- **UI architecture:** Which ScreenGuis/Frames exist, how they update, how they communicate with backend (RemoteEvents vs BindableEvents), state management approach.
- **Security boundaries:** What's server-authoritative, what client-side validation exists, what inputs get sanitized.
- **Performance strategy:** What gets cached, what's throttled, what runs on heartbeat vs events.
- **Modularity:** Utility modules, separation of concerns.
- **Config file (CRITICAL):** This is load-bearing for Phase 3. The config ModuleScript must contain EVERY tunable gameplay value: speeds, timings, distances, counts, thresholds, toggle flags. During building, the user tunes these values directly (no AI needed) before escalating to code changes. If a value might need tweaking for game feel, it goes in config. Be aggressive — over-extract is better than under-extract. Each value needs a comment explaining what it controls.
- **Script communication map (CRITICAL):** This is where AI hallucinates most in Roblox — cross-script dependencies through RemoteEvents, ModuleScript requires, and service calls. Map every connection explicitly: which script talks to which, through what mechanism, carrying what data. If Codex has to guess how scripts connect to each other, the build will produce plausible-looking code that silently breaks.
- **Build order:** Which mechanics should be built first based on dependencies. Foundation pieces (shared modules, config, core services) before mechanics that depend on them. This determines the Phase 3 build sequence.
- **Integration points:** How this system communicates with other game systems (function calls, events, shared modules).

**Simple systems:** One solid plan.
**Complex systems:** 2-3 options with trade-offs explained, then pick one with user input.

### Step 2: Critic Review
Run the `critic-reviewer` agent with `pipeline/checklists/critic-checklist.md` as the rubric.
- Feed it the architecture plan
- Any **blocking issue** = must fix before proceeding
- Iterate until the critic returns zero blocking issues
- If stuck after 3+ critic iterations, escalate to user — don't burn tokens looping

### Step 3: Lock Architecture
- Write approved architecture to `projects/<name>/architecture-outline.md` (use template from `pipeline/templates/architecture-outline.md`)
- Update `projects/<name>/state.md`: Phase → 3, Status → ready
- Tell user: "Architecture is locked. Hand this to Codex CLI to build."

## Exit Criteria
- [ ] Architecture detailed enough for Codex to implement without guessing
- [ ] Every file named, every API specified, every data structure defined
- [ ] Critic signed off (zero blocking issues)
- [ ] Security model is explicit
- [ ] UI architecture is defined
- [ ] Performance strategy is clear
- [ ] Config file fully specified (every tunable gameplay value extracted, commented, with reasonable defaults)
- [ ] Script communication map complete (every cross-script dependency explicit)
- [ ] Build order defined (mechanics sequenced by dependency for Phase 3)

## Rules
- **Be specific, not vague.** "Use RemoteEvents" is useless. "PlayerShoot RemoteEvent sends {weaponId: string, targetPosition: Vector3} from client, server validates weapon ownership and raycast" is useful.
- **Think about what Codex needs.** If you were handing this to a junior dev, would they know exactly what to build? If not, add more detail.
- **Don't gold-plate.** The architecture should solve the requirements in idea-locked.md, not anticipate features nobody asked for.
