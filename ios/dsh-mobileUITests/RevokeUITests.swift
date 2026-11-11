import DSHCore
import XCTest

/// A host that revoked this phone. FakeBridge only,
/// with `FakeHosts` that close like the bridge: 4003 (device unknown) on this device's sockets
/// after a revoke, and 4003 on every reconnect. The test revokes this phone "from another
/// client" with the Darwin notification `hosts-revoke` (`FakeHostsSwitch`): the phone gets no
/// revoke response, only the close. The bug (2026-11-08): the host stayed in the drawer and
/// showed "connecting" every few seconds. Now the app forgets it and says so once.
/// The app runs in Chinese, like the design screens. scripts/demo/revoke.sh runs these.
@MainActor
final class RevokeUITests: XCTestCase {
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
        saveShot("revoke-revoked-notice")
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
        saveShot("revoke-drawer-without-revoked-host")
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
        saveShot("revoke-revoked-08")
    }
    /// Pairs with the real bridge of scripts/demo/revoke.sh (a fresh link per test) and waits for it.
    private func pairWithRealBridge(_ variable: String, adding: Bool = false) throws -> XCUIApplication {
        guard env[variable + "_FILE"] != nil || env[variable] != nil else {
            throw XCTSkip("needs a pairing link; run the enrollment or revocation demo")
        }
        let first = XCUIApplication()
        // The unpaired Debug fallback must not reach a real host (port 1 is closed).
        first.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-DSHMResetPairing", "YES",
                                 "-DSHMResetStore", "YES", "-DSHMBridgePort", "1"]
        if adding { first.launchArguments = [] }
        first.launch()
        let app: XCUIApplication
        if let path = env[variable + "_FILE"] {
            // Let simctl open the private link so XCTest logs only the file name.
            try Data().write(to: URL(fileURLWithPath: path + ".open"))
            let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let open = system.buttons.matching(NSPredicate(format: "label IN {'Open', '打开'}")).firstMatch
            if open.waitForExistence(timeout: 4) { open.tap() }
            app = XCUIApplication(bundleIdentifier: "chang.dsh-mobile")
        } else {
            let link = try XCTUnwrap(env[variable].flatMap(URL.init(string:)))
            app = openDeepLink(link)
        }
        let confirm = app.buttons["pairing.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15), app.debugDescription)
        confirm.tap()
        let status = app.descendants(matching: .any)["pairing.status"]
        XCTAssertEqual(waitForValue(status, in: ["paired", "failed"], timeout: 20), "paired", status.label)
        app.buttons["pairing.done"].tap()
        openDrawer(app)
        let expected = adding ? "2/2" : "1/1"
        XCTAssertEqual(waitForValue(any(app, "drawer.hosts").firstMatch, in: [expected], timeout: 30), expected, app.debugDescription)
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

    /// The hosts sheet path on a real bridge (scripts/dsh-up.mjs on its own ports, Noise): pair,
    /// revoke this device in X2. The bridge answers, then closes with 4003 and refuses the phone.
    func testRevokeThisDeviceInHostsSheetOnTheRealBridgeOpens08AndStays() throws {
        let app = try pairWithRealBridge("DSHM_REVOKE_PAIR_URL")
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
        saveShot("revoke-revoke-confirm")
        alert.buttons.matching(NSPredicate(format: "label == %@", "吊销")).firstMatch.tap()
        expect08AndStays(app, shot: "revoke-real-bridge-08")
    }

    /// The drawer's "Devices and audit" under the host (the devices view) can revoke this device too.
    /// Before the fix it only closed the view: the host stayed in the drawer and retried every
    /// few seconds (the reported bug). Now the close 4003 makes the app forget it.
    func testRevokeThisDeviceInDrawerDevicesOnTheRealBridgeOpens08AndStays() throws {
        let app = try pairWithRealBridge("DSHM_REVOKE_PAIR_URL_2")
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
        expect08AndStays(app, shot: "revoke-real-bridge-drawer-08")
    }
    func testEnrolledPhoneDispatchesAfterRelaunch() throws {
        let app = try pairWithRealBridge("DSHM_TLS_PAIR_URL")
        XCTAssertEqual(any(app, "host.channel").firstMatch.value as? String, "TLS 1.3")
        let first = runDemo(app, prompt: "TLS dispatch", timeout: 120)
        XCTAssertTrue(first.contains("streamed through the dsh-mobile bridge"))
        app.terminate()
        app.launch()
        openDrawer(app)
        XCTAssertEqual(waitForValue(any(app, "drawer.hosts").firstMatch, in: ["1/1"], timeout: 30), "1/1")
        XCTAssertTrue(runDemo(app, prompt: "TLS reconnect", timeout: 120).contains("streamed through the dsh-mobile bridge"))
        app.terminate()
    }

    func testUnreachableTLSHostRetainsPairingAndCachedTask() throws {
        try XCTSkipUnless(env["DSHM_TLS_UNAVAILABLE"] == "1", "run the TLS enrollment demo")
        let app = XCUIApplication()
        app.launch()
        openDrawer(app)
        XCTAssertEqual(waitForValue(any(app, "drawer.hosts").firstMatch, in: ["0/1"], timeout: 30), "0/1")
        XCTAssertEqual(waitForValue(any(app, "host.status").firstMatch, in: ["offline"], timeout: 30), "offline")
        let recent = app.buttons.matching(identifier: "drawer.session")
        XCTAssertEqual(recent.count, 2)
        recent.firstMatch.tap()
        let transcript = any(app, "transcript.text").firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 15))
        XCTAssertTrue((transcript.value as? String ?? "").contains("streamed through the dsh-mobile bridge"))
        app.terminate()
    }

    func testFreshEnrollmentRefusesUntrustedOrRedirectedPeer() async throws {
        guard let path = env["DSHM_REFUSED_OFFER_FILE"] else { throw XCTSkip("run the TLS enrollment demo") }
        let offer = try PairingOffer(string: String(contentsOfFile: path, encoding: .utf8))
        let store = InMemoryPairedHostStore()
        let pairing = Pairing(keys: KeychainDeviceKeyStore(), hosts: store, transport: WebSocketTransport.factory)
        do {
            _ = try await pairing.pair(offer)
            XCTFail("unexpected enrollment")
        } catch {
            XCTAssertTrue(store.load().isEmpty)
        }
    }

    func testEnrollSecondHostAndSyncItsTask() throws {
        let app = try pairWithRealBridge("DSHM_SECOND_PAIR_URL", adding: true)
        let rows = app.buttons.matching(identifier: "drawer.session")
        XCTAssertTrue(rows.element(boundBy: 2).waitForExistence(timeout: 30))
        XCTAssertEqual(rows.count, 3)
        app.terminate()
    }

    func testOfflineRevokedPhoneKeepsOtherHostOnLaunch() throws {
        try XCTSkipUnless(env["DSHM_TLS_OFFLINE_REVOKE"] == "1", "run the TLS enrollment demo")
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        dismissNotice(app)
        openDrawer(app)
        XCTAssertEqual(waitForValue(any(app, "drawer.hosts").firstMatch, in: ["1/1"], timeout: 30), "1/1")
        let rows = app.buttons.matching(identifier: "drawer.session")
        XCTAssertEqual(rows.count, 1)
        rows.firstMatch.tap()
        let transcript = any(app, "transcript.text").firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 15))
        XCTAssertTrue((transcript.value as? String ?? "").contains("streamed through the dsh-mobile bridge"))
        XCTAssertTrue(runDemo(app, prompt: "Only the surviving host", timeout: 120).contains("streamed through the dsh-mobile bridge"))
    }

}
