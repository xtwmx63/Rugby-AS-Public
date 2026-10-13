import Foundation
import SwiftData

@MainActor
enum StartupPerformanceRegressionChecks {
    static func run() throws {
        try listReadsOnlyItsRequiredRecords()
        try listReflectsSavedEditsAndDeletion()
        try numberSnapshotsStayScoped()
        print("PASS: 3 startup performance regression checks")
    }

    private static func listReadsOnlyItsRequiredRecords() throws {
        let (container, match) = try RecordingRegressionChecks.fixture()
        let context = container.mainContext
        let irrelevant = Data(repeating: 65, count: 2048)
        for index in 0..<5000 {
            let event = StatEvent(matchID: match.id, teamID: match.homeTeamID, category: "tackle",
                outcome: "success", seconds: index, widgetData: irrelevant)
            context.insert(event)
        }
        for (category, outcome, team, half) in [("try", "success", match.homeTeamID, 0),
            ("conversion", "success", match.homeTeamID, 0), ("penalty_goal", "success", match.awayTeamID, 1),
            ("try", "fail", match.homeTeamID, 1), ("match_state", "finished", match.homeTeamID, 1)] {
            context.insert(StatEvent(matchID: match.id, teamID: team, category: category, outcome: outcome, seconds: 60, half: half))
        }
        try context.save()
        let count = try ModelContext(container).fetchCount(MatchListSummary.descriptor())
        try RecordingRegressionChecks.expect(count == 4, "The list fetch excludes detailed plays and missed kicks/tries")
        let start = Date()
        let side = MatchListSide(id: match.id, home: match.homeTeamID, away: match.awayTeamID)
        let tally = try MatchListSummary.load(container: container, sides: [side])[match.id]!
        let elapsed = Date().timeIntervalSince(start)
        try RecordingRegressionChecks.expect(tally.homeScore == 7 && tally.awayScore == 3 && tally.isFinished,
            "A projected, batched fetch retains scores and finished state")
        try RecordingRegressionChecks.expect(tally.homeFirstHalf == 7 && tally.awaySecondHalf == 3 && tally.homeSecondHalf == 0,
            "Half scores remain correct")
        print(String(format: "PERF: list summary read 4 of 5005 records in %.4f seconds (test machine)", elapsed))
    }

    private static func listReflectsSavedEditsAndDeletion() throws {
        let (container, match) = try RecordingRegressionChecks.fixture()
        let context = container.mainContext
        let event = StatEvent(matchID: match.id, teamID: match.homeTeamID, category: "try", outcome: "success", seconds: 1)
        context.insert(event); try context.save()
        let side = MatchListSide(id: match.id, home: match.homeTeamID, away: match.awayTeamID)
        let original = try MatchListSummary.load(container: container, sides: [side])
        event.teamID = match.awayTeamID; event.half = 1; try context.save()
        let updated = try MatchListSummary.load(container: container, sides: [side])
        try RecordingRegressionChecks.expect(original[match.id]?.homeScore == 5 && updated[match.id]?.homeScore == 0
            && updated[match.id]?.awaySecondHalf == 5, "Reopening the list reflects edits from the recording context")
        context.delete(event); try context.save()
        let deleted = try MatchListSummary.load(container: container, sides: [side])
        try RecordingRegressionChecks.expect(deleted[match.id]?.awayScore == 0, "Deleted scores do not survive in the summary")
    }

    private static func numberSnapshotsStayScoped() throws {
        let container = try ModelContainer(for: MatchLineup.self, Player.self, StatEvent.self, Substitution.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let team = UUID(), first = UUID(), second = UUID()
        let player = Player(teamID: team, number: 12, name: "選手")
        context.insert(player)
        for id in [first, second] {
            context.insert(StatEvent(matchID: id, teamID: team, playerID: player.id, category: "try", outcome: "success", seconds: 10))
        }
        try context.save()
        MatchNumbering.freezeNumbers(forMatch: first, context: context)
        let scoped = try context.fetch(FetchDescriptor<MatchLineup>())
        try RecordingRegressionChecks.expect(scoped.count == 1 && scoped[0].matchID == first && scoped[0].number == 12,
            "Closing one match never scans or snapshots another match")
        player.number = 8; try context.save()
        MatchNumbering.freezeLineupNumbers(context: context)
        let all = try context.fetch(FetchDescriptor<MatchLineup>())
        try RecordingRegressionChecks.expect(all.count == 2 && all.first { $0.matchID == first }?.number == 12
            && all.first { $0.matchID == second }?.number == 8, "Legacy snapshots preserve previously frozen numbers")
    }
}
