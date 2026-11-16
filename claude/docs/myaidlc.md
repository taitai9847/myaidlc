# myaidlc

myaidlc runs new features and bug fixes in an existing project as a staged workflow. The person drives it: they say what to build, approve each result, and decide when to stop. It is a minimal take on AI-DLC (AI-Driven Development Life Cycle) for work on code that already exists, and it assumes no particular language, framework, or branching model.

Spec version: 2

## Principles, in order: the first wins any conflict

1. **The human drives the engine.**
   - The person decides what is built, whether each result is right, what to trade off, and when to stop.
   - An explicit request (approve, change, skip, jump, stop, skip a review, switch the guard off) is carried out and recorded once the person's reply is on record. It is never refused for what it asks. The only thing refused is harm that cannot be undone and that the person did not ask for.
   - Reading what the person meant is the agent's job. A tool never judges the meaning of their words.
2. **Tools for determinism.** Bookkeeping is done by the engine and its hooks, the same way every time:
   - which step is next
   - every change of state
   - what was approved, and when
   - the audit trail
   - review records
   - the code guard
   - the list of changed files

   The agent never does this bookkeeping itself, so its instructions stay about the work.
3. **LLM for knowledge.** The agent brings what the person may not know: the code, design, testing, the tools. It makes the calls that knowledge settles. When a choice is the person's, it asks plainly, with the options, what each means for them, and its recommendation.
4. **Human for judgement.** Nothing that a tool or knowledge can settle is put to the person.

And:
- **One owner per rule.** Each rule (the transitions, the gates, the reviews, the guard) is checked in one place in the engine.
- **Guards act on the agent, not on the person.** A guard checks recorded facts about what the agent is about to do. When it refuses, it names the next step, and the person's request lifts it, with the lift recorded.
- **Lost bookkeeping falls back to the person's last instruction.** When the engine cannot check something (for example, the hooks are not installed), it says so in one line and stands aside. It never loops or asks again.
- **The person reads about their work.** They see what happened, where it stands, what they need to decide, and how to undo it, never the engine's internals.
- **Guards are not a security boundary.** A shell command can write past the guard. Permissions are the harness's job.

## Engine and conductor

```
person ── /myaidlc ──▶ conductor (skills/myaidlc/SKILL.md, the LLM)
                         1. engine next      → one directive (JSON)
                         2. carry out that one step
                         3. engine report    → the engine updates the state and the audit trail
                         ▼
                       engine (skills/myaidlc/scripts/myaidlc-engine.sh, bash + jq)
```

- The conductor never chooses the route. It owns how well each step is done.
- Agents never call each other. Only the conductor hands out work, and only the conductor starts Explore searches and reviewers.

## Phases, stages and agents

A **scope** is a production line: the stages a kind of work goes through. A **stage** is a station on that line. An **agent** is the worker at the station.

| # | Phase | Stage | Agent | Output | Gate | Review |
|---|---|---|---|---|---|---|
| 0.1 | Initialization | workspace-detection | engine | state | none (run by `start`) | — |
| 0.2 | Initialization | state-init | engine | state, audit, request | none (run by `start`) | — |
| 1.1 | Ideation | intent-capture | product | intent.md | approval | end of phase |
| 2.1 | Inception | reverse-engineering | architect | codemap.md | none | end of phase |
| 2.2 | Inception | requirements-analysis | product | requirements.md | approval | end of phase |
| 2.3 | Inception | delivery-planning | architect | delivery-plan.md | approval | end of phase |
| 3.1 | Construction | functional-design (per unit) | architect | functional-design.md | none | — |
| 3.2 | Construction | code-generation (per unit) | developer | code-plan.md + code | plan approval + unit checkpoint | doc on the plan, code on the change |
| 3.3 | Construction | build-and-test | developer | test-report.md | approval | code, if it changed code |
| 4.1 | Operation | handoff | product | handoff.md | approval | — |

| Scope | Stages | Depth | For |
|---|---|---|---|
| `feature` | all 10 | standard | new behavior in an existing project |
| `small` | 0.1, 0.2, 1.1, 2.1, 3.2, 3.3, 4.1 | minimal | a small change to existing behavior that fits in one place; one unit, `main` |
| `bugfix` | 0.1, 0.2, 1.1, 2.1, 3.2, 3.3, 4.1 | minimal | a known defect; one unit, `main`, with a regression test |

- **"End of phase"**: the engine requires the review at the last stage of that phase in the active scope. That is delivery-planning in `feature` and reverse-engineering in `small` and `bugfix`. The review covers every document of the phase.
- **Construction is unit-major**: each unit goes through functional-design and code-generation before the next unit starts, and build-and-test runs once after all units. When no units are planned, the engine uses a single unit, `main`.

### Stage files

`stages/<phase>/<slug>.md`. The frontmatter is the graph, read by the engine; the body is the work, read by the agent. The frontmatter allows only `key: value` and `key: [a, b]`.

| Key | Values |
|---|---|
| `slug`, `phase`, `order` | must match the file name, the folder, and `<phase number>.<n>` |
| `lead_agent` | an agent in `agents/`, or `engine` |
| `mode` | `inline` (the conductor works as the agent), `subagent` (dispatched; Code Generation's build step) |
| `for_each` | `unit`, or empty |
| `produces`, `consumes` | artifact file names. A consume is read when its producer is in the scope and the file exists |
| `gate` | `none`, `approval`, `plan-and-checkpoint` |
| `review` | `none`, `phase-doc`, `plan-and-code`, `code-if-changed` |
| `source_writes` | `blocked` (default), `after-plan-approval`, `allowed` |

The body has three sections: `## Steps`, `## Rules`, `## Learn`. `engine check` validates all of this, and also that every output has a template.

## Records: `docs/myaidlc/`

```
docs/myaidlc/
├── config.json                # guard, default scope, verify_commands
├── memory/
│   ├── project.md             # project rules (learned rules are added here)
│   ├── phases/<phase>.md      # rules for one phase
│   └── templates/<file>.md    # replaces the default template of that output
├── intents/<YYMMDD>-<label>/  # one piece of work
│   ├── state.json             # the state (engine only)
│   ├── state.md               # the state, readable (engine only, regenerated)
│   ├── audit.md               # the audit trail (engine only, append-only)
│   ├── request.md             # the request as typed, with secrets masked
│   └── <phase>/<stage>/…, construction/<unit>/<stage>/…
└── .runtime/                  # this machine only, git-ignored: active work, last reply, lock
```

Commit `docs/myaidlc/`, except `.runtime/`. If `docs/` is published as a site, exclude `docs/myaidlc/` from it.

### State

Each step shows one of six boxes: `[ ]` not started, `[-]` in progress, `[?]` waiting for the person (approval, or approval of the code plan), `[R]` being revised after their feedback, `[x]` completed, `[S]` skipped. A stage outside the scope is listed as "not in scope".

Each phase is `Pending`, `Active`, `Verified` (every step done or skipped), or `Skipped` (no step in scope).

### Audit trail

Each event is one Markdown block, separated by `---`. A block holds a sequence number, a timestamp, the event name, and its fields. The person's words are recorded as `Person Reply`, with secrets masked.

- Workflow: `WORKFLOW_STARTED`, `WORKFLOW_PARKED`, `WORKFLOW_RESUMED`, `WORKFLOW_COMPLETED`
- Initialization and phases: `WORKSPACE_DETECTED`, `PHASE_STARTED`, `PHASE_VERIFIED`
- Stage: `STAGE_STARTED`, `STAGE_AWAITING_APPROVAL`, `STAGE_REVISING`, `STAGE_COMPLETED`, `STAGE_SKIPPED`, `STAGE_JUMPED`, `STAGE_REOPENED`
- Decisions: `PLAN_APPROVAL_RECORDED`, `GATE_APPROVED`, `GATE_REJECTED`, `HUMAN_TURN`, `QUESTION_REPLIED`
- Reviews: `REVIEW_COMPLETED`, `REVIEW_SKIPPED`
- Work items: `UNITS_SET`, `ARTIFACT_CREATED`, `ARTIFACT_UPDATED`, `RULE_LEARNED`
- Guard: `GUARD_BLOCKED`, `GUARD_STOOD_ASIDE`, `GUARD_RESTORED`

## Gates and approval evidence

- The hooks count every message the person types and every answer they give in a question box, in `state.json`. A bare `/myaidlc`, `/myaidlc status` or `/myaidlc resume` is not counted.
- Every step the agent drives records that count: starting a step, opening or reopening a gate, completing a step, recording a review, and setting units.
- A decision that is the person's is accepted only if they replied after the agent's last step. That covers approving, rejecting, skipping a step, declining a finding, skipping a review, switching the guard off, and jumping. Each reply carries one decision. Pausing is not checked, because it only stops the work. Because the count is in `state.json`, the check works the same on any machine that has it.
- Whether the hooks run is judged per machine, by a mark they leave in `.runtime/`. On a machine where they do not run, decisions are recorded with a note instead of the check. If the hooks were removed from a machine where they used to run, delete `docs/myaidlc/.runtime/hooks-alive` there.
- The audit trail records the reply as `HUMAN_TURN` (a typed message at an open gate) or `QUESTION_REPLIED` (any answer), and copies the person's words into the decision's `Person Reply`.
- The record shows an interaction that was observed. It is not proof of who typed it. A prompt that the host itself sends, such as a scheduled wake-up, looks the same as one the person typed.

## Reviews

- Documents are reviewed by `general-purpose` with model `sonnet`.
- Code is reviewed by `feature-dev:code-reviewer` with model `opus`; where that agent is not installed, `general-purpose` with model `opus` reviews it instead.
- Reviewers never edit.
- Findings are ranked P0 (wrong or broken), P1 (serious), P2 (worth improving), and P3 (detail).
- Every P0 and P1 finding is applied before the gate, and the engine refuses a review record that leaves one unapplied. A phase is reviewed at its last step, so a fix may change a document the person approved earlier in the phase. Such changes are shown at that gate. Two exceptions, both the person's call: they can decline a finding (`--declined-by-human`), or skip the review (`review-skip`).
- P2 and P3 findings are shown at the gate for the person to decide.
- When the person skips a step, or jumps past it, and that step owed a review, the review is recorded as skipped with it, and a one-line note says so.
- For code, the engine lists the changes against a baseline it takes when the code plan is approved, or when Build and Test starts. It takes the baseline with a private git index, so the person's index and working tree are never touched.

The full procedure is in `skills/myaidlc/protocol/review.md`.

## Reading code

- Code is read through Explore, with model `haiku` and thoroughness medium, started from the main conversation.
- Each search covers only the area the work touches and its neighbors: what it imports, what imports it, the same package, tests, config.
- Reverse Engineering turns the results into `codemap.md`. A subagent step gets the results in its prompt.

## Models and sessions

Token cost is kept down by the model each part runs on and by how long one conversation runs.

| Part | Model |
|---|---|
| conductor (the main conversation) | Sonnet, chosen by the person with `/model`. A conductor on another model says so once, in one line |
| developer agent (Code Generation's build step) | `sonnet`, set in its agent file |
| Explore | `haiku` |
| document review | `sonnet` |
| code review | `opus` |

- Every record lives in `docs/myaidlc/`, so a fresh conversation picks the work up with `/myaidlc resume`. Nothing depends on the conversation's history.
- The `next` directive's `break_point` is true when the step is not started and the step before it ended a phase or a unit (Initialization excepted), unless the person jumped to it. There the conductor, if it has already run a step in this conversation, stops once and suggests `/clear` and `/myaidlc resume`; the person can also just go on.
- In the middle of a step, `/compact` keeps the discussion that is not yet written down. After a compaction the conductor reads the protocol files again.

## The guard

The guard is a PreToolUse hook on Edit, Write, MultiEdit and NotebookEdit.

- It always blocks writes to the engine's files (`state.json`, `state.md`, `audit.md`, `.runtime/`).
- While work is active, not paused, and the guard is on:
  - `docs/` and `.claude/` are always writable.
  - Other files (the product's code) are writable only in a stage whose `source_writes` allows it: Code Generation after its plan is approved, and Build and Test while it runs.
- A refusal names the next step.
- The person can switch the guard off for the current work (`engine guard off`). That is recorded.

## Customizing for a project

- **Rules**, in order, with a later file winning:
  1. `skills/myaidlc/rules/defaults.md`
  2. the project's `AGENTS.md`
  3. `docs/myaidlc/memory/project.md`
  4. `docs/myaidlc/memory/phases/<phase>.md`
- **Templates**: a file in `docs/myaidlc/memory/templates/` replaces the default template of the same name.
- **Learning**: when the person corrects the agent during a step, they are asked once whether to keep the correction as a rule. If they say yes, it is added to `project.md`.
- **Settings** in `docs/myaidlc/config.json`:
  - `guard`: `on` or `off`, the starting value for new work
  - `default_scope`
  - `verify_commands`: the project's check commands, used by Build and Test

## Engine commands

Run them from the project root: `.claude/skills/myaidlc/scripts/myaidlc-engine.sh <command>`.

| Command | Purpose |
|---|---|
| `start --scope <s> --label <l> [--request-file <path>\|-]` | create the work and run Initialization |
| `next` | the directive for the current step (read-only) |
| `report --stage <s> [--unit <u>] --result <r> [--reason <text>]` | `started`, `plan-ready`, `plan-approved`, `awaiting`, `approved`, `rejected`, `revised`, `completed`, `skipped`. (`--reply <text>` passes the person's exact words only when the hooks do not run.) |
| `review --stage <s> [--unit <u>] --kind doc\|code --file <path> --p0 N --p1 N --p2 N --p3 N --applied <levels> [--declined-by-human]` | record a review |
| `review-skip --stage <s> [--unit <u>] --kind doc\|code` | record the person's decision to skip a review |
| `units --set a,b` | the units, in build order |
| `changes [--diff]` | the code changed since the step's baseline |
| `jump --stage <s> [--unit <u>]` | move forward (skipping), back (reopening), or start the current step over |
| `park`, `resume`, `status`, `intent list`, `intent switch <name>`, `guard off\|on` | control the work |
| `learn --rule-file <path>\|-` | add a rule the person chose to keep to `project.md` (not checked against a reply) |
| `setup [--dry-run]` | create `docs/myaidlc/`, install the hooks, and allow the engine to run without a prompt (`Bash(.claude/skills/myaidlc/scripts/myaidlc-engine.sh:*)` in `permissions.allow`) |
| `check` | validate the stages and scopes |
| `hook prompt\|pre-tool\|post-tool` | Claude Code hooks |

Exit status: 0 = done, 2 = refused (the reason and the next step are printed), 1 = error. The engine needs bash 3.2 or later, jq, and git.
