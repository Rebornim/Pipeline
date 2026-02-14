# Critic Review Checklist

Use this rubric when reviewing pass designs or code. Rate each item as:
- **BLOCKING** — must fix before proceeding
- **FLAG** — note it, but doesn't halt progress
- **PASS** — no issues

---

## Cross-Module Contracts (Highest Priority)

When reviewing a pass design, check new code against EXISTING TESTED CODE, not against other design docs.

### Blocking
- [ ] Data lifecycle break: new module's output type/format doesn't match existing module's input parameter
- [ ] Missing handoff: new module expects data from existing module, but existing module doesn't provide it
- [ ] API signature mismatch: call site passes different arguments than the real function accepts
- [ ] Return value ignored or mishandled
- [ ] Cleanup gap: data created but no module responsible for cleanup
- [ ] Timing dependency: new module calls existing module before it's initialized

### Flag
- [ ] Implicit contract: modules depend on shared state without explicit documentation
- [ ] Redundant data: same data stored in multiple places with no clear owner

---

## Regression Risk (Pass-Specific)

### Blocking
- [ ] This pass modifies an existing module's API signature without updating all callers
- [ ] This pass changes data structure used by existing modules without updating those modules
- [ ] New behavior could interfere with existing pass's golden test scenarios

### Flag
- [ ] Config value changes could affect previously-proven behavior
- [ ] New module has same-named functions as existing module (confusion risk)

---

## Startup Validation

### Blocking
- [ ] System depends on workspace structure with no startup check
- [ ] New workspace contracts from this pass not added to startup validator
- [ ] Configuration values not validated at startup

### Flag
- [ ] Startup validator exists but doesn't cover all workspace contracts
- [ ] Error messages don't clearly identify the misconfiguration

---

## Security

### Blocking
- [ ] Client has authority over sensitive data
- [ ] RemoteEvent/RemoteFunction arguments not validated server-side
- [ ] Server trusts client-provided data without verification
- [ ] No rate limiting on spammable endpoints
- [ ] Player can trigger actions for other players

### Flag
- [ ] Client/server split unclear or undocumented
- [ ] Validation exists but could be stricter

---

## Performance

### Blocking
- [ ] Unbounded loop with no yield
- [ ] Expensive operation in tight loop
- [ ] RemoteEvent fires every frame
- [ ] Memory leak: connections/tables/instances never cleaned up
- [ ] O(n^2) or worse with player count
- [ ] UI updates every frame unnecessarily

### Flag
- [ ] Cacheable operation not cached
- [ ] Client doing work server already did
- [ ] Large RemoteEvent payload when smaller would work

---

## Roblox Best Practices

### Blocking
- [ ] Deprecated APIs (`wait()`, `spawn()`, `delay()`)
- [ ] Reinventing Roblox-provided functionality
- [ ] `.Touched` without debounce
- [ ] Yielding in inappropriate contexts
- [ ] String keys for RemoteEvents when structured data would prevent typo bugs

### Flag
- [ ] Not using CollectionService for tagged-instance patterns
- [ ] Missing type annotations on public functions
- [ ] Not using built-in replication where it would simplify

---

## Maintainability

### Blocking
- [ ] Config values hardcoded in logic
- [ ] Monolithic script
- [ ] Spaghetti control flow
- [ ] Core logic and UI logic mixed

### Flag
- [ ] Inconsistent naming conventions
- [ ] Magic numbers without explanation
- [ ] Complex logic without comments
- [ ] Module API surface unclear

---

## Diagnostics Coverage

### Blocking
- [ ] System has no diagnostics module
- [ ] Lifecycle events missing reason codes
- [ ] No health counters for key metrics

### Flag
- [ ] Per-entity trail too short for debugging
- [ ] Diagnostics output hard to read
- [ ] Diagnostics not toggleable via Config

---

## UI Integration (if applicable)

### Blocking
- [ ] UI state can desync from server state
- [ ] UI fires RemoteEvents without throttling
- [ ] No loading state handling
- [ ] No edge case handling (close mid-action, data not loaded)

### Flag
- [ ] No optimistic UI updates
- [ ] UI code mixed with backend logic
- [ ] No empty state handling
- [ ] UI elements not cleaned up

---

## Review Output Format

```
## Critic Review: [System Name] — Pass [N] [Design/Code]

### Blocking Issues (must fix)
1. [Category] Description. Where. How to fix.

### Flagged Items (note for later)
1. [Category] Description. Suggestion.

### Passed
Summary of what looks good.

### Regression Risk
Any concerns about impact on previous passes.

### Verdict: APPROVED / BLOCKED (N blocking issues)
```
