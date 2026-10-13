import Foundation
import CoreGraphics

private enum BoardCheckFailure: Error { case failed(String) }

enum BoardRegressionChecks {
    static func run() throws {
        try preservesPinnedTilesBeforeAutomaticPacking()
        try packsMixedSizesDeterministicallyWithoutCollisions()
        try rejectsOverlappingPositions()
        try movesOneTileWithoutMovingItsNeighbours()
        try compactsPinnedPositions()
        try rejectsBoardBoundsAndOverflow()
        try decodesLayoutsBeforeCustomization()
        try persistsAppearanceAndPosition()
        try validatesCustomColors()
        try validatesEveryTemplate()
        try fitsBoardAcrossPhoneTabletAndLandscapeSizes()
        try keepsUniformSixPointRowGaps()
        try foldsLandscapeWithoutSplittingTallCards()
        try keepsTransientSmallViewportsInBounds()
        print("PASS: 14 board regression checks")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw BoardCheckFailure.failed(message) }
    }

    private static func rejects(_ message: String, _ action: () throws -> Void) throws {
        do { try action() } catch is RecordingWidgetError { return }
        throw BoardCheckFailure.failed(message)
    }

    private static func tile(_ size: RecordingWidgetSize, at position: RecordingBoardPosition? = nil) -> RecordingWidgetDefinition {
        var widget = RecordingWidgetDefinition.make(.count)
        widget.size = size
        widget.position = position
        return widget
    }

    private static func preservesPinnedTilesBeforeAutomaticPacking() throws {
        let widgets = [tile(.small), tile(.small, at: .init(column: 0, row: 0)), tile(.wide, at: .init(column: 0, row: 4))]
        let cells = RecordingBoardPacking.cells(widgets: widgets)
        try expect(cells[0] == .init(column: 3, row: 0, width: 3, height: 1), "Automatic tile must respect a later pinned tile")
        try expect(cells[1] == .init(column: 0, row: 0, width: 3, height: 1), "Valid explicit position must remain fixed")
        try expect(cells[2].row == 4, "Intentional empty rows must not be collapsed implicitly")
    }

    private static func packsMixedSizesDeterministicallyWithoutCollisions() throws {
        for offset in 0..<RecordingWidgetSize.allCases.count {
            let widgets = (0..<15).map { tile(RecordingWidgetSize.allCases[($0 + offset) % RecordingWidgetSize.allCases.count]) }
            let cells = RecordingBoardPacking.cells(widgets: widgets)
            try expect(cells == RecordingBoardPacking.cells(widgets: widgets), "Packing must be deterministic")
            try expect(cells.count == widgets.count, "Packing must retain widget ordering and count")
            var occupied = Set<Int>()
            for (index, cell) in cells.enumerated() {
                try expect(cell.width == widgets[index].size.columns && cell.height == widgets[index].size.rows,
                           "Each tile must use its full integral row and column span")
                try expect(cell.column >= 0 && cell.column + cell.width <= RecordingBoardPacking.columnCount,
                           "Every tile must fit the board width")
                for row in cell.row..<(cell.row + cell.height) {
                    for column in cell.column..<(cell.column + cell.width) {
                        try expect(occupied.insert(row * RecordingBoardPacking.columnCount + column).inserted,
                                   "Mixed size tiles must never overlap")
                    }
                }
            }
        }
    }

    private static func rejectsOverlappingPositions() throws {
        let overlap = RecordingLayout(widgets: [tile(.large, at: .init(column: 0, row: 0)), tile(.compact, at: .init(column: 2, row: 1))])
        try rejects("Explicit partial overlap must fail validation") { _ = try overlap.validated() }
        let layout = RecordingLayout(widgets: [tile(.small), tile(.small)])
        try rejects("Moving onto another automatic tile must be rejected") {
            _ = try RecordingBoardPacking.placing(widgetID: layout.widgets[0].id, column: 3, row: 0, in: layout)
        }
        var resized = layout
        for index in resized.widgets.indices { resized.widgets[index].position = .init(column: index * 3, row: 0) }
        resized.widgets[0].size = .wide
        try rejects("Resizing into a pinned neighbour must be rejected") { _ = try resized.validated() }
    }

    private static func movesOneTileWithoutMovingItsNeighbours() throws {
        let layout = RecordingLayout(widgets: [tile(.small), tile(.small), tile(.compact)])
        let original = RecordingBoardPacking.cells(widgets: layout.widgets)
        let moved = try RecordingBoardPacking.placing(widgetID: layout.widgets[0].id, column: 3, row: 2, in: layout)
        let cells = RecordingBoardPacking.cells(widgets: moved.widgets)
        try expect(cells[0] == .init(column: 3, row: 2, width: 3, height: 1), "Moved tile must use requested coordinates")
        try expect(Array(cells.dropFirst()) == Array(original.dropFirst()), "Moving must not rearrange the other tiles")
        try expect(moved.widgets.allSatisfy { $0.position != nil }, "Manual placement must pin current neighbours")
        try expect(layout.widgets.allSatisfy { $0.position == nil }, "Editing a candidate must leave original layout unchanged")
    }

    private static func compactsPinnedPositions() throws {
        let layout = RecordingLayout(widgets: [tile(.small, at: .init(column: 0, row: 5)), tile(.small, at: .init(column: 3, row: 9))])
        let compacted = RecordingBoardPacking.compacting(layout)
        try expect(compacted.widgets.allSatisfy { $0.position == nil }, "Auto arranging must clear explicit positions")
        try expect(RecordingBoardPacking.rowCount(widgets: compacted.widgets) == 1, "Auto arranging must reclaim empty rows")
        try expect(compacted.widgets.map(\.id) == layout.widgets.map(\.id), "Auto arranging must preserve widget identities")
    }

    private static func rejectsBoardBoundsAndOverflow() throws {
        for position in [RecordingBoardPosition(column: -1, row: 0), .init(column: 4, row: 0),
                         .init(column: 0, row: -1), .init(column: 0, row: 10), .init(column: Int.max, row: Int.max)] {
            let layout = RecordingLayout(widgets: [tile(.small, at: position)])
            try rejects("Out-of-bounds positions must fail safely") { _ = try layout.validated() }
        }
        try rejects("A two-row tile cannot start on the final row") {
            _ = try RecordingLayout(widgets: [tile(.large, at: .init(column: 0, row: 9))]).validated()
        }
        let filled = RecordingLayout(widgets: (0..<30).map { _ in tile(.compact) })
        _ = try filled.validated()
        try expect(RecordingBoardPacking.rowCount(widgets: filled.widgets) == 10, "Thirty compact tiles fit exactly in ten rows")
        try rejects("Automatically packed rows must respect the ten-row limit") {
            _ = try RecordingLayout(widgets: (0..<6).map { _ in tile(.large) }).validated()
        }
        try expect(RecordingBoardPacking.rowCount(widgets: []) == 0, "Empty boards must have zero rows")
    }

    private static func decodesLayoutsBeforeCustomization() throws {
        let old = Data(#"{"version":1,"name":"マイレイアウト","widgets":[{"id":"10000000-0000-0000-0000-000000000001","kind":"count","title":"タックル","symbol":"shield.fill","color":"orange","size":"row","category":"tackle","scope":"selected","timerTarget":"home","choices":[],"unit":"m","leadTime":10,"lagTime":5,"attachesToLatest":false,"isPrimaryAction":true}],"links":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(RecordingLayout.self, from: old)
        _ = try decoded.validated()
        try expect(decoded.widgets[0].position == nil && decoded.widgets[0].appearance == nil,
                   "Layouts saved before customization must decode absent fields")
        try expect(decoded.widgets[0].effectiveAppearance == RecordingWidgetAppearance(), "Old layouts must use default appearance")
        let partialAppearance = try JSONDecoder().decode(RecordingWidgetAppearance.self, from: Data(#"{"showIcon":false}"#.utf8))
        try expect(partialAppearance.style == .filled && partialAppearance.corner == .rounded && !partialAppearance.showIcon,
                   "Partially specified appearance must fill its optional defaults")
    }

    private static func persistsAppearanceAndPosition() throws {
        var widget = tile(.compact, at: .init(column: 4, row: 7))
        widget.appearance = .init(style: .outline, corner: .pill, showIcon: false, customColorHex: "#2468AC")
        let layout = RecordingLayout(widgets: [widget])
        let decoded = try JSONDecoder().decode(RecordingLayout.self, from: JSONEncoder().encode(layout))
        try expect(decoded == layout, "Board placement, colors, corners and icons must survive save and reopen")
    }

    private static func validatesCustomColors() throws {
        for color in ["#12aBef", "12aBef"] {
            var widget = tile(.compact)
            widget.appearance = .init(customColorHex: color)
            _ = try RecordingLayout(widgets: [widget]).validated()
            try expect(widget.effectiveAppearance.normalizedCustomColorHex == "#12ABEF", "Custom color normalization must retain RGB values")
        }
        for color in ["#FFF", "#12345678", "#12GGFF", "", "１２３４５６"] {
            var widget = tile(.compact)
            widget.appearance = .init(customColorHex: color)
            try rejects("Malformed colors must fail before saving") { _ = try RecordingLayout(widgets: [widget]).validated() }
        }
    }

    private static func validatesEveryTemplate() throws {
        for template in RecordingLayoutTemplate.all {
            _ = try template.layout.validated()
            try expect(RecordingBoardPacking.rowCount(widgets: template.layout.widgets) <= RecordingBoardPacking.maximumRows,
                       "Every offered template must fit the board")
        }
        let setPiece = RecordingLayout.setPieceTemplate
        for category in ["lineout", "scrum"] {
            try expect(setPiece.widgets.contains { $0.category == category && $0.kind == .result },
                       "Set-piece template must include inputs for the metrics it displays")
        }
    }

    private static func fitsBoardAcrossPhoneTabletAndLandscapeSizes() throws {
        let sizes = [CGSize(width: 320, height: 306), CGSize(width: 393, height: 520),
                     CGSize(width: 760, height: 800), CGSize(width: 620, height: 300)]
        let mixed = RecordingLayout(widgets: [.compact, .compact, .compact, .large, .row, .small, .wide, .large].map { tile($0) })
        let pinned = RecordingLayout(widgets: [tile(.compact, at: .init(column: 4, row: 0)),
                                               tile(.large, at: .init(column: 0, row: 3)),
                                               tile(.small, at: .init(column: 3, row: 9)), tile(.row)])
        let crowded = RecordingLayout(widgets: (0..<30).map { _ in tile(.compact) })
        let layouts = RecordingLayoutTemplate.all.map(\.layout) + [mixed, pinned, crowded]
        for layout in layouts {
            _ = try layout.validated()
            let cells = RecordingBoardPacking.cells(widgets: layout.widgets)
            for size in sizes {
                let frames = RecordingBoardViewport(cells: cells, size: size).frames
                try expect(frames.count == cells.count, "Viewport must keep every card visible")
                try verifyFrames(frames, fit: size)
                try expect(frames.allSatisfy { $0.width > 0 && $0.height > 0 }, "Normal phone and tablet sizes must give every card positive area")
            }
        }
    }

    private static func keepsUniformSixPointRowGaps() throws {
        let widgets: [RecordingWidgetDefinition] = [.compact, .compact, .compact, .row, .row, .small, .small, .wide, .large].map { tile($0) }
        let cells = RecordingBoardPacking.cells(widgets: widgets)
        for size in [CGSize(width: 320, height: 306), CGSize(width: 393, height: 520), CGSize(width: 760, height: 800)] {
            let frames = RecordingBoardViewport(cells: cells, size: size).frames
            for pair in [(0, 3), (3, 5), (5, 7), (7, 8)] {
                try expect(abs(frames[pair.1].minY - frames[pair.0].maxY - 6) < 0.0001,
                           "Compact and row cards must fill the row, leaving exactly six points before the next row")
            }
            try expect(abs(frames[0].height - frames[3].height) < 0.0001,
                       "One-row cards must share height regardless of their width or face style")
            try expect(abs(frames[8].height - (frames[0].height * 2 + 6)) < 0.0001,
                       "Tall cards must fill two complete rows and their intervening gap")
        }
    }

    private static func foldsLandscapeWithoutSplittingTallCards() throws {
        let size = CGSize(width: 620, height: 300)
        // The two-row card crosses the middle of this six-row board. Folding
        // directly at the midpoint would cut the card, so a neighbouring cut is needed.
        let widgets: [RecordingWidgetDefinition] = [.wide, .wide, .large, .wide, .wide].map { tile($0) }
        let frames = RecordingBoardViewport(cells: RecordingBoardPacking.cells(widgets: widgets), size: size).frames
        try verifyFrames(frames, fit: size)
        let leftEdgeOfSeam = (size.width - 6) / 2
        let rightEdgeOfSeam = (size.width + 6) / 2
        try expect(frames.allSatisfy { $0.maxX <= leftEdgeOfSeam + 0.0001 || $0.minX >= rightEdgeOfSeam - 0.0001 },
                   "Every card must fit entirely on one side of the landscape seam")
        try expect(frames.contains { $0.minX >= rightEdgeOfSeam - 0.0001 }, "Wide viewports must actually fold taller boards")
        try expect(abs(frames[2].height - (frames[3].height * 2 + 6)) < 0.0001,
                   "Landscape folding must retain the full two-row card")
        try expect(abs(frames[1].maxY - size.height) < 0.0001 && abs(frames[4].maxY - size.height) < 0.0001,
                   "Uneven landscape panels must both fill the available height without a blank bottom row")

        let sixRows = (0..<6).map { _ in tile(.wide) }
        let rows = RecordingBoardViewport(cells: RecordingBoardPacking.cells(widgets: sixRows), size: size).frames
        for pair in [(0, 1), (1, 2), (3, 4), (4, 5)] {
            try expect(abs(rows[pair.1].minY - rows[pair.0].maxY - 6) < 0.0001,
                       "Adjacent rows on each landscape panel must retain six-point gaps")
        }
        try expect(abs(rows[3].minX - rows[0].maxX - 6) < 0.0001, "Landscape panels must have the same six-point gap")
    }

    private static func keepsTransientSmallViewportsInBounds() throws {
        let cells = RecordingBoardPacking.cells(widgets: (0..<30).map { _ in tile(.compact) })
        for size in [CGSize.zero, CGSize(width: 12, height: 8), CGSize(width: 320, height: 0)] {
            try verifyFrames(RecordingBoardViewport(cells: cells, size: size).frames, fit: size)
        }
    }

    private static func verifyFrames(_ frames: [CGRect], fit size: CGSize) throws {
        for (index, frame) in frames.enumerated() {
            try expect(frame.minX >= -0.0001 && frame.minY >= -0.0001 && frame.maxX <= size.width + 0.0001 && frame.maxY <= size.height + 0.0001,
                       "Every frame must stay within the visible viewport")
            try expect(frame.width >= 0 && frame.height >= 0, "Viewport must never produce negative frame dimensions")
            for other in frames.dropFirst(index + 1) {
                let intersection = frame.intersection(other)
                try expect(intersection.isNull || intersection.width < 0.0001 || intersection.height < 0.0001,
                           "Fitting the board must not overlap card frames")
            }
        }
    }
}
