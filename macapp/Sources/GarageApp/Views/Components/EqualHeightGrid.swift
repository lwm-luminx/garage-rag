import SwiftUI

/// Columns as `GridItem(.adaptive(minimum:maximum:))` lays them out, with every tile in a row
/// as tall as the tallest one. `LazyVGrid` sizes each tile to its own content, so a tile with a
/// longer subtitle or an extra badge stood taller than its neighbours. A tile fills the height it
/// is offered when it ends in `.frame(maxHeight: .infinity)`.
struct EqualHeightGrid: Layout {
    var minimumColumnWidth: CGFloat
    var maximumColumnWidth: CGFloat = .infinity
    var spacing: CGFloat = 12

    /// How many columns of at least `minimum` fit in `width`, as an adaptive grid item counts them.
    static func columnCount(width: CGFloat, minimum: CGFloat, spacing: CGFloat) -> Int {
        guard width.isFinite, minimum > 0 else { return 1 }
        return max(1, Int(((width + spacing) / (minimum + spacing)).rounded(.down)))
    }

    /// The width of each of `count` columns sharing `width`, held to `maximum`.
    static func columnWidth(width: CGFloat, count: Int, spacing: CGFloat, maximum: CGFloat) -> CGFloat {
        let shared = (width - spacing * CGFloat(count - 1)) / CGFloat(count)
        return max(0, min(shared, maximum))
    }

    /// The tallest tile of each row.
    static func rowHeights(_ heights: [CGFloat], columns: Int) -> [CGFloat] {
        stride(from: 0, to: heights.count, by: max(columns, 1)).map { start in
            heights[start..<min(start + max(columns, 1), heights.count)].max() ?? 0
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let metrics = metrics(width: proposal.width, subviews: subviews)
        let rows = metrics.rowHeights
        let height = rows.reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let used = min(subviews.count, metrics.columns)
        let width = metrics.columnWidth * CGFloat(used) + spacing * CGFloat(max(used - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let metrics = metrics(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (row, height) in metrics.rowHeights.enumerated() {
            for column in 0..<metrics.columns {
                let index = row * metrics.columns + column
                guard index < subviews.count else { break }
                subviews[index].place(
                    at: CGPoint(x: bounds.minX + CGFloat(column) * (metrics.columnWidth + spacing), y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: metrics.columnWidth, height: height)
                )
            }
            y += height + spacing
        }
    }

    private struct Metrics {
        var columns: Int
        var columnWidth: CGFloat
        var rowHeights: [CGFloat]
    }

    private func metrics(width proposed: CGFloat?, subviews: Subviews) -> Metrics {
        // Unproposed, the grid is as wide as three columns at their minimum.
        let width = proposed ?? (minimumColumnWidth * 3 + spacing * 2)
        let columns = Self.columnCount(width: width, minimum: minimumColumnWidth, spacing: spacing)
        let columnWidth = Self.columnWidth(
            width: width, count: columns, spacing: spacing, maximum: maximumColumnWidth)
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }
        return Metrics(columns: columns, columnWidth: columnWidth, rowHeights: Self.rowHeights(heights, columns: columns))
    }
}
