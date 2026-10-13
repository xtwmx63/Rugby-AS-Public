import Foundation
import CoreGraphics

/// Cards share row heights within each panel. A wide viewport may place row
/// bands side by side and fill both panels without splitting a card.
struct RecordingBoardViewport {
    let frames: [CGRect]
    init(cells: [RecordingGridCell], size: CGSize, spacing: CGFloat = 6) {
        let availableWidth = max(0, size.width.isFinite ? size.width : 0)
        let availableHeight = max(0, size.height.isFinite ? size.height : 0)
        let originalRows = max(1, cells.map { $0.row + $0.height }.max() ?? 1)
        let canFold = availableWidth > availableHeight * 1.4 && originalRows >= 5
        let cut = canFold ? (1..<originalRows).filter { row in
            !cells.contains { $0.row < row && $0.row + $0.height > row }
        }.min { abs($0 * 2 - originalRows) < abs($1 * 2 - originalRows) } : nil
        let rows = cut.map { max($0, originalRows - $0) } ?? originalRows
        let columns = cut == nil ? 6 : 12
        // During rotation the proposed size can briefly be smaller than the
        // gaps alone. Shrink spacing too, keeping every frame within the board.
        let requestedGap: CGFloat = max(0, spacing.isFinite ? spacing : 0)
        let gap: CGFloat = min(requestedGap, min(availableWidth / CGFloat(columns - 1),
                                                availableHeight / CGFloat(max(1, rows - 1))))
        let unitWidth: CGFloat = max(0, (availableWidth - CGFloat(columns - 1) * gap) / CGFloat(columns))
        frames = cells.map { cell in
            let right = cut.map { cell.row >= $0 } ?? false
            let panelRows = cut.map { right ? originalRows - $0 : $0 } ?? originalRows
            let unitHeight: CGFloat = max(0, (availableHeight - CGFloat(panelRows - 1) * gap) / CGFloat(panelRows))
            let column = cell.column + (right ? 6 : 0)
            let row = cell.row - (right ? cut! : 0)
            let x: CGFloat = CGFloat(column) * (unitWidth + gap)
            let y: CGFloat = CGFloat(row) * (unitHeight + gap)
            let width: CGFloat = CGFloat(cell.width) * unitWidth + CGFloat(cell.width - 1) * gap
            let height: CGFloat = CGFloat(cell.height) * unitHeight + CGFloat(cell.height - 1) * gap
            return CGRect(x: x, y: y, width: width, height: height)
        }
    }
}
