//
//  OfficialHeadToHead.swift
//  Rugby AS
//
//  対戦成績に、まだ取り込んでいない公式記録の試合も加えるための照合。
//  チーム名は取り込みと同じ方法で比べる(SVNS・W杯は「（男子7人制）」などを付けた名前、
//  空白・全角半角・大文字小文字は区別しない、チームの別名も見る)。
//  すでに自分の試合として保存してある対戦(公式記録の ID が同じ、または同じ日の同じ2チーム)は除く。
//

import Foundation

nonisolated enum OfficialHeadToHead {
    struct Meeting: Sendable {
        let summary: OfficialRecordSummary
        /// 公式記録のホームが、比べている「チームA」かどうか
        let homeIsTeamA: Bool
        let playedAt: Date
    }

    /// 保存済みの試合(重複を除くのに使う)
    struct SavedMatch: Sendable {
        let officialRecordID: String?
        let playedAt: Date
    }

    /// - Parameters:
    ///   - teamA, teamB: 各チームの名前(本名と別名)
    ///   - before: この時刻より前の試合だけ
    ///   - saved: この2チームの保存済みの試合(すべて。重複を除くのに使う)
    ///   - variant: この試合が 7人制/15人制 のどちらか(分からなければ nil)。
    ///     JRFU の記録は代表のセブンズも同じチーム名なので、大会名から分かる人数が違う試合は加えない。
    static func meetings(in summaries: [OfficialRecordSummary], teamA: [String], teamB: [String],
                         before: Date, saved: [SavedMatch], variant: RugbyVariant? = nil,
                         calendar: Calendar = .current) -> [Meeting] {
        let keysA = Set(teamA.map(OfficialRecordImporter.nameKey).filter { !$0.isEmpty })
        let keysB = Set(teamB.map(OfficialRecordImporter.nameKey).filter { !$0.isEmpty })
        guard !keysA.isEmpty, !keysB.isEmpty, keysA.isDisjoint(with: keysB) else { return [] }
        let savedIDs = Set(saved.compactMap(\.officialRecordID))
        // 日ごとの保存済み試合の掲載元(手入力は "")。取り込みの重複判定と同じ考え方
        var savedSources: [Date: Set<String>] = [:]
        for match in saved {
            let source = match.officialRecordID?.components(separatedBy: ":").first ?? ""
            savedSources[calendar.startOfDay(for: match.playedAt), default: []].insert(source)
        }
        var result: [Meeting] = []
        for summary in summaries where !savedIDs.contains(summary.id) {
            let home = OfficialRecordImporter.nameKey(
                OfficialRecordImporter.importedTeamName(summary.homeTeam, source: summary.source, category: summary.category))
            let away = OfficialRecordImporter.nameKey(
                OfficialRecordImporter.importedTeamName(summary.awayTeam, source: summary.source, category: summary.category))
            let homeIsTeamA: Bool
            if keysA.contains(home) && keysB.contains(away) { homeIsTeamA = true }
            else if keysB.contains(home) && keysA.contains(away) { homeIsTeamA = false }
            else { continue }
            if let variant, let other = TournamentCategory.inferredVariant(from: summary.tournament), other != variant { continue }
            guard let playedAt = OfficialRecordImporter.playedAt(date: summary.date, kickoff: summary.kickoff, calendar: calendar),
                  playedAt < before else { continue }
            // 手入力や別の掲載元から保存した同じ日の同じ対戦は、同じ試合とみなして二重に数えない。
            // 同じ掲載元で ID が違うものは、セブンズの1日2回の対戦のように別の試合。
            let sameDay = savedSources[calendar.startOfDay(for: playedAt), default: []]
            if sameDay.contains("") || sameDay.contains(where: { $0 != summary.source }) { continue }
            result.append(Meeting(summary: summary, homeIsTeamA: homeIsTeamA, playedAt: playedAt))
        }
        return result
    }
}

/// 公式記録の終了した試合の一覧を、アプリを動かしている間だけ覚えておく(同梱の公式記録は変わらないため)。
actor OfficialSummaryCache {
    static let shared = OfficialSummaryCache()
    private var summaries: [URL: [OfficialRecordSummary]] = [:]

    func finished(at url: URL) throws -> [OfficialRecordSummary] {
        if let cached = summaries[url] { return cached }
        let loaded = try OfficialRecordsStore.finishedSummaries(at: url)
        summaries[url] = loaded
        return loaded
    }
}
