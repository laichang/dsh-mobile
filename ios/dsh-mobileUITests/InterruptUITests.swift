import XCTest

@MainActor
final class InterruptUITests: XCTestCase {
    func testInterruptLongRunningTask() throws {
        try XCTSkipUnless(env["DSHM_REAL_DSH"] == "1", "run scripts/demo/interrupt.sh with the slow DSH host")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-DSHMBridgePort", env["DSHM_BRIDGE_PORT"] ?? "47811",
                               "-DSHMResetPairing", "YES", "-DSHMResetStore", "YES",
                               "-DSHMPresetPrompt", "Stream a long reply"]
        app.launch()
        app.buttons["composer.send"].tap()
        let transcript = app.descendants(matching: .any)["transcript.text"]
        wait(for: [expectation(for: NSPredicate(format: "value != '' AND exists == true"), evaluatedWith: transcript)], timeout: 20)
        let stop = app.buttons["task.interrupt"]
        XCTAssertTrue(stop.waitForExistence(timeout: 3))
        stop.tap()
        let status = app.descendants(matching: .any)["task.status"]
        waitForValue(status, in: ["interrupted"], timeout: 4)
        XCTAssertFalse(stop.exists)
        XCTAssertFalse((transcript.value as? String ?? "").contains("through the dsh-mobile bridge."))
        saveShot("interrupt-interrupted-detail")
        openAllTasks(app)
        let row = app.buttons.matching(identifier: "tasklist.row").matching(NSPredicate(format: "value == 'interrupted'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 4), app.debugDescription)
        XCTAssertTrue(row.label.contains("Interrupted"), row.label)

        app.terminate()
        app.launchArguments = ["-DSHMBridgePort", env["DSHM_BRIDGE_PORT"] ?? "47811", "-DSHMConnectDelay", "10"]
        app.launch()
        openAllTasks(app)
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()
        waitForValue(status, in: ["interrupted"], timeout: 4)
        let milestone = app.descendants(matching: .any)["milestone.card"]
        XCTAssertEqual(milestone.label, "Interrupted")
    }
}
