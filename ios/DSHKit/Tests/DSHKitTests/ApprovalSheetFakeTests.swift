import DSHCore
import DSHFeatures
import DSHTestSupport
import Foundation
import Testing

/// The approval sheet's FakeBridge scenario (`-DSHMFakeBridge approvals -DSHMFakeAsk …`):
/// a running task asks for an approval, so a new approval arrives in an open session; and an
/// answer from another client (the Web) reaches the phone only as `ApprovalResolved`.
@MainActor
@Suite(.serialized) struct ApprovalSheetFakeTests {
    let storeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("dshm-s18-\(UUID().uuidString).store")

    /// Waits on the store with no polling: `waitForStore` in StoreWait.swift. A short
    /// timeout here is raised to its 30 s, so a busy machine makes the test slower, not red.
    func waitUntil(_ what: String, timeout: Duration = .seconds(5), sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
        await waitForStore(what, timeout: max(timeout, .seconds(30)), sourceLocation: sourceLocation, condition)
    }

    static let asked = FakeBridge.PendingApproval(
        title: "", tool: "bash", arguments: #"{"command":"rm -rf ~/Desktop/Q3/tmp"}"#, reason: "Remove the images")

    func launch(_ host: FakeHost) throws -> TaskListStore {
        let connection = HostConnection(endpoint: .localBridge(), transport: host.factory)
        let store = TaskListStore(cache: try TaskCache(url: storeURL), hosts: [.init(key: "fake:home", connection: connection)])
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
        store.composer.prompt = "Clean up the Q3 slides"
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
