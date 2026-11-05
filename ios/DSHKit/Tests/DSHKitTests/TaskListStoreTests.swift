import DSHCore
import DSHTestSupport
import Foundation
import SwiftData
import Testing

/// S2 · durable list + resume against `FakeHost` (PLAN.md §5).
@MainActor
@Suite struct TaskListStoreTests {
    let storeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("dshm-s2-\(UUID().uuidString).store")

    func waitUntil(_ what: String = "", timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now > deadline { Issue.record("timed out: \(what)"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A store as the app builds it on launch: the cache on disk, one host, nothing running yet.
    func launch(_ host: FakeHost, prompt: String = "Count to five.") throws -> TaskListStore {
        let connection = HostConnection(endpoint: .localBridge(), channel: PlaintextChannel(), transport: host.factory)
        let store = TaskListStore(
            container: try TaskCache.container(url: storeURL),
            hosts: [.init(key: "fake:127.0.0.1:47801", connection: connection)], prompt: prompt)
        store.backoff = (.milliseconds(20), .milliseconds(100))
        store.sendWaitsFor = .milliseconds(500)
        return store
    }

    static let reply = ["one ", "two ", "three ", "four ", "five"]
    static let fullReply = reply.joined()

    @Test func streamsATaskIntoTheUnifiedList() async throws {
        let host = FakeHost(script: .init(reply: Self.reply, chunkDelay: .milliseconds(10)))
        let store = try launch(host)
        store.foreground()
        let key = try #require(await store.send())
        #expect(store.prompt.isEmpty)
        try await waitUntil("completed") { store.task(key)?.state == .completed }
        let task = try #require(store.task(key))
        #expect(task.title == "Count to five.")
        #expect(task.transcript == Self.fullReply)
        #expect(task.hostName == "FakeBridge Mac")
        #expect(store.sections.done.map(\.key) == [key])
        #expect(store.sections.running.isEmpty)
        #expect(store.hosts.map(\.reachability) == [.online])
    }

    @Test func killAndReopenKeepsTheListAndFillsTheGapFromTheBridge() async throws {
        let host = FakeHost(script: .init(reply: Self.reply, chunkDelay: .milliseconds(60)))
        var store: TaskListStore? = try launch(host)
        store?.foreground()
        let key = try #require(await store?.send())
        try await waitUntil("some text") { !(store?.task(key)?.transcript.isEmpty ?? true) }
        // The user swipes the app away: iOS backgrounds it, then it's gone.
        store?.background()
        store = nil
        try await Task.sleep(for: .milliseconds(500)) // the task finishes on the host meanwhile

        let reopened = try launch(host)
        // Before any connection: the list and the transcript so far come from the cache.
        let cached = try #require(reopened.task(key))
        #expect(cached.title == "Count to five.")
        #expect(cached.state == .running)
        #expect(!cached.transcript.isEmpty && cached.transcript != Self.fullReply)
        #expect(Self.fullReply.hasPrefix(cached.transcript))

        reopened.foreground()
        try await waitUntil("gap filled") { reopened.task(key)?.state == .completed }
        // The gap came from the bridge, exactly once: no repeated or missing text.
        #expect(reopened.task(key)?.transcript == Self.fullReply)
        #expect(reopened.sections.done.map(\.key) == [key])
    }

    @Test func reconnectsAfterTheConnectionDropsAndReplaysOnlyTheGap() async throws {
        let host = FakeHost(script: .init(reply: Self.reply, chunkDelay: .milliseconds(40)))
        let store = try launch(host)
        store.foreground()
        let key = try #require(await store.send())
        try await waitUntil("some text") { !(store.task(key)?.transcript.isEmpty ?? true) }
        host.dropConnections()
        try await waitUntil("reconnected") { store.hosts.first?.reachability == .online && host.connectionCount == 1 }
        try await waitUntil("completed") { store.task(key)?.state == .completed }
        #expect(store.task(key)?.transcript == Self.fullReply)
    }

    @Test func unreachableHostIsNamedAsOffline() async throws {
        let host = FakeHost(script: .init(reply: ["ok"], chunkDelay: .milliseconds(5)))
        let store = try launch(host)
        store.foreground()
        try await waitUntil("online") { store.hosts.first?.reachability == .online }
        host.setReachable(false)
        try await waitUntil("offline") { store.hosts.first?.reachability == .offline }
        #expect(store.offlineHosts.map(\.name) == ["FakeBridge Mac"])
        #expect(await store.send() == nil)
        #expect(store.sendError?.contains("FakeBridge Mac is offline") == true)

        host.setReachable(true)
        store.foreground() // coming back to the foreground retries at once
        try await waitUntil("online again") { store.hosts.first?.reachability == .online }
        #expect(store.offlineHosts.isEmpty)
    }

    @Test func neverReachedHostIsNamedByItsAddress() async throws {
        let store = try launch(FakeHost(reachable: false))
        store.foreground()
        try await waitUntil("offline") { store.hosts.first?.reachability == .offline }
        #expect(store.offlineHosts.map(\.name) == ["127.0.0.1:47801"])
    }

    @Test func bridgeRestartMarksTasksItLostAsFailed() async throws {
        let host = FakeHost(script: .init(reply: Self.reply, chunkDelay: .milliseconds(80)))
        let store = try launch(host)
        store.foreground()
        let key = try #require(await store.send())
        try await waitUntil("some text") { !(store.task(key)?.transcript.isEmpty ?? true) }
        host.restart()
        try await waitUntil("lost") { store.task(key)?.state == .failed }
        #expect(store.task(key)?.message.contains("restarted") == true)
        // The new bridge's tasks still arrive.
        store.prompt = "again"
        let next = try #require(await store.send())
        try await waitUntil("completed") { store.task(next)?.state == .completed }
        #expect(store.task(next)?.transcript == Self.fullReply)
    }
}
