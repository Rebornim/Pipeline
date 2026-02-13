# Roblox Game System Development Pipeline
**AI-Assisted Development Workflow | Claude Opus 4.6 & GPT 5.3**

---

## MISSION

Build Roblox game systems (ship controls, weapons, capture points, quests, AI enemies, wandering props) that don't suck. No spaghetti code, no security holes, no "we have to rebuild this in 3 months." The pipeline front-loads planning so AI executes a validated technical plan instead of guessing its way through implementation.

**Key principle:** If you just tell AI "make a gun system," it has to improvise every technical decision, you iterate 47 times fixing bugs, and it's probably still exploitable. Instead: validate the idea, design the architecture with critic oversight, prototype to catch mistakes early, then build production. This is how real engineering works.

---

## TOOLCHAIN

- **AI Models:** Claude Opus 4.6 (primary architect/builder), GPT 5.3 (specialized tasks if needed)
- **Language:** Roblox Luau
- **Sync:** Rojo (AI writes code to disk, user connects via localhost and tests in Studio)
- **Context Management:** Markdown files on disk for cross-AI communication and phase handoffs
- **Agent Mode:** Claude's agentic features for specialized critic/builder roles
- **User Knowledge Assumption:** Minimal Luau/Roblox expertise. AI must handle all technical decisions.

---

## RATE-LIMIT EFFICIENCY STRATEGY

**Constraint:** Hourly/weekly usage caps on Claude and GPT (not dollar cost).

**How to stay efficient:**
1. **Front-load planning aggressively.** 10k tokens on a good architecture outline saves 100k tokens on rewrites.
2. **Critic agents iterate on outlines, not code.** Catching issues in a 3-page markdown doc is way cheaper than refactoring 800 lines of Luau.
3. **Context files are mandatory.** Never re-explain the system from scratch. Load `idea-locked.md` + `architecture-outline.md` at the start of each phase.
4. **Prototype before production.** A 200-line prototype that reveals "oh, this API doesn't work how we thought" saves you from building a 2000-line system wrong.
5. **Batch related work.** If building UI + backend logic, do architecture for both in one critic session, not separately.
6. **Avoid open-ended exploration.** Every phase has hard exit criteria. No "let's keep tweaking this."

**Simple systems (wandering props, basic capture points):** Might skip multiple architecture options in Phase 2 and go straight to one plan + critic review.

**Complex systems (quest chains, AI enemies with state machines):** Full process with multiple architecture candidates and thorough critic passes.

---

## PHASE 1: IDEA DEVELOPMENT & VALIDATION

**Input:** Raw idea from user
**Output:** `idea-locked.md` context file

### Process

1. **User fills out System Idea Template** (see template below).
2. **AI reviews** and provides feedback:
   - Is this realistic in Roblox? (API limitations, performance constraints)
   - Is anything underspecified? (e.g., "AI enemies" — what's the behavior? Pathfinding? Combat? Idle states?)
   - Are there edge cases or abuse scenarios not covered?
   - How does UI fit in? (HUD elements, menus, notifications — define here, not later)
   - What could derail development? (technical roadblocks, scope creep, integration hell with existing systems)
3. **Iterate on the idea** until it's locked. No architecture talk yet — just clarify WHAT the system does, HOW players interact with it, and WHAT could go wrong.

### Exit Criteria
- [ ] System purpose and player-facing behavior are crystal clear
- [ ] UI requirements are defined (what screens/HUD elements, what info they show, how players interact)
- [ ] Edge cases and abuse scenarios identified
- [ ] No "this won't work in Roblox" blockers
- [ ] User approves: "Yes, this is exactly what I want"

### Deliverable
Save everything to `idea-locked.md`. This is the source of truth. If you're ever confused later, come back to this.

---

## PHASE 2: TECHNICAL ARCHITECTURE OUTLINE

**Input:** `idea-locked.md`
**Output:** `architecture-outline.md` context file

### Process

1. **AI generates technical architecture plan(s):**
   - **Script organization:** Client/server/shared split. What files go where.
   - **Roblox APIs:** Specific services/APIs to use (RemoteEvents, DataStores, CollectionService, TweenService, PathfindingService, etc.)
   - **Data flow:** How information moves between client, server, storage, and UI
   - **UI architecture:** How UI is structured (ScreenGuis, ViewportFrames, etc.), how it communicates with backend logic (RemoteEvents, BindableEvents), how state is managed
   - **Security boundaries:** What runs on server vs client, what validation is needed, how to prevent exploits
   - **Performance strategy:** Caching, rate limiting, avoiding expensive loops, client-server communication optimization
   - **Modularity approach:** Utility modules, config files, how to make this editable without touching core logic
   - **Integration points:** How this system talks to existing systems (shop, spawning, inventory, etc.)

   **For simple systems:** One solid plan.
   **For complex systems:** 2-3 options with trade-offs explained, then pick one.

2. **Critic Agent Review (iterative until clean):**

   **Critic checks against:**
   - **Security rubric** (see below) — no client authority, input validation, exploit resistance
   - **Performance rubric** (see below) — no server lag bombs, efficient client-server communication
   - **Roblox best practices** — using the right APIs, respecting Luau quirks, not reinventing wheels
   - **Maintainability** — is this modular? Can a human read and modify this? Are config values separated?
   - **UI integration** — is UI architecture clear? Does it avoid common pitfalls (client-side state desync, excessive RemoteEvent spam)?

   **Critic output:** Either "approved" or "blocking issues found" with specific fixes needed.

3. **Iterate until critic signs off.** This is where you catch "oh wait, we should use CollectionService instead of hardcoded references" BEFORE writing 500 lines of code.

4. **User reviews final architecture** (optional but recommended for complex systems).

### Exit Criteria
- [ ] Architecture is detailed enough that an AI could implement it without guessing
- [ ] Critic has signed off (zero blocking issues)
- [ ] Security model is explicit: what's server-authoritative, what validation happens where
- [ ] UI architecture is defined: what screens exist, how they update, how they talk to backend
- [ ] Performance strategy is clear: no obvious lag bombs
- [ ] User approves (or auto-proceed if user has enabled that)

### Deliverable
Save to `architecture-outline.md`. This is the blueprint. Code should match this exactly.

---

## PHASE 3: PROTOTYPE DEVELOPMENT

**Input:** `architecture-outline.md`
**Output:** `prototype/` code directory + `prototype-validation.md` context file

### Process

1. **AI writes minimal prototype code to disk:**
   - **Core mechanic only.** No polish, minimal UI (just enough to prove it works).
   - **Rojo-compatible file structure:** `src/server/`, `src/client/`, `src/shared/`, `default.project.json` (AI handles all of this).
   - **Basic security:** Server-side validation on critical operations.
   - **Readable code:** Clear variable names, structure does the heavy lifting. Light comments where helpful.
   - **Config file if applicable:** E.g., weapon stats in a ModuleScript instead of hardcoded.

2. **User syncs via Rojo** (just connect localhost, no manual config) and **tests in Studio.**

3. **User reports back:**
   - Does the core mechanic work?
   - Any performance issues? (lag, stuttering, memory problems)
   - Does the architecture hold up, or are there design flaws?

4. **If major architecture problems found:** Loop back to Phase 2. Update `architecture-outline.md`, re-run critic, then rebuild prototype.

5. **If minor bugs:** Fix in prototype. Document in `prototype-validation.md`.

### Exit Criteria
- [ ] Prototype demonstrates core mechanic working as intended
- [ ] No game-breaking bugs or performance disasters
- [ ] Architecture validated (no need for major rewrites)
- [ ] User approves to move to production

### Deliverable
- Code in `prototype/` directory
- `prototype-validation.md` documenting what worked, what didn't, any changes made

---

## PHASE 4: PRODUCTION BUILD

**Input:** `architecture-outline.md`, `prototype-validation.md`, prototype code
**Output:** `production/` code directory + `production-notes.md` context file

### Process

1. **AI builds full production version:**
   - **Complete feature set** from `idea-locked.md`
   - **Full UI implementation** per architecture plan (polished, user-friendly, handles edge cases)
   - **Security hardening:** Anti-exploit measures, server authority, input validation, rate limiting where needed
   - **Performance optimization:** Efficient loops, caching, minimized client-server traffic, memory management
   - **Error handling:** Graceful failures, no game crashes
   - **Config files where applicable:** Make it easy to tweak values without editing code
   - **Readable structure:** Modular, clear naming, comments where helpful (not excessive)
   - **Rojo-compatible structure** with all files properly organized

2. **Final Critic Review:**
   - Does code match `architecture-outline.md`?
   - Security validated against rubric (see below)
   - Performance validated (no lag bombs, resource leaks)
   - Maintainability check (can a human understand and modify this?)
   - UI validated (responsive, no desync issues, clean integration with backend)

3. **User syncs via Rojo and performs final testing.**

4. **Any issues found:** AI fixes. If issues reveal architecture problems, escalate (don't silently hack around it).

### Exit Criteria
- [ ] All features from `idea-locked.md` implemented
- [ ] UI is complete and functional
- [ ] Security validated (exploit-resistant, server authority enforced)
- [ ] Performance acceptable in realistic game conditions
- [ ] Code is modular, readable, and maintainable
- [ ] User approves for deployment

### Deliverable
- Production code in `production/` directory
- `production-notes.md` with deployment notes, known limitations, future improvement ideas

---

## SYSTEM IDEA TEMPLATE

Use this to structure your idea before handing it to AI. The more detail here, the less back-and-forth later.

```markdown
# System Idea: [System Name]

## Overall Purpose
What does this system do from the player's perspective? Why does it exist in the game?

## Player-Facing Behavior
How do players interact with this system? What actions can they take? What feedback do they get?

## UI Requirements
What screens, HUD elements, or menus does this need?
- Example: Health bar, ammo counter, quest tracker, shop interface, etc.
- What information is displayed?
- How do players interact with UI elements? (click, drag, hover, etc.)
- When does UI appear/disappear?

## Core Mechanics
Break down the system into specific mechanics.
- Example for gun system: Shooting, reloading, damage calculation, hit detection, ammo management
- Example for quest system: Quest acceptance, objective tracking, progress updates, completion rewards

## Instances & Scope
- How many instances of this system run at once? (one global, one per player, one per team, etc.)
- Does this persist across server restarts? (DataStore needed?)
- Is this per-player or shared across players?

## Edge Cases & Abuse Scenarios
What could go wrong? What will players try to exploit?
- Example: Can players spam requests? Duplicate items? Bypass cooldowns? Crash the server?

## Integration with Existing Systems
Does this need to talk to other systems?
- Shop integration (buying/selling related to this system)
- Spawning system (does this affect where/when things spawn?)
- Inventory (does this add/remove items?)
- Economy (does this give/take currency?)
- Other systems: [list]

## Security Concerns
What MUST be server-authoritative? What can't clients be trusted with?
- Example: Money changes, inventory updates, quest completion, damage dealing

## Performance Concerns
What could lag the game if not handled carefully?
- Example: Too many raycasts, pathfinding for 100 AI enemies, UI updates every frame

## Open Questions / Uncertainties
Anything you're not sure about yet? List it here so AI can help clarify.
```

---

## CRITIC AGENT RUBRIC

When reviewing architecture outlines or production code, the critic checks these categories. Any **blocking issue** means "do not proceed until fixed."

### SECURITY

**Blocking issues:**
- Client has authority over money, inventory, game state, or other sensitive data
- RemoteEvent/RemoteFunction arguments not validated server-side
- Server trusts client-provided data for critical operations (damage, rewards, progression)
- No rate limiting on server endpoints that could be spammed

**Non-blocking but flag:**
- Unclear separation of client/server responsibilities
- Validation exists but could be stricter

### PERFORMANCE

**Blocking issues:**
- Unbounded loops or recursive calls (e.g., `while true do` with no wait, recursive pathfinding with no depth limit)
- Expensive operations in tight loops (raycasting every frame for every player)
- Client-server RemoteEvent spam (updates every frame instead of batched/throttled)
- Memory leaks (connections never disconnected, tables never cleared)
- UI updates every frame unnecessarily (should use change events or throttling)

**Non-blocking but flag:**
- Operations that could be cached but aren't
- Inefficient algorithms (e.g., nested loops on large datasets)
- Client doing work that could be done once on server and replicated

### ROBLOX BEST PRACTICES

**Blocking issues:**
- Using deprecated APIs
- Reinventing something Roblox provides (e.g., custom pathfinding instead of PathfindingService)
- Misusing APIs (e.g., using `wait()` instead of `task.wait()`, using `Touched` without debounce)
- Luau-specific errors (e.g., assuming bitwise operators exist in old Luau versions)

**Non-blocking but flag:**
- Not using optimal APIs (e.g., using `FindFirstChild` in a loop instead of CollectionService)
- Type annotations missing (not blocking, but helpful)

### MAINTAINABILITY

**Blocking issues:**
- Core logic and config values mixed together (hardcoded stats that should be in config)
- No clear module boundaries (everything in one giant script)
- Spaghetti code (unclear control flow, deeply nested logic)

**Non-blocking but flag:**
- Inconsistent naming conventions
- Missing comments on complex logic
- Magic numbers (no explanation what the value represents)

### UI INTEGRATION

**Blocking issues:**
- Client-side UI state can desync from server state (e.g., UI shows 100 gold but server has 50)
- UI spams RemoteEvents unnecessarily (every button click fires event instead of batching)
- UI doesn't handle edge cases (what happens if data hasn't loaded yet? What if player closes UI mid-action?)

**Non-blocking but flag:**
- UI could be more responsive (local feedback before server confirmation)
- UI code mixed with backend logic (should be separated)

---

## HUMAN REVIEW GATES: RECOMMENDATIONS

**The choice:** Auto-proceed with critic validation, or manually review at each phase?

### Auto-Proceed (Faster, Higher Risk)
**How it works:** If critic signs off, AI moves to next phase automatically. You only review when something breaks or at final production stage.

**Pros:**
- Much faster iteration
- Lets you batch-test multiple systems
- Critic catches most issues

**Cons:**
- If critic misses something, you don't catch it until later (more expensive to fix)
- You might disagree with an architectural choice that critic approved
- Less control over the process

**Recommended for:** Simple, well-understood systems (basic guns, capture points, wandering props).

### Manual Review (Slower, Lower Risk)
**How it works:** You approve before moving from Phase 1 -> 2 -> 3 -> 4.

**Pros:**
- You catch issues early
- You learn how the system works (easier to modify later)
- Full control

**Cons:**
- Slower
- Requires you to understand architecture outlines (but AI can explain if asked)

**Recommended for:** Complex or mission-critical systems (quest chains, economy, AI enemies with complex behavior).

### Hybrid (Recommended Starting Point)
**How it works:**
- **Always manual review at Phase 1 -> 2:** Make sure you agree with the idea before committing tokens to architecture.
- **Auto-proceed Phase 2 -> 3 if critic approves:** Let AI build prototype automatically.
- **Manual review at Phase 3 -> 4:** Test prototype yourself, approve production build.

**Why this works:**
- You catch bad ideas early (Phase 1)
- Critic handles technical validation (Phase 2)
- You validate the prototype works (Phase 3)
- You don't waste time reviewing architecture docs if you're not technical

**Honest take:** Start with hybrid. If you find the critic is consistently right and you trust it, move to auto-proceed for simple systems. If critic keeps missing things, switch to full manual review and document what it's missing so you can improve the rubric.

---

## CONTEXT FILE STRATEGY

**Purpose:** Cross-AI memory and phase handoffs. Never rely on chat history alone.

### File Naming Convention
- `idea-locked.md` — Phase 1 output
- `architecture-outline.md` — Phase 2 output
- `prototype-validation.md` — Phase 3 learnings
- `production-notes.md` — Phase 4 final notes
- `critic-review-[phase].md` — Critic feedback logs (optional but useful for debugging)

### When to Create/Update
- **End of each phase:** Create new context file summarizing decisions and next steps
- **Critic feedback:** Update working file with what was changed and why
- **Cross-AI handoff:** If switching from Claude to GPT (or vice versa), summarize current state in context file first
- **Phase start:** Always load relevant context files (e.g., Phase 4 loads `idea-locked.md` + `architecture-outline.md` + `prototype-validation.md`)

### What Goes in Context Files
- **Decisions made** (and why, if non-obvious)
- **Changes from original plan** (e.g., "Switched from RemoteEvents to BindableEvents for client-side UI state because...")
- **Open issues or tech debt** (e.g., "Pathfinding works but could be optimized later")
- **Integration notes** (e.g., "This system expects shop to provide `PurchaseItem(player, itemId)` function")

**Critical rule:** If it's not in a context file, it doesn't exist. Don't assume AI remembers something from 50 messages ago.

---

## ROJO INTEGRATION

**User responsibility:** Connect Rojo to localhost and test in Studio. That's it.

**AI responsibility (handled automatically):**
1. Create proper Rojo project structure:
   ```
   ProjectRoot/
   ├── default.project.json  (Rojo config file)
   ├── src/
   │   ├── server/           (ServerScriptService scripts)
   │   ├── client/           (StarterPlayer/StarterPlayerScripts)
   │   ├── shared/           (ReplicatedStorage modules)
   ```
2. Write all scripts to correct directories
3. Ensure `default.project.json` maps everything correctly
4. Handle module dependencies (shared utilities, config files)

**User workflow:**
1. AI writes code to disk
2. User runs `rojo serve` in project directory
3. User connects in Studio via localhost
4. User tests
5. User reports results back to AI

**No manual Rojo config needed.** AI handles it all.

---

## FAILURE HANDLING & ROLLBACK

### Prototype Reveals Architecture Flaw
**What to do:**
1. Document the issue in `prototype-validation.md`
2. Loop back to Phase 2
3. Update `architecture-outline.md` with fix
4. Re-run critic review
5. Rebuild prototype
6. **Do not proceed to production with a known architectural flaw**

### Production Build Deviates from Outline
**What to do:**
1. Critic flags the deviation
2. Either:
   - Fix code to match outline, OR
   - Update outline to reflect better approach (requires user approval + critic re-review)
3. Never ship code that doesn't match the validated architecture unless you've explicitly updated the architecture and re-validated

### Stuck in Iteration Loop
**What to do:**
1. If critic keeps finding issues after 3+ iterations, escalate to user
2. User options:
   - Simplify the system (reduce scope)
   - Accept the issue as tech debt (document in context file)
   - Manually fix the problem
3. **Do not burn tokens on infinite loops.** If you're stuck, stop and ask for help.

### Rate Limit Hit Mid-Phase
**What to do:**
1. Save all work to context files immediately
2. Document exactly where you stopped
3. When rate limit resets, load context files and resume
4. **This is why context files are mandatory.** You can't resume from memory.

---

## PHASE SUMMARY CHECKLIST

Use this to track progress on a system.

```
[ ] Phase 1: Idea Development & Validation
    [ ] System idea template filled out
    [ ] AI feedback reviewed
    [ ] Edge cases identified
    [ ] UI requirements defined
    [ ] idea-locked.md created
    [ ] User approval obtained

[ ] Phase 2: Technical Architecture Outline
    [ ] Architecture plan(s) generated
    [ ] Critic review passed (zero blocking issues)
    [ ] Security model defined
    [ ] Performance strategy defined
    [ ] UI architecture defined
    [ ] architecture-outline.md created
    [ ] User approval obtained (if manual review enabled)

[ ] Phase 3: Prototype Development
    [ ] Prototype code written to disk
    [ ] Rojo structure created
    [ ] User tested in Studio
    [ ] Core mechanic validated
    [ ] prototype-validation.md created
    [ ] User approval to proceed

[ ] Phase 4: Production Build
    [ ] Full feature set implemented
    [ ] UI completed
    [ ] Security hardened
    [ ] Performance optimized
    [ ] Final critic review passed
    [ ] User tested in Studio
    [ ] production-notes.md created
    [ ] System deployed
```

---

## FINAL NOTES

**This pipeline is not bureaucracy for its own sake.** Every step exists because skipping it causes pain later:
- Skip idea validation -> build the wrong thing
- Skip architecture planning -> spaghetti code and rewrites
- Skip critic review -> security holes and lag bombs
- Skip prototyping -> waste tokens building broken systems at scale

**The pipeline is front-loaded on purpose.** 80% of the work happens before writing production code. This feels slow at first but saves massive time over the lifecycle of the system.

**Trust the critic.** If it flags something, there's probably a reason. If you keep disagreeing with critic decisions, update the rubric to reflect your priorities.

**Context files are non-negotiable.** If you skip them, you will hit rate limits mid-project and lose all context. Don't do this to yourself.

**UI is not an afterthought.** Define UI requirements in Phase 1, plan UI architecture in Phase 2, test UI in Phase 3. If you treat UI as "we'll figure it out later," you will regret it.

**You don't need to be technical.** That's the AI's job. Your job is to know what you want the system to do (Phase 1) and test that it works (Phase 3/4). Everything in between is on the AI.

Now go build some systems.
