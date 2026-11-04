# AGENTS.md

dsh-mobile is the iOS client for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (DSH). DSH runs tasks on the user's own machines; the phone only **dispatches tasks, watches progress, makes decisions, and receives results**. It never calls model APIs directly.

## What to read

Read on demand, not all at once:

1. **This file**: what the repo is and where to find more.
2. **[STORY.md](STORY.md)** (in Chinese): product vision, the nine design principles, non-goals, and capabilities that depend on upstream DSH. Read it before making any product or UX decision; confirm with the user before going against it.
3. **[ARCHITECTURE.md](ARCHITECTURE.md)**: tech stack, system shape (iOS app + DSH bridge plugin + protocol), key decisions with rationale, milestones, and open risks. Read it before writing code; update it when a decision changes.
4. **[PLAN.md](PLAN.md)**: current build plan. A tracer bullet (T0) first, then near-independent vertical slices to M1. Before picking up work, read its "How to use this file" section and the §0 status table. It's a working doc and gets archived when M1 exits.

## Repo layout

- `ios/`: the iOS app. `ios/dsh-mobile.xcodeproj` (views in `ios/dsh-mobile/`, XCUITests in `ios/dsh-mobileUITests/`) and the local SwiftPM package `ios/DSHKit` (protocol, connection, store, `FakeBridge`; `swift test`)
- `bridge/`: the DSH companion plugin (TypeScript, pnpm; `FakeDSH` in `bridge/test/`). Install: `bridge/README.md`
- `protocol/`: the protobuf contract between the app and the bridge (`frame.proto`, golden `fixtures/`). Regenerate code with `scripts/codegen`
- `scripts/demo/<slice>.sh`: re-runnable demo per slice; `scripts/dsh-up.mjs` starts a local DSH + bridge with a mock model
- `evidence/<slice>/`: screenshots cited by PLAN.md `shot:` pointers
- `scripts/check-plan`: guards PLAN.md's Done when items (see PLAN.md "How to use this file")
- `.githooks/`: git hooks; `.claude/`: Claude Code hooks for this repo

## Code is truth

- **Code is the source of truth.** The code should express the ideas in STORY.md and ARCHITECTURE.md, and every idea should map to code. If code and docs disagree, either fix the code or update the doc. Don't leave them out of sync.
- **Archive working docs once they're done.** Any discussion, proposal, plan, or design note about the app (code, UX, architecture, etc.) is temporary. When it has been acted on or dropped, move it to `.archive/YYYYMMDD/<topic>.md`, using the date it was archived. Archived files are history, not guidance. Don't treat them as current; the code and the living docs (this file, STORY.md, ARCHITECTURE.md) are.

## Conventions

- Write AGENTS.md and other agent-facing docs in English.

## Hooks

After cloning, enable the repo's git hooks (this repo only):

```bash
git config core.hooksPath .githooks
```

The pre-commit hook runs `scripts/check-plan`. **Never bypass it**: no `git commit --no-verify` / `-n`, no overriding `core.hooksPath`. If a check blocks you, ask the user in the conversation.

A PLAN.md rewrite the user has approved is made and committed by the user, by hand, with `CHECK_PLAN_ALLOW=1 git commit …`. Agents never set `CHECK_PLAN_ALLOW`.
