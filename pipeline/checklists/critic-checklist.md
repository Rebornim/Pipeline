# Critic Review Checklist

Use this rubric when reviewing architecture outlines OR production code. Rate each item as:
- **BLOCKING** — must fix before proceeding
- **FLAG** — note it, but doesn't halt progress
- **PASS** — no issues

---

## Security

### Blocking
- [ ] Client has authority over sensitive data (money, inventory, health, progression, game state)
- [ ] RemoteEvent/RemoteFunction arguments not validated server-side (type, range, sanity)
- [ ] Server trusts client-provided data for critical operations without verification
- [ ] No rate limiting on endpoints players could spam (purchases, actions, requests)
- [ ] Player can trigger actions for other players (missing player identity verification)

### Flag
- [ ] Client/server responsibility split is unclear or undocumented
- [ ] Validation exists but could be stricter (e.g., only type-checking, not range-checking)
- [ ] Sensitive operation lacks logging for debugging exploits later

---

## Performance

### Blocking
- [ ] Unbounded loop with no yield (`while true do` without `task.wait()`)
- [ ] Expensive operation in tight loop (raycasting every frame per player, pathfinding in RenderStepped)
- [ ] RemoteEvent fires every frame instead of batched/throttled
- [ ] Memory leak: connections never disconnected, tables never cleared, instances never destroyed
- [ ] Server-side operation scales O(n^2) or worse with player count
- [ ] UI updates every frame when it should use change events or throttling

### Flag
- [ ] Cacheable operation not cached (e.g., repeated FindFirstChild calls for same object)
- [ ] Client doing computation that server already did and could replicate
- [ ] Large data payload sent via RemoteEvent when a smaller one would work

---

## Roblox Best Practices

### Blocking
- [ ] Using deprecated APIs (`wait()`, `spawn()`, `delay()` — use `task.*` equivalents)
- [ ] Reinventing something Roblox provides (custom pathfinding vs PathfindingService, custom tween vs TweenService)
- [ ] `.Touched` event without debounce
- [ ] Yielding in inappropriate contexts (e.g., inside a connection callback without task.spawn)
- [ ] Using string keys for RemoteEvents when Enum or structured data would prevent typo bugs

### Flag
- [ ] Not using CollectionService for tagged-instance patterns (using FindFirstChild loops instead)
- [ ] Missing type annotations on public module functions
- [ ] Not using Roblox's built-in replication where it would simplify things

---

## Maintainability

### Blocking
- [ ] Config values hardcoded in logic (weapon damage = 25 buried in a function instead of config module)
- [ ] Monolithic script (everything in one file, no module separation)
- [ ] Spaghetti control flow (deeply nested if/else, unclear state transitions)
- [ ] Core system logic and UI logic mixed in the same script
- [ ] Cross-script dependencies not documented (scripts require or fire RemoteEvents to each other with no clear map of what connects to what)

### Flag
- [ ] Inconsistent naming conventions (camelCase mixed with PascalCase mixed with snake_case)
- [ ] Magic numbers without explanation
- [ ] Complex logic without any comments
- [ ] Module API surface unclear (no obvious entry points)
- [ ] Script communication doesn't match architecture-outline.md's communication map

---

## UI Integration

### Blocking
- [ ] UI state can desync from server state (shows gold amount client calculates instead of server-confirmed)
- [ ] UI fires RemoteEvents on every interaction without throttling (button spam → server spam)
- [ ] No handling for loading state (UI shows before data is ready)
- [ ] No handling for edge cases (player closes UI mid-transaction, data fails to load)

### Flag
- [ ] No optimistic UI updates (waits for full server round-trip before showing feedback)
- [ ] UI code and backend logic in same module (should be separated)
- [ ] UI doesn't handle empty state (e.g., empty inventory shows nothing instead of "No items")
- [ ] UI elements not cleaned up when player leaves or screen changes

---

## Review Output Format

After checking all items, report:

```
## Critic Review: [System Name] — [Phase]

### Blocking Issues (must fix)
1. [Category] Description of issue. Where it is. How to fix it.
2. ...

### Flagged Items (note for later)
1. [Category] Description. Suggestion.
2. ...

### Passed
Summary of what looks good.

### Verdict: APPROVED / BLOCKED (N blocking issues)
```
