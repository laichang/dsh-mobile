import DSHCore
import SwiftUI

struct ApprovalCard: View {
    let approval: Approval
    let hostKey: String
    let store: TaskListStore
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Approve \(approval.tool)?", systemImage: "hand.raised")
                .font(.headline)
            if let command = approval.command {
                Text(verbatim: command)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .accessibilityIdentifier("approval.command")
            }
            if approval.arguments.isEmpty {
                Text("Operation details unavailable").foregroundStyle(.secondary)
            } else if approval.command == nil {
                Text(verbatim: approval.arguments).textSelection(.enabled)
            } else {
                DisclosureGroup("Tool arguments") {
                    Text(verbatim: approval.arguments).textSelection(.enabled)
                }
            }
            if !approval.reason.isEmpty { Text(verbatim: approval.reason).font(.footnote) }
            if let error { Text(verbatim: error).foregroundStyle(.red) }
            HStack {
                Button("Deny", role: .destructive) { answer(false) }
                    .accessibilityIdentifier("approval.deny")
                Button("Allow once") { answer(true) }
                    .disabled(approval.arguments.isEmpty)
                    .accessibilityIdentifier("approval.allow")
            }
            .buttonStyle(.bordered)
            .disabled(sending || store.hosts.first { $0.key == hostKey }?.reachability != .online)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func answer(_ allow: Bool) {
        sending = true
        error = nil
        Task {
            defer { sending = false }
            do { try await store.answerApproval(approval, hostKey: hostKey, allow: allow) }
            catch { self.error = String(describing: error) }
        }
    }
}
