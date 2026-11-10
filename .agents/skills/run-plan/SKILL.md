---
name: run-plan
description: As the coordinator, run the approved PLAN.md to the end without the user's help (WORKFLOW.md §5). Use when the user invokes /run-plan.
disable-model-invocation: true
---

# Run the plan

You are the coordinator. Follow WORKFLOW.md. Run the plan to the end without my help.

This message is the kickoff message of WORKFLOW.md §5.1. It gives you permission for sessions, workflows, background agents, keep-awake, and the heartbeat (§5.5). Read WORKFLOW.md §5 before the first slice.

If `PLAN.md` does not exist, stop and tell the user to start a requirement first (`/start-requirement <milestone>`). If `PLAN.md` is not committed, commit it first: the user approved it when they sent this message.

## Run the nodes with the run-plan Workflow

When the plan has `plan/` data, the nodes run through one Workflow, `.claude/workflows/run-plan.js`. Do not start a session for each slice.

1. Make the args: `scripts/run-plan-args --into main --done <ID>…` (add `--done` for each node merged without the merge step).
2. Call the Workflow tool with `scriptPath: .claude/workflows/run-plan.js` and `args` = that JSON (an object, not a string).
3. For each node it starts brief, a fresh build agent, the verifier and the merge step (3 nodes at the same time or fewer), with up to 3 rounds. Read only its return:
   - `merged`: run `scripts/plan merged <ID> <merge>` bookkeeping (WORKFLOW.md §10).
   - `blocked`: a node stopped after 3 rounds, 2 rounds with the same evidence, or a problem outside its slice. Read `why`; repair the plan or add a fix, or tell the user.
   - `review`: the merge step refused changed evidence. A reviewer (or the user, for a checker) reads that diff; then you run `scripts/plan merge <ID> --into main --allow-changed-evidence <file>`. The Workflow never does.
   - `waiting`: nodes that did not start and what they wait on.
4. A graph change (a new node, other needs, a fix): stop the run, make the args again (`--fix <ID>:<item>`, `--started <ID>` for each node that had started), and resume with `resumeFromRunId` and the new args.

If you cannot call the Workflow tool, start each slice in its own session, or as background agents.
