import XCTest

/// A follow-up in a finished session (ARCHITECTURE D89, screen 04), against real DSH with its
/// mock LLM. Needs scripts/demo/followup-host.mjs (DSH Web + the bridge); scripts/demo/followup.sh
/// runs it. The host checks afterwards that DSH has both messages in one session.
@MainActor
final class FollowUpUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: id)
    }

    func testFollowUpInAFinishedSessionAgainstRealDSH() throws {
        let signals = URL(fileURLWithPath: try XCTUnwrap(env["DSHM_FOLLOWUP_SIGNALS"], "run scripts/demo/followup.sh"))
        let port = try String(contentsOf: signals.appendingPathComponent("bridge-port"), encoding: .utf8)
        let app = XCUIApplication()
        app.launchArguments = ["-DSHMBridgePort", port, "-DSHMResetStore", "YES", "-DSHMResetPairing", "YES"]
        app.launch()

        // 1. The first message, to the end of its turn.
        let tag = UUID().uuidString.prefix(6)
        let prompt = "Say hello. #\(tag)"
        let first = runDemo(app, prompt: prompt, timeout: 120)
        XCTAssertTrue(first.contains("streamed through the dsh-mobile bridge"), first)

        // 2. The finished page takes a follow-up.
        let field = app.textFields["session.followUp"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), app.debugDescription)
        let send = app.buttons["session.send"]
        XCTAssertFalse(send.isEnabled, "nothing to send yet")
        let followUp = "And once more, please. #\(tag)"
        type(followUp, into: field)
        XCTAssertTrue(waitUntil(send, "isEnabled == true", timeout: 15))
        saveShot("followup-typed")
        send.tap()

        // 3. The task runs again on the same page, and the reply streams under the first answer.
        let status = any(app, "task.status").firstMatch
        waitForValue(status, in: ["running"], timeout: 30)
        let bubbles = any(app, "session.message.user")
        let both = expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: bubbles)
        wait(for: [both], timeout: 30)
        XCTAssertEqual(bubbles.element(boundBy: 0).label, prompt)
        XCTAssertEqual(bubbles.element(boundBy: 1).label, followUp)
        let transcript = any(app, "transcript.structured").firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 30), app.debugDescription)
        saveShot("followup-streaming")
        waitForValue(status, in: ["completed", "failed"], timeout: 120)
        XCTAssertEqual(status.value as? String, "completed", status.label)

        // Two answers, the follow-up between them.
        let mock = "streamed through the dsh-mobile bridge"
        let text = transcript.value as? String ?? ""
        XCTAssertEqual(text.components(separatedBy: mock).count - 1, 2, text)
        XCTAssertLessThan(bubbles.element(boundBy: 1).frame.minY, transcript.frame.maxY)
        XCTAssertGreaterThan(bubbles.element(boundBy: 1).frame.minY, bubbles.element(boundBy: 0).frame.maxY)
        XCTAssertTrue(app.textFields["session.followUp"].waitForExistence(timeout: 10), "it takes another one")
        saveShot("followup-done")

        // 4. The host checks the DSH session; it reads the two messages from here.
        try "\(prompt)\n\(followUp)".write(to: signals.appendingPathComponent("messages"), atomically: true, encoding: .utf8)
    }
}
