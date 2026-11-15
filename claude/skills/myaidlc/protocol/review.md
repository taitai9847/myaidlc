# Review protocol

Every design and every code change is reviewed before the person approves it: Ideation and Inception at the last step of the phase, and in Construction each unit's code plan and each unit's code. The engine says when a review is due (`review.required` in the directive) and what it covers (`review.targets`). It refuses to go on until the review is recorded, or until the person says to skip it.

## Who reviews

| Kind | `subagent_type` | `model` |
|---|---|---|
| `doc` (requirements, plans, designs, code maps) | `general-purpose` | `opus` |
| `code` | `feature-dev:code-reviewer` | `opus` |

If `feature-dev:code-reviewer` cannot be started because that agent is not installed, run the code review with `general-purpose` and `model: "opus"`, using the code lens below.

A reviewer never edits files. Start every review prompt with: "Review only. Do not edit, create or delete any file. Report findings."

## What to put in the prompt

Every review prompt contains:

- **What the work is for**: the path of `intent.md`, and of `requirements.md` if there is one.
- **What to read**: only the files listed in the prompt, plus the files they directly depend on. Say so in the prompt.
- **The output format below, word for word**, and the instruction to report findings at every level, P2 and P3 included.

Then add what fits the kind of review.

**For a `doc` review:**
- The paths in `review.targets`.
- The upstream documents those targets must agree with: the step's `consumes`.
- The lens:
  - whether it meets the intent and the requirements
  - contradictions and gaps
  - requirements that cannot be checked
  - anything out of scope
  - statements about the existing code that `codemap.md` does not support

**For a `code` review:**
- The files in `review.targets`.
- The full diff from `engine changes --diff`, pasted into the prompt. A code reviewer may not be able to run commands.
- The approved `code-plan.md`, `functional-design.md` if there is one, and `.claude/docs/dev-guideline.md`.
- The lens:
  - correctness
  - whether the change follows the plan and meets the requirements
  - error handling
  - whether the tests are enough (for a bug fix, a regression test)
  - the guideline's hard rules
  - the conventions of the surrounding code

## Output format

```
For each finding:
- Priority: P0 | P1 | P2 | P3
- Location: <file and section or line>
- Problem:
- Why it matters:
- Suggested fix:

P0 = as it stands, the wrong thing gets built, something breaks, or a requirement is not met
P1 = a serious defect or a serious gap
P2 = an improvement worth making
P3 = a matter of taste or detail
Sort by priority. If there are no findings at a level, say so.
```

If the reviewer answers in another form, sort its findings into P0–P3 yourself, and say at the top of the review file that you did.

## After the review

1. Save the findings to `<output_dir>/review-<n>.md`. `<n>` starts at 1 and goes up by one for each review of the step, the confirmation review included.
2. **Apply every P0 and P1 finding.**
   - If you think one is wrong, or applying it needs a choice that is the person's, ask them before you record the review. If they decide to leave it, see "When the person decides otherwise".
   - If a fix changes a document the person approved earlier in the phase, note the change. It is shown at the gate.
3. If there was any P0 finding, run one more review of the changed files to confirm the fixes, and save it as the next `review-<n>.md`. Do this once, not in a loop. If it finds a new P0 or P1 finding, fix it, and tell the person about it at the gate.
4. Record the review, giving the counts from the first review:
   ```
   engine review --stage <stage> [--unit <unit>] --kind <doc|code> --file <first review file> --p0 N --p1 N --p2 N --p3 N --applied P0,P1
   ```
   Put in `--applied` only the levels you fully applied. The engine refuses the record when a P0 or P1 finding was not applied.
5. At the gate, show the P2 and P3 findings as the person's choice.

## When the person decides otherwise

These are the person's call. Record them only after the person has said so; the engine accepts them once their reply is on record.

- **They decide not to apply a P0 or P1 finding.** Record the review with `--declined-by-human`, with `--applied` listing only the levels you did fully apply. The engine keeps their words.
- **They say a review is not needed.** Run `engine review-skip --stage <stage> [--unit <unit>] --kind <doc|code>`.
