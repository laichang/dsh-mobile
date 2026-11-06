import DSHCore
import DSHTestSupport
import Foundation
import Testing

/// S18 · the approval sheet's FakeBridge scenario (`-DSHMFakeBridge approvals -DSHMFakeAsk …`):
/// a running task asks for an approval, so a new approval arrives in an open session; and an
/// answer from another client (the Web) reaches the phone only as `ApprovalResolved`.
@MainActor
@Suite(.serialized) struct ApprovalSheetFakeTests {
    let storeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("dshm-s18-\(UUID().uuidString).store")

    func waitUntil(_ what: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now > deadline { Issue.record("timed out: \(what)"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static let asked = FakeBridge.PendingApproval(
        title: "", tool: "bash", arguments: #"{"command":"rm -rf ~/Desktop/Q3/tmp"}"#, reason: "Remove the images")

    func launch(_ host: FakeHost) throws -> TaskListStore {
        let connection = HostConnection(endpoint: .localBridge(), channel: PlaintextChannel(), transport: host.factory)
        let store = TaskListStore(container: try TaskCache.container(url: storeURL),
                                  hosts: [.init(key: "fake:home", connection: connection)])
        store.backoff = (.milliseconds(20), .milliseconds(100))
        return store
    }

    @Test(arguments: [true, false]) func aRunningTaskAsksAndAWebAnswerResolvesIt(allow: Bool) async throws {
        var script = FakeBridge.Script(reply: ["Reply ", "from ", "Home Mac"], chunkDelay: .milliseconds(10))
        script.ask = ("Clean up", Self.asked)
        let host = FakeHost(script: script, hostName: "Home Mac")
        let store = try launch(host)
        store.foreground()
        try await waitUntil("online") { store.hosts.first?.reachability == .online }
        store.prompt = "Clean up the Q3 slides"
        let key = try #require(await store.send())

        try await waitUntil("asked") { store.task(key)?.approvals.count == 1 && store.task(key)?.state == .waitingOnUser }
        let asking = try #require(store.task(key))
        #expect(asking.state == .waitingOnUser)
        #expect(asking.approvals.first?.command == "rm -rf ~/Desktop/Q3/tmp")

        host.answerFromElsewhere(allow: allow)
        try await waitUntil("resolved") { store.task(key)?.approvals.isEmpty == true }
        try await waitUntil("completed") { store.task(key)?.state == .completed }
        #expect(store.task(key)?.transcript == "Reply from Home Mac")
    }
}
