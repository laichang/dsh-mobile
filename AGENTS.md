# AGENTS.md

dsh-mobile is the iOS client for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (DSH). DSH runs tasks on the user's own machines; the phone only **dispatches tasks, watches progress, makes decisions, and receives results**. It never calls model APIs directly.

## What to read

Read on demand, not all at once:

1. **This file**: what the repo is and where to find more.
2. **[STORY.md](STORY.md)** (in Chinese): product vision, the nine design principles, non-goals, and capabilities that depend on upstream DSH. Read it before making any product or UX decision; confirm with the user before going against it.
3. **[ARCHITECTURE.md](ARCHITECTURE.md)**: tech stack, system shape (iOS app + DSH bridge plugin + protocol), key decisions with rationale, milestones, and open risks. Read it before writing code; update it when a decision changes.
4. **[PLAN.md](PLAN.md)**: current build plan. A tracer bullet (T0) first, then near-independent vertical slices to M1. Read it before picking up work; it's a working doc and gets archived when M1 exits.

## Repo layout

- `dsh-mobile/`: SwiftUI app source (currently just the Xcode template)
- `dsh-mobile.xcodeproj/`: Xcode project

## Code is truth

- **Code is the source of truth.** The code should express the ideas in STORY.md and ARCHITECTURE.md, and every idea should map to code. If code and docs disagree, either fix the code or update the doc. Don't leave them out of sync.
- **Archive working docs once they're done.** Any discussion, proposal, plan, or design note about the app (code, UX, architecture, etc.) is temporary. When it has been acted on or dropped, move it to `.archive/YYYYMMDD/<topic>.md`, using the date it was archived. Archived files are history, not guidance. Don't treat them as current; the code and the living docs (this file, STORY.md, ARCHITECTURE.md) are.

## Conventions

- Write AGENTS.md and other agent-facing docs in English.
