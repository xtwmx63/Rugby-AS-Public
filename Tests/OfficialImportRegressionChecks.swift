import Foundation
import SwiftData

@MainActor
enum OfficialImportRegressionChecks {
    static func run() async throws {
        try draftReadsOfficialRecord()
        try savesMatchReusingExistingRecords()
        try invalidDraftLeavesNothing()
        try leagueOneScorerNumbers()
        try groupsTournamentStages()
        try savesWholeTournament()
        try detectsSeries()
        try substitutionsAndPlayingTime()
        try svnsIdentityAndTime()
        try worldCupHistoricScoring()
        try bundledWorldRugbyImports()
        try bulkImportResumesWithoutDuplicates()
        try await backgroundBulkSaving()
        try headToHeadAddsUnimportedOfficialMatches()
        print("PASS: 14 official record import regression checks")
    }

    /// 対戦成績に、取り込んでいない公式記録の対戦を加える(表記ゆれ・別名・重複・日付の扱い)
    private static func headToHeadAddsUnimportedOfficialMatches() throws {
        func summary(_ id: String, _ source: String, _ category: String, _ date: String, _ home: String, _ away: String,
                     _ homeScore: Int, _ awayScore: Int) -> OfficialRecordSummary {
            OfficialRecordSummary(id: id, source: source, season: "2026", year: 2026, category: category, tournament: "大会",
                                  round: "", date: date, kickoff: "13:00", venue: "", homeTeam: home, awayTeam: away,
                                  homeScore: homeScore, awayScore: awayScore, status: "finished", detailLevel: "full")
        }
        let calendar = Calendar(identifier: .gregorian)
        let day = { (text: String) in OfficialRecordImporter.playedAt(date: text, kickoff: "13:00", calendar: calendar)! }
        let summaries = [
            summary("jrfu:1", "jrfu", "大学", "2026-05-01", "早稲田 大学", "明治大学", 20, 10),     // 空白の表記ゆれ
            summary("jrfu:2", "jrfu", "大学", "2026-06-01", "明治大学", "早大", 7, 14),            // 別名・ホームが逆
            summary("jrfu:3", "jrfu", "大学", "2026-07-01", "早稲田大学", "明治大学", 3, 3),       // 取り込み済み(ID)
            summary("leagueone:9", "leagueone", "大学", "2026-08-01", "早稲田大学", "明治大学", 9, 9), // 同じ日に手入力あり
            summary("jrfu:4", "jrfu", "大学", "2026-09-01", "早稲田大学", "慶應義塾大学", 1, 0),   // 別の対戦
            summary("jrfu:5", "jrfu", "大学", "2026-12-01", "早稲田大学", "明治大学", 5, 0),       // この試合より後
            summary("svns:1", "svns", "HSBC SVNS 男子", "2026-03-01", "Japan", "Fiji", 12, 7),
        ]
        let saved = [OfficialHeadToHead.SavedMatch(officialRecordID: "jrfu:3", playedAt: day("2026-07-01")),
                     OfficialHeadToHead.SavedMatch(officialRecordID: nil, playedAt: day("2026-08-01"))]
        let found = OfficialHeadToHead.meetings(in: summaries, teamA: ["早稲田大学", "早大"], teamB: ["明治大学"],
                                                before: day("2026-10-01"), saved: saved, calendar: calendar)
        try expect(found.map(\.summary.id) == ["jrfu:1", "jrfu:2"],
                   "Head-to-head adds unimported official meetings once, before this match, by name or alias: \(found.map(\.summary.id))")
        try expect(found.map(\.homeIsTeamA) == [true, false], "Official meetings keep which side each team played")
        // SVNS は取り込みと同じく「（男子7人制）」付きの名前で照合する
        let sevens = OfficialHeadToHead.meetings(in: summaries, teamA: ["Japan（男子7人制）"], teamB: ["Fiji（男子7人制）"],
                                                 before: day("2026-10-01"), saved: [], calendar: calendar)
        try expect(sevens.map(\.summary.id) == ["svns:1"], "SVNS meetings match the imported sevens team names")
        let fifteens = OfficialHeadToHead.meetings(in: summaries, teamA: ["Japan"], teamB: ["Fiji"],
                                                   before: day("2026-10-01"), saved: [], calendar: calendar)
        try expect(fifteens.isEmpty, "A 15-a-side team never picks up sevens meetings")
        // JRFU は代表のセブンズも同じチーム名。大会名から人数が分かれば、この試合と違う人数の試合は加えない
        let sameNames = [summary("jrfu:20", "jrfu", "セブンズ", "2015-04-05", "日本代表", "フィジー代表", 5, 41),
                         summary("jrfu:21", "jrfu", "15人制男子日本代表", "2015-07-29", "フィジー代表", "日本代表", 27, 22)]
        let seven = sameNames[0], fifteen = sameNames[1]
        let renamed = [OfficialRecordSummary(id: seven.id, source: seven.source, season: seven.season, year: seven.year,
                            category: seven.category, tournament: "HSBCセブンズワールドシリーズ東京セブンズ2015", round: "",
                            date: seven.date, kickoff: seven.kickoff, venue: "", homeTeam: seven.homeTeam, awayTeam: seven.awayTeam,
                            homeScore: seven.homeScore, awayScore: seven.awayScore, status: "finished", detailLevel: "full"),
                       OfficialRecordSummary(id: fifteen.id, source: fifteen.source, season: fifteen.season, year: fifteen.year,
                            category: fifteen.category, tournament: "パシフィック・ネーションズカップ2015 第3戦", round: "",
                            date: fifteen.date, kickoff: fifteen.kickoff, venue: "", homeTeam: fifteen.homeTeam, awayTeam: fifteen.awayTeam,
                            homeScore: fifteen.homeScore, awayScore: fifteen.awayScore, status: "finished", detailLevel: "full")]
        let tests = OfficialHeadToHead.meetings(in: renamed, teamA: ["日本代表"], teamB: ["フィジー代表"],
                                                before: day("2026-10-01"), saved: [], variant: .fifteens, calendar: calendar)
        try expect(tests.map(\.summary.id) == ["jrfu:21"], "A 15-a-side head-to-head leaves out sevens meetings of the same names")
    }

    private static func backgroundBulkSaving() async throws {
        let archive = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Rugby AS/OfficialRecords.sqlite")
        let page = try OfficialRecordsStore.search(at: archive, query: OfficialArchiveQuery(source: "svns", status: "finished"))
        let ids = page.matches.map(\.id)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try ModelContainer(for: Team.self, Player.self, Tournament.self, Match.self, StatEvent.self,
            MatchLineup.self, Substitution.self, configurations: ModelConfiguration(url: folder.appendingPathComponent("test.store")))
        let worker = await OfficialBulkImportWorker.make(container: store)
        var ticks = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(5)) } catch { break }
                ticks += 1
            }
        }
        let start = Date()
        let saved = try await worker.saveBatch(archiveURL: archive, ids: ids, includesLineups: true)
        heartbeat.cancel()
        try expect(saved == ids.count, "Background worker imports a complete chunk")
        try expect(ticks > 0, "MainActor stays responsive while archive decoding and persistence run")
        let context = ModelContext(store)
        let matches = try context.fetch(FetchDescriptor<Match>())
        let lineups = try context.fetchCount(FetchDescriptor<MatchLineup>())
        try expect(Set(matches.compactMap(\.officialRecordID)) == Set(ids) && lineups > 0,
                   "Worker saves visible matches and their lineups to the shared store")
        let resumed = await OfficialBulkImportWorker.make(container: store)
        let repeated = try await resumed.saveBatch(archiveURL: archive, ids: ids, includesLineups: true)
        try expect(repeated == 0, "A fresh worker resumes without duplicating saved matches")
        let cancelled = Task {
            try Task.checkCancellation()
            return try await resumed.saveBatch(archiveURL: archive, ids: ["missing:test"], includesLineups: true)
        }
        cancelled.cancel()
        var wasCancelled = false
        do { _ = try await cancelled.value } catch is CancellationError { wasCancelled = true }
        try expect(wasCancelled, "Cancellation is honored before a new chunk starts")
        print("PASS: background bulk import \(saved) matches in \(String(format: "%.2f", Date().timeIntervalSince(start)))s; UI heartbeat \(ticks) ticks")
    }

    private static let expect = RecordingRegressionChecks.expect

    private static func bulkImportResumesWithoutDuplicates() throws {
        let container = try self.container()
        var first = OfficialRecordImporter.draft(from: try record())
        first.officialRecordID = "svns:first"
        var second = first
        second.officialRecordID = "svns:second"
        let session = try OfficialRecordImporter.BulkSession(container: container)
        let initialCount = try session.saveBatch([first, second])
        try expect(initialCount == 2,
                   "Distinct same-day sevens games are both imported")
        let repeatedCount = try session.saveBatch([first, second])
        try expect(repeatedCount == 0, "Repeated batches add no duplicates")
        var renamed = first
        renamed.homeTeamName = "Renamed team"
        renamed.playedAt = first.playedAt.addingTimeInterval(86400)
        let resumed = try OfficialRecordImporter.BulkSession(container: container)
        let renamedCount = try resumed.saveBatch([renamed])
        try expect(renamedCount == 0, "Official ID survives name and date changes on resume")
        var alternate = first
        alternate.officialRecordID = "jrfu:alternate"
        let alternateCount = try resumed.saveBatch([alternate])
        try expect(alternateCount == 0, "Alternate publisher of same game is excluded")
        var third = first
        third.officialRecordID = "svns:third"
        var invalid = first
        invalid.officialRecordID = "svns:invalid"
        invalid.homeTeamName = ""
        var failed = false
        do { _ = try resumed.saveBatch([third, invalid]) } catch { failed = true }
        let check = ModelContext(container)
        let remainingCount = try check.fetchCount(FetchDescriptor<Match>())
        try expect(failed && remainingCount == 2,
                   "A failed chunk rolls back only that chunk, preserving earlier saves")
        let retriedCount = try resumed.saveBatch([third])
        try expect(retriedCount == 1, "Failed chunks can be retried with a rebuilt index")

        let legacyStore = try self.container()
        var legacy = first
        legacy.officialRecordID = nil
        _ = try OfficialRecordImporter.save(legacy, context: legacyStore.mainContext)
        let teams = try legacyStore.mainContext.fetch(FetchDescriptor<Team>())
        let home = teams.first { $0.name == first.homeTeamName }!
        home.aliases = ["旧チーム表記"]
        try legacyStore.mainContext.save()
        var aliased = first
        aliased.homeTeamName = "旧チーム表記"
        let legacyIndex = try OfficialRecordImporter.DuplicateIndex(context: legacyStore.mainContext)
        try expect(legacyIndex.contains(aliased), "Legacy imports are detected using dates and team aliases")

        let archive = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Rugby AS/OfficialRecords.sqlite")
        let page = try OfficialRecordsStore.search(at: archive, query: OfficialArchiveQuery(status: "finished"))
        let ids = Array(page.matches.prefix(20).map(\.id).reversed())
        let records = try OfficialRecordsStore.records(at: archive, ids: ids)
        try expect(records.map(\.id) == ids, "Bulk reads preserve the requested order")
        var missingFailed = false
        do { _ = try OfficialRecordsStore.records(at: archive, ids: ["missing:test"]) } catch { missingFailed = true }
        try expect(missingFailed, "A missing archive ID fails visibly rather than being silently skipped")
    }

    private static func record() throws -> OfficialRecord {
        let json = """
        {"id":"jrfu:1","source":"jrfu","season":"2025","year":2025,"category":"大学","tournament":"関東大学リーグ",
         "round":"第1節","date":"2025-09-14","kickoff":"13:00","venue":"","homeTeam":"筑波大学","awayTeam":"明治大学",
         "homeScore":19,"awayScore":3,"homeFirstHalfScore":12,"awayFirstHalfScore":3,"homeSecondHalfScore":7,"awaySecondHalfScore":0,
         "status":"finished","sourceURL":"https://example.invalid","officialRecordURL":null,"fetchedAt":"2025-09-15T00:00:00Z",
         "detailLevel":"full",
         "players":[
          {"side":"home","number":10,"name":"山田 太郎","position":"SO","role":"先発"},
          {"side":"home","number":11,"name":"佐藤 次郎","position":"WTB","role":"先発"},
          {"side":"home","number":23,"name":"鈴木 三郎","position":"TB","role":"リザーブ"},
          {"side":"away","number":10,"name":"高橋 四郎","position":"SO","role":"先発・キャプテン"}],
         "scoreEvents":[
          {"period":"前半","time":"9分","side":"home","player":"佐藤 次郎","kind":"T","homeScore":5,"awayScore":0},
          {"period":"前半","time":"10分","side":"home","player":"山田 太郎","kind":"G","homeScore":7,"awayScore":0},
          {"period":"前半","time":"20分","side":"away","player":"高橋 四郎","kind":"PG","homeScore":7,"awayScore":3},
          {"period":"前半","time":"30分","side":"home","player":"佐藤 次郎","kind":"T","homeScore":12,"awayScore":3},
          {"period":"前半","time":"31分","side":"home","player":"山田 太郎","kind":"Gx","homeScore":12,"awayScore":3},
          {"period":"後半","time":"5分","side":"home","player":"","kind":"PT","homeScore":19,"awayScore":3},
          {"period":"後半","time":"8分","side":"","player":"","kind":"??","homeScore":null,"awayScore":null}],
         "substitutions":[],"stats":[]}
        """
        return try JSONDecoder().decode(OfficialRecord.self, from: Data(json.utf8))
    }

    private static func svnsIdentityAndTime() throws {
        let json = """
        {"id":"svns:1","source":"svns","season":"2022","year":2022,"category":"HSBC SVNS 女子",
         "tournament":"Sevens Series 2022 - Dubai 女子 2021-11-26","seriesName":"Sevens Series 2022 女子",
         "round":"Pool A","date":"2021-09-18","kickoff":"09:00","kickoffUTC":"2021-09-18T16:00:00Z",
         "venue":"Vancouver","homeTeam":"Japan 7s","awayTeam":"Fiji 7s","homeScore":5,"awayScore":0,
         "status":"finished","sourceURL":"https://www.svns.com/en/match/1","fetchedAt":"2026-10-02T00:00:00Z",
         "detailLevel":"full","players":[
          {"side":"home","number":23,"name":"A","position":"FW","role":"先発"},
          {"side":"away","number":12,"name":"B","position":"BK","role":"リザーブ"}],
         "scoreEvents":[{"period":"後半","time":"4分","side":"home","player":"A","kind":"T","homeScore":5,"awayScore":0}],
         "substitutions":[],"stats":[],"omissions":["出典に一部未掲載"]}
        """
        let record = try JSONDecoder().decode(OfficialRecord.self, from: Data(json.utf8))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3600)!
        let draft = OfficialRecordImporter.draft(from: record, calendar: calendar)
        try expect(draft.homeTeamName == "Japan 7s（女子7人制）" && draft.awayTeamName == "Fiji 7s（女子7人制）",
                   "SVNS imports keep men's, women's and 15-a-side rosters separate")
        let components = calendar.dateComponents([.day, .hour], from: draft.playedAt)
        try expect(components.day == 19 && components.hour == 1, "Overseas local kickoff converts to the correct absolute instant")
        try expect(draft.seriesName == "Sevens Series 2022 女子" && draft.notes.contains("出典に一部未掲載"),
                   "Explicit series and omissions survive the import draft")
        try expect(draft.members[0].isStarter && !draft.members[1].isStarter && draft.members[1].position == "BK",
                   "SVNS starters are not inferred from jersey numbers")
        try expect(draft.halfMinutes == [7, 7] && draft.events[0].minute == 4 && draft.events[0].half == 1,
                   "SVNS uses seven-minute halves and half-relative minutes")
        try expect(TournamentCategory.inferred(from: draft.tournamentName) == "代表"
                   && TournamentCategory.inferredVariant(from: draft.tournamentName) == .sevens,
                   "SVNS tournament is classified for representative sevens")
    }

    private static func bundledWorldRugbyImports() throws {
        let archive = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Rugby AS/OfficialRecords.sqlite")
        guard FileManager.default.fileExists(atPath: archive.path) else { return }
        var query = OfficialArchiveQuery()
        query.status = "finished"
        var offset = 0
        var checked = 0
        while true {
            let page = try OfficialRecordsStore.search(at: archive, query: query, offset: offset)
            for summary in page.matches where summary.detailLevel == "full" && ["rwc", "svns", "topleague"].contains(summary.source) {
                let record = try OfficialRecordsStore.detail(at: archive, id: summary.id)
                let draft = OfficialRecordImporter.draft(from: record)
                try expect(draft.matchesOfficialScore == true,
                           "Every complete bundled World Rugby / Top League record imports with its official score: \(record.id)")
                let minimumHalf = record.source == "svns" ? 7 : 40
                try expect(draft.halfMinutes[0] >= minimumHalf && draft.halfMinutes[1] >= minimumHalf,
                           "World Rugby records use their competition's minimum half length: \(record.id)")
                if record.source == "svns" {
                    try expect(draft.homeTeamName.hasSuffix("7人制）") && draft.awayTeamName.hasSuffix("7人制）"),
                               "All SVNS imports distinguish their teams from 15-a-side: \(record.id)")
                }
                checked += 1
            }
            offset += page.matches.count
            if page.matches.isEmpty || offset >= page.total { break }
        }
        print("PASS: \(checked) complete bundled World Rugby / Top League import drafts")
    }

    private static func worldCupHistoricScoring() throws {
        let json = """
        {"id":"rwc:1991-final","source":"rwc","season":"1991","year":1991,
         "category":"ラグビーワールドカップ 男子","tournament":"男子ラグビーワールドカップ1991",
         "round":"Final","date":"1991-11-02","kickoff":"15:00","kickoffUTC":"1991-11-02T15:00:00Z",
         "venue":"Twickenham","homeTeam":"England","awayTeam":"Australia","homeScore":6,"awayScore":12,
         "status":"finished","sourceURL":"https://www.world.rugby/match/2173","fetchedAt":"2026-10-03T00:00:00Z",
         "detailLevel":"full","players":[
          {"side":"away","number":1,"name":"Tony Daly","position":"PR","role":"先発"}],
         "scoreEvents":[
          {"period":"前半","time":"27分","side":"away","player":"","kind":"PG","points":3,"homeScore":0,"awayScore":3},
          {"period":"前半","time":"30分","side":"away","player":"Tony Daly","kind":"T4","points":4,"homeScore":0,"awayScore":7},
          {"period":"前半","time":"30分","side":"away","player":"","kind":"G","points":2,"homeScore":0,"awayScore":9},
          {"period":"後半","time":"20分","side":"home","player":"","kind":"PG","points":3,"homeScore":3,"awayScore":9},
          {"period":"後半","time":"25分","side":"away","player":"","kind":"PG","points":3,"homeScore":3,"awayScore":12},
          {"period":"後半","time":"31分","side":"home","player":"","kind":"PG","points":3,"homeScore":6,"awayScore":12}],
         "substitutions":[],"stats":[]}
        """
        let record = try JSONDecoder().decode(OfficialRecord.self, from: Data(json.utf8))
        let draft = OfficialRecordImporter.draft(from: record)
        try expect(draft.matchesOfficialScore == true && draft.score(side: "away") == 12,
                   "The 1991 final uses four-point tries in the import preview")
        try expect(draft.homeTeamName == "England（男子15人制）" && draft.halfMinutes == [40, 40],
                   "World Cup names distinguish gender and 15-a-side, even with partial rosters")
        let container = try container()
        let match = try OfficialRecordImporter.save(draft, context: container.mainContext)
        let events = try container.mainContext.fetch(FetchDescriptor<StatEvent>())
        let tally = try MatchListSummary.load(container: container, sides: [MatchListSide(id: match.id, home: match.homeTeamID, away: match.awayTeamID)])[match.id]
        try expect(tally?.homeScore == 6 && tally?.awayScore == 12, "Saved historical scores survive background list loading")
        let scoring = events.filter { $0.category == "try" }
        try expect(scoring.count == 1, "Historical tries remain ordinary tries for counts and player analysis")
        let historic = scoring[0]
        try expect(RecordingFormatting.score(category: historic.category, outcome: historic.outcome, widgetData: historic.widgetData) == 4,
                   "Recording scoreboard honors historical points")
        let entries = try TeamPerformance.loadScorers(container: container, teamID: match.awayTeamID, matchIDs: [match.id])
        try expect(entries.reduce(0) { $0 + $1.points } == 12 && entries.reduce(0) { $0 + $1.tries } == 1,
                   "Player and team scoring rankings use the same historical value")
        var details = historic.recordingDetails
        details.note = "時刻を確認"
        historic.recordingDetails = details
        try expect(ScoringRules.points(category: "try", widgetData: historic.widgetData) == 4,
                   "Editing notes preserves the historical scoring value")
        try expect(ScoringRules.points(category: "penalty_goal", widgetData: historic.widgetData) == 3,
                   "Changing the scoring category cannot carry four points into a penalty goal")
        try expect(ScoringRules.points(category: "try") == 5
                   && ScoringRules.validatedOfficialPoints(99, category: "try") == nil,
                   "Modern scoring remains unchanged and invalid point overrides are rejected")
        try expect(OfficialRecordImporter.category(forKind: "PT5")?.0 == "penalty_try"
                   && OfficialRecordImporter.historicalPoints(forKind: "PT5") == 5,
                   "Old penalty tries retain five points separately from their conversion")
        let unknownTimeJSON = json.replacingOccurrences(of: "\"period\":\"前半\",\"time\":\"30分\"", with: "\"period\":\"\",\"time\":\"\"")
        let unknownTime = try JSONDecoder().decode(OfficialRecord.self, from: Data(unknownTimeJSON.utf8))
        let unknownDraft = OfficialRecordImporter.draft(from: unknownTime)
        try expect(unknownDraft.matchesOfficialScore == true && unknownDraft.notes.contains { $0.contains("仮に後半") },
                   "Untimed historical scores retain their points and clearly explain provisional timing")
        try expect(!unknownDraft.notes.contains { $0.contains("延長の得点") },
                   "Missing timing is never described as extra time")
        let womenJSON = json.replacingOccurrences(of: "男子", with: "女子")
        let women = try JSONDecoder().decode(OfficialRecord.self, from: Data(womenJSON.utf8))
        try expect(OfficialRecordImporter.draft(from: women).homeTeamName == "England（女子15人制）",
                   "Women's World Cup rosters cannot merge with men's")
    }

    private static func container() throws -> ModelContainer {
        try ModelContainer(for: Team.self, Player.self, Tournament.self, Match.self, StatEvent.self, MatchLineup.self,
                           Substitution.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private static func draftReadsOfficialRecord() throws {
        let draft = OfficialRecordImporter.draft(from: try record())
        try expect(draft.events.count == 6 && draft.notes.contains { $0.contains("読み取れない得点1件") }, "Unreadable score is skipped with a note")
        try expect(draft.score(side: "home") == 19 && draft.score(side: "away") == 3 && draft.matchesOfficialScore == true, "Draft score matches the official score")
        let kinds = draft.events.map { "\($0.category):\($0.outcome):\($0.half):\($0.minute)" }
        try expect(kinds == ["try:success:0:9", "conversion:success:0:10", "penalty_goal:success:0:20", "try:success:0:30",
                             "conversion:fail:0:31", "penalty_try:success:1:5"], "Kinds, halves and minutes map to app records")
        try expect(draft.members.map(\.isStarter) == [true, true, false, true] && draft.members[2].position == RugbyPosition.back.rawValue,
                   "Roles and positions map")
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour], from: draft.playedAt)
        try expect(components.year == 2025 && components.month == 9 && components.day == 14 && components.hour == 13, "Kickoff becomes the match date")
    }

    private static func savesMatchReusingExistingRecords() throws {
        let container = try container()
        let context = container.mainContext
        // 既存: 筑波大学(スペースなし表記の山田太郎・背番号11を既に使用)
        let tsukuba = Team(name: "筑波大学")
        context.insert(tsukuba)
        let yamada = Player(teamID: tsukuba.id, number: 11, name: "山田太郎")
        context.insert(yamada)
        try context.save()

        var draft = OfficialRecordImporter.draft(from: try record())
        draft.events[2].isIncluded = false     // 相手のPGは取り込まない
        let match = try OfficialRecordImporter.save(draft, context: context)

        let teams = try context.fetch(FetchDescriptor<Team>())
        let players = try context.fetch(FetchDescriptor<Player>())
        let events = try context.fetch(FetchDescriptor<StatEvent>()).filter { $0.matchID == match.id }
        let lineups = try context.fetch(FetchDescriptor<MatchLineup>()).filter { $0.matchID == match.id }
        let tournament = try context.fetch(FetchDescriptor<Tournament>()).first
        try expect(teams.count == 2 && match.homeTeamID == tsukuba.id, "Existing team is reused and one team is created")
        try expect(tournament?.officialName == "関東大学リーグ" && tournament?.year == 2025
                   && Set(tournament?.teamIDs ?? []) == Set([match.homeTeamID, match.awayTeamID]), "Tournament is created with both teams")
        try expect(players.filter { $0.name == "山田太郎" || $0.name == "山田 太郎" }.count == 1, "Existing player is matched despite spacing")
        let sato = players.first { $0.name == "佐藤 次郎" }
        try expect(sato?.number == nil && lineups.first { $0.playerID == sato?.id }?.number == 11,
                   "A taken number stays on the lineup only")
        try expect(players.first { $0.name == "鈴木 三郎" }?.number == 23, "A free number becomes the new player's number")
        try expect(lineups.count == 4 && lineups.filter { $0.role == "starter" }.count == 3, "Lineups are saved with roles")
        let scoring = events.filter { $0.category != "match_state" }
        try expect(scoring.count == 5 && !scoring.contains { $0.category == "penalty_goal" }, "Excluded events are not saved")
        try expect(scoring.filter { $0.category == "try" }.allSatisfy { $0.playerID == sato?.id }
                   && scoring.first { $0.category == "conversion" && $0.outcome == "success" }?.playerID == yamada.id,
                   "Scorers link to the lineup players")
        try expect(scoring.first { $0.category == ScoringRules.penaltyTryCategory }.map { $0.playerID == nil && $0.half == 1 && $0.seconds == 300 } == true,
                   "Penalty try has no player and keeps its time")
        let tally = try MatchListSummary.load(context: context,
            sides: [MatchListSide(id: match.id, home: match.homeTeamID, away: match.awayTeamID)])[match.id]
        try expect(tally?.isFinished == true && tally?.homeScore == 19 && tally?.awayScore == 0 && tally?.homeFirstHalf == 12,
                   "Imported match is finished and scores from its events")
    }

    // 7人制: 交代・一時交替(戻りあり/試合終了まで)・退出を取り込み、前後半7分で出場時間を計算する
    private static func substitutionsAndPlayingTime() throws {
        let json = """
        {"id":"jrfu:9","source":"jrfu","season":"2026","year":2026,"category":"7人制女子","tournament":"太陽生命ウィメンズセブンズシリーズ2026 第1戦",
         "round":"","date":"2026-05-01","kickoff":"10:00","venue":"","homeTeam":"A","awayTeam":"B",
         "homeScore":5,"awayScore":0,"homeFirstHalfScore":5,"awayFirstHalfScore":0,"homeSecondHalfScore":0,"awaySecondHalfScore":0,
         "status":"finished","sourceURL":"https://www.rugby-japan.jp/match/9","officialRecordURL":"https://www.rugby-japan.jp/match/9/print",
         "fetchedAt":"2026-05-02T00:00:00Z","detailLevel":"full",
         "players":[
          {"side":"home","number":1,"name":"先発一","position":"","role":"先発"},
          {"side":"home","number":2,"name":"先発二","position":"","role":"先発"},
          {"side":"home","number":3,"name":"先発三","position":"","role":"先発"},
          {"side":"home","number":8,"name":"控え八","position":"","role":"リザーブ"},
          {"side":"home","number":9,"name":"控え九","position":"","role":"リザーブ"},
          {"side":"home","number":10,"name":"控え十","position":"","role":"リザーブ"}],
         "scoreEvents":[{"period":"前半","time":"2分","side":"home","player":"1.先発一","kind":"T","homeScore":5,"awayScore":0}],
         "substitutions":[
          {"side":"home","period":"後半","time":"4分","outgoing":"先発一","incoming":"控え八","kind":"入替"},
          {"side":"home","period":"前半","time":"3分 → 前半5分","outgoing":"先発二","incoming":"控え九","kind":"一時交替 出血"},
          {"side":"home","period":"後半","time":"6分 → 試合終了","outgoing":"3","incoming":"10","kind":"一時交替 HIA"},
          {"side":"home","period":"後半","time":"5分","outgoing":"先発二","incoming":"","kind":"退出"}],
         "stats":[]}
        """
        let record = try JSONDecoder().decode(OfficialRecord.self, from: Data(json.utf8))
        let draft = OfficialRecordImporter.draft(from: record)
        try expect(draft.halfMinutes == [7, 7], "Sevens halves are 7 minutes")
        try expect(draft.substitutions.count == 4, "Temporary replacement becomes off and back; exit is skipped")
        try expect(draft.substitutions.contains { $0.half == 0 && $0.minute == 5 && $0.outgoingName == "控え九" && $0.incomingName == "先発二" },
                   "Blood replacement returns at the recorded time")
        try expect(draft.substitutions.contains { $0.half == 1 && $0.minute == 6 && $0.outgoingName == "先発三" && $0.incomingName == "控え十" },
                   "Numbers only are matched to the lineup")
        try expect(draft.officialPageURL == "https://www.rugby-japan.jp/match/9" && draft.officialSheetURL?.hasSuffix("/print") == true,
                   "Official links are kept")

        let container = try container()
        let context = container.mainContext
        let match = try OfficialRecordImporter.save(draft, context: context)
        let players = try context.fetch(FetchDescriptor<Player>())
        func minutes(_ name: String) throws -> Int {
            let lineups = try context.fetch(FetchDescriptor<MatchLineup>()).filter { $0.matchID == match.id }
            let substitutions = try context.fetch(FetchDescriptor<Substitution>()).filter { $0.matchID == match.id }
            let events = try context.fetch(FetchDescriptor<StatEvent>()).filter { $0.matchID == match.id }
            let result = PlayingTimeCalculator.calculate(matchID: match.id, lineups: lineups, substitutions: substitutions, events: events)
            let id = players.first { $0.name == name }!.id
            return result.minutesByPlayer[id] ?? 0
        }
        try expect(match.officialRecordID == "jrfu:9", "Match remembers its official record")
        let played = try ["先発一", "控え八", "先発二", "控え九", "先発三", "控え十"].map(minutes)
        try expect(played == [11, 3, 12, 2, 13, 1],
                   "Replaced starter, blood replacement and replacement until full time split the 14 minutes (\(played))")
    }

    // リーグワンは得点者が「10.名前」の形。番号を分け、メンバー表の選手に紐づける(重複選手を作らない)
    private static func leagueOneScorerNumbers() throws {
        try expect(OfficialRecordImporter.splitNumber("10.李承信") == (10, "李承信")
                   && OfficialRecordImporter.splitNumber("山田 太郎") == (nil, "山田 太郎")
                   && OfficialRecordImporter.splitNumber("2026年代表") == (nil, "2026年代表")
                   && OfficialRecordImporter.splitNumber(".") == (nil, "") && OfficialRecordImporter.splitNumber(".山田") == (nil, "山田"),
                   "Jersey prefix is split only when followed by a dot; stray dots are dropped")
        var draft = OfficialRecordImporter.draft(from: try record())
        draft.events[0].playerName = "佐藤次郎表記ゆれ"; draft.events[0].playerNumber = 11
        let container = try container()
        let match = try OfficialRecordImporter.save(draft, context: container.mainContext)
        let players = try container.mainContext.fetch(FetchDescriptor<Player>())
        let firstTry = try container.mainContext.fetch(FetchDescriptor<StatEvent>())
            .filter { $0.matchID == match.id && $0.category == "try" }.min { $0.seconds < $1.seconds }
        try expect(!players.contains { $0.name == "佐藤次郎表記ゆれ" } && players.first { $0.id == firstTry?.playerID }?.name == "佐藤 次郎",
                   "Unmatched name falls back to the jersey number")
    }

    private static func groupsTournamentStages() throws {
        let parent = OfficialTournamentGrouping.parentName
        try expect(parent("第62回全国大学ラグビーフットボール選手権大会 準々決勝") == "第62回全国大学ラグビーフットボール選手権大会"
                   && parent("第62回全国大学ラグビーフットボール選手権大会 3回戦") == "第62回全国大学ラグビーフットボール選手権大会"
                   && parent("KOBELCO CUP 第22回全国高等学校合同チームラグビーフットボール大会 U17 決勝リーグ") == "KOBELCO CUP 第22回全国高等学校合同チームラグビーフットボール大会 U17"
                   && parent("KOBELCO CUP 第22回全国高等学校合同チームラグビーフットボール大会 U17予選リーグ") == "KOBELCO CUP 第22回全国高等学校合同チームラグビーフットボール大会 U17"
                   && parent("Women’s College Sevens 2025 第12回大学女子7人制ラグビーフットボール大会 順位決定トーナメント（2日目）") == "Women’s College Sevens 2025 第12回大学女子7人制ラグビーフットボール大会"
                   && parent("決勝") == "決勝" && parent("関東大学リーグ") == "関東大学リーグ", "Stage suffixes are removed; U17 and U18 stay separate")
        try expect(OfficialTournamentGrouping.stageName("第62回全国大学ラグビーフットボール選手権大会 準決勝") == "準決勝", "Stage name is kept for display")
        // 回の分からない名前は年ごとに分ける
        let groups = OfficialTournamentGrouping.groups(from: [
            OfficialTournamentStage(tournament: "大会A 準決勝", year: 2025, matchCount: 2, firstDate: "2025-12-01", lastDate: "2025-12-01", finishedCount: 2),
            OfficialTournamentStage(tournament: "大会A 決勝", year: 2025, matchCount: 1, firstDate: "2025-12-08", lastDate: "2025-12-08", finishedCount: 1),
            OfficialTournamentStage(tournament: "大会A 決勝", year: 2024, matchCount: 1, firstDate: "2024-12-08", lastDate: "2024-12-08", finishedCount: 0)])
        try expect(groups.count == 2 && groups[0].name == "大会A" && groups[0].year == 2025 && groups[0].matchCount == 3
                   && groups[0].stages == ["大会A 決勝", "大会A 準決勝"] && groups[0].lastDate == "2025-12-08", "Stages group by parent name and year")
        // 「第N回」の大会は年末年始をまたいでも1つ。年度は始まった年
        let spanning = OfficialTournamentGrouping.groups(from: [
            OfficialTournamentStage(tournament: "第62回選手権 準々決勝", year: 2025, matchCount: 4, firstDate: "2025-12-20", lastDate: "2025-12-20", finishedCount: 4),
            OfficialTournamentStage(tournament: "第62回選手権 決勝", year: 2026, matchCount: 1, firstDate: "2026-01-11", lastDate: "2026-01-11", finishedCount: 1)])
        try expect(spanning.count == 1 && spanning[0].year == 2025 && spanning[0].years == [2025, 2026] && spanning[0].matchCount == 5,
                   "Numbered tournaments spanning New Year stay together")
        try expect(OfficialTournamentGrouping.parentName("ジュニア選手権 13位決定戦・準決勝") == "ジュニア選手権",
                   "Trailing separators are trimmed")
        try expect(parent("セブンズ札幌大会 入替戦") == "セブンズ札幌大会" && parent("セブンズ札幌大会 ５位決定") == "セブンズ札幌大会"
                   && parent("第26回選抜大会 1回戦敗者戦") == "第26回選抜大会" && parent("セブンズ札幌大会 エキシビション") == "セブンズ札幌大会"
                   && parent("第105回全国高等学校大会 第18回U18合同チーム東西対抗戦") == "第105回全国高等学校大会 第18回U18合同チーム東西対抗戦",
                   "Placement games and exhibitions join the tournament; side events stay separate")
    }

    private static func detectsSeries() throws {
        let series = OfficialTournamentGrouping.seriesName
        try expect(series("太陽生命ウィメンズセブンズシリーズ2026 第1戦熊谷大会") == "太陽生命ウィメンズセブンズシリーズ2026"
                   && series("太陽生命ウィメンズセブンスシリーズ2026 第3戦北九州大会") == "太陽生命ウィメンズセブンズシリーズ2026"
                   && series("太陽生命ウィメンズセブンズシリーズ2026 グランドファイナル札幌大会 準決勝") == "太陽生命ウィメンズセブンズシリーズ2026"
                   && series("太陽生命ウィメンズセブンズシリーズ2026 チャレンジャートーナメント第1戦名古屋大会") == "太陽生命ウィメンズセブンズシリーズ2026 チャレンジャートーナメント"
                   && series("第62回全国大学ラグビーフットボール選手権大会 決勝") == nil
                   && series("ワールドラグビーセブンズシリーズ2026") == nil, "Series names are detected, spelling variants unified, challengers kept apart")
        // 取り込みで新しく作った大会にシリーズ名が付き、手で付けた名前は上書きしない
        let container = try container()
        let context = container.mainContext
        var draft = OfficialRecordImporter.draft(from: try record())
        draft.seriesName = "シリーズA"
        try OfficialRecordImporter.save(draft, context: context)
        let created = try context.fetch(FetchDescriptor<Tournament>()).first
        try expect(created?.seriesName == "シリーズA", "Imported tournament gets the series name")
        created?.seriesName = "手で付けた名前"
        var second = draft
        second.playedAt = draft.playedAt.addingTimeInterval(86_400)
        try OfficialRecordImporter.save(second, context: context)
        let kept = try context.fetch(FetchDescriptor<Tournament>()).first?.seriesName
        try expect(kept == "手で付けた名前", "A manual series name is kept")
        // 起動時の後付け: シリーズ名のない古い大会にだけ1回付ける
        let suite = "rugby-as-series-backfill." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = Tournament(officialName: "太陽生命ウィメンズセブンズシリーズ2026 グランドファイナル札幌大会 入替戦")
        let cleared = Tournament(officialName: "太陽生命ウィメンズセブンズシリーズ2026 第1戦熊谷大会", seriesName: "")
        let plain = Tournament(officialName: "関東大学リーグ戦")
        [old, cleared, plain].forEach { context.insert($0) }
        try context.save()
        try expect(OfficialTournamentGrouping.backfillSeriesNames(context: context, defaults: defaults) == 2
                   && old.seriesName == "太陽生命ウィメンズセブンズシリーズ2026" && plain.seriesName == nil
                   && kept == "手で付けた名前", "Backfill fills only missing series names")
        old.seriesName = nil
        try expect(OfficialTournamentGrouping.backfillSeriesNames(context: context, defaults: defaults) == 0 && old.seriesName == nil,
                   "Backfill runs only once")
    }

    private static func savesWholeTournament() throws {
        let container = try container()
        let context = container.mainContext
        var first = OfficialRecordImporter.draft(from: try record())
        var second = first
        second.playedAt = first.playedAt.addingTimeInterval(7 * 86_400)
        first.tournamentName = "関東大学リーグ"; second.tournamentName = " 関東 大学リーグ "
        let matches = try OfficialRecordImporter.saveAll([first, second], context: context)
        let tournaments = try context.fetch(FetchDescriptor<Tournament>())
        let teams = try context.fetch(FetchDescriptor<Team>())
        let players = try context.fetch(FetchDescriptor<Player>())
        try expect(matches.count == 2 && tournaments.count == 1 && Set(matches.map(\.tournamentID)) == [tournaments[0].id],
                   "All matches go into one tournament")
        try expect(teams.count == 2 && players.count == 4, "Teams and players created by the first match are reused by the next")
        var broken = first
        broken.awayTeamName = broken.homeTeamName
        var failed = false
        do { try OfficialRecordImporter.saveAll([second, broken], context: context) } catch { failed = true }
        let afterFailure = try context.fetch(FetchDescriptor<Match>())
        try expect(failed && afterFailure.count == 2, "A failing match saves none of the batch")
    }

    private static func invalidDraftLeavesNothing() throws {
        let container = try container()
        let context = container.mainContext
        var draft = OfficialRecordImporter.draft(from: try record())
        draft.awayTeamName = " 筑波 大学 "
        var failed = false
        do { try OfficialRecordImporter.save(draft, context: context) } catch { failed = true }
        let matches = try context.fetch(FetchDescriptor<Match>())
        let teams = try context.fetch(FetchDescriptor<Team>())
        try expect(failed && matches.isEmpty && teams.isEmpty, "Same team on both sides is rejected without saving anything")
    }
}
