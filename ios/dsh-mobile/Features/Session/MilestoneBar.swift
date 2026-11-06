import DSHCore
import SwiftUI

/// S16 · the milestone bar of a session page (screen 04, ARCHITECTURE D23 (b)): one line with the
/// step being worked on and "done / total", and a thin progress line under it. It sits above the
/// scrolling transcript, so it stays at the top while the transcript scrolls. A tap opens all the
/// steps in a sheet (`SheetRoute.milestones`). Details on demand (STORY §4).
struct MilestoneBar: View {
    let timeline: MilestoneTimeline
    let state: TaskState?
    /// S19: when the task failed, the line that replaces the headline ("失败 · 第 3 步"); the
    /// bar then has a red border (screen X1).
    var alert: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                icon.frame(width: 20, height: 20)
                Text(alert ?? timeline.headline)
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
        .background(DSHTheme.s16BarFill, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(alert == nil ? DSHTheme.hairline : DSHTheme.s19FailBarBorder))
        .contentShape(.rect)
    }

    private var kind: Milestone.Kind? { timeline.current?.kind }

    @ViewBuilder
    private var icon: some View {
        if alert != nil {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(DSHTheme.s19FailText)
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

    /// Blue while it runs, green when done, red when it failed (DESIGN.md "Visual language").
    private var tint: Color {
        switch kind {
        case .finished?: DSHTheme.green
        case .failed?: DSHTheme.red
        case .interrupted?: DSHTheme.textTertiary
        default: state == .waitingOnUser ? DSHTheme.amber : DSHTheme.blue
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
