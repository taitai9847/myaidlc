---
name: small
title: Small change
stages: [workspace-detection, state-init, intent-capture, reverse-engineering, code-generation, build-and-test, handoff]
depth: minimal
---
## When to choose

A small, well-understood change to how the project already behaves: a rename, a wording or default change, a new option on an existing command, a small validation. Choose it when the change fits in one place, what "done" looks like can be said in a few lines, and no new behavior needs to be designed. If it needs requirements or a split into units, choose Feature; if something behaves wrongly, choose Bugfix.

## Route

7 stages, the same as Bugfix. Intent Capture records the change and what done looks like; Reverse Engineering maps where the change goes; Code Generation plans and makes it with tests (one unit, `main`); Build and Test runs the project's checks.

## Approvals

The intent, the code plan and its checkpoint, the test results, and the handoff. Document reviews run on the intent and the code map, and on the code plan; a code review runs on the change.
