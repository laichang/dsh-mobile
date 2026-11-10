import DSHCore
import SwiftUI

/// The milestone bar of a session page (screen 04): one line with the
/// step being worked on and "done / total", and a thin progress line under it. It sits above the
/// scrolling transcript, so it stays at the top while the transcript scrolls. A tap opens all the
/// steps in a sheet (`SheetRoute.milestones`). Details on demand (STORY §4).
struct MilestoneBar: View {
    let timeline: MilestoneTimeline
    let state: TaskState?
    /// When the task failed, the line that replaces the headline ("失败 · 第 3 步"); the
    /// bar then has a red border (screen X1).
    var alert: String? = nil
    /// P1: an agent question waits for the user: "等你回答", with an amber border.
    var asking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                icon.frame(width: 20, height: 20)
                Text(Self.line(timeline, state: state, alert: alert, asking: asking))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(DSHTheme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !timeline.todos.isEmpty {
                    Text(verbatim: "\(timeline.completedCount) / \(timeline.todos.count)")
                        .font(DSHTheme.mono(.subheadline))
                        .foregroundStyle(DSHTheme.textSecondary)
                }
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(DSHTheme.textSecondary)
            }
            if !timeline.todos.isEmpty {
                MilestoneProgressLine(fraction: Double(timeline.completedCount) / Double(timeline.todos.count), tint: tint)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSHTheme.milestoneBarFill, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(alert != nil ? DSHTheme.failBarBorder
            : asking ? DSHTheme.amber.opacity(0.4) : DSHTheme.hairline))
        .contentShape(.rect)
    }

    /// The bar's one line. After a stop or a finish, a follow-up continues the task,
    /// and its turns add no milestones: the last milestone is history then, so the line says what
    /// the task does now.
    static func line(_ timeline: MilestoneTimeline, state: TaskState?, alert: String?, asking: Bool = false) -> String {
        if let alert { return alert }
        if asking { return String(localized: "Waiting for your answer") }
        guard outdated(timeline, state: state) else { return timeline.headline }
        return state == .completed ? String(localized: "Done") : String(localized: "Running")
    }

    private static func outdated(_ timeline: MilestoneTimeline, state: TaskState?) -> Bool {
        switch (timeline.current?.kind, state) {
        case (.interrupted?, .running?), (.interrupted?, .waitingOnUser?), (.interrupted?, .completed?),
             (.finished?, .running?), (.finished?, .waitingOnUser?): true
        default: false
        }
    }

    private var kind: Milestone.Kind? {
        guard Self.outdated(timeline, state: state) else { return timeline.current?.kind }
        return state == .completed ? .finished : nil
    }

    @ViewBuilder
    private var icon: some View {
        if alert != nil {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(DSHTheme.failText)
        } else if asking {
            Image(systemName: "bubble.left").foregroundStyle(DSHTheme.amber)
        } else {
            stateIcon
        }
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch kind {
        case .finished?: Image(systemName: "checkmark.circle.fill").foregroundStyle(DSHTheme.green)
        case .failed?: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(DSHTheme.red)
        case .interrupted?: Image(systemName: "stop.circle").foregroundStyle(DSHTheme.textSecondary)
        default:
            if state == .waitingOnUser {
                Image(systemName: "hand.raised.fill").foregroundStyle(DSHTheme.amber)
            } else if state?.isTerminal == true {
                Image(systemName: "circle").foregroundStyle(DSHTheme.textTertiary)
            } else {
                ProgressView().controlSize(.small).tint(DSHTheme.textSecondary)
            }
        }
    }

    /// Blue while it runs, green when done, red when it failed (the DSHTheme visual language).
    private var tint: Color {
        switch kind {
        case .finished?: DSHTheme.green
        case .failed?: DSHTheme.red
        case .interrupted?: DSHTheme.textTertiary
        default: state == .waitingOnUser || asking ? DSHTheme.amber : DSHTheme.blue
        }
    }
}

/// A 4 pt track with a rounded fill: the bar's progress line.
private struct MilestoneProgressLine: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(tint).frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}
