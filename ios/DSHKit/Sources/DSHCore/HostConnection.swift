import DSHProtocol
import Foundation
import SwiftProtobuf

/// What the app learns about a task, in order. Exactly one `.ended` per task, always last.
public enum TaskEvent: Sendable, Equatable {
    case chunk(taskID: String, seq: UInt64, text: String)
    case ended(taskID: String, status: TaskEndStatus, message: String)
    /// S3: the next step on the task's milestone timeline. Arrives before `.ended`.
    case milestone(Milestone)
}

public enum TaskEndStatus: Sendable, Equatable {
    case completed, failed
}

public enum HostConnectionError: Error, Equatable, CustomStringConvertible {
    case notConnected
    case bridge(code: String, message: String)
    case unexpectedResponse
    case disconnected

    public var description: String {
        switch self {
        case .notConnected: "not connected to the bridge"
        case .bridge(let code, let message): "\(code): \(message)"
        case .unexpectedResponse: "the bridge sent an unexpected response"
        case .disconnected: "the connection to the bridge closed"
        }
    }
}

/// One connection to one host's bridge (ARCHITECTURE §4). Owns the transport, correlates
/// requests with responses, and publishes events. T0: no reconnect, no resume.
public actor HostConnection {
    public let endpoint: HostEndpoint
    private let channel: any SecureChannel
    private let makeTransport: BridgeTransportFactory

    private var transport: (any BridgeTransport)?
    private var receiveLoop: Task<Void, Never>?
    private var nextRequestID: UInt64 = 1
    private var pending: [UInt64: CheckedContinuation<Dshm_V1_Response, any Error>] = [:]
    private let eventContinuation: AsyncStream<TaskEvent>.Continuation

    /// Every task event from this host, for as long as the connection lives.
    public nonisolated let events: AsyncStream<TaskEvent>
    /// Capabilities from the bridge's Hello; empty until connected.
    public private(set) var capabilities: [String] = []

    public init(endpoint: HostEndpoint, channel: any SecureChannel, transport: @escaping BridgeTransportFactory) {
        self.endpoint = endpoint
        self.channel = channel
        self.makeTransport = transport
        (events, eventContinuation) = AsyncStream.makeStream(of: TaskEvent.self)
    }

    /// Validates the endpoint against the channel, opens the transport, and exchanges Hello.
    public func connect() async throws {
        if transport != nil { return }
        try channel.validate(endpoint)
        let t = try await makeTransport(endpoint)
        transport = t
        receiveLoop = Task { await self.receive(from: t) }
        var hello = Dshm_V1_Hello()
        hello.protocolVersion = DSHProtocolInfo.version
        let response = try await request(.hello(hello))
        guard case .hello(let theirs)? = response.body else { throw HostConnectionError.unexpectedResponse }
        capabilities = theirs.capabilities
    }

    /// Starts a task; its output arrives on `events`.
    public func createTask(prompt: String) async throws -> String {
        var create = Dshm_V1_CreateTask()
        create.prompt = prompt
        let response = try await request(.createTask(create))
        guard case .taskCreated(let created)? = response.body else { throw HostConnectionError.unexpectedResponse }
        return created.taskID
    }

    public func disconnect() async {
        receiveLoop?.cancel()
        await transport?.close()
        transport = nil
        failPending(HostConnectionError.disconnected)
    }

    // MARK: - Internals

    private func request(_ body: Dshm_V1_Request.OneOf_Body) async throws -> Dshm_V1_Response {
        guard let transport else { throw HostConnectionError.notConnected }
        let id = nextRequestID
        nextRequestID += 1
        var frame = Dshm_V1_Frame()
        var request = Dshm_V1_Request()
        request.id = id
        request.body = body
        frame.request = request
        let bytes = try channel.seal(try frame.serializedBytes())
        let response = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do { try await transport.send(bytes) } catch { self.resolve(id, with: .failure(error)) }
            }
        }
        if case .error(let e)? = response.body { throw HostConnectionError.bridge(code: e.code, message: e.message) }
        return response
    }

    private func resolve(_ id: UInt64, with result: Result<Dshm_V1_Response, any Error>) {
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private func failPending(_ error: any Error) {
        let waiting = pending
        pending = [:]
        for continuation in waiting.values { continuation.resume(throwing: error) }
    }

    private func receive(from transport: any BridgeTransport) async {
        while !Task.isCancelled {
            let frame: Dshm_V1_Frame
            do {
                let bytes = try channel.open(try await transport.receive())
                frame = try Dshm_V1_Frame(serializedBytes: bytes)
            } catch {
                break
            }
            switch frame.kind {
            case .response(let response)?:
                resolve(response.requestID, with: .success(response))
            case .event(let event)?:
                switch event.body {
                case .assistantChunk(let c)?:
                    eventContinuation.yield(.chunk(taskID: c.taskID, seq: c.seq, text: c.text))
                case .taskEnded(let e)?:
                    let status: TaskEndStatus = e.status == .completed ? .completed : .failed
                    eventContinuation.yield(.ended(taskID: e.taskID, status: status, message: e.message))
                case .milestoneAdded(let m)?:
                    if let milestone = Milestone(m) { eventContinuation.yield(.milestone(milestone)) }
                case nil:
                    break
                }
            case .request?, nil:
                break
            }
        }
        self.transport = nil
        failPending(HostConnectionError.disconnected)
    }
}
