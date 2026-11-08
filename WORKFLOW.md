# WORKFLOW

This file tells people and agents how work moves in this repository. It applies to all agents: Claude Code, Codex, and others. Product intent is in [STORY.md](STORY.md). Technical design is in [ARCHITECTURE.md](ARCHITECTURE.md). The current work items are in the plan file, [PLAN.md](PLAN.md).

Writing rules for this file: English, in the ASD-STE100 style. Use short sentences. Use one instruction in each sentence. Use the active voice. Use the terms in §1 and no synonyms for them.

## Contents

1. [Terms](#1-terms)
2. [Set up a new Mac](#2-set-up-a-new-mac)
3. [Roles and ownership](#3-roles-and-ownership)
4. [Start and stop a work session](#4-start-and-stop-a-work-session)
5. [Long-horizon run](#5-long-horizon-run)
6. [Resources for each slice](#6-resources-for-each-slice)
7. [Status titles](#7-status-titles)
8. [Session settings](#8-session-settings)
9. [Default choices](#9-default-choices)
10. [Merge a slice](#10-merge-a-slice)
11. [Decisions that stay with the user](#11-decisions-that-stay-with-the-user)
12. [Guards](#12-guards)
13. [Tool support](#13-tool-support)
14. [Change this file](#14-change-this-file)

## 1. Terms

| Term | Meaning |
|---|---|
| **User** | The human who owns this repository. The user gives instructions only in the chat of a session. |
| **Coordinator** | The one session that runs the plan. It works only on `main`. |
| **Slice** | One work item in the plan file: a tracer (T0), a spike (Xn), or a slice (Sn). It has an ID, a section, and a branch. |
| **Slice owner** | The session or agent that builds one slice, on the slice branch, in its own worktree. |
| **Reviewer** | An agent that did not build the slice. It runs the `[ui]` items of the slice again. |
| **Batch** | A set of slices that the coordinator starts at the same time. |
| **Status** | One of `todo`, `doing`, `blocked`, `review`, `done`. The plan file defines each status. |
| **Status title** | The name of a session. It shows the status of the session's slice (§7). |
| **Report** | The last message of a turn. It tells what is done, what is not done, and the next step. |

## 2. Set up a new Mac

Do this procedure one time on each Mac. Do it before any other work.

1. Install Xcode 26 and an iOS 26 Simulator runtime.
2. Install [nvm](https://github.com/nvm-sh/nvm).
3. Clone the repository: `git clone https://github.com/laichang/dsh-mobile.git`.
4. Go to the repository root.
5. Run `scripts/bootstrap`.
6. Make sure that the script ends with `bootstrap: done. The T0 round trip runs on this Mac.`

The script header lists each item that the script installs. All items outside the repository go into `~/.dshm`.

Note: You do not need a model API key. The demos use the mock LLM server from DeepSeek Harness (`@deepseek-ai/dsh-llm-mock-server`, in the `deepseek-ai/deepseek-harness` repository). The mock server sends fixed replies. A demo with a real model is a `[human]` item.

Note: Agent memory and old sessions do not move to the new Mac. They are not necessary. The repository holds all the context: this file, [AGENTS.md](AGENTS.md), and the plan file.

If step 6 fails, repair the setup first. Do not start slice work on a Mac where the T0 demo fails.

### 2.1 Codex only

Do this procedure if you use Codex on this Mac.

1. Run `codex update`. An old Codex CLI cannot use the newest models.
2. Start Codex in the repository root.
3. When Codex asks if you trust the project, select yes. Codex loads the project hooks only from a trusted project.
4. Type `/hooks`.
5. Trust the `codex-guard` hook.
6. Run `.codex/hooks/codex-guard-test`. Make sure that it ends with `failures: 0`.

Note: Codex records trust against the hash of each hook. When a hook file changes, Codex skips the hook until you trust it again. Do steps 4 and 5 again after each change to `.codex/`.

## 3. Roles and ownership

| Part | Owner | Where |
|---|---|---|
| Plan file §0 (status table) | Coordinator | `main` |
| Plan file §8 (plan log) | Coordinator | `main` |
| Plan file §9 (pending user confirmation) | Coordinator | `main` |
| One slice section, its Done when items, and its Log | Slice owner | Slice branch |
| Code and tests of a slice | Slice owner | Slice branch |
| Fix of a bug that the user reports | Owner of the fix slice (§5.2) | Fix slice branch |
| Merge into `main` | Coordinator | `main` |
| `[human]` items, `Dxx` confirmation, push, pull request | User | — |

Rules:

- The coordinator does not change code (`ios/`, `bridge/`, `protocol/`, `spikes/`, `scripts/`). Code goes into `main` only through the merge of a slice branch. The pre-commit hook stops a commit on `main` that changes code and is not a merge (§12).
- A slice owner edits only the section of its own slice.
- A slice owner does not edit §0, §8, or §9. Parallel branches that edit adjacent rows cause merge conflicts.
- If §0 must change, the slice owner writes this in its Log and its report. The coordinator then changes §0.
- A subagent gives its results to the slice owner. The slice owner records them in the Log.
- Change the plan file with `scripts/plan` (§3.1). Do not edit §0, §8, §9, the items, or a Log by hand. The script refuses a command on the wrong branch.

### 3.1 Bookkeeping commands

`scripts/plan` makes each change, checks it with `scripts/check-plan`, and commits it with `--commit`. Use `--dry-run` to see the change first. The file header of `scripts/plan` lists all commands.

| Who | Command | What it does |
|---|---|---|
| Coordinator | `scripts/plan assign <ID> --branch <branch> --commit` | Gives the resources (§6), sets §0 to `doing`, and adds the §8 entry |
| Coordinator | `scripts/plan merged <ID> <merge commit> --commit` | Checks the merge commit (§10, condition 3), sets §0, adds the §9 rows and the §8 entry |
| Coordinator | `scripts/plan fix "<name>" --bug "<what the user saw>" --commit` | Adds a fix slice for a bug that the user reports (§5.2): the next S number, a §0 row, and a section with a regression test item |
| Coordinator | `scripts/plan row`, `scripts/plan log`, `scripts/plan pending` | Changes one §0 row, adds one §8 entry, adds one §9 row |
| Coordinator | `scripts/plan title` | Writes the coordinator status title (§7.1) from §0 |
| Slice owner | `scripts/plan tick <ID> "<part of the item>" --evidence "<pointers>"` | Ticks one `[auto]` or `[ui]` item |
| Slice owner | `scripts/plan slice-log <ID> "<title>" --body -` | Adds a dated Log entry. The body comes from stdin |
| Slice owner | `scripts/plan slice-status <ID> <status>` | Changes the Status field of the slice |
| All | `scripts/plan show <ID>` | Shows the §0 row and the section of the slice |

## 4. Start and stop a work session

### 4.1 Before you start

1. Read [AGENTS.md](AGENTS.md).
2. Read this file.
3. Run `scripts/plan show <ID>`. It shows the §0 row and the section of your slice, together with its Log. Do not read all of the plan file.
4. Read `git log` from the date of the last Log entry of your slice.
5. Run `eval "$(scripts/slice-env <ID>)"`. It exports the resources of your slice (§6).
6. Run `scripts/demo/t0.sh`. If it fails, repair it first.
7. Set your status title (§7).

### 4.2 Before you stop

1. Add an entry to the Log of your slice with `scripts/plan slice-log`. Write what is done, what is not done, and the next step. Tick each item with `scripts/plan tick`.
2. Commit on the slice branch.
3. Set your status title (§7).
4. In your report, list each new provisional item (§9).

## 5. Long-horizon run

The user starts the coordinator one time. After that, the coordinator moves the plan forward without help from the user. It continues until the plan is complete, or until all remaining slices wait for the user.

### 5.1 Kickoff message

The user sends this message (or a message with the same meaning) to the coordinator:

> You are the coordinator. Follow WORKFLOW.md. Run the plan to the end without my help. Start each slice in its own session. If you cannot start a session, run the slices as a workflow or as background agents.

This message gives the coordinator permission for sessions, workflows, background agents, keep-awake, and the heartbeat (§5.5).

### 5.2 Rules for the coordinator

- Do not propose a session card that waits for a click. The user does not click cards. Start the session, or use the fallback in §5.3.
- Start slices whose **Needs** are met. Start a maximum of 3 slices in one batch.
- Give each slice its resources (§6) before you start it: `scripts/plan assign <ID> --branch <branch> --commit`.
- Give each slice owner a brief. The brief contains: the slice ID, the branch, the worktree, the resources, the session settings (§8), the default choices (§9), and the status title rules (§7).
- When a slice owner stops, examine its result. Do not trust its report alone.
- Merge each slice that meets the merge conditions (§10). Then start the next slice.
- Keep §0 and your own status title (§7) up to date after each change. `scripts/plan title` gives the title.
- Wait for the completion event of a slice session. Do not poll git for a commit. Do not wait on a background shell for the work of a slice owner.
- A completion event tells you that a turn of the slice session ended. It does not tell you that the slice is complete. Read the report:
  - If the report says that the work is complete, examine the result (see above).
  - If the report says that a job continues in the background, wait for the next completion event of that slice session.
  - If no next event arrives and the slice session is idle, do the recovery steps (§5.4) for that slice.
- Each brief tells the slice owner: "When a background job ends, examine its result and end a turn with a report. Do not end the slice work while a job runs."
- Do not add merge conditions to §10. If a condition in §10 is not sufficient, propose a change to this file (§14).
- When the user reports a bug, do not fix it in the coordinator session. This rule also applies after the run ends, for example while the user does the `[human]` items. Do these steps:
  1. Add a fix slice: `scripts/plan fix "<name>" --bug "<what the user saw>" --commit`. Use one fix slice for each bug. Bugs in the same part of the code can share one fix slice.
  2. Give it its resources: `scripts/plan assign <ID> --branch claude/<id>-<name> --commit`.
  3. Start a session for it (§5.3). Put the words of the user in the brief.
  4. Merge it with the conditions in §10, as for each slice.
  Only the user can put a code change directly into `main` (`CHECK_PLAN_ALLOW=1`, by hand).
- Stop only when no slice can move without the user. Then tell the user what waits for them.

### 5.3 Session start limit and fallback

WARNING: In the Claude desktop app, a session can start other sessions only in a turn that comes from the user. A turn that comes from a completion event can also start sessions, but only in a chain that began with a user turn. The chain ends when a turn stops or fails, or after many events with no user turn. A turn that comes from a message of another session can only propose cards.

Do these steps to keep the run moving:

1. In the kickoff turn, start the first batch as sessions.
2. When a completion event arrives, merge the finished slice and start the next slice in the same turn.
3. If the app refuses to start a session, do not propose a card. Run the remaining slices as a workflow (Claude Code) or as background processes (Codex: `codex exec -C <worktree>`).
4. Record the change in §8 of the plan file.

CAUTION: Never send a message to the coordinator for the user. A relayed message breaks the chain in step 2.

### 5.4 Recovery after an interruption

An API error, an app restart, or a stopped turn ends the chain (§5.3). An app restart also stops all background shells and all running tests.

A notification that a background job is `stopped` or `killed` is an interruption. The jobs of other sessions can also be stopped, and those sessions possibly get no notification. Do not end that turn with no action.

Do these steps at the start of each turn that follows an interruption:

1. Do not trust the state that you remember. Run `scripts/status`. It shows the real state of each slice that is `doing`: the head commit of the slice branch, the uncommitted changes in its worktree, the test and build processes that run for it, and its latest review result. Its "attention" list shows the slices that look stuck. It also shows the free space on the data volume, the `dshm-*` simulators, the worktrees, and the `/tmp/dshm-*` paths. If the "attention" list shows leftovers of a slice in `review` or `done`, run `scripts/plan cleanup <ID>` on `main`. Then examine the status of each slice session (`list_sessions`). A script cannot see the sessions.
2. If a slice owner is idle and no process runs for its slice, send it a brief to continue. The brief tells it what stopped and what to run again.
3. Start the slices whose **Needs** are met (§5.2).
4. Record the interruption and the recovery in §8 of the plan file.

If the app refuses to start a session or to send a message, tell the user in one line. Ask the user to send one message to the coordinator, for example: "Continue. Recover after the interruption (WORKFLOW.md §5.4)." That user turn starts a new chain.

A slice owner does the same steps 1 and 2 for its own slice when it receives a message after an interruption.

### 5.5 Heartbeat and keep-awake

After an interruption, no event wakes the coordinator. The heartbeat wakes it. Thus the run continues without the user.

In the kickoff turn, before the first batch:

1. Request keep-awake for the Mac (`request_keep_awake`). A sleeping Mac stops all work.
2. Create the heartbeat with `CronCreate`:
   - `cron`: `7,27,47 * * * *` (about every 20 minutes),
   - `recurring`: `true`,
   - `durable`: `true` (it continues after an app restart),
   - `prompt`: `Heartbeat (WORKFLOW.md §5.5).`
3. Record the heartbeat job ID in §8 of the plan file.

In each heartbeat turn:

1. Find the work that runs now: run `scripts/status`, and examine the linked sessions (`list_sessions` with `linked: true`), your workflows, and your background jobs.
2. If work runs, do nothing. End the turn with one line.
3. If no work runs, do the recovery steps (§5.4).
4. If the app refuses to start a session in this turn, do not wait for the user. Run the slices as a workflow (§5.3, step 3).
5. A recurring job ends after 7 days. If its age is more than 6 days (`CronList`), create a new heartbeat, delete the old one (`CronDelete`), and record the new job ID in §8.

When the plan is complete, or when all remaining slices wait for the user, delete the heartbeat. Then tell the user what waits for them.

Do not use a `/goal` stop hook for the run. It stops the turn from ending, and then the coordinator cannot wait for completion events.

## 6. Resources for each slice

Slices run tests at the same time. Each slice therefore gets its own resources:

| Resource | Rule | Example (S1) |
|---|---|---|
| Worktree | `.claude/worktrees/<name>` or the worktree that the tool creates | `wf_219b7aa1-71c-2` |
| Branch | `claude/<id>-<short-name>` | `claude/s1-pair-encrypt` |
| Slot | The lowest slot that no active slice holds | 0 |
| Bridge port | 47810 + slot. A second host: 47840 + slot | 47810 |
| DSH web port | 3283 + slot. A second host: 3313 + slot | 3283 |
| `DSH_HOME` | `~/.dshm/home-<id>` | `~/.dshm/home-s1` |
| Simulator | `dshm-<ID>`, an iOS 26 iPhone | `dshm-S1` |
| Decision numbers | A block of 3 `Dxx` numbers after the highest number in use | `D60-D62` |

- The coordinator gives the resources with `scripts/slice-env --assign` (through `scripts/plan assign`). The script writes them to the registry `scripts/resources.tsv`. Do not edit the registry by hand.
- A slice holds its slot while it is `todo`, `doing`, or `blocked` in §0. After the merge, the next slice can use the slot. The script also skips a slot when a process listens on one of its ports.
- The slice owner runs `eval "$(scripts/slice-env <ID>)"` in each shell before a demo. This also works in a worktree that was cut before the assignment.
- Use only the decision numbers of your block (`DSHM_DECISIONS`). Then parallel slices do not use the same number. Do not use the unused numbers of a block for a different slice.
- A slice uses only its own resources. All slices use the DSH install in `~/.dshm/runtime` read-only.
- When a slice is merged, `scripts/plan merged` removes its resources (§10). Do not keep them for later use.
- Port 47800 is for demos on `main`. Port 47801 is for `scripts/demo/t0.sh`.
- The slice demo script reads the resources from `DSHM_BRIDGE_PORT`, `DSHM_WEB_PORT`, `DSHM_SECOND_BRIDGE_PORT`, `DSHM_SECOND_WEB_PORT`, `DSHM_HOME`, and `DSHM_SIM`.

### 6.1 Simulator limit and free space

Many booted simulators make the Mac slow. A slow Mac makes UI tests fail at random.

The guard in `scripts/demo/lib.sh` applies these rules. Each demo script and `scripts/review` loads it.

- The guard stops the script when the data volume has less than 30 GB free (`DSHM_MIN_FREE_GB`). It does not wait. It examines the volume that holds `$HOME`. It does this check before it boots a simulator or builds.
- The guard waits while the CPU is less than 15% idle. It waits while 3 other `dshm-*` simulators are booted. After 30 minutes, it stops the script with an error. The guard does not use the load average. On macOS, the load average also counts threads that only wait.
- The guard boots a `dshm-*` simulator and stops the iOS background services that no test needs (`DSHM_SIM_NOISE`). These services can use 5 CPUs or more.
- When the script ends, the guard shuts down the simulator of the script. This also occurs when a tool kills the script. It does not shut down a simulator of the user.
- The guard records the owner of each simulator in `/tmp/dshm-guard/`. Before a run, it shuts down each `dshm-*` simulator whose owner is not running.

Rules for all agents:

- Run UI tests only through a demo script or `scripts/review`. Do not run `xcodebuild test` directly.
- Do not change `DSHM_SIM_LIMIT`, `DSHM_GUARD_WAIT`, or `DSHM_MIN_IDLE`.
- Do not change `DSHM_MIN_FREE_GB`. If the guard stops you for free space, run `scripts/status`. Remove the leftovers that it shows with `scripts/plan cleanup <ID>`. Then run the script again.
- If the guard stops you, shut down the `dshm-*` simulators that no running slice uses. Then run the script again.
- The coordinator does not start a new slice or reviewer while 3 `dshm-*` simulators are booted.

## 7. Status titles

The session list shows the progress of each slice. The status title of a session shows the status of its slice.

### 7.1 Format

`<mark> <ID> · <Name>`

Examples: `🔨 S4 · Approvals`, `✅ S2 · Durable list + resume`.

The coordinator uses this format: `🎛 Coordinator · M1 · ✅<n> 👀<n> 🔨<n> ⏸<n>`. Each `<n>` is the number of slices with that mark.

### 7.2 Marks

| Mark | Status | Who sets it | When |
|---|---|---|---|
| 🔨 | `doing` | Slice owner | At the start of work |
| ⏸ | `blocked` | Slice owner | When work cannot continue without a decision |
| 🔍 | `doing` | Slice owner | When all `[auto]` and `[ui]` items are ticked and the reviewer runs |
| 👀 | `review` | Coordinator | After the merge, while `[human]` items are open |
| ✅ | `done` | Coordinator | After the merge with no open `[human]` items, or after the user ticks the last `[human]` item |
| ❌ | — | Coordinator | When the coordinator stops the slice. Write the reason in §8. |

§0 of the plan file is the source of truth. A status title is a copy. If the two are different, §0 is correct.

### 7.3 How to set a status title

| Tool | Method |
|---|---|
| Claude Code (desktop app) | Call `set_session_title` with `session_id: "self"` (slice owner), or with the session ID (coordinator). |
| Codex, or a tool with no rename function | Write the status title as the first line of each report. The coordinator writes the current status titles of all slices in its own report. The user can rename the session by hand. |

Note: In Claude Code, if the user typed a session title, the app asks the user before it changes that title. Thus, do not rename these sessions by hand.

## 8. Session settings

| Tool | Model | Effort |
|---|---|---|
| Claude Code | `claude-opus-5-5` | `medium` |
| Codex | The model that the user selects | The default of the user |

The coordinator uses these settings for each slice session, workflow agent, and background process that it starts.

## 9. Default choices

The user is not always available. Agents therefore do not wait for the user at a choice.

- **Decisions.** At a toolchain or design choice, continue with your recommendation. Record it in [ARCHITECTURE.md](ARCHITECTURE.md) as a `Dxx` entry, with a number from your block (§6). Mark the entry **provisional, pending user confirmation**. List the alternatives that you considered.
- **Dependencies and downloads.** You can add them without permission. Pin each one: an exact version, or a commit and a checksum. Record each one as provisional, and name it in the Log of the slice.
- **Reports.** List each new provisional item in your report to the coordinator. The coordinator adds it to §9 of the plan file with the slice, the branch, and the commit.
- **Confirmation.** A provisional item stays provisional until the user confirms it. When the user confirms or changes it, the owner removes the marker or applies the change.
- **Briefs.** Each brief from the coordinator contains these rules.

## 10. Merge a slice

The coordinator merges a slice branch into `main` without permission when all these conditions are true:

1. Each `[auto]` and `[ui]` item of the slice is ticked, and each evidence pointer resolves.
2. A reviewer ran `scripts/review <ID>` on the head commit of the slice branch, and the result is `RESULT: PASS`.
3. `scripts/check-plan` passes. On a merge commit, the `pre-merge-commit` hook runs it. `scripts/plan merged` runs it again on the merge commit.

The merge does not wait for `[human]` items. After the merge, run `scripts/plan merged <ID> <merge commit> --commit`. It does condition 3 for the merge commit and the bookkeeping below:

- If the slice has open `[human]` items, set §0 to `review`. Add each open `[human]` item to §9 with the device or setup that it needs.
- If the slice has no open `[human]` items, set §0 to `done`.
- A slice in `review` becomes `done` when the user ticks its last `[human]` item.
- A merged slice meets the **Needs** of other slices, also in `review`.
- If the user finds a problem during acceptance, repair it on `main`. Do not revert the merge.
- Tell the user in one or two sentences what you merged and where the evidence is.
- Bookkeeping commits on `main` (§0, §8, §9) do not need permission.
- Then `scripts/plan merged` removes what the slice left on the Mac: the simulator `dshm-<ID>`, the paths `/tmp/dshm-<id>` and `/tmp/dshm-<id>-*`, and the `DSHM_HOME` of the slice in `~/.dshm/`. It removes each worktree and branch of the slice only when its head is in the merge commit and it has no uncommitted or untracked file. It does not force a removal. It keeps a simulator or a path that a running process uses. It prints each thing that it removes, and each thing that it keeps, with the reason.
- Use `--keep` only when a later step needs these resources. Then run `scripts/plan cleanup <ID>` when that step is complete.

If a condition is false, do not merge. Tell the user what is missing.

### 10.1 Review run and flaky tests

A test is flaky when it fails and then passes with no change to the code.

`scripts/review <ID>` applies these rules:

- It runs only the `[ui]` items of the slice, from the plan file: each `cmd:` pointer one time, and the slice demo for items with only `test:` pointers. Then each `test:` pointer must show as passed.
- It runs a failed part again, a maximum of 2 times. A part that passes on a run again is flaky. The review still passes, and the result lists the flaky part.
- It does not run again the parts that passed for the same code. This applies to a run again and to `--resume`. "The same code" is the same content of the worktree, not the same commit. Changes to `evidence/` and to `*.md` files do not change the code. Thus a commit that only ticks items or adds a Log entry keeps the passed parts.
- It refuses a worktree with uncommitted changes. It writes the result to `/tmp/dshm-review/<ID>-<commit>.txt`.

Rules for all agents:

- The reviewer runs `scripts/review <ID>` and nothing else. The reviewer reports the result file.
- Do not run the review again because of a flaky part. Write each flaky part in the Log of the slice. The coordinator adds it to §8.
- If the result is `RESULT: FAIL`, the slice owner repairs the failure. Then run `scripts/review <ID> --resume` on the new commit.
- A slice owner uses a maximum of 3 repair rounds for flaky tests of one slice. After that, do not repair more. Record each remaining flaky test in the Log and in §8.
- Do not repair a flaky test that the slice did not add or change. Record it in §8 for a later slice.
- A script that runs many parts (for example `scripts/demo/t1.sh --all`) wraps each part in `demo_part` from `scripts/demo/lib.sh`. Then a failure in one part does not run the other parts again.
- At the start of a work session, run only the T0 demo (§4.1). Do not run the demos of other slices to prepare the Mac.

## 11. Decisions that stay with the user

Only the user can do these things:

- Tick a `[human]` item.
- Confirm a `Dxx` entry, a dependency, or a download.
- Push to GitHub, or open a pull request.
- Commit a change to a guard file (§12).
- Approve a change to this file or to the rules in the plan file (§14).

## 12. Guards

| Guard | Applies to | What it does |
|---|---|---|
| `.githooks/pre-commit` | All tools | Runs `scripts/check-plan` on each commit. It also stops build output (`.build/`, `node_modules/`, `DerivedData/`, `*.xcresult`) and files larger than 4 MB. On `main`, it stops a commit that changes code and is not a merge (§3). Git does not run this hook for `git cherry-pick`, `git rebase`, or `git revert`. Thus do not use these commands on `main`. |
| `.githooks/pre-merge-commit` | All tools | Runs the same checks on each merge commit. In a merge of `main` into a slice branch, it judges the plan changes of the slice against `main`, and it lets through guard files that come unchanged from `main`. |
| `.claude/hooks/plan-guard` | Claude Code only | Stops a bad edit of the plan file before it occurs. Stops a shell command that writes the plan file: use `scripts/plan` (§3.1) or the Edit tool. Asks the user before an edit of a guard file, also from a shell command. It checks the paths in each worktree of the repository. |
| `.claude/hooks/git-guard` | Claude Code only | Stops `--no-verify` on git, `core.hooksPath` changes, and `CHECK_PLAN_ALLOW`. It parses the command. A command that only reads or writes text with these words (`grep`, a commit message, a file) passes. |
| `.codex/hooks/codex-guard` (from `.codex/hooks.json`) | Codex only | Runs `git-guard` and the shell checks of `plan-guard` on shell commands. Runs the plan-guard checks on `apply_patch` edits. Denies each edit of a guard file. |

Rules for all agents:

- Do not use `git commit --no-verify` or `git commit -n`.
- Do not change `core.hooksPath`. Its value is `.githooks`.
- Do not set `CHECK_PLAN_ALLOW`. Only the user sets it, by hand.
- Do not tick a `[human]` item. The pre-commit hook cannot tell who ticked an item. Thus this rule depends on you.
- Do not edit a guard file without permission.
- Do not change code on `main`. Code goes into `main` only through the merge of a slice branch. A bug that the user reports becomes a fix slice (§5.2).

Differences in Codex:

- Codex does not support the `ask` decision. Thus `codex-guard` denies each change that Claude Code asks about. If a guard stops you, ask the user in the chat.
- Codex runs the project hooks only after the user trusts them (§2.1). Without trust, only the pre-commit hook applies.
- After a change to a file in `.claude/hooks/` or `.codex/hooks/`, run `.claude/hooks/guard-test`. It also runs `.codex/hooks/codex-guard-test`. Make sure that it ends with `failures: 0`.

Guard files: `scripts/check-plan`, `.githooks/`, `.claude/hooks/`, `.claude/settings.json`, `.codex/hooks.json`, `.codex/hooks/`. The list is `PROTECTED` in `scripts/check-plan`. `.claude/hooks/plan-guard` keeps a copy of the list. Keep the two lists the same.

## 13. Tool support

| Capability | Claude Code (desktop app) | Codex |
|---|---|---|
| Reads this file | Through [AGENTS.md](AGENTS.md) | Through [AGENTS.md](AGENTS.md) (read automatically) |
| Starts a slice session | `start_session` (limits in §5.3) | Not available. Use `codex exec -C <worktree> "<brief>"` as a background process. |
| Runs a batch in the background | Workflow tool, or background agents | `codex exec`, one process for each slice |
| Sets a status title | `set_session_title` | First line of each report (§7.3) |
| Guards | Pre-commit hook and `.claude/hooks/` | Pre-commit hook and `.codex/hooks/codex-guard`, after trust (§2.1, §12) |
| Drives the iOS Simulator | Simulator tools, XCUITest, `scripts/demo/*.sh` | XCUITest and `scripts/demo/*.sh` |

If a tool has no function for a capability, use the fallback in this table. Then record the fallback in the Log.

## 14. Change this file

1. Show the change to the user before you commit it.
2. Commit it only after the user approves it.
3. Add a line to the change log below.

### Change log

- **2026-11-05**: First version. Moved the process rules from "How to use this file" in the plan file. Added the setup procedure, the long-horizon run, the resources, the status titles, and the tool support for Codex. Added the Codex hooks (`.codex/hooks.json`, `codex-guard`) and the Codex setup (§2.1).
- **2026-11-06**: Added the recovery after an interruption (§5.4), the simulator limit (§6.1, enforced by the guard in `scripts/demo/lib.sh`), and the review run with the rules for flaky tests (§10.1, enforced by `scripts/review`). Added coordinator rules to §5.2: wait for completion events, read each event as the end of a turn and not of the slice, and do not add merge conditions. A `stopped` or `killed` job notification starts the recovery (§5.4). Reason: T1 stopped for many hours. An app restart stopped the background jobs. Six booted simulators made the UI tests flaky. A merge condition of "5 runs in a row" did not converge. Each failure in `t1.sh --all` started the full regression again. Added the heartbeat and keep-awake (§5.5): after an interruption, no event woke the coordinator.
- **2026-11-06**: The guard (§6.1) now checks the CPU idle time, not the load average. It also stops the iOS background services in each `dshm-*` simulator.
- **2026-11-06**: The shutdown by the guard (§6.1) now also occurs after a tool kills the script. The guard shuts down a `dshm-*` simulator whose owner is not running.
- **2026-11-07**: Added the bookkeeping commands (§3.1, `scripts/plan`), the run status (`scripts/status`, in §5.4 and §5.5), and the resource registry with blocks of decision numbers (§6, `scripts/slice-env`, `scripts/resources.tsv`). The code key of the parts (§10.1) is now the content of the worktree, not the commit. Reason: a review of all sessions to 2026-11-07. About one quarter of all commits were hand edits of §0, §8, and §9. The user asked for the progress more than 15 times, and each answer was a set of hand-made commands. Parallel slices took the same `Dxx` number, and agents renumbered decisions 10 times. A commit with no code change made the review run the passed parts again.
- **2026-11-07**: Guards (§10, §12). git-guard parses the command. A command that only mentions a blocked word passes. plan-guard also checks shell commands (writes to the plan file and to guard files) and the paths in each worktree. `scripts/check-plan` with no arguments runs as `--staged`. It also stops build output and large files. The new `pre-merge-commit` hook checks each merge commit. `.claude/hooks/guard-test` tests the guards. Reason: git-guard stopped read-only commands. Agents edited the plan file through shell commands, and plan-guard did not see these edits. A session in `main` edited files in a worktree with no check. A 28 MB build directory went into a commit. Merge commits had no automatic check.
- **2026-11-07**: Bug fixes (§3, §3.1, §5.2, §12). The coordinator does not change code. A bug that the user reports becomes a fix slice (`scripts/plan fix`), with its own branch, session, and merge (§10). On `main`, the pre-commit hook stops a commit that changes code and is not a merge. Reason: after the run ended, the user reported bugs from a real iPhone to the coordinator. The coordinator fixed them on `main` (`505aa7d`, `2c650d1`), with no slice branch and no review run. No rule said who fixes a bug after a merge, and no hook stopped code commits on `main`.
- **2026-11-08**: Free space and cleanup (§5.4, §6, §6.1, §10). The guard stops a demo or review when the data volume has less than 30 GB free. `scripts/plan merged` removes the simulator, the `/tmp/dshm-*` paths, the merged worktrees and branches, and the `DSHM_HOME` of the slice. `scripts/plan cleanup <ID>` does the same for a slice in `review` or `done`. `scripts/status` shows the free space and the leftovers. Reason: on 2026-11-08 the data volume had 8.3 GB free. The run left 23 `dshm-*` simulators, 30 merged worktrees, and about 230 `/tmp/dshm-*` directories. No script removed them.
