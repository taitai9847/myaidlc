#!/usr/bin/env bash
# myaidlc engine: the deterministic half of myaidlc. See .claude/docs/myaidlc.md.
#
# It decides which step comes next, owns every state transition, writes the state
# and the audit trail, checks gates and reviews, and runs the hooks. The conductor
# (skills/myaidlc/SKILL.md) never decides the route and never writes these files.
#
# Usage: myaidlc-engine.sh <command> [args]
#   start --scope <name> --label <label> [--request-file <path>|-]
#   next
#   report --stage <slug> [--unit <unit>] --result <result> [--reason <text>] [--reply <text>]
#          result: started | plan-ready | plan-approved | awaiting | approved | rejected | revised | completed | skipped
#   review --stage <slug> [--unit <unit>] --kind <doc|code> --file <path> --p0 N --p1 N --p2 N --p3 N
#          --applied <P0,P1,...> [--declined-by-human]
#   review-skip --stage <slug> [--unit <unit>] --kind <doc|code>
#   units --set <a,b,...>
#   changes [--diff]
#   jump --stage <slug> [--unit <unit>]
#   park | resume | status
#   intent list | intent switch <name>
#   guard off | guard on
#   learn --rule-file <path>|-
#   setup [--dry-run]
#   check
#   hook prompt | hook pre-tool | hook post-tool      (Claude Code hooks; JSON on stdin)
#
# Exit status: 0 = done, 2 = refused (the reason and the next step are on stdout), 1 = error.
# Portable to bash 3.2 (macOS) and Linux. Requires jq and, for code changes, git.
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
refuse() { printf '%s\n' "$@"; exit 2; }

command -v jq >/dev/null 2>&1 || die "jq is required"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
AGENTS_DIR="$(cd "$SKILL_DIR/../.." && pwd -P)/agents"
RAW_ROOT="${CLAUDE_PROJECT_DIR:-}"
# Without the hook variable, the project is the folder that holds this .claude/
if [ -z "$RAW_ROOT" ] && [ "$(basename "$(dirname "$(dirname "$SKILL_DIR")")")" = .claude ]; then
  RAW_ROOT="$(dirname "$(dirname "$(dirname "$SKILL_DIR")")")"
fi
[ -n "$RAW_ROOT" ] || RAW_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$RAW_ROOT" || die "cannot enter $RAW_ROOT"
ROOT="$(pwd -P)"

D=docs/myaidlc
RT=$D/.runtime
INTENTS=$D/intents
CONFIG=$D/config.json
PHASES="initialization ideation inception construction operation"

relpath() {
  case "$1" in
    "$ROOT"/*) printf '%s' "${1#"$ROOT"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}
SKILL_REL="$(relpath "$SKILL_DIR")"

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ---------------------------------------------------------------------------
# Shared jq definitions: the route is computed here and only here.
# ---------------------------------------------------------------------------
JQLIB='
def phases: ["initialization", "ideation", "inception", "construction", "operation"];
def pidx($p): phases | index($p);
def onum: split(".") | map(tonumber);
def effunits($s): if (($s.units // []) | length) > 0 then $s.units else ["main"] end;
def scoped($cat; $sc):
  [ $cat[] | select(.slug as $x | ($sc.stages | index($x)) != null) ]
  | sort_by(pidx(.phase), (.order | onum));
def instances($cat; $sc; $s):
  scoped($cat; $sc) as $st
  | [ $st[] | select(pidx(.phase) < 3) | . + {unit: null} ]
  + [ effunits($s)[] as $u | $st[] | select(.phase == "construction" and .for_each == "unit") | . + {unit: $u} ]
  + [ $st[] | select(.phase == "construction" and .for_each != "unit") | . + {unit: null} ]
  + [ $st[] | select(pidx(.phase) > 3) | . + {unit: null} ];
def ikey: if .unit then "\(.slug)@\(.unit)" else .slug end;
def entry($s): ($s.stages[ikey] // {status: "pending"});
def finished: . == "completed" or . == "skipped";
def cur($cat; $sc; $s): [ instances($cat; $sc; $s)[] | select(entry($s).status | finished | not) ] | .[0];
def last_in_phase($ins; $i): ([ $ins[] | select(.phase == $i.phase and (entry($s).status != "skipped")) ] | last | ikey) == ($i | ikey);
def review_needed($ins; $i; $e):
  if $i.review == "phase-doc" then (if last_in_phase($ins; $i) then "doc" else "none" end)
  elif $i.review == "plan-and-code" then (if ($e.plan_approved // false) then "code" else "doc" end)
  elif $i.review == "code-if-changed" then "code-if-changed"
  else "none" end;
def outdir($idir; $i):
  if $i.unit then "\($idir)/construction/\($i.unit)/\($i.slug)" else "\($idir)/\($i.phase)/\($i.slug)" end;
def phase_status($cat; $sc; $s; $p):
  [ instances($cat; $sc; $s)[] | select(.phase == $p) | entry($s).status ] as $xs
  | if ($xs | length) == 0 then "Skipped"
    elif all($xs[]; finished) then "Verified"
    elif any($xs[]; . != "pending") then "Active"
    else "Pending" end;
def mask:
  gsub("AKIA[0-9A-Z]{16}"; "[masked]")
  | gsub("(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}"; "[masked]")
  | gsub("github_pat_[A-Za-z0-9_]{20,}"; "[masked]")
  | gsub("sk-[A-Za-z0-9_-]{16,}"; "[masked]")
  | gsub("xox[abposr]-[A-Za-z0-9-]{10,}"; "[masked]")
  | gsub("(?i)bearer\\s+[A-Za-z0-9._~+/=-]{8,}"; "Bearer [masked]")
  | gsub("-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z ]*PRIVATE KEY-----"; "[masked private key]")
  | gsub("(?<s>[A-Za-z][A-Za-z0-9+.-]*://[^:/@\\s]+):[^@\\s]+@"; "\(.s):[masked]@")
  | gsub("(?i)(?<k>password|passwd|token|secret|api[_-]?key)(?<sep>\\s*[=:]\\s*)[^\\s\"'"'"']+"; "\(.k)\(.sep)[masked]");
'

# jq with the catalog, the scope and the state bound; the last argument is the program
q() {
  local n=$#
  local prog="${!n}"
  local args=("${@:1:n-1}")
  jq -n --argjson cat "$CAT" --argjson sc "$SCOPE" --argjson s "$STATE" ${args[@]+"${args[@]}"} "$JQLIB $prog"
}

mask() { jq -Rrs "$JQLIB mask"; }

# ---------------------------------------------------------------------------
# Stage and scope definitions (frontmatter: "key: value" and "key: [a, b]" only)
# ---------------------------------------------------------------------------
fm_dump() {
  awk '
    { sub(/\r$/, "") }
    FNR == 1 { f = ($0 == "---"); if (f) next }
    f && $0 == "---" { f = 0; next }
    f {
      i = index($0, ":")
      if (i > 0) {
        k = substr($0, 1, i - 1); v = substr($0, i + 1)
        sub(/[ \t]+#.*$/, "", v); gsub(/^[ \t]+|[ \t]+$/, "", v)
        print FILENAME "\t" k "\t" v
      }
    }' "$@"
}

FMLIB='
def lst: (. // "") | ltrimstr("[") | rtrimstr("]") | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""));
def fmparse($root):
  split("\n") | map(select(length > 0) | split("\t"))
  | group_by(.[0])
  | map(.[0][0] as $f | (map({key: .[1], value: (.[2:] | join("\t"))}) | from_entries) + {
      _file: ($f | ltrimstr($root)), _dir: ($f | split("/") | .[-2]), _stem: ($f | split("/") | .[-1] | rtrimstr(".md"))});
'

load_catalog() {
  local files=("$SKILL_DIR"/stages/*/*.md)
  [ -f "${files[0]}" ] || die "no stage files under $SKILL_REL/stages"
  CAT="$(fm_dump "${files[@]}" | jq -R -s --arg root "$ROOT/" "$FMLIB"'
    fmparse($root) | map({
      slug: (.slug // ""), phase: (.phase // ""), order: (.order // "0.0"), title: (.title // .slug // ""),
      lead_agent: (.lead_agent // ""), mode: ((.mode // "") | if . == "" then "inline" else . end),
      for_each: (.for_each // ""), gate: ((.gate // "") | if . == "" then "none" else . end),
      review: ((.review // "") | if . == "" then "none" else . end),
      source_writes: ((.source_writes // "") | if . == "" then "blocked" else . end),
      produces: (.produces | lst), consumes: (.consumes | lst),
      file: ._file, dir: ._dir, stem: ._stem })')"
}

load_scopes() {
  local files=("$SKILL_DIR"/scopes/*.md)
  [ -f "${files[0]}" ] || die "no scope files under $SKILL_REL/scopes"
  SCOPES="$(fm_dump "${files[@]}" | jq -R -s --arg root "$ROOT/" "$FMLIB"'
    fmparse($root) | map({name: (.name // ""), title: (.title // .name // ""), depth: (.depth // "standard"),
      stages: (.stages | lst), file: ._file, stem: ._stem})')"
}

load_scope() {
  load_scopes
  SCOPE="$(jq --arg n "$1" '[.[] | select(.name == $n)] | .[0]' <<<"$SCOPES")"
  [ "$SCOPE" != null ] || die "unknown scope: $1"
}

# ---------------------------------------------------------------------------
# Runtime, lock, state and audit
# ---------------------------------------------------------------------------
ensure_runtime() {
  mkdir -p "$RT"
  [ -f "$RT/.gitignore" ] || printf '*\n' > "$RT/.gitignore"
}

LOCKED=0
lock() {
  ensure_runtime
  local i=0
  while ! mkdir "$RT/lock.d" 2>/dev/null; do
    i=$((i + 1))
    if [ $i -gt 200 ]; then
      if [ -n "$(find "$RT/lock.d" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
        rmdir "$RT/lock.d" 2>/dev/null || true
        i=0
        continue
      fi
      die "myaidlc is busy (another command holds $RT/lock.d); try again"
    fi
    sleep 0.05
  done
  LOCKED=1
  trap unlock EXIT
}
unlock() {
  if [ "$LOCKED" = 1 ]; then rmdir "$RT/lock.d" 2>/dev/null || true; LOCKED=0; fi
}

# Loads the active intent into INTENT, IDIR, STATE, SCOPE and CAT. Returns 1 when there is none.
load_active() {
  INTENT=""
  [ -f "$RT/active-intent" ] || return 1
  INTENT="$(head -n 1 "$RT/active-intent" | tr -d '\r')"
  [ -n "$INTENT" ] || return 1
  IDIR="$INTENTS/$INTENT"
  [ -f "$IDIR/state.json" ] || die "the active work $INTENT has no state file ($IDIR/state.json). Run: myaidlc-engine.sh intent list"
  jq -e 'type == "object" and (.stages | type) == "object" and (.scope | type) == "string"' "$IDIR/state.json" >/dev/null 2>&1 \
    || die "the state file $IDIR/state.json is not valid (for example, an unresolved merge). Fix the JSON, or restore it from git: git checkout -- $IDIR/state.json"
  STATE="$(jq -c . "$IDIR/state.json")"
  load_scope "$(jq -r '.scope' <<<"$STATE")"
  load_catalog
  return 0
}

# Sets CUR (instance JSON or null), KEY ("" when everything is finished) and E (its state entry)
load_current() {
  CUR="$(q 'cur($cat; $sc; $s)')"
  KEY="$(jq -r 'if . == null then "" elif .unit then "\(.slug)@\(.unit)" else .slug end' <<<"$CUR")"
  E="$(jq --arg k "$KEY" '.stages[$k] // {status: "pending"}' <<<"$STATE")"
}
cf() { jq -r "$1" <<<"$CUR"; }
ef() { jq -r "$1" <<<"$E"; }

# set_entry <jq expression on the entry> [jq args...]
set_entry() {
  local expr="$1"; shift
  STATE="$(jq --arg entry_key "$KEY" "$@" ".stages[\$entry_key] = ((.stages[\$entry_key] // {status: \"pending\"}) | $expr)" <<<"$STATE")"
  E="$(jq --arg k "$KEY" '.stages[$k]' <<<"$STATE")"
}

RENDER='
def box: {"pending": "[ ]", "in-progress": "[-]", "plan-awaiting": "[?]", "awaiting": "[?]", "revising": "[R]", "completed": "[x]", "skipped": "[S]"}[.] // "[ ]";
def cap: (.[0:1] | ascii_upcase) + .[1:];
def human: {"pending": "Not started", "in-progress": "In progress", "plan-awaiting": "Waiting for approval of the code plan",
  "awaiting": "Waiting for approval", "revising": "Revising after feedback", "completed": "Completed", "skipped": "Skipped"}[.] // .;
def line: "- \(entry($s).status | box) \(.slug)\(if (entry($s).status) == "plan-awaiting" then " (plan approval)" else "" end)";
instances($cat; $sc; $s) as $ins
| cur($cat; $sc; $s) as $c
| $sc.stages as $in
| [ "# myaidlc State", "",
    "<!-- Generated by myaidlc-engine.sh from state.json on every change. Do not edit. -->", "",
    "## Project Information",
    "- **Intent**: \($s.intent)",
    "- **Request**: \($s.request_preview)",
    "- **Scope**: \($s.scope) (\($sc.title))",
    "- **Depth**: \($s.depth)",
    "- **Started**: \($s.created)",
    "- **Units**: \(if (($s.units // []) | length) > 0 then ($s.units | join(", ")) else "not planned yet (one unit, main, if none are planned)" end)",
    "- **Guard**: \($s.guard)",
    "",
    "## Workspace State",
    "- **Git**: \($s.workspace.git)",
    "- **Branch**: \($s.workspace.branch)",
    "- **Start Commit**: \($s.workspace.head)",
    "- **Tracked Files**: \($s.workspace.tracked_files)",
    "",
    "## Phase Progress" ]
  + [ phases[] as $p | "- **\($p | cap)**: \(phase_status($cat; $sc; $s; $p))" ]
  + [ "", "## Stage Progress" ]
  + [ phases[] as $p
      | ([ $cat[] | select(.phase == $p) ] | sort_by(.order | onum)) as $ps
      | "", "### \($p | ascii_upcase) PHASE",
        ( if $p == "construction" then
            ( effunits($s)[] as $u
              | [ $ins[] | select(.unit == $u) ] as $us
              | if ($us | length) > 0 then ("Per unit: \($u)", ($us[] | line)) else empty end ),
            ( [ $ins[] | select(.phase == $p and .unit == null) ] | if length > 0 then ("After all units:", (.[] | line)) else empty end ),
            ( $ps[] | select(.slug as $x | ($in | index($x)) == null) | "- \(.slug) — not in scope" )
          else
            ( $ps[] | . as $st
              | if ($in | index($st.slug)) == null then "- \($st.slug) — not in scope"
                else ($st + {unit: null}) | line end )
          end ) ]
  + [ "", "## Current Status",
      "- **Lifecycle Phase**: \(if $c then ($c.phase | ascii_upcase) else "COMPLETE" end)",
      "- **Current Stage**: \(if $c then ($c | ikey) else "none" end)",
      "- **Status**: \(if $s.status == "parked" then "Parked" elif $c then ($c | entry($s).status | human) else "Completed" end)",
      "- **Last Updated**: \($s.updated)",
      "", "## Session Resume Point",
      "- **Last Completed Stage**: \($s.last_completed // "none")",
      "- **Next Action**: \(if $c then "Run /myaidlc to continue with \($c.title)\(if $c.unit then " (unit \($c.unit))" else "" end)" else "Nothing left to do" end)" ]
| .[]
'

save_state() {
  STATE="$(jq --arg t "$(now)" '.updated = $t' <<<"$STATE")"
  printf '%s\n' "$STATE" > "$IDIR/state.json.tmp"
  mv "$IDIR/state.json.tmp" "$IDIR/state.json"
  q -r "$RENDER" > "$IDIR/state.md.tmp"
  mv "$IDIR/state.md.tmp" "$IDIR/state.md"
}

# audit <EVENT> [<Field> <value>]...  Appends one block and advances the sequence number.
LAST_SEQ=0
audit() {
  local ev="$1"; shift
  local heading ts
  STATE="$(jq '.seq = ((.seq // 0) + 1)' <<<"$STATE")"
  LAST_SEQ="$(jq -r '.seq' <<<"$STATE")"
  ts="$(now)"
  heading="$(printf '%s' "$ev" | tr '_' ' ' | awk '{ for (i = 1; i <= NF; i++) $i = substr($i, 1, 1) tolower(substr($i, 2)); print }')"
  {
    printf '## %s\n' "$heading"
    printf '**Seq**: %s\n**Timestamp**: %s\n**Event**: %s\n' "$LAST_SEQ" "$ts" "$ev"
    while [ $# -ge 2 ]; do
      printf '**%s**: %s\n' "$1" "$(printf '%s' "$2" | sed '2,$s/^/    /')"
      shift 2
    done
    printf '\n---\n\n'
  } >> "$IDIR/audit.md"
}

# The person's most recent words, recorded by the hooks (already masked), or --reply
REPLY_ARG=""
person_reply() {
  if [ -n "$REPLY_ARG" ]; then printf '%s' "$REPLY_ARG" | mask; return 0; fi
  local p="$RT/last-prompt.txt" a="$RT/last-answer.txt"
  if [ -f "$a" ] && { [ ! -f "$p" ] || [ "$a" -nt "$p" ]; }; then cat "$a"
  elif [ -f "$p" ]; then cat "$p"
  fi
}

NOTE=""
# The one rule for the person's say-so: the hooks count every message and every answer the
# person gives (human_count), and every step the agent drives records the count at that moment
# (agent_mark). A decision that is the person's (approve, reject, skip, decline a finding, skip a
# review, guard off, jump) needs a message or an answer after the agent's last step, and uses
# it up: one reply carries one decision. Pausing is not checked; it only stops the work.
# Without the hooks it stands aside with a note.
# The hooks run on this machine when they have left their mark in the local runtime folder.
# This is per machine on purpose: a teammate whose hooks cannot run (no jq, hooks removed)
# is not held to evidence their machine cannot record.
hooks_alive() { [ -f "$RT/hooks-alive" ]; }

human_replied() {
  if ! hooks_alive; then
    NOTE="The myaidlc hooks are not installed, so this was recorded without checking for a reply from the person. Run /myaidlc-setup to install them."
    return 0
  fi
  [ "$(jq -r '(.human_count // 0) > (.agent_mark // 0)' <<<"$STATE")" = true ]
}
require_human() {
  if human_replied; then
    mark_agent_step
    rm -f "$RT/last-request.txt"
    return 0
  fi
  refuse "No reply from the person has been recorded since your last step. This is the person's decision: ask them, and record it after they answer. Do not decide it yourself." \
    "If they already answered in a question box and this repeats, ask them once to type their answer in the chat."
}
mark_agent_step() { STATE="$(jq '.agent_mark = (.human_count // 0)' <<<"$STATE")"; }

config_get() {
  if [ -f "$CONFIG" ]; then jq -r "$1" "$CONFIG"; else jq -nr "$2"; fi
}

# ---------------------------------------------------------------------------
# Code baselines: a tree object of the working tree, taken with a private index so
# the person's index and working tree are never touched.
# ---------------------------------------------------------------------------
is_git() { git rev-parse --is-inside-work-tree >/dev/null 2>&1; }

snapshot_tree() {
  is_git || return 1
  ensure_runtime
  local idx real tree
  idx="$(mktemp "$RT/index.XXXXXX")"
  real="$(git rev-parse --git-path index)"
  if [ -f "$real" ]; then cp "$real" "$idx"; else rm -f "$idx"; fi
  GIT_INDEX_FILE="$idx" git add -A -- . ":(exclude)$D" >/dev/null 2>&1 || { rm -f "$idx"; return 1; }
  tree="$(GIT_INDEX_FILE="$idx" git write-tree)" || { rm -f "$idx"; return 1; }
  rm -f "$idx"
  printf '%s' "$tree"
}

# Files changed since the baseline of the current step (one per line)
changed_files() {
  local base cur
  base="$(ef '.base // ""')"
  [ -n "$base" ] || return 0
  cur="$(snapshot_tree)" || return 0
  git -c core.quotePath=false diff --relative --name-only --no-renames "$base" "$cur" -- || true
}

changes_json() { changed_files | jq -R -s 'split("\n") | map(select(. != ""))'; }

# ---------------------------------------------------------------------------
# start
# ---------------------------------------------------------------------------
cmd_start() {
  local scope="" label="" reqfile="" text name n i head branch tracked git=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --scope) scope="${2:-}"; shift 2 ;;
      --label) label="${2:-}"; shift 2 ;;
      --request-file) reqfile="${2:-}"; shift 2 ;;
      *) die "start: unknown argument $1" ;;
    esac
  done
  [ -n "$scope" ] || scope="$(config_get '.default_scope // "feature"' '"feature"')"
  [[ "$label" =~ ^[a-z0-9][a-z0-9-]*$ ]] || refuse "The label must be lowercase letters, digits and dashes, for example: --label saved-search"
  load_scope "$scope"
  load_catalog

  if [ "$reqfile" = "-" ]; then text="$(cat)"
  elif [ -n "$reqfile" ]; then [ -f "$reqfile" ] || die "request file not found: $reqfile"; text="$(cat "$reqfile")"
  elif [ -f "$RT/last-request.txt" ]; then text="$(cat "$RT/last-request.txt")"
  elif [ -f "$RT/last-prompt.txt" ]; then text="$(cat "$RT/last-prompt.txt")"
  else refuse "No request was recorded. Pass the person's request on standard input: myaidlc-engine.sh start --scope $scope --label $label --request-file -"
  fi
  text="$(printf '%s' "$text" | sed '1s#^[[:space:]]*/myaidlc[[:space:]]*##' | mask)"
  [ -n "$(printf '%s' "$text" | tr -d '[:space:]')" ] || refuse "The request is empty. Ask the person what they want to build or fix."

  lock
  mkdir -p "$INTENTS"
  name="$(date +%y%m%d)-$label"
  if [ -e "$INTENTS/$name" ]; then
    n=2
    while [ -e "$INTENTS/$name-$n" ]; do n=$((n + 1)); done
    name="$name-$n"
  fi
  INTENT="$name"
  IDIR="$INTENTS/$name"
  mkdir -p "$IDIR"
  printf '# Request\n\n%s\n' "$text" > "$IDIR/request.md"
  : > "$IDIR/audit.md"
  printf '# myaidlc Audit Log\n\n' >> "$IDIR/audit.md"

  head=""; branch=""; tracked=0
  if is_git; then
    git=true
    head="$(git rev-parse --verify -q HEAD 2>/dev/null || true)"
    branch="$(git symbolic-ref --short -q HEAD 2>/dev/null || echo "(detached)")"
    tracked="$(git ls-files | wc -l | tr -d ' ')"
  fi
  local hooks=false
  if hooks_alive; then hooks=true; fi
  STATE="$(jq -n --arg i "$name" --arg l "$label" --arg sc "$scope" --arg d "$(jq -r .depth <<<"$SCOPE")" \
    --arg t "$(now)" --arg g "$(config_get '.guard // "on"' '"on"')" --argjson hooks "$hooks" \
    --arg prev "$(printf '%s' "$text" | head -n 1)" \
    --argjson git "$git" --arg head "$head" --arg branch "$branch" --arg tracked "$tracked" '
    {version: 1, intent: $i, label: $l, scope: $sc, depth: $d, created: $t, updated: $t, status: "active",
     guard: $g, seq: 0, human_count: 0, agent_mark: 0, hooks_seen: $hooks, request_preview: ($prev | .[0:120]),
     workspace: {git: $git, head: $head, branch: $branch, tracked_files: ($tracked | tonumber)},
     units: [], stages: {}, carry: [], verified: [], last_completed: null}')"

  audit WORKFLOW_STARTED Intent "$name" Scope "$scope" Request "$(jq -r .request_preview <<<"$STATE")"
  audit PHASE_STARTED Phase initialization
  # Initialization runs here, without a gate: the engine detects the workspace and creates the state
  for i in workspace-detection state-init; do
    if jq -e --arg x "$i" '.stages | index($x)' <<<"$SCOPE" >/dev/null; then
      KEY="$i"
      set_entry '.status = "completed" | .completed = $t' --arg t "$(now)"
      if [ "$i" = workspace-detection ]; then
        audit WORKSPACE_DETECTED Git "$git" Branch "$branch" "Start Commit" "$head" "Tracked Files" "$tracked"
      fi
      audit STAGE_COMPLETED Stage "$i" Agent engine
      STATE="$(jq --arg k "$i" '.last_completed = $k' <<<"$STATE")"
    fi
  done
  if [ "$(q -r 'phase_status($cat; $sc; $s; "initialization")')" = Verified ]; then
    audit PHASE_VERIFIED Phase initialization
    STATE="$(jq '.verified += ["initialization"]' <<<"$STATE")"
  fi
  save_state
  rm -f "$RT/last-request.txt"
  printf '%s\n' "$name" > "$RT/active-intent"
  unlock
  cmd_next
}

# ---------------------------------------------------------------------------
# next: the one directive for what to do now (read-only)
# ---------------------------------------------------------------------------
open_intents() {
  local f
  for f in "$INTENTS"/*/state.json; do
    [ -f "$f" ] || continue
    jq -c 'select(.status != "completed") | {name: .intent, scope: .scope, status: .status, request: .request_preview}' "$f"
  done | jq -s '.'
}

existing_json() {
  jq -r '.[]' <<<"$1" | while IFS= read -r p; do
    if [ -n "$p" ] && [ -e "$p" ]; then printf '%s\n' "$p"; fi
  done | jq -R -s 'split("\n") | map(select(. != ""))'
}

cmd_next() {
  local err
  if [ -f "$RT/active-intent" ] && ! err="$( (load_active) 2>&1 >/dev/null)"; then
    jq -n --arg m "${err#error: }" '{directive: "error", message: $m}'
    return 0
  fi
  if ! load_active; then
    local open count
    open="$(open_intents)"
    count="$(jq 'length' <<<"$open")"
    if [ "$count" = 1 ]; then
      ensure_runtime
      jq -r '.[0].name' <<<"$open" > "$RT/active-intent"
      load_active
    else
      jq -n --argjson o "$open" '
        if ($o | length) == 0 then {directive: "ask", reason: "no-work", message: "There is no work in progress. Ask the person what they want to build or fix."}
        else {directive: "ask", reason: "choose-work", message: "Several pieces of work are open. Ask the person which one to continue.", options: $o} end'
      return 0
    fi
  fi
  if [ "$(jq -r .status <<<"$STATE")" = parked ]; then
    jq -n --arg i "$INTENT" '{directive: "parked", intent: $i, message: "This work is paused. It continues when the person asks to resume."}'
    return 0
  fi
  load_current
  if [ -z "$KEY" ]; then
    jq -n --arg i "$INTENT" --arg d "$IDIR" '{directive: "done", intent: $i, record: $d, message: "Every step of this work is finished."}'
    return 0
  fi

  local draft prods cons rules rk recorded targets note="" verify
  draft="$(q --arg idir "$IDIR" --arg skill "$SKILL_REL" --arg key "$KEY" '
    instances($cat; $sc; $s) as $ins
    | ($ins[] | select(ikey == $key)) as $i
    | ($i | entry($s)) as $e
    | scoped($cat; $sc) as $st
    | outdir($idir; $i) as $od
    | {
        stage: $i.slug, unit: $i.unit, phase: $i.phase, title: $i.title, status: $e.status,
        step: (if $i.gate == "plan-and-checkpoint" then (if ($e.plan_approved // false) then "build" else "plan" end) else null end),
        stage_file: $i.file, agent: $i.lead_agent, mode: $i.mode, gate: $i.gate, output_dir: $od,
        source_writes: $i.source_writes,
        produces: [ $i.produces[] | {name: ., path: "\($od)/\(.)",
          candidates: ["docs/myaidlc/memory/templates/\(.)", "\($skill)/templates/\(.)"]} ],
        consumes: ( ["\($idir)/request.md"]
          + [ $i.consumes[] as $n | $st[] | select(.produces | index($n)) as $p
              | if $p.for_each == "unit" then
                  (if $i.unit then ["\($idir)/construction/\($i.unit)/\($p.slug)/\($n)"]
                   else [ effunits($s)[] | "\($idir)/construction/\(.)/\($p.slug)/\($n)" ] end)
                else ["\($idir)/\($p.phase)/\($p.slug)/\($n)"] end
              | .[] ] ),
        rules: ["\($skill)/rules/defaults.md", "AGENTS.md", "docs/myaidlc/memory/project.md", "docs/myaidlc/memory/phases/\($i.phase).md"],
        review_kind: review_needed($ins; $i; $e),
        reviews: ($e.review // {}),
        doc_targets: (
          if $i.review == "phase-doc" then
            [ $ins[] | select(.phase == $i.phase) | outdir($idir; .) as $o | .produces[] | "\($o)/\(.)" ]
          else
            [ $i.produces[] | "\($od)/\(.)" ]
            + [ $i.consumes[] as $n | $st[] | select((.produces | index($n)) and .for_each == "unit" and $i.unit != null)
                | "\($idir)/construction/\($i.unit)/\(.slug)/\($n)" ]
          end),
        carry: ($s.carry // []),
        break_point: (
          ([ $ins[] | ikey ] | index($key)) as $n
          | if $e.status == "pending" and (($e.jumped // false) | not) and $n != null and $n > 0 then
              $ins[$n - 1] as $p
              | $p.phase != "initialization" and ($p.phase != $i.phase or $p.unit != $i.unit)
            else false end)
      }')"

  prods="$(jq -c '.produces[]' <<<"$draft" | while IFS= read -r p; do
    local t="" c
    while IFS= read -r c; do
      if [ -z "$t" ] && [ -f "$c" ]; then t="$c"; fi
    done < <(jq -r '.candidates[]' <<<"$p")
    jq -c --arg t "$t" '{name, path, template: $t}' <<<"$p"
  done | jq -s '.')"
  cons="$(existing_json "$(jq -c '.consumes' <<<"$draft")")"
  rules="$(existing_json "$(jq -c '.rules' <<<"$draft")")"

  rk="$(jq -r '.review_kind' <<<"$draft")"
  if [ "$rk" = code-if-changed ]; then
    if [ -n "$(changed_files)" ]; then rk=code; else rk=none; fi
  fi
  targets="[]"
  case "$rk" in
    doc) targets="$(existing_json "$(jq -c '.doc_targets' <<<"$draft")")" ;;
    code) targets="$(changes_json)" ;;
  esac
  recorded="$(jq --arg k "$rk" '$k == "none" or (.reviews[$k] != null)' <<<"$draft")"
  verify="$(config_get '.verify_commands // []' '[]')"
  if ! hooks_alive; then
    note="The myaidlc hooks are not installed, so approvals are not checked and the guard is off. Run /myaidlc-setup to install them."
  fi
  jq -n --argjson d "$draft" --argjson prods "$prods" --argjson cons "$cons" --argjson rules "$rules" \
    --arg rk "$rk" --argjson recorded "$recorded" --argjson targets "$targets" --argjson verify "$verify" \
    --arg intent "$INTENT" --arg scope "$(jq -r .scope <<<"$STATE")" --arg depth "$(jq -r .depth <<<"$STATE")" \
    --arg guard "$(jq -r .guard <<<"$STATE")" --arg note "$note" '
    {directive: "run-stage", intent: $intent, scope: $scope, depth: $depth,
     phase: $d.phase, stage: $d.stage, unit: $d.unit, title: $d.title, status: $d.status, step: $d.step,
     stage_file: $d.stage_file, agent: $d.agent, mode: $d.mode, output_dir: $d.output_dir,
     produces: $prods, consumes: $cons, rules: $rules, gate: $d.gate,
     review: {required: $rk, recorded: $recorded, targets: $targets},
     carry_reviews: $d.carry, verify_commands: $verify, guard: $guard, source_writes: $d.source_writes,
     break_point: $d.break_point, note: $note}'
}

# ---------------------------------------------------------------------------
# report and the transition rules (the single owner of every transition)
# ---------------------------------------------------------------------------
parse_stage_args() {
  STAGE_ARG=""; UNIT_ARG=""; RESULT_ARG=""; REASON_ARG=""; REPLY_ARG=""
  KIND_ARG=""; FILE_ARG=""; P0=""; P1=""; P2=""; P3=""; APPLIED_ARG=""; DECLINED=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --stage) STAGE_ARG="${2:-}"; shift 2 ;;
      --unit) UNIT_ARG="${2:-}"; shift 2 ;;
      --result) RESULT_ARG="${2:-}"; shift 2 ;;
      --reason) REASON_ARG="${2:-}"; shift 2 ;;
      --reply) REPLY_ARG="${2:-}"; shift 2 ;;
      --kind) KIND_ARG="${2:-}"; shift 2 ;;
      --file) FILE_ARG="${2:-}"; shift 2 ;;
      --p0) P0="${2:-}"; shift 2 ;;
      --p1) P1="${2:-}"; shift 2 ;;
      --p2) P2="${2:-}"; shift 2 ;;
      --p3) P3="${2:-}"; shift 2 ;;
      --applied) APPLIED_ARG="${2:-}"; shift 2 ;;
      --declined-by-human) DECLINED=1; shift ;;
      *) die "unknown argument $1" ;;
    esac
  done
  [ -n "$STAGE_ARG" ] || die "--stage is required"
}

# Loads the work and checks that the named stage is the current step
require_current() {
  load_active || refuse "There is no work in progress. Start one with: myaidlc-engine.sh start --scope <scope> --label <label>"
  [ "$(jq -r .status <<<"$STATE")" != parked ] || refuse "This work is paused. Resume it first: myaidlc-engine.sh resume"
  load_current
  [ -n "$KEY" ] || refuse "Every step of this work is already finished."
  local cs cu
  cs="$(cf .slug)"; cu="$(cf '.unit // ""')"
  if [ "$STAGE_ARG" != "$cs" ] || { [ -n "$UNIT_ARG" ] && [ "$UNIT_ARG" != "$cu" ]; }; then
    refuse "The current step is $KEY, not $STAGE_ARG${UNIT_ARG:+@$UNIT_ARG}. Run myaidlc-engine.sh next to see it."
  fi
}

# The review kind the current step needs now: none, doc or code
review_kind_now() {
  local rk
  rk="$(q -r --arg key "$KEY" 'instances($cat; $sc; $s) as $ins | ($ins[] | select(ikey == $key)) as $i | review_needed($ins; $i; ($i | entry($s)))')"
  if [ "$rk" = code-if-changed ]; then
    if [ -n "$(changed_files)" ]; then rk=code; else rk=none; fi
  fi
  printf '%s' "$rk"
}

require_review() {
  local rk
  rk="$(review_kind_now)"
  [ "$rk" = none ] && return 0
  if [ "$(jq -r --arg k "$rk" '(.review // {})[$k] != null' <<<"$E")" != true ]; then
    if [ "$rk" = doc ]; then
      refuse "This step needs a document review before it can go on. Run the document review in protocol/review.md, apply every P0 and P1 finding, then record it with: myaidlc-engine.sh review --stage $(cf .slug)$(unit_flag) --kind doc --file <review file> --p0 N --p1 N --p2 N --p3 N --applied P0,P1" \
        "If the person says the review is not needed: myaidlc-engine.sh review-skip --stage $(cf .slug)$(unit_flag) --kind doc"
    else
      refuse "This step changed code, so it needs a code review before it can go on. List the changes with: myaidlc-engine.sh changes --diff. Run the code review in protocol/review.md, apply every P0 and P1 finding, then record it with: myaidlc-engine.sh review --stage $(cf .slug)$(unit_flag) --kind code --file <review file> --p0 N --p1 N --p2 N --p3 N --applied P0,P1" \
        "If the person says the review is not needed: myaidlc-engine.sh review-skip --stage $(cf .slug)$(unit_flag) --kind code"
    fi
  fi
}

unit_flag() { local u; u="$(cf '.unit // ""')"; if [ -n "$u" ]; then printf ' --unit %s' "$u"; fi; }

# After a step finishes: phase verification and completion of the whole work
after_finish() {
  local p="$1" ps
  STATE="$(jq --arg k "$KEY" '.last_completed = $k' <<<"$STATE")"
  ps="$(q -r --arg p "$p" 'phase_status($cat; $sc; $s; $p)')"
  if [ "$ps" = Verified ] && ! jq -e --arg p "$p" '(.verified // []) | index($p)' <<<"$STATE" >/dev/null; then
    audit PHASE_VERIFIED Phase "$p"
    STATE="$(jq --arg p "$p" '.verified = ((.verified // []) + [$p])' <<<"$STATE")"
  fi
  if [ "$(q 'cur($cat; $sc; $s) == null')" = true ]; then
    STATE="$(jq '.status = "completed"' <<<"$STATE")"
    audit WORKFLOW_COMPLETED Intent "$INTENT"
  fi
}

say_ok() {
  printf 'ok: %s is %s\n' "$KEY" "$(ef .status)"
  if [ -n "$NOTE" ]; then printf 'note: %s\n' "$NOTE"; fi
}


cmd_report() {
  parse_stage_args "$@"
  [ -n "$RESULT_ARG" ] || die "--result is required"
  lock
  require_current
  local st phase gate slug unit agent pa
  st="$(ef .status)"; phase="$(cf .phase)"; gate="$(cf .gate)"; slug="$(cf .slug)"; unit="$(cf '.unit // ""')"
  agent="$(cf .lead_agent)"; pa="$(ef '.plan_approved // false')"

  case "$RESULT_ARG" in
    started)
      case "$st" in
        in-progress|revising) say_ok; return 0 ;;
        pending) ;;
        *) refuse "$KEY is waiting for the person's decision. Present the question again instead of starting over." ;;
      esac
      if [ "$(q -r --arg p "$phase" 'phase_status($cat; $sc; $s; $p)')" = Pending ]; then
        audit PHASE_STARTED Phase "$phase"
      fi
      if [ -n "$unit" ] && [ "$(jq '(.units // []) | length' <<<"$STATE")" = 0 ]; then
        STATE="$(jq '.units = ["main"]' <<<"$STATE")"
        audit UNITS_SET Units main Source "default (no units were planned)"
      fi
      set_entry '.status = "in-progress" | .started = $t' --arg t "$(now)"
      if [ "$(cf .review)" = code-if-changed ] || [ "$(cf .source_writes)" = allowed ]; then
        local base
        if base="$(snapshot_tree)"; then set_entry '.base = $b' --arg b "$base"; fi
      fi
      audit STAGE_STARTED Stage "$slug" Unit "$unit" Agent "$agent"
      ;;
    plan-ready)
      [ "$gate" = plan-and-checkpoint ] || refuse "$slug has no plan approval. Report awaiting or completed instead."
      [ "$st" = in-progress ] && [ "$pa" != true ] || refuse "$KEY is not writing its plan now (it is $st)."
      require_review
      set_entry '.status = "plan-awaiting" | .gate_kind = "plan"'
      audit STAGE_AWAITING_APPROVAL Stage "$slug" Unit "$unit" Gate "plan approval"
      set_entry '.gate_seq = $n' --argjson n "$LAST_SEQ"
      ;;
    plan-approved)
      [ "$st" = plan-awaiting ] || refuse "$KEY is not waiting for plan approval (it is $st)."
      require_human
      local base=""
      base="$(snapshot_tree)" || base=""
      set_entry '.status = "in-progress" | .plan_approved = true | .base = $b | .gate_kind = null' --arg b "$base"
      audit PLAN_APPROVAL_RECORDED Stage "$slug" Unit "$unit" "Person Reply" "$(person_reply)"
      STATE="$(jq '.carry = []' <<<"$STATE")"
      ;;
    awaiting)
      case "$gate" in
        approval) ;;
        plan-and-checkpoint) [ "$pa" = true ] || refuse "The code plan for $KEY has not been approved yet. Report plan-ready to ask for plan approval first." ;;
        *) refuse "$slug has no approval gate. Report completed instead." ;;
      esac
      [ "$st" = in-progress ] || refuse "$KEY is $st, not in progress."
      require_review
      set_entry '.status = "awaiting" | .gate_kind = "checkpoint"'
      audit STAGE_AWAITING_APPROVAL Stage "$slug" Unit "$unit" Gate "$([ "$gate" = approval ] && echo approval || echo "unit checkpoint")"
      set_entry '.gate_seq = $n' --argjson n "$LAST_SEQ"
      ;;
    approved)
      [ "$st" = awaiting ] || refuse "$KEY is not waiting for approval (it is $st)."
      require_human
      set_entry '.status = "completed" | .completed = $t | .gate_kind = null' --arg t "$(now)"
      audit GATE_APPROVED Stage "$slug" Unit "$unit" "Person Reply" "$(person_reply)"
      audit STAGE_COMPLETED Stage "$slug" Unit "$unit"
      STATE="$(jq '.carry = []' <<<"$STATE")"
      after_finish "$phase"
      ;;
    rejected)
      case "$st" in awaiting|plan-awaiting) ;; *) refuse "$KEY is not waiting for a decision (it is $st)." ;; esac
      require_human
      local kind
      if [ "$st" = plan-awaiting ]; then kind=doc; else kind="$(review_kind_now)"; fi
      set_entry '.status = "revising" | .revisions = ((.revisions // 0) + 1) | (if $k != "none" then .review[$k] = null else . end)' --arg k "$kind"
      audit GATE_REJECTED Stage "$slug" Unit "$unit" "Person Reply" "$(person_reply)" Reason "$REASON_ARG"
      audit STAGE_REVISING Stage "$slug" Unit "$unit" Revision "$(ef .revisions)"
      ;;
    revised)
      [ "$st" = revising ] || refuse "$KEY is not being revised (it is $st)."
      local gk; gk="$(ef '.gate_kind // "checkpoint"')"
      if [ "$gk" = plan ]; then
        require_review
        set_entry '.status = "plan-awaiting"'
      else
        set_entry '.status = "in-progress"'
        require_review
        set_entry '.status = "awaiting"'
      fi
      audit STAGE_AWAITING_APPROVAL Stage "$slug" Unit "$unit" Gate "$([ "$gk" = plan ] && echo "plan approval" || echo approval)" Revision "$(ef .revisions)"
      set_entry '.gate_seq = $n' --argjson n "$LAST_SEQ"
      ;;
    completed)
      [ "$gate" = none ] || refuse "$slug ends with the person's approval. Report awaiting and present the question instead."
      [ "$st" = in-progress ] || refuse "$KEY is $st, not in progress. Report started first."
      require_review
      set_entry '.status = "completed" | .completed = $t' --arg t "$(now)"
      audit STAGE_COMPLETED Stage "$slug" Unit "$unit"
      after_finish "$phase"
      ;;
    skipped)
      require_human
      local owed_kind; owed_kind="$(review_kind_now)"
      if [ "$owed_kind" != none ] && [ "$(jq -r --arg k "$owed_kind" '(.review // {})[$k] != null' <<<"$E")" != true ]; then
        if [ "$owed_kind" = doc ]; then
          audit REVIEW_SKIPPED Stage "$slug" Unit "$unit" Kind doc Reason "the step was skipped at the person's request, so the review of this phase's documents was skipped with it"
          NOTE="The document review of this phase was skipped together with the step."
        else
          audit REVIEW_SKIPPED Stage "$slug" Unit "$unit" Kind code Reason "the step was skipped at the person's request, so the review of its code changes was skipped with it"
          NOTE="The code changes of this step were not reviewed, because the step was skipped."
        fi
      fi
      set_entry '.status = "skipped" | .gate_kind = null'
      audit STAGE_SKIPPED Stage "$slug" Unit "$unit" Reason "$REASON_ARG" "Person Reply" "$(person_reply)"
      after_finish "$phase"
      ;;
    *) die "unknown result: $RESULT_ARG" ;;
  esac
  case "$RESULT_ARG" in started|plan-ready|awaiting|revised|completed) mark_agent_step ;; esac
  save_state
  say_ok
}

cmd_review() {
  parse_stage_args "$@"
  case "$KIND_ARG" in doc|code) ;; *) die "--kind must be doc or code" ;; esac
  local v
  for v in "$P0" "$P1" "$P2" "$P3"; do [[ "$v" =~ ^[0-9]+$ ]] || die "--p0 to --p3 must be counts"; done
  [ -n "$FILE_ARG" ] && [ -f "$FILE_ARG" ] || die "--file must name the saved review file"
  case "$FILE_ARG" in docs/*) ;; *) refuse "Save the review under docs/ (in the step's output folder) and pass that path." ;; esac
  lock
  require_current
  case "$(ef .status)" in in-progress|revising) ;; *) refuse "$KEY is $(ef .status); a review is recorded while the step is in progress or being revised." ;; esac
  local applied=",${APPLIED_ARG// /},"
  if [ "$DECLINED" = 0 ]; then
    if [ "$((10#$P0))" -gt 0 ] && [[ "$applied" != *,P0,* ]]; then
      refuse "The review found $P0 P0 finding(s). Apply every P0 finding and pass --applied P0,P1. If the person decided not to apply one, add --declined-by-human."
    fi
    if [ "$((10#$P1))" -gt 0 ] && [[ "$applied" != *,P1,* ]]; then
      refuse "The review found $P1 P1 finding(s). Apply every P1 finding and pass --applied P0,P1. If the person decided not to apply one, add --declined-by-human."
    fi
  fi
  local declined_reply=""
  if [ "$DECLINED" = 1 ]; then require_human; declined_reply="$(person_reply)"; fi
  set_entry '.review[$k] = {file: $f, p0: ($a | tonumber), p1: ($b | tonumber), p2: ($c | tonumber), p3: ($d | tonumber), applied: $ap, declined: $dc}' \
    --arg k "$KIND_ARG" --arg f "$FILE_ARG" --arg a "$P0" --arg b "$P1" --arg c "$P2" --arg d "$P3" --arg ap "$APPLIED_ARG" --argjson dc "$([ $DECLINED = 1 ] && echo true || echo false)"
  if [ "$(cf .gate)" = none ] && [ $((10#$P2 + 10#$P3)) -gt 0 ]; then
    STATE="$(jq --arg f "$FILE_ARG" '.carry = ((.carry // []) + [$f] | unique)' <<<"$STATE")"
  fi
  audit REVIEW_COMPLETED Stage "$(cf .slug)" Unit "$(cf '.unit // ""')" Kind "$KIND_ARG" File "$FILE_ARG" \
    P0 "$P0" P1 "$P1" P2 "$P2" P3 "$P3" Applied "$APPLIED_ARG" "Declined By Person" "$declined_reply"
  mark_agent_step
  save_state
  printf 'ok: %s review recorded for %s\n' "$KIND_ARG" "$KEY"
}

cmd_review_skip() {
  parse_stage_args "$@"
  case "$KIND_ARG" in doc|code) ;; *) die "--kind must be doc or code" ;; esac
  lock
  require_current
  require_human
  set_entry '.review[$k] = {skipped: true}' --arg k "$KIND_ARG"
  audit REVIEW_SKIPPED Stage "$(cf .slug)" Unit "$(cf '.unit // ""')" Kind "$KIND_ARG" "Person Reply" "$(person_reply)"
  save_state
  printf 'ok: %s review skipped for %s at the person'"'"'s request\n' "$KIND_ARG" "$KEY"
}

cmd_units() {
  [ "${1:-}" = --set ] || die "usage: units --set <a,b,...>"
  local list="${2:-}" u units
  [ -n "$list" ] || die "units --set needs a comma-separated list"
  units="$(printf '%s' "$list" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | sed '/^$/d')"
  while IFS= read -r u; do
    [[ "$u" =~ ^[a-z0-9][a-z0-9-]*$ ]] || refuse "Unit names must be lowercase letters, digits and dashes: $u"
  done <<<"$units"
  lock
  load_active || refuse "There is no work in progress."
  if [ "$(jq '[.stages | to_entries[] | select((.key | contains("@")) and .value.status != "pending")] | length' <<<"$STATE")" != 0 ]; then
    refuse "Construction has already started, so the units cannot change now. To re-plan, jump back first: myaidlc-engine.sh jump --stage delivery-planning"
  fi
  local arr
  arr="$(jq -R -s 'split("\n") | map(select(. != "")) | reduce .[] as $u ([]; if index([$u]) then . else . + [$u] end)' <<<"$units")"
  STATE="$(jq --argjson a "$arr" '.units = $a | .stages |= with_entries(select((.key | contains("@") | not) or ((.key | split("@") | .[1]) as $u | $a | index($u))))' <<<"$STATE")"
  audit UNITS_SET Units "$(jq -r 'join(", ")' <<<"$arr")" Source planning
  mark_agent_step
  save_state
  printf 'ok: units are %s\n' "$(jq -r 'join(", ")' <<<"$arr")"
}

cmd_changes() {
  load_active || refuse "There is no work in progress."
  load_current
  [ -n "$KEY" ] || refuse "Every step of this work is already finished."
  local base cur
  base="$(ef '.base // ""')"
  [ -n "$base" ] || refuse "No code baseline is recorded for $KEY yet (it is taken when the code plan is approved, or when a test step starts)."
  cur="$(snapshot_tree)" || die "could not read the working tree with git"
  if [ "${1:-}" = --diff ]; then
    git -c core.quotePath=false diff --relative --no-renames "$base" "$cur" --
  else
    git -c core.quotePath=false diff --relative --name-only --no-renames "$base" "$cur" --
  fi
}

cmd_jump() {
  parse_stage_args "$@"
  lock
  load_active || refuse "There is no work in progress."
  load_current
  local target ti ci keys
  target="$STAGE_ARG${UNIT_ARG:+@$UNIT_ARG}"
  ti="$(q -r --arg t "$target" '[instances($cat; $sc; $s)[] | ikey] | index($t) // -1')"
  if [ "$ti" = -1 ]; then
    [ -z "$UNIT_ARG" ] || refuse "$STAGE_ARG has no unit $UNIT_ARG in this work. The units are: $(q -r 'effunits($s) | join(", ")')"
    # a unit stage named without its unit means the current unit, else the first one
    target="$(q -r --arg t "$STAGE_ARG" --arg k "$KEY" '[instances($cat; $sc; $s)[] | select(.slug == $t) | ikey] as $ks
      | if ($ks | index($k)) then $k else ($ks[0] // "") end')"
    [ -n "$target" ] || refuse "$STAGE_ARG is not a step of this work. Run myaidlc-engine.sh status to see the steps."
    ti="$(q -r --arg t "$target" '[instances($cat; $sc; $s)[] | ikey] | index($t)')"
  fi
  if [ "$(q -r --arg t "$target" '[instances($cat; $sc; $s)[] | select(ikey == $t)][0].lead_agent')" = engine ]; then
    refuse "$target is run by the engine when the work starts; it cannot be jumped to."
  fi
  if [ -z "$KEY" ]; then ci="$(q -r '[instances($cat; $sc; $s)[]] | length')"
  else ci="$(q -r --arg k "$KEY" '[instances($cat; $sc; $s)[] | ikey] | index($k)')"; fi
  require_human
  local reply; reply="$(person_reply)"
  if [ "$ti" -gt "$ci" ]; then
    local owed
    owed="$(q -r --argjson a "$ci" --argjson b "$ti" '[instances($cat; $sc; $s)] as [$ins] | $ins[$a:$b][] | . as $i
      | select((entry($s).status | finished | not) and review_needed($ins; $i; entry($s)) == "doc" and ((entry($s).review // {}).doc == null)) | ikey')"
    keys="$(q -r --argjson a "$ci" --argjson b "$ti" '[instances($cat; $sc; $s)[]] | .[$a:$b][] | select(entry($s).status | finished | not) | ikey')"
    local k
    while IFS= read -r k; do
      [ -n "$k" ] || continue
      STATE="$(jq --arg k "$k" '.stages[$k] = ((.stages[$k] // {}) + {status: "skipped"})' <<<"$STATE")"
    done <<<"$keys"
    if [ -n "$owed" ]; then
      audit REVIEW_SKIPPED Stages "$(printf '%s' "$owed" | paste -sd ',' - | sed 's/,/, /g')" Kind doc Reason "the steps that end a phase were jumped over at the person's request, so their document reviews were skipped"
      NOTE="The document review of a phase was skipped by this jump."
    fi
    audit STAGE_JUMPED From "${KEY:-end}" To "$target" Skipped "$(printf '%s' "$keys" | paste -sd ',' - | sed 's/,/, /g')" "Person Reply" "$reply"
  elif [ "$ti" -lt "$ci" ] || [ -z "$KEY" ]; then
    keys="$(q -r --argjson a "$ti" '[instances($cat; $sc; $s)[]] | .[$a:][] | select(entry($s).status != "pending") | ikey')"
    local k
    while IFS= read -r k; do
      [ -n "$k" ] || continue
      STATE="$(jq --arg k "$k" '.stages[$k] = {status: "pending"}' <<<"$STATE")"
    done <<<"$keys"
    STATE="$(jq '.status = (if .status == "completed" then "active" else .status end)' <<<"$STATE")"
    audit STAGE_REOPENED From "${KEY:-end}" To "$target" Reopened "$(printf '%s' "$keys" | paste -sd ',' - | sed 's/,/, /g')" "Person Reply" "$reply"
  else
    # the current step itself: start it over (a new plan, or a redo)
    STATE="$(jq --arg k "$target" '.stages[$k] = {status: "pending"}' <<<"$STATE")"
    audit STAGE_REOPENED From "$target" To "$target" Reopened "$target" "Person Reply" "$reply"
  fi
  # the person moved here on purpose: this step is not a break point
  STATE="$(jq --arg k "$target" '.stages[$k] = ((.stages[$k] // {status: "pending"}) + {jumped: true})' <<<"$STATE")"
  # keep the verified phases consistent with the new positions
  STATE="$(q '$s | .verified = [ phases[] as $p | select(phase_status($cat; $sc; $s; $p) == "Verified") | $p ]')"
  save_state
  printf 'ok: the current step is now %s\n' "$target"
  if [ -n "$NOTE" ]; then printf 'note: %s\n' "$NOTE"; fi
}

cmd_park() {
  lock
  load_active || refuse "There is no work in progress."
  [ "$(jq -r .status <<<"$STATE")" = active ] || refuse "This work is $(jq -r .status <<<"$STATE"), not active."
  STATE="$(jq '.status = "parked"' <<<"$STATE")"
  audit WORKFLOW_PARKED Intent "$INTENT" "Person Reply" "$(person_reply)"
  save_state
  echo "ok: $INTENT is paused"
}

cmd_resume() {
  lock
  load_active || refuse "There is no work in progress."
  [ "$(jq -r .status <<<"$STATE")" = parked ] || { echo "ok: $INTENT is not paused"; return 0; }
  STATE="$(jq '.status = "active"' <<<"$STATE")"
  audit WORKFLOW_RESUMED Intent "$INTENT"
  save_state
  echo "ok: $INTENT continues"
}

cmd_status() {
  if ! load_active; then
    local open; open="$(open_intents)"
    if [ "$(jq length <<<"$open")" = 0 ]; then echo "No work in progress."; else
      echo "No work is selected. Open work:"; jq -r '.[] | "- \(.name) (\(.scope), \(.status)): \(.request)"' <<<"$open"; fi
    return 0
  fi
  load_current
  local alive=false
  if hooks_alive; then alive=true; fi
  q -r --arg key "$KEY" --argjson alive "$alive" '
    def human: {"pending": "ready to start", "in-progress": "in progress", "plan-awaiting": "waiting for your approval of the code plan",
      "awaiting": "waiting for your approval", "revising": "being revised after your feedback"}[.] // .;
    [instances($cat; $sc; $s)[]] as $ins
    | "Work: \($s.intent) (\($sc.title)) — \($s.request_preview)",
      (if $s.status == "parked" then "Paused. Say /myaidlc resume to continue." else empty end),
      (if $key == "" then "Every step is finished."
       else ($ins[] | select(ikey == $key) | "Now: \(.title)\(if .unit then " — unit \(.unit)" else "" end), \(entry($s).status | human)") end),
      "Done: \([ $ins[] | select(entry($s).status | finished) ] | length) of \($ins | length) steps",
      (if $alive then empty else "Note: the myaidlc hooks are not installed, so approvals are not checked. Run /myaidlc-setup." end),
      (if $s.guard == "off" then "Note: the guard is off for this work." else empty end),
      "Record: docs/myaidlc/intents/\($s.intent)/state.md"'
}

cmd_intent() {
  case "${1:-list}" in
    list)
      local f a=""
      [ -f "$RT/active-intent" ] && a="$(head -n 1 "$RT/active-intent")"
      for f in "$INTENTS"/*/state.json; do
        [ -f "$f" ] || continue
        jq -r --arg a "$a" '"\(if .intent == $a then "*" else " " end) \(.intent)  \(.scope)  \(.status)  \(.request_preview)"' "$f"
      done
      ;;
    switch)
      local n="${2:-}"
      [[ "$n" =~ ^[0-9]{6}-[a-z0-9][a-z0-9-]*$ ]] && [ -f "$INTENTS/$n/state.json" ] || refuse "No work named ${n:-?}. Run: myaidlc-engine.sh intent list"
      ensure_runtime
      printf '%s\n' "$n" > "$RT/active-intent"
      echo "ok: now working on $n"
      ;;
    *) die "usage: intent list | intent switch <name>" ;;
  esac
}

cmd_guard() {
  local v="${1:-}"
  case "$v" in on|off) ;; *) die "usage: guard on | guard off" ;; esac
  lock
  load_active || refuse "There is no work in progress, so no guard is active."
  STATE="$(jq --arg v "$v" '.guard = $v' <<<"$STATE")"
  if [ "$v" = off ]; then
    require_human
    audit GUARD_STOOD_ASIDE Scope "this work" "Person Reply" "$(person_reply)"
  else
    audit GUARD_RESTORED Scope "this work"
  fi
  save_state
  echo "ok: the guard is $v for $INTENT"
}

cmd_learn() {
  [ "${1:-}" = --rule-file ] || die "usage: learn --rule-file <path>|-"
  local src="${2:-}" text
  if [ "$src" = - ]; then text="$(cat)"; else [ -f "$src" ] || die "rule file not found: $src"; text="$(cat "$src")"; fi
  text="$(printf '%s' "$text" | mask)"
  [ -n "$(printf '%s' "$text" | tr -d '[:space:]')" ] || die "the rule is empty"
  lock
  load_active || refuse "There is no work in progress."
  local pm="$D/memory/project.md"
  mkdir -p "$D/memory"
  [ -f "$pm" ] || printf '# Project rules\n' > "$pm"
  if ! grep -qx '## Learned rules' "$pm"; then printf '\n## Learned rules\n\n' >> "$pm"; fi
  printf -- '- %s (learned in %s, %s)\n' "$(printf '%s' "$text" | sed '2,$s/^/  /')" "$INTENT" "$(date +%Y-%m-%d)" >> "$pm"
  audit RULE_LEARNED Rule "$text" File "$pm"
  save_state
  echo "ok: rule added to $pm"
}

# ---------------------------------------------------------------------------
# setup
# ---------------------------------------------------------------------------
HOOK_BASE='"$CLAUDE_PROJECT_DIR"/.claude/skills/myaidlc/scripts/myaidlc-engine.sh hook'
# Lets the conductor run engine commands without a permission prompt for each step
ALLOW_RULE='Bash(.claude/skills/myaidlc/scripts/myaidlc-engine.sh:*)'

cmd_setup() {
  local dry=0
  [ "${1:-}" = --dry-run ] && dry=1
  local settings=.claude/settings.json old new f
  if [ -f "$settings" ]; then
    old="$(jq . "$settings")" || die "$settings is not valid JSON; fix it first"
  else old='{}'; fi
  new="$(jq --arg b "$HOOK_BASE" --arg allow "$ALLOW_RULE" '
    def add($ev; $m; $cmd):
      .hooks[$ev] = ((.hooks[$ev] // []) as $arr
        | if any($arr[]?.hooks[]?; .command == $cmd) then
            ($arr | map(if any(.hooks[]?; .command == $cmd) and $m != "" then .matcher = $m else . end))
          else $arr + [ ({hooks: [{type: "command", command: $cmd}]} + (if $m == "" then {} else {matcher: $m} end)) ] end);
    add("UserPromptSubmit"; ""; "\($b) prompt")
    | add("PreToolUse"; "Edit|Write|MultiEdit|NotebookEdit"; "\($b) pre-tool")
    | add("PostToolUse"; "Edit|Write|MultiEdit|NotebookEdit|AskUserQuestion"; "\($b) post-tool")
    | .permissions.allow = ((.permissions.allow // []) | if index([$allow]) then . else . + [$allow] end)' <<<"$old")"

  local creates=()
  for f in "$CONFIG" "$D/memory/project.md" "$D/memory/phases" "$D/memory/templates" "$RT/.gitignore"; do
    [ -e "$f" ] || creates+=("$f")
  done
  if [ $dry = 1 ]; then
    if [ ${#creates[@]} -gt 0 ]; then printf 'create %s\n' "${creates[@]}"; fi
    if [ "$(jq -S . <<<"$old")" = "$(jq -S . <<<"$new")" ]; then echo "$settings: hooks and permission already installed"
    else echo "$settings: add hooks and the engine permission"; diff <(jq -S . <<<"$old") <(jq -S . <<<"$new") || true; fi
    return 0
  fi
  ensure_runtime
  mkdir -p "$D/memory/phases" "$D/memory/templates" "$INTENTS"
  if [ ! -f "$CONFIG" ]; then
    jq -n '{version: 1, guard: "on", default_scope: "feature", verify_commands: []}' > "$CONFIG"
  fi
  if [ ! -f "$D/memory/project.md" ]; then
    if [ -f "$SKILL_DIR/templates/project-rules.md" ]; then cp "$SKILL_DIR/templates/project-rules.md" "$D/memory/project.md"
    else printf '# Project rules\n' > "$D/memory/project.md"; fi
  fi
  if [ "$(jq -S . <<<"$old")" != "$(jq -S . <<<"$new")" ]; then
    mkdir -p .claude
    printf '%s\n' "$new" > "$settings.tmp"
    mv "$settings.tmp" "$settings"
    echo "ok: hooks and the engine permission added to $settings"
  else
    echo "ok: hooks and permission already installed in $settings"
  fi
  if [ ${#creates[@]} -gt 0 ]; then printf 'ok: created %s\n' "${creates[@]}"; fi
}

# ---------------------------------------------------------------------------
# check: the stage and scope definitions are consistent
# ---------------------------------------------------------------------------
cmd_check() {
  load_catalog
  load_scopes
  local status=0 out
  out="$(jq -r --arg agents "$AGENTS_DIR" --arg skill "$SKILL_DIR" --argjson scopes "$SCOPES" '
    def phases: ["initialization", "ideation", "inception", "construction", "operation"];
    . as $cat
    | ( $cat[] | . as $s
        | ( if .slug != .stem then "NG  stage \(.file): slug \(.slug) does not match the file name" else empty end ),
          ( if .phase != .dir then "NG  stage \(.slug): phase \(.phase) does not match its folder \(.dir)" else empty end ),
          ( if (phases | index($s.phase)) == null then "NG  stage \(.slug): unknown phase \(.phase)" else empty end ),
          ( if (.order | test("^[0-9]+\\.[0-9]+$") | not) or ((.order | split(".")[0] | tonumber) != (phases | index($s.phase)))
            then "NG  stage \(.slug): order \(.order) must be <phase number>.<n>" else empty end ),
          ( if ([ "inline", "subagent" ] | index($s.mode)) == null then "NG  stage \(.slug): unknown mode \(.mode)" else empty end ),
          ( if ([ "none", "approval", "plan-and-checkpoint" ] | index($s.gate)) == null then "NG  stage \(.slug): unknown gate \(.gate)" else empty end ),
          ( if ([ "none", "phase-doc", "plan-and-code", "code-if-changed" ] | index($s.review)) == null then "NG  stage \(.slug): unknown review \(.review)" else empty end ),
          ( if ([ "blocked", "after-plan-approval", "allowed" ] | index($s.source_writes)) == null then "NG  stage \(.slug): unknown source_writes \(.source_writes)" else empty end ),
          ( if ([ "", "unit" ] | index($s.for_each)) == null then "NG  stage \(.slug): for_each must be unit or empty" else empty end ),
          ( if .for_each == "unit" and .phase != "construction" then "NG  stage \(.slug): only construction stages run per unit" else empty end ),
          ( if (.gate == "plan-and-checkpoint") != (.review == "plan-and-code") then "NG  stage \(.slug): plan-and-checkpoint and plan-and-code go together" else empty end ),
          ( if .lead_agent == "" then "NG  stage \(.slug): lead_agent is missing" else empty end ) ),
      ( [ $cat[] | .slug ] | group_by(.) | map(select(length > 1) | .[0]) | .[] | "NG  stage slug \(.) is used more than once" ),
      ( [ $cat[] | .slug as $sl | .produces[] | {n: ., s: $sl} ] | group_by(.n) | map(select(length > 1)) | .[]
        | "NG  artifact \(.[0].n) is produced by more than one stage: \(map(.s) | join(", "))" ),
      ( $scopes[] | . as $sc
        | ( if .name != .stem then "NG  scope \(.file): name \(.name) does not match the file name" else empty end ),
          ( if ([ "minimal", "standard" ] | index($sc.depth)) == null then "NG  scope \(.name): unknown depth \(.depth)" else empty end ),
          ( .stages[] | . as $x | if ([ $cat[] | .slug ] | index($x)) == null then "NG  scope \($sc.name): unknown stage \($x)" else empty end ),
          ( [ "workspace-detection", "state-init" ][] | . as $x | if ($sc.stages | index($x)) == null then "NG  scope \($sc.name): must include \($x)" else empty end ) )
  ' <<<"$CAT")"
  if [ -n "$out" ]; then printf '%s\n' "$out"; status=1; fi
  local row slug lead file name
  while IFS=$'\t' read -r slug lead file; do
    if [ "$lead" != engine ] && [ ! -f "$AGENTS_DIR/$lead.md" ]; then
      echo "NG  stage $slug: lead_agent $lead has no file agents/$lead.md"; status=1
    fi
    if [ "$lead" != engine ]; then
      for row in '## Steps' '## Rules' '## Learn'; do
        grep -qx "$row" "$ROOT/$file" 2>/dev/null || grep -qx "$row" "$file" 2>/dev/null || { echo "NG  stage $slug: body has no \"$row\" section"; status=1; }
      done
    fi
  done < <(jq -r '.[] | [.slug, .lead_agent, .file] | @tsv' <<<"$CAT")
  while IFS= read -r name; do
    [ -f "$SKILL_DIR/templates/$name" ] || { echo "NG  artifact $name has no template templates/$name"; status=1; }
  done < <(jq -r '.[].produces[]' <<<"$CAT")
  if [ $status = 0 ]; then
    echo "OK  $(jq length <<<"$CAT") stages and $(jq length <<<"$SCOPES") scopes are consistent"
  fi
  return $status
}

# ---------------------------------------------------------------------------
# hooks: never block the session on an internal problem (exit 0 and say so on stderr);
# block a tool only on a recorded fact (exit 2 with the next step on stderr).
# ---------------------------------------------------------------------------
# Project-relative form of a path, or nothing (status 1) when it is outside the project
to_rel() {
  local p="$1" pre dir rest
  case "$p" in
    /*) ;;
    *) printf '%s' "${p#./}"; return 0 ;;
  esac
  for pre in "$ROOT" "$RAW_ROOT"; do
    case "$p" in "$pre"/*) printf '%s' "${p#"$pre"/}"; return 0 ;; esac
  done
  dir="$(dirname "$p")"; rest="$(basename "$p")"
  while [ ! -d "$dir" ] && [ "$dir" != / ]; do rest="$(basename "$dir")/$rest"; dir="$(dirname "$dir")"; done
  dir="$(cd "$dir" 2>/dev/null && pwd -P)" || return 1
  case "$dir/$rest" in "$ROOT"/*) printf '%s' "${dir#"$ROOT"}/$rest" | sed 's#^/##'; return 0 ;; esac
  return 1
}

# Removes ".", ".." and repeated slashes from a relative path; fails when it leaves the project
normalize_rel() {
  printf '%s' "$1" | awk -F/ '{
    n = 0
    for (i = 1; i <= NF; i++) {
      if ($i == "" || $i == ".") continue
      if ($i == "..") { if (n == 0) exit 1; n--; continue }
      p[++n] = $i
    }
    out = ""
    for (i = 1; i <= n; i++) out = out (i > 1 ? "/" : "") p[i]
    print out
  }'
}

engine_owned() {
  case "$1" in
    "$INTENTS"/*/state.json|"$INTENTS"/*/state.md|"$INTENTS"/*/audit.md|"$RT"/*|"$INTENTS"/*/state.json.tmp|"$INTENTS"/*/state.md.tmp) return 0 ;;
  esac
  return 1
}

gate_open() {
  [ -n "$KEY" ] || return 1
  case "$(ef .status)" in awaiting|plan-awaiting) return 0 ;; esac
  return 1
}

hook_prompt() {
  local input prompt
  input="$(cat)"
  [ -d "$D" ] || return 0
  prompt="$(jq -r '.prompt // empty' <<<"$input" 2>/dev/null)" || return 0
  lock
  : > "$RT/hooks-alive"
  printf '%s' "$prompt" | mask > "$RT/last-prompt.txt"
  # /myaidlc <request> is the shortcut that starts work: keep its words for start
  if printf '%s' "$prompt" | head -n 1 | grep -Eq '^[[:space:]]*/myaidlc[[:space:]]+[^[:space:]]' \
     && ! printf '%s' "$prompt" | grep -Eq '^[[:space:]]*/myaidlc[[:space:]]+(status|resume|park|jump|intent|guard)([[:space:]]|$)'; then
    printf '%s' "$prompt" | mask > "$RT/last-request.txt"
  fi
  load_active 2>/dev/null || return 0
  local changed=0
  if [ "$(jq -r '.hooks_seen // false' <<<"$STATE")" != true ]; then
    STATE="$(jq '.hooks_seen = true' <<<"$STATE")"; changed=1
  fi
  load_current
  # A bare /myaidlc (to resume or check status) is not an answer to anything
  if ! jq -e -n --arg p "$prompt" '$p | test("\\A\\s*/myaidlc(\\s+(status|resume))?\\s*\\z")' >/dev/null; then
    STATE="$(jq '.human_count = ((.human_count // 0) + 1)' <<<"$STATE")"; changed=1
    if gate_open; then audit HUMAN_TURN Stage "$(cf .slug)" Unit "$(cf '.unit // ""')"; fi
  fi
  if [ $changed = 1 ]; then save_state; fi
}

hook_pre_tool() {
  local input path rel
  input="$(cat)"
  path="$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$input" 2>/dev/null)" || return 0
  [ -n "$path" ] || return 0
  rel="$(to_rel "$path")" || return 0
  rel="$(normalize_rel "$rel")" || return 0
  if engine_owned "$rel"; then
    echo "myaidlc: $rel is written only by the engine. Use the engine command for the change you want (report, review, units, jump, park, guard), never a file edit." >&2
    exit $BLOCK
  fi
  [ -d "$D" ] || return 0
  load_active 2>/dev/null || return 0
  [ "$(jq -r .status <<<"$STATE")" = active ] || return 0
  [ "$(jq -r .guard <<<"$STATE")" = on ] || return 0
  case "$rel" in docs/*|.claude/*) return 0 ;; esac
  load_current
  [ -n "$KEY" ] || return 0
  local sw st pa
  sw="$(cf .source_writes)"; st="$(ef .status)"; pa="$(ef '.plan_approved // false')"
  case "$st" in in-progress|revising) ;; *) st=closed ;; esac
  if [ "$sw" = allowed ] && [ "$st" != closed ]; then return 0; fi
  if [ "$sw" = after-plan-approval ] && [ "$pa" = true ] && [ "$st" != closed ]; then return 0; fi
  lock
  STATE="$(cat "$IDIR/state.json")"
  audit GUARD_BLOCKED Path "$rel" Stage "$(cf .slug)" Unit "$(cf '.unit // ""')"
  save_state
  unlock
  local why="the current step ($(cf .title)) does not change product code"
  [ "$sw" = after-plan-approval ] && [ "$pa" != true ] && why="the code plan for $(cf .title)$(cf '.unit // "" | if . != "" then " (unit \(.))" else "" end') is not approved yet"
  if [ "$st" = closed ]; then
    if [ "$(ef .status)" = pending ]; then why="$KEY has not started yet"; else why="$KEY is waiting for the person's decision"; fi
  fi
  echo "myaidlc: blocked writing $rel because $why. Finish the step and get the person's approval first. If the person asks to change code now, run: .claude/skills/myaidlc/scripts/myaidlc-engine.sh guard off" >&2
  exit $BLOCK
}

hook_post_tool() {
  local input tool path rel answer kind
  input="$(cat)"
  [ -d "$D" ] || return 0
  tool="$(jq -r '.tool_name // empty' <<<"$input" 2>/dev/null)" || return 0
  if [ "$tool" = AskUserQuestion ]; then
    answer="$(jq -r '
      (.tool_input.answers // .tool_response.answers // .tool_response // "")
      | if type == "object" then (to_entries | map("\(.key) -> \(.value | if type == "string" then . else tojson end)") | join("\n"))
        elif type == "string" then . else tojson end' <<<"$input" 2>/dev/null)" || return 0
    lock
    : > "$RT/hooks-alive"
    printf '%s' "$answer" | mask > "$RT/last-answer.txt"
    load_active 2>/dev/null || return 0
    STATE="$(jq '.hooks_seen = true | .human_count = ((.human_count // 0) + 1)' <<<"$STATE")"
    load_current
    audit QUESTION_REPLIED Stage "$(cf '.slug // ""')" Unit "$(cf '.unit // ""')" Reply "$(cat "$RT/last-answer.txt")"
    save_state
    return 0
  fi
  path="$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$input" 2>/dev/null)" || return 0
  [ -n "$path" ] || return 0
  rel="$(to_rel "$path")" || return 0
  rel="$(normalize_rel "$rel")" || return 0
  load_active 2>/dev/null || return 0
  case "$rel" in "$IDIR"/*) ;; *) return 0 ;; esac
  engine_owned "$rel" && return 0
  kind=ARTIFACT_UPDATED
  [ "$(jq -r '.tool_response.type // empty' <<<"$input" 2>/dev/null)" = create ] && kind=ARTIFACT_CREATED
  lock
  STATE="$(cat "$IDIR/state.json")"
  STATE="$(jq '.hooks_seen = true' <<<"$STATE")"
  audit "$kind" File "$rel" Tool "$tool"
  save_state
}

# Runs a hook in a subshell. Only a deliberate block (BLOCK=3 inside) becomes exit 2; any
# other failure is reported on stderr and lets the session go on.
BLOCK=3
cmd_hook() {
  local kind="${1:-}" rc=0
  case "$kind" in prompt|pre-tool|post-tool) ;; *) die "usage: hook prompt | hook pre-tool | hook post-tool" ;; esac
  set +e
  ( set -e; case "$kind" in prompt) hook_prompt ;; pre-tool) hook_pre_tool ;; post-tool) hook_post_tool ;; esac )
  rc=$?
  set -e
  if [ $rc = $BLOCK ]; then exit 2; fi
  if [ $rc != 0 ]; then echo "myaidlc: the $kind hook could not run (exit $rc) and was skipped" >&2; fi
  exit 0
}

# ---------------------------------------------------------------------------
cmd="${1:-}"
[ $# -gt 0 ] && shift
case "$cmd" in
  start) cmd_start "$@" ;;
  next) cmd_next ;;
  report) cmd_report "$@" ;;
  review) cmd_review "$@" ;;
  review-skip) cmd_review_skip "$@" ;;
  units) cmd_units "$@" ;;
  changes) cmd_changes "$@" ;;
  jump) cmd_jump "$@" ;;
  park) cmd_park ;;
  resume) cmd_resume ;;
  status) cmd_status ;;
  intent) cmd_intent "$@" ;;
  guard) cmd_guard "$@" ;;
  learn) cmd_learn "$@" ;;
  setup) cmd_setup "$@" ;;
  check) cmd_check ;;
  hook) cmd_hook "$@" ;;
  *) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; [ -z "$cmd" ] && exit 0; exit 1 ;;
esac
