import DSHProtocol
import DSHTransport
import Foundation
import Synchronization

/// What the app learns about a task, in order. Each turn ends with one `.ended`; with
/// `conversation.v1` a `.userMessage` can start another turn after it.
package enum TaskEvent: Sendable, Equatable {
    case chunk(taskID: String, seq: UInt64, text: String)
    /// `code`: DSH's failure class for a model failure (`QUOTA`, `AUTH`, …); empty otherwise.
    case ended(taskID: String, status: TaskEndStatus, message: String, code: String = "")
    /// The next step on the task's milestone timeline. Arrives before `.ended`.
    case milestone(Milestone)
    case modelSelected(taskID: String, selection: ModelSelection)
    /// A task was created or changed state.
    case upserted(TaskSnapshot)
    case approvalPending(Approval)
    case approvalResolved(taskID: String, id: String)
    /// The app's resume cursor didn't apply; a replay of log `logID` from its start follows.
    case logReset(logID: String)
    /// A thinking or tool-call row was added or changed (`transcript.v1`).
    case transcriptBlock(TranscriptItem)
    /// The user sent one more message into the task (`conversation.v1`). Its turn follows.
    /// For a message that waited, this is where DSH took it.
    case userMessage(TranscriptItem)
    /// A follow-up waits while the task runs, moved, or stopped waiting (`conversation.v2`).
    case queuedMessage(QueuedMessage)
    /// An agent question waits for an answer (`questions.v1`): its card as a transcript row.
    case questionPending(TranscriptItem)
    case questionResolved(AgentQuestion.Resolution)
}

public enum TaskEndStatus: Sendable, Equatable {
    case completed, failed, interrupted

    var state: TaskState {
        switch self {
        case .completed: .completed
        case .failed: .failed
        case .interrupted: .interrupted
        }
    }

    init(wire: Dshm_V1_TaskStatus) {
        self = switch wire {
        case .completed: .completed
        case .interrupted: .interrupted
        default: .failed
        }
    }
}

/// One event from a host, with its place in the host's event log.
package struct HostEvent: Sendable, Equatable {
    /// Per-host monotonic sequence number; 0 when the event isn't logged (`.logReset`).
    public var hostSeq: UInt64
    public var event: TaskEvent

    public init(hostSeq: UInt64 = 0, _ event: TaskEvent) {
        self.hostSeq = hostSeq
        self.event = event
    }
}

/// Where a task stands in the unified list (STORY principle 4).
public enum TaskState: String, Sendable, Equatable, CaseIterable {
    case running
    case waitingOnUser
    case completed
    case failed
    case interrupted

    public var isTerminal: Bool { self == .completed || self == .failed || self == .interrupted }
}

/// A task as the host reports it (`TaskSummary` in protocol/durable_list.proto).
public struct TaskSnapshot: Sendable, Equatable {
    public var taskID: String
    public var title: String
    public var state: TaskState
    public var createdAt: Date
    public var updatedAt: Date
    public var message: String
    /// DSH's failure class when the task failed on its model (`QUOTA`, `AUTH`, …); empty otherwise.
    public var failureCode = ""
    public var approvals: [Approval] = []
    public var approvalOnly = false
    public var modelSelection: ModelSelection?
    public var sessionRevision: UInt64?
    public var externalSession = false
    public var latestReply: String?
    /// With `drawer.v1`: the session's workspace directory on the host.
    public var workspace: String?
    /// When the latest turn started; nil from an older bridge (then `createdAt` stands in).
    public var turnStartedAt: Date?
    /// Agent questions the task waits on (`pending_questions`), as card rows.
    public var questions: [TranscriptItem] = []

    public init(taskID: String, title: String, state: TaskState, createdAt: Date, updatedAt: Date, message: String = "") {
        self.taskID = taskID
        self.title = title
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.message = message
    }

    init(_ s: Dshm_V1_TaskSummary) {
        let state: TaskState = switch s.state {
        case .interrupted: .interrupted
        case .waitingOnUser: .waitingOnUser
        case .completed: .completed
        case .failed: .failed
        case .running, .unspecified, .UNRECOGNIZED: .running
        }
        self.init(
            taskID: s.taskID, title: s.title, state: state,
            createdAt: Date(timeIntervalSince1970: Double(s.createdAtMs) / 1000),
            updatedAt: Date(timeIntervalSince1970: Double(s.updatedAtMs) / 1000),
            message: s.message)
        failureCode = s.failureCode
        sessionRevision = s.hasSessionRevision ? s.sessionRevision : nil
        externalSession = s.externalSession
        latestReply = s.hasLatestReply ? s.latestReply : nil
        workspace = s.hasWorkspace && !s.workspace.isEmpty ? s.workspace : nil
        turnStartedAt = s.hasTurnStartedAtMs ? Date(timeIntervalSince1970: Double(s.turnStartedAtMs) / 1000) : nil
        approvals = s.pendingApprovals.map(Approval.init)
        questions = s.pendingQuestions.map { AgentQuestion.pendingRow($0) }
        approvalOnly = s.approvalOnly
        modelSelection = s.hasModelSelection ? ModelSelection(s.modelSelection) : nil
    }
}

/// The answer to `Resume` (protocol/durable_list.proto `Resumed`).
public struct ResumeResult: Sendable, Equatable {
    public var logID: String
    public var headSeq: UInt64
    public var hostName: String
    public var reset: Bool
    public var replayed: UInt64
}

/// The answer to `ListTasks`.
public struct TaskListing: Sendable, Equatable {
    public var tasks: [TaskSnapshot]
    public var logID: String
    public var hostName: String
}

public enum HostConnectionError: Error, Equatable, CustomStringConvertible {
    case notConnected
    case bridge(code: String, message: String)
    case bridgeUpdateRequired(version: String, supported: String)
    case unexpectedResponse
    case disconnected
    /// The host refused this device with close 4003 (device unknown): it was revoked
    /// (or never paired), on a live connection. Final: retrying cannot succeed.
    case deviceRevoked
    /// No address of the host worked; the last error of each address, in the order tried.
    case unreachable([AddressFailure])

    public var description: String {
        switch self {
        case .notConnected: "not connected to the bridge"
        case .bridge(let code, let message): "\(code): \(message)"
        case .bridgeUpdateRequired(let version, let supported): "This host needs a bridge update. DSH \(version) is installed. This bridge supports \(supported)."
        case .unexpectedResponse: "the bridge sent an unexpected response"
        case .disconnected: "the connection to the bridge closed"
        case .deviceRevoked: "this host revoked this phone's access"
        case .unreachable(let failures): "couldn't reach the host at \(failures.map(\.description).joined(separator: ", "))"
        }
    }
}

/// The transport of one address try, so a timeout can close it.
private final class OpenedTransport: Sendable {
    private let transport = Mutex<(any BridgeTransport)?>(nil)

    func set(_ t: any BridgeTransport) { transport.withLock { $0 = t } }
    func close() async { await transport.withLock { $0 }?.close() }
}

/// One connection to one host's bridge. It negotiates Hello and maps host commands and events. The store owns reconnect policy and the resume cursor.
///
/// A host can have more than one address (LAN, Tailscale). Each connect tries them one at a
/// time, the address that worked last first, each with `attemptTimeout`.
package actor HostConnection {
    /// How long one address may take to open and finish the handshake.
    public static let defaultAttemptTimeout: Duration = .seconds(5)
    /// How long the TCP probe after a timeout may take. A computer that is reachable
    /// answers a TCP connect within one round trip.
    public static let probeTimeout: Duration = .seconds(1)

    /// The first address as configured: stable, for names (two hosts with one name) and logs.
    public nonisolated let endpoint: HostEndpoint
    /// Every address, as configured.
    public nonisolated let endpoints: [HostEndpoint]
    package nonisolated let enrollment: HostEnrollment
    public nonisolated let channelName: String
    public nonisolated let attemptTimeout: Duration
    /// Asked after an address gave no answer in `attemptTimeout`; nil: no probe.
    private let probe: PortProbe?
    private let makeTransport: BridgeTransportFactory
    private let onAddressesChange: (@Sendable ([HostEndpoint]) -> Void)?

    /// The order the next connect tries: the address that worked last first.
    public private(set) var addresses: [HostEndpoint]
    /// The address of the live connection, or of the last one that worked.
    public private(set) var currentEndpoint: HostEndpoint?
    /// The last error of each address from the last connect that failed; empty after one that worked.
    public private(set) var addressFailures: [AddressFailure] = []

    private var dispatcher: FrameDispatcher?
    private var connecting: Task<Void, any Error>?
    package typealias EventDelivery = @Sendable (isolated HostConnection, Dshm_V1_Event, FrameDispatcher) async -> Void
    private let deliverEvent: EventDelivery
    private var disconnectWaiters: [CheckedContinuation<Void, Never>] = []
    private let eventContinuation: AsyncStream<HostEvent>.Continuation

    /// Every event from this host, across reconnects, for as long as the connection object lives.
    package nonisolated let events: AsyncStream<HostEvent>
    /// Capabilities from the bridge's Hello; empty until connected.
    package private(set) var capabilities: [String] = []
    /// The host refused this device with close 4003 (device unknown), on a live
    /// connection (the close after a revoke) or on a reconnect (the device credential check). A revoked
    /// device stays refused, so `TaskListStore` does not retry it. Cleared by a connect that works.
    public private(set) var deviceRevoked = false

    /// Whether `error` is the host's refusal of this device (close 4003 device unknown).
    public static func isDeviceRefusal(_ error: any Error) -> Bool {
        switch error {
        case HostConnectionError.deviceRevoked: true
        case BridgeTransportError.closed(let code, _): code == 4003
        default: false
        }
    }

    package init(endpoint: HostEndpoint, channelName: String = "In-process", transport: @escaping BridgeTransportFactory) {
        self.init(endpoints: [endpoint], channelName: channelName, transport: transport)
    }

    /// - Parameters:
    ///   - endpoints: every address of the host, the one to try first first. Not empty.
    ///   - probe: a plain TCP connect after an address gave no answer, to tell another
    ///     program that holds the port from a computer that is not reachable (`TCPPortProbe.probe`).
    ///   - onAddressesChange: called with the new order when a different address than the first
    ///     worked, so the caller can save it (`Pairing.connection(to:)`).
    package init(endpoints: [HostEndpoint], channelName: String = "In-process", enrollment: HostEnrollment? = nil, transport: @escaping BridgeTransportFactory,
                attemptTimeout: Duration = HostConnection.defaultAttemptTimeout,
                probe: PortProbe? = nil,
                deliverEvent: @escaping EventDelivery = { host, event, session in host.yield(event, from: session) },
                onAddressesChange: (@Sendable ([HostEndpoint]) -> Void)? = nil) {
        precondition(!endpoints.isEmpty, "a host connection needs at least one address")
        // In-process hosts have no TLS credential and are recreated by the debug launch fixture.
        self.enrollment = enrollment ?? HostEnrollment(hostKey: [], tlsDeviceID: endpoints[0].description)
        self.endpoint = endpoints[0]
        self.endpoints = endpoints
        self.addresses = endpoints
        self.attemptTimeout = attemptTimeout
        self.deliverEvent = deliverEvent
        self.probe = probe
        self.onAddressesChange = onAddressesChange
        self.channelName = channelName
        self.makeTransport = transport
        (events, eventContinuation) = AsyncStream.makeStream(of: HostEvent.self)
    }

    /// The bridge drops staged uploads when this socket closes. A failed batch can release all
    /// five slots without interrupting the host's replay stream or another composer's send.
    func attachmentConnection() -> HostConnection {
        HostConnection(endpoints: addresses, channelName: channelName, enrollment: enrollment,
                       transport: makeTransport, attemptTimeout: attemptTimeout, probe: probe,
                       deliverEvent: { _, _, _ in })
    }

    public var isConnected: Bool { dispatcher != nil && connecting == nil }

    /// Opens the transport and exchanges Hello.
    public func connect() async throws {
        if let connecting { return try await connecting.value }
        if dispatcher != nil { return }
        let attempt = Task { try await self.open() }
        connecting = attempt
        defer { if connecting == attempt { connecting = nil } }
        try await attempt.value
    }

    /// Tries each address, the one that worked last first, until one connects. Throws
    /// `.unreachable` with the error of each address when none does.
    private func open() async throws {
        var failures: [AddressFailure] = []
        for endpoint in addresses {
            try Task.checkCancellation()
            do {
                try await open(endpoint)
                try Task.checkCancellation()
            } catch {
                try Task.checkCancellation()
                if Self.endsTheSearch(error) {
                    addressFailures = failures + [AddressFailure(endpoint: endpoint, error: error)]
                    throw error
                }
                failures.append(AddressFailure(endpoint: endpoint, error: error))
                continue
            }
            addressFailures = []
            currentEndpoint = endpoint
            if addresses.first != endpoint {
                addresses = [endpoint] + addresses.filter { $0 != endpoint }
                onAddressesChange?(addresses)
            }
            return
        }
        addressFailures = failures
        throw HostConnectionError.unreachable(failures)
    }

    /// The host answered at this address, so another address would get the same answer: it
    /// revoked this device (4003) or needs a DSH update. Or the
    /// caller gave up (cancelled).
    static func endsTheSearch(_ error: any Error) -> Bool {
        switch error {
        case HostConnectionError.bridgeUpdateRequired, is CancellationError: true
        default: isDeviceRefusal(error)
        }
    }

    /// Opens the transport and runs the handshake, within `attemptTimeout`.
    private func handshake(_ endpoint: HostEndpoint) async throws -> any BridgeTransport {
        let makeTransport = self.makeTransport, timeout = attemptTimeout, probe = self.probe
        let url = endpoint.webSocketURL()
        let opened = OpenedTransport()
        return try await withThrowingTaskGroup(of: (any BridgeTransport)?.self) { group in
            group.addTask {
                let t = try await makeTransport(url)
                opened.set(t)
                do {
                    try Task.checkCancellation()
                    return t
                } catch {
                    await t.close()
                    throw error
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            let result = try await withTaskCancellationHandler {
                try await group.next()
            } onCancel: {
                Task { await opened.close() }
            }
            guard let first = result else { throw CancellationError() }
            if let established = first { return established }
            group.cancelAll()
            // No answer in time: closing the transport ends the handshake's wait for a reply.
            await opened.close()
            // Does anything take TCP connections there? Another program, or no computer.
            throw AddressTimeout(after: timeout, port: await probe?(endpoint, Self.probeTimeout))
        }
    }

    private func open(_ endpoint: HostEndpoint) async throws {
        let t: any BridgeTransport
        do {
            t = try await handshake(endpoint)
        } catch {
            try Task.checkCancellation()
            throw refusal(error)
        }
        if Task.isCancelled {
            await t.close()
            throw CancellationError()
        }
        let session = FrameDispatcher(transport: t) { [weak self] session, event in
            guard let self else { return }
            await self.deliverEvent(self, event, session)
        } onClose: { [weak self] session, error in
            await self?.didClose(session, cause: error)
        }
        dispatcher = session
        do {
            var hello = Dshm_V1_Hello()
            hello.protocolVersion = DSHProtocolInfo.version
            hello.capabilities = [
                DSHProtocolInfo.tasksCapability, DSHProtocolInfo.milestonesCapability, DSHProtocolInfo.resumeCapability,
                DSHProtocolInfo.interruptCapability, DSHProtocolInfo.transcriptCapability, DSHProtocolInfo.approvalsCapability,
                DSHProtocolInfo.conversationCapability, DSHProtocolInfo.failuresCapability, DSHProtocolInfo.queueCapability,
                DSHProtocolInfo.questionsCapability, DSHProtocolInfo.attachmentsCapability,
                "sessions.v1", "models.v1", "workspaces.v1", "devices.v1", "drawer.v1",
            ]
            let response = try await request(.hello(hello))
            guard case .hello(let theirs)? = response.body else { throw HostConnectionError.unexpectedResponse }
            if theirs.requiresBridgeUpdate {
                throw HostConnectionError.bridgeUpdateRequired(version: theirs.dshVersion, supported: theirs.supportedDshRange)
            }
            try Task.checkCancellation()
            guard dispatcher === session else { throw HostConnectionError.disconnected }
            capabilities = theirs.capabilities
            deviceRevoked = false
        } catch {
            await session.close()
            throw error
        }
    }

    /// Records a refusal of this device; returns the error unchanged.
    private func refusal(_ error: any Error) -> any Error {
        if Self.isDeviceRefusal(error) { deviceRevoked = true }
        return error
    }

    /// Returns once the current transport is gone (immediately if there is none).
    public func waitUntilDisconnected() async {
        if dispatcher == nil { return }
        await withCheckedContinuation { disconnectWaiters.append($0) }
    }

    public func disconnect() async {
        connecting?.cancel()
        connecting = nil
        if let session = dispatcher {
            didClose(session, cause: FrameDispatcher.Failure.disconnected)
            await session.close()
        }
    }

    private static func domainError(_ error: any Error) -> any Error {
        switch error {
        case FrameDispatcher.Failure.receive(let cause):
            return isDeviceRefusal(cause) ? HostConnectionError.deviceRevoked : HostConnectionError.disconnected
        case FrameDispatcher.Failure.disconnected: return HostConnectionError.disconnected
        default: return isDeviceRefusal(error) ? HostConnectionError.deviceRevoked : error
        }
    }

    private func didClose(_ session: FrameDispatcher, cause: any Error) {
        guard dispatcher === session else { return }
        dispatcher = nil
        _ = refusal(Self.domainError(cause))
        for waiter in disconnectWaiters { waiter.resume() }
        disconnectWaiters.removeAll()
    }

    func request(_ body: Dshm_V1_Request.OneOf_Body) async throws -> Dshm_V1_Response {
        try Task.checkCancellation()
        guard let dispatcher else { throw HostConnectionError.notConnected }
        let response: Dshm_V1_Response
        do {
            response = try await dispatcher.request(body)
        } catch {
            throw Self.domainError(error)
        }
        if case .error(let e)? = response.body { throw HostConnectionError.bridge(code: e.code, message: e.message) }
        return response
    }

    package func yield(_ event: Dshm_V1_Event, from session: FrameDispatcher) {
        guard dispatcher === session, let mapped = Self.taskEvent(event.body) else { return }
        eventContinuation.yield(HostEvent(hostSeq: event.hostSeq, mapped))
    }

    private static func taskEvent(_ body: Dshm_V1_Event.OneOf_Body?) -> TaskEvent? {
        switch body {
        case .assistantChunk(let c)?:
            return .chunk(taskID: c.taskID, seq: c.seq, text: c.text)
        case .taskEnded(let e)?:
            return .ended(taskID: e.taskID, status: TaskEndStatus(wire: e.status), message: e.message, code: e.failureCode)
        case .taskUpserted(let u)?:
            return .upserted(TaskSnapshot(u.task))
        case .approvalPending(let approval)?:
            return .approvalPending(Approval(approval))
        case .approvalResolved(let result)?:
            return .approvalResolved(taskID: result.taskID, id: result.id)
        case .logReset(let r)?:
            return .logReset(logID: r.logID)
        case .modelSelected(let m)?:
            return .modelSelected(taskID: m.taskID, selection: ModelSelection(m.selection))
        case .milestoneAdded(let m)?:
            return Milestone(m).map { .milestone($0) }
        case .transcriptBlock(let b)?:
            return TranscriptItem(b).map { .transcriptBlock($0) }
        case .userMessage(let m)?:
            return .userMessage(TranscriptItem(m))
        case .queuedMessage(let q)?:
            return .queuedMessage(QueuedMessage(q))
        case .questionPending(let q)?:
            return .questionPending(AgentQuestion.pendingRow(q))
        case .questionResolved(let r)?:
            return .questionResolved(.init(r))
        case nil:
            return nil
        }
    }
}
