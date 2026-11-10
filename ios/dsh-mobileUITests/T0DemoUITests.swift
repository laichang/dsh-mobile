import XCTest

/// Round-trip demo in the Simulator, driven by accessibility identifiers.
/// - `testDemoWithFakeBridge` needs nothing else running.
/// - `testDemoAgainstRealDSH` needs `node scripts/dsh-up.mjs` (real DSH + bridge on 47801) and
///   runs only with TEST_RUNNER_DSHM_REAL_DSH=1; scripts/demo/t0.sh sets that up.
/// Set TEST_RUNNER_DSHM_SHOT_DIR to save a screenshot of the finished screen there.
/// Every launch passes `-DSHMResetPairing YES`, so a pairing left by the pairing tests doesn't move
/// these onto Noise: this is the Debug plaintext loopback path. Helpers: UITestSupport.swift.
@MainActor
final class T0DemoUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testDemoWithFakeBridge() {
        let app = XCUIApplication()
        app.launchArguments = ["-DSHMFakeBridge", "YES", "-DSHMResetPairing", "YES"]
        app.launch()
        let text = runDemo(app, prompt: "Introduce yourself in one sentence.", timeout: 15)
        XCTAssertEqual(text, "Hello from FakeBridge. No DSH was involved.")
        saveShot("t0-fakebridge-done")
    }

    func testPresetPromptLaunchArgument() {
        let app = XCUIApplication()
        app.launchArguments = ["-DSHMFakeBridge", "YES", "-DSHMResetPairing", "YES", "-DSHMPresetPrompt", "Preset from a launch argument"]
        app.launch()
        let field = app.textFields["composer.prompt"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, "Preset from a launch argument")
        XCTAssertTrue(app.buttons["composer.send"].isEnabled)
    }

    /// `dshm://pair?…` opens the real pairing screen. The old stub link
    /// carries no offer, so the screen says it can't use it, and Close returns to the composer.
    func testPairDeepLinkOpensPairingStub() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-DSHMFakeBridge", "YES", "-DSHMResetPairing", "YES"]
        app.launch()
        XCTAssertTrue(app.textFields["composer.prompt"].waitForExistence(timeout: 10))
        let reopened = openDeepLink(try XCTUnwrap(URL(string: "dshm://pair?host=127.0.0.1&port=47801&secret=t0-stub")))
        let status = reopened.descendants(matching: .any)["pairing.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10), reopened.debugDescription)
        XCTAssertEqual(status.value as? String, "invalid")
        XCTAssertTrue(reopened.descendants(matching: .any)["pairing.view"].exists)
        saveShot("t0-pair-deeplink-stub")
        reopened.buttons["pairing.close"].tap()
        XCTAssertTrue(reopened.textFields["composer.prompt"].waitForExistence(timeout: 5))
    }

    func testDemoAgainstRealDSH() throws {
        try XCTSkipUnless(env["DSHM_REAL_DSH"] == "1", "needs scripts/dsh-up.mjs; run scripts/demo/t0.sh")
        let app = XCUIApplication()
        app.launchArguments = ["-DSHMBridgePort", env["DSHM_BRIDGE_PORT"] ?? "47801", "-DSHMResetPairing", "YES"]
        app.launch()
        // A unique prompt per run: real DSH keeps every earlier run, and the list shows only the rows
        // on screen, so a repeated prompt never adds a row that the wait can see.
        let text = runDemo(app, prompt: "用一句话介绍你自己。#\(UUID().uuidString.prefix(6))", timeout: 120)
        // The local acceptance host uses DSH's mock LLM (scripts/dsh-up.mjs MOCK_TEXT).
        XCTAssertTrue(text.contains("streamed through the dsh-mobile bridge"), text)
        saveShot("t0-real-dsh-done")
    }
}
