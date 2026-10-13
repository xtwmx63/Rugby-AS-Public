import Foundation
import SwiftData

// 「集計対象外」にした試合が、分析・大会CSVから外れ、バックアップで保たれることを確かめる。
@MainActor
enum StatsExclusionRegressionChecks {
    private static let expect = RecordingRegressionChecks.expect

    static func run() throws {
        let container = try ModelContainer(for: Team.self, Player.self, Tournament.self, Match.self,
            StatEvent.self, MatchLineup.self, Substitution.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let tournament = Tournament(officialName: "大会", seriesName: "シリーズ2026")
        let home = Team(name: "集計チーム"), away = Team(name: "相手チーム"), other = Team(name: "対象外チーム")
        [home, away, other].forEach { context.insert($0) }
        context.insert(tournament)
        let counted = Match(tournamentID: tournament.id, homeTeamID: home.id, awayTeamID: away.id, playedAt: .now)
        let excluded = Match(tournamentID: tournament.id, homeTeamID: other.id, awayTeamID: away.id,
                             playedAt: .now.addingTimeInterval(-86_400), isExcludedFromStats: true)
        excluded.officialRecordID = "jrfu:1"
        excluded.officialPageURL = "https://www.rugby-japan.jp/match/1"
        excluded.officialSheetURL = "https://www.rugby-japan.jp/match/1/print"
        context.insert(counted); context.insert(excluded)
        for match in [counted, excluded] {
            context.insert(StatEvent(matchID: match.id, teamID: match.homeTeamID, category: "try", outcome: "success", seconds: 60, half: 0))
        }
        try context.save()
        let matches = try context.fetch(FetchDescriptor<Match>())
        let events = try context.fetch(FetchDescriptor<StatEvent>())

        // 分析: 条件なしでも、試合を指定しても、対象外は入らない
        var scope = AnalysisScope()
        try expect(scope.selectedMatches(from: matches, events: events, lineups: []).map(\.id) == [counted.id], "Analysis skips excluded matches")
        scope.matchIDs = [excluded.id]
        try expect(scope.selectedMatches(from: matches, events: events, lineups: []).isEmpty, "An excluded match cannot be picked for analysis")

        // 大会CSV: 対象外の試合は書き出さない
        let csv = try TournamentCSVLoader.makeFile(container: container, tournamentID: tournament.id,
                                                   tournamentName: "大会", metricCategoryNames: [:]).csvText
        try expect(csv.contains("集計チーム") && !csv.contains("対象外チーム"), "Tournament CSV skips excluded matches")

        // バックアップ: 印が往復し、印のない古いファイルは「含める」になる
        let suite = "rugby-as-exclusion-checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let data = try BackupManager.makeBackupData(context: context, defaults: defaults)
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let saved = (json["matches"] as! [[String: Any]]).first { ($0["id"] as? String) == excluded.id.uuidString }
        try expect(saved?["isExcludedFromStats"] as? Bool == true, "Backup stores the exclusion")
        json["matches"] = (json["matches"] as! [[String: Any]]).map { var item = $0; item.removeValue(forKey: "isExcludedFromStats"); return item }
        let restoredContainer = try ModelContainer(for: Team.self, Player.self, Tournament.self, Match.self,
            StatEvent.self, MatchLineup.self, Substitution.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        try BackupManager.restore(from: data, context: restoredContainer.mainContext, defaults: defaults)
        let restored = try restoredContainer.mainContext.fetch(FetchDescriptor<Match>())
        let restoredSeries = try restoredContainer.mainContext.fetch(FetchDescriptor<Tournament>()).first?.seriesName
        try expect(restoredSeries == "シリーズ2026",
                   "Restore keeps the series name")
        try expect(restored.first { $0.id == excluded.id }?.isExcludedFromStats == true
                   && restored.first { $0.id == counted.id }?.isExcludedFromStats == false, "Restore keeps the exclusion")
        let restoredOfficial = restored.first { $0.id == excluded.id }
        try expect(restoredOfficial?.officialRecordID == "jrfu:1" && restoredOfficial?.officialSheetURL?.hasSuffix("/print") == true
                   && restored.first { $0.id == counted.id }?.officialPageURL == nil, "Restore keeps the official record links")
        let oldContainer = try ModelContainer(for: Team.self, Player.self, Tournament.self, Match.self,
            StatEvent.self, MatchLineup.self, Substitution.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        try BackupManager.restore(from: try JSONSerialization.data(withJSONObject: json), context: oldContainer.mainContext, defaults: defaults)
        let oldRestored = try oldContainer.mainContext.fetch(FetchDescriptor<Match>())
        try expect(oldRestored.count == 2 && oldRestored.allSatisfy { !$0.isExcludedFromStats },
                   "Older backups without the field restore as included")
        print("PASS: 7 stats exclusion, series and official link regression checks")
    }
}
