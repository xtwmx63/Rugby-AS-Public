import Foundation
import SwiftData

@MainActor
enum TeamPerformanceRegressionChecks {
    private enum Failure: Error { case failed(String) }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.failed(message) }
    }
    static func run() throws {
        let team = UUID(), opponent = UUID(), other = UUID()
        let tournament = Tournament(officialName: "年度をまたぐ大会", year: 2024)
        let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2025, month: 1, day: 5))!
        func game(_ home: UUID, _ away: UUID, tournamentID: UUID? = nil) -> Match {
            Match(tournamentID: tournamentID ?? tournament.id, homeTeamID: home, awayTeamID: away, playedAt: date)
        }
        func score(_ home: Int, _ away: Int, finished: Bool = true) -> MatchListTally {
            var tally = MatchListTally()
            tally.homeScore = home; tally.awayScore = away; tally.isFinished = finished
            return tally
        }
        let win = game(team, opponent), loss = game(opponent, team)
        let draw = game(team, other, tournamentID: UUID())
        let excluded = game(team, opponent), unfinished = game(team, opponent), unrelated = game(opponent, other)
        excluded.isExcludedFromStats = true
        let matches = [win, loss, draw, excluded, unfinished, unrelated]
        var tallies = [win.id: score(12, 7), loss.id: score(20, 5), draw.id: score(0, 0),
                       excluded.id: score(99, 0), unfinished.id: score(5, 0, finished: false), unrelated.id: score(3, 0)]
        let rows = TeamPerformance.results(teamID: team, matches: matches, tallies: tallies, tournaments: [tournament])
        try expect(rows.count == 3, "Only finished, included matches involving this team count")
        let away = rows.first { $0.id == loss.id }!
        try expect(away.pointsFor == 5 && away.pointsAgainst == 20 && away.opponentID == opponent,
                   "Away matches must be viewed from the selected team's side")
        try expect(rows.filter { $0.year == 2024 }.count == 2 && rows.first { $0.id == draw.id }?.year == 2025,
                   "Tournament year takes precedence, with calendar year as fallback")
        let summary = TeamPerformance.summary(rows)
        try expect(summary.wins == 1 && summary.draws == 1 && summary.losses == 1,
                   "A finished zero-zero match is a draw; unfinished games are excluded")
        try expect(summary.pointsFor == 17 && summary.pointsAgainst == 27 && summary.winRate == 1.0 / 3.0,
                   "Totals and win rate include draws in the denominator")
        let versus = TeamPerformance.summary(rows.filter { $0.year == 2024 && $0.opponentID == opponent })
        try expect(versus.played == 2 && versus.wins == 1 && versus.losses == 1, "Year/opponent intersection")
        tallies[win.id] = score(0, 7)
        let corrected = TeamPerformance.results(teamID: team, matches: matches, tallies: tallies, tournaments: [tournament])
        try expect(TeamPerformance.summary(corrected).wins == 0, "Score corrections must update results")
        try expect(TeamPerformance.summary([]).winRate == nil && TeamPerformance.summary([]).averageFor == nil,
                   "Empty results have no fabricated percentage or average")
        try rankingsRespectRecordedScorersAndScope()
        try conversionRankingsRespectAttemptsAndThresholds()
        print("PASS: team performance — home/away, seasons, opponents, exclusions, finished zero draw, corrections and empty scope")
    }
    private static func rankingsRespectRecordedScorersAndScope() throws {
        let container = try ModelContainer(for: Team.self, Player.self, Tournament.self, Match.self,
            StatEvent.self, MatchLineup.self, Substitution.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let team = UUID(), opponent = UUID(), matchID = UUID(), excludedID = UUID()
        let first = UUID(), tied = UUID(), third = UUID()
        func add(_ player: UUID?, _ category: String, teamID: UUID? = nil, gameID: UUID? = nil, outcome: String = "success") {
            context.insert(StatEvent(matchID: gameID ?? matchID, teamID: teamID ?? team,
                playerID: player, category: category, outcome: outcome, seconds: 0))
        }
        add(first, "try"); add(first, "conversion")
        add(tied, "try"); add(tied, "conversion")
        add(third, "penalty_goal")
        add(first, "conversion", outcome: "fail")
        add(first, "conversion", outcome: "unknown")
        add(first, "penalty_goal", outcome: "fail")
        add(first, "conversion", teamID: opponent)
        add(first, "try", teamID: opponent)
        add(first, "try", gameID: excludedID)
        add(nil, "try")
        add(first, "penalty_try") // Even if a stale playerID exists, penalty tries are team points.
        try context.save()
        let entries = try TeamPerformance.loadScorers(container: container, teamID: team, matchIDs: [matchID, excludedID])
        let points = TeamPerformance.standings(entries: entries, matchIDs: [matchID], metric: .points)
        try expect(points.map(\.value) == [7, 7, 3] && points.map(\.rank) == [1, 1, 3],
                   "Rankings keep ties and exclude opponents, unsuccessful kicks, unknown scorers, penalty tries and out-of-scope matches")
        let tries = TeamPerformance.standings(entries: entries, matchIDs: [matchID], metric: .tries)
        try expect(tries.count == 2 && tries.allSatisfy { $0.value == 1 && $0.rank == 1 },
                   "Try ranking counts tries only, with equal ranks")
        try expect(entries.filter { $0.playerID == nil }.reduce(0) { $0 + $1.points } == 12,
                   "Unknown scorer and penalty try points remain available for coverage disclosure")
        try expect(TeamPerformance.standings(entries: entries, matchIDs: [], metric: .points).isEmpty,
                   "An empty selected scope must not leak scorer values")
        let narrower = try TeamPerformance.loadScorers(container: container, teamID: team, matchIDs: [matchID])
        try expect(narrower.allSatisfy { $0.matchID == matchID }, "Scorer fetch is limited to requested matches")
        let conversions = TeamPerformance.standings(entries: entries, matchIDs: [matchID], metric: .conversions)
        try expect(conversions.count == 2 && conversions.allSatisfy { $0.value == 1 && $0.rank == 1 },
                   "Only successful conversions count toward the success ranking")
        let rates = TeamPerformance.standings(entries: entries, matchIDs: [matchID], metric: .conversionRate,
                                             minimumConversionAttempts: 1)
        try expect(rates.map(\.playerID) == [tied, first] && rates.map(\.conversionAttempts) == [1, 2] &&
                   rates.map(\.conversionRate) == [1, 0.5], "Failed conversions contribute to attempts, never points")
        let stored = try context.fetch(FetchDescriptor<StatEvent>())
        let corrected = stored.first { $0.playerID == first && $0.teamID == team && $0.category == "conversion" && $0.outcome == "success" }!
        corrected.outcome = "fail"
        try context.save()
        let revised = try TeamPerformance.loadScorers(container: container, teamID: team, matchIDs: [matchID])
        let revisedRates = TeamPerformance.standings(entries: revised, matchIDs: [matchID], metric: .conversionRate,
                                                    minimumConversionAttempts: 1)
        try expect(revisedRates.first { $0.playerID == first }?.conversionRate == 0 &&
                   revisedRates.first { $0.playerID == first }?.conversionAttempts == 2,
                   "Correcting a successful kick recomputes the rate without changing its attempt count")
    }

    private static func conversionRankingsRespectAttemptsAndThresholds() throws {
        let game = UUID(), otherGame = UUID()
        let first = UUID(), tied = UUID(), lower = UUID(), zero = UUID(), short = UUID()
        func entry(_ player: UUID?, _ made: Int, _ taken: Int, gameID: UUID? = nil) -> TeamPerformance.ScoringEntry {
            .init(matchID: gameID ?? game, playerID: player, points: made * 2, tries: 0,
                  conversions: made, conversionAttempts: taken)
        }
        let entries = [entry(first, 4, 6), entry(tied, 2, 3), entry(lower, 3, 5),
                       entry(zero, 0, 5), entry(short, 1, 1), entry(nil, 10, 10),
                       entry(zero, 50, 50, gameID: otherGame)]
        let rates = TeamPerformance.standings(entries: entries, matchIDs: [game], metric: .conversionRate,
                                             minimumConversionAttempts: 3)
        try expect(rates.map(\.playerID) == [first, tied, lower, zero] && rates.map(\.rank) == [1, 1, 3, 4],
                   "Equal rates share rank and sort by attempts; short/unknown/out-of-scope records are excluded and 0% remains eligible")
        let stricter = TeamPerformance.standings(entries: entries, matchIDs: [game], metric: .conversionRate,
                                                minimumConversionAttempts: 5)
        try expect(stricter.map(\.playerID) == [first, lower, zero], "Threshold includes its boundary and changes eligibility")
        try expect(TeamPerformance.standings(entries: entries, matchIDs: [game], metric: .conversionRate,
                                             minimumConversionAttempts: 7).isEmpty, "Threshold can produce an empty ranking")
        try expect(TeamPerformance.standings(entries: entries, matchIDs: [], metric: .conversionRate,
                                             minimumConversionAttempts: 1).isEmpty, "Rate ranking respects the selected match scope")
        let almost = UUID(), exact = UUID()
        let closeRates = TeamPerformance.standings(entries: [entry(almost, 333, 500), entry(exact, 2, 3)],
                                                   matchIDs: [game], metric: .conversionRate, minimumConversionAttempts: 1)
        try expect(closeRates.map(\.playerID) == [exact, almost] && closeRates.map(\.rank) == [1, 2],
                   "Ranking uses exact rates, not rounded display percentages")
    }

}
