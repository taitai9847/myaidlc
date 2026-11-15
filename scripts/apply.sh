#!/usr/bin/env bash
# Copy bundles or individual items under claude/ into a target project's .claude/.
# Usage: ./scripts/apply.sh [--force] [--dry-run] <target project> <bundle | item>...
#   item: skills/<name>, agents/<file>, commands/<file>, hooks/<file>, or docs/<file>
#   --force   replace existing items; the previous copy is moved to .claude/.myaidlc-backup/<timestamp>/
#   --dry-run show what would be created or replaced, and change nothing
# Writes only inside .claude/: never touches settings.json, AGENTS.md, CLAUDE.md, or the project's docs/ (where myaidlc keeps its records).
# Records what was copied in .claude/.myaidlc-manifest.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
force=0
dry_run=0
args=()

usage() {
  echo "Usage: $0 [--force] [--dry-run] <target project> <bundle | item>..." >&2
  echo "Bundles: $(ls "$REPO_DIR/bundles" | sed 's/\.txt$//' | tr '\n' ' ')" >&2
  exit 1
}

for arg in "$@"; do
  case "$arg" in
    --force) force=1 ;;
    --dry-run) dry_run=1 ;;
    -*) echo "NG  unknown option: $arg" >&2; usage ;;
    *) args+=("$arg") ;;
  esac
done
[ ${#args[@]} -ge 2 ] || usage

target="${args[0]}"
[ -d "$target" ] || { echo "NG  target directory not found: $target" >&2; exit 1; }
target_abs="$(cd "$target" && pwd -P)"
case "$target_abs/" in
  "$REPO_DIR"/*) echo "NG  target is inside this repository: $target_abs" >&2; exit 1 ;;
esac
dest_root="$target_abs/.claude"
if [ -L "$dest_root" ]; then
  echo "NG  $dest_root is a symlink; refusing to write through it" >&2; exit 1
fi

# Expand arguments into items. Bundle files tolerate CRLF and a missing final newline.
items=()
for arg in "${args[@]:1}"; do
  bundle="$REPO_DIR/bundles/$arg.txt"
  if [ -f "$bundle" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%$'\r'}"
      [ -z "$line" ] || [[ "$line" == \#* ]] || items+=("$line")
    done < "$bundle"
  else
    items+=("$arg")
  fi
done
[ ${#items[@]} -gt 0 ] || { echo "NG  nothing to copy" >&2; exit 1; }

# Check every item first; copy nothing if any check fails
status=0
for p in "${items[@]}"; do
  if ! [[ "$p" =~ ^(skills|agents|commands|hooks|docs)/[^/]+$ ]] || [[ "$p" == */. || "$p" == */.. ]]; then
    echo "NG  $p: expected skills/<name>, agents/<file>, commands/<file>, hooks/<file>, or docs/<file>" >&2; status=1
  elif [ ! -e "$REPO_DIR/claude/$p" ]; then
    echo "NG  claude/$p not found" >&2; status=1
  elif [ -e "$dest_root/$p" ] && [ $force -eq 0 ]; then
    echo "NG  .claude/$p already exists (use --force to replace it)" >&2; status=1
  elif [ -e "$dest_root/$(dirname "$p")" ] && [ ! -d "$dest_root/$(dirname "$p")" ]; then
    echo "NG  .claude/$(dirname "$p") exists but is not a directory" >&2; status=1
  fi
done
[ $status -eq 0 ] || exit $status

stamp="$(date +%Y%m%d-%H%M%S)"
backup_dir="$dest_root/.myaidlc-backup/$stamp"
for p in "${items[@]}"; do
  if [ -e "$dest_root/$p" ]; then action="replace"; else action="create"; fi
  if [ $dry_run -eq 1 ]; then
    echo "DRY $action .claude/$p"
    continue
  fi
  mkdir -p "$dest_root/$(dirname "$p")"
  # Copy to a temporary path first so a failed copy leaves the existing item intact
  tmp="$dest_root/$p.myaidlc-tmp"
  rm -rf "$tmp"
  cp -R "$REPO_DIR/claude/$p" "$tmp"
  if [ "$action" = "replace" ]; then
    mkdir -p "$backup_dir/$(dirname "$p")"
    mv "$dest_root/$p" "$backup_dir/$p"
  fi
  mv "$tmp" "$dest_root/$p"
  echo "OK  $action .claude/$p"
done
[ $dry_run -eq 1 ] && exit 0

commit="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
{
  echo "# Written by myaidlc scripts/apply.sh"
  echo "applied: $(date +%Y-%m-%dT%H:%M:%S%z)"
  echo "source_commit: $commit"
  printf 'item: %s\n' "${items[@]}"
} >> "$dest_root/.myaidlc-manifest"
[ -d "$backup_dir" ] && echo "Backup of replaced items: .claude/.myaidlc-backup/$stamp/"
echo "Manifest: .claude/.myaidlc-manifest"
