import XCTest

/// Attachments (ARCHITECTURE D95) against real DSH with the mock model: attach one photo on
/// composer 01 with the system photo picker and send. Run by scripts/demo/attachments.sh, which
/// adds the golden photo to the simulator's library and then checks the DSH session has the image.
@MainActor
final class AttachmentsUITests: XCTestCase {
    func testAttachOnePhotoAndSend() throws {
        try XCTSkipUnless(env["DSHM_REAL_DSH"] == "1", "run scripts/demo/attachments.sh with a real DSH host")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-DSHMBridgePort", env["DSHM_BRIDGE_PORT"] ?? "47801",
                               "-DSHMResetPairing", "YES", "-DSHMResetStore", "YES",
                               "-DSHMPresetPrompt", "What is in this photo?"]
        app.launch()

        let photoKey = app.buttons["composer.photo"]
        XCTAssertTrue(photoKey.waitForExistence(timeout: 20), "the host advertises attachments.v1")
        photoKey.tap()
        // The system picker runs out of process; its grid lists the newest photo (the demo's) first.
        // Its cells' identifier does not depend on the simulator's language.
        let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 15), app.debugDescription)
        // The picker's cells report "not hittable" to XCUITest; a tap at the cell's centre works.
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let chip = app.descendants(matching: .any)["composer.photoChip"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10), app.debugDescription)
        saveShot("attachments-composer")

        app.buttons["composer.send"].tap()
        let bubblePhoto = app.descendants(matching: .any)["session.message.user.photo"]
        XCTAssertTrue(bubblePhoto.waitForExistence(timeout: 20), app.debugDescription)
        let status = app.descendants(matching: .any)["task.status"]
        XCTAssertEqual(waitForValue(status, in: ["completed", "failed"], timeout: 30), "completed")
        XCTAssertTrue(bubblePhoto.exists)
        XCTAssertFalse(chip.exists, "the photo was for this one task")
        saveShot("attachments-session")
    }
}
