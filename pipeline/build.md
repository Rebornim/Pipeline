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

#### 2b. Bring code to Claude for review.
Tell Claude: "Review [module] for [project-name], pass N."

Claude will:
- Read the code against the pass design doc
- Verify cross-module contracts against existing code
- Give a plain-language briefing of what the code does
- Flag anything wrong before you test

#### 2c. Sync via Rojo and test.
- Check output window: startup validator errors? Diagnostics running?
- Run this pass's golden tests
- **Run previous passes' golden tests** (regression check)
- Check diagnostics output for anomalies

#### 2d. If it fails:
1. **Check diagnostics.** What do reason codes and trails say?
2. **Check config.** Is it a tunable value problem? Free fix, no tokens.
3. **If not config:** Send Codex ONE categorized issue with diagnostics output. Tell it to re-read files from disk first.
4. **If stuck after 3 attempts:** Escalate to Claude — may be a design issue.

#### 2e. PASS → move to next step.

### Step 3: All Steps Built

When all modules for this pass are built and individual tests pass:
- Run ALL golden tests (this pass + all previous passes)
- Check diagnostics health summary
- If everything passes → move to Prove

## Change Discipline

Each Codex interaction is ONE of:
- **Bugfix** — something doesn't work
- **Tuning** — values need adjusting
- **Design change** — behavior needs to work differently (update the pass design doc first)

Never mix these. One change, one test, one confirmation.

## Instrument-First Debugging

When a bug appears:
1. Read diagnostics output first
2. If diagnostics don't cover this case, tell Codex to add logging first
3. Only then patch the code

No speculative fixes without evidence.

## Codex Checkpoints

Tell the user to go to Claude at these moments:
- After building each step (every time, no exceptions)
- After any bug fix that touched code
- If unsure about a design decision
- If stuck on the same issue 3+ times
- When all modules for this pass are built
