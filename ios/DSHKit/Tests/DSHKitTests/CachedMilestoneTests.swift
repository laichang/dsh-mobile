import DSHCore
import DSHTestSupport
import Foundation
import SwiftData
import Testing

/// S2 × S3 seam (S2 landed second, PLAN.md §5 S2): a task's milestones are cached with it, so the
/// card survives kill/reopen, and the gap is replayed by Resume exactly once.
@MainActor
@Suite(.serialized) struct CachedMilestoneTests {
    let storeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("dshm-s2s3-\(UUID().uuidString).store")

    func waitUntil(_ what: String = "", timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now > deadline { Issue.record("timed out: \(what)"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func launch(_ host: FakeHost) throws -> TaskListStore {
        let connection = HostConnection(endpoint: .localBridge(), channel: PlaintextChannel(), transport: host.factory)
        let store = TaskListStore(
            container: try TaskCache.container(url: storeURL),
            hosts: [.init(key: "fake:127.0.0.1:47801", connection: connection)], prompt: "Three steps.")
        store.backoff = (.milliseconds(20), .milliseconds(100))
        store.sendWaitsFor = .milliseconds(500)
        return store
    }

    static let kinds: [Milestone.Kind] = [.started, .planned, .todoStarted, .todoDone, .todoStarted, .todoDone,
                                          .todoStarted, .todoDone, .finished]

    @Test func milestonesSurviveKillAndReopenAndTheGapIsReplayed() async throws {
        let host = FakeHost(script: .threeTodos(delay: .milliseconds(60)))
        var store: TaskListStore? = try launch(host)
        store?.foreground()
        let key = try #require(await store?.send())
        try await waitUntil("a few milestones") { (store?.task(key)?.milestones.milestones.count ?? 0) >= 3 }
        store?.background()
        store = nil
        try await Task.sleep(for: .milliseconds(900)) // the task finishes on the host meanwhile

        // Before any connection: the card's milestones come from the cache.
        let reopened = try launch(host)
        let cached = try #require(reopened.task(key)?.milestones)
        #expect(cached.milestones.count >= 3)
        #expect(cached.todos.map(\.content) == FakeBridge.threeTodoItems)
        #expect(cached.completedCount < 3)

        // After Resume: the gap is filled, each milestone exactly once, in order.
        reopened.foreground()
        try await waitUntil("completed") { reopened.task(key)?.state == .completed }
        try await waitUntil("finished milestone") { reopened.task(key)?.milestones.current?.kind == .finished }
        let timeline = try #require(reopened.task(key)?.milestones)
        #expect(timeline.milestones.map(\.kind) == Self.kinds)
        #expect(timeline.milestones.map(\.seq) == Array(1...UInt64(Self.kinds.count)))
        #expect(timeline.completedCount == 3)
        reopened.background()

        // A third launch with the host gone: the whole timeline, from the cache alone.
        let offline = try launch(FakeHost(reachable: false))
        #expect(offline.task(key)?.milestones == timeline)
    }

    @Test func tasksWithoutMilestonesCacheNone() async throws {
        let host = FakeHost(script: .init(reply: ["ok"], chunkDelay: .milliseconds(5)))
        let store = try launch(host)
        store.foreground()
        let key = try #require(await store.send())
        try await waitUntil("completed") { store.task(key)?.state == .completed }
        #expect(store.task(key)?.milestones.isEmpty == true)
    }
}
