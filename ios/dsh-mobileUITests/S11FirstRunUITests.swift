import XCTest

@MainActor
final class S11FirstRunUITests: XCTestCase {
    func testChineseWelcomeAndGuide() throws {
        try XCTSkipUnless(env["DSHM_PAIR_URL"] != nil, "Use scripts/demo/s11.sh with a fresh Release install")
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let purpose = app.staticTexts["firstRun.purpose"]
        XCTAssertTrue(purpose.waitForExistence(timeout: 10))
        XCTAssertTrue(purpose.label.contains("电脑"))
        app.buttons["pairing.scan"].tap()
        XCTAssertTrue(app.staticTexts["pairing.guide"].label.contains("配对码"))
        XCTAssertTrue(app.textFields["pairing.paste"].exists)
    }

    func testFirstRunFromWelcomeToReply() throws {
        guard let url = env["DSHM_PAIR_URL"] else { throw XCTSkip("Use scripts/demo/s11.sh with a fresh Release install") }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let purpose = app.staticTexts["firstRun.purpose"]
        XCTAssertTrue(purpose.waitForExistence(timeout: 10))
        XCTAssertTrue(purpose.label.contains("runs the tasks on your computer"))
        XCTAssertTrue(app.staticTexts["firstRun.requiresHost"].label.contains("bridge enabled"))
        XCTAssertFalse(app.textFields["composer.prompt"].exists)
        saveShot("s11-welcome")

        app.buttons["pairing.scan"].tap()
        let guide = app.staticTexts["pairing.guide"]
        XCTAssertTrue(guide.waitForExistence(timeout: 5))
        XCTAssertTrue(guide.label.contains("terminal"))
        app.buttons["Need a pairing code?"].tap()
        XCTAssertTrue(app.staticTexts["node bridge/lib/scripts/pair.js"].exists)
        let instructions = app.descendants(matching: .any)["pairing.setupInstructions"]
        let expanded = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: instructions)
        wait(for: [expanded], timeout: 5)
        saveShot("s11-guide")
        let link = app.textFields["pairing.paste"]
        link.tap()
        link.typeText(url)
        app.buttons["pairing.pasteUse"].tap()
        let pair = app.buttons["pairing.confirm"]
        XCTAssertTrue(pair.waitForExistence(timeout: 10))
        pair.tap()
        let done = app.buttons["pairing.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 15))
        done.tap()

        openDrawer(app)
        let channel = app.descendants(matching: .any)["host.channel"]
        XCTAssertTrue(channel.waitForExistence(timeout: 10))
        XCTAssertEqual(channel.value as? String, "noise")
        // The earlier session from another device is in the drawer, under its host.
        let existing = app.buttons.matching(identifier: "drawer.session")
            .matching(NSPredicate(format: "label CONTAINS %@", "Earlier task from another device"))
        XCTAssertTrue(existing.firstMatch.waitForExistence(timeout: 8))
        XCTAssertEqual(app.buttons.matching(identifier: "drawer.session").count, 1)
        closeDrawer(app)
        // S22 seam (D63): after the first pairing the first task is already in the composer.
        let suggestion = app.buttons["firstRun.suggestion"]
        XCTAssertTrue(app.staticTexts["firstRun.hint"].waitForExistence(timeout: 10))
        XCTAssertFalse(suggestion.exists)
        saveShot("s11-first-task")
        let composer = app.textFields["composer.prompt"]
        let draft = try XCTUnwrap(composer.value as? String)
        XCTAssertTrue(draft.contains("Say hello"))
        composer.tap()
        composer.typeText(" Keep it brief.")
        let edited = try XCTUnwrap(composer.value as? String)
        XCTAssertTrue(edited.contains("Keep it brief."))
        app.buttons["composer.send"].tap()
        let row = app.buttons.matching(identifier: "tasklist.row").matching(NSPredicate(format: "label CONTAINS %@", edited)).firstMatch
        let detail = app.descendants(matching: .any)["task.status"]
        XCTAssertTrue(detail.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(waitForValue(detail, in: ["completed", "failed"], timeout: 30), "completed")
        let transcript = app.descendants(matching: .any)["transcript.text"]
        XCTAssertTrue((transcript.value as? String ?? "").contains("streamed through the dsh-mobile bridge"))
        app.terminate()
        app.launch()
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertFalse(suggestion.exists)
        XCTAssertFalse(purpose.exists)
        openAllTasks(app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
    }

    func testSavedHostWithoutAnAddressOffersRecovery() throws {
        try XCTSkipUnless(env["DSHM_S11_RECOVERY"] == "1", "Use the saved-host fixture in scripts/demo/s11.sh")
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let retry = app.buttons["Try again"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["firstRun.purpose"].exists)
        retry.tap()
        XCTAssertTrue(retry.exists)
        app.buttons["Pair a computer"].tap()
        XCTAssertTrue(app.staticTexts["pairing.guide"].waitForExistence(timeout: 5))
    }
}
