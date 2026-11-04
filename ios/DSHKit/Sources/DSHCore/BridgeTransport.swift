import Foundation

/// One bidirectional message pipe to a bridge. Real: a WebSocket. Tests: `FakeBridge`.
public protocol BridgeTransport: Sendable {
    func send(_ message: Data) async throws
    /// Next binary message; throws when the connection closes.
    func receive() async throws -> Data
    func close() async
}

/// Opens a transport to an endpoint; injected into `HostConnection`.
public typealias BridgeTransportFactory = @Sendable (HostEndpoint) async throws -> any BridgeTransport

public enum BridgeTransportError: Error {
    case unexpectedTextMessage
}

/// `URLSessionWebSocketTask` with binary messages only.
public final class WebSocketTransport: BridgeTransport {
    private let task: URLSessionWebSocketTask

    public init(url: URL, session: URLSession = .shared) {
        task = session.webSocketTask(with: url)
        task.resume()
    }

    public static let factory: BridgeTransportFactory = { endpoint in
        WebSocketTransport(url: endpoint.webSocketURL)
    }

    public func send(_ message: Data) async throws {
        try await task.send(.data(message))
    }

    public func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let data): return data
        case .string: throw BridgeTransportError.unexpectedTextMessage
        @unknown default: throw BridgeTransportError.unexpectedTextMessage
        }
    }

    public func close() async {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
