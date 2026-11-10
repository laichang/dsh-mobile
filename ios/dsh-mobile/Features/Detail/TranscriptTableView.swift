import DSHCore
import SwiftUI

/// S28 · a GFM table in the transcript (screen 04, D79): the header row on a fill, hairlines between
/// rows, each column aligned as its delimiter row says. A column is as wide as its widest cell, up to
/// `maxColumnWidth`; a longer cell wraps. A table wider than the page scrolls inside its own row.
struct TranscriptTableView: View {
    let table: TranscriptBlocks.Table
    @Environment(\.displayScale) private var displayScale

    static let maxColumnWidth: CGFloat = 240

    var body: some View {
        ScrollView(.horizontal) {
            TableGridLayout(columns: table.header.count, maxColumnWidth: Self.maxColumnWidth) {
                ForEach(table.header.indices, id: \.self) { column in
                    cell(table.header[column], column: column, header: true, last: table.rows.isEmpty)
                }
                ForEach(table.rows.indices, id: \.self) { row in
                    ForEach(table.rows[row].indices, id: \.self) { column in
                        cell(table.rows[row][column], column: column, header: false, last: row == table.rows.count - 1)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(DSHTheme.hairline))
            .padding(1)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .accessibilityIdentifier("transcript.table")
    }

    private func cell(_ text: AttributedString, column: Int, header: Bool, last: Bool) -> some View {
        let alignment = column < table.alignments.count ? table.alignments[column] : .leading
        return Text(TranscriptView.dshStyled(text, code: .footnote))
            .font(header ? .subheadline.weight(.semibold) : .subheadline)
            .foregroundStyle(header ? DSHTheme.textPrimary : DSHTheme.textPrimary.opacity(0.9))
            .multilineTextAlignment(alignment.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment.frame)
            .background(header ? DSHTheme.tableHeaderFill : .clear)
            .overlay(alignment: .bottom) {
                if !last {
                    Rectangle().fill(DSHTheme.hairline).frame(height: 1 / displayScale)
                }
            }
    }
}

private extension TranscriptBlocks.Table.Alignment {
    var text: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var frame: Alignment {
        switch self {
        case .leading: .topLeading
        case .center: .top
        case .trailing: .topTrailing
        }
    }
}

/// Cells in row-major order. Each column is as wide as its widest cell (ideal size), clamped to
/// `maxColumnWidth`; each row is as tall as its tallest cell at those widths. Every cell is placed
/// at its column's width and its row's height, so backgrounds and hairlines fill the row.
private struct TableGridLayout: Layout {
    let columns: Int
    let maxColumnWidth: CGFloat

    private func measure(_ subviews: Subviews) -> (widths: [CGFloat], heights: [CGFloat]) {
        guard columns > 0 else { return ([], []) }
        let rows = (subviews.count + columns - 1) / columns
        var widths = [CGFloat](repeating: 0, count: columns)
        for (index, subview) in subviews.enumerated() {
            let ideal = subview.sizeThatFits(.unspecified).width
            widths[index % columns] = max(widths[index % columns], min(ideal.rounded(.up), maxColumnWidth))
        }
        var heights = [CGFloat](repeating: 0, count: rows)
        for (index, subview) in subviews.enumerated() {
            let height = subview.sizeThatFits(ProposedViewSize(width: widths[index % columns], height: nil)).height
            heights[index / columns] = max(heights[index / columns], height.rounded(.up))
        }
        return (widths, heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (widths, heights) = measure(subviews)
        return CGSize(width: widths.reduce(0, +), height: heights.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (widths, heights) = measure(subviews)
        var y = bounds.minY
        for row in heights.indices {
            var x = bounds.minX
            for column in widths.indices {
                let index = row * columns + column
                guard index < subviews.count else { break }
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: widths[column], height: heights[row]))
                x += widths[column]
            }
            y += heights[row]
        }
    }
}
