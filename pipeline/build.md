# Build (per pass)

**Primary AI: Codex CLI (GPT 5.3) for implementation, Claude for reviews**

## What You're Doing

Building one feature pass from its design doc. The code integrates with existing tested code from previous passes.

## Your Leverage

- **Pass design doc** (`pass-N-design.md`) — the blueprint for exactly what to build
- **Existing code on disk** — proven foundation from previous passes
- **Config file** — tunable values, try these before code changes
- **Diagnostics module** — read the output before guessing at problems
- **Golden tests** (`golden-tests.md`) — exact pass/fail criteria

## Build Process

### Step 1: Determine Build Order

Read the pass design doc. If this pass adds multiple modules or modifies multiple files, determine the order:
- Foundation pieces first (shared modules, config additions)
- Dependencies before dependents
- Independent modules can be built in the same step

### Step 2: Build Loop (repeat for each build step)

#### 2a. Tell Codex to build this step.
Give Codex:
- The pass design doc (`pass-N-design.md`)
- Which module(s) to build or modify
- What files already exist (tell Codex to read them from disk)
- Boundaries: what it can change, what it must not touch

#### 2b. Sync via Rojo and test.
- Check output window: startup validator errors? Diagnostics running?
- Run this pass's golden tests
- **Run previous passes' golden tests** (regression check)
- Check diagnostics output for anomalies

#### 2c. If it fails:
1. **Check diagnostics.** What do reason codes and trails say?
2. **Check config.** Is it a tunable value problem? Free fix, no tokens.
3. **If not config:** Send Codex ONE categorized issue with diagnostics output. Tell it to re-read files from disk first.
4. **Do not move on until the bug is fixed.** This is non-negotiable.
5. **If Codex's fix doesn't work after 2 attempts:** Escalate to Claude. Tell Claude the bug, the diagnostics, and what Codex tried. Claude writes a targeted fix plan. Give that plan to Codex to implement.
6. **If stuck after 3 total attempts (Codex + Claude-planned fix):** This may be a design issue — revisit the pass design.

#### 2d. PASS → move to next step.

### Step 3: All Steps Built

When all modules for this pass are built and individual tests pass:
- Run ALL golden tests (this pass + all previous passes)
- Check diagnostics health summary
- If everything passes → move to Prove

## Bug Fix Discipline

- **Do not move on until the bug is fixed.** A broken module is a broken foundation for everything after it.
- **Minimize blast radius.** Fix the bug without restructuring surrounding code. The smallest change that fixes the problem is the best change.
- **One fix at a time.** Fix one bug, test, confirm. Then fix the next.
- **Never mix bugfixes with feature additions or refactors.** If you see something you want to improve while fixing a bug, note it for later.

## Bug Escalation to Claude

When Codex can't fix a bug after 2 attempts, escalate to Claude:

1. Tell Claude: **"Bug in pass N for [project-name]. Codex tried [X] and [Y], neither worked."**
2. Include: diagnostics output, what the code does now, what it should do, what Codex tried
3. Claude reads the relevant code, diagnoses the issue, and writes a targeted fix plan
4. Give the fix plan to Codex to implement
5. Codex follows the fix plan exactly — no improvising on top of it

This ensures Codex always works from a plan, even for bugfixes.

## Change Discipline

Each Codex interaction is ONE of:
- **Bugfix** — something doesn't work
- **Tuning** — values need adjusting
- **Design change** — behavior needs to work differently (escalate to Claude for a design update first)

Never mix these. One change, one test, one confirmation.

## Instrument-First Debugging

When a bug appears:
1. Read diagnostics output first
2. If diagnostics don't cover this case, tell Codex to add logging first
3. Only then patch the code

No speculative fixes without evidence.

## Periodic Structural Review

Every 3-5 passes (not every pass), invoke a full critic review on the entire codebase:
- Claude runs the critic-reviewer agent against ALL scripts
- Checks for drift, accumulated tech debt, contract looseness, patterns going stale
- Feedback goes to Codex to address before the next pass
- This catches issues that per-pass reviews miss

Between these periodic reviews, the Prove step's contract check is sufficient.

## Codex Checkpoints

Tell the user to go to Claude at these moments:
- If unsure about a design decision
- If a fix doesn't work after 2 attempts (bug escalation)
- When all modules for this pass are built — for Prove step
