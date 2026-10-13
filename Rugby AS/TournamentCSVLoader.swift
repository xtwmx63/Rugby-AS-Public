import Foundation
import SwiftData

enum TournamentCSVLoader {
    // The context and every fetched model stay on this synchronous worker.
    // Only the finished file's name and text leave it.
    nonisolated static func makeFile(
        container: ModelContainer,
        tournamentID: UUID,
        tournamentName: String,
        metricCategoryNames: [String: String]
    ) throws -> MatchCSVFile {
        try Task.checkCancellation()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        // 集計対象外にした試合は大会CSVに含めない
        let matches = try context.fetch(FetchDescriptor<Match>(
            predicate: #Predicate { $0.tournamentID == tournamentID && $0.isExcludedFromStats == false }
        ))
        let matchIDs = matches.map(\.id)
        let events = try context.fetch(FetchDescriptor<StatEvent>(
            predicate: #Predicate { matchIDs.contains($0.matchID) }
        ))
        let lineups = try context.fetch(FetchDescriptor<MatchLineup>(
            predicate: #Predicate { matchIDs.contains($0.matchID) }
        ))
        let teams = try context.fetch(FetchDescriptor<Team>())
        let players = try context.fetch(FetchDescriptor<Player>())
        try Task.checkCancellation()
        return MatchCSVExporter.makeTournamentFile(tournamentName: tournamentName,
            matches: matches, events: events, teams: teams, players: players,
            lineups: lineups, metricCategoryNames: metricCategoryNames)
    }
}
