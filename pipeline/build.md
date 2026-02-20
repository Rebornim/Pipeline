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
Codex has access to Roblox Studio via the `robloxstudio-mcp` server. **MCP testing is allowed here — this is the only place Codex uses MCP without explicit user permission.** Codex treats MCP as a dumb execution tool — it runs the procedure and matches results against the Test Packet's pass/fail conditions. It does not interpret, strategize, or invent tests.

1. Call `stop_playtest` first to clear any stale session.
2. Call `start_playtest` — launches Play Solo in Studio, begins capturing output
3. Wait for AI build prints to appear (look for `========== START READ HERE ==========` marker)
4. Call `get_playtest_output` ONE TIME — read captured output. This is cumulative (returns ALL logs), so only call it once.
5. Call `stop_playtest` — end the session. Do NOT also call `get_playtest_output` before this — `stop_playtest` returns the logs too.
6. **Match output against the Test Packet's pass/fail conditions.** Pattern-match only — do not interpret beyond what the conditions specify.

**Important: `get_playtest_output` is cumulative.** Each call returns the entire log from session start, not just new lines. Do not poll it repeatedly — one retrieval per test. If waiting for a specific marker, poll sparingly.

**Keep global diagnostics OFF.** Set `Config.DiagnosticsEnabled = false` during automated testing. Only pass-specific `[PN_TEST]` prints should be active. Unrelated diagnostics noise burns tokens.

**No-regression rule.** If a fix breaks something that was previously passing, revert that fix immediately. Do not "fix forward" through a cascade.

**After this step passes, MCP is locked.** Once the user confirms the visual check, do not run further MCP tests unless the user explicitly says to.

#### 2d. If automated tests fail — Mechanical vs Behavioral split:

**Mechanical failures** (syntax error, missing require/import, typo in variable/string, nil access on code Codex just wrote, wrong literal/path):
1. Codex may attempt **one** self-fix. Smallest change only.
2. Retest (back to 2c).
3. If still failing after 1 attempt, escalate as behavioral.

**Behavioral failures** (logic mismatch, contract violation, incorrect data flow, replication issue, failing pass/fail conditions from Test Packet):
1. **Codex does NOT diagnose.** Do not guess at fixes. Do not invent debugging strategies.
2. Codex fills out a **Build Failure Report** (template below) and stops.
3. The user takes the report to Claude for a Fix Plan.
4. Codex applies the Fix Plan exactly when it comes back.

**File scope rule:** Codex may only modify files listed anywhere in the current pass's Build Packet (design doc) or in a Fix Plan from Claude. Do not touch files outside this scope.

#### 2e. If automated tests pass → user visual check.
Tell the user: "Step [name] passes automated tests. Ready for your visual check in Studio."
The user plays the game, checks that it looks/feels right. If they report issues, those go through the normal fix process.

#### 2f. PASS → move to next step.

### Step 3: All Steps Built

When all modules for this pass are built and individual build tests pass:
- Tell the user all steps are built and passing their initial tests
- The user runs golden tests themselves in Studio (this pass + previous passes) and reports results
- **Do NOT run MCP golden tests automatically.** The user decides when and whether to test via MCP.
- If the user reports issues, fix them (MCP allowed only if user says to test)
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

## Build Failure Report + Escalation

When Codex hits a behavioral failure (or a mechanical failure that didn't resolve in 1 attempt), it fills out this template and stops:

```
## Build Failure Report
**Pass:** [N]
**Step:** [step name]
**Failure Type:** Mechanical | Behavioral
**Expected:** [from Test Packet pass/fail conditions]
**Actual:** [what the output actually showed]
**Relevant Output Lines:**
[2-5 key lines from the log — not a full dump]
**Mechanical Fix Attempted:** [what was tried, or "None — behavioral"]
**Result of Mechanical Fix:** [still failing / N/A]
```

**Codex must end this message with a Claude handoff prompt:**

```
Read: projects/<name>/pass-N-design.md. Then read: [specific file(s) involved]. Diagnose and write Fix Plan.
```

The user copies the Failure Report + handoff prompt to Claude. Claude diagnoses and returns a Fix Plan. The user copies the Fix Plan back to Codex. Codex applies it exactly — no improvising on top of it.

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
- On any behavioral failure (immediate escalation with Failure Report)
- On a mechanical failure that didn't resolve in 1 attempt (escalate as behavioral)
- When all modules for this pass are built — for Prove step
