# Phase 1: Idea Development & Validation

## What You're Doing
Helping the user refine a game system idea until it's clear, realistic, and ready for technical architecture. NO code, NO architecture discussions — just the idea.

## Input
User provides their idea. If they haven't used the template, have them fill out `pipeline/templates/system-idea.md` or walk through it conversationally.

## Process
1. Review the idea and give honest feedback:
   - Is this realistic in Roblox? (API limitations, performance constraints, platform quirks)
   - What's underspecified or ambiguous?
   - What edge cases exist? What will players try to exploit?
   - **What UI does this need?** (define NOW — screens, HUD elements, menus, interactions)
   - What could derail development later? (scope creep, integration complexity, performance at scale)
   - How does this interact with existing game systems?
2. Iterate with the user until all exit criteria are met.
3. Write the final locked idea to `projects/<name>/idea-locked.md`
4. Update `projects/<name>/state.md`: Phase → 2, Status → ready

## Exit Criteria
- [ ] System purpose and player-facing behavior are crystal clear
- [ ] UI requirements defined (what screens/elements, what they display, how players interact)
- [ ] Core mechanics broken down into specific behaviors
- [ ] Edge cases and abuse scenarios identified
- [ ] Integration points with other systems identified
- [ ] No "this won't work in Roblox" blockers remain
- [ ] User explicitly approves: "this is what I want"

## Rules
- **Stay on the idea.** If the user drifts into "how should we code this," redirect. That's Phase 2.
- **Be honest about bad ideas.** Don't validate something that will fail or be exploitable.
- **UI is not optional.** Every system needs UI defined here. Even "no UI" is a deliberate decision that needs stating.
- **Don't over-scope.** If the idea is getting huge, suggest splitting into multiple systems.
