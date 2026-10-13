import Foundation
import SwiftData

/// チームの向きにそろえた試合結果。集計値は保存せず、得点記録から毎回作る。
enum TeamPerformance {
    struct Result: Identifiable {
        let match: Match
        let opponentID: UUID
        let year: Int
        let pointsFor: Int
        let pointsAgainst: Int
        var id: UUID { match.id }
        var outcome: String { pointsFor > pointsAgainst ? "勝ち" : pointsFor < pointsAgainst ? "負け" : "引分" }
    }

    struct Summary {
        let played: Int
        let wins: Int
        let draws: Int
        let losses: Int
        let pointsFor: Int
        let pointsAgainst: Int
        var winRate: Double? { played == 0 ? nil : Double(wins) / Double(played) }
        var averageFor: Double? { played == 0 ? nil : Double(pointsFor) / Double(played) }
        var averageAgainst: Double? { played == 0 ? nil : Double(pointsAgainst) / Double(played) }
    }

    static func results(teamID: UUID, matches: [Match], tallies: [UUID: MatchListTally],
                        tournaments: [Tournament]) -> [Result] {
        let years = Dictionary(tournaments.compactMap { tournament in
            tournament.year.map { (tournament.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
        let calendar = Calendar(identifier: .gregorian)
        return matches.compactMap { match in
            guard !match.isExcludedFromStats,
                  match.homeTeamID == teamID || match.awayTeamID == teamID,
                  let tally = tallies[match.id], tally.isFinished else { return nil }
            let isHome = match.homeTeamID == teamID
            return Result(match: match, opponentID: isHome ? match.awayTeamID : match.homeTeamID,
                          year: years[match.tournamentID] ?? calendar.component(.year, from: match.playedAt),
                          pointsFor: isHome ? tally.homeScore : tally.awayScore,
                          pointsAgainst: isHome ? tally.awayScore : tally.homeScore)
        }.sorted {
            if $0.match.playedAt != $1.match.playedAt { return $0.match.playedAt > $1.match.playedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    static func summary(_ results: [Result]) -> Summary {
        Summary(played: results.count,
                wins: results.filter { $0.pointsFor > $0.pointsAgainst }.count,
                draws: results.filter { $0.pointsFor == $0.pointsAgainst }.count,
                losses: results.filter { $0.pointsFor < $0.pointsAgainst }.count,
                pointsFor: results.reduce(0) { $0 + $1.pointsFor },
                pointsAgainst: results.reduce(0) { $0 + $1.pointsAgainst })
    }
}

extension TeamPerformance {
    nonisolated static func loadScorers(container: ModelContainer, teamID: UUID, matchIDs: Set<UUID>) throws -> [ScoringEntry] {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let categories = ScoringRules.categories
        var descriptor = FetchDescriptor<StatEvent>(predicate: #Predicate {
            $0.teamID == teamID && categories.contains($0.category)
        })
        descriptor.propertiesToFetch = [\.matchID, \.playerID, \.category, \.outcome, \.widgetData]
        var entries: [ScoringEntry] = []
        try context.enumerate(descriptor, batchSize: 500) { event in
            try Task.checkCancellation()
            guard matchIDs.contains(event.matchID),
                  event.outcome == "success" || (event.category == "conversion" && event.outcome == "fail") else { return }
            entries.append(ScoringEntry(matchID: event.matchID,
                                        playerID: event.category == "penalty_try" ? nil : event.playerID,
                                        points: event.outcome == "success" ? ScoringRules.points(category: event.category, widgetData: event.widgetData) : 0,
                                        tries: event.category == "try" ? 1 : 0,
                                        conversions: event.category == "conversion" && event.outcome == "success" ? 1 : 0,
                                        conversionAttempts: event.category == "conversion" ? 1 : 0))
        }
        return entries
    }
    struct ScoringEntry: Sendable {
        let matchID: UUID
        let playerID: UUID?
        let points: Int
        let tries: Int
        let conversions: Int
        let conversionAttempts: Int
        nonisolated init(matchID: UUID, playerID: UUID?, points: Int, tries: Int,
                         conversions: Int = 0, conversionAttempts: Int = 0) {
            self.matchID = matchID; self.playerID = playerID; self.points = points; self.tries = tries
            self.conversions = conversions; self.conversionAttempts = conversionAttempts
        }
    }
    enum RankingMetric: String, CaseIterable {
        case points = "得点", tries = "トライ"
        case conversions = "コンバージョン成功数", conversionRate = "コンバージョン成功率"
        var unit: String {
            switch self {
            case .points: "点"
            case .tries: "T"
            case .conversions: "本"
            case .conversionRate: "%"
            }
        }
    }
    struct PlayerStanding: Identifiable {
        let playerID: UUID
        let value: Int
        let rank: Int
        let conversions: Int
        let conversionAttempts: Int
        var conversionRate: Double? {
            conversionAttempts > 0 ? Double(conversions) / Double(conversionAttempts) : nil
        }
        var id: UUID { playerID }
    }
    /// 選択範囲の試合だけを集計。同数は同順位、次順位は人数分進める。
    static func standings(entries: [ScoringEntry], matchIDs: Set<UUID>, metric: RankingMetric,
                          minimumConversionAttempts: Int = 5) -> [PlayerStanding] {
        struct Totals {
            var points = 0, tries = 0, conversions = 0, attempts = 0
            func value(_ metric: RankingMetric) -> Int {
                switch metric {
                case .points: points
                case .tries: tries
                case .conversions: conversions
                case .conversionRate: attempts > 0 ? Int((Double(conversions) / Double(attempts) * 100).rounded()) : 0
                }
            }
        }
        var totals: [UUID: Totals] = [:]
        for entry in entries where matchIDs.contains(entry.matchID) {
            guard let playerID = entry.playerID else { continue }
            totals[playerID, default: Totals()].points += entry.points
            totals[playerID, default: Totals()].tries += entry.tries
            totals[playerID, default: Totals()].conversions += entry.conversions
            totals[playerID, default: Totals()].attempts += entry.conversionAttempts
        }
        let ordered = totals.filter {
            metric == .conversionRate ? $0.value.attempts >= max(1, minimumConversionAttempts) : $0.value.value(metric) > 0
        }.sorted {
            if metric == .conversionRate {
                let lhs = $0.value.conversions * $1.value.attempts
                let rhs = $1.value.conversions * $0.value.attempts
                if lhs != rhs { return lhs > rhs }
                if $0.value.attempts != $1.value.attempts { return $0.value.attempts > $1.value.attempts }
            } else if $0.value.value(metric) != $1.value.value(metric) {
                return $0.value.value(metric) > $1.value.value(metric)
            }
            return $0.key.uuidString < $1.key.uuidString
        }
        var previous: Totals?, rank = 0
        return ordered.enumerated().map { index, element in
            let total = element.value
            let tied = previous.map {
                metric == .conversionRate
                    ? total.conversions * $0.attempts == $0.conversions * total.attempts
                    : total.value(metric) == $0.value(metric)
            } ?? false
            if !tied { rank = index + 1 }
            previous = total
            return PlayerStanding(playerID: element.key, value: total.value(metric), rank: rank,
                                  conversions: total.conversions, conversionAttempts: total.attempts)
        }
    }
}
