import DSHCore
import SwiftUI

/// How the app names milestones (S3, ARCHITECTURE D19). The bridge sends a kind plus DSH's own
/// words; the wording here is the app's, and nothing is summarized (D11).
extension Milestone {
    /// Timeline row title.
    var title: LocalizedStringKey {
        switch kind {
        case .started: "Started"
        case .planned: todos.isEmpty ? "Cleared the plan" : "Planned \(todos.count) steps"
        case .todoStarted: "Started a step"
        case .todoDone: "Finished a step"
        case .planModeEntered: "Planning"
        case .planModeLeft: "Plan ready"
        case .retrying: "Model request failed, retrying"
        case .failed: "Failed"
        case .finished: "Done"
        }
    }

    var symbol: String {
        switch kind {
        case .started: "play.circle"
        case .planned: "list.bullet.clipboard"
        case .todoStarted: "circle.dotted"
        case .todoDone: "checkmark.circle.fill"
        case .planModeEntered: "map"
        case .planModeLeft: "map.fill"
        case .retrying: "arrow.clockwise.circle"
        case .failed: "exclamationmark.triangle.fill"
        case .finished: "checkmark.seal.fill"
        }
    }

    var tint: Color {
        switch kind {
        case .todoDone, .finished: .green
        case .failed: .orange
        case .retrying: .yellow
        default: .accentColor
        }
    }
}

extension Todo.Status {
    var symbol: String {
        switch self {
        case .pending: "circle"
        case .inProgress: "circle.dotted.circle"
        case .completed: "checkmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .pending: .secondary
        case .inProgress: .accentColor
        case .completed: .green
        }
    }
}

extension MilestoneTimeline {
    /// The card's one line: the step being worked on, else what the latest milestone says.
    var headline: String {
        if let active = activeTodo, current?.kind != .finished, current?.kind != .failed { return active.content }
        guard let current else { return "" }
        switch current.kind {
        case .failed, .retrying:
            return current.text.isEmpty ? String(localized: "Failed") : current.text
        case .finished: return String(localized: "Done")
        case .planModeEntered: return String(localized: "Planning")
        case .planModeLeft: return String(localized: "Plan ready")
        case .planned: return String(localized: "Planned \(todos.count) steps")
        case .todoDone: return current.text
        case .started, .todoStarted: return String(localized: "Started")
        }
    }

    /// `done/total` for UI tests and VoiceOver; "" while the agent keeps no list.
    var progressToken: String { todos.isEmpty ? "" : "\(completedCount)/\(todos.count)" }
}
