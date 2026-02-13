# Testing Report: [System Name]

**Date:**
**Test Round:** (1, 2, 3... increment each time you re-test)
**Testing In:** (Studio play solo / multiplayer test / etc.)

---

## Mechanic Testing

_Copy one block per mechanic from idea-locked.md. Test each one individually._

### [Mechanic Name]
- **What it should do:** (copy from idea-locked.md)
- **Status:** PASS / BUG / WRONG BEHAVIOR / FEELS OFF / MISSING
- **What actually happened:**
- **Issue type (if not PASS):** Bug / Wrong Behavior / Feels Off / Missing Feature
- **Details:**

### [Mechanic Name]
- **What it should do:**
- **Status:** PASS / BUG / WRONG BEHAVIOR / FEELS OFF / MISSING
- **What actually happened:**
- **Issue type (if not PASS):**
- **Details:**

_(add more mechanic blocks as needed)_

---

## Security Testing

_Try the exploit scenarios from idea-locked.md edge cases section._

- [ ] Can you cheat/exploit any mechanic? (describe what you tried)
- [ ] Does the server reject bad inputs?
- [ ] Can you spam actions without rate limiting?

**Issues found:**

---

## Performance Testing

- [ ] Any lag or stuttering?
- [ ] Any frame drops?
- [ ] Memory usage seem stable? (no growing over time)

**Issues found:**

---

## UI Testing (if applicable)

- [ ] Does UI show correct information?
- [ ] Does UI update when state changes?
- [ ] Does UI handle edge cases? (loading, empty state, rapid changes)

**Issues found:**

---

## Config Adjustments Attempted

_Before sending issues to AI, document config values you tried changing._

| Config Value | Original | Changed To | Effect | Resolved? |
|-------------|----------|------------|--------|-----------|
| | | | | |
| | | | | |

---

## Issues for AI (after config tuning exhausted)

_Only issues that need code changes. Each must have a category._

### Issue 1
- **Mechanic:**
- **Category:** Bug / Wrong Behavior / Feels Off / Missing Feature
- **Description:**
- **Expected behavior:** (reference idea-locked.md or architecture-outline.md)
- **What you tried:** (config adjustments, if any)

### Issue 2
- **Mechanic:**
- **Category:**
- **Description:**
- **Expected behavior:**
- **What you tried:**

_(add more as needed)_

---

## Summary

**Mechanics passing:** X / Y
**Issues for AI:** N (list categories)
**Verdict:** ALL PASS / NEEDS FIXES
