import SwiftUI

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    typealias Cache = (size: CGSize, positions: [CGPoint])

    func makeCache(subviews: Subviews) -> Cache {
        (CGSize.zero, [])
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        cache = result
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        // A cached arrangement may have been measured before a sidebar/inspector resize.
        let result = arrange(proposal: ProposedViewSize(width: bounds.width, height: proposal.height),
                             subviews: subviews)
        cache = result
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = max(1, proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 1)
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: currentX, y: currentY))
            rowHeight = max(rowHeight, size.height)
            currentX += size.width + spacing
            maxX = max(maxX, currentX - spacing)
        }

        return (CGSize(width: min(maxX, maxWidth), height: currentY + rowHeight), positions)
    }
}
