//
//  TournamentFolders.swift
//  Rugby AS
//
//  大会一覧のフォルダ分け(チーム一覧の TeamFolders.swift と同じ考え方)。
//  画面から切り離して、どの大会がどのフォルダに入るかだけをここで決める。
//
//  - 自動フォルダ: 大会の「男子/女子・カテゴリー・7人制/15人制」(TeamFolderKey と同じ区分)。1大会1つ。
//  - シリーズ: 大会の設定で付けたシリーズ名(例: 太陽生命ウィメンズセブンズシリーズ2026)。
//  - 未分類: 自動フォルダにもシリーズにも入らない大会。
//  フォルダの中は年度ごと(新しい年度が上)に並べる。
//

import Foundation

nonisolated enum TournamentFolder: Hashable {
    case all
    case auto(TeamFolderKey)
    case series(String)
    case uncategorized

    var title: String {
        switch self {
        case .all: return "すべての大会"
        case .auto(let key): return key.label
        case .series(let name): return name
        case .uncategorized: return "未分類"
        }
    }
}

nonisolated enum TournamentFolders {
    static func seriesName(of tournament: Tournament) -> String? {
        let trimmed = (tournament.seriesName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 男子/女子の切り替えに合う大会か(nil = すべて)
    static func matchesGender(_ tournament: Tournament, genderRaw: String?) -> Bool {
        genderRaw == nil || tournament.genderRaw == genderRaw
    }

    static func tournaments(in folder: TournamentFolder, from tournaments: [Tournament], genderRaw: String?) -> [Tournament] {
        tournaments.filter { tournament in
            guard matchesGender(tournament, genderRaw: genderRaw) else { return false }
            switch folder {
            case .all: return true
            case .auto(let key): return TeamFolderKey(tournament: tournament) == key
            case .series(let name): return seriesName(of: tournament) == name
            case .uncategorized: return TeamFolderKey(tournament: tournament) == nil && seriesName(of: tournament) == nil
            }
        }
    }

    /// 自動フォルダと大会数(男子 → 女子 → 未設定、カテゴリーの決まった順、7人制 → 15人制)
    static func autoFolders(_ tournaments: [Tournament], genderRaw: String?) -> [(key: TeamFolderKey, count: Int)] {
        var counts: [TeamFolderKey: Int] = [:]
        for tournament in tournaments where matchesGender(tournament, genderRaw: genderRaw) {
            if let key = TeamFolderKey(tournament: tournament) { counts[key, default: 0] += 1 }
        }
        return counts.keys.sorted().map { ($0, counts[$0] ?? 0) }
    }

    /// シリーズと大会数(名前順)
    static func seriesFolders(_ tournaments: [Tournament], genderRaw: String?) -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for tournament in tournaments where matchesGender(tournament, genderRaw: genderRaw) {
            if let name = seriesName(of: tournament) { counts[name, default: 0] += 1 }
        }
        return counts.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { ($0, counts[$0] ?? 0) }
    }

    /// 年度ごとにまとめる。新しい年度が上、年度未設定は最後。
    /// 同じ年度の中は、いちばん最近の試合が新しい大会から(試合がなければ名前順で後ろ)。
    static func byYear(_ tournaments: [Tournament], latestMatch: [UUID: Date]) -> [(year: Int?, tournaments: [Tournament])] {
        let grouped = Dictionary(grouping: tournaments, by: \.year)
        let years = grouped.keys.sorted { ($0 ?? Int.min) > ($1 ?? Int.min) }
        return years.map { year in
            let sorted = (grouped[year] ?? []).sorted { lhs, rhs in
                let left = latestMatch[lhs.id] ?? .distantPast
                let right = latestMatch[rhs.id] ?? .distantPast
                if left != right { return left > right }
                return lhs.officialName.localizedStandardCompare(rhs.officialName) == .orderedAscending
            }
            return (year, sorted)
        }
    }

    /// 大会ごとの、いちばん最近の試合日
    static func latestMatchDates(_ matches: [Match]) -> [UUID: Date] {
        var result: [UUID: Date] = [:]
        for match in matches where match.playedAt > (result[match.tournamentID] ?? .distantPast) {
            result[match.tournamentID] = match.playedAt
        }
        return result
    }

    static func yearTitle(_ year: Int?) -> String {
        year.map { "\(String($0))年度" } ?? "年度未設定"
    }
}
