import Foundation

/// S19 · what the session page says about a task that has ended (screens 06 and X1, ARCHITECTURE
/// D60). Built only from data the host sent: the state, the failure message, the milestone
/// timeline and the answered approvals. Nothing is summarized (D11).
public struct TaskOutcome: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case done, failed, interrupted
    }

    public var kind: Kind
    /// The milestones on the task's timeline: the rows that "已工作 · N 步 ›" opens.
    public var steps: Int
    /// The approvals of the task that were answered, on any client.
    public var approvals: Int
    /// The todo (1-based) the task was on when it failed or stopped; nil without a todo list,
    /// or when every todo was done.
    public var stoppedAtStep: Int?
    /// The failure message, as the host gave it; empty when there is none.
    public var error: String

    public init?(_ row: TaskListStore.TaskRow) {
        switch row.state {
        case .completed: kind = .done
        case .failed: kind = .failed
        case .interrupted: kind = .interrupted
        case .running, .waitingOnUser: return nil
        }
        let timeline = row.milestones
        steps = timeline.milestones.count
        approvals = row.approvalsAnswered
        let todos = timeline.todos
        if kind != .done, let at = todos.firstIndex(where: { $0.status == .inProgress })
            ?? todos.firstIndex(where: { $0.status != .completed }) {
            stoppedAtStep = at + 1
        } else {
            stoppedAtStep = nil
        }
        var error = kind == .failed ? row.message : ""
        if kind == .failed, error.isEmpty, let current = timeline.current, current.kind == .failed {
            error = current.text
        }
        self.error = error
    }
}
