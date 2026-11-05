# PLAN

How we get from the Xcode template to M1, tracer-bullet style. Product intent: [STORY.md](STORY.md). Technical design: [ARCHITECTURE.md](ARCHITECTURE.md). This file is a working doc: when M1 exits, archive it to `.archive/YYYYMMDD/plan-m1.md` and write the next one.

## How to use this file

**Process rules** live in [WORKFLOW.md](WORKFLOW.md): set up a Mac, roles and ownership (who writes §0, §8, §9, and each slice section), start and stop a work session, the long-horizon run, resources for each slice, status titles, session settings, default choices, merging a slice, and what stays with the user. Read it before you pick up work. This section keeps only the format of this file and the rules for Done when items.

**Slice fields**, always in this order. Write "—" for an empty field; never drop one.
`Status · Needs · Branch` on one line, then **Why**, **Cuts**, **Demo**, **Done when**, **Not**, **Log**.
- **Status** is one of `todo` / `doing` / `blocked` / `review` / `done`. The slice owner sets it on the branch; the coordinating session brings §0 in line.
- **Log** is append-only and dated: done, not done, next step, and anything learned along the way. Technical decisions go into ARCHITECTURE.md as a `Dxx` entry; the Log just says "see Dxx".

**Done when items** are checkboxes: `- [ ] [tier] description — Evidence: …`
- **Tiers**
  - `[auto]`: unit or integration test against `FakeBridge`, `FakeDSH`, or golden fixtures. Evidence: `test:` pointers, green in CI or a script.
  - `[ui]`: verified in the Simulator, preferably by XCUITest (`test:`), otherwise by an agent driving it through `scripts/demo/<slice>.sh` (`cmd:`). Add a `shot:` as a snapshot for people. Before the slice is marked `done`, a review subagent that didn't take part in development reruns every `[ui]` item.
  - `[human]`: real device, camera, packet capture, subjective experience, or a decision only the user can judge. **Only the user ticks these.** An agent never does.
- **Edit rules**: you may only tick `[ ]` → `[x]` or add new items. Never delete, reword, re-tier, untick, or move an item. Agents add items unticked and tick them in a later edit. If an item truly has to change, explain the original text, the new text, and the reason to the user in the conversation first, and let the user make the edit.
- **Evidence** on a ticked item is one or more typed pointers separated by ` · `. Each one must resolve, otherwise check-plan fails; unknown types fail too.

  | Pointer | Resolves when |
  |---|---|
  | `test:<Name>` | the name appears in Swift/TS test sources (`Suite/name` = both parts in one file) |
  | `cmd:<path> [args]` | the repo-relative path exists and is executable, e.g. `cmd:scripts/demo/t0.sh` |
  | `commit:<hash>` | `git cat-file -e <hash>^{commit}` succeeds |
  | `shot:<path>` | the file exists under `evidence/<slice ID>/` |
  | `human:<YYYY-MM-DD> <device or note>` | `[human]` items only, e.g. `human:2026-11-20 iPhone 16, PR link …` |

  The real evidence is something re-runnable: a test or `scripts/demo/<slice>.sh`. Screenshots are only snapshots for people:
  - Scale them to about 1/3 size and save as compressed PNG, a few hundred KB each.
  - Commit them under `evidence/<slice ID>/`.
  - Recordings stay out of git. If one is really needed, the user attaches it to the PR and the item cites it as `human:` plus the PR link.
  - When M1 is archived, `evidence/` moves with this file to `.archive/YYYYMMDD/`.
- **Enforcement**: `scripts/check-plan` runs from the git pre-commit hook (`.githooks/`) and from a Claude Code PreToolUse hook (`.claude/settings.json`). Edits to the guard files themselves (`scripts/check-plan`, `.githooks/`, `.claude/hooks/`, `.claude/settings.json`) ask the user first, and only the user commits them. Never use `git commit --no-verify` or any other way around them.

## 0. Status

| ID | Status | Branch/PR | Updated | Next action |
|---|---|---|---|---|
| T0 | review | merged `84db2e8` | 2026-11-05 | User accepts 3 `[human]` items (§9) |
| X1 | done | merged `ccc8ff9` | 2026-11-05 | — |
| X2 | done | merged `e34a8bc` | 2026-11-05 | — (provisional D6 and deps in §9) |
| X3 | doing | claude/x3-markdown | 2026-11-05 | Implement and verify |
| X4 | done | merged `ccc8ff9` | 2026-11-05 | — |
| S1 | review | merged `1f35fa2` (batch 1) | 2026-11-05 | User accepts 2 `[human]` items: real iPhone, packet capture (§9) |
| S2 | done | merged `1f35fa2` (batch 1) | 2026-11-05 | — (provisional D20, D23 in §9) |
| S3 | done | merged `1f35fa2` (batch 1) | 2026-11-05 | — (provisional D19 in §9) |
| S4 | doing | `claude/s4-approvals` | 2026-11-05 | Implement and verify in batch 2 |
| S5 | done | merged `529bb16` | 2026-11-05 | — (provisional D28 in §9) |
| S6 | doing | `claude/s6-models` | 2026-11-05 | Implement and verify in batch 2 |
| S7 | todo | — | 2026-11-05 | Ready (T0 merged); batch 2 |
| S8 | todo | — | 2026-11-05 | Wait for X3 (T0 merged) |
| S9 | todo | — | 2026-11-05 | Ready (S1 merged) |
| S10 | todo | — | 2026-11-05 | Ready (S1 merged) |
| S11 | todo | — | 2026-11-05 | Ready (S1 merged) |
| S12 | todo | — | 2026-11-05 | Ready (T0 merged); also pins D17's prepend ordering |

## 1. Approach

**Tracer bullet first.** Before any feature is built properly, fire one thin round trip through *every* layer of the real architecture: SwiftUI → `HostConnection` → `SecureChannel` → WebSocket → protobuf `Frame` → bridge plugin → DSH session → and back. It's thin but it's production code, not a throwaway prototype. Everything after it thickens that path.

**Then slices that are almost independent and stand alone.** Each slice after the tracer:

- is **vertical**: it touches protocol + bridge + app + tests, and has a demo you can do on its own;
- **depends on the tracer (T0) and nothing else**, unless a dependency is named explicitly (at most one, where possible);
- can be built, reviewed, merged, and dropped **in any order** relative to its siblings.

### How slices stay independent

| Rule | Mechanism |
|---|---|
| Own files | Each slice gets `protocol/<slice>.proto`, `ios/…/Features/<Slice>/`, `bridge/src/<slice>/`. Shared files (`frame.proto`, app root, plugin entry) only get a one-line registration. |
| No field-number collisions | `Request` / `Event` oneofs reserve **20 field numbers per slice** (T0: 1–19, S1: 20–39, S2: 40–59, …). Parallel branches never fight over tags. |
| Ship in any order | Each slice advertises a **capability string** in `Hello.capabilities` (e.g. `approvals.v1`). The app hides UI for capabilities the bridge lacks. This is the same mechanism that later handles bridge N / N-1. |
| Test alone | Fakes at every boundary: **`FakeBridge`** (Swift, in-process) for app tests and previews; **`FakeDSH`** (TS) for bridge tests. No slice needs a neighbor slice or a real DSH to pass CI. |
| Cross-language truth | `protocol/fixtures/` holds golden encoded frames. Swift and TS tests both decode/encode them, so the two sides can't drift. |
| Seams | When two slices meet (e.g. resume × approvals), **the slice that lands second owns the seam** and adds it to its Done when. |

**Done** for any slice = every Done when item ticked with evidence, merged to `main`, ARCHITECTURE.md updated if a decision changed (AGENTS.md: code is truth).

## 2. Map

```mermaid
flowchart LR
    T0([T0 · Tracer bullet])

    X1[X1 · Spike: approval answerer]
    X2[X2 · Spike: Noise interop]
    X3[X3 · Spike: streaming Markdown]
    X4[X4 · Spike: mid-task context]

    T0 --> S1[S1 · Pair + encrypt]
    T0 --> S2[S2 · Durable list + resume]
    T0 --> S3[S3 · Milestones]
    T0 --> S4[S4 · Approvals]
    T0 --> S5[S5 · Interrupt]
    T0 --> S6[S6 · Models]
    T0 --> S7[S7 · Workspaces]
    T0 --> S8[S8 · Rich detail]
    T0 --> S12[S12 · Upstream guard]

    X2 -.-> S1
    X1 -.-> S4
    X3 -.-> S8
    X4 -.-> M2([M2 · mid-task context])

    S1 --> S9[S9 · Multi-host]
    S1 --> S10[S10 · Control: devices + audit]
    S1 --> S11[S11 · First run]
```

Solid = must land first. Dotted = spike result must exist first (a written conclusion, not code). Spikes depend on nothing and can start today, in parallel with T0.

## 3. T0 · Tracer bullet

**Status** review · **Needs** — · **Branch** `claude/t0-tracer-513793` (merged `84db2e8`)

**Why**: prove every layer of the architecture end to end before building any feature. Type one sentence in the iOS Simulator; text streams back from a DSH agent running on the same Mac.

**Cuts**
- `ios/`: move the Xcode project here. One screen: text field, send button, streaming text. `@Observable` store, in-memory only. One `HostConnection` actor, address hardcoded to `127.0.0.1:<port>`. `SecureChannel` protocol with a single `PlaintextChannel` implementation that **refuses any non-loopback address**.
- `protocol/`: `frame.proto` with `Frame { oneof { Request, Response, Event } }`, `Hello { protocol_version, capabilities }`, `CreateTask { prompt }` → `TaskCreated { task_id }`, events `AssistantChunk { task_id, seq, text }`, `TaskEnded { task_id, status }`. Codegen script for Swift + TS. First golden fixtures.
- `bridge/`: Cordis plugin that opens its own WebSocket listener on loopback, speaks the frame protocol through the same plaintext channel, maps `CreateTask` to a DSH session + prompt (DSH's default model and a fixed cwd), and forwards assistant text.
- Tests: fixture round trip in Swift and TS; bridge test against `FakeDSH`; app store test against `FakeBridge`.
- Testability entry points, **debug builds only**:
  - launch arguments that inject `FakeBridge` and preset state;
  - accessibility identifiers on key controls;
  - a reserved `dshm://pair?…` deep link, so S1's pairing flow can be tested end to end in the Simulator without a camera.

**Demo**: in the Simulator, type a read-only prompt; the answer streams back from the real DSH on the same Mac.

**Done when**
- [x] [auto] Golden fixtures round-trip in both Swift and TS tests — Evidence: test:GoldenFixtures/fixturesRoundTrip · cmd:scripts/demo/t0.sh
- [x] [auto] Bridge `CreateTask` → session + prompt → `AssistantChunk` / `TaskEnded` passes against `FakeDSH` (CI) — Evidence: test:BridgeAgainstFakeDSH/createTaskStreamsChunksThenTaskEnded · test:BridgeAgainstFakeDSH/failedTurnEndsWithFailedStatus · cmd:scripts/demo/t0.sh
- [x] [auto] App store test streams a task to completion against `FakeBridge` — Evidence: test:TaskStoreTests/streamsTaskToCompletionAgainstFakeBridge · cmd:scripts/demo/t0.sh
- [x] [auto] `PlaintextChannel` refuses a non-loopback address — Evidence: test:PlaintextChannelTests/refusesNonLoopbackAddress · test:PlaintextChannelTests/connectionRefusesNonLoopbackBeforeOpeningTransport · test:PlaintextChannelBridge/refusesNonLoopbackAddress
- [x] [ui] Demo passes in the Simulator against a real DSH `v0.2.2-rc.1` (local acceptance; CI uses `FakeDSH`) — Evidence: test:T0DemoUITests/testDemoAgainstRealDSH · cmd:scripts/demo/t0.sh · shot:evidence/T0/t0-real-dsh-done.png
- [x] [ui] With the `FakeBridge` launch argument, an XCUITest runs the demo with no DSH, finding controls by accessibility identifier — Evidence: test:T0DemoUITests/testDemoWithFakeBridge · cmd:scripts/demo/t0.sh · shot:evidence/T0/t0-fakebridge-done.png
- [x] [auto] Debug build routes `dshm://pair?…` to a pairing entry point (a stub until S1) — Evidence: test:DebugEntryPointTests/routesPairDeepLink · test:T0DemoUITests/testPairDeepLinkOpensPairingStub · shot:evidence/T0/t0-pair-deeplink-stub.png
- [x] [auto] Release build contains none of the testability entry points (launch arguments, `FakeBridge`, `dshm://pair`) — Evidence: cmd:scripts/check-release-clean
- [ ] [human] Following `bridge/README.md` installs and enables the plugin in a DSH profile (answers ARCHITECTURE §8.2) — Evidence:
- [ ] [human] Toolchain choices (codegen tool, whether generated code is committed, bridge package manager, Swift package layout) recorded in ARCHITECTURE.md — Evidence:
- [ ] [human] Testability entry points (launch arguments, accessibility identifiers, `dshm://` deep link) recorded in ARCHITECTURE.md — Evidence:

**Not**: pairing, encryption, persistence, reconnect, milestones, approvals (DSH fails closed on any approval, which is fine; use read-only prompts), model or workspace choice, real device.

**Log**
- **2026-11-05 · start.**
  - Done:
    - Fast-forwarded the branch to local `main` (`10d4639`); it had been cut from `0bda405`, before PLAN.md and the guards. `origin/main` is still at `0bda405`.
    - Moved the Xcode project to `ios/` (`ios/dsh-mobile.xcodeproj`, `ios/dsh-mobile/`). It still builds for the iOS Simulator; the template's build settings (multiplatform, Swift 5 mode) are untouched for now.
    - Drafted `protocol/frame.proto`: `Frame { Request | Response | Event }`, `Hello` as the first request (answered with the bridge's `Hello`), `CreateTask` → `TaskCreated`, `AssistantChunk`, `TaskEnded`, plus a generic `Error` response. Field ranges per slice are written in its header.
  - Found: no DSH `v0.2.2-rc.1` install on this Mac (npm `next` = `0.2.2-rc.1`; `~/.dsh/profiles/web` exists but has only the default bundles; no `protoc`/`buf`). Prior art in `~/dsh-remote/spikes/host/SPIKE-S1.md`: a Cordis plugin bundle installed with `dsh plugin --profile web add <dir>`, DSH needs Node ≥ 24.9, and `@deepseek-ai/dsh-llm-mock-server` drives a DSH session without a model key.
  - Not done: everything else. Blocked on the user for the toolchain choices (codegen tool, committing generated code, bridge package manager, Swift package layout), the dependencies to add, and where the DSH install and profile should live.
  - Next: once the user answers, record the choices as a `Dxx` entry, add codegen + fixtures, then bridge + `FakeDSH`, then the app + `FakeBridge`.
- **2026-11-05 · built, to review.**
  - The user's answers were relayed by the coordinating session: use the recommended defaults and mark them provisional, approve every listed dependency and download, use the mock LLM (no API key), and tick the real-DSH `[ui]` item with the mock noted. Choices are recorded in D15 (toolchain) and D16 (testability entry points), both *provisional, pending user confirmation*.
  - Done (commits `28d1bda`, `b54c8d5`, `03cc202`, `f562e52`; history was rewritten to drop an accidental `ios/DSHKit/.build/` commit):
    - **Protocol**: `protocol/frame.proto`, buf config, `scripts/codegen` (`--check` for drift), 9 golden fixtures.
    - **Bridge**: `bridge/` with its own WebSocket listener, `src/dsh.ts` mapping a task onto one DSH session through in-process `ctx.workspaceController` / `ctx.sessionController` (no Peer needed), `FakeDSH`, `node:test` suite, README.
    - **App**: `ios/DSHKit` (`HostConnection` actor, `SecureChannel` / `PlaintextChannel`, `@Observable TaskStore`, `FakeBridge`), the one-screen app, and the D16 debug entry points. The project is now iOS-only, iOS 26.0, Swift 6.
    - **Verification**: XCUITests, `scripts/demo/t0.sh`, `scripts/check-release-clean` (it also confirms Debug *does* contain the markers), and screenshots in `evidence/T0/`.
  - **Real DSH**: the bridge runs inside DSH `0.2.2-rc.1` via `node scripts/dsh-up.mjs` (web 127.0.0.1:3281, bridge 127.0.0.1:47801, `DSH_HOME=~/.dshm/home`). The model is DSH's **mock LLM** (`@deepseek-ai/dsh-llm-mock-server`, fixed reply), not a real model. A demo with a real key waits for the user.
  - **Independent review**: a review subagent that took no part in development reran both `[ui]` items. It ran `scripts/demo/t0.sh` (exit 0, 4/4 UI tests) and the FakeBridge UI test alone (DSH session count 7 → 7). It decoded the DSH session log to confirm the app's prompt and reply live in a real DSH session, and confirmed the evidence pointers resolve. Doubts it raised:
    1. `runDemo` checks only that text appeared, not that it arrived in pieces. Incremental streaming is covered by `TaskStoreTests/streamsTaskToCompletionAgainstFakeBridge`.
    2. The FakeBridge "no DSH" claim rests on code plus the unchanged session count, not on a run with DSH stopped, because DSH is shared.
  - **Provisional, pending user confirmation**:
    - **Decisions**: D15 toolchain, D16 testability entry points (commit `03cc202`).
    - **Bridge dependencies** (`bridge/pnpm-lock.yaml`, `28d1bda`):
      - runtime: `@bufbuild/protobuf` 2.16.0, `ws` 8.22.1;
      - dev: `@bufbuild/buf` 1.75.0, `@bufbuild/protoc-gen-es` 2.16.0, `typescript` 7.0.2, `@types/node` 24.19.2, `@types/ws` 8.18.2;
      - pnpm 11.28.5 via corepack.
    - **Swift dependency**: `apple/swift-protobuf` 1.39.0, revision `3d537cb81aef272a03cb3be815439e9bf0eb3bd3` (`ios/DSHKit/Package.resolved`, `b54c8d5`).
    - **Downloads**:
      - npm `@deepseek-ai/dsh@0.2.2-rc.1` (`sha512-ijR9UEVYkG15Q/Q79JzvzLBzQOQfc63VLr9n6flpwHPhr5IKn2UxthnSoto/P9l7qGd7pPvI1Ra6TW7LH3oKpg==`) and `@deepseek-ai/dsh-llm-mock-server@0.2.2-rc.1` (`sha512-hxBNmQEGeibDdmdEtWv3Pmm/11omcnvWbyh6RULkasUQoNVfgppJbrBtres2EaqUjaEULIRuMFhdLZcX13zMhQ==`), installed into `~/.dshm/runtime`.
      - A shallow clone of swift-protobuf 1.39.0 in `~/.dshm/mirrors/swift-protobuf`. It seeds the SwiftPM cache because a full clone ran at about 50 KB/s.
    - **Local setup outside the repo**:
      - `~/.dshm/bin/pnpm`, a shim for `corepack pnpm@11.28.5`; Node 24's default corepack pnpm is broken here.
      - SwiftPM cache entry `~/Library/Caches/org.swift.swiftpm/repositories/swift-protobuf-88c150a7`, seeded from that clone.
    - **DSH location**: `~/.dshm` (`DSH_HOME=~/.dshm/home`). The user said `~/.dsh` may be cleared, but it was left untouched because `~/.dshm` was already set up. Recorded in `bridge/README.md`.
  - Not done: the three `[human]` items, which are the user's to tick. There is no CI yet, so the "(CI)" in the `FakeDSH` item is met by `scripts/demo/t0.sh --fake-only`.
  - Known gaps:
    - If DSH abandons an attempt and retries it, text deltas already forwarded are not retracted.
    - The bridge only logs if its port is taken.
    - A sheet presented from `onOpenURL` didn't show up in XCUITest's accessibility tree, so the pairing stub replaces the screen instead.
  - Next: the user reviews the provisional list, then ticks the `[human]` items (README install, D15, D16).

## 4. Spikes

Each spike ends in a short written conclusion (a working note, archived once acted on), plus throwaway code if needed. None of them blocks T0.

### X1 · Spike: approval answerer

**Status** review · **Needs** — · **Branch** `claude/x1x4-spikes`

**Why**: can a plugin answerer own approvals for **all** agents? How does it order against web/desktop answerers, and does the web UI still see a held request? (ARCHITECTURE §8.1) Unblocks S4.

**Cuts**: minimal throwaway plugin + a release script.

**Demo**: —

**Done when**
- [x] [auto] A minimal plugin parks one approval and a script releases it — Evidence: cmd:spikes/x1-approval/scripts/run · commit:ee2c64c
- [x] [human] Ordering versus web/desktop answerers, and web UI visibility, written down — Evidence: human:2026-11-05 read spikes/x1-approval/README.md

**Not**: production code.

**Log**
- **2026-11-05 · built, to review.** Conclusion in `spikes/x1-approval/README.md`. Commits `ee2c64c` (plugin, release script, runner), `977805e` (README), `e9d2fa6` (ARCHITECTURE).
  - Done: a throwaway plugin parks `approval/request` in-process, and `release.mjs` releases it. `spikes/x1-approval/scripts/run` runs 11 scenarios (36 checks, all pass) against real DSH `0.2.2-rc.1` (`dsh web` on 3282, mock LLM, `DSH_HOME=~/.dshm/home-x1x4`, control port 47803, mock proxy 47804).
  - Learned:
    - A prepended, unscoped plugin answerer owns every root agent's approvals and can hold them indefinitely (DSH has no timeout). Turn cancel aborts `request.signal`. Real `bash` sandbox escalations reach it too.
    - Subagents never ask: DSH pins them to policy `never`, so they are rejected before any answerer runs.
    - Under `dsh web`, the gateway's Remote forwarder is already an answerer. It holds requests **even with no tab open** and delivers them when a tab connects, which corrects ARCHITECTURE §1's "immediately `unavailable`". Append = the plugin never sees requests; prepend = the web sees nothing.
    - Recommended prepend + fan-out (first answer wins, other copy withdrawn) works both ways, verified with an in-process stand-in for a browser tab on the gateway's event stream.
  - Provisional, pending user confirmation: **D17** (approval holder ordering: prepend + fan-out), plus the ARCHITECTURE §1 approvals row, §5.4 and §8.1 notes. No dependencies or downloads (uses T0's `~/.dshm/runtime`).
  - Not done: the `[human]` item is the user's to tick. Not verified: the DSH desktop app, and a real browser tab (J–L use the in-process stand-in).
  - For the coordinator: §0 X1 → `review`. The D17 number may collide with a parallel slice's Dxx; renumber on merge if so.
  - Next: the user reads the README and ticks the `[human]` item; S4 builds the holder on D17. S12 should pin the prepend ordering with a test.

### X2 · Spike: Noise interop

**Status** done · **Needs** — · **Branch** `claude/x2-noise-b1b3cc` (merged `e34a8bc`)

**Why**: do a CryptoKit Swift Noise implementation and a TS `@noble/*` one interoperate? Which pattern (likely `IK` with the host static key from the QR)? (ARCHITECTURE §8.3) Unblocks S1.

**Cuts**: Swift and TS Noise implementations + test vector harness.

**Demo**: —

**Done when**
- [x] [auto] Swift and TS implementations both pass the official Noise test vectors — Evidence: test:NoiseVectorTests/officialVector · cmd:spikes/x2-noise/scripts/interop
- [x] [auto] Swift and TS complete a handshake against each other in a test — Evidence: test:InteropTests/swiftInitiatorTsResponder · test:InteropTests/tsInitiatorSwiftResponder · cmd:spikes/x2-noise/scripts/interop

**Not**: —

**Log**
- 2026-11-05: Done; status `review`. Conclusion in `spikes/x2-noise/README.md`.
  - **Interop:** yes. Swift (CryptoKit only, no SPM deps) and TS (`@noble/curves`, `@noble/ciphers`, `@noble/hashes` 2.4.0, user-approved) both pass 12 official vectors: IK, IKpsk1, IKpsk2, XX × ChaChaPoly/AESGCM × SHA256, from cacophony @18b7348 and snow @d00b360 (download user-approved; sha256-pinned; filtered subset committed). They cross-handshake in both directions over stdio pipes (no socket, no Simulator), with transport messages; wrong secret and wrong host key are rejected. `spikes/x2-noise/scripts/interop` runs it all.
  - **Recommendation:** pairing `Noise_IKpsk1_25519_ChaChaPoly_SHA256` (psk = the QR's one-time secret); reconnect `Noise_IK_25519_ChaChaPoly_SHA256`. Not `IKpsk2`: there a wrong secret passes the host's first read. Not `XX`: the QR already gives the host key.
  - **CryptoKit lacks** BLAKE2 (so SHA256) and any Noise state machine (about 390 lines, ours). HKDF, nonce layout and the tag split are small glue.
  - **For the coordinator:** §0 X2 → `review`. S1 should port the code, not depend on `spikes/`.
  - **Proposed** (user's call): refine ARCHITECTURE D6 with the concrete patterns and the prologue binding. Open question for S1: whether the Secure Enclave P-256 identity key is still needed in M1, since the IK static key already authenticates the device.
  - Next: S1 (after T0).
- 2026-11-05: Provisional dependencies and downloads, pending user confirmation. All are under `spikes/x2-noise/` only.
  - **npm** (`spikes/x2-noise/ts/package.json`, exact pins, installed with `--ignore-scripts`; commit 3f4d72e):
    - `@noble/curves@2.4.0` from npmjs.com; its only dependency is `@noble/hashes`.
    - `@noble/ciphers@2.4.0` from npmjs.com.
    - `@noble/hashes@2.4.0` from npmjs.com.
  - **Downloads** (gitignored raw files, sha256 in `vectors/SHA256SUMS`, filtered subset committed as `vectors/subset.json`; commit 3f4d72e):
    - `cacophony.txt` from github.com/haskell-cryptography/cacophony `vectors/cacophony.txt` @ `18b7348c54fd61fcd0c220298883de0d09c8364d`.
    - `snow.txt` from github.com/mcginty/snow `tests/vectors/snow.txt` @ `d00b360cc61a7fe519ce7539974dca4f36c4654a`.
  - **SPM:** none.
  - **Provisional decision:** ARCHITECTURE D6 now names the concrete Noise patterns and suite, marked "provisional — pending user review" (see the commit that adds this entry).

### X3 · Spike: streaming Markdown

**Status** todo · **Needs** — · **Branch** —

**Why**: which Markdown path survives incremental rendering of long streaming transcripts? (ARCHITECTURE §8.5) Unblocks S8.

**Cuts**: benchmark harness for 2–3 candidates.

**Demo**: —

**Done when**
- [ ] [human] Benchmark of 2–3 candidates on a 5k-line transcript on a real device — Evidence:
- [ ] [human] Choice recorded in ARCHITECTURE D10 — Evidence:

**Not**: production code.

**Log**
- —

### X4 · Spike: mid-task context

**Status** review · **Needs** — · **Branch** `claude/x1x4-spikes`

**Why**: STORY principles 4 and 7. Can the bridge add a follow-up message or attachment to a DSH session that is still running? Is it queued for the next turn or injected immediately? How does an agent's open question to the user surface, as distinct from an approval request? (ARCHITECTURE §8.6) Unblocks the M2 mid-task context slice; doesn't block M1.

**Cuts**: throwaway plugin or script that sends a message into a running session and observes when the agent sees it.

**Demo**: —

**Done when**
- [x] [auto] A script sends a message into a running session of a real DSH and records whether it is queued or injected — Evidence: cmd:spikes/x4-midtask/scripts/run · commit:7a861fb
- [x] [human] Queue-vs-inject behavior, attachment support, and how agent questions surface written down — Evidence: human:2026-11-05 read spikes/x4-midtask/README.md

**Not**: production code · any M1 slice.

**Log**
- **2026-11-05 · built, to review.** Conclusion in `spikes/x4-midtask/README.md`. Commits `7a861fb` (plugin, runner), `977805e` (README), `e9d2fa6` (ARCHITECTURE).
  - Done: `spikes/x4-midtask/scripts/run` runs 6 scenarios (19 checks, all pass) against real DSH `0.2.2-rc.1` (`dsh web` on 3282, mock LLM, `DSH_HOME=~/.dshm/home-x1x4`, control port 47805, mock proxy 47804). It reuses the X1 host lib.
  - Learned:
    - `sessionController.prompt` accepts messages into a running session. `mode: steer` is injected at the next step of the current turn: after the running tool returns, or after the current stream ends, without interrupting either; on an idle session it starts a new turn. `mode: queue` runs as the next turn. Both show in `state().queue` as `steering` / `queued`.
    - Files (staged via `ctx.fileUploads`; the model gets a saved-path note, not the contents) and inline images (the model gets an image block plus a note) work mid-task.
    - Agent questions use `user-questions/request`, not `approval/request`. The web holds them like approvals (`pendingInput: ['question']`), and a prepended plugin answerer can park them. The request carries no `callId`; the answer is `{answers:[{id, selected, custom?}]}`. A steer doesn't release a waiting question. Subagents can't ask.
  - Provisional, pending user confirmation: **D18** (`SendMessage` with steer/queue, default steer; questions held like approvals, as their own messages), plus the ARCHITECTURE §1 mid-task row and §8.6 notes. No dependencies or downloads.
  - Not done: the `[human]` item is the user's to tick. Not verified: real-model reactions, image refusal on a non-vision route, timed questions, queue edits, steering a subagent.
  - For the coordinator: §0 X4 → `review`. The D18 number may collide with a parallel slice's Dxx; renumber on merge if so.
  - Next: the user reads the README and ticks the `[human]` item; the M2 mid-task context slice builds on D18.

## 5. M1 slices

Each slice needs only T0, unless "Needs" says otherwise.

### S1 · Pair + encrypt

**Status** review · **Needs** T0, X2 · **Branch** `claude/s1-pair-encrypt`

**Why**: principle 6 (anyone can pair) and D6 (every transport is untrusted). This slice unlocks the real device.

**Cuts**: bridge shows a QR (terminal first, DSH UI later) with address(es), host static key, one-time secret · app scanner + `NoiseChannel: SecureChannel` · device identity key (Secure Enclave) + Noise static key (Keychain) · bridge device registry (store only, no UI).

**Demo**: a fresh iPhone scans the QR and runs the T0 demo over Wi-Fi or Tailscale. A packet capture shows only ciphertext.

**Done when**
- [x] [auto] `PlaintextChannel` is debug-only and loopback-only — Evidence: test:PlaintextChannelTests/refusesNonLoopbackAddress · test:PlaintextChannelTests/connectionRefusesNonLoopbackBeforeOpeningTransport · test:PlaintextChannelDevOnly/plaintextPathRefusedUnlessConfigured · test:PlaintextChannelDevOnly/devPlaintextRequiresLoopbackListener · cmd:scripts/check-release-clean · cmd:scripts/demo/s1.sh
- [x] [auto] A reused or expired pairing secret is rejected — Evidence: test:PairingBridge/reusedSecretIsRejected · test:PairingBridge/expiredSecretIsRejected · test:PairingTests/reusedSecretIsRejected · test:PairingTests/expiredSecretIsRejectedByHost · test:PairingTests/expiredOfferIsRefusedBeforeConnecting · cmd:scripts/demo/s1.sh
- [x] [ui] Pairing through the `dshm://pair?…` deep link in the Simulator, then the T0 demo over `NoiseChannel` against the local bridge — Evidence: test:S1PairingUITests/testPairViaDeepLinkThenDemoOverNoise · test:S1PairingUITests/testRelaunchReconnectsOverNoise · test:S1PairingUITests/testExpiredPairingLinkIsRefused · cmd:scripts/demo/s1.sh · shot:evidence/S1/s1-paired.png · shot:evidence/S1/s1-demo-over-noise.png · shot:evidence/S1/s1-reused-code-refused.png
- [ ] [human] A fresh iPhone scans the QR and runs the T0 demo over Wi-Fi or Tailscale — Evidence:
- [ ] [human] A packet capture of that session shows only ciphertext — Evidence:
- [x] [auto] The Swift and TS Noise ports pass the official vectors and agree byte for byte on golden pairing and reconnect transcripts and the offer URL — Evidence: test:NoiseVectors/officialVector · test:NoiseVectorsBridge/officialVectors · test:NoiseChannelTests/goldenTranscripts · test:NoiseGoldenTranscripts/transcriptsMatchFixture · test:PairingOfferTests/parsesGoldenOfferURL · cmd:scripts/demo/s1.sh
- [x] [auto] The bridge registers a device only after a completed pairing handshake, and a key it doesn't know can't reconnect — Evidence: test:PairingBridge/deviceRegisteredOnlyAfterFirstTransportMessage · test:PairingBridge/unpairedDeviceCannotReconnect · test:PairingTests/unpairedPhoneCannotReconnect · cmd:scripts/demo/s1.sh
- [x] [ui] Seam with S2 (S1 landed second): after kill/reopen the app reconnects over `NoiseChannel` (IK) and still resumes from its cursor; the gap is filled from the bridge — Evidence: test:S1PairingUITests/testResumeOverNoisePhase2GapFilled · test:S1PairingUITests/testResumeOverNoisePhase1KillWhileConnected · test:NoiseResumeTests/killAndReopenReconnectsOverNoiseAndResumesFromTheCursor · test:ResumeOverNoise/ikReconnectResumesFromTheCursor · cmd:scripts/demo/s1.sh · shot:evidence/S1/s1-resumed-over-noise-list.png · shot:evidence/S1/s1-resumed-over-noise-detail.png

**Not**: QR inside the DSH UI (terminal first) · device registry UI (S10).

**Log**
- **2026-11-05 · built, to review.**
  - Done (commits `6b1f0bf`, `7d74a63`, `4181b8f`, then this one):
    - **Bridge** (`bridge/src/pairing/`): X2's Noise ported (no dependency on `spikes/`); IKpsk1 pairing with the QR's one-time secret, IK reconnect, mode and offer id bound into the prologue (D6, D20). Offers are single use (burnt at the first valid message 1) and expire after 10 minutes. Terminal QR at startup while no device is paired, more with `node bridge/lib/scripts/pair.js`. State in `$DSH_HOME/dsh-mobile-bridge/` (host key, offers, device registry; store only). The listener is Noise on every path; plaintext only with `devPlaintext`, only on `/plaintext`, only on loopback.
    - **App** (`ios/DSHKit` + views): `NoiseChannel: SecureChannel`; `SecureChannel` now runs a handshake and returns a `FrameCipher`, and `HostConnection` seals and sends from one ordered outbox (Noise nonces). `PlaintextChannel` and `HostEndpoint.localBridge` are Debug-only. Device Noise key in the Keychain (`ThisDeviceOnly`), paired hosts in Application Support. Pairing screen, VisionKit QR scanner with a paste-the-link fallback, `-DSHMResetPairing` launch argument, `host.channel` / `pairing.*` accessibility identifiers. T0's pairing stub is replaced; its UI test now checks the real screen refuses T0's offer-less link.
    - **Cross-language truth**: `protocol/fixtures/noise/official-vectors.json` (X2's subset) and `transcripts.json` (fixed-key pair/reconnect transcripts + an offer URL), checked by both sides.
    - **Verification**: `scripts/demo/s1.sh` (exit 0): bridge and DSHKit tests, `scripts/check-release-clean`, CLI pair → task → IK reconnect → task against real DSH 0.2.2-rc.1 (mock LLM), reused code refused (`closed 4001 pairing secret used`), T0 plaintext path, then XCUITests in `dshm-S1`: S1 (pair via deep link, T0 demo over Noise, reused code refused, relaunch reconnects over Noise, expired code refused) and all T0 UI tests. `scripts/demo/t0.sh --fake-only` also passes.
  - **Decisions** (provisional, pending user confirmation): **D20** pairing offer, wire header, close codes, bridge state, listener defaults. **D21** the X2 open question: no Secure Enclave P-256 key in M1 (the IK static key already authenticates the device; SE returns with Face ID approvals in M2). D17–D19 were skipped because X1, X4 and S3 already use them on their branches; renumber on merge if needed.
  - **Provisional dependencies** (bridge runtime, `bridge/pnpm-lock.yaml`, commit `6b1f0bf`): `@noble/curves` 2.4.0, `@noble/ciphers` 2.4.0, `@noble/hashes` 2.4.0 (same versions X2 approved), `uqr` 0.1.3 (terminal QR, no dependencies). No new Swift packages (CryptoKit, VisionKit). No downloads.
  - **Changed shared behavior**: the bridge's default listen address is now `0.0.0.0` with Noise only; `scripts/dsh-up.mjs` keeps the dev host on `127.0.0.1` with `devPlaintext` on, so T0's demo is unchanged. `scripts/check-release-clean` markers: dropped the stub's, added `PlaintextChannel`, `/plaintext`, `FakeNoiseHost`, `DSHMResetPairing`.
  - Not done: the two `[human]` items (real iPhone over Wi-Fi/Tailscale: run `DSHM_BRIDGE_HOST=0.0.0.0 DSHM_BRIDGE_DEV_PLAINTEXT=0 node scripts/dsh-up.mjs` or the plugin in a real profile, then `pair.js` and scan; packet capture of that session). Camera scanning is untested (Simulator has no camera). Known limits: one address on reconnect; Noise's 65535-byte message cap (M3 artifacts need chunking); the hand-rolled Noise is unaudited.
  - For the coordinator: §0 S1 → `review` after an independent rerun of the `[ui]` item (`scripts/demo/s1.sh`); add D20, D21 and the four npm deps to §9; the two `[human]` items go to §9 (real iPhone + Wi-Fi/Tailscale; Wireshark/tcpdump on the Mac).
  - Next: independent `[ui]` rerun, merge, then the user's `[human]` acceptance on a real iPhone.
- **2026-11-05 · batch 1 integration** (branch `claude/batch1-integration`, merged last, after S3 and S2).
  - Renumbering: the entries this Log calls **D20** and **D21** are now **D21** (pairing and the encrypted wire) and **D22** (no Secure Enclave key in M1) in ARCHITECTURE.md (main keeps D17/D18, S3 took D19, S2 took D20). Still *provisional, pending user confirmation*.
  - S2 replaced T0's `ContentView`: S1's host channel row (`host.channel`) and pairing button (`pairing.scan`) now live on S2's task list; `AppModel` builds S2's `TaskListStore` for the paired host (or the Debug dev paths) and swaps it on pairing. `HostConnection` keeps both S1's outbox/cipher and S2's reconnect generations. `FakeNoiseHost` now fronts S2's `FakeHost`. `scripts/demo/s2-host.mjs` and `s3-host.mjs` enable the bridge's dev plaintext path on loopback. See **D24** (*provisional, pending user confirmation*).
  - Seam with S2 (S1 landed second, so S1 owns it): added and ticked "resume over Noise". `scripts/demo/s1.sh` now kills the paired app, runs a task on the bridge from the CLI, and reopens: a fresh IK handshake, then `Resume` from the cursor brings the missed task with its transcript. s1.sh now runs only S1 and T0 UI tests (it used to run the whole scheme, which now includes S2/S3 real-DSH tests that need their own hosts) and fails on any skipped test.
  - Full `scripts/demo/s1.sh --shots` run on the integration branch: exit 0, refreshed `evidence/S1/`.

### S2 · Durable list + resume

**Status** review · **Needs** T0 · **Branch** `claude/s2-durable-list`

**Why**: principle 4 (unified list; nothing lost across disconnects), D9.

**Cuts**: bridge per-host monotonic `seq` + event log · `Resume { after_seq }` · `ListTasks` · app SwiftData models, unified task list (running / waiting on me / done), reconnect with backoff, refresh on foreground · offline host named explicitly (principle 3).
- Seams it owns if it lands second: replay of pending approvals (S4), cached milestones (S3).

**Demo**: start a task, kill the app, wait, reopen. The list and transcript are intact, and the gap is filled from the bridge.

**Done when**
- [x] [auto] Bridge `Resume { after_seq }` returns exactly the events after `after_seq` — Evidence: test:ResumeAgainstFakeDSH/resumeReturnsExactlyTheEventsAfterSeq · test:HostLog/sinceReturnsExactlyTheEventsAfterSeq · test:ResumeAgainstFakeDSH/taskOutlivesTheConnectionThatCreatedIt · commit:73ca56c
- [x] [ui] Start a task, kill the app, wait, reopen: the list and transcript are intact and the gap is filled from the bridge — Evidence: test:S2DurableListUITests/testKillAndReopenAgainstRealDSH · test:TaskListStoreTests/killAndReopenKeepsTheListAndFillsTheGapFromTheBridge · cmd:scripts/demo/s2.sh · shot:evidence/S2/s2-reopened-from-cache.png · shot:evidence/S2/s2-gap-filled.png · shot:evidence/S2/s2-list-after-resume.png
- [x] [ui] With the host unreachable, the list names that host as offline — Evidence: test:S2DurableListUITests/testOfflineHostIsNamedWithFakeBridge · test:S2DurableListUITests/testOfflineRealHostIsNamed · test:TaskListStoreTests/unreachableHostIsNamedAsOffline · cmd:scripts/demo/s2.sh · shot:evidence/S2/s2-offline-fakebridge.png · shot:evidence/S2/s2-offline-real-host.png
- [x] [ui] Seam with S3 (S2 landed second): list rows show the `MilestoneCard`, and after kill/reopen a task's milestones are still shown from the cache — Evidence: test:S2DurableListUITests/testCachedMilestonesAfterKillAndReopenWithFakeBridge · test:CachedMilestoneTests/milestonesSurviveKillAndReopenAndTheGapIsReplayed · test:ResumeReplaysMilestones/resumeAfterSeqReplaysTheMissedMilestonesOnce · cmd:scripts/demo/s2.sh · shot:evidence/S2/s2-cached-milestones-list.png · shot:evidence/S2/s2-cached-milestones-timeline.png

**Not**: background refresh (M1 refreshes on foreground; push is M2).

**Log**
- **2026-11-05 · built, to review.**
  - Done (commits `3ebac5b` protocol, `73ca56c` bridge, `7063405` DSHKit, `babd28c` app, `2b14fd0` UI tests + demo + D17):
    - **Protocol**: `protocol/s2.proto` (`ListTasks`/`TaskList`, `Resume`/`Resumed`, `TaskUpserted`, `LogReset`, `TaskState`), registered in `frame.proto` at 40–59, plus `Event.host_seq` (40). Capability `resume.v1`. 7 new golden fixtures (`s2_*`).
    - **Bridge**: `bridge/src/s2/` (`HostLog`, `TaskHub`). Tasks belong to the host, not the connection; closing the socket no longer aborts a task. `Resume` replays exactly the gap and subscribes in one synchronous step. T0-style clients (no `Resume`) still get only their own tasks' events. `TaskUpserted(state)` now comes just before `TaskEnded`, so `TaskEnded` stays last.
    - **App**: SwiftData cache (`CachedHost` with the cursor, `CachedTask` with transcript + chunk cursor), `TaskListStore` (sync loop per host, Resume, reconnect with backoff 0.5 s → 30 s, foreground refresh, offline host named), unified list (waiting on me / running / done) + task detail + composer in `ios/dsh-mobile/Features/TaskList/`. T0's `ContentView` is gone; its identifiers live on in the new screens, so T0's UI tests pass unchanged. T0's `TaskStore` stays in DSHKit (its tests are T0 evidence) but the app no longer uses it.
    - **Testability**: `FakeHost` in `DSHTestSupport` (a fake bridge process whose log outlives connections; can go unreachable, drop connections, restart); launch arguments `-DSHMFakeBridge offline`, `-DSHMResetStore YES`, `-DSHMConnectDelay <s>`, added to `scripts/check-release-clean`'s markers.
    - **Demo**: `scripts/demo/s2.sh` (env `DSHM_BRIDGE_PORT`=47811, `DSHM_WEB_PORT`=3284, `DSHM_HOME`=~/.dshm/home-s2, `DSHM_SIM`=dshm-S2) starts `scripts/demo/s2-host.mjs` (real DSH 0.2.2-rc.1, mock LLM slowed to 250 ms per chunk, so a task streams ~6 s), runs the kill/reopen XCUITest, then stops the host and checks the app names it offline. Full run exit 0 on 2026-11-05.
  - Decisions: see D17 (*provisional, pending user confirmation*). No new dependencies or downloads; uses the shared `~/.dshm/runtime` read-only. Local setup: `~/.dshm/home-s2` (DSH home with the bridge linked from this worktree, port 47811 via its `cordis.patch.yml`); Simulator `dshm-S2` (already existed).
  - Not done: no independent `[ui]` rerun yet (the coordinating session's reviewer should run `scripts/demo/s2.sh`). The `[ui]` items were verified by me, in the Simulator, with the commands above.
  - Seams: S3 (cached milestones) is being built in parallel; **whichever of S2/S3 lands second owns the seam** (cache `MilestoneAdded` in `CachedTask` and replay it through `Resume`). S4 (replay of pending approvals) is the same: S4 lands after S2, so S4 owns it. Expect merge conflicts in `frame.proto` (both add oneof entries, different numbers), `protocol/fixtures/fixtures.json` (end of the array), the generated code (rerun `scripts/codegen`), and the app root / `AppComposition.swift`.
  - Learned / known gaps:
    - The bridge log is in memory: restarting DSH starts a new log; the app then marks its still-running cached tasks of the old log as failed ("the bridge restarted"). Persisting the log is an alternative in D17.
    - `XCUIApplication.terminate()` kills the app without a background phase, so the kill test relies on the ~150 ms coalesced save; the `[ui]` test passes with that.
    - T0's `TaskStoreTests/streamsTaskToCompletionAgainstFakeBridge` samples the transcript every 10 ms and once missed an intermediate value while the S2 store tests loaded the main actor in parallel. `TaskListStoreTests` is now `.serialized`; 7 runs in a row were green.
    - The composer lives on the list screen only; the detail screen shows state and transcript.
    - The D17 number may collide with S1/S3 entries written in parallel; renumber on merge if needed.
  - Next: independent `[ui]` rerun via `scripts/demo/s2.sh`, then merge. The coordinating session updates §0 (S2 → review) and lists D17 in §9.
- **2026-11-05 · batch 1 integration** (branch `claude/batch1-integration`, merged after S3, before S1).
  - Renumbering: the entries this Log calls **D17** are now **D20** in ARCHITECTURE.md (main keeps D17/D18 from X1/X4, S3 took D19). Still *provisional, pending user confirmation*.
  - Seam with S3 (S2 landed second, so S2 owns it): added and ticked the "cached milestones" item. The bridge logs `MilestoneAdded` in the host log, so `Resume` replays it; the app caches each task's whole milestone timeline in `CachedTask.milestonesData`; list rows and the task detail show `MilestoneCard` from the cache. See **D23** (*provisional, pending user confirmation*).
  - Fixed on the way: `FakeHost` task ids are now unique per instance; before, a task cached by an earlier launch (`fake-task-1`) collided with the next launch's first task, which S3's UI tests (no `-DSHMResetStore`) exposed.
  - `scripts/demo/s2.sh` also runs the seam UI test.

### S3 · Milestones

**Status** review · **Needs** T0 · **Branch** `claude/s3-milestones`

**Why**: principle 4 (milestone summary by default, details on demand), D11.

**Cuts**: bridge mapper DSH `todos` / `plan` / `state` / errors → `MilestoneAdded` · app task card showing the current milestone, detail view showing the milestone timeline.

**Demo**: a multi-step prompt shows its todos ticking off on the card without opening the transcript.

**Done when**
- [x] [auto] Mapper turns `FakeDSH` `todos` / `plan` / `state` / error projections into the expected `MilestoneAdded` events — Evidence: test:MilestoneMapperAgainstFakeDSH/mapsTodosPlanStateAndErrorsIntoMilestoneAdded · test:MilestoneMapperAgainstFakeDSH/failedTurnBecomesFailedMilestone · test:MilestoneMapper/ignoresMalformedPayloadsLaterTurnsAndEventsAfterTheEnd · test:MilestoneStoreTests/todosTickOffOnTheTimelineAgainstFakeBridge · cmd:scripts/demo/s3.sh
- [x] [ui] A multi-step prompt shows its todos ticking off on the card without opening the transcript — Evidence: test:S3MilestonesUITests/testTodosTickOffOnCardWithFakeBridge · test:S3MilestonesUITests/testMilestonesAgainstRealDSH · cmd:scripts/demo/s3.sh · shot:evidence/S3/s3-real-dsh-card-ticking.png · shot:evidence/S3/s3-fakebridge-card-ticking.png
- [x] [ui] The detail view shows the milestone timeline — Evidence: test:S3MilestonesUITests/testTimelineWithFakeBridge · test:S3MilestonesUITests/testMilestonesAgainstRealDSH · cmd:scripts/demo/s3.sh · shot:evidence/S3/s3-real-dsh-timeline.png · shot:evidence/S3/s3-fakebridge-timeline.png

**Not**: summarizing with a model (never; D11).

**Log**
- **2026-11-05 · built, to review** (workflow `wf_219b7aa1-71c`, unattended; commits `8a78489`, `ecf6123`, `debb402` and this one).
  - Done:
    - **Protocol**: `protocol/milestones.proto` (`MilestoneAdded { task_id, seq, kind, text, todos[], time_ms }`, Event field 60, capability `milestones.v1`) and two golden fixtures (`s3_milestone_*`).
    - **Bridge**: `bridge/src/milestones/` maps DSH `turn/start`, `todo/write`, `plan/mode`, `llm/retry` and `turn/end` into milestones; `server.ts` emits them before `TaskEnded`. `FakeDSH` gained scripted session events. The CLI client prints milestones. Choices in **D17**: "state" is read as the turn lifecycle (DSH has no `state` projection; the keys are `todos`, `plan`, `llmRetry`, `goal`, `title`, …), and "errors" as a failed turn plus `llm/retry`.
    - **App**: `MilestoneTimeline` on `TaskStore` (DSHKit); `Features/Milestones/`: a task card above the transcript (headline = the todo in progress, `n of m`, checklist), tapping it opens the timeline. No card when the bridge sends no milestones, so T0's screen is unchanged for a bridge without `milestones.v1`. `FakeBridge` scripts a three-todo task with `-DSHMFakeMilestones YES` (added to `scripts/check-release-clean`'s markers).
    - **Real DSH**: `scripts/demo/s3-host.mjs` runs DSH 0.2.2-rc.1 + the bridge (`~/.dshm/home-s3`, web 3285, bridge 47812) with DSH's mock LLM scripted to call `todo_write` four times, then answer. The card ticks 0/3 → 3/3 in the Simulator `dshm-S3` against it; no API key.
    - **Verification**: `scripts/demo/s3.sh` (exit 0): codegen check, 12 bridge tests, 16 DSHKit tests, the real-DSH CLI milestone sequence, and 4 S3 UI tests on `dshm-S3` (real-DSH one not skipped). T0's UI tests still pass on `dshm-S3` (FakeBridge; the real-DSH one skipped, since T0's host is T0's). `scripts/check-release-clean` passes; it now takes `DSHM_RELEASE_DD`, because the shared default DerivedData collided with a parallel slice's build ("database is locked").
    - The UI test samples the transcript before the card, so "transcript still empty while the card shows < 3/3" is causal, not timing-dependent (the first version flaked under load).
  - Not done: the independent review rerun of the two `[ui]` items (the coordinator's review agent). Rerun: `DSHM_SIM=dshm-S3 DSHM_BRIDGE_PORT=47812 DSHM_WEB_PORT=3285 DSHM_HOME=~/.dshm/home-s3 scripts/demo/s3.sh` (starts and stops its own host when 47812 is free).
  - **Provisional, pending user confirmation**: **D17** (milestone mapping, wire shape, card + timeline UI, `-DSHMFakeMilestones` and identifiers, the mock-LLM proxy in `s3-host.mjs`). No new dependencies or downloads; `s3-host.mjs` uses the already-installed `@deepseek-ai/dsh-llm-mock-server@0.2.2-rc.1` from `~/.dshm/runtime`.
  - Seams for others: S2 (lands second) owns cached milestones; every `MilestoneAdded` carries the whole todo list, so the latest one is enough to restore a card. S2's list should reuse `MilestoneCard`. `ContentView.swift` gets a ~14-line insert that may conflict with S2's list rewrite.
  - For §0 (coordinator): S3 → `review`, branch `claude/s3-milestones`.
  - Next: independent `[ui]` rerun, merge; the user reviews D17.
- **2026-11-05 · batch 1 integration** (branch `claude/batch1-integration`, merged first).
  - Renumbering: the entries this Log calls **D17** are now **D19** in ARCHITECTURE.md (main keeps D17/D18 from X1/X4). Still *provisional, pending user confirmation*.
  - S2 replaced T0's `ContentView`: the milestone card now sits in S2's task detail (above the transcript, same identifiers) and in the list rows; S2 owns that seam (D23). `MilestoneTimelineView` takes a `MilestoneTimeline` instead of the T0 `TaskStore`. `FakeBridge`'s milestone script runs inside S2's `FakeHost`.

### S4 · Approvals (in-app, held)

**Status** todo · **Needs** T0, X1 · **Branch** —

**Why**: principle 5. Approvals pause and never default-allow. ARCHITECTURE §5.4.

**Cuts**: bridge answerer on `approval/request` that parks requests, joins by `callId` with the streamed tool call for a basic impact view (tool, command / files / args), times out → cancel + `ApprovalResolved(timeout)`, writes an audit record · `ApprovalPending`, `AnswerApproval`, `ApprovalResolved` · app approval card in the list and in the detail view.

**Demo**: prompt "delete `/tmp/x`". The phone shows the exact command, you deny it, and the task continues without running it. Repeat with the app closed: the request waits, and when you reopen the app it's there.

**Done when**
- [ ] [auto] A held request that times out is cancelled with `ApprovalResolved(timeout)`, never allowed — Evidence:
- [ ] [auto] Every answer writes an audit record (who, when, which device, what) — Evidence:
- [ ] [ui] Prompt "delete `/tmp/x`": the card shows the exact command, you deny it, and the task continues without running it — Evidence:
- [ ] [ui] With the app closed, the request waits; reopening the app shows it — Evidence:

**Not**: risk tiers, Face ID, push (M2).

**Log**
- —

### S5 · Interrupt

**Status** doing · **Needs** T0 · **Branch** `claude/s5-interrupt`

**Why**: "随时打断" (interrupt at any time) in STORY.

**Cuts**: `Interrupt { task_id }` → DSH interrupt · app stop button in the detail view; task status `interrupted`.

**Demo**: interrupt a long-running task; it stops within a few seconds and the card says so.

**Done when**
- [x] [auto] Bridge maps `Interrupt { task_id }` to a DSH interrupt and reports status `interrupted` (`FakeDSH`) — Evidence: test:interruptCallsDSHAndReportsInterrupted
- [x] [ui] Interrupt a long-running task: it stops within a few seconds and the card says so — Evidence: test:S5InterruptUITests/testInterruptLongRunningTask · cmd:scripts/demo/s5.sh · shot:evidence/S5/s5-interrupted-detail.png
- [x] [ui] Reopen after an interrupt: the cached task and its milestone still say interrupted (S2 × S3 × S5) — Evidence: test:S5InterruptUITests/testInterruptLongRunningTask · cmd:scripts/demo/s5.sh · shot:evidence/S5/s5-interrupted-detail.png

**Not**: continuing an interrupted task with a new prompt in the same session (later, together with adding context mid-task).

**Log**
- —
- **2026-11-05 · Started.** Read the workflow, slice requirements, architecture, product story, and recent git history. Resources: bridge 47811, web 3284, `DSHM_HOME=/Users/bytedance/.dshm/home-s5`, simulator `dshm-S5`, DerivedData `/tmp/dshm-s5-dd`. T0 invoked from an untracked `/tmp/dshm-s5-t0.sh` copy with isolated `/tmp/dshm-s5-t0` logs; tracked T0 script unchanged. Coordinator owns the corresponding §0 update.
- **2026-11-05 · Environment blocked before implementation.** T0 did not reach tests: dependency installation stalled; an offline recovery attempt failed with `ERR_PNPM_NO_OFFLINE_TARBALL` (including `@noble/hashes@2.4.0`). `xcrun simctl list devices booted` failed with CoreSimulator connection refusal and an explicit sandbox denial opening its log. The assigned DSH home does not exist and is outside this session's writable roots. WORKFLOW §2 and §4 require a passing local T0 before slice work. No acceptance items are ticked; no dependencies or provisional design decisions were added. Next: coordinator supplies a session with access to the assigned simulator, DSH home, dependency cache/network, and worktree git metadata; rerun the isolated T0 command, then implement and verify S5. Existing machine-wide ByteSec hooksPath is unchanged.

- **2026-11-05 · Baseline restored.** The replacement owner ran T0 in the assigned worktree and profile. All 41 bridge tests, 46 Swift tests and 4 UI tests passed, including the real DSH round trip. Implementation resumed.
- **2026-11-05 · Implementation and owner verification.** `c5b1739` adds `interrupt.v1`, the host stop command and interrupted state/milestone through the S2 cache. See provisional D28. No new dependency or download. `scripts/demo/s5.sh --shots` passed 42 bridge tests, 46 DSHKit tests and the real DSH Simulator test, with zero skips. The UI test stopped a streaming task, checked its partial reply and list row, then relaunched without a connection and read its interrupted state and milestone. Independent UI rerun and merge are with the coordinator.

### S6 · Models

**Status** doing · **Needs** T0 · **Branch** claude/s6-models

**Why**: principle 8. The host provides the list, names are shown as given, there's no silent substitution, and you can switch mid-task.

**Cuts**: `ModelCatalog` / `SelectModel` passthrough of `session/modelCatalog` / `session/selectModel` · composer model + effort picker defaulting to the host's default · mid-task switch in the detail view · explicit error when the chosen model is unavailable.

**Demo**: start on low effort, raise it mid-task, and see the switch recorded in the transcript.

**Done when**
- [x] [auto] Catalog names and the default pass through unchanged from `session/modelCatalog` — Evidence: test:hostCatalogPreservesGroupsNamesEffortsAndDefault
- [x] [auto] Choosing an unavailable model returns an explicit error; no other model is substituted — Evidence: test:unavailableModelDoesNotPromptOrSubstitute · test:modelSwitchReplaysInOrderAndRejectedSelectionDoesNotChangeTask
- [x] [ui] Start on low effort, raise it mid-task, and see the switch recorded in the transcript — Evidence: test:S6ModelsUITests/testRaiseEffortDuringRealTask · cmd:scripts/demo/s6.sh · shot:evidence/S6/s6-effort-switch.png
- [x] [auto] Resume replays model selections with their original host sequence numbers — Evidence: test:modelSwitchReplaysInOrderAndRejectedSelectionDoesNotChangeTask

**Not**: renaming or regrouping models (principle 8).

**Log**
- —
- **2026-11-05**: Started S6 (`doing`), read the required project documents and git history, and attempted the prerequisite T0 rerun with bridge 47812, web 3285, `DSHM_HOME=/Users/bytedance/.dshm/home-s6`, Simulator `dshm-S6`, and DerivedData `/tmp/dshm-s6-dd`. Used an untracked `/tmp/dshm-s6-t0.sh` copy with only the root and temporary log paths changed (`/tmp/dshm-s6-t0-20261105*`). No tracked T0 script change. T0 stopped before tests: dependency installation stalled; offline installation reported `ERR_PNPM_NO_OFFLINE_TARBALL`, and attempting the existing shared pnpm store with copy imports reported `ERR_SQLITE_ERROR: unable to open database file`. Direct `xcrun simctl list devices available` reported CoreSimulator connection failure and `Operation not permitted` opening its log. The assigned DSH home is absent and outside this session's writable roots. The fixed sandbox cannot request escalation. Status is `blocked`; no implementation or acceptance checkbox changes, no new dependencies or provisional decisions. Next: coordinator supplies a session that can use the assigned Simulator, DSH home, dependency cache, and worktree git metadata; rerun T0 before implementing S6. Independent UI review remains with the coordinator.
- **2026-11-05**: Coordinator supplied a new owner with access to the isolated resources. The full T0 rerun passed (41 bridge, 46 DSHKit, four UI tests and real DSH). Implementation resumed.
- **2026-11-05**: Implemented S6 and the S2 replay seam (see D31). Verified the pinned DSH 0.2.2-rc.1 model catalog and effort switch against the real host with its mock LLM. The demo passed 44 bridge tests, 46 DSHKit tests and the Simulator UI test, with no skips. A first UI run lost its host when a concurrent bridge rebuild triggered DSH's reload; rerunning after a clean host start passed. No new dependencies or downloads. Next: independent UI review and merge.

### S7 · Workspaces

**Status** todo · **Needs** T0 · **Branch** —

**Why**: D12 (DSH sessions need a cwd).

**Cuts**: `ListWorkspaces` (per-host default + recents) · `CreateTask.workspace` · composer picker.

**Demo**: run the same prompt in two different repos and get correct, different answers.

**Done when**
- [ ] [auto] `CreateTask.workspace` becomes the DSH session cwd (`FakeDSH`) — Evidence:
- [ ] [ui] The same prompt run in two different repos gives correct, different answers — Evidence:

**Not**: inferring the workspace from the prompt.

**Log**
- —

### S8 · Rich detail

**Status** todo · **Needs** T0, X3 · **Branch** —

**Why**: D1 (native streaming detail), D13 (quick answers inline).

**Cuts**: native rendering of Markdown, code, diffs, and terminal output in the transcript, incremental while streaming · short tasks rendered inline as an answer, not as a task page.

**Demo**: a coding task's diff and test output read well on a phone. "Translate this sentence" just shows the answer.

**Done when**
- [ ] [ui] "Translate this sentence" just shows the answer inline, not a task page — Evidence:
- [ ] [human] A coding task's diff and test output read well on a phone — Evidence:

**Not**: WebView (D1).

**Log**
- —

### S9 · Multi-host

**Status** todo · **Needs** S1 · **Branch** —

**Why**: principles 1–3 (one phone, many hosts, all hosts treated the same, smart default).

**Cuts**: pair a second host · host attribute on tasks · composer host picker (default: last used; prompt-based guess later) · per-host `HostConnection` · "all hosts offline" names each machine.
- Seam: if S2 has landed, the unified list spans hosts.

**Demo**: two Macs, tasks from both in one list; take one offline and it's named.

**Done when**
- [ ] [ui] With two hosts (`FakeBridge` ×2), tasks from both appear in one list; one taken offline is named — Evidence:
- [ ] [human] Two real Macs, tasks from both in one list; take one offline and it's named — Evidence:

**Not**: prompt-based host guess (later).

**Log**
- —

### S10 · Control: devices + audit

**Status** todo · **Needs** S1 · **Branch** —

**Why**: principle 9.

**Cuts**: `ListDevices` / `RevokeDevice` · app host + device management screen · audit view (who, when, which device, what) for approvals and pairing.
- Seam: the audit view covers approvals if S4 has landed.

**Demo**: revoke the phone from a second device; its next connection is refused.

**Done when**
- [ ] [auto] Bridge refuses a connection from a revoked device — Evidence:
- [ ] [ui] Revoke a device from the management screen; its next connection is refused — Evidence:
- [ ] [ui] Audit view shows who, when, which device, and what for pairing events — Evidence:

**Not**: —

**Log**
- —

### S11 · First run

**Status** todo · **Needs** S1 · **Branch** —

**Why**: principle 6 (with no host paired, the app explains what it is and what's missing).

**Cuts**: empty state → pairing guide → first task suggestion.

**Demo**: someone who has never seen DSH gets from install to their first answer without help, given a DSH that's already running.

**Done when**
- [ ] [human] With no host paired, the app explains what it is and what's missing — Evidence:
- [ ] [human] Someone who has never seen DSH gets from install to their first answer without help, given a DSH that's already running — Evidence:

**Not**: installing DSH for the user (STORY non-goal).

**Log**
- —

### S12 · Upstream guard

**Status** todo · **Needs** T0 · **Branch** —

**Why**: ARCHITECTURE §8.4 (upstream churn).

**Cuts**: supported DSH version range pinned in the bridge and reported in `Hello` · CI: bridge tests against the pinned DSH and a non-blocking job against DSH `main`.

**Demo**: point the bridge at an unsupported DSH; the app shows "host needs bridge update" instead of breaking.

**Done when**
- [ ] [auto] Bridge reports the supported DSH range and an unsupported DSH in `Hello` — Evidence:
- [ ] [auto] CI runs bridge tests against the pinned DSH, plus a non-blocking job against DSH `main` — Evidence:
- [ ] [ui] Against an unsupported DSH, the app shows "host needs bridge update" instead of breaking — Evidence:

**Not**: blocking CI on DSH `main`.

**Log**
- —

## 6. M1 exit

From a real iPhone over Tailscale, against a home Mac. All items are human-only.

- [ ] [human] Pair by scanning a QR (S1) — Evidence:
- [ ] [human] "Fix the failing CI test in `<repo>`, open a PR", with workspace and model picked (S6, S7) — Evidence:
- [ ] [human] Watch milestones tick (S3); open the detail view and read the diff (S8) — Evidence:
- [ ] [human] Approve the `git push` from an approval card showing the exact command (S4) — Evidence:
- [ ] [human] Raise reasoning effort mid-task (S6). Kill the app, reopen, and find nothing lost (S2) — Evidence:
- [ ] [human] Get the PR link in the result — Evidence:

When all of these are ticked, archive this file and plan M2 the same way.

## 7. After M1 (coarse, re-slice when we get there)

| Milestone | Candidate slices | Gate |
|---|---|---|
| M2 | Push via `PushSender` → APNs · risk tiers + Face ID for the top tier · plan alignment + pre-authorization · pause timeout + re-confirm on resume · mid-task context: follow-up messages + answering agent questions (attachments with M3; continues S5's interrupted tasks) | Paid Apple account; X4 result |
| M3 | Quick Look + share-out · Share Extension + attachment upload · photos as context | Verify App Groups on the signing team first |
| M4 | Live Activities / Dynamic Island · voice entry · relay `Transport` | Relay design note |

## 8. Plan log

Append-only, dated. Changes to this file's format and to the checks that guard it.

- **2026-11-04 · format + checks.**
  - Done:
    - Baseline commit `71b367a`; format change in `08f64b9`.
    - Added `scripts/check-plan`, `.githooks/pre-commit` (`git config core.hooksPath .githooks`, repo-local), `.claude/settings.json` with `.claude/hooks/plan-guard` (Edit|Write|MultiEdit) and `.claude/hooks/git-guard` (Bash).
  - Verification. Samples were derived from `PLAN.md` with `sed` and checked three ways: `scripts/check-plan --new <sample> --agent`, staged + `git commit` (pre-commit), and live Edit calls in a Claude Code desktop session in bypass-permissions mode.
    1. Reword the T0 fixtures item → rejected: check-plan exit 1, commit refused. Live Edit with `ask`: the confirmation dialog appeared.
    2. Tick a `[human]` M1 exit item → rejected: check-plan `--agent` exit 1, live Edit denied. Pre-commit allows it on purpose, because the user ticks human items by hand.
    3. Tick the T0 fixtures item with empty evidence → rejected: check-plan exit 1, commit refused, live Edit blocked (tested under `deny`; under `ask` it goes to the same dialog as sample 1).
    4. Tick it with evidence → passes: check-plan exit 0, commit succeeded (then undone), live Edit applied (then restored).
    - Also: deleting an item → rejected.
    - git-guard denies `--no-verify`, `git commit -n`, `core.hooksPath` overrides or unset, and `CHECK_PLAN_ALLOW`. It allows `git commit -am`, `git push -n`, and `git config core.hooksPath .githooks`.
  - Finding: in bypass-permissions mode a PreToolUse `ask` **still shows the confirmation dialog**. Tested twice; both times the user saw the dialog and clicked allow, so the edit went through. plan-guard therefore keeps `ask` for non-human violations; ticking a `[human]` item is always `deny`. Hooks in `.claude/settings.json` took effect mid-session, with no restart.
  - Known gaps:
    - An agent editing PLAN.md through Bash (`sed`, `python`) skips plan-guard. Pre-commit still catches rewrites and empty evidence, but not a `[human]` tick, because it can't tell who made it.
    - The `CHECK_PLAN_ALLOW=1 git commit` escape hatch is for the user only. It's blocked for agents by git-guard, not by git.
  - Next: —
- **2026-11-04 · user review.**
  - The evidence marker is `Evidence:` only; check-plan no longer accepts the Chinese marker.
  - The user confirmed the derived Done when items for S4–S12, the tier choices, and the §1 Done definition.
  - Still open: the S5 **Not** TODO.
- **2026-11-04 · four guard gaps + evidence pointers** (gaps found by a re-test in another session; fixes approved by the user).
  - Done:
    1. **Guard files are guarded.** plan-guard returns `ask` for Edit/Write/MultiEdit on `scripts/check-plan`, `.githooks/*`, `.claude/hooks/*`, `.claude/settings.json`. `check-plan --staged`, and so pre-commit, fails when any of them is staged unless the user commits with `CHECK_PLAN_ALLOW=1`.
    2. **Evidence is typed pointers** (`test:` / `cmd:` / `commit:` / `shot:` / `human:`, joined by ` · `), each resolved by check-plan. The rules are in "How to use this file", including screenshots and recordings. `test:` reports clearly that there are no Swift/TS test sources yet.
    3. **No pre-ticked new items in `--agent` mode** (plan-guard): agents add unticked and tick in a later edit. Pre-commit still allows the user to add and tick at once.
    4. **git-guard parses commands** instead of regex-matching `core.hooksPath`. It denies setting the value to anything but `.githooks`, `--unset`/`--unset-all`/`unset`, removing or renaming the `core` section, `git -c`/`--config-env` overrides, and `GIT_CONFIG_*` mentioning hooksPath, including inside `sh -c "…"`. It allows `git config core.hooksPath`, `--get`, `--get-regexp`, `--list`, and `git config core.hooksPath; git status`.
  - Verification. Harness: `/tmp/dshm-guard-tests/plan-run.py` and `gg-run.py` (outside the repo, because git-guard blocks any shell command containing the guarded strings). Result: 0 failures.
    - check-plan `--agent` and plan-guard: the original samples 1–4 are unchanged (reword → ask, `[human]` tick → deny, empty evidence → ask, valid tick with `commit:08f64b9 · cmd:scripts/check-plan` → allow; delete → ask).
    - New samples, all blocked: `Evidence: done`, `test:NoSuchTest`, adding a ticked item (even with valid evidence), adding a ticked item with `trust me`, unknown pointer `url:`, `human:` on an `[auto]` item.
    - plan-guard on each of the four guard paths → ask; AGENTS.md and files outside the repo → allow.
    - Pre-commit (staged vs HEAD, sample commits undone): rewrite, empty, `done`, missing test, bad pointers, and staged `scripts/check-plan` → refused; valid tick, user `[human]` tick, and an added ticked item with valid evidence → accepted.
    - git-guard: 25 cases, including the read-only `hooksPath` queries.
    - Live, in bypass-permissions mode: an Edit of `scripts/check-plan` (`return 1` → `return 0`) showed the confirmation dialog. The user clicked allow, and the change was reverted immediately.
  - Known gaps:
    - Writing guard files through Bash (`sed`, `python`, `cp`) skips plan-guard. Only pre-commit catches it, and only at commit time.
    - plan-guard and check-plan each keep a copy of the PROTECTED list; keep them in sync.
    - `shot:` and `cmd:` resolve against the working tree, not the index.
  - Next: the user reviews and commits the guard changes by hand (`CHECK_PLAN_ALLOW=1 git commit …`, since guard files are staged).
- **2026-11-04 · S5 scope.**
  - The user committed the guard fixes as `057acb1`.
  - S5 stays "stop only". Continuing an interrupted task with a new prompt is out of S5; it's for later, together with adding context mid-task. This closes the S5 **Not** TODO.
- **2026-11-05 · mid-task context.**
  - STORY.md now covers adding context mid-task (`cc91a02`).
  - Added spike X4 (no deps, doesn't block M1; ARCHITECTURE §8.6) and an M2 candidate slice, gated on X4.
- **2026-11-05 · §0 ownership + auto-merge** (both approved by the user).
  - Several slice branches editing adjacent §0 rows would conflict on merge. From now on §0 and this Plan log are written only by the coordinating session, on `main`, when a slice starts, is blocked, goes to review, or merges.
  - Slice sessions edit only their own slice's section and its Log, on their own branch. "Before you stop" and "Who writes this file" in "How to use this file" say so; the Status field note now says the coordinating session brings §0 in line.
  - The user chose "Auto-merge when complete". The new "Merging a slice" rule: the coordinating session merges without asking once every Done when item is ticked with resolving evidence, every `[ui]` item was rerun by an independent reviewer, and pre-commit passes. It reports afterwards. Its bookkeeping commits for §0 and this log don't need asking either. Ticking `[human]` items, `Dxx` entries, any push or PR, and guard-file changes stay with the user.
  - No Done when item changed.
- **2026-11-05 · T0 and X2 started.**
  - Both run in their own sessions and worktrees, cut from `10d4639`: T0 on `claude/t0-tracer-513793`, X2 on `claude/x2-noise-b1b3cc`.
  - Ports (each worktree uses only its own bridge port; the real DSH and the Simulator are shared, so tests that hit them run one at a time):

    | Port | Owner | Use |
    |---|---|---|
    | 3080 | real DSH | DSH webserver (shared) |
    | 47800 | `main` | bridge, for demos on `main` after merges |
    | 47801 | T0 | bridge listener, app's loopback address |
    | 47802 | X2 | cross-handshake socket, if needed |

  - Next: start X1 + X4 as one session once T0's bridge runs inside DSH. Start X3 when the user has real-device time.
- **2026-11-05 · session settings** (approved by the user).
  - The user's rule is "指定 opus 5.5 medium": every tracer, slice, and spike session runs on model `claude-opus-5-5` at effort `medium`. "Session settings" in "How to use this file" says so.
  - T0 and X2 already ran `claude-opus-5-5`; their effort went from `high` to `medium`, starting with each session's next turn.
- **2026-11-05 · default choices** (the user's rules, relayed by the coordinating parent session while the user is out; the user replied "确认").
  - Decisions: sessions go ahead with their own recommendation and mark the `Dxx` entry provisional, pending user confirmation. Dependencies and downloads: allowed, pinned, marked the same way. "Default choices" in "How to use this file" says so. The "still the user's call" line under "Merging a slice" now says *confirming* `Dxx` entries and dependencies.
  - New §9 "Pending user confirmation": the coordinating session's list of every provisional item, for the user to review at once.
  - The user hasn't seen this diff yet. It was committed because the user is out and the rule text is theirs. It's listed in §9 for review.
  - No Done when item changed.
- **2026-11-05 · merge first, accept later** (the user approved this as "Yes, switch", relayed by the coordinating parent session).
  - It replaces the auto-merge condition. A slice merges once its `[auto]` and `[ui]` items are ticked with resolving evidence, `[ui]` items were rerun by an independent reviewer, and pre-commit passes. It no longer waits for `[human]` ticks.
  - After the merge, §0 says `review` while `[human]` items are open (each one listed in §9), or `done` if there are none. A merged slice meets its dependents' Needs, even in `review`. Problems found while the user accepts are fixed forward on `main`.
  - No Done when item changed.
- **2026-11-05 · X2 merged** as `e34a8bc`, status `done` (no `[human]` items).
  - Checked before the merge: both `[auto]` items ticked with resolving pointers; `spikes/x2-noise/scripts/interop` rerun by the coordinating session in X2's worktree; all Swift and TS vector and cross-handshake tests green. No `[ui]` items.
  - `.githooks/` has only `pre-commit`, which doesn't run on a merge commit, so `scripts/check-plan --base <pre-merge PLAN.md> --new PLAN.md` was run by hand: exit 0.
  - Result: pairing `Noise_IKpsk1_25519_ChaChaPoly_SHA256`, reconnect `Noise_IK_25519_ChaChaPoly_SHA256` (provisional D6, §9). S1 ports the code instead of depending on `spikes/`. Open question for S1: is the Secure Enclave P-256 identity key still needed in M1?
- **2026-11-05 · T0's bridge runs inside real DSH; X1 + X4 proposed.**
  - T0 reports a full round trip on its branch (`c245373`): client → `ws 127.0.0.1:47801` → `Hello` / `CreateTask` → DSH session → streamed text → `TaskEnded COMPLETED`. It uses DSH 0.2.2-rc.1 in `~/.dshm/runtime` with the mock model server and no API key. The shared install's details are in `scripts/dsh-up.mjs` on T0's branch.
  - That meets the start condition for X1 + X4. The app only starts sessions on the user's own words, so the session is a proposal card in the coordinating session, waiting for the user.
  - More ports, plus a separate `DSH_HOME` for each DSH instance:

    | Port | Owner | Use |
    |---|---|---|
    | 3281 | T0 | DSH web of T0's instance (`DSH_HOME=~/.dshm/home`) |
    | 3282 | X1 + X4 | DSH web of the spikes' instance (`DSH_HOME=~/.dshm/home-x1x4`) |
    | 47803–47809 | X1 + X4 | plugin listener, mock model server, release scripts |

  - T0's `c245373` committed about 28 MB of `ios/DSHKit/.build/`, which `89f76df` removes only at the tip. T0 was asked to drop it from its branch history before review.
- **2026-11-05 · T0 merged** as `84db2e8`, status `review` (3 `[human]` items open, listed in §9).
  - Checked before the merge:
    - All 6 `[auto]` and both `[ui]` items are ticked, with resolving pointers.
    - T0's independent review subagent reran both `[ui]` items (see T0's Log).
    - The coordinating session reran `scripts/demo/t0.sh` in T0's worktree: codegen check, bridge tests, 11 DSHKit tests, the bridge inside real DSH (mock LLM), and 4 XCUITests. All green, exit 0.
    - `scripts/check-plan --base <pre-merge PLAN.md> --new PLAN.md`: exit 0.
    - No `ios/DSHKit/.build/` objects are left in the branch history. The branch was rewritten, so the `c245373` cited in the entry above is now `28d1bda`.
  - T0's Needs are met for S1 (X2 done), S2, S3, S5, S6, S7, and S12. S4 still waits for X1, S8 for X3.
  - Next: propose sessions for S1, S2, S3, at most 3 at a time. The app starts each one only on the user's word.
- **2026-11-05 · S1, S2, S3 proposed** as sessions, waiting for the user to start them (along with X1 + X4). Each slice gets its own bridge port, DSH instance, and Simulator device, so the three can run tests in parallel. All of them use the shared DSH install in `~/.dshm/runtime` read-only.

    | Slice | Bridge port | DSH web | `DSH_HOME` | Simulator |
    |---|---|---|---|---|
    | S1 | 47810 | 3283 | `~/.dshm/home-s1` | `dshm-S1` |
    | S2 | 47811 | 3284 | `~/.dshm/home-s2` | `dshm-S2` |
    | S3 | 47812 | 3285 | `~/.dshm/home-s3` | `dshm-S3` |
- **2026-11-05 · execution moves from sessions to a workflow** (the user: "先用 workflow 跑一批").
  - Why: the app starts a new session only from the user's own words, so the S1–S3 and X1 + X4 cards sat unstarted while the user was out. A Workflow script started from the main session runs the slices as background agents instead; it doesn't need the user to start each one.
  - Batch 1 is `wf_219b7aa1-71c`: X1 + X4, S1, S2, S3, each in its own worktree and branch, with the ports, `DSH_HOME`s and Simulators from the entry above. Agents run on `claude-opus-5-5` at effort `medium`, the same as "Session settings". A slice with `[ui]` items is then rerun by a separate review agent that didn't build it. Merging, §0 and §9 stay with the coordinating side on `main`, which is now the main session; the rules in "Merging a slice" are unchanged.
  - The X1 + X4, S1, S2 and S3 session cards in the coordinating session are superseded; don't start them.
- **2026-11-05 · X1 + X4 merged** as `ccc8ff9` from batch 1's workflow (`wf_5740da3d-b68`, which resumed the stopped `wf_219b7aa1-71c` in the same worktrees). Status of both is `review`: one `[human]` item each is open (§9).
  - Checked before the merge:
    - both `[auto]` items are ticked, with pointers that resolve;
    - the main session reran `spikes/x1-approval/scripts/run` (36/36) and `spikes/x4-midtask/scripts/run` (19/19) in the branch worktree;
    - `scripts/check-plan --base <main PLAN.md> --new <branch PLAN.md>` exited 0;
    - no build products are in the history.
  - There are no `[ui]` items and no new dependencies or downloads.
  - Results: provisional D17 (approval holder goes first in the chain and fans a copy out to the web; first answer wins) and D18 (`SendMessage` steer/queue; agent questions have their own messages). ARCHITECTURE §1, §5.4, §8.1 and §8.6 are updated and marked provisional.
  - S4's Needs are now met.
  - S3 and S1 also wrote new `Dxx` entries starting at D17. They are renumbered after D18 when they merge.
- **2026-11-05 · X1 and X4 accepted.** The user ticked both `[human]` items in `0eaa7e3` after reading a summary of the two conclusions, so both are now `done`. §9 rows 15 and 16 are removed. D17 and D18 stay provisional (rows 13 and 14) until the user confirms them.
- **2026-11-05 · D17 and D18 confirmed by the user** ("一起确认"). ARCHITECTURE.md drops their provisional markers, along with the related §1, §5.4, §8.1 and §8.6 notes. §9 rows 13 and 14 are removed. The S1 and S3 branches also number new entries from D17; those get renumbered when they merge.
- **2026-11-05 · batch 1 merged: S1, S2, S3** (`main` fast-forwarded to `1f35fa2`). S2 and S3 are `done`. S1 is `review`, with 2 `[human]` items open (§9).
  - **Build:** workflow `wf_5740da3d-b68`. Each slice was built in its own worktree, and a review agent that hadn't built it reran its `[ui]` items. All three passed.
  - **Integration:** workflow `wf_ab6e2118-9f3`, on branch `claude/batch1-integration` cut from `main`. The slices were merged in the order S3 (`eb429a9`), S2 (`3ce2088`), S1 (`f7c3c4d`).
  - **Seams**, each owned by the slice that landed second, added to its Done when, then built and ticked:
    - S2 × S3, cached milestones: list rows and the detail view show the milestone card from the cache after kill/reopen (D23).
    - S1 × S2, resume over Noise: kill/reopen reconnects with an IK handshake and resumes from the cursor (D24).
  - **Renumbered:** S3 D17 → D19, S2 D17 → D20, S1 D20 → D21 and D21 → D22. Each slice appended a Log line for this; older Log entries keep the old numbers.
  - **Demo scripts fixed:** `scripts/demo/lib.sh` installs bridge dependencies before `codegen --check`, and fails on skipped tests; each run gets its own DerivedData.
  - **Integration bug:** FakeHost task ids collided across app launches. They now carry a per-instance prefix (D23).
  - **Checked before the merge:**
    - The integrator reran `check-release-clean`, `t0.sh`, `s1.sh`, `s2.sh` and `s3.sh` from clean builds. All exited 0: 41 bridge tests, 46 DSHKit tests, nothing skipped.
    - A separate review agent reran every `[ui]` item of T0, S1, S2 and S3 at `1f35fa2`, including both seam items. All passed.
    - `scripts/check-plan --base <main PLAN.md> --new PLAN.md` exited 0. Dxx numbers are unique, with no dangling references. No build products are in the diff.
  - **Side effects:**
    - The DSH profiles in `~/.dshm/home*` now point at a review worktree's `bridge/`. The next demo run re-adds its own path.
    - `~/.dshm/home-s1` holds test devices from repeated runs.
  - Also updated: the two spike READMEs now say D17 and D18 are confirmed.
  - **Next:** batch 2. Ready now: S4, S5, S6, S7, S9, S10, S11, S12. X3 runs a Simulator benchmark, with the real-device check left as `[human]`.
- **2026-11-05 · process rules move to WORKFLOW.md** (asked for by the user before a move to another Mac).
  - "How to use this file" kept only the slice format and the Done when rules. Before you start / stop, Who writes this file, Merging a slice, Session settings and Default choices moved to the new WORKFLOW.md, rewritten in ASD-STE100-style English. The rules themselves are unchanged.
  - New in WORKFLOW.md: `scripts/bootstrap` for a new Mac (§2), the long-horizon run (§5: the user starts the coordinator once and does not click session cards; the coordinator falls back to a workflow or `codex exec` when the app refuses a session start), resources for each slice (§6), status titles (§7), and Codex support (§12, §13).
  - Codex guards: `.codex/hooks.json` runs `.codex/hooks/codex-guard` before `Bash` and `apply_patch`. It reuses `git-guard` and `check-plan`, and denies where Claude Code asks (Codex doesn't support `ask` yet). `.codex/hooks.json` and `.codex/hooks/*` joined `PROTECTED` in `scripts/check-plan` and `plan-guard`. Verified: `.codex/hooks/codex-guard-test` (16 cases, 0 failures), and a live `codex exec` run (codex-cli 0.146.0) in a scratch worktree, where the hook blocked a `[human]` tick, a guard-file edit and a `--no-verify` commit. The user commits these guard files by hand.
  - No Done when item changed.

- **2026-11-05 · Coordinator starts batch 2 on this Mac.** At `fb64666`, T0 passed with the real DSH CLI, 41 bridge tests, 46 DSHKit tests and 4 Simulator UI tests. The DSHKit Mac deployment target is 15 for host tests on this Mac (macOS 15.7.7, Xcode 26.0); the iOS target is 26. The pinned DSH packages were installed from the public npm registry.
  - Codex started three `codex exec` owners. Each worktree is under `~/.codex/worktrees/<branch suffix>/dsh-mobile`. Each owner uses its own Simulator, DSH profile, DerivedData and ports. The shared runtime is read-only to owners.
  - S4: `claude/s4-approvals`, `dshm-S4`, `~/.dshm/home-s4`, bridge 47810, web 3283.
  - S5: `claude/s5-interrupt`, `dshm-S5`, `~/.dshm/home-s5`, bridge 47811, web 3284.
  - S6: `claude/s6-models`, `dshm-S6`, `~/.dshm/home-s6`, bridge 47812, web 3285.

- **2026-11-05 · Batch 2 execution fallback.** The three CLI workspaces could not fetch missing dependencies or access CoreSimulator under their child sandbox. The coordinator transferred each slice to a Codex subagent in the same branch and worktree, with the same resources. Each owner reruns T0 before implementing its slice.

- **2026-11-05 · S5.** Merged `529bb16` after an independent rerun at b3ad3a8. All 42 bridge tests, 46 Swift tests and the real DSH UI test passed with zero skips. The reviewer verified the interrupted stream, list and offline reopened milestone. Evidence: scripts/demo/s5.sh and evidence/S5/s5-interrupted-detail.png. The merge PLAN comparison passed.

- **2026-11-05 · X3.** Assigned claude/x3-markdown, worktree /Users/bytedance/.codex/worktrees/x3-markdown/dsh-mobile, simulator dshm-X3, DSHM_HOME ~/.dshm/home-x3, bridge 47813, web 3286. The owner uses the shared DSH runtime read-only.

## 9. Pending user confirmation

Kept by the coordinating session on `main`. It lists provisional `Dxx` entries, dependencies, and downloads (see [WORKFLOW.md §9](WORKFLOW.md#9-default-choices)), rule commits the user hasn't seen, and open `[human]` items of merged slices with the device or setup each needs (see [WORKFLOW.md §10](WORKFLOW.md#10-merge-a-slice)). The user reviews and accepts them all at once. A row leaves this table, with a Plan log line, when the user confirms or changes it.

| # | Slice | Kind | Item | Branch | Commit |
|---|---|---|---|---|---|
| 1 | — | rule | "Default choices" rule text (now WORKFLOW.md §9) and this section (the user approved the rules, not this wording) | `main` | see Plan log 2026-11-05 · default choices |
| 2 | X2 | dependency | npm `@noble/ciphers` 2.4.0, `@noble/curves` 2.4.0, `@noble/hashes` 2.4.0 (spike only, `spikes/x2-noise/ts/`) | `main` (merged `e34a8bc`) | `3f4d72e` |
| 3 | X2 | download | Noise test vectors: `cacophony.txt` (haskell-cryptography/cacophony @ `18b7348`) and `snow.txt` (mcginty/snow @ `d00b360`); sha256 in `spikes/x2-noise/vectors/SHA256SUMS`; a filtered subset is committed | `main` (merged `e34a8bc`) | `3f4d72e` |
| 4 | T0 | decision | ARCHITECTURE D15 (toolchain: buf + protoc-gen-es / swift-protobuf codegen, pnpm bridge, `ios/DSHKit` package layout) and D16 (debug-only testability entry points), *provisional* | `main` (merged `84db2e8`) | `03cc202` |
| 5 | X2 | decision | ARCHITECTURE D6 refined, *provisional*: pairing `Noise_IKpsk1_25519_ChaChaPoly_SHA256` (psk = the QR's one-time secret), reconnect `Noise_IK_25519_ChaChaPoly_SHA256`, mode + protocol version in the prologue, own Noise state machine on CryptoKit / `@noble/*` | `main` (merged `e34a8bc`) | `ce9ee4c` |
| 6 | T0 | dependency | Bridge (`bridge/pnpm-lock.yaml`): runtime `@bufbuild/protobuf` 2.16.0, `ws` 8.22.1; dev `@bufbuild/buf` 1.75.0, `@bufbuild/protoc-gen-es` 2.16.0, `typescript` 7.0.2, `@types/node` 24.19.2, `@types/ws` 8.18.2; pnpm 11.28.5 via corepack | `main` (merged `84db2e8`) | `28d1bda` |
| 7 | T0 | dependency | Swift: `apple/swift-protobuf` 1.39.0, revision `3d537cb` (`ios/DSHKit/Package.resolved`) | `main` (merged `84db2e8`) | `b54c8d5` |
| 8 | T0 | download | npm `@deepseek-ai/dsh@0.2.2-rc.1` and `@deepseek-ai/dsh-llm-mock-server@0.2.2-rc.1` in `~/.dshm/runtime` (sha512 in T0's Log); shallow swift-protobuf 1.39.0 clone in `~/.dshm/mirrors/swift-protobuf` | outside the repo | `71dd78c` (Log) |
| 9 | T0 | local setup | `~/.dshm/bin/pnpm` shim (corepack pnpm 11.28.5); SwiftPM cache entry seeded from the shallow clone; DSH location `~/.dshm` with `DSH_HOME=~/.dshm/home` (`~/.dsh` untouched) | outside the repo | `71dd78c` (Log) |
| 10 | T0 | `[human]` | "Following `bridge/README.md` installs and enables the plugin in a DSH profile". Needs: this Mac with DSH 0.2.2-rc.1 (`~/.dshm`), about 10 minutes | `main` | `84db2e8` |
| 11 | T0 | `[human]` | "Toolchain choices … recorded in ARCHITECTURE.md". Needs: reading D15 (confirms row 4) | `main` | `84db2e8` |
| 12 | T0 | `[human]` | "Testability entry points … recorded in ARCHITECTURE.md". Needs: reading D16 (confirms row 4) | `main` | `84db2e8` |
| 17 | S3 | decision | ARCHITECTURE D19, *provisional*: milestone mapping from DSH session events (turn/start, todo/write, plan/mode, llm/retry, turn/end), `MilestoneAdded` carries the whole todo list, card + timeline UI | `main` (merged `1f35fa2`) | `debb402` |
| 18 | S2 | decision | ARCHITECTURE D20, *provisional*: in-memory per-host event log (`log_id` + `host_seq`), `ListTasks` / `Resume` / `LogReset`, SwiftData cache + cursor, reconnect backoff 0.5 s → 30 s, refresh on foreground | `main` (merged `1f35fa2`) | `2b14fd0` |
| 19 | S1 | decision | ARCHITECTURE D21, *provisional*: pairing offer URL, 10-minute single-use offers, wire header in the Noise prologue, close codes 4000–4003, bridge listens on 0.0.0.0 Noise-only (plaintext only in dev, on loopback `/plaintext`) | `main` (merged `1f35fa2`) | `4181b8f` |
| 20 | S1 | decision | ARCHITECTURE D22, *provisional*: no Secure Enclave identity key in M1; one Keychain X25519 Noise static key per device; the SE signing key returns with Face ID approvals in M2 | `main` (merged `1f35fa2`) | `4181b8f` |
| 21 | S2 × S3 | decision | ARCHITECTURE D23, *provisional*: milestones are written into the host log and cached with the task; the card shows in list rows and in the detail view | `main` (merged `1f35fa2`) | `67bb77c` |
| 22 | S1 × S2 | decision | ARCHITECTURE D24, *provisional*: one TaskListStore per host, swapped on pairing; every reconnect is a fresh IK handshake followed by `Resume` | `main` (merged `1f35fa2`) | `08abaa6` |
| 23 | S1 | dependency | Bridge runtime: `@noble/curves`, `@noble/ciphers`, `@noble/hashes` 2.4.0 (previously spike-only, row 2), `uqr` 0.1.3 (terminal QR) | `main` (merged `1f35fa2`) | `6b1f0bf` |
| 24 | S1 | `[human]` | "A fresh iPhone scans the QR and runs the T0 demo over Wi-Fi or Tailscale". Needs: a real iPhone, this Mac running `scripts/dsh-up.mjs` with the bridge reachable on the LAN or Tailscale, and the app installed with your free Apple team | `main` | `1f35fa2` |
| 25 | S1 | `[human]` | "A packet capture of that session shows only ciphertext". Needs: the session from row 24, plus Wireshark or `tcpdump` on this Mac | `main` | `1f35fa2` |
| 26 | S5 | decision | ARCHITECTURE D28, provisional: acknowledge the interrupt, then derive the terminal state from the durable DSH aborted/user event. | `main` | `529bb16` |
