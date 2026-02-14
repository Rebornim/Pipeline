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
2. Claude reads existing code, designs this pass, runs critic
3. When approved: Claude writes `pass-N-design.md`

**Done when:** Claude says "Hand this to Codex."

### Build (Codex CLI)
1. Open Codex CLI
2. Tell Codex: **"Build pass N for <system-name>"**
3. Codex builds step by step, stops after each for Claude review
4. Follow Codex's prompts — switch to Claude when told

### Test (You, in Studio)
1. `rojo serve` in `projects/<system-name>/src/`
2. Connect in Studio
3. **Check output window** — startup errors? Diagnostics running?
4. **Run golden tests** from `golden-tests.md`:
   - This pass's tests (new stuff works)
   - Previous passes' tests (nothing broke)
5. Note what diagnostics output says

### Config Tuning (You, no AI needed)
1. Open Config.luau
2. Adjust values for anything that feels off
3. Re-test
4. **Exhaust config before going back to AI**

### Fix Issues (You → Codex)
1. Check diagnostics output — **include it in your report**
2. Categorize: Bug / Wrong Behavior / Feels Off / Missing
3. Send ONE issue at a time to Codex
4. Codex fixes, you re-test
5. Repeat until all golden tests pass

### Prove (Claude)
1. When all golden tests pass (this pass + previous):
   Tell Claude: **"Prove pass N for <system-name>"**
2. Claude runs critic review
3. If issues: Codex fixes → Claude re-reviews
4. When approved: pass is locked, move to next pass

---

## Ship

When all passes are proven:
1. Tell Claude: **"Ship <system-name>"**
2. Claude does final review, writes build-notes.md
3. Done

---

## If Rate Limit Hits

- Stop. AI saved state.
- When limit resets: **"Resuming pass N [design/build/prove] for <system-name>"**

---

## If Stuck 3+ Times on Same Issue

- Stop iterating with Codex
- Tell Claude: **"Stuck on [issue] in pass N. Diagnostics show: [output]"**
- May be a design issue, not a code issue

---

## The Pattern
```
Idea → Roadmap → [Design → Build → Prove] × N → Ship
```
