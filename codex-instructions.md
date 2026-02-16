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
2. **Test:** `start_playtest` → wait for markers → `get_playtest_output` → `stop_playtest`
3. **Read AI build prints.** The `[TAG] key=value` lines tell you what ran and what failed.
4. **If fail:** Fix one thing, retest. Max 3 cycles.
5. **If pass:** Tell the user it's ready for their visual check.

**No-regression rule:** If your fix breaks something that was previously passing, revert it. Do not fix forward.

## AI Build Prints

Add temporary print statements so you can read what the code does at runtime. These are your eyes.

- **Format:** `[TAG] key=value` — one line per event, structured, non-spammy
- **Markers:** Add a script that prints `========== START READ HERE ==========` after a few seconds of startup, so you know where to read from
- **Summaries:** End each test window with `[SUMMARY] spawned=N despawned=N errors=N`
- **These are temporary.** They get removed after the pass is proven. They are NOT permanent diagnostics.

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
