import Foundation

@MainActor
enum MatchStatisticsRegressionChecks {
    private enum Failure: Error { case failed(String) }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.failed(message) }
    }

    static func run() throws {
        try combinesLegacyAndCurrentPossession()
        try keepsFractionalIntervalsWithoutDoubleCountingBIP()
        try resolvesLegacyRelativePossession()
        try countsPlayingTimeThroughTheFinalWhistle()
        try exportsTimerMeasurementsAndAnnotations()
        try exportsPossessionForTheCorrectTeam()
        try ordersTriesBeforeConversionsAtTheSameTime()
        print("PASS: 7 match statistics and CSV regression checks")
    }

    private static func ordersTriesBeforeConversionsAtTheSameTime() throws {
        let game = match()
        func event(_ category: String, seconds: Int, half: Int = 0, outcome: String = "success") -> StatEvent {
            StatEvent(matchID: game.id, teamID: game.homeTeamID, category: category,
                      outcome: outcome, seconds: seconds, half: half)
        }
        let earlier = event("penalty_goal", seconds: 59)
        let attempt = event("try", seconds: 60)
        let conversion = event("conversion", seconds: 60)
        let nextTry = event("try", seconds: 120)
        let failedConversion = event("conversion", seconds: 120, outcome: "fail")
        let secondHalf = event("try", seconds: 0, half: 1)
        let expected = [earlier, attempt, conversion, nextTry, failedConversion, secondHalf]
        let reversed = Array(expected.reversed()).sorted { MatchStatistics.scoringEventPrecedes($0, $1) }
        try expect(reversed.map(\.id) == expected.map(\.id),
                   "Tied TRY/CON records, including failed kicks, must remain in scoring order across halves")
        var total = 0
        let totals = reversed.map { event in
            total += event.outcome == "success" ? ScoringRules.points(category: event.category) : 0
            return total
        }
        try expect(totals == [3, 8, 10, 15, 15, 20], "Cumulative scores must show the try before its conversion")
        let tiedTry = event("try", seconds: 60)
        let forward = [attempt, tiedTry, conversion].sorted { MatchStatistics.scoringEventPrecedes($0, $1) }
        let backward = [conversion, tiedTry, attempt].sorted { MatchStatistics.scoringEventPrecedes($0, $1) }
        try expect(forward.map(\.id) == backward.map(\.id), "Equal-category ties must be independent of fetch order")
    }

    private static func match() -> Match {
        Match(tournamentID: UUID(), homeTeamID: UUID(), awayTeamID: UUID(), playedAt: Date(timeIntervalSince1970: 0))
    }

    private static func possession(
        _ match: Match, teamID: UUID? = nil, outcome: String, duration: Double, start: Double? = nil, half: Int = 0
    ) -> StatEvent {
        StatEvent(matchID: match.id, teamID: teamID, category: "possession", outcome: outcome,
                  seconds: Int(duration), startSeconds: start.map(Int.init), half: half,
                  startSecondsExact: start, durationSecondsExact: duration)
    }

    private static func combinesLegacyAndCurrentPossession() throws {
        let match = match()
        let events = [
            possession(match, outcome: "own", duration: 10),
            possession(match, outcome: "opponent", duration: 5),
            possession(match, teamID: match.homeTeamID, outcome: "own", duration: 20.5, start: 100),
            possession(match, teamID: match.awayTeamID, outcome: "own", duration: 15, start: 130),
            possession(match, outcome: "none", duration: 25, start: 100),
            possession(match, teamID: match.homeTeamID, outcome: "own", duration: 12, start: 0, half: 1),
            possession(Self.match(), outcome: "own", duration: 999)
        ]
        let first = MatchStatistics.possessionTotals(events: events, match: match, half: 0)
        try expect(first[.home] == 30.5 && first[.away] == 20, "Legacy holds remain included after recording with team IDs")
        try expect(first[.bip] == 55, "BIP includes old unlocated holds and new intervals without overlap")
        let all = MatchStatistics.possessionTotals(events: events, match: match)
        try expect(all[.home] == 42.5 && all[.bip] == 67, "Halves stay separate even when clocks both start at zero")
    }

    private static func keepsFractionalIntervalsWithoutDoubleCountingBIP() throws {
        let match = match()
        let events = [
            possession(match, teamID: match.homeTeamID, outcome: "own", duration: 0.4, start: 0),
            possession(match, teamID: match.awayTeamID, outcome: "own", duration: 0.4, start: 0.4),
            possession(match, teamID: match.homeTeamID, outcome: "own", duration: 0.4, start: 0.8),
            possession(match, outcome: "none", duration: 1.2, start: 0)
        ]
        let totals = MatchStatistics.possessionTotals(events: events, match: match)
        try expect(abs((totals[.home] ?? 0) - 0.8) < 0.000_001, "Subsecond holds accumulate even when all integer seconds are zero")
        try expect(abs((totals[.away] ?? 0) - 0.4) < 0.000_001, "The other team's short hold is preserved")
        try expect(abs((totals[.bip] ?? 0) - 1.2) < 0.000_001, "Explicit BIP does not count team intervals twice")
        let saved = MatchStatistics.possessionTotals(events: events, match: match,
            excludingBIPInterval: (half: 0, start: 0.4))
        try expect(abs((saved[.bip] ?? 0) - 0.4) < 0.000_001, "An interval crossing the running BIP start is clipped at that start")
        try expect(saved[.home] == totals[.home] && saved[.away] == totals[.away], "Excluding running BIP never hides saved team possession")
    }

    private static func resolvesLegacyRelativePossession() throws {
        let match = match()
        let events = [
            possession(match, teamID: match.homeTeamID, outcome: "opponent", duration: 7),
            possession(match, teamID: match.awayTeamID, outcome: "opponent", duration: 11),
            possession(match, teamID: match.homeTeamID, outcome: "none", duration: 0)
        ]
        let totals = MatchStatistics.possessionTotals(events: events, match: match)
        try expect(totals[.home] == 11 && totals[.away] == 7, "Legacy opponent refers to the other side of the recorded team")
        try expect(totals[.bip] == 18, "Old zero-second pause markers do not suppress possession-based BIP")
        let timelineAway = StatEvent(matchID: match.id, teamID: match.awayTeamID,
            category: "possession", outcome: "opponent", seconds: 9, startSeconds: 30)
        let exactAway = StatEvent(matchID: match.id, teamID: match.awayTeamID,
            category: "possession", outcome: "opponent", seconds: 2,
            startSecondsExact: 40, durationSecondsExact: 2.5)
        let mixed = MatchStatistics.possessionTotals(events: events + [timelineAway, exactAway], match: match)
        try expect(mixed[.home] == 11 && mixed[.away] == 18.5, "Located legacy timeline holds keep their explicit AWAY team even when outcome is opponent")
        try expect(mixed[.bip] == 29.5, "Located timeline holds coexist with the oldest unlocated records")
    }

    private static func countsPlayingTimeThroughTheFinalWhistle() throws {
        let match = match()
        let starter = UUID(), reserve = UUID()
        let lineups = [MatchLineup(matchID: match.id, teamID: match.homeTeamID, playerID: starter, role: "starter", order: 0)]
        let events = [
            StatEvent(matchID: match.id, category: "try", outcome: "success", seconds: 600),
            StatEvent(matchID: match.id, category: "match_state", outcome: "finished", seconds: 1200),
            StatEvent(matchID: match.id, category: "try", outcome: "success", seconds: 600, half: 1),
            StatEvent(matchID: match.id, category: "match_state", outcome: "finished", seconds: 2400, half: 1),
            StatEvent(matchID: UUID(), category: "match_state", outcome: "finished", seconds: 7200, half: 1)
        ]
        let substitutions = [Substitution(matchID: match.id, playerInID: reserve, playerOutID: starter, minute: 10, half: 1)]
        let result = PlayingTimeCalculator.calculate(matchID: match.id, lineups: lineups, substitutions: substitutions, events: events)
        try expect(result.totalMinutes == 60, "The final whistle, not the last try, sets the recorded match length")
        try expect(result.minutesByPlayer[starter] == 30 && result.minutesByPlayer[reserve] == 30, "Substitution playing times include time until the final whistle")
        try expect(MatchStatistics.halfEndSeconds(events: events.filter { $0.matchID == match.id }, half: 1) == 2400, "The score chart uses the same recorded endpoint")
        let unknown = PlayingTimeCalculator.calculate(matchID: match.id, lineups: [], substitutions: substitutions, events: events)
        try expect(!unknown.hasStarterInfo, "An end marker alone never invents starting lineups")
    }

    private static func exportsTimerMeasurementsAndAnnotations() throws {
        let match = match()
        let timed = StatEvent(matchID: match.id, teamID: match.homeTeamID, category: "good_tackle", outcome: "success", seconds: 10)
        var details = RecordingEventDetails()
        details.intervalDuration = 4.75
        details.title = "前へのタックル"
        details.note = "メモ,一行目\r\n\"確認\""
        timed.recordingDetails = details
        let carry = StatEvent(matchID: match.id, teamID: match.homeTeamID, category: "carry_metres", outcome: "count", seconds: 20)
        var measurement = RecordingEventDetails()
        measurement.number = -2.5
        measurement.unit = "m"
        measurement.zone = 8
        measurement.attackUp = true
        carry.recordingDetails = measurement
        let foreign = StatEvent(matchID: UUID(), category: "foreign", outcome: "success", seconds: 0)
        let finish = StatEvent(matchID: match.id, category: "match_state", outcome: "finished", seconds: 100)
        let file = MatchCSVExporter.makeFile(match: match, events: [carry, finish, timed, foreign], teams: [], players: [], tournamentName: "大会")
        let rows = parseCSV(file.csvText)
        try expect(rows.count == 3 && rows.allSatisfy { $0.count == rows[0].count }, "CSV contains two complete event rows, excludes other matches and status markers")
        let timerRow = Dictionary(uniqueKeysWithValues: zip(rows[0], rows[1]))
        let distanceRow = Dictionary(uniqueKeysWithValues: zip(rows[0], rows[2]))
        try expect(timerRow["継続秒"] == "4.75" && timerRow["カテゴリ"] == "ドミナントタックル", "Timer duration and metric label survive export")
        try expect(timerRow["メモ"] == details.note && timerRow["ウィジェット"] == details.title, "CSV preserves commas, quotes and embedded line breaks")
        try expect(distanceRow["数値"] == "-2.5" && distanceRow["単位"] == "m" && distanceRow["場所"] == "自陣・右", "Numeric and location annotations remain attached to the right row")
    }

    private static func exportsPossessionForTheCorrectTeam() throws {
        let match = match()
        let home = Team(id: match.homeTeamID, name: "HOME")
        let away = Team(id: match.awayTeamID, name: "AWAY")
        let event = possession(match, teamID: match.homeTeamID, outcome: "opponent", duration: 3.25)
        let timelineAway = StatEvent(matchID: match.id, teamID: match.awayTeamID,
            category: "possession", outcome: "opponent", seconds: 5, startSeconds: 20)
        let file = MatchCSVExporter.makeFile(match: match, events: [event, timelineAway], teams: [home, away], players: [], tournamentName: "大会")
        let rows = parseCSV(file.csvText)
        let row = Dictionary(uniqueKeysWithValues: zip(rows[0], rows[1]))
        try expect(row["チーム"] == "AWAY" && row["継続秒"] == "3.25", "CSV and on-screen totals resolve the same legacy side and exact duration")
        let timelineRow = Dictionary(uniqueKeysWithValues: zip(rows[0], rows[2]))
        try expect(timelineRow["チーム"] == "AWAY" && timelineRow["継続秒"] == "5", "CSV keeps the explicit AWAY side on located legacy timeline records")
    }

    private static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                if quoted, index + 1 < characters.count, characters[index + 1] == "\"" {
                    field.append("\"")
                    index += 1
                } else {
                    quoted.toggle()
                }
            } else if character == ",", !quoted {
                row.append(field)
                field = ""
            } else if character == "\n", !quoted {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else {
                field.append(character)
            }
            index += 1
        }
        return rows
    }
}
