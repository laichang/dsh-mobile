import DSHProtocol
import Foundation

/// One item of the agent's todo list, as DSH holds it (protocol/milestones.proto).
public struct Todo: Sendable, Equatable, Hashable, Codable {
    public enum Status: String, Sendable, Equatable, Hashable, Codable {
        case pending, inProgress, completed
    }

    public var content: String
    public var status: Status

    public init(content: String, status: Status) {
        self.content = content
        self.status = status
    }
}

/// One step on a task's milestone timeline. `text` is DSH's own words,
/// or empty; the app labels each kind itself and never summarizes.
public struct Milestone: Sendable, Equatable, Identifiable, Codable {
    public enum Kind: String, Sendable, Equatable, Codable {
        case started, planned, todoStarted, todoDone, planModeEntered, planModeLeft, retrying, failed, finished, interrupted
    }

    public var taskID: String
    public var seq: UInt64
    public var kind: Kind
    public var text: String
    /// The agent's whole todo list right after this milestone.
    public var todos: [Todo]
    public var time: Date

    public var id: UInt64 { seq }

    public init(taskID: String, seq: UInt64, kind: Kind, text: String = "", todos: [Todo] = [], time: Date) {
        self.taskID = taskID
        self.seq = seq
        self.kind = kind
        self.text = text
        self.todos = todos
        self.time = time
    }
}

/// A task's milestones in order, and what the task card shows from them. Codable: the durable list's cache
/// keeps each task's timeline (`CachedTask.milestonesData`).
public struct MilestoneTimeline: Sendable, Equatable, Codable {
    public private(set) var milestones: [Milestone] = []

    public init(_ milestones: [Milestone] = []) {
        for m in milestones { add(m) }
    }

    /// Appends `milestone` if it is newer than the last one; returns whether it did.
    @discardableResult
    public mutating func add(_ milestone: Milestone) -> Bool {
        if let last = milestones.last, milestone.seq <= last.seq { return false }
        milestones.append(milestone)
        return true
    }

    public var isEmpty: Bool { milestones.isEmpty }
    /// The latest milestone: what the card leads with.
    public var current: Milestone? { milestones.last }
    /// The agent's todo list as of the latest milestone.
    public var todos: [Todo] { milestones.last?.todos ?? [] }
    public var completedCount: Int { todos.count { $0.status == .completed } }
    /// The todo being worked on now (the first one, if the agent runs several).
    public var activeTodo: Todo? { todos.first { $0.status == .inProgress } }
}

extension Milestone {
    /// Maps the wire message; nil for kinds this build doesn't know (a newer bridge).
    public init?(_ m: Dshm_V1_MilestoneAdded) {
        let kind: Kind
        switch m.kind {
        case .started: kind = .started
        case .planned: kind = .planned
        case .todoStarted: kind = .todoStarted
        case .todoDone: kind = .todoDone
        case .planModeEntered: kind = .planModeEntered
        case .planModeLeft: kind = .planModeLeft
        case .retrying: kind = .retrying
        case .failed: kind = .failed
        case .finished: kind = .finished
        case .interrupted: kind = .interrupted
        case .unspecified, .UNRECOGNIZED: return nil
        }
        let todos = m.todos.map { t -> Todo in
            let status: Todo.Status = switch t.status {
            case .completed: .completed
            case .inProgress: .inProgress
            default: .pending
            }
            return Todo(content: t.content, status: status)
        }
        self.init(taskID: m.taskID, seq: m.seq, kind: kind, text: m.text, todos: todos,
                  time: Date(timeIntervalSince1970: TimeInterval(m.timeMs) / 1000))
    }
}
