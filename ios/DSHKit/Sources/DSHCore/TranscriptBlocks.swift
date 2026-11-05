import Foundation

/// A streamed transcript retains completed blocks; the partial final line can end inside any token.
public struct TranscriptBlocks {
    public enum Block: Equatable {
        case prose(AttributedString)
        case heading(Int, AttributedString)
        case fence(language: String, text: String)
    }

    public private(set) var completed: [Block] = []
    private var lines: [String] = []
    private var fragment = ""
    private var endedWithCR = false
    private var fence: (marker: Character, length: Int, language: String)?

    public init() {}

    public mutating func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        let continuation = endedWithCR && chunk.first == "\n" ? chunk.dropFirst() : chunk[...]
        endedWithCR = chunk.last == "\r"
        var rest = (fragment + continuation)[...]
        while let end = rest.firstIndex(where: \.isNewline) {
            consume(String(rest[..<end]))
            rest = rest[rest.index(after: end)...]
        }
        fragment = String(rest)
    }

    /// A preview of the unfinished block. It may still be a paragraph, a fence opener, or a closer.
    public var tail: [Block] {
        var preview = self
        preview.completed = []
        if !fragment.isEmpty { preview.consume(fragment) }
        preview.finish()
        return preview.completed
    }

    private mutating func consume(_ line: String) {
        let trimmed = line.drop(while: { $0 == " " })
        let indentation = line.count - trimmed.count
        if let fence {
            let marker = trimmed.prefix(while: { $0 == fence.marker })
            if indentation <= 3, marker.count >= fence.length,
               trimmed.dropFirst(marker.count).allSatisfy(\.isWhitespace) {
                finish()
            } else {
                lines.append(line)
            }
            return
        }
        if let first = trimmed.first, indentation <= 3, first == "\u{60}" || first == "~" {
            let run = trimmed.prefix(while: { $0 == first })
            if run.count >= 3 {
                finish()
                let info = trimmed.dropFirst(run.count)
                fence = (first, run.count, info.split(whereSeparator: \.isWhitespace).first?.lowercased() ?? "")
                return
            }
        }
        let hashes = trimmed.prefix(while: { $0 == "#" })
        if indentation <= 3, (1...6).contains(hashes.count), trimmed.dropFirst(hashes.count).first == " " {
            finish()
            completed.append(.heading(hashes.count, Self.markdown(String(trimmed.dropFirst(hashes.count + 1)))))
        } else if trimmed.isEmpty {
            finish()
        } else {
            lines.append(line)
        }
    }

    private mutating func finish() {
        let content = lines.joined(separator: "\n")
        if let fence {
            completed.append(.fence(language: fence.language, text: content))
        } else if !content.isEmpty {
            completed.append(.prose(Self.markdown(content)))
        }
        lines.removeAll(keepingCapacity: true)
        fence = nil
    }

    public static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
