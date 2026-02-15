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
- **After 2 failed fix attempts: STOP.** Tell the user to take it to Claude for a fix plan. Do not keep guessing.

## Completing a Pass

When all golden tests pass and the user confirms:

1. **Write build delta to state.md:** What was built as designed, what deviated and why, any new contracts not in the original design.
2. **Commit and push:** `git add -A && git commit -m "pass N complete: [name]" && git push origin main`
3. **Write a Claude handoff prompt** for the user to copy. Include: which pass completed, where to read build deltas, what code to read, what the next pass is.

## Code Standards

- Modern Luau (`task.wait()`, `--!strict` where practical)
- Server authority on sensitive operations, validate RemoteEvent args
- Use diagnostics module for lifecycle events, config for all tunables
- Clean up connections on player leave
