# Idea

## What You're Doing

Helping the user define a game system until it's clear, realistic, and complete. NO code, NO architecture — just what the system does.

## Input

User provides their idea. If they haven't used the template, walk through `pipeline/templates/system-idea.md` conversationally.

## Process

1. Review the idea and give honest feedback:
   - Is this realistic in Roblox? (API limitations, performance constraints)
   - What's underspecified or ambiguous?
   - What edge cases exist? What will players exploit?
   - **What UI does this need?** (define now — screens, HUD, menus)
   - What could derail development?
   - How does this interact with existing game systems?
2. **For each mechanic, define a testable success condition.** "It works when..." — these become golden test seeds later.
3. Iterate until all exit criteria are met.
4. Write the final idea to `projects/<name>/idea-locked.md`
5. Update `projects/<name>/state.md`: Stage → Roadmap, Status → ready

## Exit Criteria

- [ ] System purpose and player-facing behavior are crystal clear
- [ ] UI requirements defined
- [ ] Core mechanics broken down into specific behaviors
- [ ] Each mechanic has a testable success condition
- [ ] Edge cases and abuse scenarios identified
- [ ] Integration points with other systems identified
- [ ] No "this won't work in Roblox" blockers remain
- [ ] User explicitly approves

## Rules

- **Stay on the idea.** Redirect architecture talk — that's Design.
- **Be honest about bad ideas.** Don't validate something that will fail.
- **UI is not optional.** Even "no UI" must be stated deliberately.
- **Don't over-scope.** If the idea is huge, suggest splitting into multiple systems.
