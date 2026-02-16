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

#### 2b. Checkpoint before testing.
Codex commits a checkpoint: `git add -A && git commit -m "checkpoint: pass N step [name] pre-test"`. If the test-fix loop makes things worse, the user can revert to this commit.

#### 2c. Automated test loop (via MCP).
Codex has access to Roblox Studio via the `robloxstudio-mcp` server. Use it:

1. Call `start_playtest` — launches Play Solo in Studio, begins capturing output
2. Wait for AI build prints to appear (look for `========== START READ HERE ==========` marker)
3. Call `get_playtest_output` ONE TIME — read captured output. This is cumulative (returns ALL logs), so only call it once.
4. Call `stop_playtest` — end the session. Do NOT also call `get_playtest_output` before this — `stop_playtest` returns the logs too.

**Important: `get_playtest_output` is cumulative.** Each call returns the entire log from session start, not just new lines. Do not poll it repeatedly — one retrieval per test. If waiting for a specific marker, poll sparingly.

**Keep global diagnostics OFF.** Set `Config.DiagnosticsEnabled = false` during automated testing. Only pass-specific `[PN_TEST]` prints should be active. Unrelated diagnostics noise burns tokens.

**Read the output.** AI build prints tell you exactly what ran, in what order, and what failed. Check against golden test expectations. Summarize findings — do not dump full raw logs.

**3 test-fix cycles max.** If the code doesn't pass after 3 cycles of (test → read logs → fix → retest), STOP. Hand the code + logs to the user for escalation to Claude.

**No-regression rule.** If a fix breaks something that was previously passing, revert that fix immediately. Do not "fix forward" through a cascade.

#### 2d. If automated tests fail within the 3-cycle cap:
1. **Read AI build prints.** What do the `[TAG]` lines say?
2. **Check config.** Is it a tunable value problem? Free fix, no tokens.
3. **Fix ONE thing.** The smallest change that addresses the specific failure.
4. **Retest.** Back to 2c.

#### 2e. If automated tests pass → user visual check.
Tell the user: "Step [name] passes automated tests. Ready for your visual check in Studio."
The user plays the game, checks that it looks/feels right. If they report issues, those go through the normal fix process.

#### 2f. PASS → move to next step.

### Step 3: All Steps Built

When all modules for this pass are built and individual tests pass:
- Run ALL golden tests (this pass + all previous passes)
- Check diagnostics health summary
- If everything passes → move to Prove

## AI Build Prints

Temporary print statements that exist ONLY during the build step so Codex can read what the code does at runtime. These are **not** the same as permanent diagnostics.

**Rules:**
- **Structured and tagged:** `[TAG] key=value` format. One line per event. Machine-readable.
- **Non-spammy:** Don't print every frame. Print on events (spawn, despawn, state change, error).
- **Marker scripts:** Add a small script that waits a few seconds then prints `========== START READ HERE ==========` so the AI knows where to read from, skipping startup noise. Use `========== END READ HERE ==========` to bracket the interesting window.
- **Summary prints:** At the end of a test window, print a one-line summary: `[SUMMARY] spawned=12 despawned=4 errors=0 avg_lifetime=28.3s`. This lets the AI assess pass/fail from one line instead of parsing hundreds.
- **Temporary.** AI build prints are removed after the pass is proven (during the Prove step). They do not ship.
- **Separate from diagnostics.** The permanent diagnostics module (lifecycle reason codes, health counters) is controlled by `DEBUG_MODE` and is human-focused. AI build prints are AI-focused and exist only during development.

**Example AI build prints:**
```lua
print("[SPAWN] id=NPC_012 pos=(142,3,87) model=Zombie zone=Forest")
print("[PATH]  id=NPC_012 waypoints=5 target=(200,3,120)")
print("[STATE] id=NPC_012 old=wandering new=returning reason=out_of_range")
print("[DESPAWN] id=NPC_012 reason=cleanup lifetime=34.2s")
print("[SUMMARY] spawned=12 despawned=4 active=8 errors=0")
```

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
