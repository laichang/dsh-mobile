import DSHCore
import SwiftUI
import UIKit

/// The navigation state of the shell (design/screens.json nav and rules): which page shows, which
/// bottom sheet is up, and whether the workspace drawer is open. There is no navigation stack:
/// the left edge belongs to the drawer, and details open as sheets.
///
/// Registration points for features: a feature
/// adds one case to `ShellPage` or `SheetRoute`, and one line where each is switched over
/// (`ShellView.page(_:)`, `SheetRoute.content(store:)`, `DrawerView`).
@MainActor
@Observable
final class ShellModel {
    /// The app opens on a blank new session (STORY §3), never on the last place.
    /// Each change of page, sheet or drawer puts the keyboard away first. Typing and
    /// the send key do not come here; every other action that moves the shell does.
    var page: ShellPage = .newSession { didSet { if page != oldValue { Keyboard.dismiss() } } }
    var sheet: SheetRoute? { didSet { if sheet != nil { Keyboard.dismiss() } } }
    var drawerOpen = false { didSet { if drawerOpen { Keyboard.dismiss() } } }
    /// True from a tap in the drawer until the page fills the screen (F1–F4). A pending
    /// approval's sheet waits for it.
    private(set) var moving = false
    /// One more for each tap that opens a page from the drawer; the light haptic follows it.
    private(set) var taps = 0
    /// True while the page cross-fades (F2); `ShellView` animates the page change then.
    private(set) var fading = false
    /// The last scroll position, per session, that the user scrolled to. Not observed:
    /// it changes on each scroll frame, and only a new page reads it.
    @ObservationIgnored var lastPositions: [String: CGFloat] = [:]
    @ObservationIgnored private var motion: Task<Void, Never>?

    /// Shows a page. With the drawer open, it moves like design screens F1–F4 (`DrawerMotion`):
    /// the peeking edge cross-fades to the page (0–120 ms), then the page slides in with a spring
    /// and pushes the drawer away (120–350 ms). Without the drawer (the composer's first message,
    /// a card in 03), the page cross-fades in place.
    func open(_ page: ShellPage) {
        motion?.cancel()
        taps += 1
        let fromDrawer = drawerOpen
        moving = true
        fading = true
        // Assign the page directly (a page set inside `withTransaction` could get lost);
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
    /// session page on the same page.
    func show(_ page: ShellPage) {
        motion?.cancel()
        moving = false
        fading = false
        self.page = page
        drawerOpen = false
    }

    /// Opens or closes the drawer with the same spring as the slide.
    func setDrawer(open: Bool) {
        withAnimation(DrawerMotion.slide) { drawerOpen = open }
    }

    func present(_ route: SheetRoute) { sheet = route }
}

/// Puts the keyboard away, wherever the focus is (the composer's prompt, a sheet's
/// field). The shell calls it on each move; `NewSessionBody` on a tap or a swipe down; a menu on
/// the composer just before it shows (`dismissesKeyboardBeforeMenu`).
@MainActor
enum Keyboard {
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

/// The pages of the shell. Each is a full page beside the drawer, not a pushed view.
enum ShellPage: Hashable {
    /// The blank new session (01). The first message turns it into `.session`.
    case newSession
    /// One session (04), by `TaskListStore.TaskRow.key`.
    case session(String)
    /// 所有任务 (03): the M1 task list, across hosts.
    case allTasks
}

/// Every bottom sheet of the shell (design/screens.json: details open as bottom sheets).
enum SheetRoute: Identifiable, Hashable {
    /// A task's whole milestone timeline.
    case milestones(taskKey: String)
    /// The workspace picker for the composer's host.
    case workspace(hostKey: String)
    /// The model and effort picker: for the composer (`taskKey` nil) or for a running task.
    case model(hostKey: String, taskKey: String?)
    /// Paired devices and the audit history of one host.
    case devices(hostKey: String)
    /// The pending approval of a session (screen 05).
    case approval(taskKey: String)
    /// Settings, from the bottom of the drawer.
    case settings
    /// The hosts sheet (H), from the "2 / 3" pill in the drawer.
    case hosts
    /// One thinking or tool-call row of a session.
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
