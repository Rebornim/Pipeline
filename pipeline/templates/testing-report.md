# Testing Report: [System Name] — Pass [N]

**Date:**
**Test Round:** (increment each re-test)
**Testing In:** (Studio play solo / multiplayer / etc.)

---

## Startup Validation
- [ ] Server started without errors
- **Errors (if any):**

---

## Golden Tests — This Pass

### Test: [Name]
- **Setup done:** Yes / No
- **Expected:** [from pass design]
- **Actual:**
- **Diagnostics output:** [relevant lines]
- **Status:** PASS / FAIL

---

## Golden Tests — Previous Passes (Regression)

### Test: [Name] (Pass N)
- **Status:** PASS / FAIL
- **Notes:** [any changes from previous behavior]

---

## Diagnostics Health Check

- **Active count:** [stable / drifting]
- **Spawn/destroy rates:** [balanced / imbalanced]
- **Failure/reject counts:** [expected / unexpected]
- **Anomalies:**

---

## Config Adjustments

| Value | Original | Changed To | Effect | Resolved? |
|-------|----------|------------|--------|-----------|
| | | | | |

---

## Issues for AI

_One issue at a time. Include diagnostics. Specify change type._

### Issue 1
- **Module:**
- **Category:** Bug / Wrong Behavior / Feels Off / Missing
- **Change type:** Bugfix / Tuning / Design change
- **Diagnostics output:**
- **Description:**
- **Expected behavior:** (reference pass design doc)

---

## Summary

**Startup:** PASS / FAIL
**This pass golden tests:** X / Y
**Previous pass golden tests:** X / Y (regression)
**Diagnostics:** Clean / Anomalies
**Verdict:** ALL PASS / NEEDS FIXES
