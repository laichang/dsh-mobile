import XCTest

/// A reconnect tries every saved address of a host (screen H). Real DSH and
/// bridge, Noise only (scripts/demo/reconnect.sh). The pairing link lists two addresses: first a
/// proxy that forwards one connection and then dies (DSHM_DEAD_PORT), then the bridge itself
/// (DSHM_BRIDGE_PORT). The app pairs through the proxy, so it saves the proxy first.
@MainActor
final class ReconnectUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private var bridgeAddress: String { "127.0.0.1:\(env["DSHM_BRIDGE_PORT"] ?? "47801")" }
    private var deadAddress: String { "127.0.0.1:\(env["DSHM_DEAD_PORT"] ?? "47830")" }

    /// Paired with a first address that is dead now: the host shows online through the second
    /// address, the hosts sheet names that address, and a task runs.
    func testDeadFirstAddressFallsThroughToTheSecond() throws {
        try XCTSkipUnless(env["DSHM_RECONNECT_PAIR_URL"] != nil, "needs a pairing link; run scripts/demo/reconnect.sh")
        let link = try XCTUnwrap(env["DSHM_RECONNECT_PAIR_URL"].flatMap(URL.init(string:)))
        let app = XCUIApplication()
        // The unpaired Debug fallback must not reach a real host (port 1 is closed).
        app.launchArguments = ["-DSHMResetPairing", "YES", "-DSHMResetStore", "YES", "-DSHMBridgePort", "1"]
        app.launch()

        let reopened = openDeepLink(link)
        let confirm = reopened.buttons["pairing.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15), reopened.debugDescription)
        confirm.tap()
        let status = reopened.descendants(matching: .any)["pairing.status"]
        XCTAssertEqual(waitForValue(status, in: ["paired", "failed"], timeout: 30), "paired", status.label)
        reopened.buttons["pairing.done"].tap()

        // The pairing used the proxy, which is dead now: the reconnect must use the bridge.
        openDrawer(reopened)
        let host = reopened.descendants(matching: .any)["host.status"]
        XCTAssertTrue(host.waitForExistence(timeout: 15), reopened.debugDescription)
        XCTAssertEqual(waitForValue(host, in: ["online"], timeout: 30), "online", host.label)

        let sheet = openHostsSheet(reopened)
        let row = reopened.descendants(matching: .any).matching(identifier: "hosts.row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), sheet.debugDescription)
        waitFor("value == 'online' AND label CONTAINS %@", bridgeAddress, row)
        XCTAssertFalse(row.label.contains(deadAddress), row.label)
        saveShot("reconnect-online-via-second")
        sheet.swipeDown(velocity: .fast)
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), reopened.debugDescription)

        let text = runDemo(reopened, prompt: "用一句话介绍你自己。#\(UUID().uuidString.prefix(6))", timeout: 120)
        // The local acceptance host uses DSH's mock LLM (scripts/dsh-up.mjs MOCK_TEXT).
        XCTAssertTrue(text.contains("streamed through the dsh-mobile bridge"), text)
        saveShot("reconnect-task-done")
    }

    /// DSH is stopped, so both saved addresses are dead: the hosts sheet shows the host offline,
    /// with the error of each address.
    func testAllAddressesDeadShowEachError() throws {
        try XCTSkipUnless(env["DSHM_RECONNECT_ALL_DEAD"] == "1", "needs a stopped host; run scripts/demo/reconnect.sh")
        let app = XCUIApplication()
        app.launchArguments = ["-DSHMBridgePort", "1"]
        app.launch()

        let sheet = openHostsSheet(app)
        let row = app.descendants(matching: .any).matching(identifier: "hosts.row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), sheet.debugDescription)
        waitFor("value == 'offline' AND label CONTAINS %@", bridgeAddress, row, timeout: 60)
        XCTAssertTrue(row.label.contains(deadAddress), row.label)
        XCTAssertTrue(row.label.contains("connection refused"), row.label)
        saveShot("reconnect-all-dead")
    }

    private func openHostsSheet(_ app: XCUIApplication) -> XCUIElement {
        openDrawer(app)
        let pill = app.descendants(matching: .any).matching(identifier: "drawer.hosts").firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 10), app.debugDescription)
        pill.tap()
        let sheet = app.descendants(matching: .any).matching(identifier: "hosts.sheet").firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), app.debugDescription)
        return sheet
    }

    private func waitFor(_ format: String, _ argument: String, _ element: XCUIElement, timeout: TimeInterval = 30,
                         file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: format, argument)
        let result = XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout)
        XCTAssertEqual(result, .completed, "\(predicate): \(element.debugDescription)", file: file, line: line)
    }
}
