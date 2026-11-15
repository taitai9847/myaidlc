---
slug: code-generation
phase: construction
order: 3.2
title: Code Generation
lead_agent: myaidlc-developer-agent
mode: subagent
for_each: unit
produces: [code-plan.md]
consumes: [codemap.md, requirements.md, delivery-plan.md, functional-design.md]
gate: plan-and-checkpoint
review: plan-and-code
source_writes: after-plan-approval
---
## Steps

First read `.claude/docs/dev-guideline.md`. Then follow the part for the directive's `step`.

### Step `plan`: the code plan

The conductor does this part in the main conversation, as the developer.

1. Read the unit's `functional-design.md` (scope `feature`) or `codemap.md` and `intent.md` (scope `bugfix`), plus the requirements and the rules.
2. Write `code-plan.md` from the template: the files to create or change, in order, with what changes in each; the tests to add or change; and the commands that will check the work.
   - Scope `bugfix`: the confirmed cause, how to reproduce the bug, and a regression test that fails before the fix and passes after it. These are required.
3. Follow "Finishing a step" in `protocol/stage-protocol.md`. The gate here is the plan approval (`plan-ready`). Product code stays locked until the person approves.

### Step `build`: the code

1. Before you dispatch, read any code the developer will need that the documents do not describe, as described in "Reading code" in `protocol/stage-protocol.md`.
2. Dispatch `myaidlc-developer-agent` (mode `subagent`) as described in "Subagent steps" in `protocol/stage-protocol.md`. Give it the approved `code-plan.md`, `functional-design.md`, the requirements, `codemap.md`, the Explore results, the rules, and `verify_commands`.
3. When it returns, check its report against the plan. If it stopped on a blocker, take that to the person.
4. Follow "Finishing a step" in `protocol/stage-protocol.md`. The gate here is the unit checkpoint (`awaiting`). Show what was built, the tests and their results, and anything that differs from the plan.

## Rules

- Change only what the approved plan names. If the plan turns out to be wrong, stop and follow "Decisions that are the person's" in `protocol/stage-protocol.md`; do not improvise.
- New behavior comes with tests. Never weaken or skip a test to make it pass.

## Learn

Follow "Learn" in `protocol/stage-protocol.md`.
