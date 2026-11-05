import XCTest

@MainActor
final class S9MultiHostUITests: XCTestCase {
    func testTwoHostsShareTheListAndTheOfflineHostIsNamed() {
        let app = XCUIApplication()
        app.launchArguments = ["-DSHMFakeBridge", "multi", "-DSHMResetStore", "YES"]
        app.launch()
        let picker = app.buttons["composer.host"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        XCTAssertEqual(runDemo(app, prompt: "Task for home", timeout: 20), "Reply from Home Mac")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        picker.tap()
        app.buttons["Office Mac"].tap()
        XCTAssertEqual(runDemo(app, prompt: "Task for office", timeout: 20), "Reply from Office Mac")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let rows = app.descendants(matching: .any).matching(identifier: "tasklist.row")
        XCTAssertTrue(rows.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Task for home", "Home Mac")).firstMatch.exists)
        XCTAssertTrue(rows.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Task for office", "Office Mac")).firstMatch.exists)
        saveShot("s9-two-hosts")

        app.terminate()
        app.launchArguments = ["-DSHMFakeBridge", "multi-office-offline"]
        app.launch()
        let statuses = app.descendants(matching: .any).matching(identifier: "host.status")
        XCTAssertTrue(statuses.matching(NSPredicate(format: "label CONTAINS %@ AND value == %@", "Office Mac", "offline"))
            .firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(statuses.matching(NSPredicate(format: "label CONTAINS %@ AND value == %@", "Home Mac", "online"))
            .firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(picker.label.contains("Office Mac"), picker.debugDescription)
        saveShot("s9-office-offline")
    }
}
