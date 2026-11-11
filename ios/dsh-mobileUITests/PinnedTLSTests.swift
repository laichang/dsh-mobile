import DSHTransport
import DSHCore
import XCTest

@MainActor
final class PinnedTLSTests: XCTestCase {
    struct Fixture: Decodable {
        let pin, hello, reply: Data
        let ports: [String: Int]
    }

    func testPinnedHelloAndRecovery() async throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DSHM_TLS_FIXTURE"] != nil, "Run scripts/demo/pinned-tls.sh")
        let json = try XCTUnwrap(ProcessInfo.processInfo.environment["DSHM_TLS_FIXTURE"])
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(json.utf8))
        func endpoint(_ name: String, _ host: String) throws -> HostEndpoint {
            .init(host: host, port: try XCTUnwrap(fixture.ports[name]))
        }
        let sentinel = "Bearer public-transport-sentinel"
        func exchange(_ name: String, host: String = "127.0.0.1") async throws -> Data {
            let target = try endpoint(name, host)
            let url = try XCTUnwrap(URL(string: "wss://\(target)/"))
            let pipe = try WebSocketTransport.pinnedTLS(url: url, spkiSHA256: fixture.pin, authorization: sentinel)
            do {
                try await pipe.send(fixture.hello)
                let reply = try await pipe.receive()
                await pipe.close()
                return reply
            } catch {
                await pipe.close()
                throw error
            }
        }
        let initial = try await exchange("ip")
        XCTAssertEqual(initial, fixture.reply)
        let renewed = try await exchange("renewed", host: "localhost")
        XCTAssertEqual(renewed, fixture.reply)
        for peer in ["wrongKey", "wrongName", "expired", "wrongUsage", "oldTLS", "cleartext", "redirect"] {
            do {
                _ = try await exchange(peer)
                XCTFail("Accepted \(peer)")
            } catch {}
        }
        let dead = try endpoint("ip", "127.0.0.1")
        XCTAssertThrowsError(try WebSocketTransport.pinnedTLS(url: dead.webSocketURL(), spkiSHA256: fixture.pin))
        let dns = try endpoint("renewed", "localhost")
        let connection = HostConnection(endpoints: [dead, dns], spkiSHA256: fixture.pin, authorization: sentinel)
        try await connection.connect()
        let active = await connection.currentEndpoint
        XCTAssertEqual(active, dns)
        await connection.disconnect()

        let app = XCUIApplication()
        app.launchArguments = ["-DSHMResetStore", "YES"]
        app.launchEnvironment["DSHM_TLS_TEST_PIN"] = fixture.pin.base64EncodedString()
        app.launchEnvironment["DSHM_TLS_TEST_ADDRESSES"] = [dead.description, "localhost:\(dead.port)"].joined(separator: ",")
        app.launch()
        openDrawer(app)
        app.descendants(matching: .any)["drawer.hosts"].firstMatch.tap()
        let row = app.descendants(matching: .any)["hosts.row"].firstMatch
        let offline = NSPredicate(format: "value == 'offline' AND label CONTAINS %@ AND label CONTAINS %@",
                                  dead.description, "localhost:\(dead.port)")
        await fulfillment(of: [expectation(for: offline, evaluatedWith: row)], timeout: 45)
        XCTAssertTrue(app.buttons["hosts.pair"].isHittable)
    }
}
