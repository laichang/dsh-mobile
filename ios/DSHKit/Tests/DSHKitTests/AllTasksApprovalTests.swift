import DSHCore
import DSHTestSupport
import Foundation
import Testing

/// 所有任务: a FakeHost that starts with a task waiting on an approval (the scenario of
/// `-DSHMFakeBridge approvals`). An answer from the list resolves it, and the task runs on.
@MainActor
@Suite(.serialized) struct AllTasksApprovalTests {
    let storeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("dshm-s15-\(UUID().uuidString).store")

    /// Waits on the store with no polling: `waitForStore` in StoreWait.swift. A short
    /// timeout here is raised to its 30 s, so a busy machine makes the test slower, not red.
    func waitUntil(_ what: String, timeout: Duration = .seconds(5), sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
        await waitForStore(what, timeout: max(timeout, .seconds(30)), sourceLocation: sourceLocation, condition)
    }

    func launch(_ host: FakeHost) throws -> TaskListStore {
        let connection = HostConnection(endpoint: .localBridge(), channel: PlaintextChannel(), transport: host.factory)
        let store = TaskListStore(container: try TaskCache.container(url: storeURL),
                                  hosts: [.init(key: "fake:home", connection: connection)])
        store.backoff = (.milliseconds(20), .milliseconds(100))
        return store
    }

    static let approval = FakeBridge.PendingApproval(
        title: "Turn the Q3 report into slides", tool: "bash",
        arguments: #"{"command":"rm -rf ~/Desktop/Q3/tmp"}"#, reason: "Remove the images")

    @Test(arguments: [true, false]) func answerFromTheListResolvesTheSeededApproval(allow: Bool) async throws {
        let host = FakeHost(script: .init(reply: ["Reply ", "from ", "Home Mac"], chunkDelay: .milliseconds(10)),
                            hostName: "Home Mac", approvals: [Self.approval])
        let store = try launch(host)
        store.foreground()
        // The seeded task can arrive before the host is marked online; an answer needs it online.
        try await waitUntil("seeded approval") {
            store.sections.waitingOnMe.first?.approvals.count == 1 && store.hosts.first?.reachability == .online
        }
        let row = try #require(store.sections.waitingOnMe.first)
        #expect(row.title == Self.approval.title)
        let pending = try #require(row.approvals.first)
        #expect(pending.tool == "bash")
        #expect(pending.command == "rm -rf ~/Desktop/Q3/tmp")
        #expect(pending.reason == "Remove the images")

        try await store.answerApproval(pending, hostKey: row.hostKey, allow: allow)
        try await waitUntil("completed") { store.task(row.key)?.state == .completed }
        let done = try #require(store.task(row.key))
        #expect(done.approvals.isEmpty)
        #expect(done.transcript == "Reply from Home Mac")
        #expect(store.sections.waitingOnMe.isEmpty)
        #expect(store.sections.done.map(\.key) == [row.key])
    }
}
