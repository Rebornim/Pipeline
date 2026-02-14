# Design (per pass)

## What You're Doing

Designing the technical architecture for one feature pass. This design must be detailed enough that Codex can implement it without guessing, and it must integrate cleanly with the existing tested code from previous passes.

## Input

- `projects/<name>/feature-passes.md` — which pass you're designing and what it includes
- `projects/<name>/idea-locked.md` — the full feature spec (for reference)
- **Previous passes' code on disk** — the existing tested codebase. This is your source of truth for how previous passes actually work, not their design docs.
- Previous pass design docs — for reference only, the code is the authority

## Process

### Step 1: Read Existing Code

If this is pass 2+, read the actual code from previous passes. Understand:
- What modules exist and what their real APIs are
- What data structures are actually used
- How modules actually communicate
- What config values exist

Do NOT rely on previous design docs as the source of truth. The code is what Codex will build against.

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

### Step 7: Lock This Pass's Design

- Write to `projects/<name>/pass-N-design.md`
- Add new golden tests to `projects/<name>/golden-tests.md`
- Update `projects/<name>/state.md`: Step → Build, Status → ready
- Tell user: "Pass N design is locked. Hand this to Codex."

## Exit Criteria

- [ ] All new/modified modules specified with exact APIs
- [ ] Integration pass complete — every cross-boundary data flow traced against real code
- [ ] Golden tests defined for new functionality
- [ ] Regression tests identified from previous passes
- [ ] Diagnostics/validators updated if new behaviors or workspace contracts added
- [ ] Config values extracted for any new tunables
- [ ] Critic signed off (zero blocking issues)

## Rules

- **Design against real code, not specs.** If pass 1 is built, read pass 1's code. Don't reference pass-1-design.md as the source of truth.
- **Don't redesign what works.** If previous pass code is working, don't refactor it unless this pass requires changes.
- **Stay scoped.** Only design what this pass's features need. Don't anticipate future passes.
- **Be specific.** Codex needs exact function signatures, exact data types, exact integration points.
