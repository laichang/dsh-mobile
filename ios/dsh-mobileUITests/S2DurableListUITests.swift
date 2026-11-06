import XCTest

/// S2 · Durable list + resume in the Simulator (PLAN.md §5), driven by accessibility identifiers.
/// - `testOfflineHostIsNamedWithFakeBridge` needs nothing else running.
/// - `testKillAndReopenAgainstRealDSH` needs `scripts/demo/s2-host.mjs` (real DSH + bridge on
///   DSHM_BRIDGE_PORT, slow mock LLM); runs only with TEST_RUNNER_DSHM_REAL_DSH=1.
/// - `testOfflineRealHostIsNamed` runs after that one, with the host stopped
///   (TEST_RUNNER_DSHM_EXPECT_OFFLINE=1, TEST_RUNNER_DSHM_HOST_NAME = the bridge's hostname).
/// scripts/demo/s2.sh runs them in that order. TEST_RUNNER_DSHM_SHOT_DIR saves screenshots.
@MainActor
final class S2DurableListUITests: XCTestCase {
    /// scripts/demo/s2-host.mjs MOCK_TEXT.
    static let mockText = "你好！I am a DSH agent on your Mac. This reply is streamed through the dsh-mobile bridge."

    override func setUp() {
        continueAfterFailure = false
    }

    private var port: String { env["DSHM_BRIDGE_PORT"] ?? "47811" }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + arguments
        app.launch()
        return app
    }

    private func send(_ app: XCUIApplication, _ prompt: String) {
        let field = app.textFields["composer.prompt"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(prompt)
        app.buttons["composer.send"].tap()
    }

    /// Polls faster than XCTest's expectations (about 1 s), so a mid-stream moment isn't missed.
    @discardableResult
    private func poll(_ timeout: TimeInterval, _ what: String, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("timed out waiting for \(what)")
        return false
    }

    private func value(_ element: XCUIElement) -> String { element.value as? String ?? "" }


    func testKillAndReopenAgainstRealDSH() throws {
        try XCTSkipUnless(env["DSHM_REAL_DSH"] == "1", "needs scripts/demo/s2-host.mjs; run scripts/demo/s2.sh")
        let prompt = "Durable list check \(Int(Date().timeIntervalSince1970) % 100_000)"
        var app = launch(["-DSHMBridgePort", port, "-DSHMResetStore", "YES"])
        send(app, prompt)

        // Kill the app while the task is still streaming on the host.
        var transcript = app.descendants(matching: .any)["transcript.text"]
        poll(30, "the first streamed text") { !value(transcript).isEmpty }
        let seenBeforeKill = value(transcript)
        XCTAssertNotEqual(seenBeforeKill, Self.mockText, "the task finished before the kill; the mock must be slow")
        XCTAssertEqual(value(app.descendants(matching: .any)["task.status"]), "running")
        app.terminate()

        // Wait: the task finishes on the host while the app is gone.
        Thread.sleep(forTimeInterval: 9)

        // Reopen, holding the connection back so the cache can be checked first (XCUITest is slow,
        // so the hold is generous).
        app = launch(["-DSHMBridgePort", port, "-DSHMConnectDelay", "20"])
        openDrawer(app)
        XCTAssertEqual(value(app.descendants(matching: .any)["host.status"]), "connecting")
        app.buttons["drawer.allTasks"].tap()
        let row = app.buttons.matching(identifier: "tasklist.row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(row.label.contains(prompt), row.label)
        row.tap()
        transcript = app.descendants(matching: .any)["transcript.text"]
        let status = app.descendants(matching: .any)["task.status"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        let cached = value(transcript)
        // The list and the transcript so far are intact, from the cache, before any connection.
        XCTAssertFalse(cached.isEmpty, "cached transcript is empty")
        XCTAssertTrue(Self.mockText.hasPrefix(cached), cached)
        XCTAssertNotEqual(cached, Self.mockText, "the gap was filled before the connection was allowed")
        XCTAssertEqual(value(status), "running")
        saveShot("s2-reopened-from-cache")

        // Then the bridge fills the gap: the full reply, exactly once, and the task is done.
        poll(60, "the task to complete after resume") { value(status) == "completed" }
        XCTAssertEqual(value(transcript), Self.mockText)
        saveShot("s2-gap-filled")

        openAllTasks(app)
        XCTAssertTrue(app.descendants(matching: .any)["tasklist.done"].waitForExistence(timeout: 5) ||
                      app.staticTexts["Done"].exists, app.debugDescription)
        saveShot("s2-list-after-resume")
        openDrawer(app)
        XCTAssertEqual(app.descendants(matching: .any)["host.status"].value as? String, "online")
    }

    func testOfflineHostIsNamedWithFakeBridge() {
        // First run: a task completes against the in-process FakeBridge host.
        var app = launch(["-DSHMFakeBridge", "YES", "-DSHMResetStore", "YES"])
        send(app, "Offline check")
        let status = app.descendants(matching: .any)["task.status"]
        poll(30, "the task to complete") { value(status) == "completed" }
        app.terminate()

        // Next launch: the same host is unreachable. The list stays, and names the host.
        app = launch(["-DSHMFakeBridge", "offline"])
        openDrawer(app)
        let host = app.descendants(matching: .any)["host.status"]
        XCTAssertTrue(host.waitForExistence(timeout: 10))
        poll(15, "the host to show as offline") { value(host) == "offline" }
        XCTAssertTrue(host.label.contains("FakeBridge Mac is offline"), host.label)
        app.buttons["drawer.allTasks"].tap()
        let row = app.buttons.matching(identifier: "tasklist.row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("Offline check"), row.label)

        // S21 seam: with no host online, the new session names the host on the all-offline card
        // (X3), and the send key is off instead of failing after the tap.
        newSession(app)
        let line = app.descendants(matching: .any).matching(identifier: "hosts.offlineCard.host").firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(line.label.contains("FakeBridge Mac"), line.label)
        let field = app.textFields["composer.prompt"]
        field.tap()
        field.typeText("Will not go out")
        let off = expectation(for: NSPredicate(format: "isEnabled == false"), evaluatedWith: app.buttons["composer.send"])
        wait(for: [off], timeout: 10)
        saveShot("s2-offline-fakebridge")
    }

    func testOfflineRealHostIsNamed() throws {
        try XCTSkipUnless(env["DSHM_EXPECT_OFFLINE"] == "1", "runs after testKillAndReopenAgainstRealDSH with the host stopped")
        let name = try XCTUnwrap(env["DSHM_HOST_NAME"])
        let app = launch(["-DSHMBridgePort", port])
        openDrawer(app)
        let host = app.descendants(matching: .any)["host.status"]
        XCTAssertTrue(host.waitForExistence(timeout: 10))
        poll(15, "the host to show as offline") { value(host) == "offline" }
        XCTAssertTrue(host.label.contains("\(name) is offline"), host.label)
        XCTAssertTrue(host.label.contains("Last connected"), host.label)
        // The cached list from the previous run is still there.
        app.buttons["drawer.allTasks"].tap()
        XCTAssertTrue(app.buttons.matching(identifier: "tasklist.row").firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        saveShot("s2-offline-real-host")
    }

    /// S2 × S3 seam (S2 landed second): list rows show the milestone card, and after kill/reopen
    /// with the host unreachable the card and the timeline still come from the cache.
    func testCachedMilestonesAfterKillAndReopenWithFakeBridge() {
        let prompt = "Milestone cache check"
        var app = launch(["-DSHMFakeBridge", "YES", "-DSHMFakeMilestones", "YES", "-DSHMResetStore", "YES"])
        send(app, prompt)
        var card = app.descendants(matching: .any)["milestone.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 20), app.debugDescription)
        let status = app.descendants(matching: .any)["task.status"]
        poll(30, "the task to complete") { value(status) == "completed" && value(card) == "3/3" }

        // The list row shows the card too.
        openAllTasks(app)
        var row = app.buttons.matching(identifier: "tasklist.row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(row.label.contains(prompt), row.label)
        XCTAssertTrue(row.label.contains("3 of 3"), row.label)
        // Let the coalesced save land (terminate() skips the background phase).
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.terminate()

        // Reopen with the host unreachable: nothing can come from the bridge, only the cache.
        app = launch(["-DSHMFakeBridge", "offline"])
        openDrawer(app)
        let host = app.descendants(matching: .any)["host.status"]
        XCTAssertTrue(host.waitForExistence(timeout: 10))
        poll(15, "the host to show as offline") { value(host) == "offline" }
        app.buttons["drawer.allTasks"].tap()
        row = app.buttons.matching(identifier: "tasklist.row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(row.label.contains(prompt), row.label)
        XCTAssertTrue(row.label.contains("3 of 3"), row.label)
        saveShot("s2-cached-milestones-list")

        row.tap()
        card = app.descendants(matching: .any)["milestone.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(value(card), "3/3")
        XCTAssertEqual(card.label, "Done")
        card.tap()
        let timeline = app.descendants(matching: .any)["milestone.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5), app.debugDescription)
        let first = app.descendants(matching: .any)["milestone.row.1"]
        XCTAssertTrue(first.waitForExistence(timeout: 3))
        XCTAssertEqual(value(first), "started")
        saveShot("s2-cached-milestones-timeline")
    }
}
