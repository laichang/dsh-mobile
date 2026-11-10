import DSHCore
import DSHProtocol
import SwiftUI

/// The workspace part of the "host · workspace" line above the composer (screen
/// 01). It opens `WorkspacePicker` as a sheet (`SheetRoute.workspace`). The choice is for
/// this one new session: it is not saved, and a sent task or a relaunch goes back to the default.
struct WorkspaceControl: View {
    let store: TaskListStore
    let hostKey: String
    @Environment(ShellModel.self) private var shell

    private var path: String? { store.composerWorkspaces[hostKey] }

    var body: some View {
        Button {
            shell.present(.workspace(hostKey: hostKey))
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                Text(verbatim: name).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
            }
            .font(.subheadline)
        }
        .accessibilityLabel(name)
        .accessibilityValue(path ?? "default")
        .accessibilityIdentifier("workspace.open")
    }

    private var name: String {
        path.map(WorkspacePath.name) ?? String(localized: "Default workspace", table: "Pickers")
    }
}

/// How the sheet shows a path: the folder name, and the path with the home folder as `~`.
enum WorkspacePath {
    static func name(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    static func short(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        // "/Users/<name>/…" (macOS) and "/home/<name>/…" (Linux) → "~/…"
        if parts.count >= 3, parts[0].isEmpty, parts[1] == "Users" || parts[1] == "home" {
            let rest = parts.dropFirst(3).joined(separator: "/")
            return rest.isEmpty ? "~" : "~/" + rest
        }
        return path
    }
}

/// The workspace sheet (screen 07, STORY §3): the host switch at the top, the host default,
/// recent workspaces, and an absolute path on this host.
struct WorkspacePicker: View {
    let store: TaskListStore
    @State private var hostKey: String
    @Environment(\.dismiss) private var dismiss
    @State private var workspaces: Dshm_V1_WorkspaceList?
    @State private var error: String?
    @State private var path = ""

    init(store: TaskListStore, hostKey: String) {
        self.store = store
        _hostKey = State(initialValue: hostKey)
    }

    private var host: TaskListStore.HostStatus? { store.hosts.first { $0.key == hostKey } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hostSwitch
                    if let workspaces {
                        PickerGroupTitle(text: String(localized: "Host default", table: "Pickers"))
                        PickerCard {
                            option(String(localized: "Default workspace", table: "Pickers"),
                                   detail: WorkspacePath.short(workspaces.defaultPath), value: nil)
                                .accessibilityLabel(workspaces.defaultPath)
                        }
                        if !workspaces.recentPaths.isEmpty {
                            PickerGroupTitle(text: String(localized: "Recent", table: "Pickers"))
                            PickerCard {
                                ForEach(Array(workspaces.recentPaths.enumerated()), id: \.element) { index, recent in
                                    if index > 0 { PickerDivider() }
                                    option(WorkspacePath.name(recent), detail: WorkspacePath.short(recent), value: recent)
                                        .accessibilityLabel(recent)
                                }
                            }
                        }
                    } else if let error {
                        HStack(spacing: 4) {
                            Text(verbatim: error + " ·").foregroundStyle(DSHTheme.textTertiary)
                            Button(String(localized: "Retry", table: "Pickers")) { Task { await refresh() } }
                                .foregroundStyle(DSHTheme.link)
                                .accessibilityIdentifier("workspace.retry")
                        }
                        .font(.subheadline)
                        .padding(.top, 16)
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 24)
                    }
                    PickerGroupTitle(text: String(localized: "Another folder on this computer", table: "Pickers"))
                    HStack(spacing: 10) {
                        TextField(String(localized: "Absolute folder path", table: "Pickers"), text: $path,
                                  prompt: Text(verbatim: (workspaces?.defaultPath ?? "/Users") + "/…").foregroundStyle(DSHTheme.textTertiary))
                            .font(DSHTheme.mono(.subheadline))
                            .foregroundStyle(DSHTheme.textPrimary)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 12)
                            .padding(.vertical, 11)
                            .background(DSHTheme.field, in: .rect(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(DSHTheme.hairline))
                            .accessibilityIdentifier("workspace.path")
                        Button { choose(path.trimmingCharacters(in: .whitespacesAndNewlines)) } label: {
                            Text("Use", tableName: "Pickers")
                                .font(.body.weight(.semibold))
                                .padding(.horizontal, 18)
                                .padding(.vertical, 11)
                                .background(DSHTheme.bubble, in: .rect(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(DSHTheme.textPrimary)
                        .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("workspace.apply")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
            .pickerSheetChrome(title: String(localized: "Workspace", table: "Pickers"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", table: "Pickers")) { dismiss() }
                        .accessibilityIdentifier("workspace.cancel")
                }
            }
            .task(id: hostKey) { await refresh() }
        }
    }

    /// The host at the top: a menu when there are more hosts. A switch changes the composer's host.
    @ViewBuilder
    private var hostSwitch: some View {
        let label = HStack(spacing: 8) {
            Circle()
                .fill(host?.reachability == .online ? DSHTheme.green : DSHTheme.textTertiary)
                .frame(width: 8, height: 8)
            Text(verbatim: host?.name ?? hostKey).foregroundStyle(DSHTheme.textPrimary)
            if store.hosts.count > 1 {
                Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(DSHTheme.textSecondary)
            }
        }
        .font(.body)
        if store.hosts.count > 1 {
            Menu {
                ForEach(store.hosts) { other in
                    Button(other.name) { switchHost(other.key) }
                }
            } label: { label }
            .accessibilityLabel(host?.name ?? hostKey)
            .accessibilityIdentifier("workspace.host")
            .disabled(store.isSending)
        } else {
            label
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("workspace.host")
        }
    }

    private func option(_ label: String, detail: String, value: String?) -> some View {
        PickerRow(id: "workspace.option." + (value ?? "default"), checked: store.composerWorkspaces[hostKey] == value) {
            Image(systemName: "folder").foregroundStyle(DSHTheme.textSecondary)
            Text(verbatim: label).lineLimit(1).layoutPriority(1)
            Text(verbatim: detail)
                .font(DSHTheme.mono(.footnote))
                .foregroundStyle(DSHTheme.textTertiary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
        } action: {
            choose(value)
        }
    }

    private func switchHost(_ key: String) {
        guard key != hostKey else { return }
        store.chooseHost(key)
        workspaces = nil
        error = nil
        hostKey = key
    }

    private func choose(_ value: String?) {
        store.chooseWorkspace(value, hostKey: hostKey)
        dismiss()
    }

    private func refresh() async {
        do {
            workspaces = try await store.listWorkspaces(hostKey: hostKey)
            error = nil
        } catch {
            self.error = String(describing: error)
        }
    }
}
