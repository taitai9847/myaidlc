#!/usr/bin/env bash
# Check that:
# - every skill has a SKILL.md with name and description, and name matches the directory
# - every path listed in a bundle exists under claude/ and is a valid item
# - every agent under claude/agents/ has name and description, and name matches the file name
# - the README Skills and Agents tables list exactly what is under claude/skills/ and claude/agents/
# - shell scripts under claude/ parse and are executable
# - the myaidlc stages and scopes are consistent (myaidlc-engine.sh check)
# - the steps that change code, and the myaidlc skill, point to the development guideline
# - the myaidlc engine passes its end-to-end test (scripts/test-myaidlc.sh; skip with SKIP_ENGINE_TEST=1)
# Requires jq and git.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
status=0

for skill in "$REPO_DIR"/claude/skills/*/; do
  dir="$(basename "$skill")"
  file="$skill/SKILL.md"
  if [ ! -f "$file" ]; then
    echo "NG  $dir: SKILL.md not found"; status=1; continue
  fi
  frontmatter="$(awk 'NR==1 && /^---$/ {f=1; next} f && /^---$/ {exit} f' "$file")"
  name="$(sed -n 's/^name:[[:space:]]*//p' <<<"$frontmatter")"
  if ! grep -q '^description:' <<<"$frontmatter"; then
    echo "NG  $dir: description is missing"; status=1
  elif [ "$name" != "$dir" ]; then
    echo "NG  $dir: name ($name) does not match the directory name"; status=1
  else
    echo "OK  $dir"
  fi
done

for agent in "$REPO_DIR"/claude/agents/*.md; do
  [ -f "$agent" ] || continue
  file_name="$(basename "$agent" .md)"
  frontmatter="$(awk 'NR==1 && /^---$/ {f=1; next} f && /^---$/ {exit} f' "$agent")"
  name="$(sed -n 's/^name:[[:space:]]*//p' <<<"$frontmatter")"
  if ! grep -q '^description:' <<<"$frontmatter"; then
    echo "NG  agent $file_name: description is missing"; status=1
  elif [ "$name" != "$file_name" ]; then
    echo "NG  agent $file_name: name ($name) does not match the file name"; status=1
  else
    echo "OK  agent $file_name"
  fi
done

for bundle in "$REPO_DIR"/bundles/*.txt; do
  [ -f "$bundle" ] || continue
  name="$(basename "$bundle" .txt)"
  bundle_ok=1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [ -z "$line" ] || [[ "$line" == \#* ]] && continue
    if ! [[ "$line" =~ ^(skills|agents|commands|hooks|docs)/[^/]+$ ]]; then
      echo "NG  bundle $name: $line is not a valid item"; status=1; bundle_ok=0
    elif [ ! -e "$REPO_DIR/claude/$line" ]; then
      echo "NG  bundle $name: claude/$line not found"; status=1; bundle_ok=0
    fi
  done < "$bundle"
  [ $bundle_ok -eq 1 ] && echo "OK  bundle $name"
done

# Names in the first column of the table under the given "## <section>" heading of the README
readme_table() {
  awk -v h="## $1" '$0 == h {f=1; next} f && /^## / {exit} f' "$REPO_DIR/README.md" \
    | sed -n 's/^| `\([a-z0-9-]*\)` |.*/\1/p' | sort
}

check_table() {
  local section="$1" expected="$2"
  local listed
  listed="$(readme_table "$section")"
  if [ "$listed" = "$expected" ]; then
    echo "OK  README $section table"
  else
    echo "NG  README $section table does not match the repository:"
    diff <(echo "$listed") <(echo "$expected") | sed 's/^/    /' || true
    status=1
  fi
}

check_table Skills "$(for d in "$REPO_DIR"/claude/skills/*/; do basename "$d"; done | sort)"
check_table Agents "$(for f in "$REPO_DIR"/claude/agents/*.md; do [ -f "$f" ] && basename "$f" .md; done | sort)"

# Shell scripts shipped under claude/ parse and are executable
while IFS= read -r script; do
  rel="${script#"$REPO_DIR"/}"
  if ! bash -n "$script" 2>/dev/null; then
    echo "NG  $rel: syntax error"; status=1
  elif [ ! -x "$script" ]; then
    echo "NG  $rel: not executable"; status=1
  else
    echo "OK  $rel"
  fi
done < <(find "$REPO_DIR/claude" -name '*.sh' -type f | sort)

# The myaidlc definitions are consistent
ENGINE="$REPO_DIR/claude/skills/myaidlc/scripts/myaidlc-engine.sh"
if ! command -v jq >/dev/null 2>&1; then
  echo "NG  jq is required for the myaidlc checks"; exit 1
fi
if out="$(CLAUDE_PROJECT_DIR="$REPO_DIR" "$ENGINE" check 2>&1)"; then
  echo "$out"
else
  echo "$out"; status=1
fi

# Implementation steps and the conductor read the development guideline first
for f in skills/myaidlc/SKILL.md skills/myaidlc/stages/construction/code-generation.md \
         skills/myaidlc/stages/construction/build-and-test.md agents/myaidlc-developer-agent.md; do
  if grep -q '\.claude/docs/dev-guideline\.md' "$REPO_DIR/claude/$f"; then
    echo "OK  $f points to dev-guideline.md"
  else
    echo "NG  $f does not point to .claude/docs/dev-guideline.md"; status=1
  fi
done

# Every document the bundle's files point to under .claude/docs/ is in the bundle
while IFS= read -r doc; do
  if grep -qxF "docs/$doc" "$REPO_DIR/bundles/core.txt"; then
    echo "OK  bundle core includes docs/$doc"
  else
    echo "NG  bundle core does not include docs/$doc, which its files point to"; status=1
  fi
done < <(while IFS= read -r line || [ -n "$line" ]; do
            line="${line%$'\r'}"
            [ -z "$line" ] || [[ "$line" == \#* ]] || [ ! -e "$REPO_DIR/claude/$line" ] || printf '%s\n' "$REPO_DIR/claude/$line"
          done < "$REPO_DIR/bundles/core.txt" | while IFS= read -r f; do grep -rhoE '\.claude/docs/[A-Za-z0-9._-]+\.md' "$f" || true; done \
          | sed 's#^\.claude/docs/##' | sort -u)

# The engine works end to end
if [ "${SKIP_ENGINE_TEST:-0}" = 1 ]; then
  echo "--  scripts/test-myaidlc.sh skipped (SKIP_ENGINE_TEST=1)"
elif out="$("$REPO_DIR/scripts/test-myaidlc.sh" 2>&1)"; then
  echo "OK  scripts/test-myaidlc.sh: $(grep -c 'passed, 0 failed' <<<"$out") shell(s) passed"
else
  echo "NG  scripts/test-myaidlc.sh failed:"; sed 's/^/    /' <<<"$out" | grep -v '^    ==' || true; status=1
fi

exit $status
