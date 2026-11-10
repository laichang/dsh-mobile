import XCTest

/// Hosts and control (screens H, X2, X3). FakeBridge only:
/// `-DSHMFakeBridge hosts` has MacBook-Pro (online, with a model catalog, devices and audit
/// records), hk-1 (its DSH is too old) and 公司-PC (a session waits on the user); `hosts-one` has
/// only MacBook-Pro.
/// The test stops and starts the hosts with Darwin notifications (`FakeHostsSwitch`): "down"
/// takes MacBook-Pro and 公司-PC offline, "up" brings MacBook-Pro back.
/// The app runs in Chinese, like the design screens. scripts/demo/hosts.sh runs these;
/// TEST_RUNNER_DSHM_SHOT_DIR keeps the screenshots.
@MainActor
final class HostsUITests: XCTestCase {
    static let mac = "MacBook-Pro"
    static let hk = "hk-1"
    static let office = "公司-PC"
    static let thisDevice = "dshm-a3f9c21e"
    static let otherDevice = "dshm-77b0e4d2"
    /// MacBook-Pro's default model (`FakeHosts.defaultModelName`).
    static let defaultModel = "DeepSeek-V41-Flash"

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

    private func element(_ app: XCUIApplication, _ id: String, containing text: String) -> XCUIElement {
        any(app, id).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName("chang.dsh-mobile.fake.\(name)" as CFString), nil, nil, true)
    }

    private func waitFor(_ format: String, _ element: XCUIElement, timeout: TimeInterval = 20,
                         file: StaticString = #filePath, line: UInt = #line) {
        let result = XCTWaiter().wait(for: [expectation(for: NSPredicate(format: format), evaluatedWith: element)], timeout: timeout)
        XCTAssertEqual(result, .completed, "\(format): \(element.debugDescription)", file: file, line: line)
    }

    /// Waits until the drawer's pill says `value` ("online/total"), then closes the drawer.
    private func waitForHostsOnline(_ app: XCUIApplication, _ value: String) {
        openDrawer(app)
        XCTAssertEqual(waitForValue(any(app, "drawer.hosts").firstMatch, in: [value], timeout: 20), value)
        closeDrawer(app)
    }

    private func openHostsSheet(_ app: XCUIApplication) -> XCUIElement {
        openDrawer(app)
        let pill = any(app, "drawer.hosts").firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        pill.tap()
        let sheet = any(app, "hosts.sheet").firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), app.debugDescription)
        return sheet
    }

    /// X3: with every host offline, 01 names each host and its last connection; the send key is
    /// off and history still opens. When one host is back, the card goes away.
    func testAllOfflineCardNamesEachHostAndGoesWhenOneIsBack() {
        let app = launch("hosts")
        waitForHostsOnline(app, "2/3")
        let card = any(app, "hosts.offlineCard").firstMatch
        XCTAssertFalse(card.exists)

        post("hosts-down")
        XCTAssertTrue(card.waitForExistence(timeout: 30), app.debugDescription)
        for name in [Self.mac, Self.office] {
            // "MacBook-Pro, 12秒钟前" (or 现在): the host and when it was last connected.
            let line = element(app, "hosts.offlineCard.host", containing: name)
            XCTAssertTrue(line.waitForExistence(timeout: 5), app.debugDescription)
            waitFor("value == 'offline' AND (label CONTAINS '前' OR label CONTAINS '现在')", line)
        }
        let hk = element(app, "hosts.offlineCard.host", containing: Self.hk)
        XCTAssertTrue(hk.exists)
        XCTAssertTrue(hk.label.contains("需要更新 DSH"), hk.label)

        type("整理 Q3 报表", into: app.textFields["composer.prompt"])
        let send = app.buttons["composer.send"]
        waitFor("isEnabled == false", send)
        saveShot("hosts-sheet-all-offline")

        // History still opens: the cached session of 公司-PC.
        openSession(app, "Install the printer driver")
        newSession(app)
        XCTAssertTrue(card.waitForExistence(timeout: 5))

        post("hosts-up")
        XCTAssertTrue(card.waitForNonExistence(timeout: 30), app.debugDescription)
        waitFor("isEnabled == true", send)
        saveShot("hosts-sheet-host-back")
    }

    /// H: the "2 / 3" pill opens the hosts sheet. Online with its channel; an unsupported DSH
    /// with the installed and supported versions; offline with its last connection and what
    /// waits on it.
    func testHostsSheetShowsEachHostsState() {
        let app = launch("hosts")
        waitForHostsOnline(app, "2/3")
        post("hosts-down")
        XCTAssertTrue(any(app, "hosts.offlineCard").firstMatch.waitForExistence(timeout: 30), app.debugDescription)
        post("hosts-up")
        waitForHostsOnline(app, "1/3")

        _ = openHostsSheet(app)
        XCTAssertEqual(waitForValue(any(app, "hosts.summary").firstMatch, in: ["1/3"], timeout: 10), "1/3")
        XCTAssertEqual(any(app, "hosts.row").count, 3)
        let mac = element(app, "hosts.row", containing: Self.mac)
        waitFor("value == 'online' AND label CONTAINS '加密'", mac)
        let hk = element(app, "hosts.row", containing: Self.hk)
        waitFor("value == 'bridgeUpdateRequired' AND label CONTAINS '0.8.2' AND label CONTAINS '0.9.x'", hk)
        XCTAssertTrue(hk.label.contains("更新前不能下新任务"), hk.label)
        let office = element(app, "hosts.row", containing: Self.office)
        waitFor("value == 'offline' AND label CONTAINS '最后连接' AND label CONTAINS '1 项在等它回来'", office)
        XCTAssertTrue(any(app, "hosts.pair").firstMatch.exists)
        saveShot("hosts-sheet-hosts-sheet")
    }

    /// H: an online host names its default model, as the host's catalog names it
    /// ("默认 DeepSeek-V41-Flash"). A host that sent no catalog shows no model.
    func testHostsSheetShowsTheDefaultModelOfTheCatalog() {
        let app = launch("hosts")
        waitForHostsOnline(app, "2/3")
        _ = openHostsSheet(app)
        let mac = element(app, "hosts.row", containing: Self.mac)
        waitFor("value == 'online' AND label CONTAINS '默认 \(Self.defaultModel)'", mac)
        let hk = element(app, "hosts.row", containing: Self.hk)
        XCTAssertTrue(hk.exists, app.debugDescription)
        XCTAssertFalse(hk.label.contains("默认"), hk.label)
        saveShot("hosts-sheet-hosts-default-model")
    }

    /// X2: one host's devices (this device is marked) and audit records with "load older".
    /// A revoke of another device asks first; a revoke of this device asks, then opens 08.
    func testRevokeThisDeviceAsksThenOpens08() {
        let app = launch("hosts-one")
        waitForHostsOnline(app, "1/1")
        _ = openHostsSheet(app)
        let row = element(app, "hosts.row", containing: Self.mac)
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
        row.tap()
        XCTAssertTrue(any(app, "host.detail").firstMatch.waitForExistence(timeout: 10), app.debugDescription)

        let own = any(app, "device.current").firstMatch
        XCTAssertTrue(own.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(own.label, Self.thisDevice)
        XCTAssertTrue(any(app, "device.id.\(Self.otherDevice)").firstMatch.exists)
        XCTAssertTrue(any(app, "audit.Approval allowed").firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(any(app, "audit.Approval denied").firstMatch.exists)
        XCTAssertFalse(any(app, "audit.Device revoked").firstMatch.exists)
        saveShot("hosts-sheet-host-detail")
        let older = app.buttons["audit.loadOlder"]
        XCTAssertTrue(older.exists)
        older.tap()
        let revokedRecord = element(app, "audit.Device revoked", containing: "dshm-1c0045aa")
        XCTAssertTrue(revokedRecord.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(older.waitForNonExistence(timeout: 5))

        // Another device: confirm, and it goes from the list.
        app.buttons["device.revoke.\(Self.otherDevice)"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), app.debugDescription)
        alert.buttons.matching(NSPredicate(format: "label == %@", "吊销")).firstMatch.tap()
        XCTAssertTrue(any(app, "device.id.\(Self.otherDevice)").firstMatch.waitForNonExistence(timeout: 10))
        XCTAssertTrue(element(app, "audit.Device revoked", containing: Self.otherDevice).waitForExistence(timeout: 10))

        // This device: the alert says what it means, Cancel keeps it, Revoke opens 08.
        app.buttons["device.revoke.\(Self.thisDevice)"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(alert.staticTexts["吊销这台设备？"].exists, alert.debugDescription)
        saveShot("hosts-sheet-revoke-confirm")
        alert.buttons.matching(NSPredicate(format: "label == %@", "取消")).firstMatch.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        XCTAssertTrue(own.exists)
        app.buttons["device.revoke.\(Self.thisDevice)"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5), app.debugDescription)
        alert.buttons.matching(NSPredicate(format: "label == %@", "吊销")).firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["firstRun.purpose"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.buttons["drawer.open"].exists)
        saveShot("hosts-sheet-revoked-08")
    }
}
