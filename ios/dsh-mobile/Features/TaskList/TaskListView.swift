import DSHCore
import DSHFeatures
import DSHProtocol
import SwiftUI

/// 所有任务 (03), opened from the drawer: every task from every host in one list (STORY
/// principle 4), in three sections: waiting on me, running, done. The list comes from the local
/// cache, so it shows while offline. Approvals are cards with the tool, the command, the reason
/// and the tool arguments (STORY §5); a card of a host that is not connected has grey buttons and
/// says why. An agent question is its card, which answers there too (P1). A tap on a task opens
/// its session page. Short answers show in the row (the
/// 280-character rule). Design screen 03.
struct AllTasksPage: View {
    let store: TaskListStore

    var body: some View {
        VStack(spacing: 0) {
            PageBar(title: String(localized: "All tasks"),
                    subtitle: String(localized: "\(store.hosts.count) hosts", table: "AllTasks"))
            TaskListView(store: store)
        }
        .background(DSHTheme.canvas.ignoresSafeArea())
    }
}

struct TaskListView: View {
    let store: TaskListStore
    @Environment(ShellModel.self) private var shell

    var body: some View {
        let sections = store.sections
        ScrollView {
            // Not lazy: a row moves between sections with the same id, and a LazyVStack kept the
            // old view of a row that moved from 等我处理 to 已完成. The list is short.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(store.offlineHosts) { host in
                    OfflineHostBanner(host: host).padding(.top, 4)
                }
                if store.tasks.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No tasks yet")
                            .font(.headline)
                            .foregroundStyle(DSHTheme.textPrimary)
                            .accessibilityIdentifier("tasklist.empty")
                        Text("Send a task from a new session.").foregroundStyle(DSHTheme.textSecondary)
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 24)
                }
                taskSection("Waiting on me", sections.waitingOnMe, id: "waiting")
                taskSection("Running", sections.running, id: "running")
                taskSection("Done", sections.done, id: "done")
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("tasklist")
    }

    @ViewBuilder
    private func taskSection(_ title: LocalizedStringKey, _ rows: [TaskListStore.TaskRow], id: String) -> some View {
        if !rows.isEmpty {
            HStack {
                Text(title, tableName: "AllTasks").accessibilityIdentifier("tasklist.\(id)")
                Spacer()
                Text(verbatim: "\(rows.count)")
                    .font(DSHTheme.mono(.footnote))
                    .foregroundStyle(DSHTheme.textTertiary)
                    .accessibilityIdentifier("tasklist.\(id).count")
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(DSHTheme.textSecondary)
            .padding(.horizontal, 4)
            .padding(.top, 18)
            .padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if !row.approvals.isEmpty {
                    ForEach(row.approvals) { approval in
                        AllTasksApprovalCard(row: row, approval: approval, store: store)
                            .padding(.bottom, 8)
                    }
                } else if row.state == .waitingOnUser, let question = row.blocks.pendingQuestion {
                    // P1: an agent question needs a decision like an approval.
                    AllTasksQuestionCard(row: row, question: question, store: store)
                        .padding(.bottom, 8)
                } else if !row.approvalOnly {
                    Button { shell.open(.session(row.key)) } label: { TaskRowView(row: row) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("tasklist.row")
                        .overlay(alignment: .top) {
                            if index > 0 && rows[index - 1].approvals.isEmpty
                                && !(rows[index - 1].state == .waitingOnUser && rows[index - 1].blocks.pendingQuestion != nil) {
                                Rectangle().fill(DSHTheme.hairline).frame(height: 1)
                            }
                        }
                }
            }
        }
    }
}

/// One line for each offline host at the top of 所有任务: its tasks and approvals below come
/// from the cache, and its approvals cannot be answered until it reconnects.
private struct OfflineHostBanner: View {
    let host: TaskListStore.HostStatus

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .strokeBorder(DSHTheme.textTertiary, lineWidth: 1.5)
                .frame(width: 7, height: 7)
            Text(verbatim: text)
                .font(.footnote)
                .foregroundStyle(DSHTheme.textSecondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(DSHTheme.card, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DSHTheme.hairline))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("alltasks.offlineHost")
        .accessibilityValue(host.name)
    }

    private var text: String {
        guard let last = host.lastConnectedAt else {
            return String(localized: "\(host.name) offline", table: "AllTasks")
        }
        let ago = last.formatted(.relative(presentation: .named))
        return String(localized: "\(host.name) offline · last connected \(ago)", table: "AllTasks")
    }
}

struct HostStatusRow: View {
    let host: TaskListStore.HostStatus

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                if case .needsBridgeUpdate(let version, let supported) = host.reachability {
                    Text("Installed DSH: \(version). Supported DSH: \(supported).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if host.reachability == .offline, let last = host.lastConnectedAt {
                    Text("Last connected \(last, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("host.status")
        .accessibilityValue(host.reachability.token)
    }

    private var title: String {
        switch host.reachability {
        case .online: "\(host.name) · connected"
        case .connecting: "Connecting to \(host.name)…"
        case .offline: "\(host.name) is offline"
        case .needsBridgeUpdate: "\(host.name) needs a bridge update"
        }
    }

    private var icon: String {
        switch host.reachability {
        case .online: "desktopcomputer"
        case .connecting: "arrow.triangle.2.circlepath"
        case .offline: "wifi.exclamationmark"
        case .needsBridgeUpdate: "arrow.down.circle"
        }
    }

    private var color: Color {
        switch host.reachability {
        case .online: .green
        case .connecting: .secondary
        case .offline, .needsBridgeUpdate: .orange
        }
    }
}

/// Shows the connection used for this host.
struct HostChannelRow: View {
    let host: TaskListStore.HostStatus

    var body: some View {
        let encrypted = host.isEncrypted
        HStack(spacing: 6) {
            Image(systemName: encrypted ? "lock.fill" : "lock.open")
                .foregroundStyle(encrypted ? .green : .orange)
            Text(encrypted ? "End-to-end encrypted" : "In-process test host")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(encrypted ? "\(host.name), encrypted" : "\(host.name), in-process test host")
        .accessibilityValue(host.channelName)
        .accessibilityIdentifier("host.channel")
    }
}

/// A task in 所有任务 (`.run` on the board): state, title, one status line, and the progress on
/// the right. A short completed answer shows under the title.
struct TaskRowView: View {
    let row: TaskListStore.TaskRow

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            TaskStateIcon(state: row.state)
                .frame(width: 18, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title.isEmpty ? row.taskID : row.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(DSHTheme.textPrimary)
                    .lineLimit(2)
                if let statusLine {
                    Text(verbatim: statusLine)
                        .font(.footnote)
                        .foregroundStyle(row.state == .failed ? DSHTheme.redText : DSHTheme.textSecondary)
                        .lineLimit(2)
                }
                if row.showsInlineAnswer {
                    Text(TranscriptBlocks.markdown(row.inlineReply))
                        .font(.subheadline)
                        .foregroundStyle(DSHTheme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(DSHTheme.hairlineStrong).frame(width: 2)
                        }
                        .padding(.top, 6)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if row.state.isTerminal {
                    Text(verbatim: row.hostName)
                        .font(.caption)
                        .foregroundStyle(DSHTheme.textTertiary)
                        .lineLimit(1)
                }
                if !row.milestones.todos.isEmpty {
                    Text(verbatim: row.milestones.progressToken)
                        .font(DSHTheme.mono(.caption))
                        .foregroundStyle(DSHTheme.textTertiary)
                        .accessibilityLabel("\(row.milestones.completedCount) of \(row.milestones.todos.count)")
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityValue(row.state.rawValue)
    }

    /// Running or waiting: what it does now · host. Done: why it stopped, when that is news.
    private var statusLine: String? {
        let headline = row.milestones.isEmpty ? nil : row.milestones.headline
        switch row.state {
        case .running, .waitingOnUser:
            return [headline, row.hostName].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
        case .interrupted:
            return String(localized: "Interrupted")
        case .failed:
            return row.failureText.isEmpty ? (headline ?? String(localized: "Failed")) : row.failureText
        case .completed:
            return row.showsInlineAnswer ? nil : headline
        }
    }
}

private extension TaskListStore.TaskRow {
    var inlineReply: String { latestReply ?? transcript }

    var showsInlineAnswer: Bool {
        state == .completed && !inlineReply.isEmpty && inlineReply.prefix(281).count <= 280 &&
            inlineReply.split(whereSeparator: \.isNewline).count <= 3 &&
            !inlineReply.contains("```") && !inlineReply.contains("~~~") &&
            milestones.milestones.allSatisfy { $0.kind == .started || $0.kind == .finished }
    }
}

struct TaskStateIcon: View {
    let state: TaskState

    var body: some View {
        switch state {
        case .interrupted: Image(systemName: "stop.circle").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .waitingOnUser: Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
        case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}
