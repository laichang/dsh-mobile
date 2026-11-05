import XCTest

@MainActor
final class S8RichDetailUITests: XCTestCase {
    private let translation = "Translate this sentence: Bonjour."
    private let coding = "Show the patch and the test output"

    private func launch(prompt: String? = nil) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-DSHMBridgePort", env["DSHM_BRIDGE_PORT"] ?? "47814", "-DSHMResetPairing", "YES"]
        if let prompt {
            app.launchArguments += ["-DSHMResetStore", "YES", "-DSHMPresetPrompt", prompt]
        }
        app.launch()
        return app
    }

    func testTranslationCompletesInline() throws {
        try XCTSkipUnless(env["DSHM_S8_REPLY"] == "translation", "run scripts/demo/s8.sh")
        let app = launch(prompt: translation)
        app.buttons["composer.send"].tap()
        // T1 (D51): the first message turns the new session into the session page, with the reply.
        let status = app.descendants(matching: .any)["task.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5), app.debugDescription)
        waitForValue(status, in: ["completed"], timeout: 12)
        XCTAssertTrue((app.descendants(matching: .any)["transcript.text"].value as? String ?? "").contains("Hello."))
        // The short answer shows inline in its row in 所有任务 (the 280-character rule).
        openAllTasks(app)
        let row = app.buttons.matching(identifier: "tasklist.row").matching(NSPredicate(format: "label CONTAINS 'Hello.'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(row.value as? String, "completed")
        XCTAssertTrue(row.isHittable)
        saveShot("s8-inline-answer")
    }

    func testCodingReplyStreamsFences() throws {
        try XCTSkipUnless(env["DSHM_S8_REPLY"] == "coding", "run scripts/demo/s8.sh")
        let app = launch(prompt: coding)
        app.buttons["composer.send"].tap()
        let transcript = app.descendants(matching: .any)["transcript.text"]
        let diff = app.descendants(matching: .any)["transcript.fence.diff"]
        XCTAssertTrue(diff.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(app.descendants(matching: .any)["task.status"].value as? String, "running")
        XCTAssertFalse((transcript.value as? String ?? "").contains("1 test passed"))
        waitForValue(app.descendants(matching: .any)["task.status"], in: ["completed"], timeout: 20)
        XCTAssertTrue(app.descendants(matching: .any)["transcript.fence.console"].exists)
        XCTAssertTrue(app.staticTexts["+return 1"].exists)
        XCTAssertTrue(app.staticTexts["$ swift test\n1 test passed"].exists)
        saveShot("s8-rich-detail")
    }

    func testCachedRichDetailAfterRelaunch() throws {
        try XCTSkipUnless(env["DSHM_S8_REPLY"] == "offline", "run scripts/demo/s8.sh")
        let app = launch()
        openDrawer(app)
        waitForValue(app.descendants(matching: .any)["host.status"], in: ["offline"], timeout: 20)
        app.buttons["drawer.allTasks"].tap()
        let row = app.buttons.matching(identifier: "tasklist.row").matching(NSPredicate(format: "label CONTAINS %@", coding)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["transcript.fence.diff"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["transcript.fence.console"].exists)
        XCTAssertTrue(app.staticTexts["+return 1"].exists)
        XCTAssertEqual(app.descendants(matching: .any)["task.status"].value as? String, "completed")
    }
}
