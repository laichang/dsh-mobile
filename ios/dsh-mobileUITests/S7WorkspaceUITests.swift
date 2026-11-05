import XCTest

@MainActor
final class S7WorkspaceUITests: XCTestCase {
    func testSamePromptReadsTwoActualRepositories() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let repos = try XCTUnwrap(env["DSHM_S7_REPOS"])
        let port = try XCTUnwrap(env["DSHM_BRIDGE_PORT"])
        app.launchArguments = ["-DSHMBridgePort", port, "-DSHMResetPairing", "YES", "-DSHMResetStore", "YES"]
        app.launch()
        let open = app.buttons["workspace.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        open.tap()
        let defaultPath = app.buttons["workspace.option.default"]
        XCTAssertTrue(defaultPath.waitForExistence(timeout: 10))
        XCTAssertTrue(defaultPath.label.contains(repos + "/amber"))
        defaultPath.tap()
        let prompt = "Read project-label.txt and identify this repository."
        let first = runDemo(app, prompt: prompt, timeout: 20)
        XCTAssertTrue(first.contains("Amber repository"), first)
        saveShot("s7-default")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        open.tap()
        let path = app.textFields["workspace.path"]
        XCTAssertTrue(path.waitForExistence(timeout: 10))
        path.tap()
        path.typeText(repos + "/violet")
        app.buttons["workspace.apply"].tap()
        let second = runDemo(app, prompt: prompt, timeout: 20)
        XCTAssertTrue(second.contains("Violet repository"), second)
        saveShot("s7-selected")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        open.tap()
        let recent = app.buttons["workspace.option." + repos + "/violet"]
        XCTAssertTrue(recent.waitForExistence(timeout: 10))
        saveShot("s7-picker")
        recent.tap()
    }
}
