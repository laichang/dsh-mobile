#if DEBUG
@testable import DSHCore
import DSHFeatures
import DSHProtocol
import Foundation
import Synchronization
import Testing

struct ReplayDispatchTests {
    private final class Replay: Sendable {
        let mappingSecond = Wake()
        let releaseMapper = Wake()
        let trace = Mutex<[String]>([])
        let pipe = TransportDispatchTests.Pipe()

        func connection() -> HostConnection {
            pipe.allowClose.fire()
            return HostConnection(endpoints: [.localBridge()], transport: { _ in self.pipe }, deliverEvent: { host, event, session in
                if event.hostSeq == 2 {
                    self.mappingSecond.fire()
                    await self.releaseMapper.wait()
                }
                host.yield(event, from: session)
                self.trace.withLock { $0.append("yielded \(event.hostSeq)") }
            })
        }

        func sendReplay(for request: Dshm_V1_Request) async throws {
            guard case .resume = request.body else { Issue.record("expected Resume"); return }
            try pipe.deliver(.event(.with { $0.logReset.logID = "new" }))
            for seq: UInt64 in [1, 2] {
                try pipe.deliver(.event(.with { event in
                    event.hostSeq = seq
                    event.assistantChunk.taskID = "replayed"
                    event.assistantChunk.seq = seq
                    event.assistantChunk.text = String(seq)
                }))
            }
            await mappingSecond.wait()
            try pipe.reply(request.id, .resumed(.with { $0.logID = "new"; $0.reset = true; $0.replayed = 2 }))
        }
    }

    @Test func resumeWaitsForMappingAndYieldWithConsumerPaused() async throws {
        let replay = Replay(), connection = replay.connection()
        var outbound = replay.pipe.outgoing.stream.makeAsyncIterator()
        let opening = Task { try await connection.connect() }
        let hello = try #require(await outbound.next())
        try replay.pipe.reply(hello.id, .hello(.init()))
        try await opening.value

        let resuming = Task {
            let result = try await connection.resume(logID: "old", afterSeq: 10)
            replay.trace.withLock { $0.append("resumed") }
            return result
        }
        try await replay.sendReplay(for: #require(await outbound.next()))
        #expect(replay.trace.withLock { $0 } == ["yielded 0", "yielded 1"])
        replay.releaseMapper.fire()
        #expect(try await resuming.value.reset)
        #expect(replay.trace.withLock { $0 } == ["yielded 0", "yielded 1", "yielded 2", "resumed"])
        var stream = connection.events.makeAsyncIterator()
        for seq: UInt64 in [0, 1, 2] {
            let event = try #require(await stream.next())
            #expect(event.hostSeq == seq)
            if seq == 0 { #expect(event.event == .logReset(logID: "new")) }
        }
        await connection.disconnect()
    }

    @Test func workspaceReadAndTaskCreationShareTheReplayBarrier() async throws {
        let replay = Replay(), connection = replay.connection()
        var outbound = replay.pipe.outgoing.stream.makeAsyncIterator()
        let opening = Task { try await connection.connect() }
        let hello = try #require(await outbound.next())
        try replay.pipe.reply(hello.id, .hello(.init()))
        try await opening.value

        let resuming = Task { try await connection.resume(logID: "", afterSeq: 0) }
        let resume = try #require(await outbound.next())
        let reading = Task { try await connection.listWorkspaces() }
        let read = try #require(await outbound.next())
        let creating = Task { try await connection.createTask(prompt: "go") }
        let create = try #require(await outbound.next())
        #expect(Set([resume.id, read.id, create.id]).count == 3)
        guard case .listWorkspaces = read.body, case .createTask = create.body else {
            Issue.record("expected workspace read and task creation")
            return
        }
        try await replay.sendReplay(for: resume)
        try replay.pipe.reply(create.id, .taskCreated(.with { $0.taskID = "created" }))
        try replay.pipe.reply(read.id, .workspaceList(.with { $0.defaultPath = "/workspace" }))
        replay.releaseMapper.fire()
        #expect(try await resuming.value.replayed == 2)
        #expect(try await creating.value == "created")
        #expect(try await reading.value.defaultPath == "/workspace")
        await connection.disconnect()
    }

    @MainActor @Test func hostSyncListsAfterReplayMappingAndResumed() async throws {
        let replay = Replay(), connection = replay.connection()
        let config = HostSync.HostConfig(key: "host", connection: connection)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tasks.store")
        var holdFlush = false
        let flushAttempted = Wake()
        let sync = HostSync(config: config, cache: try TaskCache(url: url)) {
            if holdFlush {
                flushAttempted.fire()
                throw CocoaError(.fileWriteOutOfSpace)
            }
        }
        let (gated, input) = AsyncStream<HostEvent>.makeStream()
        let process = Wake(), yielded = Wake()
        let consumer = Task {
            var buffered: [HostEvent] = []
            for await event in connection.events {
                buffered.append(event)
                if buffered.count == 3 {
                    yielded.fire()
                    await process.wait()
                    for event in buffered { input.yield(event) }
                    return
                }
            }
        }
        defer { consumer.cancel(); input.finish(); sync.retire() }
        var outbound = replay.pipe.outgoing.stream.makeAsyncIterator()
        sync.start(firstConnectDelay: .zero, backoff: (.seconds(1), .seconds(5)), eventStream: gated)
        let hello = try #require(await outbound.next())
        try replay.pipe.reply(hello.id, .hello(.init()))
        try await replay.sendReplay(for: #require(await outbound.next()))
        #expect(replay.pipe.sent.withLock { $0.count } == 2)
        holdFlush = true
        replay.releaseMapper.fire()
        let list = try #require(await outbound.next())
        guard case .listTasks = list.body else { Issue.record("expected ListTasks"); return }
        #expect(replay.trace.withLock { $0 } == ["yielded 0", "yielded 1", "yielded 2"])
        await yielded.wait()
        #expect(sync.rows(hostName: "host").isEmpty)
        // ListTasks has already crossed the wire; only now can the real consumer process the batch.
        process.fire()
        await flushAttempted.wait()
        #expect(sync.rows(hostName: "host").first?.transcript == "12")
        func savedTranscript() throws -> String? {
            try TaskListStore(cache: TaskCache(url: url), hosts: [config]).tasks.first?.transcript
        }
        #expect(try savedTranscript() == nil)
        holdFlush = false
        sync.stop()
        #expect(try savedTranscript() == "12")
    }
}
#endif
