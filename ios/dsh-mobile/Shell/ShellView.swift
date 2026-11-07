import DSHCore
import SwiftUI

/// T1 · the navigation shell (DESIGN.md "Navigation"): one page at a time, and the workspace
/// drawer on its left. The drawer pushes the page (it doesn't cover it). A drag from the left
/// edge moves the drawer and the page with the finger; on release, the position and the velocity
/// decide if it opens or goes back. There is no `NavigationStack` and no back button: details
/// open as bottom sheets (`SheetRoute`), so the left edge belongs to the drawer.
struct ShellView: View {
    let store: TaskListStore
    @Binding var showFirstTask: Bool
    let pair: () -> Void
    @State private var shell = ShellModel()
    /// The drawer's offset while a finger moves it; nil when no drag is going on.
    @State private var dragOffset: CGFloat?

    /// A drag that starts this close to the left edge opens the drawer.
    static let edgeWidth: CGFloat = 24

    var body: some View {
        GeometryReader { geometry in
            let width = Self.drawerWidth(for: geometry.size.width)
            let offset = dragOffset ?? (shell.drawerOpen ? width : 0)
            ZStack(alignment: .topLeading) {
                if offset > 0 {
                    DrawerView(store: store, pair: pair)
                        .frame(width: width)
                        .offset(x: offset - width)
                }
                // S23 F2: the peeking edge cross-fades to the new page (`ShellModel.fading`).
                ZStack {
                    page(shell.page)
                        .id(shell.page)
                        .transition(.opacity)
                }
                .animation(shell.fading ? DrawerMotion.fadeAnimation : nil, value: shell.page)
                .frame(width: geometry.size.width)
                .accessibilityHidden(shell.drawerOpen)
                .overlay {
                    if offset > 0 {
                        // The peeking page closes the drawer on a tap.
                        Button { close() } label: { Color.black.opacity(0.001) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Close the drawer")
                            .accessibilityIdentifier("drawer.dismiss")
                    }
                }
                .offset(x: offset)
            }
            .simultaneousGesture(drag(width: width))
        }
        .background(DSHTheme.canvas.ignoresSafeArea())
        .modifier(DrawerReadTracker(store: store, shell: shell))
        .sensoryFeedback(.impact(weight: .light), trigger: shell.taps) // S23 F1
        .environment(shell)
        .environment(store)
        .sheet(item: $shell.sheet) { route in
            route.content(store: store)
                .environment(shell)
        }
    }

    static func drawerWidth(for pageWidth: CGFloat) -> CGFloat { min(pageWidth * 0.82, 340) }

    @ViewBuilder
    private func page(_ page: ShellPage) -> some View {
        switch page {
        case .newSession:
            SessionPage(store: store, taskKey: nil, showFirstTask: $showFirstTask)
        case .session(let key):
            SessionPage(store: store, taskKey: key, showFirstTask: $showFirstTask,
                        lastPosition: shell.lastPositions[key]) // S23: read once, when the page is made
                .id(key)
        case .allTasks:
            AllTasksPage(store: store)
        }
    }

    private func close() {
        shell.setDrawer(open: false)
    }

    /// Opens from the left edge when closed; anywhere when open (a drag to the left closes it).
    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                let base: CGFloat = shell.drawerOpen ? width : 0
                if dragOffset == nil {
                    let horizontal = abs(value.translation.width) > abs(value.translation.height)
                    guard horizontal, shell.drawerOpen || value.startLocation.x <= Self.edgeWidth else { return }
                    // S24 (D67): the keyboard goes when the drag starts, not when the drawer settles.
                    Keyboard.dismiss()
                }
                dragOffset = min(max(base + value.translation.width, 0), width)
            }
            .onEnded { value in
                guard let current = dragOffset else { return }
                let open = Self.settlesOpen(offset: current, velocity: value.velocity.width, width: width)
                // S23 F3: the same spring as the slide after a tap in the drawer.
                withAnimation(DrawerMotion.slide) {
                    shell.drawerOpen = open
                    dragOffset = nil
                }
            }
    }

    /// Where a released drawer settles: project the release velocity a short way forward, and
    /// open if that lands past the middle. A slow release near the edge goes back; a flick opens.
    static func settlesOpen(offset: CGFloat, velocity: CGFloat, width: CGFloat) -> Bool {
        let projected = offset + velocity * 0.15
        return projected > width / 2
    }
}

/// The page's top bar: the drawer button on the left, a title, and an optional subtitle.
/// Session pages have no back button (DESIGN.md "Navigation").
struct PageBar<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing
    @Environment(ShellModel.self) private var shell

    var body: some View {
        HStack(spacing: 12) {
            Button {
                shell.setDrawer(open: true)
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(DSHTheme.textPrimary)
                    .frame(width: 40, height: 40)
                    .background(DSHTheme.bubble, in: .circle)
            }
            .accessibilityLabel("Open the drawer")
            .accessibilityIdentifier("drawer.open")
            .overlay(alignment: .topTrailing) { DrawerButtonBadge() }
            VStack(spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(DSHTheme.textPrimary)
                    .lineLimit(1)
                    .accessibilityIdentifier("page.title")
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(DSHTheme.textSecondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("page.subtitle")
                }
            }
            .frame(maxWidth: .infinity)
            trailing.frame(minWidth: 40)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

extension PageBar where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}
