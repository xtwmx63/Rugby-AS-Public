import Foundation
import SwiftData

/// 変わった試合だけを処理する仕組み(ModelChangeTracker・得点の控え・背番号の点検)の確認
@MainActor
enum ChangeTrackingRegressionChecks {
    private static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "ChangeTrackingChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "FAIL: " + message]) }
    }

    private static func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Team.self, Player.self, Tournament.self, Match.self,
            StatEvent.self, MatchLineup.self, Substitution.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    static func run() async throws {
        try workStoreKeepsChangesMadeDuringWork()
        try await trackerRecordsChangedMatches()
        try partialTalliesMatchFullTallies()
        try multiMatchNumberCheckMatchesPerMatch()
        try fastTallyMatchesSwiftData()
        print("PASS: 5 change tracking checks")
    }

    private static func workStoreKeepsChangesMadeDuringWork() throws {
        let defaults = UserDefaults(suiteName: "rugby-as-change-checks." + UUID().uuidString)!
        let first = UUID(), second = UUID()
        MatchWorkStore.add(PendingMatchWork(matchIDs: [first]), to: .tallies, defaults: defaults)
        let handled = MatchWorkStore.pending(.tallies, defaults: defaults)
        // 処理している間に別の試合が変わった
        MatchWorkStore.add(PendingMatchWork(matchIDs: [second]), to: .tallies, defaults: defaults)
        MatchWorkStore.clear(handled, from: .tallies, defaults: defaults)
        try expect(MatchWorkStore.pending(.tallies, defaults: defaults).matchIDs == [second],
                   "A change made while working is kept for the next pass")

        MatchWorkStore.add(PendingMatchWork(all: true), to: .tallies, defaults: defaults)
        let fullPass = MatchWorkStore.pending(.tallies, defaults: defaults)
        MatchWorkStore.add(PendingMatchWork(matchIDs: [first]), to: .tallies, defaults: defaults)
        MatchWorkStore.clear(fullPass, from: .tallies, defaults: defaults)
        try expect(MatchWorkStore.pending(.tallies, defaults: defaults).all,
                   "A full pass interrupted by new changes is repeated")
        MatchWorkStore.clear(MatchWorkStore.pending(.tallies, defaults: defaults), from: .tallies, defaults: defaults)
        try expect(MatchWorkStore.pending(.tallies, defaults: defaults).isEmpty, "Finished work is cleared")

        let many = PendingMatchWork(matchIDs: Set((0...MatchWorkStore.matchLimit).map { _ in UUID() }))
        MatchWorkStore.add(many, to: .numbers, defaults: defaults)
        try expect(MatchWorkStore.pending(.numbers, defaults: defaults).all, "Too many changed matches become a full pass")
        defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation().keys.first ?? "")
    }

    private static func waitForNotifications() async {
        for _ in 0..<5 { await Task.yield(); try? await Task.sleep(for: .milliseconds(20)) }
    }

    private static func trackerRecordsChangedMatches() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let team = Team(name: "記録チーム")
        let player = Player(teamID: team.id, number: 9, name: "記録者")
        let match = Match(tournamentID: UUID(), homeTeamID: team.id, awayTeamID: UUID(), playedAt: .now)
        let other = Match(tournamentID: UUID(), homeTeamID: team.id, awayTeamID: UUID(), playedAt: .now)
        [team].forEach { context.insert($0) }
        context.insert(player); context.insert(match); context.insert(other)
        try context.save()

        let tracker = ModelChangeTracker.shared
        tracker.start(container: container)
        for kind in [MatchWorkKind.tallies, .numbers] {
            MatchWorkStore.clear(MatchWorkStore.pending(kind), from: kind)
        }
        await waitForNotifications()
        for kind in [MatchWorkKind.tallies, .numbers] {
            MatchWorkStore.clear(MatchWorkStore.pending(kind), from: kind)
        }

        let event = StatEvent(matchID: match.id, teamID: team.id, playerID: player.id, category: "try", outcome: "success", seconds: 10)
        context.insert(event)
        try context.save()
        await waitForNotifications()
        try expect(MatchWorkStore.pending(.tallies).matchIDs == [match.id], "A new play marks its match's score")
        try expect(MatchWorkStore.pending(.numbers).matchIDs == [match.id], "A play with a player marks its match's numbers")
        try expect(!MatchWorkStore.pending(.tallies).matchIDs.contains(other.id), "Untouched matches are not marked")

        MatchWorkStore.clear(MatchWorkStore.pending(.tallies), from: .tallies)
        tracker.activeMatchID = match.id
        context.delete(event)
        try context.save()
        await waitForNotifications()
        try expect(MatchWorkStore.pending(.tallies).matchIDs == [match.id] && !MatchWorkStore.pending(.tallies).all,
                   "Deleting a play inside an open match marks that match")

        MatchWorkStore.clear(MatchWorkStore.pending(.tallies), from: .tallies)
        tracker.activeMatchID = nil
        let second = StatEvent(matchID: other.id, teamID: team.id, category: "try", outcome: "success", seconds: 20)
        context.insert(second); try context.save()
        await waitForNotifications()
        MatchWorkStore.clear(MatchWorkStore.pending(.tallies), from: .tallies)
        context.delete(second); try context.save()
        await waitForNotifications()
        try expect(MatchWorkStore.pending(.tallies).all, "Deleting a play from an unknown match recounts everything")
        for kind in [MatchWorkKind.tallies, .numbers] {
            MatchWorkStore.clear(MatchWorkStore.pending(kind), from: kind)
        }
    }

    private static func partialTalliesMatchFullTallies() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let home = UUID(), away = UUID()
        var sides: [MatchListSide] = []
        for index in 0..<5 {
            let match = Match(tournamentID: UUID(), homeTeamID: home, awayTeamID: away, playedAt: .now)
            context.insert(match)
            sides.append(MatchListSide(id: match.id, home: home, away: away))
            for second in 0...index {
                context.insert(StatEvent(matchID: match.id, teamID: second % 2 == 0 ? home : away,
                                         category: second % 3 == 0 ? "try" : "conversion", outcome: "success",
                                         seconds: second, half: second % 2))
            }
            if index % 2 == 0 {
                context.insert(StatEvent(matchID: match.id, category: "match_state", outcome: "finished", seconds: 0))
            }
        }
        var details = RecordingEventDetails()
        details.officialPoints = 4
        details.officialScoringCategory = "try"
        let historical = StatEvent(matchID: sides[1].id, teamID: home, category: "try", outcome: "success", seconds: 99,
                                   widgetData: try JSONEncoder().encode(details))
        context.insert(historical)
        try context.save()

        let full = try MatchListSummary.load(context: context, sides: sides)
        let subset = [sides[1], sides[3]]
        let partial = try MatchListSummary.load(context: context, sides: subset, onlyListed: true)
        try expect(partial.count == 2 && subset.allSatisfy { partial[$0.id] == full[$0.id] },
                   "Recounting chosen matches gives the same scores as recounting everything")
        try expect(full[sides[1].id]?.homeScore == 5 + 4, "Historical 4-point tries are still counted as 4")
    }

    /// 保存先のファイルを直接読む数え方が、今までの数え方と同じ得点・前後半・終了の印になる
    private static func fastTallyMatchesSwiftData() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let container = try ModelContainer(for: Team.self, Player.self, Tournament.self, Match.self,
            StatEvent.self, MatchLineup.self, Substitution.self,
            configurations: ModelConfiguration(url: folder.appendingPathComponent("tally.store")))
        let context = container.mainContext
        let home = UUID(), away = UUID()
        var sides: [MatchListSide] = []
        for index in 0..<6 {
            let match = Match(tournamentID: UUID(), homeTeamID: home, awayTeamID: away, playedAt: .now)
            context.insert(match)
            sides.append(MatchListSide(id: match.id, home: home, away: away))
            for second in 0...index {
                let category = ["try", "conversion", "penalty_goal", "drop_goal", ScoringRules.penaltyTryCategory, "tackle"][second % 6]
                context.insert(StatEvent(matchID: match.id, teamID: second % 2 == 0 ? home : away, category: category,
                                         outcome: second % 4 == 3 ? "fail" : "success", seconds: second, half: second % 2))
            }
            if index % 2 == 0 { context.insert(StatEvent(matchID: match.id, category: "match_state", outcome: "finished", seconds: 0)) }
        }
        var details = RecordingEventDetails()
        details.officialPoints = 4
        details.officialScoringCategory = "try"
        context.insert(StatEvent(matchID: sides[2].id, teamID: away, category: "try", outcome: "success", seconds: 5, half: 1,
                                 widgetData: try JSONEncoder().encode(details)))
        try context.save()

        let slow = try MatchListSummary.load(context: ModelContext(container), sides: sides)
        let fast = MatchListFastTally.load(storeURL: container.configurations.first?.url, sides: sides)
        try expect(fast != nil && sides.allSatisfy { fast?[$0.id] == slow[$0.id] },
                   "Reading the store file gives the same scores, halves and finish marks")
        try expect(MatchListFastTally.load(storeURL: folder.appendingPathComponent("missing.store"), sides: sides) == nil,
                   "A missing store falls back to the normal count")
    }

    private static func multiMatchNumberCheckMatchesPerMatch() throws {
        func build() throws -> (ModelContainer, [UUID]) {
            let container = try makeContainer()
            let context = container.mainContext
            let team = Team(name: "番号チーム")
            context.insert(team)
            let players = (1...3).map { Player(teamID: team.id, number: $0 * 10, name: "選手\($0)") }
            players.forEach { context.insert($0) }
            var ids: [UUID] = []
            for index in 0..<3 {
                let match = Match(tournamentID: UUID(), homeTeamID: team.id, awayTeamID: UUID(), playedAt: .now)
                context.insert(match); ids.append(match.id)
                context.insert(StatEvent(matchID: match.id, teamID: team.id, playerID: players[index].id,
                                         category: "try", outcome: "success", seconds: 1))
                context.insert(MatchLineup(matchID: match.id, teamID: team.id, playerID: players[(index + 1) % 3].id,
                                           role: "starter", order: 1, number: nil))
            }
            try context.save()
            return (container, ids)
        }
        func snapshot(_ container: ModelContainer) throws -> [String] {
            try container.mainContext.fetch(FetchDescriptor<MatchLineup>())
                .map { "\($0.matchID)|\($0.playerID)|\($0.role)|\($0.number ?? -1)" }.sorted()
        }
        let (perMatch, perIDs) = try build()
        for id in perIDs { MatchNumbering.freezeNumbers(forMatch: id, context: perMatch.mainContext) }
        // 同じデータを別に作り、まとめて点検する(IDは別になるので、試合の並びで比べる)
        let (together, togetherIDs) = try build()
        MatchNumbering.freezeNumbers(forMatches: Set(togetherIDs), context: together.mainContext)
        let normalize: ([String], [UUID]) -> [String] = { rows, ids in
            rows.map { row in
                var row = row
                for (index, id) in ids.enumerated() { row = row.replacingOccurrences(of: id.uuidString, with: "M\(index)") }
                return String(row.split(separator: "|")[0]) + "|" + String(row.split(separator: "|")[2...].joined(separator: "|"))
            }.sorted()
        }
        try expect(normalize(try snapshot(perMatch), perIDs) == normalize(try snapshot(together), togetherIDs),
                   "Checking several matches at once fixes numbers the same way as one by one")
        try expect(try snapshot(together).filter { $0.hasSuffix("|-1") }.isEmpty, "Every listed player gets a number")
    }
}
