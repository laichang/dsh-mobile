import DSHCore
import SwiftUI

/// S2 · the home screen: every task from every host in one list (STORY principle 4), grouped as
/// running / waiting on me / done, with the composer at the bottom. Hosts that can't be reached
/// are named (principle 3). The list comes from the local cache, so it shows while offline.
struct RootView: View {
    @Bindable var store: TaskListStore
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            TaskListView(store: store)
                .navigationTitle("Tasks")
                .navigationDestination(for: String.self) { key in
                    TaskDetailView(store: store, taskKey: key)
                }
        }
        .safeAreaInset(edge: .bottom) {
            ComposerView(store: store) { key in path = [key] }
        }
    }
}

struct TaskListView: View {
    let store: TaskListStore

    var body: some View {
        let sections = store.sections
        List {
            Section {
                ForEach(store.hosts) { HostStatusRow(host: $0) }
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
            Section(title) {
                ForEach(rows) { row in
                    NavigationLink(value: row.key) { TaskRowView(row: row) }
                        .accessibilityIdentifier("tasklist.row")
                }
            }
            .accessibilityIdentifier("tasklist.\(id)")
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

struct TaskRowView: View {
    let row: TaskListStore.TaskRow

    var body: some View {
        HStack(spacing: 10) {
            TaskStateIcon(state: row.state)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title.isEmpty ? row.taskID : row.title)
                    .lineLimit(2)
                Text(row.hostName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
