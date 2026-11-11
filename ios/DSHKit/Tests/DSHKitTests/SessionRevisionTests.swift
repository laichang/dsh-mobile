@testable import DSHCore
@testable import DSHFeatures
import DSHProtocol
import DSHTestSupport
import Foundation
import Testing

@MainActor struct SessionRevisionTests {
    @Test func completedPhoneTurnRecoversMissingChunksFromItsJournal() {
        var row = TaskListStore.TaskRow(key: "Mac\nphone", hostKey: "Mac", hostName: "Mac", taskID: "phone",
            title: "First turn", state: .completed, message: "", transcript: "", createdAt: Date(), updatedAt: Date(),
            externalSession: false, approvalOnly: false, approvals: [], milestones: MilestoneTimeline())
        var answer = Dshm_V1_SessionMessage()
        answer.text = "first half and second half"
        #expect(row.singleTurnTranscript([SessionMessage(answer)]) == answer.text)
        row.transcript = "second half"
        #expect(row.singleTurnTranscript([SessionMessage(answer)]) == answer.text)
        row.state = .running
        #expect(row.singleTurnTranscript([SessionMessage(answer)]) == "second half")
    }

    @Test func followUpCanResumeAtTheStopTimestampWithoutARevision() throws {
        let connection = HostConnection(endpoint: .localBridge(), channel: PlaintextChannel(), transport: FakeHost().factory)
        let sync = HostSync(config: .init(key: "Mac", connection: connection), container: try TaskCache.container(inMemory: true))
        let start = Date()
        let stop = start.addingTimeInterval(1)
        let task = CachedTask(hostKey: "Mac", taskID: "session", title: "First turn", createdAt: start)
        var snapshot = TaskSnapshot(taskID: task.taskID, title: task.title, state: .interrupted,
                                    createdAt: start, updatedAt: stop)
        sync.merge(snapshot, into: task)
        let interrupted = snapshot
        snapshot.state = .running
        snapshot.turnStartedAt = stop
        sync.merge(snapshot, into: task)
        #expect(task.state == .running)
        sync.merge(interrupted, into: task)
        #expect(task.state == .running)
        #expect(task.turnStartedAt == stop)
    }

    @Test func laterTurnCanRunAtTheSameTimestampAndStaleReplayCannotFinishIt() throws {
        let connection = HostConnection(endpoint: .localBridge(), channel: PlaintextChannel(), transport: FakeHost().factory)
        let sync = HostSync(config: .init(key: "Mac", connection: connection), container: try TaskCache.container(inMemory: true))
        let now = Date()
        let task = CachedTask(hostKey: "Mac", taskID: "one session", title: "First turn", createdAt: now)
        var snapshot = TaskSnapshot(taskID: task.taskID, title: task.title, state: .completed,
                                    createdAt: now, updatedAt: now)
        snapshot.sessionRevision = 7
        sync.merge(snapshot, into: task)
        let finished = snapshot
        snapshot.sessionRevision = 8
        snapshot.state = .running
        sync.merge(snapshot, into: task)
        sync.merge(finished, into: task)
        #expect(task.state == .running)
        #expect(task.sessionRevision == 8)
    }
}
