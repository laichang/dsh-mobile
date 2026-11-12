#if DEBUG
import DSHCore
import DSHProtocol
import DSHTransport

enum DurableHostScenario: String {
    case online = "durable"
    case offline = "durable-offline"
    case reconnected = "durable-reconnected"

    func hosts() -> [HostSync.HostConfig] {
        return ["Office Mac", "Home Mac"].map { name in
            let taskID = "shared-1"
            let connectedAgain = self == .reconnected
            var journal = Dshm_V1_SessionPage()
            journal.messages = [.with { $0.seq = 1; $0.fromUser = true; $0.text = "Journal on " + name }]
            journal.throughSeq = connectedAgain ? 2 : 1
            var script = FakeBridge.Script()
            script.ask = ("Session", FakeApprovalSheet.asked)
            script.followUpReply = ["done"]
            script.queuesFollowUps = true
            var summary = Dshm_V1_TaskSummary()
            summary.taskID = taskID
            summary.title = "Session on " + name
            summary.state = .completed
            summary.sessionRevision = journal.throughSeq
            let host = FakeHost(script: script, hostName: name, reachable: self != .offline,
                                seed: connectedAgain ? [summary] : [], extraCapabilities: [DSHProtocolInfo.attachmentsCapability],
                                journals: [taskID: journal], taskIDPrefix: "shared")
            if connectedAgain {
                var end = Dshm_V1_Event()
                end.taskEnded.taskID = taskID
                end.taskEnded.status = .completed
                host.emit(end, taskID: taskID)
            }
            return .init(key: "fake:" + name, connection: .init(endpoint: .localBridge(), transport: host.factory), name: name)
        }
    }
}
#endif
