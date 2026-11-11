#if DEBUG
import DSHCore
import DSHProtocol
import Foundation
import Synchronization
import Testing

@Suite struct TransportDispatchTests {
    /// Both directions are independent streams of whole WebSocket messages.
    final class Pipe: BridgeTransport {
        let incoming = AsyncStream<Data>.makeStream()
        let outgoing = AsyncStream<Dshm_V1_Request>.makeStream()
        let closing = Wake()
        let allowClose = Wake()
        let sent = Mutex<[Dshm_V1_Frame]>([])

        func send(_ message: Data) async throws {
            let frame = try Dshm_V1_Frame(serializedBytes: message)
            sent.withLock { $0.append(frame) }
            if case .request(let request) = frame.kind { outgoing.continuation.yield(request) }
        }

        func receive() async throws -> Data {
            var iterator = incoming.stream.makeAsyncIterator()
            guard let bytes = await iterator.next() else { throw HostConnectionError.disconnected }
            return bytes
        }

        func close() async {
            closing.fire()
            incoming.continuation.finish()
            await allowClose.wait()
        }

        func deliver(_ kind: Dshm_V1_Frame.OneOf_Kind) throws {
            var frame = Dshm_V1_Frame()
            frame.kind = kind
            incoming.continuation.yield(try frame.serializedBytes())
        }

        func reply(_ id: UInt64, _ body: Dshm_V1_Response.OneOf_Body) throws {
            try deliver(.response(.with { $0.requestID = id; $0.body = body }))
        }
    }

    @MainActor @Test func requestTowardPhoneIsIgnoredBetweenCallAndReply() async throws {
        let pipe = Pipe()
        pipe.allowClose.fire()
        let connection = HostConnection(endpoint: .localBridge(), transport: { _ in pipe })
        var outbound = pipe.outgoing.stream.makeAsyncIterator()
        let store = TaskStore(connection: connection, prompt: "hello")
        let sending = Task { await store.send() }
        let hello = try #require(await outbound.next())
        try pipe.reply(hello.id, .hello(.init()))
        let create = try #require(await outbound.next())
        try pipe.deliver(.request(.with { $0.id = create.id; $0.hello.protocolVersion = DSHProtocolInfo.version }))
        try pipe.reply(create.id, .taskCreated(.with { $0.taskID = "t" }))
        await sending.value
        #expect(store.status == .running(taskID: "t"))
        try pipe.deliver(.event(.with { $0.assistantChunk = .with { $0.taskID = "t"; $0.text = "reply" } }))
        await waitForStore("chunk from the same connection") { store.transcript == "reply" }
        #expect(pipe.sent.withLock { $0.count } == 2)
        await connection.disconnect()
    }

    @Test func concurrentCallsKeepWireOrderAndMatchRepliesByID() async throws {
        let pipe = Pipe()
        pipe.allowClose.fire()
        let connection = HostConnection(endpoint: .localBridge(), transport: { _ in pipe })
        var outbound = pipe.outgoing.stream.makeAsyncIterator()
        let connect = Task { try await connection.connect() }
        let hello = try #require(await outbound.next())
        try pipe.reply(hello.id, .hello(.init()))
        try await connect.value

        let calls = (0..<12).map { index in
            Task { try await connection.createTask(prompt: String(index)) }
        }
        var requests: [Dshm_V1_Request] = []
        for _ in calls { requests.append(try #require(await outbound.next())) }
        let ids = requests.map(\.id)
        #expect(ids == ids.sorted())
        for request in requests.reversed() {
            try pipe.reply(request.id, .taskCreated(.with { $0.taskID = request.createTask.prompt }))
        }
        for (index, call) in calls.enumerated() { #expect(try await call.value == String(index)) }
        await connection.disconnect()
    }

    @Test func closingOldConnectionLeavesReplacementAndItsPendingCallAlone() async throws {
        let old = Pipe(), replacement = Pipe()
        replacement.allowClose.fire()
        let available = Mutex([old, replacement])
        let connection = HostConnection(endpoint: .localBridge(), transport: { _ in available.withLock { $0.removeFirst() } })
        var first = old.outgoing.stream.makeAsyncIterator()
        let connect = Task { try await connection.connect() }
        let hello = try #require(await first.next())
        try old.reply(hello.id, .hello(.init()))
        try await connect.value

        let cancelled = Task { try await connection.listTasks() }
        _ = try #require(await first.next())
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let pending = Task { try await connection.listTasks() }
        _ = try #require(await first.next())
        let closing = Task { await connection.disconnect() }
        await old.closing.wait()

        var second = replacement.outgoing.stream.makeAsyncIterator()
        let reconnect = Task { try await connection.connect() }
        let newHello = try #require(await second.next())
        old.allowClose.fire()
        await closing.value
        await #expect(throws: HostConnectionError.disconnected) { try await pending.value }
        try replacement.reply(newHello.id, .hello(.init()))
        try await reconnect.value
        #expect(await connection.isConnected)
        await connection.disconnect()
    }
}
#endif
