import XCTest

/// Follow-ups while a task runs, and after a stop (ARCHITECTURE D18, D101, screen 04, X1), against
/// real DSH with its mock LLM. Needs scripts/demo/followup-host.mjs in its running mode (DSH Web +
/// the bridge, a slow mock reply); `scripts/demo/followup.sh --running` runs it. The host checks
/// afterwards that DSH has the messages in one session each, in the order the agent took them.
@MainActor
final class FollowUpQueueUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: id)
    }

    private func signals() throws -> URL {
        URL(fileURLWithPath: try XCTUnwrap(env["DSHM_FOLLOWUP_SIGNALS"], "run scripts/demo/followup.sh --running"))
    }

    private func launch() throws -> XCUIApplication {
        let port = try String(contentsOf: try signals().appendingPathComponent("bridge-port"), encoding: .utf8)
        let app = XCUIApplication()
        app.launchArguments = ["-DSHMBridgePort", port, "-DSHMResetStore", "YES", "-DSHMResetPairing", "YES"]
        app.launch()
        return app
    }

    /// Sends the first message from the new session and waits until its task runs.
    private func start(_ app: XCUIApplication, prompt: String) -> XCUIElement {
        let field = app.textFields["composer.prompt"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), app.debugDescription)
        field.tap()
        field.typeText(prompt)
        app.buttons["composer.send"].tap()
        let status = any(app, "task.status").firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 60), app.debugDescription)
        waitForValue(status, in: ["running"], timeout: 60)
        return status
    }

    /// Types `text` in the session composer and sends it.
    private func reply(_ app: XCUIApplication, _ text: String) {
        let field = app.textFields["session.followUp"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), app.debugDescription)
        field.tap()
        field.typeText(text)
        let send = app.buttons["session.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5) && send.isEnabled, app.debugDescription)
        send.tap()
    }

    private func waitForCount(_ query: XCUIElementQuery, _ count: Int, timeout: TimeInterval) {
        wait(for: [expectation(for: NSPredicate(format: "count == \(count)"), evaluatedWith: query)], timeout: timeout)
    }

    func testFollowUpsWhileATaskRunsAgainstRealDSH() throws {
        let app = try launch()
        let tag = UUID().uuidString.prefix(6)
        let prompt = "Count to three. #\(tag)"
        let later = "Then say goodbye. #\(tag)"
        let now = "Use Chinese, please. #\(tag)"
        let status = start(app, prompt: prompt)
        let stop = app.buttons["task.interrupt"]
        XCTAssertTrue(stop.waitForExistence(timeout: 15), "the stop key while the field is empty")

        // 1. A follow-up while it runs waits above the composer, and the stop key comes back.
        reply(app, later)
        let queued = any(app, "followup.queued")
        waitForCount(queued, 1, timeout: 15)
        XCTAssertEqual(queued.element(boundBy: 0).label, later)
        XCTAssertEqual(queued.element(boundBy: 0).value as? String, "queued")
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "the stop key stays")
        reply(app, now)
        waitForCount(queued, 2, timeout: 15)
        XCTAssertEqual(queued.element(boundBy: 1).label, now)
        XCTAssertEqual(status.value as? String, "running")
        saveShot("followup-queued")

        // 2. 立即发送 on the second: the agent takes it at its next step, in this turn.
        app.buttons.matching(identifier: "followup.sendNow").element(boundBy: 1).tap()
        let bubbles = any(app, "session.message.user")
        waitForCount(bubbles, 2, timeout: 60)
        XCTAssertEqual(bubbles.element(boundBy: 0).label, prompt)
        XCTAssertEqual(bubbles.element(boundBy: 1).label, now)
        XCTAssertEqual(queued.count, 1, "the first one still waits for the next turn")
        XCTAssertEqual(queued.element(boundBy: 0).label, later)
        XCTAssertEqual(status.value as? String, "running")
        XCTAssertTrue(stop.exists, "the stop key stays")
        saveShot("followup-steered")

        // 3. The queued one runs after the turn, as the next turn.
        waitForCount(bubbles, 3, timeout: 90)
        XCTAssertEqual(bubbles.element(boundBy: 2).label, later)
        waitForCount(queued, 0, timeout: 10)
        waitForValue(status, in: ["completed", "failed"], timeout: 120)
        XCTAssertEqual(status.value as? String, "completed", status.label)
        let transcript = any(app, "transcript.structured").firstMatch
        let text = transcript.value as? String ?? ""
        XCTAssertEqual(text.components(separatedBy: "streamed through the dsh-mobile bridge").count - 1, 3, text)
        saveShot("followup-queue-done")

        // The host checks the DSH session; it reads the messages from here, in the order sent.
        try "\(prompt)\n\(later)\n\(now)".write(to: try signals().appendingPathComponent("messages-queue"), atomically: true, encoding: .utf8)
    }

    func testContinueAfterAnInterruptAgainstRealDSH() throws {
        let app = try launch()
        let tag = UUID().uuidString.prefix(6)
        let prompt = "Write a long story. #\(tag)"
        let goOn = "Go on, but keep it short. #\(tag)"
        let status = start(app, prompt: prompt)

        // 1. Stop the task: the page shows the stopped card, and the field takes a new message.
        let stop = app.buttons["task.interrupt"]
        XCTAssertTrue(stop.waitForExistence(timeout: 15), app.debugDescription)
        stop.tap()
        waitForValue(status, in: ["interrupted"], timeout: 30)
        let card = any(app, "outcome.card").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), app.debugDescription)
        saveShot("followup-interrupted")

        // 2. A new message continues the same session: it runs again, and the card goes.
        reply(app, goOn)
        waitForValue(status, in: ["running"], timeout: 30)
        XCTAssertTrue(card.waitForNonExistence(timeout: 15), "the stopped card goes")
        let bubbles = any(app, "session.message.user")
        waitForCount(bubbles, 2, timeout: 30)
        XCTAssertEqual(bubbles.element(boundBy: 0).label, prompt)
        XCTAssertEqual(bubbles.element(boundBy: 1).label, goOn)
        waitForValue(status, in: ["completed", "failed"], timeout: 120)
        XCTAssertEqual(status.value as? String, "completed", status.label)
        XCTAssertFalse(any(app, "outcome.card").firstMatch.exists, "no stopped card after it completed")
        saveShot("followup-continued")

        try "\(prompt)\n\(goOn)".write(to: try signals().appendingPathComponent("messages-interrupt"), atomically: true, encoding: .utf8)
    }
}
