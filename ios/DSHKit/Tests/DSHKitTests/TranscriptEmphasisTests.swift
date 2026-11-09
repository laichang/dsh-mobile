import DSHCore
import Foundation
import Testing

/// S14 · bold text in phone replies (ARCHITECTURE D140): emphasis next to CJK text, as DSH Web shows it.
@Suite struct TranscriptEmphasisTests {
    /// The text of each run with `intent`, in order.
    private func spans(_ text: AttributedString, _ intent: InlinePresentationIntent = .stronglyEmphasized) -> [String] {
        text.runs.filter { $0.inlinePresentationIntent?.contains(intent) == true }.map { String(text[$0.range].characters) }
    }

    private func plain(_ text: AttributedString) -> String { String(text.characters) }

    /// The user's reply (2026-11-09, deepseek-flash). CommonMark takes it; it must stay bold.
    @Test func reportedReplyIsBold() {
        let text = TranscriptBlocks.markdown("今天是 **2026 年 11 月 9 日，星期一**。")
        #expect(spans(text) == ["2026 年 11 月 9 日，星期一"])
        #expect(plain(text) == "今天是 2026 年 11 月 9 日，星期一。")
    }

    /// The same symptom where CommonMark's flanking rules fail: a `**` between CJK punctuation and
    /// a CJK letter. DSH Web (remark-cjk-friendly) shows these bold; the phone showed the stars.
    @Test func boldNextToCJKPunctuation() {
        let cases: [(String, String, String)] = [
            ("**星期一（Monday）**是工作日。", "星期一（Monday）", "星期一（Monday）是工作日。"),
            ("**粗体。**后面", "粗体。", "粗体。后面"),
            ("今天是**「星期一」**。", "「星期一」", "今天是「星期一」。"),
            ("1. **注意：**明天放假", "注意：", "1. 注意：明天放假"),
        ]
        for (source, bold, shown) in cases {
            let text = TranscriptBlocks.markdown(source)
            #expect(spans(text) == [bold], "\(source)")
            #expect(plain(text) == shown, "\(source)")
        }
        let italic = TranscriptBlocks.markdown("*星期一（Monday）*是")
        #expect(spans(italic, .emphasized) == ["星期一（Monday）"])
        #expect(plain(italic) == "星期一（Monday）是")
    }

    /// The transcript path: streamed one scalar at a time, the follow-up's list reply is bold too.
    @Test func streamedListReplyIsBold() {
        let source = "确定。今天是：\n\n- **星期一（Monday）**是一周的第一天。\n- **11 月 9 日**是今天。"
        var stream = TranscriptBlocks()
        for scalar in source.unicodeScalars { stream.append(String(scalar)) }
        let blocks = stream.completed + stream.tail
        guard blocks.count == 2, case .prose(let list) = blocks[1] else {
            Issue.record("blocks: \(blocks)")
            return
        }
        #expect(spans(list) == ["星期一（Monday）", "11 月 9 日"])
        #expect(!plain(list).contains("*"))
    }

    /// Text the parser keeps as it is stays so: code spans, escapes, a lone star, ASCII rules.
    @Test func otherStarsStayAsTheyAre() {
        let code = TranscriptBlocks.markdown("用 `**星期一（Monday）**是` 写粗体")
        #expect(plain(code) == "用 **星期一（Monday）**是 写粗体")
        #expect(spans(code).isEmpty)
        let escaped = TranscriptBlocks.markdown("\\*\\*星期一（Monday）\\*\\*是")
        #expect(plain(escaped) == "**星期一（Monday）**是")
        #expect(spans(escaped).isEmpty)
        #expect(plain(TranscriptBlocks.markdown("2 * 3 * 4 和 5 * 6")) == "2 * 3 * 4 和 5 * 6")
        let ascii = TranscriptBlocks.markdown("a **b** c and **(d)**e")
        #expect(spans(ascii) == ["b"])
        #expect(plain(ascii) == "a b c and **(d)**e")
        #expect(plain(TranscriptBlocks.markdown("私用\u{E000}字符")) == "私用字符")
    }
}
