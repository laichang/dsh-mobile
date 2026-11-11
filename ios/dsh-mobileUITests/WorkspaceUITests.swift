import XCTest

@MainActor
final class WorkspaceUITests: XCTestCase {
    func testSamePromptReadsTwoActualRepositories() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let repos = try XCTUnwrap(env["DSHM_WORKSPACES_REPOS"])
        let port = try XCTUnwrap(env["DSHM_BRIDGE_PORT"])
        app.launchArguments = ["-DSHMBridgePort", port, "-DSHMResetPairing", "YES", "-DSHMResetStore", "YES"]
        launchEnrolled(app)
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
        saveShot("workspaces-default")
        newSession(app)
        open.tap()
        let path = app.textFields["workspace.path"]
        XCTAssertTrue(path.waitForExistence(timeout: 10))
        type(repos + "/violet", into: path)
        app.buttons["workspace.apply"].tap()
        let second = runDemo(app, prompt: prompt, timeout: 20)
        XCTAssertTrue(second.contains("Violet repository"), second)
        saveShot("workspaces-selected")
        newSession(app)
        open.tap()
        let recent = app.buttons["workspace.option." + repos + "/violet"]
        XCTAssertTrue(recent.waitForExistence(timeout: 10))
        saveShot("workspaces-picker")
        recent.tap()
    }
}
