import Foundation

/// S14 · what the workspace drawer (screen 02) shows for one host: host › workspace › session,
/// like the DSH desktop sidebar (ARCHITECTURE D54). Pure, so `swift test` covers the rules.
///
/// - With `drawer.v1`, sessions are grouped by their workspace directory. Workspaces are ordered
///   by their newest session, and sessions newest first.
/// - Without `drawer.v1` (an older bridge), the drawer shows host › session, as T1 did.
/// - An offline host has no capabilities until it connects again. Its cached sessions keep their
///   workspaces, so the cache decides: group when any cached session has a workspace.
public struct DrawerTree: Equatable, Sendable {
    public static let capability = "drawer.v1"

    public struct Workspace: Identifiable, Equatable, Sendable {
        public var id: String { path }
        /// The absolute directory on the host.
        public var path: String
        public var sessions: [TaskListStore.TaskRow]

        public init(path: String, sessions: [TaskListStore.TaskRow]) {
            self.path = path
            self.sessions = sessions
        }

        /// The folder name, as the desktop sidebar shows it.
        public var name: String {
            let last = (path as NSString).lastPathComponent
            return last.isEmpty ? path : last
        }

        /// The path with a home directory (`/Users/<name>`, `/home/<name>`) written as `~`.
        public var displayPath: String { DrawerTree.abbreviate(path) }
    }

    /// True when the drawer shows the workspace level for this host.
    public var grouped: Bool
    public var workspaces: [Workspace]
    /// Sessions shown directly under the host: all of them without the workspace level, or the
    /// ones whose workspace the host did not report.
    public var loose: [TaskListStore.TaskRow]

    public init(rows: [TaskListStore.TaskRow], hostKey: String, capabilities: [String]) {
        let sessions = rows.filter { $0.hostKey == hostKey && !$0.approvalOnly }.sorted { $0.updatedAt > $1.updatedAt }
        grouped = capabilities.contains(Self.capability) ||
            (capabilities.isEmpty && sessions.contains { $0.workspace != nil })
        guard grouped else {
            workspaces = []
            loose = sessions
            return
        }
        var order: [String] = []
        var byPath: [String: [TaskListStore.TaskRow]] = [:]
        var loose: [TaskListStore.TaskRow] = []
        for row in sessions {
            guard let path = row.workspace else { loose.append(row); continue }
            if byPath[path] == nil { order.append(path) }
            byPath[path, default: []].append(row)
        }
        workspaces = order.map { Workspace(path: $0, sessions: byPath[$0] ?? []) }
        self.loose = loose
    }

    static func abbreviate(_ path: String) -> String {
        for prefix in ["/Users/", "/home/"] where path.hasPrefix(prefix) {
            let rest = path.dropFirst(prefix.count)
            guard let slash = rest.firstIndex(of: "/") else { return "~" }
            return "~" + rest[slash...]
        }
        return path
    }
}

/// S14 · the status mark at the end of a drawer row (screen 02).
public enum DrawerMark: String, Sendable {
    /// Amber dot: the session waits on you (an approval or a question).
    case waiting
    /// Spinner: the session is running.
    case running
    /// Blue dot (red when it failed): finished, and not read on this phone.
    case unread
    /// No mark: the drawer shows when the session last changed.
    case read
}

extension TaskListStore.TaskRow {
    public var drawerMark: DrawerMark {
        switch state {
        case .waitingOnUser: .waiting
        case .running: .running
        case .completed, .failed, .interrupted: unread ? .unread : .read
        }
    }
}
