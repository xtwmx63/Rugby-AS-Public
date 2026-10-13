//
//  PlayerMerge.swift
//  Rugby AS
//
//  同じチームの中で2人に分かれてしまった同じ選手(表記ゆれ・誤字・苗字が変わった等)を
//  1人にまとめる。消える方(source)の記録・メンバー表・交代を残す方(target)に付け替え、
//  消える方の名前は残す方の「別名」に入れる。
//
//  別のチームの選手(移籍・代表・国体・合同チーム)は統合せず、「同一人物としてつなぐ」で扱う
//  (背番号やメンバー表はチームごとの登録として残すため)。
//

import Foundation
import SwiftData

enum PlayerMerge {
    struct Impact: Equatable {
        var matches = 0
        var events = 0
        var lineups = 0
        var substitutions = 0
        /// 2人がどちらもメンバー表に載っている(または入れ替わった)試合の数。1以上なら別人なので統合できない
        var matchesTogether = 0
    }

    enum MergeError: LocalizedError {
        case samePlayer
        case differentTeam
        case playedTogether(Int)

        var errorDescription: String? {
            switch self {
            case .samePlayer:
                return "同じ選手は統合できません。"
            case .differentTeam:
                return "別のチームの選手は統合できません。移籍や代表などで同じ人のときは「同一人物としてつなぐ」を使ってください。"
            case .playedTogether(let count):
                return "この2人が同じ試合のメンバー表に載っている試合が\(count)試合あるため、別の選手として扱います。"
            }
        }
    }

    static func impact(of source: Player, into target: Player, context: ModelContext) throws -> Impact {
        let sourceID = source.id
        let optionalSourceID: UUID? = sourceID
        let targetID = target.id
        let events = try context.fetch(FetchDescriptor<StatEvent>(predicate: #Predicate { $0.playerID == optionalSourceID }))
        let lineups = try context.fetch(FetchDescriptor<MatchLineup>(predicate: #Predicate {
            $0.playerID == sourceID || $0.playerID == targetID
        }))
        let substitutions = try context.fetch(FetchDescriptor<Substitution>(predicate: #Predicate {
            $0.playerInID == sourceID || $0.playerOutID == sourceID
        }))
        let sourceLineups = lineups.filter { $0.playerID == sourceID }
        let targetLineupMatches = Set(lineups.filter { $0.playerID == targetID }.map(\.matchID))
        var together = Set(sourceLineups.map(\.matchID)).intersection(targetLineupMatches)
        for substitution in substitutions where Set([substitution.playerInID, substitution.playerOutID]) == Set([sourceID, targetID]) {
            together.insert(substitution.matchID)
        }
        var impact = Impact()
        impact.events = events.count
        impact.lineups = sourceLineups.count
        impact.substitutions = substitutions.count
        impact.matches = Set(events.map(\.matchID) + sourceLineups.map(\.matchID) + substitutions.map(\.matchID)).count
        impact.matchesTogether = together.count
        return impact
    }

    /// 統合後の別名。消える方の名前と別名を足し、残す方の名前と重複は除く
    static func mergedAliases(target: Player, source: Player) -> [String] {
        var result: [String] = []
        for name in target.aliases + [source.name].compactMap({ $0 }) + source.aliases {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != target.name, !result.contains(trimmed) else { continue }
            result.append(trimmed)
        }
        return result
    }

    @MainActor
    @discardableResult
    static func merge(
        _ source: Player,
        into target: Player,
        context: ModelContext,
        defaults: UserDefaults = .standard,
        removeImage: (String) -> Void
    ) -> Bool {
        let sourceID = source.id
        let optionalSourceID: UUID? = sourceID
        let targetID = target.id
        var restores: [() -> Void] = []
        var imagesToCheck: [String] = []

        return AppPersistence.transaction(context, restoreVisibleValues: {
            restores.reversed().forEach { $0() }
        }, mutation: {
            guard sourceID != targetID else { throw MergeError.samePlayer }
            guard source.teamID == target.teamID else { throw MergeError.differentTeam }
            let impact = try impact(of: source, into: target, context: context)
            guard impact.matchesTogether == 0 else { throw MergeError.playedTogether(impact.matchesTogether) }

            var matchIDs = Set<UUID>()

            for event in try context.fetch(FetchDescriptor<StatEvent>(predicate: #Predicate { $0.playerID == optionalSourceID })) {
                restores.append { event.playerID = sourceID }
                event.playerID = targetID
                matchIDs.insert(event.matchID)
            }
            for lineup in try context.fetch(FetchDescriptor<MatchLineup>(predicate: #Predicate { $0.playerID == sourceID })) {
                restores.append { lineup.playerID = sourceID }
                lineup.playerID = targetID
                matchIDs.insert(lineup.matchID)
            }
            for substitution in try context.fetch(FetchDescriptor<Substitution>(predicate: #Predicate {
                $0.playerInID == sourceID || $0.playerOutID == sourceID
            })) {
                let original = (substitution.playerInID, substitution.playerOutID)
                restores.append { (substitution.playerInID, substitution.playerOutID) = original }
                if substitution.playerInID == sourceID { substitution.playerInID = targetID }
                if substitution.playerOutID == sourceID { substitution.playerOutID = targetID }
                matchIDs.insert(substitution.matchID)
            }

            // その試合に保存した記録途中の状態・入力データに書かれた選手も付け替える
            let ids = Array(matchIDs)
            for match in try context.fetch(FetchDescriptor<Match>(predicate: #Predicate { ids.contains($0.id) })) {
                let original = (match.recordingLayoutData, match.recordingSessionData)
                restores.append { (match.recordingLayoutData, match.recordingSessionData) = original }
                match.recordingLayoutData = TeamMerge.replacingID(sourceID, with: targetID, in: match.recordingLayoutData)
                match.recordingSessionData = TeamMerge.replacingID(sourceID, with: targetID, in: match.recordingSessionData)
            }
            for event in try context.fetch(FetchDescriptor<StatEvent>(predicate: #Predicate { ids.contains($0.matchID) }))
            where event.widgetData != nil {
                let original = event.widgetData
                restores.append { event.widgetData = original }
                event.widgetData = TeamMerge.replacingID(sourceID, with: targetID, in: event.widgetData)
            }

            // 残す方: 名前はそのまま、空いている項目だけ消える方から引き継ぐ
            let original = (target.aliases, target.number, target.name, target.nameKana, target.nameRoman,
                            target.imagePath, target.position, target.birthDate, target.heightCm, target.weightKg,
                            target.isFavorite)
            restores.append {
                (target.aliases, target.number, target.name, target.nameKana, target.nameRoman,
                 target.imagePath, target.position, target.birthDate, target.heightCm, target.weightKg,
                 target.isFavorite) = original
            }
            target.aliases = mergedAliases(target: target, source: source)
            if target.number == nil { target.number = source.number }
            if (target.name ?? "").isEmpty { target.name = source.name }
            if (target.nameKana ?? "").isEmpty { target.nameKana = source.nameKana }
            if (target.nameRoman ?? "").isEmpty { target.nameRoman = source.nameRoman }
            if target.imagePath == nil { target.imagePath = source.imagePath }
            if target.position == nil { target.position = source.position }
            if target.birthDate == nil { target.birthDate = source.birthDate }
            if target.heightCm == nil { target.heightCm = source.heightCm }
            if target.weightKg == nil { target.weightKg = source.weightKg }
            target.isFavorite = target.isFavorite || source.isFavorite
            imagesToCheck = [source.imagePath].compactMap { $0 }

            context.delete(source)
        }, afterSave: {
            // 保存した分析レポートで選んでいた選手も付け替える
            if let data = defaults.data(forKey: AnalysisReport.storageKey),
               let replaced = TeamMerge.replacingID(sourceID, with: targetID, in: data), replaced != data {
                defaults.set(replaced, forKey: AnalysisReport.storageKey)
            }
            SafeDeletion.removeUnreferencedImages(imagesToCheck, context: context, remove: removeImage)
        })
    }
}
