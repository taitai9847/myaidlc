---
slug: intent-capture
phase: ideation
order: 1.1
title: Intent Capture
lead_agent: myaidlc-product-agent
mode: inline
produces: [intent.md]
consumes: []
gate: approval
review: phase-doc
---
## Steps

1. Read `request.md` from the directive's `consumes`, and the rules in the directive's `rules`.
2. Work out what the person wants. Separate what they said from what you are assuming.
3. If something only the person can decide is unclear (who it is for, what "done" looks like, what is out of scope), ask it as described in "Questions" in `protocol/stage-protocol.md`. Ask only what changes the outcome; do not ask what the request already answers.
4. Write `intent.md` from the template in the directive's `produces`. Keep it short: an intent is a statement of the goal, not a specification.
   - Scope `bugfix`: the symptom, the steps to reproduce it, what should happen instead, and how often or for whom it happens. Mark the steps to reproduce "unconfirmed" if you have not been able to confirm them.
   - Scope `small`: "What done looks like" is the acceptance check for the change, so write each item so a test or a command can show it.
5. Follow "Finishing a step" in `protocol/stage-protocol.md`.

## Rules

- Do not read the code yet. The code is read in Reverse Engineering, scoped by this intent.
- Write the person's goal in their terms. Do not turn it into a solution here.

## Learn

Follow "Learn" in `protocol/stage-protocol.md`.
