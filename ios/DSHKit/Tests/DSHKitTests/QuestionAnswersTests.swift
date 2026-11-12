@testable import DSHCore
@testable import DSHFeatures
import DSHProtocol
import DSHTestSupport
import DSHPlatform
import Foundation
import Testing

/// Agent questions after the first card (screen P1), against
/// `FakeHost`: a question counts in 等我处理 and comes back from the host's summary (as it does for
/// approvals), also after a relaunch; a typed and a multi-select answer reach DSH as given; an
/// answer from another client withdraws the card.
@MainActor
@Suite(.serialized) struct QuestionAnswersTests {
    static let templates = AgentQuestion.Item(
        id: "q1", text: "桌面上有两个周报模板，用哪个？", header: "模板",
        options: [.init(label: "公司模板.pptx", description: "带公司页眉"), .init(label: "简洁版.pptx")])
    static let parts = AgentQuestion.Item(
        id: "q2", text: "周报里放哪些部分？",
        options: [.init(label: "进展"), .init(label: "风险"), .init(label: "下周计划")], multiSelect: true)
    static let prompt = "用本周的笔记写一份周报"

    func host(_ items: [AgentQuestion.Item] = [templates], seed: [Dshm_V1_TaskSummary] = []) -> FakeHost {
        var script = FakeBridge.Script(reply: ["好的", "，开始写。"], chunkDelay: .milliseconds(20))
        script.question = (prompt: Self.prompt, items: items)
        return FakeHost(script: script, seed: seed, extraCapabilities: [DSHProtocolInfo.transcriptCapability])
    }

    func launch(_ host: FakeHost, url: URL = FollowUpTests.cacheURL()) throws -> TaskListStore {
        let store = try FollowUpTests().launch(host, url: url)
        store.composer.prompt = Self.prompt
        return store
    }

    /// Starts the task and waits until it waits on its question.
    func asked(_ store: TaskListStore) async throws -> (key: String, question: AgentQuestion) {
        let key = try #require(await store.send())
        await waitForStore("asked") { store.task(key)?.blocks.pendingQuestion != nil }
        return (key, try #require(store.task(key)?.blocks.pendingQuestion))
    }

    // MARK: - Fixtures and pure logic

    @Test func theSummaryCarriesEveryPendingQuestion() throws {
        guard case .taskUpserted(let upserted)? = try QuestionsTests().frame("questions_waiting_task_upserted_event").event.body else {
            Issue.record("not a TaskUpserted event"); return
        }
        let snapshot = TaskSnapshot(upserted.task)
        #expect(snapshot.state == .waitingOnUser)
        let question = try #require(snapshot.questions.first?.question)
        #expect(snapshot.questions.map(\.id) == [AgentQuestion.rowID("7a2d3e4f-5061-4728-9a3b-4c5d6e7f8091")])
        #expect(question.items.map(\.multiSelect) == [false, true])
        #expect(question.outcome == nil)
    }

    @Test func theTypedAnswerFixtureHasTheTextAndTheChoices() throws {
        guard case .answerQuestion(let answer)? = try QuestionsTests().frame("questions_typed_answer_request").request.body else {
            Issue.record("not an AnswerQuestion request"); return
        }
        #expect(answer.answers.map(\.custom) == ["用去年的模板", ""])
        #expect(answer.answers.map(\.selected) == [[], ["进展", "下周计划"]])
    }

    @Test func typedTextChoosesAnOptionWithTheSameLabelElseIsTheFreeTextAnswer() {
        let question = AgentQuestion(requestID: "r", items: [Self.templates])
        #expect(question.replies(typed: "  简洁版.PPTX \n") == ["q1": .init(selected: ["简洁版.pptx"])])
        #expect(question.replies(typed: " 用去年的模板 ") == ["q1": .init(custom: "用去年的模板")])
    }

    // MARK: - Against FakeHost

    @Test func aPendingQuestionWaitsOnMeAndATypedAnswerReachesDshAsGiven() async throws {
        let host = host()
        let store = try launch(host)
        store.foreground()
        defer { store.background() }
        let (key, question) = try await asked(store)
        await waitForStore("waiting on me") { store.task(key)?.state == .waitingOnUser }
        #expect(store.sections.waitingOnMe.map(\.key) == [key])
        #expect(store.task(key)?.drawerMark == .waiting)
        #expect(store.canAnswerQuestions(hostKey: try #require(store.task(key)).hostKey))

        store.composer.sessionDrafts[key] = " 用去年的模板 "
        try await store.submitDraft(for: #require(store.task(key)), answering: question)
        #expect(store.composer.sessionDrafts[key] == nil)
        let given = try #require(host.questionAnswers.last)
        #expect(given.answers.map(\.questionID) == ["q1"])
        #expect(given.answers.map(\.custom) == ["用去年的模板"])
        #expect(given.answers.map(\.selected) == [[]])
        await waitForStore("answered") { store.task(key)?.blocks.items.compactMap(\.question).first?.outcome == .answered }
        let card = try #require(store.task(key)?.blocks.items.compactMap(\.question).first)
        #expect(card.answers == ["q1": ["用去年的模板"]])
        #expect(store.task(key)?.blocks.pendingQuestion == nil)
        await waitForStore("done") { store.task(key)?.state == .completed }
        #expect(store.sections.waitingOnMe.isEmpty)
    }

    @Test func aMultiSelectAnswerReachesDshAsGiven() async throws {
        let host = host([Self.templates, Self.parts])
        let store = try launch(host)
        store.foreground()
        defer { store.background() }
        let (key, question) = try await asked(store)
        let hostKey = try #require(store.task(key)).hostKey
        // One choice for a question that is not multi-select: the host refuses it, and nothing reaches DSH.
        await #expect(throws: (any Error).self) {
            try await store.answerQuestion(question, hostKey: hostKey, answers: [
                "q1": .init(selected: ["公司模板.pptx", "简洁版.pptx"]), "q2": .init(selected: ["进展"])])
        }
        #expect(host.questionAnswers.isEmpty)

        try await store.answerQuestion(question, hostKey: hostKey, answers: [
            "q1": .init(selected: ["简洁版.pptx"]), "q2": .init(selected: ["进展", "下周计划"])])
        let given = try #require(host.questionAnswers.last)
        #expect(given.answers.map(\.questionID) == ["q1", "q2"])
        #expect(given.answers.map(\.selected) == [["简洁版.pptx"], ["进展", "下周计划"]])
        await waitForStore("answered") { store.task(key)?.blocks.pendingQuestion == nil }
        let card = try #require(store.task(key)?.blocks.items.compactMap(\.question).first)
        #expect(card.answers == ["q1": ["简洁版.pptx"], "q2": ["进展", "下周计划"]])
    }

    @Test func aQuestionOnlyInTheSummaryComesBackAndStaysAfterARelaunch() async throws {
        // A task whose QuestionPending event is gone (a trimmed log): only its summary has the question.
        var summary = Dshm_V1_TaskSummary()
        summary.taskID = "session-waiting"
        summary.title = Self.prompt
        summary.state = .waitingOnUser
        summary.createdAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        summary.updatedAtMs = summary.createdAtMs
        var pending = Dshm_V1_QuestionPending()
        pending.id = "session-waiting-question"
        pending.taskID = summary.taskID
        var q = Dshm_V1_Question()
        q.id = "q1"
        q.text = Self.templates.text
        q.options = Self.templates.options.map { var o = Dshm_V1_QuestionOption(); o.label = $0.label; return o }
        pending.questions = [q]
        summary.pendingQuestions = [pending]
        let host = host(seed: [summary])
        let url = FollowUpTests.cacheURL()
        let store = try launch(host, url: url)
        store.foreground()
        let key = CachedTask.key(hostKey: "fake:127.0.0.1:47801", taskID: summary.taskID)
        await waitForStore("restored") { store.task(key)?.blocks.pendingQuestion != nil }
        #expect(store.task(key)?.blocks.pendingQuestion?.requestID == pending.id)
        #expect(store.sections.waitingOnMe.map(\.key) == [key])
        store.background()

        // Relaunch with the host offline: the cache still has the card, under 等我处理.
        host.setReachable(false)
        let relaunched = try launch(host, url: url)
        #expect(relaunched.task(key)?.blocks.pendingQuestion?.requestID == pending.id)
        #expect(relaunched.sections.waitingOnMe.map(\.key) == [key])
        #expect(relaunched.task(key)?.drawerMark == .waiting)
    }

    @Test func anAnswerFromAnotherClientWithdrawsTheCard() async throws {
        let host = host()
        let store = try launch(host)
        store.foreground()
        defer { store.background() }
        let (key, _) = try await asked(store)
        host.answerQuestionFromElsewhere(["q1": ["公司模板.pptx"]])
        await waitForStore("withdrawn") { store.task(key)?.blocks.pendingQuestion == nil }
        let card = try #require(store.task(key)?.blocks.items.compactMap(\.question).first)
        #expect(card.outcome == .answeredElsewhere)
        #expect(card.answers == ["q1": ["公司模板.pptx"]])
        await waitForStore("done") { store.task(key)?.state == .completed }
        #expect(store.sections.waitingOnMe.isEmpty)
    }

    @Test func aTaskThatEndedClosesACardWhoseAnswerTheLogLost() {
        var blocks = StructuredTranscript()
        var pending = Dshm_V1_QuestionPending()
        pending.id = "r1"
        pending.taskID = "t"
        let row = AgentQuestion.pendingRow(pending)
        let restored = blocks.restoreQuestions([row], offset: 0, ended: false)
        #expect(restored)
        #expect(blocks.pendingQuestion?.requestID == "r1")
        let again = blocks.restoreQuestions([row], offset: 0, ended: false)
        #expect(!again, "a card is restored once")
        let closed = blocks.restoreQuestions([], offset: 0, ended: true)
        #expect(closed)
        #expect(blocks.pendingQuestion == nil)
        #expect(blocks.items.first?.question?.outcome == .cancelled)
    }
}
