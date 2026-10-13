//
//  TeamMerge.swift
//  Rugby AS
//
//  本当は同じチームなのに2つに分かれてしまったチーム(大会ごとの表記ゆれ・旧名など)を、
//  1つにまとめる。消える方(source)の試合・選手・記録・メンバー表・大会の出場登録を、
//  残す方(target)に付け替え、消える方の名前は残す方の「別名」に入れる。
//
//  チームのIDは、データベースの項目のほかに、記録途中の状態や記録ボードの設定(試合に保存した
//  JSON)と、保存した分析レポート(UserDefaults)にも書かれているので、それらも書き換える。
//  元に戻せない操作なので、画面側で影響する件数を見せて確認してから呼ぶ。
//

import Foundation
import SwiftData

enum TeamMerge {
    /// 統合で付け替わる件数(確認画面に出す)
    struct Impact: Equatable {
        var matches = 0
        var players = 0
        var events = 0
        var lineups = 0
        var tournaments = 0
        /// この2チームどうしの試合の数。1以上なら統合できない(同じチーム同士の試合になってしまうため)
        var matchesBetween = 0
    }

    enum MergeError: LocalizedError {
        case sameTeam
        case playedEachOther(Int)

        var errorDescription: String? {
            switch self {
            case .sameTeam:
                return "同じチームは統合できません。"
            case .playedEachOther(let count):
                return "この2チームが対戦した試合が\(count)試合あるため統合できません。本当に別のチームでないか確認してください。"
            }
        }
    }

    static func impact(of source: Team, into target: Team, context: ModelContext) throws -> Impact {
        let sourceID = source.id
        let optionalSourceID: UUID? = sourceID
        let targetID = target.id
        var impact = Impact()
        let matches = try context.fetch(FetchDescriptor<Match>(predicate: #Predicate {
            $0.homeTeamID == sourceID || $0.awayTeamID == sourceID
        }))
        impact.matches = matches.count
        impact.matchesBetween = matches.filter { $0.homeTeamID == targetID || $0.awayTeamID == targetID }.count
        impact.players = try context.fetchCount(FetchDescriptor<Player>(predicate: #Predicate { $0.teamID == sourceID }))
        impact.events = try context.fetchCount(FetchDescriptor<StatEvent>(predicate: #Predicate { $0.teamID == optionalSourceID }))
        impact.lineups = try context.fetchCount(FetchDescriptor<MatchLineup>(predicate: #Predicate { $0.teamID == sourceID }))
        impact.tournaments = try context.fetch(FetchDescriptor<Tournament>()).filter { $0.teamIDs.contains(sourceID) }.count
        return impact
    }

    /// 統合後の別名。消える方の名前と別名を足し、残す方の名前と重複は除く(表記の細かい違いは残す)
    static func mergedAliases(target: Team, source: Team) -> [String] {
        var result: [String] = []
        for name in target.aliases + [source.name] + source.aliases {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != target.name, !result.contains(trimmed) else { continue }
            result.append(trimmed)
        }
        return result
    }

    /// source を target にまとめる。成功したら true。失敗したら何も変えずに false(画面に理由を知らせる)。
    @MainActor
    @discardableResult
    static func merge(
        _ source: Team,
        into target: Team,
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
            guard sourceID != targetID else { throw MergeError.sameTeam }

            let matches = try context.fetch(FetchDescriptor<Match>(predicate: #Predicate {
                $0.homeTeamID == sourceID || $0.awayTeamID == sourceID
            }))
            let between = matches.filter { $0.homeTeamID == targetID || $0.awayTeamID == targetID }.count
            guard between == 0 else { throw MergeError.playedEachOther(between) }

            // 試合(と、試合に保存した記録途中の状態・記録ボード)
            for match in matches {
                let original = (match.homeTeamID, match.awayTeamID, match.recordingLayoutData, match.recordingSessionData)
                restores.append {
                    (match.homeTeamID, match.awayTeamID, match.recordingLayoutData, match.recordingSessionData) = original
                }
                if match.homeTeamID == sourceID { match.homeTeamID = targetID }
                if match.awayTeamID == sourceID { match.awayTeamID = targetID }
                match.recordingLayoutData = replacingID(sourceID, with: targetID, in: match.recordingLayoutData)
                match.recordingSessionData = replacingID(sourceID, with: targetID, in: match.recordingSessionData)
            }

            // 記録(チームの付いた記録と、その試合の記録に残る入力データ)
            let matchIDs = matches.map(\.id)
            let events = try context.fetch(FetchDescriptor<StatEvent>(predicate: #Predicate {
                $0.teamID == optionalSourceID || matchIDs.contains($0.matchID)
            }))
            for event in events {
                let original = (event.teamID, event.widgetData)
                restores.append { (event.teamID, event.widgetData) = original }
                if event.teamID == sourceID { event.teamID = targetID }
                event.widgetData = replacingID(sourceID, with: targetID, in: event.widgetData)
            }

            // メンバー表・選手
            for lineup in try context.fetch(FetchDescriptor<MatchLineup>(predicate: #Predicate { $0.teamID == sourceID })) {
                restores.append { lineup.teamID = sourceID }
                lineup.teamID = targetID
            }
            for player in try context.fetch(FetchDescriptor<Player>(predicate: #Predicate { $0.teamID == sourceID })) {
                restores.append { player.teamID = sourceID }
                player.teamID = targetID
            }

            // 大会の出場チーム(両方登録されていた大会は1つにまとめる)
            for tournament in try context.fetch(FetchDescriptor<Tournament>()) where tournament.teamIDs.contains(sourceID) {
                let original = tournament.teamIDs
                restores.append { tournament.teamIDs = original }
                var merged: [UUID] = []
                for id in tournament.teamIDs {
                    let mapped = id == sourceID ? targetID : id
                    if !merged.contains(mapped) { merged.append(mapped) }
                }
                tournament.teamIDs = merged
            }

            // 残す方のチーム: 名前はそのまま、空いている項目だけ消える方から引き継ぐ
            let original = (target.aliases, target.logoPath, target.colorHex, target.category)
            restores.append { (target.aliases, target.logoPath, target.colorHex, target.category) = original }
            target.aliases = mergedAliases(target: target, source: source)
            if target.logoPath == nil { target.logoPath = source.logoPath }
            if target.colorHex == nil { target.colorHex = source.colorHex }
            if (target.category ?? "").isEmpty { target.category = source.category }
            imagesToCheck = [source.logoPath].compactMap { $0 }

            context.delete(source)
        }, afterSave: {
            // 保存した分析レポートの条件に書かれたチームも付け替える(データベースの保存が済んでから)
            if let data = defaults.data(forKey: AnalysisReport.storageKey),
               let replaced = replacingID(sourceID, with: targetID, in: data), replaced != data {
                defaults.set(replaced, forKey: AnalysisReport.storageKey)
            }
            SafeDeletion.removeUnreferencedImages(imagesToCheck, context: context, remove: removeImage)
        })
    }

    /// JSON などの中に書かれたIDを置き換える(大文字・小文字どちらの書き方でも)。読めないデータはそのまま返す。
    static func replacingID(_ old: UUID, with new: UUID, in data: Data?) -> Data? {
        guard let data, let text = String(data: data, encoding: .utf8) else { return data }
        let replaced = text
            .replacingOccurrences(of: old.uuidString, with: new.uuidString)
            .replacingOccurrences(of: old.uuidString.lowercased(), with: new.uuidString.lowercased())
        return replaced == text ? data : Data(replaced.utf8)
    }
}
