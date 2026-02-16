# Prove (per pass)

## What You're Doing

Confirming that this feature pass works correctly and hasn't broken anything from previous passes. Once proven, this pass becomes locked foundation for future passes.

## Process

### Step 1: Run All Golden Tests

Run every golden test in `projects/<name>/golden-tests.md`:
- This pass's golden tests (new functionality works)
- All previous passes' golden tests (no regressions)

For each test:
- Set up workspace as described
- Set config overrides as specified
- Run the test
- Check expected outcomes (visual behavior + diagnostics output)
- Record results

### Step 2: Diagnostics Health Check

With DEBUG_MODE enabled, play for a few minutes and check:
- Active entity counts: stable, or drifting?
- Spawn/destroy rates: balanced?
- Failure/reject counts: any unexpected failures?
- Per-entity trails: do they show the expected lifecycle?
- Any new warning or error messages?

### Step 3: Regression Check

Specifically verify that behaviors from previous passes still work correctly:
- Does pass 1's core loop still function?
- Do previous passes' features still behave as expected?
- Are diagnostics patterns from previous passes unchanged?

If a regression is found: **this is a blocking issue.** Fix it before this pass can be locked. The fix goes through the normal build process (categorize issue, send to Codex with diagnostics, one fix at a time).

### Step 4: Contract Check

Tell Claude: "Pass N prove for [project-name]."

Claude does a focused contract check on the new/modified code (NOT a full critic review):
1. Do function signatures match the pass design doc?
2. Do cross-module calls pass the right arguments and handle returns?
3. Are diagnostics and validators hooked up as specified?

This is quick — focused on verifying the build matches the design, not a comprehensive code review.

### Step 5: Clean Up AI Build Prints

**Codex removes all temporary AI build prints** added during the build step:
- All `[TAG] key=value` print statements
- All `START READ HERE` / `END READ HERE` marker scripts
- All `[SUMMARY]` print lines

Keep permanent diagnostics (the `DEBUG_MODE`-gated logging, lifecycle reason codes, health counters). Those are human-focused and stay in the codebase. Only the temporary AI-focused prints get removed.

### Step 6: Build Delta + Handoff

**Codex writes the build delta.** Before locking the pass, tell Codex to document what actually changed vs what was planned:
- What was built exactly as designed
- What deviated from the design and why (bug fixes, user-requested changes, practical adjustments)
- Any new contracts, config values, or behaviors that weren't in the original design

This goes into `state.md` so Claude reads it before designing the next pass.

**Codex commits and pushes.** All scripts get committed and pushed to `git@github.com:Rebornim/Pipeline.git` with a clear commit message: `pass N complete: [pass name]`

**Codex produces a Claude handoff prompt.** A short message the user pastes to Claude to start the next pass's design. It must include:
- Which project, which pass was just completed
- Where to read the build delta (state.md)
- Which files to read for the current codebase state
- What the next pass is (from feature-passes.md)

Example:
> "Pass 2 for wandering-props is complete. Read `state.md` for build deltas, then read code in `src/`. Next is pass 3 per `feature-passes.md`. Design pass 3."

### Step 7: Lock This Pass

When contract check passes, AI prints are cleaned, build delta is written, and code is pushed:
- Update `state.md` with build deltas and next pass info
- The code on disk is now **proven foundation** for the next pass
- Move to next pass's Design step (or Ship if this was the last pass)

## Exit Criteria

- [ ] All golden tests pass (this pass + all previous)
- [ ] Diagnostics health check clean (no anomalies, stable counts)
- [ ] No regressions on previous pass behavior
- [ ] Contract check passed (build matches design)
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
