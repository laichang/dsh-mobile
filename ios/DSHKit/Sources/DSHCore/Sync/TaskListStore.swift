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

        public init(key: String, connection: HostConnection) {
            self.key = key
            self.connection = connection
        }
    }

    public enum Reachability: Equatable, Sendable {
        case connecting
        case online
        case offline

        /// Stable token for UI tests (`host.status` accessibility value).
        public var token: String {
            switch self {
            case .connecting: "connecting"
            case .online: "online"
            case .offline: "offline"
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
        /// S3 milestones, from the cache (S2 x S3 seam): the list row shows the card.
        public var milestones: MilestoneTimeline
    }

    public struct Sections: Equatable, Sendable {
        public var running: [TaskRow] = []
        public var waitingOnMe: [TaskRow] = []
        public var done: [TaskRow] = []
    }

    public var prompt: String
    public private(set) var hosts: [HostStatus] = []
    public private(set) var tasks: [TaskRow] = []
    public private(set) var isSending = false
    public private(set) var sendError: String?

    /// How long `send()` waits for a host that is still connecting.
    public var sendWaitsFor: Duration = .seconds(10)
    /// Reconnect backoff: first delay, doubled per failure, capped.
    public var backoff: (initial: Duration, max: Duration) = (.milliseconds(500), .seconds(30))

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let links: [Link]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let firstConnectDelay: Duration
    /// Decoded `CachedTask.milestones`, so `refresh()` doesn't decode every task's JSON each time.
    @ObservationIgnored private var timelines: [String: MilestoneTimeline] = [:]

    @MainActor
    private final class Link {
        let key: String
        let connection: HostConnection
        var loop: Task<Void, Never>?
        var events: Task<Void, Never>?
        var wake: CheckedContinuation<Void, Never>?
        var reachability: Reachability = .connecting
        init(key: String, connection: HostConnection) {
            self.key = key
            self.connection = connection
        }
    }

    /// - Parameter firstConnectDelay: debug hook (`-DSHMConnectDelay`): show the cache for a
    ///   while before the first connection attempt.
    public init(container: ModelContainer, hosts: [HostConfig], prompt: String = "", firstConnectDelay: Duration = .zero) {
        self.context = ModelContext(container)
        self.context.autosaveEnabled = false
        self.links = hosts.map { Link(key: $0.key, connection: $0.connection) }
        self.prompt = prompt
        self.firstConnectDelay = firstConnectDelay
        for link in links where cachedHost(link.key) == nil {
            context.insert(CachedHost(key: link.key, name: link.connection.endpoint.description))
        }
        try? context.save()
        refresh()
    }

    // MARK: - Reading

    public var sections: Sections {
        var s = Sections()
        for task in tasks {
            switch task.state {
            case .running: s.running.append(task)
            case .waitingOnUser: s.waitingOnMe.append(task)
            case .completed, .failed: s.done.append(task)
            }
        }
        return s
    }

    public func task(_ key: String) -> TaskRow? { tasks.first { $0.key == key } }

    /// Hosts that can't be reached right now, by name.
    public var offlineHosts: [HostStatus] { hosts.filter { $0.reachability == .offline } }

    public var canSend: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
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
        for link in links {
            link.loop?.cancel()
            link.loop = nil
            link.wake?.resume()
            link.wake = nil
            let connection = link.connection
            Task { await connection.disconnect() }
        }
        saveNow()
    }

    // MARK: - Sending

    /// Sends the composer's prompt as a new task on the first host. Returns the new task's key,
    /// or nil with `sendError` set (for example, the host is offline).
    @discardableResult
    public func send() async -> String? {
        guard canSend, let link = links.first else { return nil }
        let text = prompt
        isSending = true
        sendError = nil
        defer { isSending = false }
        guard await waitOnline(link) else {
            sendError = "\(hostName(link.key)) is offline. The task was not sent."
            return nil
        }
        do {
            let taskID = try await link.connection.createTask(prompt: text)
            let task = taskRecord(hostKey: link.key, taskID: taskID, title: text)
            if task.title.isEmpty { task.title = text }
            prompt = ""
            saveNow()
            refresh()
            return task.key
        } catch {
            sendError = String(describing: error)
            return nil
        }
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
            setReachability(.connecting, link)
            do {
                try await link.connection.connect()
                let host = ensureHost(link.key)
                let resumed = try await link.connection.resume(logID: host.logID, afterSeq: UInt64(host.lastSeq))
                if !resumed.hostName.isEmpty { host.name = resumed.hostName }
                if resumed.reset {
                    reconcile(try await link.connection.listTasks(), hostKey: link.key)
                }
                host.lastConnectedAt = Date()
                saveNow()
                setReachability(.online, link)
                delay = backoff.initial
                await link.connection.waitUntilDisconnected()
            } catch {
                await link.connection.disconnect()
            }
            if Task.isCancelled { break }
            setReachability(.offline, link)
            await sleep(delay, link)
            delay = min(delay * 2, backoff.max)
        }
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
        guard link.reachability != r else { return }
        link.reachability = r
        refresh()
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
        case .ended(let taskID, let status, let message):
            let task = taskRecord(hostKey: link.key, taskID: taskID, title: "")
            task.state = status == .completed ? .completed : .failed
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
        where !known.contains(task.taskID) && !task.state.isTerminal && task.logID != listing.logID {
            task.state = .failed
            task.message = "The bridge on this host restarted and lost track of this task."
        }
        scheduleSave()
        refresh()
    }

    /// Newer host state wins; an older snapshot never moves a finished task back to running.
    private func merge(_ snapshot: TaskSnapshot, into task: CachedTask) {
        if !snapshot.title.isEmpty { task.title = snapshot.title }
        task.createdAt = snapshot.createdAt
        let regresses = task.state.isTerminal && !snapshot.state.isTerminal
        if snapshot.updatedAt > task.updatedAt || (snapshot.updatedAt == task.updatedAt && !regresses) {
            task.state = snapshot.state
            task.message = snapshot.message
            task.updatedAt = snapshot.updatedAt
        }
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

    private func hostName(_ key: String) -> String { cachedHost(key)?.name ?? key }

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
        let names = Dictionary(hostRecords.map { ($0.key, $0.name) }, uniquingKeysWith: { a, _ in a })
        hosts = links.map { link in
            let record = hostRecords.first { $0.key == link.key }
            return HostStatus(
                key: link.key, name: record?.name ?? link.key,
                reachability: link.reachability, lastConnectedAt: record?.lastConnectedAt,
                channelName: link.connection.channelName)
        }
        let descriptor = FetchDescriptor<CachedTask>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        tasks = ((try? context.fetch(descriptor)) ?? []).map { t in
            TaskRow(
                key: t.key, hostKey: t.hostKey, hostName: names[t.hostKey] ?? t.hostKey, taskID: t.taskID,
                title: t.title, state: t.state, message: t.message, transcript: t.transcript,
                createdAt: t.createdAt, updatedAt: t.updatedAt, milestones: timeline(of: t))
        }
    }

    private func timeline(of task: CachedTask) -> MilestoneTimeline {
        if let cached = timelines[task.key] { return cached }
        let decoded = task.milestones
        timelines[task.key] = decoded
        return decoded
    }
}
