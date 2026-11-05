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
    @State private var history: Dshm_V1_SessionPage?
    @State private var historyError: String?
    @State private var retry = 0

    private struct HistoryRequest: Equatable {
        var key: String
        var revision: UInt64?
        var online: Bool
        var retry: Int
    }


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
                if let row {
                    ForEach(row.approvals) { approval in
                        ApprovalCard(approval: approval, hostKey: row.hostKey, store: store).padding(.horizontal)
                    }
                }
                if let row {
                    let messages = history?.messages ?? []
                    let showJournal = row.externalSession || messages.filter(\.fromUser).count > 1
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(messages.filter { showJournal || $0.fromUser }, id: \.seq) { message in
                            if message.fromUser {
                                Text(verbatim: message.text)
                                    .fontWeight(.medium)
                                    .textSelection(.enabled)
                                    .accessibilityIdentifier("session.message.user")
                            } else {
                                TranscriptView(source: message.text)
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel(message.text)
                                    .accessibilityIdentifier("session.message.assistant")
                            }
                        }
                        if !showJournal {
                            TranscriptView(source: row.singleTurnTranscript(messages))
                        } else if history == nil && historyError == nil {
                            if host?.reachability == .online { ProgressView() }
                            else { Text("Connect to this host to load the conversation.").foregroundStyle(.secondary) }
                        }
                        if let historyError {
                            Text(historyError).font(.footnote)
                            Button("Retry") { retry += 1 }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
            }
            // Follow the stream at the bottom, but start a short transcript at the top.
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.top, for: .alignment)
        }
        .task(id: HistoryRequest(key: taskKey, revision: row?.sessionRevision,
                                 online: host?.reachability == .online, retry: retry)) {
            guard let row else { return }
            historyError = nil
            history = store.cachedHistory(for: row)
            do {
                let result = try await store.readHistory(for: row)
                try Task.checkCancellation()
                history = result
            } catch {
                if !Task.isCancelled { historyError = String(describing: error) }
            }
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
