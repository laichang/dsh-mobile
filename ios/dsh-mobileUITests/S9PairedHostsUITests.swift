import XCTest

@MainActor
final class S9PairedHostsUITests: XCTestCase {
    func testPairedDevicesAndInlineAnswersStayWithTheirHost() throws {
        try XCTSkipUnless(env["DSHM_S9_PEER"] != nil, "run scripts/demo/s9.sh")
        let peer = try XCTUnwrap(env["DSHM_S9_PEER"])
        let app = XCUIApplication()
        app.launchArguments = ["-DSHMResetPairing", "YES", "-DSHMResetStore", "YES", "-DSHMBridgePort", "1"]
        app.launch()
        for index in 0...1 {
            let offer = try XCTUnwrap(env["DSHM_S9_OFFER_\(index)"].flatMap(URL.init(string:)))
            let pairing = openDeepLink(offer)
            pairing.buttons["pairing.confirm"].tap()
            let status = pairing.descendants(matching: .any)["pairing.status"]
            XCTAssertEqual(waitForValue(status, in: ["paired", "failed"], timeout: 20), "paired", status.label)
            pairing.buttons["pairing.done"].tap()
        }
        var currentDevice: String?
        for index in 0...1 {
            let port = try XCTUnwrap(env["DSHM_S9_PORT_\(index)"])
            // The two distinct Noise keys have the same system hostname; their endpoints distinguish them.
            let manage = app.buttons.matching(identifier: "host.manage")
                .matching(NSPredicate(format: "label ENDSWITH %@", ":\(port))")).firstMatch
            XCTAssertTrue(manage.waitForExistence(timeout: 15), app.debugDescription)
            let hostName = String(manage.label.dropFirst("Devices and audit on ".count))
            manage.tap()
            let current = app.staticTexts["device.current"]
            XCTAssertTrue(current.waitForExistence(timeout: 10))
            if let currentDevice { XCTAssertEqual(current.label, currentDevice) }
            currentDevice = current.label
            XCTAssertEqual(app.staticTexts["device.id.\(peer)"].exists, index == 0)
            app.navigationBars.buttons.element(boundBy: 0).tap()

            let picker = app.buttons["composer.host"]
            if index == 1 {
                picker.tap()
                app.buttons[hostName].tap()
            }
            XCTAssertTrue(picker.label.contains(hostName), picker.debugDescription)
            let prompt = "Say hello on \(index)"
            let input = app.textFields["composer.prompt"]
            input.tap()
            input.typeText(prompt)
            app.buttons["composer.send"].tap()
            let row = app.buttons.matching(identifier: "tasklist.row")
                .matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", prompt, "Hello from host \(index).")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 15), app.debugDescription)
            XCTAssertEqual(row.value as? String, "completed")
            RunLoop.current.run(until: .now.addingTimeInterval(2.2))
            XCTAssertTrue(input.exists)
            XCTAssertFalse(app.descendants(matching: .any)["task.status"].exists)
        }
        saveShot("s9-paired-inline")
    }
}
