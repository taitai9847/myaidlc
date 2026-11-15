---
slug: functional-design
phase: construction
order: 3.1
title: Functional Design
lead_agent: myaidlc-architect-agent
mode: inline
for_each: unit
produces: [functional-design.md]
consumes: [codemap.md, requirements.md, delivery-plan.md]
gate: none
review: none
---
## Steps

1. Read the unit's part of `delivery-plan.md`, the requirements it covers, `codemap.md` and the rules.
2. If the design needs code that `codemap.md` does not describe, read it as described in "Reading code" in `protocol/stage-protocol.md`.
3. Write `functional-design.md` for this unit from the template:
   - the components, files and interfaces it adds or changes, and how data flows between them
   - the behavior for each requirement it covers, including errors and edge cases
   - how it fits the existing code: which conventions it follows, and what it must not break
   - the tests that will show each requirement is met
4. Follow "Finishing a step" in `protocol/stage-protocol.md`. This step has no approval of its own; the design is approved with the code plan in Code Generation.

## Rules

- Design only this unit. Note anything another unit needs instead of designing it here.

## Learn

Follow "Learn" in `protocol/stage-protocol.md`.
