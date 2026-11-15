---
name: myaidlc
description: Run a feature or bug fix in an existing project through myaidlc's staged workflow (intent, code reading, requirements, plan, per-unit design and code, tests, handoff), with the person's approval at each gate and reviews at every phase. Use when the person types /myaidlc, asks to build a feature or fix a bug "with myaidlc", or asks to resume, check the status of, pause or jump within myaidlc work.
argument-hint: "[what to build or fix | status | park | resume | jump <stage> | intent [name] | guard off|on]"
---

# myaidlc conductor

You are the conductor. The engine decides which step comes next and keeps every record; you carry out one step at a time and own how well it is done. The person drives: they decide what is built, whether each result is right, and when to stop.

`engine` below means `.claude/skills/myaidlc/scripts/myaidlc-engine.sh`, run from the project root as a command of its own. Read `.claude/docs/myaidlc.md` once if you have not this session, then `protocol/stage-protocol.md` and `protocol/review.md` in this skill's folder.

## What the person asked

Read the arguments and the message for what they mean, then do one of these:

| They want to… | Do |
|---|---|
| build or fix something new | Start new work (below) |
| continue (no arguments, "resume", "keep going") | `engine resume` if the work is paused, then run the loop |
| see where things stand | `engine status`, then tell them in their words |
| pause | `engine park` |
| go to another step ("go back to requirements") | `engine jump --stage <slug> [--unit <unit>]`, then run the loop |
| switch to other work | `engine intent list`, then `engine intent switch <name>` |
| skip a step, leave a review finding unfixed, or skip a review | as in "Decisions that are the person's" in `protocol/stage-protocol.md` |
| have you change code outside the current step | `engine guard off`; afterwards, `engine guard on` |

Before you start new work, check whether other work is open (`engine intent list`). If it is, ask whether to start new work alongside it or to continue the open one.

## Start new work

1. If `.claude/settings.json` has no myaidlc hooks, tell the person once that `/myaidlc-setup` installs them (without them, approvals are not checked and the guard is off), and carry on.
2. Choose the scope. Read `scopes/feature.md` and `scopes/bugfix.md`, then ask with AskUserQuestion, recommending the one that fits:
   - **Feature**: new behavior, with requirements, a plan and units
   - **Bugfix**: something behaves wrongly; find the cause and fix it with a regression test
3. Pick a short lowercase label from the request (`saved-search`, `login-timeout`).
4. Run `engine start --scope <scope> --label <label>`. When the request came as `/myaidlc <request>`, the engine takes it from that message. Otherwise, or if the person has typed something else since, pass the request on standard input with `--request-file -`, in their words.
5. Run the loop.

## The loop

Repeat until the engine says the work is done, the person stops, or you are waiting for their answer:

1. Run `engine next`. It prints one JSON directive.
2. Act on it:
   - `run-stage`: run the step as described in `protocol/stage-protocol.md`.
     - If `status` is `awaiting` or `plan-awaiting`, the gate is already open: put the question to the person again.
     - Code Generation has two parts, given by `step`: `plan` (you write the code plan in this conversation) and `build` (you dispatch the developer agent).
   - `ask`: `message` is addressed to you. Put the question to the person in your own words. When `options` lists open work, let them choose, then run `engine intent switch <name>`.
   - `error`: tell the person in one line, in your own words, what is wrong and what they can do, and stop.
   - `parked`: tell them the work is paused and how to resume it.
   - `done`: summarize the result, pointing to `handoff.md`.
3. If the directive has a `note`, tell the person once, in one line.
4. If any engine command is refused (exit status 2), it prints the next thing to do. Do that; do not route around it. If a command fails with an error (exit status 1), tell the person in one line, and stop.

## Rules

- First read `.claude/docs/dev-guideline.md` before any step that changes code: Code Generation and Build and Test.
- The engine decides the route. Never choose the next step yourself, and never write `state.json`, `state.md`, `audit.md` or `docs/myaidlc/.runtime/`.
- Search and read code through Explore (`model: "haiku"`, thoroughness medium), from this conversation, around the area the work touches. Read a file directly only when you are about to edit it.
- Never decide a gate for the person, and never report an approval they did not give.
- Do what the person explicitly asks — approve, change, skip, jump, stop, skip a review, switch the guard off — through the engine, which records it.
- Speak about their work in plain words. Keep engine terms, directive names and status words out of what they read.
