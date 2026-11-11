import DSHProtocol
import Foundation
import Observation
import SwiftData

/// The unified task list (STORY principle 4).
///
/// - Every task from every host, cached in SwiftData, shown as running / waiting on me / done.
/// - One sync loop per host: connect, `Resume` from the cached cursor, apply the gap and live
///   events, and on disconnect reconnect with exponential backoff.
/// - Foreground refresh: the app calls `foreground()` / `background()` on scene phase changes.
/// - A host that can't be reached is named as offline (principle 3).
@MainActor
@Observable
public final class TaskListStore {
    /// One configured host: how to reach it and the key its cache rows use.
    public struct HostConfig: Sendable {
        public var key: String
        public var connection: HostConnection
        public var name: String?

        public init(key: String, connection: HostConnection, name: String? = nil) {
            self.key = key
            self.name = name
            self.connection = connection
        }
    }

    public enum Reachability: Equatable, Sendable {
        case connecting
        case online
        case offline
        case needsBridgeUpdate(version: String, supported: String)

        var isUpdateRequired: Bool {
            if case .needsBridgeUpdate = self { true } else { false }
        }

        /// Stable token for UI tests (`host.status` accessibility value).
        public var token: String {
            switch self {
            case .connecting: "connecting"
            case .online: "online"
            case .offline: "offline"
            case .needsBridgeUpdate: "bridgeUpdateRequired"
            }
        }
    }

    public struct HostStatus: Identifiable, Equatable, Sendable {
        public var id: String { key }
        public var key: String
        public var name: String
        public var reachability: Reachability
        public var lastConnectedAt: Date?
        /// The connection's channel: "noise", or "plaintext" on Debug's loopback dev path.
        public var channelName: String
        public var capabilities: [String]
        /// The address of the host in use while online, or the last one that worked.
        public var address: HostEndpoint? = nil
        /// While offline, the last error of each address of the host, in the order tried.
        public var addressFailures: [AddressFailure] = []

        /// While not online, the failure that says most about the host
        /// (`AddressFailure.mostTelling`). It stays during the next try, so X3 does not flash.
        public var offlineReason: AddressFailure? {
            reachability == .online ? nil : AddressFailure.mostTelling(addressFailures)
        }
    }

    /// A task as the views show it (a value copy of `CachedTask`).
    public struct TaskRow: Identifiable, Equatable, Sendable {
        public var id: String { key }
        public var key: String
        public var hostKey: String
        public var hostName: String
        public var taskID: String
        public var title: String
        public var state: TaskState
        public var message: String
        public var transcript: String
        public var createdAt: Date
        public var updatedAt: Date
        public var latestReply: String?
        public var sessionRevision: UInt64?
        public var externalSession: Bool
        public var approvalOnly: Bool
        public var approvals: [Approval]
        /// Milestones, from the cache: the list row shows the card.
        public var milestones: MilestoneTimeline
        public var modelSelection: ModelSelection?
        /// The session's workspace directory on the host (`drawer.v1`), from the cache.
        public var workspace: String? = nil
        /// Finished, and changed since the user last saw it on this phone.
        public var unread = false
        /// How many approvals of this task were answered, on any client.
        public var approvalsAnswered = 0
        /// Thinking and tool-call rows (`transcript.v1`), in transcript order.
        public var blocks = StructuredTranscript()
        /// When the latest turn started, if the host said.
        public var turnStartedAt: Date? = nil
        /// Follow-ups that wait while the task runs, in the order they were sent.
        public var queue: [QueuedMessage] = []
        /// The files this phone sent with the first message, with image thumbnails.
        public var attachments: [MessageAttachment] = []
        /// DSH's failure class when the task failed on its model (`QUOTA`, `AUTH`, …); empty otherwise.
        public var failureCode = ""

        /// Where the done footer's 用时 starts: the latest turn's start, else the task's
        /// creation (a single turn, or an older bridge). Never before `createdAt` or after `updatedAt`.
        public var lastTurnStart: Date {
            guard let turnStartedAt else { return createdAt }
            return min(max(turnStartedAt, createdAt), updatedAt)
        }

        /// Chunks stream the first phone turn. Its committed journal restores text after a truncated replay.
        /// A conversation with follow-ups keeps its streamed transcript, where the messages sit.
        public func singleTurnTranscript(_ messages: [SessionMessage]) -> String {
            guard state.isTerminal, blocks.followUpCount == 0 else { return transcript }
            let reply = messages.filter { !$0.fromUser }.map(\.text).joined(separator: "\n\n")
            return reply.isEmpty || transcript.contains(reply) ? transcript : reply
        }

    }

    public struct Sections: Equatable, Sendable {
        public var running: [TaskRow] = []
        public var waitingOnMe: [TaskRow] = []
        public var done: [TaskRow] = []
    }

    public private(set) var modelHosts: Set<String> = []
    public private(set) var catalogs: [String: ModelCatalog] = [:]
    public private(set) var catalogErrors: [String: String] = [:]
    public var composerSelections: [String: ModelSelection] = [:]
    public private(set) var composerWorkspaces: [String: String] = [:]

    public func chooseWorkspace(_ path: String?, hostKey: String) {
        composerWorkspaces[hostKey] = path
        sendError = nil
    }

    public func listWorkspaces(hostKey: String) async throws -> WorkspaceList {
        guard let link = links.first(where: { $0.key == hostKey }), link.reachability == .online else {
            throw HostConnectionError.notConnected
        }
        return try await link.connection.listWorkspaces()
    }

    public private(set) var composerHostKey: String?

    public func chooseHost(_ key: String) {
        guard !isSending, links.contains(where: { $0.key == key }) else { return }
        composerHostKey = key
        onHostChoice(key)
        sendError = nil
    }

    public func useHostDefault(hostKey: String) {
        composerSelections.removeValue(forKey: hostKey)
        sendError = nil
    }

    public func refreshCatalog(hostKey: String) async {
        guard modelHosts.contains(hostKey), let link = links.first(where: { $0.key == hostKey }) else { return }
        do {
            let catalog = try await link.connection.modelCatalog()
            catalogs[hostKey] = catalog
            catalogErrors[hostKey] = nil
        } catch {
            catalogErrors[hostKey] = String(describing: error)
        }
    }

    public func selectModel(_ selection: ModelSelection, for row: TaskRow) async throws {
        guard modelHosts.contains(row.hostKey), let link = links.first(where: { $0.key == row.hostKey }) else {
            throw HostConnectionError.notConnected
        }
        try await link.connection.selectModel(selection, taskID: row.taskID)
        await refreshCatalog(hostKey: row.hostKey)
    }

    public var prompt: String
    /// The files on composer 01, in order: sent to the host before the task, then dropped.
    public private(set) var composerAttachments: [ComposerAttachment] = []
    /// The files on each session page's composer, by task key, for its next follow-up.
    public private(set) var followUpAttachments: [String: [ComposerAttachment]] = [:]
    /// Thumbnails of a follow-up's images until its `UserMessage` arrives, by row id.
    @ObservationIgnored private var pendingThumbnails: [String: [MessageAttachment]] = [:]
    public private(set) var hosts: [HostStatus] = []
    public private(set) var tasks: [TaskRow] = []
    public private(set) var isSending = false
    public private(set) var sendError: String?
    /// Hosts that refused this device with close 4003 (it was revoked), as they
    /// were last shown. The store dropped them: no row, no task, no retry.
    public private(set) var revokedHosts: [HostStatus] = []
    /// Called once per host that revoked this device, after the store dropped it. The app
    /// forgets the pairing and tells the user.
    @ObservationIgnored public var onHostRevoked: (HostStatus) -> Void = { _ in }

    /// The Live Activity of each running task: brought in line after each change of the list.
    @ObservationIgnored public var liveActivities: LiveActivities? {
        didSet { syncLiveActivities() }
    }

    /// How long `send()` waits for a host that is still connecting.
    public var sendWaitsFor: Duration = .seconds(10)
    /// Reconnect backoff: first delay, doubled per failure, capped.
    public var backoff: (initial: Duration, max: Duration) = (.milliseconds(500), .seconds(30))

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private var links: [Link]
    @ObservationIgnored private let onHostChoice: (String) -> Void
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let firstConnectDelay: Duration
    /// Decoded `CachedTask.milestones`, so `refresh()` doesn't decode every task's JSON each time.
    @ObservationIgnored private var timelines: [String: MilestoneTimeline] = [:]
    /// Decoded `CachedTask.transcriptBlocksData`, for the same reason.
    @ObservationIgnored private var structuredTranscripts: [String: StructuredTranscript] = [:]

    @MainActor
    private final class Link {
        let key: String
        let connection: HostConnection
        var loop: Task<Void, Never>?
        var events: Task<Void, Never>?
        var wake: CheckedContinuation<Void, Never>?
        var capabilities: [String]?
        var reachability: Reachability = .connecting
        var address: HostEndpoint?
        var addressFailures: [AddressFailure] = []
        init(key: String, connection: HostConnection) {
            self.key = key
            self.connection = connection
        }
    }

    /// - Parameter firstConnectDelay: debug hook (`-DSHMConnectDelay`): show the cache for a
    ///   while before the first connection attempt.
    public init(container: ModelContainer, hosts: [HostConfig], prompt: String = "", firstConnectDelay: Duration = .zero,
                preferredHostKey: String? = nil, onHostChoice: @escaping (String) -> Void = { _ in }) {
        self.context = ModelContext(container)
        self.context.autosaveEnabled = false
        self.links = hosts.map { Link(key: $0.key, connection: $0.connection) }
        self.onHostChoice = onHostChoice
        self.composerHostKey = hosts.first(where: { $0.key == preferredHostKey })?.key ?? hosts.last?.key
        self.prompt = prompt
        self.firstConnectDelay = firstConnectDelay
        for host in hosts {
            if let record = cachedHost(host.key) {
                if record.lastConnectedAt == nil, let name = host.name { record.name = name }
            } else {
                context.insert(CachedHost(key: host.key, name: host.name ?? host.connection.endpoint.description))
            }
        }
        try? context.save()
        refresh()
    }

    /// Add a newly paired host or replace its old endpoint without interrupting other hosts.
    public func connectPairedHost(_ host: HostConfig) {
        let link = Link(key: host.key, connection: host.connection)
        if let index = links.firstIndex(where: { $0.key == host.key }) {
            let old = links[index]
            old.events?.cancel()
            stop(old)
            links[index] = link
            modelHosts.remove(host.key)
        } else {
            links.append(link)
        }
        let record = ensureHost(host.key)
        if let name = host.name { record.name = name }
        saveNow()
        refresh()
        foreground()
    }

    // MARK: - Reading

    public var sections: Sections {
        var s = Sections()
        for task in tasks {
            switch task.state {
            case .running: s.running.append(task)
            case .waitingOnUser: s.waitingOnMe.append(task)
            case .completed, .failed, .interrupted: s.done.append(task)
            }
        }
        return s
    }

    public func task(_ key: String) -> TaskRow? { tasks.first { $0.key == key } }

    /// Hosts that can't be reached right now, by name.
    public var offlineHosts: [HostStatus] { hosts.filter { $0.reachability == .offline } }

    /// Whether the composer's host can take attachments (`attachments.v1`).
    public var canAttach: Bool {
        hosts.contains { $0.key == composerHostKey && $0.reachability == .online
            && $0.capabilities.contains(DSHProtocolInfo.attachmentsCapability) }
    }

    /// Whether a follow-up to `row` can take attachments: once the task is done (completed or
    /// stopped), not while it runs (a queued message carries text only).
    public func canAttach(to row: TaskRow) -> Bool {
        row.state.isTerminal && canFollowUp(row) && links.first { $0.key == row.hostKey }?.capabilities?.contains(DSHProtocolInfo.attachmentsCapability) == true
    }

    public func attachments(on target: AttachTarget) -> [ComposerAttachment] {
        switch target {
        case .composer: composerAttachments
        case .followUp(let key): followUpAttachments[key] ?? []
        }
    }

    private func setAttachments(_ list: [ComposerAttachment], on target: AttachTarget) {
        switch target {
        case .composer: composerAttachments = list
        case .followUp(let key): followUpAttachments[key] = list.isEmpty ? nil : list
        }
    }

    /// Adds a file at the end of a composer. A file over the limit stays, with the error on
    /// its chip, and the send waits until it is removed. Returns false when the composer already
    /// has `Attachments.maxCount` files.
    @discardableResult
    public func attach(_ attachment: FileAttachment, to target: AttachTarget = .composer) -> Bool {
        var list = attachments(on: target)
        guard list.count < Attachments.maxCount else { return false }
        list.append(ComposerAttachment(attachment))
        setAttachments(list, on: target)
        if target == .composer { sendError = nil }
        return true
    }

    public func removeAttachment(_ id: UUID, from target: AttachTarget = .composer) {
        setAttachments(attachments(on: target).filter { $0.id != id }, on: target)
        if target == .composer { sendError = nil }
    }

    private func setStatus(_ status: ComposerAttachment.Status, of id: UUID, on target: AttachTarget) {
        var list = attachments(on: target)
        guard let at = list.firstIndex(where: { $0.id == id }) else { return }
        list[at].status = status
        setAttachments(list, on: target)
    }

    /// Uploads the files of a composer in order, each chip showing its progress. On a refusal
    /// the chip shows the error and the send stops; the files stay on the composer.
    private func uploadAttachments(on target: AttachTarget, via connection: HostConnection) async throws -> [String] {
        var uploadIDs: [String] = []
        for item in attachments(on: target) {
            setStatus(.uploading(0), of: item.id, on: target)
            do {
                uploadIDs.append(try await connection.upload(item.attachment) { [weak self] fraction in
                    self?.setStatus(.uploading(fraction), of: item.id, on: target)
                })
            } catch {
                setStatus(.failed(String(describing: error)), of: item.id, on: target)
                throw error
            }
        }
        return uploadIDs
    }

    /// Whether a composer's files can go: none is over the limit.
    private func attachmentsCanSend(on target: AttachTarget) -> Bool {
        !attachments(on: target).contains { $0.status == .tooLarge }
    }

    public var canSend: Bool {
        // With every host offline, the send key is off (X3).
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending && !allHostsOffline
            && attachmentsCanSend(on: .composer)
    }

    // MARK: - Lifecycle

    /// Starts (or wakes) every host's sync loop. Call on launch and whenever the app comes to
    /// the foreground; a host waiting out its backoff retries at once.
    public func foreground() {
        for link in links {
            if link.events == nil {
                let events = link.connection.events
                link.events = Task { [weak self] in
                    for await event in events { self?.apply(event, from: link) }
                }
            }
            if link.loop == nil {
                link.loop = Task { [weak self] in await self?.run(link) }
            } else if let wake = link.wake {
                link.wake = nil
                wake.resume()
            }
        }
    }

    /// iOS can't keep sockets alive in the background (ARCHITECTURE §4): save, stop the loops,
    /// and close the connections. `foreground()` resumes from the cursor.
    public func background() {
        for link in links { stop(link) }
        saveNow()
    }

    private func stop(_ link: Link) {
        link.loop?.cancel()
        link.loop = nil
        link.wake?.resume()
        link.wake = nil
        let connection = link.connection
        Task { await connection.disconnect() }
    }

    // MARK: - Sending

    /// Sends the composer's prompt as a new task on the selected host. Returns the new task's key,
    /// or nil with `sendError` set (for example, the host is offline).
    @discardableResult
    public func send() async -> String? {
        guard canSend, let link = links.first(where: { $0.key == composerHostKey }) else { return nil }
        let text = prompt
        let selection = composerSelections[link.key]
        let workspace = composerWorkspaces[link.key]
        isSending = true
        sendError = nil
        defer { isSending = false }
        guard await waitOnline(link) else {
            let name = hosts.first { $0.key == link.key }?.name ?? link.key
            if case .needsBridgeUpdate(let version, let supported) = link.reachability {
                sendError = "\(name) needs a bridge update. Installed DSH: \(version). Supported DSH: \(supported)."
            } else {
                sendError = "\(name) is offline. The task was not sent."
            }
            return nil
        }
        do {
            // The files go to the host first, in order; the task names their upload ids.
            let sent = composerAttachments.map(\.attachment.sent)
            let uploadIDs = try await uploadAttachments(on: .composer, via: link.connection)
            let taskID = try await link.connection.createTask(prompt: text, selection: selection, workspace: workspace,
                                                              uploadIDs: uploadIDs)
            let task = taskRecord(hostKey: link.key, taskID: taskID, title: text)
            if task.title.isEmpty { task.title = text }
            if !sent.isEmpty { task.sentAttachments = sent }
            prompt = ""
            composerAttachments = []
            composerWorkspaces[link.key] = nil // A workspace choice is for this one new session.
            onHostChoice(link.key)
            saveNow()
            refresh()
            return task.key
        } catch {
            sendError = String(describing: error)
            return nil
        }
    }

    public func deviceManagement(for hostKey: String) -> (any HostDeviceManagement)? {
        guard let link = links.first(where: { $0.key == hostKey }), link.reachability == .online,
              link.capabilities?.contains("devices.v1") == true else { return nil }
        return link.connection
    }

    public func interrupt(_ row: TaskRow) async throws {
        guard let link = links.first(where: { $0.key == row.hostKey }), link.reachability == .online else {
            throw HostConnectionError.notConnected
        }
        try await link.connection.interrupt(taskID: row.taskID)
    }

    /// The host can take a follow-up for this task now: the host is online with `conversation.v1`,
    /// and the task is done. With `conversation.v2` also while it runs (the message
    /// waits in a queue) and after the user stopped it (the session goes on). With `failures.v1`
    /// also after a failure: the user tops up or fixes the key, then goes on in the session.
    public func canFollowUp(_ row: TaskRow) -> Bool {
        guard !row.externalSession, !row.approvalOnly,
              let link = links.first(where: { $0.key == row.hostKey }), link.reachability == .online,
              let capabilities = link.capabilities, capabilities.contains(DSHProtocolInfo.conversationCapability) else { return false }
        switch row.state {
        case .completed: return true
        case .running, .waitingOnUser, .interrupted: return capabilities.contains(DSHProtocolInfo.queueCapability)
        case .failed: return capabilities.contains(DSHProtocolInfo.failuresCapability)
        }
    }

    /// Sends `text` into the DSH session of `row`. The user message and the new turn arrive as host
    /// events, so the page shows them in order, and a reconnect replays them. While the task
    /// runs, the message waits in its queue (`QUEUE`): the next turn, unless the user sends it now.
    /// Once the task is done, the files on the page's composer go up first and with the
    /// message; then they leave it.
    public func sendFollowUp(_ text: String, for row: TaskRow) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard canFollowUp(row), let link = links.first(where: { $0.key == row.hostKey }) else {
            throw HostConnectionError.notConnected
        }
        let target = AttachTarget.followUp(taskKey: row.key)
        guard attachmentsCanSend(on: target) else {
            throw HostConnectionError.bridge(code: "upload/too-large",
                                             message: "Remove the files larger than \(Attachments.sizeText(Attachments.maxBytes)).")
        }
        let sent = attachments(on: target).map(\.attachment.sent)
        let mode: Dshm_V1_MessageMode = row.state.isTerminal ? .steer : .queue
        let uploadIDs = sent.isEmpty ? [] : try await uploadAttachments(on: target, via: link.connection)
        let messageID = try await link.connection.sendMessage(taskID: row.taskID, text: trimmed, mode: mode, uploadIDs: uploadIDs)
        setAttachments([], on: target)
        if sent.contains(where: { $0.thumbnail != nil }) { keepThumbnails(sent, messageID: messageID, taskKey: row.key) }
    }

    /// The follow-up's row gets the thumbnails of its images, now or when its `UserMessage` arrives.
    private func keepThumbnails(_ sent: [MessageAttachment], messageID: String, taskKey: String) {
        let rowID = TranscriptItem.userMessageID(messageID)
        guard let task = try? context.fetch(FetchDescriptor<CachedTask>(predicate: #Predicate { $0.key == taskKey })).first else { return }
        var blocks = structuredTranscript(of: task)
        guard var item = blocks.items.first(where: { $0.id == rowID }) else {
            pendingThumbnails[taskKey + "\n" + rowID] = sent
            return
        }
        item.attachments = (item.attachments ?? []).keepingThumbnails(of: sent)
        if blocks.upsert(item, offset: item.offset) {
            task.structuredTranscript = blocks
            structuredTranscripts[task.key] = blocks
            scheduleSave()
            refresh()
        }
    }

    /// "立即发送": the waiting message goes in at the next step of the running turn.
    public func sendNow(_ message: QueuedMessage, for row: TaskRow) async throws {
        try await editQueue(message, for: row, action: .steer)
    }

    /// Takes a waiting message out of the queue; it does not run.
    public func removeQueued(_ message: QueuedMessage, for row: TaskRow) async throws {
        try await editQueue(message, for: row, action: .remove)
    }

    private func editQueue(_ message: QueuedMessage, for row: TaskRow, action: Dshm_V1_QueueAction) async throws {
        guard let link = links.first(where: { $0.key == row.hostKey }), link.reachability == .online else {
            throw HostConnectionError.notConnected
        }
        try await link.connection.editQueue(taskID: row.taskID, messageID: message.id, action: action)
    }

    /// The texts of follow-ups that the task did not run because it stopped, for the
    /// composer of the task's page. They leave the store when the page takes them.
    public private(set) var returnedDrafts: [String: [String]] = [:]

    public func takeReturnedDrafts(for taskKey: String) -> [String] {
        returnedDrafts.removeValue(forKey: taskKey) ?? []
    }

    public func answerApproval(_ approval: Approval, hostKey: String, allow: Bool) async throws {
        guard let link = links.first(where: { $0.key == hostKey }), link.reachability == .online,
              link.capabilities?.contains(DSHProtocolInfo.approvalsCapability) == true else { throw HostConnectionError.notConnected }
        try await link.connection.answerApproval(id: approval.id, allow: allow)
    }

    /// Answers an agent question (`questions.v1`). The card closes on the host's `QuestionResolved`.
    public func answerQuestion(_ question: AgentQuestion, hostKey: String, answers: [String: AgentQuestion.Reply]) async throws {
        guard canAnswerQuestions(hostKey: hostKey) else { throw HostConnectionError.notConnected }
        try await links.first { $0.key == hostKey }!.connection.answerQuestion(id: question.requestID, answers: answers)
    }

    /// Answers an agent question with what the user typed in the session's composer ("回答 Agent…"):
    /// the text goes to the question, not into the task as a follow-up.
    public func answerQuestion(_ question: AgentQuestion, hostKey: String, typed text: String) async throws {
        try await answerQuestion(question, hostKey: hostKey, answers: question.replies(typed: text))
    }

    /// Whether this phone can answer the questions of the host now: online, with `questions.v1`.
    public func canAnswerQuestions(hostKey: String) -> Bool {
        links.contains { $0.key == hostKey && $0.reachability == .online
            && $0.capabilities?.contains(DSHProtocolInfo.questionsCapability) == true }
    }

    /// Waits for the host to be online: through a connection attempt in progress, or one
    /// started now if the host was offline. False once that attempt fails, or on timeout.
    private func waitOnline(_ link: Link) async -> Bool {
        if link.reachability == .offline { foreground() }
        let clock = ContinuousClock()
        let deadline = clock.now + sendWaitsFor
        var sawAttempt = false
        while clock.now < deadline {
            switch link.reachability {
            case .online: return true
            case .needsBridgeUpdate: return false
            case .connecting: sawAttempt = true
            case .offline: if sawAttempt { return false }
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    // MARK: - Sync loop

    private func run(_ link: Link) async {
        if firstConnectDelay > .zero { try? await Task.sleep(for: firstConnectDelay) }
        var delay = backoff.initial
        while !Task.isCancelled {
            var failure: Reachability = .offline
            // Keep the update message visible while retrying an incompatible host.
            if link.reachability == .offline || link.reachability == .online {
                setReachability(.connecting, link)
            }
            do {
                try await link.connection.connect()
                try Task.checkCancellation()
                link.address = await link.connection.currentEndpoint
                link.addressFailures = []
                link.capabilities = await link.connection.capabilities
                let host = ensureHost(link.key)
                let resumed = try await link.connection.resume(logID: host.logID, afterSeq: UInt64(host.lastSeq))
                try Task.checkCancellation()
                if !resumed.hostName.isEmpty { host.name = resumed.hostName }
                if resumed.reset {
                    let tasks = try await link.connection.listTasks()
                    try Task.checkCancellation()
                    reconcile(tasks, hostKey: link.key)
                }
                host.lastConnectedAt = Date()
                saveNow()
                setReachability(.online, link)
                if link.capabilities?.contains("models.v1") == true {
                    modelHosts.insert(link.key)
                    await refreshCatalog(hostKey: link.key)
                }
                delay = backoff.initial
                await link.connection.waitUntilDisconnected()
            } catch HostConnectionError.bridgeUpdateRequired(let version, let supported) {
                link.capabilities = []
                failure = .needsBridgeUpdate(version: version, supported: supported)
                await link.connection.disconnect()
            } catch {
                await link.connection.disconnect()
            }
            if Task.isCancelled { break }
            let failures = await link.connection.addressFailures
            if link.addressFailures != failures {
                link.addressFailures = failures
                refresh()
            }
            // A refusal of this device (close 4003) is final, not transient.
            if await link.connection.deviceRevoked {
                dropRevoked(link)
                break
            }
            setReachability(failure, link)
            await sleep(delay, link)
            delay = min(delay * 2, backoff.max)
        }
    }

    /// The host revoked this device. Drop it like a host that was never configured (its
    /// rows go too; the cache stays on disk until the app forgets the host), and say so once.
    private func dropRevoked(_ link: Link) {
        guard let index = links.firstIndex(where: { $0 === link }) else { return }
        let status = hosts.first { $0.key == link.key }
        link.loop = nil
        link.events?.cancel()
        link.events = nil
        links.remove(at: index)
        modelHosts.remove(link.key)
        catalogs[link.key] = nil
        if composerHostKey == link.key { composerHostKey = links.last?.key }
        updateAllHostsOffline()
        refresh()
        guard let status else { return }
        revokedHosts.append(status)
        onHostRevoked(status)
    }

    /// Waits out a backoff delay, or until `foreground()` wakes the loop.
    private func sleep(_ delay: Duration, _ link: Link) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            link.wake = continuation
            Task { [weak self] in
                try? await Task.sleep(for: delay)
                self?.wakeUp(link)
            }
        }
    }

    private func wakeUp(_ link: Link) {
        // One continuation is pending at a time; whoever takes it first resumes it.
        guard let wake = link.wake else { return }
        link.wake = nil
        wake.resume()
    }

    private func setReachability(_ r: Reachability, _ link: Link) {
        if r != .online { modelHosts.remove(link.key) }
        guard link.reachability != r else { return }
        link.reachability = r
        updateAllHostsOffline()
        refresh()
    }

    /// No host can take a task (screen X3). True once every host has failed to connect
    /// (offline, or its DSH needs an update); it stays true while hosts retry, and goes false
    /// when one is online. So the card on 01 does not flash on each reconnect attempt.
    public private(set) var allHostsOffline = false

    private func updateAllHostsOffline() {
        if links.contains(where: { $0.reachability == .online }) {
            allHostsOffline = false
        } else if !links.isEmpty, links.allSatisfy({ $0.reachability == .offline || $0.reachability.isUpdateRequired }) {
            allHostsOffline = true
        }
    }

    // MARK: - Applying host events

    private func apply(_ event: HostEvent, from link: Link) {
        let host = ensureHost(link.key)
        if case .logReset(let logID) = event.event {
            host.logID = logID
            host.lastSeq = 0
            scheduleSave()
            return
        }
        if event.hostSeq > 0 {
            // Replays can overlap what was applied already; the cursor makes them idempotent.
            guard Int64(event.hostSeq) > host.lastSeq else { return }
            host.lastSeq = Int64(event.hostSeq)
        }
        switch event.event {
        case .upserted(let snapshot):
            let task = taskRecord(hostKey: link.key, taskID: snapshot.taskID, title: snapshot.title)
            merge(snapshot, into: task)
            task.logID = host.logID
        case .chunk(let taskID, let seq, let text):
            let task = taskRecord(hostKey: link.key, taskID: taskID, title: "")
            if Int64(seq) > task.lastChunkSeq {
                task.transcript += text
                task.lastChunkSeq = Int64(seq)
            }
            task.logID = host.logID
        case .modelSelected(let taskID, let selection):
            let task = taskRecord(hostKey: link.key, taskID: taskID, title: "")
            applyModel(selection, to: task)
            task.logID = host.logID
        case .ended(let taskID, let status, let message, let code):
            let task = taskRecord(hostKey: link.key, taskID: taskID, title: "")
            task.state = status.state
            task.message = message
            task.failureCode = code
            // The bridge settles each waiting message before TaskEnded (taken, removed or
            // returned); one that is still here is stale and must not float above the field.
            if !task.queueData.isEmpty { task.followUpQueue = FollowUpQueue() }
            task.logID = host.logID
        case .milestone(let milestone):
            let task = taskRecord(hostKey: link.key, taskID: milestone.taskID, title: "")
            var timeline = timeline(of: task)
            // Replays can repeat milestones; the timeline keeps only newer seqs.
            if timeline.add(milestone) {
                task.milestones = timeline
                timelines[task.key] = timeline
            }
            task.logID = host.logID
        case .transcriptBlock(var item), .userMessage(var item):
            // A new row sits after the text streamed so far; an update keeps its place.
            // A follow-up message sits there too, and the next turn's text streams after it.
            let task = taskRecord(hostKey: link.key, taskID: item.taskID, title: "")
            var blocks = structuredTranscript(of: task)
            if let attachments = item.attachments {
                // A replay keeps the thumbnails this phone already has.
                let local = blocks.items.first { $0.id == item.id }?.attachments
                    ?? pendingThumbnails.removeValue(forKey: task.key + "\n" + item.id)
                item.attachments = attachments.keepingThumbnails(of: local)
            }
            if blocks.upsert(item, offset: task.transcript.utf8.count) {
                task.structuredTranscript = blocks
                structuredTranscripts[task.key] = blocks
            }
            // A follow-up that waited is in the transcript now, where DSH took it.
            if case .userMessage = event.event, item.id.hasPrefix(TranscriptItem.messagePrefix), !task.queueData.isEmpty {
                var queue = task.followUpQueue
                if queue.taken(String(item.id.dropFirst(TranscriptItem.messagePrefix.count))) { task.followUpQueue = queue }
            }
            task.logID = host.logID
        case .queuedMessage(let message):
            let task = taskRecord(hostKey: link.key, taskID: message.taskID, title: "")
            var queue = task.followUpQueue
            var blocks = structuredTranscript(of: task)
            let rowID = TranscriptItem.userMessageID(message.id)
            let sentNow = blocks.items.contains { $0.id == rowID && $0.state == .running }
            let waited = queue.messages.contains { $0.id == message.id } || sentNow
            if message.placement == .steering {
                // Sent now, it is the user's message in this turn: a bubble in the transcript at
                // once (not above the field), marked until DSH takes it at the agent's next step.
                if queue.taken(message.id) { task.followUpQueue = queue }
                let row = TranscriptItem(id: rowID, taskID: message.taskID, state: .running,
                                         kind: .userMessage(text: message.text), time: message.time)
                if !blocks.items.contains(where: { $0.id == rowID }), blocks.upsert(row, offset: task.transcript.utf8.count) {
                    task.structuredTranscript = blocks
                    structuredTranscripts[task.key] = blocks
                }
            } else {
                if queue.apply(message) { task.followUpQueue = queue }
                if !message.placement.isWaiting, sentNow, blocks.remove(id: rowID) {
                    // A message sent now that DSH did not take (stopped, or removed elsewhere) leaves the transcript.
                    task.structuredTranscript = blocks
                    structuredTranscripts[task.key] = blocks
                }
            }
            // The task stopped before it ran: its text goes back to this phone's composer.
            if message.placement == .returned, waited { returnedDrafts[task.key, default: []].append(message.text) }
            task.logID = host.logID
        case .questionPending(let item):
            // The card sits after the text streamed so far, as a transcript row does.
            let task = taskRecord(hostKey: link.key, taskID: item.taskID, title: "")
            var blocks = structuredTranscript(of: task)
            if !blocks.items.contains(where: { $0.id == item.id }), blocks.upsert(item, offset: task.transcript.utf8.count) {
                task.structuredTranscript = blocks
                structuredTranscripts[task.key] = blocks
            }
            task.logID = host.logID
        case .questionResolved(let result):
            let task = taskRecord(hostKey: link.key, taskID: result.taskID, title: "")
            var blocks = structuredTranscript(of: task)
            if var row = blocks.items.first(where: { $0.id == AgentQuestion.rowID(result.id) }), let question = row.question {
                let closed = question.resolved(result)
                row.kind = .question(closed)
                row.state = closed.outcome == .cancelled ? .failed : .done
                if blocks.upsert(row, offset: row.offset) {
                    task.structuredTranscript = blocks
                    structuredTranscripts[task.key] = blocks
                }
            }
            task.logID = host.logID
        case .approvalPending(let approval):
            let task = taskRecord(hostKey: link.key, taskID: approval.taskID, title: "")
            if !task.approvals.contains(where: { $0.id == approval.id }) { task.approvals.append(approval) }
        case .approvalResolved(let taskID, let id):
            let key = CachedTask.key(hostKey: link.key, taskID: taskID)
            if let task = try? context.fetch(FetchDescriptor<CachedTask>(predicate: #Predicate { $0.key == key })).first {
                // Count each pending approval once, when it is resolved.
                if task.approvals.contains(where: { $0.id == id }) { task.approvalsAnswered += 1 }
                task.approvals.removeAll { $0.id == id }
                if task.approvalOnly && task.approvals.isEmpty { context.delete(task) }
            }
        case .logReset:
            break
        }
        scheduleSave()
        refresh()
    }

    /// After a log reset the replay may not cover every task: take the host's list as truth.
    /// Cached tasks of this host that the host no longer knows, and that were still running in
    /// a log that's gone, can never finish; they're marked failed instead of spinning forever.
    private func reconcile(_ listing: TaskListing, hostKey: String) {
        let known = Set(listing.tasks.map(\.taskID))
        for snapshot in listing.tasks {
            let task = taskRecord(hostKey: hostKey, taskID: snapshot.taskID, title: snapshot.title)
            merge(snapshot, into: task)
        }
        for task in cachedTasks(hostKey: hostKey)
        where !known.contains(task.taskID) {
            if task.approvalOnly {
                context.delete(task)
                continue
            }
            guard !task.state.isTerminal, task.logID != listing.logID else { continue }
            task.state = .failed
            task.approvals = []
            task.message = "The bridge on this host restarted and lost track of this task."
            task.failureCode = ""
        }
        scheduleSave()
        refresh()
    }

    /// Newer host state wins; an older snapshot never moves a finished task back to running.
    func merge(_ snapshot: TaskSnapshot, into task: CachedTask) {
        let previousRevision = task.sessionRevision
        if let current = previousRevision, let incoming = snapshot.sessionRevision, incoming < UInt64(current) { return }
        let newerTurn = snapshot.sessionRevision.map { $0 > UInt64(previousRevision ?? 0) } ?? false
        if !snapshot.title.isEmpty { task.title = snapshot.title }
        if let revision = snapshot.sessionRevision {
            task.sessionRevision = max(task.sessionRevision ?? 0, Int64(revision))
            task.externalSession = snapshot.externalSession
            task.latestReply = snapshot.latestReply
        }
        task.createdAt = snapshot.createdAt
        task.approvalOnly = snapshot.approvalOnly
        if let workspace = snapshot.workspace { task.workspace = workspace }
        let regresses = task.state.isTerminal && !snapshot.state.isTerminal
        if newerTurn || snapshot.updatedAt > task.updatedAt || (snapshot.updatedAt == task.updatedAt && !regresses) {
            task.approvals = snapshot.approvals
            if let selection = snapshot.modelSelection { applyModel(selection, to: task) }
            task.state = snapshot.state
            task.message = snapshot.message
            task.failureCode = snapshot.failureCode
            task.updatedAt = snapshot.updatedAt
            task.turnStartedAt = snapshot.turnStartedAt
        }
        // The questions of the summary, as for approvals: a card the trimmed log lost.
        var blocks = structuredTranscript(of: task)
        if blocks.restoreQuestions(snapshot.questions, offset: task.transcript.utf8.count, ended: task.state.isTerminal) {
            task.structuredTranscript = blocks
            structuredTranscripts[task.key] = blocks
        }
    }

    private func applyModel(_ selection: ModelSelection, to task: CachedTask) {
        let data = try? selection.wire.serializedData()
        if task.modelSelectionData != data {
            task.modelSelectionData = data
            task.transcript += selection.transcriptLine
        }
    }

    /// The user saw this session as it is now. A finished session loses its unread mark
    /// until the host reports a newer change. Stored in the cache, on this phone only.
    public func markRead(_ key: String) {
        guard let task = try? context.fetch(FetchDescriptor<CachedTask>(predicate: #Predicate { $0.key == key })).first,
              task.state.isTerminal, task.readThrough.map({ $0 < task.updatedAt }) ?? true else { return }
        task.readThrough = task.updatedAt
        scheduleSave()
        refresh()
    }

    public func cachedHistory(for row: TaskRow) -> SessionHistory? {
        let record = taskRecord(hostKey: row.hostKey, taskID: row.taskID, title: row.title)
        return record.history
    }

    public func readHistory(for row: TaskRow) async throws -> SessionHistory? {
        let cached = cachedHistory(for: row)
        guard let revision = row.sessionRevision, cached.map({ $0.throughSeq < revision }) ?? true,
              let link = links.first(where: { $0.key == row.hostKey }), link.reachability == .online,
              link.capabilities?.contains("sessions.v1") == true else { return cached }
        let page = try await link.connection.readSession(row.taskID)
        try Task.checkCancellation()
        let record = taskRecord(hostKey: row.hostKey, taskID: row.taskID, title: row.title)
        if let newer = record.history, newer.throughSeq >= page.throughSeq { return newer }
        record.sessionHistory = page.cacheData
        scheduleSave()
        return page
    }

    // MARK: - Cache

    private func cachedHost(_ key: String) -> CachedHost? {
        try? context.fetch(FetchDescriptor<CachedHost>(predicate: #Predicate { $0.key == key })).first
    }

    private func ensureHost(_ key: String) -> CachedHost {
        if let host = cachedHost(key) { return host }
        let host = CachedHost(key: key, name: key)
        context.insert(host)
        return host
    }

    private func cachedTasks(hostKey: String) -> [CachedTask] {
        (try? context.fetch(FetchDescriptor<CachedTask>(predicate: #Predicate { $0.hostKey == hostKey }))) ?? []
    }

    private func taskRecord(hostKey: String, taskID: String, title: String) -> CachedTask {
        let key = CachedTask.key(hostKey: hostKey, taskID: taskID)
        if let task = try? context.fetch(FetchDescriptor<CachedTask>(predicate: #Predicate { $0.key == key })).first {
            return task
        }
        // Until the host's summary arrives: sorted as new, and any host state is newer.
        let task = CachedTask(hostKey: hostKey, taskID: taskID, title: title, createdAt: Date())
        task.updatedAt = .distantPast
        context.insert(task)
        return task
    }

    /// Coalesces saves; the cursor and the data it covers are saved together.
    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            self?.saveNow()
        }
    }

    private func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        if context.hasChanges { try? context.save() }
    }

    private func refresh() {
        let hostRecords = (try? context.fetch(FetchDescriptor<CachedHost>())) ?? []
        var names = Dictionary(hostRecords.map { ($0.key, $0.name) }, uniquingKeysWith: { a, _ in a })
        // Two independently paired machines can advertise the same name.
        for (name, group) in Dictionary(grouping: links, by: { names[$0.key] ?? $0.key }) where group.count > 1 {
            for link in group {
                let address = link.connection.endpoint.description
                let uniqueAddress = group.filter { $0.connection.endpoint.description == address }.count == 1
                names[link.key] = "\(name) (\(uniqueAddress ? address : link.key))"
            }
        }
        hosts = links.map { link in
            let record = hostRecords.first { $0.key == link.key }
            return HostStatus(
                key: link.key, name: names[link.key] ?? link.key,
                reachability: link.reachability, lastConnectedAt: record?.lastConnectedAt,
                channelName: link.connection.channelName, capabilities: link.capabilities ?? [],
                address: link.address, addressFailures: link.addressFailures)
        }
        let descriptor = FetchDescriptor<CachedTask>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        tasks = ((try? context.fetch(descriptor)) ?? []).compactMap { t in
            // Before Hello, cached requests remain readable offline; a downgrade hides unsupported UI.
            guard let link = links.first(where: { $0.key == t.hostKey }) else { return nil }
            let supportsApprovals = link.capabilities?.contains(DSHProtocolInfo.approvalsCapability)
            if t.approvalOnly && supportsApprovals == false { return nil }
            return TaskRow(
                key: t.key, hostKey: t.hostKey, hostName: names[t.hostKey] ?? t.hostKey, taskID: t.taskID,
                title: t.title, state: t.state, message: t.message, transcript: t.transcript,
                createdAt: t.createdAt, updatedAt: t.updatedAt,
                latestReply: t.latestReply, sessionRevision: t.sessionRevision.map(UInt64.init), externalSession: t.externalSession,
                approvalOnly: t.approvalOnly, approvals: supportsApprovals == false ? [] : t.approvals,
                milestones: timeline(of: t),
                modelSelection: t.modelSelectionData.flatMap { (try? Dshm_V1_ModelSelection(serializedBytes: $0)).map(ModelSelection.init) },
                workspace: t.workspace, unread: t.state.isTerminal && (t.readThrough.map { $0 < t.updatedAt } ?? true),
                approvalsAnswered: t.approvalsAnswered,
                blocks: link.capabilities?.contains(DSHProtocolInfo.transcriptCapability) == false
                    ? structuredTranscript(of: t).userMessagesOnly : structuredTranscript(of: t),
                turnStartedAt: t.turnStartedAt,
                queue: t.queueData.isEmpty ? [] : t.followUpQueue.messages, attachments: t.sentAttachments,
                failureCode: t.failureCode)
        }
        syncLiveActivities()
    }

    private func syncLiveActivities() {
        liveActivities?.sync(tasks, onlineHosts: Set(hosts.filter { $0.reachability == .online }.map(\.key)))
    }

    private func structuredTranscript(of task: CachedTask) -> StructuredTranscript {
        if let cached = structuredTranscripts[task.key] { return cached }
        let decoded = task.structuredTranscript
        structuredTranscripts[task.key] = decoded
        return decoded
    }

    private func timeline(of task: CachedTask) -> MilestoneTimeline {
        if let cached = timelines[task.key] { return cached }
        let decoded = task.milestones
        timelines[task.key] = decoded
        return decoded
    }
}
