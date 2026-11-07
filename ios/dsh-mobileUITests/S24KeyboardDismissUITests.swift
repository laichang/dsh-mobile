import XCTest

/// S24 · Fix: Keyboard dismiss (PLAN.md §5 S24, ARCHITECTURE D67). The user's bug on a real
/// iPhone: with the keyboard up, a tap on the drawer button opened the drawer and the keyboard
/// stayed. Any action other than typing puts the keyboard away first.
///
/// The tests check the prompt's focus, not `app.keyboards`: a Simulator with a hardware keyboard
/// shows no on-screen keyboard. While the drawer is open the page is hidden from accessibility,
/// so each test closes the drawer or the sheet again before it reads the focus. Nothing in
/// between gives the prompt its focus back. scripts/demo/s24.sh runs these.
@MainActor
final class S24KeyboardDismissUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ scenario: String = "YES") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-DSHMResetPairing", "YES",
                               "-DSHMResetStore", "YES", "-DSHMFakeBridge", scenario]
        app.launch()
        return app
    }

    private func prompt(_ app: XCUIApplication) -> XCUIElement { app.textFields["composer.prompt"] }

    private func expectFocus(_ field: XCUIElement, _ focused: Bool, _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "exists == true AND hasKeyboardFocus == %@", NSNumber(value: focused))
        let result = XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: field)], timeout: 5)
        XCTAssertEqual(result, .completed, message, file: file, line: line)
    }

    /// Puts the keyboard up and types: typing keeps it up.
    private func startTyping(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let field = prompt(app)
        XCTAssertTrue(field.waitForExistence(timeout: 15), app.debugDescription, file: file, line: line)
        field.tap()
        expectFocus(field, true, "the prompt takes focus", file: file, line: line)
        field.typeText("draft")
        expectFocus(field, true, "typing keeps the keyboard up", file: file, line: line)
    }

    // MARK: - Done when

    /// The reported bug: the drawer button with the keyboard up.
    func testDrawerButtonPutsKeyboardAway() {
        let app = launch()
        startTyping(app)
        openDrawer(app)
        closeDrawer(app)
        expectFocus(prompt(app), false, "opening the drawer with its button puts the keyboard away")
        XCTAssertEqual(prompt(app).value as? String, "draft", "the draft stays")
    }

    /// The same with a drag from the left edge: the keyboard goes when the drag starts.
    func testEdgeDragPutsKeyboardAway() {
        let app = launch()
        startTyping(app)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: 3, dy: 420))
            .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: app.frame.width * 0.9, dy: 430)),
                   withVelocity: .default, thenHoldForDuration: 0.2)
        XCTAssertTrue(app.otherElements["drawer"].waitForExistence(timeout: 3), app.debugDescription)
        closeDrawer(app)
        expectFocus(prompt(app), false, "an edge drag that opens the drawer puts the keyboard away")
    }

    /// Pickers open as sheets: the workspace sheet and the model sheet put the keyboard away.
    func testPickerSheetsPutKeyboardAway() {
        let app = launch("pickers")
        for (open, option) in [("workspace.open", "workspace.option.default"), ("model.open", "model.provider")] {
            startTyping(app)
            let button = app.buttons[open]
            XCTAssertTrue(button.waitForExistence(timeout: 20), app.debugDescription)
            button.tap()
            XCTAssertTrue(app.descendants(matching: .any)[option].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
            let cancel = app.buttons["Cancel"].firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 5), app.debugDescription)
            cancel.tap()
            XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
            expectFocus(prompt(app), false, "\(open) puts the keyboard away")
        }
    }
}
