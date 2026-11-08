import XCTest

/// S28 · Markdown tables (PLAN.md §5 S28, screen 04, D79): a GFM table in the agent's reply shows as
/// a table, not as its Markdown source. Against the in-process FakeBridge's coding task
/// (`-DSHMFakeScenario coding`), whose reply has a table, and its wide-table variant
/// (`FakeBridge.tablesPrompt`). scripts/demo/s28.sh runs these; set TEST_RUNNER_DSHM_SHOT_DIR to save
/// the screenshots there. Helpers: UITestSupport.swift.
@MainActor
final class S28MarkdownTablesUITests: XCTestCase {
    /// The last line of each reply (`FakeBridge.codingReply`, `FakeBridge.tablesReply`).
    static let codingEnd = "Running the tests now."
    static let tablesPrompt = "Compare the test runs in a table"
    static let tablesEnd = "Only doctest fails. Done."

    override func setUp() {
        continueAfterFailure = false
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    private func send(_ prompt: String, waitFor end: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-DSHMResetPairing", "YES",
                               "-DSHMResetStore", "YES", "-DSHMFakeBridge", "YES", "-DSHMFakeScenario", "coding"]
        app.launch()
        send(app, prompt)
        let transcript = any(app, "transcript.text")
        XCTAssertTrue(transcript.waitForExistence(timeout: 10), app.debugDescription)
        let replied = expectation(for: NSPredicate(format: "value CONTAINS %@", end), evaluatedWith: transcript)
        if XCTWaiter().wait(for: [replied], timeout: 30) != .completed {
            XCTFail("no reply ending in \(end): \(app.debugDescription)")
        }
        return app
    }

    /// Scrolls the transcript until `element` is on screen.
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        let scroll = app.scrollViews["session.transcript"]
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            scroll.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }

    /// No text on the page shows the Markdown table source: no delimiter row, no `| a | b |` row.
    private func assertNoRawTable(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let raw = NSPredicate(format: "label CONTAINS '---|' OR label CONTAINS '--- |' OR label CONTAINS '| ---' OR label CONTAINS '|---' OR label BEGINSWITH '| '")
        let texts = app.staticTexts.matching(raw)
        XCTAssertEqual(texts.count, 0, "raw table text: \(texts.allElementsBoundByIndex.map(\.label))", file: file, line: line)
    }

    /// The bug the user reported: the reply's table showed as `| Case | Before | After |` and `| --- |`
    /// text. With the fix, each cell is its own text, in a table, and no raw row shows.
    func testReplyTableShowsAsTable() {
        let app = send("Fix the failing CI test and open a PR", waitFor: Self.codingEnd)
        let table = any(app, "transcript.table")
        XCTAssertTrue(table.waitForExistence(timeout: 5), app.debugDescription)
        scrollTo(table, in: app)
        for cell in ["Case", "Before", "After", "replay, then live", "live, then replay", "wrong order"] {
            XCTAssertTrue(table.staticTexts[cell].exists, "cell \(cell): \(app.debugDescription)")
        }
        // Columns line up: "wrong order" is under "Before", in the row of "live, then replay".
        let header = table.staticTexts["Before"].frame
        let cell = table.staticTexts["wrong order"].frame
        XCTAssertEqual(cell.minX, header.minX, accuracy: 1, "a left-aligned column")
        XCTAssertEqual(cell.midY, table.staticTexts["live, then replay"].frame.midY, accuracy: 2)
        XCTAssertGreaterThan(cell.minY, header.maxY)
        assertNoRawTable(app)
        saveShot("s28-table")
    }

    /// A table wider than the screen scrolls inside its own row; the page does not widen. Long cells
    /// wrap; a right-aligned column lines up at the trailing edge; an escaped pipe is a pipe.
    func testWideTableScrollsInItsRow() {
        let app = send(Self.tablesPrompt, waitFor: Self.tablesEnd)
        let table = any(app, "transcript.table")
        XCTAssertTrue(table.waitForExistence(timeout: 5), app.debugDescription)
        scrollTo(table, in: app)
        assertNoRawTable(app)
        let window = app.windows.firstMatch.frame
        let prose = app.staticTexts[Self.tablesEnd]
        XCTAssertTrue(prose.exists, app.debugDescription)
        XCTAssertLessThanOrEqual(prose.frame.maxX, window.maxX, "the page does not widen")
        XCTAssertLessThanOrEqual(table.frame.maxX, window.maxX + 1, "the table's row stays in the page")

        // Right-aligned numbers: the trailing edges of the header and the cells line up.
        let time = table.staticTexts["Time (s)"]
        let first = table.staticTexts["0.41"]
        XCTAssertEqual(first.frame.maxX, time.frame.maxX, accuracy: 1)
        // A long cell wraps instead of making its column as wide as its text.
        let long = table.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'The default runner.'")).firstMatch
        XCTAssertTrue(long.exists, app.debugDescription)
        XCTAssertGreaterThan(long.frame.height, first.frame.height * 1.8, "the long cell wraps")
        XCTAssertTrue(table.staticTexts.matching(NSPredicate(format: "label CONTAINS 'a | b'")).firstMatch.exists,
                      "an escaped pipe shows as a pipe in its cell")
        saveShot("s28-wide-table")

        // The last column is off screen; a swipe on the table brings it in, and the prose stays put.
        let notes = table.staticTexts["Notes"]
        XCTAssertGreaterThan(notes.frame.minX, window.maxX - 40, "the table is wider than the screen")
        let proseFrame = prose.frame
        table.swipeLeft(velocity: .slow)
        table.swipeLeft(velocity: .slow)
        XCTAssertLessThan(notes.frame.maxX, window.maxX + 1, app.debugDescription)
        XCTAssertEqual(prose.frame, proseFrame, "only the table scrolled")
        saveShot("s28-wide-table-scrolled")
    }
}
