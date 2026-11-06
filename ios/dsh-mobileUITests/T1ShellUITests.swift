import XCTest

/// T1 · the new UI shell (PLAN.md §5 T1, DESIGN.md "Navigation"), against the in-process
/// FakeBridge: nothing else needs to run. scripts/demo/t1.sh runs these; set
/// TEST_RUNNER_DSHM_SHOT_DIR to save the screenshots there. Helpers: UITestSupport.swift.
@MainActor
final class T1ShellUITests: XCTestCase {
    static let fakeReply = "Hello from FakeBridge. No DSH was involved."

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ arguments: [String] = [], reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-DSHMResetPairing", "YES"] + arguments
        if reset { app.launchArguments += ["-DSHMResetStore", "YES"] }
        app.launch()
        return app
    }

    private func send(_ app: XCUIApplication, _ prompt: String) {
        let field = app.textFields["composer.prompt"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
        field.tap()
        field.typeText(prompt)
        app.buttons["composer.send"].tap()
    }

    private func status(_ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)["task.status"] }

    private func assertNewSession(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let title = app.staticTexts["page.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), app.debugDescription, file: file, line: line)
        XCTAssertEqual(title.label, "New session", file: file, line: line)
        XCTAssertTrue(app.textFields["composer.prompt"].exists, file: file, line: line)
        XCTAssertFalse(status(app).exists, file: file, line: line)
        XCTAssertFalse(app.descendants(matching: .any)["tasklist"].exists, "the task list is not the home screen", file: file, line: line)
        XCTAssertFalse(app.otherElements["drawer"].exists, file: file, line: line)
        // One line above the composer: "host · workspace", the default host and workspace.
        let context = app.descendants(matching: .any)["composer.context"]
        XCTAssertTrue(context.exists, file: file, line: line)
        XCTAssertEqual(app.staticTexts["composer.hostName"].label, "FakeBridge Mac", file: file, line: line)
        XCTAssertTrue(context.staticTexts["Default workspace"].exists, app.debugDescription, file: file, line: line)
    }

    /// Drags from the left edge to `x` (points). `hold` keeps the finger still before release,
    /// so the release has no velocity.
    private func edgeDrag(_ app: XCUIApplication, to x: CGFloat, velocity: XCUIGestureVelocity, hold: TimeInterval) {
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: 3, dy: 420))
        let end = origin.withOffset(CGVector(dx: x, dy: 430))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: velocity, thenHoldForDuration: hold)
    }

    // MARK: - Done when

    /// On launch: a blank new session with the default host and workspace, not the task list.
    /// Also after a relaunch with tasks in the cache: the app does not go back to the last place.
    func testLaunchShowsBlankNewSession() {
        var app = launch(["-DSHMFakeBridge", "YES"])
        assertNewSession(app)
        saveShot("t1-launch-new-session")

        send(app, "Introduce yourself in one sentence.")
        waitForValue(status(app), in: ["completed"], timeout: 15)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.terminate()
        app = launch(["-DSHMFakeBridge", "YES"], reset: false)
        assertNewSession(app)
    }

    /// The first message creates the session, and the same page shows the reply: no list routing
    /// and no grace period (ARCHITECTURE D51, which supersedes D34).
    func testFirstMessageCreatesSessionOnSamePage() {
        let app = launch(["-DSHMFakeBridge", "YES"])
        assertNewSession(app)
        let prompt = "Translate: Bonjour."
        send(app, prompt)
        XCTAssertTrue(status(app).waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(app.staticTexts["page.title"].label, prompt)
        XCTAssertEqual(app.staticTexts["page.subtitle"].label, "FakeBridge Mac")
        XCTAssertEqual(app.descendants(matching: .any)["session.message.user"].label, prompt)
        XCTAssertFalse(app.textFields["composer.prompt"].exists, "the new session became the session page")
        let transcript = app.descendants(matching: .any)["transcript.text"]
        waitForValue(status(app), in: ["completed"], timeout: 15)
        XCTAssertEqual(transcript.value as? String, Self.fakeReply)
        // Beyond M1's two-second routing window: still the same page, the reply on it.
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        XCTAssertTrue(status(app).exists)
        XCTAssertEqual(transcript.value as? String, Self.fakeReply)
        XCTAssertFalse(app.descendants(matching: .any)["tasklist"].exists)
        saveShot("t1-first-message-reply")

        // The drawer shows the session under its host.
        openDrawer(app)
        let host = app.descendants(matching: .any)["host.status"]
        let row = app.buttons.matching(identifier: "drawer.session").matching(NSPredicate(format: "label CONTAINS %@", prompt)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(host.label.contains("FakeBridge Mac"), host.label)
        XCTAssertGreaterThan(row.frame.minY, host.frame.maxY)
        XCTAssertEqual(row.value as? String, "completed")
    }

    /// A drag from the left edge opens the drawer and pushes the page; a release with low
    /// velocity before the middle closes it again; a quick flick opens it.
    func testEdgeDragOpensDrawerAndSlowReleaseCloses() {
        let app = launch(["-DSHMFakeBridge", "YES"])
        assertNewSession(app)
        send(app, "Session for the drawer")
        waitForValue(status(app), in: ["completed"], timeout: 15)
        let drawer = app.otherElements["drawer"]
        let pageWidth = app.frame.width
        let drawerWidth = min(pageWidth * 0.82, 340)

        // A full drag: open. The page is pushed by the drawer's width, not covered.
        edgeDrag(app, to: pageWidth * 0.9, velocity: .default, hold: 0.2)
        XCTAssertTrue(drawer.waitForExistence(timeout: 3), app.debugDescription)
        let peek = app.buttons["drawer.dismiss"]
        XCTAssertTrue(peek.waitForExistence(timeout: 3))
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(peek.frame.minX, drawerWidth, accuracy: 2, "the page moved right by the drawer width")
        XCTAssertEqual(drawer.frame.minX, 0, accuracy: 2)
        XCTAssertTrue(app.buttons.matching(identifier: "drawer.session")
            .matching(NSPredicate(format: "label CONTAINS 'Session for the drawer'")).firstMatch.exists)
        saveShot("t1-drawer-open")
        closeDrawer(app)
        XCTAssertTrue(status(app).exists, "closing the drawer shows the same page")

        // A short, slow drag with a still release: back to closed.
        edgeDrag(app, to: drawerWidth * 0.3, velocity: .slow, hold: 0.4)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        XCTAssertFalse(drawer.exists, "a slow release before the middle closes the drawer")
        XCTAssertTrue(status(app).isHittable)

        // A drag that stops just before the middle, released at speed: open. Without the velocity
        // it would close (as above); even a slow measured release (~100 pt/s) carries it past.
        edgeDrag(app, to: drawerWidth * 0.45, velocity: 2500, hold: 0)
        XCTAssertTrue(drawer.waitForExistence(timeout: 3), "a flick opens the drawer")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(app.buttons["drawer.dismiss"].frame.minX, drawerWidth, accuracy: 2)
    }

    /// The session page has no back button. The milestone timeline opens as a sheet.
    func testNoBackButtonAndTimelineSheet() {
        let app = launch(["-DSHMFakeBridge", "YES", "-DSHMFakeMilestones", "YES"])
        send(app, "Summarize this project in three steps.")
        let card = app.descendants(matching: .any)["milestone.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 20), app.debugDescription)
        waitForValue(status(app), in: ["completed"], timeout: 30)
        XCTAssertEqual(app.navigationBars.count, 0, "a session page has no navigation bar")
        XCTAssertFalse(app.buttons["BackButton"].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label IN {'Back', 'Tasks'}")).count, 0)
        XCTAssertTrue(app.buttons["drawer.open"].exists)
        saveShot("t1-session-page")

        card.tap()
        let timeline = app.descendants(matching: .any)["milestone.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["sheet.done"].exists, "the timeline is a sheet with its own Done")
        // A bottom sheet: the session page stays under it, from the top of the screen.
        XCTAssertGreaterThan(timeline.frame.minY, 20)
        saveShot("t1-timeline-sheet")
        app.buttons["sheet.done"].tap()
        XCTAssertTrue(timeline.waitForNonExistence(timeout: 5))
        XCTAssertEqual(status(app).value as? String, "completed")
    }

    /// The demo's tail: 所有任务 from the drawer, then a tap on a running task opens its session.
    /// A tap on a session in the drawer shows it.
    func testAllTasksAndDrawerOpenSessions() {
        // The FakeBridge holds the second task after its first milestone, so it is still running
        // when the test taps it.
        let app = launch(["-DSHMFakeBridge", "YES", "-DSHMFakeMilestones", "YES", "-DSHMFakeHold", "Second task"])
        send(app, "First task, finished")
        waitForValue(status(app), in: ["completed"], timeout: 30)
        newSession(app)
        send(app, "Second task, running")
        XCTAssertTrue(status(app).waitForExistence(timeout: 5))
        XCTAssertEqual(status(app).value as? String, "running")

        openAllTasks(app)
        let running = app.buttons.matching(identifier: "tasklist.row")
            .matching(NSPredicate(format: "label CONTAINS 'Second task, running'")).firstMatch
        XCTAssertTrue(running.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(running.value as? String, "running")
        XCTAssertTrue(app.descendants(matching: .any)["tasklist.running"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["tasklist.done"].exists)
        saveShot("t1-all-tasks")
        running.tap()
        XCTAssertTrue(status(app).waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["page.title"].label, "Second task, running")
        XCTAssertEqual(status(app).value as? String, "running")

        openSession(app, "First task, finished")
        XCTAssertEqual(app.staticTexts["page.title"].label, "First task, finished")
        XCTAssertEqual(status(app).value as? String, "completed")
        XCTAssertFalse(app.otherElements["drawer"].exists)
    }
}
