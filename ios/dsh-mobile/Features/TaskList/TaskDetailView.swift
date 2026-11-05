import DSHCore
import DSHProtocol
import SwiftUI

/// S2 · one task: its state and the transcript so far, from the cache. While the host is
/// connected the transcript keeps streaming; after a reconnect the gap fills in from the bridge.
struct TaskDetailView: View {
    let store: TaskListStore
    let taskKey: String
    @State private var requestingStop = false
    @State private var stopError: String?

    var body: some View {
        let row = store.task(taskKey)
        let host = store.hosts.first { $0.key == row?.hostKey }
        VStack(spacing: 0) {
            statusRow(row, host: host)
                .padding(.horizontal)
                .padding(.vertical, 8)
            if let row, !row.state.isTerminal, store.modelHosts.contains(row.hostKey) {
                ModelControl(store: store, hostKey: row.hostKey, task: row)
                    .padding(.horizontal)
            }
            if let timeline = row?.milestones, !timeline.isEmpty {
                // S3: milestone summary by default; the timeline on demand. From the cache, so it
                // shows after kill/reopen too (S2 x S3 seam).
                NavigationLink {
                    MilestoneTimelineView(timeline: store.task(taskKey)?.milestones ?? timeline)
                } label: {
                    MilestoneCard(timeline: timeline)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(timeline.headline)
                .accessibilityValue(timeline.progressToken)
                .accessibilityIdentifier("milestone.card")
                .padding(.horizontal)
            }
            ScrollView {
                let transcript = row?.transcript ?? ""
                Text(transcript.isEmpty ? "Waiting for the agent…" : transcript)
                    .foregroundStyle(transcript.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
                    .accessibilityIdentifier("transcript.text")
                    .accessibilityValue(transcript)
            }
            // Follow the stream at the bottom, but start a short transcript at the top.
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.top, for: .alignment)
        }
        .toolbar {
            if let row, !row.state.isTerminal, let host,
               host.reachability == .online, host.capabilities.contains(DSHProtocolInfo.interruptCapability) {
                Button("Stop", systemImage: "stop.circle", role: .destructive) {
                    requestingStop = true
                    Task {
                        defer { requestingStop = false }
                        do { try await store.interrupt(row) }
                        catch { stopError = String(describing: error) }
                    }
                }
                .disabled(requestingStop)
                .accessibilityIdentifier("task.interrupt")
            }
        }
        .alert("Couldn’t stop the task", isPresented: Binding(get: { stopError != nil }, set: { if !$0 { stopError = nil } })) {
            Button("OK") { stopError = nil }
        } message: {
            Text(stopError ?? "")
        }
        .navigationTitle(row?.title ?? "Task")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func statusRow(_ row: TaskListStore.TaskRow?, host: TaskListStore.HostStatus?) -> some View {
        let text = statusText(row, host: host)
        return HStack(spacing: 8) {
            if let row { TaskStateIcon(state: row.state) }
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Spacer()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityValue(row?.state.token ?? "unknown")
        .accessibilityIdentifier("task.status")
    }

    private func statusText(_ row: TaskListStore.TaskRow?, host: TaskListStore.HostStatus?) -> String {
        guard let row else { return "This task is not in the list." }
        let where_ = row.hostName
        switch row.state {
        case .running:
            if host?.reachability == .offline { return "Was running on \(where_), which is offline. It will catch up when \(where_) is back." }
            return "Running on \(where_)"
        case .interrupted: return "Interrupted on \(where_)"
        case .waitingOnUser: return "Waiting on you (\(where_))"
        case .completed: return "Done on \(where_)"
        case .failed: return "Failed: \(row.message.isEmpty ? "the task failed" : row.message)"
        }
    }
}

extension TaskState {
    /// Stable token for UI tests (`task.status` accessibility value; T0's tokens for its states).
    var token: String {
        switch self {
        case .running: "running"
        case .waitingOnUser: "waiting"
        case .completed: "completed"
        case .failed: "failed"
        case .interrupted: "interrupted"
        }
    }
}
