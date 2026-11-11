import DSHCore
import DSHFeatures
import SwiftUI

/// Screen 03 · a task that waits on an agent question, under 等我处理 in 所有任务 (STORY §4–§5,
/// screen P1): the task and its host on one line (a tap opens the session), then the question's
/// card, which answers here as on the session page. Counts like an approval card.
struct AllTasksQuestionCard: View {
    let row: TaskListStore.TaskRow
    let question: AgentQuestion
    let store: TaskListStore
    @Environment(ShellModel.self) private var shell

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { shell.open(.session(row.key)) } label: {
                HStack(spacing: 8) {
                    Text(verbatim: row.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DSHTheme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(verbatim: row.hostName)
                        .font(.caption)
                        .foregroundStyle(DSHTheme.textTertiary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DSHTheme.textTertiary)
                }
                .padding(.horizontal, 4)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tasklist.question.open")
            QuestionCard(store: store, row: row, question: question)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tasklist.question")
    }
}
