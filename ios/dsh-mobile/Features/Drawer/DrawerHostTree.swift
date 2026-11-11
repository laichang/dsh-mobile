import DSHCore
import DSHFeatures
import SwiftUI

/// One host in the workspace drawer (screen 02): host › workspace › session, like the DSH
/// desktop sidebar. Sessions from the Web and the desktop app show here too
///. Each session row ends in its status mark: amber dot = waiting on you, spinner =
/// running, blue dot = done and not read (red when it failed). An offline host is grey, and its
/// cached sessions still open. Without `drawer.v1` the host shows host › session (`DrawerTree`).
///
/// Accessibility contract: `host.status` (label: the host's state, value: its token),
/// `host.channel`, `host.manage`, `drawer.workspace` (value: the path), `drawer.session` (value:
/// the task state token) and `drawer.session.mark` (label: the session title, value: `DrawerMark`).
struct DrawerHostTree: View {
    let store: TaskListStore
    let host: TaskListStore.HostStatus
    @Environment(ShellModel.self) private var shell

    var body: some View {
        let tree = DrawerTree(rows: store.tasks, host: host)
        VStack(alignment: .leading, spacing: 0) {
            DrawerHostHeader(host: host)
                .padding(.top, 18)
            HostChannelRow(host: host)
                .padding(.leading, 18)
                .padding(.vertical, 2)
            if store.deviceManagement(for: host.key) != nil {
                Button { shell.present(.devices(hostKey: host.key)) } label: {
                    Label("Devices and audit", systemImage: "person.badge.key")
                        .font(.footnote)
                        .foregroundStyle(DSHTheme.textSecondary)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .padding(.leading, 18)
                .accessibilityLabel("Devices and audit on \(host.name)")
                .accessibilityIdentifier("host.manage")
            }
            ForEach(tree.workspaces) { workspace in
                DrawerWorkspaceRow(workspace: workspace, dimmed: dimmed)
                ForEach(workspace.sessions) { row in
                    DrawerSessionRow(row: row, indent: 36, dimmed: dimmed)
                }
            }
            ForEach(tree.loose) { row in
                DrawerSessionRow(row: row, indent: tree.grouped ? 8 : 28, dimmed: dimmed)
            }
        }
        .padding(.horizontal, 8)
    }

    /// An offline host is grey; its rows still open from the cache.
    private var dimmed: Bool { host.reachability == .offline }
}

/// "● MacBook-Pro ———", or "○ Office-PC · offline" in grey.
private struct DrawerHostHeader: View {
    let host: TaskListStore.HostStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                dot
                Text(verbatim: host.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let state {
                    Text(verbatim: "·")
                    Text(state).lineLimit(1)
                }
                Rectangle().fill(DSHTheme.drawerHostRule).frame(height: 1)
            }
            .font(.subheadline)
            .foregroundStyle(online ? DSHTheme.textSecondary : DSHTheme.textTertiary)
            if host.reachability == .offline, let last = host.lastConnectedAt {
                Text("Last connected \(last, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(DSHTheme.textTertiary)
                    .padding(.leading, 16)
            }
            if case .needsBridgeUpdate(let version, let supported) = host.reachability {
                Text("Installed DSH: \(version). Supported DSH: \(supported).")
                    .font(.caption)
                    .foregroundStyle(DSHTheme.amber)
                    .padding(.leading, 16)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityIdentifier("host.status")
        .accessibilityValue(host.reachability.token)
    }

    private var online: Bool { host.reachability == .online }

    @ViewBuilder
    private var dot: some View {
        switch host.reachability {
        case .online:
            Circle().fill(DSHTheme.green).frame(width: DSHTheme.drawerDot, height: DSHTheme.drawerDot)
        case .connecting:
            ProgressView().controlSize(.mini)
        case .offline:
            Circle().stroke(DSHTheme.textTertiary, lineWidth: 1.5).frame(width: DSHTheme.drawerDot, height: DSHTheme.drawerDot)
        case .needsBridgeUpdate:
            Circle().fill(DSHTheme.amber).frame(width: DSHTheme.drawerDot, height: DSHTheme.drawerDot)
        }
    }

    /// The word after the name, when the host is not simply online.
    private var state: LocalizedStringKey? {
        switch host.reachability {
        case .online: nil
        case .connecting: "connecting"
        case .offline: "offline"
        case .needsBridgeUpdate: "update the bridge"
        }
    }

    /// The same words as the shell's host status row, for VoiceOver and the UI tests.
    private var label: String {
        var parts: [String] = switch host.reachability {
        case .online: ["\(host.name) · connected"]
        case .connecting: ["Connecting to \(host.name)…"]
        case .offline: ["\(host.name) is offline"]
        case .needsBridgeUpdate: ["\(host.name) needs a bridge update"]
        }
        if host.reachability == .offline, let last = host.lastConnectedAt {
            parts.append(String(localized: "Last connected \(last, format: .relative(presentation: .named))"))
        }
        if case .needsBridgeUpdate(let version, let supported) = host.reachability {
            parts.append(String(localized: "Installed DSH: \(version). Supported DSH: \(supported)."))
        }
        return parts.joined(separator: ", ")
    }
}

/// A workspace: the folder name, and its path on the host in SF Mono.
private struct DrawerWorkspaceRow: View {
    let workspace: DrawerTree.Workspace
    let dimmed: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .font(.system(size: 15))
            Text(verbatim: workspace.name)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 8)
            Text(verbatim: workspace.displayPath)
                .font(DSHTheme.mono(.caption))
                .foregroundStyle(DSHTheme.textTertiary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .foregroundStyle(dimmed ? DSHTheme.textTertiary : DSHTheme.textPrimary)
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(workspace.name)
        .accessibilityValue(workspace.path)
        .accessibilityIdentifier("drawer.workspace")
    }
}

/// One session. A tap shows it; the mark at the end tells its status.
private struct DrawerSessionRow: View {
    let row: TaskListStore.TaskRow
    let indent: CGFloat
    let dimmed: Bool
    @Environment(ShellModel.self) private var shell

    var body: some View {
        Button { shell.open(.session(row.key)) } label: {
            Text(row.title.isEmpty ? row.taskID : row.title)
                .lineLimit(1)
                .foregroundStyle(titleColor)
                .fontWeight(current || row.drawerMark == .unread ? .semibold : .regular)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, indent)
                .padding(.trailing, 64)
                .padding(.vertical, 10)
                .background(current ? DSHTheme.drawerCurrentRow : .clear, in: .rect(cornerRadius: 10))
                .contentShape(.rect)
        }
        .buttonStyle(.drawerPress) // F1: highlighted under the finger
        .accessibilityElement(children: .combine)
        .accessibilityValue(row.state.token)
        .accessibilityIdentifier("drawer.session")
        .overlay(alignment: .trailing) {
            DrawerMarkView(row: row)
                .padding(.trailing, 8)
                .allowsHitTesting(false)
        }
    }

    private var current: Bool { shell.page == .session(row.key) }

    private var titleColor: Color {
        if dimmed { return DSHTheme.textTertiary }
        return current || row.drawerMark == .unread ? DSHTheme.textPrimary : DSHTheme.textSecondary
    }
}

/// Amber dot, spinner, blue (or red) dot, or when the session last changed.
private struct DrawerMarkView: View {
    let row: TaskListStore.TaskRow

    var body: some View {
        Group {
            switch row.drawerMark {
            case .waiting:
                Circle().fill(DSHTheme.amber).frame(width: DSHTheme.drawerDot, height: DSHTheme.drawerDot)
            case .running:
                ProgressView().controlSize(.small).tint(DSHTheme.textSecondary)
            case .unread:
                Circle().fill(row.state == .completed ? DSHTheme.blue : DSHTheme.red)
                    .frame(width: DSHTheme.drawerDot, height: DSHTheme.drawerDot)
            case .read:
                Text(verbatim: Self.when(row.updatedAt))
                    .font(.caption)
                    .foregroundStyle(DSHTheme.textTertiary)
            }
        }
        .frame(minWidth: 16, alignment: .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.title.isEmpty ? row.taskID : row.title)
        .accessibilityValue(row.drawerMark.rawValue)
        .accessibilityIdentifier("drawer.session.mark")
    }

    /// Today: the time. Yesterday: "Yesterday". Before: the date.
    static func when(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) {
            return date.formatted(.relative(presentation: .named, unitsStyle: .wide)).capitalized(with: .current)
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// "●●○ 2 / 3" at the top of the drawer: how many paired hosts are online now.
/// It opens the hosts sheet.
struct DrawerHostsOnline: View {
    let hosts: [TaskListStore.HostStatus]

    var body: some View {
        let online = hosts.filter { $0.reachability == .online }.count
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(hosts.prefix(5)) { host in
                    if host.reachability == .online {
                        Circle().fill(DSHTheme.green).frame(width: 7, height: 7)
                    } else {
                        Circle().stroke(DSHTheme.textTertiary, lineWidth: 1.2).frame(width: 7, height: 7)
                    }
                }
            }
            Text(verbatim: "\(online) / \(hosts.count)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(DSHTheme.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(DSHTheme.drawerPill, in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(online) of \(hosts.count) hosts online")
        .accessibilityValue("\(online)/\(hosts.count)")
        .accessibilityIdentifier("drawer.hosts")
    }
}

/// The amber badge on the drawer button: how many items wait in 等我处理 (所有任务).
struct DrawerButtonBadge: View {
    @Environment(TaskListStore.self) private var store: TaskListStore?

    var body: some View {
        let count = store?.sections.waitingOnMe.count ?? 0
        if count > 0 {
            Text(verbatim: "\(count)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.black)
                .padding(.horizontal, 5)
                .frame(minWidth: 18, minHeight: 18)
                .background(DSHTheme.amber, in: .capsule)
                .offset(x: 5, y: -5)
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(count) waiting on you")
                .accessibilityValue("\(count)")
                .accessibilityIdentifier("drawer.badge")
        }
    }
}

/// Marks the session that shows now as read: when it opens, and when it changes while it
/// shows. The read state stays in the cache, on this phone only.
struct DrawerReadTracker: ViewModifier {
    let store: TaskListStore
    let shell: ShellModel

    func body(content: Content) -> some View {
        content.onChange(of: unreadKey, initial: true) { _, key in
            if let key { store.markRead(key) }
        }
    }

    /// The key of the current session while it is unread; nil otherwise.
    private var unreadKey: String? {
        guard case .session(let key) = shell.page, store.task(key)?.unread == true else { return nil }
        return key
    }
}
