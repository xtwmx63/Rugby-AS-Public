//
//  TeamFolders.swift
//  Rugby AS
//
//  チーム一覧のフォルダ分け。画面(TeamListView・TeamFolderView)から切り離して、
//  どのチームがどのフォルダに入るかだけをここで決める。
//
//  - 自動フォルダ: 出場した大会の「男子/女子・カテゴリー・7人制/15人制」の組み合わせ。
//    トップと大学の両方に出たチームは両方に入る。
//  - マイフォルダ: チーム設定で自分で決める名前(Team.category)。1チーム1つ。
//  - 未分類: 自動フォルダにもマイフォルダにも入らないチーム。
//

import Foundation
import SwiftData

/// 自動フォルダ1つ分の区分(例: 女子・トップ・7人制)。大会の設定から作る。
nonisolated struct TeamFolderKey: Hashable, Comparable {
    var genderRaw: String?
    var category: String?
    var variantRaw: String?

    /// 男女・カテゴリー・人数のどれも付いていない大会は、フォルダにしない
    init?(tournament: Tournament) {
        let category = (tournament.category ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(genderRaw: tournament.genderRaw, category: category.isEmpty ? nil : category, variantRaw: tournament.variantRaw)
        if genderRaw == nil && self.category == nil && variantRaw == nil { return nil }
    }

    init(genderRaw: String?, category: String?, variantRaw: String?) {
        self.genderRaw = genderRaw
        self.category = category
        self.variantRaw = variantRaw
    }

    var label: String {
        TournamentCategory.label(category: category, variantRaw: variantRaw, genderRaw: genderRaw) ?? "カテゴリー未設定"
    }

    /// 並び順: 男子 → 女子 → 男女未設定、その中でカテゴリーの決まった順(未設定は最後)、7人制 → 15人制
    static func < (lhs: TeamFolderKey, rhs: TeamFolderKey) -> Bool {
        func genderOrder(_ raw: String?) -> Int { raw.flatMap { RugbyGender(rawValue: $0) }.flatMap { RugbyGender.allCases.firstIndex(of: $0) } ?? 9 }
        func variantOrder(_ raw: String?) -> Int { raw.flatMap { RugbyVariant(rawValue: $0) }.flatMap { RugbyVariant.allCases.firstIndex(of: $0) } ?? 9 }
        func categoryOrder(_ name: String?) -> (Int, String) {
            name.map { TournamentCategory.sortKey($0) } ?? (TournamentCategory.suggestions.count + 1, "")
        }
        let left = (genderOrder(lhs.genderRaw), categoryOrder(lhs.category), variantOrder(lhs.variantRaw))
        let right = (genderOrder(rhs.genderRaw), categoryOrder(rhs.category), variantOrder(rhs.variantRaw))
        if left.0 != right.0 { return left.0 < right.0 }
        if left.1 != right.1 { return left.1 < right.1 }
        return left.2 < right.2
    }
}

/// チーム一覧の1つのフォルダ
nonisolated enum TeamFolder: Hashable {
    case all
    case auto(TeamFolderKey)
    case mine(String)
    case uncategorized

    var title: String {
        switch self {
        case .all: return "すべてのチーム"
        case .auto(let key): return key.label
        case .mine(let name): return name
        case .uncategorized: return "未分類"
        }
    }
}

/// どのチームがどの自動フォルダに入るか。試合一覧と大会から1回だけ数えて、画面ではこれを引く。
nonisolated struct TeamFolderIndex {
    private var keysByTeam: [UUID: Set<TeamFolderKey>] = [:]

    init(matches: [Match], tournaments: [Tournament]) {
        let tournamentsByID = Dictionary(tournaments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func add(_ teamID: UUID, _ tournament: Tournament?) {
            guard let tournament, let key = TeamFolderKey(tournament: tournament) else { return }
            keysByTeam[teamID, default: []].insert(key)
        }
        // 同じ大会・同じチームの組は1回だけ数えればよい(試合が数千あっても大会×チームの数で済む)。
        // 組は文字列にせず値のまま覚える(試合が2万あると、文字列を作るだけで重いため)
        struct Pair: Hashable { let team: UUID; let tournament: UUID }
        var seen = Set<Pair>()
        for match in matches {
            let tournamentID = match.tournamentID
            for teamID in [match.homeTeamID, match.awayTeamID]
            where seen.insert(Pair(team: teamID, tournament: tournamentID)).inserted {
                add(teamID, tournamentsByID[tournamentID])
            }
        }
        // 試合がなくても「出場チーム」に登録された大会は数える
        for tournament in tournaments {
            tournament.teamIDs.forEach { add($0, tournament) }
        }
    }

    func keys(for teamID: UUID) -> Set<TeamFolderKey> { keysByTeam[teamID] ?? [] }

    /// チーム設定で決めたマイフォルダの名前(なければ nil)
    static func myFolderName(of team: Team) -> String? {
        let trimmed = (team.category ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 男子/女子の切り替えに合うチームか(nil = すべて)
    func matchesGender(_ team: Team, genderRaw: String?) -> Bool {
        guard let genderRaw else { return true }
        return keys(for: team.id).contains { $0.genderRaw == genderRaw }
    }

    /// フォルダに入るチーム(名前順)
    func teams(in folder: TeamFolder, from teams: [Team], genderRaw: String?) -> [Team] {
        teams.filter { team in
            guard matchesGender(team, genderRaw: genderRaw) else { return false }
            switch folder {
            case .all: return true
            case .auto(let key): return keys(for: team.id).contains(key)
            case .mine(let name): return Self.myFolderName(of: team) == name
            case .uncategorized: return keys(for: team.id).isEmpty && Self.myFolderName(of: team) == nil
            }
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 自動フォルダとチーム数。男子/女子を選んでいるときは、その男女のフォルダだけ
    func autoFolders(teams: [Team], genderRaw: String?) -> [(key: TeamFolderKey, count: Int)] {
        var counts: [TeamFolderKey: Int] = [:]
        for team in teams {
            for key in keys(for: team.id) where genderRaw == nil || key.genderRaw == genderRaw {
                counts[key, default: 0] += 1
            }
        }
        return counts.keys.sorted().map { ($0, counts[$0] ?? 0) }
    }

    /// マイフォルダとチーム数(名前順)
    func myFolders(teams: [Team], genderRaw: String?) -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for team in teams where matchesGender(team, genderRaw: genderRaw) {
            if let name = Self.myFolderName(of: team) { counts[name, default: 0] += 1 }
        }
        return counts.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { ($0, counts[$0] ?? 0) }
    }

    /// チームの行に出す説明(例: 「女子・トップ・7人制、女子・大学・7人制」)。大会の情報がなければ nil
    func summary(for teamID: UUID) -> String? {
        let labels = keys(for: teamID).sorted().map(\.label)
        return labels.isEmpty ? nil : labels.joined(separator: "、")
    }
}

/// マイフォルダの名前を変える・消す。フォルダはチームに付けた名前なので、入っているチーム全部を書き換える。
enum TeamFolderEditing {
    static func rename(_ oldName: String, to newName: String, teams: [Team], context: ModelContext) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        for team in teams where TeamFolderIndex.myFolderName(of: team) == oldName {
            team.category = trimmed
        }
        return AppPersistence.save(context)
    }

    /// フォルダだけを消す(チームは消さない)
    static func remove(_ name: String, teams: [Team], context: ModelContext) -> Bool {
        for team in teams where TeamFolderIndex.myFolderName(of: team) == name {
            team.category = nil
        }
        return AppPersistence.save(context)
    }
}
