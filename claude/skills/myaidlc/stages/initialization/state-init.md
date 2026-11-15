---
slug: state-init
phase: initialization
order: 0.2
title: State Initialization
lead_agent: engine
gate: none
review: none
---
Run by `myaidlc-engine.sh start`, with no agent and no gate. The engine creates the work's record folder `docs/myaidlc/intents/<YYMMDD>-<label>/` with `state.json`, `state.md`, `audit.md` and `request.md` (the person's request, with secrets masked), and makes it the active work.
