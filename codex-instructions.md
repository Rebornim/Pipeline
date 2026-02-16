# Codex Builder Instructions

If this is your first conversation on this project, read `pipeline/overview.md` once for context.

## Starting a Pass

1. Read `state.md` — current pass + build deltas from previous passes
2. Read the pass design doc (`pass-N-design.md`) — your blueprint
3. Read existing code on disk — source of truth for already-built modules
4. Build what the design doc specifies, one step at a time

## Rules

- **Follow the design doc exactly.** Don't improvise, don't add things it doesn't specify.
- **Read code from disk before modifying.** Your memory drifts. The files are truth.
- **One step at a time.** Don't build the next step until the current one passes testing.
- **One fix at a time.** Never batch multiple fixes.
- **Do not move on until bugs are fixed.** A broken module is a broken foundation.
- **Minimize blast radius on fixes.** Smallest change that fixes the problem. Don't restructure or refactor while fixing.
- **After 3 failed test-fix cycles: STOP.** Tell the user to take it to Claude for a fix plan. Do not keep guessing.

## Automated Testing via MCP

You have access to Roblox Studio via the `robloxstudio-mcp` server. After writing code for each build step:

1. **Checkpoint:** `git add -A && git commit -m "checkpoint: pass N step [name] pre-test"`
2. **Test:** `start_playtest` → wait for marker → `get_playtest_output` once → `stop_playtest`
3. **Read AI build prints.** The `[TAG] key=value` lines tell you what ran and what failed.
4. **If fail:** Fix one thing, retest. Max 3 cycles.
5. **If pass:** Tell the user it's ready for their visual check.

**No-regression rule:** If your fix breaks something that was previously passing, revert it. Do not fix forward.

## MCP Efficiency Rules

These are hard limits. MCP output eats tokens fast if you're careless.

- **Never call `get_project_structure` on broad roots** (`game`, `ReplicatedStorage`, `Workspace`) with depth > 2. Always query specific paths only.
- **Playtest log budget: max 2 retrievals per test.** `start_playtest` + one `get_playtest_output` or `stop_playtest`. Not both. `get_playtest_output` is cumulative — each call returns ALL prior logs, not just new ones. Do not poll repeatedly unless waiting for a specific marker.
- **Keep `Config.DiagnosticsEnabled = false`** during automated testing. Global diagnostics create noise unrelated to what you're testing. Use only test-scoped prints with unique pass tags (e.g., `[P6_TEST]`).
- **If logs exceed ~200 lines, stop and reduce logging** before continuing. Something is too noisy.
- **Edit repo files only for implementation.** Never edit Studio scripts/modules for implementation changes — Rojo syncs one way. Studio edits are allowed ONLY for temporary test probes, and must be removed after.
- **Summarize findings in responses.** Do not paste full raw log dumps. Report pass/fail + 1-2 supporting lines per test.

## AI Build Prints

Add temporary print statements so you can read what the code does at runtime. These are your eyes.

- **Format:** `[PN_TEST] key=value` — use pass-specific tag prefix, one line per event, non-spammy
- **Markers:** Add a script that prints `========== START READ HERE ==========` after a few seconds of startup, so you know where to read from
- **Summaries:** End each test window with `[PN_SUMMARY] spawned=N despawned=N errors=N`
- **These are temporary.** They get removed after the pass is proven. They are NOT permanent diagnostics.
- **Keep global diagnostics OFF** during testing. Only your pass-specific test prints should be active.

## Completing a Pass

When all golden tests pass and the user confirms:

1. **Remove AI build prints.** Delete all temporary `[TAG]` print statements and marker scripts. Keep permanent diagnostics (the `DEBUG_MODE` ones).
2. **Write build delta to state.md:** What was built as designed, what deviated and why, any new contracts not in the original design.
3. **Commit and push:** `git add -A && git commit -m "pass N complete: [name]" && git push origin main`
4. **Write a Claude handoff prompt** for the user to copy. Include: which pass completed, where to read build deltas, what code to read, what the next pass is.

## Code Standards

- Modern Luau (`task.wait()`, `--!strict` where practical)
- Server authority on sensitive operations, validate RemoteEvent args
- Use diagnostics module for lifecycle events, config for all tunables
- Clean up connections on player leave
