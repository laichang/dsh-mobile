import DSHCore
import Foundation
import SwiftUI

/// An approval in 所有任务 (03, `.card.needs` on the board). It says what will happen
/// (STORY §5): the tool, the command or the path, the reason, and the full tool arguments on
/// request. 拒绝 / 允许一次 answer it on its host. When the host is not connected, the buttons are
/// grey and one line says why: the answer can only go through that host, and the task stays
/// paused there; nothing is allowed by default (STORY §5).
///
/// Identifiers: `approval.card`, `approval.host`, `approval.command`, `approval.path`,
/// `approval.arguments` (toggle), `approval.arguments.full`, `approval.deny`, `approval.allow`,
/// `approval.offline`; the task title is the `tasklist.row` button that opens the session.
struct AllTasksApprovalCard: View {
    let row: TaskListStore.TaskRow
    let approval: Approval
    let store: TaskListStore
    @Environment(ShellModel.self) private var shell
    @State private var sending = false
    @State private var error: String?
    @State private var showsArguments = false

    var body: some View {
        let host = store.hosts.first { $0.key == row.hostKey }
        let online = host?.reachability == .online
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Label {
                    Text("Approve \(approval.tool)?", tableName: "AllTasks")
                } icon: {
                    Image(systemName: "hand.raised")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(DSHTheme.amber)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(DSHTheme.amberSoft, in: .rect(cornerRadius: 6))
                Spacer(minLength: 8)
                Text(verbatim: hostLine(host))
                    .font(.caption)
                    .foregroundStyle(DSHTheme.textTertiary)
                    .lineLimit(1)
                    .accessibilityIdentifier("approval.host")
            }
            title
            operation
            details
            if showsArguments {
                CommandBlock(text: Self.pretty(approval.arguments))
                    .accessibilityIdentifier("approval.arguments.full")
                    .padding(.top, 8)
            }
            if let error {
                Text(verbatim: error)
                    .font(.footnote)
                    .foregroundStyle(DSHTheme.red)
                    .padding(.top, 6)
            }
            HStack(spacing: 8) {
                Button { answer(false) } label: {
                    Text("Deny", tableName: "AllTasks")
                        .foregroundStyle(online ? DSHTheme.redText : DSHTheme.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(DSHTheme.fill, in: .rect(cornerRadius: 12))
                }
                .accessibilityIdentifier("approval.deny")
                Button { answer(true) } label: {
                    Text("Allow once", tableName: "AllTasks")
                        .foregroundStyle(online ? Color(hex: 0x111111) : DSHTheme.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(online ? DSHTheme.textPrimary : DSHTheme.fill, in: .rect(cornerRadius: 12))
                }
                .disabled(approval.arguments.isEmpty)
                .accessibilityIdentifier("approval.allow")
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.plain)
            .disabled(sending || !online)
            .opacity(online ? 1 : 0.4)
            .padding(.top, 10)
            if let host, !online {
                Text(verbatim: Self.notConnectedReason(host))
                    .font(.caption)
                    .foregroundStyle(DSHTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                    .accessibilityIdentifier("approval.offline")
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 18)
                .fill(LinearGradient(colors: [DSHTheme.amber.opacity(0.07), .clear], startPoint: .top, endPoint: .center))
                .background(DSHTheme.card, in: .rect(cornerRadius: 18))
        }
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(DSHTheme.amberBorder))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approval.card")
        .accessibilityValue(host?.reachability.token ?? "")
    }

    /// The task title opens its session. A Web session that only shows while it needs a decision
    /// (`approvalOnly`) has no session page here.
    @ViewBuilder
    private var title: some View {
        let text = row.title.isEmpty ? row.taskID : row.title
        if row.approvalOnly {
            if !row.title.isEmpty {
                Text(verbatim: row.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DSHTheme.textPrimary)
                    .lineLimit(2)
                    .padding(.top, 8)
            }
        } else {
            Button { shell.open(.session(row.key)) } label: {
                Text(verbatim: text)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DSHTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: "\(text), \(row.hostName)"))
            .accessibilityValue(row.state.rawValue)
            .accessibilityIdentifier("tasklist.row")
            .padding(.top, 8)
        }
    }

    /// What will happen: the command, else the path, else the raw arguments.
    @ViewBuilder
    private var operation: some View {
        if approval.arguments.isEmpty {
            Text("Operation details unavailable", tableName: "AllTasks")
                .font(.footnote)
                .foregroundStyle(DSHTheme.textSecondary)
                .padding(.top, 8)
        } else if let command = approval.command {
            CommandBlock(text: command)
                .accessibilityLabel(Text(verbatim: command))
                .accessibilityIdentifier("approval.command")
                .padding(.top, 8)
        } else if let path = approval.path {
            Text(verbatim: path)
                .font(DSHTheme.mono(.subheadline))
                .foregroundStyle(DSHTheme.textPrimary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(DSHTheme.fill, in: .rect(cornerRadius: 6))
                .textSelection(.enabled)
                .accessibilityIdentifier("approval.path")
                .padding(.top, 8)
        } else {
            CommandBlock(text: Self.pretty(approval.arguments))
                .accessibilityIdentifier("approval.arguments.full")
                .padding(.top, 8)
        }
    }

    /// The reason, and the tool arguments behind a link when the card shows only part of them.
    @ViewBuilder
    private var details: some View {
        let partial = !approval.arguments.isEmpty && (approval.command != nil || approval.path != nil)
        if !approval.reason.isEmpty || partial {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if !approval.reason.isEmpty {
                    Text(verbatim: approval.reason)
                        .foregroundStyle(DSHTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if partial {
                    if !approval.reason.isEmpty { Text(verbatim: "·").foregroundStyle(DSHTheme.textSecondary) }
                    Button { showsArguments.toggle() } label: {
                        Text(showsArguments ? "Hide tool arguments" : "Tool arguments ›", tableName: "AllTasks")
                            .foregroundStyle(DSHTheme.link)
                            .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("approval.arguments")
                }
            }
            .font(.footnote)
            .padding(.top, 7)
        }
    }

    private func hostLine(_ host: TaskListStore.HostStatus?) -> String {
        guard let host else { return row.hostName }
        switch host.reachability {
        case .online: return host.name
        case .offline: return String(localized: "\(host.name) · offline", table: "AllTasks")
        case .connecting: return String(localized: "\(host.name) · connecting", table: "AllTasks")
        case .needsBridgeUpdate: return String(localized: "\(host.name) · update needed", table: "AllTasks")
        }
    }

    /// Why the buttons are grey. The answer must reach the host, and the host never allows by
    /// default while it waits (STORY §5).
    static func notConnectedReason(_ host: TaskListStore.HostStatus) -> String {
        switch host.reachability {
        case .online: ""
        case .offline:
            String(localized: "\(host.name) must reconnect before you can answer. The task stays paused; nothing is allowed by default.",
                   table: "AllTasks")
        case .connecting:
            String(localized: "Connecting to \(host.name). You can answer when it is connected.", table: "AllTasks")
        case .needsBridgeUpdate:
            String(localized: "\(host.name) needs a bridge update before you can answer.", table: "AllTasks")
        }
    }

    static func pretty(_ json: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return json }
        return text
    }

    private func answer(_ allow: Bool) {
        sending = true
        error = nil
        Task {
            defer { sending = false }
            do { try await store.answerApproval(approval, hostKey: row.hostKey, allow: allow) }
            catch { self.error = String(describing: error) }
        }
    }
}

/// A command or JSON in SF Mono on the dark block (`.cmd` on the board).
private struct CommandBlock: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(DSHTheme.mono(.footnote))
            .foregroundStyle(DSHTheme.commandText)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(DSHTheme.commandBackground, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DSHTheme.hairline))
    }
}

private extension Approval {
    /// The file a write or edit tool touches, when its arguments name one.
    var path: String? {
        let fields = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any]
        return (fields?["path"] ?? fields?["file_path"]) as? String
    }
}
