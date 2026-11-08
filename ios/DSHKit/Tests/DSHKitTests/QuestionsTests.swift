import DSHCore
import DSHProtocol
import Foundation
import Testing

/// Agent questions · the Swift half of the question fixtures (the TS half: bridge/test/questions.test.ts).
@Suite struct QuestionsTests {
    func frame(_ name: String) throws -> Dshm_V1_Frame {
        let bytes = try Data(contentsOf: GoldenFixtures.fixturesDir.appending(path: "\(name).binpb"))
        return try Dshm_V1_Frame(serializedBytes: bytes)
    }

    @Test func pendingQuestionBecomesARunningCardRow() throws {
        guard case .questionPending(let wire)? = try frame("questions_pending_event").event.body else {
            Issue.record("not a QuestionPending event"); return
        }
        let row = AgentQuestion.pendingRow(wire, time: Date(timeIntervalSince1970: 0))
        #expect(row.id == "question-6f1c2c1e-3f5a-4d0b-9c33-1d2e3f4a5b6c")
        #expect(row.taskID == "session-1")
        #expect(row.state == .running)
        let question = try #require(row.question)
        #expect(question.outcome == nil)
        #expect(question.items.map(\.text) == ["桌面上有两个周报模板，用哪个？"])
        #expect(question.items[0].options == [.init(label: "公司模板.pptx", description: "the company one"), .init(label: "简洁版.pptx")])
        #expect(!question.items[0].multiSelect)
    }

    @Test func resolvedEventClosesTheCardWithTheAnswer() throws {
        guard case .questionPending(let pending)? = try frame("questions_pending_event").event.body,
              case .questionResolved(let resolved)? = try frame("questions_resolved_event").event.body else {
            Issue.record("fixtures"); return
        }
        let question = try #require(AgentQuestion.pendingRow(pending).question)
        let closed = question.resolved(resolved)
        #expect(closed.outcome == .answeredElsewhere)
        #expect(closed.answers == ["q1": ["公司模板.pptx"]])
    }

    @Test func answerRequestEncodesTheChosenLabel() throws {
        guard case .answerQuestion(let answer)? = try frame("questions_answer_request").request.body else {
            Issue.record("not an AnswerQuestion request"); return
        }
        #expect(answer.answers.map(\.questionID) == ["q1"])
        #expect(answer.answers[0].selected == ["简洁版.pptx"])
    }

    @Test func aClosedCardKeepsItsPlaceAndSurvivesTheCache() throws {
        guard case .questionPending(let pending)? = try frame("questions_pending_event").event.body,
              case .questionResolved(let resolved)? = try frame("questions_resolved_event").event.body else {
            Issue.record("fixtures"); return
        }
        var blocks = StructuredTranscript()
        var row = AgentQuestion.pendingRow(pending, time: Date(timeIntervalSince1970: 0))
        blocks.upsert(row, offset: 6)
        row.kind = .question(try #require(row.question).resolved(resolved))
        row.state = .done
        blocks.upsert(row, offset: 99)
        #expect(blocks.items.map(\.offset) == [6])
        let decoded = try JSONDecoder().decode(StructuredTranscript.self, from: JSONEncoder().encode(blocks))
        #expect(decoded == blocks)
        #expect(decoded.segments(of: "Hello. Using 公司模板.pptx.").count == 3)
    }
}
