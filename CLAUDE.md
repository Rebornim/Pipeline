# Claude Instructions

If this is your first conversation on this project, read `pipeline/overview.md` once for context.

## Workflow

1. Read `state.md` — find current position + build deltas from previous passes
2. Read the relevant instruction file: `pipeline/idea.md`, `pipeline/roadmap.md`, `pipeline/design.md`, `pipeline/build.md`, or `pipeline/prove.md`
3. Follow those instructions

## Rules

- Design against real code on disk, not previous design docs
- Read build deltas in state.md before designing any pass after pass 1
- When reviewing built code: focused contract check (signatures, cross-module calls, diagnostics)
- When Codex escalates a bug: read the code, diagnose, write a targeted fix plan
- Every 3-5 passes: run full critic review on entire codebase
- Assume the user has minimal Luau/Roblox scripting knowledge

## Design Considerations

When designing passes, consider these in addition to the standard design process:
- **AI build prints:** Specify which `[PN_TEST]` prints Codex needs for automated MCP testing. Be specific about tags, data, markers, and summary lines. Codex is blind — these prints are its only eyes during testing.
- **Startup telemetry:** For systems with initialization sequences, include a toggleable startup timing probe (begin/end timestamps, first spawn, first client visualization).
- **Golden test fixtures:** Specify exact folder/part naming conventions, allowed alternates, and examples for complex setups (e.g., multi-entrance POIs).
- **Known operational pitfalls:** If the system has non-obvious runtime behaviors (sync delays, LOD far-tier invisibility, fire-and-forget RemoteEvent timing), document them in the pass design so Codex doesn't waste test cycles diagnosing expected behavior.

## Handoff Prompts

Handoff prompts MUST be file pointers only. Do NOT summarize, explain, or include information in the prompt itself. The receiving AI reads the files — that's where the information lives.

**Format — always this, nothing more:**
```
Read: [file1], [file2], [file3]. Then read code in [path]. Do [action].
```

**Example Codex handoff (from Claude after design):**
```
Read: codex-instructions.md, projects/wandering-props/state.md, projects/wandering-props/pass-3-design.md. Then read code in projects/wandering-props/src/. Build pass 3.
```

**Example Claude handoff (from Codex after build):**
```
Read: CLAUDE.md, projects/wandering-props/state.md. Then read code in projects/wandering-props/src/. Prove pass 3.
```

No summaries. No context. No "this pass added X and Y." Just files and action.

## Key Files

- Instructions: `pipeline/idea.md`, `pipeline/roadmap.md`, `pipeline/design.md`, `pipeline/build.md`, `pipeline/prove.md`
- Critic checklist: `pipeline/checklists/critic-checklist.md`
- Templates: `pipeline/templates/`

## Git

Code pushes to `git@github.com:Rebornim/Pipeline.git` after each pass. Codex handles commits.
