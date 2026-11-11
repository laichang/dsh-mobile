@testable import DSHCore
import DSHTestSupport
import Foundation
import Network
import Synchronization
import Testing

/// Why a host is offline, for each of its addresses (on top of the address order): nothing
/// listens on the port (refused), another program holds the port (it takes the connection but is
/// no DSH bridge), or the computer is not reachable (no answer). First with fake sockets that
/// fail the way URLSession and the TCP probe do, then with real sockets on the loopback interface.
@Suite(.serialized) struct OfflineReasonsTests {
    static let refused = HostEndpoint(host: "192.0.2.1", port: 47801)
    static let http = HostEndpoint(host: "192.0.2.2", port: 47801)
    static let silentProgram = HostEndpoint(host: "192.0.2.3", port: 47801)
    static let asleep = HostEndpoint(host: "192.0.2.4", port: 47801)
    static let silentRefused = HostEndpoint(host: "192.0.2.5", port: 47801)
    static let foreignClose = HostEndpoint(host: "192.0.2.6", port: 47801)
    static let textReply = HostEndpoint(host: "192.0.2.7", port: 47801)
    static let echo = HostEndpoint(host: "192.0.2.8", port: 47801)

    /// The phone's sockets: how each address answers a WebSocket and a plain TCP connect.
    static let transport: BridgeTransportFactory = { url in
        switch HostEndpoint(host: url.host() ?? "", port: url.port ?? 0) {
        case OfflineReasonsTests.refused: throw URLError(.cannotConnectToHost)
        case OfflineReasonsTests.http: throw URLError(.badServerResponse)
        case OfflineReasonsTests.foreignClose: throw URLError(.badServerResponse)
        case OfflineReasonsTests.textReply: throw BridgeTransportError.unexpectedTextMessage
        case OfflineReasonsTests.echo: throw URLError(.badServerResponse)
        default: try await Task.sleep(for: .seconds(60)); throw URLError(.timedOut)
        }
    }

    static let probe: PortProbe = { endpoint, _ in
        switch endpoint {
        case OfflineReasonsTests.silentProgram: .accepted
        case OfflineReasonsTests.silentRefused: .refused
        default: .noAnswer
        }
    }

    func failures(_ endpoints: [HostEndpoint], probe: PortProbe? = Self.probe,
                  transport: @escaping BridgeTransportFactory = Self.transport) async throws -> [AddressFailure] {
        let connection = HostConnection(endpoints: endpoints, transport: transport,
                                        attemptTimeout: .milliseconds(200), probe: probe)
        do {
            try await connection.connect()
            Issue.record("connected to \(endpoints)")
        } catch HostConnectionError.unreachable(let failures) {
            #expect(await connection.addressFailures == failures)
            return failures
        }
        return []
    }

    /// The three reasons: refused, another program (an HTTP answer, or a TCP connection that never
    /// answers), and no answer at all.
    @Test func refusedOtherProgramAndTimeoutAreThreeReasons() async throws {
        let failures = try await failures([Self.refused, Self.http, Self.silentProgram, Self.asleep])
        #expect(failures.map(\.kind) == [.nothingListens, .otherProgram, .otherProgram, .notReachable])
        #expect(failures.map(\.reason) == [
            "URL error -1004, connection refused",
            "URL error -1011, bad server response",
            "no answer in 0.2 s; the port takes connections",
            "no answer in 0.2 s",
        ])
        #expect(AddressFailure.mostTelling(failures)?.endpoint == Self.http)
    }

    /// A WebSocket peer that is not a DSH bridge: a close code the bridge never sends, a text
    /// message, or an unexpected reply.
    @Test func aWebSocketThatIsNoBridgeIsAnotherProgram() async throws {
        let failures = try await failures([Self.foreignClose, Self.textReply, Self.echo])
        #expect(failures.map(\.kind) == [.otherProgram, .otherProgram, .otherProgram])
    }

    /// A timeout where the probe is refused, or no probe at all (tests, Debug's fake bridge).
    @Test func aTimeoutWithoutAnAcceptedProbeIsNotAnotherProgram() async throws {
        #expect(try await failures([Self.silentRefused]).map(\.kind) == [.nothingListens])
        let unprobed = try await failures([Self.silentProgram], probe: nil)
        #expect(unprobed.map(\.kind) == [.notReachable])
        #expect(unprobed.map(\.reason) == ["no answer in 0.2 s"])
    }

    /// The bridge's own refusals stay what they were: they mean a DSH bridge answered.
    @Test func theBridgesOwnRefusalsAreNoneOfTheThree() {
        let e = Self.refused
        #expect(AddressFailure(endpoint: e, error: URLError(.serverCertificateUntrusted)).kind == nil)
        #expect(AddressFailure(endpoint: e, error: HostConnectionError.deviceRevoked).kind == nil)
        #expect(AddressFailure(endpoint: e, error: URLError(.appTransportSecurityRequiresSecureConnection)).kind == nil)
    }

    /// The host row and the offline card name the reason that says most about the host.
    @Test func theMostTellingReasonOfAHost() {
        func f(_ port: Int, _ kind: AddressFailure.Kind?) -> AddressFailure {
            AddressFailure(endpoint: HostEndpoint(host: "10.0.0.1", port: port), reason: "r", kind: kind)
        }
        #expect(AddressFailure.mostTelling([f(1, .notReachable), f(2, .nothingListens)])?.endpoint.port == 2)
        #expect(AddressFailure.mostTelling([f(1, .nothingListens), f(2, .otherProgram), f(3, .notReachable)])?.endpoint.port == 2)
        #expect(AddressFailure.mostTelling([f(1, nil), f(2, .notReachable)])?.endpoint.port == 2)
        #expect(AddressFailure.mostTelling([f(1, nil)]) == nil)
        #expect(AddressFailure.mostTelling([]) == nil)
    }

    // MARK: - Real sockets on the loopback interface

    /// A TCP server on 127.0.0.1: an HTTP server that answers 404 to everything (another program),
    /// or one that takes connections and never says anything.
    final class LoopbackServer: Sendable {
        enum Behavior: Sendable { case http404, silent }
        let listener: NWListener
        let port: Int
        private let connections = Connections()

        /// Every connection the server took, so `stop()` can close them.
        final class Connections: Sendable {
            private let list = Mutex<[NWConnection]>([])
            func add(_ connection: NWConnection) { list.withLock { $0.append(connection) } }
            func all() -> [NWConnection] { list.withLock { $0 } }
        }

        init(_ behavior: Behavior) async throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            let queue = DispatchQueue(label: "dshm.loopback-server")
            let connections = self.connections
            listener.newConnectionHandler = { connection in
                connections.add(connection)
                connection.start(queue: queue)
                guard behavior == .http404 else { return }
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                    let response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            port = try await withCheckedThrowingContinuation { continuation in
                let resumed = Mutex(false)
                listener.stateUpdateHandler = { state in
                    let result: Result<Int, any Error>? = switch state {
                    case .ready: .success(Int(listener.port?.rawValue ?? 0))
                    case .failed(let error): .failure(error)
                    default: nil
                    }
                    guard let result, resumed.withLock({ was in defer { was = true }; return !was }) else { return }
                    continuation.resume(with: result)
                }
                listener.start(queue: queue)
            }
            self.listener = listener
        }

        var endpoint: HostEndpoint { HostEndpoint(host: "127.0.0.1", port: port) }

        func stop() {
            listener.cancel()
            for c in connections.all() { c.cancel() }
        }
    }

    /// A port that nothing listens on: one the system just gave out and took back.
    func closedPort() async throws -> HostEndpoint {
        let server = try await LoopbackServer(.silent)
        server.stop()
        try await Task.sleep(for: .milliseconds(50))
        return server.endpoint
    }

    /// The real stack: `WebSocketTransport` (URLSession) and `TCPPortProbe` (Network.framework).
    @Test func realSocketsGiveTheThreeReasons() async throws {
        let http = try await LoopbackServer(.http404)
        let silent = try await LoopbackServer(.silent)
        defer { http.stop(); silent.stop() }
        let closed = try await closedPort()

        let failures = try await failures([closed, http.endpoint, silent.endpoint], probe: TCPPortProbe.probe,
                                          transport: { url in
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            parts.scheme = "https"
            _ = try await WebSocketTransport.pinnedRequest(URLRequest(url: parts.url!), spkiSHA256: Data(repeating: 0, count: 32))
            throw URLError(.badServerResponse)
        })
        #expect(failures.map(\.kind) == [.nothingListens, .otherProgram, .otherProgram], "\(failures)")

        #expect(await TCPPortProbe.probe(silent.endpoint, .seconds(1)) == .accepted)
        #expect(await TCPPortProbe.probe(closed, .seconds(1)) == .refused)
    }
}
