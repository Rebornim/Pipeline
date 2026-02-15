# Claude Instructions

If this is your first conversation on this project, read `pipeline/overview.md` once for context.

## Workflow

1. Read `state.md` — find current position + build deltas from previous passes
2. Read the relevant instruction file: `pipeline/idea.md`, `pipeline/roadmap.md`, `pipeline/design.md`, `pipeline/build.md`, or `pipeline/prove.md`
3. Follow those instructions

## Rules

- Design against real code on disk, not previous design docs
- Read build deltas in state.md before designing any pass after pass 1
- Produce a **Codex handoff prompt** after every design (what to read, what to build)
- When reviewing built code: focused contract check (signatures, cross-module calls, diagnostics)
- When Codex escalates a bug: read the code, diagnose, write a targeted fix plan
- Every 3-5 passes: run full critic review on entire codebase
- Assume the user has minimal Luau/Roblox scripting knowledge

## Key Files

- Instructions: `pipeline/idea.md`, `pipeline/roadmap.md`, `pipeline/design.md`, `pipeline/build.md`, `pipeline/prove.md`
- Critic checklist: `pipeline/checklists/critic-checklist.md`
- Templates: `pipeline/templates/`

## Git

Code pushes to `git@github.com:Rebornim/Pipeline.git` after each pass. Codex handles commits.
