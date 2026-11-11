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
        /// The negotiated channel shown in the host status row.
        public var channelName: String
        public var isEncrypted: Bool { channelName == "noise" || channelName == "TLS 1.3" }
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

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private var links: [HostSync]
    @ObservationIgnored private let onHostChoice: (String) -> Void
    @ObservationIgnored private let firstConnectDelay: Duration

    /// - Parameter firstConnectDelay: debug hook (`-DSHMConnectDelay`): show the cache for a
    ///   while before the first connection attempt.
    public init(container: ModelContainer, hosts: [HostConfig], prompt: String = "", firstConnectDelay: Duration = .zero,
                preferredHostKey: String? = nil, onHostChoice: @escaping (String) -> Void = { _ in }) {
        self.container = container
        self.links = hosts.map { HostSync(config: $0, container: container) }
        self.onHostChoice = onHostChoice
        self.composerHostKey = hosts.first(where: { $0.key == preferredHostKey })?.key ?? hosts.last?.key
        self.prompt = prompt
        self.firstConnectDelay = firstConnectDelay
        for link in links { observe(link) }
        refresh()
    }

    private func observe(_ link: HostSync) {
        link.changed = { [weak self] in self?.refresh() }
        link.online = { [weak self, key = link.key] in await self?.refreshCatalog(hostKey: key) }
        link.revoked = { [weak self, weak link] in
            if let link { self?.dropRevoked(link) }
        }
        link.returnedDraft = { [weak self] key, text in self?.returnedDrafts[key, default: []].append(text) }
    }

    public func connectPairedHost(_ host: HostConfig) {
        let existing = links.firstIndex { $0.key == host.key }
        if let existing, links[existing].connection === host.connection {
            if let name = host.name { links[existing].rename(name) }
            refresh()
            foreground()
            return
        }
        if let existing { links[existing].retire() }
        let link = HostSync(config: host, container: container)
        if let name = host.name { link.rename(name) }
        observe(link)
        if let existing { links[existing] = link } else { links.append(link) }
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
        for link in links { link.start(firstConnectDelay: firstConnectDelay, backoff: backoff) }
    }

    public func background() {
        for link in links { link.stop() }
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
            let key = link.recordCreatedTask(taskID, title: text, attachments: sent)
            prompt = ""
            composerAttachments = []
            composerWorkspaces[link.key] = nil // A workspace choice is for this one new session.
            onHostChoice(link.key)
            return key
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
        if sent.contains(where: { $0.thumbnail != nil }) { link.keepThumbnails(sent, messageID: messageID, taskKey: row.key) }
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
    private func waitOnline(_ link: HostSync) async -> Bool {
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

    /// The host revoked this device. Drop it like a host that was never configured (its
    /// rows go too; the cache stays on disk until the app forgets the host), and say so once.
    private func dropRevoked(_ link: HostSync) {
        guard let index = links.firstIndex(where: { $0 === link }) else { return }
        let status = hosts.first { $0.key == link.key }
        link.retire()
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

    public func markRead(_ key: String) {
        guard let row = task(key) else { return }
        links.first { $0.key == row.hostKey }?.markRead(key)
    }

    public func cachedHistory(for row: TaskRow) -> SessionHistory? {
        links.first { $0.key == row.hostKey }?.cachedHistory(for: row)
    }

    public func readHistory(for row: TaskRow) async throws -> SessionHistory? {
        try await links.first { $0.key == row.hostKey }?.readHistory(for: row)
    }

    private func refresh() {
        var names = Dictionary(links.map { ($0.key, $0.name) }, uniquingKeysWith: { first, _ in first })
        // Two independently paired machines can advertise the same name.
        for (name, group) in Dictionary(grouping: links, by: { names[$0.key] ?? $0.key }) where group.count > 1 {
            for link in group {
                let address = link.connection.endpoint.description
                let uniqueAddress = group.filter { $0.connection.endpoint.description == address }.count == 1
                names[link.key] = "\(name) (\(uniqueAddress ? address : link.key))"
            }
        }
        hosts = links.map { $0.status(named: names[$0.key] ?? $0.name) }
        tasks = links.flatMap { $0.rows(hostName: names[$0.key] ?? $0.name) }.sorted { $0.createdAt > $1.createdAt }
        modelHosts = Set(links.filter { $0.reachability == .online && $0.capabilities?.contains("models.v1") == true }.map(\.key))
        updateAllHostsOffline()
        syncLiveActivities()
    }

    private func syncLiveActivities() {
        liveActivities?.sync(tasks, onlineHosts: Set(hosts.filter { $0.reachability == .online }.map(\.key)))
    }

}
