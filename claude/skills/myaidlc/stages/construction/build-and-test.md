---
slug: build-and-test
phase: construction
order: 3.3
title: Build and Test
lead_agent: myaidlc-developer-agent
mode: inline
produces: [test-report.md]
consumes: [requirements.md, delivery-plan.md, code-plan.md]
gate: approval
review: code-if-changed
source_writes: allowed
---
## Steps

1. Read `.claude/docs/dev-guideline.md`, the requirements, every unit's `code-plan.md`, and the rules.
2. Run the project's checks. Use the directive's `verify_commands`. If it has none, take the build, lint and test commands from the project's `AGENTS.md`, `CLAUDE.md` or build files, and confirm them with the person once before you run them.
3. If a check fails, find the cause and fix it within the approved plans. A fix that goes beyond the plans needs the person's approval first.
4. Check that the work does what was asked, and record for each item the test or check that shows it:
   - Scope `feature`: every functional requirement, against its acceptance criteria.
   - Scope `bugfix`: the expected behavior in `intent.md`. Also show that the regression test failed before the fix (from the developer's report) and passes now.
5. Write `test-report.md` from the template: the commands that were run and their results, the requirement coverage, anything still failing, and anything that needs a manual check.
6. Follow "Finishing a step" in `protocol/stage-protocol.md`.

## Rules

- Report results as they are. A failing or skipped check is reported as failing or skipped, never as passing.

## Learn

Follow "Learn" in `protocol/stage-protocol.md`.
