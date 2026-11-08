import XCTest

/// S26 · Fix: Page title centering (PLAN.md §5 S26). The user's bug on a real iPhone: the title
/// "新会话" (New session) was not centered on the screen. `PageBar` gave the drawer button a
/// 40-pt slot on the left and nothing on the right (an `EmptyView` takes no width, also in a
/// frame), so the title was centered in the space right of the button: 26 pt to the right.
/// These tests check the title (and the subtitle) against the window's midX, within 1 pt, on each
/// page that has a `PageBar`. scripts/demo/s26.sh runs these; set TEST_RUNNER_DSHM_SHOT_DIR to
/// save the screenshots there. Helpers: UITestSupport.swift.
@MainActor
final class S26TitleCenterUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-DSHMResetPairing", "YES",
                               "-DSHMResetStore", "YES", "-DSHMFakeBridge", "YES"]
        app.launch()
        return app
    }

    private func title(_ app: XCUIApplication) -> XCUIElement { app.staticTexts["page.title"] }

    /// The element's center is the window's center, within 1 pt.
    private func expectCentered(_ element: XCUIElement, in app: XCUIApplication, _ what: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), app.debugDescription, file: file, line: line)
        let window = app.windows.firstMatch.frame
        XCTAssertEqual(element.frame.midX, window.midX, accuracy: 1,
                       "\(what) is centered on the screen (frame \(element.frame), window \(window))",
                       file: file, line: line)
    }

    /// The title does not overlap the drawer button, and it stays inside the bar's margins.
    private func expectClearOfButton(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons["drawer.open"].frame
        let frame = title(app).frame
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(frame.minX, button.maxX, "the title is right of the drawer button", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, window.maxX - button.maxX + 0.5,
                                 "the title keeps the same margin on the right", file: file, line: line)
    }

    /// Sends a prompt from the new session; the app shows its session page.
    private func startTask(_ app: XCUIApplication, _ prompt: String) {
        send(app, prompt)
        XCTAssertTrue(app.descendants(matching: .any)["task.status"].waitForExistence(timeout: 10), app.debugDescription)
    }

    // MARK: - Done when

    /// The reported bug: "New session" (新会话) is centered on the screen.
    func testNewSessionTitleIsCentered() {
        let app = launch()
        XCTAssertTrue(app.textFields["composer.prompt"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(title(app).label, "New session")
        expectCentered(title(app), in: app, "the new-session title")
        saveShot("s26-new-session")
    }

    /// A session page: the title and the host subtitle are centered; 所有任务 too.
    func testSessionAndAllTasksTitlesAreCentered() {
        let app = launch()
        startTask(app, "Hi")
        expectCentered(title(app), in: app, "the session title")
        let subtitle = app.staticTexts["page.subtitle"]
        if subtitle.waitForExistence(timeout: 3) {
            expectCentered(subtitle, in: app, "the session subtitle")
        }
        saveShot("s26-session")

        openAllTasks(app)
        XCTAssertEqual(title(app).label, "All tasks")
        expectCentered(title(app), in: app, "the All tasks title")
        expectCentered(app.staticTexts["page.subtitle"], in: app, "the All tasks subtitle")
    }

    /// A title longer than the bar truncates: it stays centered and clear of the drawer button.
    func testLongTitleTruncatesWithoutOverlap() {
        let app = launch()
        startTask(app, "Read the whole repository, find every failing test, fix each one, and then open one pull request")
        expectCentered(title(app), in: app, "the long title")
        expectClearOfButton(app)
        saveShot("s26-long-title")
    }
}
