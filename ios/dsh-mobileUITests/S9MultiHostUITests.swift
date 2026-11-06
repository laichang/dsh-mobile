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
        newSession(app)

        picker.tap()
        app.buttons["Office Mac"].tap()
        XCTAssertEqual(runDemo(app, prompt: "Task for office", timeout: 20), "Reply from Office Mac")
        openAllTasks(app)

        let rows = app.descendants(matching: .any).matching(identifier: "tasklist.row")
        XCTAssertTrue(rows.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Task for home", "Home Mac")).firstMatch.exists)
        XCTAssertTrue(rows.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Task for office", "Office Mac")).firstMatch.exists)
        saveShot("s9-two-hosts")

        app.terminate()
        app.launchArguments = ["-DSHMFakeBridge", "multi-office-offline"]
        app.launch()
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        XCTAssertTrue(picker.label.contains("Office Mac"), picker.debugDescription)
        openDrawer(app)
        let statuses = app.descendants(matching: .any).matching(identifier: "host.status")
        XCTAssertTrue(statuses.matching(NSPredicate(format: "label CONTAINS %@ AND value == %@", "Office Mac", "offline"))
            .firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(statuses.matching(NSPredicate(format: "label CONTAINS %@ AND value == %@", "Home Mac", "online"))
            .firstMatch.waitForExistence(timeout: 10))
        app.buttons["drawer.allTasks"].tap()
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(rows.count, 2)
        saveShot("s9-office-offline")
    }
}
