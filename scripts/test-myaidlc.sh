#!/usr/bin/env bash
# End-to-end test of the myaidlc engine in a temporary git repository: setup, a feature run
# with two units, a bugfix run, gates, reviews, the guard, jumps, park and resume, learning,
# and masking. Hooks are driven with the JSON Claude Code sends them.
# Usage: ./scripts/test-myaidlc.sh [bash binary...]
#   With no argument it runs with `bash`, and again with /bin/bash when that is a different version.
# Requires jq and git.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=0

run_suite() {
  local BASH_BIN="$1" T pass=0 fail=0 out d
  T="$(cd "$(mktemp -d)" && pwd -P)"
  # shellcheck disable=SC2064
  trap "rm -rf '$T'" RETURN EXIT
  # keep the person's own git configuration (signing, hooks, templates) out of the test
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

  git -C "$T" init -q
  git -C "$T" config user.email test@example.com
  git -C "$T" config user.name test
  printf 'hello\n' > "$T/README.md"
  mkdir -p "$T/src"
  printf 'one\n' > "$T/src/app.txt"
  git -C "$T" add -A
  git -C "$T" -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -qm init
  mkdir -p "$T/.claude/skills" "$T/.claude/agents"
  cp -R "$REPO_DIR/claude/skills/myaidlc" "$T/.claude/skills/"
  cp "$REPO_DIR"/claude/agents/myaidlc-*.md "$T/.claude/agents/"

  E() { (cd /tmp && CLAUDE_PROJECT_DIR="$T" "$BASH_BIN" "$T/.claude/skills/myaidlc/scripts/myaidlc-engine.sh" "$@"); }
  check() {
    local desc="$1"; shift
    if out="$("$@" 2>&1)"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "NG  $desc"; printf '%s\n' "$out" | sed 's/^/      /' | head -n 8; fi
  }
  refused() {
    local desc="$1" rc=0; shift
    out="$("$@" 2>&1)" || rc=$?
    if [ "$rc" = 2 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "NG  $desc (expected a refusal, got exit $rc)"; printf '%s\n' "$out" | sed 's/^/      /' | head -n 8; fi
  }
  is() { [ "$1" = "$2" ] || { echo "expected [$2], got [$1]"; return 1; }; }
  has() { grep -q -- "$2" "$1" || { echo "$1 does not contain $2"; return 1; }; }
  hasnt() { if grep -q -- "$2" "$1"; then echo "$1 contains $2"; return 1; fi; }
  prompt() { jq -n --arg p "$1" '{hook_event_name: "UserPromptSubmit", prompt: $p}' | E hook prompt; }
  answer() { jq -n --arg a "$1" '{hook_event_name: "PostToolUse", tool_name: "AskUserQuestion", tool_input: {questions: [], answers: {"How would you like to proceed?": $a}}}' | E hook post-tool; }
  write_hook() { jq -n --arg f "$T/$1" '{hook_event_name: "PreToolUse", tool_name: "Write", tool_input: {file_path: $f, content: "x"}}' | E hook pre-tool; }
  next_is() { is "$(E next | jq -r "$1")" "$2"; }
  outdir() { E next | jq -r .output_dir; }
  make_file() { mkdir -p "$(dirname "$T/$1")"; printf '%s\n' "${2:-content}" > "$T/$1"; }
  review() { # review <kind> <p0> <p1> <p2> <p3> <applied> [extra]
    local d f; d="$(outdir)"; f="$d/review-$RANDOM.md"; make_file "$f" "findings"
    E review --stage "$(E next | jq -r .stage)" --kind "$1" --file "$f" --p0 "$2" --p1 "$3" --p2 "$4" --p3 "$5" --applied "$6" ${7:+"$7"}
  }
  R() { E report --stage "$(E next | jq -r .stage)" --result "$1"; }
  AUDIT() { ls "$T"/docs/myaidlc/intents/*"$1"*/audit.md | head -n 1; }
  STATEMD() { ls "$T"/docs/myaidlc/intents/*"$1"*/state.md | head -n 1; }

  echo "== $("$BASH_BIN" -c 'echo bash $BASH_VERSION')"

  # setup is idempotent and installs three hooks
  check "setup dry run lists the hooks" bash -c "$(declare -f E); T='$T'; BASH_BIN='$BASH_BIN'; E setup --dry-run | grep -q 'add hooks'"
  check "setup" E setup
  check "setup again changes nothing" bash -c "$(declare -f E); T='$T'; BASH_BIN='$BASH_BIN'; E setup | grep -q 'already installed'"
  check "three hook events are registered once" is "$(jq '[.hooks[] | length] | add' "$T/.claude/settings.json")" 3
  check "the engine permission is allowed once" is "$(jq '[.permissions.allow[] | select(. == "Bash(.claude/skills/myaidlc/scripts/myaidlc-engine.sh:*)")] | length' "$T/.claude/settings.json")" 1
  check "the runtime folder is ignored" has "$T/docs/myaidlc/.runtime/.gitignore" '\*'
  check "definitions are consistent" E check
  check "no work yet: ask" next_is .reason no-work

  # ---- feature run ----
  prompt "/myaidlc Add saved searches. token=FAKEVALUEFORTESTS"
  check "still no work before start" next_is .directive ask
  check "start returns the first step" is "$(E start --scope feature --label saved-search | jq -r .stage)" intent-capture
  check "the request drops the command and masks the secret" hasnt "$T"/docs/myaidlc/intents/*saved-search/request.md FAKEVALUEFORTESTS
  check "the request keeps the words" has "$(ls "$T"/docs/myaidlc/intents/*saved-search/request.md)" "Add saved searches"
  check "initialization is verified" has "$(STATEMD saved-search)" '\*\*Initialization\*\*: Verified'

  check "intent-capture started" R started
  refused "product code is locked before any plan" write_hook src/app.txt
  check "docs are writable" write_hook docs/notes.md
  refused "engine files are locked" write_hook docs/myaidlc/intents/x/state.md
  make_file "$(outdir)/intent.md"
  refused "the end of a phase needs a document review" R awaiting
  refused "a P0 finding must be applied" review doc 1 0 1 0 ""
  check "review with P0 applied" review doc 1 0 1 0 P0
  check "gate opens" R awaiting
  check "directive shows the gate" next_is .status awaiting
  refused "approval needs a reply from the person" R approved
  prompt "Looks good"
  check "approved after the reply" R approved
  check "the reply is in the audit" has "$(AUDIT saved-search)" 'Person Reply\*\*: Looks good'
  check "ideation verified" has "$(STATEMD saved-search)" '\*\*Ideation\*\*: Verified'

  check "next is reverse engineering" next_is .stage reverse-engineering
  check "reverse engineering needs no review mid-phase" next_is .review.required none
  check "reverse engineering started" R started
  make_file "$(outdir)/codemap.md"
  check "reverse engineering completed without a gate" R completed

  check "requirements started" R started
  make_file "$(outdir)/requirements.md"
  check "requirements consume the intent and the map" is "$(E next | jq '[.consumes[] | select(test("intent.md|codemap.md"))] | length')" 2
  check "requirements gate" R awaiting
  answer "Approve"
  check "approved by the question box" R approved
  check "the answer is in the audit" has "$(AUDIT saved-search)" QUESTION_REPLIED

  check "delivery planning started" R started
  make_file "$(outdir)/delivery-plan.md"
  check "units set" E units --set search-api,search-ui
  check "phase review targets every inception document" is "$(E next | jq '.review.targets | length')" 3
  refused "delivery planning needs the phase review" R awaiting
  check "review with nothing to apply" review doc 0 0 0 2 ""
  check "delivery planning gate" R awaiting
  prompt "ok"
  check "delivery planning approved" R approved
  check "inception verified" has "$(STATEMD saved-search)" '\*\*Inception\*\*: Verified'

  check "functional design for the first unit" next_is .unit search-api
  refused "code still locked in functional design" write_hook src/app.txt
  check "functional design started" R started
  make_file "$(outdir)/functional-design.md"
  check "functional design completed" R completed

  check "code generation plan step" next_is .step plan
  check "the next step of the same unit is not a break point" next_is .break_point false
  check "code generation started" R started
  make_file "$(outdir)/code-plan.md"
  refused "the plan needs a document review" R plan-ready
  check "plan review targets the design and the plan" is "$(E next | jq '.review.targets | length')" 2
  check "plan review" review doc 0 1 0 0 P1
  check "plan ready" R plan-ready
  refused "code locked while the plan waits" write_hook src/app.txt
  refused "plan approval needs a reply" R plan-approved
  prompt "approve the plan"
  check "plan approved" R plan-approved
  check "build step" next_is .step build
  check "code writable after plan approval" write_hook src/app.txt
  make_file src/api.txt "api"
  check "changes list the new file" bash -c "$(declare -f E); T='$T'; BASH_BIN='$BASH_BIN'; E changes | grep -qx src/api.txt"
  check "the directive lists the changed file for review" is "$(E next | jq -r '.review.targets | join(",")')" src/api.txt
  refused "the checkpoint needs a code review" R awaiting
  check "code review" review code 0 0 1 0 ""
  check "checkpoint" R awaiting
  answer "Approve"
  check "unit approved" R approved
  refused "units cannot change once construction started" E units --set other

  check "second unit" next_is .unit search-ui
  check "a new unit is a break point" next_is .break_point true
  check "fd2 started" R started
  make_file "$(outdir)/functional-design.md"
  check "fd2 completed" R completed
  check "cg2 started" R started
  make_file "$(outdir)/code-plan.md"
  check "cg2 plan review" review doc 0 0 0 0 ""
  check "cg2 plan ready" R plan-ready
  prompt "yes"
  check "cg2 plan approved" R plan-approved
  make_file src/ui.txt "ui"
  check "second unit's changes exclude the first unit's" is "$(E changes | tr '\n' ',')" "src/ui.txt,"
  check "cg2 code review" review code 0 0 0 0 ""
  check "cg2 checkpoint" R awaiting
  prompt "rename the handler"
  check "rejected" R rejected
  check "now revising" next_is .status revising
  refused "a revision needs a new review" R revised
  check "cg2 code review again" review code 0 0 0 0 ""
  check "revised" R revised
  prompt "good now"
  check "cg2 approved" R approved

  check "build and test" next_is .stage build-and-test
  check "the step after the last unit is a break point" next_is .break_point true
  check "build and test reads the intent" is "$(E next | jq '[.consumes[] | select(test("intent.md"))] | length')" 1
  check "build and test consumes both plans" is "$(E next | jq '[.consumes[] | select(test("code-plan.md"))] | length')" 2
  check "bt started" R started
  check "code writable while testing" write_hook src/app.txt
  make_file "$(outdir)/test-report.md"
  check "no code change, no review" next_is .review.required none
  check "bt gate" R awaiting
  prompt "fine"
  check "bt approved" R approved

  check "handoff" next_is .stage handoff
  check "a new phase after construction is a break point" next_is .break_point true
  refused "code locked at handoff" write_hook src/app.txt
  check "handoff started" R started
  make_file "$(outdir)/handoff.md"
  check "handoff gate" R awaiting
  prompt "ship it"
  check "handoff approved" R approved
  check "the work is done" next_is .directive done
  check "state shows the finished unit" has "$(STATEMD saved-search)" 'Per unit: search-ui'
  check "audit records completion" has "$(AUDIT saved-search)" WORKFLOW_COMPLETED

  # ---- bugfix run ----
  prompt "/myaidlc Login fails with ghp_FAKEFAKEFAKEFAKEFAKEFAKE0000"
  check "start a bugfix" is "$(E start --scope bugfix --label login | jq -r .stage)" intent-capture
  check "the prompt is masked" hasnt "$T/docs/myaidlc/.runtime/last-prompt.txt" ghp_FAKE
  check "the first step after start is not a break point" next_is .break_point false
  check "bf intent started" R started
  make_file "$(outdir)/intent.md"
  check "bf intent review" review doc 0 0 0 0 ""
  check "bf intent gate" R awaiting
  prompt "yes"
  check "bf intent approved" R approved
  check "a new phase is a break point" next_is .break_point true
  check "bf re started" R started
  check "a started step is not a break point" next_is .break_point false
  make_file "$(outdir)/codemap.md"
  refused "in bugfix, reverse engineering ends inception and needs a review" R completed
  prompt "skip the review"
  check "review skipped at the person's request" E review-skip --stage reverse-engineering --kind doc
  check "bf re completed" R completed
  check "bugfix builds the default unit" next_is .unit main
  check "construction after inception is a break point" next_is .break_point true
  check "bf cg started" R started
  check "default unit recorded" has "$(AUDIT login)" 'Units\*\*: main'

  check "park" E park
  check "parked" next_is .directive parked
  check "the guard stands aside while parked" write_hook src/app.txt
  check "resume" E resume
  refused "the guard is back" write_hook src/app.txt
  prompt "let me edit the code myself now"
  check "guard off" E guard off
  check "the guard is off" write_hook src/app.txt
  check "guard on" E guard on

  prompt "skip ahead to the handoff"
  check "jump forward" E jump --stage handoff
  check "now at handoff" next_is .stage handoff
  check "skipped steps are marked" has "$(STATEMD login)" '\[S\] build-and-test'
  prompt "go back to the intent"
  check "jump back" E jump --stage intent-capture
  check "intent reopened" next_is .status pending
  check "a step jumped back to is not a break point" next_is .break_point false
  check "ideation is no longer verified" has "$(STATEMD login)" '\*\*Ideation\*\*: Pending'

  check "learn a rule" bash -c "$(declare -f E); T='$T'; BASH_BIN='$BASH_BIN'; printf 'Use the project logger, never print.' | E learn --rule-file -"
  check "the rule is in project.md" has "$T/docs/myaidlc/memory/project.md" 'Use the project logger'
  check "two pieces of work" is "$(E intent list | wc -l | tr -d ' ')" 2
  check "switch back" E intent switch "$(basename "$(dirname "$(AUDIT saved-search)")")"
  check "status reads plainly" bash -c "$(declare -f E); T='$T'; BASH_BIN='$BASH_BIN'; E status | grep -q 'Every step is finished'"

  # ---- unit order, carried findings, skipping a phase end, plan rejection, declined findings ----
  prompt "/myaidlc Extra work"
  prompt "the feature one, please"
  check "start a third piece of work" is "$(E start --scope feature --label extra | jq -r .stage)" intent-capture
  check "the request is the /myaidlc message, not the later answer" has "$(ls "$T"/docs/myaidlc/intents/*extra/request.md)" "Extra work"
  check "x intent started" R started
  make_file "$(outdir)/intent.md"
  check "x intent review" review doc 0 0 0 0 ""
  check "x intent gate" R awaiting
  prompt "/myaidlc"
  refused "a bare /myaidlc is not an answer to the gate" R approved
  prompt "yes"
  check "x intent approved" R approved
  refused "one reply carries one decision" E guard off
  check "x re started" R started
  make_file "$(outdir)/codemap.md"
  check "an optional review with P2 findings" review doc 0 0 2 0 ""
  check "x re completed" R completed
  check "the findings are carried to the next gate" is "$(E next | jq '.carry_reviews | length')" 1
  check "x req started" R started
  make_file "$(outdir)/requirements.md"
  check "x req gate" R awaiting
  prompt "ok"
  check "x req approved" R approved
  check "carried findings are cleared once shown" is "$(E next | jq '.carry_reviews | length')" 0
  check "x dp started" R started
  check "units keep the planned order" E units --set zeta,alpha
  prompt "skip the plan"
  check "skip the step that ends the phase" R skipped
  check "the phase review is recorded as skipped with it" has "$(AUDIT extra)" 'the review of this phase'"'"'s documents was skipped'
  check "the first unit is the first planned" next_is .unit zeta
  check "a new phase after a skipped step is a break point" next_is .break_point true
  check "x fd started" R started
  make_file "$(outdir)/functional-design.md"
  check "x fd completed" R completed
  check "x cg started" R started
  make_file "$(outdir)/code-plan.md"
  check "x plan review" review doc 1 1 0 0 P0,P1
  check "x plan ready" R plan-ready
  prompt "change the plan"
  check "plan rejected" R rejected
  refused "the revised plan needs a new review" R revised
  check "x plan review again" review doc 0 0 0 0 ""
  check "plan revised" R revised
  check "back at plan approval" next_is .status plan-awaiting
  prompt "approve"
  check "x plan approved" R plan-approved
  make_file src/zeta.txt "zeta"
  refused "an unapplied P1 is refused" review code 0 1 0 0 ""
  prompt "leave that one as it is"
  check "the person declines a P1" review code 0 1 0 0 "" --declined-by-human
  check "the decline is recorded with their words" has "$(AUDIT extra)" 'Declined By Person\*\*: leave that one'
  prompt "start this plan over"
  check "jumping to the current step starts it over" E jump --stage code-generation --unit zeta
  check "the plan is open again" next_is .step plan
  check "and the step is not started" next_is .status pending
  check "a step started over is not a break point" next_is .break_point false
  refused "a unit that does not exist is refused" E jump --stage code-generation --unit nope
  refused "a path with .. cannot reach the engine's files" write_hook "src/../docs/myaidlc/intents/x/state.json"

  # ---- a damaged state file never blocks the session ----
  sf="$(ls "$T"/docs/myaidlc/intents/*extra/state.json)"
  cp "$sf" "$sf.bak"
  printf '<<<<<<< HEAD\n' >> "$sf"
  check "the prompt hook lets the session go on" bash -c "$(declare -f E prompt); T='$T'; BASH_BIN='$BASH_BIN'; prompt 'hello' 2>/dev/null"
  check "the write hook lets the session go on" bash -c "$(declare -f E write_hook); T='$T'; BASH_BIN='$BASH_BIN'; write_hook src/app.txt 2>/dev/null"
  check "next explains the damaged state" next_is .directive error
  mv "$sf.bak" "$sf"

  # ---- without hooks: approvals stand aside with a note ----
  rm -f "$T/docs/myaidlc/.runtime/last-prompt.txt" "$T/docs/myaidlc/.runtime/last-answer.txt" "$T/docs/myaidlc/.runtime/hooks-alive"
  check "start without hooks" bash -c "$(declare -f E); T='$T'; BASH_BIN='$BASH_BIN'; printf 'Add export' | E start --scope bugfix --label export --request-file - | jq -e '.note | length > 0' >/dev/null"
  check "nh started" R started
  make_file "$(outdir)/intent.md"
  check "nh review" review doc 0 0 0 0 ""
  check "nh gate" R awaiting
  check "approval stands aside with a note" bash -c "$(declare -f E R); T='$T'; BASH_BIN='$BASH_BIN'; R approved | grep -q 'hooks are not installed'"

  # ---- small scope: intent, code map, one unit, tests, handoff ----
  check "start a small change" bash -c "$(declare -f E); T='$T'; BASH_BIN='$BASH_BIN'; printf 'Rename the button' | E start --scope small --label rename --request-file - | jq -e '.stage == \"intent-capture\" and .scope == \"small\" and .depth == \"minimal\"' >/dev/null"
  check "small has no requirements step" has "$(STATEMD rename)" 'requirements-analysis — not in scope'
  check "small has no delivery plan" has "$(STATEMD rename)" 'delivery-planning — not in scope'
  check "small has no functional design" has "$(STATEMD rename)" 'functional-design — not in scope'
  check "sm intent started" R started
  make_file "$(outdir)/intent.md"
  check "sm intent review" review doc 0 0 0 0 ""
  check "sm intent gate" R awaiting
  check "sm intent approved" R approved
  check "sm code map is a break point" next_is .break_point true
  check "sm re started" R started
  make_file "$(outdir)/codemap.md"
  refused "in small, reverse engineering ends inception and needs a review" R completed
  check "sm re review" review doc 0 0 0 0 ""
  check "sm re completed" R completed
  check "small builds the default unit" next_is .unit main
  check "small code generation reads the intent" is "$(E next | jq '[.consumes[] | select(test("intent.md"))] | length')" 1

  echo "   $pass passed, $fail failed"
  [ "$fail" = 0 ] || FAILED=1
}

shells=("$@")
if [ ${#shells[@]} -eq 0 ]; then
  shells=(bash)
  if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo $BASH_VERSION')" != "$(bash -c 'echo $BASH_VERSION')" ]; then shells+=(/bin/bash); fi
fi
for sh in "${shells[@]}"; do run_suite "$sh"; done
exit $FAILED
