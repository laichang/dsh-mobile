import XCTest

@MainActor
final class S10DevicesUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    // The companion CLI device dispatches a held request over Noise. The demo script then
    // attempts IK with its original key and requires the real bridge's device-unknown refusal.
    func testAuditAndRevokeAnotherPairedDevice() throws {
        try XCTSkipUnless(env["DSHM_S10_PEER"] != nil, "run scripts/demo/s10.sh")
        let peer = try XCTUnwrap(env["DSHM_S10_PEER"])
        let link = try XCTUnwrap(env["DSHM_PAIR_URL"].flatMap(URL.init(string:)))
        let original = XCUIApplication()
        // The unpaired Debug fallback must not cache this real host under its loopback identity.
        original.launchArguments = ["-DSHMResetPairing", "YES", "-DSHMResetStore", "YES",
                                    "-DSHMBridgePort", "1"]
        original.launch()
        openDrawer(original)
        XCTAssertTrue(original.descendants(matching: .any)["host.channel"].waitForExistence(timeout: 15))
        XCTAssertFalse(original.buttons["host.manage"].exists)
        let app = openDeepLink(link)
        app.buttons["pairing.confirm"].tap()
        let paired = app.descendants(matching: .any)["pairing.status"]
        XCTAssertEqual(waitForValue(paired, in: ["paired", "failed"], timeout: 20), "paired")
        app.buttons["pairing.done"].tap()
        openAllTasks(app)
        let deny = app.buttons["approval.deny"].firstMatch
        XCTAssertTrue(deny.waitForExistence(timeout: 30), app.debugDescription)
        deny.tap()
        XCTAssertTrue(deny.waitForNonExistence(timeout: 15))
        openDrawer(app)
        let manage = app.buttons["host.manage"]
        XCTAssertTrue(manage.waitForExistence(timeout: 10))
        manage.tap()
        let own = app.staticTexts["device.current"]
        XCTAssertTrue(own.waitForExistence(timeout: 10))
        let ownerID = own.label
        XCTAssertNotEqual(ownerID, peer)
        saveShot("s10-devices")
        app.buttons["devices.audit"].tap()
        let approval = app.descendants(matching: .any)["audit.Approval denied"].firstMatch
        XCTAssertTrue(approval.waitForExistence(timeout: 10))
        XCTAssertTrue(approval.label.contains(ownerID), approval.label)
        XCTAssertTrue(approval.label.contains("owner"), approval.label)
        XCTAssertTrue(approval.label.contains(try XCTUnwrap(env["DSHM_S4_COMMAND"])), approval.label)
        let record = app.descendants(matching: .any).matching(identifier: "audit.Device paired")
            .matching(NSPredicate(format: "label CONTAINS %@", peer)).firstMatch
        XCTAssertTrue(record.exists)
        XCTAssertTrue(record.label.contains("owner"), record.label)
        let year = Calendar(identifier: .gregorian).component(.year, from: .now)
        XCTAssertTrue(record.label.contains(String(year)), record.label)
        XCTAssertNotNil(record.label.range(of: #"[0-9]{1,2}:[0-9]{2}"#, options: .regularExpression), record.label)
        saveShot("s10-audit")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let revoke = app.buttons["device.revoke.\(peer)"]
        XCTAssertTrue(revoke.waitForExistence(timeout: 10))
        revoke.tap()
        app.alerts.buttons["Revoke"].tap()
        XCTAssertTrue(revoke.waitForNonExistence(timeout: 15))
        XCTAssertTrue(own.exists)
        app.buttons["devices.audit"].tap()
        let revoked = app.descendants(matching: .any)["audit.Device revoked"].firstMatch
        XCTAssertTrue(revoked.waitForExistence(timeout: 10))
        XCTAssertTrue(revoked.label.contains(peer) && revoked.label.contains(ownerID), revoked.label)
        saveShot("s10-revoked")
    }
}
