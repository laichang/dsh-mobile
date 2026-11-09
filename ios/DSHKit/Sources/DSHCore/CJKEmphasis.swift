import Foundation

/// S14 · emphasis next to CJK text (ARCHITECTURE D140). CommonMark's flanking rules leave
/// `**星期一（Monday）**是` as text: the closing `**` follows punctuation and comes before a letter.
/// DSH Web renders it bold (its Markdown has remark-cjk-friendly). Foundation's parser has no such
/// option, so before parsing, the `*` and `**` pairs that only a CJK neighbour keeps apart become
/// private-use marks; after parsing, the marks become the emphasis and go away.
enum CJKEmphasis {
    static let strongOpen: Character = "\u{E000}"
    static let strongClose: Character = "\u{E001}"
    static let emphasisOpen: Character = "\u{E002}"
    static let emphasisClose: Character = "\u{E003}"
    private static let marks: ClosedRange<UInt32> = 0xE000...0xE003

    /// Parses inline Markdown as `parse` does, with the CJK-friendly `*` and `**` pairs too.
    static func markdown(_ text: String, parse: (String) -> AttributedString) -> AttributedString {
        // The marks are private-use characters; a reply that has them loses them.
        let clean = text.unicodeScalars.contains { marks.contains($0.value) }
            ? String(String.UnicodeScalarView(text.unicodeScalars.filter { !marks.contains($0.value) }))
            : text
        guard let marked = mark(clean) else { return parse(clean) }
        return apply(parse(marked))
    }

    private struct Run {
        var start: Int
        var length: Int
        var opens: Bool
        var closes: Bool
        var strictOpens: Bool
        var strictCloses: Bool
    }

    /// The text with marks for the pairs that CommonMark does not take and a CJK neighbour allows,
    /// or nil when there are none. Code spans and backslash escapes stay as they are.
    static func mark(_ text: String) -> String? {
        guard text.contains("*") else { return nil }
        let chars = Array(text)
        var runs: [Run] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, chars[i + 1].isASCII, chars[i + 1].isPunctuation || chars[i + 1].isSymbol {
                i += 2
                continue
            }
            if c == "`" {
                let n = run(of: "`", in: chars, at: i)
                var j = i + n
                var closed = false
                while j < chars.count {
                    if chars[j] == "`" {
                        let m = run(of: "`", in: chars, at: j)
                        if m == n { j += m; closed = true; break }
                        j += m
                    } else {
                        j += 1
                    }
                }
                i = closed ? j : i + n
                continue
            }
            if c == "*" {
                let n = run(of: "*", in: chars, at: i)
                let before = i > 0 ? chars[i - 1] : nil
                let after = i + n < chars.count ? chars[i + n] : nil
                let left = flanks(toward: after, away: before)
                let right = flanks(toward: before, away: after)
                let cjk = isCJK(before) || isCJK(after)
                runs.append(Run(start: i, length: n,
                                opens: after.map { !$0.isWhitespace } == true && (left || cjk),
                                closes: before.map { !$0.isWhitespace } == true && (right || cjk),
                                strictOpens: left, strictCloses: right))
                i += n
                continue
            }
            i += 1
        }

        var openers: [Run] = []
        var pairs: [(Run, Run)] = []
        for run in runs where run.length <= 2 {
            if run.closes, let at = openers.lastIndex(where: { $0.length == run.length }) {
                let opener = openers[at]
                openers.removeSubrange(at...)
                // A pair CommonMark takes is left to the parser.
                if !(opener.strictOpens && run.strictCloses) { pairs.append((opener, run)) }
                continue
            }
            if run.opens { openers.append(run) }
        }
        guard !pairs.isEmpty else { return nil }

        var replacement: [Int: (length: Int, mark: Character)] = [:]
        for (opener, closer) in pairs {
            let strong = opener.length == 2
            replacement[opener.start] = (opener.length, strong ? strongOpen : emphasisOpen)
            replacement[closer.start] = (closer.length, strong ? strongClose : emphasisClose)
        }
        var out = ""
        var k = 0
        while k < chars.count {
            if let r = replacement[k] {
                out.append(r.mark)
                k += r.length
            } else {
                out.append(chars[k])
                k += 1
            }
        }
        return out
    }

    /// The parsed text with each marked pair as emphasis, and without the marks.
    static func apply(_ parsed: AttributedString) -> AttributedString {
        var out = parsed
        let kinds: [(Character, Character, InlinePresentationIntent)] = [
            (strongOpen, strongClose, .stronglyEmphasized), (emphasisOpen, emphasisClose, .emphasized),
        ]
        for (open, close, intent) in kinds {
            while let start = out.characters.firstIndex(of: open) {
                let inside = out.characters.index(after: start)
                if let end = out.characters[inside...].firstIndex(of: close) {
                    for range in out[inside..<end].runs.map(\.range) {
                        out[range].inlinePresentationIntent = (out[range].inlinePresentationIntent ?? []).union(intent)
                    }
                    if let end = out.characters.firstIndex(of: close) {
                        out.removeSubrange(end..<out.characters.index(after: end))
                    }
                }
                if let start = out.characters.firstIndex(of: open) {
                    out.removeSubrange(start..<out.characters.index(after: start))
                }
            }
            // A close mark whose open mark the parser dropped (for example inside a link's URL).
            while let end = out.characters.firstIndex(of: close) {
                out.removeSubrange(end..<out.characters.index(after: end))
            }
        }
        return out
    }

    private static func run(of character: Character, in chars: [Character], at start: Int) -> Int {
        var end = start
        while end < chars.count, chars[end] == character { end += 1 }
        return end - start
    }

    /// CommonMark's flanking test for a delimiter run: `toward` is the character on the side of
    /// the emphasized text, `away` the one on the other side (nil: the start or end of the text).
    private static func flanks(toward: Character?, away: Character?) -> Bool {
        guard let toward, !toward.isWhitespace else { return false }
        guard isPunctuation(toward) else { return true }
        guard let away else { return true }
        return away.isWhitespace || isPunctuation(away)
    }

    /// CommonMark punctuation: Unicode P and S categories (ASCII punctuation is among them).
    private static func isPunctuation(_ c: Character) -> Bool {
        c.isPunctuation || c.isSymbol
    }

    /// Han, kana, Hangul, Bopomofo, and the CJK and full-width punctuation.
    static func isCJK(_ c: Character?) -> Bool {
        guard let scalar = c?.unicodeScalars.first?.value else { return false }
        switch scalar {
        case 0x1100...0x11FF, 0x2E80...0x2FDF, 0x3000...0x303F, 0x3040...0x30FF, 0x3100...0x312F,
             0x3130...0x318F, 0x31A0...0x31FF, 0x3200...0x4DBF, 0x4E00...0x9FFF, 0xA960...0xA97F,
             0xAC00...0xD7FF, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFFEF, 0x20000...0x3FFFF:
            return true
        default:
            return false
        }
    }
}
