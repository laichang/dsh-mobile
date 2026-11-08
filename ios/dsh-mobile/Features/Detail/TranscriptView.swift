import DSHCore
import SwiftUI

struct TranscriptView: View {
    let source: String
    @State private var blocks = TranscriptBlocks()
    @State private var previous = ""

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            if source.isEmpty {
                Text("Waiting for the agent…").foregroundStyle(DSHTheme.textSecondary)
            }
            ForEach(blocks.completed.indices, id: \.self) { index in
                blockView(blocks.completed[index])
            }
            let tail = blocks.tail
            ForEach(tail.indices, id: \.self) { index in
                blockView(tail[index])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
        .accessibilityValue(source)
        .accessibilityIdentifier("transcript.text")
        .onChange(of: source, initial: true) { _, text in
            if text.utf8.starts(with: previous.utf8) {
                let end = text.utf8.index(text.utf8.startIndex, offsetBy: previous.utf8.count)
                blocks.append(String(text[end...]))
            } else {
                blocks = TranscriptBlocks()
                blocks.append(text)
            }
            previous = text
        }
    }

    @ViewBuilder
    private func blockView(_ block: TranscriptBlocks.Block) -> some View {
        switch block {
        case .prose(let text):
            Text(Self.dshStyled(text))
                .lineSpacing(4)
        case .heading(let level, let text):
            Text(Self.dshStyled(text)).font(level <= 2 ? .title3.weight(.semibold) : .headline)
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
        case .fence(let language, let text):
            VStack(alignment: .leading, spacing: 6) {
                if !language.isEmpty {
                    Text(language).font(DSHTheme.mono(.caption)).foregroundStyle(DSHTheme.textTertiary)
                }
                ScrollView(.horizontal) {
                    if language == "diff" || language == "patch" {
                        VStack(alignment: .leading, spacing: 0) {
                            let lines = text.components(separatedBy: "\n")
                            ForEach(lines.indices, id: \.self) { index in
                                let line = lines[index]
                                Text(verbatim: line.isEmpty ? " " : line)
                                    .padding(.horizontal, 3)
                                    .background(diffTint(line), in: RoundedRectangle(cornerRadius: 2))
                            }
                        }
                    } else {
                        Text(verbatim: text)
                    }
                }
                .font(DSHTheme.mono(.footnote))
                .foregroundStyle(DSHTheme.textPrimary.opacity(0.9))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            // S16 · DSH style (screen 04): a block a shade below the canvas, under a hairline.
            .background(DSHTheme.s16CodeFill, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(DSHTheme.hairline))
            .accessibilityIdentifier("transcript.fence." + language)
        case .table(let table):
            TranscriptTableView(table: table) // S28
        }
    }

    private func diffTint(_ line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@") { return .clear }
        if line.hasPrefix("+") { return DSHTheme.s16DiffAdded }
        if line.hasPrefix("-") { return DSHTheme.s16DiffRemoved }
        return .clear
    }

    /// S16 · inline Markdown in the DSH style: `code` in SF Mono on the bubble color, links in blue.
    static func dshStyled(_ text: AttributedString, code: Font.TextStyle = .callout) -> AttributedString {
        var styled = text
        for run in text.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                styled[run.range].font = DSHTheme.mono(code)
                styled[run.range].backgroundColor = DSHTheme.s16InlineCodeFill
            }
            if run.link != nil {
                styled[run.range].foregroundColor = DSHTheme.blue
            }
        }
        return styled
    }
}
