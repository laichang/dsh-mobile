#if DEBUG
import DSHCore
import DSHProtocol
import Foundation
import SwiftProtobuf

/// In-process stand-in for the bridge (PLAN §1 "Test alone"). Speaks real `Frame` bytes, so
/// `HostConnection`, the channel, and protobuf coding are all exercised. Debug builds only.
public actor FakeBridge: BridgeTransport {
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
        public var failWith: String?
        /// S3: milestones sent before the reply, `milestoneDelay` apart. When there are any, a
        /// closing FINISHED (or FAILED, with `failWith`) follows the reply, as the real bridge does.
        public var milestones: [Step]
        public var milestoneDelay: Duration

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

        /// A three-todo task that ticks its todos off one by one (S3 demo, `-DSHMFakeMilestones YES`).
        public static func threeTodos(delay: Duration = .milliseconds(900)) -> Script {
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

    public static let defaultReply = Script().reply.joined()
    public static let threeTodoItems = ["Read the project layout", "Write the summary", "Check the summary against the code"]

    private let script: Script
    private var inbox: [Data] = []
    private var waiter: CheckedContinuation<Data, any Error>?
    private var closed = false
    private var tasksCreated = 0
    public private(set) var prompts: [String] = []

    public init(script: Script = Script()) {
        self.script = script
    }

    public static func factory(script: Script = Script()) -> BridgeTransportFactory {
        { _ in FakeBridge(script: script) }
    }

    // MARK: BridgeTransport (the app's side of the pipe)

    public func send(_ message: Data) async throws {
        let frame = try Dshm_V1_Frame(serializedBytes: message)
        guard case .request(let request)? = frame.kind else { return }
        switch request.body {
        case .hello?:
            var hello = Dshm_V1_Hello()
            hello.protocolVersion = DSHProtocolInfo.version
            hello.capabilities = [DSHProtocolInfo.tasksCapability, DSHProtocolInfo.milestonesCapability]
            respond(request.id, .hello(hello))
        case .createTask(let create)?:
            prompts.append(create.prompt)
            tasksCreated += 1
            let taskID = "fake-task-\(tasksCreated)"
            var created = Dshm_V1_TaskCreated()
            created.taskID = taskID
            respond(request.id, .taskCreated(created))
            Task { await self.stream(taskID: taskID) }
        case nil:
            break
        }
    }

    public func receive() async throws -> Data {
        if !inbox.isEmpty { return inbox.removeFirst() }
        if closed { throw HostConnectionError.disconnected }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    public func close() async {
        closed = true
        waiter?.resume(throwing: HostConnectionError.disconnected)
        waiter = nil
    }

    // MARK: Bridge side

    private func stream(taskID: String) async {
        var milestoneSeq: UInt64 = 0
        var lastTodos: [Todo] = []
        func milestone(_ step: Step) {
            milestoneSeq += 1
            lastTodos = step.todos
            emit(.milestoneAdded(Self.wire(taskID: taskID, seq: milestoneSeq, step)))
        }
        for step in script.milestones {
            try? await Task.sleep(for: script.milestoneDelay)
            milestone(step)
        }
        for (i, text) in script.reply.enumerated() {
            try? await Task.sleep(for: script.chunkDelay)
            var chunk = Dshm_V1_AssistantChunk()
            chunk.taskID = taskID
            chunk.seq = UInt64(i + 1)
            chunk.text = text
            emit(.assistantChunk(chunk))
        }
        if !script.milestones.isEmpty {
            milestone(script.failWith.map { Step(.failed, $0, todos: lastTodos) } ?? Step(.finished, todos: lastTodos))
        }
        var ended = Dshm_V1_TaskEnded()
        ended.taskID = taskID
        if let failure = script.failWith {
            ended.status = .failed
            ended.message = failure
        } else {
            ended.status = .completed
        }
        emit(.taskEnded(ended))
    }

    private static func wire(taskID: String, seq: UInt64, _ step: Step) -> Dshm_V1_MilestoneAdded {
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

    private func respond(_ requestID: UInt64, _ body: Dshm_V1_Response.OneOf_Body) {
        var response = Dshm_V1_Response()
        response.requestID = requestID
        response.body = body
        var frame = Dshm_V1_Frame()
        frame.response = response
        deliver(frame)
    }

    private func emit(_ body: Dshm_V1_Event.OneOf_Body) {
        var event = Dshm_V1_Event()
        event.body = body
        var frame = Dshm_V1_Frame()
        frame.event = event
        deliver(frame)
    }

    private func deliver(_ frame: Dshm_V1_Frame) {
        guard !closed, let bytes = try? frame.serializedData() else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: bytes)
        } else {
            inbox.append(bytes)
        }
    }
}
#endif
