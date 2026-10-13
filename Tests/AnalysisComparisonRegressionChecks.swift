import Foundation
import SwiftData

enum AnalysisComparisonRegressionChecks {
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw NSError(domain: "AnalysisComparisonChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func run() throws {
        let team = UUID(), opponent = UUID(), otherTeam = UUID(), tournament = UUID(), player = UUID()
        var matches: [Match] = []
        for index in 0..<8 {
            let tournamentID: UUID = index == 7 ? UUID() : tournament
            let homeID: UUID = index == 6 ? otherTeam : team
            let date = Date(timeIntervalSince1970: Double(index) * 60)
            matches.append(Match(tournamentID: tournamentID, homeTeamID: homeID, awayTeamID: opponent, playedAt: date))
        }
        let events: [StatEvent] = matches.map { StatEvent(matchID: $0.id, teamID: $0.homeTeamID, playerID: player,
            category: "tackle", outcome: "success", seconds: 60, half: 1) }
        var scope = AnalysisScope(tournamentID: tournament, recentLimit: 2)
        scope.filter.teamID = team
        let selected = scope.selectedMatches(from: matches, events: events, lineups: [])
        try expect(selected.map(\.id) == [matches[5].id, matches[4].id], "Team and tournament conditions must apply before recent-match limit")

        scope.matchIDs = [matches[1].id, matches[3].id, UUID()]
        try expect(scope.selectedMatches(from: matches, events: events, lineups: []).map(\.id) == [matches[3].id, matches[1].id], "Explicit selection must intersect scope and ignore stale IDs")

        scope.matchIDs = []; scope.filter.player = player.uuidString
        let sparseEvents = [events[0], events[2]]
        try expect(scope.selectedMatches(from: matches, events: sparseEvents, lineups: []).map(\.id) == [matches[2].id, matches[0].id], "A player's recent matches must use their participation before applying the limit")

        scope.filter.half = 0
        try expect(scope.selectedEvents(from: events, matches: selected).isEmpty, "Cross-match results must honor the same half conditions as single-match analysis")
        scope.filter.half = 1
        let filtered = scope.selectedEvents(from: events, matches: selected)
        try expect(filtered.count == 2 && Set(filtered.map(\.matchID)) == Set(selected.map(\.id)), "Excluded matches must not leak into comparison")

        let missing = StatEvent(matchID: selected[0].id, category: "tackle", outcome: "fail", seconds: 90)
        let playerRows = AnalysisComparison.playerRows(events: filtered + [missing], category: "tackle")
        try expect(playerRows.count == 1 && playerRows[0].summary.count == 2 && playerRows[0].summary.successRate == 1, "Unassigned plays must not be attributed to a player")

        // 表に出す人数だけ集計しても、並び・値は全員分を集計したときの先頭と同じ
        let many = (0..<7).flatMap { index -> [StatEvent] in
            let player = UUID()
            return (0..<(index % 3 + 1)).map { second in
                StatEvent(matchID: selected[0].id, playerID: player, category: "tackle",
                          outcome: second % 2 == 0 ? "success" : "fail", seconds: second)
            }
        } + [missing]
        let all = AnalysisComparison.playerRows(events: many, category: "tackle")
        let top = AnalysisComparison.topPlayerRows(events: many, category: "tackle", limit: 4)
        try expect(top.total == all.count && top.rows.map(\.id) == all.prefix(4).map(\.id)
                   && top.rows.map(\.summary) == all.prefix(4).map(\.summary),
                   "Top player rows must match the first rows of the full ranking")

        let rows = AnalysisComparison.matchRows(matches: matches, events: filtered, category: "tackle")
        try expect(rows.count == 8 && rows.filter { $0.summary.count == 0 }.allSatisfy { $0.summary.successRate == nil }, "Unrecorded matches must show no success rate rather than a false zero")

        let custom = StatEvent(matchID: matches[0].id, category: "custom_attack", outcome: "count", seconds: 0)
        var details = RecordingEventDetails(); details.title = "独自の攻撃"; custom.recordingDetails = details
        let definitions = AnalysisComparison.definitions(events: events + [custom])
        try expect(definitions.filter { $0.category == "tackle" }.count == 1 && definitions.contains { $0.category == "custom_attack" && $0.title == "独自の攻撃" }, "Custom metrics must remain available and catalog aliases must not duplicate comparison rows")
        print("PASS: 9 cross-match analysis regression checks")
    }

    /// 分析画面の裏の集計(AnalysisWorkspaceLoader)が、画面で直接計算していた頃と同じ結果を返すこと
    static func runWorkspaceLoader() async throws {
        // ファイルに保存する形にして、保存先を直接読む速い読み方も確かめる
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let container = try ModelContainer(for: Team.self, Player.self, Tournament.self, Match.self,
            StatEvent.self, MatchLineup.self, Substitution.self,
            configurations: ModelConfiguration(url: folder.appendingPathComponent("analysis.store")))
        let context = container.mainContext
        let home = Team(name: "ホーム"), away = Team(name: "アウェイ")
        let tournament = Tournament(officialName: "検証大会")
        let scorer = Player(teamID: home.id, number: 10, name: "得点者")
        [home, away].forEach { context.insert($0) }
        context.insert(tournament); context.insert(scorer)
        var matches: [Match] = []
        for index in 0..<6 {
            let match = Match(tournamentID: tournament.id, homeTeamID: home.id, awayTeamID: away.id,
                              playedAt: Date(timeIntervalSince1970: Double(index) * 86_400),
                              isExcludedFromStats: index == 5)
            context.insert(match); matches.append(match)
            for second in 0..<(index + 1) {
                context.insert(StatEvent(matchID: match.id, teamID: home.id, playerID: second == 0 ? scorer.id : nil,
                                         category: "tackle", outcome: second % 2 == 0 ? "success" : "fail", seconds: second * 60, half: 0))
            }
            context.insert(StatEvent(matchID: match.id, teamID: away.id, category: "try", outcome: "success", seconds: 600, half: 1))
            context.insert(StatEvent(matchID: match.id, category: "match_state", outcome: "finished", seconds: 0))
        }
        let custom = StatEvent(matchID: matches[0].id, teamID: home.id, category: "custom_attack", outcome: "count", seconds: 0)
        var details = RecordingEventDetails(); details.title = "独自の攻撃"; custom.recordingDetails = details
        context.insert(custom)
        try context.save()

        let templateCategories = RecordingMetricCatalog.templates.map(\.widget).filter { !$0.kind.isDisplay }.map(\.category)
        let loader = AnalysisWorkspaceLoader(modelContainer: container)
        var scope = AnalysisScope(recentLimit: 3)
        scope.filter.teamID = home.id
        let result = try await loader.compute(AnalysisWorkspaceRequest(scope: scope, category: "tackle",
                                                                       templateCategories: templateCategories))

        // 以前の画面と同じ計算を、同じデータで直接行う
        let allMatches = try context.fetch(FetchDescriptor<Match>())
        let allEvents = try context.fetch(FetchDescriptor<StatEvent>())
        let selected = scope.selectedMatches(from: allMatches, events: allEvents, lineups: [])
        let categoryEvents = scope.selectedEvents(from: allEvents, matches: selected).filter { $0.category == "tackle" }
        let expectedOverall = RecordingMetricAggregation.summary(events: categoryEvents, category: "tackle")
        let expectedRows = AnalysisComparison.matchRows(matches: selected, events: categoryEvents, category: "tackle")

        try expect(result.selectedCount == selected.count && result.selectedCount == 3, "The background summary selects the same matches")
        try expect(result.matchRows.map(\.id) == selected.map(\.id), "Match rows keep the newest-first order")
        try expect(result.overall == expectedOverall, "The overall summary is unchanged")
        try expect(result.matchRows.map(\.summary) == expectedRows.map(\.summary), "Per-match summaries are unchanged")
        try expect(result.playerRows.count == 1 && result.playerTotal == 1 && result.playerRows[0].name == "得点者 · ホーム", "Player rows carry display names")
        try expect(result.unassignedCount == categoryEvents.filter { $0.playerID == nil }.count, "Unassigned plays are counted")
        try expect(result.excludedCount == 1 && result.allMatches.count == 6, "Excluded matches are still listed for selection")
        try expect(result.matchRows.first?.title == "ホーム vs アウェイ", "Match titles use team names")
        try expect(result.choices.customSamples.contains { $0.category == "custom_attack" && $0.customTitle == "独自の攻撃" }
                   && result.choices.presentTemplateCategories.contains("tackle") && !result.choices.presentTemplateCategories.contains("match_state"),
                   "Metric choices match the previous definitions")

        let rows = StoreFileReader.analysisRows(storeURL: container.configurations.first?.url)
        let saved = try context.fetch(FetchDescriptor<StatEvent>()).filter { $0.category != "match_state" && $0.category != "possession" }
        try expect(rows?.count == saved.count
                   && rows.map { Set($0.map { "\($0.id)|\($0.matchID)|\($0.teamID?.uuidString ?? "")|\($0.playerID?.uuidString ?? "")|\($0.category)|\($0.outcome)|\($0.half)|\($0.seconds)|\($0.recordingDetails.title ?? "")" }) }
                      == Set(saved.map { "\($0.id)|\($0.matchID)|\($0.teamID?.uuidString ?? "")|\($0.playerID?.uuidString ?? "")|\($0.category)|\($0.outcome)|\($0.half)|\($0.seconds)|\($0.recordingDetails.title ?? "")" }),
                   "Reading plays straight from the store gives the same values as SwiftData")

        // マイ分析レポートも、以前と同じ指標ごとの値になる
        let report = try await loader.report(scope, templateCategories: templateCategories)
        let expectedSnapshot = AnalysisMetricSnapshot(events: scope.selectedEvents(from: allEvents, matches: selected))
        try expect(report.selectedCount == selected.count
                   && report.snapshot.summary(for: "tackle") == expectedSnapshot.summary(for: "tackle")
                   && report.snapshot.summary(for: "try") == expectedSnapshot.summary(for: "try")
                   && report.snapshot.recordedMatchCount(for: "tackle") == expectedSnapshot.recordedMatchCount(for: "tackle"),
                   "Report metrics are unchanged")

        // データが変わったら、控えを捨てて読み直す
        context.insert(StatEvent(matchID: matches[4].id, teamID: home.id, category: "tackle", outcome: "success", seconds: 900, half: 0))
        try context.save()
        let stale = try await loader.compute(AnalysisWorkspaceRequest(scope: scope, category: "tackle", templateCategories: templateCategories))
        await loader.invalidate()
        let fresh = try await loader.compute(AnalysisWorkspaceRequest(scope: scope, category: "tackle", templateCategories: templateCategories))
        try expect(fresh.overall.count == stale.overall.count + 1, "Invalidating reloads saved changes")

        // アプリで使う集計係は、メインスレッドの外で計算する(メインで動くと、集計の間アプリ全体が固まる)
        let shared = AnalysisLoaderStore.loader(for: container)
        let again = AnalysisLoaderStore.loader(for: container)
        try expect(shared === again, "Screens share one loader so plays are not reloaded on every visit")
        let sharedOnMain = await shared.runsOnMainThread()
        let directOnMain = await loader.runsOnMainThread()
        try expect(!sharedOnMain && !directOnMain, "The loader computes off the main thread even when made on the main thread")
        print("PASS: 14 analysis workspace loader checks")
    }
}

extension AnalysisWorkspaceLoader {
    func runsOnMainThread() -> Bool { Thread.isMainThread }
}
