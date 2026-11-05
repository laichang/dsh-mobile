import XCTest

/// S3 demo in the Simulator (PLAN.md §5 S3): a multi-step task's todos tick off on the task card,
/// and the detail view shows the milestone timeline.
/// - `testTodosTickOffOnCardWithFakeBridge`, `testTimelineWithFakeBridge` need nothing else running
///   (`-DSHMFakeBridge YES -DSHMFakeMilestones YES`).
/// - `testMilestonesAgainstRealDSH` needs `node scripts/demo/s3-host.mjs` (real DSH + bridge, DSH's
///   mock LLM scripted to call `todo_write`) and runs only with TEST_RUNNER_DSHM_REAL_DSH=1;
///   scripts/demo/s3.sh sets that up.
/// Set TEST_RUNNER_DSHM_SHOT_DIR to save screenshots there.
@MainActor
final class S3MilestonesUITests: XCTestCase {
    static let todos = ["Read the project layout", "Write the summary", "Check the summary against the code"]

    override func setUp() {
        continueAfterFailure = false
    }

    private var env: [String: String] { ProcessInfo.processInfo.environment }

    private func saveShot(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = env["DSHM_SHOT_DIR"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    private func send(_ app: XCUIApplication, prompt: String) {
        let field = app.textFields["composer.prompt"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(prompt)
        app.buttons["composer.send"].tap()
    }

    /// One sample of the main screen while the task runs.
    private struct Sample: Equatable {
        var progress: String
        var headline: String
        var transcript: String
    }

    /// Samples the card until it shows `3/3` (or `timeout`); returns each distinct sample in order.
    /// Saves `shotAt` progress as a screenshot named `shotName`.
    private func watchCard(_ app: XCUIApplication, timeout: TimeInterval, shotAt: String, shotName: String) -> [Sample] {
        let card = app.descendants(matching: .any)["milestone.card"]
        let transcript = app.descendants(matching: .any)["transcript.text"]
        XCTAssertTrue(card.waitForExistence(timeout: timeout), app.debugDescription)
        var samples: [Sample] = []
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let s = Sample(progress: card.value as? String ?? "", headline: card.label,
                           transcript: transcript.value as? String ?? "")
            if samples.last != s {
                samples.append(s)
                if s.progress == shotAt, !samples.dropLast().contains(where: { $0.progress == shotAt }) { saveShot(shotName) }
            }
            if s.progress == "3/3" { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return samples
    }

    /// The card went 0/3 → 1/3 → 2/3 → 3/3, leading with the step being worked on, while the
    /// transcript was still empty: the card alone told the story.
    private func assertTicksOff(_ samples: [Sample], file: StaticString = #filePath, line: UInt = #line) {
        let progress = samples.map(\.progress).reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } }
        XCTAssertEqual(progress.filter { $0.hasSuffix("/3") }, ["0/3", "1/3", "2/3", "3/3"], "\(samples)", file: file, line: line)
        for (i, step) in Self.todos.enumerated() {
            XCTAssertTrue(samples.contains { $0.progress == "\(i)/3" && $0.headline == step }, "step \(i): \(samples)", file: file, line: line)
        }
        XCTAssertTrue(samples.filter { $0.progress != "3/3" }.allSatisfy { $0.transcript.isEmpty }, "\(samples)", file: file, line: line)
    }

    private func waitForEnd(_ app: XCUIApplication, timeout: TimeInterval) {
        let status = app.descendants(matching: .any)["task.status"]
        let done = expectation(for: NSPredicate(format: "value == 'completed' OR value == 'failed'"), evaluatedWith: status)
        wait(for: [done], timeout: timeout)
        XCTAssertEqual(status.value as? String, "completed", "status label: \(status.label)")
    }

    /// Opens the card and checks the timeline: the expected kinds in order, all todos done.
    private func assertTimeline(_ app: XCUIApplication, kinds: [String], shot: String) {
        let card = app.descendants(matching: .any)["milestone.card"]
        XCTAssertEqual(card.label, "Done")
        card.tap()
        let timeline = app.descendants(matching: .any)["milestone.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5), app.debugDescription)
        for (i, kind) in kinds.enumerated() {
            let row = app.descendants(matching: .any)["milestone.row.\(i + 1)"]
            if !row.exists { timeline.swipeUp() }
            XCTAssertTrue(row.waitForExistence(timeout: 3), "row \(i + 1): \(app.debugDescription)")
            XCTAssertEqual(row.value as? String, kind, "row \(i + 1): \(row.label)")
        }
        XCTAssertFalse(app.descendants(matching: .any)["milestone.row.\(kinds.count + 1)"].exists)
        timeline.swipeDown()
        for i in Self.todos.indices {
            let todo = app.descendants(matching: .any)["milestone.todo.\(i)"]
            XCTAssertTrue(todo.waitForExistence(timeout: 3))
            XCTAssertEqual(todo.value as? String, "completed")
            XCTAssertTrue(todo.label.contains(Self.todos[i]), todo.label)
        }
        saveShot(shot)
    }

    static let fakeKinds = ["started", "planned", "todoStarted", "todoDone", "todoStarted", "todoDone",
                            "todoStarted", "todoDone", "finished"]

    func testTodosTickOffOnCardWithFakeBridge() {
        let app = XCUIApplication()
        app.launchArguments = ["-DSHMFakeBridge", "YES", "-DSHMFakeMilestones", "YES"]
        app.launch()
        send(app, prompt: "Summarize this project in three steps.")
        let samples = watchCard(app, timeout: 20, shotAt: "2/3", shotName: "s3-fakebridge-card-ticking")
        assertTicksOff(samples)
        waitForEnd(app, timeout: 10)
        saveShot("s3-fakebridge-card-done")
    }

    func testTimelineWithFakeBridge() {
        let app = XCUIApplication()
        app.launchArguments = ["-DSHMFakeBridge", "YES", "-DSHMFakeMilestones", "YES"]
        app.launch()
        send(app, prompt: "Summarize this project in three steps.")
        waitForEnd(app, timeout: 30)
        assertTimeline(app, kinds: Self.fakeKinds, shot: "s3-fakebridge-timeline")
    }

    /// A bridge that sends no milestones (T0's FakeBridge script) gets T0's screen, no card.
    func testNoMilestonesNoCard() {
        let app = XCUIApplication()
        app.launchArguments = ["-DSHMFakeBridge", "YES"]
        app.launch()
        send(app, prompt: "Introduce yourself in one sentence.")
        waitForEnd(app, timeout: 15)
        XCTAssertFalse(app.descendants(matching: .any)["milestone.card"].exists)
    }

    func testMilestonesAgainstRealDSH() throws {
        try XCTSkipUnless(env["DSHM_REAL_DSH"] == "1", "needs scripts/demo/s3-host.mjs; run scripts/demo/s3.sh")
        let app = XCUIApplication()
        app.launchArguments = ["-DSHMBridgePort", env["DSHM_BRIDGE_PORT"] ?? "47812"]
        app.launch()
        send(app, prompt: "分三步总结这个项目。Summarize this project in three steps.")
        let samples = watchCard(app, timeout: 120, shotAt: "2/3", shotName: "s3-real-dsh-card-ticking")
        assertTicksOff(samples)
        waitForEnd(app, timeout: 60)
        saveShot("s3-real-dsh-card-done")
        // Real DSH: the first todo_write both plans and starts step 1; the last one ticks step 3.
        assertTimeline(app, kinds: ["started", "planned", "todoStarted", "todoDone", "todoStarted", "todoDone",
                                    "todoStarted", "todoDone", "finished"], shot: "s3-real-dsh-timeline")
    }
}
