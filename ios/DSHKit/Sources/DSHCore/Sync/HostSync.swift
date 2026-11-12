import DSHTransport
import DSHProtocol
import Foundation
import DSHPlatform

/// Serializes one host's reconnects and saves its replay cursor with the rows it covers.
@MainActor
public final class HostSync {
    package let key: String
    let connection: HostConnection
    package var commands: any HostCommands { connection }
    package var endpointDescription: String { connection.endpoint.description }
    package func uses(_ config: HostConfig) -> Bool { connection === config.connection }
    package func supports(_ capability: HostCapability) -> Bool { capabilities?.contains(capability.name) == true }
    private let beforeSave: () throws -> Void
    let storage: HostStorage
    let host: CachedHost
    package var name: String { host.name }
    private(set) var capabilities: [String]?
    package private(set) var reachability: Reachability = .connecting
    var address: HostEndpoint?
    var addressFailures: [AddressFailure] = []
    private var loop: Task<Void, Never>?
    private var shutdown: Task<Void, Never>?
    private var events: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var retryTimer: Task<Void, Never>?
    private var wake: CheckedContinuation<Void, Never>?
    private var timelines: [String: MilestoneTimeline] = [:]
    private var structuredTranscripts: [String: StructuredTranscript] = [:]
    private var pendingThumbnails: [String: [MessageAttachment]] = [:]
    package var changed: () -> Void = {}
    package var online: () async -> Void = {}
    package var revoked: () -> Void = {}
    package var returnedDraft: (String, String) -> Void = { _, _ in }

    package init(config: HostConfig, cache: TaskCache, beforeSave: @escaping () throws -> Void = {}) {
        self.beforeSave = beforeSave
        key = config.key
        connection = config.connection
        storage = cache.storage.session(hostKey: key, name: config.name ?? connection.endpoint.description)
        host = storage.host
        if host.lastConnectedAt == nil, let name = config.name { host.name = name }
        saveNow()
    }

    package func start(firstConnectDelay: Duration, backoff: (initial: Duration, max: Duration)) {
        if events == nil {
            let stream = connection.events
            events = Task { [weak self] in
                for await event in stream {
                    guard let self else { break }
                    if self.loop != nil { self.apply(event) }
                }
            }
        }
        guard loop == nil else { wakeUp(); return }
        let previous = shutdown
        loop = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await run(firstConnectDelay: firstConnectDelay, backoff: backoff)
        }
    }

    package func stop() {
        let previous = loop
        loop = nil
        saveNow()
        guard let previous else { return }
        previous.cancel()
        wakeUp()
        let earlier = shutdown
        shutdown = Task {
            await earlier?.value
            await connection.disconnect()
            await previous.value
        }
    }

    package func retire() {
        stop()
        events?.cancel()
        events = nil
    }

    private func sleep(_ delay: Duration) async {
        guard !Task.isCancelled else { return }
        await withCheckedContinuation { continuation in
            wake = continuation
            retryTimer = Task {
                do { try await Task.sleep(for: delay) } catch { return }
                wakeUp()
            }
        }
    }

    private func wakeUp() {
        retryTimer?.cancel()
        retryTimer = nil
        wake?.resume()
        wake = nil
    }

    private func setReachability(_ value: Reachability) {
        guard reachability != value else { return }
        reachability = value
        changed()
    }

    private func run(firstConnectDelay: Duration, backoff: (initial: Duration, max: Duration)) async {
        if firstConnectDelay > .zero { try? await Task.sleep(for: firstConnectDelay) }
        var delay = backoff.initial
        while !Task.isCancelled {
            var failure: Reachability = .offline
            // Keep the update message visible while retrying an incompatible host.
            if reachability == .offline || reachability == .online {
                setReachability(.connecting)
            }
            do {
                try await connection.connect()
                try Task.checkCancellation()
                address = await connection.currentEndpoint
                addressFailures = []
                capabilities = await connection.capabilities
                try Task.checkCancellation()
                try flush()
                let resumed = try await connection.resume(logID: host.logID, afterSeq: UInt64(host.lastSeq))
                try Task.checkCancellation()
                if !resumed.hostName.isEmpty { host.name = resumed.hostName }
                if resumed.reset || host.needsReconciliation {
                    let tasks = try await connection.listTasks()
                    try Task.checkCancellation()
                    reconcile(tasks)
                    host.needsReconciliation = false
                }
                host.lastConnectedAt = Date()
                saveNow()
                setReachability(.online)
                if supports(.models) {
                    await online()
                }
                delay = backoff.initial
                await connection.waitUntilDisconnected()
            } catch HostConnectionError.bridgeUpdateRequired(let version, let supported) {
                capabilities = []
                failure = .needsBridgeUpdate(version: version, supported: supported)
                await connection.disconnect()
            } catch {
                await connection.disconnect()
            }
            if Task.isCancelled { break }
            let failures = await connection.addressFailures
            if addressFailures != failures {
                addressFailures = failures
                changed()
            }
            // A refusal of this device (close 4003) is final, not transient.
            if await connection.deviceRevoked {
                revoked()
                break
            }
            setReachability(failure)
            await sleep(delay)
            delay = min(delay * 2, backoff.max)
        }
    }

    // MARK: - Applying host events

    private func apply(_ event: HostEvent) {
        if case .logReset(let logID) = event.event {
            host.logID = logID
            host.needsReconciliation = true
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
            let task = taskRecord(taskID: snapshot.taskID, title: snapshot.title)
            merge(snapshot, into: task)
            task.logID = host.logID
        case .chunk(let taskID, let seq, let text):
            let task = taskRecord(taskID: taskID, title: "")
            if Int64(seq) > task.lastChunkSeq {
                task.transcript += text
                task.lastChunkSeq = Int64(seq)
            }
            task.logID = host.logID
        case .modelSelected(let taskID, let selection):
            let task = taskRecord(taskID: taskID, title: "")
            applyModel(selection, to: task)
            task.logID = host.logID
        case .ended(let taskID, let status, let message, let code):
            let task = taskRecord(taskID: taskID, title: "")
            task.state = status.state
            task.message = message
            task.failureCode = code
            // The bridge settles each waiting message before TaskEnded (taken, removed or
            // returned); one that is still here is stale and must not float above the field.
            if !task.queueData.isEmpty { task.followUpQueue = FollowUpQueue() }
            task.logID = host.logID
        case .milestone(let milestone):
            let task = taskRecord(taskID: milestone.taskID, title: "")
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
            let task = taskRecord(taskID: item.taskID, title: "")
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
            let task = taskRecord(taskID: message.taskID, title: "")
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
            if message.placement == .returned, waited { returnedDraft(task.key, message.text) }
            task.logID = host.logID
        case .questionPending(let item):
            // The card sits after the text streamed so far, as a transcript row does.
            let task = taskRecord(taskID: item.taskID, title: "")
            var blocks = structuredTranscript(of: task)
            if !blocks.items.contains(where: { $0.id == item.id }), blocks.upsert(item, offset: task.transcript.utf8.count) {
                task.structuredTranscript = blocks
                structuredTranscripts[task.key] = blocks
            }
            task.logID = host.logID
        case .questionResolved(let result):
            let task = taskRecord(taskID: result.taskID, title: "")
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
            let task = taskRecord(taskID: approval.taskID, title: "")
            if !task.approvals.contains(where: { $0.id == approval.id }) { task.approvals.append(approval) }
        case .approvalResolved(let taskID, let id):
            let key = CachedTask.key(hostKey: self.key, taskID: taskID)
            if let task = storage.task(key: key) {
                // Count each pending approval once, when it is resolved.
                if task.approvals.contains(where: { $0.id == id }) { task.approvalsAnswered += 1 }
                task.approvals.removeAll { $0.id == id }
                if task.approvalOnly && task.approvals.isEmpty { storage.delete(task) }
            }
        case .logReset:
            break
        }
        scheduleSave()
        changed()
    }

    /// After a log reset the replay may not cover every task: take the host's list as truth.
    /// Cached tasks of this host that the host no longer knows, and that were still running in
    /// a log that's gone, can never finish; they're marked failed instead of spinning forever.
    private func reconcile(_ listing: TaskListing) {
        let known = Set(listing.tasks.map(\.taskID))
        for snapshot in listing.tasks {
            let task = taskRecord(taskID: snapshot.taskID, title: snapshot.title)
            merge(snapshot, into: task)
        }
        for task in storage.tasks()
        where !known.contains(task.taskID) {
            if task.approvalOnly {
                storage.delete(task)
                continue
            }
            guard !task.state.isTerminal, task.logID != listing.logID else { continue }
            task.state = .failed
            task.approvals = []
            task.message = "The bridge on this host restarted and lost track of this task."
            task.failureCode = ""
        }
        scheduleSave()
        changed()
    }

    /// Newer host state wins; an older snapshot never moves a finished task back to running.
    func merge(_ snapshot: TaskSnapshot, into task: CachedTask) {
        let previousRevision = task.sessionRevision
        if let current = previousRevision, let incoming = snapshot.sessionRevision, incoming < UInt64(current) { return }
        let newerRevision = snapshot.sessionRevision.map { $0 > UInt64(previousRevision ?? 0) } ?? false
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
        // The host clock has millisecond precision. A follow-up can start in the same tick as a stop.
        let incomingTurn = snapshot.turnStartedAt ?? snapshot.createdAt
        let currentTurn = task.turnStartedAt ?? task.createdAt
        let winsTie = incomingTurn > currentTurn || (incomingTurn == currentTurn && !regresses)
        if newerRevision || snapshot.updatedAt > task.updatedAt || (snapshot.updatedAt == task.updatedAt && winsTie) {
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
    package func markRead(_ key: String) {
        guard let task = storage.task(key: key),
              task.state.isTerminal, task.readThrough.map({ $0 < task.updatedAt }) ?? true else { return }
        task.readThrough = task.updatedAt
        scheduleSave()
        changed()
    }

    package func cachedHistory(for row: TaskRow) -> SessionHistory? {
        let record = taskRecord(taskID: row.taskID, title: row.title)
        return record.history
    }

    package func readHistory(for row: TaskRow) async throws -> SessionHistory? {
        let cached = cachedHistory(for: row)
        guard let revision = row.sessionRevision, cached.map({ $0.throughSeq < revision }) ?? true,
              reachability == .online,
              capabilities?.contains("sessions.v1") == true else { return cached }
        let page = try await connection.readSession(row.taskID)
        try Task.checkCancellation()
        let record = taskRecord(taskID: row.taskID, title: row.title)
        if let newer = record.history, newer.throughSeq >= page.throughSeq { return newer }
        record.sessionHistory = page.cacheData
        scheduleSave()
        return page
    }

    // MARK: - Cache

    private func taskRecord(taskID: String, title: String) -> CachedTask {
        let hostKey = self.key
        let key = CachedTask.key(hostKey: hostKey, taskID: taskID)
        if let task = storage.task(key: key) {
            return task
        }
        // Until the host's summary arrives: sorted as new, and any host state is newer.
        let task = CachedTask(hostKey: hostKey, taskID: taskID, title: title, createdAt: Date())
        task.updatedAt = .distantPast
        storage.insert(task)
        return task
    }

    /// Coalesces saves; the cursor and the data it covers are saved together.
    private func scheduleSave(after delay: Duration = .milliseconds(150)) {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        do { try flush() } catch {
            // Retain the whole dirty batch. Reconnect must flush it before advertising its cursor.
            if loop != nil { scheduleSave(after: .seconds(2)) }
        }
    }

    private func flush() throws {
        try storage.flush(beforeSave: beforeSave)
    }

    package typealias UploadProgress = @MainActor @Sendable (UUID, Result<Double, any Error>) -> Void

    package func createTask(prompt: String, selection: ModelSelection?, workspace: String?,
                            attachments: [FileAttachment], progress: @escaping UploadProgress) async throws -> String {
        let ids = try await upload(attachments, progress: progress)
        let taskID = try await connection.createTask(prompt: prompt, selection: selection, workspace: workspace, uploadIDs: ids)
        return recordCreatedTask(taskID, title: prompt, attachments: attachments.map(\.sent))
    }

    package func sendFollowUp(_ text: String, for row: TaskRow, attachments: [FileAttachment],
                              progress: @escaping UploadProgress) async throws {
        let ids = try await upload(attachments, progress: progress)
        let messageID = try await connection.sendMessage(taskID: row.taskID, text: text,
                                                         mode: row.state.isTerminal ? .steer : .queue, uploadIDs: ids)
        if attachments.contains(where: { $0.thumbnail != nil }) {
            keepThumbnails(attachments.map(\.sent), messageID: messageID, taskKey: row.key)
        }
    }

    private func upload(_ files: [FileAttachment], progress: @escaping UploadProgress) async throws -> [String] {
        var ids: [String] = []
        for file in files {
            progress(file.id, .success(0))
            do {
                let id = try await connection.upload(file) { progress(file.id, .success($0)) }
                ids.append(id)
            } catch {
                progress(file.id, .failure(error))
                throw error
            }
        }
        return ids
    }

    /// The follow-up's row gets the thumbnails of its images, now or when its `UserMessage` arrives.
    private func keepThumbnails(_ sent: [MessageAttachment], messageID: String, taskKey: String) {
        let rowID = TranscriptItem.userMessageID(messageID)
        guard let task = storage.task(key: taskKey) else { return }
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
            changed()
        }
    }

    func structuredTranscript(of task: CachedTask) -> StructuredTranscript {
        if let cached = structuredTranscripts[task.key] { return cached }
        let decoded = task.structuredTranscript
        structuredTranscripts[task.key] = decoded
        return decoded
    }

    func timeline(of task: CachedTask) -> MilestoneTimeline {
        if let cached = timelines[task.key] { return cached }
        let decoded = task.milestones
        timelines[task.key] = decoded
        return decoded
    }

    private func recordCreatedTask(_ taskID: String, title: String, attachments: [MessageAttachment]) -> String {
        let task = taskRecord(taskID: taskID, title: title)
        if task.title.isEmpty { task.title = title }
        if !attachments.isEmpty { task.sentAttachments = attachments }
        saveNow()
        changed()
        return task.key
    }

    package func rename(_ name: String) {
        host.name = name
        saveNow()
    }

}
