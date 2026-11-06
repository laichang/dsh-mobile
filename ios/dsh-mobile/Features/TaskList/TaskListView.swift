import DSHCore
import DSHProtocol
import SwiftUI

/// 所有任务 (03), opened from the drawer: every task from every host in one list (STORY
/// principle 4), grouped as waiting on me / running / done. The list comes from the local cache,
/// so it shows while offline. A tap on a row opens its session page. Short answers show in the
/// row (the 280-character rule, ARCHITECTURE D51). S15 restyles this page.
struct AllTasksPage: View {
    let store: TaskListStore

    var body: some View {
        VStack(spacing: 0) {
            PageBar(title: String(localized: "All tasks"))
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
        List {
            if store.tasks.isEmpty {
                Section {
                    Text("Send a task from a new session.").foregroundStyle(.secondary)
                } header: {
                    Text("No tasks yet").accessibilityIdentifier("tasklist.empty")
                }
            }
            taskSection("Waiting on me", sections.waitingOnMe, id: "waiting")
            taskSection("Running", sections.running, id: "running")
            taskSection("Done", sections.done, id: "done")
        }
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("tasklist")
    }

    @ViewBuilder
    private func taskSection(_ title: LocalizedStringKey, _ rows: [TaskListStore.TaskRow], id: String) -> some View {
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row in
                    if row.approvalOnly {
                        Text(row.hostName).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button { shell.open(.session(row.key)) } label: { TaskRowView(row: row) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("tasklist.row")
                            .id(row.key)
                    }
                    ForEach(row.approvals) { approval in
                        ApprovalCard(approval: approval, hostKey: row.hostKey, store: store)
                    }
                }
            } header: {
                Text(title).accessibilityIdentifier("tasklist.\(id)")
            }
        }
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

/// Which channel the host is reached over (S1): end-to-end encrypted (Noise), or plaintext on
/// Debug's loopback dev path. `host.channel` value = the channel name.
struct HostChannelRow: View {
    let host: TaskListStore.HostStatus

    var body: some View {
        let encrypted = host.channelName == "noise"
        HStack(spacing: 6) {
            Image(systemName: encrypted ? "lock.fill" : "lock.open")
                .foregroundStyle(encrypted ? .green : .orange)
            Text(encrypted ? "End-to-end encrypted" : "Plaintext (dev, loopback only)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(encrypted ? "\(host.name), encrypted" : "\(host.name), plaintext")
        .accessibilityValue(host.channelName)
        .accessibilityIdentifier("host.channel")
    }
}

struct TaskRowView: View {
    let row: TaskListStore.TaskRow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TaskStateIcon(state: row.state)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title.isEmpty ? row.taskID : row.title)
                        .lineLimit(2)
                    if row.state == .interrupted && row.milestones.current?.kind != .interrupted {
                        Text("Interrupted").font(.caption)
                    }
                    Text(row.hostName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            // S3's card, from the cache (S2 x S3 seam): progress shows in the list, offline too.
            if row.showsInlineAnswer {
                Text(TranscriptBlocks.markdown(row.inlineReply))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if !row.milestones.isEmpty {
                MilestoneCard(timeline: row.milestones, maxTodos: 3, showsChevron: false)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(row.state.rawValue)
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
