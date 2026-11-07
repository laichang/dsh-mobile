import DSHProtocol
import Foundation
import Observation
import SwiftData

/// S2 · the unified task list (STORY principle 4, ARCHITECTURE D9 / D20).
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
        /// The connection's channel (S1): "noise", or "plaintext" on Debug's loopback dev path.
        public var channelName: String
        public var capabilities: [String]
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
        /// S3 milestones, from the cache (S2 x S3 seam): the list row shows the card.
        public var milestones: MilestoneTimeline
        public var modelSelection: ModelSelection?
        /// S14: the session's workspace directory on the host (`drawer.v1`), from the cache.
        public var workspace: String? = nil
        /// S14: finished, and changed since the user last saw it on this phone.
        public var unread = false
        /// S19: how many approvals of this task were answered, on any client.
        public var approvalsAnswered = 0
        /// S17: thinking and tool-call rows (`transcript.v1`), in transcript order.
        public var blocks = StructuredTranscript()

        /// Chunks stream the first phone turn. Its committed journal restores text after a truncated replay.
        public func singleTurnTranscript(_ messages: [Dshm_V1_SessionMessage]) -> String {
            guard state.isTerminal else { return transcript }
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

    public func listWorkspaces(hostKey: String) async throws -> Dshm_V1_WorkspaceList {
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
    public private(set) var hosts: [HostStatus] = []
    public private(set) var tasks: [TaskRow] = []
    public private(set) var isSending = false
    public private(set) var sendError: String?
    /// S29 (D82): hosts that refused this device with close 4003 (it was revoked), as they
    /// were last shown. The store dropped them: no row, no task, no retry.
    public private(set) var revokedHosts: [HostStatus] = []
    /// S29: called once per host that revoked this device, after the store dropped it. The app
    /// forgets the pairing (D59) and tells the user.
    @ObservationIgnored public var onHostRevoked: (HostStatus) -> Void = { _ in }

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
    /// S17: decoded `CachedTask.transcriptBlocksData`, for the same reason.
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

    public var canSend: Bool {
        // S21: with every host offline, the send key is off (X3).
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending && !allHostsOffline
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
            let taskID = try await link.connection.createTask(prompt: text, selection: selection, workspace: workspace)
            let task = taskRecord(hostKey: link.key, taskID: taskID, title: text)
            if task.title.isEmpty { task.title = text }
            prompt = ""
            composerWorkspaces[link.key] = nil // S20: a workspace choice is for this one new session.
            onHostChoice(link.key)
            saveNow()
            refresh()
            return task.key
        } catch {
            sendError = String(describing: error)
            return nil
        }
    }

    public func deviceManagement(for hostKey: String) -> HostConnection? {
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

    public func answerApproval(_ approval: Approval, hostKey: String, allow: Bool) async throws {
        guard let link = links.first(where: { $0.key == hostKey }), link.reachability == .online,
              link.capabilities?.contains(DSHProtocolInfo.approvalsCapability) == true else { throw HostConnectionError.notConnected }
        try await link.connection.answerApproval(id: approval.id, allow: allow)
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
            // S29 (D82): a refusal of this device (close 4003) is final, not transient.
            if await link.connection.deviceRevoked {
                dropRevoked(link)
                break
            }
            setReachability(failure, link)
            await sleep(delay, link)
            delay = min(delay * 2, backoff.max)
        }
    }

    /// S29: the host revoked this device. Drop it like a host that was never configured (its
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

    /// S21: no host can take a task (screen X3). True once every host has failed to connect
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
        case .ended(let taskID, let status, let message):
            let task = taskRecord(hostKey: link.key, taskID: taskID, title: "")
            task.state = status.state
            task.message = message
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
        case .transcriptBlock(let item):
            // S17: a new row sits after the text streamed so far; an update keeps its place.
            let task = taskRecord(hostKey: link.key, taskID: item.taskID, title: "")
            var blocks = structuredTranscript(of: task)
            if blocks.upsert(item, offset: task.transcript.utf8.count) {
                task.structuredTranscript = blocks
                structuredTranscripts[task.key] = blocks
            }
            task.logID = host.logID
        case .approvalPending(let approval):
            let task = taskRecord(hostKey: link.key, taskID: approval.taskID, title: "")
            if !task.approvals.contains(where: { $0.id == approval.id }) { task.approvals.append(approval) }
        case .approvalResolved(let taskID, let id):
            let key = CachedTask.key(hostKey: link.key, taskID: taskID)
            if let task = try? context.fetch(FetchDescriptor<CachedTask>(predicate: #Predicate { $0.key == key })).first {
                // S19: count each pending approval once, when it is resolved.
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
            task.updatedAt = snapshot.updatedAt
        }
    }

    private func applyModel(_ selection: ModelSelection, to task: CachedTask) {
        let data = try? selection.serializedData()
        if task.modelSelectionData != data {
            task.modelSelectionData = data
            task.transcript += selection.transcriptLine
        }
    }

    /// S14: the user saw this session as it is now. A finished session loses its unread mark
    /// until the host reports a newer change. Stored in the cache, on this phone only.
    public func markRead(_ key: String) {
        guard let task = try? context.fetch(FetchDescriptor<CachedTask>(predicate: #Predicate { $0.key == key })).first,
              task.state.isTerminal, task.readThrough.map({ $0 < task.updatedAt }) ?? true else { return }
        task.readThrough = task.updatedAt
        scheduleSave()
        refresh()
    }

    public func cachedHistory(for row: TaskRow) -> Dshm_V1_SessionPage? {
        let record = taskRecord(hostKey: row.hostKey, taskID: row.taskID, title: row.title)
        return record.sessionHistory.flatMap { try? Dshm_V1_SessionPage(serializedBytes: $0) }
    }

    public func readHistory(for row: TaskRow) async throws -> Dshm_V1_SessionPage? {
        let cached = cachedHistory(for: row)
        guard let revision = row.sessionRevision, cached.map({ $0.throughSeq < revision }) ?? true,
              let link = links.first(where: { $0.key == row.hostKey }), link.reachability == .online,
              link.capabilities?.contains("sessions.v1") == true else { return cached }
        let page = try await link.connection.readSession(row.taskID)
        try Task.checkCancellation()
        taskRecord(hostKey: row.hostKey, taskID: row.taskID, title: row.title).sessionHistory = try page.serializedData()
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
                channelName: link.connection.channelName, capabilities: link.capabilities ?? [])
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
                modelSelection: t.modelSelectionData.flatMap { try? ModelSelection(serializedBytes: $0) },
                workspace: t.workspace, unread: t.state.isTerminal && (t.readThrough.map { $0 < t.updatedAt } ?? true),
                approvalsAnswered: t.approvalsAnswered,
                blocks: link.capabilities?.contains(DSHProtocolInfo.transcriptCapability) == false
                    ? StructuredTranscript() : structuredTranscript(of: t))
        }
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
