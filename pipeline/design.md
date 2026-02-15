# Design (per pass)

## What You're Doing

Designing the technical architecture for one feature pass. This design must be detailed enough that Codex can implement it without guessing, and it must integrate cleanly with the existing tested code from previous passes.

## Input

- `projects/<name>/feature-passes.md` — which pass you're designing and what it includes
- `projects/<name>/idea-locked.md` — the full feature spec (for reference)
- `projects/<name>/state.md` — current state, including build deltas from previous passes
- **Previous passes' code on disk** — the existing tested codebase. This is your source of truth for how previous passes actually work.
- Previous pass design docs — for reference only, the code is the authority
- **Build deltas in state.md** — what Codex actually changed vs what was planned in previous passes. Read these carefully — they describe the real state of the code.

## Process

### Step 1: Read Existing Code + Build Deltas

If this is pass 2+, read the actual code from previous passes AND the build deltas in state.md. Understand:
- What modules exist and what their real APIs are
- What data structures are actually used
- How modules actually communicate
- What config values exist
- **What changed from previous designs** — build deltas tell you where reality diverged from the plan

Do NOT rely on previous design docs as the source of truth. The code + build deltas are what's real.

### Step 2: Design This Pass

Cover everything relevant to this pass:

- **New files:** Name, location (server/client/shared), purpose
- **Modified files:** What's changing and why
- **New data structures and types**
- **New or modified APIs:** Exact function signatures
- **New RemoteEvents** (if any)
- **Data flow** for new behaviors
- **New config values** (with comments, defaults, ranges)
- **Script communication:** How new modules connect to existing ones
- **Security boundaries** (if this pass adds client-facing features)
- **Performance considerations** (if relevant to this pass)

Keep it focused. Don't redesign what's already working — just design what's new or changing.

### Step 3: Integration Pass

For every new piece of data or function call that crosses a module boundary:

1. **Where is it created?** Which module, which function, what type?
2. **How is it passed?** Argument, return value, RemoteEvent, shared state?
3. **Who receives it?** Which module, which function — check against REAL CODE signatures
4. **Where is it stored?** What table, what lifetime?
5. **When is it cleaned up?**

For every call site where new code calls existing code (or vice versa):
- Do the argument types match the real function signature?
- Is the return value handled correctly?
- If the function can return nil, is that handled?

**This is the most important step.** Checking new code against real, tested code is fundamentally more reliable than checking specs against specs.

### Step 4: Design Golden Tests for This Pass

Define 1-3 specific test scenarios for the new functionality:
- **Setup:** What workspace layout, what config overrides
- **Action:** What happens
- **Expected:** Specific observable result
- **Pass condition:** What to check (visual + diagnostics)

Also note: which previous passes' golden tests should be re-run as regression checks.

### Step 5: Update Diagnostics & Validators (if needed)

- New lifecycle reason codes for new behaviors
- New health counters if relevant
- New startup validator checks for new workspace contracts
- These get added to existing modules, not new ones

### Step 6: Critic Review

Run the `critic-reviewer` agent with `pipeline/checklists/critic-checklist.md`:
- Feed it the pass design AND the relevant existing code
- Critic verifies data lifecycle traces against real code
- Any blocking issue → fix → re-review
- If stuck after 3 iterations, escalate to user

### Step 7: Lock This Pass's Design + Produce Handoff

- Write to `projects/<name>/pass-N-design.md`
- Add new golden tests to `projects/<name>/golden-tests.md`
- Update `projects/<name>/state.md`: Step → Build, Status → ready

**Produce a Codex handoff prompt.** Write a short, copy-pasteable message the user gives to Codex. It must include:
- Which project, which pass
- Exactly which files to read (state.md, pass-N-design.md, existing code files)
- What to build
- A reminder to read `codex-instructions.md` for pipeline rules

Example:
> "Building pass 2 for wandering-props. Read: `state.md`, `pass-2-design.md`, `codex-instructions.md`. Read existing code in `src/`. Build what pass-2-design.md specifies. Follow pipeline rules in codex-instructions.md."

This handoff prompt is how the user transitions from Claude to Codex without doing orchestration work themselves.

## Exit Criteria

- [ ] All new/modified modules specified with exact APIs
- [ ] Integration pass complete — every cross-boundary data flow traced against real code
- [ ] Golden tests defined for new functionality
- [ ] Regression tests identified from previous passes
- [ ] Diagnostics/validators updated if new behaviors or workspace contracts added
- [ ] Config values extracted for any new tunables
- [ ] Critic signed off (zero blocking issues)
- [ ] Codex handoff prompt produced

## Rules

- **Design against real code, not specs.** If pass 1 is built, read pass 1's code. Don't reference pass-1-design.md as the source of truth.
- **Read build deltas.** They tell you what Codex actually built vs what was planned. Design against reality.
- **Don't redesign what works.** If previous pass code is working, don't refactor it unless this pass requires changes.
- **Stay scoped.** Only design what this pass's features need. Don't anticipate future passes.
- **Be specific.** Codex needs exact function signatures, exact data types, exact integration points.
