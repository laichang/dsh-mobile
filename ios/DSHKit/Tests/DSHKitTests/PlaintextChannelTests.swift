#if DEBUG
import DSHTransport
import DSHCore
import Foundation
import Testing

/// PlaintextChannel exists only in Debug builds (scripts/check-release-clean) and only reaches
/// loopback literals.
@Suite struct PlaintextChannelTests {
    @Test(arguments: ["192.168.1.10", "10.0.0.1", "0.0.0.0", "8.8.8.8", "::", "fe80::1", "example.com", "localhost", ""])
    func refusesNonLoopbackAddress(host: String) {
        #expect(throws: SecureChannelError.nonLoopbackRefused(host)) {
            try PlaintextChannel().validate(HostEndpoint(host: host, port: 47801))
        }
    }

    @Test(arguments: ["127.0.0.1", "127.1.2.3", "::1", "[::1]"])
    func acceptsLoopback(host: String) throws {
        try PlaintextChannel().validate(HostEndpoint(host: host, port: 47801))
    }

    /// The refusal happens before any socket opens: the transport factory is never called.
    @Test func connectionRefusesNonLoopbackBeforeOpeningTransport() async {
        let opened = Counter()
        let connection = HostConnection(
            endpoint: HostEndpoint(host: "192.168.1.10", port: 47801),
            channel: PlaintextChannel(),
            transport: { _ in await opened.increment(); throw CancellationError() })
        await #expect(throws: SecureChannelError.nonLoopbackRefused("192.168.1.10")) {
            try await connection.connect()
        }
        #expect(await opened.value == 0)
    }
}

#endif

actor Counter {
    var value = 0
    func increment() { value += 1 }
}
