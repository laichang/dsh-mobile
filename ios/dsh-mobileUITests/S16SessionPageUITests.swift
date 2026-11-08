import XCTest

/// S16 · the session page (PLAN.md §5 S16, screen 04), against the in-process FakeBridge's coding
/// task (`-DSHMFakeScenario coding`): five steps, three done ("3 / 5"), a reply longer than the
/// screen, and the task keeps running until the user taps stop. scripts/demo/s16.sh runs these;
/// set TEST_RUNNER_DSHM_SHOT_DIR to save the screenshots there. Helpers: UITestSupport.swift.
@MainActor
final class S16SessionPageUITests: XCTestCase {
    static let prompt = "Fix the failing CI test and open a PR"
    /// The last line of `FakeBridge.codingReply`.
    static let replyEnd = "Running the tests now."

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchCodingTask() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-DSHMResetPairing", "YES",
                               "-DSHMResetStore", "YES", "-DSHMFakeBridge", "YES", "-DSHMFakeScenario", "coding"]
        app.launchArguments += noUIKitAnimations // D128
        app.launch()
        return app
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    /// Sends the coding task and waits until it shows "3 / 5" with its whole reply, still running.
    private func startCodingTask(_ app: XCUIApplication) {
        send(app, Self.prompt)
        let bar = any(app, "milestone.card")
        XCTAssertTrue(bar.waitForExistence(timeout: 10), app.debugDescription)
        waitForValue(bar, in: ["3/5"], timeout: 15)
        XCTAssertEqual(bar.label, "Run the tests")
        let transcript = any(app, "transcript.text")
        wait(for: [expectation(for: NSPredicate(format: "value CONTAINS %@", Self.replyEnd), evaluatedWith: transcript)],
             timeout: 20)
        XCTAssertEqual(any(app, "task.status").value as? String, "running")
    }

    /// The milestone bar stays at the top while the transcript scrolls: the transcript moves under
    /// it in both directions, and the bar keeps its frame. A tap on the bar opens all steps.
    func testMilestoneBarStaysAtTopWhileTranscriptScrolls() {
        let app = launchCodingTask()
        startCodingTask(app)
        let bar = any(app, "milestone.card")
        let scroll = app.scrollViews["session.transcript"]
        let bubble = any(app, "session.message.user")
        let transcript = any(app, "transcript.text")
        XCTAssertTrue(scroll.exists, app.debugDescription)
        XCTAssertGreaterThan(transcript.frame.height, scroll.frame.height, "the reply is longer than the screen")
        // The bar is above the scroll view, under the page bar.
        XCTAssertLessThanOrEqual(bar.frame.maxY, scroll.frame.minY + 1)
        XCTAssertGreaterThan(bar.frame.minY, app.staticTexts["page.title"].frame.maxY)
        let barFrame = bar.frame

        // To the top: the user's message shows under the bar.
        for _ in 0..<4 { scroll.swipeDown(velocity: .fast) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        XCTAssertTrue(bubble.isHittable, app.debugDescription)
        XCTAssertGreaterThanOrEqual(bubble.frame.minY, bar.frame.maxY)
        let top = bubble.frame.minY
        XCTAssertEqual(bar.frame, barFrame)
        saveShot("s16-session-top")

        // To the end: the transcript moved up under the bar; the bar did not move.
        for _ in 0..<4 { scroll.swipeUp(velocity: .fast) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        XCTAssertLessThan(bubble.frame.minY, top - 200, "the transcript scrolled")
        XCTAssertLessThan(bubble.frame.maxY, bar.frame.maxY, "the user's message is above the bar's lower edge")
        XCTAssertFalse(bubble.isHittable, "the user's message scrolled away under the bar")
        XCTAssertEqual(bar.frame, barFrame, "the bar stays at the top")
        XCTAssertTrue(bar.isHittable)
        XCTAssertTrue(any(app, "transcript.fence.swift").exists, "Markdown code blocks render as blocks")
        saveShot("s16-session-scrolled")

        // A tap on the bar opens all the steps in a sheet.
        bar.tap()
        let timeline = any(app, "milestone.timeline")
        XCTAssertTrue(timeline.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["sheet.done"].exists)
        app.buttons["sheet.done"].tap()
        XCTAssertTrue(timeline.waitForNonExistence(timeout: 5))
        XCTAssertEqual(bar.frame, barFrame)
    }

    /// Stop interrupts the task from the send position: the stop key takes the send key's place
    /// while the task runs, and the send key comes back there when it stops.
    func testStopInterruptsFromTheSendPosition() {
        let app = launchCodingTask()
        startCodingTask(app)
        let stop = app.buttons["task.interrupt"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["session.send"].exists, "while it runs, stop is in the send position")
        let place = stop.frame
        // The trailing end of the composer, at the bottom of the screen.
        XCTAssertGreaterThan(place.minX, app.frame.width * 0.75)
        XCTAssertGreaterThan(place.minY, app.frame.height * 0.8)
        saveShot("s16-stop-running")

        stop.tap()
        let status = any(app, "task.status")
        waitForValue(status, in: ["interrupted"], timeout: 10)
        XCTAssertTrue(stop.waitForNonExistence(timeout: 5))
        let send = app.buttons["session.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(send.isEnabled)
        XCTAssertEqual(send.frame.minX, place.minX, accuracy: 1)
        XCTAssertEqual(send.frame.minY, place.minY, accuracy: 1)
        let bar = any(app, "milestone.card")
        wait(for: [expectation(for: NSPredicate(format: "label == 'Interrupted'"), evaluatedWith: bar)], timeout: 5)
        XCTAssertEqual(bar.value as? String, "3/5", "the bar keeps the progress it had")
        saveShot("s16-stopped")
    }
}
