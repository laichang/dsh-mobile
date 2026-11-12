import DSHCore
import DSHFeatures
import DSHProtocol
import DSHTestSupport
import Foundation
import Testing

/// The FakeBridge coding task behind the session-page UI tests: it stops at "3 / 5" with
/// its whole reply, keeps running, and stops like the real bridge when it is interrupted.
@MainActor
@Suite(.serialized) struct CodingTaskTests {
    let storeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("dshm-s16-\(UUID().uuidString).store")

    func launch(_ host: FakeHost) throws -> TaskListStore {
        let connection = HostConnection(endpoint: .localBridge(), transport: host.factory)
        let store = TaskListStore(
            cache: try TaskCache(url: storeURL), hosts: [.init(key: "fake:127.0.0.1:47801", connection: connection)], prompt: "Fix the failing test.")
        store.backoff = (.milliseconds(20), .milliseconds(100))
        // send() returns as soon as the host is online; under load the first connect can take
        // longer than 500 ms, and then send() gave nil. The 30 s
        // are only a deadline for a busy machine.
        store.sendWaitsFor = .seconds(30)
        return store
    }

    @Test func codingTaskHoldsAtThreeOfFiveAndStopsOnInterrupt() async throws {
        var script = FakeBridge.Script.codingTask(delay: .milliseconds(10))
        script.chunkDelay = .milliseconds(1)
        let host = FakeHost(script: script)
        let store = try launch(host)
        store.foreground()
        let key = try #require(await store.send())
        await waitForStore("the whole reply") { store.task(key)?.transcript == FakeBridge.codingReply + "\n" }
        let running = try #require(store.task(key))
        #expect(running.state == .running)
        #expect(running.milestones.completedCount == 3)
        #expect(running.milestones.todos.count == 5)
        #expect(running.milestones.activeTodo?.content == "Run the tests")
        #expect(store.hosts.first?.supports(.interrupt) == true)

        // It stays running until the stop: it ends interrupted, not completed, and its timeline
        // has no closing milestone (no fixed sleep to watch it stay running).
        try await store.interrupt(running)
        await waitForStore("interrupted") { store.task(key)?.state == .interrupted }
        await waitForStore("interrupted milestone") { store.task(key)?.milestones.current?.kind == .interrupted }
        let stopped = try #require(store.task(key))
        #expect(stopped.milestones.completedCount == 3)
        #expect(!stopped.milestones.milestones.contains { $0.kind == .finished || $0.kind == .failed })
        store.background()
    }
}
