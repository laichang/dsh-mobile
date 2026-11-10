import CoreFoundation
import XCTest

/// Drawer motion and landing positions (design/screens.json nav and rules, F1–F4), against
/// the in-process FakeBridge:
/// - `-DSHMFakeScenario outcomes`: "… open a PR" asks to run `git push`, and after the Web
///   allows it, gives a final answer longer than the screen and ends done;
/// - `-DSHMFakeScenario coding`: a reply longer than the screen, then it keeps running.
/// Where a session lands: done and not read → the start of the final answer;
/// running → the bottom; already read → the last position the user scrolled to.
/// scripts/demo/s23.sh runs these; TEST_RUNNER_DSHM_SHOT_DIR keeps the shots.
///
/// The Mac can be very slow: every check waits on a predicate.
@MainActor
final class S23DrawerMotionUITests: XCTestCase {
    static let donePrompt = "Fix the failing CI test and open a PR"
    static let codingPrompt = "Fix the failing CI test"
    /// The last line of `FakeBridge.codingReply`.
    static let codingReplyEnd = "Running the tests now."

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                               "-DSHMResetPairing", "YES", "-DSHMResetStore", "YES",
                               "-DSHMFakeBridge", "YES", "-DSHMFakeScenario", scenario]
        app.launch()
        return app
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    private func waitFor(_ format: String, _ args: [Any] = [], on element: XCUIElement, timeout: TimeInterval = 20,
                         file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: format, argumentArray: args)
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout)
        XCTAssertEqual(result, .completed, "\(format) \(args) on \(element)", file: file, line: line)
    }

    /// Polls `condition` (frames cannot go in an NSPredicate) until it holds or time runs out.
    private func eventually(_ what: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line,
                            _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out: \(what)", file: file, line: line); return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
    }

    /// Polls `condition` until it holds or time runs out, with no failure: an assertion after it
    /// then reports the numbers.
    private func settles(timeout: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
    }

    /// The element's top edge once it stops moving (the scroll has come to rest).
    private func restingMinY(_ element: XCUIElement) -> CGFloat {
        var last = element.frame.minY
        for _ in 0..<20 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            let now = element.frame.minY
            if abs(now - last) < 0.5 { return now }
            last = now
        }
        return last
    }

    /// A slow drag in the transcript (no flick, so the scroll stops where the finger stops).
    private func dragContent(_ scroll: XCUIElement, from: CGFloat, to: CGFloat) {
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
        let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
    }

    private func startTask(_ app: XCUIApplication, _ prompt: String) {
        send(app, prompt)
        XCTAssertTrue(any(app, "task.status").waitForExistence(timeout: 20), app.debugDescription)
    }

    private func drawerRow(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.buttons.matching(identifier: "drawer.session").matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Taps a session in the drawer and waits until the page fills the screen (F4): the drawer has
    /// gone, and the page shows the session.
    private func tapInDrawer(_ app: XCUIApplication, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        openDrawer(app, file: file, line: line)
        let row = drawerRow(app, text)
        XCTAssertTrue(row.waitForExistence(timeout: 15), app.debugDescription, file: file, line: line)
        row.tap()
        XCTAssertTrue(app.otherElements["drawer"].waitForNonExistence(timeout: 10), app.debugDescription, file: file, line: line)
        waitFor("label == %@", [text], on: app.staticTexts["page.title"], file: file, line: line)
    }

    /// Done and not read → the start of the final answer. Already read → the last position the
    /// user scrolled to. On the way, a tap on a session that waits on an approval brings 05 up
    /// only after the page fills the screen.
    func testDoneUnreadLandsAtTheAnswerAndReadReturnsToTheLastPosition() {
        let app = launch("outcomes")
        startTask(app, Self.donePrompt)

        // The task asks to run `git push`: leave the sheet down and go to a new session.
        let sheet = app.descendants(matching: .any).matching(identifier: "approval.sheet").firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 40), app.debugDescription)
        closeApprovalSheet(app)
        newSession(app)

        // A tap on the waiting session: the page slides in, then the sheet comes up (F4).
        tapInDrawer(app, Self.donePrompt)
        XCTAssertTrue(sheet.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.otherElements["drawer"].exists, "the sheet comes up after the drawer has gone")
        closeApprovalSheet(app)
        newSession(app)

        // The Web allows it; the task ends while the phone shows another page.
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName("chang.dsh-mobile.fake.web-allow" as CFString),
                                             nil, nil, true)
        openDrawer(app)
        let row = drawerRow(app, Self.donePrompt)
        waitFor("value == 'completed'", on: row, timeout: 60)
        let mark = app.descendants(matching: .any).matching(identifier: "drawer.session.mark")
            .matching(NSPredicate(format: "label CONTAINS %@", Self.donePrompt)).firstMatch
        waitFor("value == 'unread'", on: mark)

        // 1. Done and not read: the page lands at the start of the final answer.
        tapInDrawer(app, Self.donePrompt)
        let scroll = app.scrollViews["session.transcript"]
        let process = any(app, "outcome.process")
        let transcript = any(app, "transcript.text")
        let footer = any(app, "outcome.footer")
        waitFor("value == 'answerStart'", on: scroll)
        XCTAssertTrue(process.waitForExistence(timeout: 15), app.debugDescription)
        waitFor("value BEGINSWITH 'Done: the CI test passes again'", on: transcript)
        eventually("the process row and the answer's start are at the top of the transcript") {
            process.isHittable && abs(process.frame.minY - scroll.frame.minY) < 40
                && transcript.frame.minY - scroll.frame.minY < 90
        }
        XCTAssertGreaterThan(transcript.frame.maxY, scroll.frame.maxY, "the rest of the answer is below the screen")
        XCTAssertFalse(footer.isHittable, "the page did not land at the end")
        let answerTop = restingMinY(transcript)
        saveShot("s23-done-unread")

        // The user reads on: a slow drag moves the answer up, and the page stays there.
        dragContent(scroll, from: 0.75, to: 0.45)
        let readTop = restingMinY(transcript)
        XCTAssertLessThan(readTop, answerTop - 60, "the user scrolled down into the answer")
        XCTAssertFalse(footer.isHittable, "the user did not reach the end")

        // 2. Already read: the page lands where the user left it.
        newSession(app)
        openDrawer(app)
        waitFor("value != 'unread'", on: mark)
        tapInDrawer(app, Self.donePrompt)
        waitFor("value == 'lastPosition'", on: scroll)
        XCTAssertTrue(transcript.waitForExistence(timeout: 15), app.debugDescription)
        settles(timeout: 20) {
            abs(transcript.frame.minY - readTop) < 24
        }
        XCTAssertEqual(transcript.frame.minY, readTop, accuracy: 24, "the answer's top, back from \(answerTop)")
        XCTAssertFalse(footer.isHittable, "not at the end: at the last position")
        saveShot("s23-read-last-position")
    }

    /// Running → the bottom, and it follows the stream. A position the user scrolled to does not
    /// count while the task runs: the page lands at the bottom again.
    func testRunningSessionLandsAtTheBottom() {
        let app = launch("coding")
        startTask(app, Self.codingPrompt)
        let transcript = any(app, "transcript.text")
        waitFor("value CONTAINS %@", [Self.codingReplyEnd], on: transcript, timeout: 30)
        waitFor("value == 'running'", on: any(app, "task.status"))

        // The user scrolls up, away from the bottom, and leaves.
        let scroll = app.scrollViews["session.transcript"]
        dragContent(scroll, from: 0.3, to: 0.7)
        newSession(app)

        // 3. Running: the page lands at the bottom, at the end of the reply so far.
        tapInDrawer(app, Self.codingPrompt)
        waitFor("value == 'followBottom'", on: scroll)
        waitFor("value == 'running'", on: any(app, "task.status"))
        // The transcript scrolls under the composer (a safe-area inset): its bottom is the
        // composer's top.
        let composer = any(app, "session.followUp")
        settles(timeout: 20) {
            let bottom = transcript.frame.maxY
            return bottom <= composer.frame.minY && bottom > composer.frame.minY - 120
        }
        XCTAssertEqual(transcript.frame.maxY, composer.frame.minY - 60, accuracy: 60, "the end of the reply")
        XCTAssertLessThan(transcript.frame.minY, scroll.frame.minY, "the start of the reply is above the screen")
        saveShot("s23-running-bottom")
    }
}
