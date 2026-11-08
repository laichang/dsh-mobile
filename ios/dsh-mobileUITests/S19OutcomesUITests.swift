import CoreFoundation
import XCTest

/// S19 · done and failed (PLAN.md §5 S19, DESIGN.md screens 06 and X1), against the in-process
/// FakeBridge's outcomes scenario (`-DSHMFakeScenario outcomes`, `FakeBridge.Script.outcomes`):
/// - "… open a PR": five todos; after four it asks to run `git push`, then gives a final answer
///   longer than the screen and ends done;
/// - "… upload …": four todos; it fails on the third with `upload: 403 Forbidden (token expired)`;
/// - "Rename …": runs until the user stops it.
/// The Web's answer is a Darwin notification (`FakeApprovalSheet`). The app runs in Chinese, like
/// the design board. scripts/demo/s19.sh runs these; TEST_RUNNER_DSHM_SHOT_DIR keeps the shots.
///
/// The Mac can be very slow: every check waits on a predicate.
@MainActor
final class S19OutcomesUITests: XCTestCase {
    static let donePrompt = "Fix the failing CI test and open a PR"
    static let failPrompt = "Compress the media from yesterday and upload it"
    static let holdPrompt = "Rename the photos by date"
    static let failure = "upload: 403 Forbidden (token expired)"

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                               "-DSHMResetPairing", "YES", "-DSHMResetStore", "YES",
                               "-DSHMFakeBridge", "YES", "-DSHMFakeScenario", "outcomes"]
        app.launchArguments += noUIKitAnimations // D128
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

    private func startTask(_ app: XCUIApplication, _ prompt: String) {
        send(app, prompt)
        XCTAssertTrue(any(app, "task.status").waitForExistence(timeout: 20), app.debugDescription)
    }

    private func drawerRow(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.buttons.matching(identifier: "drawer.session").matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// A done session that this phone has not shown opens at the start of its final answer, right
    /// under the process row, with no marker (S27, D76). Once read, it opens at the end, as before.
    func testDoneSessionNotReadOpensAtTheStartOfTheFinalAnswer() {
        let app = launch()
        startTask(app, Self.donePrompt)

        // The task asks to run `git push` (S18's sheet). Leave it, and go to a new session.
        let sheet = app.descendants(matching: .any).matching(identifier: "approval.sheet").firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 40), app.debugDescription)
        closeApprovalSheet(app)
        newSession(app)

        // The Web allows it; the task ends while the phone shows another page.
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName("chang.dsh-mobile.fake.web-allow" as CFString),
                                             nil, nil, true)
        openDrawer(app)
        let row = drawerRow(app, Self.donePrompt)
        XCTAssertTrue(row.waitForExistence(timeout: 15), app.debugDescription)
        waitFor("value == 'completed'", on: row, timeout: 60)
        let mark = app.descendants(matching: .any).matching(identifier: "drawer.session.mark")
            .matching(NSPredicate(format: "label CONTAINS %@", Self.donePrompt)).firstMatch
        waitFor("value == 'unread'", on: mark)
        row.tap()

        // It opens at the start of the final answer: the process row is at the top of the
        // transcript, the answer starts right under it and goes on below the screen.
        let scroll = app.scrollViews["session.transcript"]
        waitFor("value == 'answerStart'", on: scroll)
        let transcript = any(app, "transcript.text")
        let footer = any(app, "outcome.footer")
        waitFor("value BEGINSWITH 'Done: the CI test passes again'", on: transcript)
        let process = any(app, "outcome.process")
        eventually("the process row and the answer's start are at the top of the transcript") {
            process.isHittable && abs(process.frame.minY - scroll.frame.minY) < 40
                && transcript.frame.minY - scroll.frame.minY < 90
        }
        XCTAssertGreaterThanOrEqual(transcript.frame.minY, process.frame.maxY - 1, "the answer starts under the process row")
        XCTAssertFalse(any(app, "outcome.answerStart").exists, "no marker (S27)")
        XCTAssertGreaterThan(transcript.frame.maxY, scroll.frame.maxY, "the rest of the answer is below the screen")
        XCTAssertFalse(footer.isHittable, "the page did not open at the end")
        // The process is one row: steps and the approval answered on the Web.
        waitFor("label == '已工作 · 8 步 · 1 次审批'", on: process)
        waitFor("value == 'completed'", on: any(app, "task.status"))
        let bar = any(app, "milestone.card")
        waitFor("value == '5/5'", on: bar)
        saveShot("s19-done-unread")

        // The process row opens all the steps.
        process.tap()
        XCTAssertTrue(any(app, "milestone.timeline").waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["sheet.done"].tap()
        XCTAssertTrue(any(app, "milestone.timeline").waitForNonExistence(timeout: 10))

        // Read now: the next time it opens at the end.
        newSession(app)
        openDrawer(app)
        waitFor("value != 'unread'", on: mark)
        drawerRow(app, Self.donePrompt).tap()
        XCTAssertTrue(footer.waitForExistence(timeout: 15), app.debugDescription)
        eventually("the read session opens at the end") { footer.isHittable }
        saveShot("s19-done-read")
    }

    /// A failed task: a red bar with the step, the raw error, 复制错误; 新会话里再试 opens 01 with
    /// the original prompt, which the user can edit and send.
    func testFailedTaskRetriesInANewSessionWithTheOriginalPrompt() {
        let app = launch()
        startTask(app, Self.failPrompt)
        let status = any(app, "task.status")
        waitFor("value == 'failed'", on: status, timeout: 60)

        let bar = any(app, "milestone.card")
        waitFor("label == '失败 · 第 3 步'", on: bar)
        waitFor("value == '2/4'", on: bar)
        let card = any(app, "outcome.card")
        XCTAssertTrue(card.waitForExistence(timeout: 10), app.debugDescription)
        waitFor("value == 'failed'", on: card)
        waitFor("label == %@", [Self.failure], on: any(app, "outcome.error"))
        waitFor("label CONTAINS '任务失败'", on: any(app, "outcome.title"))
        waitFor("label == '已工作 · 5 步'", on: any(app, "outcome.process"))
        let copy = app.buttons["outcome.copy"]
        waitFor("label == '复制错误'", on: copy)
        let retry = app.buttons["outcome.retry"]
        waitFor("label == '新会话里再试'", on: retry)
        saveShot("s19-failed")

        copy.tap()
        waitFor("label == '已复制'", on: copy)

        // 新会话里再试: a new session (01) with the original prompt, ready to edit.
        retry.tap()
        let field = app.textFields["composer.prompt"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), app.debugDescription)
        waitFor("value == %@", [Self.failPrompt], on: field)
        XCTAssertFalse(any(app, "task.status").exists, "a new session, not the failed one")
        waitFor("label == '新会话'", on: app.staticTexts["page.title"])
        saveShot("s19-retry-prefilled")

        field.tap()
        waitFor("hasKeyboardFocus == true", on: field)
        field.typeText(" again")
        waitFor("value CONTAINS ' again' AND value CONTAINS 'upload' AND value CONTAINS 'Compress'", on: field)
        let edited = field.value as? String ?? ""
        XCTAssertEqual(edited.count, Self.failPrompt.count + " again".count)
        app.buttons["composer.send"].tap()
        waitFor("label == %@", [edited], on: app.staticTexts["page.title"], timeout: 30)
        XCTAssertTrue(any(app, "task.status").waitForExistence(timeout: 15), app.debugDescription)
    }

    /// A task the user stopped shows the same card: 任务已停止, and 新会话里再试.
    func testStoppedTaskShowsTheSameCard() {
        let app = launch()
        startTask(app, Self.holdPrompt)
        let stop = app.buttons["task.interrupt"]
        XCTAssertTrue(stop.waitForExistence(timeout: 20), app.debugDescription)
        waitFor("isEnabled == true", on: stop)
        stop.tap()
        waitFor("value == 'interrupted'", on: any(app, "task.status"))

        let card = any(app, "outcome.card")
        XCTAssertTrue(card.waitForExistence(timeout: 10), app.debugDescription)
        waitFor("value == 'interrupted'", on: card)
        waitFor("label CONTAINS '任务已停止'", on: any(app, "outcome.title"))
        XCTAssertFalse(app.buttons["outcome.copy"].exists, "no error to copy")
        waitFor("label == '新会话里再试'", on: app.buttons["outcome.retry"])
        saveShot("s19-stopped")

        app.buttons["outcome.retry"].tap()
        waitFor("value == %@", [Self.holdPrompt], on: app.textFields["composer.prompt"])
    }
}
