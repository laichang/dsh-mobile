<div align="center">

# dsh-mobile

**Your agent works on your own machine. You steer from your phone.**

The native iOS client for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (DSH).
Dispatch tasks, watch progress, approve risky actions, and get results back from every machine you run DSH on.

[![iOS 26](https://img.shields.io/badge/iOS-26-000000?logo=apple&logoColor=white)](#requirements)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](ios/)
[![TypeScript](https://img.shields.io/badge/bridge-TypeScript-3178C6?logo=typescript&logoColor=white)](bridge/)
[![Protobuf](https://img.shields.io/badge/protocol-protobuf-4285F4)](protocol/)
[![E2E: Noise](https://img.shields.io/badge/E2E-Noise_IK-2ea44f)](#security)
[![License: PolyForm Noncommercial](https://img.shields.io/badge/license-PolyForm_Noncommercial-blue)](#license)
[![Status: preview](https://img.shields.io/badge/status-preview-orange)](#status)

English · [简体中文](README.zh-CN.md)

<br/>

<table>
  <tr>
    <td align="center"><img src="evidence/T1/t1-session-page.png" width="200" alt="Session page with milestone card"/><br/><sub>Live progress as milestones</sub></td>
    <td align="center"><img src="evidence/S14/s14-drawer.png" width="200" alt="Drawer grouped by host and workspace"/><br/><sub>Every host, workspace, session</sub></td>
    <td align="center"><img src="evidence/S15/s15-all-tasks.png" width="200" alt="All tasks with pending approvals"/><br/><sub>Approvals that say what they do</sub></td>
  </tr>
</table>

<sub>Real screenshots of the app in the iOS Simulator, taken by its demo scripts.</sub>

</div>

---

## Why

DSH lives on your machines: the Mac at home, the PC at work, a cloud box behind NAT. It can read and write files, run commands, drive a browser. It has a Web UI and a desktop app, but no phone app.

Real tasks take minutes, not seconds:

> *"Turn the Q3 report on my desktop into slides and email them to me."*
> *"Fix the failing CI test in that repo and open a PR."*
> *"I'm at the airport. Compress yesterday's footage and upload it."*

You don't want to sit and watch. You want to hand it off, get pinged when it needs you, and approve the `rm -rf` from wherever you are. That's dsh-mobile.

The phone does exactly four things: **dispatch, watch, decide, receive.** It never calls a model API and never holds an API key. Every request runs on your own hardware.

## Features

- 📱 **One entry point.** The app opens on a blank session, ready to type. Quick questions come back inline; long jobs turn into trackable tasks.
- 🖥️ **Many hosts, treated the same.** Pair the home Mac, the office PC and a server. The drawer groups sessions by host › workspace, the way the desktop sidebar does.
- 🔄 **Same session everywhere.** Sessions started in the DSH Web UI or desktop app show up on the phone, and new replies stream in live.
- 🧭 **Milestones, not log spam.** Progress maps straight from DSH's own todos, plan and state events. No hidden summarizer model.
- ✋ **Approvals that say what they do.** The exact command, path or arguments, plus the agent's reason. Phone, Web and desktop all see the same request; the first answer wins.
- 🛑 **Never allowed by default.** No answer means the task stays paused, even when your phone is offline.
- 🧠 **Your model, your choice.** Pick the model and reasoning effort per task from the list that host offers, and switch mid-task. Names are shown exactly as the provider gives them.
- 📂 **Workspace picker.** The host's default, recent workspaces, or any absolute path on that host.
- ⏹️ **Interrupt any time.**
- 📴 **Survives bad networks.** A per-host event log with resume cursors: kill the app, lose Wi-Fi, reopen, and you see exactly what you missed. Nothing is lost.
- 🔐 **End-to-end encrypted.** Pair once by QR. Every frame is Noise-encrypted, on the LAN or over Tailscale alike. No relay and no server of ours: the phone talks straight to your hosts.
- 💬 **Talk to a running task.** Follow-up messages wait for the next turn or go in now; answer the agent's questions from a card or the composer; attach photos and files; dictate on the device.
- 🔒 **Live Activity.** Each running task ticks on the lock screen (local only, no push).
- 🧾 **Devices and audit.** See every paired device, revoke a lost phone, and review who approved what, when, from which device.

## How it works

```
 ┌─ iPhone ─────────────┐                              ┌─ your machine (×N) ─────────────────────┐
 │ dsh-mobile (SwiftUI) │   E2E-encrypted protobuf     │ DSH host process                        │
 │ SwiftData cache      │◄───── one WebSocket ────────►│  └ bridge plugin (TypeScript, Cordis)   │
 └──────────────────────┘   LAN / Tailscale            │     • pairing + device registry         │
                                                       │     • approval holder                   │
                                                       │     • milestone mapper · resume log     │
                                                       └─────────────────────────────────────────┘
```

DSH has no pairing, no push, no relay, and no stable public wire API yet. So this repo ships **three pieces**:

| Piece | Where | What it is |
|---|---|---|
| **iOS app** | [`ios/`](ios/) | SwiftUI, Swift 6 strict concurrency, `@Observable` stores, SwiftData cache. Logic lives in the `DSHKit` Swift package. |
| **Bridge plugin** | [`bridge/`](bridge/) | A Cordis plugin you install into the DSH you already run. It opens its own listener and absorbs upstream API churn, so the app never speaks DSH's internal protocol. |
| **Protocol** | [`protocol/`](protocol/) | The only contract between the two: `.proto` files, codegen for Swift and TS, and golden fixtures that both sides test against. |

Read [ARCHITECTURE.md](ARCHITECTURE.md) for the full design and the reasons behind it.

## Quick start

### Requirements

- macOS with **Xcode 26** and an **iOS 26** Simulator runtime
- [nvm](https://github.com/nvm-sh/nvm) (bootstrap installs Node 24 and pnpm for you)
- **No model API key.** The demos use DSH's own mock LLM server.

### 1. Try it in the Simulator

```bash
git clone https://github.com/laichang/dsh-mobile.git
```

```bash
cd dsh-mobile && scripts/bootstrap
```

`bootstrap` installs everything it needs under `~/.dshm` (your `~/.dsh` is left alone), builds the bridge, starts a real DSH `0.2.2-rc.1` with the mock model, and runs the first end-to-end round trip in the Simulator. It ends with:

```
bootstrap: done. The T0 round trip runs on this Mac.
```

Each feature has its own re-runnable demo, for example:

```bash
scripts/demo/all-tasks.sh
```

### 2. Use it with your own DSH

1. **Install the bridge** into the DSH profile you run (Node ≥ 24.9, pnpm on `PATH`):

   ```bash
   cd bridge && pnpm install && pnpm build
   ```

   ```bash
   dsh plugin --profile web add /path/to/dsh-mobile/bridge
   ```

2. **Restart DSH** (`dsh web`). The bridge listens on `0.0.0.0:47801` and prints a pairing QR while no phone is paired.
3. **Build the app** to your iPhone. Create `ios/Config/Signing.local.xcconfig` (git ignores it) with your own team and bundle ID prefix, then open `ios/dsh-mobile.xcodeproj` and run. A free Apple developer account is enough.

   ```
   DEVELOPMENT_TEAM = ABCDE12345
   DSHM_BUNDLE_ID_PREFIX = com.example
   ```

4. **Scan the QR** in the app. The phone tries each of the host's addresses, so the same Wi-Fi or Tailscale both work.

Need a fresh QR later (single use, valid 10 minutes)?

```bash
node bridge/lib/scripts/pair.js
```

Full install, configuration and state-file details: [bridge/README.md](bridge/README.md).

## Security

- **Noise protocol, end to end.** Pairing uses `Noise_IKpsk1_25519_ChaChaPoly_SHA256`: the QR carries the host's static key and a one-time 32-byte secret. Reconnects use `Noise_IK`. Implemented on CryptoKit (Swift) and `@noble/*` (TS), and both pass the official Noise test vectors plus shared golden transcripts.
- **Single-use, short-lived pairing codes.** A QR burns on first use and expires after 10 minutes, so a leaked screenshot is worth little.
- **Per-device keys and revocation.** The phone's key stays in the Keychain on this device only, never synced. Revoking a device closes its sockets at once and rejects reconnects.
- **Fail closed.** Approvals that nobody answers are never allowed; a timeout rejects.
- **No debug hooks in Release.** Plaintext channels, fake bridges and test launch arguments are Debug-only, and `scripts/check-release-clean` proves it.

> [!WARNING]
> The Noise implementation is hand-rolled and **has not been independently audited**. Reviews are very welcome.

## Status

Built and in use: everything under Features. Not built yet: risk tiers with Face ID for the top tier, plan alignment and pre-authorization, artifact preview and share-out, the share extension. Open work is in the [issues](https://github.com/laichang/dsh-mobile/issues).

**Out of scope:** installing or hosting DSH for you, on-device models (they would plug in later as a "this phone" host), calling model APIs from the phone, push notifications (APNs), a relay server, and guessing the host from the prompt.

> [!NOTE]
> DSH itself is a developer preview. The bridge supports DSH **`0.2.2-rc.1`** exactly. On any other version it still pairs and tells the app which versions are installed and supported, so you know what to update.

## Built with agents

This repo was planned, built and reviewed by AI coding agents (Claude Code and Codex) working in parallel, under one human's direction. The process itself is part of the project:

- **[STORY.md](STORY.md)**: product vision and the nine design principles (in Chinese). Every principle maps to a screen in **[design/screens.json](design/screens.json)**.
- **The plan** ([M1's, at tag `m1`](https://github.com/laichang/dsh-mobile/blob/m1/PLAN.md)): a tracer bullet first, then vertical slices. Each "Done when" item has a tier (`[auto]`, `[ui]`, `[human]`) and evidence that must resolve, checked by a pre-commit hook. A plan file exists only while a requirement is in progress; everything else is a [GitHub issue](https://github.com/laichang/dsh-mobile/issues).
- **[WORKFLOW.md](WORKFLOW.md)**: how a coordinator session runs slice sessions in git worktrees, how independent reviewers rerun every UI check, and which decisions stay with the human.
- **[`evidence/`](https://github.com/laichang/dsh-mobile/tree/m1/evidence)** (at tag `m1`): the screenshots behind each completed M1 slice.

If you're curious how far long-horizon agentic development can go on a real native app, start with WORKFLOW.md.

## Project layout

```
ios/            SwiftUI app · DSHKit package (protocol, connection, store, FakeBridge)
bridge/         DSH companion plugin (TypeScript, pnpm, node:test, FakeDSH)
protocol/       frame.proto + golden fixtures · regenerate with scripts/codegen
design/         screens (screens.json, screens/<id>.html → png, kit/), app icon
spikes/         X1–X4 experiments behind key decisions
scripts/        bootstrap · demo/<feature>.sh · codegen · check-plan · review
evidence/       screenshots cited by the current plan (only while one is in progress)
```

## Development

| Command | What it does |
|---|---|
| `scripts/bootstrap` | Set up a Mac and prove the round trip works |
| `cd ios/DSHKit && swift test` | Protocol, Noise, store and sync tests on the Mac |
| `cd bridge && pnpm test` | Bridge tests against `FakeDSH`, golden fixtures, Noise vectors |
| `scripts/codegen` | Regenerate Swift + TS from `protocol/*.proto` (`--check` fails if anything changes) |
| `scripts/demo/<feature>.sh` | Drive one feature end to end in the Simulator |
| `node scripts/dsh-up.mjs` | Start a local DSH + bridge with the mock model |

Enable the repo's git hooks after cloning:

```bash
git config core.hooksPath .githooks
```

## Contributing

Issues and PRs are welcome, especially Noise/crypto reviews, real-device testing, and bridge support for new DSH releases.

By submitting a contribution, you agree that the maintainer may license it under the project license and under separate commercial licenses.

Before writing code, read [AGENTS.md](AGENTS.md) (it applies to humans too): the code is the source of truth, and STORY, the screens and ARCHITECTURE change together with it. Product and UX changes should follow the principles in [STORY.md](STORY.md).

## Acknowledgements

- [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness), the agent runtime this app steers
- [Cordis](https://github.com/cordiverse/cordis), the plugin framework DSH and the bridge are built on
- [Noise Protocol Framework](https://noiseprotocol.org/), [swift-protobuf](https://github.com/apple/swift-protobuf), [protobuf-es](https://github.com/bufbuild/protobuf-es), [@noble](https://paulmillr.com/noble/)

## License

[PolyForm Noncommercial 1.0.0](LICENSE). Free for personal use, study, research, hobby projects and noncommercial organizations. **Commercial use needs the author's permission:** [open an issue](https://github.com/laichang/dsh-mobile/issues) to ask.

dsh-mobile is an independent community project. It is not affiliated with or endorsed by DeepSeek.
