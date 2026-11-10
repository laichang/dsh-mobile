import XCTest

@MainActor
final class RichDetailUITests: XCTestCase {
    private let translation = "Translate this sentence: Bonjour."
    private let coding = "Show the patch and the test output"

    /// The offline launch's composer text: it only shows that the app has its launch arguments.
    private let offlineMarker = "rich-detail offline relaunch"

    private func launch(prompt: String? = nil) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-DSHMBridgePort", env["DSHM_BRIDGE_PORT"] ?? "47811", "-DSHMResetPairing", "YES",
                               "-DSHMPresetPrompt", prompt ?? offlineMarker]
        if prompt != nil { app.launchArguments += ["-DSHMResetStore", "YES"] }
        app.launch()
        // #22: each part of scripts/demo/rich-detail.sh is its own xcodebuild run, which installs
        // the app again. A Live Activity of the part before can make liveactivitiesd open the app
        // in the background just then, and XCTest's launch takes that process, which has none of
        // these arguments (port 47801, no prompt). Seen in the simulator log, 2026-11-09. The
        // preset prompt shows which process it got: if not this one, launch it again.
        if !hasPresetPrompt(app, prompt ?? offlineMarker) {
            print("rich-detail: the app came up without its launch arguments; launching it again")
            app.terminate()
            app.launch()
        }
        XCTAssertTrue(hasPresetPrompt(app, prompt ?? offlineMarker), app.debugDescription)
        return app
    }

    private func hasPresetPrompt(_ app: XCUIApplication, _ text: String) -> Bool {
        let field = app.textFields["composer.prompt"]
        return field.waitForExistence(timeout: 10) && field.value as? String == text
    }

    func testTranslationCompletesInline() throws {
        try XCTSkipUnless(env["DSHM_RICH_REPLY"] == "translation", "run scripts/demo/rich-detail.sh")
        let app = launch(prompt: translation)
        app.buttons["composer.send"].tap()
        // The first message turns the new session into the session page, with the reply.
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
        saveShot("rich-detail-inline-answer")
    }

    func testCodingReplyStreamsFences() throws {
        try XCTSkipUnless(env["DSHM_RICH_REPLY"] == "coding", "run scripts/demo/rich-detail.sh")
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
        saveShot("rich-detail-rich-detail")
    }

    func testCachedRichDetailAfterRelaunch() throws {
        try XCTSkipUnless(env["DSHM_RICH_REPLY"] == "offline", "run scripts/demo/rich-detail.sh")
        let app = launch()
        openDrawer(app)
        waitForValue(app.descendants(matching: .any)["host.status"], in: ["offline"], timeout: 20)
        app.buttons["drawer.allTasks"].tap()
        // #22: the row shows the task's title, not its prompt: DSH's session title once it
        // has one, which DSH's mock model makes from the reply ("## Patch"), else the prompt. Both
        // have "patch"; the other tasks of the demo's DSH home do not. A coding task of an earlier
        // run has the same reply, so any match will do.
        let row = app.buttons.matching(identifier: "tasklist.row").matching(NSPredicate(format: "label CONTAINS[c] 'patch'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["transcript.fence.diff"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["transcript.fence.console"].exists)
        XCTAssertTrue(app.staticTexts["+return 1"].exists)
        XCTAssertEqual(app.descendants(matching: .any)["task.status"].value as? String, "completed")
    }
}
