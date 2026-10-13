//
//  AnalysisEventRecord.swift
//  Rugby AS
//
//  分析の計算が読む「記録」の形。保存されている記録(StatEvent)そのものでも、
//  そこから値だけ写した軽い記録(AnalysisEventRow)でも、同じ計算に通せるようにする。
//  記録が24万件あると、StatEvent を全部作るだけで Mac でも約10秒・メモリも大きく使うため、
//  分析画面は保存先のファイルから値だけを直接読んだ軽い記録で集計する(結果は同じ)。
//

import Foundation
import SQLite3
import SwiftData

nonisolated protocol AnalysisEventRecord {
    var id: UUID { get }
    var matchID: UUID { get }
    var teamID: UUID? { get }
    var playerID: UUID? { get }
    var category: String { get }
    var outcome: String { get }
    var seconds: Int { get }
    var startSeconds: Int? { get }
    var startSecondsExact: Double? { get }
    var half: Int { get }
    var origin: String? { get }
    var recordingOrigin: PlayOrigin? { get }
    var recordingDetails: RecordingEventDetails { get }
}

nonisolated extension StatEvent: AnalysisEventRecord {}

extension PlayOrigin {
    /// 記録に保存した起点の文字列を読む(古い名前も受け付ける)
    nonisolated static func recorded(_ origin: String?) -> PlayOrigin? {
        guard let origin else { return nil }
        if let known = PlayOrigin(rawValue: origin) { return known }
        switch origin {
        case "kickoff": return .restart
        case "penalty": return .tapKick
        default: return nil
        }
    }
}

extension RecordingEventDetails {
    /// 保存した中身をほどく。読めなければ空(記録時刻は不明)にする(StatEvent.recordingDetails と同じ規則)
    nonisolated static func decoded(from data: Data?) -> RecordingEventDetails {
        if let data, let decoded = try? JSONDecoder().decode(RecordingEventDetails.self, from: data) { return decoded }
        var fallback = RecordingEventDetails()
        fallback.recordedAt = .distantPast
        return fallback
    }
}

/// 分析用の軽い記録。値だけを持つので、裏の処理でそのまま扱える
nonisolated struct AnalysisEventRow: AnalysisEventRecord, Sendable {
    let id: UUID
    let matchID: UUID
    let teamID: UUID?
    let playerID: UUID?
    let category: String
    let outcome: String
    let seconds: Int
    let startSeconds: Int?
    let startSecondsExact: Double?
    let half: Int
    let origin: String?
    let recordingDetails: RecordingEventDetails

    var recordingOrigin: PlayOrigin? { PlayOrigin.recorded(origin) }

    init(id: UUID, matchID: UUID, teamID: UUID?, playerID: UUID?, category: String, outcome: String, seconds: Int,
         startSeconds: Int?, startSecondsExact: Double?, half: Int, origin: String?, widgetData: Data?) {
        self.id = id; self.matchID = matchID; self.teamID = teamID; self.playerID = playerID
        self.category = category; self.outcome = outcome; self.seconds = seconds
        self.startSeconds = startSeconds; self.startSecondsExact = startSecondsExact
        self.half = half; self.origin = origin
        recordingDetails = RecordingEventDetails.decoded(from: widgetData)
    }

    init(_ event: StatEvent) {
        self.init(id: event.id, matchID: event.matchID, teamID: event.teamID, playerID: event.playerID,
                  category: event.category, outcome: event.outcome, seconds: event.seconds,
                  startSeconds: event.startSeconds, startSecondsExact: event.startSecondsExact,
                  half: event.half, origin: event.origin, widgetData: event.widgetData)
    }
}

/// 保存先のファイル(SQLite)を読むだけの道具。書き換えはしない。
/// 列や表の形が想定と違えば nil を返し、呼ぶ側は SwiftData での読み方に戻す。
nonisolated enum StoreFileReader {
    /// 分析に使う記録(試合終了の印とポゼッションを除く)
    static func analysisRows(storeURL: URL?) -> [AnalysisEventRow]? {
        guard let storeURL, FileManager.default.fileExists(atPath: storeURL.path) else { return nil }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db = handle else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT ZID, ZMATCHID, ZTEAMID, ZPLAYERID, ZCATEGORY, ZOUTCOME, ZSECONDS, ZSTARTSECONDS,
               ZSTARTSECONDSEXACT, ZHALF, ZORIGIN, ZWIDGETDATA
        FROM ZSTATEVENT WHERE ZCATEGORY <> 'match_state' AND ZCATEGORY <> 'possession'
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            return nil
        }
        defer { sqlite3_finalize(statement) }
        var rows: [AnalysisEventRow] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return nil }
            guard let id = uuid(statement, 0), let matchID = uuid(statement, 1),
                  let category = text(statement, 4), let outcome = text(statement, 5) else { continue }
            rows.append(AnalysisEventRow(
                id: id, matchID: matchID, teamID: uuid(statement, 2), playerID: uuid(statement, 3),
                category: category, outcome: outcome, seconds: Int(sqlite3_column_int64(statement, 6)),
                startSeconds: isNull(statement, 7) ? nil : Int(sqlite3_column_int64(statement, 7)),
                startSecondsExact: isNull(statement, 8) ? nil : sqlite3_column_double(statement, 8),
                half: Int(sqlite3_column_int64(statement, 9)), origin: text(statement, 10), widgetData: blob(statement, 11)))
        }
        return rows
    }

    /// 選手と試合の組(メンバー表と、選手の付いた記録)。出場の様子を数えるのに使う
    static func playerMatchPairs(storeURL: URL?) -> (lineups: [(player: UUID, match: UUID)], events: [(player: UUID, match: UUID)])? {
        guard let storeURL, FileManager.default.fileExists(atPath: storeURL.path) else { return nil }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db = handle else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        defer { sqlite3_close(db) }
        func pairs(_ sql: String) -> [(player: UUID, match: UUID)]? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                if let statement { sqlite3_finalize(statement) }
                return nil
            }
            defer { sqlite3_finalize(statement) }
            var result: [(player: UUID, match: UUID)] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { return result }
                guard step == SQLITE_ROW else { return nil }
                if let player = uuid(statement, 0), let match = uuid(statement, 1) { result.append((player, match)) }
            }
        }
        guard let lineups = pairs("SELECT ZPLAYERID, ZMATCHID FROM ZMATCHLINEUP"),
              let events = pairs("SELECT ZPLAYERID, ZMATCHID FROM ZSTATEVENT WHERE ZPLAYERID IS NOT NULL") else { return nil }
        return (lineups, events)
    }

    static func isNull(_ statement: OpaquePointer, _ column: Int32) -> Bool {
        sqlite3_column_type(statement, column) == SQLITE_NULL
    }

    static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard !isNull(statement, column), let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }

    static func blob(_ statement: OpaquePointer, _ column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) == SQLITE_BLOB, let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    /// SwiftData は UUID を16バイトのまま保存している
    static func uuid(_ statement: OpaquePointer, _ column: Int32) -> UUID? {
        guard sqlite3_column_type(statement, column) == SQLITE_BLOB, sqlite3_column_bytes(statement, column) == 16,
              let bytes = sqlite3_column_blob(statement, column) else { return nil }
        let raw = bytes.assumingMemoryBound(to: UInt8.self)
        return UUID(uuid: (raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
                           raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]))
    }
}
