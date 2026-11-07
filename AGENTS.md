# AGENTS.md

dsh-mobile is the iOS client for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (DSH). DSH runs tasks on the user's own machines; the phone only **dispatches tasks, watches progress, makes decisions, and receives results**. It never calls model APIs directly.

## What to read

Read on demand, not all at once:

1. **This file**: what the repo is and where to find more.
2. **[STORY.md](STORY.md)** (in Chinese): product vision, the nine design principles, non-goals, and capabilities that depend on upstream DSH. Read it before making any product or UX decision; confirm with the user before going against it.
3. **[DESIGN.md](DESIGN.md)**: the screens and interactions (`design/board.html`, rendered to `design/board.png` and `design/screens/`). STORY is DESIGN, DESIGN is STORY: read it with STORY.md before any UI work, and change both together.
4. **[ARCHITECTURE.md](ARCHITECTURE.md)**: tech stack, system shape (iOS app + DSH bridge plugin + protocol), key decisions with rationale, milestones, and open risks. Read it before writing code; update it when a decision changes.
5. **[WORKFLOW.md](WORKFLOW.md)**: how work moves here, for every agent (Claude Code, Codex, …): setting up a new Mac (`scripts/bootstrap`), the coordinator and slice sessions, the long-horizon run, status titles, merging, and what stays with the user. Read it before picking up any work. It's a living doc; it doesn't get archived with a plan.
6. **[PLAN.md](PLAN.md)**: current build plan. A tracer bullet (T0) first, then near-independent vertical slices to M1. Before picking up work, read its §0 status table and the format rules in "How to use this file". It's a working doc and gets archived when M1 exits.

## Repo layout

- `ios/`: the iOS app. `ios/dsh-mobile.xcodeproj` (views in `ios/dsh-mobile/`, XCUITests in `ios/dsh-mobileUITests/`) and the local SwiftPM package `ios/DSHKit` (protocol, connection, store, `FakeBridge`; `swift test`)
- `bridge/`: the DSH companion plugin (TypeScript, pnpm; `FakeDSH` in `bridge/test/`). Install: `bridge/README.md`
- `protocol/`: the protobuf contract between the app and the bridge (`frame.proto`, golden `fixtures/`). Regenerate code with `scripts/codegen`
- `scripts/bootstrap`: sets up a new Mac and runs the T0 demo (WORKFLOW.md §2)
- `scripts/demo/<slice>.sh`: re-runnable demo per slice; `scripts/dsh-up.mjs` starts a local DSH + bridge with a mock model
- `design/`: the design board (`board.html` is the source; `board.png` and `screens/` are renders from `scripts/render-design`). See DESIGN.md
- `evidence/<slice>/`: screenshots cited by PLAN.md `shot:` pointers
- `scripts/check-plan`: guards PLAN.md's Done when items (see PLAN.md "How to use this file")
- `scripts/review <ID>`: the review run of one slice; `scripts/demo/lib.sh` also holds the machine guard (WORKFLOW.md §6.1, §10.1)
- `scripts/plan`: PLAN.md bookkeeping (§0, §8, §9, ticks, Logs) without hand edits; `scripts/status`: the run in one screen; `scripts/slice-env <ID>`: the resources of a slice, from `scripts/resources.tsv` (WORKFLOW.md §5, §6). Tests: `scripts/plan-test`
- `.githooks/`: git hooks; `.claude/`: Claude Code hooks; `.codex/`: Codex hooks (WORKFLOW.md §12)

## Code is truth

- **Code is the source of truth.** The code should express the ideas in STORY.md and ARCHITECTURE.md, and every idea should map to code. If code and docs disagree, either fix the code or update the doc. Don't leave them out of sync.
- **STORY is DESIGN, DESIGN is STORY.** Every STORY principle maps to a screen on the design board, and every screen serves a STORY principle. A change to one is a change to the other, in the same commit. Each screen's milestone tag says whether the code has it yet (DESIGN.md).
- **Archive working docs once they're done.** Any discussion, proposal, plan, or design note about the app (code, UX, architecture, etc.) is temporary. When it has been acted on or dropped, move it to `.archive/YYYYMMDD/<topic>.md`, using the date it was archived. Archived files are history, not guidance. Don't treat them as current; the code and the living docs (this file, STORY.md, DESIGN.md, ARCHITECTURE.md, WORKFLOW.md) are.

## Conventions

- Write AGENTS.md and other agent-facing docs in English. WORKFLOW.md also follows the ASD-STE100 style (its header says how).

## Hooks

After cloning, enable the repo's git hooks (this repo only):

```bash
git config core.hooksPath .githooks
```

The pre-commit and pre-merge-commit hooks run `scripts/check-plan`. **Never bypass it**: no `git commit --no-verify` / `-n`, no overriding `core.hooksPath`. If a check blocks you, ask the user in the conversation.

Code reaches `main` only through the merge of a slice branch; on `main` the pre-commit hook stops any other commit that changes code. A bug the user reports becomes a fix slice (`scripts/plan fix`, WORKFLOW.md §5.2), even when the coordinator is the session that hears about it.

A PLAN.md rewrite the user has approved is made and committed by the user, by hand, with `CHECK_PLAN_ALLOW=1 git commit …`. Agents never set `CHECK_PLAN_ALLOW`.
