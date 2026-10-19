import SwiftUI
import Core

/// Uses the width actually proposed by scroll content, including any space reserved for a
/// native scrollbar. Each subview is one independent card, in ordinary row-major order.
struct CardGridLayout: Layout {
    enum ColumnSizing {
        /// Lists share viewport-based tracks across every tag group, even sparse ones.
        case uniform
        /// The home task preview keeps its existing item-count-based sizing.
        case fitItems
    }

    let mode: CardDisplayMode
    var columnSizing: ColumnSizing = .uniform

    private struct Metrics {
        let width: CGFloat
        let columns: Int
        let cardWidth: CGFloat
        let sizes: [CGSize]
        let rowHeights: [CGFloat]

        var height: CGFloat {
            rowHeights.reduce(0, +) + CGFloat(max(0, rowHeights.count - 1)) * CardDisplay.spacing
        }
    }

    private func metrics(width proposedWidth: CGFloat?, subviews: Subviews) -> Metrics {
        let width = proposedWidth.flatMap { $0.isFinite ? max(0, $0) : nil } ?? CardDisplay.wideColumnMinimum
        let columns: Int
        let cardWidth: CGFloat
        switch mode {
        case .wide:
            let grid = columnSizing == .uniform
                ? CardDisplay.wideListGrid(in: width)
                : CardDisplay.wideGrid(in: width, itemCount: subviews.count)
            columns = grid.columns
            cardWidth = min(width, grid.cardWidth)
        case .square:
            columns = CardDisplay.squareColumns(in: width)
            cardWidth = CardDisplay.cardHeight
        }
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: cardWidth, height: nil)) }
        var rows = Array(repeating: CGFloat.zero, count: (subviews.count + columns - 1) / columns)
        for (index, size) in sizes.enumerated() {
            rows[index / columns] = max(rows[index / columns], size.height)
        }
        return Metrics(width: width, columns: columns, cardWidth: cardWidth, sizes: sizes, rowHeights: rows)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let grid = metrics(width: proposal.width, subviews: subviews)
        return CGSize(width: grid.width, height: grid.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let grid = metrics(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (index, subview) in subviews.enumerated() {
            let column = index % grid.columns
            if column == 0 && index > 0 {
                y += grid.rowHeights[index / grid.columns - 1] + CardDisplay.spacing
            }
            subview.place(at: CGPoint(x: bounds.minX + CGFloat(column) * (grid.cardWidth + CardDisplay.spacing), y: y),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(width: grid.cardWidth, height: grid.sizes[index].height))
        }
    }
}
