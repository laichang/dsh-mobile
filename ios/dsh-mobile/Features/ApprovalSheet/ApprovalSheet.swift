import DSHCore
import DSHFeatures
import Foundation
import SwiftUI

/// The approval sheet in a session (05). It says what will happen (STORY §5): the tool,
/// the full command (or the file, or the raw arguments), the agent's reason, and the full tool
/// arguments on request. Two answers only: 拒绝 / 允许一次; there is no "always allow". The footer
/// says that the task stays paused and that every client can see the approval: nothing is
/// allowed by default.
///
/// The sheet shows the first pending approval of the task. When the task has none left (answered
/// here, or on the Web or the desktop), the sheet closes (`PendingApprovalBar`).
///
/// Identifiers: `approval.sheet` (value: the approval id), `approval.tool`, `approval.title`,
/// `approval.task`, `approval.command`, `approval.path`, `approval.arguments.full`,
/// `approval.reason`, `approval.arguments` (toggle), `approval.deny`, `approval.allow`,
/// `approval.offline`, `approval.footer`.
struct ApprovalSheet: View {
    let store: TaskListStore
    let taskKey: String
    @Environment(\.dismiss) private var dismiss
    @State private var height: CGFloat = 460

    var body: some View {
        Group {
            if let row = store.task(taskKey), let approval = row.approvals.first {
                ScrollView {
                    ApprovalSheetContent(store: store, row: row, approval: approval)
                        .id(approval.id)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
            } else {
                Color.clear.onAppear { dismiss() }
            }
        }
        .presentationDetents([.height(height), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(DSHTheme.sheetCorner)
        .presentationBackground(DSHTheme.sheet)
    }
}

private struct ApprovalSheetContent: View {
    let store: TaskListStore
    let row: TaskListStore.TaskRow
    let approval: Approval
    @State private var sending = false
    @State private var error: String?
    @State private var showsArguments = false
    @State private var rowWidth: CGFloat = 0

    var body: some View {
        let host = store.hosts.first { $0.key == row.hostKey }
        let online = host?.reachability == .online
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label {
                    Text(verbatim: approval.tool)
                } icon: {
                    Image(systemName: "hand.raised")
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(DSHTheme.amber)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(DSHTheme.amberSoft, in: .rect(cornerRadius: 6))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: approval.tool))
                .accessibilityIdentifier("approval.tool")
                Spacer(minLength: 8)
                Text("The task is paused until you decide", tableName: "ApprovalSheet")
                    .font(.footnote)
                    .foregroundStyle(DSHTheme.textTertiary)
                    .lineLimit(1)
            }
            Text(title)
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(DSHTheme.textPrimary)
                .padding(.top, 10)
                .accessibilityIdentifier("approval.title")
            Text(verbatim: "\(row.title.isEmpty ? row.taskID : row.title) · \(row.hostName)")
                .font(.subheadline)
                .foregroundStyle(DSHTheme.textSecondary)
                .lineLimit(2)
                .padding(.top, 4)
                .accessibilityIdentifier("approval.task")
            operation
                .padding(.top, 14)
            if !approval.reason.isEmpty {
                KeyValueRow(divider: true) {
                    Text("Agent's reason", tableName: "ApprovalSheet")
                } value: {
                    Text(verbatim: approval.reason)
                        .foregroundStyle(DSHTheme.textPrimary)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("approval.reason")
                }
                .padding(.top, 6)
            }
            if !approval.arguments.isEmpty && (approval.command != nil || approval.sheetPath != nil) {
                KeyValueRow(divider: false) {
                    Text("Tool arguments", tableName: "ApprovalSheet")
                } value: {
                    Button { showsArguments.toggle() } label: {
                        Text(showsArguments ? "Hide" : "Show ›", tableName: "ApprovalSheet")
                            .foregroundStyle(DSHTheme.link)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("approval.arguments")
                }
                if showsArguments {
                    SheetCommandBlock(text: AllTasksApprovalCard.pretty(approval.arguments))
                        .accessibilityIdentifier("approval.arguments.full")
                }
            }
            if let error {
                Text(verbatim: error)
                    .font(.footnote)
                    .foregroundStyle(DSHTheme.red)
                    .padding(.top, 8)
            }
            HStack(spacing: 10) {
                Button { answer(false) } label: {
                    Text("Deny", tableName: "ApprovalSheet")
                        .foregroundStyle(online ? DSHTheme.redText : DSHTheme.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: DSHTheme.tallButtonHeight)
                        .background(DSHTheme.fill, in: .rect(cornerRadius: DSHTheme.tallButtonCorner))
                        .contentShape(.rect)
                }
                // 拒绝 : 允许一次 = 0.8 : 1 (`flex:.8` on the board).
                .frame(width: rowWidth > 0 ? (rowWidth - 10) * 0.8 / 1.8 : nil)
                .accessibilityIdentifier("approval.deny")
                Button { answer(true) } label: {
                    Text("Allow once", tableName: "ApprovalSheet")
                        .foregroundStyle(online ? Color(hex: 0x111111) : DSHTheme.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: DSHTheme.tallButtonHeight)
                        .background(online ? DSHTheme.textPrimary : DSHTheme.fill,
                                    in: .rect(cornerRadius: DSHTheme.tallButtonCorner))
                        .contentShape(.rect)
                }
                .disabled(approval.arguments.isEmpty)
                .accessibilityIdentifier("approval.allow")
            }
            .font(.body.weight(.semibold))
            .buttonStyle(.plain)
            .disabled(sending || !online)
            .opacity(online ? 1 : 0.4)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
            .padding(.top, 14)
            if let host, !online {
                Text(verbatim: AllTasksApprovalCard.notConnectedReason(host))
                    .font(.footnote)
                    .foregroundStyle(DSHTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .accessibilityIdentifier("approval.offline")
            }
            VStack(spacing: 4) {
                Text("Nothing is allowed if you do not answer; the task stays paused.", tableName: "ApprovalSheet")
                Text("The phone, the Web and the desktop can all see this approval.", tableName: "ApprovalSheet")
            }
            .font(.caption)
            .foregroundStyle(DSHTheme.textTertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("approval.footer")
        }
        .padding(.horizontal, 18)
        .padding(.top, 28)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approval.sheet")
        .accessibilityValue(approval.id)
    }

    private var title: LocalizedStringResource {
        if approval.command != nil { return LocalizedStringResource("Approve this command?", table: "ApprovalSheet") }
        if approval.sheetPath != nil { return LocalizedStringResource("Approve this file change?", table: "ApprovalSheet") }
        return LocalizedStringResource("Approve this tool call?", table: "ApprovalSheet")
    }

    /// What will happen: the full command, else the file, else the raw arguments.
    @ViewBuilder
    private var operation: some View {
        if approval.arguments.isEmpty {
            Text("Operation details unavailable", tableName: "ApprovalSheet")
                .font(.footnote)
                .foregroundStyle(DSHTheme.textSecondary)
        } else if let command = approval.command {
            SheetCommandBlock(text: command)
                .accessibilityLabel(Text(verbatim: command))
                .accessibilityIdentifier("approval.command")
        } else if let path = approval.sheetPath {
            SheetCommandBlock(text: path)
                .accessibilityLabel(Text(verbatim: path))
                .accessibilityIdentifier("approval.path")
        } else {
            SheetCommandBlock(text: AllTasksApprovalCard.pretty(approval.arguments))
                .accessibilityIdentifier("approval.arguments.full")
        }
    }

    private func answer(_ allow: Bool) {
        sending = true
        error = nil
        Task {
            defer { sending = false }
            // The sheet closes when the host's ApprovalResolved removes the approval.
            do { try await store.answerApproval(approval, hostKey: row.hostKey, allow: allow) }
            catch { self.error = String(describing: error) }
        }
    }
}

/// One `.kv` row of the board: a grey key on the left, the value on the right.
private struct KeyValueRow<Key: View, Value: View>: View {
    let divider: Bool
    @ViewBuilder var key: Key
    @ViewBuilder var value: Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            key.foregroundStyle(DSHTheme.textSecondary)
            Spacer(minLength: 12)
            value
        }
        .font(.subheadline)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            if divider { Rectangle().fill(DSHTheme.hairline).frame(height: 1) }
        }
    }
}

/// A command, a path or JSON in SF Mono on the dark block (`.cmd` on the board).
private struct SheetCommandBlock: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(DSHTheme.mono(.callout))
            .foregroundStyle(DSHTheme.commandText)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(DSHTheme.commandBackground, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DSHTheme.hairline))
    }
}

/// The session page's side of the approval sheet. When the open session has a pending
/// approval, the sheet comes up: when the session opens, and when a new approval arrives. When
/// no approval is left (answered here or on another client), the sheet closes. A sheet that the
/// user swipes away stays down for that approval; this bar then opens it again.
///
/// Identifiers: `approval.pending` (value: the approval id).
struct PendingApprovalBar: View {
    let store: TaskListStore
    let row: TaskListStore.TaskRow
    @Environment(ShellModel.self) private var shell
    /// Approvals whose sheet the user closed without an answer, in this visit to the session.
    @State private var dismissed: Set<String> = []

    private var route: SheetRoute { .approval(taskKey: row.key) }

    var body: some View {
        Group {
            if let approval = row.approvals.first {
                Button { shell.present(route) } label: { label(approval) }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(Text("Waiting on you", tableName: "ApprovalSheet"))
                    .accessibilityValue(approval.id)
                    .accessibilityIdentifier("approval.pending")
            }
        }
        .onAppear(perform: sync)
        .onChange(of: row.approvals.map(\.id)) { sync() }
        .onChange(of: shell.drawerOpen) { sync() }
        .onChange(of: shell.moving) { sync() } // After the page fills the screen (F4)
        .onChange(of: shell.sheet) { old, new in
            if old == route, new == nil, let id = row.approvals.first?.id { dismissed.insert(id) }
            if new == nil { sync() }
        }
    }

    private func label(_ approval: Approval) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised")
                .foregroundStyle(DSHTheme.amber)
            Text("Waiting on you", tableName: "ApprovalSheet")
                .foregroundStyle(DSHTheme.textPrimary)
            Text(verbatim: approval.command ?? approval.tool)
                .font(DSHTheme.mono(.footnote))
                .foregroundStyle(DSHTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text("Review ›", tableName: "ApprovalSheet")
                .foregroundStyle(DSHTheme.link)
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(DSHTheme.amberSoft.opacity(0.5), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(DSHTheme.amberBorder))
    }

    /// Brings the sheet up for a new approval; takes it down when none is left.
    private func sync() {
        guard let approval = row.approvals.first else {
            if shell.sheet == route { shell.sheet = nil }
            return
        }
        guard shell.sheet == nil, !shell.drawerOpen, !shell.moving, !dismissed.contains(approval.id) else { return }
        shell.present(route)
    }
}

private extension Approval {
    /// The file a write or edit tool touches, when its arguments name one.
    var sheetPath: String? {
        let fields = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any]
        return (fields?["path"] ?? fields?["file_path"]) as? String
    }
}
