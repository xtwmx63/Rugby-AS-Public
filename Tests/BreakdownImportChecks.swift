import Foundation
import SwiftData

/// 公式記録票の公開が終わった試合(得点経過なし)を、試合ページの前後半の内訳から取り込む確認
@MainActor
enum BreakdownImportChecks {
    private static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "BreakdownImportChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "FAIL: " + message]) }
    }

    /// 実データ(jrfu:19977 2020年 大学選手権決勝 明治大学 35-45 早稲田大学)と同じ内容
    static func record(homeScore: Int = 35, id: String = "jrfu:19977", stats: Bool = true) throws -> OfficialRecord {
        let breakdown = stats ? """
        [{"away":"4","home":"0","label":"前半 T"},{"away":"4","home":"0","label":"前半 G"},{"away":"0","home":"0","label":"前半 PT"},
         {"away":"1","home":"0","label":"前半 PG"},{"away":"0","home":"0","label":"前半 DG"},{"away":"2","home":"5","label":"後半 T"},
         {"away":"2","home":"5","label":"後半 G"},{"away":"0","home":"0","label":"後半 PT"},{"away":"0","home":"0","label":"後半 PG"},
         {"away":"0","home":"0","label":"後半 DG"}]
        """ : "[]"
        let json = """
        {"id":"\(id)","source":"jrfu","season":"2020","year":2020,"category":"大学","categories":["大学"],
         "tournament":"第56回全国大学ラグビーフットボール選手権大会決勝","round":"","date":"2020-01-11","kickoff":"14:30",
         "venue":"国立競技場","homeTeam":"明治大学","awayTeam":"早稲田大学","homeScore":\(homeScore),"awayScore":45,
         "homeFirstHalfScore":0,"awayFirstHalfScore":31,"homeSecondHalfScore":35,"awaySecondHalfScore":14,
         "status":"finished","sourceURL":"https://www.rugby-japan.jp/match/19977","officialRecordURL":null,
         "fetchedAt":"2026-10-03T22:20:14Z","detailLevel":"summary","players":[],"scoreEvents":[],"substitutions":[],
         "stats":\(breakdown)}
        """
        return try JSONDecoder().decode(OfficialRecord.self, from: Data(json.utf8))
    }

    static func run() throws {
        let draft = OfficialRecordImporter.draft(from: try record())
        try expect(draft.score(side: "home") == 35 && draft.score(side: "away") == 45, "The page breakdown reproduces the official score")
        try expect(draft.matchesOfficialScore == true, "The import screen reports the score as matching")
        func count(_ side: String, _ half: Int, _ category: String) -> Int {
            draft.events.filter { $0.side == side && $0.half == half && $0.category == category }.count
        }
        try expect(count("away", 0, "try") == 4 && count("away", 0, "conversion") == 4 && count("away", 0, "penalty_goal") == 1
                   && count("home", 1, "try") == 5 && count("home", 1, "conversion") == 5 && count("home", 0, "try") == 0,
                   "Counts are placed in the right half and team")
        try expect(draft.events.allSatisfy { $0.minute == 0 && $0.playerName.isEmpty && $0.outcome == "success" },
                   "Breakdown points have no time or scorer")
        try expect(draft.notes.contains(OfficialRecordImporter.breakdownNote), "The import explains where the points came from")

        let mismatch = OfficialRecordImporter.draft(from: try record(homeScore: 36))
        try expect(mismatch.events.isEmpty && mismatch.notes.contains { $0.contains("合わない") },
                   "A breakdown that disagrees with the official score adds no points")
        let empty = OfficialRecordImporter.draft(from: try record(stats: false))
        try expect(empty.events.isEmpty, "A match without a breakdown still imports without points")

        try fillsExistingScorelessMatches()
        print("PASS: 7 breakdown import checks")
    }

    /// すでに得点なしで取り込んだ試合に、起動時の処理で得点が入る。得点のある試合には触らない
    private static func fillsExistingScorelessMatches() throws {
        let container = try ModelContainer(for: Team.self, Player.self, Tournament.self, Match.self,
            StatEvent.self, MatchLineup.self, Substitution.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let home = Team(name: "明治大学"), away = Team(name: "早稲田大学")
        context.insert(home); context.insert(away)
        let scoreless = Match(tournamentID: UUID(), homeTeamID: home.id, awayTeamID: away.id, playedAt: .now)
        scoreless.officialRecordID = "jrfu:19977"
        let scored = Match(tournamentID: UUID(), homeTeamID: home.id, awayTeamID: away.id, playedAt: .now)
        scored.officialRecordID = "jrfu:19977"
        context.insert(scoreless); context.insert(scored)
        context.insert(StatEvent(matchID: scored.id, teamID: home.id, category: "try", outcome: "success", seconds: 60, half: 0))
        try context.save()

        // 公式記録データベースの代わりに、同じ形の小さなファイルを作る
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        try makeArchive(at: url)
        let defaults = UserDefaults(suiteName: "breakdown-checks." + UUID().uuidString)!
        let filled = OfficialRecordImporter.fillScoresFromBreakdown(container: container, archiveURL: url, defaults: defaults)

        let check = ModelContext(container)
        let scorelessID = scoreless.id, scoredID = scored.id
        let added = try check.fetch(FetchDescriptor<StatEvent>(predicate: #Predicate { $0.matchID == scorelessID }))
        let untouched = try check.fetch(FetchDescriptor<StatEvent>(predicate: #Predicate { $0.matchID == scoredID }))
        let homeID = home.id
        let homePoints = added.filter { $0.teamID == homeID }.reduce(0) { $0 + ScoringRules.points(category: $1.category, widgetData: $1.widgetData) }
        try expect(filled == 1 && homePoints == 35 && added.count == 4 + 4 + 1 + 5 + 5 + 2 + 2,
                   "A scoreless imported match gets its points from the breakdown")
        try expect(untouched.count == 1, "A match that already has points is left alone")
        try expect(defaults.bool(forKey: OfficialRecordImporter.breakdownFillKey), "The fill runs only once")
        try expect(OfficialRecordImporter.fillScoresFromBreakdown(container: container, archiveURL: url, defaults: defaults) == 0,
                   "Running again adds nothing")
    }

    private static func makeArchive(at url: URL) throws {
        let payload = String(data: try JSONSerialization.data(withJSONObject: try JSONSerialization.jsonObject(
            with: Data(rawPayload.utf8))), encoding: .utf8)!.replacingOccurrences(of: "'", with: "''")
        let sql = """
        CREATE TABLE matches (id TEXT PRIMARY KEY NOT NULL,"source" TEXT NOT NULL,"sourceMatchID" TEXT NOT NULL,"season" TEXT NOT NULL,"category" TEXT NOT NULL,"tournament" TEXT NOT NULL,"round" TEXT NOT NULL,"date" TEXT NOT NULL,"kickoff" TEXT NOT NULL,"venue" TEXT NOT NULL,"homeTeam" TEXT NOT NULL,"awayTeam" TEXT NOT NULL,"status" TEXT NOT NULL,"sourceURL" TEXT NOT NULL,"fetchedAt" TEXT NOT NULL,"detailLevel" TEXT NOT NULL,year INTEGER NOT NULL,"homeScore" INTEGER,"awayScore" INTEGER,"homeFirstHalfScore" INTEGER,"awayFirstHalfScore" INTEGER,"homeSecondHalfScore" INTEGER,"awaySecondHalfScore" INTEGER,officialRecordURL TEXT,payload TEXT NOT NULL);
        INSERT INTO matches VALUES ('jrfu:19977','jrfu','19977','2020','大学','第56回全国大学ラグビーフットボール選手権大会決勝','','2020-01-11','14:30','国立競技場','明治大学','早稲田大学','finished','https://www.rugby-japan.jp/match/19977','2026-10-03T22:20:14Z','summary',2020,35,45,0,31,35,14,NULL,'\(payload)');
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [url.path, sql]
        try process.run()
        process.waitUntilExit()
    }

    private static let rawPayload = """
    {"awayFirstHalfScore":31,"awayScore":45,"awaySecondHalfScore":14,"awayTeam":"早稲田大学","categories":["大学"],"category":"大学",
     "date":"2020-01-11","detailLevel":"summary","fetchedAt":"2026-10-03T22:20:14Z","homeFirstHalfScore":0,"homeScore":35,
     "homeSecondHalfScore":35,"homeTeam":"明治大学","id":"jrfu:19977","kickoff":"14:30","officialRecordURL":null,"players":[],
     "round":"","scoreEvents":[],"season":"2020","source":"jrfu","sourceMatchID":"19977",
     "sourceURL":"https://www.rugby-japan.jp/match/19977",
     "stats":[{"away":"4","home":"0","label":"前半 T"},{"away":"4","home":"0","label":"前半 G"},{"away":"0","home":"0","label":"前半 PT"},
              {"away":"1","home":"0","label":"前半 PG"},{"away":"0","home":"0","label":"前半 DG"},{"away":"2","home":"5","label":"後半 T"},
              {"away":"2","home":"5","label":"後半 G"},{"away":"0","home":"0","label":"後半 PT"},{"away":"0","home":"0","label":"後半 PG"},
              {"away":"0","home":"0","label":"後半 DG"}],
     "status":"finished","substitutions":[],"tournament":"第56回全国大学ラグビーフットボール選手権大会決勝","venue":"国立競技場","year":2020}
    """
}
