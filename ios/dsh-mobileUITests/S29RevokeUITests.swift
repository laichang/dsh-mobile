import XCTest

/// S29 · a host that revoked this phone (PLAN.md §5 S29, ARCHITECTURE D59, D82). FakeBridge only,
/// with `FakeHosts` that close like the bridge: 4003 (device unknown) on this device's sockets
/// after a revoke, and 4003 on every reconnect. The test revokes this phone "from another
/// client" with the Darwin notification `hosts-revoke` (`FakeHostsSwitch`): the phone gets no
/// revoke response, only the close. The bug (2026-11-08): the host stayed in the drawer and
/// showed "connecting" every few seconds. Now the app forgets it and says so once.
/// The app runs in Chinese, like the design board. scripts/demo/s29.sh runs these.
@MainActor
final class S29RevokeUITests: XCTestCase {
    static let mac = "MacBook-Pro"
    static let office = "公司-PC"

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ variant: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-DSHMResetPairing", "YES",
                               "-DSHMResetStore", "YES", "-DSHMFakeBridge", variant]
        app.launch()
        return app
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: id)
    }

    private func hostHeader(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        any(app, "host.status").matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
    }

    private func revokeElsewhere() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName("chang.dsh-mobile.fake.hosts-revoke" as CFString), nil, nil, true)
    }

    /// The notice, once: "访问已被吊销 / MacBook-Pro 已吊销这台手机的访问…". 好 closes it.
    private func dismissNotice(_ app: XCUIApplication) {
        let notice = app.alerts["访问已被吊销"]
        XCTAssertTrue(notice.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(notice.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "\(Self.mac) 已吊销")).firstMatch.exists,
                      notice.debugDescription)
        saveShot("s29-revoked-notice")
        notice.buttons["好"].tap()
        XCTAssertTrue(notice.waitForNonExistence(timeout: 5))
    }

    /// Other hosts left: the app shows 01 with them. The revoked host is not in the drawer, and
    /// it does not come back as "connecting" (the bug: it retried every few seconds).
    func testRevokedHostLeavesTheDrawerAndIsNotRetried() {
        let app = launch("hosts")
        openDrawer(app)
        XCTAssertEqual(waitForValue(any(app, "drawer.hosts").firstMatch, in: ["2/3"], timeout: 20), "2/3")
        XCTAssertTrue(hostHeader(app, Self.mac).exists)

        // The drawer stays open: the host goes from it (before the fix it stayed, retrying).
        revokeElsewhere()
        XCTAssertTrue(hostHeader(app, Self.mac).waitForNonExistence(timeout: 15),
                      "the revoked host is still in the drawer: \(hostHeader(app, Self.mac).debugDescription)")
        dismissNotice(app)
        openDrawer(app)
        XCTAssertEqual(waitForValue(any(app, "drawer.hosts").firstMatch, in: ["1/2"], timeout: 10), "1/2",
                       app.debugDescription)
        XCTAssertTrue(hostHeader(app, Self.office).exists, app.debugDescription)
        // Watch it for longer than a few backoff rounds: it stays gone, with no loading or retry.
        for _ in 0..<8 {
            XCTAssertFalse(hostHeader(app, Self.mac).exists, app.debugDescription)
            XCTAssertFalse(app.alerts["访问已被吊销"].exists, "said once")
            Thread.sleep(forTimeInterval: 1)
        }
        saveShot("s29-drawer-without-revoked-host")
    }

    /// No host left: the app shows 08.
    func testRevokedLastHostOpens08() {
        let app = launch("hosts-one")
        openDrawer(app)
        XCTAssertEqual(waitForValue(any(app, "drawer.hosts").firstMatch, in: ["1/1"], timeout: 20), "1/1")
        closeDrawer(app)

        revokeElsewhere()
        dismissNotice(app)
        XCTAssertTrue(app.descendants(matching: .any)["firstRun.purpose"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.buttons["drawer.open"].exists)
        saveShot("s29-revoked-08")
    }
    /// Pairs with the real bridge of scripts/demo/s29.sh (a fresh link per test) and waits for it.
    private func pairWithRealBridge(_ variable: String) throws -> XCUIApplication {
        try XCTSkipUnless(env[variable] != nil, "needs a pairing link; run scripts/demo/s29.sh")
        let link = try XCTUnwrap(env[variable].flatMap(URL.init(string:)))
        let first = XCUIApplication()
        // The unpaired Debug fallback must not reach a real host (port 1 is closed).
        first.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-DSHMResetPairing", "YES",
                                 "-DSHMResetStore", "YES", "-DSHMBridgePort", "1"]
        first.launch()
        let app = openDeepLink(link)
        let confirm = app.buttons["pairing.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15), app.debugDescription)
        confirm.tap()
        let status = app.descendants(matching: .any)["pairing.status"]
        XCTAssertEqual(waitForValue(status, in: ["paired", "failed"], timeout: 20), "paired", status.label)
        app.buttons["pairing.done"].tap()
        openDrawer(app)
        XCTAssertEqual(waitForValue(any(app, "drawer.hosts").firstMatch, in: ["1/1"], timeout: 30), "1/1", app.debugDescription)
        return app
    }

    /// After the revoke: 08, and it stays (no retry brings the host back). The close 4003 can
    /// come before the response, or the revoke was not made from X2; then the app says so once.
    private func expect08AndStays(_ app: XCUIApplication, shot: String) {
        let notice = app.alerts["访问已被吊销"]
        if notice.waitForExistence(timeout: 5) { notice.buttons["好"].tap() }
        let welcome = app.descendants(matching: .any)["firstRun.purpose"]
        XCTAssertTrue(welcome.waitForExistence(timeout: 15), "the revoked host is still shown: \(app.debugDescription)")
        saveShot(shot)
        for _ in 0..<8 {
            XCTAssertTrue(welcome.exists, "left 08: \(app.debugDescription)")
            XCTAssertFalse(app.buttons["drawer.open"].exists)
            Thread.sleep(forTimeInterval: 1)
        }
    }

    /// The user (2026-11-08): the alert before a revoke of this device says that this device is
    /// removed and the host leaves the drawer, with nothing left to tap.
    private func expectRevokeThisDeviceMessage(_ alert: XCUIElement) {
        for part in ["这台手机会从", "移除", "侧边栏里不再有", "没有可点的入口", "不会再去连它"] {
            XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", part)).firstMatch.exists,
                          "the alert does not say \"\(part)\": \(alert.debugDescription)")
        }
    }

    /// The hosts sheet path on a real bridge (scripts/dsh-up.mjs on S29's ports, Noise): pair,
    /// revoke this device in X2. The bridge answers, then closes with 4003 and refuses the phone.
    func testRevokeThisDeviceInHostsSheetOnTheRealBridgeOpens08AndStays() throws {
        let app = try pairWithRealBridge("DSHM_S29_PAIR_URL")
        any(app, "drawer.hosts").firstMatch.tap()
        let row = any(app, "hosts.row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
        row.tap()
        let own = any(app, "device.current").firstMatch
        XCTAssertTrue(own.waitForExistence(timeout: 15), app.debugDescription)
        app.buttons["device.revoke.\(own.label)"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), app.debugDescription)
        expectRevokeThisDeviceMessage(alert)
        saveShot("s29-revoke-confirm")
        alert.buttons.matching(NSPredicate(format: "label == %@", "吊销")).firstMatch.tap()
        expect08AndStays(app, shot: "s29-real-bridge-08")
    }

    /// The drawer's "Devices and audit" under the host (S10's view) can revoke this device too.
    /// Before the fix it only closed the view: the host stayed in the drawer and retried every
    /// few seconds (the reported bug). Now the close 4003 makes the app forget it.
    func testRevokeThisDeviceInDrawerDevicesOnTheRealBridgeOpens08AndStays() throws {
        let app = try pairWithRealBridge("DSHM_S29_PAIR_URL_2")
        let manage = app.buttons["host.manage"]
        XCTAssertTrue(manage.waitForExistence(timeout: 15), app.debugDescription)
        manage.tap()
        let own = app.staticTexts["device.current"]
        XCTAssertTrue(own.waitForExistence(timeout: 15), app.debugDescription)
        app.buttons["device.revoke.\(own.label)"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), app.debugDescription)
        expectRevokeThisDeviceMessage(alert)
        alert.buttons.matching(NSPredicate(format: "label IN {'Revoke', '吊销'}")).firstMatch.tap()
        expect08AndStays(app, shot: "s29-real-bridge-drawer-08")
    }
}
