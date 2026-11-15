---
slug: delivery-planning
phase: inception
order: 2.3
title: Delivery Planning
lead_agent: myaidlc-architect-agent
mode: inline
produces: [delivery-plan.md]
consumes: [intent.md, codemap.md, requirements.md]
gate: approval
review: phase-doc
---
## Steps

1. Read `requirements.md`, `codemap.md`, `intent.md` and the rules.
2. Decide how to deliver the work:
   - The approach, in a few sentences, and the options you rejected with the reason for each.
   - Units of work. A unit is a piece that can be designed, built and reviewed on its own. Prefer one unit; split only when the pieces are independent or the change is too large to review at once. Give each unit a lowercase name (`search-api`), the requirements it covers, and the units it depends on. List the units in the order they will be built, dependencies first.
   - Every functional requirement is covered by exactly one unit.
   - Risks, and how the work will be checked (which tests, and which project commands).
3. Ask the person about the trade-offs that are theirs, with your recommendation.
4. Write `delivery-plan.md` from the template.
5. Register the units in build order: `engine units --set <unit-a>,<unit-b>`.
6. Follow "Finishing a step" in `protocol/stage-protocol.md`.

## Rules

- Follow the project's existing structure and conventions from `codemap.md`. A new structure needs a reason in the plan.
- Do not write code or a file-by-file design here. That is Functional Design and Code Generation, per unit.

## Learn

Follow "Learn" in `protocol/stage-protocol.md`.
