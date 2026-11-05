import SwiftUI
import XCTest

// Two renderers share a block grammar and view. Only retention across appends differs.
private enum Row: Equatable {
    case markdown(AttributedString)
    case code(String, String)
}

private struct Blocks {
    var rows: [Row] = []
    private var lines: [String] = []
    private var fragment = ""
    private var language: String?

    mutating func append(_ chunk: String) throws {
        var text = (fragment + chunk)[...]
        while let newline = text.firstIndex(of: "\n") {
            let line = String(text[..<newline])
            text = text[text.index(after: newline)...]
            if language != nil {
                if line == "```" {
                    try finish()
                } else {
                    lines.append(line)
                }
            } else if line.hasPrefix("```") {
                try finish()
                language = String(line.dropFirst(3))
            } else if line.isEmpty {
                try finish()
            } else {
                lines.append(line)
            }
        }
        fragment = String(text)
    }

    private mutating func finish() throws {
        if let row = try pending("") { rows.append(row) }
        lines.removeAll(keepingCapacity: true)
        language = nil
    }

    private func pending(_ partial: String) throws -> Row? {
        let text = (lines + (partial.isEmpty ? [] : [partial])).joined(separator: "\n")
        if let language { return .code(language, text) }
        if text.isEmpty { return nil }
        return .markdown(try AttributedString(markdown: text))
    }

    func visible() throws -> [Row] {
        var last = Array(rows.suffix(4))
        if let row = try pending(fragment) { last.append(row) }
        return Array(last.suffix(4))
    }
}

private struct Viewport: View {
    let rows: [Row]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows.indices, id: \.self) { index in
                switch rows[index] {
                case .markdown(let text):
                    Text(text)
                case .code(let language, let text):
                    Text(verbatim: language + "\n" + text).font(.system(.caption, design: .monospaced))
                }
            }
        }
        .frame(width: 360, height: 260, alignment: .bottomLeading)
        .clipped()
    }
}

final class StreamingTests: XCTestCase {
    @MainActor
    func testFiveThousandLines() throws {
        // Six visibly different source blocks per case. Blank lines in fences are significant.
        let lines = (0..<250).flatMap { i in
            ["## Change \(i)", "", "Read **the patch** and `run\(i)`.", "",
             "```swift", "let n = \(i)", "", "print(n)", "```", "",
             "```diff", "-old \(i)", "+new \(i)", "```", "",
             "```console", "$ swift test", "```", "[Open result](https://example.org/\(i)) · 完成", ""]
        }
        XCTAssertEqual(lines.count, 5_000)
        let source = lines.joined(separator: "\n") + "\n"
        // Neither line nor block aligned, so an update can end inside a fence or Markdown token.
        var remaining = source[...]
        var chunks: [String] = []
        while !remaining.isEmpty {
            let chunk = remaining.prefix(767)
            chunks.append(String(chunk))
            remaining = remaining.dropFirst(chunk.count)
        }

        var expected = Blocks()
        try expected.append(source)
        XCTAssertEqual(expected.rows.count, 1_500)
        XCTAssertTrue(expected.rows.contains(.code("swift", "let n = 249\n\nprint(n)")))
        XCTAssertTrue(expected.rows.contains(.code("diff", "-old 249\n+new 249")))
        XCTAssertTrue(expected.rows.contains(.code("console", "$ swift test")))
        // Warm the native text and image machinery before timing either path.
        _ = ImageRenderer(content: Viewport(rows: try expected.visible())).cgImage
        print("X3 workload lines=\(lines.count) utf8=\(source.utf8.count) updates=\(chunks.count)")

        var referenceViews: [[Row]] = []
        for round in 1...3 {
            for incremental in (round == 2 ? [true, false] : [false, true]) {
                var blocks = Blocks()
                var prefix = ""
                var elapsed: [Double] = []
                for (index, chunk) in chunks.enumerated() {
                    let start = CACurrentMediaTime()
                    if incremental {
                        try blocks.append(chunk)
                    } else {
                        prefix += chunk
                        blocks = Blocks()
                        try blocks.append(prefix)
                    }
                    let visible = try blocks.visible()
                    let viewport = Viewport(rows: visible)
                    let image = ImageRenderer(content: viewport).cgImage
                    elapsed.append((CACurrentMediaTime() - start) * 1_000)
                    XCTAssertNotNil(image)
                    if round == 1 && !incremental {
                        referenceViews.append(visible)
                    } else {
                        XCTAssertEqual(visible, referenceViews[index])
                    }
                }
                XCTAssertEqual(blocks.rows, expected.rows)
                let sorted = elapsed.sorted()
                let p95 = sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]
                let total = elapsed.reduce(0, +)
                let candidate = incremental ? "retained" : "full"
                print(String(format: "X3 round=%d candidate=%@ total_ms=%.2f p95_ms=%.2f max_ms=%.2f", round, candidate, total, p95, sorted.last!))
            }
        }
    }
}
