@testable import DSHCore
import DSHProtocol
import DSHTestSupport
import Foundation
import SwiftData
import Testing

/// D104, D110 · a model failure, against `FakeHost`: the task ends failed with DSH's text and its
/// failure class, the outcome picks the app's own words for `AUTH` and `QUOTA`, and a new message
/// in the same session continues the task (`conversation.v1`).
@MainActor
@Suite(.serialized) struct ModelFailureTests {
    func waitUntil(_ what: String = "", timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now > deadline { Issue.record("timed out: \(what)"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func launch(_ host: FakeHost, url: URL = Self.cacheURL()) throws -> TaskListStore {
        let connection = HostConnection(endpoint: .localBridge(), channel: PlaintextChannel(), transport: host.factory)
        let store = TaskListStore(container: try TaskCache.container(url: url),
                                  hosts: [.init(key: "fake:127.0.0.1:47801", connection: connection)], prompt: "Say hello.")
        store.backoff = (.milliseconds(20), .milliseconds(100))
        store.sendWaitsFor = .seconds(10)
        return store
    }

    static func cacheURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("dshm-model-failure-\(UUID().uuidString).store")
    }

    /// A provider with no balance: DSH ends the turn with `QUOTA`. After the top-up a follow-up completes.
    func noBalance(_ message: String = "Insufficient Balance", code: String = "QUOTA") -> FakeHost {
        var script = FakeBridge.Script(reply: [], chunkDelay: .milliseconds(10), failWith: message)
        script.failureCode = code
        script.followUpReply = ["Topped ", "up."]
        return FakeHost(script: script)
    }

    @Test func aModelFailureEndsTheTaskFailedWithTheTextAndCodeOfDSH() async throws {
        let store = try launch(noBalance())
        store.foreground()
        defer { store.background() }
        let key = try #require(await store.send())
        try await waitUntil("failed") { store.task(key)?.state == .failed }
        let row = try #require(store.task(key))
        #expect(row.message == "Insufficient Balance")
        #expect(row.failureCode == "QUOTA")
        let outcome = try #require(TaskOutcome(row))
        #expect(outcome.kind == .failed)
        #expect(outcome.error == "Insufficient Balance")
        #expect(outcome.code == "QUOTA")
        #expect(outcome.ownCopy == .quotaExhausted)
    }

    @Test func theAppUsesItsOwnWordsOnlyForAuthAndQuota() async throws {
        let cases: [(String, TaskOutcome.OwnCopy?)] = [
            ("AUTH", .invalidKey), ("QUOTA", .quotaExhausted), ("ACCOUNT_QUOTA", .quotaExhausted),
            ("RATE_LIMIT", nil), ("HTTP_404", nil), ("INVALID_REQUEST", nil), ("", nil),
        ]
        for (code, copy) in cases {
            var row = Self.row(state: .failed, message: "Provider text")
            row.failureCode = code
            let outcome = try #require(TaskOutcome(row))
            #expect(outcome.ownCopy == copy, "code \(code)")
            #expect(outcome.error == "Provider text")
        }
        // A stopped or completed task has no failure, whatever the row says.
        var done = Self.row(state: .completed, message: "")
        done.failureCode = "QUOTA"
        #expect(TaskOutcome(done)?.ownCopy == nil)
        #expect(TaskOutcome(done)?.code == "")
    }

    @Test func aNewMessageAfterTheFailureContinuesTheSameSession() async throws {
        let host = noBalance()
        let store = try launch(host)
        store.foreground()
        defer { store.background() }
        let key = try #require(await store.send())
        try await waitUntil("failed") { store.task(key)?.state == .failed }
        let failed = try #require(store.task(key))
        #expect(store.canFollowUp(failed))

        try await store.sendFollowUp("I topped up. Go on.", for: failed)
        #expect(host.followUps == ["I topped up. Go on."])
        try await waitUntil("running again") { store.task(key)?.state == .running }
        #expect(store.task(key)?.failureCode == "")
        try await waitUntil("completed") { store.task(key)?.state == .completed }
        let row = try #require(store.task(key))
        #expect(row.taskID == failed.taskID)
        #expect(row.transcript == "Topped up.")
        #expect(row.blocks.followUpCount == 1)
        #expect(row.message == "" && row.failureCode == "")
        #expect(TaskOutcome(row)?.kind == .done)
    }

    @Test func aReconnectKeepsTheFailureCode() async throws {
        let host = noBalance("Authentication Fails, Your api key: ****-key is invalid", code: "AUTH")
        let store = try launch(host)
        store.foreground()
        let key = try #require(await store.send())
        try await waitUntil("failed") { store.task(key)?.state == .failed }
        store.background()

        // Another phone, or this one after its cache is gone: the host's list and log say the same.
        let fresh = try launch(host)
        fresh.foreground()
        defer { fresh.background() }
        try await waitUntil("replayed") { fresh.task(key)?.failureCode == "AUTH" }
        #expect(fresh.task(key)?.state == .failed)
        #expect(TaskOutcome(try #require(fresh.task(key)))?.ownCopy == .invalidKey)
    }

    static func row(state: TaskState, message: String) -> TaskListStore.TaskRow {
        TaskListStore.TaskRow(
            key: "h\nt", hostKey: "h", hostName: "h", taskID: "t", title: "Say hello.", state: state, message: message,
            transcript: "", createdAt: .now, updatedAt: .now, latestReply: nil, sessionRevision: nil,
            externalSession: false, approvalOnly: false, approvals: [], milestones: MilestoneTimeline(), modelSelection: nil)
    }
}
