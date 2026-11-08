import DSHCore
import DSHProtocol
import DSHTestSupport
import Foundation
import SwiftProtobuf
import Testing

/// S27 · the done footer's 用时 counts the latest turn only (ARCHITECTURE D76).
@MainActor
@Suite(.serialized) struct LastTurnTests {
    let storeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("dshm-s27-\(UUID().uuidString).store")

    /// Waits on the store with no polling (S12): `waitForStore` in StoreWait.swift. A short
    /// timeout here is raised to its 30 s, so a busy machine makes the test slower, not red.
    func waitUntil(_ what: String, timeout: Duration = .seconds(5), sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
        await waitForStore(what, timeout: max(timeout, .seconds(30)), sourceLocation: sourceLocation, condition)
    }

    static func fixture(_ name: String) throws -> Dshm_V1_TaskSummary {
        let bytes = try Data(contentsOf: GoldenFixtures.fixturesDir.appending(path: "\(name).binpb"))
        return try Dshm_V1_Frame(serializedBytes: bytes).event.taskUpserted.task
    }

    /// The Swift half of the S27 golden fixture (bridge/test/drawer.test.ts); S14's fixture is the
    /// same session from an older bridge, without the field.
    @Test func goldenWebSessionCarriesItsLatestTurnStart() throws {
        let web = try Self.fixture("s27_web_session_upserted_event")
        #expect(web.hasTurnStartedAtMs && web.turnStartedAtMs == 1_793_000_000_000)
        let old = try Self.fixture("s14_web_session_upserted_event")
        #expect(!old.hasTurnStartedAtMs)
    }

    /// Through a host and the cache: the row's 用时 starts at the latest turn, not at the first.
    @Test func rowCountsFromTheLatestTurnAndFallsBackToCreation() async throws {
        let now: Int64 = 1_793_000_000_000
        var old = FakeTurns.summary(now: now)
        old.taskID = "old-bridge"
        old.clearTurnStartedAtMs()
        let host = FakeHost(hostName: "Mac", seed: [FakeTurns.summary(now: now), old])
        let store = TaskListStore(container: try TaskCache.container(url: storeURL), hosts: [.init(key: "fake:mac",
            connection: HostConnection(endpoint: .localBridge(), channel: PlaintextChannel(), transport: host.factory))])
        store.foreground()
        try await waitUntil("both sessions") { store.tasks.count == 2 }
        let turns = try #require(store.task("fake:mac\n\(FakeTurns.taskID)"))
        #expect(turns.updatedAt.timeIntervalSince(turns.lastTurnStart) == Double(FakeTurns.lastTurn) / 1000)
        #expect(turns.updatedAt.timeIntervalSince(turns.createdAt) == Double(FakeTurns.sinceFirstTurn) / 1000)
        let fallback = try #require(store.task("fake:mac\nold-bridge"))
        #expect(fallback.turnStartedAt == nil)
        #expect(fallback.lastTurnStart == fallback.createdAt)
    }
}
