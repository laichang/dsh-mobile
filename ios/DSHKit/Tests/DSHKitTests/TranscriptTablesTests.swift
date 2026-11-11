import DSHCore
import DSHFeatures
import DSHTestSupport
import Foundation
import Testing

/// GFM pipe tables in `TranscriptBlocks`.
@Suite struct TranscriptTablesTests {
    private func md(_ text: String) -> AttributedString { TranscriptBlocks.markdown(text) }

    private func blocks(_ source: String) -> [TranscriptBlocks.Block] {
        var stream = TranscriptBlocks()
        stream.append(source)
        return stream.completed + stream.tail
    }

    private func tableIn(_ block: TranscriptBlocks.Block?) -> TranscriptBlocks.Table? {
        if case .table(let table) = block { return table }
        return nil
    }

    @Test func delimiterRowSetsAlignment() {
        let found = blocks("| Left | Center | Right | Plain |\n|:---|:-:|---:|---|\n| a | b | c | d |\n")
        #expect(found.count == 1)
        let table = tableIn(found.first)
        #expect(table?.alignments == [.leading, .center, .trailing, .leading])
        #expect(table?.header == ["Left", "Center", "Right", "Plain"].map(md))
        #expect(table?.rows == [["a", "b", "c", "d"].map(md)])
    }

    @Test func outerPipesAreOptionalAndRowsMatchTheHeader() {
        let found = blocks("Case | Before | After\n--- | --- | ---\nshort | row\nlong | row | with | extra\nno pipes here\n")
        let table = tableIn(found.first)
        #expect(table?.header == ["Case", "Before", "After"].map(md))
        #expect(table?.rows == [
            ["short", "row", ""].map(md),
            ["long", "row", "with"].map(md),
            ["no pipes here", "", ""].map(md),
        ])
    }

    @Test func escapedPipeStaysInItsCell() {
        let table = tableIn(blocks("| Expr | Meaning |\n| --- | --- |\n| `a \\| b` | a or b \\| c |\n").first)
        #expect(table?.rows.first?.count == 2)
        #expect(table?.rows.first?[0] == md("`a | b`"))
        #expect(table?.rows.first?[1] == md("a or b | c"))
    }

    @Test func cellsKeepInlineMarkdown() throws {
        let table = try #require(tableIn(blocks("| Name | Link |\n|---|---|\n| **bold** `code` | [PR](https://example.org/pr/1) |").first))
        let name = try #require(table.rows.first?[0])
        #expect(name.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        #expect(name.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        #expect(String(name.characters) == "bold code")
        #expect(table.rows.first?[1].runs.contains { $0.link?.absoluteString == "https://example.org/pr/1" } == true)
    }

    @Test func tableBetweenProse() {
        let source = "I ran it twice:\n| Case | Result |\n| --- | --- |\n| replay | ok |\n\nBoth pass.\n"
        let found = blocks(source)
        #expect(found.count == 3)
        #expect(found[0] == .prose(md("I ran it twice:")))
        #expect(tableIn(found[1])?.rows == [["replay", "ok"].map(md)])
        #expect(found[2] == .prose(md("Both pass.")))
    }

    @Test func headingAndFenceEndATable() {
        let found = blocks("| a | b |\n|---|---|\n| 1 | 2 |\n## Next\n| 3 | 4 |\n|---|---|\n```swift\nlet x = 1\n```\n")
        #expect(found.count == 4)
        #expect(tableIn(found[0])?.rows == [["1", "2"].map(md)])
        #expect(found[1] == .heading(2, md("Next")))
        #expect(tableIn(found[2])?.rows == [])
        #expect(found[3] == .fence(language: "swift", text: "let x = 1"))
    }

    @Test func linesWithPipesThatAreNotATableStayProse() {
        let source = "Pipe it: `ls | wc -l` | then count.\nThe next line is not a delimiter.\n\na | b\n---\n\n| x | y |\n| --- |\n"
        let found = blocks(source)
        #expect(found.allSatisfy { tableIn($0) == nil })
        #expect(found.first == .prose(md("Pipe it: `ls | wc -l` | then count.\nThe next line is not a delimiter.")))
        #expect(found.count == 3)
    }

    @Test func unfinishedTableAtTheStreamingTail() {
        var stream = TranscriptBlocks()
        stream.append("Results:\n\n| Case | Before | After |\n")
        #expect(stream.completed == [.prose(md("Results:"))])
        // Only the header so far: it is still a line of text.
        #expect(stream.tail == [.prose(md("| Case | Before | After |"))])

        // The delimiter row is coming in: the header already shows as a table.
        stream.append("| --- | :-")
        #expect(tableIn(stream.tail.first)?.header == ["Case", "Before", "After"].map(md))
        #expect(tableIn(stream.tail.first)?.rows == [])

        // Rows show as they arrive; a half-streamed row fills its remaining cells with nothing.
        stream.append("-: | --- |\n| replay, then live | ok | ok |\n| live, then rep")
        #expect(stream.completed == [.prose(md("Results:"))], "an open table is still the tail")
        let open = tableIn(stream.tail.first)
        #expect(open?.alignments == [.leading, .center, .leading])
        #expect(open?.rows == [["replay, then live", "ok", "ok"].map(md), ["live, then rep", "", ""].map(md)])

        // A blank line completes the table; it then renders once, from `completed`.
        stream.append("lay | wrong order | ok |\n\nDone")
        #expect(stream.completed.count == 2)
        #expect(tableIn(stream.completed.last)?.rows.last == ["live, then replay", "wrong order", "ok"].map(md))
        #expect(stream.tail == [.prose(md("Done"))])
    }

    @Test func streamedTableMatchesCachedSource() {
        let source = "Intro\n| A | B |\n|:--|--:|\n| `x \\| y` | **1** |\n| z | 2 |\nOutro\n\n# End\n"
        var streamed = TranscriptBlocks()
        for character in source { streamed.append(String(character)) }
        var cached = TranscriptBlocks()
        cached.append(source)
        #expect(streamed.completed + streamed.tail == cached.completed + cached.tail)
        // "Outro" has no pipe but is still a row: GFM ends a table only at a blank line or a new block.
        #expect(tableIn(cached.completed[1])?.rows.count == 3)
    }
}

/// The FakeBridge reply behind MarkdownTablesUITests' wide table.
@MainActor
@Suite(.serialized) struct TablesReplyTests {
    @Test func tablesPromptRepliesWithAWideTable() async throws {
        var script = FakeBridge.Script.codingTask(delay: .milliseconds(10))
        script.chunkDelay = .milliseconds(1)
        script.variants = script.variants.map { variant in
            var fast = variant
            fast.script.chunkDelay = .milliseconds(1)
            return fast
        }
        let host = FakeHost(script: script)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dshm-s28-\(UUID().uuidString).store")
        let connection = HostConnection(endpoint: .localBridge(), channel: PlaintextChannel(), transport: host.factory)
        let store = TaskListStore(cache: try TaskCache(url: url), hosts: [.init(key: "fake:127.0.0.1:47801", connection: connection)],
                                  prompt: FakeBridge.tablesPrompt)
        store.backoff = (.milliseconds(20), .milliseconds(100))
        store.sendWaitsFor = .seconds(5)
        store.foreground()
        let key = try #require(await store.send())
        await waitForStore("the whole reply") { store.task(key)?.transcript == FakeBridge.tablesReply + "\n" }
        let transcript = try #require(store.task(key)?.transcript)
        #expect(transcript == FakeBridge.tablesReply + "\n")
        var blocks = TranscriptBlocks()
        blocks.append(transcript)
        let tables = blocks.completed.compactMap { block -> TranscriptBlocks.Table? in
            if case .table(let table) = block { return table }
            return nil
        }
        #expect(tables.count == 1)
        #expect(tables.first?.alignments == [.leading, .center, .trailing, .trailing, .leading])
        #expect(tables.first?.rows.count == 3)
        store.background()
    }
}
