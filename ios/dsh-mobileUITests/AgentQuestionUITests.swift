import XCTest

/// Screen P1 against real DSH with the mock model (scripts/demo/questions.sh): the agent asks
/// which of two templates to use; the card shows the question and its options; one tap answers;
/// the task continues with that answer. With `--all`: a typed answer from the composer, and a
/// multi-select question that waits under 等我处理 and in the drawer badge across a relaunch.
@MainActor
final class AgentQuestionUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(prompt: String?, reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-DSHMBridgePort", env["DSHM_BRIDGE_PORT"] ?? "47800"]
        if let prompt { app.launchArguments += ["-DSHMPresetPrompt", prompt] }
        if reset { app.launchArguments += ["-DSHMResetStore", "YES", "-DSHMResetPairing", "YES"] }
        if reset { launchEnrolled(app) } else { app.launch() }
        return app
    }

    /// Sends the preset prompt and waits for the question's card on the session page.
    private func ask(_ app: XCUIApplication) -> XCUIElement {
        let send = app.buttons["composer.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 20))
        send.tap()
        let card = app.descendants(matching: .any)["question.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 60), app.debugDescription)
        XCTAssertEqual(card.value as? String, "pending")
        return card
    }

    /// The answer text the transcript ends with, once the task is done.
    private func expectDone(_ app: XCUIApplication, reply: String) {
        let status = app.descendants(matching: .any)["task.status"]
        waitForValue(status, in: ["completed"], timeout: 60)
        let transcript = app.descendants(matching: .any)["transcript.structured"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        XCTAssertTrue((transcript.value as? String ?? "").contains(reply), transcript.debugDescription)
    }

    /// P1: the composer answers the waiting question ("回答 Agent…"); the text goes to the question,
    /// not into the task as a follow-up. The card shows the typed answer and the task continues.
    func testTypeAnAnswerInTheComposer() throws {
        try XCTSkipIf(env["DSHM_QUESTIONS_HOST"] == nil, "needs the real question host from scripts/demo/questions.sh")
        let app = launch(prompt: "用本周的笔记写一份周报", reset: true)
        let card = ask(app)
        // The amber bar: the task waits for an answer.
        let bar = app.descendants(matching: .any)["milestone.card"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(bar.label, "等你回答")
        XCTAssertTrue(app.staticTexts["question.footer"].label.hasPrefix("也可以在下面直接回答"), app.staticTexts["question.footer"].label)
        let field = app.textFields["session.followUp"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(field.placeholderValue, "回答 Agent…")
        type("用去年的模板", into: field)
        saveShot("questions-typed")
        app.buttons["session.send"].tap()

        waitForValue(card, in: ["answered"], timeout: 20)
        let answer = app.descendants(matching: .any)["question.answer"].firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        XCTAssertTrue(answer.label.contains("用去年的模板"), answer.label)
        XCTAssertFalse(app.descendants(matching: .any)["followup.queued"].exists, "the answer is not a queued follow-up")
        expectDone(app, reply: "好的，用去年的模板写周报。")
        XCTAssertNotEqual(bar.exists ? bar.label : "", "等你回答")
        saveShot("questions-typed-answered")
    }

    /// P1 and screen 03: a multi-select question counts in 等我处理 (所有任务) and in the drawer
    /// badge, also after a relaunch; its card there takes several chips and 回答.
    func testAWaitingQuestionIsUnderWaitingOnMeAcrossARelaunch() throws {
        try XCTSkipIf(env["DSHM_QUESTIONS_HOST"] == nil, "needs the real question host from scripts/demo/questions.sh")
        var app = launch(prompt: "周报分几部分？用本周的笔记写", reset: true)
        _ = ask(app)
        expectWaiting(app)
        saveShot("questions-waiting")
        // The cache keeps the card; the coalesced save lands before terminate().
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        app.terminate()

        app = launch(prompt: nil, reset: false)
        expectWaiting(app)
        saveShot("questions-waiting-relaunched")
        let card = app.descendants(matching: .any)["tasklist.question"]
        let options = card.buttons.matching(identifier: "question.option")
        XCTAssertEqual(options.count, 3)
        let submit = card.buttons["question.submit"]
        XCTAssertFalse(submit.isEnabled, "nothing chosen yet")
        options.element(boundBy: 0).tap()
        options.element(boundBy: 2).tap()
        XCTAssertTrue(submit.isEnabled)
        submit.tap()
        // Answered: the task leaves 等我处理, and the badge goes.
        let waiting = app.descendants(matching: .any)["tasklist.waiting"]
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: waiting)
        wait(for: [gone], timeout: 30)
        XCTAssertFalse(app.descendants(matching: .any)["drawer.badge"].exists)
        // The newest task first; DSH may have retitled it, so it is found by its place.
        app.buttons.matching(identifier: "tasklist.row").firstMatch.tap()
        let answer = app.descendants(matching: .any)["question.answer"].firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(answer.label.contains("进展, 下周计划"), answer.label)
        expectDone(app, reply: "好的，周报写进展和下周计划。")
        saveShot("questions-multi-answered")
    }

    /// The drawer badge counts the question, and 所有任务 lists it under 等我处理 as its card.
    private func expectWaiting(_ app: XCUIApplication) {
        let badge = app.descendants(matching: .any)["drawer.badge"].firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 30), app.debugDescription)
        waitForValue(badge, in: ["1"], timeout: 10)
        openAllTasks(app)
        let waiting = app.staticTexts["tasklist.waiting"]
        XCTAssertTrue(waiting.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(waiting.label, "等我处理")
        XCTAssertEqual(app.staticTexts["tasklist.waiting.count"].label, "1")
        let card = app.descendants(matching: .any)["tasklist.question"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(card.staticTexts["question.text"].firstMatch.label, "周报里放哪些部分？")
        XCTAssertEqual(app.descendants(matching: .any)["question.card"].firstMatch.value as? String, "pending")
    }

    func testTapAnOptionAnswersAndTheTaskContinues() throws {
        try XCTSkipIf(env["DSHM_QUESTIONS_HOST"] == nil, "needs the real question host from scripts/demo/questions.sh")
        let app = XCUIApplication()
        app.launchArguments = ["-DSHMBridgePort", env["DSHM_BRIDGE_PORT"] ?? "47800",
                               "-DSHMPresetPrompt", "用本周的笔记写一份周报",
                               "-DSHMResetStore", "YES", "-DSHMResetPairing", "YES"]
        launchEnrolled(app)
        let send = app.buttons["composer.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 20))
        send.tap()

        let card = app.descendants(matching: .any)["question.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 60), app.debugDescription)
        XCTAssertEqual(card.value as? String, "pending")
        XCTAssertEqual(app.staticTexts["question.text"].firstMatch.label, "桌面上有两个周报模板，用哪个？")
        let options = app.buttons.matching(identifier: "question.option")
        XCTAssertEqual(options.count, 2)
        XCTAssertEqual(options.element(boundBy: 0).label, "公司模板.pptx")
        XCTAssertEqual(options.element(boundBy: 1).label, "简洁版.pptx")
        // The task waits: nothing answers by itself.
        let status = app.descendants(matching: .any)["task.status"]
        XCTAssertNotEqual(status.value as? String, "completed")
        saveShot("questions-pending")

        options.element(boundBy: 1).tap()
        waitForValue(card, in: ["answered"], timeout: 20)
        let answer = app.descendants(matching: .any)["question.answer"].firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        XCTAssertTrue(answer.label.contains("简洁版.pptx"), answer.label)
        XCTAssertFalse(app.buttons["question.option"].exists, "the chips give way to the answer")

        waitForValue(status, in: ["completed"], timeout: 60)
        let transcript = app.descendants(matching: .any)["transcript.structured"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        XCTAssertTrue((transcript.value as? String ?? "").contains("好的，用简洁版.pptx 写周报。"), transcript.debugDescription)
        saveShot("questions-answered")
    }
}
