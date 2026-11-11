# M3 draft · Three-layer mobile architecture and TLS 1.3

M3 has two deliverables. The iOS features use typed Swift domain operations, and the iPhone connects directly to its host bridge over pinned TLS 1.3. The user has agreed to update the host plugin, reinstall the phone app and scan a fresh QR. Host sessions and audit history remain on the computer.

This is the external planning draft. After M2.5 exits, create the M3 milestone and its issues, then use the tools on the resulting `main` to generate `plan/*.json`. Map each slice to its issue in its Why field (`Closes #N`). Record the affected files, screens and runnable `cmd:` for each automated or simulator criterion. The slice IDs below keep the two reviews comparable. Map them to the generated IDs if the tool assigns them sequentially. Product and implementation references are [STORY.md](dsh-mobile/STORY.md), [screens.json](dsh-mobile/design/screens.json) and [ARCHITECTURE.md](dsh-mobile/ARCHITECTURE.md).

## 1. Interfaces M3 must preserve

| Owner | Interface and responsibility | Production example |
|---|---|---|
| Business layer · app, DSHFeatures, widget UI | SwiftUI and feature state call host-scoped Swift domain operations and observe typed snapshots. The composition root injects concrete platform services. The widget uses the small DSHActivity contract. | Workspace selection, a pending approval, dictation and Live Activity updates. |
| Business foundation · DSHCore, with DSHActivity as the separate widget contract | DSHCore owns host identity and address selection, the active connection generation, frame dispatch, request correlation, attachment upload and typed refusals. Its sync owner persists each host's data and cursor. Domain-facing protocols for platform services have production and test implementations. | A command response reaches its caller while a host event updates the task. The voice feature uses `TranscriberFactory`, and Live Activities use `LiveActivityClient`. |
| Foundation · DSHTransport and DSHProtocol | DSHTransport opens an authenticated byte channel and exposes ordered binary `send`, `receive` and `close`, with generic transport, trust and key-storage primitives. DSHProtocol owns the generated frame types and wire encoding. DSHCore supplies the expected host identity and pairing policy and interprets frames. | One protobuf frame per binary WebSocket message. An unsolicited event can arrive while a request is pending. |
| Host bridge · TypeScript plugin on the user's machine | The bridge adapts the wire protocol to DSH, authenticates each device and checks its live registry entry. The device identity used for a command and its audit comes from the authenticated connection. | Two paired devices have independent connections, capabilities and revocation outcomes. |

The phone initiates one full-duplex connection. Its DSHCore receive loop owns the dispatch of responses and events for that generation. Disconnecting completes outstanding requests with an error. A late frame or teardown from an old connection cannot resolve a new request or close a new connection. In the current wire contract the phone sends requests and the bridge answers them. An unexpected request arriving at the phone is ignored safely. S1 proves that behavior with an existing frame.

Each side sends its own supported features in `Hello`. The bridge uses the phone's announcement to select events for that connection. The phone interprets the host's announcement as typed feature availability. Recompute availability on reconnect. Historical information may serve offline presentation. Authority to run a host operation comes from the authenticated device, the bridge's registry and the existing operation rules. A capability string alone grants no access. The existing contracts are visible in [BridgeTransport.swift](dsh-mobile/ios/DSHKit/Sources/DSHCore/BridgeTransport.swift), [frame.proto](dsh-mobile/protocol/frame.proto), [HostConnection.swift](dsh-mobile/ios/DSHKit/Sources/DSHCore/HostConnection.swift) and the [bridge connection handler](dsh-mobile/bridge/src/server.ts).

### Design check · a future phone workspace

Consider a user sharing two iPhone recordings with session A on a paired Mac. The DSH workspace remains the Mac directory where the task executes. The phone workspace would identify the material the user chose to share. The example tests whether a future feature fits the interfaces above.

- **Discovery.** In a future feature, the phone could advertise a versioned ability to list or read shared items. The bridge could expose those operations to the eligible DSH agent through DSH's scoped `ctx.tools.register` interface. An advertised operation, an online phone and a grant to read a particular item answer three different questions.
- **Invocation and trust.** The bridge would take the session from the actual DSH tool execution context, bind it to the authenticated host/device connection, and send a correlated call. The phone would match the paired bridge's assertion against the user's grant. The bridge is trusted to distinguish A from B on that host. Model-supplied arguments cannot confer session identity. Session B and another host must not inherit A's grant.
- **Lifetime.** Revocation would stop new reads. Going offline would make material still on the phone unavailable. A copy already delivered to the Mac could continue to be analyzed there. Transfer interruption and copy retention would be decisions for that feature.

**Scope for M3.** Preserve the existing byte channel, frame dispatcher, connection-scoped negotiation, domain operations and injectable platform services. Prove them with today's frames, events, attachments and adapters. The phone workspace has no M3 slice or exit item. Its wire messages, reverse RPC, capability names, DSH tools, sharing grants and UI, media providers, offline behavior and copy policy all belong to a later requirement. M3 introduces no placeholder API or generic tool registry for it.

## 2. Slice dependencies

T0 and S1 can start independently. S6 verifies the architecture. S8 delivers the transport change. S8 can ship once its transport, enrollment and regression checks pass. M3 exits after both lines pass on the combined revision and the user completes the physical-device check. Whichever line lands last reruns the dependency and release checks. S2 and S7 share the device-management behavior; whichever lands second reruns self-revocation through both existing UI entry points.

~~~mermaid
flowchart LR
    T0["T0 · Workspace domain API"] --> S2["S2 · Host management"]
    T0 --> S3["S3 · Model selection"]
    T0 --> S4["S4 · Session history"]
    S1["S1 · Transport boundary"] --> T1["T1 · Pinned TLS tracer"]
    S1 --> S5["S5 · Durable host sync"]
    S2 --> S5
    S3 --> S5
    S4 --> S5
    S5 --> S10["S10 · Feature state"]
    S10 --> S6["S6 · Dependency enforcement"]
    T1 --> S7["S7 · Device enrollment and revocation"]
    S7 --> S11["S11 · TLS demo migration"]
    S11 --> S8["S8 · TLS-only cutover"]
    S6 --> Exit["M3 exit"]
    S8 --> Exit
~~~

## 3. Work and acceptance

All slices are proposed. Commands are relative to the repository root. Existing commands identify where to run the original behavior and the new assertions. A command labeled **new** is an executable to deliver in that slice. Check all evidence paths against the post-M2.5 checkout when authoring the executable plan. A command below names planned evidence and carries no passing result.

### T0 · List host workspaces through a Swift domain API

**Needs** —  
Map the existing workspace-list response once inside DSHCore. Use the same Swift values for the real picker and its fake. Set the mapping and shared signatures with this single read. S2–S4 each move their own operations into feature-specific extensions as needed.

- [ ] [auto] Empty and populated lists preserve the host default and the selected path. The picker and its public interface compile using Swift domain values. `cmd:scripts/swift-test`, `cmd:scripts/demo/pickers.sh`
- [ ] [ui] Select a workspace on the intended host and relaunch. PickersUITests shows the host default again. `cmd:scripts/demo/pickers.sh`

### S1 · Extract the transport boundary

**Needs** —  
Move ordered WebSocket I/O, endpoint probing and generic key storage into DSHTransport. Keep the working connection path while T1 brings up TLS. DSHCore owns protocol-level upload, one inbound dispatcher per connection generation, cancellation, refusal handling and address selection. The transport can carry messages in either direction without decoding a protobuf frame.

- [ ] [auto] The foundation targets build independently of DSHCore, UI, widget and fakes. Exercise ordered delivery, cancellation, refusal and disconnect with an outstanding request. A stale connection cannot affect its replacement. `cmd:scripts/swift-test`
- [ ] [auto] Inject an existing, well-formed Request frame such as Hello toward the phone. It triggers no action or reply. On the same channel a subsequent valid response resolves its caller and a supported event reaches the store. `cmd:scripts/swift-test`
- [ ] [ui] Pair during the test and reconnect to the real bridge through the second address. `cmd:scripts/demo/reconnect.sh`

### T1 · Exchange a golden Hello over pinned TLS 1.3

**Needs** S1  
Connect the production iOS transport to a real Node HTTPS/WebSocket listener. Require TLS 1.3 at both ends. The QR identifies a host by SHA-256 of the P-256 DER SubjectPublicKeyInfo (SPKI). Define how the bridge issues and renews its certificate on supported host platforms, how IP and DNS addresses reach the QR, and how certificate names/SANs are validated as addresses change. Record any new signing dependency for user review. Try URLSession first; evaluate Network.framework against the same checks if needed.

- [ ] [auto] Swift and Node agree on the SPKI fixture, negotiate TLS 1.3, exchange a golden Hello and reconnect after valid same-key renewal. `cmd:scripts/demo/pinned-tls.sh` **new**
- [ ] [auto] Reject the wrong host/key, an expired or unsuitable server certificate, TLS 1.2, cleartext and redirects. Use a harmless sentinel to prove upgrade-header delivery to the trusted listener and absence on rejected or redirected peers. S7 repeats this with actual device credentials. `cmd:scripts/demo/pinned-tls.sh`
- [ ] [ui] Use the production client in an iOS build with no broad ATS exception and no preinstalled private CA. Test IP and DNS, then change the reachable address or DNS resolution after pairing under the same key. Show a recovery path if all known addresses fail. Inspect the built test product's Info.plist so the old arbitrary-loads setting cannot satisfy this check. `cmd:scripts/demo/pinned-tls.sh`

### S2 · Give host management a domain API

**Needs** T0  
Route both the drawer and the hosts sheet through the selected host's device, audit-page and revocation operations in DSHCore. Interpret support and refusal once. Each feature owns its views and local interaction state.

- [ ] [auto] HostsControlTests cover pagination cursors, actor identity, missing support, offline hosts and both orders of self-revocation response and socket close. The management views compile using domain values. `cmd:scripts/swift-test`, `cmd:scripts/demo/devices.sh`
- [ ] [ui] Audit and revoke another device on the real bridge. Self-revoke from each existing management entry point. `cmd:scripts/demo/devices.sh`, `cmd:scripts/demo/revoke.sh`

### S3 · Use domain values for model selection

**Needs** T0  
Translate provider groups, model choices, optional reasoning effort, availability, defaults and errors at the host boundary. Keep picker draft and display decisions in the feature. Apply the same mapping to live and cached selections.

- [ ] [auto] Cover absent effort, explicit choice, unavailable model, missing optional capability and reopening a saved selection. Preserve field presence, provider order and host defaults. `cmd:scripts/swift-test`
- [ ] [ui] Select a model and effort, restore the default and show an unavailable selection through the existing sheet. `cmd:scripts/demo/pickers.sh --regress`

### S4 · Read session history through domain values

**Needs** T0  
Map session pages, messages, parts and attachments at the host/cache boundary. Use them in the session page, retry text and single-turn transcript recovery. Preserve the serialized history format and revision rules.

- [ ] [auto] Read a history with absent optional fields, mixed parts and attachments through the bridge and from disk. Both produce the same messages. Stale revisions and replay cannot duplicate a turn. `cmd:scripts/swift-test`
- [ ] [ui] A web-originated turn updates the open phone session. After disconnect and relaunch, detail still displays the saved history. `cmd:scripts/demo/session-visibility.sh`, `cmd:scripts/demo/rich-detail.sh`

### S5 · Extract durable cache and per-host sync

**Needs** S1, S2, S3, S4  
Keep the SwiftData models in DSHCore. Give each host a single sync owner for its connection loop, replay cursor and writes. Save each applied set of events and its cursor together. Supply typed snapshots/events for consumers. S10 moves feature state after this boundary works.

- [ ] [auto] Populate a fresh disk cache via production sync. Offline after relaunch, read tasks, transcript, pending decisions, attachment metadata and the saved cursor. `cmd:scripts/swift-test`
- [ ] [auto] Interrupt a save and restart. The durable cursor never leads the stored data. Replay from the last committed cursor restores each change once. Repeated foreground transitions, dropped connections and host-log replacement preserve isolation between hosts. `cmd:scripts/swift-test`
- [ ] [ui] A phone task streams into the list, survives relaunch and remains available for a follow-up. `cmd:scripts/demo/durable-list.sh`, `cmd:scripts/demo/followup.sh`

### S10 · Move feature state and commands to their consumers

**Needs** S5  
Build DSHFeatures on the typed sync API. Put draft/send state and Live Activity orchestration with their consumers. Keep protocol-level transfers and durable writes in DSHCore. Preserve the domain-facing transcriber and activity-client contracts and inject the iOS implementations at composition.

- [ ] [auto] TaskListStore consumes snapshots and domain commands. Feature code cannot drive a socket or a ModelContext. Existing composer, approval, question, queued follow-up and attachment suites retain their state transitions. `cmd:scripts/swift-test`
- [ ] [ui] Send and follow up through the app. Exercise the injected transcriber and Live Activity adapter through their existing smoke paths. `cmd:scripts/demo/followup.sh`, `cmd:scripts/demo/voice.sh`, `cmd:scripts/demo/live-activity.sh`

### S6 · Enforce the dependency graph

**Needs** S10  
Replace aggregate DSHKit linkage with explicit target dependencies and middle-layer factories. Keep DSHActivity dependency-free and Debug fakes in test support. Use compiler-enforced access control for generated types, then check target declarations, imports and re-exports. Add the check to the normal test entry point and update ARCHITECTURE.md and the repo layout in AGENTS.md alongside the code.

- [ ] [auto] The production graph passes with zero per-feature exemptions. A seeded reverse dependency, a feature-to-foundation shortcut and a public protobuf typealias each fail the appropriate check. `cmd:scripts/check-layers` **new**, `cmd:scripts/check-layers-test` **new**
- [ ] [auto] Business code consumes typed operations and availability. Raw transports, SwiftData containers and wire capability strings stay behind the boundary. The widget links only DSHActivity. Codegen, Swift, bridge golden tests and Debug/Release checks pass; Release contains no test entry points. `cmd:scripts/check-layers`, `cmd:scripts/codegen --check`, `cmd:scripts/swift-test`, `cmd:scripts/pnpm-test`, `cmd:scripts/check-release-clean`
- [ ] [ui] The real-DSH round trip, Live Activity and voice smoke tests pass with the final composition. `cmd:scripts/demo/round-trip.sh`, `cmd:scripts/demo/live-activity.sh`, `cmd:scripts/demo/voice.sh`

### S7 · Enroll and revoke individual devices over TLS

**Needs** T1  
Use a versioned QR with the bridge key fingerprint, addresses, expiry and a single-use random enrollment secret. The bridge is the only writer of offers. The CLI requests each QR over owner-only local IPC. Record the platforms on which IPC access control and certificate provisioning were verified. Issue a random per-device bearer over the pinned connection, store it under a distinct ThisDeviceOnly Keychain service, and store its digest on the bridge. Use the Authorization header on the WebSocket upgrade. Redact secrets, reject redirects and gate task, event and management access on live registry membership.

- [ ] [auto] Run CLI and bridge as separate processes. Verify local caller access, concurrent issue/redemption, replay, expiry, interruption and restart. Each offer enrolls at most one device; a new offer recovers an interrupted enrollment. Wrong pins, redirects and invalid credentials yield no credential disclosure or RPC/event access. `cmd:scripts/demo/tls-enrollment.sh` **new**
- [ ] [auto] Race upgrade/reconnect with revocation. Close all sockets of the targeted device, deny its reconnect and record the authenticated actor. The other device keeps access. Two authenticated peers with different Hello announcements receive the correct `questions.v1` behavior on their own connections. Reconnect renegotiates availability. `cmd:scripts/pnpm-test`, `cmd:scripts/demo/tls-enrollment.sh`
- [ ] [auto] Disconnect with a partial or staged attachment. A fresh connection cannot consume the old upload ID. An attachment already consumed by CreateTask or SendMessage reached DSH with its original bytes and metadata. `cmd:scripts/pnpm-test`
- [ ] [ui] Dispatch, relaunch and reconnect. Test revocation both while connected and while offline. Only an explicit device refusal from the pinned host triggers forgetting that host. Network errors, certificate errors and an unrelated listener leave its pairing and cache intact. Other hosts are unaffected. `cmd:scripts/demo/tls-enrollment.sh`

### S11 · Migrate real bridge demos to TLS

**Needs** S7  
Add a shared TLS enrollment step in `scripts/demo/lib.sh`. Inventory the demos and fixtures that use a network listener, then migrate them to the production TLS path. Retain in-process fakes for isolated tests. S11 owns demo migration, and S8 owns release cutover and removal of the old implementations. Budget review of the shared helper and the changed evidence scripts. Follow the merge tool's actual protected-path list and record each reviewed path it requires.

- [ ] [auto] The shared setup creates isolated host/device state and runs fresh enrollment. The demo inventory catches remaining live bridge connections using legacy or cleartext setup. Exercise the migrated suites through their normal wrappers. `cmd:scripts/demo/check-tls-demos.sh` **new**
- [ ] [ui] Run the real bridge round trip, attachment transfer, failover and revocation using the common TLS setup. `cmd:scripts/demo/round-trip.sh`, `cmd:scripts/demo/attachments.sh`, `cmd:scripts/demo/reconnect.sh`, `cmd:scripts/demo/revoke.sh`

### S8 · Cut over to TLS as the only phone–bridge network transport

**Needs** S11  
Ship the TLS-only plugin, CLI and iOS app together. Remove the Swift and TypeScript Noise implementations, their runtime dependencies and the real Debug cleartext route. Replace the old arbitrary-loads assertion in `scripts/check-release-clean` with checks of the built products. Have the reviewer inspect each protected evidence change. Keep the existing bridge state root and DSH session store. Put the TLS identity and new device registry in a separate subdirectory or files under that root. Read legacy device records only to reconstruct pairing audit; merge that history with approval records and new audit entries.

- [ ] [auto] With old offers, device records, host keys and a residual Keychain item, a new app installation starts unpaired. Old credentials grant no access. A new QR enrolls the phone. Read prior DSH sessions and page across old and new pairing, revocation and approval records with no gaps or duplicates. `cmd:scripts/pnpm-test`, `cmd:scripts/demo/tls-upgrade.sh` **new**
- [ ] [auto] All phone–bridge network paths use TLS 1.3. Built-product and listener checks catch legacy code, cleartext and broad ATS exceptions. Same-key renewal occurs before expiry. Old QRs and changed keys fail closed with recovery instructions. `cmd:scripts/check-release-clean`, `cmd:scripts/demo/tls-upgrade.sh`
- [ ] [auto] Swift, bridge and protobuf checks pass. Installation instructions cover update order, fresh enrollment, same-key renewal and changed-key recovery. The shipped CLI and migrated demos work with that procedure. `cmd:scripts/swift-test`, `cmd:scripts/pnpm-test`, `cmd:scripts/codegen --check`, `cmd:scripts/demo/check-tls-demos.sh`
- [ ] [ui] From a fresh install, read a pre-existing host session, dispatch, fall back to a second address, replay missed events and revoke through both existing management screens. `cmd:scripts/demo/tls-upgrade.sh`, `cmd:scripts/demo/revoke.sh`

## 4. Exit and decisions

- [ ] **Combined revision.** S6 and S8 have both landed. Rerun the dependency, package, bridge, release and real round-trip checks on their combined code.
- [ ] **Physical iPhone · user check.** With a fresh install and release trust settings, scan a new QR, open a pre-existing host session and reconnect over LAN and Tailscale (IP and MagicDNS). Relaunch offline and read the synced session. An early physical-device smoke after T1 is optional.
- **Technology decisions to record.** T1 records the tested cross-platform certificate issuance and renewal mechanism, including any new dependency for user confirmation. S7 records the bearer credential design and the IPC protection verified on each supported host platform.

The proposed swift-markdown parser change (formerly S9) is a separate follow-up. Its eventual benchmark should exercise the actual old and new production rendering paths with the same streaming workload. Measure run-to-run variation before choosing a regression threshold.

## Review record

The original planning run at `edaf1b9` reported 164 Swift tests, 116 bridge tests and a codegen check passing. Its temporary macOS TLS exchange established feasibility only. The iOS trust path, upgrade behavior and human exit above remain to be demonstrated.

On 2026-11-10 Codex and Claude Fable 5.2 High agreed on the independent architecture and TLS delivery lines, the clean-install cutover, the split of durable sync from feature state, and deferring Markdown. A second review used the phone workspace to define the existing interfaces M3 must preserve and the current behaviors that prove them.
