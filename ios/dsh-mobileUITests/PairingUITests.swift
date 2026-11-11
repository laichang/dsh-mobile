import XCTest

/// Pair + encrypt in the Simulator, against the real bridge inside a real DSH
/// (scripts/demo/pairing.sh starts it and mints the pairing links). Needs:
/// - TEST_RUNNER_DSHM_PAIR_URL: a fresh single-use `dshm://pair?…` from `bridge/lib/scripts/pair.js --url-only`;
/// - TEST_RUNNER_DSHM_EXPIRED_PAIR_URL (optional): one that has already expired.
/// Skipped without them. Helpers: UITestSupport.swift.
@MainActor
final class PairingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Pair through the deep link (IKpsk1), then the round-trip demo over Noise (IK reconnect) against
    /// the local bridge; then the same link again is refused because the secret was used.
    func testPairViaDeepLinkThenDemoOverNoise() throws {
        try XCTSkipUnless(env["DSHM_PAIR_URL"] != nil, "needs a pairing link; run scripts/demo/pairing.sh")
        let link = try XCTUnwrap(env["DSHM_PAIR_URL"].flatMap(URL.init(string:)))
        let app = XCUIApplication()
        app.launchArguments = ["-DSHMResetPairing", "YES", "-DSHMBridgePort", env["DSHM_BRIDGE_PORT"] ?? "47801"]
        app.launch()
        // Unpaired Debug build: the plaintext dev path. Host rows are in the drawer.
        openDrawer(app)
        let channel = app.descendants(matching: .any)["host.channel"]
        XCTAssertTrue(channel.waitForExistence(timeout: 10))
        XCTAssertEqual(channel.value as? String, "plaintext")

        // Pair.
        var reopened = openDeepLink(link)
        let confirm = reopened.buttons["pairing.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), reopened.debugDescription)
        saveShot("pairing-pair-review")
        confirm.tap()
        let status = reopened.descendants(matching: .any)["pairing.status"]
        XCTAssertEqual(waitForValue(status, in: ["paired", "failed"], timeout: 20), "paired", status.label)
        saveShot("pairing-paired")
        reopened.buttons["pairing.done"].tap()

        // The round-trip demo, now over Noise to the paired host.
        openDrawer(reopened)
        let noise = reopened.descendants(matching: .any)["host.channel"]
        XCTAssertTrue(noise.waitForExistence(timeout: 10))
        XCTAssertEqual(noise.value as? String, "noise")
        // A unique prompt per run: real DSH keeps every earlier run, and the list shows only the rows
        // on screen, so a repeated prompt never adds a row that the wait can see.
        let text = runDemo(reopened, prompt: "用一句话介绍你自己。#\(UUID().uuidString.prefix(6))", timeout: 120)
        XCTAssertTrue(text.contains("streamed through the dsh-mobile bridge"), text)
        saveShot("pairing-demo-over-noise")

        // The same QR again: the one-time secret is spent, so the bridge refuses it.
        reopened = openDeepLink(link)
        let again = reopened.buttons["pairing.confirm"]
        XCTAssertTrue(again.waitForExistence(timeout: 10))
        again.tap()
        let refused = reopened.descendants(matching: .any)["pairing.status"]
        XCTAssertEqual(waitForValue(refused, in: ["paired", "failed"], timeout: 20), "failed")
        XCTAssertTrue(refused.label.contains("pairing secret used"), refused.label)
        saveShot("pairing-reused-code-refused")
        reopened.buttons["pairing.close"].tap()
        // Still paired: the refusal didn't touch the existing pairing.
        openDrawer(reopened)
        XCTAssertEqual(reopened.descendants(matching: .any)["host.channel"].value as? String, "noise")
    }

    /// After a relaunch the app reconnects to the paired host over Noise with no pairing step.
    /// Runs after the test above (XCTest orders tests by name: Pair < Relaunch).
    func testRelaunchReconnectsOverNoise() throws {
        try XCTSkipUnless(env["DSHM_PAIR_URL"] != nil, "run scripts/demo/pairing.sh")
        let app = XCUIApplication()
        app.launch()
        openDrawer(app)
        let channel = app.descendants(matching: .any)["host.channel"]
        XCTAssertTrue(channel.waitForExistence(timeout: 10))
        XCTAssertEqual(channel.value as? String, "noise")
        let text = runDemo(app, prompt: "Again, after a relaunch.", timeout: 120)
        XCTAssertTrue(text.contains("streamed through the dsh-mobile bridge"), text)
    }

    /// An expired code is refused (by the app before connecting; the bridge refuses it too).
    func testExpiredPairingLinkIsRefused() throws {
        try XCTSkipUnless(env["DSHM_EXPIRED_PAIR_URL"] != nil, "needs an expired pairing link; run scripts/demo/pairing.sh")
        let link = try XCTUnwrap(env["DSHM_EXPIRED_PAIR_URL"].flatMap(URL.init(string:)))
        let app = XCUIApplication()
        app.launchArguments = ["-DSHMResetPairing", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["pairing.pasteLink"].waitForExistence(timeout: 10))
        let reopened = openDeepLink(link)
        let confirm = reopened.buttons["pairing.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()
        let status = reopened.descendants(matching: .any)["pairing.status"]
        XCTAssertEqual(waitForValue(status, in: ["paired", "failed"], timeout: 20), "failed")
        XCTAssertTrue(status.label.contains("expired"), status.label)
        saveShot("pairing-expired-code-refused")
    }

    // MARK: - Pairing with the durable list: kill/reopen over Noise resumes from the cursor

    /// Phase 1 of 2 (scripts/demo/pairing.sh, TEST_RUNNER_DSHM_RESUME_PHASE=1, after the pairing tests):
    /// the paired app connects over Noise, catches up, and is killed. pairing.sh then runs a task on the
    /// bridge from the CLI while the app is gone.
    func testResumeOverNoisePhase1KillWhileConnected() throws {
        try XCTSkipUnless(env["DSHM_RESUME_PHASE"] == "1", "run scripts/demo/pairing.sh")
        let app = XCUIApplication()
        app.launch()
        openDrawer(app)
        let channel = app.descendants(matching: .any)["host.channel"]
        XCTAssertTrue(channel.waitForExistence(timeout: 10))
        XCTAssertEqual(channel.value as? String, "noise")
        let host = app.descendants(matching: .any)["host.status"]
        XCTAssertEqual(waitForValue(host, in: ["online"], timeout: 30), "online", host.label)
        // Let the cursor's coalesced save land (terminate() skips the background phase).
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.terminate()
    }

    /// Phase 2 of 2 (TEST_RUNNER_DSHM_RESUME_PHASE=2, TEST_RUNNER_DSHM_GAP_PROMPT = the CLI task's
    /// prompt): reopened, the app reconnects with a fresh IK handshake (no pairing step) and
    /// resumes from its cursor; the task it missed arrives with its whole transcript, which only
    /// the replay carries (ListTasks has no text).
    func testResumeOverNoisePhase2GapFilled() throws {
        try XCTSkipUnless(env["DSHM_RESUME_PHASE"] == "2", "run scripts/demo/pairing.sh")
        let prompt = try XCTUnwrap(env["DSHM_GAP_PROMPT"])
        let app = XCUIApplication()
        app.launch()
        openDrawer(app)
        let channel = app.descendants(matching: .any)["host.channel"]
        XCTAssertTrue(channel.waitForExistence(timeout: 10))
        XCTAssertEqual(channel.value as? String, "noise")
        app.buttons["drawer.allTasks"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier == 'tasklist.row' AND label CONTAINS %@", prompt)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), app.debugDescription)
        saveShot("pairing-resumed-over-noise-list")
        row.tap()
        let status = app.descendants(matching: .any)["task.status"]
        XCTAssertEqual(waitForValue(status, in: ["completed"], timeout: 30), "completed", status.label)
        let transcript = app.descendants(matching: .any)["transcript.text"]
        XCTAssertTrue((transcript.value as? String ?? "").contains("streamed through the dsh-mobile bridge"),
                      transcript.value as? String ?? "")
        saveShot("pairing-resumed-over-noise-detail")
    }
}
