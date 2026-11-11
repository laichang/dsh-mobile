import DSHCore
import DSHFeatures
import SwiftUI

/// The details of one collapsed row, in a bottom sheet (design/screens.json: details open as sheets).
/// Tool call: verb and the whole target, DSH's tool name, the state, the lines added and removed,
/// DSH's error, and the raw arguments. Thinking: how long, and DSH's reasoning text. No full diff
/// view.
struct TranscriptBlockSheet: View {
    let store: TaskListStore
    let taskKey: String
    let blockID: String

    var body: some View {
        let item = store.task(taskKey)?.blocks.items.first { $0.id == blockID }
        NavigationStack {
            ScrollView {
                if let item {
                    VStack(alignment: .leading, spacing: 16) {
                        switch item.kind {
                        case .thinking(_, let text, let truncated):
                            Text(item.rowTitle)
                                .font(.headline)
                                .accessibilityIdentifier("transcript.sheet.title")
                            section("Reasoning", text: text, truncated: truncated, mono: false)
                        case .question:
                            EmptyView() // A question is a card in the transcript; it has no sheet.
                        case .tool(let tool):
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(item.verb).font(.headline)
                                    .accessibilityIdentifier("transcript.sheet.title")
                                Text(verbatim: tool.target.isEmpty ? tool.name : tool.target)
                                    .font(DSHTheme.mono(.callout))
                                    .textSelection(.enabled)
                                    .accessibilityIdentifier("transcript.sheet.target")
                            }
                            facts(item, tool)
                            if !tool.error.isEmpty {
                                section("Error", text: tool.error, truncated: false, mono: false)
                            }
                            if !tool.arguments.isEmpty {
                                section("Arguments", text: tool.arguments, truncated: tool.argumentsTruncated, mono: true)
                            }
                        case .userMessage(let text):
                            Text(verbatim: text).textSelection(.enabled) // A bubble, no sheet; shown as is
                        }
                    }
                    .foregroundStyle(DSHTheme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                } else {
                    Text("This step is no longer in the session.")
                        .foregroundStyle(DSHTheme.textSecondary)
                        .padding(20)
                }
            }
            .background(DSHTheme.canvas)
            .navigationTitle(item?.isThinking == true ? String(localized: "Thinking") : String(localized: "Tool call"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SheetDoneButton() }
        }
        .presentationDetents([.medium, .large])
    }

    private func facts(_ item: TranscriptItem, _ tool: TranscriptItem.Tool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            fact("Tool", Text(verbatim: tool.name).font(DSHTheme.mono(.callout)))
            fact("State", Text(stateText(item.state)).foregroundStyle(stateColor(item.state)))
            if tool.linesAdded > 0 || tool.linesRemoved > 0 {
                fact("Lines", Text(verbatim: "+\(tool.linesAdded)").foregroundStyle(DSHTheme.green)
                     + Text(verbatim: " −\(tool.linesRemoved)").foregroundStyle(DSHTheme.red))
                    .accessibilityIdentifier("transcript.sheet.lines")
            }
            fact("Started", Text(item.time, format: .dateTime.hour().minute().second()))
        }
        .font(.subheadline)
    }

    private func fact(_ title: LocalizedStringKey, _ value: Text) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(DSHTheme.textSecondary).frame(width: 80, alignment: .leading)
            value
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func section(_ title: LocalizedStringKey, text: String, truncated: Bool, mono: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote).foregroundStyle(DSHTheme.textSecondary)
            Text(verbatim: text)
                .font(mono ? DSHTheme.mono(.footnote) : .callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(DSHTheme.bubble, in: RoundedRectangle(cornerRadius: 12))
            if truncated {
                Text("Shortened by the host").font(.caption).foregroundStyle(DSHTheme.textTertiary)
            }
        }
    }

    private func stateText(_ state: TranscriptItem.State) -> LocalizedStringKey {
        switch state {
        case .running: "Running"
        case .done: "Done"
        case .failed: "Failed"
        }
    }

    private func stateColor(_ state: TranscriptItem.State) -> Color {
        switch state {
        case .running: DSHTheme.blue
        case .done: DSHTheme.green
        case .failed: DSHTheme.red
        }
    }
}
