import XCTest

/// Milestones demo in the Simulator: a multi-step task's todos tick off on the task card,
/// and the detail view shows the milestone timeline.
/// - `testTodosTickOffOnCardWithFakeBridge`, `testTimelineWithFakeBridge` need nothing else running
///   (`-DSHMFakeBridge YES -DSHMFakeMilestones YES`).
/// - `testMilestonesAgainstRealDSH` needs `node scripts/demo/milestones-host.mjs` (real DSH + bridge, DSH's
///   mock LLM scripted to call `todo_write`) and runs only with TEST_RUNNER_DSHM_REAL_DSH=1;
///   scripts/demo/milestones.sh sets that up.
/// Set TEST_RUNNER_DSHM_SHOT_DIR to save screenshots there.
@MainActor
final class MilestonesUITests: XCTestCase {
    static let todos = ["Read the project layout", "Write the summary", "Check the summary against the code"]

    override func setUp() {
        continueAfterFailure = false
    }



    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + arguments
        if arguments.contains("-DSHMBridgePort") { launchEnrolled(app) } else { app.launch() }
        return app
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
            // Transcript first: the reply only starts after the last todo is done, so if the card
            // still shows less than 3/3 *after* this read, the transcript was empty at that point.
            let text = transcript.value as? String ?? ""
            let s = Sample(progress: card.value as? String ?? "", headline: card.label, transcript: text)
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
        // The todos are on top. Check them first: the timeline is a sheet, and a swipe
        // down at the top of it would close it.
        for i in Self.todos.indices {
            let todo = app.descendants(matching: .any)["milestone.todo.\(i)"]
            XCTAssertTrue(todo.waitForExistence(timeout: 3))
            XCTAssertEqual(todo.value as? String, "completed")
            XCTAssertTrue(todo.label.contains(Self.todos[i]), todo.label)
        }
        for (i, kind) in kinds.enumerated() {
            let row = app.descendants(matching: .any)["milestone.row.\(i + 1)"]
            if !row.exists { timeline.swipeUp() }
            XCTAssertTrue(row.waitForExistence(timeout: 3), "row \(i + 1): \(app.debugDescription)")
            XCTAssertEqual(row.value as? String, kind, "row \(i + 1): \(row.label)")
        }
        XCTAssertFalse(app.descendants(matching: .any)["milestone.row.\(kinds.count + 1)"].exists)
        saveShot(shot)
    }

    static let fakeKinds = ["started", "planned", "todoStarted", "todoDone", "todoStarted", "todoDone",
                            "todoStarted", "todoDone", "finished"]

    func testTodosTickOffOnCardWithFakeBridge() {
        let app = launch(["-DSHMFakeBridge", "YES", "-DSHMFakeMilestones", "YES"])
        send(app, "Summarize this project in three steps.")
        let samples = watchCard(app, timeout: 20, shotAt: "2/3", shotName: "milestones-fakebridge-card-ticking")
        assertTicksOff(samples)
        waitForEnd(app, timeout: 10)
        saveShot("milestones-fakebridge-card-done")
    }

    func testTimelineWithFakeBridge() {
        let app = launch(["-DSHMFakeBridge", "YES", "-DSHMFakeMilestones", "YES"])
        send(app, "Summarize this project in three steps.")
        waitForEnd(app, timeout: 30)
        assertTimeline(app, kinds: Self.fakeKinds, shot: "milestones-fakebridge-timeline")
    }

    /// A bridge that sends no milestones (the plain FakeBridge script) gets the plain screen, no card.
    func testNoMilestonesNoCard() {
        let app = launch(["-DSHMFakeBridge", "YES"])
        send(app, "Introduce yourself in one sentence.")
        waitForEnd(app, timeout: 15)
        XCTAssertFalse(app.descendants(matching: .any)["milestone.card"].exists)
    }

    func testMilestonesAgainstRealDSH() throws {
        try XCTSkipUnless(env["DSHM_REAL_DSH"] == "1", "needs scripts/demo/milestones-host.mjs; run scripts/demo/milestones.sh")
        let app = launch(["-DSHMBridgePort", env["DSHM_BRIDGE_PORT"] ?? "47812"])
        send(app, "分三步总结这个项目。Summarize this project in three steps.")
        let samples = watchCard(app, timeout: 120, shotAt: "2/3", shotName: "milestones-real-dsh-card-ticking")
        assertTicksOff(samples)
        waitForEnd(app, timeout: 60)
        saveShot("milestones-real-dsh-card-done")
        // Real DSH: the first todo_write both plans and starts step 1; the last one ticks step 3.
        assertTimeline(app, kinds: ["started", "planned", "todoStarted", "todoDone", "todoStarted", "todoDone",
                                    "todoStarted", "todoDone", "finished"], shot: "milestones-real-dsh-timeline")
    }
}
