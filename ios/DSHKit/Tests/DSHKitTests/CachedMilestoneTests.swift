import DSHCore
import DSHTestSupport
import Foundation
import SwiftData
import Testing

/// The durable list with milestones: a task's milestones are cached with it, so the
/// card survives kill/reopen, and the gap is replayed by Resume exactly once.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2))) struct CachedMilestoneTests {
    let storeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("dshm-cached-milestones-\(UUID().uuidString).store")

    func launch(_ host: FakeHost) throws -> TaskListStore {
        let connection = HostConnection(endpoint: .localBridge(), transport: host.factory)
        let store = TaskListStore(
            container: try TaskCache.container(url: storeURL),
            hosts: [.init(key: "fake:127.0.0.1:47801", connection: connection)], prompt: "Three steps.")
        store.backoff = (.milliseconds(20), .milliseconds(100))
        // send() returns as soon as the host is online; under load the first connect can take
        // longer than 500 ms, and then send() gave nil. The 30 s
        // are only a deadline for a busy machine.
        store.sendWaitsFor = .seconds(30)
        return store
    }

    static let kinds: [Milestone.Kind] = [.started, .planned, .todoStarted, .todoDone, .todoStarted, .todoDone,
                                          .todoStarted, .todoDone, .finished]

    @Test func milestonesSurviveKillAndReopenAndTheGapIsReplayed() async throws {
        let host = FakeHost(script: .threeTodos(delay: .milliseconds(60)))
        var store: TaskListStore? = try launch(host)
        store?.foreground()
        let key = try #require(await store?.send())
        await waitForStore("a few milestones") { (store?.task(key)?.milestones.milestones.count ?? 0) >= 3 }
        let taskID = try #require(store?.task(key)?.taskID)
        store?.background()
        store = nil
        await host.ended(taskID) // the task finishes on the host meanwhile

        // Before any connection: the card's milestones come from the cache.
        let reopened = try launch(host)
        let cached = try #require(reopened.task(key)?.milestones)
        #expect(cached.milestones.count >= 3)
        #expect(cached.todos.map(\.content) == FakeBridge.threeTodoItems)
        #expect(cached.completedCount < 3)

        // After Resume: the gap is filled, each milestone exactly once, in order.
        reopened.foreground()
        await waitForStore("completed") { reopened.task(key)?.state == .completed }
        await waitForStore("finished milestone") { reopened.task(key)?.milestones.current?.kind == .finished }
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
        await waitForStore("completed") { store.task(key)?.state == .completed }
        #expect(store.task(key)?.milestones.isEmpty == true)
    }
}
