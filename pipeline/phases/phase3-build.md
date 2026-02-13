# Phase 3: Build & Refine

**Primary AI: Codex CLI (GPT 5.3) for building, Claude for reviews and translation**

This phase has two halves. The first is structured and rigid — you build mechanic by mechanic, test each one, and don't move on until it works. The second is open — you polish, tune, and iterate however you want. The gate between them is simple: does every mechanic from idea-locked.md pass?

The structured half exists because handing AI a full architecture and saying "build everything" is where control gets lost. The open half exists because you can't spec your way through the last 20% of making something feel right.

---

## Your Leverage

You have three things that prevent blind vibe coding:

1. **idea-locked.md** — Every mechanic defined. Testing is mechanic-by-mechanic against this, not freeform "play and see."
2. **architecture-outline.md** — Every technical decision made. When behavior is wrong, compare against the spec instead of guessing.
3. **Config file** — Tunable values separated from logic. "Feels off" problems hit the config first (free, no AI tokens) before touching code.

If you find yourself saying "this feels weird, fix it" with no reference to a specific mechanic or spec, you've lost your leverage. Stop and use the testing template.

---

## Part 1: Structured Build

### Step 1: Determine Build Order

Open architecture-outline.md. Look at the file organization and the script communication map. Identify which mechanics depend on which. Build foundation pieces first.

Ask Claude to help sequence this if it's not obvious. The output is a numbered list:
1. Mechanic A (no dependencies — build first)
2. Mechanic B (depends on A)
3. Mechanic C (depends on A)
4. Mechanic D (depends on B and C)
...and so on.

For simple systems this might be 3-4 items. For complex systems it could be 8-12. Either way, each one is a single buildable unit.

---

### Step 2: Build Loop (repeat for each mechanic)

For each mechanic in the build order:

#### 2a. Tell Codex to build this mechanic only.
Give Codex:
- The architecture-outline.md (or the relevant sections)
- Which mechanic you're building
- What files already exist (if this isn't the first mechanic)
- Explicit boundaries: what files Codex can create/modify, what it must not touch

**Context rule:** If Codex has been working on previous mechanics in the same conversation, tell it to re-read the relevant files from disk before starting. AI does not reliably remember what it wrote earlier — the files on disk are the source of truth, not its memory.

#### 2b. Bring the code to Claude for review.
Before you test, tell Claude: "Review mechanic [name] for [project-name]."

Claude will:
- Read the code Codex wrote
- Give you a plain-language briefing: what the code does, what to watch for when testing, which config values matter for this mechanic
- Check for deviations from architecture-outline.md
- Flag anything that looks wrong before you spend time testing a broken build

This is not a full critic review — it's a quick sanity check and translation so you understand what you're about to test.

#### 2c. Sync via Rojo and test in Studio.
Test ONLY this mechanic against idea-locked.md:
- Does it work at all? (functional)
- Does it behave as described? (spec compliance)
- Try to break it (exploit scenarios)

Use the testing report template if you want to track results, but during the build loop a simple PASS/FAIL per mechanic is enough.

#### 2d. If it fails: fix before moving on.
1. **Config first.** Is it a number problem? Change the config value, re-test. Free, no tokens.
2. **If not config:** Describe the issue to Codex using the triage categories (Bug / Wrong Behavior / Feels Off / Missing). Tell Codex to re-read the relevant files first. One issue at a time.
3. **If stuck after 3 attempts on the same issue:** Escalate to Claude. The architecture might need revision — that's a Phase 2 problem leaking into Phase 3.

#### 2e. Mark PASS, move to next mechanic.
Don't move on until this mechanic works. Compounding broken mechanics is how you end up vibe coding.

---

### Step 3: Spec Complete Gate

When every mechanic in idea-locked.md passes:
- All mechanics functional and matching spec
- Config file complete with all tunable values
- No known bugs

You are now **spec complete**. Update the testing report summary. The structured phase is over.

---

## Part 2: Open Refinement

You've earned this. Every mechanic works per spec. Now you make it feel right.

**There are no mandatory steps here.** You polish when you want, iterate how you want, stop when you're satisfied. The pipeline gives you tools, not orders:

- **Config tuning** — Still free, still the first thing to try when something feels off.
- **Testing template** — Use it if you want to track what you're changing. Don't if you don't need to.
- **Claude** — For translation (explain what code does), triage (help structure an issue for Codex), or architecture questions (is this a logic problem or a tuning problem?).
- **Critic review** — Run it when you think you're done, or earlier if you want a checkpoint.

### Context Hygiene (for working with Codex during refinement)

These rules exist because AI breaks most often when context drifts from reality:

1. **One issue at a time.** Don't batch five problems into one message. Codex performs best focused on a single function or script.
2. **Tell Codex to re-read files.** Before any fix, tell it to read the current version of the files it's modifying. The files on disk are the truth, not what Codex remembers writing.
3. **Set boundaries.** Tell Codex what it can change and what it must not touch. "Fix the detection range logic in DetectionService.luau. Do not modify Config.luau or any other file."
4. **Reference the spec.** When describing wrong behavior, quote what architecture-outline.md says should happen. This prevents Codex from "fixing" something by inventing new behavior.

---

## Step 4: Final Critic Review

When you're satisfied with the system (not just spec-complete, but polished to your standards):

1. Tell Claude: "Final review for [system-name]"
2. Claude runs the critic-reviewer agent against:
   - All code in `projects/<name>/src/`
   - `projects/<name>/architecture-outline.md`
   - `pipeline/checklists/critic-checklist.md`
3. If blocking issues found → Codex fixes → Claude re-reviews
4. When critic approves: proceed to Ship

---

## Step 5: Ship

1. Write `projects/<name>/build-notes.md` using template from `pipeline/templates/build-notes.md`
2. Update `projects/<name>/state.md` to Phase: complete
3. System is done

---

## Exit Criteria
- [ ] All mechanics from idea-locked.md implemented and passing
- [ ] Config file complete with documented values
- [ ] Security validated by critic (no blocking issues)
- [ ] Performance acceptable under testing conditions
- [ ] User approves for deployment

---

## Anti-Vibe-Coding Rules

These apply to the structured build phase. During open refinement, you have more freedom — but these are still good habits.

1. **Never say "this feels weird, fix it" without specifying which mechanic and what's wrong.**
2. **Never skip config.** If it might be a number, try the number first.
3. **Never move to the next mechanic with a broken one behind you.** Fix it or escalate it.
4. **Never send unstructured feedback to Codex.** Use the issue categories. Tell it to re-read files. Set boundaries.
5. **If you've been iterating for 30+ minutes on the same issue, stop.** Either it's an architecture problem (escalate to Claude) or the spec needs updating (revisit idea-locked.md). Don't grind.
