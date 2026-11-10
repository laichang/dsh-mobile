import XCTest

/// The keyboard goes away before any action that is not typing. The menus on
/// the composer of 01 open in place, not through the shell: the host menu (shown with 2 or more
/// hosts) and the "+" attach menu. With the keyboard up, a tap on either puts the keyboard away
/// first; then the menu shows.
///
/// Two FakeBridge hosts that take attachments (`-DSHMFakeBridge multi -DSHMFakeScenario
/// attachments`). While the menu shows, the test reads `app.keyboards` (the on-screen keyboard;
/// the demo's headless Simulator has no hardware keyboard, and the test checks that the keyboard
/// was on screen first). After the menu closes, it also reads the prompt's focus.
/// scripts/demo/keyboard.sh runs these.
@MainActor
final class KeyboardMenusUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-DSHMResetPairing", "YES",
                               "-DSHMResetStore", "YES", "-DSHMFakeBridge", "multi", "-DSHMFakeScenario", "attachments"]
        app.launch()
        // A Live Activity of an earlier test can make the system open the app in the background
        // just before the launch; XCTest then takes that process, which has none of these
        // arguments (one host, no host menu). The host menu shows which process it got.
        if !app.buttons["composer.host"].waitForExistence(timeout: 15) {
            print("keyboard: the app came up without its launch arguments; launching it again")
            app.terminate()
            app.launch()
        }
        XCTAssertTrue(app.buttons["composer.host"].waitForExistence(timeout: 15), app.debugDescription)
        return app
    }

    private func prompt(_ app: XCUIApplication) -> XCUIElement { app.textFields["composer.prompt"] }

    private func waitFor(_ format: String, on object: Any, timeout: TimeInterval = 5) -> Bool {
        XCTWaiter().wait(for: [expectation(for: NSPredicate(format: format), evaluatedWith: object)], timeout: timeout) == .completed
    }

    /// Puts the keyboard up on 01 and types: the keyboard is on screen.
    private func startTyping(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let field = prompt(app)
        XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription, file: file, line: line)
        field.tap()
        XCTAssertTrue(waitFor("hasKeyboardFocus == true", on: field), "the prompt takes focus", file: file, line: line)
        field.typeText("draft")
        XCTAssertTrue(waitFor("count > 0", on: app.keyboards), "the on-screen keyboard is up\n\(app.debugDescription)",
                      file: file, line: line)
    }

    /// While a menu shows: the keyboard is gone.
    private func expectKeyboardGone(_ app: XCUIApplication, _ menu: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitFor("count == 0", on: app.keyboards), "\(menu) puts the keyboard away\n\(app.debugDescription)",
                      file: file, line: line)
    }

    private func expectUnfocused(_ app: XCUIApplication, _ menu: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitFor("exists == true AND hasKeyboardFocus == false", on: prompt(app)),
                      "after \(menu), the prompt has no focus", file: file, line: line)
        XCTAssertEqual(prompt(app).value as? String, "draft", "the draft stays", file: file, line: line)
    }

    // MARK: - Checks

    /// The reported bug: with the keyboard up on 01, the host menu opened over the keyboard.
    func testHostMenuPutsKeyboardAwayFirst() {
        let app = launch()
        startTyping(app)
        let picker = app.buttons["composer.host"]
        XCTAssertTrue(picker.label.contains("Home Mac"), picker.debugDescription)
        picker.tap()
        let office = app.buttons["Office Mac"]
        let home = app.buttons["Home Mac"]
        XCTAssertTrue(office.waitForExistence(timeout: 5), "the host menu shows\n\(app.debugDescription)")
        XCTAssertTrue(home.exists, "the host menu lists both hosts\n\(app.debugDescription)")
        expectKeyboardGone(app, "the host menu")
        saveShot("keyboard-host-menu")
        office.tap()
        XCTAssertTrue(office.waitForNonExistence(timeout: 5), "the menu closes")
        XCTAssertTrue(waitFor("label CONTAINS 'Office Mac'", on: picker), "the choice is taken\n\(picker.debugDescription)")
        expectUnfocused(app, "the host menu")
    }

    /// The other menu on the composer: "+" (photo library, camera, files).
    func testAttachMenuPutsKeyboardAwayFirst() {
        let app = launch()
        startTyping(app)
        let plus = app.buttons["composer.attach"]
        XCTAssertTrue(plus.waitForExistence(timeout: 10), "the hosts take attachments\n\(app.debugDescription)")
        XCTAssertTrue(waitFor("isEnabled == true", on: plus, timeout: 10))
        plus.tap()
        let files = app.buttons["attach.files"]
        XCTAssertTrue(files.waitForExistence(timeout: 5), "the + menu shows\n\(app.debugDescription)")
        expectKeyboardGone(app, "the + menu")
        saveShot("keyboard-attach-menu")
        // A tap outside the menu closes it and picks nothing.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        XCTAssertTrue(files.waitForNonExistence(timeout: 5), "the menu closes")
        expectUnfocused(app, "the + menu")
    }
}
