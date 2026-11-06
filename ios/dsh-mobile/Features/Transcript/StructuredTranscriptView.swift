import DSHCore
import SwiftUI

/// S17 · the streamed transcript with its collapsed rows (screen 04, ARCHITECTURE D61): the text
/// as S16 shows it, cut where each thinking or tool-call row sits. A row is one line; a tap opens
/// its details in a sheet. With no rows (a bridge without `transcript.v1`, or a task with no
/// thinking and no tools) this is S16's `TranscriptView`, unchanged.
struct StructuredTranscriptView: View {
    let row: TaskListStore.TaskRow
    let text: String

    var body: some View {
        if row.blocks.isEmpty {
            TranscriptView(source: text)
        } else {
            let groups = Self.groups(row.blocks.segments(of: text))
            VStack(alignment: .leading, spacing: 12) {
                ForEach(groups.indices, id: \.self) { index in
                    switch groups[index] {
                    case .text(let piece):
                        TranscriptView(source: piece)
                    case .thinking(let item):
                        TranscriptBlockRow(taskKey: row.key, item: item)
                    case .tools(let items):
                        // Screen 04: consecutive tool calls sit together under a hairline on the left.
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(items) { item in TranscriptBlockRow(taskKey: row.key, item: item) }
                        }
                        .padding(.leading, 14)
                        .overlay(alignment: .leading) { Rectangle().fill(DSHTheme.hairline).frame(width: 1) }
                        .padding(.leading, 6)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityValue(text)
            .accessibilityIdentifier("transcript.structured")
        }
    }

    enum Group {
        case text(String)
        case thinking(TranscriptItem)
        case tools([TranscriptItem])
    }

    static func groups(_ segments: [StructuredTranscript.Segment]) -> [Group] {
        var out: [Group] = []
        for segment in segments {
            switch segment {
            case .text(let piece):
                out.append(.text(piece))
            case .item(let item):
                if case .tool = item.kind {
                    if case .tools(let items)? = out.last {
                        out[out.count - 1] = .tools(items + [item])
                    } else {
                        out.append(.tools([item]))
                    }
                } else {
                    out.append(.thinking(item))
                }
            }
        }
        return out
    }
}

/// One collapsed row: "已思考 8 秒 ›", or "Edit TaskListStore.swift +12 −3".
struct TranscriptBlockRow: View {
    let taskKey: String
    let item: TranscriptItem
    @Environment(ShellModel.self) private var shell

    var body: some View {
        Button { shell.present(.transcriptBlock(taskKey: taskKey, blockID: item.id)) } label: {
            switch item.kind {
            case .thinking:
                HStack(spacing: 4) {
                    Text(item.rowTitle)
                    if item.state == .running {
                        ProgressView().controlSize(.mini).tint(DSHTheme.textSecondary)
                    } else {
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                    }
                }
                .font(.subheadline)
                .foregroundStyle(DSHTheme.textSecondary)
                .padding(.vertical, 2)
            case .tool(let tool):
                HStack(spacing: 8) {
                    Text(item.verb)
                        .font(.footnote)
                        .foregroundStyle(DSHTheme.textSecondary)
                        .frame(minWidth: 38, alignment: .leading)
                    Text(verbatim: item.shortTarget)
                        .font(DSHTheme.mono(.caption))
                        .foregroundStyle(item.state == .failed ? DSHTheme.red : DSHTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if item.state == .running {
                        ProgressView().controlSize(.mini).tint(DSHTheme.textSecondary)
                    } else if item.state == .failed {
                        Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(DSHTheme.red)
                    } else if tool.linesAdded > 0 || tool.linesRemoved > 0 {
                        Text(verbatim: "+\(tool.linesAdded)").foregroundStyle(DSHTheme.green)
                        Text(verbatim: "−\(tool.linesRemoved)").foregroundStyle(DSHTheme.red)
                    }
                }
                .font(DSHTheme.mono(.caption))
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityText)
        .accessibilityValue(item.state.rawValue)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(item.isThinking ? "transcript.thinking" : "transcript.tool")
    }
}

extension TranscriptItem {
    var isThinking: Bool {
        if case .thinking = kind { true } else { false }
    }

    /// "已思考 8 秒" / "思考中…". DSH's chunk timestamps give the seconds (the bridge).
    var rowTitle: String {
        if let seconds = thinkingSeconds { return String(localized: "Thought for \(seconds) s") }
        if isThinking { return String(localized: "Thinking…") }
        return "\(verb) \(shortTarget)"
    }

    /// The row's verb: DSH's tool name, capitalized as the DSH desktop shows it (screen 04).
    var verb: String {
        guard case .tool(let tool) = kind else { return "" }
        switch tool.name {
        case "edit", "str_replace_editor", "apply_patch": return "Edit"
        case "write": return "Write"
        case "read", "read_image": return "Read"
        case "bash", "bash_persistent": return "Bash"
        case "pwsh", "pwsh_persistent": return "PowerShell"
        case "grep": return "Grep"
        case "glob": return "Glob"
        default: return tool.name
        }
    }

    /// The file name for a path, else the target as is (a command, a pattern).
    var shortTarget: String {
        guard case .tool(let tool) = kind else { return "" }
        let fileTools: Set = ["read", "read_image", "edit", "write", "str_replace_editor", "apply_patch"]
        if fileTools.contains(tool.name), tool.target.contains("/") {
            return (tool.target as NSString).lastPathComponent
        }
        return tool.target
    }

    var accessibilityText: String {
        guard case .tool(let tool) = kind else { return rowTitle }
        var text = shortTarget.isEmpty ? verb : "\(verb) \(shortTarget)"
        if state == .done, tool.linesAdded > 0 || tool.linesRemoved > 0 { text += " +\(tool.linesAdded) −\(tool.linesRemoved)" }
        return text
    }
}
