import XCTest

/// The workspace drawer (screen 02). The FakeBridge tests use
/// `-DSHMFakeBridge drawer…` (`FakeDrawer`: MacBook-Pro and Office-PC with sessions in
/// workspaces). `testWebAndPhoneSessionsShareAWorkspaceWithRealDSH` needs scripts/demo/drawer-web.mjs
/// (real DSH Web + the bridge); scripts/demo/drawer.sh runs all of them.
@MainActor
final class DrawerUITests: XCTestCase {
    static let mac = "MacBook-Pro"
    static let office = "Office-PC"

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ variant: String, reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-DSHMResetPairing", "YES",
                               "-DSHMFakeBridge", variant]
        if reset { app.launchArguments += ["-DSHMResetStore", "YES"] }
        app.launch()
        return app
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: id)
    }

    private func row(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(identifier: "drawer.session").matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    }

    private func mark(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        any(app, "drawer.session.mark").matching(NSPredicate(format: "label == %@", title)).firstMatch
    }

    private func workspace(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        any(app, "drawer.workspace").matching(NSPredicate(format: "label == %@", name)).firstMatch
    }

    private func host(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        any(app, "host.status").matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
    }

    /// Waits for the accessibility value: under load, one read can return a stale snapshot.
    private func expectValue(_ element: XCUIElement, _ value: String, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(waitForValue(element, in: [value], timeout: 10), value, message, file: file, line: line)
    }

    /// Asserts that the elements are in this order from top to bottom.
    private func assertOrder(_ elements: [XCUIElement], file: StaticString = #filePath, line: UInt = #line) {
        for (upper, lower) in zip(elements, elements.dropFirst()) {
            XCTAssertLessThan(upper.frame.midY, lower.frame.midY, "\(upper) above \(lower)", file: file, line: line)
        }
    }

    /// host › workspace › session, and the three marks: amber = waiting on you, spinner =
    /// running, blue = done and not read. Opening a session clears its blue dot.
    func testDrawerGroupsByHostAndWorkspaceWithStatusMarks() {
        let app = launch("drawer")
        openDrawer(app)
        XCTAssertTrue(workspace(app, "Q3").waitForExistence(timeout: 10), app.debugDescription)
        waitForValue(any(app, "drawer.hosts").firstMatch, in: ["2/2"], timeout: 10)
        expectValue(workspace(app, "Q3"), "/Users/laichang/Desktop/Q3")
        assertOrder([
            host(app, Self.mac), workspace(app, "Q3"),
            row(app, "整理 Q3 报表成 PPT"), row(app, "Q3 summary slides"), row(app, "网页第一条"),
            workspace(app, "dsh-mobile"), row(app, "修复 CI 挂掉的测试并提 PR"),
            host(app, Self.office), workspace(app, "office"),
            row(app, "Install the printer driver"), row(app, "Weekly report"),
        ])
        XCTAssertEqual(any(app, "drawer.workspace").count, 3)
        expectValue(mark(app, "整理 Q3 报表成 PPT"), "waiting")
        expectValue(mark(app, "修复 CI 挂掉的测试并提 PR"), "running")
        expectValue(mark(app, "Q3 summary slides"), "unread")
        expectValue(mark(app, "网页第一条"), "unread")
        // A mark sits at the end of its own row.
        let slides = row(app, "Q3 summary slides")
        XCTAssertEqual(mark(app, "Q3 summary slides").frame.midY, slides.frame.midY, accuracy: 2)
        saveShot("drawer-drawer")

        // Read on this phone: the blue dot goes; the others stay.
        slides.tap()
        XCTAssertTrue(any(app, "task.status").firstMatch.waitForExistence(timeout: 5))
        openDrawer(app)
        waitForValue(mark(app, "Q3 summary slides"), in: ["read"], timeout: 5)
        expectValue(mark(app, "网页第一条"), "unread")
        expectValue(mark(app, "整理 Q3 报表成 PPT"), "waiting")
        saveShot("drawer-drawer-read")
    }

    /// The amber badge on the drawer button counts the items in 等我处理 (所有任务), across hosts.
    func testBadgeCountMatchesWaitingOnMe() {
        let app = launch("drawer")
        let badge = any(app, "drawer.badge").firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 10), app.debugDescription)
        waitForValue(badge, in: ["2"], timeout: 10)
        saveShot("drawer-badge")
        openAllTasks(app)
        let waiting = app.buttons.matching(identifier: "tasklist.row").matching(NSPredicate(format: "value == 'waitingOnUser'"))
        XCTAssertTrue(waiting.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(waiting.count, Int(badge.value as? String ?? ""), app.debugDescription)
        XCTAssertTrue(any(app, "tasklist.waiting").firstMatch.exists)
    }

    /// An offline host is grey and named; its sessions open from the cache.
    func testOfflineHostSessionsOpenFromTheCache() {
        var app = launch("drawer")
        openDrawer(app)
        XCTAssertTrue(mark(app, "Weekly report").waitForExistence(timeout: 10), app.debugDescription)
        app.terminate()

        app = launch("drawer-office-offline", reset: false)
        openDrawer(app)
        let office = host(app, Self.office)
        XCTAssertTrue(office.waitForExistence(timeout: 10), app.debugDescription)
        waitForValue(office, in: ["offline"], timeout: 15)
        // Wait for the label with a predicate: under load, one read of `label` can return a stale snapshot.
        let named = any(app, "host.status").matching(NSPredicate(format: "label BEGINSWITH %@", "\(Self.office) is offline")).firstMatch
        XCTAssertTrue(named.waitForExistence(timeout: 15), office.debugDescription)
        waitForValue(any(app, "drawer.hosts").firstMatch, in: ["1/2"], timeout: 10)
        XCTAssertTrue(workspace(app, "office").exists)
        assertOrder([office, workspace(app, "office"), row(app, "Install the printer driver"), row(app, "Weekly report")])
        saveShot("drawer-offline-host")

        row(app, "Weekly report").tap()
        XCTAssertTrue(any(app, "task.status").firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        let title = app.staticTexts["page.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(identifier: "page.title").matching(NSPredicate(format: "label == %@", "Weekly report")).firstMatch.waitForExistence(timeout: 10), title.label)
        XCTAssertFalse(app.otherElements["drawer"].exists)
    }

    /// An older bridge (no `drawer.v1`) sends no workspaces: the drawer shows host › session.
    func testWithoutDrawerCapabilityShowsHostAndSession() {
        let app = launch("drawer-v0")
        openDrawer(app)
        XCTAssertTrue(row(app, "Weekly report").waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(row(app, "Q3 summary slides").exists)
        XCTAssertEqual(any(app, "drawer.workspace").count, 0)
        assertOrder([host(app, Self.mac), row(app, "整理 Q3 报表成 PPT"), row(app, "修复 CI 挂掉的测试并提 PR"),
                     host(app, Self.office), row(app, "Install the printer driver")])
        expectValue(mark(app, "修复 CI 挂掉的测试并提 PR"), "running")
        saveShot("drawer-no-capability")
    }

    /// Real DSH: a Web session and a phone session in the same workspace show under that workspace.
    func testWebAndPhoneSessionsShareAWorkspaceWithRealDSH() throws {
        let signals = URL(fileURLWithPath: try XCTUnwrap(env["DSHM_DRAWER_SIGNALS"], "run scripts/demo/drawer.sh"))
        let port = try String(contentsOf: signals.appendingPathComponent("bridge-port"), encoding: .utf8)
        let path = try String(contentsOf: signals.appendingPathComponent("workspace"), encoding: .utf8)
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                               "-DSHMBridgePort", port, "-DSHMResetStore", "YES", "-DSHMResetPairing", "YES"]
        app.launch()

        // The phone picks the workspace of the Web session, then sends its own task there.
        let open = app.buttons["workspace.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 20), app.debugDescription)
        open.tap()
        let recent = app.buttons["workspace.option." + path]
        XCTAssertTrue(recent.waitForExistence(timeout: 15), app.debugDescription)
        recent.tap()
        _ = runDemo(app, prompt: "手机会话", timeout: 60)

        openDrawer(app)
        let web = row(app, "网页会话")
        XCTAssertTrue(web.waitForExistence(timeout: 30), app.debugDescription)
        let folder = any(app, "drawer.workspace").matching(NSPredicate(format: "value == %@", path)).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(any(app, "drawer.workspace").count, 1, app.debugDescription)
        assertOrder([any(app, "host.status").firstMatch, folder, row(app, "手机会话"), web])
        expectValue(mark(app, "网页会话"), "unread")
        expectValue(mark(app, "手机会话"), "read", "the phone showed its own reply")
        saveShot("drawer-web-and-phone")
        try Data().write(to: signals.appendingPathComponent("verified"))
    }
}
