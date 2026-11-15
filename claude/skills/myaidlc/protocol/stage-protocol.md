# Stage protocol

How every myaidlc step is carried out. Stage files say what a step does; this file says how a step is run, the same way each time, and it is the one place these rules live. `engine` means `.claude/skills/myaidlc/scripts/myaidlc-engine.sh`, run from the project root as a command of its own.

## Starting a step

1. Read the stage file named in the directive (`stage_file`). Then read every file in `rules`, in order; a later file wins where two disagree.
2. Unless the step is dispatched as a subagent (see "Subagent steps"), read `.claude/agents/<agent>.md` for the directive's `agent`, and work in that role.
3. Report `started`: `engine report --stage <stage> [--unit <unit>] --result started`. Skip this when the directive's `status` is already `in-progress` or `revising`.
4. Read the files in `consumes` that the step needs. Write each output to the `path` in `produces`, starting from its `template`. An empty template means the step decides the layout. If the output already exists because the step was reopened, revise it rather than starting over, unless the person asked for a redo.

Everything the step writes as a document (`.md`, `.html`, `.txt`) goes under `docs/`: the outputs go in the directive's `output_dir`, and any other note or report goes elsewhere in `docs/`.

## Reading code

Code is read through Explore, started from the main conversation, never from a subagent:

```
Agent(subagent_type: "Explore", model: "haiku", prompt: "thoroughness: medium. <what to find and why> ...")
```

- Scope each search to the area the work touches: the files named, what they import and what imports them, the same package or module, their tests, and their config and build files. Never ask for the whole repository.
- Say in the prompt what to return: file paths, the role of each file, the dependencies between them, entry points, test locations and commands, conventions, and anything not found.
- Give independent areas one Explore each, started in parallel.
- Read a file directly only when you are about to edit it, or when it is one of myaidlc's own documents.

## Questions

Ask only what is the person's to decide, and only what changes the outcome. Never ask again what they have already answered.

- **1 to 4 questions with clear options**: use AskUserQuestion. Put your recommendation first, marked "(Recommended)", and in each option say in plain words what it means for them.
- **More questions, or ones that need longer answers**:
  1. Write `<output_dir>/questions.md` with an `[Answer]:` line under each question.
  2. Ask how they want to answer: one at a time in the chat, by editing the file, or by talking it through. If they talk it through, write their decisions back into the file.
  3. Whichever they choose, the file is the record.
- Record each decision in the step's output, under the heading the template gives for it.

## Gates

A gate is where the person decides. The engine opens it; you put the question.

1. Open the gate:
   - `engine report ... --result awaiting` for an approval or a unit checkpoint
   - `engine report ... --result plan-ready` for a code plan
2. Ask with AskUserQuestion. The options are **Approve** and **Request changes**; the person can always answer in their own words. Before the options, say in a few lines:
   - what was produced, with the paths to read
   - the decisions it contains
   - review findings left for them: P2 and P3, and any review file in `carry_reviews`
   - any change the review made to a document they approved earlier
   - anything skipped or at risk
3. Report what they decided, in the same turn:

   | The person… | Do |
   |---|---|
   | approves, in whatever words | report `approved`, or `plan-approved` at a plan gate |
   | asks for changes | report `rejected` with `--reason "<the change, in your words>"`, then see step 4 |
   | approves with a small change to a document ("fine, but rename X in the plan") | make the change, then report `approved` (or `plan-approved`) |
   | approves with a change to code | treat it as asking for changes: the code is locked while they decide |
   | approves and stops ("ok, let's stop here") | report `approved`, then `engine park` |

   If the person closes the question without answering, end your turn. Their next message is the answer.
4. After `rejected`:
   1. Work out with them whether to modify the output or redo the step.
   2. Revise it, and run the review again if the directive asks for one.
   3. Report `revised`. This reopens the gate; ask again.
   4. To redo the step from the start, run `engine jump --stage <stage> [--unit <unit>]` on the current step instead.

Never decide a gate yourself, and never report a decision the person did not give. The engine checks that the person replied after your last step, and each reply carries one decision. When it refuses, ask the person. If it refuses a second time although they answered in the question box, ask them once to type their answer in the chat. If it still refuses, the hooks are not running on this machine although they once did: tell the person to run `/myaidlc-setup` and start a new session, or, if they removed the hooks on purpose, to delete `docs/myaidlc/.runtime/hooks-alive`.

## Decisions that are the person's

Carry these out when the person asks, and only then. Each one needs their reply after your last step, like a gate.

| The person asks to… | Run |
|---|---|
| skip this step | `engine report --stage <stage> [--unit <unit>] --result skipped --reason "<why>"` |
| go back to a step, skip ahead, or start the current step over | `engine jump --stage <stage> [--unit <unit>]` |
| leave a P0 or P1 finding unfixed | record the review with `--declined-by-human` (see `protocol/review.md`) |
| skip a review | `engine review-skip --stage <stage> [--unit <unit>] --kind <doc\|code>` |
| pause | `engine park` |
| let you change code outside the current step | `engine guard off`; afterwards, `engine guard on` |

If, after a code plan was approved, the plan turns out to be wrong:
1. Tell the person what you found and what you propose instead.
2. If they agree, run `engine jump --stage code-generation --unit <unit>`. The code is locked again, and you write a new plan.

## Finishing a step

1. If the step may have changed what a review covers, run `engine next` again first, so that `review.required` and `review.targets` are current. If `review.required` is `doc` or `code` and `review.recorded` is false, run the review in `protocol/review.md`.
2. Run "Learn" below.
3. If `gate` is `none`, report `completed`. Otherwise open the gate, as in "Gates".
4. Run `engine next`, and carry out what it says.

When the engine refuses any command, it prints why and what to do next. Do that, and never route around it. If an engine command fails with an error (exit status 1), tell the person in one line what failed, and stop.

## Subagent steps

When the directive's `mode` is `subagent` and its `step` is `build` (the build step of Code Generation):

- Dispatch the agent named in `agent` with the Agent tool.
- It cannot see the conversation, so its prompt must hold everything it needs:
  - the step and the unit
  - the paths of the approved documents to follow
  - the rule files
  - the results of the Explore searches you ran
  - `verify_commands`
- Tell it to report the files it changed, the commands it ran and their results, any difference from the plan, and any blocker.
- The subagent does the work; you keep the bookkeeping. You report to the engine, run the reviews, and talk to the person.

## Learn

Only when the person corrected you during this step ("no, our handlers always…"):

1. Before you finish the step, ask once whether this should become a standing rule for the project. Show the rule as one sentence.
2. If they say yes, record it with `engine learn --rule-file -`, giving the sentence on standard input. It is added to `docs/myaidlc/memory/project.md` and applies from the next step on.

If there was no correction, say nothing about it.

## What the person reads

- Talk about their work: what was done, where it stands against what they approved, what they need to decide, and how to undo it.
- Never show them directive names, status words such as `plan-awaiting`, or the engine's field names.
- Say a risk or a skipped step once, in one line.

## Files and commands

- Create and edit files with your file tools, not the shell.
- Never write `state.json`, `state.md`, `audit.md` or anything under `docs/myaidlc/.runtime/`. Every change to them goes through an engine command.
- Run engine commands exactly as written, each as a command of its own, from the project root.
- Do not commit, push, reset, stash, or clean the person's working tree, and do not install anything the approved plan does not name, unless the person asks.
