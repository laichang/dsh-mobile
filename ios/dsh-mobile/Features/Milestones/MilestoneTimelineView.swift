import DSHCore
import SwiftUI

/// S3 detail: the task's whole milestone timeline, newest last, with the todo list on top.
struct MilestoneTimelineView: View {
    let store: TaskStore
    private var timeline: MilestoneTimeline { store.milestones }

    var body: some View {
        List {
            if !timeline.todos.isEmpty {
                Section("Steps · \(timeline.completedCount) of \(timeline.todos.count) done") {
                    ForEach(Array(timeline.todos.enumerated()), id: \.offset) { i, todo in
                        TodoRow(todo: todo)
                            .accessibilityElement(children: .combine)
                            .accessibilityValue(todo.status.rawValue)
                            .accessibilityIdentifier("milestone.todo.\(i)")
                    }
                }
            }
            Section("Timeline") {
                ForEach(timeline.milestones) { m in
                    MilestoneRow(milestone: m)
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(m.kind.rawValue)
                        .accessibilityIdentifier("milestone.row.\(m.seq)")
                }
            }
        }
        .accessibilityIdentifier("milestone.timeline")
        .navigationTitle("Milestones")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MilestoneRow: View {
    let milestone: Milestone

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: milestone.symbol).foregroundStyle(milestone.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(milestone.title).font(.subheadline.weight(.medium))
                if !milestone.text.isEmpty {
                    Text(milestone.text).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Text(milestone.time, format: .dateTime.hour().minute().second())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }
}
