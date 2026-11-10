import ActivityKit
import DSHActivity
import DSHCore
import Foundation
import Observation

/// The Live Activities of the tasks, through ActivityKit (screen L, ARCHITECTURE D119–D121). Local
/// activities only: no push token is asked for, so a free Apple team can run them. The widget
/// extension (`ios/LiveActivity`) draws them from `TaskActivityState`.
@MainActor
@Observable
final class ActivityKitClient: LiveActivityClient {
    @ObservationIgnored private var activities: [String: Activity<TaskActivityAttributes>] = [:]
    @ObservationIgnored private var queue: Task<Void, Never>?
    /// Debug: what the system has, for UI tests (`liveactivity.probe`, `-DSHMLiveActivityProbe YES`).
    private(set) var summary = ""

    init() {
        // A relaunch: take over the activities that the system still has. Two for one task
        // (should not occur) leave one.
        for activity in Activity<TaskActivityAttributes>.activities {
            let key = activity.attributes.taskKey
            if activities[key] == nil {
                activities[key] = activity
            } else {
                run(activity.id, .dismiss)
            }
        }
        refreshSummary()
    }

    func current() -> [String: LiveActivityRecord] {
        activities.mapValues { activity in
            LiveActivityRecord(hostName: activity.attributes.hostName, state: activity.content.state,
                               ended: activity.activityState == .ended || activity.activityState == .dismissed)
        }
    }

    func start(key: String, hostName: String, state: TaskActivityState, staleDate: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activities[key] = try Activity.request(
                attributes: TaskActivityAttributes(taskKey: key, hostName: hostName),
                content: ActivityContent(state: state, staleDate: staleDate), pushType: nil)
        } catch {
            // The user turned Live Activities off, or the system limit is reached: the app works without.
        }
        summary = Self.describe(activities, override: [key: (state, false)])
    }

    func update(key: String, state: TaskActivityState, staleDate: Date) {
        guard let activity = activities[key] else { return }
        run(activity.id, .update(state, staleDate))
        summary = Self.describe(activities, override: [key: (state, false)])
    }

    func end(key: String, state: TaskActivityState) {
        guard let activity = activities[key] else { return }
        run(activity.id, .end(state))
        summary = Self.describe(activities, override: [key: (state, true)])
    }

    func dismiss(key: String) {
        guard let activity = activities.removeValue(forKey: key) else { return }
        run(activity.id, .dismiss)
        refreshSummary()
    }

    /// Debug test launches that do not ask for Live Activities end the ones left.
    func dismissAll() {
        for key in Array(activities.keys) { dismiss(key: key) }
    }

    private enum Operation: Sendable {
        case update(TaskActivityState, Date)
        case end(TaskActivityState)
        case dismiss
    }

    /// Runs `operation` on the activity with this ID after the calls before it, in order. The
    /// activity is found again off the main actor: `Activity` is not Sendable; its ID is.
    private func run(_ id: String, _ operation: Operation) {
        let previous = queue
        queue = Task.detached { await Self.perform(operation, on: id, after: previous) }
    }

    nonisolated private static func perform(_ operation: Operation, on id: String, after previous: Task<Void, Never>?) async {
        await previous?.value
        guard let activity = Activity<TaskActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
        switch operation {
        case .update(let state, let staleDate): await activity.update(ActivityContent(state: state, staleDate: staleDate))
        case .end(let state): await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .default)
        case .dismiss: await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func refreshSummary() { summary = Self.describe(activities, override: [:]) }

    /// One line for each activity, by task key: `phase|step|done/total`, and `ended` once it ended.
    /// `override`: what was just sent, since ActivityKit applies an update asynchronously.
    private static func describe(_ activities: [String: Activity<TaskActivityAttributes>],
                                 override: [String: (TaskActivityState, Bool)]) -> String {
        activities.keys.sorted().map { key in
            let activity = activities[key]!
            let (state, ended) = override[key] ?? (activity.content.state, activity.activityState == .ended)
            return "\(state.phase.rawValue)|\(state.step)|\(state.done)/\(state.total)\(ended ? "|ended" : "")"
        }.joined(separator: "\n")
    }
}
