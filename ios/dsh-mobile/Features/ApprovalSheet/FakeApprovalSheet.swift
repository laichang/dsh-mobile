#if DEBUG
import CoreFoundation
import DSHTestSupport
import Synchronization

/// S18 · the FakeBridge parts of the approval sheet scenario. Debug only.
///
/// - `-DSHMFakeAsk <text>` with `-DSHMFakeBridge approvals`: a task whose prompt contains `<text>`
///   asks for `asked` before its reply, so a new approval arrives in an open session.
/// - The Web's answer: a UI test posts the Darwin notification `webDeny` or `webAllow`. Each fake
///   host then resolves its pending approvals as another client would; the phone gets only the
///   `ApprovalResolved` event (`FakeHost.answerFromElsewhere`).
enum FakeApprovalSheet {
    static let asked = FakeBridge.PendingApproval(
        title: "", tool: "bash", arguments: #"{"command":"rm -rf ~/Desktop/Q3/tmp","timeout":60}"#,
        reason: "Remove the images left over from building the slides")

    static let webDeny = "chang.dsh-mobile.fake.web-deny"
    static let webAllow = "chang.dsh-mobile.fake.web-allow"

    private static let hosts = Mutex<[FakeHost]>([])
    private static let observing = Mutex(false)

    /// Lets a UI test answer the approvals of `host` "from the Web".
    static func watchWebAnswers(_ host: FakeHost) {
        hosts.withLock { $0.append(host) }
        let first = observing.withLock { observing in
            defer { observing = true }
            return !observing
        }
        guard first else { return }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for name in [webDeny, webAllow] {
            CFNotificationCenterAddObserver(center, nil, { _, _, name, _, _ in
                FakeApprovalSheet.answerFromTheWeb(allow: name?.rawValue as String? == FakeApprovalSheet.webAllow)
            }, name as CFString, nil, .deliverImmediately)
        }
    }

    private static func answerFromTheWeb(allow: Bool) {
        for host in hosts.withLock({ $0 }) { host.answerFromElsewhere(allow: allow) }
    }
}
#endif
