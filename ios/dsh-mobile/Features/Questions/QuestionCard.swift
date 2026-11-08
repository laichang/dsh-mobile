import DSHCore
import SwiftUI

/// Screen P1 · a question from the agent, as a card in the transcript (STORY §4–§5). One chip per
/// option; a tap answers. The task waits and never chooses by itself. Once answered (here or on
/// DSH Web) the card shows the answer in place of the chips.
struct QuestionCard: View {
    let store: TaskListStore?
    let row: TaskListStore.TaskRow
    let question: AgentQuestion
    /// Choices made on this card, by question id, until every question has one.
    @State private var chosen: [String: String] = [:]
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label { Text("Agent is asking you", tableName: "Questions") } icon: { Image(systemName: "bubble.left") }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(DSHTheme.amber)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(DSHTheme.amber.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                // The card's handle for tests and VoiceOver: a SwiftUI stack is not an element of its own.
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("question.card")
                .accessibilityValue(question.outcome?.rawValue ?? "pending")
            ForEach(question.items) { item in
                VStack(alignment: .leading, spacing: 9) {
                    Text(verbatim: item.text)
                        .font(.body)
                        .foregroundStyle(DSHTheme.textPrimary)
                        .accessibilityIdentifier("question.text")
                    if !item.detail.isEmpty {
                        Text(verbatim: item.detail).font(.footnote).foregroundStyle(DSHTheme.textSecondary)
                    }
                    if question.outcome == nil {
                        chips(item)
                    } else {
                        answer(item)
                    }
                }
            }
            footer
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(question.outcome == nil ? DSHTheme.amber.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(question.outcome == nil ? DSHTheme.amber.opacity(0.4) : DSHTheme.hairline))
    }

    private func chips(_ item: AgentQuestion.Item) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(item.options, id: \.label) { option in
                let selected = chosen[item.id] == option.label
                Button { choose(option.label, for: item) } label: {
                    Text(verbatim: option.label)
                        .font(.subheadline)
                        .foregroundStyle(DSHTheme.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(selected ? DSHTheme.blue.opacity(0.25) : Color.clear, in: Capsule())
                        .overlay(Capsule().strokeBorder(selected ? DSHTheme.blue : Color.white.opacity(0.16)))
                }
                .buttonStyle(.plain)
                .disabled(sending)
                .accessibilityLabel(option.label)
                .accessibilityHint(option.description)
                .accessibilityIdentifier("question.option")
            }
        }
    }

    private func answer(_ item: AgentQuestion.Item) -> some View {
        let labels = question.answers[item.id] ?? []
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: question.outcome == .cancelled ? "xmark.circle" : "checkmark.circle.fill")
                .foregroundStyle(question.outcome == .cancelled ? DSHTheme.textTertiary : DSHTheme.green)
            Text(verbatim: labels.isEmpty ? "—" : labels.joined(separator: ", "))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(DSHTheme.textPrimary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("question.answer")
    }

    @ViewBuilder private var footer: some View {
        Group {
            if let error {
                Text(verbatim: error).foregroundStyle(DSHTheme.red)
            } else {
                switch question.outcome {
                case nil: Text("The task is waiting for you and will not choose by itself.", tableName: "Questions")
                case .answered?: Text("You answered. The task continues.", tableName: "Questions")
                case .answeredElsewhere?: Text("Answered on another client.", tableName: "Questions")
                case .cancelled?: Text("Not answered. The turn ended.", tableName: "Questions")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(DSHTheme.textTertiary)
        .accessibilityIdentifier("question.footer")
    }

    private func choose(_ label: String, for item: AgentQuestion.Item) {
        chosen[item.id] = label
        // One tap answers a single question; with several, the last missing choice sends.
        guard question.items.allSatisfy({ chosen[$0.id] != nil }), let store else { return }
        let answers = chosen.mapValues { [$0] }
        sending = true
        error = nil
        Task {
            do {
                try await store.answerQuestion(question, hostKey: row.hostKey, answers: answers)
            } catch {
                self.error = String(localized: "Could not send the answer. Try again.", table: "Questions")
                chosen = [:]
            }
            sending = false
        }
    }
}

/// Chips that wrap onto more lines when they do not fit on one.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
