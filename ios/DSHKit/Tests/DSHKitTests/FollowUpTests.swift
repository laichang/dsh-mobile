@testable import DSHCore
import DSHProtocol
import DSHTestSupport
import Foundation
import SwiftData
import Testing

/// A follow-up in a finished session, against `FakeHost` (`conversation.v1`): the user
/// message and the next turn go under the first answer, and a reconnect replays the same page.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2))) struct FollowUpTests {
    static let first = ["First ", "answer."]
    static let second = ["Second ", "answer."]

    func launch(_ host: FakeHost, url: URL) throws -> TaskListStore {
        let connection = HostConnection(endpoint: .localBridge(), transport: host.factory)
        let store = TaskListStore(container: try TaskCache.container(url: url),
                                  hosts: [.init(key: "fake:127.0.0.1:47801", connection: connection)], prompt: "Say hello.")
        store.backoff = (.milliseconds(20), .milliseconds(100))
        store.sendWaitsFor = .seconds(30) // a deadline: send() returns once the host is online
        return store
    }

    static func cacheURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("dshm-followup-\(UUID().uuidString).store")
    }

    func host(chunkDelay: Duration = .milliseconds(10)) -> FakeHost {
        var script = FakeBridge.Script(reply: Self.first, chunkDelay: chunkDelay)
        script.followUpReply = Self.second
        return FakeHost(script: script)
    }

    /// The page as the session page draws it: text and user messages, in order.
    static func page(_ row: TaskListStore.TaskRow) -> [String] {
        row.blocks.segments(of: row.transcript).map { segment in
            switch segment {
            case .text(let text): "agent: \(text)"
            case .item(let item):
                if case .userMessage(let text) = item.kind { "user: \(text)" } else { "row: \(item.id)" }
            }
        }
    }

    @Test func followUpOnACompletedTaskAddsTheMessageRunsAndAppendsTheReply() async throws {
        let host = host(chunkDelay: .milliseconds(60))
        let store = try launch(host, url: Self.cacheURL())
        store.foreground()
        defer { store.background() }
        let key = try #require(await store.send())
        await waitForStore("first turn done") { store.task(key)?.state == .completed }
        let done = try #require(store.task(key))
        #expect(store.canFollowUp(done))

        try await store.sendFollowUp("  And once more?  ", for: done)
        #expect(host.followUps == ["And once more?"])
        await waitForStore("running again") { store.task(key)?.state == .running }
        #expect(Self.page(try #require(store.task(key))).prefix(2) == ["agent: First answer.", "user: And once more?"])
        #expect(!store.canFollowUp(try #require(store.task(key))))

        await waitForStore("second turn done") { store.task(key)?.state == .completed }
        let row = try #require(store.task(key))
        #expect(Self.page(row) == ["agent: First answer.", "user: And once more?", "agent: Second answer."])
        #expect(row.transcript == "First answer.Second answer.")
        #expect(row.blocks.followUpCount == 1)
        #expect(store.sections.done.map(\.key) == [key])
        // A finished conversation keeps its streamed transcript, where the message sits.
        var journal = Dshm_V1_SessionMessage()
        journal.text = "First answer.\n\nSecond answer."
        #expect(row.singleTurnTranscript([SessionMessage(journal)]) == row.transcript)
    }

    @Test func aReconnectReplaysTheSameTranscript() async throws {
        let host = host()
        let store = try launch(host, url: Self.cacheURL())
        store.foreground()
        let key = try #require(await store.send())
        await waitForStore("first turn done") { store.task(key)?.state == .completed }
        try await store.sendFollowUp("Again?", for: try #require(store.task(key)))
        await waitForStore("second turn done") {
            store.task(key)?.state == .completed && store.task(key)?.transcript == "First answer.Second answer."
        }
        let live = Self.page(try #require(store.task(key)))
        store.background()

        // Another phone, or this one after its cache is gone: the whole log replays.
        let fresh = try launch(host, url: Self.cacheURL())
        fresh.foreground()
        defer { fresh.background() }
        await waitForStore("replayed") { fresh.task(key)?.state == .completed && fresh.task(key)?.blocks.followUpCount == 1 }
        await waitForStore("replayed text") { fresh.task(key)?.transcript == "First answer.Second answer." }
        let replayed = Self.page(try #require(fresh.task(key)))
        #expect(replayed == live, "replayed \(replayed), live \(live)")
    }

    @Test func killAndReopenDuringTheFollowUpFillsTheGapOnce() async throws {
        let host = host(chunkDelay: .milliseconds(80))
        let url = Self.cacheURL()
        var store: TaskListStore? = try launch(host, url: url)
        store?.foreground()
        let key = try #require(await store?.send())
        await waitForStore("first turn done") { store?.task(key)?.state == .completed }
        try await store?.sendFollowUp("Again?", for: try #require(store?.task(key)))
        await waitForStore("follow-up seen") { store?.task(key)?.blocks.followUpCount == 1 }
        let taskID = try #require(store?.task(key)?.taskID)
        store?.background()
        store = nil
        await host.ended(taskID, count: 2) // the turn finishes on the host meanwhile

        let reopened = try launch(host, url: url)
        reopened.foreground()
        defer { reopened.background() }
        await waitForStore("gap filled") { reopened.task(key)?.state == .completed && reopened.task(key)?.transcript == "First answer.Second answer." }
        #expect(Self.page(try #require(reopened.task(key))) == ["agent: First answer.", "user: Again?", "agent: Second answer."])
    }

    @Test func withoutTheCapabilityThereIsNoFollowUp() async throws {
        let host = FakeHost(script: .init(reply: Self.first, chunkDelay: .milliseconds(10)))
        let store = try launch(host, url: Self.cacheURL())
        store.foreground()
        defer { store.background() }
        let key = try #require(await store.send())
        await waitForStore("done") { store.task(key)?.state == .completed }
        let row = try #require(store.task(key))
        #expect(!store.canFollowUp(row))
        await #expect(throws: HostConnectionError.self) { try await store.sendFollowUp("Again?", for: row) }
        #expect(host.followUps.isEmpty)
    }
}
