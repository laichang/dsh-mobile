import DSHCore
import SwiftUI

struct TranscriptView: View {
    let source: String
    @State private var blocks = TranscriptBlocks()
    @State private var previous = ""

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            if source.isEmpty {
                Text("Waiting for the agent…").foregroundStyle(.secondary)
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
            Text(text)
        case .heading(let level, let text):
            Text(text).font(level <= 2 ? .title3.bold() : .headline)
                .accessibilityAddTraits(.isHeader)
        case .fence(let language, let text):
            VStack(alignment: .leading, spacing: 6) {
                if !language.isEmpty {
                    Text(language).font(.caption.weight(.medium)).foregroundStyle(.secondary)
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
                .font(.system(.callout, design: .monospaced))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("transcript.fence." + language)
        }
    }

    private func diffTint(_ line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@") { return .clear }
        if line.hasPrefix("+") { return .green.opacity(0.18) }
        if line.hasPrefix("-") { return .red.opacity(0.16) }
        return .clear
    }
}
