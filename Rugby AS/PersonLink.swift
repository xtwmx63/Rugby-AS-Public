//
//  PersonLink.swift
//  Rugby AS
//
//  別のチームに登録された同じ人(移籍・代表・国体・合同チームなど)を「同一人物」としてつなぐ。
//  チームごとの選手登録・背番号・メンバー表はそのまま残し、Player.personID に同じ値を入れるだけ。
//  選手の個人成績画面で、つないだ登録の記録をまとめて(通算・チーム別・年度別で)見せる。
//  統合と違って記録を書き換えないので、いつでも外せる。
//

import Foundation
import SwiftData

enum PersonLink {
    /// この選手と同一人物としてつながっている登録(自分を含む)。つないでいなければ自分だけ。
    static func linkedPlayers(of player: Player, context: ModelContext) -> [Player] {
        guard let personID = player.personID else { return [player] }
        let optionalID: UUID? = personID
        let linked = (try? context.fetch(FetchDescriptor<Player>(predicate: #Predicate { $0.personID == optionalID }))) ?? []
        return linked.contains { $0.id == player.id } ? linked : [player] + linked
    }

    /// 2人を同一人物としてつなぐ。どちらかが既にほかの登録とつながっていれば、そのまとまりごとつなぐ。
    @MainActor
    @discardableResult
    static func link(_ player: Player, with other: Player, context: ModelContext) -> Bool {
        guard player.id != other.id else { return false }
        var restores: [() -> Void] = []
        return AppPersistence.transaction(context, restoreVisibleValues: {
            restores.reversed().forEach { $0() }
        }, mutation: {
            let personID = player.personID ?? other.personID ?? UUID()
            let group = linkedPlayers(of: player, context: context) + linkedPlayers(of: other, context: context)
            for member in group where member.personID != personID {
                let original = member.personID
                restores.append { member.personID = original }
                member.personID = personID
            }
        })
    }

    /// 複数の組をまとめてつなぐ(1回の保存で。途中で失敗したら何も変えない)。つないだ組の数を返す。
    @MainActor
    @discardableResult
    static func linkAll(_ pairs: [(Player, Player)], context: ModelContext) -> Int {
        var restores: [() -> Void] = []
        var linked = 0
        let succeeded = AppPersistence.transaction(context, restoreVisibleValues: {
            restores.reversed().forEach { $0() }
        }, mutation: {
            for (player, other) in pairs where player.id != other.id {
                let personID = player.personID ?? other.personID ?? UUID()
                let group = linkedPlayers(of: player, context: context) + linkedPlayers(of: other, context: context)
                for member in group where member.personID != personID {
                    let original = member.personID
                    restores.append { member.personID = original }
                    member.personID = personID
                }
                linked += 1
            }
        })
        return succeeded ? linked : 0
    }

    /// つながりから外す。残りが1人だけになったら、その印も消す。
    @MainActor
    @discardableResult
    static func unlink(_ player: Player, context: ModelContext) -> Bool {
        guard player.personID != nil else { return true }
        var restores: [() -> Void] = []
        return AppPersistence.transaction(context, restoreVisibleValues: {
            restores.reversed().forEach { $0() }
        }, mutation: {
            let remaining = linkedPlayers(of: player, context: context).filter { $0.id != player.id }
            let original = player.personID
            restores.append { player.personID = original }
            player.personID = nil
            if remaining.count == 1, let last = remaining.first {
                let lastOriginal = last.personID
                restores.append { last.personID = lastOriginal }
                last.personID = nil
            }
        })
    }
}
