import DSHCore
import SwiftUI

/// T1 · the navigation state of the shell (DESIGN.md "Navigation"): which page shows, which
/// bottom sheet is up, and whether the workspace drawer is open. There is no navigation stack:
/// the left edge belongs to the drawer, and details open as sheets.
///
/// Registration points for the UI slices (PLAN.md "How the UI slices stay independent"): a slice
/// adds one case to `ShellPage` or `SheetRoute`, and one line where each is switched over
/// (`ShellView.page(_:)`, `SheetRoute.content(store:)`, `DrawerView`).
@MainActor
@Observable
final class ShellModel {
    /// The app opens on a blank new session (STORY §3), never on the last place.
    var page: ShellPage = .newSession
    var sheet: SheetRoute?
    var drawerOpen = false

    /// Shows a page. From the drawer this closes the drawer with no animation (T1; S23 adds motion).
    func open(_ page: ShellPage) {
        self.page = page
        drawerOpen = false
    }

    func present(_ route: SheetRoute) { sheet = route }
}

/// The pages of the shell. Each is a full page beside the drawer, not a pushed view.
enum ShellPage: Hashable {
    /// The blank new session (01). The first message turns it into `.session` (ARCHITECTURE D51).
    case newSession
    /// One session (04), by `TaskListStore.TaskRow.key`.
    case session(String)
    /// 所有任务 (03): the M1 task list, across hosts.
    case allTasks
}

/// Every bottom sheet of the shell (DESIGN.md: details open as bottom sheets).
enum SheetRoute: Identifiable, Hashable {
    /// A task's whole milestone timeline (S3).
    case milestones(taskKey: String)
    /// The workspace picker for the composer's host (S7).
    case workspace(hostKey: String)
    /// The model and effort picker: for the composer (`taskKey` nil) or for a running task (S6).
    case model(hostKey: String, taskKey: String?)
    /// Paired devices and the audit history of one host (S10).
    case devices(hostKey: String)
    /// Settings, from the bottom of the drawer (S14).
    case settings

    var id: Self { self }

    @ViewBuilder
    func content(store: TaskListStore) -> some View {
        switch self {
        case .milestones(let key):
            MilestoneTimelineSheet(store: store, taskKey: key)
        case .workspace(let hostKey):
            WorkspacePicker(store: store, hostKey: hostKey)
        case .model(let hostKey, let taskKey):
            ModelPicker(store: store, hostKey: hostKey, task: taskKey.flatMap { store.task($0) })
        case .devices(let hostKey):
            DevicesSheet(store: store, hostKey: hostKey)
        case .settings:
            DrawerSettingsSheet(store: store)
        }
    }
}

/// A sheet's own close button. Pages have no back button; sheets close with this or a swipe down.
struct SheetDoneButton: ToolbarContent {
    @Environment(\.dismiss) private var dismiss

    var body: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }.accessibilityIdentifier("sheet.done")
        }
    }
}

private struct MilestoneTimelineSheet: View {
    let store: TaskListStore
    let taskKey: String

    var body: some View {
        NavigationStack {
            MilestoneTimelineView(timeline: store.task(taskKey)?.milestones ?? MilestoneTimeline())
                .toolbar { SheetDoneButton() }
        }
    }
}

private struct DevicesSheet: View {
    let store: TaskListStore
    let hostKey: String

    var body: some View {
        NavigationStack {
            if let connection = store.deviceManagement(for: hostKey) {
                DeviceManagementView(host: store.hosts.first { $0.key == hostKey }?.name ?? "", connection: connection)
                    .toolbar { SheetDoneButton() }
            } else {
                Text("This host has no device management.").foregroundStyle(.secondary)
            }
        }
    }
}
