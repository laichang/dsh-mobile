import XCTest

@MainActor
final class S6ModelsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testRaiseEffortDuringRealTask() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-DSHMBridgePort", try XCTUnwrap(env["DSHM_BRIDGE_PORT"]),
                               "-DSHMResetPairing", "YES", "-DSHMResetStore", "YES",
                               "-DSHMPresetPrompt", "Introduce yourself in one sentence."]
        app.launch()
        let picker = app.buttons["model.open"]
        XCTAssertTrue(picker.waitForExistence(timeout: 15))
        picker.tap()
        let low = app.buttons["model.effort.low"]
        XCTAssertTrue(low.waitForExistence(timeout: 10))
        low.tap()
        app.buttons["model.apply"].tap()
        app.buttons["composer.send"].tap()

        let transcript = app.descendants(matching: .any)["transcript.text"]
        let lowSelected = expectation(for: NSPredicate(format: "value CONTAINS %@", " · low]"), evaluatedWith: transcript)
        wait(for: [lowSelected], timeout: 15)
        XCTAssertEqual(app.descendants(matching: .any)["task.status"].value as? String, "running")
        picker.tap()
        let high = app.buttons["model.effort.high"]
        XCTAssertTrue(high.waitForExistence(timeout: 10), app.debugDescription)
        high.tap()
        app.buttons["model.apply"].tap()
        let switched = expectation(for: NSPredicate(format: "value CONTAINS %@", " · high]"), evaluatedWith: transcript)
        wait(for: [switched], timeout: 15)
        let text = try XCTUnwrap(transcript.value as? String)
        XCTAssertTrue(try XCTUnwrap(text.range(of: " · low]")).lowerBound < XCTUnwrap(text.range(of: " · high]")).lowerBound)
        XCTAssertEqual(app.descendants(matching: .any)["task.status"].value as? String, "running")
        saveShot("s6-effort-switch")
    }
}
