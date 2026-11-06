import DSHCore
import DSHProtocol
import DSHTestSupport
import Foundation
import SwiftData
import Testing

/// S16 · the FakeBridge coding task behind the session-page UI tests: it stops at "3 / 5" with
/// its whole reply, keeps running, and stops like the real bridge when it is interrupted.
@MainActor
@Suite(.serialized) struct S16CodingTaskTests {
    let storeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("dshm-s16-\(UUID().uuidString).store")

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
            hosts: [.init(key: "fake:127.0.0.1:47801", connection: connection)], prompt: "Fix the failing test.")
        store.backoff = (.milliseconds(20), .milliseconds(100))
        // send() returns as soon as the host is online; under load the first connect can take
        // longer than 500 ms, and then send() gave nil (S20 review, 2026-11-07).
        store.sendWaitsFor = .seconds(5)
        return store
    }

    @Test func codingTaskHoldsAtThreeOfFiveAndStopsOnInterrupt() async throws {
        var script = FakeBridge.Script.codingTask(delay: .milliseconds(10))
        script.chunkDelay = .milliseconds(1)
        let host = FakeHost(script: script)
        let store = try launch(host)
        store.foreground()
        let key = try #require(await store.send())
        try await waitUntil("the whole reply") { store.task(key)?.transcript == FakeBridge.codingReply + "\n" }
        let running = try #require(store.task(key))
        #expect(running.state == .running)
        #expect(running.milestones.completedCount == 3)
        #expect(running.milestones.todos.count == 5)
        #expect(running.milestones.activeTodo?.content == "Run the tests")
        #expect(store.hosts.first?.capabilities.contains(DSHProtocolInfo.interruptCapability) == true)
        // It stays running: no closing milestone, no end.
        try await Task.sleep(for: .milliseconds(200))
        #expect(store.task(key)?.state == .running)

        try await store.interrupt(running)
        try await waitUntil("interrupted") { store.task(key)?.state == .interrupted }
        try await waitUntil("interrupted milestone") { store.task(key)?.milestones.current?.kind == .interrupted }
        #expect(store.task(key)?.milestones.completedCount == 3)
        store.background()
    }
}
