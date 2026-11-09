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
        XCTAssertTrue(app.textFields["composer.prompt"].waitForExistence(timeout: 30), app.debugDescription)
        send(app, prompt)
        let status = any(app, "task.status").firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 60), app.debugDescription)
        waitForValue(status, in: ["running"], timeout: 60)
        return status
    }

    /// Types `text` in the session composer and sends it.
    private func reply(_ app: XCUIApplication, _ text: String) {
        send(app, text, field: "session.followUp", send: "session.send")
        dismissKeyboardTip(app)
    }

    /// A fresh Simulator shows a one-time keyboard tip ("Speed up your typing…") over the page.
    private func dismissKeyboardTip(_ app: XCUIApplication) {
        let tip = app.buttons["Continue"]
        if tip.exists { tip.tap() }
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        dismissKeyboardTip(app)
        saveShot(name)
    }

    private func waitForCount(_ query: XCUIElementQuery, _ count: Int, timeout: TimeInterval, in app: XCUIApplication) {
        let predicate = NSPredicate(format: "count == \(count)")
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: query)], timeout: timeout)
        XCTAssertEqual(query.count, count, app.debugDescription)
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
        waitForCount(queued, 1, timeout: 15, in: app)
        XCTAssertEqual(queued.element(boundBy: 0).label, later)
        XCTAssertEqual(queued.element(boundBy: 0).value as? String, "queued")
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "the stop key stays")
        reply(app, now)
        waitForCount(queued, 2, timeout: 15, in: app)
        XCTAssertEqual(queued.element(boundBy: 1).label, now)
        XCTAssertEqual(status.value as? String, "running")
        shot(app, "followup-queued")

        // 2. 立即发送 on the second: the agent takes it at its next step, in this turn.
        app.buttons.matching(identifier: "followup.sendNow").element(boundBy: 1).tap()
        let bubbles = any(app, "session.message.user")
        waitForCount(bubbles, 2, timeout: 60, in: app)
        XCTAssertEqual(bubbles.element(boundBy: 0).label, prompt)
        XCTAssertEqual(bubbles.element(boundBy: 1).label, now)
        XCTAssertEqual(queued.count, 1, "the first one still waits for the next turn")
        XCTAssertEqual(queued.element(boundBy: 0).label, later)
        XCTAssertEqual(status.value as? String, "running")
        XCTAssertTrue(stop.exists, "the stop key stays")
        shot(app, "followup-steered")

        // 3. The queued one runs after the turn, as the next turn.
        waitForCount(bubbles, 3, timeout: 90, in: app)
        XCTAssertEqual(bubbles.element(boundBy: 2).label, later)
        waitForCount(queued, 0, timeout: 10, in: app)
        waitForValue(status, in: ["completed", "failed"], timeout: 120)
        XCTAssertEqual(status.value as? String, "completed", status.label)
        let transcript = any(app, "transcript.structured").firstMatch
        let text = transcript.value as? String ?? ""
        XCTAssertEqual(text.components(separatedBy: "streamed through the dsh-mobile bridge").count - 1, 3, text)
        shot(app, "followup-queue-done")

        // The host checks the DSH session; it reads the messages from here, in the order sent.
        try "\(prompt)\n\(later)\n\(now)".write(to: try signals().appendingPathComponent("messages-queue"), atomically: true, encoding: .utf8)
    }

    /// The reported bug: 立即发送 while the agent is in a long step (a tool call that waits). The
    /// message must leave the queue and show in the transcript, and must not float after the turn.
    /// Needs scripts/demo/steer-host.mjs (`scripts/demo/followup.sh --steer`).
    func testSendNowDuringALongStepAgainstRealDSH() throws {
        let app = try launch()
        let tag = UUID().uuidString.prefix(6)
        let prompt = "Summarize every file. #\(tag)"
        let stopNow = "不用了 #\(tag)"
        let status = start(app, prompt: prompt)
        reply(app, stopNow)
        let queued = any(app, "followup.queued")
        waitForCount(queued, 1, timeout: 15, in: app)
        app.buttons.matching(identifier: "followup.sendNow").element(boundBy: 0).tap()

        // D143: at once (the tool step runs 30 s more), the message is a bubble in the transcript,
        // marked until DSH gives it to the agent; nothing floats above the field.
        let bubbles = any(app, "session.message.user")
        waitForCount(bubbles, 2, timeout: 10, in: app)
        XCTAssertEqual(bubbles.element(boundBy: 1).label, stopNow)
        XCTAssertEqual(bubbles.element(boundBy: 1).value as? String, "steering")
        waitForCount(queued, 0, timeout: 5, in: app)
        XCTAssertTrue(any(app, "session.message.user.pending").firstMatch.exists, app.debugDescription)
        XCTAssertEqual(status.value as? String, "running")
        shot(app, "steer-sent-now")

        // The step ends, DSH gives it to the agent: the mark goes, the bubble stays where it was.
        let pending = any(app, "session.message.user.pending").firstMatch
        XCTAssertTrue(pending.waitForNonExistence(timeout: 90), "taken when the step ends")
        XCTAssertEqual(bubbles.count, 2)
        XCTAssertEqual(bubbles.element(boundBy: 1).label, stopNow)
        waitForValue(status, in: ["completed", "failed"], timeout: 120)
        XCTAssertEqual(status.value as? String, "completed", status.label)
        XCTAssertEqual(queued.count, 0, "nothing floats above the field after the turn")
        shot(app, "steer-taken")
        try "\(prompt)\n\(stopNow)".write(to: try signals().appendingPathComponent("steer-done"), atomically: true, encoding: .utf8)
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
        shot(app, "followup-interrupted")

        // 2. A new message continues the same session: it runs again, and the card goes.
        reply(app, goOn)
        waitForValue(status, in: ["running"], timeout: 30)
        XCTAssertTrue(card.waitForNonExistence(timeout: 15), "the stopped card goes")
        let bubbles = any(app, "session.message.user")
        waitForCount(bubbles, 2, timeout: 30, in: app)
        XCTAssertEqual(bubbles.element(boundBy: 0).label, prompt)
        XCTAssertEqual(bubbles.element(boundBy: 1).label, goOn)
        waitForValue(status, in: ["completed", "failed"], timeout: 120)
        XCTAssertEqual(status.value as? String, "completed", status.label)
        XCTAssertFalse(any(app, "outcome.card").firstMatch.exists, "no stopped card after it completed")
        let bar = any(app, "milestone.card").firstMatch
        if bar.exists { XCTAssertFalse(bar.label.contains("Interrupted") || bar.label.contains("已中断"), bar.label) }
        shot(app, "followup-continued")

        try "\(prompt)\n\(goOn)".write(to: try signals().appendingPathComponent("messages-interrupt"), atomically: true, encoding: .utf8)
    }
}
