import DSHCore
import DSHFeatures
import SwiftUI

/// Drawer motion (design/screens.json nav and rules, screens F1–F4). A tap on a session in the drawer
/// (or on 所有任务, or on an approval card in 03) moves in three steps:
/// - F1, 0 ms: the row is highlighted (`DrawerPressStyle`) with a light haptic (`ShellModel.taps`);
/// - F2, 0–120 ms: the peeking edge cross-fades to the target page, from the cache; the drawer
///   does not move;
/// - F3, 120–350 ms: the page slides in with a spring and pushes the drawer away, the same spring
///   as a released drag (`DrawerMotion.slide`);
/// - F4, 350 ms: the page fills the screen and lands (`SessionLanding`). A pending approval's sheet
///   (05) comes up only now (`ShellModel.moving`).
enum DrawerMotion {
    /// F2: the cross-fade of the peeking edge.
    static let fade = Duration.milliseconds(120)
    /// F3: the slide, from 120 ms to 350 ms.
    static let slideTime = Duration.milliseconds(230)
    /// The spring of the slide. A released drag and the drawer button use it too.
    static let slide = Animation.spring(duration: 0.23, bounce: 0.12)
    static let fadeAnimation = Animation.easeOut(duration: 0.12)
}

/// F1: the row under the finger is highlighted while it is pressed.
struct DrawerPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? DSHTheme.drawerCurrentRow : .clear, in: .rect(cornerRadius: 10))
    }
}

extension ButtonStyle where Self == DrawerPressStyle {
    static var drawerPress: DrawerPressStyle { DrawerPressStyle() }
}

/// F4 · where a session page lands when it opens:
/// - done (or failed, or stopped) and not read: at the start of the final answer (the outcome scroll, no marker);
/// - running or waiting: at the bottom, and it follows the stream;
/// - already read: at the last position the user scrolled to on this phone; with none, at the end.
enum SessionLanding: Equatable {
    case answerStart
    case followBottom
    case lastPosition(CGFloat)
    case end

    static func landing(_ row: TaskListStore.TaskRow?, lastPosition: CGFloat?) -> Self {
        if OutcomeAnchor.opensAtAnswer(row) { return .answerStart }
        guard let row, row.state.isTerminal else { return .followBottom }
        if let lastPosition { return .lastPosition(lastPosition) }
        return .end
    }

    /// The initial scroll anchor: the top when the page restores a position or goes to the answer.
    var anchor: UnitPoint {
        switch self {
        case .answerStart, .lastPosition: .top
        case .followBottom, .end: .bottom
        }
    }

    /// A stable token for UI tests (`session.transcript` accessibility value).
    var token: String {
        switch self {
        case .answerStart: "answerStart"
        case .followBottom: "followBottom"
        case .lastPosition: "lastPosition"
        case .end: "end"
        }
    }
}
