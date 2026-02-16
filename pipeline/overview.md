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
- **Build** — Codex implements from the design doc. Codex tests automatically via MCP (start playtest, read logs, fix). User does a final visual check. If Codex can't fix after 3 test-fix cycles, Claude writes a fix plan.
- **Prove** — All golden tests pass (this pass + all previous = regression check). Codex writes a build delta (what actually changed vs the design), commits, pushes, and produces a handoff prompt for Claude.

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
- **Bug escalation:** Codex defers to Claude after 3 failed test-fix cycles. Claude writes a structural fix plan.
- **Automated testing via MCP:** Codex connects to Roblox Studio through the `robloxstudio-mcp` server. It can start/stop playtests and read all output logs without the user touching anything. The user only steps in for visual/behavioral judgment.
- **AI build prints:** Temporary, structured print statements (`[TAG] key=value`) that let Codex "see" what the code does at runtime by reading logs. These are AI-focused, non-spammy, and get removed after each pass is proven. Separate from permanent human-focused diagnostics.
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
