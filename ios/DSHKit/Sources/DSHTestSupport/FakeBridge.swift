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
    public static let threeTodoItems = ["Read the project layout", "Write the summary", "Check the summary against the code"]

    /// A fresh host behind every connection this factory opens (T0 behaviour, plus S2's log).
    public static func factory(script: Script = Script()) -> BridgeTransportFactory {
        FakeHost(script: script).factory
    }

    private struct State {
        var inbox: [Data] = []
        var waiter: CheckedContinuation<Data, any Error>?
        var closed = false
    }

    private let host: FakeHost
    private let state = Mutex(State())
    let id = UUID()

    init(host: FakeHost) {
        self.host = host
    }

    // MARK: BridgeTransport (the app's side of the pipe)

    public func send(_ message: Data) async throws {
        if state.withLock({ $0.closed }) { throw HostConnectionError.disconnected }
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
                    continuation.resume(throwing: HostConnectionError.disconnected)
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

    /// The bridge closes this connection (it went away, or the network dropped).
    func drop() {
        state.withLock { s in
            s.closed = true
            s.waiter?.resume(throwing: HostConnectionError.disconnected)
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
    /// S15, S18: seeded approvals or a script that asks for one.
    private var answersApprovals: Bool { !approvals.isEmpty || script.ask != nil }

    private struct Connection {
        let bridge: FakeBridge
        var resumed = false
        var ownTasks: Set<String> = []
        var helloDone = false
    }

    private struct State {
        var logID = UUID().uuidString
        var log: [Dshm_V1_Event] = []
        var tasks: [Dshm_V1_TaskSummary] = []
        var connections: [UUID: Connection] = [:]
        var reachable = true
        var prompts: [String] = []
        var tasksCreated = 0
        var incarnation = 0
        /// S21: `devices.v1` records; `revoked` once this phone's device lost its access.
        var devices: FakeDevices?
        var revoked = false
        /// S16: interrupted tasks; their stream stops.
        var stopped: Set<String> = []
        /// S16: each task's latest milestone seq and todos, for the INTERRUPTED milestone.
        var lastMilestones: [String: (seq: UInt64, todos: [Todo])] = [:]
    }

    private let state = Mutex(State())

    /// - Parameter seed: sessions the host already has, as if other clients made them (S14).
    public init(script: FakeBridge.Script = .init(), hostName: String = "FakeBridge Mac", reachable: Bool = true,
                incompatibleDsh: (installed: String, supported: String)? = nil,
                seed: [Dshm_V1_TaskSummary] = [], extraCapabilities: [String] = [],
                approvals: [FakeBridge.PendingApproval] = [], devices: FakeDevices? = nil) {
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
    public var logID: String { state.withLock { $0.logID } }
    public var head: UInt64 { state.withLock { UInt64($0.log.count) } }
    public var connectionCount: Int { state.withLock { $0.connections.count } }

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
            guard s.reachable, !s.revoked else { throw FakeHostError.unreachable }
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
                    if s.devices != nil { hello.capabilities.append(FakeDevices.capability) }
                }
                bridge.deliver(Self.response(id, .hello(hello)))
            case .createTask(let create)?:
                s.prompts.append(create.prompt)
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
                s.tasks.append(summary)
                s.connections[bridge.id] = conn
                Self.upserted(summary, in: &s)
                let incarnation = s.incarnation
                let hold = script.holds(create.prompt)
                let ask = script.asks(create.prompt)
                let variant = script.variant(for: create.prompt) // S19
                Task { await self.stream(taskID: taskID, incarnation: incarnation, hold: hold, ask: ask, using: variant) }
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
                s.tasks[at].state = .interrupted
                s.tasks[at].updatedAtMs = Self.nowMs()
                Self.upserted(s.tasks[at], in: &s)
                var ended = Dshm_V1_TaskEnded()
                ended.taskID = interrupt.taskID
                ended.status = .interrupted
                var event = Dshm_V1_Event()
                event.taskEnded = ended
                Self.append(event, taskID: interrupt.taskID, in: &s)
            case .answerApproval(let answer)? where answersApprovals:
                answerApproval(answer, requestID: id, bridge: bridge, in: &s)
            case let body? where s.devices != nil && FakeDevices.handles(body):
                guard let (answer, revokedCurrent) = s.devices?.answer(body) else { break }
                bridge.deliver(Self.response(id, answer))
                if revokedCurrent {
                    s.revoked = true
                    let dropped = s.connections.values.map(\.bridge)
                    Task { for bridge in dropped { bridge.drop() } }
                }
            case .answerApproval?, .interrupt?, .getModelCatalog?, .selectModel?, .listWorkspaces?, .listDevices?, .listAudit?, .revokeDevice?, .readSession?:
                var error = Dshm_V1_Error()
                error.code = "request/unsupported"
                error.message = "This test host does not advertise this capability."
                bridge.deliver(Self.response(id, .error(error)))
            case nil:
                break
            }
        }
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
                        ask: FakeBridge.PendingApproval? = nil, using variant: FakeBridge.Script? = nil) async {
        let script = variant ?? self.script // S19: the task's own script, if its prompt picks one
        // S3: milestones are logged like any other event, so Resume replays them.
        var milestoneSeq: UInt64 = 0
        var lastTodos: [Todo] = []
        func milestone(_ step: FakeBridge.Step) -> Bool {
            milestoneSeq += 1
            lastTodos = step.todos
            let wire = Self.wire(taskID: taskID, seq: milestoneSeq, step)
            return state.withLock { s -> Bool in
                guard s.incarnation == incarnation, !s.stopped.contains(taskID) else { return false }
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
        for (i, text) in script.reply.enumerated() {
            try? await Task.sleep(for: script.chunkDelay)
            var chunk = Dshm_V1_AssistantChunk()
            chunk.taskID = taskID
            chunk.seq = UInt64(i + 1)
            chunk.text = text
            let alive = state.withLock { s -> Bool in
                guard s.incarnation == incarnation, !s.stopped.contains(taskID) else { return false }
                var event = Dshm_V1_Event()
                event.assistantChunk = chunk
                Self.append(event, taskID: taskID, in: &s)
                return true
            }
            if !alive { return }
            if i == 0 { await script.afterFirstChunk?() }
        }
        for step in script.milestones.dropFirst(split) {
            try? await Task.sleep(for: script.milestoneDelay)
            if !milestone(step) { return }
        }
        if script.holdAfterReply { return }
        if !script.milestones.isEmpty {
            let closing = script.failWith.map { FakeBridge.Step(.failed, $0, todos: lastTodos) }
                ?? FakeBridge.Step(.finished, todos: lastTodos)
            if !milestone(closing) { return }
        }
        state.withLock { s in
            guard s.incarnation == incarnation, !s.stopped.contains(taskID),
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
