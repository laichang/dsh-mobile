import DSHFeatures
import Testing

@Suite struct TranscriptBlocksTests {
    @Test func fragmentedMarkdownMatchesCachedSource() {
        let source = "# Patch\r\n\r\nOpen **result** [PR](https://example.org/pr/1).\n\n~~~~diff\n-old\n+new\n\n```\n~~~~\n\n```console\n$ swift test\nok\n```"
        var streamed = TranscriptBlocks()
        for scalar in source.unicodeScalars { streamed.append(String(scalar)) }
        var cached = TranscriptBlocks()
        cached.append(source)
        let visible = streamed.completed + streamed.tail
        #expect(visible == cached.completed + cached.tail)
        #expect(visible.count == 4)
        #expect(visible[0] == .heading(1, TranscriptBlocks.markdown("Patch")))
        if case .prose(let text) = visible[1] {
            #expect(text.runs.contains { $0.link?.absoluteString == "https://example.org/pr/1" })
            #expect(text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        } else {
            Issue.record("Missing Markdown paragraph")
        }
        #expect(visible[2] == .fence(language: "diff", text: "-old\n+new\n\n```"))
        #expect(visible[3] == .fence(language: "console", text: "$ swift test\nok"))
    }

    @Test func unfinishedFenceUpdatesOnlyTheTail() {
        var stream = TranscriptBlocks()
        stream.append("Summary\n\n```swift\nlet")
        let completed = stream.completed
        #expect(completed == [.prose(TranscriptBlocks.markdown("Summary"))])
        #expect(stream.tail == [.fence(language: "swift", text: "let")])
        stream.append(" value = 42\n\nprint(value)\n```\n")
        #expect(stream.completed == completed + [.fence(language: "swift", text: "let value = 42\n\nprint(value)")])
        #expect(stream.tail.isEmpty)
    }
}
