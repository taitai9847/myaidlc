---
name: myaidlc-setup
description: Set up myaidlc in a project after its files were copied into .claude/. Creates docs/myaidlc/ (settings, project rules, template folder), installs myaidlc's hooks and the permission to run its engine in .claude/settings.json after showing the change, and records the project's check commands. Use when the person types /myaidlc-setup, or asks to install, set up or repair myaidlc in this project.
---

# myaidlc setup

`engine` means `.claude/skills/myaidlc/scripts/myaidlc-engine.sh`, run from the project root as a command of its own.

## Steps

1. Check what myaidlc needs:
   - The project is a git repository. Without git, myaidlc cannot list code changes for review; say so and stop.
   - `jq` is installed.
   - `.claude/skills/myaidlc/` and `.claude/agents/myaidlc-*.md` exist. If they are missing, tell the person to copy them in with `scripts/apply.sh` from the myaidlc repository.
   - Run `engine check`. If it reports any `NG` line, show it and stop.
2. Run `engine setup --dry-run`. Show the person what it will create and the change to `.claude/settings.json`, and ask whether to go ahead. The change has two parts:
   - three hooks that record their replies, keep code locked until a plan is approved, and log changes to the work's documents
   - one rule in `permissions.allow`, `Bash(.claude/skills/myaidlc/scripts/myaidlc-engine.sh:*)`, so that each step's engine command runs without a permission prompt. It allows only that script.
3. If they agree, run `engine setup`.
4. Find the project's check commands (build, lint, type check, test) in `AGENTS.md`, `CLAUDE.md`, the README and the build files. Ask the person to confirm or correct them, then write the confirmed list to `verify_commands` in `docs/myaidlc/config.json`. Leave the list empty if they prefer to be asked each time.
5. Ask whether to add a short myaidlc section to the project's `AGENTS.md` (create the file if it does not exist). If they agree, add this, between the markers, and change nothing else in the file:
   ```
   <!-- myaidlc:begin -->
   ## myaidlc
   Features and bug fixes can be run with `/myaidlc <what to build or fix>`.
   Work records (state, audit trail, documents) are in `docs/myaidlc/intents/`; project rules are in `docs/myaidlc/memory/project.md`.
   <!-- myaidlc:end -->
   ```
6. Tell the person:
   - Hooks take effect in a new Claude Code session.
   - `docs/myaidlc/` is meant to be committed, except `.runtime/`, which is already git-ignored.
   - If `docs/` is published as a documentation site, they should exclude `docs/myaidlc/` from it.
   - Project rules go in `docs/myaidlc/memory/project.md`, rules for one phase in `memory/phases/<phase>.md`, and template overrides in `memory/templates/`.

## Rules

- Never change `.claude/settings.json` without the person's agreement in step 2.
- Running setup again is safe. It adds only what is missing.
