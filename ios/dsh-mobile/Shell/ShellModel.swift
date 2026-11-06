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
    /// S23: true from a tap in the drawer until the page fills the screen (F1–F4). A pending
    /// approval's sheet waits for it.
    private(set) var moving = false
    /// S23: one more for each tap that opens a page from the drawer; the light haptic follows it.
    private(set) var taps = 0
    /// S23: true while the page cross-fades (F2); `ShellView` animates the page change then.
    private(set) var fading = false
    /// S23: the last scroll position, per session, that the user scrolled to (D65). Not observed:
    /// it changes on each scroll frame, and only a new page reads it.
    @ObservationIgnored var lastPositions: [String: CGFloat] = [:]
    @ObservationIgnored private var motion: Task<Void, Never>?

    /// Shows a page. With the drawer open, it moves like DESIGN.md F1–F4 (S23, `DrawerMotion`):
    /// the peeking edge cross-fades to the page (0–120 ms), then the page slides in with a spring
    /// and pushes the drawer away (120–350 ms). Without the drawer (the composer's first message,
    /// a card in 03), the page cross-fades in place.
    func open(_ page: ShellPage) {
        motion?.cancel()
        taps += 1
        let fromDrawer = drawerOpen
        moving = true
        fading = true
        // Assign the page directly (T1: a page set inside `withTransaction` could get lost);
        // `ShellView` animates it while `fading` is true.
        self.page = page
        motion = Task { [weak self] in
            try? await Task.sleep(for: DrawerMotion.fade)
            guard let self, !Task.isCancelled else { return }
            self.fading = false
            if fromDrawer {
                withAnimation(DrawerMotion.slide) { self.drawerOpen = false }
                try? await Task.sleep(for: DrawerMotion.slideTime)
                guard !Task.isCancelled else { return }
            }
            self.moving = false
        }
    }

    /// Shows a page at once, with no motion: the first message turns the new session into the
    /// session page on the same page (ARCHITECTURE D51).
    func show(_ page: ShellPage) {
        motion?.cancel()
        moving = false
        fading = false
        self.page = page
        drawerOpen = false
    }

    /// Opens or closes the drawer with the same spring as the slide (S23).
    func setDrawer(open: Bool) {
        withAnimation(DrawerMotion.slide) { drawerOpen = open }
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
    /// The pending approval of a session (S18, screen 05).
    case approval(taskKey: String)
    /// Settings, from the bottom of the drawer (S14).
    case settings
    /// The hosts sheet (H), from the "2 / 3" pill in the drawer (S21).
    case hosts
    /// One thinking or tool-call row of a session (S17).
    case transcriptBlock(taskKey: String, blockID: String)

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
        case .approval(let key):
            ApprovalSheet(store: store, taskKey: key)
        case .settings:
            DrawerSettingsSheet(store: store)
        case .hosts:
            HostsSheet(store: store)
        case .transcriptBlock(let key, let blockID):
            TranscriptBlockSheet(store: store, taskKey: key, blockID: blockID)
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
