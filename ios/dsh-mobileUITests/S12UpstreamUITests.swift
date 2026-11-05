import XCTest

@MainActor
final class S12UpstreamUITests: XCTestCase {
    func testUnsupportedHostDisplaysBridgeUpdateAndKeepsPrompt() throws {
        let port = try XCTUnwrap(env["DSHM_BRIDGE_PORT"])
        let app = XCUIApplication()
        app.launchArguments = ["-DSHMBridgePort", port, "-DSHMResetPairing", "YES", "-DSHMResetStore", "YES",
                               "-DSHMPresetPrompt", "Keep this task for after the update"]
        app.launch()
        let host = app.descendants(matching: .any)["host.status"]
        waitForValue(host, in: ["bridgeUpdateRequired"], timeout: 20)
        XCTAssertTrue(host.label.contains("needs a bridge update"))
        XCTAssertTrue(host.label.contains("0.2.2-alpha.3"))
        XCTAssertTrue(host.label.contains("0.2.2-rc.1"))
        app.buttons["composer.send"].tap()
        XCTAssertEqual(app.textFields["composer.prompt"].value as? String, "Keep this task for after the update")
        XCTAssertFalse(app.descendants(matching: .any)["task.status"].exists)
        saveShot("s12-update-required")
    }
}
