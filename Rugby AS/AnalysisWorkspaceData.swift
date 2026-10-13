//
//  AnalysisWorkspaceData.swift
//  Rugby AS
//
//  分析画面の計算。公式記録の取り込みで記録が数十万件になっても画面が固まらないよう、
//  裏の作業場所(actor)で読み込んで集計し、画面には表示に要る値だけを返す。
//  読み込んだ記録は控えておき、データが保存されたときだけ読み直す
//  (条件を変えるたびに全記録を読み直すと、そのたびに数秒待たされるため)。
//  集計の中身は以前と同じ部品(AnalysisScope・AnalysisComparison・RecordingMetricAggregation)を使う。
//

import Combine
import Foundation
import SwiftData

/// 画面から計算に渡す条件
nonisolated struct AnalysisWorkspaceRequest: Equatable, Sendable {
    var scope: AnalysisScope
    /// 画面で選んだ指標(空なら最初の指標)
    var category: String
    /// 指標の並び順(標準の指標の種類。表示用の部品は除いてある)
    var templateCategories: [String]
}

/// 記録がある指標(選択肢の一覧を作るのに使う)
nonisolated struct AnalysisMetricChoices: Sendable {
    /// 標準にない指標の、最初の記録(指標の名前と並びを決めるのに使う)
    struct CategorySample: Sendable, Equatable {
        let category: String
        let eventID: UUID
        let customTitle: String?
    }
    /// 記録がある標準の指標の種類
    var presentTemplateCategories: Set<String> = []
    var customSamples: [CategorySample] = []
}

extension AnalysisMetricChoices {
    /// 標準の指標の種類(表示用の部品は除く)。指標の並び順に使う
    static let templateCategories: [String] = {
        var seen = Set<String>()
        return RecordingMetricCatalog.templates.map(\.widget)
            .filter { !$0.kind.isDisplay && seen.insert($0.category).inserted }
            .map(\.category)
    }()

    /// 指標の一覧(以前の AnalysisComparison.definitions と同じ並び・同じ名前)
    var definitions: [RecordingWidgetDefinition] {
        var seen = Set<String>()
        var definitions = RecordingMetricCatalog.templates.map(\.widget).filter {
            presentTemplateCategories.contains($0.category) && !$0.kind.isDisplay && seen.insert($0.category).inserted
        }
        for sample in customSamples where seen.insert(sample.category).inserted {
            var value = RecordingWidgetDefinition.make(.count)
            value.id = sample.eventID; value.category = sample.category
            value.title = StatEvent.recordingTitle(category: sample.category, customTitle: sample.customTitle)
            definitions.append(value)
        }
        return definitions
    }
}

/// マイ分析レポートの集計結果(指標ごとの値だけ)
nonisolated struct AnalysisReportData: Sendable {
    var choices = AnalysisMetricChoices()
    var selectedCount = 0
    var summaries: [String: RecordingMetricSummary] = [:]
    var matchCounts: [String: Int] = [:]

    var snapshot: AnalysisMetricSnapshot { AnalysisMetricSnapshot(summaries: summaries, matchCounts: matchCounts) }
}

/// 計算結果。画面に出す値だけを持つ
nonisolated struct AnalysisWorkspaceResult: Sendable {
    struct MatchItem: Sendable, Identifiable {
        let id: UUID
        let playedAt: Date
        let title: String
        let isExcluded: Bool
    }
    struct MatchRow: Sendable, Identifiable {
        let id: UUID
        let playedAt: Date
        let title: String
        let summary: RecordingMetricSummary
    }
    struct PlayerRow: Sendable, Identifiable {
        let id: UUID
        let name: String
        let summary: RecordingMetricSummary
    }

    /// 比較の一覧・グラフに出す試合・選手の上限(新しい順・多い順に絞る)。
    /// 表に出ない分まで集計すると、試合2万・選手1万を超えたときに条件を変えるたび数秒かかるため、ここまでしか計算しない
    static let shownMatchLimit = 50
    static let shownPlayerLimit = 100

    var choices = AnalysisMetricChoices()
    var selectedCategory = ""
    var selectedCount = 0
    var overall = RecordingMetricAggregation.summary(events: [AnalysisEventRow](), category: "")
    /// 対象の試合ごとの記録(新しい順・最大 shownMatchLimit 試合。全部で何試合かは selectedCount)
    var matchRows: [MatchRow] = []
    /// 選手ごとの記録(多い順・最大 shownPlayerLimit 人)
    var playerRows: [PlayerRow] = []
    /// 選手別の行が全部で何人分あるか
    var playerTotal = 0
    var unassignedCount = 0
    var excludedCount = 0
    /// 「対象試合を選ぶ」の一覧(新しい順)
    var allMatches: [MatchItem] = []
}

/// SwiftData の @ModelActor は使わない。@ModelActor は(裏で作っても)メインスレッドで動くことがあり、
/// そうなると集計の間アプリ全体が固まる。ふつうの actor にして、呼ばれるたびに専用の ModelContext を作って読む
/// (公式記録の取り込み・大会CSVなど、ほかの裏の処理と同じやり方)。
actor AnalysisWorkspaceLoader {
    nonisolated let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// 読み込んだデータの控え。保存の合図で捨てて、次の計算で読み直す
    private struct Loaded {
        let matches: [AnalysisMatchRow]
        let events: [AnalysisEventRow]
        let teamNames: [UUID: String]
        let presentCategories: Set<String>
        let firstEventByCategory: [(category: String, event: AnalysisEventRow)]
        let allMatches: [AnalysisWorkspaceResult.MatchItem]
    }

    private var loaded: Loaded?

    func invalidate() {
        loaded = nil
    }

    func compute(_ request: AnalysisWorkspaceRequest) throws -> AnalysisWorkspaceResult {
        let modelContext = ModelContext(modelContainer)
        let data = try loadIfNeeded(modelContext)
        try Task.checkCancellation()
        let scope = request.scope

        // 選手で絞るときだけ、その選手のメンバー表の行を読む(全行は読まない)
        var lineups: [MatchLineup] = []
        if let playerID = UUID(uuidString: scope.filter.player) {
            lineups = try modelContext.fetch(FetchDescriptor<MatchLineup>(predicate: #Predicate { $0.playerID == playerID }))
        }

        let selected = scope.selectedMatches(from: data.matches, events: data.events, lineups: lineups,
                                             tournaments: try Self.tournaments(for: scope, in: modelContext))
        try Task.checkCancellation()
        let filtered = scope.selectedEvents(from: data.events, matches: selected)

        // 指標の並びは、標準の指標(決まった順) → それ以外(記録に出てきた順)
        let choices = Self.choices(data, templateCategories: request.templateCategories)
        let firstCategory = request.templateCategories.first { choices.presentTemplateCategories.contains($0) }
            ?? choices.customSamples.first?.category ?? ""
        let selectedCategory = !scope.filter.category.isEmpty ? scope.filter.category
            : request.category.isEmpty ? firstCategory : request.category

        let categoryEvents = filtered.filter { $0.category == selectedCategory }
        // 表に出す分だけ集計する(試合は新しい順、選手は記録の多い順に上限まで)
        let matchRows = AnalysisComparison.matchRows(
            matches: Array(selected.prefix(AnalysisWorkspaceResult.shownMatchLimit)),
            events: categoryEvents, category: selectedCategory)
        let (playerRows, playerTotal) = AnalysisComparison.topPlayerRows(
            events: categoryEvents, category: selectedCategory, limit: AnalysisWorkspaceResult.shownPlayerLimit)
        try Task.checkCancellation()

        // 選手名は、表に出る選手だけ読む
        let playerIDs = playerRows.map(\.id)
        let players = playerIDs.isEmpty ? [] : try modelContext.fetch(FetchDescriptor<Player>(
            predicate: #Predicate { playerIDs.contains($0.id) }))
        let playersByID = Dictionary(players.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let matchesByID = Dictionary(selected.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var result = AnalysisWorkspaceResult()
        result.choices = choices
        result.selectedCategory = selectedCategory
        result.selectedCount = selected.count
        result.overall = RecordingMetricAggregation.summary(events: categoryEvents, category: selectedCategory)
        result.matchRows = matchRows.compactMap { row in
            matchesByID[row.id].map {
                AnalysisWorkspaceResult.MatchRow(id: row.id, playedAt: $0.playedAt,
                                                 title: Self.matchTitle($0, teamNames: data.teamNames), summary: row.summary)
            }
        }
        result.playerRows = playerRows.map { row in
            let name: String
            if let player = playersByID[row.id] {
                name = (player.name ?? player.number.map { "#\($0)" } ?? "名前未設定") + " · "
                    + (data.teamNames[player.teamID] ?? "チーム未設定")
            } else {
                name = "選手未設定"
            }
            return AnalysisWorkspaceResult.PlayerRow(id: row.id, name: name, summary: row.summary)
        }
        result.playerTotal = playerTotal
        result.unassignedCount = categoryEvents.lazy.filter { $0.playerID == nil }.count
        result.excludedCount = data.matches.lazy.filter(\.isExcludedFromStats).count
        result.allMatches = data.allMatches
        return result
    }

    /// マイ分析レポート: 条件に合う記録を、指標ごとに集計する
    func report(_ scope: AnalysisScope, templateCategories: [String]) throws -> AnalysisReportData {
        let modelContext = ModelContext(modelContainer)
        let data = try loadIfNeeded(modelContext)
        var lineups: [MatchLineup] = []
        if let playerID = UUID(uuidString: scope.filter.player) {
            lineups = try modelContext.fetch(FetchDescriptor<MatchLineup>(predicate: #Predicate { $0.playerID == playerID }))
        }
        let selected = scope.selectedMatches(from: data.matches, events: data.events, lineups: lineups,
                                             tournaments: try Self.tournaments(for: scope, in: modelContext))
        try Task.checkCancellation()
        let snapshot = AnalysisMetricSnapshot(records: scope.selectedEvents(from: data.events, matches: selected))
        return AnalysisReportData(choices: Self.choices(data, templateCategories: templateCategories),
                                  selectedCount: selected.count,
                                  summaries: snapshot.allSummaries, matchCounts: snapshot.allMatchCounts)
    }

    private static func choices(_ data: Loaded, templateCategories: [String]) -> AnalysisMetricChoices {
        let templateSet = Set(templateCategories.filter { data.presentCategories.contains($0) })
        let customSamples = data.firstEventByCategory
            .filter { !templateSet.contains($0.category) }
            .map { AnalysisMetricChoices.CategorySample(category: $0.category, eventID: $0.event.id,
                                                        customTitle: $0.event.recordingDetails.title) }
        return AnalysisMetricChoices(presentTemplateCategories: templateSet, customSamples: customSamples)
    }

    /// 男子/女子・カテゴリーなどで絞るときだけ大会を読む(大会は保存した Match などと違い、値を控えずに毎回読む)
    private static func tournaments(for scope: AnalysisScope, in context: ModelContext) throws -> [Tournament] {
        guard scope.competition?.isActive == true else { return [] }
        return try context.fetch(FetchDescriptor<Tournament>())
    }

    private func loadIfNeeded(_ modelContext: ModelContext) throws -> Loaded {
        if let loaded { return loaded }
        // 試合は値だけ写して持つ(条件を変えるたびに2万件の Match から値を読むと遅いため)
        let matches = try modelContext.fetch(FetchDescriptor<Match>(sortBy: [SortDescriptor(\.playedAt, order: .reverse)]))
            .map(AnalysisMatchRow.init)
        // 試合終了の印とポゼッションは、指標にも比較にも使わないので読まない。
        // 保存先のファイルから値だけを直接読む(StatEvent を24万件作ると約10秒かかるため)。読めなければ今までの読み方
        let events: [AnalysisEventRow]
        if let rows = StoreFileReader.analysisRows(storeURL: modelContainer.configurations.first?.url) {
            events = rows
        } else {
            events = try modelContext.fetch(FetchDescriptor<StatEvent>(predicate: #Predicate {
                $0.category != "match_state" && $0.category != "possession"
            })).map(AnalysisEventRow.init)
        }
        let teamNames = Dictionary(try modelContext.fetch(FetchDescriptor<Team>()).map { ($0.id, $0.name) },
                                   uniquingKeysWith: { first, _ in first })
        var present = Set<String>()
        var firsts: [(category: String, event: AnalysisEventRow)] = []
        for event in events where present.insert(event.category).inserted {
            firsts.append((event.category, event))
        }
        let items = matches.map {
            AnalysisWorkspaceResult.MatchItem(id: $0.id, playedAt: $0.playedAt,
                                              title: Self.matchTitle($0, teamNames: teamNames),
                                              isExcluded: $0.isExcludedFromStats)
        }
        let value = Loaded(matches: matches, events: events, teamNames: teamNames,
                           presentCategories: present, firstEventByCategory: firsts, allMatches: items)
        loaded = value
        return value
    }

    private static func matchTitle(_ match: some AnalysisMatchRecord, teamNames: [UUID: String]) -> String {
        (teamNames[match.homeTeamID] ?? "チーム未設定") + " vs " + (teamNames[match.awayTeamID] ?? "チーム未設定")
    }
}

/// 分析の集計係は、アプリ全体で1つだけ使う(画面を開き直すたびに全記録を読み直さないため)。
@MainActor
enum AnalysisLoaderStore {
    private static var current: (container: ModelContainer, loader: AnalysisWorkspaceLoader)?
    private static var saveObserver: AnyCancellable?

    static func loader(for container: ModelContainer) -> AnalysisWorkspaceLoader {
        if let current, current.container === container { return current.loader }
        let created = AnalysisWorkspaceLoader(modelContainer: container)
        current = (container, created)
        // 分析の画面が開いていないときに保存されても、次に開いたとき読み直すようにする
        saveObserver = ModelSaveSignal.didSave.sink { _ in
            Task { await created.invalidate() }
        }
        return created
    }
}
