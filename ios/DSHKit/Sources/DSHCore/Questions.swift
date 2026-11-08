import DSHProtocol
import Foundation

/// A question from the agent (STORY §4–§5, screen P1, ARCHITECTURE D18, D92). DSH's
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

    /// The bridge's id of the held request (`QuestionPending.id`).
    public var requestID: String
    public var items: [Item]
    /// Nil while the task waits for the answer.
    public var outcome: Outcome?
    /// Chosen labels by question id.
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
    public static func pendingRow(_ wire: Dshm_V1_QuestionPending, time: Date = .now) -> TranscriptItem {
        let items = wire.questions.map { q in
            Item(id: q.id, text: q.text, header: q.header, detail: q.detail,
                 options: q.options.map { Option(label: $0.label, description: $0.description_p) }, multiSelect: q.multiSelect)
        }
        return TranscriptItem(id: rowID(wire.id), taskID: wire.taskID, state: .running,
                              kind: .question(AgentQuestion(requestID: wire.id, items: items)), time: time)
    }

    /// The same question, closed by `QuestionResolved`.
    public func resolved(_ wire: Dshm_V1_QuestionResolved) -> AgentQuestion {
        var copy = self
        copy.outcome = switch wire.outcome {
        case .answered: .answered
        case .answeredElsewhere: .answeredElsewhere
        default: .cancelled
        }
        copy.answers = Dictionary(wire.answers.map { ($0.questionID, $0.selected) }, uniquingKeysWith: { a, _ in a })
        return copy
    }
}

extension TranscriptItem {
    /// The question of a question row.
    public var question: AgentQuestion? {
        if case .question(let q) = kind { q } else { nil }
    }
}
