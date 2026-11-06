import DSHCore
import DSHTestSupport
import Foundation
import Testing

/// S19 · done and failed against the FakeBridge outcomes scenario (`-DSHMFakeScenario outcomes`):
/// what `TaskOutcome` reads from the store when a task is done, failed or stopped.
@MainActor
@Suite(.serialized) struct OutcomeFakeTests {
    let storeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("dshm-s19-\(UUID().uuidString).store")

    func waitUntil(_ what: String, timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now > deadline { Issue.record("timed out: \(what)"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func launch(_ host: FakeHost) async throws -> TaskListStore {
        let connection = HostConnection(endpoint: .localBridge(), channel: PlaintextChannel(), transport: host.factory)
        let store = TaskListStore(container: try TaskCache.container(url: storeURL),
                                  hosts: [.init(key: "fake:outcomes", connection: connection)])
        store.backoff = (.milliseconds(20), .milliseconds(100))
        store.foreground()
        try await waitUntil("online") { store.hosts.first?.reachability == .online }
        return store
    }

    func send(_ prompt: String, _ store: TaskListStore) async throws -> String {
        store.prompt = prompt
        return try #require(await store.send())
    }

    @Test func aDoneTaskCountsItsStepsAndTheApprovalAnsweredOnTheWeb() async throws {
        let host = FakeHost(script: .outcomes(delay: .milliseconds(5)), hostName: "MacBook-Pro")
        let store = try await launch(host)
        let key = try await send("Fix the failing CI test and \(FakeBridge.outcomeDonePrompt)", store)
        try await waitUntil("asked") { store.task(key)?.approvals.count == 1 }
        let waiting = try #require(store.task(key))
        #expect(TaskOutcome(waiting) == nil, "a task that waits has no outcome")
        host.answerFromElsewhere(allow: true)
        try await waitUntil("done") { store.task(key)?.state == .completed }

        let row = try #require(store.task(key))
        let outcome = try #require(TaskOutcome(row))
        #expect(outcome.kind == .done)
        #expect(outcome.steps == 8)
        #expect(row.milestones.milestones.map(\.seq) == Array(1...8), "the replayed steps after the answer are not counted twice")
        #expect(outcome.approvals == 1)
        #expect(outcome.stoppedAtStep == nil)
        #expect(outcome.error.isEmpty)
        #expect(row.transcript.hasPrefix(FakeBridge.outcomeAnswerStart))
        #expect(row.transcript.contains(FakeBridge.outcomeAnswerEnd))
        #expect(row.unread, "nobody saw it on this phone yet")
    }

    @Test func aFailedTaskGivesTheStepAndTheRawError() async throws {
        let host = FakeHost(script: .outcomes(delay: .milliseconds(5)), hostName: "hk-1")
        let store = try await launch(host)
        let key = try await send("Compress yesterday's media and \(FakeBridge.outcomeFailPrompt) it", store)
        try await waitUntil("failed") { store.task(key)?.state == .failed }

        let row = try #require(store.task(key))
        let outcome = try #require(TaskOutcome(row))
        #expect(outcome.kind == .failed)
        #expect(outcome.error == FakeBridge.outcomeFailure)
        #expect(outcome.stoppedAtStep == 3)
        #expect(row.milestones.completedCount == 2)
        #expect(row.milestones.todos.count == 4)
        #expect(outcome.steps == 5)
        #expect(outcome.approvals == 0)
        #expect(row.transcript == FakeBridge.outcomeFailReply)
    }

    @Test func aStoppedTaskHasAnInterruptedOutcome() async throws {
        let host = FakeHost(script: .outcomes(delay: .milliseconds(5)), hostName: "MacBook-Pro")
        let store = try await launch(host)
        let key = try await send("\(FakeBridge.outcomeHoldPrompt) the photos by date", store)
        try await waitUntil("started") { store.task(key)?.milestones.isEmpty == false }
        let running = try #require(store.task(key))
        try await store.interrupt(running)
        try await waitUntil("interrupted") { store.task(key)?.state == .interrupted }

        let stopped = try #require(store.task(key))
        let outcome = try #require(TaskOutcome(stopped))
        #expect(outcome.kind == .interrupted)
        #expect(outcome.error.isEmpty)
        #expect(outcome.stoppedAtStep == nil, "it had no todo list")
    }
}
