//
//  MatchNumbering.swift
//  Rugby AS
//
//  「この試合での背番号」を1箇所で解決するヘルパー。
//  ラグビーは固定背番号を持たないため、メンバー表(MatchLineup)に
//  試合ごとの番号を持ち、未設定なら選手の基本番号を使う。
//  番号を表示する画面はすべてここを通す(表示のばらつきを防ぐ)。
//

import Foundation
import SwiftData

enum MatchNumbering {
    // メンバー表に載っていないのに記録に登場した選手の「番号の控え」に使う役割名。
    // メンバー登録画面には表示されない(starter/reserveのみ表示するため)。
    nonisolated static let numberSnapshotRole = "number_snapshot"

    /// 全試合の背番号を「その時点の番号」で固定する(起動時に1回)。
    /// これをしないと、後からチームページで番号を変えたとき
    /// 過去の試合の背番号まで遡って変わってしまう。
    nonisolated static func freezeLineupNumbers(context: ModelContext) {
        freezeNumbers(context: context)
    }

    /// 特定の試合だけ背番号を固定する(記録画面を閉じたとき等に呼ぶ)
    nonisolated static func freezeNumbers(forMatch matchID: UUID, context: ModelContext) {
        freezeNumbers(matchIDs: [matchID], context: context)
    }

    /// 指定した試合だけ背番号を固定する(起動時に、前回から記録が変わった試合だけ点検するのに使う)
    nonisolated static func freezeNumbers(forMatches matchIDs: Set<UUID>, context: ModelContext) {
        guard !matchIDs.isEmpty else { return }
        freezeNumbers(matchIDs: Array(matchIDs), context: context)
    }

    /// matchIDs が nil なら全試合
    nonisolated private static func freezeNumbers(matchIDs: [UUID]? = nil, context: ModelContext) {
        var lineupFetch = FetchDescriptor<MatchLineup>()
        var eventFetch = FetchDescriptor<StatEvent>(predicate: #Predicate { $0.playerID != nil })
        var substitutionFetch = FetchDescriptor<Substitution>()
        if let matchIDs {
            lineupFetch.predicate = #Predicate { matchIDs.contains($0.matchID) }
            eventFetch.predicate = #Predicate { matchIDs.contains($0.matchID) && $0.playerID != nil }
            substitutionFetch.predicate = #Predicate { matchIDs.contains($0.matchID) }
        }
        eventFetch.propertiesToFetch = [\.matchID, \.playerID]
        guard let lineups = try? context.fetch(lineupFetch),
              let events = try? context.fetch(eventFetch),
              let substitutions = try? context.fetch(substitutionFetch) else {
            return
        }
        // 選手は、この試合に出てくる人だけ読む(全選手を読むと、選手が数万人いるときに重いため)
        let players: [Player]
        if matchIDs == nil {
            guard let all = try? context.fetch(FetchDescriptor<Player>()) else { return }
            players = all
        } else {
            let ids = Array(Set(lineups.map(\.playerID) + events.compactMap(\.playerID)
                                + substitutions.flatMap { [$0.playerInID, $0.playerOutID] }))
            guard let found = try? context.fetch(FetchDescriptor<Player>(predicate: #Predicate { ids.contains($0.id) })) else { return }
            players = found
        }
        let playersByID = Dictionary(players.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var didChange = false

        // 1) メンバー表にあるが番号未設定の行に、現在の番号を書き込む
        //    (背番号なしの選手はそのまま=書き込むものがない)
        for entry in lineups where entry.number == nil {
            if let number = playersByID[entry.playerID]?.number {
                entry.number = number
                didChange = true
            }
        }

        // 2) メンバー表に載っていないのに得点・交代の記録に登場する選手には、
        //    「番号の控え」の行を作って現在の番号を残す
        //    (メンバー表未登録の試合でも、過去の背番号が変わらないように)
        var knownPairs: Set<String> = Set(lineups.map { "\($0.matchID)|\($0.playerID)" })

        var appearingPairs: [(matchID: UUID, playerID: UUID)] = []
        for event in events {
            if let playerID = event.playerID {
                appearingPairs.append((event.matchID, playerID))
            }
        }
        for substitution in substitutions {
            appearingPairs.append((substitution.matchID, substitution.playerInID))
            appearingPairs.append((substitution.matchID, substitution.playerOutID))
        }

        for pair in appearingPairs {
            let key = "\(pair.matchID)|\(pair.playerID)"
            guard !knownPairs.contains(key),
                  let player = playersByID[pair.playerID],
                  let number = player.number else {
                continue
            }
            knownPairs.insert(key)
            context.insert(MatchLineup(
                matchID: pair.matchID,
                teamID: player.teamID,
                playerID: pair.playerID,
                role: numberSnapshotRole,
                order: 0,
                number: number
            ))
            didChange = true
        }

        if didChange {
            try? context.save()
        }
    }

    /// その試合での背番号。メンバー表に試合用の番号があればそれ、なければ基本番号。
    /// nil = 背番号なし。
    nonisolated static func number(for player: Player, matchID: UUID, lineups: [MatchLineup]) -> Int? {
        lineups.first { $0.matchID == matchID && $0.playerID == player.id }?.number ?? player.number
    }

    /// 「#7」形式の番号表示。背番号なしは「ー」
    static func numberText(_ number: Int?) -> String {
        number.map { "#\($0)" } ?? "ー"
    }

    /// その試合での「#7」表示(背番号なしは「ー」)
    static func numberLabel(for player: Player, matchID: UUID, lineups: [MatchLineup]) -> String {
        numberText(number(for: player, matchID: matchID, lineups: lineups))
    }

    /// 「#7 山田」形式の表示名。番号なしなら名前のみ、両方なければ「名前未設定」
    static func label(for player: Player, matchID: UUID, lineups: [MatchLineup]) -> String {
        let number = number(for: player, matchID: matchID, lineups: lineups)
        let name = (player.name?.isEmpty == false) ? player.name : nil
        switch (number, name) {
        case (let number?, let name?): return "#\(number) \(name)"
        case (nil, let name?): return name
        case (let number?, nil): return "#\(number)"
        case (nil, nil): return "名前未設定"
        }
    }
}

/// Prepared once when a picker opens. Sorting never scans the lineup for each comparison.
struct RecordingPlayerRoster {
    let numbered: [Player]
    let others: [Player]
    private let numbers: [UUID: Int]
    private let playersByID: [UUID: Player]

    init() {
        numbered = []; others = []; numbers = [:]; playersByID = [:]
    }

    init(players: [Player], numberFor: (Player) -> Int?) {
        var numbers: [UUID: Int] = [:]
        var numbered: [Player] = []
        var others: [Player] = []
        var byID: [UUID: Player] = [:]
        for player in players {
            byID[player.id] = player
            if let number = numberFor(player) {
                numbers[player.id] = number
                numbered.append(player)
            } else {
                others.append(player)
            }
        }
        self.numbered = numbered.sorted {
            let a = numbers[$0.id]!, b = numbers[$1.id]!
            if a != b { return a < b }
            let lhs = $0.name ?? "", rhs = $1.name ?? ""
            return lhs == rhs ? $0.id.uuidString < $1.id.uuidString : lhs < rhs
        }
        self.others = others
        self.numbers = numbers
        self.playersByID = byID
    }

    init(players: [Player], teamID: UUID, matchID: UUID, lineups: [MatchLineup]) {
        var lineupNumbers: [UUID: Int] = [:]
        var seen: Set<UUID> = []
        for entry in lineups where entry.matchID == matchID {
            guard seen.insert(entry.playerID).inserted else { continue }
            if let number = entry.number { lineupNumbers[entry.playerID] = number }
        }
        self.init(players: players.filter { $0.teamID == teamID }) {
            lineupNumbers[$0.id] ?? $0.number
        }
    }

    func number(for player: Player) -> Int? { numbers[player.id] }

    func visiblePlayers(includeOthers: Bool, selectedPlayerID: UUID? = nil) -> [Player] {
        if includeOthers { return numbered + others }
        // A saved or just-selected unnumbered player stays visible when the additional list is closed.
        if let id = selectedPlayerID, numbers[id] == nil, let player = playersByID[id] {
            return numbered + [player]
        }
        return numbered
    }
}
