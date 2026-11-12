import DSHActivity
import DSHCore
import DSHFeatures
import DSHProtocol
import DSHTestSupport
import Foundation
import Testing

/// The system's Live Activities, as ActivityKit keeps them: they outlive the app, so a relaunch
/// finds them again. Records each call.
@MainActor
final class FakeActivitySystem: LiveActivityClient {
    enum Call: Equatable {
        case start(String, TaskActivityState)
        case update(String, TaskActivityState)
        case end(String, TaskActivityState)
        case dismiss(String)
    }

    private(set) var activities: [String: LiveActivityRecord] = [:]
    private(set) var calls: [Call] = []
    private(set) var staleDates: [Date] = []
    /// Starts while an activity of the same task was still there: must stay empty.
    private(set) var duplicates: [String] = []

    func current() -> [String: LiveActivityRecord] { activities }

    func start(key: String, hostName: String, state: TaskActivityState, staleDate: Date) {
        if activities[key] != nil { duplicates.append(key) }
        activities[key] = .init(hostName: hostName, state: state, ended: false)
        calls.append(.start(key, state))
        staleDates.append(staleDate)
    }

    func update(key: String, state: TaskActivityState, staleDate: Date) {
        activities[key]?.state = state
        calls.append(.update(key, state))
        staleDates.append(staleDate)
    }

    func end(key: String, state: TaskActivityState) {
        activities[key]?.state = state
        activities[key]?.ended = true
        calls.append(.end(key, state))
    }

    func dismiss(key: String) {
        activities[key] = nil
        calls.append(.dismiss(key))
    }

    func starts(_ key: String) -> Int { calls.count { if case .start(key, _) = $0 { true } else { false } } }
    /// Every state sent to the activity of `key`, in order.
    func states(_ key: String) -> [TaskActivityState] {
        calls.compactMap {
            switch $0 {
            case .start(key, let s), .update(key, let s), .end(key, let s): s
            default: nil
            }
        }
    }
}

/// The Live Activity of a task follows it (screen L): it starts when the task
/// runs, shows the latest step on each milestone, and ends with done, failed or waiting; one
/// activity for each task, also after a relaunch. Against `FakeHost` and `FakeActivitySystem`.
@MainActor
@Suite(.serialized) struct LiveActivityTests {
    let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("dshm-live-activity-\(UUID().uuidString).store")

    func waitUntil(_ what: String, timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now > deadline { Issue.record("timed out: \(what)"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The step as the test reads it: the latest milestone's kind and DSH's words.
    static func step(_ row: TaskListStore.TaskRow) -> String {
        row.milestones.current.map { "\($0.kind.rawValue) \($0.text)" } ?? ""
    }

    func launch(_ host: FakeHost, system: FakeActivitySystem, prompt: String = "Three steps.") throws -> TaskListStore {
        let connection = HostConnection(endpoint: .localBridge(), transport: host.factory)
        let store = TaskListStore(cache: try TaskCache(url: storeURL), hosts: [.init(key: "fake:mac", connection: connection, name: "MacBook-Pro")], prompt: prompt)
        store.backoff = (.milliseconds(20), .milliseconds(100))
        store.sendWaitsFor = .seconds(10)
        store.liveActivities = LiveActivities(client: system, step: Self.step)
        return store
    }

    @Test func followsTheTaskFromStartThroughEachMilestoneToDone() async throws {
        let system = FakeActivitySystem()
        let store = try launch(FakeHost(script: .threeTodos(delay: .milliseconds(40)), hostName: "MacBook-Pro"), system: system)
        store.foreground()
        defer { store.background() }
        let key = try #require(await store.send())
        try await waitUntil("done") { system.activities[key]?.ended == true }

        #expect(system.starts(key) == 1)
        #expect(system.duplicates.isEmpty)
        guard case .start(_, let first)? = system.calls.first else { Issue.record("no start: \(system.calls)"); return }
        #expect(first.phase == .running)
        #expect(first.title == "Three steps.")
        #expect(system.activities[key]?.hostName == "MacBook-Pro")
        #expect(first.endedAt == nil)

        // Each milestone reached the activity, in order: the steps it showed while running.
        let states = system.states(key)
        var steps: [String] = []
        for s in states where s.phase == .running && steps.last != s.step { steps.append(s.step) }
        let items = FakeBridge.threeTodoItems
        let expected = ["started ", "planned ", "todoStarted \(items[0])", "todoDone \(items[0])", "todoStarted \(items[1])",
                        "todoDone \(items[1])", "todoStarted \(items[2])", "todoDone \(items[2])",
                        // FINISHED comes just before the task ends.
                        "finished "]
        #expect(steps.filter { !$0.isEmpty } == expected)

        // It ended as done, with the whole list done and a fixed end time; it ended once.
        let last = try #require(states.last)
        let row = try #require(store.task(key))
        #expect(last.phase == .done)
        #expect(last.startedAt == max(row.turnStartedAt ?? row.createdAt, row.createdAt))
        #expect(last.step == "finished ")
        #expect((last.done, last.total) == (3, 3))
        #expect(last.endedAt != nil && last.endedAt! >= last.startedAt)
        #expect(system.calls.count { if case .end = $0 { true } else { false } } == 1)
        // Each start and update carried a stale date after now.
        #expect(!system.staleDates.isEmpty && system.staleDates.allSatisfy { $0 > first.startedAt })
    }

    @Test func endsAsFailedWhenTheTaskFails() async throws {
        let system = FakeActivitySystem()
        var script = FakeBridge.Script.threeTodos(delay: .milliseconds(30))
        script.failWith = "The model is not available."
        let store = try launch(FakeHost(script: script), system: system)
        store.foreground()
        defer { store.background() }
        let key = try #require(await store.send())
        try await waitUntil("ended") { system.activities[key]?.ended == true }
        #expect(system.starts(key) == 1)
        #expect(system.states(key).last?.phase == .failed)
        #expect(system.states(key).last?.step == "failed The model is not available.")
    }

    @Test func endsWhileTheTaskWaitsOnAnApprovalAndStartsAgainAfterTheAnswer() async throws {
        let system = FakeActivitySystem()
        var script = FakeBridge.Script(reply: ["Cleaned ", "up."], chunkDelay: .milliseconds(20))
        script.ask = ("Clean up", .init(title: "", tool: "bash", arguments: #"{"command":"rm -rf ~/Desktop/Q3/tmp"}"#, reason: "Remove"))
        let host = FakeHost(script: script)
        let store = try launch(host, system: system, prompt: "Clean up the Q3 slides")
        store.foreground()
        defer { store.background() }
        let key = try #require(await store.send())

        // The approval can come a moment before the task's WAITING state: it ends the activity already.
        try await waitUntil("waits") { system.activities[key]?.ended == true && store.task(key)?.state == .waitingOnUser }
        #expect(system.states(key).last?.phase == .approval)
        #expect(system.starts(key) == 1)

        host.answerFromElsewhere(allow: true)
        try await waitUntil("done") { store.task(key)?.state == .completed && system.activities[key]?.ended == true }
        // The ended one went before the task's second activity started: one at a time.
        #expect(system.starts(key) == 2)
        #expect(system.duplicates.isEmpty)
        let dismissed = try #require(system.calls.firstIndex(of: .dismiss(key)))
        let restarted = try #require(system.calls.lastIndex { if case .start(key, _) = $0 { true } else { false } })
        #expect(dismissed < restarted)
        #expect(system.states(key).last?.phase == .done)
    }

    @Test func endsWhileAnAgentQuestionWaits() async throws {
        let system = FakeActivitySystem()
        var script = FakeBridge.Script.threeTodos(delay: .milliseconds(20))
        script.holdPrompt = "Which template"
        // A real bridge with `questions.v1` also has `transcript.v1`, where the question card sits.
        let host = FakeHost(script: script, extraCapabilities: [DSHProtocolInfo.transcriptCapability, DSHProtocolInfo.questionsCapability])
        let store = try launch(host, system: system, prompt: "Which template for the report?")
        store.foreground()
        defer { store.background() }
        let key = try #require(await store.send())
        try await waitUntil("running") { system.activities[key]?.state.phase == .running }
        let taskID = try #require(store.task(key)?.taskID)

        var pending = Dshm_V1_QuestionPending()
        pending.id = "q-1"
        pending.taskID = taskID
        pending.questions = [.with { $0.id = "template"; $0.text = "Which template?"; $0.options = [.with { $0.label = "A" }] }]
        host.emit(.with { $0.questionPending = pending }, taskID: taskID)
        try await waitUntil("waits") { system.activities[key]?.ended == true }
        #expect(system.states(key).last?.phase == .question)
        #expect(store.task(key)?.state == .running, "the task runs while DSH waits for the answer")

        var resolved = Dshm_V1_QuestionResolved()
        resolved.id = "q-1"
        resolved.taskID = taskID
        resolved.outcome = .answered
        host.emit(.with { $0.questionResolved = resolved }, taskID: taskID)
        try await waitUntil("runs again") { system.activities[key]?.ended == false }
        #expect(system.starts(key) == 2)
        #expect(system.duplicates.isEmpty)
    }

    @Test func oneActivityForEachTaskAlsoAfterARelaunch() async throws {
        let system = FakeActivitySystem()
        let host = FakeHost(script: .threeTodos(delay: .milliseconds(150)))
        var store: TaskListStore? = try launch(host, system: system)
        store?.foreground()
        let key = try #require(await store?.send())
        try await waitUntil("a few steps") { (store?.task(key)?.milestones.milestones.count ?? 0) >= 3 }
        #expect(system.starts(key) == 1)
        // The app is killed while the task runs; the system keeps the activity.
        store?.background()
        store = nil
        #expect(system.activities[key]?.ended == false)

        // A relaunch with a second task: the first task's activity is taken over, not started again.
        let reopened = try launch(host, system: system, prompt: "Another task.")
        reopened.foreground()
        defer { reopened.background() }
        let second = try #require(await reopened.send())
        try await waitUntil("both done") {
            system.activities[key]?.ended == true && system.activities[second]?.ended == true
        }
        #expect(system.starts(key) == 1)
        #expect(system.starts(second) == 1)
        #expect(system.duplicates.isEmpty)
        #expect(system.activities.count == 2)
        #expect(system.states(key).last?.phase == .done)
        // After the relaunch it still showed the steps it missed.
        #expect(system.states(key).contains { $0.step.hasPrefix("todoDone") && $0.phase == .running })
    }

    @Test func aTaskThatLeftTheListLeavesNoActivity() async throws {
        let system = FakeActivitySystem()
        let host = FakeHost(script: .threeTodos(delay: .milliseconds(200)))
        let store = try launch(host, system: system)
        store.foreground()
        let key = try #require(await store.send())
        try await waitUntil("running") { system.activities[key] != nil }
        store.background()

        // The cache is erased (a reset), and the app starts again with a host that has no tasks.
        try TaskCache(url: storeURL).erase()
        let reopened = try launch(FakeHost(reachable: false), system: system)
        defer { reopened.background() }
        #expect(system.activities[key] == nil)
        #expect(system.calls.last == .dismiss(key))
    }
}
