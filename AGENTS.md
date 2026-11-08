# AGENTS.md

dsh-mobile is the iOS client for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (DSH). DSH runs tasks on the user's own machines; the phone only **dispatches tasks, watches progress, makes decisions, and receives results**. It never calls model APIs directly.

## What to read

Read on demand, not all at once:

1. **This file**: what the repo is and where to find more.
2. **[STORY.md](STORY.md)** (in Chinese): product vision, the nine design principles, non-goals, and capabilities that depend on upstream DSH. Read it before making any product or UX decision; confirm with the user before going against it.
3. **[DESIGN.md](DESIGN.md)**: the screens and interactions (`design/board.html`, rendered to `design/board.png` and `design/screens/`). STORY is DESIGN, DESIGN is STORY: read it with STORY.md before any UI work, and change both together.
4. **[ARCHITECTURE.md](ARCHITECTURE.md)**: tech stack, system shape (iOS app + DSH bridge plugin + protocol), key decisions with rationale, milestones, and open risks. Read it before writing code; update it when a decision changes.
5. **[WORKFLOW.md](WORKFLOW.md)**: how work moves here, for every agent (Claude Code, Codex, …): setting up a new Mac (`scripts/bootstrap`), the coordinator and slice sessions, the long-horizon run, status titles, merging, and what stays with the user. Read it before picking up any work. It's a living doc.
6. **`PLAN.md`**: the plan of the current requirement, only while one is in progress: tracer bullets first, then near-independent vertical slices. Before picking up work, read its §0 status table and "How to use this file". With no requirement there is no PLAN.md: ideas, follow-ups and bugs are [GitHub issues](https://github.com/laichang/dsh-mobile/issues) (WORKFLOW.md §3.2).

## Repo layout

- `ios/`: the iOS app. `ios/dsh-mobile.xcodeproj` (views in `ios/dsh-mobile/`, XCUITests in `ios/dsh-mobileUITests/`) and the local SwiftPM package `ios/DSHKit` (protocol, connection, store, `FakeBridge`; `swift test`)
- `bridge/`: the DSH companion plugin (TypeScript, pnpm; `FakeDSH` in `bridge/test/`). Install: `bridge/README.md`
- `protocol/`: the protobuf contract between the app and the bridge (`frame.proto`, golden `fixtures/`). Regenerate code with `scripts/codegen`
- `scripts/bootstrap`: sets up a new Mac and runs the T0 demo (WORKFLOW.md §2)
- `scripts/demo/<slice>.sh`: re-runnable demo per slice; `scripts/dsh-up.mjs` starts a local DSH + bridge with a mock model
- `design/`: the design board (`board.html` is the source; `board.png` and `screens/` are renders from `scripts/render-design`). See DESIGN.md
- `evidence/<slice>/`: screenshots cited by the plan's `shot:` pointers; deleted with PLAN.md
- `scripts/check-plan`: guards the Done when items of PLAN.md (WORKFLOW.md §12)
- `scripts/review <ID>`: the review run of one slice; `scripts/demo/lib.sh` also holds the machine guard (WORKFLOW.md §6.1, §10.1)
- `scripts/plan`: writes and keeps PLAN.md without hand edits (`new`, `add`, `lint`, §0, §8, §9, ticks, Logs; format in `scripts/lib/plan-template.md`, WORKFLOW.md §3.1); `scripts/status`: the run in one screen; `scripts/slice-env <ID>`: the resources of a slice, from `scripts/resources.tsv` (WORKFLOW.md §5, §6). Tests: `scripts/plan-test`
- `.agents/skills/`: skills for all agents: `/start-requirement <milestone>`, `/run-plan` (WORKFLOW.md §3.2, §5.1). `.claude/skills/<name>` links to each one
- `.githooks/`: git hooks; `.claude/`: Claude Code hooks; `.codex/`: Codex hooks (WORKFLOW.md §12)

## Code is truth

- **Code is the source of truth.** The code should express the ideas in STORY.md and ARCHITECTURE.md, and every idea should map to code. If code and docs disagree, either fix the code or update the doc. Don't leave them out of sync.
- **STORY is DESIGN, DESIGN is STORY.** Every STORY principle maps to a screen on the design board, and every screen serves a STORY principle. A change to one is a change to the other, in the same commit. Each screen's milestone tag says whether the code has it yet (DESIGN.md).
- **Delete working docs once they're done; there is no archive.** Any discussion, proposal, plan, or design note about the app (code, UX, architecture, etc.) is temporary. When it has been acted on or dropped, move what stays true into the code or a living doc (this file, STORY.md, DESIGN.md, ARCHITECTURE.md, WORKFLOW.md), open an issue for what is still to do, and delete it. git keeps the history. Living docs and code never refer to a working doc.

## Conventions

- Write AGENTS.md and other agent-facing docs in English. WORKFLOW.md also follows the ASD-STE100 style (its header says how).

## Hooks

After cloning, enable the repo's git hooks (this repo only):

```bash
git config core.hooksPath .githooks
```

The pre-commit and pre-merge-commit hooks run `scripts/check-plan`. **Never bypass it**: no `git commit --no-verify` / `-n`, no overriding `core.hooksPath`. If a check blocks you, ask the user in the conversation.

Code reaches `main` only through the merge of a slice branch; on `main` the pre-commit hook stops any other commit that changes code. A bug the user reports becomes a fix slice (`scripts/plan fix`, WORKFLOW.md §5.2), even when the coordinator is the session that hears about it; with no plan, it becomes an issue.

A PLAN.md rewrite or deletion the user has approved is made and committed by the user, by hand, with `CHECK_PLAN_ALLOW=1 git commit …`. Agents never set `CHECK_PLAN_ALLOW`.
