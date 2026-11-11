import XCTest

/// Pair again after a revoke. The bug
/// (2026-11-08, real iPhone): the user had revoked this phone; 08 asked to pair again; they
/// scanned a fresh QR from the same Mac, pairing succeeded, and then the root showed "Couldn't
/// open your paired computers". The app kept the forgotten host's key (`noise:<host id>`, from
/// the host key) in memory and dropped the same Mac from the new store.
/// Real DSH + bridge (scripts/dsh-up.mjs on its own ports, TLS). scripts/demo/pair-again.sh runs it
/// with three fresh pairing links. The app runs in Chinese, like the design screens.
@MainActor
final class PairAgainUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: id)
    }

    private func link(_ variable: String) throws -> URL {
        try XCTSkipUnless(env[variable] != nil, "needs a pairing link; run scripts/demo/pair-again.sh")
        return try XCTUnwrap(env[variable].flatMap(URL.init(string:)))
    }

    /// Opens a pairing link in the running app, pairs, and expects the drawer with one host.
    private func pair(_ url: URL, shot: String? = nil) -> XCUIApplication {
        let app = openDeepLink(url)
        let confirm = app.buttons["pairing.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15), app.debugDescription)
        confirm.tap()
        let status = app.descendants(matching: .any)["pairing.status"]
        XCTAssertEqual(waitForValue(status, in: ["paired", "failed"], timeout: 20), "paired", status.label)
        app.buttons["pairing.done"].tap()
        // The bug: here the root showed the error screen, with no drawer.
        let drawer = app.buttons["drawer.open"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 15), "no drawer after pairing again: \(app.debugDescription)")
        if let shot { saveShot(shot) }
        openDrawer(app)
        XCTAssertEqual(waitForValue(any(app, "drawer.hosts").firstMatch, in: ["1/1"], timeout: 30), "1/1", app.debugDescription)
        return app
    }

    /// Revokes this device in X2 (the hosts sheet) and expects 08. The drawer is open.
    private func revokeThisDevice(_ app: XCUIApplication, shot: String? = nil) {
        any(app, "drawer.hosts").firstMatch.tap()
        let row = any(app, "hosts.row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
        row.tap()
        let own = any(app, "device.current").firstMatch
        XCTAssertTrue(own.waitForExistence(timeout: 15), app.debugDescription)
        app.buttons["device.revoke.\(own.label)"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), app.debugDescription)
        alert.buttons.matching(NSPredicate(format: "label == %@", "吊销")).firstMatch.tap()
        let notice = app.alerts["访问已被吊销"]
        if notice.waitForExistence(timeout: 5) { notice.buttons["好"].tap() }
        let welcome = app.descendants(matching: .any)["firstRun.purpose"]
        XCTAssertTrue(welcome.waitForExistence(timeout: 15), "no 08 after the revoke: \(app.debugDescription)")
        if let shot { saveShot(shot) }
    }

    /// The user's path: pair, revoke this phone, 08, pair the same Mac again: the drawer shows
    /// it. Then a second revoke still opens 08 (the app does not ignore the host's key).
    func testPairTheSameHostAgainAfterARevokeOpensTheDrawer() throws {
        let urls = try ["DSHM_PAIR_AGAIN_URL", "DSHM_PAIR_AGAIN_URL_2", "DSHM_PAIR_AGAIN_URL_3"].map(link)
        let first = XCUIApplication()
        // The unpaired Debug fallback must not reach a real host (port 1 is closed).
        first.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-DSHMResetPairing", "YES",
                                 "-DSHMResetStore", "YES", "-DSHMBridgePort", "1"]
        first.launch()

        var app = pair(urls[0])
        revokeThisDevice(app, shot: "pair-again-revoked-08")
        app = pair(urls[1], shot: "pair-again-paired-again")
        saveShot("pair-again-paired-again-drawer")
        XCTAssertFalse(app.staticTexts["无法打开已配对的电脑"].exists, app.debugDescription)
        XCTAssertFalse(app.staticTexts["Couldn't open your paired computers"].exists, app.debugDescription)

        // Revoked again: the app forgets the host again and shows 08; pairing a third time works.
        revokeThisDevice(app)
        _ = pair(urls[2])
    }
}
