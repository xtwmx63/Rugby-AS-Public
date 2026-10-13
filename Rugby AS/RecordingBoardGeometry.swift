import Foundation

/// The board uses six equal columns and integral row spans. Explicit positions
/// are reserved first, so adding an automatic tile never displaces a pinned one.
enum RecordingBoardPacking {
    static let columnCount = 6
    static let maximumRows = 10

    static func cells(widgets: [RecordingWidgetDefinition]) -> [RecordingGridCell] {
        var result = Array<RecordingGridCell?>(repeating: nil, count: widgets.count)
        var occupied: Set<Int> = []
        for (index, widget) in widgets.enumerated() {
            guard let position = widget.position,
                  isInBounds(position, size: widget.size) else { continue }
            let cell = cell(position: position, size: widget.size)
            let indices = indices(for: cell)
            guard occupied.isDisjoint(with: indices) else { continue }
            result[index] = cell
            occupied.formUnion(indices)
        }
        for (index, widget) in widgets.enumerated() where result[index] == nil {
            var row = 0
            search: while true {
                for column in 0...(columnCount - widget.size.columns) {
                    let candidate = cell(position: .init(column: column, row: row), size: widget.size)
                    let indices = indices(for: candidate)
                    if occupied.isDisjoint(with: indices) {
                        result[index] = candidate
                        occupied.formUnion(indices)
                        break search
                    }
                }
                row += 1
            }
        }
        return result.compactMap { $0 }
    }

    static func rowCount(widgets: [RecordingWidgetDefinition]) -> Int {
        cells(widgets: widgets).map { $0.row + $0.height }.max() ?? 0
    }

    static func placing(widgetID: UUID, column: Int, row: Int, in layout: RecordingLayout) throws -> RecordingLayout {
        try validate(widgets: layout.widgets)
        guard let index = layout.widgets.firstIndex(where: { $0.id == widgetID }) else {
            throw RecordingWidgetError.invalid("配置するボタンが見つかりません。")
        }
        let position = RecordingBoardPosition(column: column, row: row)
        guard isInBounds(position, size: layout.widgets[index].size) else {
            throw RecordingWidgetError.invalid("ボタンがボードからはみ出します。サイズか位置を変更してください。")
        }
        let existing = cells(widgets: layout.widgets)
        let candidateIndices = indices(for: cell(position: position, size: layout.widgets[index].size))
        for (otherIndex, other) in existing.enumerated() where otherIndex != index {
            guard candidateIndices.isDisjoint(with: indices(for: other)) else {
                throw RecordingWidgetError.invalid("その位置には別のボタンがあります。空いている位置を選んでください。")
            }
        }
        var result = layout
        // Freeze the current effective positions while moving, preserving every
        // other tile. Auto arranging is an explicit, separate editor action.
        for widgetIndex in result.widgets.indices {
            result.widgets[widgetIndex].position = .init(column: existing[widgetIndex].column, row: existing[widgetIndex].row)
        }
        result.widgets[index].position = position
        return try result.validated()
    }

    static func compacting(_ layout: RecordingLayout) -> RecordingLayout {
        var result = layout
        for index in result.widgets.indices { result.widgets[index].position = nil }
        return result
    }

    static func validate(widgets: [RecordingWidgetDefinition]) throws {
        var occupied: Set<Int> = []
        for widget in widgets {
            guard let position = widget.position else { continue }
            guard isInBounds(position, size: widget.size) else {
                throw RecordingWidgetError.invalid("ボタンがボードからはみ出します。サイズか位置を変更してください。")
            }
            let indices = indices(for: cell(position: position, size: widget.size))
            guard occupied.isDisjoint(with: indices) else {
                throw RecordingWidgetError.invalid("ボタンの位置が重なっています。空いている位置に移動してください。")
            }
            occupied.formUnion(indices)
        }
        guard rowCount(widgets: widgets) <= maximumRows else {
            throw RecordingWidgetError.invalid("1画面のボードは10段までです。ボタンを小さくするか、項目を減らしてください。")
        }
    }

    private static func isInBounds(_ position: RecordingBoardPosition, size: RecordingWidgetSize) -> Bool {
        (0...(columnCount - size.columns)).contains(position.column)
            && (0...(maximumRows - size.rows)).contains(position.row)
    }

    private static func cell(position: RecordingBoardPosition, size: RecordingWidgetSize) -> RecordingGridCell {
        .init(column: position.column, row: position.row, width: size.columns, height: size.rows)
    }

    private static func indices(for cell: RecordingGridCell) -> Set<Int> {
        Set((cell.row..<(cell.row + cell.height)).flatMap { row in
            (cell.column..<(cell.column + cell.width)).map { row * columnCount + $0 }
        })
    }
}
