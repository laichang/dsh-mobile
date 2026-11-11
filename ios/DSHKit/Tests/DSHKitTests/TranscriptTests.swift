import DSHCore
import DSHFeatures
import DSHProtocol
import DSHTestSupport
import Foundation
import SwiftData
import Testing

/// The Swift half of the transcript fixtures (the TS half: bridge/test/transcript.test.ts,
/// `TranscriptFixtures`): thinking and tool blocks decode the same on both sides.
@Suite struct TranscriptFixtures {
    func block(_ name: String) throws -> Dshm_V1_TranscriptBlock {
        let bytes = try Data(contentsOf: GoldenFixtures.fixturesDir.appending(path: "\(name).binpb"))
        let frame = try Dshm_V1_Frame(serializedBytes: bytes)
        guard case .transcriptBlock(let block)? = frame.event.body else {
            Issue.record("\(name) is not a TranscriptBlock event")
            return Dshm_V1_TranscriptBlock()
        }
        return block
    }

    @Test func thinkingAndToolBlocksDecode() throws {
        let thinking = try #require(TranscriptItem(try block("transcript_thinking_block_event")))
        #expect(thinking.id == "thinking-attempt-1-0")
        #expect(thinking.taskID == "session-1")
        #expect(thinking.state == .done)
        #expect(thinking.kind == .thinking(durationMs: 8000, text: "先看测试为什么失败。", truncated: false))
        #expect(thinking.thinkingSeconds == 8)
        #expect(thinking.time == Date(timeIntervalSince1970: 1_793_000_000))

        let tool = try #require(TranscriptItem(try block("transcript_tool_block_event")))
        #expect(tool.state == .done)
        guard case .tool(let t) = tool.kind else { Issue.record("not a tool"); return }
        #expect([t.name, t.target] == ["edit", "ios/DSHKit/Sources/DSHCore/Sync/TaskListStore.swift"])
        #expect((t.linesAdded, t.linesRemoved) == (12, 3))
        #expect(t.arguments == #"{"file_path":"ios/DSHKit/Sources/DSHCore/Sync/TaskListStore.swift"}"#)

        let failed = try #require(TranscriptItem(try block("transcript_failed_tool_block_event")))
        #expect(failed.state == .failed)
        guard case .tool(let f) = failed.kind else { Issue.record("not a tool"); return }
        #expect(f.error == "exit code 1")
        #expect(f.argumentsTruncated)
    }

    @Test func aBlockOfAnUnknownKindIsDropped() {
        var block = Dshm_V1_TranscriptBlock()
        block.blockID = "x"
        #expect(TranscriptItem(block) == nil)
    }
}

/// Rows keep their place in the transcript, and updates replace them.
@Suite struct StructuredTranscriptTests {
    func tool(_ id: String, _ state: TranscriptItem.State, added: Int = 0) -> TranscriptItem {
        TranscriptItem(id: id, taskID: "t", state: state, kind: .tool(.init(name: "edit", target: "a/b.swift", linesAdded: added)),
                       time: Date(timeIntervalSince1970: 0))
    }

    @Test func segmentsCutTheTextAtEachRow() {
        var blocks = StructuredTranscript()
        let text = "First part. Second part."
        blocks.upsert(tool("a", .running), offset: 0)
        blocks.upsert(tool("b", .running), offset: "First part. ".utf8.count)
        // The update keeps the row's first place, whatever the transcript's length now.
        let changed = blocks.upsert(tool("a", .done, added: 3), offset: 99)
        let again = blocks.upsert(tool("a", .done, added: 3), offset: 99)
        #expect(changed)
        #expect(!again, "the same block twice changes nothing")
        let segments = blocks.segments(of: text)
        #expect(segments == [
            .item(tool("a", .done, added: 3)),
            .text("First part. "),
            .item({ var b = tool("b", .running); b.offset = 12; return b }()),
            .text("Second part."),
        ])
    }

    @Test func rowsPastTheEndOfTheTextGoLast() {
        var blocks = StructuredTranscript()
        blocks.upsert(tool("a", .done), offset: 500)
        #expect(blocks.segments(of: "short").map { if case .text = $0 { "text" } else { "row" } } == ["text", "row"])
    }
}

/// The FakeBridge transcript task through the real store: blocks arrive in their place,
/// survive the cache, and a host without `transcript.v1` shows none.
@MainActor
@Suite(.serialized) struct TranscriptStoreTests {
    let storeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("dshm-s17-\(UUID().uuidString).store")

    /// Waits on the store with no polling: `waitForStore` in StoreWait.swift. A short
    /// timeout here is raised to its 30 s, so a busy machine makes the test slower, not red.
    func waitUntil(_ what: String = "", timeout: Duration = .seconds(5), sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
        await waitForStore(what, timeout: max(timeout, .seconds(30)), sourceLocation: sourceLocation, condition)
    }

    func launch(_ host: FakeHost) throws -> TaskListStore {
        let connection = HostConnection(endpoint: .localBridge(), transport: host.factory)
        let store = TaskListStore(
            cache: try TaskCache(url: storeURL), hosts: [.init(key: "fake:127.0.0.1:47801", connection: connection)], prompt: "Fix the failing test.")
        store.backoff = (.milliseconds(20), .milliseconds(100))
        // Long enough for a loaded Mac (other slices' simulators): a short wait made send() nil once.
        store.sendWaitsFor = .seconds(5)
        return store
    }

    @Test func transcriptTaskShowsThinkingAndToolRowsInPlace() async throws {
        let host = FakeHost(script: FakeTranscript.script(chunkDelay: .milliseconds(1)), extraCapabilities: [FakeTranscript.capability])
        let store = try launch(host)
        store.foreground()
        let key = try #require(await store.send())
        try await waitUntil("the task ends") { store.task(key)?.state == .completed }
        let row = try #require(store.task(key))
        let reply = FakeTranscript.script().reply
        #expect(row.transcript == reply.joined())
        #expect(row.blocks.items.map(\.id) == ["thinking-1-0", "call-read", "call-edit", "call-bash"])
        #expect(row.blocks.items.allSatisfy { $0.state == .done })
        #expect(row.blocks.items[0].thinkingSeconds == 8)
        #expect(row.blocks.items[0].offset == 0)
        #expect(row.blocks.items[1].offset == reply.prefix(2).joined().utf8.count)
        guard case .tool(let edit) = row.blocks.items[2].kind else { Issue.record("not a tool"); return }
        #expect((edit.linesAdded, edit.linesRemoved) == (12, 3))
        let rows = row.blocks.segments(of: row.transcript).map { segment -> String in
            switch segment {
            case .text: "text"
            case .item(let item): item.id
            }
        }
        #expect(rows == ["thinking-1-0", "text", "call-read", "text", "call-edit", "text", "call-bash", "text"])
        store.background()

        // The cache keeps the rows (offline, after a relaunch).
        let reopened = try launch(FakeHost(reachable: false))
        #expect(reopened.task(key)?.blocks == row.blocks)
    }

    @Test func withoutTheCapabilityThereAreNoRows() async throws {
        // This fake host sends blocks anyway; the app still shows none without `transcript.v1`.
        let host = FakeHost(script: FakeTranscript.script(chunkDelay: .milliseconds(1)))
        let store = try launch(host)
        store.foreground()
        let key = try #require(await store.send())
        try await waitUntil("the task ends") { store.task(key)?.state == .completed }
        #expect(store.hosts.first?.supports(.transcript) == false)
        #expect(store.task(key)?.blocks.isEmpty == true)
        #expect(store.task(key)?.transcript == FakeTranscript.script().reply.joined())
        store.background()
    }
}
