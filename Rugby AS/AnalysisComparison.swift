import Foundation

/// 分析が読む「試合」の形。保存されている試合(Match)そのものでも、値だけ写した軽い試合(AnalysisMatchRow)でも、
/// 同じ絞り込みに通せるようにする(2万試合あると、Match の値を読むだけで条件を変えるたびに時間がかかるため)
nonisolated protocol AnalysisMatchRecord {
    var id: UUID { get }
    var tournamentID: UUID { get }
    var homeTeamID: UUID { get }
    var awayTeamID: UUID { get }
    var playedAt: Date { get }
    var isExcludedFromStats: Bool { get }
}

nonisolated extension Match: AnalysisMatchRecord {}

/// 分析用の軽い試合。値だけを持つ
nonisolated struct AnalysisMatchRow: AnalysisMatchRecord, Sendable {
    let id: UUID
    let tournamentID: UUID
    let homeTeamID: UUID
    let awayTeamID: UUID
    let playedAt: Date
    let isExcludedFromStats: Bool

    init(_ match: Match) {
        id = match.id; tournamentID = match.tournamentID
        homeTeamID = match.homeTeamID; awayTeamID = match.awayTeamID
        playedAt = match.playedAt; isExcludedFromStats = match.isExcludedFromStats
    }
}

// 分析の計算は裏でも行うので、画面に縛られない値として作る
nonisolated struct AnalysisScope: Codable, Equatable, Sendable {
    var tournamentID: UUID?
    var recentLimit = 0
    var matchIDs: Set<UUID> = []
    var filter = RecordingAnalysisFilter()
    // 男子/女子・カテゴリー(トップ・大学など)・7人制/15人制。後から足した項目なので、保存済みの分析では nil
    var competition: CompetitionFilter?

    func selectedMatches<M: AnalysisMatchRecord, E: AnalysisEventRecord>(from matches: [M], events: [E], lineups: [MatchLineup],
                         tournaments: [Tournament] = []) -> [M] {
        var competitionTournamentIDs: Set<UUID>?
        if let competition, competition.isActive {
            competitionTournamentIDs = Set(tournaments
                .filter { competition.matches($0) }
                .map(\.id))
        }
        let playerID = UUID(uuidString: filter.player)
        var playerMatches = Set<UUID>()
        if let playerID {
            for event in events where event.playerID == playerID { playerMatches.insert(event.matchID) }
            for lineup in lineups where lineup.playerID == playerID { playerMatches.insert(lineup.matchID) }
        }
        let selected = matches.filter { match in
            !match.isExcludedFromStats   // 集計対象外の試合は、どの条件でも分析に入れない
            && (tournamentID == nil || match.tournamentID == tournamentID)
            && (competitionTournamentIDs.map { $0.contains(match.tournamentID) } ?? true)
            && (filter.teamID == nil || match.homeTeamID == filter.teamID || match.awayTeamID == filter.teamID)
            && (matchIDs.isEmpty || matchIDs.contains(match.id))
            && (playerID == nil || playerMatches.contains(match.id))
        }.sorted { $0.playedAt == $1.playedAt ? $0.id.uuidString < $1.id.uuidString : $0.playedAt > $1.playedAt }
        return recentLimit > 0 ? Array(selected.prefix(recentLimit)) : selected
    }

    func selectedEvents<E: AnalysisEventRecord, M: AnalysisMatchRecord>(from events: [E], matches: [M]) -> [E] {
        let ids = Set(matches.map(\.id))
        let prepared = filter.prepared()
        return events.filter { ids.contains($0.matchID) && prepared.matches($0, matchID: $0.matchID) }
    }
}

nonisolated struct AnalysisComparisonRow: Identifiable, Sendable {
    let id: UUID
    let summary: RecordingMetricSummary
}

enum AnalysisComparison {
    /// topPlayerRows の並べ替え用
    private nonisolated struct RankedPlayer { let id: UUID; let count: Int; let key: String }

    nonisolated static func matchRows<E: AnalysisEventRecord, M: AnalysisMatchRecord>(matches: [M], events: [E], category: String) -> [AnalysisComparisonRow] {
        // 並べる試合の記録だけを分ける(全記録を試合ごとに分けると、記録が多いとき遅いため)
        let ids = Set(matches.map(\.id))
        var groups: [UUID: [E]] = [:]
        for event in events where ids.contains(event.matchID) { groups[event.matchID, default: []].append(event) }
        return matches.map { AnalysisComparisonRow(id: $0.id,
            summary: RecordingMetricAggregation.summary(events: groups[$0.id] ?? [], category: category)) }
    }

    nonisolated static func playerRows<E: AnalysisEventRecord>(events: [E], category: String) -> [AnalysisComparisonRow] {
        let grouped = Dictionary(grouping: events.filter { $0.category == category && $0.playerID != nil }, by: { $0.playerID! })
        return grouped.map { AnalysisComparisonRow(id: $0.key,
            summary: RecordingMetricAggregation.summary(events: $0.value, category: category)) }
            .sorted { $0.summary.count == $1.summary.count ? $0.id.uuidString < $1.id.uuidString : $0.summary.count > $1.summary.count }
    }

    /// playerRows と同じ並びの先頭 limit 人だけを集計する(選手が1万人を超えても、表に出す人数ぶんだけ計算する)。
    /// total は選手別の行が全部で何人分あるか
    nonisolated static func topPlayerRows<E: AnalysisEventRecord>(events: [E], category: String, limit: Int)
        -> (rows: [AnalysisComparisonRow], total: Int) {
        var grouped: [UUID: [E]] = [:]
        for event in events where event.category == category {
            if let playerID = event.playerID { grouped[playerID, default: []].append(event) }
        }
        // 並びは記録数の多い順、同数なら ID の文字列順(playerRows と同じ)
        let ranked: [RankedPlayer] = grouped.map { RankedPlayer(id: $0.key, count: $0.value.count, key: $0.key.uuidString) }
            .sorted { (a: RankedPlayer, b: RankedPlayer) -> Bool in a.count == b.count ? a.key < b.key : a.count > b.count }
        let rows: [AnalysisComparisonRow] = ranked.prefix(max(limit, 0)).map { entry in
            AnalysisComparisonRow(id: entry.id,
                                  summary: RecordingMetricAggregation.summary(events: grouped[entry.id] ?? [], category: category))
        }
        return (rows, ranked.count)
    }

    static func definitions(events: [StatEvent], preferred: [RecordingWidgetDefinition] = [], boardOnly: Bool = false) -> [RecordingWidgetDefinition] {
        var seen = Set<String>()
        let categories = Set(events.map(\.category)).subtracting(["possession", "match_state"])
        var definitions = (preferred + RecordingMetricCatalog.templates.map(\.widget)).filter {
            categories.contains($0.category)
                && (boardOnly
                    ? !$0.attachesToLatest && ![.possession, .player, .zone, .note, .leader, .clip, .teamBadge, .matchClock, .scoreboard].contains($0.kind)
                    : !$0.kind.isDisplay)
                && seen.insert($0.category).inserted
        }
        // Only one definition per missing category is needed. Reusing the
        // recorded ID keeps custom rows stable across SwiftUI updates.
        for event in events where categories.contains(event.category) && seen.insert(event.category).inserted {
            var value = RecordingWidgetDefinition.make(.count)
            value.id = event.id; value.category = event.category; value.title = event.recordingTitle
            definitions.append(value)
        }
        return definitions
    }
}

/// Shared by visible rows and exports so adding more metrics does not rescan
/// all matches and apply the same conditions once for each metric.
nonisolated struct AnalysisMetricSnapshot {
    let eventsByCategory: [String: [StatEvent]]
    private let summaries: [String: RecordingMetricSummary]
    private let matchCounts: [String: Int]
    private static let empty = RecordingMetricAggregation.summary(events: [AnalysisEventRow](), category: "")

    init(events: [StatEvent]) {
        let grouped = Dictionary(grouping: events, by: \.category)
        eventsByCategory = grouped
        summaries = grouped.mapValues { events in
            RecordingMetricAggregation.summary(events: events, category: events[0].category)
        }
        matchCounts = grouped.mapValues { Set($0.map(\.matchID)).count }
    }

    /// 軽い記録から集計だけ作る(eventsByCategory は空になる)
    init<E: AnalysisEventRecord>(records: [E]) {
        let grouped = Dictionary(grouping: records, by: \.category)
        eventsByCategory = [:]
        summaries = grouped.mapValues { events in
            RecordingMetricAggregation.summary(events: events, category: events[0].category)
        }
        matchCounts = grouped.mapValues { Set($0.map(\.matchID)).count }
    }

    /// 裏で集計した値から作る(画面に記録そのものは渡さないとき。eventsByCategory は空になる)
    init(summaries: [String: RecordingMetricSummary], matchCounts: [String: Int]) {
        eventsByCategory = [:]
        self.summaries = summaries
        self.matchCounts = matchCounts
    }

    var allSummaries: [String: RecordingMetricSummary] { summaries }
    var allMatchCounts: [String: Int] { matchCounts }

    func summary(for category: String) -> RecordingMetricSummary { summaries[category] ?? Self.empty }
    func recordedMatchCount(for category: String) -> Int { matchCounts[category] ?? 0 }
}
