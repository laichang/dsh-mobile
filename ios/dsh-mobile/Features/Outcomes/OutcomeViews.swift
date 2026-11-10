import DSHCore
import DSHProtocol
import SwiftUI
import UIKit

/// Done and failed on the session page (screens 06 and X1, STORY §4).
/// When a task has ended, the page shows:
/// - the process as one row, "已工作 · N 步 · M 次审批 ›", which opens all the steps in a sheet;
/// - when the session was finished and not read on this phone, the page opens at the start of the
///   final answer (`OutcomeAnchor`), with no marker there;
/// - done: a footer with the time the latest turn took; failed or stopped: a card with the raw failure
///   message, "复制错误" and "新会话里再试" (the original prompt in a new session, 01).
/// The milestone bar turns red and says the step (`TaskOutcome.barAlert`).
///
/// Identifiers: `outcome.process` (value: "steps/approvals"),
/// `outcome.card` (value: the kind), `outcome.error`, `outcome.copy`, `outcome.retry`,
/// `outcome.footer`.
enum OutcomeAnchor {
    /// The scroll target when the page opens at the final answer: the process row right above it,
    /// so that the page shows the process row and the answer's start.
    static let id = "outcome.lead"

    /// A finished session that this phone has not shown yet opens at the start of its final
    /// answer. Read when the page is made: the drawer marks it read as soon as it shows.
    static func opensAtAnswer(_ row: TaskListStore.TaskRow?) -> Bool {
        guard let row else { return false }
        return row.unread && row.state.isTerminal
    }

    /// The text to try again with: the user's first message, else the task's title.
    static func retryPrompt(_ row: TaskListStore.TaskRow, messages: [Dshm_V1_SessionMessage]) -> String {
        messages.first(where: \.fromUser)?.text ?? row.title
    }
}

extension TaskOutcome {
    /// The milestone bar's line when the task failed: "失败 · 第 3 步"; nil otherwise.
    var barAlert: String? {
        guard kind == .failed else { return nil }
        if let step = stoppedAtStep { return String(localized: "Failed · step \(step)", table: "Outcomes") }
        return String(localized: "Failed", table: "Outcomes")
    }

    /// "已工作 · 23 步 · 1 次审批".
    var processText: String {
        var parts = [String(localized: "Worked", table: "Outcomes")]
        if steps > 0 { parts.append(String(localized: "\(steps) steps", table: "Outcomes")) }
        if approvals > 0 { parts.append(String(localized: "\(approvals) approvals", table: "Outcomes")) }
        return parts.joined(separator: " · ")
    }
}

/// What comes before the final answer of a finished task: the process row. When the page opens
/// at the answer, the row is the scroll target; S27 removed the marker under it.
struct OutcomeLead: View {
    let row: TaskListStore.TaskRow
    let outcome: TaskOutcome?
    let marksAnswer: Bool

    var body: some View {
        if let outcome {
            if marksAnswer {
                OutcomeProcessRow(row: row, outcome: outcome).id(OutcomeAnchor.id)
            } else {
                OutcomeProcessRow(row: row, outcome: outcome)
            }
        } else if marksAnswer {
            Color.clear.frame(height: 0).id(OutcomeAnchor.id) // the scroll target, with nothing drawn
        }
    }
}

/// "已工作 · N 步 · M 次审批 ›": the whole process in one row. A tap opens all the steps.
private struct OutcomeProcessRow: View {
    let row: TaskListStore.TaskRow
    let outcome: TaskOutcome
    @Environment(ShellModel.self) private var shell

    var body: some View {
        Button { shell.present(.milestones(taskKey: row.key)) } label: {
            HStack(spacing: 6) {
                if outcome.kind == .done {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(DSHTheme.green)
                }
                Text(verbatim: outcome.processText)
                    .font(.subheadline)
                    .foregroundStyle(DSHTheme.textSecondary)
                if outcome.steps > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DSHTheme.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(outcome.steps == 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(outcome.processText)
        .accessibilityValue("\(outcome.steps)/\(outcome.approvals)")
        .accessibilityHint(Text("Shows all steps", tableName: "Outcomes"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("outcome.process")
    }
}

/// After the final answer: a footer when the task is done, a card when it failed or stopped.
struct OutcomeEnd: View {
    let store: TaskListStore
    let row: TaskListStore.TaskRow
    let outcome: TaskOutcome
    let prompt: String

    var body: some View {
        switch outcome.kind {
        case .done: OutcomeFooter(row: row)
        case .failed, .interrupted: OutcomeCard(store: store, row: row, outcome: outcome, prompt: prompt)
        }
    }
}

/// "用时 5 分 24 秒 · <model>", under a hairline. S27: the latest turn's time, from its
/// start (`TaskRow.lastTurnStart`) to the task's last update, so that the idle time between the
/// turns of a Web session does not count.
private struct OutcomeFooter: View {
    let row: TaskListStore.TaskRow

    var body: some View {
        let took = Duration.seconds(max(0, row.updatedAt.timeIntervalSince(row.lastTurnStart).rounded()))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
        var parts = [String(localized: "Took \(took)", table: "Outcomes")]
        if let model = row.modelSelection?.model, !model.isEmpty { parts.append(model) }
        let text = parts.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 12) {
            Rectangle().fill(DSHTheme.hairline).frame(height: 1)
            Text(verbatim: text)
                .font(.footnote)
                .foregroundStyle(DSHTheme.textTertiary)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityIdentifier("outcome.footer")
    }
}

/// X1 · "任务失败" with the failure message as the host gave it (model failures: ModelFailureViews),
/// or "任务已停止"; then "复制错误" and "新会话里再试".
private struct OutcomeCard: View {
    let store: TaskListStore
    let row: TaskListStore.TaskRow
    let outcome: TaskOutcome
    let prompt: String
    @Environment(ShellModel.self) private var shell
    @State private var copied = false

    var body: some View {
        let failed = outcome.kind == .failed
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(failed ? LocalizedStringKey("Task failed") : LocalizedStringKey("Task stopped"), tableName: "Outcomes")
            } icon: {
                Image(systemName: failed ? "exclamationmark.triangle" : "stop.circle")
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(failed ? DSHTheme.failText : DSHTheme.textSecondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(failed ? Text("Task failed", tableName: "Outcomes") : Text("Task stopped", tableName: "Outcomes"))
            .accessibilityIdentifier("outcome.title")
            if failed {
                // The app's own words for some model failures, DSH's text for the others.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: outcome.shownError)
                        .font(DSHTheme.mono(.footnote))
                        .foregroundStyle(DSHTheme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("outcome.error")
                    FailureCodeTag(code: outcome.code)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(DSHTheme.errorFill, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(DSHTheme.hairline))
                FailureContinueHint(store: store, row: row)
            } else {
                Group {
                    if let step = outcome.stoppedAtStep {
                        Text("Stopped at step \(step). Nothing after it ran.", tableName: "Outcomes")
                    } else {
                        Text("Nothing more runs for this task.", tableName: "Outcomes")
                    }
                }
                .font(.footnote)
                .foregroundStyle(DSHTheme.textSecondary)
            }
            HStack(spacing: 10) {
                if failed && !outcome.error.isEmpty {
                    Button(action: copy) {
                        Text(copied ? LocalizedStringKey("Copied") : LocalizedStringKey("Copy error"), tableName: "Outcomes")
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(DSHTheme.secondaryButton, in: .rect(cornerRadius: 12))
                    }
                    .foregroundStyle(DSHTheme.textPrimary)
                    .accessibilityIdentifier("outcome.copy")
                }
                if !prompt.isEmpty {
                    Button(action: retry) {
                        Text("Try again in a new session", tableName: "Outcomes")
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(DSHTheme.textPrimary, in: .rect(cornerRadius: 12))
                    }
                    .foregroundStyle(.black)
                    .accessibilityIdentifier("outcome.retry")
                }
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(failed ? DSHTheme.failFill : DSHTheme.stoppedFill, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(failed ? DSHTheme.failBorder : DSHTheme.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityValue(outcome.kind.rawValue)
        .accessibilityIdentifier("outcome.card")
    }

    private func copy() {
        UIPasteboard.general.string = outcome.copiedError
        copied = true
    }

    /// 01 with the original prompt, on the same host and workspace; the user can edit it first.
    private func retry() {
        store.chooseHost(row.hostKey)
        if let workspace = row.workspace { store.chooseWorkspace(workspace, hostKey: row.hostKey) }
        store.prompt = prompt
        shell.open(.newSession)
    }
}
