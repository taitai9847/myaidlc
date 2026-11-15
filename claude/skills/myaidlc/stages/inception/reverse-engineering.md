---
slug: reverse-engineering
phase: inception
order: 2.1
title: Reverse Engineering
lead_agent: myaidlc-architect-agent
mode: inline
produces: [codemap.md]
consumes: [intent.md]
gate: none
review: phase-doc
---
## Steps

1. Read `intent.md` and the rules.
2. From the intent, list the likely entry points: the words, features, routes, commands, screens, or error messages it names. If the project's `AGENTS.md` describes the layout, use it.
3. Read the code as described in "Reading code" in `protocol/stage-protocol.md`: Explore with `model: "haiku"` and thoroughness medium, only around those entry points. If the work touches areas that do not depend on each other, start one Explore for each area in parallel.
4. Write `codemap.md` from the template. Record only what Explore found, with file paths, and mark what it did not confirm as open:
   - the files in the area and what each one does
   - how the packages or modules depend on each other, both what this area uses and what uses it
   - entry points, and the places a change would most likely go
   - where the tests are, how they run, and the conventions of the surrounding code (naming, errors, structure)
   - scope `bugfix`: the likely cause, with the code path from the trigger to the failure
5. Follow "Finishing a step" in `protocol/stage-protocol.md`. This step has no approval of its own; the next approval covers its facts.

## Rules

- Never read the whole repository. Widen the search only when a dependency of the area needs it, and say in the map why it was widened.
- Do not propose a design here. The map records what exists.

## Learn

Follow "Learn" in `protocol/stage-protocol.md`.
