import ActivityKit
import DSHActivity
import SwiftUI
import WidgetKit

/// The widget extension of dsh-mobile: only the Live Activity of a running task (screen L,
/// ARCHITECTURE D119). The app starts, updates and ends it; this draws `TaskActivityState`.
@main
struct LiveActivityBundle: WidgetBundle {
    var body: some Widget {
        TaskActivityWidget()
    }
}

struct TaskActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TaskActivityAttributes.self) { context in
            TaskActivityLockScreenView(hostName: context.attributes.hostName, state: context.state, isStale: context.isStale)
                .activityBackgroundTint(Palette.canvas.opacity(0.82))
                .activitySystemActionForegroundColor(Palette.text)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PhaseIcon(phase: context.state.phase).font(.title3).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Elapsed(state: context.state).font(.system(.body, design: .monospaced).weight(.semibold))
                        .frame(maxWidth: 72, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(Lines.detail(hostName: context.attributes.hostName, state: context.state))
                        .font(.caption).foregroundStyle(Palette.secondary).lineLimit(1)
                }
            } compactLeading: {
                PhaseIcon(phase: context.state.phase)
            } compactTrailing: {
                Elapsed(state: context.state).font(.system(.caption, design: .monospaced).weight(.semibold))
                    .frame(maxWidth: 44)
            } minimal: {
                PhaseIcon(phase: context.state.phase)
            }
            .keylineTint(Palette.tint(context.state.phase))
        }
    }
}

/// The lock screen view (screen L): DSH mark, title, host and latest step, the time, and the
/// progress of the todo list.
struct TaskActivityLockScreenView: View {
    let hostName: String
    let state: TaskActivityState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .center, spacing: 10) {
                Text(verbatim: "DSH")
                    .font(.system(size: 9.5, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Palette.blue, in: .rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title).font(.system(size: 14.5, weight: .semibold)).lineLimit(1)
                    Text(Lines.detail(hostName: hostName, state: state))
                        .font(.system(size: 12.5)).foregroundStyle(Palette.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 2) {
                    Elapsed(state: state).font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 90, alignment: .trailing)
                    status
                }
            }
            if state.total > 0 {
                ProgressBar(fraction: Double(state.done) / Double(state.total), tint: Palette.tint(state.phase))
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 14)
        .foregroundStyle(Palette.text)
    }

    /// Under the time: `n/m` while it runs, else how it ended.
    @ViewBuilder
    private var status: some View {
        if state.phase.isRunning {
            if isStale {
                Text("Not updated", comment: "A Live Activity that the app could not update for a while").font(.system(size: 11.5)).foregroundStyle(Palette.amber)
            } else if state.total > 0 {
                Text(verbatim: "\(state.done)/\(state.total)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.secondary)
            }
        } else {
            HStack(spacing: 3) {
                PhaseIcon(phase: state.phase)
                Text(Lines.phase(state.phase))
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.tint(state.phase))
        }
    }
}

/// The time since the turn started: it ticks while the task runs (also while the app is
/// suspended), and stops at the end.
struct Elapsed: View {
    let state: TaskActivityState

    var body: some View {
        if let end = state.endedAt {
            Text(timerInterval: state.startedAt...max(end, state.startedAt), pauseTime: max(end, state.startedAt), countsDown: false)
        } else {
            Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
        }
    }
}

struct PhaseIcon: View {
    let phase: TaskActivityState.Phase

    var body: some View {
        Image(systemName: symbol).foregroundStyle(Palette.tint(phase))
    }

    private var symbol: String {
        switch phase {
        case .running: "circle.dotted.circle"
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .stopped: "stop.circle"
        case .approval: "hand.raised.fill"
        case .question: "questionmark.bubble.fill"
        }
    }
}

struct ProgressBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(tint).frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 5)
    }
}

enum Lines {
    /// "host · latest step", or "host · how it ended" before the first step.
    static func detail(hostName: String, state: TaskActivityState) -> String {
        let step = state.step.isEmpty ? phase(state.phase) : state.step
        return hostName.isEmpty ? step : "\(hostName) · \(step)"
    }

    static func phase(_ phase: TaskActivityState.Phase) -> String {
        switch phase {
        case .running: String(localized: "Running")
        case .done: String(localized: "Done")
        case .failed: String(localized: "Failed")
        case .stopped: String(localized: "Stopped")
        case .approval: String(localized: "Needs your approval")
        case .question: String(localized: "Needs your answer")
        }
    }
}

/// DESIGN.md "Visual language".
enum Palette {
    static let canvas = Color(red: 0x15 / 255, green: 0x15 / 255, blue: 0x17 / 255)
    static let text = Color(red: 0xF9 / 255, green: 0xFA / 255, blue: 0xFB / 255)
    static let secondary = Color(red: 0xAD / 255, green: 0xB2 / 255, blue: 0xB8 / 255)
    static let blue = Color(red: 0x4D / 255, green: 0x6B / 255, blue: 0xFE / 255)
    static let amber = Color(red: 0xF5 / 255, green: 0xA5 / 255, blue: 0x24 / 255)
    static let red = Color(red: 0xF8 / 255, green: 0x51 / 255, blue: 0x49 / 255)
    static let green = Color(red: 0x3F / 255, green: 0xB9 / 255, blue: 0x50 / 255)
    static let tertiary = Color(red: 0x71 / 255, green: 0x76 / 255, blue: 0x7E / 255)

    /// Blue while it runs, green when done, red when it failed, amber when it needs the user.
    static func tint(_ phase: TaskActivityState.Phase) -> Color {
        switch phase {
        case .running: blue
        case .done: green
        case .failed: red
        case .stopped: tertiary
        case .approval, .question: amber
        }
    }
}
