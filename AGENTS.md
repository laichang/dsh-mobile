# AGENTS.md

dsh-mobile is the iOS client for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (DSH). DSH runs tasks on the user's own machines; the phone only **dispatches tasks, watches progress, makes decisions, and receives results**. It never calls model APIs directly.

## What to read

Read on demand, not all at once:

1. **This file**: what the repo is and where to find more.
2. **[STORY.md](STORY.md)** (in Chinese): product vision, the nine design principles, non-goals, and capabilities that depend on upstream DSH. Read it before making any product or UX decision; confirm with the user before going against it.
3. **[ARCHITECTURE.md](ARCHITECTURE.md)**: tech stack, system shape (iOS app + DSH bridge plugin + protocol), key decisions with rationale, milestones, and open risks. Read it before writing code; update it when a decision changes.

## Repo layout

- `dsh-mobile/`: SwiftUI app source (currently just the Xcode template)
- `dsh-mobile.xcodeproj/`: Xcode project

## Conventions

- Write AGENTS.md and other agent-facing docs in English.
