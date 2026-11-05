import XCTest

@MainActor
final class S4ApprovalUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-DSHMBridgePort", env["DSHM_BRIDGE_PORT"] ?? "47810",
                               "-DSHMPresetPrompt", "delete /tmp/x"]
        if reset { app.launchArguments += ["-DSHMResetStore", "YES", "-DSHMResetPairing", "YES"] }
        app.launch()
        return app
    }

    private func send(_ app: XCUIApplication) {
        let send = app.buttons["composer.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        send.tap()
        XCTAssertTrue(app.descendants(matching: .any)["task.status"].waitForExistence(timeout: 20))
    }

    private func checkCommand(_ app: XCUIApplication, expected: String) {
        let command = app.staticTexts["approval.command"].firstMatch
        XCTAssertTrue(command.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertEqual(command.label, expected)
    }

    func testDenyExactCommandAndContinue() throws {
        try XCTSkipIf(env["DSHM_S4_COMMAND"] == nil, "needs the real approval host from scripts/demo/s4.sh")
        let command = try XCTUnwrap(env["DSHM_S4_COMMAND"])
        let app = launch(reset: true)
        send(app)
        checkCommand(app, expected: command)
        saveShot("s4-detail-pending")
        app.buttons["approval.deny"].tap()
        waitForValue(app.descendants(matching: .any)["task.status"], in: ["completed"], timeout: 30)
        XCTAssertEqual(app.descendants(matching: .any)["transcript.text"].value as? String, "Deletion denied. Task continued.")
        saveShot("s4-denied")
    }

    func testApprovalWaitsWhileClosedAndReturnsOnList() throws {
        try XCTSkipIf(env["DSHM_S4_COMMAND"] == nil, "needs the real approval host from scripts/demo/s4.sh")
        let command = try XCTUnwrap(env["DSHM_S4_COMMAND"])
        var app = launch(reset: true)
        send(app)
        app.terminate()
        app = launch(reset: false)
        checkCommand(app, expected: command)
        saveShot("s4-reopened-waiting")
        app.buttons["approval.deny"].firstMatch.tap()
        let row = app.buttons.matching(identifier: "tasklist.row").matching(NSPredicate(format: "label CONTAINS 'delete /tmp/x'")).firstMatch
        row.tap()
        waitForValue(app.descendants(matching: .any)["task.status"], in: ["completed"], timeout: 30)
        XCTAssertEqual(app.descendants(matching: .any)["transcript.text"].value as? String, "Deletion denied. Task continued.")
    }

    /// X1's control plugin creates a session through DSH directly (no CreateTask), and its web
    /// peer answers over the same remote-event gateway as the browser.
    func testUpstreamWebApprovalAppearsAfterReconnectAndWebAnswerWithdrawsIt() async throws {
        try XCTSkipIf(env["DSHM_S4_CONTROL"] == nil, "needs the real approval host from scripts/demo/s4.sh")
        let controlPort = try XCTUnwrap(env["DSHM_S4_CONTROL"])
        let command = try XCTUnwrap(env["DSHM_S4_COMMAND"])
        func post(_ path: String, _ body: [String: String] = [:]) async throws {
            let url = try XCTUnwrap(URL(string: "http://127.0.0.1:" + controlPort + path))
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertNil(result?["error"], String(decoding: data, as: UTF8.self))
        }

        var app = launch(reset: true)
        waitForValue(app.descendants(matching: .any)["host.status"], in: ["online"], timeout: 20)
        app.terminate()
        try await post("/fake-web/open")
        try await post("/task", ["prompt": "delete /tmp/x from the web session"])
        app = launch(reset: false)
        checkCommand(app, expected: command)
        saveShot("s4-upstream-reopened")
        try await post("/fake-web/answer", ["outcome": "rejected"])
        let card = app.staticTexts["approval.command"].firstMatch
        XCTAssertTrue(card.waitForNonExistence(timeout: 10))
        try await post("/fake-web/close")
    }

    func testSwitchWhileHeldResumeThenInterrupt() throws {
        try XCTSkipIf(env["DSHM_S4_COMMAND"] == nil, "needs scripts/demo/s4.sh")
        let command = try XCTUnwrap(env["DSHM_S4_COMMAND"])
        var app = launch(reset: true)
        let picker = app.buttons["model.open"]
        XCTAssertTrue(picker.waitForExistence(timeout: 20))
        picker.tap()
        let low = app.buttons["model.effort.low"]
        XCTAssertTrue(low.waitForExistence(timeout: 10))
        low.tap()
        app.buttons["model.apply"].tap()
        send(app)
        checkCommand(app, expected: command)

        picker.tap()
        let high = app.buttons["model.effort.high"]
        XCTAssertTrue(high.waitForExistence(timeout: 10))
        high.tap()
        app.buttons["model.apply"].tap()
        var transcript = app.descendants(matching: .any)["transcript.text"]
        wait(for: [expectation(for: NSPredicate(format: "value CONTAINS %@", " · high]"), evaluatedWith: transcript)], timeout: 15)
        checkCommand(app, expected: command)
        app.terminate()

        app = launch(reset: false)
        checkCommand(app, expected: command)
        let row = app.buttons.matching(identifier: "tasklist.row").matching(NSPredicate(format: "value == 'waitingOnUser'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), app.debugDescription)
        row.tap()
        transcript = app.descendants(matching: .any)["transcript.text"]
        XCTAssertTrue((transcript.value as? String)?.contains(" · high]") == true)
        let stop = app.buttons["task.interrupt"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        stop.tap()
        waitForValue(app.descendants(matching: .any)["task.status"], in: ["interrupted"], timeout: 30)
        XCTAssertTrue(app.buttons["approval.allow"].waitForNonExistence(timeout: 5))
        saveShot("s4-interrupted-held-task")
    }
}
