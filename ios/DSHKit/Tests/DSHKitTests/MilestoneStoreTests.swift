import DSHCore
import DSHProtocol
import DSHTestSupport
import Foundation
import Testing

@MainActor
@Suite struct MilestoneStoreTests {
    /// The card's progress, "done/all".
    static func progress(_ timeline: MilestoneTimeline) -> String {
        "\(timeline.completedCount)/\(timeline.todos.count)"
    }

    func makeStore(_ script: FakeBridge.Script) -> TaskStore {
        let connection = HostConnection(
            endpoint: .localBridge(), channel: PlaintextChannel(), transport: FakeBridge.factory(script: script))
        return TaskStore(connection: connection, prompt: "Do it in three steps.")
    }

    @Test func todosTickOffOnTheTimelineAgainstFakeBridge() async throws {
        let store = makeStore(.threeTodos(delay: .milliseconds(20)))
        var seen: [String] = []
        let send = Task { await store.send() }
        await waitForStore("completed") {
            let p = Self.progress(store.milestones)
            if seen.last != p { seen.append(p) }
            return store.status == .completed
        }
        await send.value
        // The card's progress went up one todo at a time, not in one jump: it is the timeline's
        // progress after each milestone. The test's own looks can miss a step under load (two
        // milestones land between two looks), so they only have to be some of these steps.
        let all = store.milestones.milestones
        var steps: [String] = []
        for n in 1...all.count {
            var timeline = MilestoneTimeline()
            all.prefix(n).forEach { timeline.add($0) }
            let p = Self.progress(timeline)
            if steps.last != p { steps.append(p) }
        }
        #expect(steps.filter { $0.hasSuffix("/3") } == ["0/3", "1/3", "2/3", "3/3"])
        #expect(steps.first == "0/0") // started: no todos yet
        #expect(Set(seen).isSubset(of: steps), "\(seen)")
        #expect(seen.filter { $0.hasSuffix("/3") } == seen.filter { $0.hasSuffix("/3") }.sorted(), "\(seen)")
        #expect(seen.last == "3/3")
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
        await waitForStore("failed") { store.status.token == "failed" }
        let current = try #require(store.milestones.current)
        #expect(current.kind == .failed)
        #expect(current.text == "error: rate limited")
        #expect(store.milestones.activeTodo?.content == FakeBridge.threeTodoItems[0])
    }

    @Test func newTaskStartsAnEmptyTimelineAndPlainTasksHaveNone() async throws {
        let store = makeStore(.init(reply: ["hi"], chunkDelay: .milliseconds(1)))
        await store.send()
        await waitForStore("completed") { store.status == .completed }
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
