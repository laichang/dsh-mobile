#if DEBUG
import DSHCore
import DSHProtocol
import Foundation
import SwiftProtobuf
import Synchronization

/// In-process stand-in for the bridge (PLAN §1 "Test alone"). Speaks real `Frame` bytes, so
/// `HostConnection`, the channel, and protobuf coding are all exercised. Debug builds only.
///
/// `FakeHost` is the bridge process: its tasks and event log outlive connections, like the real
/// bridge's `TaskHub` (S2). Each `FakeBridge` is one connection (one transport) to it.
public final class FakeBridge: BridgeTransport {
    /// S3: one scripted milestone. `todos` is the whole list right after it.
    public struct Step: Sendable {
        public var kind: Milestone.Kind
        public var text: String
        public var todos: [Todo]

        public init(_ kind: Milestone.Kind, _ text: String = "", todos: [Todo] = []) {
            self.kind = kind
            self.text = text
            self.todos = todos
        }
    }

    public struct Script: Sendable {
        public var reply: [String]
        public var chunkDelay: Duration
        /// Lets a test inspect the streamed prefix before the remaining chunks are delivered.
        public var afterFirstChunk: (@Sendable () async -> Void)?
        public var failWith: String?
        /// S3: milestones sent before the reply, `milestoneDelay` apart. When there are any, a
        /// closing FINISHED (or FAILED, with `failWith`) follows the reply, as the real bridge does.
        public var milestones: [Step]
        public var milestoneDelay: Duration
        /// T1: a task whose prompt contains this text stops after its first milestone (or before
        /// its reply, with no milestones) and stays running for the rest of the run.
        public var holdPrompt: String?
        /// S16: the reply streams after this many milestones (nil: after all of them).
        public var replyAfterMilestones: Int?
        /// S16: every task stays running after its reply and its milestones, until it is interrupted.
        public var holdAfterReply = false
        /// S16: the host advertises `interrupt.v1` and stops a task like the real bridge: an
        /// `InterruptAccepted`, then an INTERRUPTED milestone and `TaskEnded(INTERRUPTED)`.
        public var interruptible = false
        /// S18: a task whose prompt contains `ask.prompt` asks for `ask.approval` before its reply
        /// and waits until it is answered (here, or from elsewhere with `answerFromElsewhere`).
        public var ask: (prompt: String, approval: PendingApproval)?
        /// S19: a task whose prompt contains `prompt` runs `script` instead (its milestones, reply
        /// and end). Hold, ask and the host's capabilities still come from this script.
        public var variants: [Variant] = []

        public struct Variant: Sendable {
            public var prompt: String
            public var script: Script

            public init(prompt: String, script: Script) {
                self.prompt = prompt
                self.script = script
            }
        }

        func variant(for prompt: String) -> Script {
            variants.first { !$0.prompt.isEmpty && prompt.contains($0.prompt) }?.script ?? self
        }
        /// S17: transcript blocks, each sent just before reply chunk `beforeChunk` (0-based;
        /// `reply.count` or more: after the reply). The host sends them whatever its capabilities.
        public var blocks: [(beforeChunk: Int, block: Dshm_V1_TranscriptBlock)] = []
        /// D89: with a value, the host advertises `conversation.v1`. A follow-up on a completed task
        /// is accepted like the real bridge does it: `MessageAccepted`, a logged `UserMessage`, the
        /// task RUNNING again, this reply (its chunk seqs go on), and `TaskEnded(COMPLETED)`.
        public var followUpReply: [String]?
        /// D101: with `followUpReply`, the host also advertises `conversation.v2`, as the real bridge:
        /// a follow-up while the task runs waits (`QueuedMessage`); `EditQueue` steers or removes it.
        /// When the reply has streamed, steered messages go in (each a `UserMessage` and this reply),
        /// then each queued one runs as its own turn; the task ends after the last. A stop returns them.
        /// A follow-up after a stop continues the task.
        public var queuesFollowUps = false
        /// Agent questions (`questions.v1`): a task whose prompt contains `question.prompt` asks
        /// `question.items` before its reply and waits for the answer, as the real bridge's holder
        /// does. The answer (here, or from elsewhere with `answerQuestionFromElsewhere`) is checked
        /// like the bridge checks it, recorded in `questionAnswers`, and the reply streams.
        public var question: (prompt: String, items: [AgentQuestion.Item])?

        func questions(_ prompt: String) -> [AgentQuestion.Item]? {
            guard let question, !question.prompt.isEmpty, prompt.contains(question.prompt) else { return nil }
            return question.items
        }

        public init(
            reply: [String] = ["Hello", " from", " FakeBridge", ". ", "No DSH", " was", " involved."],
            chunkDelay: Duration = .milliseconds(120),
            failWith: String? = nil,
            milestones: [Step] = [],
            milestoneDelay: Duration = .milliseconds(120)
        ) {
            self.reply = reply
            self.chunkDelay = chunkDelay
            self.failWith = failWith
            self.milestones = milestones
            self.milestoneDelay = milestoneDelay
        }

        func holds(_ prompt: String) -> Bool {
            guard let holdPrompt, !holdPrompt.isEmpty else { return false }
            return prompt.contains(holdPrompt)
        }

        /// S16 · a coding task (`-DSHMFakeScenario coding`): five todos, three done and the fourth
        /// running ("3 / 5"); a long Markdown reply, so the transcript scrolls; then it keeps running
        /// until the user taps stop.
        public static func codingTask(delay: Duration = .milliseconds(300)) -> Script {
            let items = FakeBridge.codingTodoItems
            func list(done: Int) -> [Todo] {
                items.enumerated().map { i, content in
                    Todo(content: content, status: i < done ? .completed : i == done ? .inProgress : .pending)
                }
            }
            var script = Script(
                reply: FakeBridge.codingReply.split(separator: "\n", omittingEmptySubsequences: false).map { $0 + "\n" },
                chunkDelay: .milliseconds(40),
                milestones: [
                    Step(.started),
                    Step(.planned, todos: list(done: 0)),
                    Step(.todoDone, items[0], todos: list(done: 1)),
                    Step(.todoDone, items[1], todos: list(done: 2)),
                    Step(.todoDone, items[2], todos: list(done: 3)),
                ],
                milestoneDelay: delay)
            script.holdAfterReply = true
            script.interruptible = true
            // S28: a prompt with `tablesPrompt` gets a reply with a wide GFM table.
            script.variants = [.init(prompt: FakeBridge.tablesPrompt, script: Script(
                reply: FakeBridge.tablesReply.split(separator: "\n", omittingEmptySubsequences: false).map { $0 + "\n" },
                chunkDelay: .milliseconds(40)))]
            return script
        }

        func asks(_ prompt: String) -> PendingApproval? {
            guard let ask, !ask.prompt.isEmpty, prompt.contains(ask.prompt) else { return nil }
            return ask.approval
        }

        /// A three-todo task that ticks its todos off one by one (S3 demo, `-DSHMFakeMilestones YES`).
        public static func threeTodos(delay: Duration = .milliseconds(1500)) -> Script {
            let items = FakeBridge.threeTodoItems
            func list(done: Int, active: Int?) -> [Todo] {
                items.enumerated().map { i, content in
                    Todo(content: content, status: i < done ? .completed : i == active ? .inProgress : .pending)
                }
            }
            return Script(
                reply: ["All three steps", " are done."],
                chunkDelay: .milliseconds(120),
                milestones: [
                    Step(.started),
                    Step(.planned, todos: list(done: 0, active: 0)),
                    Step(.todoStarted, items[0], todos: list(done: 0, active: 0)),
                    Step(.todoDone, items[0], todos: list(done: 1, active: 1)),
                    Step(.todoStarted, items[1], todos: list(done: 1, active: 1)),
                    Step(.todoDone, items[1], todos: list(done: 2, active: 2)),
                    Step(.todoStarted, items[2], todos: list(done: 2, active: 2)),
                    Step(.todoDone, items[2], todos: list(done: 3, active: nil)),
                ],
                milestoneDelay: delay)
        }
    }

    /// S15: a task that waits on an approval when the host starts, as if DSH had paused it there.
    public struct PendingApproval: Sendable {
        public var title: String
        public var tool: String
        public var arguments: String
        public var reason: String

        public init(title: String, tool: String, arguments: String, reason: String) {
            self.title = title
            self.tool = tool
            self.arguments = arguments
            self.reason = reason
        }
    }

    /// S20: the host advertises `models.v1` and `workspaces.v1` and answers their requests.
    /// A model in `goneAfterUse` leaves the catalog once a task uses it (the scenario's stand-in
    /// for a provider key that expired on the host).
    public struct Pickers: Sendable {
        public var catalog: ModelCatalog
        public var workspaces: Dshm_V1_WorkspaceList
        public var goneAfterUse: Set<String>

        public init(catalog: ModelCatalog, workspaces: Dshm_V1_WorkspaceList, goneAfterUse: Set<String> = []) {
            self.catalog = catalog
            self.workspaces = workspaces
            self.goneAfterUse = goneAfterUse
        }
    }

    public static let defaultReply = Script().reply.joined()
    public static let codingTodoItems = ["Find the failing test", "Reproduce it", "Fix the order of replayed events",
                                         "Run the tests", "Open a pull request"]
    /// S16: long enough to scroll on any iPhone; ends with a line a UI test can look for.
    public static let codingReply = """
        The failing test is `TaskListStoreTests/resume`: after a reconnect, replayed events were put **after** the new ones.

        ## What I changed

        - `TaskListStore.apply` now sorts a replay by `host_seq` before it merges.
        - Live events wait until the replay is in.
        - The cache keeps the highest `host_seq` it has seen.

        ```swift
        let ordered = replay.sorted { $0.hostSeq < $1.hostSeq }
        for event in ordered where event.hostSeq > lastSeq {
            apply(event)
        }
        ```

        ## Why it failed

        The bridge sends the replay first, but the app read the live socket in parallel. A fast live event could land first, and the replay then wrote an older state over it.

        ```diff
        - for event in replay { apply(event) }
        + for event in replay.sorted(by: \\.hostSeq) where event.hostSeq > lastSeq { apply(event) }
        ```

        ## How I checked it

        I added `resumeFillsGapInOrder`. It drops the connection after two events, sends three live events, and then lets the replay in. Before the fix the cache ended on the second event; now it ends on the fifth.

        | Case | Before | After |
        | --- | --- | --- |
        | replay, then live | ok | ok |
        | live, then replay | wrong order | ok |

        The other tests in the suite still pass. The change touches only the merge, so the list and the transcript code stay the same.

        ## Next

        1. Run the whole suite on the simulator.
        2. Open a pull request with the fix and the new test.

        Running the tests now.
        """
    /// S28: the coding scenario's prompt for a reply with a wide table (as DSH answered the user's
    /// "demo directory" task): alignment, inline code and bold in cells, an escaped pipe, long cells.
    public static let tablesPrompt = "Compare the test runs in a table"
    public static let tablesReply = """
        I ran the tests in `demo/` three ways:

        | Runner | Command | Result | Time (s) | Notes |
        |:--- | :---: | ---: | ---: | --- |
        | pytest | `pytest -q demo` | **3 passed** | 0.41 | The default runner. It finds `test_*.py` files and prints one dot per test, then the summary line. |
        | unittest | `python -m unittest` | 3 passed | 0.12 | Needs the `TestCase` classes; `a \\| b` is a literal pipe. |
        | doctest | `python -m doctest add.py` | 1 failed | 0.05 | The example in the docstring expects `5`, but `add(2, 2)` returns `4`. |

        Only doctest fails. Done.
        """
    public static let threeTodoItems = ["Read the project layout", "Write the summary", "Check the summary against the code"]

    /// A fresh host behind every connection this factory opens (T0 behaviour, plus S2's log).
    public static func factory(script: Script = Script()) -> BridgeTransportFactory {
        FakeHost(script: script).factory
    }

    private struct State {
        var inbox: [Data] = []
        var waiter: CheckedContinuation<Data, any Error>?
        var closed = false
        /// S29: the WebSocket close code the bridge sent (4003 device unknown), if any.
        var closeCode: Int?

        var closedError: any Error {
            if let closeCode { BridgeTransportError.closed(code: closeCode, reason: "device revoked") } else { HostConnectionError.disconnected }
        }
    }

    private let host: FakeHost
    private let state = Mutex(State())
    let id = UUID()

    init(host: FakeHost) {
        self.host = host
    }

    // MARK: BridgeTransport (the app's side of the pipe)

    public func send(_ message: Data) async throws {
        if let error = state.withLock({ $0.closed ? $0.closedError : nil }) { throw error }
        let frame = try Dshm_V1_Frame(serializedBytes: message)
        guard case .request(let request)? = frame.kind else { return }
        host.handle(request, from: self)
    }

    public func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            state.withLock { s in
                if !s.inbox.isEmpty {
                    continuation.resume(returning: s.inbox.removeFirst())
                } else if s.closed {
                    continuation.resume(throwing: s.closedError)
                } else {
                    s.waiter = continuation
                }
            }
        }
    }

    public func close() async {
        drop()
        host.forget(self)
    }

    // MARK: Bridge side

    /// The bridge closes this connection (it went away, or the network dropped). S29: with a
    /// `code`, it closes with that WebSocket close code, like the bridge's 4003 after a revoke.
    func drop(code: Int? = nil) {
        state.withLock { s in
            guard !s.closed else { return }
            s.closed = true
            s.closeCode = code
            s.waiter?.resume(throwing: s.closedError)
            s.waiter = nil
        }
    }

    func deliver(_ frame: Dshm_V1_Frame) {
        guard let bytes = try? frame.serializedData() else { return }
        state.withLock { s in
            guard !s.closed else { return }
            if let waiter = s.waiter {
                s.waiter = nil
                waiter.resume(returning: bytes)
            } else {
                s.inbox.append(bytes)
            }
        }
    }
}

public enum FakeHostError: Error, Equatable {
    case unreachable
}

/// The fake bridge process: tasks, per-host event log, ListTasks and Resume, like
/// `bridge/src/s2/`. Tests can make it unreachable, drop connections, or restart it.
public final class FakeHost: Sendable {
    public let hostName: String
    private let incompatibleDsh: (installed: String, supported: String)?
    /// Task ids are unique across FakeHost instances (like DSH session ids), so a task cached by
    /// an earlier app launch never collides with a new one that happens to be numbered the same.
    private let taskIDPrefix = "fake-\(UUID().uuidString.prefix(8).lowercased())-task"
    private let script: FakeBridge.Script
    /// Capabilities this host adds to T0–S3's (for example S14's `drawer.v1`).
    private let extraCapabilities: [String]
    /// S15: with any, the host advertises `approvals.v1` and answers `AnswerApproval`.
    private let approvals: [FakeBridge.PendingApproval]
    /// S20: with a value, the host answers model and workspace requests.
    private let pickers: FakeBridge.Pickers?
    /// S15, S18: seeded approvals or a script that asks for one.
    private var answersApprovals: Bool { !approvals.isEmpty || script.ask != nil }
    /// S27: with any, the host advertises `sessions.v1` and answers `ReadSession` with these
    /// journals (task id → its latest page), like a DSH session made on the Web.
    private let journals: [String: Dshm_V1_SessionPage]

    private struct Connection {
        let bridge: FakeBridge
        var resumed = false
        var ownTasks: Set<String> = []
        var helloDone = false
        /// D95: this connection's uploads, like bridge/src/attachments/staging.ts.
        var uploads: [String: FakeUpload] = [:]
    }

    private struct FakeUpload {
        var begin: Dshm_V1_UploadBegin
        var data = Data()
        var parts = 0
        var staged = false
    }

    private struct State {
        var logID = UUID().uuidString
        var log: [Dshm_V1_Event] = []
        var tasks: [Dshm_V1_TaskSummary] = []
        var connections: [UUID: Connection] = [:]
        var reachable = true
        var prompts: [String] = []
        /// D95: the files each CreateTask named, in order (one entry per task).
        var attachments: [[(begin: Dshm_V1_UploadBegin, data: Data)]] = []
        var uploadFrameSizes: [Int] = []
        var tasksCreated = 0
        var incarnation = 0
        /// S20: models that left the catalog (`Pickers.goneAfterUse`).
        var goneModels: Set<String> = []
        /// S21: `devices.v1` records; `revoked` once this phone's device lost its access.
        var devices: FakeDevices?
        var revoked = false
        /// S29: every attempt to open a connection, also the refused ones.
        var connectAttempts = 0
        /// S16: interrupted tasks; their stream stops.
        var stopped: Set<String> = []
        /// D101: per task, how many turns a follow-up after a stop started; an older turn's stream stops.
        var turns: [String: Int] = [:]
        /// D89: each task's last chunk seq, so a follow-up turn goes on from it.
        var chunkSeqs: [String: UInt64] = [:]
        /// D89: every follow-up message, in order.
        var followUps: [String] = []
        /// D107: the files each follow-up named, in order (one entry per follow-up).
        var followUpAttachments: [[(begin: Dshm_V1_UploadBegin, data: Data)]] = []
        /// D107: how many UploadBegin requests arrived (a refusal before the upload sends none).
        var uploadBegins = 0
        /// D101: per task, the follow-ups that wait, in order.
        var queued: [String: [Dshm_V1_QueuedMessage]] = [:]
        /// D101: every queue edit, as "steer <text>" or "remove <text>".
        var queueEdits: [String] = []
        /// Every accepted answer to an agent question, as DSH got it.
        var questionAnswers: [Dshm_V1_AnswerQuestion] = []
        /// S16: each task's latest milestone seq and todos, for the INTERRUPTED milestone.
        var lastMilestones: [String: (seq: UInt64, todos: [Todo])] = [:]
    }

    private let state = Mutex(State())

    /// - Parameter seed: sessions the host already has, as if other clients made them (S14).
    public init(script: FakeBridge.Script = .init(), hostName: String = "FakeBridge Mac", reachable: Bool = true,
                incompatibleDsh: (installed: String, supported: String)? = nil,
                seed: [Dshm_V1_TaskSummary] = [], extraCapabilities: [String] = [],
                approvals: [FakeBridge.PendingApproval] = [], pickers: FakeBridge.Pickers? = nil,
                devices: FakeDevices? = nil, journals: [String: Dshm_V1_SessionPage] = [:]) {
        self.pickers = pickers
        self.journals = journals
        self.incompatibleDsh = incompatibleDsh
        self.script = script
        self.hostName = hostName
        self.extraCapabilities = extraCapabilities
        self.approvals = approvals
        state.withLock { s in
            s.reachable = reachable
            s.devices = devices
            for summary in seed {
                s.tasks.append(summary)
                Self.upserted(summary, in: &s)
            }
        }
        self.seed(approvals)
    }

    /// S15: each approval is a waiting task. Its ids depend only on the host name and the
    /// position, like a DSH session that outlives the app: a later launch finds the same task.
    private func seed(_ approvals: [FakeBridge.PendingApproval]) {
        let slug = hostName.lowercased().filter { $0.isLetter || $0.isNumber }
        state.withLock { s in
            for (i, approval) in approvals.enumerated() {
                var pending = Dshm_V1_ApprovalPending()
                pending.taskID = "fake-seed-\(slug)-\(i + 1)"
                pending.id = "\(pending.taskID)-approval"
                pending.callID = "\(pending.taskID)-call"
                pending.tool = approval.tool
                pending.argumentsJson = approval.arguments
                pending.reason = approval.reason
                var summary = Dshm_V1_TaskSummary()
                summary.taskID = pending.taskID
                summary.title = approval.title
                summary.state = .waitingOnUser
                summary.createdAtMs = Self.nowMs() - Int64(60_000 * (approvals.count - i))
                summary.updatedAtMs = summary.createdAtMs
                summary.pendingApprovals = [pending]
                s.tasks.append(summary)
                Self.upserted(summary, in: &s)
                var event = Dshm_V1_Event()
                event.approvalPending = pending
                Self.append(event, taskID: pending.taskID, in: &s)
            }
        }
    }

    /// Opens a connection to this host; throws while it's unreachable.
    public var factory: BridgeTransportFactory {
        { [self] _ in try self.connection() }
    }

    public var prompts: [String] { state.withLock { $0.prompts } }
    /// D89: the follow-up messages this host accepted, in order.
    public var followUps: [String] { state.withLock { $0.followUps } }
    /// Every accepted answer to an agent question, in order: what reached DSH.
    public var questionAnswers: [Dshm_V1_AnswerQuestion] { state.withLock { $0.questionAnswers } }
    /// D101: the queue edits this host made, in order ("steer <text>", "remove <text>").
    public var queueEdits: [String] { state.withLock { $0.queueEdits } }
    /// D95: per created task, the staged files it named: (media type, name, bytes).
    public var attachments: [[(mediaType: String, name: String, data: Data)]] {
        state.withLock { $0.attachments.map { $0.map { (mediaType: $0.begin.mediaType, name: $0.begin.name, data: $0.data) } } }
    }
    /// D107: per follow-up, the staged files it named: (media type, name, bytes).
    public var followUpAttachments: [[(mediaType: String, name: String, data: Data)]] {
        state.withLock { $0.followUpAttachments.map { $0.map { (mediaType: $0.begin.mediaType, name: $0.begin.name, data: $0.data) } } }
    }
    /// D107: how many uploads began on this host.
    public var uploadBegins: Int { state.withLock { $0.uploadBegins } }
    /// D95: the encoded size of every UploadChunk request frame received, in order.
    public var uploadFrameSizes: [Int] { state.withLock { $0.uploadFrameSizes } }
    private var takesAttachments: Bool { extraCapabilities.contains(DSHProtocolInfo.attachmentsCapability) }
    public var logID: String { state.withLock { $0.logID } }
    public var head: UInt64 { state.withLock { UInt64($0.log.count) } }
    public var connectionCount: Int { state.withLock { $0.connections.count } }
    /// S29: connection attempts so far (a refused or unreachable attempt counts too).
    public var connectAttempts: Int { state.withLock { $0.connectAttempts } }

    /// S29: another client (the web UI, another phone) revokes this phone's device, as with
    /// `RevokeDevice` from there: the host records it, closes this device's connections with
    /// 4003 (device unknown) and refuses it from now on. The phone gets no response.
    public func revokeThisDevice() {
        let dropped = state.withLock { s -> [FakeBridge] in
            if var devices = s.devices {
                _ = devices.answer(.revokeDevice(.with { $0.deviceID = devices.current }))
                s.devices = devices
            }
            s.revoked = true
            defer { s.connections = [:] }
            return s.connections.values.map(\.bridge)
        }
        for bridge in dropped { bridge.drop(code: PairingWire.CloseCode.deviceUnknown.rawValue) }
    }

    /// Unreachable: new connections fail and live ones drop (the Mac slept, Wi-Fi went away).
    public func setReachable(_ reachable: Bool) {
        let dropped = state.withLock { s -> [FakeBridge] in
            s.reachable = reachable
            guard !reachable else { return [] }
            defer { s.connections = [:] }
            return s.connections.values.map(\.bridge)
        }
        for bridge in dropped { bridge.drop() }
    }

    /// Drops every live connection; the host and its tasks stay.
    public func dropConnections() {
        let dropped = state.withLock { s -> [FakeBridge] in
            defer { s.connections = [:] }
            return s.connections.values.map(\.bridge)
        }
        for bridge in dropped { bridge.drop() }
    }

    /// The bridge process restarts: new log id, no tasks, every connection dropped.
    public func restart() {
        dropConnections()
        state.withLock { s in
            s.logID = UUID().uuidString
            s.log = []
            s.tasks = []
            s.incarnation += 1
        }
    }

    // MARK: - Internals

    /// Opens one connection (a `FakeBridge`) to this host; throws while it's unreachable.
    func connection() throws -> FakeBridge {
        let bridge = FakeBridge(host: self)
        try state.withLock { s in
            s.connectAttempts += 1
            guard s.reachable else { throw FakeHostError.unreachable }
            // S29: like the bridge's handshake (bridge/src/pairing/handshake.ts), a revoked
            // device is refused with close 4003 device unknown.
            guard !s.revoked else {
                throw BridgeTransportError.closed(code: PairingWire.CloseCode.deviceUnknown.rawValue, reason: "device not paired")
            }
            s.connections[bridge.id] = Connection(bridge: bridge)
        }
        return bridge
    }

    func forget(_ bridge: FakeBridge) {
        _ = state.withLock { $0.connections.removeValue(forKey: bridge.id) }
    }

    func handle(_ request: Dshm_V1_Request, from bridge: FakeBridge) {
        state.withLock { s in
            guard var conn = s.connections[bridge.id] else { return }
            defer { s.connections[bridge.id] = conn }
            let id = request.id
            switch request.body {
            case .hello?:
                conn.helloDone = true
                var hello = Dshm_V1_Hello()
                hello.protocolVersion = DSHProtocolInfo.version
                if let incompatibleDsh {
                    hello.dshVersion = incompatibleDsh.installed
                    hello.supportedDshRange = incompatibleDsh.supported
                    hello.requiresBridgeUpdate = true
                } else {
                    hello.capabilities = [DSHProtocolInfo.tasksCapability, DSHProtocolInfo.milestonesCapability, DSHProtocolInfo.resumeCapability]
                    if script.interruptible { hello.capabilities.append(DSHProtocolInfo.interruptCapability) }
                    if answersApprovals { hello.capabilities.append(DSHProtocolInfo.approvalsCapability) }
                    hello.capabilities += extraCapabilities
                    if pickers != nil { hello.capabilities += ["models.v1", "workspaces.v1"] }
                    if s.devices != nil { hello.capabilities.append(FakeDevices.capability) }
                    if !journals.isEmpty { hello.capabilities.append("sessions.v1") }
                    if script.followUpReply != nil { hello.capabilities.append(DSHProtocolInfo.conversationCapability) }
                    if script.followUpReply != nil && script.queuesFollowUps { hello.capabilities.append(DSHProtocolInfo.queueCapability) }
                    if script.question != nil { hello.capabilities.append(DSHProtocolInfo.questionsCapability) }
                }
                bridge.deliver(Self.response(id, .hello(hello)))
            case .createTask(let create)? where !create.uploadIds.isEmpty && (!takesAttachments
                    || Set(create.uploadIds).count != create.uploadIds.count
                    || !create.uploadIds.allSatisfy({ conn.uploads[$0]?.staged == true })):
                bridge.deliver(Self.uploadError(id, "upload/unknown", "The attachment is not on the host. Send it again."))
            case .createTask(let create)?:
                s.prompts.append(create.prompt)
                if !create.uploadIds.isEmpty {
                    s.attachments.append(create.uploadIds.map { uploadID in
                        let upload = conn.uploads.removeValue(forKey: uploadID)!
                        return (begin: upload.begin, data: upload.data)
                    })
                }
                s.tasksCreated += 1
                let taskID = "\(taskIDPrefix)-\(s.tasksCreated)"
                conn.ownTasks.insert(taskID)
                var created = Dshm_V1_TaskCreated()
                created.taskID = taskID
                bridge.deliver(Self.response(id, .taskCreated(created)))
                var summary = Dshm_V1_TaskSummary()
                summary.taskID = taskID
                summary.title = create.prompt
                summary.state = .running
                summary.createdAtMs = Self.nowMs()
                summary.updatedAtMs = summary.createdAtMs
                if let pickers {
                    let selection = create.hasModelSelection ? create.modelSelection : pickers.catalog.defaultSelection
                    summary.modelSelection = selection
                    if pickers.goneAfterUse.contains(selection.model) { s.goneModels.insert(selection.model) }
                    if create.hasWorkspace { summary.workspace = create.workspace }
                }
                s.tasks.append(summary)
                s.connections[bridge.id] = conn
                Self.upserted(summary, in: &s)
                let incarnation = s.incarnation
                let hold = script.holds(create.prompt)
                let ask = script.asks(create.prompt)
                let question = script.questions(create.prompt)
                let variant = script.variant(for: create.prompt) // S19
                Task { await self.stream(taskID: taskID, incarnation: incarnation, hold: hold, ask: ask, question: question, using: variant) }
            case .uploadBegin(let begin)? where takesAttachments:
                // D107: any media type; the four image types enter as images, the rest as files.
                s.uploadBegins += 1
                if conn.uploads[begin.uploadID] != nil || begin.uploadID.isEmpty || begin.sha256.count != 32 || begin.size == 0 {
                    bridge.deliver(Self.uploadError(id, "upload/invalid", "Bad upload."))
                } else if conn.uploads.count >= Attachments.maxCount {
                    bridge.deliver(Self.uploadError(id, "upload/too-many", "Send at most \(Attachments.maxCount) attachments at a time."))
                } else if begin.size > UInt64(Attachments.maxBytes) {
                    bridge.deliver(Self.uploadError(id, "upload/too-large", "The file is too large."))
                } else {
                    conn.uploads[begin.uploadID] = FakeUpload(begin: begin)
                    bridge.deliver(Self.response(id, .uploadAck(.with { $0.uploadID = begin.uploadID })))
                }
            case .uploadChunk(let chunk)? where takesAttachments:
                s.uploadFrameSizes.append((try? Self.frame(request).serializedData().count) ?? 0)
                guard var upload = conn.uploads[chunk.uploadID], !upload.staged else {
                    bridge.deliver(Self.uploadError(id, "upload/unknown", "No upload with this id."))
                    return
                }
                guard chunk.index == upload.parts, !chunk.data.isEmpty, chunk.data.count <= Attachments.partSize,
                      UInt64(upload.data.count + chunk.data.count) <= upload.begin.size else {
                    conn.uploads[chunk.uploadID] = nil
                    bridge.deliver(Self.uploadError(id, "upload/missing-part", "Expected part \(upload.parts), got part \(chunk.index)."))
                    return
                }
                upload.data.append(chunk.data)
                upload.parts += 1
                conn.uploads[chunk.uploadID] = upload
                bridge.deliver(Self.response(id, .uploadAck(.with { $0.uploadID = chunk.uploadID; $0.received = UInt64(upload.data.count) })))
            case .uploadEnd(let end)? where takesAttachments:
                guard var upload = conn.uploads[end.uploadID], !upload.staged else {
                    bridge.deliver(Self.uploadError(id, "upload/unknown", "No upload with this id."))
                    return
                }
                if UInt64(upload.data.count) != upload.begin.size {
                    conn.uploads[end.uploadID] = nil
                    bridge.deliver(Self.uploadError(id, "upload/missing-part", "Received \(upload.data.count) of \(upload.begin.size) bytes."))
                } else if Attachments.sha256(upload.data) != upload.begin.sha256 {
                    conn.uploads[end.uploadID] = nil
                    bridge.deliver(Self.uploadError(id, "upload/hash-mismatch", "The file does not match its SHA-256."))
                } else {
                    upload.staged = true
                    conn.uploads[end.uploadID] = upload
                    bridge.deliver(Self.response(id, .uploadStaged(.with { $0.uploadID = end.uploadID })))
                }
            case .listTasks?:
                var list = Dshm_V1_TaskList()
                list.tasks = s.tasks.reversed()
                list.logID = s.logID
                list.hostName = hostName
                bridge.deliver(Self.response(id, .taskList(list)))
            case .resume(let resume)?:
                let head = UInt64(s.log.count)
                let continuable = resume.logID == s.logID && resume.afterSeq <= head
                if !continuable {
                    var reset = Dshm_V1_LogReset()
                    reset.logID = s.logID
                    var event = Dshm_V1_Event()
                    event.logReset = reset
                    bridge.deliver(Self.frame(event))
                }
                let replay = continuable ? Array(s.log[Int(resume.afterSeq)...]) : s.log
                for event in replay { bridge.deliver(Self.frame(event)) }
                var resumed = Dshm_V1_Resumed()
                resumed.logID = s.logID
                resumed.headSeq = head
                resumed.hostName = hostName
                resumed.reset = !continuable
                resumed.replayed = UInt64(replay.count)
                bridge.deliver(Self.response(id, .resumed(resumed)))
                conn.resumed = true
            case .interrupt(let interrupt)? where script.interruptible:
                guard let at = s.tasks.firstIndex(where: { $0.taskID == interrupt.taskID }), s.tasks[at].state == .running else {
                    var error = Dshm_V1_Error()
                    error.code = "task/not-running"
                    error.message = "The task is not running."
                    bridge.deliver(Self.response(id, .error(error)))
                    return
                }
                bridge.deliver(Self.response(id, .interruptAccepted(Dshm_V1_InterruptAccepted())))
                s.stopped.insert(interrupt.taskID)
                let last = s.lastMilestones[interrupt.taskID] ?? (0, [])
                if !script.milestones.isEmpty {
                    var event = Dshm_V1_Event()
                    event.milestoneAdded = Self.wire(taskID: interrupt.taskID, seq: last.seq + 1,
                                                     FakeBridge.Step(.interrupted, todos: last.todos))
                    Self.append(event, taskID: interrupt.taskID, in: &s)
                }
                // D101: what still waits does not run after a stop; its text goes back to the composer.
                for var message in s.queued.removeValue(forKey: interrupt.taskID) ?? [] {
                    message.placement = .returned
                    var event = Dshm_V1_Event()
                    event.queuedMessage = message
                    Self.append(event, taskID: interrupt.taskID, in: &s)
                }
                s.tasks[at].state = .interrupted
                s.tasks[at].updatedAtMs = Self.nowMs()
                Self.upserted(s.tasks[at], in: &s)
                var ended = Dshm_V1_TaskEnded()
                ended.taskID = interrupt.taskID
                ended.status = .interrupted
                var event = Dshm_V1_Event()
                event.taskEnded = ended
                Self.append(event, taskID: interrupt.taskID, in: &s)
            case .sendMessage(let message)? where script.followUpReply != nil:
                let at = s.tasks.firstIndex { $0.taskID == message.taskID }
                let state = at.map { s.tasks[$0].state }
                // D101: while the task runs the message waits; after a stop it continues the task.
                let running = script.queuesFollowUps && (state == .running || state == .waitingOnUser)
                let idle = state == .completed || (script.queuesFollowUps && state == .interrupted)
                guard let at, running || idle, !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    var error = Dshm_V1_Error()
                    error.code = "message/refused"
                    error.message = "Send a follow-up when the task is done."
                    bridge.deliver(Self.response(id, .error(error)))
                    return
                }
                // D107: files with a follow-up, used up by it, like CreateTask's; not into a running task's queue.
                if running && !message.uploadIds.isEmpty {
                    var error = Dshm_V1_Error()
                    error.code = "message/refused"
                    error.message = "Attach files when the task is done."
                    bridge.deliver(Self.response(id, .error(error)))
                    return
                }
                if !message.uploadIds.isEmpty && (!takesAttachments || Set(message.uploadIds).count != message.uploadIds.count
                    || !message.uploadIds.allSatisfy({ conn.uploads[$0]?.staged == true })) {
                    bridge.deliver(Self.uploadError(id, "upload/unknown", "The attachment is not on the host. Send it again."))
                    return
                }
                let files = message.uploadIds.map { uploadID in
                    let upload = conn.uploads.removeValue(forKey: uploadID)!
                    return (begin: upload.begin, data: upload.data)
                }
                s.followUpAttachments.append(files)
                s.followUps.append(message.text)
                let messageID = "message-\(s.followUps.count)"
                var accepted = Dshm_V1_MessageAccepted()
                accepted.taskID = message.taskID
                accepted.messageID = messageID
                if !conn.resumed { conn.ownTasks.insert(message.taskID) }
                s.connections[bridge.id] = conn
                bridge.deliver(Self.response(id, .messageAccepted(accepted)))
                if running {
                    var queued = Dshm_V1_QueuedMessage()
                    queued.taskID = message.taskID
                    queued.messageID = messageID
                    queued.text = message.text
                    queued.timeMs = Self.nowMs()
                    queued.placement = message.mode == .queue ? .queued : .steering
                    s.queued[message.taskID, default: []].append(queued)
                    var event = Dshm_V1_Event()
                    event.queuedMessage = queued
                    Self.append(event, taskID: message.taskID, in: &s)
                    return
                }
                s.stopped.remove(message.taskID)
                s.turns[message.taskID, default: 0] += 1 // the stream of the stopped turn stays stopped
                var user = Dshm_V1_UserMessage()
                user.taskID = message.taskID
                user.messageID = messageID
                user.text = message.text
                user.timeMs = Self.nowMs()
                user.attachments = files.map { file in
                    .with {
                        $0.kind = Attachments.isImage(file.begin.mediaType) ? .image : .file
                        $0.name = file.begin.name
                        $0.size = UInt64(file.data.count)
                        $0.mediaType = file.begin.mediaType
                    }
                }
                var event = Dshm_V1_Event()
                event.userMessage = user
                Self.append(event, taskID: message.taskID, in: &s)
                s.tasks[at].state = .running
                s.tasks[at].updatedAtMs = Self.nowMs()
                s.tasks[at].turnStartedAtMs = s.tasks[at].updatedAtMs
                Self.upserted(s.tasks[at], in: &s)
                let incarnation = s.incarnation
                var turn = script
                turn.reply = script.followUpReply ?? []
                turn.milestones = []
                turn.blocks = []
                turn.variants = []
                Task { await self.stream(taskID: message.taskID, incarnation: incarnation, using: turn) }
            case .editQueue(let edit)? where script.followUpReply != nil && script.queuesFollowUps:
                guard var list = s.queued[edit.taskID], let i = list.firstIndex(where: { $0.messageID == edit.messageID }),
                      edit.action == .steer || edit.action == .remove else {
                    var error = Dshm_V1_Error()
                    error.code = "queue/refused"
                    error.message = "This message is no longer waiting."
                    bridge.deliver(Self.response(id, .error(error)))
                    return
                }
                var message = list[i]
                if edit.action == .remove {
                    list.remove(at: i)
                    message.placement = .removed
                    s.queueEdits.append("remove \(message.text)")
                } else {
                    message.placement = .steering
                    list[i] = message
                    s.queueEdits.append("steer \(message.text)")
                }
                s.queued[edit.taskID] = list.isEmpty ? nil : list
                var edited = Dshm_V1_QueueEdited()
                edited.taskID = edit.taskID
                edited.messageID = edit.messageID
                edited.placement = message.placement
                bridge.deliver(Self.response(id, .queueEdited(edited)))
                var event = Dshm_V1_Event()
                event.queuedMessage = message
                Self.append(event, taskID: edit.taskID, in: &s)
            case .answerApproval(let answer)? where answersApprovals:
                answerApproval(answer, requestID: id, bridge: bridge, in: &s)
            case .answerQuestion(let answer)? where script.question != nil:
                answerQuestion(answer, requestID: id, bridge: bridge, in: &s)
            case .getModelCatalog? where pickers != nil:
                bridge.deliver(Self.response(id, .modelCatalog(Self.catalog(pickers!, gone: s.goneModels))))
            case .selectModel(let select)? where pickers != nil:
                selectModel(select, requestID: id, bridge: bridge, in: &s)
            case .listWorkspaces? where pickers != nil:
                bridge.deliver(Self.response(id, .workspaceList(pickers!.workspaces)))
            case .readSession(let read)? where journals[read.taskID] != nil:
                bridge.deliver(Self.response(id, .sessionPage(journals[read.taskID]!)))
            case let body? where s.devices != nil && FakeDevices.handles(body):
                guard let (answer, revokedCurrent) = s.devices?.answer(body) else { break }
                bridge.deliver(Self.response(id, answer))
                if revokedCurrent {
                    // Like bridge/src/server.ts: the response first, then every socket of this
                    // device closes with 4003 (device unknown), and new ones are refused.
                    s.revoked = true
                    for conn in s.connections.values { conn.bridge.drop(code: PairingWire.CloseCode.deviceUnknown.rawValue) }
                }
            case .answerApproval?, .answerQuestion?, .interrupt?, .sendMessage?, .editQueue?, .getModelCatalog?, .selectModel?, .listWorkspaces?, .listDevices?, .listAudit?, .revokeDevice?, .readSession?,
                 .uploadBegin?, .uploadChunk?, .uploadEnd?:
                var error = Dshm_V1_Error()
                error.code = "request/unsupported"
                error.message = "This test host does not advertise this capability."
                bridge.deliver(Self.response(id, .error(error)))
            case nil:
                break
            }
        }
    }

    /// S20: the catalog without the models that left it.
    private static func catalog(_ pickers: FakeBridge.Pickers, gone: Set<String>) -> ModelCatalog {
        var catalog = pickers.catalog
        for i in catalog.groups.indices { catalog.groups[i].models.removeAll { gone.contains($0.id) } }
        return catalog
    }

    /// S20: a running task switches model; a model that is not in the catalog is refused.
    private func selectModel(_ select: Dshm_V1_SelectModel, requestID: UInt64, bridge: FakeBridge, in s: inout State) {
        guard let pickers, Self.catalog(pickers, gone: s.goneModels).entry(for: select.selection) != nil,
              let at = s.tasks.firstIndex(where: { $0.taskID == select.taskID }) else {
            var error = Dshm_V1_Error()
            error.code = "model/unavailable"
            error.message = "\(select.selection.model) is not available on \(hostName)."
            bridge.deliver(Self.response(requestID, .error(error)))
            return
        }
        s.tasks[at].modelSelection = select.selection
        s.tasks[at].updatedAtMs = Self.nowMs()
        var selected = Dshm_V1_ModelSelected()
        selected.taskID = select.taskID
        selected.selection = select.selection
        bridge.deliver(Self.response(requestID, .modelSelected(selected)))
        Self.upserted(s.tasks[at], in: &s)
    }

    /// S15: the answer resolves the approval, and the task goes on to its reply.
    private func answerApproval(_ answer: Dshm_V1_AnswerApproval, requestID: UInt64, bridge: FakeBridge, in s: inout State) {
        guard let at = s.tasks.firstIndex(where: { $0.pendingApprovals.contains { $0.id == answer.id } }) else {
            var error = Dshm_V1_Error()
            error.code = "approval/unknown"
            error.message = "No pending approval has this id."
            bridge.deliver(Self.response(requestID, .error(error)))
            return
        }
        let resolved = resolve(answer.id, at: at, allow: answer.decision == .allowOnce, in: &s)
        bridge.deliver(Self.response(requestID, .approvalResolved(resolved)))
    }

    /// Checks an answer as the bridge's `QuestionHolder` does; a valid one resolves the question.
    private func answerQuestion(_ answer: Dshm_V1_AnswerQuestion, requestID: UInt64, bridge: FakeBridge, in s: inout State) {
        func refuse(_ code: String, _ message: String) {
            var error = Dshm_V1_Error()
            error.code = code
            error.message = message
            bridge.deliver(Self.response(requestID, .error(error)))
        }
        guard let at = s.tasks.firstIndex(where: { $0.pendingQuestions.contains { $0.id == answer.id } }),
              let pending = s.tasks[at].pendingQuestions.first(where: { $0.id == answer.id }) else {
            return refuse("question/refused", "This question has already closed.")
        }
        guard answer.answers.count == pending.questions.count else { return refuse("question/refused", "Answer every question.") }
        for q in pending.questions {
            guard let a = answer.answers.first(where: { $0.questionID == q.id }) else { return refuse("question/refused", "Answer every question.") }
            let typed = a.custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1
            if a.selected.count + typed == 0 { return refuse("question/refused", "Answer every question.") }
            if !q.multiSelect && a.selected.count + typed != 1 { return refuse("question/refused", "Choose one option, or type an answer.") }
            if a.selected.contains(where: { label in !q.options.contains { $0.label == label } }) {
                return refuse("question/refused", "Choose one of the offered options.")
            }
        }
        let resolved = resolveQuestion(answer, at: at, outcome: .answered, in: &s)
        bridge.deliver(Self.response(requestID, .questionResolved(resolved)))
    }

    /// Another client (DSH Web) answers every pending question of this host with these labels,
    /// by question id. The phone gets only the `QuestionResolved` event, as from the real bridge.
    public func answerQuestionFromElsewhere(_ selected: [String: [String]]) {
        state.withLock { s in
            for at in s.tasks.indices {
                for pending in s.tasks[at].pendingQuestions {
                    var answer = Dshm_V1_AnswerQuestion()
                    answer.id = pending.id
                    answer.answers = pending.questions.map { q in
                        var a = Dshm_V1_QuestionAnswer()
                        a.questionID = q.id
                        a.selected = selected[q.id] ?? []
                        return a
                    }
                    _ = resolveQuestion(answer, at: at, outcome: .answeredElsewhere, in: &s)
                }
            }
        }
    }

    /// Logs the resolution, records what DSH got, and the task goes on to its reply.
    private func resolveQuestion(_ answer: Dshm_V1_AnswerQuestion, at: Int, outcome: Dshm_V1_QuestionOutcome,
                                 in s: inout State) -> Dshm_V1_QuestionResolved {
        let taskID = s.tasks[at].taskID
        var given = answer
        given.answers = answer.answers.map { a in
            var trimmed = a
            trimmed.custom = a.custom.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed
        }
        s.questionAnswers.append(given)
        var resolved = Dshm_V1_QuestionResolved()
        resolved.id = answer.id
        resolved.taskID = taskID
        resolved.outcome = outcome
        resolved.answers = given.answers
        var event = Dshm_V1_Event()
        event.questionResolved = resolved
        Self.append(event, taskID: taskID, in: &s)
        s.tasks[at].pendingQuestions.removeAll { $0.id == answer.id }
        s.tasks[at].state = .running
        s.tasks[at].updatedAtMs = Self.nowMs()
        Self.upserted(s.tasks[at], in: &s)
        let incarnation = s.incarnation
        let variant = script.variant(for: s.tasks[at].title)
        Task { await self.stream(taskID: taskID, incarnation: incarnation, using: variant) }
        return resolved
    }

    /// S18: another client (the Web) answers every pending approval of this host. The phone
    /// gets only the `ApprovalResolved` event, as from the real bridge.
    public func answerFromElsewhere(allow: Bool) {
        state.withLock { s in
            for at in s.tasks.indices {
                for pending in s.tasks[at].pendingApprovals {
                    _ = resolve(pending.id, at: at, allow: allow, in: &s)
                }
            }
        }
    }

    /// Logs the resolution, and the task goes on to its reply.
    private func resolve(_ id: String, at: Int, allow: Bool, in s: inout State) -> Dshm_V1_ApprovalResolved {
        let taskID = s.tasks[at].taskID
        var resolved = Dshm_V1_ApprovalResolved()
        resolved.id = id
        resolved.taskID = taskID
        resolved.outcome = allow ? .allowed : .denied
        var event = Dshm_V1_Event()
        event.approvalResolved = resolved
        Self.append(event, taskID: taskID, in: &s)
        s.tasks[at].pendingApprovals.removeAll { $0.id == id }
        s.tasks[at].state = .running
        s.tasks[at].updatedAtMs = Self.nowMs()
        Self.upserted(s.tasks[at], in: &s)
        let incarnation = s.incarnation
        let variant = script.variant(for: s.tasks[at].title) // S19
        Task { await self.stream(taskID: taskID, incarnation: incarnation, using: variant) }
        return resolved
    }

    private func stream(taskID: String, incarnation: Int, hold: Bool = false,
                        ask: FakeBridge.PendingApproval? = nil, question: [AgentQuestion.Item]? = nil,
                        using variant: FakeBridge.Script? = nil) async {
        let script = variant ?? self.script // S19: the task's own script, if its prompt picks one
        let turn = state.withLock { $0.turns[taskID, default: 0] } // D101: a stop ends this turn's stream
        // S3: milestones are logged like any other event, so Resume replays them.
        var milestoneSeq: UInt64 = 0
        var lastTodos: [Todo] = []
        func milestone(_ step: FakeBridge.Step) -> Bool {
            milestoneSeq += 1
            lastTodos = step.todos
            let wire = Self.wire(taskID: taskID, seq: milestoneSeq, step)
            return state.withLock { s -> Bool in
                guard s.incarnation == incarnation, !s.stopped.contains(taskID), s.turns[taskID, default: 0] == turn else { return false }
                s.lastMilestones[taskID] = (milestoneSeq, step.todos)
                var event = Dshm_V1_Event()
                event.milestoneAdded = wire
                Self.append(event, taskID: taskID, in: &s)
                return true
            }
        }
        let split = min(script.replyAfterMilestones ?? script.milestones.count, script.milestones.count)
        for step in script.milestones.prefix(split) {
            try? await Task.sleep(for: script.milestoneDelay)
            if !milestone(step) { return }
            if hold { return }
        }
        if hold { return }
        if let ask {
            // S18: the task pauses on an approval; `resolve` streams the reply after the answer.
            try? await Task.sleep(for: script.chunkDelay)
            state.withLock { s in
                guard s.incarnation == incarnation, let at = s.tasks.firstIndex(where: { $0.taskID == taskID }) else { return }
                var pending = Dshm_V1_ApprovalPending()
                pending.taskID = taskID
                pending.id = "\(taskID)-approval"
                pending.callID = "\(taskID)-call"
                pending.tool = ask.tool
                pending.argumentsJson = ask.arguments
                pending.reason = ask.reason
                var event = Dshm_V1_Event()
                event.approvalPending = pending
                Self.append(event, taskID: taskID, in: &s)
                s.tasks[at].pendingApprovals = [pending]
                s.tasks[at].state = .waitingOnUser
                s.tasks[at].updatedAtMs = Self.nowMs()
                Self.upserted(s.tasks[at], in: &s)
            }
            return
        }
        if let question {
            // The task waits on the question; `resolveQuestion` streams the reply after the answer.
            try? await Task.sleep(for: script.chunkDelay)
            state.withLock { s in
                guard s.incarnation == incarnation, let at = s.tasks.firstIndex(where: { $0.taskID == taskID }) else { return }
                var pending = Dshm_V1_QuestionPending()
                pending.id = "\(taskID)-question"
                pending.taskID = taskID
                pending.questions = question.map { item in
                    var q = Dshm_V1_Question()
                    q.id = item.id
                    q.text = item.text
                    q.header = item.header
                    q.detail = item.detail
                    q.multiSelect = item.multiSelect
                    q.options = item.options.map { option in
                        var o = Dshm_V1_QuestionOption()
                        o.label = option.label
                        o.description_p = option.description
                        return o
                    }
                    return q
                }
                var event = Dshm_V1_Event()
                event.questionPending = pending
                Self.append(event, taskID: taskID, in: &s)
                s.tasks[at].pendingQuestions = [pending]
                s.tasks[at].state = .waitingOnUser
                s.tasks[at].updatedAtMs = Self.nowMs()
                Self.upserted(s.tasks[at], in: &s)
            }
            return
        }
        // S17: blocks are logged like chunks, in their place among them.
        func blocks(before chunk: Int) -> Bool {
            for entry in script.blocks where entry.beforeChunk == chunk || (chunk == script.reply.count && entry.beforeChunk > chunk) {
                var block = entry.block
                block.taskID = taskID
                let alive = state.withLock { s -> Bool in
                    guard s.incarnation == incarnation, !s.stopped.contains(taskID), s.turns[taskID, default: 0] == turn else { return false }
                    var event = Dshm_V1_Event()
                    event.transcriptBlock = block
                    Self.append(event, taskID: taskID, in: &s)
                    return true
                }
                if !alive { return false }
            }
            return true
        }
        for (i, text) in script.reply.enumerated() {
            try? await Task.sleep(for: script.chunkDelay)
            if !blocks(before: i) { return }
            var chunk = Dshm_V1_AssistantChunk()
            chunk.taskID = taskID
            chunk.text = text
            let alive = state.withLock { s -> Bool in
                guard s.incarnation == incarnation, !s.stopped.contains(taskID), s.turns[taskID, default: 0] == turn else { return false }
                // D89: the chunk seq goes on across the turns of a task, as the bridge's TaskHub does.
                chunk.seq = (s.chunkSeqs[taskID] ?? 0) + 1
                s.chunkSeqs[taskID] = chunk.seq
                var event = Dshm_V1_Event()
                event.assistantChunk = chunk
                Self.append(event, taskID: taskID, in: &s)
                return true
            }
            if !alive { return }
            if i == 0 { await script.afterFirstChunk?() }
        }
        if !script.blocks.isEmpty {
            try? await Task.sleep(for: script.chunkDelay)
            if !blocks(before: script.reply.count) { return }
        }
        for step in script.milestones.dropFirst(split) {
            try? await Task.sleep(for: script.milestoneDelay)
            if !milestone(step) { return }
        }
        // D101: steered messages go in at the next step, then each queued one runs as its own turn.
        while true {
            let taken = state.withLock { s -> Bool in
                guard s.incarnation == incarnation, !s.stopped.contains(taskID), s.turns[taskID, default: 0] == turn, var list = s.queued[taskID], !list.isEmpty else { return false }
                let steered = list.filter { $0.placement == .steering }
                let messages = steered.isEmpty ? [list[0]] : steered
                list.removeAll { m in messages.contains { $0.messageID == m.messageID } }
                s.queued[taskID] = list.isEmpty ? nil : list
                for message in messages {
                    var user = Dshm_V1_UserMessage()
                    user.taskID = taskID
                    user.messageID = message.messageID
                    user.text = message.text
                    user.timeMs = Self.nowMs()
                    var event = Dshm_V1_Event()
                    event.userMessage = user
                    Self.append(event, taskID: taskID, in: &s)
                }
                if steered.isEmpty, let at = s.tasks.firstIndex(where: { $0.taskID == taskID }) {
                    s.tasks[at].updatedAtMs = Self.nowMs()
                    s.tasks[at].turnStartedAtMs = s.tasks[at].updatedAtMs
                    Self.upserted(s.tasks[at], in: &s)
                }
                return true
            }
            guard taken else { break }
            for text in self.script.followUpReply ?? [] {
                try? await Task.sleep(for: script.chunkDelay)
                var chunk = Dshm_V1_AssistantChunk()
                chunk.taskID = taskID
                chunk.text = text
                let alive = state.withLock { s -> Bool in
                    guard s.incarnation == incarnation, !s.stopped.contains(taskID), s.turns[taskID, default: 0] == turn else { return false }
                    chunk.seq = (s.chunkSeqs[taskID] ?? 0) + 1
                    s.chunkSeqs[taskID] = chunk.seq
                    var event = Dshm_V1_Event()
                    event.assistantChunk = chunk
                    Self.append(event, taskID: taskID, in: &s)
                    return true
                }
                if !alive { return }
            }
        }
        if script.holdAfterReply { return }
        if !script.milestones.isEmpty {
            let closing = script.failWith.map { FakeBridge.Step(.failed, $0, todos: lastTodos) }
                ?? FakeBridge.Step(.finished, todos: lastTodos)
            if !milestone(closing) { return }
        }
        state.withLock { s in
            guard s.incarnation == incarnation, !s.stopped.contains(taskID), s.turns[taskID, default: 0] == turn,
                  let at = s.tasks.firstIndex(where: { $0.taskID == taskID }) else { return }
            s.tasks[at].state = script.failWith == nil ? .completed : .failed
            s.tasks[at].message = script.failWith ?? ""
            s.tasks[at].updatedAtMs = Self.nowMs()
            Self.upserted(s.tasks[at], in: &s)
            var ended = Dshm_V1_TaskEnded()
            ended.taskID = taskID
            ended.status = script.failWith == nil ? .completed : .failed
            ended.message = script.failWith ?? ""
            var event = Dshm_V1_Event()
            event.taskEnded = ended
            Self.append(event, taskID: taskID, in: &s)
        }
    }

    private static func wire(taskID: String, seq: UInt64, _ step: FakeBridge.Step) -> Dshm_V1_MilestoneAdded {
        var m = Dshm_V1_MilestoneAdded()
        m.taskID = taskID
        m.seq = seq
        m.kind = switch step.kind {
        case .started: .started
        case .planned: .planned
        case .todoStarted: .todoStarted
        case .todoDone: .todoDone
        case .planModeEntered: .planModeEntered
        case .planModeLeft: .planModeLeft
        case .retrying: .retrying
        case .failed: .failed
        case .finished: .finished
        case .interrupted: .interrupted
        }
        m.text = step.text
        m.todos = step.todos.map { t in
            var todo = Dshm_V1_Todo()
            todo.content = t.content
            todo.status = switch t.status {
            case .pending: .pending
            case .inProgress: .inProgress
            case .completed: .completed
            }
            return todo
        }
        m.timeMs = Int64(Date().timeIntervalSince1970 * 1000)
        return m
    }

    private static func upserted(_ summary: Dshm_V1_TaskSummary, in s: inout State) {
        var upserted = Dshm_V1_TaskUpserted()
        upserted.task = summary
        var event = Dshm_V1_Event()
        event.taskUpserted = upserted
        append(event, taskID: summary.taskID, in: &s)
    }

    /// Numbers, logs, and forwards one event: to resumed connections, and to T0-style
    /// connections that created the task.
    private static func append(_ event: Dshm_V1_Event, taskID: String, in s: inout State) {
        var logged = event
        logged.hostSeq = UInt64(s.log.count + 1)
        s.log.append(logged)
        for conn in s.connections.values where conn.resumed || conn.ownTasks.contains(taskID) {
            conn.bridge.deliver(frame(logged))
        }
    }

    private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private static func uploadError(_ requestID: UInt64, _ code: String, _ message: String) -> Dshm_V1_Frame {
        response(requestID, .error(.with { $0.code = code; $0.message = message }))
    }

    private static func frame(_ request: Dshm_V1_Request) -> Dshm_V1_Frame {
        var frame = Dshm_V1_Frame()
        frame.request = request
        return frame
    }

    private static func response(_ requestID: UInt64, _ body: Dshm_V1_Response.OneOf_Body) -> Dshm_V1_Frame {
        var response = Dshm_V1_Response()
        response.requestID = requestID
        response.body = body
        var frame = Dshm_V1_Frame()
        frame.response = response
        return frame
    }

    private static func frame(_ event: Dshm_V1_Event) -> Dshm_V1_Frame {
        var frame = Dshm_V1_Frame()
        frame.event = event
        return frame
    }
}
#endif
