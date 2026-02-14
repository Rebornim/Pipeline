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
- Do pass 2's features still behave as expected?
- Are diagnostics patterns from previous passes unchanged?

If a regression is found: **this is a blocking issue.** Fix it before this pass can be locked. The fix goes through the normal build process (categorize issue, send to Codex with diagnostics, one fix at a time).

### Step 4: Lock This Pass

When all golden tests pass and diagnostics are clean:

1. Tell Claude: "Pass N prove for [project-name] — all golden tests passing, diagnostics clean."
2. Claude runs critic review on the new/modified code against the pass design doc
3. If critic finds blocking issues → fix → re-prove
4. When approved:
   - Update `state.md`: move to next pass's Design step (or Ship if this was the last pass)
   - The code on disk is now **proven foundation** for the next pass

## Exit Criteria

- [ ] All golden tests pass (this pass + all previous)
- [ ] Diagnostics health check clean (no anomalies, stable counts)
- [ ] No regressions on previous pass behavior
- [ ] Critic review approved
- [ ] state.md updated

## Rules

- **Don't skip regression tests.** The whole point of the cyclic approach is that each pass builds on proven code. If you skip regression testing, you lose that guarantee.
- **Don't move on with a known regression.** Fix it in this cycle or the next pass inherits a broken foundation.
- **Config tuning is still free.** If something feels off and it's a config value, just change it. No cycle needed for config tweaks.

## If This Is The Last Pass → Ship

When all feature passes are proven:

1. Run all golden tests one final time
2. Claude runs full critic review on the complete codebase
3. Write `projects/<name>/build-notes.md`
4. Update `state.md`: Stage → Complete
5. System is done
