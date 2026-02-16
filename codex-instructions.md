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
- **All code lives in the repo. No exceptions.** Never edit Studio scripts for implementation — Rojo syncs repo → Studio, not the other way. If you edit in Studio, it will be overwritten or lost.
- **Test probes live in the repo too.** Create them as repo files so they sync via Rojo. This makes tests reproducible. If you must create a temporary Studio-only fixture (e.g., a test Part), document it and remove it before pass completion.
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

1. **Remove AI build prints.** Delete all temporary `[PN_TEST]` print statements, marker scripts, and test probe modules. Keep permanent diagnostics (the `DEBUG_MODE` ones).
2. **Write build delta to state.md** using this exact template:

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

3. **Commit and push:** `git add -A && git commit -m "pass N complete: [name]" && git push origin main`
4. **Write a Claude handoff prompt.** File pointers and action only. No summaries, no context, no explanations. The files contain the information.

Format:
```
Read: CLAUDE.md, projects/<name>/state.md. Then read code in projects/<name>/src/. Prove pass N.
```

That's it. Nothing more. Do not add what was built, what changed, or any other context. state.md has all of that.

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
