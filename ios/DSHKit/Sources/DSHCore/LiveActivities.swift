import DSHActivity
import Foundation

/// One Live Activity as the system keeps it: what it shows, and whether it ended.
public struct LiveActivityRecord: Equatable, Sendable {
    public var hostName: String
    public var state: TaskActivityState
    /// Ended: it shows its final state until the system or the user removes it.
    public var ended: Bool

    public init(hostName: String, state: TaskActivityState, ended: Bool) {
        self.hostName = hostName
        self.state = state
        self.ended = ended
    }
}

/// The system's Live Activities of this app (ActivityKit in the app, a fake in tests).
@MainActor
public protocol LiveActivityClient: AnyObject {
    /// Every activity of this app by task key, also the ones from before a relaunch.
    func current() -> [String: LiveActivityRecord]
    func start(key: String, hostName: String, state: TaskActivityState, staleDate: Date)
    func update(key: String, state: TaskActivityState, staleDate: Date)
    /// Ends the activity with its final state; it stays on the lock screen for a while.
    func end(key: String, state: TaskActivityState)
    /// Removes the activity at once.
    func dismiss(key: String)
}

/// The Live Activity of each running task (screen L, ARCHITECTURE D119–D121). A local activity
/// only: the app starts and updates it while it runs and receives the host's events; no APNs.
///
/// - A task that runs on a host that is online gets one activity. It shows the title, the host,
///   the time since the turn started (the widget ticks it), and the latest step.
/// - Each milestone updates it, with a new `staleDate`.
/// - It ends when the task is done, failed or stopped, or waits on the user (an approval, or an
///   agent question). If the task then runs again, the ended one goes and a new one starts.
/// - One activity for each task, also after a relaunch: the activities that the system still has
///   are taken over, not started again.
@MainActor
public final class LiveActivities {
    private let client: LiveActivityClient
    private let staleAfter: TimeInterval
    private let step: @MainActor (TaskListStore.TaskRow) -> String
    private let now: () -> Date
    private var records: [String: LiveActivityRecord]
    /// When each active activity was last sent, to move its stale date on in time.
    private var sentAt: [String: Date] = [:]

    /// - Parameters:
    ///   - staleAfter: the system greys out an activity this long after its last update.
    ///   - step: the latest step as the session page's milestone bar says it.
    public init(client: LiveActivityClient, staleAfter: Duration = .seconds(15 * 60),
                step: @escaping @MainActor (TaskListStore.TaskRow) -> String = LiveActivities.defaultStep,
                now: @escaping () -> Date = Date.init) {
        self.client = client
        self.staleAfter = TimeInterval(staleAfter.components.seconds)
        self.step = step
        self.now = now
        records = client.current()
    }

    /// The step text without the app's labels: the todo in progress, else DSH's words.
    public static func defaultStep(_ row: TaskListStore.TaskRow) -> String {
        row.milestones.activeTodo?.content ?? row.milestones.current?.text ?? ""
    }

    /// What the activity of `row` shows now.
    public func state(of row: TaskListStore.TaskRow) -> TaskActivityState {
        let started = max(row.turnStartedAt ?? row.createdAt, row.createdAt)
        let phase = Self.phase(of: row)
        let ended = phase.isRunning ? nil : max(row.updatedAt, row.milestones.current?.time ?? .distantPast, started)
        return TaskActivityState(phase: phase, title: row.title, step: step(row),
                                 done: row.milestones.completedCount, total: row.milestones.todos.count,
                                 startedAt: started, endedAt: ended)
    }

    public static func phase(of row: TaskListStore.TaskRow) -> TaskActivityState.Phase {
        let asks = row.blocks.items.contains { $0.question.map { $0.outcome == nil } ?? false }
        switch row.state {
        case .completed: return .done
        case .failed: return .failed
        case .interrupted: return .stopped
        case .waitingOnUser: return asks && row.approvals.isEmpty ? .question : .approval
        case .running:
            if !row.approvals.isEmpty { return .approval }
            return asks ? .question : .running
        }
    }

    /// Brings the activities in line with the task list. The store calls it after each change.
    public func sync(_ tasks: [TaskListStore.TaskRow], onlineHosts: Set<String>) {
        var seen = Set<String>()
        for row in tasks where !row.approvalOnly {
            seen.insert(row.key)
            let state = state(of: row)
            let record = records[row.key]
            switch (record, state.phase.isRunning) {
            case (nil, true):
                if onlineHosts.contains(row.hostKey) { start(row, state) }
            case (nil, false):
                break // Never seen running here: no activity.
            case (let record?, true) where record.ended:
                // It runs again (an answer, a follow-up): one activity for each task.
                guard onlineHosts.contains(row.hostKey) else { break }
                client.dismiss(key: row.key)
                start(row, state)
            case (let record?, true):
                let due = sentAt[row.key].map { now().timeIntervalSince($0) >= staleAfter / 2 } ?? true
                if record.state != state || due {
                    client.update(key: row.key, state: state, staleDate: now().addingTimeInterval(staleAfter))
                    records[row.key]?.state = state
                    sentAt[row.key] = now()
                }
            case (let record?, false):
                if !record.ended || record.state != state {
                    client.end(key: row.key, state: state)
                    records[row.key] = LiveActivityRecord(hostName: record.hostName, state: state, ended: true)
                    sentAt[row.key] = nil
                }
            }
        }
        // A task that left the list (a reset cache, a forgotten host) leaves no activity.
        for key in records.keys where !seen.contains(key) {
            client.dismiss(key: key)
            records[key] = nil
            sentAt[key] = nil
        }
    }

    private func start(_ row: TaskListStore.TaskRow, _ state: TaskActivityState) {
        client.start(key: row.key, hostName: row.hostName, state: state, staleDate: now().addingTimeInterval(staleAfter))
        records[row.key] = LiveActivityRecord(hostName: row.hostName, state: state, ended: false)
        sentAt[row.key] = now()
    }
}
