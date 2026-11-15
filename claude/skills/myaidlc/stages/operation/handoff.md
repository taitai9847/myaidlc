---
slug: handoff
phase: operation
order: 4.1
title: Handoff
lead_agent: myaidlc-product-agent
mode: inline
produces: [handoff.md]
consumes: [intent.md, requirements.md, delivery-plan.md, code-plan.md, test-report.md]
gate: approval
review: none
---
## Steps

1. Read the work's documents in `consumes` and the rules.
2. Write `handoff.md` from the template, for whoever reviews, merges or releases this change:
   - what changed and why, in a few sentences
   - the files changed, grouped by unit. To list them, run `git diff --stat <Start Commit>` with the start commit from `state.md`, and `git status --short` for new files.
   - how it was checked (from `test-report.md`)
   - what is left: open review findings, manual checks, follow-up work, and known limits
   - how to release or deploy it, and how to roll it back, as far as the project's own process says. Do not invent a process the project does not have.
3. Follow "Finishing a step" in `protocol/stage-protocol.md`. Do not commit, push, open a pull request or deploy unless the person asks.

## Rules

- This step only describes the change. It does not change code.

## Learn

Follow "Learn" in `protocol/stage-protocol.md`.
