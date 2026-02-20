# Pipeline Overview

This is a cyclic development pipeline for Roblox game systems using two AI models:
- **Claude (Opus 4.6):** Architect, critic, fix planner
- **Codex CLI (GPT 5.3):** Code builder

The human user has minimal Luau/Roblox scripting knowledge. The AIs carry the technical burden. The user orchestrates, tests in Roblox Studio, and tunes config values.

## Structure

**Idea → Roadmap → [Design → Build → Prove] × N → Ship**

### One-time stages
- **Idea** — define what the system does. All features, mechanics, edge cases, UI. Lock it.
- **Roadmap** — divide features into ordered passes. Pass 1 is bare bones. Optimizations are last.

### Per-pass cycle (repeat for each feature pass)
- **Design** — Claude architects this pass against real tested code from previous passes. Integration pass traces data across modules. Golden test scenarios defined. Produces a handoff prompt for Codex.
- **Build** — Codex implements from the design doc. Codex tests each step via MCP during the initial build loop and pattern-matches results against the Test Packet's pass/fail conditions. Mechanical failures (syntax, imports, typos) get 1 self-fix attempt. Behavioral failures (logic, data flow, contract violations) get zero — Codex files a structured Failure Report and the user takes it to Claude for a Fix Plan. After a step passes, MCP is locked — the user does visual checks and only re-enables MCP testing by explicit request.
- **Prove** — The user runs golden tests in Studio (this pass + all previous = regression check) and reports results. Codex cleans up AI build prints, writes a build delta (what actually changed vs the design), commits, pushes, and hands off to Claude to design the next pass.

### Ship
When all passes are proven. Final critic review on the full codebase.

## Why It's Cyclic

Building the entire system from one massive architecture (waterfall) fails because the architecture is designed against specs, not against working code. By the time you build module 10, modules 1-9 behave differently than the spec predicted. Bugs compound and become irreversible.

The cyclic approach designs each pass against real, tested code from previous passes. Each pass is small enough to prove correct before moving on. If something breaks, the blast radius is one pass, not the whole system.

## Key Concepts

- **Architecture-as-contract:** Codex always builds from a validated design doc, never from vibes or verbal instructions.
- **Handoff prompts:** Each AI produces a copy-pasteable message for the other AI. The user just copies and pastes. No manual orchestration.
- **Build deltas:** After each pass, Codex documents what actually changed vs what was designed. Claude reads these before designing the next pass.
- **Golden tests:** Specific test scenarios with exact expected outcomes. They accumulate across passes and serve as regression tests.
- **Diagnostics module:** Built-in logging (lifecycle reason codes, health counters, per-entity trails). Makes debugging evidence-based instead of speculative.
- **Startup validators:** Check workspace contracts at server start, fail loud if something's wrong.
- **Config extraction:** Every tunable value in a config file. User adjusts these directly without AI tokens.
- **Mechanical vs behavioral failures:** Mechanical errors (syntax, imports, typos) get 1 Codex self-fix attempt. Behavioral errors (logic, data flow, contracts) escalate immediately — Codex files a Build Failure Report, Claude writes a Fix Plan. Both use structured templates.
- **Test Packet:** Each design doc includes a Test Packet — AI build prints, exact pass/fail conditions, and MCP procedure. Codex pattern-matches against these. It does not interpret results or invent tests.
- **MCP testing (gated):** Codex connects to Roblox Studio through the `robloxstudio-mcp` server. MCP testing is allowed during the initial build loop (verifying new code works). After that, MCP is locked — the user tests in Studio and only re-enables MCP by explicitly saying "test it" or reporting an error. This keeps token usage under control while still giving Codex eyes during the critical first build.
- **AI build prints:** Temporary, structured print statements (`[TAG] key=value`) specified in the Test Packet. Codex adds exactly what the design doc says — it does not invent additional probes or harnesses. Removed after each pass is proven. Separate from permanent human-focused diagnostics.
- **Critic reviews are periodic, NOT per-pass.** Full critic review on the entire codebase every 3-5 passes. Between reviews, the pipeline relies on golden tests, diagnostics, and the integration pass in the design step. Do not run a critic review every single pass — it wastes tokens without proportional value.

## File Layout

```
CLAUDE.md                       # Claude's rules (re-read every handoff)
codex-instructions.md           # Codex's rules (re-read every handoff)
ACTION-MAP.md                   # Human user's workflow reference
pipeline/
├── overview.md                 # This file (read once)
├── idea.md                     # Idea stage instructions
├── roadmap.md                  # Roadmap stage instructions
├── design.md                   # Design step instructions (per pass)
├── build.md                    # Build step instructions (per pass)
├── prove.md                    # Prove step instructions (per pass)
├── checklists/
│   └── critic-checklist.md     # Critic review rubric
└── templates/                  # Templates for project files
projects/<name>/
├── state.md                    # Current position + build deltas
├── idea-locked.md              # Locked idea
├── feature-passes.md           # Ordered pass roadmap
├── pass-N-design.md            # Design doc per pass
├── golden-tests.md             # Accumulating test scenarios
├── build-notes.md              # Final ship output
└── src/                        # The codebase
```
