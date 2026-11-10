import XCTest

/// Attachments against real DSH with the mock model: the composer's "+"
/// menu attaches a photo (system photo picker) and files (system document picker), on a new
/// session (01) and on a follow-up (04). Run by scripts/demo/attachments.sh, which adds the golden
/// photo to the simulator's library and notes.txt and report.pdf to Files (On My iPhone), and then
/// checks that the DSH sessions have them.
@MainActor
final class AttachmentsUITests: XCTestCase {
    func launch(prompt: String) throws -> XCUIApplication {
        try XCTSkipUnless(env["DSHM_REAL_DSH"] == "1", "run scripts/demo/attachments.sh with a real DSH host")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-DSHMBridgePort", env["DSHM_BRIDGE_PORT"] ?? "47801",
                               "-DSHMResetPairing", "YES", "-DSHMResetStore", "YES",
                               "-DSHMPresetPrompt", prompt]
        app.launch()
        return app
    }

    /// Opens the "+" menu (`composer.attach` or `session.attach`) and taps one of its items.
    func openAttachMenu(_ app: XCUIApplication, key: String, item: String, labels: [String]) {
        let plus = app.buttons[key]
        XCTAssertTrue(plus.waitForExistence(timeout: 20), "the host advertises attachments.v1\n\(app.debugDescription)")
        XCTAssertTrue(waitForEnabled(plus, timeout: 10))
        plus.tap()
        var entry = app.buttons[item]
        if !entry.waitForExistence(timeout: 3) {
            entry = app.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
        }
        XCTAssertTrue(entry.waitForExistence(timeout: 5), app.debugDescription)
        entry.tap()
    }

    func waitForEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: element)
        return XCTWaiter().wait(for: [enabled], timeout: timeout) == .completed
    }

    func attachPhoto(_ app: XCUIApplication, key: String = "composer.attach") {
        openAttachMenu(app, key: key, item: "attach.photos", labels: ["照片图库", "Photo Library"])
        // The system picker runs out of process; its grid lists the newest photo (the demo's) first.
        // Its cells' identifier does not depend on the simulator's language. Its first open after
        // an install can take more than 15 s.
        let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 30), app.debugDescription)
        // The picker's cells report "not hittable" to XCUITest; a tap at the cell's centre works.
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(chip(app, "photo.jpg").waitForExistence(timeout: 10), app.debugDescription)
    }

    /// Picks `name` (e.g. "notes.txt") in the system document picker. The demo puts the files in
    /// On My iPhone. The picker opens on Recents, on the Browse root (a list of locations), or in
    /// the last folder, depending on what it showed before.
    func attachFile(_ app: XCUIApplication, _ name: String, key: String = "composer.attach") {
        openAttachMenu(app, key: key, item: "attach.files", labels: ["文件", "Files"])
        let base = (name as NSString).deletingPathExtension
        let file = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", base)).firstMatch
        if !file.waitForExistence(timeout: 6) {
            // The location cell's identifier is "DOC.sidebar.item.<name>" in any language.
            let here = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'DOC.sidebar.item' AND label CONTAINS 'iPhone'")).firstMatch
            if !here.waitForExistence(timeout: 2) {
                let browse = app.buttons.matching(NSPredicate(format: "label IN %@", ["浏览", "Browse"])).firstMatch
                XCTAssertTrue(browse.waitForExistence(timeout: 5), app.debugDescription)
                browse.tap()
            }
            if !file.waitForExistence(timeout: 3) {
                XCTAssertTrue(here.waitForExistence(timeout: 5), app.debugDescription)
                here.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
        }
        XCTAssertTrue(file.waitForExistence(timeout: 10), app.debugDescription)
        file.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(chip(app, name).waitForExistence(timeout: 10), app.debugDescription)
    }

    func chip(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.descendants(matching: .any)["attachment.chip.\(name)"]
    }

    func bubbleFile(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "session.message.user.file")
            .matching(NSPredicate(format: "label == %@", name)).firstMatch
    }

    func testAttachOnePhotoAndSend() throws {
        let app = try launch(prompt: "What is in this photo?")
        attachPhoto(app)
        saveShot("attachments-composer")

        app.buttons["composer.send"].tap()
        let bubblePhoto = app.descendants(matching: .any)["session.message.user.photo"]
        XCTAssertTrue(bubblePhoto.waitForExistence(timeout: 20), app.debugDescription)
        let status = app.descendants(matching: .any)["task.status"]
        XCTAssertEqual(waitForValue(status, in: ["completed", "failed"], timeout: 30), "completed")
        XCTAssertTrue(bubblePhoto.exists)
        XCTAssertFalse(chip(app, "photo.jpg").exists, "the photo was for this one task")
        saveShot("attachments-session")
    }

    /// A photo, a.txt and a.pdf on composer 01; the.txt is removed; the bubble shows the
    /// other two, and the demo then checks that the DSH session has the image and the PDF.
    func testAttachPhotoTextAndPDFRemoveOneAndSend() throws {
        let app = try launch(prompt: "Read these files.")
        attachPhoto(app)
        attachFile(app, "notes.txt")
        attachFile(app, "report.pdf")
        XCTAssertTrue(chip(app, "photo.jpg").exists && chip(app, "notes.txt").exists && chip(app, "report.pdf").exists)
        saveShot("attachments-files-composer")

        app.buttons["attachment.remove.notes.txt"].tap()
        XCTAssertTrue(chip(app, "notes.txt").waitForNonExistence(timeout: 5))
        app.buttons["composer.send"].tap()

        let bubblePhoto = app.descendants(matching: .any)["session.message.user.photo"]
        XCTAssertTrue(bubblePhoto.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(bubbleFile(app, "report.pdf").waitForExistence(timeout: 10), app.debugDescription)
        let status = app.descendants(matching: .any)["task.status"]
        XCTAssertEqual(waitForValue(status, in: ["completed", "failed"], timeout: 30), "completed")
        XCTAssertTrue(bubblePhoto.exists)
        XCTAssertTrue(bubbleFile(app, "report.pdf").exists)
        XCTAssertFalse(bubbleFile(app, "notes.txt").exists, "the removed file stayed on the phone")
        XCTAssertFalse(chip(app, "report.pdf").exists, "the files were for this one task")
        saveShot("attachments-files-session")
    }

    /// A file on the follow-up composer of a completed session goes into the same DSH session
    /// (the demo checks the session log); the follow-up bubble shows it.
    func testAttachFileToFollowUp() throws {
        let app = try launch(prompt: "Say hello.")
        app.buttons["composer.send"].tap()
        let status = app.descendants(matching: .any)["task.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(waitForValue(status, in: ["completed", "failed"], timeout: 30), "completed")

        attachFile(app, "notes.txt", key: "session.attach")
        let field = app.textFields["session.followUp"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        type("What is in this file?", into: field)
        saveShot("attachments-followup-composer")
        app.buttons["session.send"].tap()

        XCTAssertTrue(bubbleFile(app, "notes.txt").waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertFalse(chip(app, "notes.txt").exists, "the file left the composer with the message")
        XCTAssertEqual(waitForValue(status, in: ["completed", "failed"], timeout: 30), "completed")
        XCTAssertTrue(bubbleFile(app, "notes.txt").exists)
        saveShot("attachments-followup-session")
    }
}
