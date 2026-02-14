# Roadmap

## What You're Doing

Dividing the locked idea into ordered feature passes. Each pass is a self-contained layer of functionality that gets designed, built, and proven before the next one starts.

## Input

Read `projects/<name>/idea-locked.md`. That's everything the system needs to do.

## Process

1. **Identify the bare bones.** What is the absolute minimum system that demonstrates the core loop working end-to-end? No polish, no secondary features, no optimization. Just: does the fundamental thing work? This is always Pass 1.

2. **Group remaining features into passes.** Each pass should be:
   - A coherent chunk of related functionality (not random features stapled together)
   - Buildable on top of previous passes (dependencies flow forward)
   - Small enough to design, build, and prove in one cycle
   - Testable — you can write golden test scenarios for it

3. **Optimizations are always last.** LOD, pooling, culling, caching — these are final pass(es). They layer on top of proven core behavior.

4. **Write the roadmap.** Use the template at `pipeline/templates/feature-passes.md`.

5. **Review with user.** The user should agree with how features are divided and ordered. They may want to reprioritize — that's fine.

6. Update `projects/<name>/state.md`: Stage → Pass 1 Design, Status → ready

## Principles

- **Pass 1 must be ruthlessly minimal.** Every feature you add to pass 1 is a feature you're debugging without the benefit of a proven foundation. The less pass 1 does, the faster you get to a working system.
- **Each pass builds on proven code.** When you design pass 3, passes 1-2 are already built and tested. The architecture for pass 3 is written against real code, not specs.
- **Passes are not set in stone.** If during pass 3's design you realize the roadmap needs adjusting, adjust it. Update feature-passes.md.
- **A pass is not a single module.** A pass is a feature or behavior — it might touch multiple modules. "Add POI visits" might modify RouteBuilder, add NPCAnimator, and update Config.

## Exit Criteria

- [ ] All features from idea-locked.md are assigned to a pass
- [ ] Pass 1 is bare bones — minimum viable core loop
- [ ] Passes are ordered by dependency (each builds on previous)
- [ ] Optimizations are in the last pass(es)
- [ ] Each pass has a plain-language description of what the system does after it's complete
- [ ] User approves the roadmap

## Output

`projects/<name>/feature-passes.md`
