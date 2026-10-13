import Foundation
import SwiftData

// チームの統合: 付け替え・別名・取り込みの照合・バックアップ・対戦があるときの拒否を確かめる。
@main
@MainActor
enum IdentityMergeChecks {
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw NSError(domain: "IdentityMergeChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "FAIL: " + message]) }
        print("PASS: " + message)
    }

    static func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Team.self, Player.self, Tournament.self, Match.self,
            StatEvent.self, MatchLineup.self, Substitution.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    static func main() async throws {
        let normalizedKeys = await Task.detached {
            let names: [String?] = ["ＰＥＡＲＬＳ", " Pearls ", "山田・太郎", "山田･太郎", nil]
            return names.map(DuplicateFinder.key)
        }.value
        try expect(normalizedKeys == ["pearls", "pearls", "山田太郎", "山田太郎", ""],
                   "Name normalization is callable off the main actor and preserves duplicate matching")
        try teamMerge()
        try playerMerge()
        try personLink()
        try duplicateFinder()
        try tournamentCategory()
        try competitionFilter()
        try teamFolders()
        try tournamentFolders()
        try tournamentDeletion()
        try bulkCandidates()
        print("PASS: all identity merge checks")
    }

    static func teamMerge() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let target = Team(name: "三重パールズ")
        let source = Team(name: "PEARLS", colorHex: "#123456", aliases: ["パールズ"])
        let rival = Team(name: "相手")
        [target, source, rival].forEach { context.insert($0) }
        let tournament = Tournament(officialName: "大会", teamIDs: [source.id, target.id, rival.id])
        context.insert(tournament)
        let player = Player(teamID: source.id, number: 7, name: "山田")
        context.insert(player)
        let match = Match(tournamentID: tournament.id, homeTeamID: rival.id, awayTeamID: source.id, playedAt: .now)
        match.recordingSessionData = Data("{\"selectedTeamID\":\"\(source.id.uuidString)\"}".utf8)
        context.insert(match)
        context.insert(StatEvent(matchID: match.id, teamID: source.id, playerID: player.id, category: "try", outcome: "success", seconds: 60))
        context.insert(MatchLineup(matchID: match.id, teamID: source.id, playerID: player.id, role: "starter", order: 0))
        try context.save()

        let suite = "rugby-as-merge-checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var report = AnalysisReport(); report.scope.filter.teamID = source.id
        defaults.set(try JSONEncoder().encode([report]), forKey: AnalysisReport.storageKey)

        let impact = try TeamMerge.impact(of: source, into: target, context: context)
        try expect(impact == TeamMerge.Impact(matches: 1, players: 1, events: 1, lineups: 1, tournaments: 1, matchesBetween: 0),
                   "Impact counts what moves")

        let sourceID = source.id
        try expect(TeamMerge.merge(source, into: target, context: context, defaults: defaults, removeImage: { _ in }), "Merge succeeds")
        try expect(try context.fetch(FetchDescriptor<Team>()).allSatisfy { $0.id != sourceID }, "Merged team is removed")
        try expect(match.awayTeamID == target.id, "Match side moves to the kept team")
        try expect(player.teamID == target.id, "Players move to the kept team")
        try expect(try context.fetch(FetchDescriptor<StatEvent>()).first?.teamID == target.id, "Events move")
        try expect(try context.fetch(FetchDescriptor<MatchLineup>()).first?.teamID == target.id, "Lineups move")
        try expect(tournament.teamIDs == [target.id, rival.id], "Tournament entries merge without duplicates")
        try expect(String(decoding: match.recordingSessionData!, as: UTF8.self).contains(target.id.uuidString)
                   && !String(decoding: match.recordingSessionData!, as: UTF8.self).contains(sourceID.uuidString),
                   "In-progress recording state follows the merge")
        let reports = try JSONDecoder().decode([AnalysisReport].self, from: defaults.data(forKey: AnalysisReport.storageKey)!)
        try expect(reports.first?.scope.filter.teamID == target.id, "Saved analysis reports follow the merge")
        try expect(target.aliases == ["PEARLS", "パールズ"], "Old names become aliases")
        try expect(target.colorHex == "#123456", "Empty settings are taken from the merged team")

        // 取り込み: 別名でも同じチームとして見つかる(全角・空白の違いも吸収)
        let teams = try context.fetch(FetchDescriptor<Team>())
        try expect(OfficialRecordImporter.existingTeam(named: "ＰＥＡＲＬＳ", in: teams)?.id == target.id, "Import finds the team by alias")

        // 対戦したことのある2チームは統合できない
        let impactRival = try TeamMerge.impact(of: rival, into: target, context: context)
        try expect(impactRival.matchesBetween == 1, "Impact reports matches between the two teams")
        try expect(!TeamMerge.merge(rival, into: target, context: context, defaults: defaults, removeImage: { _ in })
                   && (try context.fetch(FetchDescriptor<Team>()).contains { $0.id == rival.id })
                   && match.homeTeamID == rival.id, "Teams that played each other are not merged and nothing changes")

        // バックアップ: 別名が往復し、別名のない古いファイルも読める
        let data = try BackupManager.makeBackupData(context: context, defaults: defaults)
        let restoredContainer = try makeContainer()
        try BackupManager.restore(from: data, context: restoredContainer.mainContext, defaults: defaults)
        let restoredTeam = try restoredContainer.mainContext.fetch(FetchDescriptor<Team>()).first { $0.id == target.id }
        try expect(restoredTeam?.aliases == ["PEARLS", "パールズ"], "Backup keeps aliases")
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json["teams"] = (json["teams"] as! [[String: Any]]).map { var item = $0; item.removeValue(forKey: "aliases"); return item }
        let oldContainer = try makeContainer()
        try BackupManager.restore(from: try JSONSerialization.data(withJSONObject: json), context: oldContainer.mainContext, defaults: defaults)
        try expect(try oldContainer.mainContext.fetch(FetchDescriptor<Team>()).first { $0.id == target.id }?.aliases == [],
                   "Old backups without aliases still restore")
    }

    static func playerMerge() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let team = Team(name: "チーム"), other = Team(name: "他チーム")
        context.insert(team); context.insert(other)
        let tournament = Tournament(officialName: "大会")
        context.insert(tournament)
        let target = Player(teamID: team.id, number: 10, name: "佐藤 花子")
        let source = Player(teamID: team.id, number: nil, name: "鈴木花子", nameKana: "すずき はなこ", isFavorite: true, heightCm: 160)
        let teammate = Player(teamID: team.id, number: 9, name: "田中")
        let elsewhere = Player(teamID: other.id, number: 10, name: "佐藤 花子")
        [target, source, teammate, elsewhere].forEach { context.insert($0) }
        let early = Match(tournamentID: tournament.id, homeTeamID: team.id, awayTeamID: other.id, playedAt: .now.addingTimeInterval(-86_400))
        let late = Match(tournamentID: tournament.id, homeTeamID: team.id, awayTeamID: other.id, playedAt: .now)
        context.insert(early); context.insert(late)
        context.insert(StatEvent(matchID: early.id, teamID: team.id, playerID: source.id, category: "try", outcome: "success", seconds: 30))
        context.insert(MatchLineup(matchID: early.id, teamID: team.id, playerID: source.id, role: "starter", order: 0))
        context.insert(Substitution(matchID: early.id, playerInID: teammate.id, playerOutID: source.id, minute: 20))
        context.insert(MatchLineup(matchID: late.id, teamID: team.id, playerID: target.id, role: "starter", order: 0))
        early.recordingSessionData = Data("{\"scorerID\":\"\(source.id.uuidString)\"}".utf8)
        try context.save()

        let suite = "rugby-as-player-merge-checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var report = AnalysisReport(); report.scope.filter.player = source.id.uuidString
        defaults.set(try JSONEncoder().encode([report]), forKey: AnalysisReport.storageKey)

        try expect(try PlayerMerge.impact(of: source, into: target, context: context)
                   == PlayerMerge.Impact(matches: 1, events: 1, lineups: 1, substitutions: 1, matchesTogether: 0),
                   "Player impact counts what moves")
        try expect(!PlayerMerge.merge(elsewhere, into: target, context: context, defaults: defaults, removeImage: { _ in })
                   && elsewhere.teamID == other.id, "Players on other teams are not merged")

        let sourceID = source.id
        try expect(PlayerMerge.merge(source, into: target, context: context, defaults: defaults, removeImage: { _ in }), "Player merge succeeds")
        try expect(try context.fetch(FetchDescriptor<Player>()).allSatisfy { $0.id != sourceID }, "Merged player is removed")
        try expect(try context.fetch(FetchDescriptor<StatEvent>()).first?.playerID == target.id, "Scoring moves to the kept player")
        try expect(try context.fetch(FetchDescriptor<MatchLineup>()).allSatisfy { $0.playerID == target.id }, "Lineups move")
        try expect(try context.fetch(FetchDescriptor<Substitution>()).first?.playerOutID == target.id, "Substitutions move")
        try expect(String(decoding: early.recordingSessionData!, as: UTF8.self).contains(target.id.uuidString), "Recording state follows the player")
        let reports = try JSONDecoder().decode([AnalysisReport].self, from: defaults.data(forKey: AnalysisReport.storageKey)!)
        try expect(reports.first?.scope.filter.player == target.id.uuidString, "Saved reports follow the player")
        try expect(target.name == "佐藤 花子" && target.number == 10 && target.aliases == ["鈴木花子"], "Kept name stays and the old name becomes an alias")
        try expect(target.nameKana == "すずき はなこ" && target.heightCm == 160 && target.isFavorite, "Empty profile fields are filled")

        // 同じ試合のメンバー表に2人とも載っていたら別人なので統合しない
        context.insert(MatchLineup(matchID: late.id, teamID: team.id, playerID: teammate.id, role: "starter", order: 1))
        try context.save()
        try expect(try PlayerMerge.impact(of: teammate, into: target, context: context).matchesTogether == 2
                   && !PlayerMerge.merge(teammate, into: target, context: context, defaults: defaults, removeImage: { _ in })
                   && (try context.fetch(FetchDescriptor<Player>()).contains { $0.id == teammate.id }),
                   "Players listed in the same match are not merged")

        // バックアップ: 別名が往復する
        let data = try BackupManager.makeBackupData(context: context, defaults: defaults)
        let restoredContainer = try makeContainer()
        try BackupManager.restore(from: data, context: restoredContainer.mainContext, defaults: defaults)
        try expect(try restoredContainer.mainContext.fetch(FetchDescriptor<Player>()).first { $0.id == target.id }?.aliases == ["鈴木花子"],
                   "Backup keeps player aliases")
    }

    static func personLink() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let club = Team(name: "クラブ"), national = Team(name: "日本代表"), prefecture = Team(name: "国体")
        [club, national, prefecture].forEach { context.insert($0) }
        let clubPlayer = Player(teamID: club.id, number: 10, name: "山田")
        let nationalPlayer = Player(teamID: national.id, number: 12, name: "山田")
        let prefecturePlayer = Player(teamID: prefecture.id, number: 9, name: "山田")
        [clubPlayer, nationalPlayer, prefecturePlayer].forEach { context.insert($0) }
        try context.save()

        try expect(PersonLink.linkedPlayers(of: clubPlayer, context: context).map(\.id) == [clubPlayer.id], "Unlinked player stands alone")
        try expect(PersonLink.link(clubPlayer, with: nationalPlayer, context: context), "Link two registrations")
        try expect(clubPlayer.personID != nil && clubPlayer.personID == nationalPlayer.personID, "Linked players share a person ID")
        try expect(PersonLink.link(prefecturePlayer, with: nationalPlayer, context: context)
                   && Set(PersonLink.linkedPlayers(of: clubPlayer, context: context).map(\.id))
                   == Set([clubPlayer.id, nationalPlayer.id, prefecturePlayer.id]), "Linking joins the whole group")
        try expect(clubPlayer.teamID == club.id && nationalPlayer.number == 12, "Links keep each team's registration")

        try expect(PersonLink.unlink(prefecturePlayer, context: context) && prefecturePlayer.personID == nil
                   && clubPlayer.personID != nil, "Unlink one keeps the others linked")
        try expect(PersonLink.unlink(nationalPlayer, context: context) && clubPlayer.personID == nil,
                   "The last one left is unlinked too")

        PersonLink.link(clubPlayer, with: nationalPlayer, context: context)
        let suite = "rugby-as-person-link-checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let data = try BackupManager.makeBackupData(context: context, defaults: defaults)
        let restoredContainer = try makeContainer()
        try BackupManager.restore(from: data, context: restoredContainer.mainContext, defaults: defaults)
        let restored = try restoredContainer.mainContext.fetch(FetchDescriptor<Player>())
        try expect(restored.first { $0.id == clubPlayer.id }?.personID == clubPlayer.personID
                   && restored.first { $0.id == nationalPlayer.id }?.personID == clubPlayer.personID, "Backup keeps person links")
    }

    static func duplicateFinder() throws {
        let tournamentID = UUID()
        let pearls = Team(name: "PEARLS"), mie = Team(name: "三重 PEARLS"), rival = Team(name: "PEARLS B")
        let national = Team(name: "日本代表")
        let teams = [pearls, mie, rival, national]
        let a = Player(teamID: pearls.id, number: 1, name: "佐藤花子")
        let typo = Player(teamID: pearls.id, number: nil, name: "佐藤 花子")
        let teammate = Player(teamID: pearls.id, number: 2, name: "田中", nameKana: "たなか")
        let sameKana = Player(teamID: pearls.id, number: 3, name: "田仲", nameKana: "たなか")
        let abroad = Player(teamID: national.id, number: 9, name: "佐藤・花子")
        let players = [a, typo, teammate, sameKana, abroad]
        let played = Match(tournamentID: tournamentID, homeTeamID: pearls.id, awayTeamID: rival.id, playedAt: .now)
        let lineups = [MatchLineup(matchID: played.id, teamID: pearls.id, playerID: teammate.id, role: "starter", order: 0),
                       MatchLineup(matchID: played.id, teamID: pearls.id, playerID: sameKana.id, role: "starter", order: 1)]

        let found = DuplicateFinder.candidates(teams: teams, players: players, matches: [played], lineups: lineups)
        func has(_ kind: DuplicateFinder.Kind, _ x: UUID, _ y: UUID) -> Bool {
            found.contains { $0.kind == kind && Set([$0.firstID, $0.secondID]) == Set([x, y]) }
        }
        try expect(has(.team, pearls.id, mie.id), "Similar team names are candidates")
        try expect(!has(.team, pearls.id, rival.id), "Teams that played each other are not candidates")
        try expect(has(.playerSameTeam, a.id, typo.id), "Same-team spelling differences are candidates")
        try expect(!has(.playerSameTeam, teammate.id, sameKana.id), "Players in the same match are not candidates")
        try expect(has(.playerOtherTeam, a.id, abroad.id), "Same name on another team is a link candidate")

        abroad.personID = UUID(); a.personID = abroad.personID
        let afterLink = DuplicateFinder.candidates(teams: teams, players: players, matches: [played], lineups: lineups)
        try expect(!afterLink.contains { Set([$0.firstID, $0.secondID]) == Set([a.id, abroad.id]) }, "Linked players are no longer candidates")

        let dismissed = found.first { $0.kind == .team }!
        let reversed = DuplicateFinder.Candidate(kind: .team, firstID: dismissed.secondID, secondID: dismissed.firstID, reason: "")
        try expect(dismissed.id == reversed.id, "A pair has the same ID in either order")
        let afterDismiss = DuplicateFinder.candidates(teams: teams, players: players, matches: [played], lineups: lineups,
                                                      dismissed: [dismissed.id])
        try expect(!afterDismiss.contains { $0.id == dismissed.id }, "Dismissed pairs are hidden")

        // 画面用の読み込み(裏で必要な分だけ読む)も、同じ候補と出場の様子になる
        let container = try makeContainer()
        let context = container.mainContext
        teams.forEach { context.insert($0) }
        players.forEach { context.insert($0) }
        context.insert(played)
        lineups.forEach { context.insert($0) }
        context.insert(StatEvent(matchID: played.id, teamID: pearls.id, playerID: a.id, category: "try", outcome: "success", seconds: 1))
        try context.save()
        let screen = DuplicateFinder.loadScreen(container: container, dismissed: [dismissed.id])
        let direct = DuplicateFinder.candidates(teams: teams, players: players, matches: [played], lineups: lineups, dismissed: [dismissed.id])
        try expect(Set(screen.candidates.map(\.id)) == Set(direct.map(\.id)), "The screen finds the same candidates while reading only what it needs")
        let allActivity = DuplicateFinder.activities(context: context)
        let shown = Set(direct.flatMap { [$0.firstID, $0.secondID] })
        try expect(shown.allSatisfy { screen.activity[$0] == allActivity[$0] } && screen.activity[a.id]?.matchCount == 1,
                   "Activity for every candidate matches the full calculation")
    }

    static func tournamentCategory() throws {
        let cases: [(String, String?, RugbyVariant?)] = [
            ("NTTジャパンラグビー リーグワン 2025-26 ディビジョン1", "トップ", .fifteens),
            ("太陽生命ウィメンズセブンズシリーズ2026 第1戦熊谷大会", "トップ", .sevens),
            ("太陽生命ウィメンズセブンスシリーズ2026 第3戦北九州大会", "トップ", .sevens),
            ("第62回全国大学ラグビーフットボール選手権大会", "大学", .fifteens),
            ("Women’s College Sevens 2026 第13回大学女子7人制ラグビーフットボール大会", "大学", .sevens),
            ("第105回全国高等学校ラグビーフットボール大会", "高校", .fifteens),
            ("第13回全国高等学校7人制ラグビーフットボール大会", "高校", .sevens),
            ("太陽生命カップ2026 第17回全国中学生ラグビーフットボール大会 (12人制) 第１ブロック 中学校男子", "中学", nil),
            ("太陽生命カップ2026 第17回全国中学生ラグビーフットボール大会 (7人制) 第3ブロック 都道府県代表女子", "中学", .sevens),
            ("第55回全国高等専門学校ラグビーフットボール大会", "高専", .fifteens),
            ("アサヒスーパードライ パシフィックネーションズカップ2026", "代表", .fifteens),
            ("第33回全国クラブラグビーフットボール大会", "クラブ", nil),
            ("なの花薬局ジャパンセブンズ2026", nil, .sevens),
            ("練習試合", nil, nil),
        ]
        for (name, category, variant) in cases {
            try expect(TournamentCategory.inferred(from: name) == category
                       && TournamentCategory.inferredVariant(from: name) == variant,
                       "Infer \(category ?? "なし")・\(variant?.displayName ?? "なし") from \(name)")
        }

        let container = try makeContainer()
        let context = container.mainContext
        let manual = Tournament(officialName: "第62回全国大学ラグビーフットボール選手権大会", variantRaw: RugbyVariant.sevens.rawValue, category: "自分で付けた")
        let empty = Tournament(officialName: "NTTジャパンラグビー リーグワン 2025-26 ディビジョン1")
        context.insert(manual); context.insert(empty)
        try context.save()
        let suite = "rugby-as-category-checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try expect(TournamentCategory.backfill(context: context, defaults: defaults) == 1
                   && empty.category == "トップ" && empty.variantRaw == RugbyVariant.fifteens.rawValue,
                   "Backfill fills empty tournaments")
        try expect(manual.category == "自分で付けた" && manual.variantRaw == RugbyVariant.sevens.rawValue,
                   "Backfill keeps values set by hand")
        empty.category = nil
        try expect(TournamentCategory.backfill(context: context, defaults: defaults) == 0 && empty.category == nil,
                   "Backfill runs only once")
        try expect(TournamentCategory.label(category: "大学", variantRaw: "sevens") == "大学・7人制"
                   && TournamentCategory.label(category: nil, variantRaw: nil) == nil, "Category labels")
        try expect(TournamentCategory.label(category: "大学", variantRaw: "sevens", genderRaw: "women") == "女子・大学・7人制",
                   "Gender comes first in labels")

        let genderCases: [(String, RugbyGender?)] = [
            ("太陽生命ウィメンズセブンズシリーズ2026 第1戦熊谷大会", .women),
            ("Women’s College Sevens 2026 第13回大学女子7人制ラグビーフットボール大会", .women),
            ("太陽生命カップ2026 第17回全国中学生ラグビーフットボール大会 (12人制) 第１ブロック 中学校男子", .men),
            ("第62回全国大学ラグビーフットボール選手権大会", .men),
            ("NTTジャパンラグビー リーグワン 2025-26 ディビジョン1", .men),
            ("アサヒスーパードライ パシフィックネーションズカップ2026", .men),
            ("全国女子ラグビーフットボール選手権大会", .women),
            ("なの花薬局ジャパンセブンズ2026", nil),
            ("練習試合", nil),
        ]
        for (name, gender) in genderCases {
            try expect(TournamentCategory.inferredGender(from: name) == gender,
                       "Infer \(gender?.displayName ?? "なし") from \(name)")
        }
        let genderSuite = "rugby-as-gender-checks." + UUID().uuidString
        let genderDefaults = UserDefaults(suiteName: genderSuite)!
        defer { genderDefaults.removePersistentDomain(forName: genderSuite) }
        let handSet = Tournament(officialName: "全国女子ラグビーフットボール選手権大会", genderRaw: RugbyGender.men.rawValue)
        context.insert(handSet)
        empty.category = nil
        try expect(TournamentCategory.backfillGender(context: context, defaults: genderDefaults) == 2
                   && empty.genderRaw == RugbyGender.men.rawValue && manual.genderRaw == RugbyGender.men.rawValue,
                   "Gender backfill fills empty tournaments")
        try expect(handSet.genderRaw == RugbyGender.men.rawValue && empty.category == nil,
                   "Gender backfill keeps hand-set values and leaves categories alone")

        empty.category = "トップ"
        let data = try BackupManager.makeBackupData(context: context, defaults: defaults)
        let restoredContainer = try makeContainer()
        try BackupManager.restore(from: data, context: restoredContainer.mainContext, defaults: defaults)
        try expect(try restoredContainer.mainContext.fetch(FetchDescriptor<Tournament>()).first { $0.id == empty.id }?.category == "トップ",
                   "Backup keeps tournament categories")
        try expect(try restoredContainer.mainContext.fetch(FetchDescriptor<Tournament>()).first { $0.id == empty.id }?.genderRaw == "men",
                   "Backup keeps tournament gender")
        manual.isFavorite = true
        let favoriteData = try BackupManager.makeBackupData(context: context, defaults: defaults)
        let favoriteContainer = try makeContainer()
        try BackupManager.restore(from: favoriteData, context: favoriteContainer.mainContext, defaults: defaults)
        let restoredTournaments = try favoriteContainer.mainContext.fetch(FetchDescriptor<Tournament>())
        try expect(restoredTournaments.first { $0.id == manual.id }?.isFavorite == true
                   && restoredTournaments.first { $0.id == empty.id }?.isFavorite == false, "Backup keeps favourite tournaments")
    }

    static func teamFolders() throws {
        let women7 = Tournament(officialName: "女子7", variantRaw: "sevens", category: "トップ", genderRaw: "women")
        let menUniv = Tournament(officialName: "大学", variantRaw: "fifteens", category: "大学", genderRaw: "men")
        let blank = Tournament(officialName: "練習試合")
        let both = Team(name: "両方出るチーム")
        let womenOnly = Team(name: "女子チーム")
        let entered = Team(name: "出場登録だけ")
        let mine = Team(name: "マイフォルダのチーム", category: " 今季の対戦相手 ")
        let none = Team(name: "どこにも出ていない")
        menUniv.teamIDs = [entered.id]
        let matches = [
            Match(tournamentID: women7.id, homeTeamID: both.id, awayTeamID: womenOnly.id, playedAt: .now),
            Match(tournamentID: menUniv.id, homeTeamID: both.id, awayTeamID: UUID(), playedAt: .now),
            Match(tournamentID: blank.id, homeTeamID: mine.id, awayTeamID: none.id, playedAt: .now),
        ]
        let teams = [both, womenOnly, entered, mine, none]
        let index = TeamFolderIndex(matches: matches, tournaments: [women7, menUniv, blank])
        func names(_ folder: TeamFolder, _ gender: String? = nil) -> [String] {
            index.teams(in: folder, from: teams, genderRaw: gender).map(\.name)
        }
        let women7Key = TeamFolderKey(tournament: women7)!
        let menUnivKey = TeamFolderKey(tournament: menUniv)!
        try expect(TeamFolderKey(tournament: blank) == nil, "Tournaments with nothing set make no folder")
        try expect(Set(names(.auto(women7Key))) == ["両方出るチーム", "女子チーム"], "Teams go into the folder of each tournament")
        try expect(Set(names(.auto(menUnivKey))) == ["両方出るチーム", "出場登録だけ"], "Entered teams count without matches")
        try expect(index.autoFolders(teams: teams, genderRaw: nil).map(\.key) == [menUnivKey, women7Key],
                   "Men's folders come before women's")
        try expect(index.autoFolders(teams: teams, genderRaw: "women").map(\.key) == [women7Key], "Gender switch hides the other folders")
        try expect(Set(names(.all, "women")) == ["両方出るチーム", "女子チーム"], "Gender switch filters all teams")
        try expect(names(.mine("今季の対戦相手")) == ["マイフォルダのチーム"]
                   && index.myFolders(teams: teams, genderRaw: nil).map(\.name) == ["今季の対戦相手"], "My folders use the team setting")
        try expect(names(.uncategorized) == ["どこにも出ていない"], "Uncategorised skips teams in my folders")
        both.isFavorite = true
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(both); context.insert(womenOnly)
        try context.save()
        let suite = "rugby-as-folder-checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let data = try BackupManager.makeBackupData(context: context, defaults: defaults)
        let restoredContainer = try makeContainer()
        let restored = restoredContainer.mainContext
        try BackupManager.restore(from: data, context: restored, defaults: defaults)
        let restoredTeams = try restored.fetch(FetchDescriptor<Team>())
        try expect(restoredTeams.first { $0.id == both.id }?.isFavorite == true
                   && restoredTeams.first { $0.id == womenOnly.id }?.isFavorite == false, "Backup keeps favourite teams")
        let folderMate = Team(name: "フォルダ仲間", category: "今季の対戦相手")
        context.insert(mine); context.insert(folderMate); context.insert(none)
        try expect(TeamFolderEditing.rename("今季の対戦相手", to: " 関東 ", teams: [both, womenOnly, mine, folderMate, none], context: context)
                   && mine.category == "関東" && folderMate.category == "関東" && none.category == nil,
                   "Renaming a my folder moves all its teams")
        try expect(!TeamFolderEditing.rename("関東", to: "  ", teams: [mine, folderMate], context: context) && mine.category == "関東",
                   "Blank folder names are refused")
        try expect(TeamFolderEditing.remove("関東", teams: [mine, folderMate, none], context: context)
                   && mine.category == nil && folderMate.category == nil
                   && (try context.fetch(FetchDescriptor<Team>())).count == 5, "Removing a my folder keeps its teams")
        try expect(women7Key.label == "女子・トップ・7人制"
                   && index.summary(for: both.id) == "男子・大学・15人制、女子・トップ・7人制", "Folder labels and team summary")
    }

    static func tournamentFolders() throws {
        let leg1 = Tournament(officialName: "シリーズ第1戦", year: 2026, variantRaw: "sevens", seriesName: "女子シリーズ",
                              category: "トップ", genderRaw: "women")
        let leg2 = Tournament(officialName: "シリーズ第2戦", year: 2026, variantRaw: "sevens", seriesName: " 女子シリーズ ",
                              category: "トップ", genderRaw: "women")
        let univ = Tournament(officialName: "大学選手権", year: 2025, variantRaw: "fifteens", category: "大学", genderRaw: "men")
        let practice = Tournament(officialName: "練習試合")
        let all = [leg1, leg2, univ, practice]
        let topKey = TeamFolderKey(tournament: leg1)!
        try expect(TournamentFolders.autoFolders(all, genderRaw: nil).map(\.count) == [1, 2]
                   && TournamentFolders.autoFolders(all, genderRaw: "women").map(\.key) == [topKey],
                   "Tournament folders follow the tournament settings")
        try expect(TournamentFolders.seriesFolders(all, genderRaw: nil).map(\.name) == ["女子シリーズ"]
                   && TournamentFolders.tournaments(in: .series("女子シリーズ"), from: all, genderRaw: nil).count == 2,
                   "Series names make folders")
        try expect(TournamentFolders.tournaments(in: .uncategorized, from: all, genderRaw: nil).map(\.officialName) == ["練習試合"],
                   "Tournaments with nothing set are uncategorised")
        let later = Match(tournamentID: leg2.id, homeTeamID: UUID(), awayTeamID: UUID(), playedAt: .now)
        let earlier = Match(tournamentID: leg1.id, homeTeamID: UUID(), awayTeamID: UUID(), playedAt: .now.addingTimeInterval(-86_400))
        let groups = TournamentFolders.byYear(all, latestMatch: TournamentFolders.latestMatchDates([earlier, later]))
        try expect(groups.map(\.year) == [2026, 2025, nil]
                   && groups[0].tournaments.map(\.officialName) == ["シリーズ第2戦", "シリーズ第1戦"],
                   "Folders list newest seasons and latest matches first")
    }

    static func competitionFilter() throws {
        let top7 = Tournament(officialName: "トップ7", variantRaw: "sevens", category: "トップ")
        let univ15 = Tournament(officialName: "大学15", variantRaw: "fifteens", category: "大学")
        let univ7 = Tournament(officialName: "大学7", variantRaw: "sevens", category: "大学")
        let none = Tournament(officialName: "練習試合")
        let tournaments = [top7, univ15, univ7, none]
        let home = UUID(), away = UUID()
        let matches = tournaments.enumerated().map { index, tournament in
            Match(tournamentID: tournament.id, homeTeamID: home, awayTeamID: away, playedAt: .now.addingTimeInterval(Double(-index) * 86_400))
        }
        func selected(_ filter: CompetitionFilter?) -> Set<UUID> {
            var scope = AnalysisScope(); scope.competition = filter
            return Set(scope.selectedMatches(from: matches, events: [StatEvent](), lineups: [], tournaments: tournaments).map(\.tournamentID))
        }
        try expect(selected(nil).count == 4, "No competition filter keeps every match")
        try expect(selected(CompetitionFilter(category: "大学")) == [univ15.id, univ7.id], "Category filter")
        try expect(selected(CompetitionFilter(variantRaw: "sevens")) == [top7.id, univ7.id], "7s filter")
        try expect(selected(CompetitionFilter(category: "大学", variantRaw: "sevens")) == [univ7.id], "Category and 7s together")
        try expect(selected(CompetitionFilter(category: "")) == [none.id], "Uncategorised tournaments can be picked")
        try expect(CompetitionFilter(category: "大学", variantRaw: "sevens").label == "大学・7人制", "Filter label")
        univ7.genderRaw = RugbyGender.women.rawValue
        univ15.genderRaw = RugbyGender.men.rawValue
        try expect(selected(CompetitionFilter(genderRaw: "women")) == [univ7.id], "Gender filter")
        try expect(selected(CompetitionFilter(category: "大学", genderRaw: "men")) == [univ15.id], "Gender and category together")
        try expect(CompetitionFilter(category: "大学", variantRaw: "sevens", genderRaw: "women").label == "女子・大学・7人制",
                   "Filter label with gender")
        let beforeGender = try JSONDecoder().decode(CompetitionFilter.self, from: Data(#"{"category":"大学","variantRaw":"sevens"}"#.utf8))
        try expect(beforeGender.genderRaw == nil && beforeGender.category == "大学", "Filters saved before gender still load")

        // 項目を足す前に保存した分析も読める
        let old = #"{"recentLimit":0,"matchIDs":[],"filter":{"half":null,"category":"","player":"","outcome":"","origin":"","zoneRow":-1,"zoneColumn":-1,"startTime":"","endTime":""}}"#
        let decoded = try JSONDecoder().decode(AnalysisScope.self, from: Data(old.utf8))
        try expect(decoded.competition == nil, "Scopes saved before the competition filter still load")
    }

    static func tournamentDeletion() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let mine = Team(name: "自チーム"), importedOnly = Team(name: "取り込みだけのチーム"), unused = Team(name: "試合なしのチーム")
        [mine, importedOnly, unused].forEach { context.insert($0) }
        let wrong = Tournament(officialName: "間違えた大会"), keep = Tournament(officialName: "残す大会")
        context.insert(wrong); context.insert(keep)
        keep.teamIDs = [mine.id, importedOnly.id]
        let regular = Player(teamID: mine.id, number: 1, name: "いつもの選手")
        let onlyWrong = Player(teamID: mine.id, number: 2, name: "間違いにだけ出た選手")
        let rosterOnly = Player(teamID: mine.id, number: 3, name: "名簿だけの選手")
        let imported = Player(teamID: importedOnly.id, number: 9, name: "取り込み選手")
        [regular, onlyWrong, rosterOnly, imported].forEach { context.insert($0) }
        let wrongMatch = Match(tournamentID: wrong.id, homeTeamID: mine.id, awayTeamID: importedOnly.id, playedAt: .now)
        let keptMatch = Match(tournamentID: keep.id, homeTeamID: mine.id, awayTeamID: unused.id, playedAt: .now)
        context.insert(wrongMatch); context.insert(keptMatch)
        context.insert(StatEvent(matchID: wrongMatch.id, teamID: mine.id, playerID: onlyWrong.id, category: "try", outcome: "success", seconds: 10))
        context.insert(StatEvent(matchID: wrongMatch.id, teamID: importedOnly.id, playerID: imported.id, category: "try", outcome: "success", seconds: 20))
        context.insert(MatchLineup(matchID: wrongMatch.id, teamID: mine.id, playerID: regular.id, role: "starter", order: 0))
        context.insert(MatchLineup(matchID: keptMatch.id, teamID: mine.id, playerID: regular.id, role: "starter", order: 0))
        context.insert(Substitution(matchID: wrongMatch.id, playerInID: onlyWrong.id, playerOutID: regular.id, minute: 30))
        try context.save()

        let plan = try TournamentDeletion.plan(for: wrong, context: context)
        try expect(plan.matchIDs == [wrongMatch.id] && plan.eventCount == 2 && plan.lineupCount == 1 && plan.substitutionCount == 1,
                   "Deletion plan counts the tournament's records")
        try expect(plan.onlyHereTeams.map(\.id) == [importedOnly.id] && plan.onlyHereTeamPlayerCount[importedOnly.id] == 1,
                   "Only teams without matches elsewhere are offered for deletion")
        try expect(plan.onlyHerePlayers.map(\.id) == [onlyWrong.id],
                   "Only players who appear nowhere else are offered; roster-only and regular players stay")

        var removedMatches: [UUID] = []
        try expect(TournamentDeletion.delete(wrong, teamIDsToDelete: Set(plan.onlyHereTeams.map(\.id)),
                                             playerIDsToDelete: Set(plan.onlyHerePlayers.map(\.id)), context: context,
                                             removeImage: { _ in }, afterMatchesDeleted: { removedMatches = $0 }),
                   "Tournament deletion succeeds")
        let tournaments = try context.fetch(FetchDescriptor<Tournament>())
        let teams = Set(try context.fetch(FetchDescriptor<Team>()).map(\.id))
        let players = Set(try context.fetch(FetchDescriptor<Player>()).map(\.id))
        try expect(tournaments.map(\.id) == [keep.id] && removedMatches == [wrongMatch.id], "Tournament and its matches are gone")
        try expect(try context.fetch(FetchDescriptor<Match>()).map(\.id) == [keptMatch.id]
                   && (try context.fetchCount(FetchDescriptor<StatEvent>())) == 0
                   && (try context.fetchCount(FetchDescriptor<Substitution>())) == 0
                   && (try context.fetch(FetchDescriptor<MatchLineup>())).map(\.matchID) == [keptMatch.id],
                   "Records of the deleted matches are gone and others stay")
        try expect(teams == [mine.id, unused.id], "Teams used elsewhere or never used stay")
        try expect(players == [regular.id, rosterOnly.id], "Imported and only-here players are removed")
        try expect(keep.teamIDs == [mine.id], "Deleted teams leave other tournaments' entries")
    }

    static func bulkCandidates() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let a = Team(name: "A"), b = Team(name: "B"), c = Team(name: "C")
        [a, b, c].forEach { context.insert($0) }
        let a1 = Player(teamID: a.id, number: 1, name: "山田"), b1 = Player(teamID: b.id, number: 1, name: "山田")
        let c1 = Player(teamID: c.id, number: 1, name: "山田")
        let a2 = Player(teamID: a.id, number: 2, name: "鈴木"), b2 = Player(teamID: b.id, number: 2, name: "鈴木")
        [a1, b1, c1, a2, b2].forEach { context.insert($0) }
        try context.save()

        // 3人の山田(A-B, B-C)と鈴木(A-B)を1回でつなぐ。つながりは推移的にまとまる
        try expect(PersonLink.linkAll([(a1, b1), (b1, c1), (a2, b2)], context: context) == 3, "Bulk link counts pairs")
        try expect(a1.personID != nil && a1.personID == b1.personID && b1.personID == c1.personID, "Bulk link joins chains into one person")
        try expect(a2.personID != nil && a2.personID == b2.personID && a2.personID != a1.personID, "Separate people stay separate")

        let suite = "rugby-as-bulk-checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let x = DuplicateFinder.Candidate(kind: .team, firstID: a.id, secondID: b.id, reason: "")
        let y = DuplicateFinder.Candidate(kind: .team, firstID: b.id, secondID: c.id, reason: "")
        DuplicateFinder.dismissAll([x, y], defaults: defaults)
        try expect(DuplicateFinder.dismissedIDs(defaults: defaults) == [x.id, y.id], "Bulk dismiss remembers every pair")
        DuplicateFinder.restoreDismissed(defaults: defaults)
        try expect(DuplicateFinder.dismissedIDs(defaults: defaults).isEmpty, "Dismissed pairs can be restored")
    }
}
