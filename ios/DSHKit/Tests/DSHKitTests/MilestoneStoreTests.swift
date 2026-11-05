import DSHCore
import DSHProtocol
import DSHTestSupport
import Foundation
import Testing

@MainActor
@Suite struct MilestoneStoreTests {
    func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(5)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now > deadline { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func makeStore(_ script: FakeBridge.Script) -> TaskStore {
        let connection = HostConnection(
            endpoint: .localBridge(), channel: PlaintextChannel(), transport: FakeBridge.factory(script: script))
        return TaskStore(connection: connection, prompt: "Do it in three steps.")
    }

    @Test func todosTickOffOnTheTimelineAgainstFakeBridge() async throws {
        let store = makeStore(.threeTodos(delay: .milliseconds(20)))
        var progress: [String] = []
        let send = Task { await store.send() }
        try await waitUntil {
            let p = "\(store.milestones.completedCount)/\(store.milestones.todos.count)"
            if progress.last != p { progress.append(p) }
            return store.status == .completed
        }
        await send.value
        // The card's progress went up one todo at a time, not in one jump.
        #expect(progress.filter { $0.hasSuffix("/3") } == ["0/3", "1/3", "2/3", "3/3"])
        let kinds = store.milestones.milestones.map(\.kind)
        #expect(kinds == [.started, .planned, .todoStarted, .todoDone, .todoStarted, .todoDone, .todoStarted, .todoDone, .finished])
        #expect(store.milestones.milestones.map(\.seq) == Array(1...9))
        #expect(store.milestones.current?.kind == .finished)
        #expect(store.milestones.todos.map(\.content) == FakeBridge.threeTodoItems)
        #expect(store.milestones.activeTodo == nil)
    }

    @Test func failedTaskEndsTimelineWithFailure() async throws {
        var script = FakeBridge.Script.threeTodos(delay: .milliseconds(5))
        script.milestones = Array(script.milestones.prefix(3))
        script.failWith = "error: rate limited"
        let store = makeStore(script)
        await store.send()
        try await waitUntil { store.status.token == "failed" }
        let current = try #require(store.milestones.current)
        #expect(current.kind == .failed)
        #expect(current.text == "error: rate limited")
        #expect(store.milestones.activeTodo?.content == FakeBridge.threeTodoItems[0])
    }

    @Test func newTaskStartsAnEmptyTimelineAndPlainTasksHaveNone() async throws {
        let store = makeStore(.init(reply: ["hi"], chunkDelay: .milliseconds(1)))
        await store.send()
        try await waitUntil { store.status == .completed }
        #expect(store.milestones.isEmpty)
    }

    @Test func timelineIgnoresStaleAndDuplicateSeqs() {
        let t0 = Date(timeIntervalSince1970: 0)
        var timeline = MilestoneTimeline()
        let added = [
            timeline.add(Milestone(taskID: "t", seq: 1, kind: .started, time: t0)),
            timeline.add(Milestone(taskID: "t", seq: 2, kind: .planned, todos: [.init(content: "a", status: .inProgress)], time: t0)),
            timeline.add(Milestone(taskID: "t", seq: 2, kind: .finished, time: t0)),
            timeline.add(Milestone(taskID: "t", seq: 1, kind: .finished, time: t0)),
        ]
        #expect(added == [true, true, false, false])
        #expect(timeline.milestones.map(\.kind) == [.started, .planned])
        #expect(timeline.activeTodo?.content == "a")
    }

    @Test func wireMilestoneMapsEveryKindAndDropsUnknownOnes() throws {
        var m = Dshm_V1_MilestoneAdded()
        m.taskID = "t"
        m.seq = 7
        m.kind = .todoDone
        m.text = "Write it"
        m.timeMs = 1_793_000_003_000
        var todo = Dshm_V1_Todo()
        todo.content = "Write it"
        todo.status = .completed
        m.todos = [todo]
        let milestone = try #require(Milestone(m))
        #expect(milestone == Milestone(taskID: "t", seq: 7, kind: .todoDone, text: "Write it",
                                       todos: [Todo(content: "Write it", status: .completed)],
                                       time: Date(timeIntervalSince1970: 1_793_000_003)))
        let kinds: [Dshm_V1_MilestoneKind: Milestone.Kind] = [
            .started: .started, .planned: .planned, .todoStarted: .todoStarted, .todoDone: .todoDone,
            .planModeEntered: .planModeEntered, .planModeLeft: .planModeLeft, .retrying: .retrying,
            .failed: .failed, .finished: .finished,
        ]
        for (wire, kind) in kinds {
            m.kind = wire
            #expect(Milestone(m)?.kind == kind)
        }
        m.kind = .unspecified
        #expect(Milestone(m) == nil)
        m.kind = .UNRECOGNIZED(99)
        #expect(Milestone(m) == nil)
    }
}
