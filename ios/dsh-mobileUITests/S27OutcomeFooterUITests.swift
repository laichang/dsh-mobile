import XCTest

/// Fix: Outcome duration and marker. The user's bugs on a
/// real iPhone (2026-11-07), on a Web session that they had used for several turns:
/// - "用时2小时37分钟15秒"，离谱了: the done footer counted from the session's first message, so
///   it took in the idle time between turns. It now counts the latest turn only.
/// - "停在这里·最终回答开头"，这是什么？: the user chose to remove the label. An unread finished
///   session still opens at the start of its final answer, with nothing drawn there.
///
/// Against the FakeBridge's `-DSHMFakeScenario turns` (`FakeTurns`): a done Web session whose first
/// turn is 2 h 37 min 15 s before its end, and whose second turn took 1 min 24 s. The app runs in
/// Chinese, as on the user's iPhone. scripts/demo/s27.sh runs these; TEST_RUNNER_DSHM_SHOT_DIR keeps
/// the shots. Helpers: UITestSupport.swift.
@MainActor
final class S27OutcomeFooterUITests: XCTestCase {
    static let title = "Plan a weekend in Hangzhou"
    static let answerStart = "Here is a day trip to Hangzhou, from the first train to the last."

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                               "-DSHMResetPairing", "YES", "-DSHMResetStore", "YES",
                               "-DSHMFakeBridge", "YES", "-DSHMFakeScenario", "turns"]
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

    private func eventually(_ what: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line,
                            _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out: \(what)", file: file, line: line); return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
    }

    /// The final answer: the last assistant message of the journal.
    private func finalAnswer(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "session.message.assistant")
            .matching(NSPredicate(format: "label BEGINSWITH %@", Self.answerStart)).firstMatch
    }

    // MARK: - Done when

    /// (a) 用时 is the latest turn's time (1 min 24 s), not the time since the first turn
    /// (2 h 37 min 15 s).
    func testDoneFooterCountsTheLatestTurnOnly() {
        let app = launch()
        openSession(app, Self.title, timeout: 20)
        waitFor("value == 'completed'", on: any(app, "task.status"))
        let footer = any(app, "outcome.footer")
        XCTAssertTrue(footer.waitForExistence(timeout: 20), app.debugDescription)
        let label = footer.label
        XCTAssertFalse(label.contains("小时"), "用时 has no hours: \(label)")
        XCTAssertFalse(label.contains("37"), "用时 is not the time since the first turn: \(label)")
        XCTAssertTrue(label.contains("1") && label.contains("24"), "用时 is the latest turn's 1 min 24 s: \(label)")
        // Scroll to the footer for the shot.
        let scroll = app.scrollViews["session.transcript"]
        for _ in 0..<6 where !footer.isHittable { scroll.swipeUp() }
        eventually("the footer is on the screen") { footer.isHittable }
        saveShot("s27-footer-latest-turn")
    }

    /// (b) An unread done session opens at the start of its final answer, with no label there:
    /// no "停在这里 · 最终回答开头", no "Stopped here".
    func testUnreadDoneSessionOpensAtTheFinalAnswerWithNoLabel() {
        let app = launch()
        openSession(app, Self.title, timeout: 20)
        let scroll = app.scrollViews["session.transcript"]
        waitFor("value == 'answerStart'", on: scroll)
        let answer = finalAnswer(app)
        XCTAssertTrue(answer.waitForExistence(timeout: 20), app.debugDescription)
        let process = any(app, "outcome.process")
        let footer = any(app, "outcome.footer")
        // The process row is at the top, the final answer starts right under it, and the rest of
        // the answer goes on below the screen.
        eventually("the process row and the answer's start are at the top of the transcript") {
            process.isHittable && abs(process.frame.minY - scroll.frame.minY) < 40
                && answer.frame.minY - process.frame.maxY < 24
        }
        XCTAssertGreaterThan(answer.frame.maxY, scroll.frame.maxY, "the rest of the answer is below the screen")
        XCTAssertFalse(footer.isHittable, "the page did not open at the end")
        // No label at the answer's start.
        XCTAssertFalse(any(app, "outcome.answerStart").exists, "no marker element")
        let label = NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@",
                                "停在这里", "最终回答开头", "Stopped here")
        XCTAssertEqual(app.descendants(matching: .any).matching(label).count, 0, "no marker text")
        saveShot("s27-unread-answer-start")
    }
}
