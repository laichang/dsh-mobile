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
| Merge into `main` | Coordinator | `main` |
| `[human]` items, `Dxx` confirmation, push, pull request | User | — |

Rules:

- A slice owner edits only the section of its own slice.
- A slice owner does not edit §0, §8, or §9. Parallel branches that edit adjacent rows cause merge conflicts.
- If §0 must change, the slice owner writes this in its Log and its report. The coordinator then changes §0.
- A subagent gives its results to the slice owner. The slice owner records them in the Log.

## 4. Start and stop a work session

### 4.1 Before you start

1. Read [AGENTS.md](AGENTS.md).
2. Read this file.
3. Read §0 of the plan file.
4. Read the section of your slice, together with its Log.
5. Read `git log` from the date of the last Log entry of your slice.
6. Run `scripts/demo/t0.sh`. If it fails, repair it first.
7. Set your status title (§7).

### 4.2 Before you stop

1. Add an entry to the Log of your slice. Write what is done, what is not done, and the next step.
2. Commit on the slice branch.
3. Set your status title (§7).
4. In your report, list each new provisional item (§9).

## 5. Long-horizon run

The user starts the coordinator one time. After that, the coordinator moves the plan forward without help from the user. It continues until the plan is complete, or until all remaining slices wait for the user.

### 5.1 Kickoff message

The user sends this message (or a message with the same meaning) to the coordinator:

> You are the coordinator. Follow WORKFLOW.md. Run the plan to the end without my help. Start each slice in its own session. If you cannot start a session, run the slices as a workflow or as background agents.

This message gives the coordinator permission for sessions, workflows, and background agents.

### 5.2 Rules for the coordinator

- Do not propose a session card that waits for a click. The user does not click cards. Start the session, or use the fallback in §5.3.
- Start slices whose **Needs** are met. Start a maximum of 3 slices in one batch.
- Give each slice its resources (§6) before you start it.
- Give each slice owner a brief. The brief contains: the slice ID, the branch, the worktree, the resources, the session settings (§8), the default choices (§9), and the status title rules (§7).
- When a slice owner stops, examine its result. Do not trust its report alone.
- Merge each slice that meets the merge conditions (§10). Then start the next slice.
- Keep §0 and your own status title (§7) up to date after each change.
- Stop only when no slice can move without the user. Then tell the user what waits for them.

### 5.3 Session start limit and fallback

WARNING: In the Claude desktop app, a session can start other sessions only in a turn that comes from the user. A turn that comes from a completion event can also start sessions, but only in a chain that began with a user turn. The chain ends when a turn stops or fails, or after many events with no user turn. A turn that comes from a message of another session can only propose cards.

Do these steps to keep the run moving:

1. In the kickoff turn, start the first batch as sessions.
2. When a completion event arrives, merge the finished slice and start the next slice in the same turn.
3. If the app refuses to start a session, do not propose a card. Run the remaining slices as a workflow (Claude Code) or as background processes (Codex: `codex exec -C <worktree>`).
4. Record the change in §8 of the plan file.

CAUTION: Never send a message to the coordinator for the user. A relayed message breaks the chain in step 2.

## 6. Resources for each slice

Slices run tests at the same time. Each slice therefore gets its own resources:

| Resource | Rule | Example (S1) |
|---|---|---|
| Worktree | `.claude/worktrees/<name>` or the worktree that the tool creates | `wf_219b7aa1-71c-2` |
| Branch | `claude/<id>-<short-name>` | `claude/s1-pair-encrypt` |
| Bridge port | Next free port from 47810 | 47810 |
| DSH web port | Next free port from 3283 | 3283 |
| `DSH_HOME` | `~/.dshm/home-<id>` | `~/.dshm/home-s1` |
| Simulator | `dshm-<ID>`, an iOS 26 iPhone | `dshm-S1` |

- The coordinator gives the resources and records them in §8 of the plan file.
- A slice uses only its own resources. All slices use the DSH install in `~/.dshm/runtime` read-only.
- Port 47800 is for demos on `main`. Port 47801 is for `scripts/demo/t0.sh`.
- The slice demo script reads the resources from `DSHM_BRIDGE_PORT`, `DSHM_WEB_PORT`, `DSHM_HOME`, and `DSHM_SIM`.

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

- **Decisions.** At a toolchain or design choice, continue with your recommendation. Record it in [ARCHITECTURE.md](ARCHITECTURE.md) as a `Dxx` entry. Mark the entry **provisional, pending user confirmation**. List the alternatives that you considered.
- **Dependencies and downloads.** You can add them without permission. Pin each one: an exact version, or a commit and a checksum. Record each one as provisional, and name it in the Log of the slice.
- **Reports.** List each new provisional item in your report to the coordinator. The coordinator adds it to §9 of the plan file with the slice, the branch, and the commit.
- **Confirmation.** A provisional item stays provisional until the user confirms it. When the user confirms or changes it, the owner removes the marker or applies the change.
- **Briefs.** Each brief from the coordinator contains these rules.

## 10. Merge a slice

The coordinator merges a slice branch into `main` without permission when all these conditions are true:

1. Each `[auto]` and `[ui]` item of the slice is ticked, and each evidence pointer resolves.
2. A reviewer ran each `[ui]` item again, and each item passed.
3. `scripts/check-plan` passes. For a merge commit, run `scripts/check-plan --base <PLAN.md before the merge> --new PLAN.md` by hand, because the pre-commit hook does not run on a merge commit.

The merge does not wait for `[human]` items. After the merge:

- If the slice has open `[human]` items, set §0 to `review`. Add each open `[human]` item to §9 with the device or setup that it needs.
- If the slice has no open `[human]` items, set §0 to `done`.
- A slice in `review` becomes `done` when the user ticks its last `[human]` item.
- A merged slice meets the **Needs** of other slices, also in `review`.
- If the user finds a problem during acceptance, repair it on `main`. Do not revert the merge.
- Tell the user in one or two sentences what you merged and where the evidence is.
- Bookkeeping commits on `main` (§0, §8, §9) do not need permission.

If a condition is false, do not merge. Tell the user what is missing.

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
| `.githooks/pre-commit` | All tools | Runs `scripts/check-plan` on each commit. |
| `.claude/hooks/plan-guard` | Claude Code only | Stops a bad edit of the plan file before it occurs. Asks the user before an edit of a guard file. |
| `.claude/hooks/git-guard` | Claude Code only | Stops `--no-verify`, `core.hooksPath` changes, and `CHECK_PLAN_ALLOW`. |
| `.codex/hooks/codex-guard` (from `.codex/hooks.json`) | Codex only | Runs `git-guard` on shell commands. Runs the plan-guard checks on `apply_patch` edits. Denies each edit of a guard file. |

Rules for all agents:

- Do not use `git commit --no-verify` or `git commit -n`.
- Do not change `core.hooksPath`. Its value is `.githooks`.
- Do not set `CHECK_PLAN_ALLOW`. Only the user sets it, by hand.
- Do not tick a `[human]` item. The pre-commit hook cannot tell who ticked an item. Thus this rule depends on you.
- Do not edit a guard file without permission.

Differences in Codex:

- Codex does not support the `ask` decision. Thus `codex-guard` denies each change that Claude Code asks about. If a guard stops you, ask the user in the chat.
- Codex runs the project hooks only after the user trusts them (§2.1). Without trust, only the pre-commit hook applies.
- After a change to `codex-guard`, run `.codex/hooks/codex-guard-test`.

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
