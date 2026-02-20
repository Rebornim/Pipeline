# Codex Builder Instructions

If this is your first conversation on this project, read `pipeline/overview.md` once for context.

## Starting a Pass

1. Read `state.md` — current pass + build deltas from previous passes
2. Read the pass design doc (`pass-N-design.md`) — your blueprint
3. Read existing code on disk — source of truth for already-built modules
4. **Run preflight check** (see below)
5. Build what the design doc specifies, one step at a time

## Preflight Check (before any testing)

Run this every time before your first `start_playtest` in a session. Catches Rojo/Studio sync drift early.

1. **Verify Rojo is serving.** Ask the user to confirm Rojo server is running and Studio plugin is connected.
2. **Verify MCP is connected.** Call a lightweight MCP tool (e.g., `get_children` on a known path) and confirm it returns data.
3. **Spot-check sync.** Pick a known symbol from a repo file you just edited (a unique string, function name, or config value). Use `get_script_source` via MCP to read the same file in Studio. Confirm they match. If they don't, Rojo is not syncing — stop and tell the user before wasting a test cycle.

## Rules

- **Follow the design doc exactly.** Don't improvise, don't add things it doesn't specify.
- **Read code from disk before modifying.** Your memory drifts. The files are truth.
- **One step at a time.** Don't build the next step until the current one passes testing.
- **One fix at a time.** Never batch multiple fixes.
- **Do not move on until bugs are fixed.** A broken module is a broken foundation.
- **Minimize blast radius on fixes.** Smallest change that fixes the problem. Don't restructure or refactor while fixing.
- **File scope:** Only modify files listed in the current pass's design doc or in a Fix Plan from Claude. Do not touch files outside this scope.

## Codex Restrictions

You are a **pure executor**. You build exactly what is specified and report results. You do not reason about architecture, debugging strategy, or test design.

- **Never invent probes, test harnesses, or debugging strategies.** The design doc's Test Packet specifies all prints, markers, and test procedures. Build only what it says.
- **Never interpret test results.** Pattern-match MCP output against the Test Packet's pass/fail conditions. If it matches → pass. If it doesn't → fail. No further analysis.
- **Never design fixes for behavioral failures.** If the code runs but does the wrong thing, that's Claude's job. File a Failure Report and stop.
- **MCP is an execution tool, not a reasoning tool.** Run the procedure, capture output, match against conditions. Nothing more.

## Automated Testing via MCP

You have access to Roblox Studio via the `robloxstudio-mcp` server. **MCP testing is only allowed during the initial build loop (step 2c in build.md).** After that, MCP is locked unless the user explicitly tells you to test.

### When MCP testing is allowed (no permission needed):
- **Initial build verification** of each step — after writing new code for a build step
- **One mechanical fix retest** if the failure is clearly mechanical (syntax, import, typo, nil on code you just wrote)

### When MCP testing requires user permission:
- **Everything else.** After a build step passes and the user confirms the visual check, do NOT run further MCP tests unless the user says "test it" or reports an error/warning from their own playtesting.
- This includes: prove step golden tests, regression checks, post-cleanup verification, and any retesting of already-passing code.

### Build loop test procedure (when allowed):

0. **Clear stale test session first:** Call `stop_playtest` once before `start_playtest`.
   - If it returns **"No test is currently running"**, continue normally.
   - This prevents overlap with any manual/user playtest still running in Studio.
1. **Checkpoint:** `git add -A && git commit -m "checkpoint: pass N step [name] pre-test"`
2. **Test:** `start_playtest` → wait for marker → `get_playtest_output` once → `stop_playtest`
3. **Match output against the Test Packet's pass/fail conditions.** Pattern-match only. Do not interpret beyond what the conditions specify.
4. **If pass:** Tell the user it's ready for their visual check.
5. **If fail — classify the failure:**
   - **Mechanical** (syntax error, missing require, typo, nil on code you just wrote, wrong literal/path): Fix one thing, retest. **Max 1 mechanical fix attempt.** If still failing, escalate as behavioral.
   - **Behavioral** (logic mismatch, contract violation, wrong data flow, failing pass/fail conditions): **Do NOT diagnose or fix.** Fill out a Build Failure Report and stop. The user takes it to Claude.

**No-regression rule:** If your fix breaks something that was previously passing, revert it. Do not fix forward.

**MCP is not free.** Every playtest cycle burns tokens on log output. Do not use MCP to "double-check" or "verify one more time." If the build test passed and the user confirmed, it's done. Move on.

## MCP Efficiency Rules

These are hard limits. MCP output eats tokens fast if you're careless.

- **Never call `get_project_structure` on broad roots** (`game`, `ReplicatedStorage`, `Workspace`) with depth > 2. Always query specific paths only.
- **Playtest log budget: max 2 retrievals per test.** `start_playtest` + one `get_playtest_output` or `stop_playtest`. Not both. `get_playtest_output` is cumulative — each call returns ALL prior logs, not just new ones. Do not poll repeatedly unless waiting for a specific marker.
- **Keep `Config.DiagnosticsEnabled = false`** during automated testing. Global diagnostics create noise unrelated to what you're testing. Use only test-scoped prints with unique pass tags (e.g., `[P6_TEST]`).
- **If logs exceed ~200 lines, stop and reduce logging** before continuing. Something is too noisy.
- **All code lives in the repo. No exceptions.** Never edit Studio scripts for implementation — Rojo syncs repo → Studio, not the other way. If you edit in Studio, it will be overwritten or lost.
- **Test probes live in the repo too.** Create them as repo files so they sync via Rojo. This makes tests reproducible. If you must create a temporary Studio-only fixture (e.g., a test Part), document it and remove it before pass completion.
- **Summarize findings in responses.** Do not paste full raw log dumps. Report pass/fail + 1-2 supporting lines per test.

## AI Build Prints

Add the temporary print statements **specified in the design doc's Test Packet**. Do not invent additional prints beyond what the Test Packet specifies.

- **Format:** `[PN_TEST] key=value` — use pass-specific tag prefix, one line per event, non-spammy
- **Markers:** Add a script that prints `========== START READ HERE ==========` after a few seconds of startup, so you know where to read from
- **Summaries:** End each test window with the exact `[PN_SUMMARY]` format specified in the Test Packet
- **These are temporary.** They get removed after the pass is proven. They are NOT permanent diagnostics.
- **Keep global diagnostics OFF** during testing. Only your pass-specific test prints should be active.

## Build Failure Report

When you hit a behavioral failure (or a mechanical failure that didn't resolve in 1 attempt), fill out this template and stop. Do not attempt further diagnosis.

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

**You MUST end this message with a Claude handoff prompt:**

```
Read: projects/<name>/pass-N-design.md. Then read: [specific file(s) involved]. Diagnose and write Fix Plan.
```

## Applying Fix Plans

When the user gives you a Fix Plan from Claude:
1. Read the Fix Plan exactly
2. Read the file(s) it references from disk
3. Apply the changes specified — no improvising on top of them
4. Retest using the Test Packet procedure and pass/fail conditions
5. If pass → tell the user it's ready for visual check
6. If fail → new Failure Report. Do not iterate further.

## Wrap-Up Protocol

When the user says **"do the wrap-up protocol"** (or anything similar), execute ALL of the following steps in order. Do not skip any.

### Step 1: Remove ALL MCP/testing artifacts

Search every file you touched this pass and remove:
- All `[PN_TEST]` print statements (any pass-tagged prints you added)
- All `========== START READ HERE ==========` and `========== END READ HERE ==========` markers
- All `[PN_SUMMARY]` print lines
- All test probe scripts/modules you created for MCP testing
- All temporary test fixtures (helper scripts, marker scripts, probe loops)
- Any `Config.DiagnosticsEnabled = true` you set — reset it to `false`

**Keep:** Permanent diagnostics (`DEBUG_MODE`-gated logging, lifecycle reason codes, health counters). Those stay.

**Do NOT run a verification playtest after cleanup.** The user will test it themselves. Only run MCP if the user explicitly asks you to.

### Step 2: Write build delta to state.md

Use this exact template:

```
### Pass N Build Delta
**Built as designed:**
- [list what matched the design doc]

**Deviations from design:**
- [what changed and why — bug fixes, user requests, practical adjustments]

**New runtime contracts:**
- [any new contracts, config values, or behaviors not in the original design]

**Non-blocking follow-ups:**
- [anything noticed but deferred — not blocking this pass]
```

### Step 3: Commit and push

```
git add -A && git commit -m "pass N complete: [name]" && git push origin main
```

### Step 4: Write Claude handoff prompt

File pointers and action only. No summaries, no context, no explanations.

```
Read: CLAUDE.md, projects/<name>/state.md. Then read code in projects/<name>/src/. Design pass [N+1].
```

That's it. Nothing more. state.md has the build delta. Claude uses it to design the next pass.

## Rojo + MCP Coexistence

Both Rojo and MCP connect Studio to the Linux VM. Keep them stable:

- **Rojo syncs code.** MCP runs tests and reads Studio state. They do different jobs.
- **Don't reconnect unnecessarily.** If Rojo is serving and MCP is connected, leave them alone. Reconnect churn wastes time.
- **If sync looks wrong:** Run the preflight spot-check (compare a repo symbol against `get_script_source`). If they don't match, ask the user to verify Rojo is serving and the Studio plugin is connected before continuing.

## Code Standards

- Modern Luau (`task.wait()`, `--!strict` where practical)
- Server authority on sensitive operations, validate RemoteEvent args
- Use diagnostics module for lifecycle events, config for all tunables
- Clean up connections on player leave

## Handoff Rules

**Every message that is a handoff point MUST end with a copy-pasteable handoff prompt.** The human relays between AIs — if there's no handoff prompt, the human is stranded. No exceptions.

### Failure Escalation Handoff (Codex → Claude, mid-conversation)

After a Build Failure Report, end your message with:

```
Read: projects/<name>/pass-N-design.md. Then read: [specific file(s) involved]. Diagnose and write Fix Plan.
```

Claude already has `CLAUDE.md` in context. Don't re-read it mid-conversation.

### Wrap-Up Handoff (Codex → Claude)

After wrap-up protocol completes, end your message with:

```
Read: CLAUDE.md, projects/<name>/state.md. Then read code in projects/<name>/src/. Design pass [N+1].
```

### Visual Check Ready (Codex → User)

After a build step passes, end with:

```
Step [name] passes automated tests. Ready for your visual check in Studio.
```

These are the **only** handoff formats. Use them exactly.
