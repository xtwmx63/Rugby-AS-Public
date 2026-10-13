//
//  DuplicateFinder.swift
//  Rugby AS
//
//  同じチーム・同じ人が2つに分かれていそうな組を探す(候補を出すだけで、自動ではまとめない)。
//  - チーム: 名前(と別名)をスペース・全角半角・大文字小文字を無視して比べ、同じ、または片方がもう片方を含む組。
//            ただし2チームが対戦したことがあれば別チームなので出さない。
//  - 同じチームの選手: 名前・読み・別名が同じ組(誤字・表記ゆれ・苗字の変化の候補)。
//            同じ試合のメンバー表に2人とも載っていれば別人なので出さない。
//  - ほかのチームの選手: 名前(または読み)が同じで、まだ同一人物としてつないでいない組(移籍・代表などの候補)。
//  「別人」と決めた組は UserDefaults に覚えて、次から出さない。
//

import Foundation
import SwiftData

enum DuplicateFinder {
    nonisolated enum Kind: String, Sendable {
        case team, playerSameTeam, playerOtherTeam
    }

    nonisolated struct Candidate: Identifiable, Equatable, Sendable {
        let kind: Kind
        let firstID: UUID
        let secondID: UUID
        /// 何が一致したか(画面に出す)
        let reason: String

        /// 順番に関係なく同じ組を同じ値にする(「別人」を覚えるため)
        var id: String {
            let pair = [firstID.uuidString, secondID.uuidString].sorted()
            return kind.rawValue + ":" + pair.joined(separator: "|")
        }
    }

    static let dismissedKey = "duplicateFinder.dismissed.v1"

    /// チーム・選手の出場の様子。同姓同名や似た名前のどちらを残すか決めるときの手がかりにする。
    nonisolated struct Activity: Equatable, Sendable {
        var matchIDs = Set<UUID>()
        var first: Date?
        var last: Date?
        /// 出た大会(新しい試合の大会から順)
        var tournamentIDs: [UUID] = []

        var matchCount: Int { matchIDs.count }

        mutating func add(_ match: Match) {
            guard matchIDs.insert(match.id).inserted else { return }
            first = min(first ?? match.playedAt, match.playedAt)
            last = max(last ?? match.playedAt, match.playedAt)
            if !tournamentIDs.contains(match.tournamentID) { tournamentIDs.append(match.tournamentID) }
        }
    }

    /// チームは試合の両チーム、選手はメンバー表と選手の付いた記録から、出場の様子をまとめる
    nonisolated static func activities(matches: [Match], lineups: [MatchLineup], events: [StatEvent]) -> [UUID: Activity] {
        var result: [UUID: Activity] = [:]
        let matchByID = Dictionary(uniqueKeysWithValues: matches.map { ($0.id, $0) })
        for match in matches.sorted(by: { $0.playedAt > $1.playedAt }) {
            result[match.homeTeamID, default: Activity()].add(match)
            result[match.awayTeamID, default: Activity()].add(match)
        }
        for lineup in lineups {
            if let match = matchByID[lineup.matchID] { result[lineup.playerID, default: Activity()].add(match) }
        }
        for event in events {
            if let playerID = event.playerID, let match = matchByID[event.matchID] {
                result[playerID, default: Activity()].add(match)
            }
        }
        return result
    }

    /// 「重複の候補」画面の中身を裏で作る。全メンバー表(数十万行)は読まず、
    /// 同じチームで名前が重なる選手と、候補に出る選手・チームの分だけ読む(結果は candidates/activities と同じ)
    nonisolated static func loadScreen(container: ModelContainer, dismissed: Set<String>)
        -> (candidates: [Candidate], activity: [UUID: Activity], tournamentNames: [UUID: String]) {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let teams = (try? context.fetch(FetchDescriptor<Team>())) ?? []
        let players = (try? context.fetch(FetchDescriptor<Player>())) ?? []
        let matches = (try? context.fetch(FetchDescriptor<Match>())) ?? []
        let tournaments = (try? context.fetch(FetchDescriptor<Tournament>())) ?? []

        // 名前で組を作る。同じチームの組は、同じ試合に出ていたら別人なので後で外す
        let named = candidates(teams: teams, players: players, matches: matches, dismissed: dismissed) { _, _ in false }
        let shownSet = Set(named.flatMap { [$0.firstID, $0.secondID] })

        // 候補に出る選手のメンバー表と記録を読む。保存先のファイルを直接読めれば速い(読めなければ今までの読み方)
        var lineupPairs: [(player: UUID, match: UUID)] = []
        var eventPairs: [(player: UUID, match: UUID)] = []
        if let pairs = StoreFileReader.playerMatchPairs(storeURL: container.configurations.first?.url) {
            lineupPairs = pairs.lineups.filter { shownSet.contains($0.player) }
            eventPairs = pairs.events.filter { shownSet.contains($0.player) }
        } else if !shownSet.isEmpty {
            let ids = Array(shownSet)
            var lineupFetch = FetchDescriptor<MatchLineup>(predicate: #Predicate { ids.contains($0.playerID) })
            lineupFetch.propertiesToFetch = [\.matchID, \.playerID]
            lineupPairs = ((try? context.fetch(lineupFetch)) ?? []).map { ($0.playerID, $0.matchID) }
            let optionalIDs: [UUID?] = ids.map { $0 }
            var eventFetch = FetchDescriptor<StatEvent>(predicate: #Predicate { optionalIDs.contains($0.playerID) })
            eventFetch.propertiesToFetch = [\.matchID, \.playerID]
            eventPairs = ((try? context.fetch(eventFetch)) ?? []).compactMap { event in event.playerID.map { ($0, event.matchID) } }
        }
        var matchesByPlayer: [UUID: Set<UUID>] = [:]
        for pair in lineupPairs { matchesByPlayer[pair.player, default: []].insert(pair.match) }
        let found = named.filter { candidate in
            candidate.kind != .playerSameTeam
                || (matchesByPlayer[candidate.firstID] ?? []).isDisjoint(with: matchesByPlayer[candidate.secondID] ?? [])
        }

        // 出場の様子は、候補に出るチーム・選手の分だけ作る(activities と同じ数え方)
        var activity: [UUID: Activity] = [:]
        let matchByID = Dictionary(matches.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for match in matches.sorted(by: { $0.playedAt > $1.playedAt }) {
            if shownSet.contains(match.homeTeamID) { activity[match.homeTeamID, default: Activity()].add(match) }
            if shownSet.contains(match.awayTeamID) { activity[match.awayTeamID, default: Activity()].add(match) }
        }
        // 選手は新しい試合から順に足す(出た大会の並びを activities と同じにするため)
        var playerMatches: [UUID: Set<UUID>] = [:]
        for pair in lineupPairs + eventPairs { playerMatches[pair.player, default: []].insert(pair.match) }
        for (player, ids) in playerMatches {
            for match in ids.compactMap({ matchByID[$0] }).sorted(by: { $0.playedAt > $1.playedAt }) {
                activity[player, default: Activity()].add(match)
            }
        }
        let names = Dictionary(tournaments.map { ($0.id, $0.officialName) }, uniquingKeysWith: { first, _ in first })
        return (found, activity.filter { shownSet.contains($0.key) }, names)
    }

    /// データベースから出場の様子をまとめて読む(選手の付いた記録だけ読む)
    static func activities(context: ModelContext) -> [UUID: Activity] {
        let matches = (try? context.fetch(FetchDescriptor<Match>())) ?? []
        let lineups = (try? context.fetch(FetchDescriptor<MatchLineup>())) ?? []
        let events = (try? context.fetch(FetchDescriptor<StatEvent>(predicate: #Predicate { $0.playerID != nil }))) ?? []
        return activities(matches: matches, lineups: lineups, events: events)
    }

    /// 例: 「5試合・2025/4/1〜2025/12/1」
    static func periodText(_ activity: Activity?) -> String {
        guard let activity, let first = activity.first, let last = activity.last else { return "出場記録なし" }
        let from = dateFormatter.string(from: first), to = dateFormatter.string(from: last)
        return "\(activity.matchCount)試合・" + (from == to ? from : from + "〜" + to)
    }

    /// 例: 「大会: 全国大学選手権、関東大学対抗戦 ほか1」
    static func tournamentText(_ activity: Activity?, names: [UUID: String]) -> String? {
        guard let ids = activity?.tournamentIDs, !ids.isEmpty else { return nil }
        let shown = ids.prefix(2).map { names[$0] ?? "大会未設定" }
        return "大会: " + shown.joined(separator: "、") + (ids.count > 2 ? " ほか\(ids.count - 2)" : "")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy/M/d"
        return formatter
    }()

    static func dismissedIDs(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: dismissedKey) ?? [])
    }

    static func dismiss(_ candidate: Candidate, defaults: UserDefaults = .standard) {
        dismissAll([candidate], defaults: defaults)
    }

    /// まとめて「別人」にする
    static func dismissAll(_ candidates: [Candidate], defaults: UserDefaults = .standard) {
        var ids = dismissedIDs(defaults: defaults)
        ids.formUnion(candidates.map(\.id))
        defaults.set(Array(ids).sorted(), forKey: dismissedKey)
    }

    /// 「別人」にした組をすべて候補に戻す(まとめて別人にし過ぎたとき用)
    static func restoreDismissed(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: dismissedKey)
    }

    nonisolated static func key(_ name: String?) -> String {
        OfficialRecordImporter.nameKey((name ?? "")
            .replacingOccurrences(of: "・", with: "")
            .replacingOccurrences(of: "･", with: ""))
    }

    /// 候補を探す。matches / lineups は「対戦した」「同じ試合に出た」の判定に使う。
    static func candidates(
        teams: [Team],
        players: [Player],
        matches: [Match],
        lineups: [MatchLineup],
        dismissed: Set<String> = []
    ) -> [Candidate] {
        var matchesByPlayer: [UUID: Set<UUID>] = [:]
        for lineup in lineups { matchesByPlayer[lineup.playerID, default: []].insert(lineup.matchID) }
        return candidates(teams: teams, players: players, matches: matches, dismissed: dismissed) { a, b in
            !(matchesByPlayer[a] ?? []).isDisjoint(with: matchesByPlayer[b] ?? [])
        }
    }

    /// 候補を探す本体。playedTogether は「同じチームの2人が同じ試合に出たか」(出ていれば別人)
    nonisolated static func candidates(
        teams: [Team],
        players: [Player],
        matches: [Match],
        dismissed: Set<String> = [],
        playedTogether: (UUID, UUID) -> Bool
    ) -> [Candidate] {
        var result: [Candidate] = []

        // チーム(組は文字列にせず値のまま覚える。試合が2万あると文字列を作るだけで重いため)
        struct Pair: Hashable { let a: UUID; let b: UUID
            init(_ x: UUID, _ y: UUID) { if x.uuidString < y.uuidString { a = x; b = y } else { a = y; b = x } } }
        var playedPairs = Set<Pair>()
        for match in matches {
            playedPairs.insert(Pair(match.homeTeamID, match.awayTeamID))
        }
        let teamKeys = teams.map { team in (team, ([team.name] + team.aliases).map(key).filter { $0.count >= 2 }) }
        for i in teamKeys.indices {
            for j in teamKeys.indices where j > i {
                let (a, aKeys) = teamKeys[i], (b, bKeys) = teamKeys[j]
                guard !playedPairs.contains(Pair(a.id, b.id)) else { continue }
                if aKeys.contains(where: { bKeys.contains($0) }) {
                    result.append(Candidate(kind: .team, firstID: a.id, secondID: b.id, reason: "名前が同じ"))
                } else if aKeys.contains(where: { ak in bKeys.contains { ak.contains($0) || $0.contains(ak) } }) {
                    result.append(Candidate(kind: .team, firstID: a.id, secondID: b.id, reason: "名前が似ている"))
                }
            }
        }

        // 選手: 名前・読み・別名のキー
        func nameKeys(_ player: Player) -> [String] {
            ([player.name] + player.aliases).map(key).filter { $0.count >= 2 }
        }
        func kanaKey(_ player: Player) -> String? {
            let value = key(player.nameKana)
            return value.count >= 2 ? value : nil
        }
        let named = players.filter { !nameKeys($0).isEmpty || kanaKey($0) != nil }
        var byKey: [String: [Player]] = [:]
        for player in named {
            for k in Set(nameKeys(player) + [kanaKey(player)].compactMap { $0 }) {
                byKey[k, default: []].append(player)
            }
        }
        var seen = Set<String>()
        for (_, group) in byKey where group.count > 1 {
            for i in group.indices {
                for j in group.indices where j > i {
                    let a = group[i], b = group[j]
                    let pair = [a.id.uuidString, b.id.uuidString].sorted().joined()
                    guard seen.insert(pair).inserted else { continue }
                    let sameName = nameKeys(a).contains { nameKeys(b).contains($0) }
                    let reason = sameName ? "名前が同じ" : "読みが同じ"
                    if a.teamID == b.teamID {
                        // 同じ試合に2人とも出ていれば別人
                        guard !playedTogether(a.id, b.id) else { continue }
                        result.append(Candidate(kind: .playerSameTeam, firstID: a.id, secondID: b.id, reason: reason))
                    } else {
                        // 既に同一人物としてつないでいれば出さない
                        if let personID = a.personID, personID == b.personID { continue }
                        result.append(Candidate(kind: .playerOtherTeam, firstID: a.id, secondID: b.id, reason: reason))
                    }
                }
            }
        }

        return result.filter { !dismissed.contains($0.id) }
    }
}
