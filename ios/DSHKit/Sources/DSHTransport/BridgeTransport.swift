import Foundation

/// One bidirectional message pipe to a bridge. Real: a WebSocket. Tests: `FakeBridge`.
public protocol BridgeTransport: Sendable {
    func send(_ message: Data) async throws
    /// Next binary message; throws when the connection closes (`BridgeTransportError.closed`
    /// when the bridge said why).
    func receive() async throws -> Data
    func close() async
}

/// Opens a transport to a bridge URL (`HostEndpoint.webSocketURL(path:)`); injected into
/// `HostConnection`.
public typealias BridgeTransportFactory = @Sendable (URL) async throws -> any BridgeTransport

public enum BridgeTransportError: Error, Equatable {
    case unexpectedTextMessage
    /// A revoked device receives close code 4003.
    case closed(code: Int, reason: String)
}

/// `URLSessionWebSocketTask` with binary messages only.
public final class WebSocketTransport: BridgeTransport {
    private let task: URLSessionWebSocketTask

    private let ownedSession: URLSession

    init(request: URLRequest, ownedSession: URLSession) {
        self.ownedSession = ownedSession
        task = ownedSession.webSocketTask(with: request)
        task.resume()
    }

    public func send(_ message: Data) async throws {
        try await task.send(.data(message))
    }

    public func receive() async throws -> Data {
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await task.receive()
        } catch {
            // The close frame's code is set by the time receive fails on it.
            if task.closeCode != .invalid {
                let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                throw BridgeTransportError.closed(code: task.closeCode.rawValue, reason: reason)
            }
            throw error
        }
        switch message {
        case .data(let data): return data
        case .string: throw BridgeTransportError.unexpectedTextMessage
        @unknown default: throw BridgeTransportError.unexpectedTextMessage
        }
    }

    public func close() async {
        task.cancel(with: .normalClosure, reason: nil)
        ownedSession.invalidateAndCancel()
    }
}
