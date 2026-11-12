import DSHCore
import Foundation
import Observation

/// Combines per-host snapshots for the task list and routes user actions to the selected host.
@MainActor
@Observable
public final class TaskListStore {
    public typealias HostConfig = HostSync.HostConfig
    public typealias HostStatus = HostSync.HostStatus
    public typealias Reachability = HostSync.Reachability
    public typealias TaskRow = HostSync.TaskRow

    public struct Sections: Equatable, Sendable {
        public var running: [TaskRow] = []
        public var waitingOnMe: [TaskRow] = []
        public var done: [TaskRow] = []
    }

    public let composer: TaskComposer
    public private(set) var modelHosts: Set<String> = []
    public private(set) var catalogs: [String: ModelCatalog] = [:]
    public private(set) var catalogErrors: [String: String] = [:]
    public func listWorkspaces(hostKey: String) async throws -> WorkspaceList {
        guard let link = links.first(where: { $0.key == hostKey }), link.reachability == .online else {
            throw HostConnectionError.notConnected
        }
        return try await link.commands.listWorkspaces()
    }


    public func chooseHost(_ key: String) {
        guard !composer.isSending, links.contains(where: { $0.key == key }) else { return }
        composer.hostKey = key
        onHostChoice(key)
        composer.sendError = nil
    }

    public func refreshCatalog(hostKey: String) async {
        guard modelHosts.contains(hostKey), let link = links.first(where: { $0.key == hostKey }) else { return }
        do {
            let catalog = try await link.commands.modelCatalog()
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
        try await link.commands.selectModel(selection, taskID: row.taskID)
        await refreshCatalog(hostKey: row.hostKey)
    }

    public private(set) var hosts: [HostStatus] = []
    public private(set) var tasks: [TaskRow] = []
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

    @ObservationIgnored private let cache: TaskCache
    @ObservationIgnored private var links: [HostSync]
    @ObservationIgnored private let onHostChoice: (String) -> Void
    @ObservationIgnored private let firstConnectDelay: Duration

    /// - Parameter firstConnectDelay: debug hook (`-DSHMConnectDelay`): show the cache for a
    ///   while before the first connection attempt.
    public init(cache: TaskCache, hosts: [HostConfig], prompt: String = "", firstConnectDelay: Duration = .zero,
                preferredHostKey: String? = nil, onHostChoice: @escaping (String) -> Void = { _ in }) {
        self.cache = cache
        self.links = hosts.map { HostSync(config: $0, cache: cache) }
        self.onHostChoice = onHostChoice
        composer = TaskComposer(prompt: prompt, hostKey: hosts.first(where: { $0.key == preferredHostKey })?.key ?? hosts.last?.key)
        self.firstConnectDelay = firstConnectDelay
        for link in links { observe(link) }
        refresh()
    }

    private func observe(_ link: HostSync) {
        link.changed = { [weak self] in self?.refresh() }
        link.online = { [weak self, key = link.key] in await self?.refreshCatalog(hostKey: key) }
        link.revoked = { [weak self] status in
            guard let self else { return }
            forget(status.enrollment)
            revokedHosts.append(status)
            onHostRevoked(status)
        }
        link.returnedDraft = { [weak self] key, text in self?.composer.returnedDrafts[key, default: []].append(text) }
    }

    public func connectPairedHost(_ host: HostConfig) {
        let existing = links.firstIndex { $0.key == host.key }
        if let existing, links[existing].uses(host) {
            if let name = host.name { links[existing].rename(name) }
            refresh()
            foreground()
            return
        }
        if let existing { links[existing].retire() }
        let link = HostSync(config: host, cache: cache)
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
        hosts.contains { $0.key == composer.hostKey && $0.reachability == .online
            && $0.supports(.attachments) }
    }

    /// Whether a follow-up to `row` can take attachments: once the task is done (completed or
    /// stopped), not while it runs (a queued message carries text only).
    public func canAttach(to row: TaskRow) -> Bool {
        row.state.isTerminal && canFollowUp(row) && links.first { $0.key == row.hostKey }?.supports(.attachments) == true
    }

    public var canSend: Bool {
        // With every host offline, the send key is off (X3).
        !allHostsOffline && composer.canSend
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

    @discardableResult
    public func send() async -> String? {
        guard canSend, let link = links.first(where: { $0.key == composer.hostKey }) else { return nil }
        let key = await composer.send(on: link, waitOnline: waitOnline) {
            self.hosts.first { $0.key == link.key }?.name ?? link.key
        }
        if key != nil { onHostChoice(link.key) }
        return key
    }

    public func deviceManagement(for hostKey: String) -> (any HostDeviceManagement)? {
        guard let link = links.first(where: { $0.key == hostKey }), link.reachability == .online,
              link.supports(.devices) else { return nil }
        return link.commands
    }

    public func interrupt(_ row: TaskRow) async throws {
        guard let link = links.first(where: { $0.key == row.hostKey }), link.reachability == .online else {
            throw HostConnectionError.notConnected
        }
        try await link.commands.interrupt(taskID: row.taskID)
    }

    /// The host can take a follow-up for this task now: the host is online with `conversation.v1`,
    /// and the task is done. With `conversation.v2` also while it runs (the message
    /// waits in a queue) and after the user stopped it (the session goes on). With `failures.v1`
    /// also after a failure: the user tops up or fixes the key, then goes on in the session.
    public func canFollowUp(_ row: TaskRow) -> Bool {
        guard !row.externalSession, !row.approvalOnly,
              let link = links.first(where: { $0.key == row.hostKey }), link.reachability == .online,
              link.supports(.conversation) else { return false }
        switch row.state {
        case .completed: return true
        case .running, .waitingOnUser, .interrupted: return link.supports(.queue)
        case .failed: return link.supports(.failures)
        }
    }

    public private(set) var sendingSessionMessages: Set<String> = []

    public func submitDraft(for row: TaskRow, answering question: AgentQuestion?) async throws {
        guard let text = composer.sessionDrafts[row.key],
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let question {
            guard sendingSessionMessages.insert(row.key).inserted else { throw MessageSendError.sendInProgress }
            defer { sendingSessionMessages.remove(row.key) }
            try await answerQuestion(question, hostKey: row.hostKey, typed: text)
        } else {
            try await sendFollowUp(text, for: row)
        }
        if composer.sessionDrafts[row.key] == text { composer.sessionDrafts[row.key] = nil }
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
        guard sendingSessionMessages.insert(row.key).inserted else { throw MessageSendError.sendInProgress }
        defer { sendingSessionMessages.remove(row.key) }
        let files = composer.attachments(on: target).map(\.attachment)
        try await link.sendFollowUp(trimmed, for: row, attachments: files,
                                    progress: composer.uploadProgress(on: target))
        composer.consume(files, on: target)
    }

    /// "立即发送": the waiting message goes in at the next step of the running turn.
    public func sendNow(_ message: QueuedMessage, for row: TaskRow) async throws {
        try await editQueue(message, for: row, action: .steer)
    }

    /// Takes a waiting message out of the queue; it does not run.
    public func removeQueued(_ message: QueuedMessage, for row: TaskRow) async throws {
        try await editQueue(message, for: row, action: .remove)
    }

    private func editQueue(_ message: QueuedMessage, for row: TaskRow, action: QueueAction) async throws {
        guard let link = links.first(where: { $0.key == row.hostKey }), link.reachability == .online else {
            throw HostConnectionError.notConnected
        }
        try await link.commands.editQueue(taskID: row.taskID, messageID: message.id, action: action)
    }

    public func answerApproval(_ approval: Approval, hostKey: String, allow: Bool) async throws {
        guard let link = links.first(where: { $0.key == hostKey }), link.reachability == .online,
              link.supports(.approvals) else { throw HostConnectionError.notConnected }
        try await link.commands.answerApproval(id: approval.id, allow: allow)
    }

    /// Answers an agent question (`questions.v1`). The card closes on the host's `QuestionResolved`.
    public func answerQuestion(_ question: AgentQuestion, hostKey: String, answers: [String: AgentQuestion.Reply]) async throws {
        guard canAnswerQuestions(hostKey: hostKey) else { throw HostConnectionError.notConnected }
        try await links.first { $0.key == hostKey }!.commands.answerQuestion(id: question.requestID, answers: answers)
    }

    /// Answers an agent question with what the user typed in the session's composer ("回答 Agent…"):
    /// the text goes to the question, not into the task as a follow-up.
    public func answerQuestion(_ question: AgentQuestion, hostKey: String, typed text: String) async throws {
        try await answerQuestion(question, hostKey: hostKey, answers: question.replies(typed: text))
    }

    /// Whether this phone can answer the questions of the host now: online, with `questions.v1`.
    public func canAnswerQuestions(hostKey: String) -> Bool {
        links.contains { $0.key == hostKey && $0.reachability == .online
            && $0.supports(.questions) }
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

    /// A delayed revoke can retire only the link created for that registration.
    public func forget(_ origin: HostEnrollment) {
        guard let index = links.firstIndex(where: { $0.enrollment == origin }) else { return }
        let link = links.remove(at: index)
        link.retire()
        modelHosts.remove(link.key)
        catalogs[link.key] = nil
        if composer.hostKey == link.key { composer.hostKey = links.last?.key }
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
                let address = link.endpointDescription
                let uniqueAddress = group.filter { $0.endpointDescription == address }.count == 1
                names[link.key] = "\(name) (\(uniqueAddress ? address : link.key))"
            }
        }
        hosts = links.map { $0.status(named: names[$0.key] ?? $0.name) }
        tasks = links.flatMap { $0.rows(hostName: names[$0.key] ?? $0.name) }.sorted { $0.createdAt > $1.createdAt }
        modelHosts = Set(links.filter { $0.reachability == .online && $0.supports(.models) }.map(\.key))
        updateAllHostsOffline()
        syncLiveActivities()
    }

    private func syncLiveActivities() {
        liveActivities?.sync(tasks, onlineHosts: Set(hosts.filter { $0.reachability == .online }.map(\.key)))
    }

}

/// Remembers which registration already caused a notice or dismissal in this installation's UI.
public struct ForgottenEnrollments {
    public private(set) var enrollments: Set<HostEnrollment> = []

    public init() {}

    public mutating func forget(_ origin: HostEnrollment, removing: (HostEnrollment) throws -> Bool) rethrows -> Bool {
        guard !enrollments.contains(origin) else { return false }
        let wasCurrent = try removing(origin)
        enrollments.insert(origin)
        return wasCurrent
    }
}
