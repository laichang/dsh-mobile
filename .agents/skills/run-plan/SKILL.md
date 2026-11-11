---
name: run-plan
description: As the coordinator, run the approved plan in plan/ to the end without the user's help. Use when the user invokes /run-plan.
disable-model-invocation: true
---

# Run the plan

You are the coordinator. Run the plan in `plan/` to the end without my help. This message gives you permission for workflows, background agents, sessions and keep-awake. The decisions in AGENTS.md "Process" stay with me.

If `plan/plan.json` does not exist, stop and tell the user to start a requirement first (`/start-requirement <milestone>`). If `plan/` is not committed, commit it first: the user approved it when they sent this message.

## Run the nodes with the run-plan Workflow

The nodes run through one Workflow, `.claude/workflows/run-plan.js`. Do not start a session for each slice.

1. Make the args: `scripts/run-plan-args --into main --done <ID>…` (add `--done` for each node merged without the merge step).
2. Call the Workflow tool with `scriptPath: .claude/workflows/run-plan.js` and `args` = that JSON (an object, not a string).
3. For each node it starts brief, a fresh build agent, the verifier and the merge step (3 nodes at the same time or fewer), with up to 3 rounds. Read only its return:
   - `merged`: the Workflow records the merge and releases the resources.
   - `blocked`: a node stopped after 3 rounds, 2 rounds with the same evidence, or a problem outside its slice. Read `why`; repair the plan or add a fix (`scripts/plan fix`), or tell the user.
   - `review`: the merge step refused changed evidence. A reviewer (or the user, for a checker) reads that diff; then you run `scripts/plan merge <ID> --into main --allow-changed-evidence <file>`. The Workflow never does.
   - `waiting`: nodes that did not start and what they wait on.
4. A graph change (a new node, other needs, a fix): stop the run, make the args again (`--fix <ID>:<item>`, `--started <ID>` for each node that had started), and resume with `resumeFromRunId` and the new args.
5. Record each step with `scripts/plan` (`row`, `log`, `pending`); `scripts/status` shows the run in one screen.

If the Workflow tool is unavailable, use a fresh build session or background agent for every round, including after an interrupted run or a fix.

1. Read the next round N from `scripts/run-plan-args --into main` (default 1). Stop after three rounds. Reserve it with `scripts/plan assign <ID> --schedule --round N --commit`.
2. Generate `scripts/brief <ID> --round N --base main`. Start a new builder with the node, round and printed brief path. On rework the brief links the preceding round’s review.
3. Capture verifier output and the result of `scripts/plan passed <ID> --json` in the file named by `scripts/brief <ID> --round N --base main --review-path`. Append any merge result and diagnostics there. Apply the same stop and review rules as the Workflow. Record a successful merge with `scripts/plan merged <ID> <merge> --commit`.
