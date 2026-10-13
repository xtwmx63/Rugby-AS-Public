import Foundation

// Foundation のみで動く定義・連動判定。端末画面やデータベースとは分離して検証する。
enum RecordingWidgetKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case count, result, possession, player, choice, zone, timed, number, note
    case successRate, leader, clip
    // チームのロゴと名前を出すカード。押すと記録対象のチームが切り替わる。
    case teamBadge
    // 上部に固定されていた試合時計と得点。ボードに置くと上の表示は消える。
    case matchClock, scoreboard
    var id: String { rawValue }
    var title: String {
        switch self {
        case .count: return "回数カウント"
        case .result: return "成功・失敗"
        case .possession: return "保持時間・BIP"
        case .player: return "選手写真から選択"
        case .choice: return "選択肢で入力"
        case .zone: return "9分割の場所入力"
        case .timed: return "自動終了タイマー"
        case .number: return "数値入力"
        case .note: return "要確認・メモ"
        case .successRate: return "成功率"
        case .leader: return "選手成績カード"
        case .clip: return "プレー映像"
        case .teamBadge: return "チームカード"
        case .matchClock: return "試合時計"
        case .scoreboard: return "得点"
        }
    }
    var symbol: String {
        switch self {
        case .count: return "plus.circle.fill"
        case .result: return "checkmark.circle.fill"
        case .possession: return "stopwatch.fill"
        case .player: return "person.crop.rectangle"
        case .choice: return "square.grid.2x2.fill"
        case .zone: return "sportscourt.fill"
        case .timed: return "timer"
        case .number: return "number"
        case .note: return "flag.fill"
        case .successRate: return "chart.pie.fill"
        case .leader: return "person.crop.square.fill"
        case .clip: return "play.rectangle.fill"
        case .teamBadge: return "shield.fill"
        case .matchClock: return "clock.fill"
        case .scoreboard: return "number.square.fill"
        }
    }
    var isDisplay: Bool { [.successRate, .leader, .clip, .teamBadge, .matchClock, .scoreboard].contains(self) }
    var canLink: Bool { [.count, .timed, .possession].contains(self) }
}

nonisolated enum RecordingWidgetSize: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case compact, small, row, wide, large
    var id: String { rawValue }
    var title: String {
        switch self {
        case .compact: return "小・3列"
        case .small: return "中・2列"
        case .row: return "横長・2列"
        case .wide: return "全幅 1段"
        case .large: return "全幅 2段"
        }
    }
    var columns: Int {
        switch self {
        case .compact: return 2
        case .small, .row: return 3
        case .wide, .large: return 6
        }
    }
    var rows: Int { self == .large ? 2 : 1 }
    var rowScale: Double {
        switch self {
        case .compact: return 0.58
        case .row: return 0.72
        default: return 1
        }
    }
}

enum RecordingWidgetColor: String, Codable, CaseIterable, Identifiable, Hashable {
    case blue, green, orange, red, purple, cyan, yellow
    var id: String { rawValue }
    var title: String {
        switch self {
        case .blue: return "青"
        case .green: return "緑"
        case .orange: return "橙"
        case .red: return "赤"
        case .purple: return "紫"
        case .cyan: return "水色"
        case .yellow: return "黄"
        }
    }
}

enum RecordingWidgetStyle: String, Codable, CaseIterable, Identifiable, Hashable {
    case filled, outline, soft
    var id: String { rawValue }
    var title: String {
        switch self {
        case .filled: return "塗りつぶし"
        case .outline: return "アウトライン"
        case .soft: return "淡い背景"
        }
    }
}

enum RecordingWidgetCorner: String, Codable, CaseIterable, Identifiable, Hashable {
    case square, rounded, pill
    var id: String { rawValue }
    var title: String {
        switch self {
        case .square: return "四角"
        case .rounded: return "角丸"
        case .pill: return "カプセル"
        }
    }
}

struct RecordingWidgetAppearance: Codable, Equatable {
    var style: RecordingWidgetStyle = .filled
    var corner: RecordingWidgetCorner = .rounded
    var showIcon: Bool = true
    var customColorHex: String? = nil

    init(style: RecordingWidgetStyle = .filled, corner: RecordingWidgetCorner = .rounded,
         showIcon: Bool = true, customColorHex: String? = nil) {
        self.style = style
        self.corner = corner
        self.showIcon = showIcon
        self.customColorHex = customColorHex
    }

    private enum CodingKeys: String, CodingKey { case style, corner, showIcon, customColorHex }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        style = try values.decodeIfPresent(RecordingWidgetStyle.self, forKey: .style) ?? .filled
        corner = try values.decodeIfPresent(RecordingWidgetCorner.self, forKey: .corner) ?? .rounded
        showIcon = try values.decodeIfPresent(Bool.self, forKey: .showIcon) ?? true
        customColorHex = try values.decodeIfPresent(String.self, forKey: .customColorHex)
    }

    var normalizedCustomColorHex: String? {
        guard let customColorHex else { return nil }
        let value = customColorHex.hasPrefix("#") ? String(customColorHex.dropFirst()) : customColorHex
        guard value.count == 6, value.unicodeScalars.allSatisfy({
            (48...57).contains($0.value) || (65...70).contains($0.value) || (97...102).contains($0.value)
        }) else { return nil }
        return "#" + value.uppercased()
    }
}

struct RecordingBoardPosition: Codable, Equatable, Hashable {
    var column: Int
    var row: Int
}

enum RecordingTeamScope: String, Codable, CaseIterable, Identifiable, Hashable {
    case selected, home, away
    var id: String { rawValue }
    var title: String { self == .selected ? "選択中のチーム" : rawValue.uppercased() }
}

enum RecordingTimerTarget: String, Codable, CaseIterable, Identifiable, Hashable {
    case home, away, bip
    var id: String { rawValue }
    var title: String { self == .bip ? "BIP / プレー中" : rawValue.uppercased() + "保持" }
}

struct RecordingWidgetDefinition: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: RecordingWidgetKind
    var title: String
    var symbol: String
    var color: RecordingWidgetColor = .blue
    var size: RecordingWidgetSize = .small
    var category: String = "tackle"
    var scope: RecordingTeamScope = .selected
    var timerTarget: RecordingTimerTarget = .home
    var choices: [String] = []
    var unit: String = "m"
    var leadTime: Double = 10
    var lagTime: Double = 5
    var attachesToLatest: Bool = false
    var isPrimaryAction: Bool = false
    // Optional storage preserves layouts saved before board customization was added.
    var position: RecordingBoardPosition? = nil
    var appearance: RecordingWidgetAppearance? = nil
    var inlineInput: Bool? = nil
    var effectiveAppearance: RecordingWidgetAppearance { appearance ?? RecordingWidgetAppearance() }

    static func make(_ kind: RecordingWidgetKind) -> Self {
        var value = Self(kind: kind, title: kind.title, symbol: kind.symbol)
        switch kind {
        case .count: value.title = "タックル"; value.color = .orange; value.size = .row
        case .result: value.title = "ラインアウト"; value.category = "lineout"; value.color = .cyan; value.size = .row
        case .possession: value.title = "HOME保持"; value.scope = .home
        case .player: value.title = "選手を追加"; value.attachesToLatest = true
        case .choice:
            value.title = "反則の種類"; value.category = "penalty"; value.color = .red
            value.choices = ["オフサイド", "ハイタックル", "ノットリリース", "その他"]
        case .zone: value.title = "場所を追加"; value.attachesToLatest = true; value.color = .green
        case .timed: value.title = "好タックル"; value.category = "good_tackle"; value.color = .orange; value.size = .row
        case .number: value.title = "キック距離"; value.category = "kick"; value.size = .row
        case .note: value.title = "要確認・メモ"; value.category = "review"; value.color = .yellow; value.attachesToLatest = true
        case .successRate: value.title = "ラインアウト成功率"; value.category = "lineout"; value.size = .wide
        case .leader: value.title = "最多得点者"; value.category = "score"; value.size = .large
        case .clip: value.title = "最新のプレー"; value.size = .wide
        case .teamBadge: value.title = "HOME"; value.scope = .home; value.size = .compact
        case .matchClock: value.title = "試合時計"; value.size = .wide
        case .scoreboard: value.title = "得点"; value.color = .green; value.size = .wide
        }
        return value
    }
}

enum RecordingLinkAction: String, Codable, CaseIterable, Identifiable, Hashable {
    case start, stop, exclusive
    var id: String { rawValue }
    var title: String { self == .start ? "一緒に開始" : self == .stop ? "停止" : "どちらか一方" }
}

struct RecordingWidgetLink: Codable, Identifiable, Equatable {
    var id = UUID()
    var source: UUID
    var target: UUID
    var action: RecordingLinkAction
}

struct RecordingLayout: Codable, Equatable {
    var version: Int = 1
    var name: String = "マイレイアウト"
    var widgets: [RecordingWidgetDefinition]
    var links: [RecordingWidgetLink] = []

    static var standard: Self {
        legacyRecordingTemplate
    }

    static var legacyRecordingTemplate: Self {
        var home = RecordingWidgetDefinition.make(.possession)
        home.size = .compact
        var away = RecordingWidgetDefinition.make(.possession)
        away.title = "AWAY保持"; away.timerTarget = .away; away.scope = .away; away.color = .red; away.size = .compact
        var bip = RecordingWidgetDefinition.make(.possession)
        bip.title = "BIP"; bip.timerTarget = .bip; bip.scope = .selected; bip.color = .orange; bip.size = .compact
        var tryScore = RecordingWidgetDefinition.make(.count)
        tryScore.title = "トライ"; tryScore.category = "try"; tryScore.color = .green; tryScore.symbol = "rugbyball.fill"; tryScore.isPrimaryAction = true
        var conversion = RecordingWidgetDefinition.make(.count)
        conversion.title = "コンバージョン"; conversion.category = "conversion"; conversion.color = .purple; conversion.symbol = "figure.rugby"; conversion.isPrimaryAction = true
        var penaltyGoal = RecordingWidgetDefinition.make(.count)
        penaltyGoal.title = "PG"; penaltyGoal.category = "penalty_goal"; penaltyGoal.color = .blue; penaltyGoal.symbol = "p.circle"; penaltyGoal.isPrimaryAction = true
        var dropGoal = RecordingWidgetDefinition.make(.count)
        dropGoal.title = "DG"; dropGoal.category = "drop_goal"; dropGoal.color = .yellow; dropGoal.symbol = "d.circle"; dropGoal.isPrimaryAction = true
        var lineout = RecordingWidgetDefinition.make(.result)
        lineout.title = "ラインアウト"; lineout.symbol = "figure.strengthtraining.traditional"
        var scrum = RecordingWidgetDefinition.make(.result)
        scrum.title = "スクラム"; scrum.category = "scrum"; scrum.color = .purple; scrum.symbol = "person.3.fill"
        var penalty = RecordingWidgetDefinition.make(.choice)
        penalty.title = "反則"; penalty.size = .row; penalty.symbol = "flag.fill"
        var origin = RecordingWidgetDefinition.make(.choice)
        origin.title = "起点"; origin.category = "origin"; origin.color = .green; origin.symbol = "arrow.triangle.branch"
        origin.choices = PlayOrigin.allCases.map(\.shortName)
        origin.size = .row
        origin.attachesToLatest = true
        return Self(name: "従来画面ベース", widgets: [home, bip, away, tryScore, conversion, penaltyGoal, dropGoal, lineout, scrum, penalty, origin], links: [
            RecordingWidgetLink(source: home.id, target: away.id, action: .exclusive)
        ])
    }

    static var scoringTemplate: Self {
        var layout = baseMatchControlTemplate(name: "得点中心")
        var scorer = RecordingWidgetDefinition.make(.player)
        scorer.title = "得点者"; scorer.size = .row; scorer.symbol = "person.crop.circle"; scorer.attachesToLatest = true
        var leader = RecordingWidgetDefinition.make(.leader)
        leader.title = "最多得点者"; leader.scope = .selected
        layout.widgets.append(contentsOf: [scorer, leader])
        return layout
    }

    static var setPieceTemplate: Self {
        var layout = baseMatchControlTemplate(name: "セットプレー分析")
        layout.widgets.append(contentsOf: legacyRecordingTemplate.widgets.filter {
            $0.category == "lineout" || $0.category == "scrum"
        })
        var lineoutRate = RecordingWidgetDefinition.make(.successRate)
        lineoutRate.title = "ラインアウト成功率"; lineoutRate.category = "lineout"
        var scrumRate = RecordingWidgetDefinition.make(.successRate)
        scrumRate.title = "スクラム成功率"; scrumRate.category = "scrum"; scrumRate.color = .purple
        var zone = RecordingWidgetDefinition.make(.zone)
        zone.title = "場所"; zone.size = .row
        layout.widgets.append(contentsOf: [lineoutRate, scrumRate, zone])
        return layout
    }

    static var defensiveTemplate: Self {
        var layout = baseMatchControlTemplate(name: "守備・反則")
        layout.widgets.removeAll { ["conversion", "penalty_goal", "drop_goal"].contains($0.category) }
        var tackle = RecordingWidgetDefinition.make(.count)
        tackle.title = "タックル"; tackle.category = "tackle"; tackle.color = .orange; tackle.symbol = "shield.fill"; tackle.isPrimaryAction = true
        var goodTackle = RecordingWidgetDefinition.make(.timed)
        goodTackle.title = "好タックル"; goodTackle.category = "good_tackle"; goodTackle.symbol = "star.fill"; goodTackle.isPrimaryAction = true
        var turnover = RecordingWidgetDefinition.make(.count)
        turnover.title = "ターンオーバー"; turnover.category = "turnover"; turnover.color = .green; turnover.symbol = "arrow.triangle.2.circlepath"; turnover.isPrimaryAction = true
        var review = RecordingWidgetDefinition.make(.note)
        review.title = "要確認"; review.size = .row
        layout.widgets.append(contentsOf: [tackle, goodTackle, turnover, review])
        return layout
    }

    static var videoReviewTemplate: Self {
        var layout = legacyRecordingTemplate
        layout.name = "映像レビュー"
        var clip = RecordingWidgetDefinition.make(.clip)
        clip.title = "最新プレー映像"
        var note = RecordingWidgetDefinition.make(.note)
        note.title = "メモ"; note.size = .row
        var zone = RecordingWidgetDefinition.make(.zone)
        zone.title = "場所"; zone.size = .row
        layout.widgets.append(contentsOf: [clip, note, zone])
        return layout
    }

    private static func baseMatchControlTemplate(name: String) -> Self {
        var layout = legacyRecordingTemplate
        layout.name = name
        layout.widgets.removeAll { ["lineout", "scrum", "penalty", "origin"].contains($0.category) }
        return layout
    }

    func validated() throws -> Self {
        guard version == 1 else { throw RecordingWidgetError.invalid("このレイアウトの形式には対応していません。") }
        guard widgets.count <= 30, Set(widgets.map(\.id)).count == widgets.count else {
            throw RecordingWidgetError.invalid("ウィジェットは重複なく30個まで追加できます。")
        }
        for widget in widgets {
            guard !widget.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  widget.title.count <= 24, !widget.category.isEmpty,
                  widget.leadTime.isFinite, widget.lagTime.isFinite,
                  (0...120).contains(widget.leadTime), (1...120).contains(widget.lagTime) else {
                throw RecordingWidgetError.invalid("名前と時間設定を確認してください。リードは0〜120秒、ラグは1〜120秒です。")
            }
            if widget.kind == .choice && (widget.choices.isEmpty || widget.choices.count > 8) {
                throw RecordingWidgetError.invalid("選択肢は1〜8個にしてください。")
            }
            if widget.effectiveAppearance.customColorHex != nil && widget.effectiveAppearance.normalizedCustomColorHex == nil {
                throw RecordingWidgetError.invalid("色は6桁のカラーコードで指定してください。例：#2478FF")
            }
        }
        try RecordingBoardPacking.validate(widgets: widgets)
        for link in links {
            guard link.source != link.target,
                  let source = widgets.first(where: { $0.id == link.source }),
                  let target = widgets.first(where: { $0.id == link.target }),
                  source.kind.canLink, target.kind.canLink,
                  link.action == .start || target.kind != .count,
                  link.action != .exclusive || source.kind != .count else {
                throw RecordingWidgetError.invalid("連動先を確認してください。停止・どちらか一方は時間ボタンに設定します。")
            }
        }
        for widget in widgets { _ = try RecordingRuleEngine.plan(source: widget.id, layout: self) }
        return self
    }
}

struct RecordingLayoutTemplate: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let layout: RecordingLayout

    static var all: [Self] {
        [
            Self(
                id: "legacy",
                title: "従来画面ベース",
                subtitle: "従来の記録画面に近い標準構成",
                symbol: "rectangle.grid.2x2",
                layout: .legacyRecordingTemplate
            ),
            Self(
                id: "scoring",
                title: "得点中心",
                subtitle: "得点・キック・得点者を素早く記録",
                symbol: "rugbyball.fill",
                layout: .scoringTemplate
            ),
            Self(
                id: "set-piece",
                title: "セットプレー分析",
                subtitle: "ラインアウト・スクラム・場所を重視",
                symbol: "chart.bar.xaxis",
                layout: .setPieceTemplate
            ),
            Self(
                id: "defense",
                title: "守備・反則",
                subtitle: "タックル、反則、ターンオーバー向け",
                symbol: "shield.fill",
                layout: .defensiveTemplate
            ),
            Self(
                id: "video",
                title: "映像レビュー",
                subtitle: "記録後の映像確認とメモを前提にした構成",
                symbol: "play.rectangle.fill",
                layout: .videoReviewTemplate
            )
        ]
    }
}

enum RecordingWidgetError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

struct RecordingActivationPlan: Equatable {
    var start: [UUID]
    var stop: [UUID]
}

enum RecordingRuleEngine {
    // ONを一度ずつたどる。循環は増殖させず、同時ON/OFFの矛盾は保存前に拒否する。
    static func plan(source: UUID, layout: RecordingLayout) throws -> RecordingActivationPlan {
        var start = [source]
        var index = 0
        while index < start.count {
            let current = start[index]; index += 1
            for link in layout.links where link.source == current && link.action == .start {
                if !start.contains(link.target) { start.append(link.target) }
            }
        }
        var stop: [UUID] = []
        for id in start {
            for link in layout.links {
                var target: UUID?
                if link.source == id && link.action != .start { target = link.target }
                if link.action == .exclusive && link.target == id { target = link.source }
                if let target, !stop.contains(target) { stop.append(target) }
            }
        }
        guard Set(start).isDisjoint(with: Set(stop)) else {
            throw RecordingWidgetError.invalid("同じボタンを開始・停止する連動が重なっています。矢印を見直してください。")
        }
        let targets = Set(layout.widgets.filter { start.contains($0.id) && $0.kind == .possession }.map(\.timerTarget))
        guard !(targets.contains(.home) && targets.contains(.away)) else {
            throw RecordingWidgetError.invalid("HOME保持とAWAY保持を同時に開始することはできません。")
        }
        return RecordingActivationPlan(start: start, stop: stop)
    }
}

struct RecordingGridCell: Equatable {
    var column: Int
    var row: Int
    var width: Int
    var height: Int
}

enum RecordingGridPacking {
    private static let columnCount = 6

    static func cells(sizes: [RecordingWidgetSize]) -> [RecordingGridCell] {
        var occupied: Set<Int> = []
        return sizes.map { size in
            var row = 0
            while true {
                for column in 0...(columnCount - size.columns) {
                    let indices = (row..<(row + size.rows)).flatMap { r in
                        (column..<(column + size.columns)).map { r * columnCount + $0 }
                    }
                    if indices.allSatisfy({ !occupied.contains($0) }) {
                        occupied.formUnion(indices)
                        return RecordingGridCell(column: column, row: row, width: size.columns, height: size.rows)
                    }
                }
                row += 1
            }
        }
    }
}

struct RecordingClock: Codable, Equatable {
    var accumulated: Double = 0
    var startedAt: Date? = nil
    var half: Int = 0
    func elapsed(at date: Date) -> Double { accumulated + max(0, startedAt.map { date.timeIntervalSince($0) } ?? 0) }
    mutating func start(at date: Date) { if startedAt == nil { startedAt = date } }
    mutating func pause(at date: Date) { accumulated = elapsed(at: date); startedAt = nil }
}

struct RecordingActiveInterval: Codable, Identifiable, Equatable {
    var id: String
    var widgetID: UUID?
    var eventID: UUID?
    var teamID: UUID?
    var half: Int
    var startedAt: Date
    var matchStart: Double
    var endsAt: Date?
    var duration: Double?
    var origin: String?
    func remaining(at date: Date) -> Double { max(0, endsAt?.timeIntervalSince(date) ?? 0) }
    func fraction(at date: Date) -> Double { min(1, remaining(at: date) / max(0.001, duration ?? 1)) }
}

struct RecordingSession: Codable, Equatable {
    var clock = RecordingClock()
    var active: [RecordingActiveInterval] = []
    var selectedTeamID: UUID?
    var scoringFlow: RecordingScoringFlow?
    var measurementRevision: Int?
}

/// A pending score belongs to the team and clock at the original tap, not the current selection.
struct RecordingScoringFlow: Codable, Equatable, Identifiable {
    var id = UUID()
    var widget: RecordingWidgetDefinition
    var teamID: UUID
    var half: Int
    var seconds: Int
    var recordedAt: Date
    var scorerID: UUID?
    var origin: String?
    var tryID: UUID?
    var kickerID: UUID?
    var kickSeconds: Int?
    var kickHalf: Int?
    var kickRecordedAt: Date?
    var conversionID: UUID?
    var conversionDeclined = false
    /// 認定トライに変えたときの記録。通常トライとキックの記録は消して、この1件(7点)にまとめる。
    var penaltyTryID: UUID?
    var previousIntervals: [RecordingActiveInterval]
    var stoppedEventIDs: [UUID] = []
    var measurementRevision: Int
    var isComplete: Bool { conversionID != nil || conversionDeclined || penaltyTryID != nil }
}

nonisolated enum RecordingEventTimeBasis: String, Codable, Sendable {
    case halfClock
}

// Stored JSON is a value, shared by main-context and background-context readers.
nonisolated struct RecordingEventDetails: Codable, Equatable, Sendable {
    var officialPoints: Int?
    var officialScoringCategory: String?
    var relatedTryID: UUID?
    var widgetID: UUID?
    var title: String?
    var number: Double?
    var unit: String?
    var choice: String?
    var zone: Int?
    var attackUp: Bool = true
    var needsReview: Bool = false
    var note: String = ""
    var leadTime: Double = 10
    var lagTime: Double = 5
    var intervalDuration: Double?
    var videoFileName: String?
    // 試合時計と動画時刻の差。映像ごと・ハーフごとに明示して合わせる。
    var videoOffset: Double?
    // Absent on older timeline edits, whose exact fields contain video coordinates.
    var timeBasis: RecordingEventTimeBasis?
    var recordedAt: Date = Date()
}

enum RecordingFormatting {
    static func time(_ seconds: Double) -> String {
        let value = seconds.isFinite ? Int(max(0, seconds)) : 0
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
    nonisolated static func zone(_ index: Int, attackUp: Bool) -> String {
        guard (0..<9).contains(index) else { return "未入力" }
        let normalized = attackUp ? index : 8 - index
        return ["敵陣", "中央", "自陣"][normalized / 3] + "・" + ["左", "中央", "右"][normalized % 3]
    }
    static func score(category: String, outcome: String, widgetData: Data? = nil) -> Int {
        guard outcome == "success" else { return 0 }
        return ScoringRules.points(category: category, widgetData: widgetData)
    }
}
