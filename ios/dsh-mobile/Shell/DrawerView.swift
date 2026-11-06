import DSHCore
import SwiftUI

/// T1 · the thin workspace drawer (02): 新建会话, 所有任务, and the sessions in groups by host.
/// Each host group starts with the host's status, its channel and its device management (S1, S2,
/// S10), so a host's state shows where its sessions are.
///
/// Registration point: each section is one line in `body`. S14 adds workspace levels and status
/// marks inside `DrawerHostSection`; S21 adds pair and settings at the bottom.
struct DrawerView: View {
    let store: TaskListStore
    let pair: () -> Void
    @Environment(ShellModel.self) private var shell

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    brand
                    DrawerNewSessionButton()
                    DrawerAllTasksRow(store: store)
                    ForEach(store.hosts) { host in
                        DrawerHostSection(store: store, host: host)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
            Divider().overlay(DSHTheme.hairline)
            DrawerFooter(pair: pair)
        }
        .background(DSHTheme.slate.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("drawer")
    }

    private var brand: some View {
        HStack(spacing: 8) {
            Text(verbatim: "deepseek").font(.title2.weight(.bold))
            Text(verbatim: "HARNESS")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(DSHTheme.textPrimary, lineWidth: 1))
        }
        .foregroundStyle(DSHTheme.textPrimary)
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct DrawerNewSessionButton: View {
    @Environment(ShellModel.self) private var shell

    var body: some View {
        Button { shell.open(.newSession) } label: {
            Label("drawer.newSession", systemImage: "plus")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.08), in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .foregroundStyle(DSHTheme.textPrimary)
        .accessibilityIdentifier("drawer.new")
    }
}

private struct DrawerAllTasksRow: View {
    let store: TaskListStore
    @Environment(ShellModel.self) private var shell

    var body: some View {
        let sections = store.sections
        Button { shell.open(.allTasks) } label: {
            HStack {
                Label("All tasks", systemImage: "list.bullet")
                Spacer()
                if !sections.waitingOnMe.isEmpty {
                    Text("\(sections.waitingOnMe.count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(DSHTheme.amber, in: .capsule)
                }
                if !sections.running.isEmpty {
                    Label("\(sections.running.count)", systemImage: "circle.dotted")
                        .font(.caption)
                        .foregroundStyle(DSHTheme.textSecondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(DSHTheme.textPrimary)
        .accessibilityIdentifier("drawer.allTasks")
    }
}

/// One host: its status, then its sessions, newest first.
private struct DrawerHostSection: View {
    let store: TaskListStore
    let host: TaskListStore.HostStatus
    @Environment(ShellModel.self) private var shell

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HostStatusRow(host: host)
                .padding(.top, 14)
            HostChannelRow(host: host)
            if store.deviceManagement(for: host.key) != nil {
                Button { shell.present(.devices(hostKey: host.key)) } label: {
                    Label("Devices and audit", systemImage: "person.badge.key")
                        .font(.footnote)
                        .foregroundStyle(DSHTheme.textSecondary)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Devices and audit on \(host.name)")
                .accessibilityIdentifier("host.manage")
            }
            ForEach(sessions) { row in
                Button { shell.open(.session(row.key)) } label: {
                    HStack(spacing: 8) {
                        Text(row.title.isEmpty ? row.taskID : row.title)
                            .lineLimit(1)
                            .foregroundStyle(current(row) ? DSHTheme.textPrimary : DSHTheme.textSecondary)
                            .fontWeight(current(row) ? .semibold : .regular)
                        Spacer(minLength: 4)
                        TaskStateIcon(state: row.state).font(.caption)
                    }
                    .padding(.leading, 28)
                    .padding(.trailing, 8)
                    .padding(.vertical, 10)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityValue(row.state.token)
                .accessibilityIdentifier("drawer.session")
            }
        }
        .padding(.horizontal, 8)
    }

    private var sessions: [TaskListStore.TaskRow] {
        store.tasks.filter { $0.hostKey == host.key && !$0.approvalOnly }.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func current(_ row: TaskListStore.TaskRow) -> Bool { shell.page == .session(row.key) }
}

private struct DrawerFooter: View {
    let pair: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button(action: pair) {
                Image(systemName: "qrcode.viewfinder").font(.title3)
            }
            .accessibilityLabel("Pair a host")
            .accessibilityIdentifier("pairing.scan")
        }
        .foregroundStyle(DSHTheme.textSecondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
