import XCTest

/// Screen P1 against real DSH with the mock model (scripts/demo/questions.sh): the agent asks
/// which of two templates to use; the card shows the question and its options; one tap answers;
/// the task continues with that answer.
@MainActor
final class AgentQuestionUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testTapAnOptionAnswersAndTheTaskContinues() throws {
        try XCTSkipIf(env["DSHM_QUESTIONS_HOST"] == nil, "needs the real question host from scripts/demo/questions.sh")
        let app = XCUIApplication()
        app.launchArguments = ["-DSHMBridgePort", env["DSHM_BRIDGE_PORT"] ?? "47800",
                               "-DSHMPresetPrompt", "用本周的笔记写一份周报",
                               "-DSHMResetStore", "YES", "-DSHMResetPairing", "YES"]
        app.launch()
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
