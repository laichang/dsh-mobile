import XCTest

/// Voice input (ARCHITECTURE D116, D117) with the fake transcriber (`-DSHMFakeSpeech`) and the
/// FakeBridge: the mic key on 01 and on the session page writes what it hears into the field,
/// and nothing goes until the user taps send. With speech permission denied, the mic says how to
/// turn it on and the field does not change. Run by scripts/demo/voice.sh.
@MainActor
final class VoiceUITests: XCTestCase {
    /// What the fake transcriber "hears".
    static let phrase = "把桌面上的截图整理到一个文件夹"

    override func setUp() {
        continueAfterFailure = false
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    func launch(speech: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-DSHMFakeBridge", "YES", "-DSHMResetStore", "YES", "-DSHMResetPairing", "YES",
                               "-DSHMFakeScenario", "conversation", "-DSHMFakeSpeech", speech]
        app.launch()
        return app
    }

    func testDictateATaskThenAFollowUpAndSend() throws {
        let app = launch(speech: Self.phrase)

        // 01: the mic fills the field as the fake speaks; nothing is sent by itself.
        let field = app.textFields["composer.prompt"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), app.debugDescription)
        let send = app.buttons["composer.send"]
        XCTAssertFalse(send.isEnabled, "nothing to send yet")
        let mic = app.buttons["composer.mic"]
        XCTAssertTrue(mic.waitForExistence(timeout: 5), app.debugDescription)
        mic.tap()
        let notice = any(app, "voice.notice")
        XCTAssertTrue(notice.waitForExistence(timeout: 5), "the line says it listens\n\(app.debugDescription)")
        XCTAssertEqual(mic.value as? String, "listening")
        // The words come into the field while it listens (DictationTests check each partial result).
        let words = expectation(for: NSPredicate(format: "value BEGINSWITH '把桌'"), evaluatedWith: field)
        wait(for: [words], timeout: 10)
        saveShot("voice-listening")
        waitForValue(field, in: [Self.phrase], timeout: 15)
        waitForValue(mic, in: ["idle"], timeout: 10)
        XCTAssertTrue(notice.waitForNonExistence(timeout: 5))
        sleep(1)
        XCTAssertFalse(any(app, "task.status").exists, "nothing is sent without a tap")
        XCTAssertTrue(send.isEnabled)
        saveShot("voice-composer")

        // Tap send: the task starts with the dictated text.
        send.tap()
        let status = any(app, "task.status")
        XCTAssertTrue(status.waitForExistence(timeout: 15), app.debugDescription)
        let bubbles = app.descendants(matching: .any).matching(identifier: "session.message.user")
        XCTAssertTrue(bubbles.firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(bubbles.firstMatch.label, Self.phrase)
        waitForValue(status, in: ["completed"], timeout: 30)

        // The session page: typed text, then the mic; the dictated words go after it.
        let followUp = app.textFields["session.followUp"]
        XCTAssertTrue(followUp.waitForExistence(timeout: 15), app.debugDescription)
        followUp.tap()
        followUp.typeText("Also: ")
        let sessionMic = app.buttons["session.mic"]
        XCTAssertTrue(sessionMic.waitForExistence(timeout: 5), app.debugDescription)
        sessionMic.tap()
        let expected = "Also: " + Self.phrase
        waitForValue(followUp, in: [expected], timeout: 15)
        waitForValue(sessionMic, in: ["idle"], timeout: 10)
        sleep(1)
        XCTAssertEqual(bubbles.count, 1, "nothing is sent without a tap")
        saveShot("voice-followup")
        let sessionSend = app.buttons["session.send"]
        XCTAssertTrue(sessionSend.isEnabled)
        sessionSend.tap()
        let both = expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: bubbles)
        wait(for: [both], timeout: 20)
        XCTAssertEqual(bubbles.element(boundBy: 1).label, expected)
        saveShot("voice-followup-sent")
    }

    func testDeniedSpeechSaysHowToTurnItOnAndKeepsTheField() throws {
        let app = launch(speech: "denied")
        let field = app.textFields["composer.prompt"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), app.debugDescription)
        field.tap()
        field.typeText("keep this")
        let mic = app.buttons["composer.mic"]
        XCTAssertTrue(mic.waitForExistence(timeout: 5), app.debugDescription)
        mic.tap()

        let notice = any(app, "voice.notice")
        XCTAssertTrue(notice.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(notice.value as? String, "denied")
        XCTAssertTrue(app.buttons["voice.openSettings"].exists, "it tells how to turn it on\n\(app.debugDescription)")
        let line = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'dsh-mobile'")).firstMatch
        XCTAssertTrue(line.exists, app.debugDescription)
        sleep(1)
        XCTAssertEqual(field.value as? String, "keep this", "the field does not change")
        XCTAssertEqual(mic.value as? String, "idle", "it does not listen")
        XCTAssertFalse(any(app, "task.status").exists, "nothing is sent")
        saveShot("voice-denied")
    }

    /// The real Speech framework path (no `-DSHMFakeSpeech`): a tap on the mic asks the system for
    /// speech recognition and the microphone. The system answers on a queue of its own; a
    /// main-actor callback crashed the app there on a real iPhone (ARCHITECTURE D146). The test
    /// allows speech recognition and turns off the microphone, so the engine never starts (no
    /// microphone prompt on the Mac), and the app must stay up and say voice input is off.
    func testRealPermissionPromptsDoNotCrashTheApp() throws {
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .microphone)
        app.launchArguments = ["-DSHMFakeBridge", "YES", "-DSHMResetStore", "YES", "-DSHMResetPairing", "YES",
                               "-DSHMFakeScenario", "conversation"]
        app.launch()
        let mic = app.buttons["composer.mic"]
        XCTAssertTrue(mic.waitForExistence(timeout: 15), app.debugDescription)
        mic.tap()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let notice = any(app, "voice.notice")
        var answered: [String] = []
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            XCTAssertEqual(app.state, .runningForeground, "the app crashed after the permission answers \(answered)")
            if notice.exists, let value = notice.value as? String, value != "listening" { break }
            let alert = springboard.alerts.firstMatch
            if alert.exists {
                let label = alert.label
                let microphone = label.localizedCaseInsensitiveContains("microphone")
                let choice = microphone
                    ? alert.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Don'")).firstMatch
                    : alert.buttons.matching(NSPredicate(format: "NOT (label BEGINSWITH 'Don')")).firstMatch // "OK" or "Allow"
                if choice.exists {
                    choice.tap()
                    answered.append(microphone ? "microphone: no" : "speech: yes")
                }
            }
            usleep(250_000)
        }
        sleep(2)
        XCTAssertEqual(app.state, .runningForeground, "the app crashed after the permission answers \(answered)")
        XCTAssertTrue(notice.waitForExistence(timeout: 5), "answers \(answered)\n\(app.debugDescription)")
        XCTAssertEqual(notice.value as? String, "denied", "the microphone is off, so voice input says how to turn it on")
        XCTAssertEqual(mic.value as? String, "idle")
        saveShot("voice-real-permission")
    }
}
