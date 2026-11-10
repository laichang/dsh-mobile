import Foundation
import Network
import Synchronization

/// What a plain TCP connection to one address found.
public enum PortProbeResult: Sendable, Equatable {
    /// Something takes TCP connections on the port.
    case accepted
    /// The computer answered and refused: nothing listens on the port.
    case refused
    /// No answer in time, or no route: the computer is not reachable from here.
    case noAnswer
}

/// Opens a plain TCP connection to an address and closes it at once, within the given time
///. `HostConnection` asks it after an address gave no answer to the WebSocket and Noise
/// handshake: it tells "another program holds the port and says nothing" from "the computer is not
/// reachable". Tests inject a fake; the app uses `TCPPortProbe.probe`.
public typealias PortProbe = @Sendable (HostEndpoint, Duration) async -> PortProbeResult

public enum TCPPortProbe {
    /// A TCP connect on Network.framework; sends nothing.
    public static let probe: PortProbe = { endpoint, timeout in await connect(endpoint, timeout: timeout) }

    static func connect(_ endpoint: HostEndpoint, timeout: Duration) async -> PortProbeResult {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: endpoint.port)), endpoint.port > 0 else { return .noAnswer }
        let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: .tcp)
        let queue = DispatchQueue(label: "dshm.port-probe")
        return await withCheckedContinuation { continuation in
            let done = Mutex(false)
            let finish: @Sendable (PortProbeResult) -> Void = { result in
                guard done.withLock({ was in defer { was = true }; return !was }) else { return }
                connection.cancel()
                continuation.resume(returning: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.accepted)
                case .waiting(let error):
                    // Refused: the computer answered. Other waits (no route, no network) last until the timeout.
                    if Self.isRefusal(error) { finish(.refused) }
                case .failed(let error):
                    finish(Self.isRefusal(error) ? .refused : .noAnswer)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            queue.asyncAfter(deadline: .now() + seconds) { finish(.noAnswer) }
        }
    }

    private static func isRefusal(_ error: NWError) -> Bool {
        if case .posix(let code) = error { return code == .ECONNREFUSED }
        return false
    }
}
