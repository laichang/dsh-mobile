import Foundation

/// A streamed transcript retains completed blocks; the partial final line can end inside any token.
public struct TranscriptBlocks {
    public enum Block: Equatable {
        case prose(AttributedString)
        case heading(Int, AttributedString)
        case fence(language: String, text: String)
        case table(Table)
    }

    /// A GFM pipe table. Every row has one cell per header cell.
    public struct Table: Equatable {
        public enum Alignment: Equatable, Sendable { case leading, center, trailing }
        public var alignments: [Alignment]
        public var header: [AttributedString]
        public var rows: [[AttributedString]]
    }

    public private(set) var completed: [Block] = []
    private var lines: [String] = []
    private var fragment = ""
    private var endedWithCR = false
    private var fence: (marker: Character, length: Int, language: String)?
    /// The open table: its rows are parsed once, as their lines complete.
    private var table: Table?

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
    /// A table shows as soon as its delimiter row starts, and gains rows as they arrive.
    public var tail: [Block] {
        var preview = self
        preview.completed = []
        if !fragment.isEmpty {
            if preview.table == nil, preview.fence == nil, Self.startsDelimiter(fragment),
               let last = preview.lines.last, let header = Self.cells(last, needsPipe: true) {
                preview.lines.removeLast()
                preview.finish()
                preview.table = Table(alignments: header.map { _ in .leading }, header: header.map(Self.markdown), rows: [])
            } else {
                preview.consume(fragment)
            }
        }
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
        } else if let count = table?.header.count {
            // GFM: every line is a row until a blank line or another block; a line without a pipe too.
            table?.rows.append(Self.row(Self.cells(line, needsPipe: false) ?? [], count: count))
        } else if indentation <= 3, let last = lines.last, let header = Self.cells(last, needsPipe: true),
                  let alignments = Self.delimiter(line), alignments.count == header.count {
            // The paragraph's last line is the header row; the lines before it stay prose.
            lines.removeLast()
            finish()
            table = Table(alignments: alignments, header: header.map(Self.markdown), rows: [])
        } else {
            lines.append(line)
        }
    }

    private mutating func finish() {
        let content = lines.joined(separator: "\n")
        if let table {
            completed.append(.table(table))
        } else if let fence {
            completed.append(.fence(language: fence.language, text: content))
        } else if !content.isEmpty {
            completed.append(.prose(Self.markdown(content)))
        }
        lines.removeAll(keepingCapacity: true)
        fence = nil
        table = nil
    }

    /// Inline Markdown. S14: `*` and `**` next to CJK text also emphasize, as in DSH Web.
    public static func markdown(_ text: String) -> AttributedString {
        CJKEmphasis.markdown(text) { source in
            (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(source)
        }
    }

    // MARK: - S28 · GFM tables

    /// A row's cells: outer pipes are optional, `\|` is a pipe inside a cell (also in code spans).
    /// A header row must have a pipe; a body row may have none (one cell).
    static func cells(_ line: String, needsPipe: Bool) -> [String]? {
        var text = line.trimmingCharacters(in: .whitespaces)[...]
        guard !needsPipe || text.contains("|") else { return nil }
        if text.first == "|" { text = text.dropFirst() }
        var cells: [String] = []
        var cell = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character == "\\", next < text.endIndex {
                let escaped = text[next]
                cell += escaped == "|" ? "|" : "\\\(escaped)"
                index = text.index(after: next)
                continue
            }
            if character == "|" {
                cells.append(cell)
                cell = ""
            } else {
                cell.append(character)
            }
            index = next
        }
        // A trailing pipe closes the last cell; it does not open an empty one.
        if !cell.trimmingCharacters(in: .whitespaces).isEmpty || cells.isEmpty { cells.append(cell) }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The delimiter row (`| :--- | :-: | --: |`): its cells set each column's alignment.
    static func delimiter(_ line: String) -> [Table.Alignment]? {
        guard line.contains("|"), let cells = cells(line, needsPipe: true), !cells.isEmpty else { return nil }
        var alignments: [Table.Alignment] = []
        for cell in cells {
            let leading = cell.hasPrefix(":"), trailing = cell.hasSuffix(":")
            let dashes = cell.dropFirst(leading ? 1 : 0).dropLast(trailing && cell.count > 1 ? 1 : 0)
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            alignments.append(leading && trailing ? .center : trailing ? .trailing : .leading)
        }
        return alignments
    }

    /// An unfinished line that can still become a delimiter row (`| --- | :-`).
    static func startsDelimiter(_ fragment: String) -> Bool {
        fragment.contains("|") && fragment.contains("-") && fragment.allSatisfy { "|:- \t".contains($0) }
    }

    static func row(_ cells: [String], count: Int) -> [AttributedString] {
        (0..<count).map { markdown($0 < cells.count ? cells[$0] : "") }
    }
}
