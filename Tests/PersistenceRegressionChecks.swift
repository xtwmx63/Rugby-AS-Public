import Foundation
import SwiftData

enum PersistenceRegressionChecks {
    private static let schema = Schema([Team.self, Player.self, Tournament.self, Match.self, StatEvent.self, MatchLineup.self, Substitution.self])
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw NSError(domain: "PersistenceChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func run() throws {
        try teamDeletionCleansMembershipAndRetainsSharedImages()
        try refusesReferencedPlayer()
        try matchDeletionCommitsBeforeMediaCleanup()
        try failureKeepsRecordsAndFiles()
        print("PASS: 4 persistence regression checks")
    }
    private static func fixture() throws -> ModelContainer {
        try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
    private static func teamDeletionCleansMembershipAndRetainsSharedImages() throws {
        let container = try fixture(), context = container.mainContext
        let team = Team(name: "削除対象", logoPath: "shared.png")
        let survivor = Team(name: "残す", logoPath: "shared.png")
        let player = Player(teamID: team.id, number: 1); player.imagePath = "player.png"
        let tournament = Tournament(officialName: "大会"); tournament.teamIDs = [team.id, survivor.id]
        for model in [team, survivor] { context.insert(model) }
        context.insert(player); context.insert(tournament); try context.save()
        var removed: [String] = []
        try expect(SafeDeletion.team(team, context: context, removeImage: { removed.append($0) }), "Team deletion must save")
        try expect(tournament.teamIDs == [survivor.id], "Deleted team must be removed from tournament membership")
        try expect(removed == ["player.png"], "Shared logos must remain while unreferenced images are removed")
    }
    private static func refusesReferencedPlayer() throws {
        let container = try fixture(), context = container.mainContext
        let player = Player(teamID: UUID(), number: 1)
        context.insert(player)
        context.insert(StatEvent(matchID: UUID(), playerID: player.id, category: "tackle", outcome: "success", seconds: 0))
        try context.save()
        var removed = false
        try expect(!SafeDeletion.player(player, context: context, removeImage: { _ in removed = true }), "Referenced players must not be deleted")
        let remaining = try context.fetch(FetchDescriptor<Player>())
        try expect(remaining.count == 1 && !removed, "Failed deletion must retain player and image")
    }
    private static func matchDeletionCommitsBeforeMediaCleanup() throws {
        let container = try fixture(), context = container.mainContext
        let match = Match(tournamentID: UUID(), homeTeamID: UUID(), awayTeamID: UUID(), playedAt: .now)
        context.insert(match)
        context.insert(StatEvent(matchID: match.id, category: "try", outcome: "success", seconds: 10))
        try context.save()
        var cleanupAfterCommit = false
        let saved = SafeDeletion.match(match, context: context) {
            cleanupAfterCommit = (try? ModelContext(container).fetch(FetchDescriptor<Match>()).isEmpty) == true
        }
        let events = try context.fetch(FetchDescriptor<StatEvent>())
        try expect(saved && cleanupAfterCommit && events.isEmpty, "Match and events must commit before media removal")
    }
    private static func failureKeepsRecordsAndFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("read-only.store")
        do {
            let seed = try ModelContainer(for: schema, configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
            seed.mainContext.insert(Team(name: "保存済み", logoPath: "old.png"))
            seed.mainContext.insert(Match(tournamentID: UUID(), homeTeamID: UUID(), awayTeamID: UUID(), playedAt: .now))
            try seed.mainContext.save()
        }
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(url: url, allowsSave: false, cloudKitDatabase: .none))
        let context = container.mainContext; context.autosaveEnabled = false
        let team = try context.fetch(FetchDescriptor<Team>()).first!
        var removed: [String] = []
        let saved = SafeImageMutation.replace(old: team.logoPath, new: "new.png", context: context,
            set: { team.logoPath = $0 }, removeImage: { removed.append($0) })
        try expect(!saved && team.logoPath == "old.png" && removed == ["new.png"], "Failure must restore visible image and remove only the staged replacement")
        let match = try context.fetch(FetchDescriptor<Match>()).first!
        var removedVideo = false
        try expect(!SafeDeletion.match(match, context: context, afterSave: { removedVideo = true }), "Read-only store must reject match deletion")
        let matches = try ModelContext(container).fetch(FetchDescriptor<Match>())
        try expect(!removedVideo && matches.count == 1 && !context.hasChanges, "Failed deletion must preserve saved match and video without pending changes")
    }
}
