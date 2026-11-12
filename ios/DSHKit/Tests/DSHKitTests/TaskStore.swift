import DSHCore
import Foundation
import Observation

/// Single-task client used by the transport, milestone and streaming tests.
@MainActor
@Observable
final class TaskStore {
    enum Status: Equatable, Sendable {
        case idle
        case connecting
        case running(taskID: String)
        case completed
        case failed(String)
        case interrupted

        /// Stable token for UI tests (`task.status` accessibility value).
        var token: String {
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

    var prompt: String
    private(set) var transcript = ""
    private(set) var status: Status = .idle
    /// The current task's milestones (card + timeline).
    private(set) var milestones = MilestoneTimeline()

    private let connection: HostConnection
    private var currentTaskID: String?
    private var eventsTask: Task<Void, Never>?

    init(connection: HostConnection, prompt: String = "") {
        self.connection = connection
        self.prompt = prompt
    }

    var canSend: Bool {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch status {
        case .connecting, .running: return false
        case .idle, .completed, .failed, .interrupted: return true
        }
    }

    /// Sends the composer's prompt as a new task and streams its reply into `transcript`.
    func send() async {
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
