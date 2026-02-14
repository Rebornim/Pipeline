# Pass [N] Design: [Pass Name] — [System Name]

**Feature pass:** [N] of [total]
**Based on:** feature-passes.md, idea-locked.md
**Existing code:** [list modules that exist from previous passes]
**Critic Status:** [APPROVED / PENDING]
**Date:** [date]

---

## What This Pass Adds

<!-- Plain language: what new behavior does this pass introduce? -->

---

## File Changes

### New Files
| File | Location | Purpose |
|------|----------|---------|
| | | |

### Modified Files
| File | What's Changing | Why |
|------|----------------|-----|
| | | |

---

## New/Modified APIs

```lua
-- [Module.luau]
-- NEW or MODIFIED functions only. Existing unchanged APIs not repeated here.

function Module.newFunction(param: type): returnType
-- What it does, when it's called, by whom
```

---

## New Data Structures

```lua
-- Only new types or modifications to existing types
```

---

## New Config Values

```lua
-- Added to existing Config.luau
-- CATEGORY
-- VALUE_NAME = default, -- What it controls. Range: X-Y.
```

---

## Data Flow for New Behaviors

### [Behavior Name]
1. [Step]: [what happens]
2. [Step]: [what happens]
3. ...

---

## Integration Pass (against real code)

### Data Lifecycle Traces

**[Data Name]**
- **Created by:** [Module.function()] → type
- **Passed via:** [mechanism]
- **Received by:** [Module.function(param)] — VERIFIED against actual code signature
- **Stored in:** [table, key, lifetime]
- **Cleaned up by:** [Module.function()] → trigger
- **Verified:** [types match, timing safe, cleanup complete]

### API Composition Checks (new calls only)

| Caller | Callee | Args Match | Return Handled | Verified Against |
|--------|--------|-----------|----------------|-----------------|
| NewMod.foo() | ExistingMod.bar(x) | Yes | Yes | Real code on disk |

---

## Diagnostics Updates

### New Reason Codes
- `CODE_NAME` — when/why this fires

### New Health Counters
- `counterName` — what it tracks

---

## Startup Validator Updates

| Contract | Check | Error Message |
|----------|-------|---------------|
| | | |

---

## Golden Tests for This Pass

### Test: [Name]
- **Setup:** [workspace layout, config overrides]
- **Action:** [what happens]
- **Expected:** [specific result within timeframe]
- **Pass condition:** [what to check — visual + diagnostics]

### Regression Tests
Re-run these golden tests from previous passes: [list test names]

---

## Critic Review Notes
<!-- Filled in after critic review -->
