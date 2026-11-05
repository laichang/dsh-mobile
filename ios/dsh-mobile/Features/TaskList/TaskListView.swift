import DSHCore
import DSHProtocol
import SwiftUI

/// S2 · the home screen: every task from every host in one list (STORY principle 4), grouped as
/// running / waiting on me / done, with the composer at the bottom. Hosts that can't be reached
/// are named (principle 3). The list comes from the local cache, so it shows while offline.
/// The toolbar opens the QR scanner to pair a host (S1).
struct RootView: View {
    @Bindable var store: TaskListStore
    let pair: () -> Void
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            TaskListView(store: store)
                .navigationTitle("Tasks")
                .safeAreaInset(edge: .bottom) {
                    ComposerView(store: store) { key in path = [key] }
                }
                .navigationDestination(for: String.self) { key in
                    TaskDetailView(store: store, taskKey: key)
                }
                .toolbar {
                    Button(action: pair) { Image(systemName: "qrcode.viewfinder") }
                        .accessibilityLabel("Pair a host")
                        .accessibilityIdentifier("pairing.scan")
                }
        }
    }
}

struct TaskListView: View {
    let store: TaskListStore

    var body: some View {
        let sections = store.sections
        List {
            Section {
                ForEach(store.hosts) { host in
                    HostStatusRow(host: host)
                    HostChannelRow(host: host)
                    if let connection = store.deviceManagement(for: host.key) {
                        NavigationLink {
                            DeviceManagementView(host: host.name, connection: connection)
                        } label: {
                            Label("Devices and audit", systemImage: "person.badge.key")
                        }
                        .accessibilityIdentifier("host.manage")
                    }
                }
            }
            if store.tasks.isEmpty {
                Text("No tasks yet. Send one below.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("tasklist.empty")
            }
            taskSection("Waiting on me", sections.waitingOnMe, id: "waiting")
            taskSection("Running", sections.running, id: "running")
            taskSection("Done", sections.done, id: "done")
        }
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
                        NavigationLink(value: row.key) { TaskRowView(row: row) }
                            .accessibilityIdentifier("tasklist.row")
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
        }
    }

    private var icon: String {
        switch host.reachability {
        case .online: "desktopcomputer"
        case .connecting: "arrow.triangle.2.circlepath"
        case .offline: "wifi.exclamationmark"
        }
    }

    private var color: Color {
        switch host.reachability {
        case .online: .green
        case .connecting: .secondary
        case .offline: .orange
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
            if !row.milestones.isEmpty {
                MilestoneCard(timeline: row.milestones, maxTodos: 3, showsChevron: false)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(row.state.rawValue)
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

struct ComposerView: View {
    @Bindable var store: TaskListStore
    let opened: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let key = store.composerHostKey {
                if let host = store.hosts.first(where: { $0.key == key && $0.reachability == .online }) {
                    if host.capabilities.contains("workspaces.v1") {
                        WorkspaceControl(store: store, hostKey: key)
                    } else if store.composerWorkspaces[key] != nil {
                        Button("Use default workspace on this host") { store.chooseWorkspace(nil, hostKey: key) }
                    }
                }
                if store.modelHosts.contains(key) {
                    ModelControl(store: store, hostKey: key, task: nil)
                } else if let choice = store.composerSelections[key],
                          store.hosts.contains(where: { $0.key == key && $0.reachability == .online && !$0.capabilities.contains("models.v1") }) {
                    Text("This host cannot select \(choice.model).")
                    Button("Use host default") { store.useHostDefault(hostKey: key) }
                }
            }
            if let error = store.sendError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("composer.error")
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("One sentence for your agent", text: $store.prompt, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("composer.prompt")
                    .onSubmit(send)
                Button(action: send) {
                    if store.isSending {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.up.circle.fill").font(.title)
                    }
                }
                .disabled(!store.canSend)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("composer.send")
            }
        }
        .padding()
        .background(.bar)
    }

    private func send() {
        Task {
            if let key = await store.send() { opened(key) }
        }
    }
}
