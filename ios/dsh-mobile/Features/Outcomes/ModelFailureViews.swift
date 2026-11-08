import DSHCore
import SwiftUI

/// Model failures on the X1 card (STORY §8, ARCHITECTURE D104, D110). A model that fails ends the
/// task in red: the card says why in DSH's words, or in the app's own words for a key that is not
/// valid and a quota that is used up (as DSH Web does), with DSH's failure class as a small tag.
/// A new message in the composer continues the same session.
///
/// Identifiers: `outcome.code` (label: DSH's failure class), `outcome.continue`.
extension TaskOutcome {
    /// The text in the card's error box.
    var shownError: String {
        switch ownCopy {
        case .invalidKey?: String(localized: "API key is invalid", table: "Outcomes")
        case .quotaExhausted?: String(localized: "Request quota exhausted", table: "Outcomes")
        case nil: error.isEmpty ? String(localized: "The host gave no error message.", table: "Outcomes") : error
        }
    }

    /// What 复制错误 copies: DSH's text as it is, and its failure class.
    var copiedError: String {
        code.isEmpty ? error : "\(error) (\(code))"
    }
}

extension TaskListStore.TaskRow {
    /// Why the task failed, in one line (the status row, 所有任务): the app's own words for a key
    /// that is not valid or a quota that is used up, else the host's message; empty when there is none.
    var failureText: String {
        guard let outcome = TaskOutcome(self), outcome.ownCopy != nil else { return message }
        return outcome.shownError
    }
}

/// DSH's failure class (`QUOTA`, `AUTH`, …) beside the error text; nothing without one.
struct FailureCodeTag: View {
    let code: String

    var body: some View {
        if !code.isEmpty {
            Text(verbatim: code)
                .font(DSHTheme.mono(.caption2))
                .foregroundStyle(DSHTheme.textTertiary)
                .accessibilityLabel(code)
                .accessibilityIdentifier("outcome.code")
        }
    }
}

/// "在下面发条消息，就在这个会话里接着做。": when the composer can continue the failed task (D110).
struct FailureContinueHint: View {
    let store: TaskListStore
    let row: TaskListStore.TaskRow

    var body: some View {
        if row.state == .failed, store.canFollowUp(row) {
            Text("Send a message below to continue in this session.", tableName: "Outcomes")
                .font(.footnote)
                .foregroundStyle(DSHTheme.textSecondary)
                .accessibilityIdentifier("outcome.continue")
        }
    }
}
