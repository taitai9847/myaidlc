---
slug: workspace-detection
phase: initialization
order: 0.1
title: Workspace Detection
lead_agent: engine
gate: none
review: none
---
Run by `myaidlc-engine.sh start`, with no agent and no gate. The engine records whether the project is a git repository, the current branch and commit, and the number of tracked files in `state.json`, and logs `WORKSPACE_DETECTED`.

myaidlc always works on an existing project. Reading the code itself is the job of Reverse Engineering, which reads only the area the work touches.
