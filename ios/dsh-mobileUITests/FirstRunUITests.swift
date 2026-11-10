import XCTest

/// First run (DESIGN screen 08, STORY §6). A fresh Release install with no
/// paired computer, in Chinese: 08 says what the app is and what it needs (with the network
/// requirement), "粘贴配对链接" opens the link field, pairing succeeds against a real DSH + bridge, and
/// 01 opens with the first task in the composer, which the user edits and sends.
/// Needs TEST_RUNNER_DSHM_PAIR_URL from scripts/demo/first-run.sh; skipped without it.
@MainActor
final class FirstRunUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testPastedLinkPairsAndOpensTheFirstTask() throws {
        guard let url = env["DSHM_PAIR_URL"] else { throw XCTSkip("Use scripts/demo/first-run.sh with a fresh Release install") }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()

        // 08: what it is, what you need, and the network requirement.
        let purpose = app.staticTexts["firstRun.purpose"]
        XCTAssertTrue(purpose.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(purpose.label.contains("手机不调用模型"), purpose.label)
        XCTAssertTrue(app.staticTexts["firstRun.requiresHost"].label.contains("dsh-mobile bridge"))
        let steps = app.descendants(matching: .any).matching(identifier: "firstRun.step")
        XCTAssertEqual(steps.count, 2)
        XCTAssertTrue(steps.element(boundBy: 0).label.contains("终端"), steps.element(boundBy: 0).label)
        let network = steps.element(boundBy: 1).label
        XCTAssertTrue(network.contains("Wi-Fi") && network.contains("Tailscale"), network)
        XCTAssertTrue(app.buttons["pairing.scan"].exists)
        XCTAssertTrue(app.buttons["firstRun.setup"].exists || app.links["firstRun.setup"].exists)
        XCTAssertFalse(app.textFields["composer.prompt"].exists)
        saveShot("first-run-welcome")

        // Paste a pairing link: the field has focus, no camera.
        app.buttons["pairing.pasteLink"].tap()
        let link = app.textFields["pairing.paste"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        let focused = expectation(for: NSPredicate(format: "hasKeyboardFocus == true"), evaluatedWith: link)
        wait(for: [focused], timeout: 5)
        link.typeText(url)
        saveShot("first-run-paste")
        app.buttons["pairing.pasteUse"].tap()

        let pair = app.buttons["pairing.confirm"]
        XCTAssertTrue(pair.waitForExistence(timeout: 10), app.debugDescription)
        saveShot("first-run-pair-review")
        pair.tap()
        let status = app.descendants(matching: .any)["pairing.status"]
        XCTAssertEqual(waitForValue(status, in: ["paired", "failed"], timeout: 20), "paired", status.label)
        app.buttons["pairing.done"].tap()

        // 01 with the first task already in the composer, ready to edit.
        let composer = app.textFields["composer.prompt"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10), app.debugDescription)
        let suggestion = "打个招呼，并举例说明你能在这台电脑上帮我做什么。"
        XCTAssertEqual(composer.value as? String, suggestion)
        XCTAssertTrue(app.staticTexts["firstRun.hint"].exists)
        XCTAssertFalse(app.buttons["firstRun.suggestion"].exists)
        let send = app.buttons["composer.send"]
        let ready = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: send)
        wait(for: [ready], timeout: 15)
        saveShot("first-run-first-task")

        composer.tap()
        composer.typeText(" Keep it brief.")
        let edited = try XCTUnwrap(composer.value as? String)
        XCTAssertTrue(edited.contains("Keep it brief."), edited)
        XCTAssertNotEqual(edited, suggestion)
        saveShot("first-run-first-task-edited")
        send.tap()

        let detail = app.descendants(matching: .any)["task.status"]
        XCTAssertTrue(detail.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(waitForValue(detail, in: ["completed", "failed"], timeout: 60), "completed")
        let transcript = app.descendants(matching: .any)["transcript.text"]
        XCTAssertTrue((transcript.value as? String ?? "").contains("streamed through the dsh-mobile bridge"))

        // The first task belongs to the first pairing only: the next launch is a blank 01 (STORY §3).
        app.terminate()
        app.launch()
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertEqual(composer.value as? String ?? "", composer.placeholderValue ?? "")
        XCTAssertFalse(app.staticTexts["firstRun.hint"].exists)
        XCTAssertFalse(purpose.exists)
    }
}
