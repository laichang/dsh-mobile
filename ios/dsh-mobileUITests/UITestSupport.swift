import XCTest

/// Shared by the slice UI tests (T0, S1, …): drive the composer, open deep links, save shots.
@MainActor
extension XCTestCase {
    var env: [String: String] { ProcessInfo.processInfo.environment }

    /// Types the prompt, taps send, waits for the task to finish; returns the transcript.
    func runDemo(_ app: XCUIApplication, prompt: String, timeout: TimeInterval) -> String {
        let field = app.textFields["composer.prompt"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(prompt)
        let send = app.buttons["composer.send"]
        XCTAssertTrue(send.isEnabled)
        let matchingRows = app.buttons.matching(identifier: "tasklist.row")
            .matching(NSPredicate(format: "label CONTAINS %@", prompt))
        let priorCount = matchingRows.count
        send.tap()

        // Short answers stay in the list (S8). This demo inspects the full session transcript.
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline, !app.descendants(matching: .any)["task.status"].exists {
            if matchingRows.count > priorCount, matchingRows.firstMatch.isHittable {
                matchingRows.firstMatch.tap()
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        let status = app.descendants(matching: .any)["task.status"]
        let transcript = app.descendants(matching: .any)["transcript.text"]

        // Streaming: some text shows while the task is still running.
        let streamed = expectation(for: NSPredicate(format: "value != ''"), evaluatedWith: transcript)
        wait(for: [streamed], timeout: timeout)

        let done = expectation(for: NSPredicate(format: "value == 'completed' OR value == 'failed'"), evaluatedWith: status)
        wait(for: [done], timeout: timeout)
        XCTAssertEqual(status.value as? String, "completed", "status label: \(status.label)")
        return transcript.value as? String ?? ""
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
