import XCTest

/// Shared by the slice UI tests (T0, S1, …): drive the composer and the T1 shell, open deep links, save shots.
@MainActor
extension XCTestCase {
    var env: [String: String] { ProcessInfo.processInfo.environment }

    /// Types the prompt in a new session, taps send, waits for the task to finish; returns the
    /// transcript. The first message turns the new session into the session page (T1, D51).
    func runDemo(_ app: XCUIApplication, prompt: String, timeout: TimeInterval) -> String {
        let field = app.textFields["composer.prompt"]
        let elsewhere = app.otherElements["drawer"].exists || app.descendants(matching: .any)["task.status"].exists ||
            app.descendants(matching: .any)["tasklist"].exists
        if elsewhere { newSession(app) }
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(prompt)
        let send = app.buttons["composer.send"]
        XCTAssertTrue(send.isEnabled)
        send.tap()

        let status = app.descendants(matching: .any)["task.status"]
        XCTAssertTrue(status.waitForExistence(timeout: timeout), app.debugDescription)
        let transcript = app.descendants(matching: .any)["transcript.text"]

        // Streaming: some text shows while the task is still running.
        let streamed = expectation(for: NSPredicate(format: "value != ''"), evaluatedWith: transcript)
        wait(for: [streamed], timeout: timeout)

        let done = expectation(for: NSPredicate(format: "value == 'completed' OR value == 'failed'"), evaluatedWith: status)
        wait(for: [done], timeout: timeout)
        XCTAssertEqual(status.value as? String, "completed", "status label: \(status.label)")
        return transcript.value as? String ?? ""
    }

    // MARK: - T1 shell: the drawer replaces the navigation stack

    /// Opens the workspace drawer with its button (no-op if it is open).
    func openDrawer(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let drawer = app.otherElements["drawer"]
        if drawer.exists { return }
        let button = app.buttons["drawer.open"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), app.debugDescription, file: file, line: line)
        button.tap()
        XCTAssertTrue(drawer.waitForExistence(timeout: 5), app.debugDescription, file: file, line: line)
    }

    /// Closes the drawer with a tap on the peeking page (no-op if it is closed).
    func closeDrawer(_ app: XCUIApplication) {
        let drawer = app.otherElements["drawer"]
        guard drawer.exists else { return }
        app.buttons["drawer.dismiss"].tap()
        XCTAssertTrue(drawer.waitForNonExistence(timeout: 5))
    }

    /// Opens the session whose drawer row contains `text`.
    func openSession(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 10,
                     file: StaticString = #filePath, line: UInt = #line) {
        openDrawer(app, file: file, line: line)
        let row = app.buttons.matching(identifier: "drawer.session").matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: timeout), app.debugDescription, file: file, line: line)
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["task.status"].waitForExistence(timeout: 5), file: file, line: line)
    }

    /// Opens 所有任务 (the M1 task list) from the drawer.
    func openAllTasks(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        openDrawer(app, file: file, line: line)
        app.buttons["drawer.allTasks"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["tasklist"].waitForExistence(timeout: 5), app.debugDescription, file: file, line: line)
    }

    /// Opens a blank new session from the drawer.
    func newSession(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        openDrawer(app, file: file, line: line)
        app.buttons["drawer.new"].tap()
        XCTAssertTrue(app.textFields["composer.prompt"].waitForExistence(timeout: 5), app.debugDescription, file: file, line: line)
    }

    /// S18: swipes the approval sheet (05) of the open session down, if it is up. The page then
    /// shows `approval.pending`, which opens it again.
    func closeApprovalSheet(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let sheet = app.descendants(matching: .any).matching(identifier: "approval.sheet").firstMatch
        guard sheet.waitForExistence(timeout: 10) else { return }
        // Drag the grabber, above the content, down to the bottom of the screen.
        let grabber = sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: -14))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        grabber.press(forDuration: 0.05, thenDragTo: bottom, withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 15), app.debugDescription, file: file, line: line)
    }

    /// S18: opens the approval sheet again from the session page's `approval.pending` bar.
    func reopenApprovalSheet(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let bar = app.buttons["approval.pending"]
        XCTAssertTrue(bar.waitForExistence(timeout: 15), app.debugDescription, file: file, line: line)
        bar.tap()
        let sheet = app.descendants(matching: .any).matching(identifier: "approval.sheet").firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 15), app.debugDescription, file: file, line: line)
    }

    /// Opens a `dshm://` link the way the system does, confirms iOS's "Open in dsh-mobile?"
    /// prompt, and returns a fresh handle on the app (the old one can keep a stale tree).
    func openDeepLink(_ url: URL) -> XCUIApplication {
        XCUIApplication().open(url)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let open = springboard.buttons.matching(NSPredicate(format: "label IN {'Open', '打开'}")).firstMatch
        if open.waitForExistence(timeout: 3) { open.tap() }
        return XCUIApplication(bundleIdentifier: "chang.dsh-mobile")
    }

    /// Waits until the element's accessibility value is one of `values`; returns the value.
    @discardableResult
    func waitForValue(_ element: XCUIElement, in values: [String], timeout: TimeInterval) -> String? {
        let predicate = NSPredicate(format: "value IN %@", values)
        wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout)
        return element.value as? String
    }

    func saveShot(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = env["DSHM_SHOT_DIR"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
}
