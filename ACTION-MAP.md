# Pipeline Action Map — What You Do

## One-Time Setup Per System
```bash
cd ~/roblox-pipeline
bash pipeline/new-project.sh <system-name>
```

---

## Phase 1: Idea (You + Claude)

1. Open new Claude Code conversation from `~/roblox-pipeline/`
2. Tell Claude: **"Starting Phase 1 for <system-name>"**
3. Describe your idea (rough is fine — Claude will ask questions)
4. Answer Claude's questions, push back if you disagree
5. When Claude says exit criteria are met, tell it: **"Lock it"**

**You're done when:** `idea-locked.md` exists in your project folder.

---

## Phase 2: Architecture (Claude, mostly hands-off for you)

1. Same or new Claude conversation
2. Tell Claude: **"Starting Phase 2 for <system-name>"**
3. Claude designs architecture and runs critic review automatically
4. Claude may ask you to choose between options — pick one
5. When critic approves, Claude locks the architecture

**You're done when:** Claude says "Hand this to Codex."

---

## Phase 3: Build & Refine

### Step A — Build (Codex CLI)
1. Open Codex CLI
2. Tell Codex: **"Starting phase 3 of the pipeline"**
   - Codex reads `state.md`, finds the project, reads the architecture, and starts building mechanic by mechanic
   - Codex will stop after each mechanic and tell you to go to Claude for review
3. Follow Codex's prompts — it will tell you when to switch to Claude

### Step B — Test (You, in Roblox Studio)
1. Run `rojo serve` in `projects/<system-name>/src/`
2. Connect in Studio, test the game
3. **Open `pipeline/templates/testing-report.md`** — copy it to your project folder
4. Test EACH mechanic from idea-locked.md one by one
5. For each mechanic: works / broken / wrong behavior / feels off / missing
6. Fill out the testing report

### Step C — Config Tuning (You, NO AI needed)
1. Open the config ModuleScript in the code
2. For anything that "feels off" — find the config value and change it
3. Re-test that mechanic
4. Write down what you changed in the testing report
5. **Exhaust config options before going back to AI**

### Step D — Report Issues (You → Codex)
1. Any remaining issues that config can't fix: categorize them
   - **Bug:** doesn't work
   - **Wrong Behavior:** works but does the wrong thing
   - **Feels Off:** config couldn't fix it, needs code change
   - **Missing Feature:** not implemented yet
2. Send categorized issues to Codex
3. Codex fixes them
4. **Go back to Step B** — re-test only the affected mechanics
5. Repeat B→C→D until all mechanics show PASS

### Step E — Final Review (Claude)
1. Switch to Claude: **"Final review for <system-name>"**
2. Claude runs critic review on all code
3. If issues: relay to Codex → fix → Claude re-reviews
4. When Claude approves: done

### Step F — Ship
1. Fill out `build-notes.md` (or have Claude do it)
2. System is complete

---

## If Rate Limit Hits
- Stop. The AI already saved state.
- When limit resets, open new conversation.
- Say: **"Resuming <phase> for <system-name>"**
- AI reads state.md and picks up where it left off.

---

## If You Get Stuck on the Same Issue 3+ Times
- Stop iterating with Codex.
- Switch to Claude: **"I'm stuck on [mechanic]. Here's what's happening: [details]"**
- It might be an architecture problem, not a code problem. Claude will figure it out.

---

## The Pattern
```
Claude plans → Codex builds → You test & tune config → Codex fixes categorized issues → Claude reviews
```
