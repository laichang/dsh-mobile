import XCTest

/// S1 · Pair + encrypt in the Simulator (PLAN §5 S1), against the real bridge inside a real DSH
/// (scripts/demo/s1.sh starts it and mints the pairing links). Needs:
/// - TEST_RUNNER_DSHM_PAIR_URL: a fresh single-use `dshm://pair?…` from `bridge/lib/scripts/pair.js --url-only`;
/// - TEST_RUNNER_DSHM_EXPIRED_PAIR_URL (optional): one that has already expired.
/// Skipped without them. Helpers: UITestSupport.swift.
@MainActor
final class S1PairingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Pair through the deep link (IKpsk1), then the T0 demo over Noise (IK reconnect) against
    /// the local bridge; then the same link again is refused because the secret was used.
    func testPairViaDeepLinkThenDemoOverNoise() throws {
        try XCTSkipUnless(env["DSHM_PAIR_URL"] != nil, "needs a pairing link; run scripts/demo/s1.sh")
        let link = try XCTUnwrap(env["DSHM_PAIR_URL"].flatMap(URL.init(string:)))
        let app = XCUIApplication()
        app.launchArguments = ["-DSHMResetPairing", "YES", "-DSHMBridgePort", env["DSHM_BRIDGE_PORT"] ?? "47801"]
        app.launch()
        // Unpaired Debug build: T0's plaintext dev path.
        let channel = app.descendants(matching: .any)["host.channel"]
        XCTAssertTrue(channel.waitForExistence(timeout: 10))
        XCTAssertEqual(channel.value as? String, "plaintext")

        // Pair.
        var reopened = openDeepLink(link)
        let confirm = reopened.buttons["pairing.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), reopened.debugDescription)
        saveShot("s1-pair-review")
        confirm.tap()
        let status = reopened.descendants(matching: .any)["pairing.status"]
        XCTAssertEqual(waitForValue(status, in: ["paired", "failed"], timeout: 20), "paired", status.label)
        saveShot("s1-paired")
        reopened.buttons["pairing.done"].tap()

        // The T0 demo, now over Noise to the paired host.
        let noise = reopened.descendants(matching: .any)["host.channel"]
        XCTAssertTrue(noise.waitForExistence(timeout: 10))
        XCTAssertEqual(noise.value as? String, "noise")
        let text = runDemo(reopened, prompt: "用一句话介绍你自己。", timeout: 120)
        XCTAssertTrue(text.contains("streamed through the dsh-mobile bridge"), text)
        saveShot("s1-demo-over-noise")

        // The same QR again: the one-time secret is spent, so the bridge refuses it.
        reopened = openDeepLink(link)
        let again = reopened.buttons["pairing.confirm"]
        XCTAssertTrue(again.waitForExistence(timeout: 10))
        again.tap()
        let refused = reopened.descendants(matching: .any)["pairing.status"]
        XCTAssertEqual(waitForValue(refused, in: ["paired", "failed"], timeout: 20), "failed")
        XCTAssertTrue(refused.label.contains("pairing secret used"), refused.label)
        saveShot("s1-reused-code-refused")
        reopened.buttons["pairing.close"].tap()
        // Still paired: the refusal didn't touch the existing pairing.
        XCTAssertEqual(reopened.descendants(matching: .any)["host.channel"].value as? String, "noise")
    }

    /// After a relaunch the app reconnects to the paired host over Noise with no pairing step.
    /// Runs after the test above (XCTest orders tests by name: Pair < Relaunch).
    func testRelaunchReconnectsOverNoise() throws {
        try XCTSkipUnless(env["DSHM_PAIR_URL"] != nil, "run scripts/demo/s1.sh")
        let app = XCUIApplication()
        app.launch()
        let channel = app.descendants(matching: .any)["host.channel"]
        XCTAssertTrue(channel.waitForExistence(timeout: 10))
        XCTAssertEqual(channel.value as? String, "noise")
        let text = runDemo(app, prompt: "Again, after a relaunch.", timeout: 120)
        XCTAssertTrue(text.contains("streamed through the dsh-mobile bridge"), text)
    }

    /// An expired code is refused (by the app before connecting; the bridge refuses it too).
    func testExpiredPairingLinkIsRefused() throws {
        try XCTSkipUnless(env["DSHM_EXPIRED_PAIR_URL"] != nil, "needs an expired pairing link; run scripts/demo/s1.sh")
        let link = try XCTUnwrap(env["DSHM_EXPIRED_PAIR_URL"].flatMap(URL.init(string:)))
        let app = XCUIApplication()
        app.launchArguments = ["-DSHMResetPairing", "YES"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["host.channel"].waitForExistence(timeout: 10))
        let reopened = openDeepLink(link)
        let confirm = reopened.buttons["pairing.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()
        let status = reopened.descendants(matching: .any)["pairing.status"]
        XCTAssertEqual(waitForValue(status, in: ["paired", "failed"], timeout: 20), "failed")
        XCTAssertTrue(status.label.contains("expired"), status.label)
        saveShot("s1-expired-code-refused")
    }
}
