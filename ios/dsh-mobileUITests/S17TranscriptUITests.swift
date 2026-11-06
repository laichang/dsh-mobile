import XCTest

/// S17 · the structured transcript (PLAN.md §5 S17, screen 04), against the in-process FakeBridge's
/// transcript task (`-DSHMFakeScenario transcript`): thinking for 8 s, then Read, Edit (+12 −3) and
/// Bash rows among the reply. `transcript-v0` sends the same blocks from a host without
/// `transcript.v1`. scripts/demo/s17.sh runs these; set TEST_RUNNER_DSHM_SHOT_DIR to save the
/// screenshots there. Helpers: UITestSupport.swift.
@MainActor
final class S17TranscriptUITests: XCTestCase {
    static let prompt = "Fix the failing resume test"
    /// The last words of `FakeTranscript.script().reply`.
    static let replyEnd = "The tests pass now."

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-DSHMResetPairing", "YES",
                               "-DSHMResetStore", "YES", "-DSHMFakeBridge", "YES", "-DSHMFakeScenario", scenario]
        app.launch()
        return app
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    private func send(_ app: XCUIApplication) {
        let field = app.textFields["composer.prompt"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
        field.tap()
        field.typeText(Self.prompt)
        app.buttons["composer.send"].tap()
    }

    private func waitFor(_ format: String, _ args: [Any], on element: XCUIElement, timeout: TimeInterval = 20) {
        let predicate = NSPredicate(format: format, argumentArray: args)
        wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout)
    }

    /// Tool rows show the verb, the target and the lines added and removed; a tap opens a sheet.
    func testToolRowsShowVerbTargetAndLinesAndOpenASheet() {
        let app = launch("transcript")
        send(app)
        let structured = any(app, "transcript.structured")
        XCTAssertTrue(structured.waitForExistence(timeout: 15), app.debugDescription)
        waitFor("value CONTAINS %@", [Self.replyEnd], on: structured)

        // "已思考 8 秒 ›" in English: one row, done.
        let thinking = app.buttons["transcript.thinking"]
        XCTAssertTrue(thinking.waitForExistence(timeout: 5), app.debugDescription)
        waitFor("label == %@ AND value == 'done'", ["Thought for 8 s"], on: thinking)

        // verb · target · +/−, each row done.
        let tools = app.buttons.matching(identifier: "transcript.tool")
        let read = tools.matching(NSPredicate(format: "label == 'Read TaskListStore.swift'")).firstMatch
        let edit = tools.matching(NSPredicate(format: "label == 'Edit TaskListStore.swift +12 −3'")).firstMatch
        let bash = tools.matching(NSPredicate(format: "label == 'Bash swift test --filter resume'")).firstMatch
        for row in [read, edit, bash] {
            XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
            waitFor("value == 'done'", [], on: row, timeout: 10)
        }
        XCTAssertEqual(tools.count, 3)
        // In transcript order: thinking, Read, Edit, Bash, under the user's message.
        XCTAssertLessThan(any(app, "session.message.user").frame.maxY, thinking.frame.minY + 1)
        XCTAssertLessThan(thinking.frame.maxY, read.frame.minY)
        XCTAssertLessThan(read.frame.maxY, edit.frame.minY + 1)
        XCTAssertLessThan(edit.frame.maxY, bash.frame.minY + 1)
        // Each row is one line.
        XCTAssertLessThan(edit.frame.height, 44)
        saveShot("s17-rows")

        // A tap on the Edit row opens its details: the whole path, the tool, +12 −3.
        edit.tap()
        let title = any(app, "transcript.sheet.title")
        XCTAssertTrue(title.waitForExistence(timeout: 5), app.debugDescription)
        let target = any(app, "transcript.sheet.target")
        waitFor("label == %@", ["ios/DSHKit/Sources/DSHCore/Sync/TaskListStore.swift"], on: target, timeout: 5)
        let lines = any(app, "transcript.sheet.lines")
        XCTAssertTrue(lines.exists, app.debugDescription)
        XCTAssertTrue(lines.label.contains("+12") && lines.label.contains("−3"), lines.label)
        saveShot("s17-tool-sheet")
        app.buttons["sheet.done"].tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))

        // The thinking row opens its sheet too.
        thinking.tap()
        waitFor("label == %@", ["Thought for 8 s"], on: any(app, "transcript.sheet.title"), timeout: 5)
        app.buttons["sheet.done"].tap()
        XCTAssertTrue(any(app, "transcript.sheet.title").waitForNonExistence(timeout: 5))
    }

    /// Without `transcript.v1`, the session page shows the S16 view: the text, no rows.
    func testWithoutTranscriptCapabilityShowsTheS16View() {
        let app = launch("transcript-v0")
        send(app)
        let transcript = any(app, "transcript.text")
        XCTAssertTrue(transcript.waitForExistence(timeout: 15), app.debugDescription)
        waitFor("value CONTAINS %@", [Self.replyEnd], on: transcript)
        waitFor("value == 'completed'", [], on: any(app, "task.status"), timeout: 10)
        XCTAssertFalse(any(app, "transcript.structured").exists)
        XCTAssertFalse(app.buttons["transcript.thinking"].exists)
        XCTAssertEqual(app.buttons.matching(identifier: "transcript.tool").count, 0)
        saveShot("s17-without-capability")
    }
}
