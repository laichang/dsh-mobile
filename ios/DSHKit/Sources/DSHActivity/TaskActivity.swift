import Foundation
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif

/// What the Live Activity of one task shows (screen L, ARCHITECTURE D119). The app fills it from
/// the task list; the widget extension only draws it. It goes to the extension through ActivityKit
/// itself, not through an App Group: a free Apple team may not have App Groups.
public struct TaskActivityState: Codable, Hashable, Sendable {
    public enum Phase: String, Codable, Hashable, Sendable {
        /// The task runs: the time ticks.
        case running
        /// Ended: the task is done.
        case done
        /// Ended: the task failed.
        case failed
        /// Ended: the user stopped the task.
        case stopped
        /// Ended: the task waits for an approval.
        case approval
        /// Ended: the task waits for an answer to an agent question (`questions.v1`).
        case question

        public var isRunning: Bool { self == .running }
    }

    public var phase: Phase
    /// The task's title (the first message, or the session title from DSH).
    public var title: String
    /// The latest step, in the words the app's milestone bar uses; empty before the first milestone.
    public var step: String
    /// Done and total todos of the agent's list; 0 / 0 while the agent keeps no list.
    public var done: Int
    public var total: Int
    /// When the current turn started: the time counts from here.
    public var startedAt: Date
    /// When the task ended or began to wait; nil while it runs.
    public var endedAt: Date?

    public init(phase: Phase, title: String, step: String, done: Int = 0, total: Int = 0, startedAt: Date, endedAt: Date? = nil) {
        self.phase = phase
        self.title = title
        self.step = step
        self.done = done
        self.total = total
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

#if canImport(ActivityKit) && os(iOS)
/// The ActivityKit type of a task's Live Activity. The fixed part: which task, on which host.
public struct TaskActivityAttributes: ActivityAttributes {
    public typealias ContentState = TaskActivityState

    /// The task list's key of the task (host key and task ID): one activity for each task.
    public var taskKey: String
    public var hostName: String

    public init(taskKey: String, hostName: String) {
        self.taskKey = taskKey
        self.hostName = hostName
    }
}
#endif
