import DSHProtocol
import Foundation

/// A question from the agent (STORY §4–§5, screen P1). DSH's
/// `ask_user_question` waits until a person answers: the bridge holds it, the phone shows it as a
/// card in the transcript, and the first answer (phone or DSH Web) wins.
public struct AgentQuestion: Codable, Equatable, Sendable {
    public struct Option: Codable, Equatable, Sendable {
        public var label: String
        public var description: String

        public init(label: String, description: String = "") {
            self.label = label
            self.description = description
        }
    }

    public struct Item: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var text: String
        public var header: String
        public var detail: String
        public var options: [Option]
        public var multiSelect: Bool

        public init(id: String, text: String, header: String = "", detail: String = "", options: [Option], multiSelect: Bool = false) {
            self.id = id
            self.text = text
            self.header = header
            self.detail = detail
            self.options = options
            self.multiSelect = multiSelect
        }
    }

    public enum Outcome: String, Codable, Sendable {
        /// Answered on a paired phone.
        case answered
        /// Answered on DSH Web or desktop.
        case answeredElsewhere
        /// The turn ended before an answer.
        case cancelled
    }

    /// One question's answer as the phone sends it: chosen option labels, or typed text (DSH's
    /// free-text answer), or both when the question is multi-select.
    public struct Reply: Equatable, Sendable {
        public var selected: [String]
        public var custom: String

        public init(selected: [String] = [], custom: String = "") {
            self.selected = selected
            self.custom = custom
        }
    }

    /// The bridge's id of the held request (`QuestionPending.id`).
    public var requestID: String
    public var items: [Item]
    /// Nil while the task waits for the answer.
    public var outcome: Outcome?
    /// Chosen labels by question id, then the typed text, if any.
    public var answers: [String: [String]]

    public init(requestID: String, items: [Item], outcome: Outcome? = nil, answers: [String: [String]] = [:]) {
        self.requestID = requestID
        self.items = items
        self.outcome = outcome
        self.answers = answers
    }

    /// The transcript row id of a request.
    public static func rowID(_ requestID: String) -> String { "question-\(requestID)" }

    /// The card as a transcript row, placed where the text stood when it arrived.
    package static func pendingRow(_ wire: Dshm_V1_QuestionPending, time: Date = .now) -> TranscriptItem {
        let items = wire.questions.map { q in
            Item(id: q.id, text: q.text, header: q.header, detail: q.detail,
                 options: q.options.map { Option(label: $0.label, description: $0.description_p) }, multiSelect: q.multiSelect)
        }
        return TranscriptItem(id: rowID(wire.id), taskID: wire.taskID, state: .running,
                              kind: .question(AgentQuestion(requestID: wire.id, items: items)), time: time)
    }

    package struct Resolution: Equatable, Sendable {
        let id: String
        let taskID: String
        let outcome: Outcome
        let answers: [String: [String]]

        package init(_ wire: Dshm_V1_QuestionResolved) {
            id = wire.id
            taskID = wire.taskID
            outcome = switch wire.outcome {
            case .answered: .answered
            case .answeredElsewhere: .answeredElsewhere
            default: .cancelled
            }
            answers = Dictionary(wire.answers.map { ($0.questionID, $0.selected + ($0.custom.isEmpty ? [] : [$0.custom])) },
                                 uniquingKeysWith: { first, _ in first })
        }
    }

    package func resolved(_ resolution: Resolution) -> AgentQuestion {
        var copy = self
        copy.outcome = resolution.outcome
        copy.answers = resolution.answers
        return copy
    }

    /// A typed answer from the composer ("回答 Agent…"), for every question of the request: text
    /// that is an offered option's label chooses that option; any other text is the free-text answer.
    public func replies(typed text: String) -> [String: Reply] {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return Dictionary(uniqueKeysWithValues: items.map { item in
            let option = item.options.first { $0.label.compare(typed, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame }
            return (item.id, option.map { Reply(selected: [$0.label]) } ?? Reply(custom: typed))
        })
    }
}

extension TranscriptItem {
    /// The question of a question row.
    public var question: AgentQuestion? {
        if case .question(let q) = kind { q } else { nil }
    }
}

extension StructuredTranscript {
    /// The question the task waits on now: the latest card with no answer yet.
    public var pendingQuestion: AgentQuestion? {
        items.last { $0.question != nil && $0.question?.outcome == nil }?.question
    }

    /// The questions of the host's summary (`pending_questions`) that this transcript lacks, as
    /// when the log lost their events, come back where the text stands now. When the task has
    /// ended, a card still open closes: its `QuestionResolved` is gone, and nothing waits on it.
    /// Returns whether anything changed.
    mutating func restoreQuestions(_ pending: [TranscriptItem], offset: Int, ended: Bool) -> Bool {
        var changed = false
        for item in pending where !items.contains(where: { $0.id == item.id }) {
            changed = upsert(item, offset: offset) || changed
        }
        guard ended else { return changed }
        for var row in items {
            guard var question = row.question, question.outcome == nil else { continue }
            question.outcome = .cancelled
            row.kind = .question(question)
            row.state = .failed
            changed = upsert(row, offset: row.offset) || changed
        }
        return changed
    }
}
