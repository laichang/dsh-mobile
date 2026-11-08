import XCTest

/// Why a host is offline, on real DSH (screens H and X3, ARCHITECTURE D125;
/// scripts/demo/bridge-errors.sh). The app pairs with the bridge on DSHM_BRIDGE_PORT. Then the
/// script restarts DSH while another program (an HTTP server) holds that port, so the bridge
/// cannot listen: the hosts sheet and the offline card say that another program uses the port.
/// Then the script stops that program: nothing listens on the port any more.
@MainActor
final class OfflineReasonsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private var port: String { env["DSHM_BRIDGE_PORT"] ?? "47801" }
    private var address: String { "127.0.0.1:\(port)" }
    /// Chinese, as the user's phone: the reasons are matched in the words the user reads.
    private let language = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]

    /// Pairs with the bridge while it listens, and sees the host online.
    func testPairWhileTheBridgeListens() throws {
        try XCTSkipUnless(env["DSHM_BRIDGE_ERRORS_PAIR_URL"] != nil, "needs a pairing link; run scripts/demo/bridge-errors.sh")
        let link = try XCTUnwrap(env["DSHM_BRIDGE_ERRORS_PAIR_URL"].flatMap(URL.init(string:)))
        let app = XCUIApplication()
        // The unpaired Debug fallback must not reach a real host (port 1 is closed).
        app.launchArguments = language + ["-DSHMResetPairing", "YES", "-DSHMResetStore", "YES", "-DSHMBridgePort", "1"]
        app.launch()

        let reopened = openDeepLink(link)
        let confirm = reopened.buttons["pairing.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15), reopened.debugDescription)
        confirm.tap()
        let status = reopened.descendants(matching: .any)["pairing.status"]
        XCTAssertEqual(waitForValue(status, in: ["paired", "failed"], timeout: 30), "paired", status.label)
        reopened.buttons["pairing.done"].tap()

        openDrawer(reopened)
        let host = reopened.descendants(matching: .any)["host.status"]
        XCTAssertTrue(host.waitForExistence(timeout: 15), reopened.debugDescription)
        XCTAssertEqual(waitForValue(host, in: ["online"], timeout: 30), "online", host.label)
    }

    /// Another program holds the bridge port: the host row says so, with the fix, and so does the
    /// offline card of a new session.
    func testAnotherProgramOnTheBridgePort() throws {
        try XCTSkipUnless(env["DSHM_BRIDGE_ERRORS_STEP"] == "taken", "needs the port taken; run scripts/demo/bridge-errors.sh")
        let app = launch()

        let row = hostRow(app)
        waitFor("value == 'offline' AND label CONTAINS %@", "另一个程序占用了这个端口", row, timeout: 60)
        XCTAssertTrue(row.label.contains(address), row.label)
        XCTAssertTrue(row.label.contains("换个端口"), row.label) // the fix
        saveShot("bridge-errors-hosts-taken")
        closeHostsSheet(app)

        let line = offlineCardLine(app)
        waitFor("label CONTAINS %@", "另一个程序占用了端口 \(port)", line)
        saveShot("bridge-errors-offline-card-taken")
    }

    /// The other program stopped; the bridge did not start again: nothing listens on the port.
    func testNothingListensOnTheBridgePort() throws {
        try XCTSkipUnless(env["DSHM_BRIDGE_ERRORS_STEP"] == "free", "needs a free port; run scripts/demo/bridge-errors.sh")
        let app = launch()

        let row = hostRow(app)
        waitFor("value == 'offline' AND label CONTAINS %@", "没有程序在这个端口上监听", row, timeout: 60)
        XCTAssertTrue(row.label.contains(address), row.label)
        XCTAssertFalse(row.label.contains("另一个程序"), row.label)
        saveShot("bridge-errors-hosts-nothing")
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = language + ["-DSHMBridgePort", "1"]
        app.launch()
        return app
    }

    private func hostRow(_ app: XCUIApplication) -> XCUIElement {
        openDrawer(app)
        let pill = app.descendants(matching: .any).matching(identifier: "drawer.hosts").firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 10), app.debugDescription)
        pill.tap()
        let sheet = app.descendants(matching: .any).matching(identifier: "hosts.sheet").firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), app.debugDescription)
        let row = app.descendants(matching: .any).matching(identifier: "hosts.row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), sheet.debugDescription)
        return row
    }

    private func closeHostsSheet(_ app: XCUIApplication) {
        let sheet = app.descendants(matching: .any).matching(identifier: "hosts.sheet").firstMatch
        sheet.swipeDown(velocity: .fast)
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), app.debugDescription)
    }

    /// The host's line on the offline card (X3) of a new session.
    private func offlineCardLine(_ app: XCUIApplication) -> XCUIElement {
        newSession(app)
        closeDrawer(app)
        let card = app.descendants(matching: .any).matching(identifier: "hosts.offlineCard").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30), app.debugDescription)
        let line = app.descendants(matching: .any).matching(identifier: "hosts.offlineCard.host").firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 10), card.debugDescription)
        return line
    }

    private func waitFor(_ format: String, _ argument: String, _ element: XCUIElement, timeout: TimeInterval = 30,
                         file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: format, argument)
        let result = XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout)
        XCTAssertEqual(result, .completed, "\(predicate): \(element.debugDescription)", file: file, line: line)
    }
}
