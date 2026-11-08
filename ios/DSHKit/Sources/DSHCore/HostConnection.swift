import DSHProtocol
import Foundation
import SwiftProtobuf

/// What the app learns about a task, in order. Each turn ends with one `.ended`; with
/// `conversation.v1` a `.userMessage` can start another turn after it.
public enum TaskEvent: Sendable, Equatable {
    case chunk(taskID: String, seq: UInt64, text: String)
    case ended(taskID: String, status: TaskEndStatus, message: String)
    /// S3: the next step on the task's milestone timeline. Arrives before `.ended`.
    case milestone(Milestone)
    case modelSelected(taskID: String, selection: ModelSelection)
    /// S2: a task was created or changed state.
    case upserted(TaskSnapshot)
    case approvalPending(Approval)
    case approvalResolved(taskID: String, id: String)
    /// S2: the app's resume cursor didn't apply; a replay of log `logID` from its start follows.
    case logReset(logID: String)
    /// S17: a thinking or tool-call row was added or changed (`transcript.v1`).
    case transcriptBlock(TranscriptItem)
    /// D89: the user sent one more message into the task (`conversation.v1`). Its turn follows.
    case userMessage(TranscriptItem)
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

/// One event from a host, with its place in the host's event log (S2, ARCHITECTURE D20).
public struct HostEvent: Sendable, Equatable {
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

/// A task as the host reports it (`TaskSummary` in protocol/s2.proto).
public struct TaskSnapshot: Sendable, Equatable {
    public var taskID: String
    public var title: String
    public var state: TaskState
    public var createdAt: Date
    public var updatedAt: Date
    public var message: String
    public var approvals: [Approval] = []
    public var approvalOnly = false
    public var modelSelection: ModelSelection?
    public var sessionRevision: UInt64?
    public var externalSession = false
    public var latestReply: String?
    /// S14 (`drawer.v1`): the session's workspace directory on the host.
    public var workspace: String?
    /// S27: when the latest turn started; nil from an older bridge (then `createdAt` stands in).
    public var turnStartedAt: Date?

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
        sessionRevision = s.hasSessionRevision ? s.sessionRevision : nil
        externalSession = s.externalSession
        latestReply = s.hasLatestReply ? s.latestReply : nil
        workspace = s.hasWorkspace && !s.workspace.isEmpty ? s.workspace : nil
        turnStartedAt = s.hasTurnStartedAtMs ? Date(timeIntervalSince1970: Double(s.turnStartedAtMs) / 1000) : nil
        approvals = s.pendingApprovals.map(Approval.init)
        approvalOnly = s.approvalOnly
        modelSelection = s.hasModelSelection ? s.modelSelection : nil
    }
}

/// The answer to `Resume` (protocol/s2.proto `Resumed`).
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
    /// S29: the host refused this device with close 4003 (device unknown, D21): it was revoked
    /// (or never paired), on a live connection. Final: retrying cannot succeed (D82).
    case deviceRevoked

    public var description: String {
        switch self {
        case .notConnected: "not connected to the bridge"
        case .bridge(let code, let message): "\(code): \(message)"
        case .bridgeUpdateRequired(let version, let supported): "This host needs a bridge update. DSH \(version) is installed. This bridge supports \(supported)."
        case .unexpectedResponse: "the bridge sent an unexpected response"
        case .disconnected: "the connection to the bridge closed"
        case .deviceRevoked: "this host revoked this phone's access"
        }
    }
}

/// One connection to one host's bridge (ARCHITECTURE §4). Owns the transport, runs the
/// channel's handshake, correlates requests with responses, and publishes events. Frames are
/// sealed and sent in order from one outbox, so Noise nonces never go out of order (S1). It can
/// be connected again after it drops; reconnect policy and the resume cursor live in
/// `TaskListStore` (S2). Each connect runs a fresh handshake (over Noise: IK reconnect).
public actor HostConnection {
    public nonisolated let endpoint: HostEndpoint
    public nonisolated let channelName: String
    private let channel: any SecureChannel
    private let makeTransport: BridgeTransportFactory

    private var transport: (any BridgeTransport)?
    private var cipher: (any FrameCipher)?
    private var outbox: AsyncStream<(UInt64, Data)>.Continuation?
    private var connecting: Task<Void, any Error>?
    /// Bumped per transport, so a finished receive loop never tears down a newer connection.
    private var generation = 0
    private var receiveLoop: Task<Void, Never>?
    private var sendLoop: Task<Void, Never>?
    private var nextRequestID: UInt64 = 1
    private var pending: [UInt64: CheckedContinuation<Dshm_V1_Response, any Error>] = [:]
    private var disconnectWaiters: [CheckedContinuation<Void, Never>] = []
    private let eventContinuation: AsyncStream<HostEvent>.Continuation

    /// Every event from this host, across reconnects, for as long as the connection object lives.
    public nonisolated let events: AsyncStream<HostEvent>
    /// Capabilities from the bridge's Hello; empty until connected.
    public private(set) var capabilities: [String] = []
    /// S29 (D82): the host refused this device with close 4003 (device unknown), on a live
    /// connection (the close after a revoke) or on a reconnect (the Noise handshake). A revoked
    /// device stays refused, so `TaskListStore` does not retry it. Cleared by a connect that works.
    public private(set) var deviceRevoked = false

    /// S29: whether `error` is the host's refusal of this device (close 4003 device unknown).
    public static func isDeviceRefusal(_ error: any Error) -> Bool {
        switch error {
        case NoiseChannelError.deviceUnknown, HostConnectionError.deviceRevoked: true
        case BridgeTransportError.closed(let code, _): code == PairingWire.CloseCode.deviceUnknown.rawValue
        default: false
        }
    }

    public init(endpoint: HostEndpoint, channel: any SecureChannel, transport: @escaping BridgeTransportFactory) {
        self.endpoint = endpoint
        self.channel = channel
        self.channelName = channel.name
        self.makeTransport = transport
        (events, eventContinuation) = AsyncStream.makeStream(of: HostEvent.self)
    }

    public var isConnected: Bool { transport != nil && connecting == nil }

    /// Validates the endpoint against the channel, opens the transport, runs the channel's
    /// handshake, and exchanges Hello.
    public func connect() async throws {
        if let connecting { return try await connecting.value }
        if transport != nil { return }
        let attempt = Task { try await self.open() }
        connecting = attempt
        defer { connecting = nil }
        try await attempt.value
    }

    private func open() async throws {
        try channel.validate(endpoint)
        let t: any BridgeTransport
        let established: any FrameCipher
        do {
            t = try await makeTransport(endpoint.webSocketURL(path: channel.path))
        } catch {
            throw refusal(error)
        }
        do {
            established = try await channel.establish(over: t)
        } catch {
            await t.close()
            throw refusal(error)
        }
        generation += 1
        let gen = generation
        transport = t
        cipher = established
        let (stream, continuation) = AsyncStream.makeStream(of: (UInt64, Data).self)
        outbox = continuation
        sendLoop = Task {
            for await (id, bytes) in stream {
                do { try await t.send(bytes) } catch { self.resolve(id, with: .failure(error)) }
            }
        }
        receiveLoop = Task { await self.receive(from: t, cipher: established, generation: gen) }
        do {
            var hello = Dshm_V1_Hello()
            hello.protocolVersion = DSHProtocolInfo.version
            hello.capabilities = [DSHProtocolInfo.approvalsCapability, "sessions.v1", DSHProtocolInfo.transcriptCapability,
                                  DSHProtocolInfo.conversationCapability]
            let response = try await request(.hello(hello))
            guard case .hello(let theirs)? = response.body else { throw HostConnectionError.unexpectedResponse }
            if theirs.requiresBridgeUpdate {
                throw HostConnectionError.bridgeUpdateRequired(version: theirs.dshVersion, supported: theirs.supportedDshRange)
            }
            capabilities = theirs.capabilities
            deviceRevoked = false
        } catch {
            await teardown(generation: gen)
            throw refusal(error)
        }
    }

    /// Records a refusal of this device (S29); returns the error unchanged.
    private func refusal(_ error: any Error) -> any Error {
        if Self.isDeviceRefusal(error) { deviceRevoked = true }
        return error
    }

    /// Starts a task; its output arrives on `events`.
    public func createTask(prompt: String, selection: ModelSelection? = nil, workspace: String? = nil) async throws -> String {
        var create = Dshm_V1_CreateTask()
        create.prompt = prompt
        if let workspace {
            guard capabilities.contains("workspaces.v1") else {
                throw HostConnectionError.bridge(code: "workspace/unavailable", message: "This host cannot select the requested workspace.")
            }
            create.workspace = workspace
        }
        if let selection {
            guard capabilities.contains("models.v1") else {
                throw HostConnectionError.bridge(code: "model/unavailable", message: "This host cannot select the requested model.")
            }
            create.modelSelection = selection
        }
        let response = try await request(.createTask(create))
        guard case .taskCreated(let created)? = response.body else { throw HostConnectionError.unexpectedResponse }
        return created.taskID
    }

    public func listWorkspaces() async throws -> Dshm_V1_WorkspaceList {
        let response = try await request(.listWorkspaces(.init()))
        guard case .workspaceList(let list)? = response.body else { throw HostConnectionError.unexpectedResponse }
        return list
    }

    public func listDevices() async throws -> Dshm_V1_DeviceList {
        let response = try await request(.listDevices(.init()))
        guard case .deviceList(let list)? = response.body else { throw HostConnectionError.unexpectedResponse }
        return list
    }

    public func revokeDevice(_ id: String) async throws -> Dshm_V1_DeviceList {
        var revoke = Dshm_V1_RevokeDevice()
        revoke.deviceID = id
        let response = try await request(.revokeDevice(revoke))
        guard case .deviceList(let list)? = response.body else { throw HostConnectionError.unexpectedResponse }
        return list
    }

    public func audit(beforeID: String = "") async throws -> Dshm_V1_AuditPage {
        var list = Dshm_V1_ListAudit()
        list.beforeID = beforeID
        let response = try await request(.listAudit(list))
        guard case .auditPage(let page)? = response.body else { throw HostConnectionError.unexpectedResponse }
        return page
    }

    public func interrupt(taskID: String) async throws {
        var command = Dshm_V1_Interrupt()
        command.taskID = taskID
        let response = try await request(.interrupt(command))
        guard case .interruptAccepted? = response.body else { throw HostConnectionError.unexpectedResponse }
    }

    /// D89: one more message into the DSH session of `taskID`. Returns the message's ID once DSH
    /// accepted it; its `.userMessage` event and the new turn's events follow.
    @discardableResult
    public func sendMessage(taskID: String, text: String, mode: Dshm_V1_MessageMode = .steer) async throws -> String {
        var message = Dshm_V1_SendMessage()
        message.taskID = taskID
        message.text = text
        message.mode = mode
        let response = try await request(.sendMessage(message))
        guard case .messageAccepted(let accepted)? = response.body else { throw HostConnectionError.unexpectedResponse }
        return accepted.messageID
    }

    public func modelCatalog() async throws -> ModelCatalog {
        let response = try await request(.getModelCatalog(.init()))
        guard case .modelCatalog(let catalog)? = response.body else { throw HostConnectionError.unexpectedResponse }
        return catalog
    }

    public func selectModel(_ selection: ModelSelection, taskID: String) async throws {
        var select = Dshm_V1_SelectModel()
        select.taskID = taskID
        select.selection = selection
        let response = try await request(.selectModel(select))
        guard case .modelSelected(let accepted)? = response.body,
              accepted.taskID == taskID, accepted.selection == selection else { throw HostConnectionError.unexpectedResponse }
    }

    public func answerApproval(id: String, allow: Bool) async throws {
        var answer = Dshm_V1_AnswerApproval()
        answer.id = id
        answer.decision = allow ? .allowOnce : .deny
        let response = try await request(.answerApproval(answer))
        guard case .approvalResolved(let result)? = response.body, result.id == id,
              result.outcome == (allow ? .allowed : .denied) else { throw HostConnectionError.unexpectedResponse }
    }

    /// Read backwards at one DSH event cut so a concurrent Web turn cannot shift page boundaries.
    public func readSession(_ id: String) async throws -> Dshm_V1_SessionPage {
        var requestPage = Dshm_V1_ReadSession()
        requestPage.taskID = id
        var pages: [[Dshm_V1_SessionMessage]] = []
        while true {
            try Task.checkCancellation()
            let response = try await request(.readSession(requestPage))
            guard case .sessionPage(let page) = response.body else { throw HostConnectionError.unexpectedResponse }
            pages.append(page.messages)
            requestPage.throughSeq = page.throughSeq
            guard page.hasNextBeforeSeq else { break }
            guard !requestPage.hasBeforeSeq || page.nextBeforeSeq < requestPage.beforeSeq else {
                throw HostConnectionError.unexpectedResponse
            }
            requestPage.beforeSeq = page.nextBeforeSeq
        }
        var result = Dshm_V1_SessionPage()
        result.throughSeq = requestPage.throughSeq
        result.messages = pages.reversed().flatMap { $0 }
        return result
    }

    /// S2: every task the host knows, newest first.
    public func listTasks() async throws -> TaskListing {
        let response = try await request(.listTasks(Dshm_V1_ListTasks()))
        guard case .taskList(let list)? = response.body else { throw HostConnectionError.unexpectedResponse }
        return TaskListing(tasks: list.tasks.map(TaskSnapshot.init), logID: list.logID, hostName: list.hostName)
    }

    /// S2: asks for every logged event after `afterSeq` of log `logID`, then live events. The
    /// replayed events reach `events` before this returns.
    public func resume(logID: String, afterSeq: UInt64) async throws -> ResumeResult {
        var resume = Dshm_V1_Resume()
        resume.logID = logID
        resume.afterSeq = afterSeq
        let response = try await request(.resume(resume))
        guard case .resumed(let r)? = response.body else { throw HostConnectionError.unexpectedResponse }
        return ResumeResult(logID: r.logID, headSeq: r.headSeq, hostName: r.hostName, reset: r.reset, replayed: r.replayed)
    }

    /// Returns once the current transport is gone (immediately if there is none).
    public func waitUntilDisconnected() async {
        if transport == nil { return }
        await withCheckedContinuation { disconnectWaiters.append($0) }
    }

    public func disconnect() async {
        await teardown(generation: generation)
    }

    // MARK: - Internals

    private func teardown(generation gen: Int) async {
        guard gen == generation, let t = transport else { return }
        transport = nil
        cipher = nil
        outbox?.finish()
        outbox = nil
        sendLoop = nil
        receiveLoop?.cancel()
        receiveLoop = nil
        await t.close()
        failPending(deviceRevoked ? HostConnectionError.deviceRevoked : HostConnectionError.disconnected)
        let waiters = disconnectWaiters
        disconnectWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func request(_ body: Dshm_V1_Request.OneOf_Body) async throws -> Dshm_V1_Response {
        guard let outbox, let cipher else { throw HostConnectionError.notConnected }
        let id = nextRequestID
        nextRequestID += 1
        var frame = Dshm_V1_Frame()
        var request = Dshm_V1_Request()
        request.id = id
        request.body = body
        frame.request = request
        // Sealed here, inside the actor, and queued in the same step: outbox order = nonce order.
        let bytes = try cipher.seal(try frame.serializedBytes())
        let response = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            outbox.yield((id, bytes))
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

    private func receive(from transport: any BridgeTransport, cipher: any FrameCipher, generation gen: Int) async {
        while !Task.isCancelled {
            let frame: Dshm_V1_Frame
            do {
                let bytes = try cipher.open(try await transport.receive())
                frame = try Dshm_V1_Frame(serializedBytes: bytes)
            } catch {
                // S29: a close 4003 here is the host revoking this device (bridge/src/server.ts).
                if gen == generation, Self.isDeviceRefusal(error) { deviceRevoked = true }
                break
            }
            guard gen == generation else { break }
            switch frame.kind {
            case .response(let response)?:
                resolve(response.requestID, with: .success(response))
            case .event(let event)?:
                if let e = Self.taskEvent(event.body) {
                    eventContinuation.yield(HostEvent(hostSeq: event.hostSeq, e))
                }
            case .request?, nil:
                break
            }
        }
        await teardown(generation: gen)
    }

    private static func taskEvent(_ body: Dshm_V1_Event.OneOf_Body?) -> TaskEvent? {
        switch body {
        case .assistantChunk(let c)?:
            return .chunk(taskID: c.taskID, seq: c.seq, text: c.text)
        case .taskEnded(let e)?:
            return .ended(taskID: e.taskID, status: TaskEndStatus(wire: e.status), message: e.message)
        case .taskUpserted(let u)?:
            return .upserted(TaskSnapshot(u.task))
        case .approvalPending(let approval)?:
            return .approvalPending(Approval(approval))
        case .approvalResolved(let result)?:
            return .approvalResolved(taskID: result.taskID, id: result.id)
        case .logReset(let r)?:
            return .logReset(logID: r.logID)
        case .modelSelected(let m)?:
            return .modelSelected(taskID: m.taskID, selection: m.selection)
        case .milestoneAdded(let m)?:
            return Milestone(m).map { .milestone($0) }
        case .transcriptBlock(let b)?:
            return TranscriptItem(b).map { .transcriptBlock($0) }
        case .userMessage(let m)?:
            return .userMessage(TranscriptItem(m))
        case nil:
            return nil
        }
    }
}
