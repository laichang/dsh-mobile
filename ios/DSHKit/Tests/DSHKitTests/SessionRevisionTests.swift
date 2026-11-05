@testable import DSHCore
import DSHProtocol
import Foundation
import Testing

@MainActor struct SessionRevisionTests {
    @Test func completedPhoneTurnRecoversMissingChunksFromItsJournal() {
        var row = TaskListStore.TaskRow(key: "Mac\nphone", hostKey: "Mac", hostName: "Mac", taskID: "phone",
            title: "First turn", state: .completed, message: "", transcript: "", createdAt: Date(), updatedAt: Date(),
            externalSession: false, approvalOnly: false, approvals: [], milestones: MilestoneTimeline())
        var answer = Dshm_V1_SessionMessage()
        answer.text = "first half and second half"
        #expect(row.singleTurnTranscript([answer]) == answer.text)
        row.transcript = "second half"
        #expect(row.singleTurnTranscript([answer]) == answer.text)
        row.state = .running
        #expect(row.singleTurnTranscript([answer]) == "second half")
    }

    @Test func laterTurnCanRunAtTheSameTimestampAndStaleReplayCannotFinishIt() throws {
        let store = TaskListStore(container: try TaskCache.container(inMemory: true), hosts: [])
        let now = Date()
        let task = CachedTask(hostKey: "Mac", taskID: "one session", title: "First turn", createdAt: now)
        var snapshot = TaskSnapshot(taskID: task.taskID, title: task.title, state: .completed,
                                    createdAt: now, updatedAt: now)
        snapshot.sessionRevision = 7
        store.merge(snapshot, into: task)
        let finished = snapshot
        snapshot.sessionRevision = 8
        snapshot.state = .running
        store.merge(snapshot, into: task)
        store.merge(finished, into: task)
        #expect(task.state == .running)
        #expect(task.sessionRevision == 8)
    }
}
