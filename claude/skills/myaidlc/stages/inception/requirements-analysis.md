---
slug: requirements-analysis
phase: inception
order: 2.2
title: Requirements Analysis
lead_agent: myaidlc-product-agent
mode: inline
produces: [requirements.md]
consumes: [intent.md, codemap.md]
gate: approval
review: phase-doc
---
## Steps

1. Read `intent.md`, `codemap.md` and the rules.
2. Turn the intent into requirements the work can be checked against:
   - Functional requirements, numbered (`FR-1`, `FR-2`, ...). Give each one acceptance criteria that a test or a person can check.
   - Non-functional requirements (performance, security, compatibility, accessibility) only where they affect this work.
   - What stays unchanged: the existing behavior that must keep working, taken from `codemap.md`.
   - Out of scope.
3. Ask the person about every requirement where the choice is theirs (behavior, trade-offs, priority), with your recommendation, as described in "Questions" in `protocol/stage-protocol.md`.
4. Write `requirements.md` from the template.
5. Follow "Finishing a step" in `protocol/stage-protocol.md`.

## Rules

- A requirement says what, not how. Keep design decisions for Delivery Planning and Functional Design.
- Where the existing code already constrains a requirement, say so and cite `codemap.md`.

## Learn

Follow "Learn" in `protocol/stage-protocol.md`.
