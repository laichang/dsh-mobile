#if DEBUG
import DSHCore
import DSHProtocol
import Foundation
import SwiftProtobuf

/// In-process stand-in for the bridge (PLAN §1 "Test alone"). Speaks real `Frame` bytes, so
/// `HostConnection`, the channel, and protobuf coding are all exercised. Debug builds only.
public actor FakeBridge: BridgeTransport {
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
            hello.capabilities = [DSHProtocolInfo.tasksCapability]
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
        for (i, text) in script.reply.enumerated() {
            try? await Task.sleep(for: script.chunkDelay)
            var chunk = Dshm_V1_AssistantChunk()
            chunk.taskID = taskID
            chunk.seq = UInt64(i + 1)
            chunk.text = text
            emit(.assistantChunk(chunk))
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
