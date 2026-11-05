import DSHCore
import DSHProtocol
import SwiftUI

/// The composer's workspace pill (S7). It opens `WorkspacePicker` as a sheet (`SheetRoute.workspace`).
struct WorkspaceControl: View {
    let store: TaskListStore
    let hostKey: String
    @Environment(ShellModel.self) private var shell

    var body: some View {
        Button {
            shell.present(.workspace(hostKey: hostKey))
        } label: {
            Label(store.composerWorkspaces[hostKey] ?? String(localized: "Default workspace"), systemImage: "folder")
                .font(.subheadline)
                .lineLimit(1)
        }
        .accessibilityIdentifier("workspace.open")
    }
}

struct WorkspacePicker: View {
    let store: TaskListStore
    let hostKey: String
    @Environment(\.dismiss) private var dismiss
    @State private var workspaces: Dshm_V1_WorkspaceList?
    @State private var error: String?
    @State private var path = ""

    var body: some View {
        NavigationStack {
            List {
                if let workspaces {
                    Section("Host default") {
                        option(workspaces.defaultPath, value: nil)
                    }
                    if !workspaces.recentPaths.isEmpty {
                        Section("Recent workspaces") {
                            ForEach(workspaces.recentPaths, id: \.self) { recent in
                                option(recent, value: recent)
                            }
                        }
                    }
                } else if let error {
                    Text(error)
                    Button("Retry") { Task { await refresh() } }
                } else {
                    ProgressView()
                }
                Section("Another folder on this host") {
                    TextField("Absolute folder path", text: $path)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("workspace.path")
                    Button("Use folder") { choose(path) }
                        .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("workspace.apply")
                }
            }
            .navigationTitle("Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Cancel") { dismiss() } }
            .task { await refresh() }
        }
    }

    private func option(_ label: String, value: String?) -> some View {
        Button { choose(value) } label: {
            HStack {
                Text(label)
                Spacer()
                if store.composerWorkspaces[hostKey] == value { Image(systemName: "checkmark") }
            }
        }
        .accessibilityIdentifier("workspace.option." + (value ?? "default"))
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
