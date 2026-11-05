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
    public struct Script: Sendable {
        public var reply: [String]
        public var chunkDelay: Duration
        public var failWith: String?

        public init(
            reply: [String] = ["Hello", " from", " FakeBridge", ". ", "No DSH", " was", " involved."],
            chunkDelay: Duration = .milliseconds(120),
            failWith: String? = nil
        ) {
            self.reply = reply
            self.chunkDelay = chunkDelay
            self.failWith = failWith
        }
    }

    public static let defaultReply = Script().reply.joined()

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
    private let script: FakeBridge.Script

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
    }

    private let state = Mutex(State())

    public init(script: FakeBridge.Script = .init(), hostName: String = "FakeBridge Mac", reachable: Bool = true) {
        self.script = script
        self.hostName = hostName
        state.withLock { $0.reachable = reachable }
    }

    /// Opens a connection to this host; throws while it's unreachable.
    public var factory: BridgeTransportFactory {
        { [self] _ in try self.open() }
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

    private func open() throws -> FakeBridge {
        let bridge = FakeBridge(host: self)
        try state.withLock { s in
            guard s.reachable else { throw FakeHostError.unreachable }
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
                hello.capabilities = [DSHProtocolInfo.tasksCapability, DSHProtocolInfo.resumeCapability]
                bridge.deliver(Self.response(id, .hello(hello)))
            case .createTask(let create)?:
                s.prompts.append(create.prompt)
                s.tasksCreated += 1
                let taskID = "fake-task-\(s.tasksCreated)"
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
                Task { await self.stream(taskID: taskID, incarnation: incarnation) }
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
            case nil:
                break
            }
        }
    }

    private func stream(taskID: String, incarnation: Int) async {
        for (i, text) in script.reply.enumerated() {
            try? await Task.sleep(for: script.chunkDelay)
            var chunk = Dshm_V1_AssistantChunk()
            chunk.taskID = taskID
            chunk.seq = UInt64(i + 1)
            chunk.text = text
            let alive = state.withLock { s -> Bool in
                guard s.incarnation == incarnation else { return false }
                var event = Dshm_V1_Event()
                event.assistantChunk = chunk
                Self.append(event, taskID: taskID, in: &s)
                return true
            }
            if !alive { return }
        }
        state.withLock { s in
            guard s.incarnation == incarnation, let at = s.tasks.firstIndex(where: { $0.taskID == taskID }) else { return }
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
