import XCTest

/// 所有任务 (design screen 03), against the in-process FakeBridge with
/// two hosts that each start with a task waiting on an approval (`-DSHMFakeBridge approvals`).
/// The app runs in Chinese, like the design screens; the checks use identifiers and host names.
/// scripts/demo/s15.sh runs these; TEST_RUNNER_DSHM_SHOT_DIR keeps the screenshots.
@MainActor
final class S15AllTasksUITests: XCTestCase {
    static let homeCommand = "rm -rf ~/Desktop/Q3/tmp"
    static let homeTask = "Turn the Q3 report into slides"
    static let officeTask = "Write the weekly report"

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ scenario: String, reset: Bool, hold: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-DSHMResetPairing", "YES",
                               "-DSHMFakeBridge", scenario]
        if reset { app.launchArguments += ["-DSHMResetStore", "YES"] }
        if let hold { app.launchArguments += ["-DSHMFakeHold", hold] }
        app.launchArguments += noUIKitAnimations
        app.launch()
        return app
    }

    private func cards(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "approval.card")
    }

    /// The approval card of one host, once that host's state is `reachability`.
    private func card(_ app: XCUIApplication, host: String, reachability: String,
                      file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let card = cards(app).containing(NSPredicate(format: "identifier == 'approval.host' AND label BEGINSWITH %@", host))
            .matching(NSPredicate(format: "value == %@", reachability)).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), app.debugDescription, file: file, line: line)
        return card
    }

    private func rows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(identifier: "tasklist.row")
    }

    /// Lets the coalesced cache save land before `terminate()` (which skips the background phase).
    private func settle() { RunLoop.current.run(until: Date().addingTimeInterval(1.5)) }

    /// 所有任务 opens from the drawer and shows 等我处理 / 正在跑 / 已完成, with tasks of both hosts.
    func testAllTasksShowsThreeSectionsAcrossHosts() {
        let app = launch("approvals", reset: true, hold: "Compress")
        // Done, on Home Mac (the default host): a short answer.
        XCTAssertEqual(runDemo(app, prompt: "Translate: Bonjour.", timeout: 30), "Reply from Home Mac")
        // Running, on Office Mac: the FakeBridge holds it after it starts.
        newSession(app)
        let picker = app.buttons["composer.host"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.tap()
        app.buttons["Office Mac"].tap()
        send(app, "Compress yesterday's media")
        let status = app.descendants(matching: .any)["task.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(status.value as? String, "running")

        openAllTasks(app)
        XCTAssertEqual(app.staticTexts["page.title"].label, "所有任务")
        XCTAssertEqual(app.staticTexts["page.subtitle"].label, "2 台执行端")
        for id in ["waiting", "running", "done"] {
            XCTAssertTrue(app.descendants(matching: .any)["tasklist.\(id)"].waitForExistence(timeout: 10), id)
        }
        XCTAssertEqual(app.staticTexts["tasklist.waiting"].label, "等我处理")
        XCTAssertEqual(app.staticTexts["tasklist.running"].label, "正在跑")
        XCTAssertEqual(app.staticTexts["tasklist.done"].label, "已完成")
        XCTAssertEqual(app.staticTexts["tasklist.waiting.count"].label, "2")

        // 等我处理: one approval card for each host, with the tool, the command and the reason.
        let home = card(app, host: "Home Mac", reachability: "online")
        let office = card(app, host: "Office Mac", reachability: "online")
        XCTAssertEqual(home.staticTexts["approval.command"].label, Self.homeCommand)
        XCTAssertEqual(office.staticTexts["approval.path"].label, "reports/week45.md")
        XCTAssertTrue(home.buttons["approval.allow"].isEnabled)
        XCTAssertTrue(office.buttons["approval.deny"].isEnabled)
        XCTAssertFalse(app.descendants(matching: .any)["approval.offline"].exists)

        // 正在跑 and 已完成, each with its host; the short answer shows in the row.
        let running = rows(app).matching(NSPredicate(format: "value == 'running'")).firstMatch
        XCTAssertTrue(running.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(running.label.contains("Compress yesterday's media"), running.label)
        XCTAssertTrue(running.label.contains("Office Mac"), running.label)
        let done = rows(app).matching(NSPredicate(format: "value == 'completed'")).firstMatch
        XCTAssertTrue(done.label.contains("Translate: Bonjour."), done.label)
        XCTAssertTrue(done.label.contains("Home Mac"), done.label)
        XCTAssertTrue(done.label.contains("Reply from Home Mac"), done.label)
        saveShot("s15-all-tasks")

        // The tool arguments open in the card; a tap on a task title opens its session.
        home.buttons["approval.arguments"].tap()
        let arguments = home.staticTexts["approval.arguments.full"]
        XCTAssertTrue(arguments.waitForExistence(timeout: 5))
        XCTAssertTrue(arguments.label.contains("\"timeout\""), arguments.label)
        saveShot("s15-tool-arguments")
        home.buttons["tasklist.row"].tap()
        // The session opens with its approval sheet up (05).
        closeApprovalSheet(app)
        XCTAssertTrue(status.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(app.staticTexts["page.title"].label, Self.homeTask)
        XCTAssertEqual(status.value as? String, "waiting")
    }

    /// One approval waits on an offline host and one on an online host. The offline one has grey
    /// buttons and says that the host must reconnect first; the online one is approved from 所有任务.
    func testOfflineHostApprovalIsGreyAndTheOnlineOneIsApproved() {
        // First launch: both hosts online, both approvals reach the cache.
        var app = launch("approvals", reset: true)
        openAllTasks(app)
        _ = card(app, host: "Office Mac", reachability: "online")
        _ = card(app, host: "Home Mac", reachability: "online")
        settle()
        app.terminate()

        // Second launch: Office Mac is unreachable. Its approval comes from the cache.
        app = launch("approvals-office-offline", reset: false)
        openAllTasks(app)
        let banner = app.descendants(matching: .any)["alltasks.offlineHost"]
        XCTAssertTrue(banner.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(banner.value as? String, "Office Mac")
        XCTAssertTrue(banner.label.contains("Office Mac 离线"), banner.label)
        XCTAssertEqual(cards(app).count, 2)

        let office = card(app, host: "Office Mac", reachability: "offline")
        XCTAssertFalse(office.buttons["approval.allow"].isEnabled)
        XCTAssertFalse(office.buttons["approval.deny"].isEnabled)
        let reason = office.staticTexts["approval.offline"]
        XCTAssertTrue(reason.exists, office.debugDescription)
        XCTAssertTrue(reason.label.contains("Office Mac"), reason.label)
        XCTAssertTrue(reason.label.contains("重新连上"), reason.label)
        XCTAssertTrue(reason.label.contains("不会默认放行"), reason.label)

        let home = card(app, host: "Home Mac", reachability: "online")
        XCTAssertFalse(home.staticTexts["approval.offline"].exists)
        XCTAssertEqual(home.staticTexts["approval.command"].label, Self.homeCommand)
        XCTAssertTrue(home.buttons["approval.allow"].isEnabled)
        saveShot("s15-offline-approval")

        // Approve the online one. The card goes, and its task runs on to its answer.
        home.buttons["approval.allow"].tap()
        XCTAssertTrue(home.waitForNonExistence(timeout: 15), app.debugDescription)
        let done = rows(app).matching(NSPredicate(format: "label CONTAINS %@ AND value == 'completed'", Self.homeTask)).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(done.label.contains("Reply from Home Mac"), done.label)
        // The offline host's approval still waits, still grey.
        XCTAssertEqual(cards(app).count, 1)
        XCTAssertFalse(card(app, host: "Office Mac", reachability: "offline").buttons["approval.allow"].isEnabled)
        saveShot("s15-approved-online")
    }
}
