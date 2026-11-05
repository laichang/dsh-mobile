import DSHCore
import SwiftUI

/// S3 task card: the current milestone and the todo list, so progress shows without the
/// transcript (STORY principle 4). Tapping it opens the timeline.
struct MilestoneCard: View {
    let timeline: MilestoneTimeline
    /// Rows shown on the card; the timeline shows them all.
    var maxTodos = 5
    /// False in the task list, where the row's own disclosure indicator already says "opens".
    var showsChevron = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let current = timeline.current {
                    Image(systemName: current.symbol).foregroundStyle(current.tint)
                }
                Text(timeline.headline)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 4)
                if !timeline.todos.isEmpty {
                    Text("\(timeline.completedCount) of \(timeline.todos.count)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if showsChevron {
                    Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                }
            }
            if !timeline.todos.isEmpty {
                ProgressView(value: Double(timeline.completedCount), total: Double(timeline.todos.count))
                    .tint(.green)
                ForEach(Array(timeline.todos.prefix(maxTodos).enumerated()), id: \.offset) { _, todo in
                    TodoRow(todo: todo).font(.footnote)
                }
                if timeline.todos.count > maxTodos {
                    Text("+\(timeline.todos.count - maxTodos) more").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
        .contentShape(.rect)
    }
}

struct TodoRow: View {
    let todo: Todo

    var body: some View {
        Label {
            Text(todo.content)
                .strikethrough(todo.status == .completed)
                .foregroundStyle(todo.status == .completed ? .secondary : .primary)
        } icon: {
            Image(systemName: todo.status.symbol).foregroundStyle(todo.status.tint)
        }
    }
}
