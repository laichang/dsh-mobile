import DSHProtocol
import Foundation

/// S17 · one collapsed row of the transcript (PLAN.md §5 S17, screen 04, ARCHITECTURE D61): the
/// model's thinking in one step, or one tool call. The bridge maps DSH's typed data into it
/// (`transcript.v1`); nothing here is a model's summary. The app words each row itself.
public struct TranscriptItem: Codable, Equatable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable {
        case running, done, failed
    }

    public enum Kind: Codable, Equatable, Sendable {
        /// `durationMs` is 0 while it runs. `text` is DSH's reasoning, cut by the bridge.
        case thinking(durationMs: UInt64, text: String, truncated: Bool)
        case tool(Tool)
        /// D89: a message the user sent into the task after its first prompt (`conversation.v1`).
        case userMessage(text: String)
        /// An agent question, shown as a card (`questions.v1`, screen P1).
        case question(AgentQuestion)
    }

    public struct Tool: Codable, Equatable, Sendable {
        /// DSH's tool name (`read`, `edit`, `write`, `bash`, `grep`, …).
        public var name: String
        /// A path, a command or a pattern, from the call's arguments; empty when there is none.
        public var target: String
        public var linesAdded: Int
        public var linesRemoved: Int
        public var arguments: String
        public var argumentsTruncated: Bool
        public var error: String

        public init(name: String, target: String, linesAdded: Int = 0, linesRemoved: Int = 0,
                    arguments: String = "", argumentsTruncated: Bool = false, error: String = "") {
            self.name = name
            self.target = target
            self.linesAdded = linesAdded
            self.linesRemoved = linesRemoved
            self.arguments = arguments
            self.argumentsTruncated = argumentsTruncated
            self.error = error
        }
    }

    public var id: String
    public var taskID: String
    public var state: State
    public var kind: Kind
    public var time: Date
    /// Where the row sits: after this many UTF-8 bytes of the task's streamed transcript.
    public var offset: Int

    public init(id: String, taskID: String, state: State, kind: Kind, time: Date, offset: Int = 0) {
        self.id = id
        self.taskID = taskID
        self.state = state
        self.kind = kind
        self.time = time
        self.offset = offset
    }

    /// Nil for a block of a kind this app does not know (a newer bridge).
    public init?(_ wire: Dshm_V1_TranscriptBlock) {
        let kind: Kind
        switch wire.kind {
        case .thinking(let t)?:
            kind = .thinking(durationMs: t.durationMs, text: t.text, truncated: t.truncated)
        case .tool(let t)?:
            kind = .tool(Tool(name: t.tool, target: t.target, linesAdded: Int(t.linesAdded), linesRemoved: Int(t.linesRemoved),
                              arguments: t.arguments, argumentsTruncated: t.argumentsTruncated, error: t.error))
        case nil:
            return nil
        }
        let state: State = switch wire.state {
        case .done: .done
        case .failed: .failed
        default: .running
        }
        self.init(id: wire.blockID, taskID: wire.taskID, state: state, kind: kind,
                  time: Date(timeIntervalSince1970: TimeInterval(wire.timeMs) / 1000))
    }

    /// D89: a follow-up message, placed like a row: after the text that streamed before it.
    public init(_ wire: Dshm_V1_UserMessage) {
        self.init(id: Self.messagePrefix + wire.messageID, taskID: wire.taskID, state: .done, kind: .userMessage(text: wire.text),
                  time: Date(timeIntervalSince1970: TimeInterval(wire.timeMs) / 1000))
    }

    /// The row ID of a follow-up message is this prefix and the bridge's message ID.
    public static let messagePrefix = "message-"

    public var isUserMessage: Bool {
        if case .userMessage = kind { true } else { false }
    }

    /// Whole seconds of thinking, at least 1 once it ended ("已思考 8 秒").
    public var thinkingSeconds: Int? {
        guard case .thinking(let ms, _, _) = kind else { return nil }
        return state == .running ? nil : max(1, Int((Double(ms) / 1000).rounded()))
    }
}

/// S17 · a task's rows in transcript order. A later block with the same id replaces the row and
/// keeps its place (the bridge sends RUNNING, then DONE or FAILED).
public struct StructuredTranscript: Codable, Equatable, Sendable {
    public private(set) var items: [TranscriptItem] = []

    public init(items: [TranscriptItem] = []) {
        self.items = items
    }

    public var isEmpty: Bool { items.isEmpty }

    /// D89: how many follow-up messages the task has (each one starts a turn).
    public var followUpCount: Int { items.filter(\.isUserMessage).count }

    /// D89: only the follow-up messages, for a host without `transcript.v1`.
    public var userMessagesOnly: StructuredTranscript { StructuredTranscript(items: items.filter(\.isUserMessage)) }

    /// Adds `item` at `offset`, or updates the row with its id. Returns whether anything changed.
    @discardableResult
    public mutating func upsert(_ item: TranscriptItem, offset: Int) -> Bool {
        if let at = items.firstIndex(where: { $0.id == item.id }) {
            var updated = item
            updated.offset = items[at].offset
            guard items[at] != updated else { return false }
            items[at] = updated
            return true
        }
        var placed = item
        placed.offset = offset
        items.append(placed)
        return true
    }

    /// One piece of the session page: streamed text, or one collapsed row.
    public enum Segment: Equatable, Sendable {
        case text(String)
        case item(TranscriptItem)
    }

    /// `transcript` cut at each row's offset. Offsets past the end put the row at the end.
    public func segments(of transcript: String) -> [Segment] {
        var out: [Segment] = []
        let utf8 = transcript.utf8
        var start = utf8.startIndex
        var startOffset = 0
        // Offsets only grow: the transcript only grows, and rows are added in event order.
        for item in items {
            let offset = min(max(item.offset, startOffset), utf8.count)
            if offset > startOffset {
                let end = utf8.index(start, offsetBy: offset - startOffset)
                let piece = String(Substring(utf8[start..<end]))
                if !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.text(piece)) }
                start = end
                startOffset = offset
            }
            out.append(.item(item))
        }
        let rest = String(Substring(utf8[start...]))
        if !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.text(rest)) }
        return out
    }
}
