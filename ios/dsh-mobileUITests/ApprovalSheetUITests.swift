import CoreFoundation
import XCTest

/// The approval sheet in a session (design screen 05), against the
/// in-process FakeBridge (`-DSHMFakeBridge approvals`): two hosts, and Home Mac starts with a task
/// that waits on `rm -rf ~/Desktop/Q3/tmp`. With `-DSHMFakeAsk 'Clean up'`, a new task asks for
/// the same command before its reply. The Web's answer is a Darwin notification that the fake
/// hosts resolve as another client would (`FakeApprovalSheet`).
/// The app runs in Chinese, like the design screens. scripts/demo/approval-sheet.sh runs these;
/// TEST_RUNNER_DSHM_SHOT_DIR keeps the screenshots.
///
/// The Mac can be very slow (load average 100+): every check waits on a predicate.
@MainActor
final class ApprovalSheetUITests: XCTestCase {
    static let command = "rm -rf ~/Desktop/Q3/tmp"
    static let seededTask = "Turn the Q3 report into slides"
    static let askingPrompt = "Clean up the Q3 slides"

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                               "-DSHMResetPairing", "YES", "-DSHMResetStore", "YES",
                               "-DSHMFakeBridge", "approvals", "-DSHMFakeAsk", "Clean up"]
        app.launch()
        return app
    }

    private func sheet(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "approval.sheet").firstMatch
    }

    private func status(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["task.status"]
    }

    private func waitFor(_ format: String, _ args: [Any] = [], on element: XCUIElement, timeout: TimeInterval = 15,
                         file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: format, argumentArray: args)
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout)
        XCTAssertEqual(result, .completed, "\(format) \(args) on \(element)", file: file, line: line)
    }

    /// Opens the seeded session from the drawer. The sheet comes up on its own.
    private func openSeededSession(_ app: XCUIApplication) -> XCUIElement {
        openDrawer(app)
        let row = app.buttons.matching(identifier: "drawer.session")
            .matching(NSPredicate(format: "label CONTAINS %@", Self.seededTask)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), app.debugDescription)
        row.tap()
        let sheet = sheet(app)
        XCTAssertTrue(sheet.waitForExistence(timeout: 20), app.debugDescription)
        return sheet
    }

    /// The sheet shows the tool, the full command, the reason, and the two answers, ready.
    private func checkContents(_ app: XCUIApplication, _ sheet: XCUIElement, task: String) {
        let command = app.staticTexts.matching(identifier: "approval.command").firstMatch
        XCTAssertTrue(command.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(command.label, Self.command)
        waitFor("label == 'bash'", on: app.descendants(matching: .any)["approval.tool"])
        waitFor("label == '批准执行这条命令？'", on: app.staticTexts["approval.title"])
        waitFor("label CONTAINS %@ AND label CONTAINS 'Home Mac'", [task], on: app.staticTexts["approval.task"])
        waitFor("label CONTAINS 'Remove the images'", on: app.staticTexts["approval.reason"])
        let footer = app.descendants(matching: .any)["approval.footer"]
        waitFor("label CONTAINS '不会默认放行' AND label CONTAINS '任务一直暂停' AND label CONTAINS '网页'", on: footer)
        // Two answers only: no "always allow".
        waitFor("isEnabled == true", on: app.buttons["approval.deny"])
        waitFor("isEnabled == true", on: app.buttons["approval.allow"])
        XCTAssertEqual(app.buttons["approval.deny"].label, "拒绝")
        XCTAssertEqual(app.buttons["approval.allow"].label, "允许一次")
        let always = app.buttons.matching(NSPredicate(format: "label CONTAINS '总是' OR label CONTAINS[c] 'always'"))
        XCTAssertEqual(always.count, 0)
    }

    /// The sheet comes up when the session opens with a pending approval, and when a new
    /// approval arrives in the open session. An answer in the sheet closes it.
    func testSheetComesUpWhenTheSessionOpensAndWhenANewApprovalArrives() {
        let app = launch()

        // 1. The session opens with a pending approval: the sheet is up.
        let sheet = openSeededSession(app)
        checkContents(app, sheet, task: Self.seededTask)
        saveShot("approval-sheet-sheet-on-open")
        app.buttons["approval.arguments"].tap()
        let arguments = app.staticTexts["approval.arguments.full"]
        XCTAssertTrue(arguments.waitForExistence(timeout: 10), app.debugDescription)
        waitFor("label CONTAINS '\"timeout\"' AND label CONTAINS '\"command\"'", on: arguments)
        saveShot("approval-sheet-tool-arguments")

        // Deny: the sheet closes, and the task runs on to its reply.
        app.buttons["approval.deny"].tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(status(app).waitForExistence(timeout: 10), app.debugDescription)
        waitFor("value == 'completed'", on: status(app), timeout: 40)
        XCTAssertFalse(app.descendants(matching: .any)["approval.pending"].exists)

        // 2. A new approval arrives while the session is open: the sheet comes up again.
        newSession(app)
        send(app, Self.askingPrompt)
        XCTAssertTrue(sheet.waitForExistence(timeout: 30), app.debugDescription)
        waitFor("value ENDSWITH '-approval' AND NOT (value BEGINSWITH 'fake-seed')", on: sheet)
        checkContents(app, sheet, task: Self.askingPrompt)
        saveShot("approval-sheet-sheet-new-approval")

        // Allow once: the sheet closes, and the task runs on to its reply.
        app.buttons["approval.allow"].tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(status(app).waitForExistence(timeout: 10), app.debugDescription)
        waitFor("value == 'completed'", on: status(app), timeout: 40)
    }

    /// A sheet swiped away stays down; the bar on the page brings it back. After an answer from
    /// the Web, the sheet closes on the phone, and the task goes on.
    func testWebAnswerClosesTheSheet() {
        let app = launch()
        let sheet = openSeededSession(app)
        checkContents(app, sheet, task: Self.seededTask)

        // Swipe it away: the page shows one line that opens it again.
        closeApprovalSheet(app)
        let bar = app.buttons["approval.pending"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10), app.debugDescription)
        waitFor("value == 'waiting'", on: status(app))
        bar.tap()
        XCTAssertTrue(sheet.waitForExistence(timeout: 15), app.debugDescription)
        checkContents(app, sheet, task: Self.seededTask)
        saveShot("approval-sheet-before-web-answer")

        // The Web denies it. The phone gets only ApprovalResolved: the sheet closes by itself.
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName("chang.dsh-mobile.fake.web-deny" as CFString),
                                             nil, nil, true)
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(bar.waitForNonExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(status(app).waitForExistence(timeout: 10), app.debugDescription)
        waitFor("value == 'completed'", on: status(app), timeout: 40)
        saveShot("approval-sheet-web-answered")
    }
}
