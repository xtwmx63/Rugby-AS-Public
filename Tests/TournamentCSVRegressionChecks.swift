import Foundation
import SwiftData

@MainActor
enum TournamentCSVRegressionChecks {
    static func run() async throws {
        let container = try ModelContainer(for: Match.self, StatEvent.self, Team.self, Player.self, MatchLineup.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let tournamentID = UUID()
        let home = Team(name: "HOME"), away = Team(name: "AWAY")
        let player = Player(teamID: home.id, number: 99, name: "選手, \"一\"")
        let first = Match(tournamentID: tournamentID, homeTeamID: home.id, awayTeamID: away.id,
            playedAt: Date(timeIntervalSince1970: 100))
        let second = Match(tournamentID: tournamentID, homeTeamID: away.id, awayTeamID: home.id,
            playedAt: Date(timeIntervalSince1970: 200))
        let foreign = Match(tournamentID: UUID(), homeTeamID: home.id, awayTeamID: away.id, playedAt: .now)
        let lineup = MatchLineup(matchID: first.id, teamID: home.id, playerID: player.id, role: "starter", order: 0, number: 7)
        let metric = StatEvent(matchID: first.id, teamID: home.id, playerID: player.id,
            category: "carry_metres", outcome: "count", seconds: 12, half: 1)
        var details = RecordingEventDetails()
        details.number = -2.5; details.unit = "m"; details.zone = 8
        details.timeBasis = .halfClock; details.note = "行1,\"確認\"\n行2"
        metric.recordingDetails = details
        let possession = StatEvent(matchID: second.id, teamID: away.id, category: "possession", outcome: "opponent",
            seconds: 4, durationSecondsExact: 4.25)
        let unrelated = StatEvent(matchID: foreign.id, category: "foreign", outcome: "success", seconds: 1)
        let finished = StatEvent(matchID: first.id, category: "match_state", outcome: "finished", seconds: 60)
        context.insert(home); context.insert(away); context.insert(player); context.insert(lineup)
        for match in [second, foreign, first] { context.insert(match) }
        for event in [unrelated, finished, possession, metric] { context.insert(event) }
        try context.save()

        let categoryNames = RecordingMetricCatalog.titlesByCategory
        let expected = MatchCSVExporter.makeTournamentFile(tournamentName: "大会", matches: [second, first],
            events: [finished, possession, metric], teams: [home, away], players: [player], lineups: [lineup])
        let file = try await Task.detached {
            try exportOffMain(container: container, tournamentID: tournamentID, categoryNames: categoryNames)
        }.value
        try RecordingRegressionChecks.expect(file.csvText == expected.csvText && file.fileName == expected.fileName,
            "Background export preserves sorted matches, exact durations, team resolution, frozen numbers and escaped JSON details")
        try RecordingRegressionChecks.expect(!file.csvText.contains("foreign") && file.csvText.contains(",7,")
            && file.csvText.contains("キャリー距離"), "Only the selected tournament is exported with its saved numbers and metric labels")
        print("PASS: background tournament CSV matches foreground export")

        let emptyID = UUID()
        let empty = try await Task.detached {
            try exportOffMain(container: container, tournamentID: emptyID, categoryNames: categoryNames)
        }.value
        try RecordingRegressionChecks.expect(empty.csvText.split(separator: "\n").count == 1,
            "A tournament without matches exports only the header, not another tournament's events")
        print("PASS: empty tournament CSV remains scoped")
    }

    nonisolated private static func exportOffMain(container: ModelContainer, tournamentID: UUID,
                                                  categoryNames: [String: String]) throws -> MatchCSVFile {
        dispatchPrecondition(condition: .notOnQueue(.main))
        return try TournamentCSVLoader.makeFile(container: container, tournamentID: tournamentID,
            tournamentName: "大会", metricCategoryNames: categoryNames)
    }
}
