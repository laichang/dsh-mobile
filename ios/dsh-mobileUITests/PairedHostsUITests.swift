import XCTest

@MainActor
final class PairedHostsUITests: XCTestCase {
    func testPairedDevicesAndInlineAnswersStayWithTheirHost() throws {
        try XCTSkipUnless(env["DSHM_MULTIHOST_PEER"] != nil, "run scripts/demo/multi-host.sh")
        let peer = try XCTUnwrap(env["DSHM_MULTIHOST_PEER"])
        let app = XCUIApplication()
        app.launchArguments = ["-DSHMResetPairing", "YES", "-DSHMResetStore", "YES", "-DSHMBridgePort", "1"]
        app.launch()
        for index in 0...1 {
            let offer = try XCTUnwrap(env["DSHM_MULTIHOST_OFFER_\(index)"].flatMap(URL.init(string:)))
            let pairing = openDeepLink(offer)
            pairing.buttons["pairing.confirm"].tap()
            let status = pairing.descendants(matching: .any)["pairing.status"]
            XCTAssertEqual(waitForValue(status, in: ["paired", "failed"], timeout: 20), "paired", status.label)
            pairing.buttons["pairing.done"].tap()
        }
        var currentDevice: String?
        for index in 0...1 {
            let port = try XCTUnwrap(env["DSHM_MULTIHOST_PORT_\(index)"])
            // The two distinct Noise keys have the same system hostname; their endpoints distinguish them.
            openDrawer(app)
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
            app.buttons["sheet.done"].tap()
            newSession(app)

            let picker = app.buttons["composer.host"]
            if index == 1 {
                picker.tap()
                app.buttons[hostName].tap()
            }
            XCTAssertTrue(picker.label.contains(hostName), picker.debugDescription)
            let prompt = "Say hello on \(index)"
            send(app, prompt)
            // The reply shows on the session page; the short answer shows inline in 所有任务.
            waitForValue(app.descendants(matching: .any)["task.status"], in: ["completed"], timeout: 15)
            XCTAssertEqual(app.staticTexts["page.subtitle"].label, hostName)
            openAllTasks(app)
            let row = app.buttons.matching(identifier: "tasklist.row")
                .matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", prompt, "Hello from host \(index).")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 15), app.debugDescription)
            XCTAssertEqual(row.value as? String, "completed")
            XCTAssertTrue(row.label.contains(hostName), row.label)
        }
        saveShot("multi-host-paired-inline")
    }
}
