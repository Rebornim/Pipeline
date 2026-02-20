# Prove (per pass)

## What You're Doing

Confirming that this feature pass works correctly and hasn't broken anything from previous passes. Once proven, this pass becomes locked foundation for future passes.

## Process

### Step 1: User Runs Golden Tests

The **user** runs golden tests in Studio — not Codex via MCP. Codex provides the checklist, the user plays and reports back.

Give the user a clear checklist from `projects/<name>/golden-tests.md`:
- This pass's golden tests (new functionality works)
- All previous passes' golden tests (no regressions)
- For each test: what to set up, what to do, what to look for

The user plays, observes, and reports results. If they report errors or warnings from the output log, Codex investigates. **Codex only uses MCP if the user explicitly says to.**

### Step 2: User Diagnostics Health Check

Tell the user to enable DEBUG_MODE and play for a few minutes. They check:
- Active entity counts: stable, or drifting?
- Spawn/destroy rates: balanced?
- Failure/reject counts: any unexpected failures?
- Per-entity trails: do they show the expected lifecycle?
- Any new warning or error messages?

The user reports what they see. Codex interprets and fixes if needed.

### Step 3: Regression Check

The user verifies that behaviors from previous passes still work correctly:
- Does pass 1's core loop still function?
- Do previous passes' features still behave as expected?
- Are diagnostics patterns from previous passes unchanged?

If a regression is found: **this is a blocking issue.** Fix it before this pass can be locked. The fix goes through the normal build process (categorize issue, send to Codex with diagnostics, one fix at a time). MCP is allowed for fix cycles only if the user says to test.

### Step 4: Clean Up AI Build Prints

**Codex removes all temporary AI build prints** added during the build step:
- All `[TAG] key=value` print statements
- All `START READ HERE` / `END READ HERE` marker scripts
- All `[SUMMARY]` print lines

Keep permanent diagnostics (the `DEBUG_MODE`-gated logging, lifecycle reason codes, health counters). Those are human-focused and stay in the codebase. Only the temporary AI-focused prints get removed.

**Do NOT run a verification playtest after cleanup.** The user will confirm it runs clean themselves.

### Step 5: Build Delta + Handoff

**Codex writes the build delta.** Before locking the pass, tell Codex to document what actually changed vs what was planned:
- What was built exactly as designed
- What deviated from the design and why (bug fixes, user-requested changes, practical adjustments)
- Any new contracts, config values, or behaviors that weren't in the original design

This goes into `state.md` so Claude reads it before designing the next pass.

**Codex commits and pushes.** All scripts get committed and pushed to `git@github.com:Rebornim/Pipeline.git` with a clear commit message: `pass N complete: [pass name]`

**Codex produces a Claude handoff prompt.** File pointers and action only. No summaries, no context, no explanations. Claude reads the build delta in state.md and uses it to design the next pass.

Format:
```
Read: CLAUDE.md, projects/<name>/state.md. Then read code in projects/<name>/src/. Design pass [N+1].
```

That's it. Nothing more.

### Step 6: Lock This Pass

When AI prints are cleaned, build delta is written, and code is pushed:
- Update `state.md` with build deltas and next pass info
- The code on disk is now **proven foundation** for the next pass
- Move to next pass's Design step (or Ship if this was the last pass)

## Exit Criteria

- [ ] All golden tests pass (this pass + all previous)
- [ ] Diagnostics health check clean (no anomalies, stable counts)
- [ ] No regressions on previous pass behavior
- [ ] AI build prints removed (only permanent diagnostics remain)
- [ ] Build delta documented in state.md
- [ ] Code committed and pushed to GitHub
- [ ] Claude handoff prompt produced
- [ ] state.md updated for next pass

## Periodic Full Critic Review

Every 3-5 passes (not every pass), run a full critic review on the entire codebase instead of just a contract check. This catches accumulated drift, tech debt, and patterns going stale. The review feedback goes to Codex to address before the next pass begins.

## Rules

- **Don't skip regression tests.** The whole point of the cyclic approach is that each pass builds on proven code.
- **Don't move on with a known regression.** Fix it in this cycle.
- **Config tuning is still free.** No cycle needed for config tweaks.
- **Build deltas are mandatory.** Claude cannot design the next pass accurately without knowing what Codex actually built.
- **Handoff prompts are mandatory.** The user should not have to figure out what to tell the next AI.

## If This Is The Last Pass → Ship

When all feature passes are proven:
1. Run all golden tests one final time
2. Claude runs full critic review on the complete codebase
3. Write `projects/<name>/build-notes.md`
4. Final commit and push
5. Update `state.md`: Stage → Complete
6. System is done
