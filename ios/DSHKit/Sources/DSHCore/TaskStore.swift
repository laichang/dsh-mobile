import Foundation
import Observation

/// State behind the first single-task screen: one composer, one task at a time, in memory only. Since
/// the durable list, the app uses `TaskListStore` (durable list + resume); this stays as the minimal client.
@MainActor
@Observable
public final class TaskStore {
    public enum Status: Equatable, Sendable {
        case idle
        case connecting
        case running(taskID: String)
        case completed
        case failed(String)
        case interrupted

        /// Stable token for UI tests (`task.status` accessibility value).
        public var token: String {
            switch self {
            case .idle: "idle"
            case .connecting: "connecting"
            case .running: "running"
            case .completed: "completed"
            case .failed: "failed"
            case .interrupted: "interrupted"
            }
        }
    }

    public var prompt: String
    public private(set) var transcript = ""
    public private(set) var status: Status = .idle
    /// The current task's milestones (card + timeline).
    public private(set) var milestones = MilestoneTimeline()

    private let connection: HostConnection
    private var currentTaskID: String?
    private var eventsTask: Task<Void, Never>?

    public init(connection: HostConnection, prompt: String = "") {
        self.connection = connection
        self.prompt = prompt
    }

    /// Transport shown in the status row.
    public var channelName: String { connection.channelName }
    public var endpoint: HostEndpoint { connection.endpoint }

    public var canSend: Bool {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch status {
        case .connecting, .running: return false
        case .idle, .completed, .failed, .interrupted: return true
        }
    }

    /// Sends the composer's prompt as a new task and streams its reply into `transcript`.
    public func send() async {
        guard canSend else { return }
        let text = prompt
        transcript = ""
        milestones = MilestoneTimeline()
        currentTaskID = nil
        status = .connecting
        startListening()
        do {
            try await connection.connect()
            let taskID = try await connection.createTask(prompt: text)
            // Events can arrive before createTask returns; only switch to running if not ended yet.
            if currentTaskID == nil || currentTaskID == taskID, case .connecting = status {
                status = .running(taskID: taskID)
            }
            currentTaskID = taskID
        } catch {
            status = .failed(String(describing: error))
        }
    }

    private func startListening() {
        guard eventsTask == nil else { return }
        let events = connection.events
        eventsTask = Task { [weak self] in
            for await event in events {
                self?.apply(event.event)
            }
        }
    }

    private func apply(_ event: TaskEvent) {
        switch event {
        case .chunk(let taskID, _, let text):
            guard currentTaskID == nil || currentTaskID == taskID else { return }
            currentTaskID = taskID
            if case .connecting = status { status = .running(taskID: taskID) }
            transcript += text
        case .ended(let taskID, let endStatus, let message, _):
            guard currentTaskID == nil || currentTaskID == taskID else { return }
            currentTaskID = taskID
            status = switch endStatus {
            case .completed: .completed
            case .failed: .failed(message.isEmpty ? "the task failed" : message)
            case .interrupted: .interrupted
            }
        case .milestone(let milestone):
            guard currentTaskID == nil || currentTaskID == milestone.taskID else { return }
            currentTaskID = milestone.taskID
            if case .connecting = status { status = .running(taskID: milestone.taskID) }
            milestones.add(milestone)
        case .upserted, .logReset, .modelSelected, .approvalPending, .approvalResolved, .transcriptBlock,
             .questionPending, .questionResolved, .userMessage, .queuedMessage:
            break
        }
    }
}
