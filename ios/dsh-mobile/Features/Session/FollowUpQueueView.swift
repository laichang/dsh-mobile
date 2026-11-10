import DSHCore
import SwiftUI

/// Screen 04: the follow-ups that wait while the task runs, above the composer's field, as
/// in the Codex and Claude apps. Each runs as the next turn by itself (排队中); "立即发送" moves it
/// into the running turn, where the agent takes it at its next step (下一步发送); × takes it out.
/// When DSH takes a message, it leaves this list and shows in the transcript, where DSH took it.
struct FollowUpQueueView: View {
    let store: TaskListStore
    let row: TaskListStore.TaskRow
    /// Tells the composer that an edit failed (nil: clear the message).
    let failed: (String?) -> Void
    @State private var editing: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(row.queue) { message in
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: message.placement == .steering ? "arrow.turn.down.right" : "clock")
                        .font(.footnote)
                        .foregroundStyle(DSHTheme.textSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: message.text)
                            .font(.subheadline)
                            .foregroundStyle(DSHTheme.textPrimary)
                            .lineLimit(2)
                        Text(message.placement == .steering ? "Goes in at the next step" : "Queued for the next turn")
                            .font(.caption)
                            .foregroundStyle(DSHTheme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(message.text)
                    .accessibilityValue(message.placement.rawValue)
                    .accessibilityIdentifier("followup.queued")
                    if message.placement == .queued {
                        Button("Send now") { edit(message) { try await store.sendNow(message, for: row) } }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(DSHTheme.blue)
                            .disabled(editing.contains(message.id))
                            .accessibilityIdentifier("followup.sendNow")
                    }
                    Button { edit(message) { try await store.removeQueued(message, for: row) } } label: {
                        Image(systemName: "xmark")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(DSHTheme.textSecondary)
                            .frame(width: 28, height: 28)
                    }
                    .disabled(editing.contains(message.id))
                    .accessibilityLabel("Remove")
                    .accessibilityIdentifier("followup.remove")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.05), in: .rect(cornerRadius: 14))
            }
        }
    }

    private func edit(_ message: QueuedMessage, _ change: @escaping () async throws -> Void) {
        editing.insert(message.id)
        failed(nil)
        Task {
            defer { editing.remove(message.id) }
            do { try await change() }
            catch { failed(String(localized: "The queue was not changed: \(String(describing: error))")) }
        }
    }
}
