import XCTest

/// S31 · pair over Tailscale (PLAN.md §5 S31, ARCHITECTURE D88). The bug (2026-11-08, real
/// iPhone 17 Pro): "couldn't reach the host at 30.34.227.222:47801, 100.79.171.34:47801". The
/// phone and the Mac were on one tailnet and Safari on the phone reached the bridge, but the app
/// sent no packet: App Transport Security refused cleartext `ws://` to an IP address outside the
/// local ranges (Tailscale's 100.64/10, a public 30.x), before any connect.
/// Real DSH + bridge on 0.0.0.0 (scripts/demo/s31.sh). The pairing link lists only the Mac's
/// non-local IPv4 addresses, so the Simulator (which enforces ATS like the phone) must reach the
/// bridge through one of them.
@MainActor
final class S31PairTailscaleUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Pair through a non-local address, then the paired host is online over Noise (IK) at the
    /// same address.
    func testPairAndConnectThroughANonLocalAddress() throws {
        try XCTSkipUnless(env["DSHM_S31_PAIR_URL"] != nil, "needs a pairing link; run scripts/demo/s31.sh")
        let link = try XCTUnwrap(env["DSHM_S31_PAIR_URL"].flatMap(URL.init(string:)))
        let app = XCUIApplication()
        // The unpaired Debug fallback must not reach a real host (port 1 is closed).
        app.launchArguments = ["-DSHMResetPairing", "YES", "-DSHMResetStore", "YES", "-DSHMBridgePort", "1"]
        app.launch()

        let reopened = openDeepLink(link)
        let confirm = reopened.buttons["pairing.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15), reopened.debugDescription)
        saveShot("s31-pair-review")
        confirm.tap()
        let status = reopened.descendants(matching: .any)["pairing.status"]
        // The bug: "failed", "couldn't reach the host at …".
        XCTAssertEqual(waitForValue(status, in: ["paired", "failed"], timeout: 30), "paired", status.label)
        saveShot("s31-paired")
        reopened.buttons["pairing.done"].tap()

        openDrawer(reopened)
        let channel = reopened.descendants(matching: .any)["host.channel"]
        XCTAssertTrue(channel.waitForExistence(timeout: 15), reopened.debugDescription)
        XCTAssertEqual(channel.value as? String, "noise")
        let host = reopened.descendants(matching: .any)["host.status"]
        XCTAssertEqual(waitForValue(host, in: ["online"], timeout: 30), "online", host.label)
        saveShot("s31-online")
    }
}
