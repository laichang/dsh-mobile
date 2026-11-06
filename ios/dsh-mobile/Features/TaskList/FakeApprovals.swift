#if DEBUG
import DSHTestSupport

/// S15 · the FakeBridge scenario `-DSHMFakeBridge approvals` (and `approvals-office-offline`):
/// each fake host starts with one task that waits on an approval, so 所有任务 shows approvals
/// from two hosts. Debug only.
enum FakeApprovals {
    static func seed(for hostName: String) -> [FakeBridge.PendingApproval] {
        switch hostName {
        case "Office Mac":
            [.init(title: "Write the weekly report", tool: "write",
                   arguments: #"{"path":"reports/week45.md","content":"Week 45 summary"}"#,
                   reason: "Save the summary of this week")]
        default:
            [.init(title: "Turn the Q3 report into slides", tool: "bash",
                   arguments: #"{"command":"rm -rf ~/Desktop/Q3/tmp","timeout":60}"#,
                   reason: "Remove the images left over from building the slides")]
        }
    }
}
#endif
