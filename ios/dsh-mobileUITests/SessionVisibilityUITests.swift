import XCTest

@MainActor
final class SessionVisibilityUITests: XCTestCase {
    func testWebTurnsUpdateOpenDetailAndResumeAfterDisconnect() throws {
        continueAfterFailure = false
        let signals = URL(fileURLWithPath: try XCTUnwrap(env["DSHM_VISIBILITY_SIGNALS"]))
        func signal(_ name: String) throws { try Data().write(to: signals.appendingPathComponent(name)) }
        let port = try String(contentsOf: signals.appendingPathComponent("phone-port"), encoding: .utf8)
        let app = XCUIApplication()
        app.launchArguments = ["-DSHMBridgePort", port, "-DSHMResetStore", "YES", "-DSHMResetPairing", "YES"]
        app.launch()
        openAllTasks(app)

        let rows = app.buttons.matching(identifier: "tasklist.row")
        let row = rows.matching(NSPredicate(format: "label CONTAINS %@", "网页第一条")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertEqual(rows.count, 1)
        row.tap()
        let messages = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier IN %@", ["session.message.user", "session.message.assistant"]))
        let reply = "已收到。"
        func labels() -> [String] { messages.allElementsBoundByAccessibilityElement.map(\.label) }
        func verify(_ expected: [String]) {
            let arrived = expectation(for: NSPredicate { _, _ in labels() == expected }, evaluatedWith: app)
            wait(for: [arrived], timeout: 30)
            XCTAssertEqual(labels(), expected, app.debugDescription)
            XCTAssertEqual(messages.allElementsBoundByAccessibilityElement.map(\.identifier),
                           expected.indices.map { $0.isMultiple(of: 2) ? "session.message.user" : "session.message.assistant" })
        }

        let first = ["网页第一条", reply]
        verify(first)
        try signal("detail-open")
        let second = first + ["网页第二条", reply]
        verify(second)
        saveShot("session-visibility-live-turn")

        try signal("disconnect")
        let completed = expectation(for: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: signals.appendingPathComponent("offline-complete").path)
        }, evaluatedWith: app)
        wait(for: [completed], timeout: 90)
        XCTAssertEqual(labels(), second, "The phone must not receive the two Web turns while disconnected.")
        app.terminate()
        app.launchArguments = ["-DSHMBridgePort", port]
        app.launch()
        openAllTasks(app)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        verify(second)
        try signal("reconnect")
        verify(second + ["离线第三条", reply, "离线第四条", reply])
        saveShot("session-visibility-reconnected")
        try signal("verified")
    }
}
