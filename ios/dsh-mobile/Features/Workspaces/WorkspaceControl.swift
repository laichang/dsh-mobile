import DSHCore
import DSHProtocol
import SwiftUI

struct WorkspaceControl: View {
    let store: TaskListStore
    let hostKey: String
    @State private var showing = false
    @State private var workspaces: Dshm_V1_WorkspaceList?
    @State private var error: String?
    @State private var path = ""

    var body: some View {
        Button {
            workspaces = nil
            error = nil
            path = ""
            showing = true
        } label: {
            Label(store.composerWorkspaces[hostKey] ?? "Default workspace", systemImage: "folder")
                .font(.subheadline)
                .lineLimit(1)
        }
        .accessibilityIdentifier("workspace.open")
        .sheet(isPresented: $showing) {
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
                .toolbar { Button("Cancel") { showing = false } }
                .task { await refresh() }
            }
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
        showing = false
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
