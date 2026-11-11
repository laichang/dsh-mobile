# AGENTS.md

dsh-mobile is the iOS client for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (DSH). DSH runs tasks on the user's own machines; the phone only **dispatches tasks, watches progress, makes decisions, and receives results**. It never calls model APIs directly.

## What to read

Read on demand, not all at once:

1. **This file**: what the repo is and where to find more.
2. **[STORY.md](STORY.md)** (in Chinese): product vision, the nine design principles, non-goals, and capabilities that depend on upstream DSH. Read it before making any product or UX decision; confirm with the user before going against it.
3. **[design/screens.json](design/screens.json)**: the screens as data: for each screen, the STORY sections it serves, what it needs, where a user action goes, and its rules, each with the XCUITest that checks it. A screen is `design/screens/<id>.html` (the phone and its caption, on the shared `design/kit/`) with its png. STORY is DESIGN, DESIGN is STORY: read the screens of your work with STORY.md before any UI work, and change both together.
4. **[ARCHITECTURE.md](ARCHITECTURE.md)**: how dsh-mobile is built now: tech stack, system shape (iOS app + DSH bridge plugin + protocol), key choices with their reasons, and known limits. It tells only the current state (no decision IDs, no history, no milestones; at most 10k tokens; `scripts/check-docs`). Read it before writing code; change it in the same commit as the code it describes.
5. **[Process](#process)** (below): how work moves here. The scripts hold the rules; each refusal names the next step.
6. **`plan/`**: the plan of the current requirement, only while one is in progress: tracer bullets first, then near-independent vertical slices. Read it with `scripts/plan show <ID>`, `scripts/plan dag` and `scripts/status`. With no requirement there is no `plan/`: ideas, follow-ups and bugs are [GitHub issues](https://github.com/laichang/dsh-mobile/issues).

## Repo layout

- `ios/`: the iOS app. `ios/dsh-mobile.xcodeproj` (views in `ios/dsh-mobile/`, XCUITests in `ios/dsh-mobileUITests/`) and the local SwiftPM package `ios/DSHKit` (protocol, connection, store, `FakeBridge`; `swift test`)
- `bridge/`: the DSH companion plugin (TypeScript, pnpm; `FakeDSH` in `bridge/test/`). Install: `bridge/README.md`
- `protocol/`: the protobuf contract between the app and the bridge (`frame.proto`, golden `fixtures/`). Regenerate code with `scripts/codegen`
- `scripts/bootstrap`: sets up a new Mac and runs the first demo
- `scripts/xc`, `scripts/swift-test`, `scripts/pnpm-test`: run xcodebuild, `swift test` and `pnpm test` with a short JSON summary; the full log goes to `/tmp/dshm-*`. Use them, not the bare tools. `scripts/check-wrappers` fails on a bare call in a demo script or `scripts/review`; `scripts/wrap-test` tests both
- `scripts/demo/<feature>.sh`: re-runnable demo per feature (screenshots to `$DSHM_EVIDENCE`); `scripts/dsh-up.mjs` starts a local DSH + bridge with a mock model
- `design/`: the screens (`screens.json`; `screens/<id>.html` with its png from `scripts/render-design`; the shared `kit/`) and the app icon (`icon.svg`, `scripts/render-icon`). `scripts/check-design` checks the screens and the theme names (test: `scripts/check-design-test`)
- `evidence/<slice>/`: screenshots cited by the plan's `shot:` pointers; deleted with `plan/`
- `scripts/check-ids`: fails on a decision or slice ID in code (test: `scripts/check-ids-test`); `scripts/check-fixtures-same <rev>`: the golden fixtures keep their bytes
- `scripts/check-docs`: checks that ARCHITECTURE.md, STORY.md, AGENTS.md and the READMEs have no decision IDs or milestones section, and that ARCHITECTURE.md stays at most 10k tokens (test: `scripts/check-docs-test`)
- `scripts/check-plan`: guards `plan/` and what a commit holds (the git hooks run it)
- `scripts/review <ID>`: the review run of the `[ui]` items of one node; `scripts/demo/lib.sh` also holds the machine guard (load, simulators, free space)
- `scripts/plan`: writes and keeps `plan/` without hand edits (`scripts/plan --help`; schema and rules in `scripts/lib/plan.schema.json`, `scripts/lib/plandata.py`); `scripts/status`: the run in one screen; `scripts/slice-env <ID>`: the resources of a slice, from `scripts/resources.tsv`. Tests: `scripts/plan-test`, `scripts/refusal-test`
- `scripts/brief <ID>`: the one packet a build agent reads instead of these docs (test: `scripts/brief-test`)
- `.agents/skills/`: skills for all agents: `/start-requirement <milestone>`, `/run-plan`. `.claude/skills/<name>` links to each one
- `.githooks/`: git hooks; `.claude/`: Claude Code hooks; `.codex/`: Codex hooks (test: `.claude/hooks/guard-test`)

## Code is truth

- **Code is the source of truth.** The code should express the ideas in STORY.md and ARCHITECTURE.md, and every idea should map to code. If code and docs disagree, either fix the code or update the doc. Don't leave them out of sync.
- **STORY is DESIGN, DESIGN is STORY.** Every STORY principle maps to a screen in `design/screens.json`, and every screen serves a STORY principle (`scripts/check-design`). A change to one is a change to the other, in the same commit. A screen with `"built": false` is not in the code yet.
- **Delete working docs once they're done; there is no archive.** Any discussion, proposal, plan, or design note about the app (code, UX, architecture, etc.) is temporary. When it has been acted on or dropped, move what stays true into the code or a living doc (this file, STORY.md, design/screens.json, ARCHITECTURE.md), open an issue for what is still to do, and delete it. git keeps the history. Living docs and code never refer to a working doc.

## Conventions

- Delete comments that repeat the code. Keep comments that explain a reason or an external constraint.
- Write AGENTS.md and other agent-facing docs in English. The Process section follows the ASD-STE100 style: short sentences, one instruction in each sentence, active voice.

## Process

The scripts and the hooks hold the rules. When a script or a hook refuses, read its message: it names the next step.

### Entry commands

- A new Mac: run `scripts/bootstrap`.
- Start a requirement: the user runs `/start-requirement <milestone>`. The coordinator writes `plan/` with `scripts/plan new` and `scripts/plan add`.
- Run the plan: the user runs `/run-plan`. The coordinator runs `.claude/workflows/run-plan.js` with the args from `scripts/run-plan-args`.
- See the run: `scripts/status`, `scripts/plan show <ID>`, `scripts/plan dag`.
- Build a node: read `scripts/brief <ID>` only. Run `eval "$(scripts/slice-env <ID>)"` in the worktree of the node.
- Record a merge: `scripts/plan merged <ID> <merge-commit>`.
- Report a bug: on a plan, `scripts/plan fix`. With no plan, open a GitHub issue.

### Close a plan

- The user commits removal of the plan on main. The pre-commit hook runs `scripts/close-plan-simulators` against the committed registry and the live device list.
- If cleanup fails, read the diagnostic, resolve the device state, and retry the close commit.

### Decisions that stay with the user

Only the user does these things:

- Set a requirement, and approve its plan.
- Record a `[human]` item: the user runs `scripts/plan accept` in their own terminal and types the ID back.
- Confirm a provisional choice, a dependency, or a download.
- Push to GitHub, or open a pull request.
- Commit a change to a guard file, also the merge of a slice that changes one into `main`. The user reviews the guard diff and merges it by hand. The guard files are `PROTECTED` in `scripts/check-plan`.
- Delete `plan/` at the end of a requirement.

### Hooks

After you clone the repo, enable its git hooks (this repo only):

```bash
git config core.hooksPath .githooks
```

The pre-commit and pre-merge-commit hooks run `scripts/check-plan` and `scripts/check-ids`. The Claude Code and Codex hooks stop a bad edit of `plan/` and ask before an edit of a guard file.

- Do not go around the hooks. Do not use `git commit --no-verify` or `-n`. Do not change `core.hooksPath`.
- Do not set `CHECK_PLAN_ALLOW`. The user sets it, by hand, for a change that the user approved.
- Do not write `plan/` by hand. Use `scripts/plan`.
- Do not change code on `main`. Code goes into `main` only through the merge of a slice branch.
- If a check blocks you, tell the user in the conversation.
