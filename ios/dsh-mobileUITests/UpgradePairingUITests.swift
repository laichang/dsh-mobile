#if DEBUG
import XCTest

@MainActor
final class UpgradePairingUITests: XCTestCase {
    func testLegacyKeyAndHostRequireFreshEnrollment() {
        let app = XCUIApplication()
        app.launchArguments = ["-DSHMSeedLegacyPairing"]
        app.launch()
        XCTAssertTrue(app.buttons["pairing.scan"].waitForExistence(timeout: 15))
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.buttons["pairing.pasteLink"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["drawer.open"].exists)
        saveShot("upgrade-requires-fresh-enrollment")
        app.terminate()
    }
}
#endif
