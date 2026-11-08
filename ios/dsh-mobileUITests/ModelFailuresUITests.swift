import XCTest

/// Model failures (ARCHITECTURE D104, D110, screens X1 and X4), against real DSH whose DeepSeek
/// provider has no balance. Needs scripts/demo/model-failures-host.mjs (DSH Web + the bridge + a
/// fake DeepSeek); scripts/demo/model-failures.sh runs it. The host tops the account up when this
/// test says the failure is on screen, and checks DSH's session afterwards.
@MainActor
final class ModelFailuresUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: id)
    }

    func testNoBalanceFailsInRedThenANewMessageContinuesAgainstRealDSH() throws {
        let signals = URL(fileURLWithPath: try XCTUnwrap(env["DSHM_FAILURE_SIGNALS"], "run scripts/demo/model-failures.sh"))
        let port = try String(contentsOf: signals.appendingPathComponent("bridge-port"), encoding: .utf8)
        let app = XCUIApplication()
        app.launchArguments = ["-DSHMBridgePort", port, "-DSHMResetStore", "YES", "-DSHMResetPairing", "YES"]
        app.launch()

        // 1. A task on a provider with no balance.
        let tag = UUID().uuidString.prefix(6)
        let prompt = "Compress yesterday's footage. #\(tag)"
        let field = app.textFields["composer.prompt"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), app.debugDescription)
        field.tap()
        field.typeText(prompt)
        app.buttons["composer.send"].tap()

        // 2. It fails at once (DSH does not retry QUOTA), with the red X1 card and the reason.
        let status = any(app, "task.status").firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 60), app.debugDescription)
        waitForValue(status, in: ["failed", "completed"], timeout: 60)
        XCTAssertEqual(status.value as? String, "failed", status.label)
        let card = any(app, "outcome.card").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(card.value as? String, "failed")
        // The app's own words for QUOTA (D104), not the provider's English text; the class beside it.
        let error = any(app, "outcome.error").firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(["当前请求的额度已用尽", "Request quota exhausted"].contains(error.label), error.label)
        XCTAssertEqual(any(app, "outcome.code").firstMatch.label, "QUOTA")
        XCTAssertFalse(status.label.contains("Insufficient Balance"), status.label)
        XCTAssertTrue(any(app, "outcome.continue").firstMatch.exists, "the card says a message continues it")
        XCTAssertTrue(any(app, "outcome.retry").firstMatch.exists)
        saveShot("model-failure-red")

        // 3. The user tops up (the host heals the provider), then sends a new message in the same session.
        try "1".write(to: signals.appendingPathComponent("failed"), atomically: true, encoding: .utf8)
        let toppedUp = signals.appendingPathComponent("topped-up")
        let deadline = Date().addingTimeInterval(60)
        while !FileManager.default.fileExists(atPath: toppedUp.path) && Date() < deadline { usleep(100_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: toppedUp.path), "the host did not top up")
        let reply = app.textFields["session.followUp"]
        XCTAssertTrue(reply.waitForExistence(timeout: 10), app.debugDescription)
        reply.tap()
        let followUp = "I topped up. Please go on. #\(tag)"
        reply.typeText(followUp)
        let send = app.buttons["session.send"]
        XCTAssertTrue(send.isEnabled)
        send.tap()

        // 4. The same task runs again and completes; the failure card gives way to the done footer.
        let bubbles = any(app, "session.message.user")
        wait(for: [expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: bubbles)], timeout: 30)
        XCTAssertEqual(bubbles.element(boundBy: 0).label, prompt)
        XCTAssertEqual(bubbles.element(boundBy: 1).label, followUp)
        waitForValue(status, in: ["completed"], timeout: 90)
        let transcript = any(app, "transcript.structured").firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 15), app.debugDescription)
        let text = transcript.value as? String ?? ""
        XCTAssertTrue(text.contains("Topped up: the model answered again in the same session."), text)
        XCTAssertTrue(any(app, "outcome.footer").firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(any(app, "outcome.card").firstMatch.exists)
        saveShot("model-failure-continued")

        // 5. The host checks the DSH session; it reads the two messages from here.
        try "\(prompt)\n\(followUp)".write(to: signals.appendingPathComponent("messages"), atomically: true, encoding: .utf8)
    }
}
