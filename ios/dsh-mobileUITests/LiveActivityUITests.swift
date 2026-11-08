import XCTest

/// Screen L (scripts/demo/live-activity.sh): a running task shows its Live Activity on the lock
/// screen with the title, the host, a ticking time and the latest step; it ends as done.
/// FakeBridge (`-DSHMFakeScenario live-activity`): three todos, five seconds apart. The lock screen
/// is SpringBoard's: the test locks the Simulator and reads the activity's view there.
@MainActor
final class LiveActivityUITests: XCTestCase {
    static let title = "整理 Q3 报表成 PPT"
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() { continueAfterFailure = false }

    func testRunningTaskShowsItsLiveActivityOnTheLockScreen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-DSHMFakeBridge", "YES", "-DSHMFakeScenario", "live-activity", "-DSHMResetStore", "YES",
                               "-DSHMLiveActivityProbe", "YES", "-DSHMPresetPrompt", Self.title]
        app.launch()
        let send = app.buttons["composer.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 20))
        send.tap()

        // ActivityKit has one activity for the task, and it shows a step.
        let probe = app.descendants(matching: .any)["liveactivity.probe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 10), app.debugDescription)
        waitFor(probe, "one running activity with a step", timeout: 30) { value in
            let lines = value.split(separator: "\n")
            return lines.count == 1 && lines[0].hasPrefix("running|") && !lines[0].hasPrefix("running||")
        }
        // Lock just after a milestone: the next one is five seconds away.
        let before = probe.value as? String ?? ""
        waitFor(probe, "the next milestone", timeout: 20) { $0 != before && $0.hasPrefix("running|") }
        let step = (probe.value as? String ?? "").split(separator: "|", omittingEmptySubsequences: false)[1]

        lock()
        allowLiveActivities()
        let running = activityView()
        XCTAssertTrue(running.waitForExistence(timeout: 15), springboard.debugDescription)
        var texts = labels(running)
        XCTAssertTrue(texts.contains(Self.title), "\(texts)")
        XCTAssertTrue(texts.contains("FakeBridge Mac · \(step)"), "\(texts), step \(step)")
        let first = try XCTUnwrap(timer(texts), "\(texts)")
        sleep(3)
        texts = labels(running)
        let later = try XCTUnwrap(timer(texts), "\(texts)")
        XCTAssertNotEqual(first, later, "the time ticks on the lock screen")
        saveShot("live-activity-running")

        // Unlock: the app comes back, the task goes on, and the activity ends as done.
        unlock(app)
        waitFor(probe, "the activity ended as done", timeout: 90) { $0.hasPrefix("done|") && $0.hasSuffix("|3/3|ended") }

        lock()
        let done = activityView()
        XCTAssertTrue(done.waitForExistence(timeout: 15), springboard.debugDescription)
        texts = labels(done)
        XCTAssertTrue(texts.contains(Self.title), "\(texts)")
        XCTAssertTrue(texts.contains("已完成") || texts.contains("Done"), "\(texts)")
        let stopped = try XCTUnwrap(timer(texts), "\(texts)")
        sleep(2)
        XCTAssertEqual(timer(labels(done)), stopped, "the time stops at the end")
        saveShot("live-activity-done")
        unlock(app)
    }

    /// The Live Activity's lock screen view, as SpringBoard shows it.
    private func activityView() -> XCUIElement {
        springboard.descendants(matching: .any).matching(identifier: "activity-content-view").firstMatch
    }

    private func labels(_ element: XCUIElement) -> [String] {
        element.staticTexts.allElementsBoundByIndex.map(\.label)
    }

    /// The elapsed time, `m:ss` or `h:mm:ss`.
    private func timer(_ labels: [String]) -> String? {
        labels.first { $0.range(of: #"^\d+(:\d\d){1,2}$"#, options: .regularExpression) != nil }
    }

    /// The first activity on the lock screen asks whether this app may show Live Activities there.
    /// The test app on the test Simulator says yes.
    private func allowLiveActivities() {
        let buttons = springboard.buttons.matching(identifier: "swipe-action-button-identifier")
        guard buttons.firstMatch.waitForExistence(timeout: 5) else { return }
        let allow = buttons.matching(NSPredicate(format: "label IN %@", ["允许", "Allow"])).firstMatch
        (allow.exists ? allow : buttons.element(boundBy: buttons.count - 1)).tap()
        sleep(2)
    }

    /// Polls `element`'s value until `check` holds.
    private func waitFor(_ element: XCUIElement, _ what: String, timeout: TimeInterval, _ check: (String) -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !check(element.value as? String ?? "") {
            if Date() > deadline { XCTFail("timed out: \(what); value: \(element.value as? String ?? "nil")"); return }
            usleep(200_000)
        }
    }

    /// Locks the device, then wakes the screen: the lock screen shows. There is no public API to
    /// lock; XCTest's private `pressLockButton` presses the side button.
    private func lock() {
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        sleep(3)
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        sleep(3)
    }

    /// Unlocks (the Simulator has no passcode) and brings the app to the front.
    private func unlock(_ app: XCUIApplication) {
        XCUIDevice.shared.press(.home)
        sleep(2)
        if app.state != .runningForeground { app.activate() }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    }
}
