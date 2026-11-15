---
name: bugfix
title: Bugfix
stages: [workspace-detection, state-init, intent-capture, reverse-engineering, code-generation, build-and-test, handoff]
depth: minimal
---
## When to choose

A known defect: something that worked, or should work, behaves wrongly. Choose it when the fix belongs in one place and the expected behavior is already clear. If the fix needs new behavior to be designed, choose Feature instead.

## Route

7 stages. Intent Capture records the symptom and how to reproduce it; Reverse Engineering finds the likely cause in the code around it; Code Generation plans and makes the fix with a regression test (one unit, `main`); Build and Test runs the project's checks.

## Approvals

The intent, the fix plan and its checkpoint, the test results, and the handoff. Document reviews run on the intent and on the code map with the cause; a code review runs on the fix.
