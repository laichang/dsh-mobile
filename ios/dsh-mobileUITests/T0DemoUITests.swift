import XCTest

/// T0 demo in the Simulator, driven by accessibility identifiers (ARCHITECTURE D16).
/// - `testDemoWithFakeBridge` needs nothing else running.
/// - `testDemoAgainstRealDSH` needs `node scripts/dsh-up.mjs` (real DSH + bridge on 47801) and
///   runs only with TEST_RUNNER_DSHM_REAL_DSH=1; scripts/demo/t0.sh sets that up.
/// Set TEST_RUNNER_DSHM_SHOT_DIR to save a screenshot of the finished screen there.
@MainActor
final class T0DemoUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private var env: [String: String] { ProcessInfo.processInfo.environment }

    /// Types the prompt, taps send, waits for the task to finish; returns the transcript.
    private func runDemo(_ app: XCUIApplication, prompt: String, timeout: TimeInterval) -> String {
        let field = app.textFields["composer.prompt"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(prompt)
        let send = app.buttons["composer.send"]
        XCTAssertTrue(send.isEnabled)
        send.tap()

        let status = app.descendants(matching: .any)["task.status"]
        let transcript = app.descendants(matching: .any)["transcript.text"]

        // Streaming: some text shows while the task is still running.
        let streamed = expectation(for: NSPredicate(format: "value != ''"), evaluatedWith: transcript)
        wait(for: [streamed], timeout: timeout)

        let done = expectation(for: NSPredicate(format: "value == 'completed' OR value == 'failed'"), evaluatedWith: status)
        wait(for: [done], timeout: timeout)
        XCTAssertEqual(status.value as? String, "completed", "status label: \(status.label)")
        return transcript.value as? String ?? ""
    }

    private func saveShot(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = env["DSHM_SHOT_DIR"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    func testDemoWithFakeBridge() {
        let app = XCUIApplication()
        app.launchArguments = ["-DSHMFakeBridge", "YES"]
        app.launch()
        let text = runDemo(app, prompt: "Introduce yourself in one sentence.", timeout: 15)
        XCTAssertEqual(text, "Hello from FakeBridge. No DSH was involved.")
        saveShot("t0-fakebridge-done")
    }

    func testPresetPromptLaunchArgument() {
        let app = XCUIApplication()
        app.launchArguments = ["-DSHMFakeBridge", "YES", "-DSHMPresetPrompt", "Preset from a launch argument"]
        app.launch()
        let field = app.textFields["composer.prompt"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, "Preset from a launch argument")
        XCTAssertTrue(app.buttons["composer.send"].isEnabled)
    }

    func testPairDeepLinkOpensPairingStub() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-DSHMFakeBridge", "YES"]
        app.launch()
        XCTAssertTrue(app.textFields["composer.prompt"].waitForExistence(timeout: 10))
        app.open(try XCTUnwrap(URL(string: "dshm://pair?host=127.0.0.1&port=47801&secret=t0-stub")))
        // iOS asks "Open in dsh-mobile?" before handing a custom-scheme URL to the app.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let open = springboard.buttons.matching(NSPredicate(format: "label IN {'Open', '打开'}")).firstMatch
        if open.waitForExistence(timeout: 3) { open.tap() }
        // Re-resolve the app after the URL hand-off; the original handle can keep a stale tree.
        let reopened = XCUIApplication(bundleIdentifier: "chang.dsh-mobile")
        let stub = reopened.descendants(matching: .any)["pairing.stub"]
        XCTAssertTrue(stub.waitForExistence(timeout: 10), reopened.debugDescription)
        XCTAssertTrue(reopened.staticTexts["secret, t0-stub"].exists, reopened.debugDescription)
        saveShot("t0-pair-deeplink-stub")
        reopened.buttons["pairing.close"].tap()
        XCTAssertTrue(reopened.textFields["composer.prompt"].waitForExistence(timeout: 5))
    }

    func testDemoAgainstRealDSH() throws {
        try XCTSkipUnless(env["DSHM_REAL_DSH"] == "1", "needs scripts/dsh-up.mjs; run scripts/demo/t0.sh")
        let app = XCUIApplication()
        app.launchArguments = ["-DSHMBridgePort", env["DSHM_BRIDGE_PORT"] ?? "47801"]
        app.launch()
        let text = runDemo(app, prompt: "用一句话介绍你自己。", timeout: 120)
        // The local acceptance host uses DSH's mock LLM (scripts/dsh-up.mjs MOCK_TEXT).
        XCTAssertTrue(text.contains("streamed through the dsh-mobile bridge"), text)
        saveShot("t0-real-dsh-done")
    }
}
