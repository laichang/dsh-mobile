import XCTest

/// S20 · the workspace sheet (07) and the model sheet (M, X4) (PLAN.md §5 S20), against two
/// in-process FakeBridge hosts with models and workspaces (`-DSHMFakeBridge pickers`).
/// MacBook-Pro is the default host; its DeepSeek-V41-Pro leaves the catalog once a task uses it.
/// The app runs in Chinese, like the design board; the checks use identifiers, values and paths.
/// Every check of a label, value or enabled state waits with a predicate (the Mac is often slow).
/// scripts/demo/s20.sh runs these; TEST_RUNNER_DSHM_SHOT_DIR keeps the screenshots.
@MainActor
final class S20PickersUITests: XCTestCase {
    static let mac = "MacBook-Pro"
    static let office = "Office-PC"
    static let repo = "/Users/laichang/code/dsh-mobile"
    static let officeReports = "/home/laichang/reports"
    static let flash = "model.option.deepseek.deepseek-v41-flash"
    static let pro = "model.option.deepseek.deepseek-v41-pro"

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(reset: Bool, hold: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-DSHMResetPairing", "YES",
                               "-DSHMFakeBridge", "pickers"]
        if reset { app.launchArguments += ["-DSHMResetStore", "YES"] }
        if let hold { app.launchArguments += ["-DSHMFakeHold", hold] }
        app.launch()
        return app
    }

    /// Waits until `element` matches `format`.
    private func expect(_ element: XCUIElement, _ format: String, _ args: Any..., timeout: TimeInterval = 15,
                        file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: format, argumentArray: args)
        let result = XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout)
        XCTAssertEqual(result, .completed, "\(element) never matched \(predicate)\n\(XCUIApplication().debugDescription)",
                       file: file, line: line)
    }

    private func workspaceButton(_ app: XCUIApplication) -> XCUIElement { app.buttons["workspace.open"] }

    private func openWorkspaceSheet(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let open = workspaceButton(app)
        expect(open, "exists == true AND hittable == true", timeout: 20, file: file, line: line)
        open.tap()
        expect(app.buttons["workspace.option.default"], "exists == true", file: file, line: line)
    }

    private func sendPrompt(_ app: XCUIApplication, _ text: String) {
        send(app, text)
        XCTAssertTrue(app.descendants(matching: .any)["task.status"].waitForExistence(timeout: 20), app.debugDescription)
    }

    // MARK: - Done when

    /// The workspace choice is for one new session: a sent task and a relaunch go back to the
    /// host default. The sheet has the host switch at the top, the host default, recent
    /// workspaces with their paths, and an absolute path on this host.
    func testWorkspaceChoiceDoesNotStayAfterRelaunch() {
        var app = launch(reset: true)
        expect(workspaceButton(app), "value == 'default'", timeout: 20)
        openWorkspaceSheet(app)
        let host = app.buttons["workspace.host"]
        expect(host, "label == %@", Self.mac)
        expect(app.buttons["workspace.option.default"], "label == '/Users/laichang'")
        let repo = app.buttons["workspace.option." + Self.repo]
        expect(repo, "exists == true")
        XCTAssertTrue(app.textFields["workspace.path"].exists)
        saveShot("s20-workspace-sheet")

        // The host switch at the top changes the list to that host's workspaces, and back.
        host.tap()
        app.buttons[Self.office].tap()
        expect(host, "label == %@", Self.office)
        expect(app.buttons["workspace.option." + Self.officeReports], "exists == true")
        host.tap()
        app.buttons[Self.mac].tap()
        expect(host, "label == %@", Self.mac)
        expect(repo, "exists == true")
        repo.tap()

        // The pick shows on the "host · workspace" line.
        expect(workspaceButton(app), "value == %@ AND label == 'dsh-mobile'", Self.repo)
        saveShot("s20-workspace-picked")

        // A sent task used it; the next new session goes back to the default.
        sendPrompt(app, "看一下这个仓库")
        newSession(app)
        expect(workspaceButton(app), "value == 'default'")

        // Pick it again, then relaunch: the app opens with the default again.
        openWorkspaceSheet(app)
        app.buttons["workspace.option." + Self.repo].tap()
        expect(workspaceButton(app), "value == %@", Self.repo)
        app.terminate()
        app = launch(reset: false)
        expect(workspaceButton(app), "value == 'default' AND label == '默认工作区'", timeout: 20)
        saveShot("s20-relaunch-default")
    }

    /// Pick dsh-mobile and DeepSeek-V41-Pro; Pro then leaves the host. The sheet names Pro and
    /// the host, selects no other model, and keeps 应用 off until the user picks one.
    func testUnavailableModelKeepsApplyOffAndSelectsNothing() {
        let app = launch(reset: true, hold: "修复")
        openWorkspaceSheet(app)
        app.buttons["workspace.option." + Self.repo].tap()
        expect(workspaceButton(app), "value == %@", Self.repo)

        // Screen M: groups by provider, original names, effort as its own group, the host
        // default, and the provider whose list failed as one row with 重试.
        let pill = app.buttons["model.open"]
        expect(pill, "label BEGINSWITH 'DeepSeek-V41-Flash'", timeout: 20)
        pill.tap()
        let flash = app.buttons[Self.flash], pro = app.buttons[Self.pro]
        expect(flash, "selected == true")
        expect(pro, "selected == false")
        expect(app.buttons["model.effort.high"], "selected == true")
        XCTAssertTrue(app.buttons["model.retry.openrouter"].exists, app.debugDescription)
        expect(app.descendants(matching: .any)["model.provider"], "label CONTAINS %@", Self.mac)
        saveShot("s20-model-sheet")
        pro.tap()
        expect(pro, "selected == true")
        expect(flash, "selected == false")
        let apply = app.buttons["model.apply"]
        expect(apply, "enabled == true")
        apply.tap()
        expect(pill, "label BEGINSWITH 'DeepSeek-V41-Pro'")

        // The task runs with Pro (the FakeBridge holds it); then Pro is gone on MacBook-Pro.
        sendPrompt(app, "修复 CI 挂掉的测试")
        expect(app.descendants(matching: .any)["task.status"], "value == 'running'")
        expect(pill, "label BEGINSWITH 'DeepSeek-V41-Pro'")
        pill.tap()

        // Screen X4: the note names the model and the host; nothing is selected; 应用 is off.
        let note = app.descendants(matching: .any)["model.unavailable"]
        expect(note, "label CONTAINS 'DeepSeek-V41-Pro' AND label CONTAINS %@", Self.mac)
        expect(pro, "value == 'unavailable' AND enabled == false")
        expect(apply, "enabled == false")
        let selected = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'model.' AND selected == true"))
        expect(selected.firstMatch, "exists == false")
        XCTAssertEqual(selected.count, 0, app.debugDescription)
        expect(flash, "value == 'default'")
        saveShot("s20-model-unavailable")

        // A new pick turns 应用 on, and the task runs on with it.
        flash.tap()
        expect(flash, "selected == true")
        expect(apply, "enabled == true")
        apply.tap()
        expect(note, "exists == false")
        expect(pill, "label BEGINSWITH 'DeepSeek-V41-Flash'")
        expect(app.descendants(matching: .any)["task.status"], "value == 'running'")
    }
}
