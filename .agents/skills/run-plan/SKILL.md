---
name: run-plan
description: As the coordinator, run the approved PLAN.md to the end without the user's help (WORKFLOW.md §5). Use when the user invokes /run-plan.
disable-model-invocation: true
---

# Run the plan

You are the coordinator. Follow WORKFLOW.md. Run the plan to the end without my help. Start each slice in its own session. If you cannot start a session, run the slices as a workflow or as background agents.

This message is the kickoff message of WORKFLOW.md §5.1. It gives you permission for sessions, workflows, background agents, keep-awake, and the heartbeat (§5.5). Read WORKFLOW.md §5 before the first slice.

If `PLAN.md` does not exist, stop and tell the user to start a requirement first (`/start-requirement <milestone>`). If `PLAN.md` is not committed, commit it first: the user approved it when they sent this message.
