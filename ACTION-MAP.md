# Pipeline Action Map — What You Do

## Setup
```bash
cd ~/roblox-pipeline
bash pipeline/new-project.sh <system-name>
```

---

## Idea (You + Claude)

1. Open Claude Code from `~/roblox-pipeline/`
2. Tell Claude: **"Starting idea for <system-name>"**
3. Describe your idea, answer questions, push back if you disagree
4. When done: **"Lock it"**

**Done when:** `idea-locked.md` exists.

---

## Roadmap (Claude, mostly hands-off)

1. Tell Claude: **"Build the roadmap for <system-name>"**
2. Claude divides features into ordered passes
3. Review the passes — reprioritize if you want
4. Approve

**Done when:** `feature-passes.md` exists.

---

## Passes (repeat for each pass)

### Design (Claude)
1. Tell Claude: **"Design pass N for <system-name>"**
   - Or paste the handoff prompt Codex gave you from the previous pass
2. Claude reads existing code + build deltas, designs this pass, runs critic
3. When approved: Claude writes `pass-N-design.md`
4. **Claude gives you a handoff prompt for Codex** — copy it

**Done when:** Claude gives you a Codex handoff prompt.

### Build (Codex CLI)
1. Open Codex CLI
2. **Paste the handoff prompt Claude gave you**
3. Codex builds step by step
4. Test in Studio after each step (golden tests + regression tests)
5. If a bug won't fix after 2 Codex attempts:
   - Tell Claude: **"Bug in pass N. [describe bug + diagnostics]. Codex tried [X] and [Y]."**
   - Claude writes a fix plan → give it to Codex
6. When all golden tests pass → tell Codex: **"All tests passing, complete the pass"**

### Pass Completion (Codex handles this)
Codex automatically:
1. Writes build delta to `state.md` (what changed from the design)
2. Commits and pushes all code to GitHub
3. **Gives you a handoff prompt for Claude** — copy it for the next pass

### Prove (You + Claude)
1. **Paste the handoff prompt Codex gave you** into Claude
2. Claude does a contract check (build matches design)
3. If issues: back to Codex → fix → Claude re-checks
4. When approved: pass is locked, Claude starts designing the next pass

---

## The Flow Between AIs

```
Claude designs → gives you a Codex prompt
↓
You paste into Codex → Codex builds
↓
Codex finishes → gives you a Claude prompt
↓
You paste into Claude → Claude proves + designs next pass
↓
(repeat)
```

You are the bridge. The handoff prompts make that easy — just copy and paste.

---

## Config Tuning (You, no AI needed)

At any point during testing:
1. Open Config.luau
2. Adjust values for anything that feels off
3. Re-test
4. **Exhaust config before going back to AI**

---

## Periodic Structural Review (every 3-5 passes)

1. Tell Claude: **"Full structural review for <system-name>"**
2. Claude runs critic on the entire codebase
3. Give feedback to Codex to address
4. Then continue with the next pass

---

## Ship

When all passes are proven:
1. Tell Claude: **"Ship <system-name>"**
2. Claude does final review, writes build-notes.md
3. Final commit and push
4. Done

---

## If Rate Limit Hits

- Stop. AI saved state to state.md.
- When limit resets: **"Resuming pass N [design/build/prove] for <system-name>"**

---

## If Stuck 3+ Times on Same Bug

- Stop iterating with Codex
- Tell Claude: **"Bug in pass N. [describe bug + diagnostics]. Codex tried [X], [Y], [Z]."**
- Claude writes a fix plan, you give it to Codex

---

## The Pattern
```
Idea → Roadmap → [Design → Build → Prove] × N → Ship
```
