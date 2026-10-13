import Foundation
import SQLite3
import SwiftData

struct MatchListSide: Sendable {
    let id: UUID
    let home: UUID
    let away: UUID
}

struct MatchListTally: Sendable, Equatable, Codable {
    var isFinished = false
    var homeScore = 0
    var awayScore = 0
    var homeFirstHalf = 0
    var awayFirstHalf = 0
    var homeSecondHalf = 0
    var awaySecondHalf = 0
    nonisolated init() {}
}

enum MatchListSummary {
    // The list needs only scoring and finish markers. Scoring metadata retains
    // historical point values; unrelated detailed play records are not loaded.
    nonisolated static func descriptor(matchIDs: [UUID]? = nil) -> FetchDescriptor<StatEvent> {
        let scoring = ScoringRules.categories
        var descriptor = FetchDescriptor<StatEvent>(predicate: #Predicate<StatEvent> {
            ($0.category == "match_state" && $0.outcome == "finished") ||
            ($0.outcome == "success" && scoring.contains($0.category))
        })
        if let matchIDs {
            descriptor.predicate = #Predicate<StatEvent> {
                matchIDs.contains($0.matchID) && (($0.category == "match_state" && $0.outcome == "finished") ||
                ($0.outcome == "success" && scoring.contains($0.category)))
            }
        }
        descriptor.propertiesToFetch = [\.matchID, \.teamID, \.category, \.outcome, \.half, \.widgetData]
        return descriptor
    }

    nonisolated static func load(container: ModelContainer, sides: [MatchListSide]) throws -> [UUID: MatchListTally] {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return try load(context: context, sides: sides)
    }

    /// onlyListed が true なら、sides に渡した試合の記録だけを読む(変わった試合だけ数え直すとき)
    nonisolated static func load(context: ModelContext, sides: [MatchListSide], onlyListed: Bool = false) throws -> [UUID: MatchListTally] {
        let sidesByID = Dictionary(sides.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var tallies = Dictionary(sides.map { ($0.id, MatchListTally()) }, uniquingKeysWith: { first, _ in first })
        try context.enumerate(descriptor(matchIDs: onlyListed ? sides.map(\.id) : nil), batchSize: 500) { event in
            try Task.checkCancellation()
            guard let side = sidesByID[event.matchID], var tally = tallies[event.matchID] else { return }
            if event.category == "match_state" { tally.isFinished = true }
            else {
                let points = ScoringRules.points(category: event.category, widgetData: event.widgetData)
                if event.teamID == side.home {
                    tally.homeScore += points
                    if event.half == 0 { tally.homeFirstHalf += points }
                    if event.half == 1 { tally.homeSecondHalf += points }
                } else if event.teamID == side.away {
                    tally.awayScore += points
                    if event.half == 0 { tally.awayFirstHalf += points }
                    if event.half == 1 { tally.awaySecondHalf += points }
                }
            }
            tallies[event.matchID] = tally
        }
        return tallies
    }
}

/// 試合一覧の得点の控え。起動したらまずこれを出し、変わった試合だけ数え直す
/// (全試合を数え直すと、試合が数万あるときに起動のたびに長く待たされるため)。
nonisolated enum MatchListTallyCache {
    private static var url: URL {
        URL.applicationSupportDirectory.appendingPathComponent("MatchListTallies.v1.json")
    }

    static func load() -> [UUID: MatchListTally]? {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([String: MatchListTally].self, from: data) else { return nil }
        return Dictionary(stored.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } },
                          uniquingKeysWith: { first, _ in first })
    }

    static func save(_ tallies: [UUID: MatchListTally]) {
        let stored = Dictionary(tallies.map { ($0.key.uuidString, $0.value) }, uniquingKeysWith: { first, _ in first })
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// 試合一覧の得点を、保存先のファイル(SQLite)から直接読んで数える。
/// SwiftData で記録を1件ずつ作ると、得点の記録が約19万件あるときに Mac でも7秒かかる。
/// ここは読むだけ(書き換えない)で、約0.1秒で終わる。保存先の形が想定と違えば nil を返し、
/// 呼ぶ側は今までの数え方に戻す(アプリの更新で保存の形が変わっても、得点が出なくならないように)。
nonisolated enum MatchListFastTally {
    static func load(storeURL: URL?, sides: [MatchListSide]) -> [UUID: MatchListTally]? {
        guard let storeURL, FileManager.default.fileExists(atPath: storeURL.path) else { return nil }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db = handle else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        defer { sqlite3_close(db) }
        let categories = ScoringRules.categories.map { "'\($0)'" }.joined(separator: ",")
        let sql = """
        SELECT ZMATCHID, ZTEAMID, ZCATEGORY, ZHALF, ZWIDGETDATA FROM ZSTATEVENT
        WHERE (ZCATEGORY = 'match_state' AND ZOUTCOME = 'finished') OR (ZOUTCOME = 'success' AND ZCATEGORY IN (\(categories)))
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            return nil
        }
        defer { sqlite3_finalize(statement) }

        let sidesByID = Dictionary(sides.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var tallies = Dictionary(sides.map { ($0.id, MatchListTally()) }, uniquingKeysWith: { first, _ in first })
        func uuid(_ column: Int32) -> UUID? {
            guard sqlite3_column_type(statement, column) == SQLITE_BLOB, sqlite3_column_bytes(statement, column) == 16,
                  let bytes = sqlite3_column_blob(statement, column) else { return nil }
            let raw = bytes.assumingMemoryBound(to: UInt8.self)
            return UUID(uuid: (raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
                               raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]))
        }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return nil }
            guard let matchID = uuid(0), let side = sidesByID[matchID], var tally = tallies[matchID],
                  let text = sqlite3_column_text(statement, 2) else { continue }
            let category = String(cString: text)
            if category == "match_state" {
                tally.isFinished = true
            } else {
                var widgetData: Data?
                if sqlite3_column_type(statement, 4) == SQLITE_BLOB, let blob = sqlite3_column_blob(statement, 4) {
                    widgetData = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 4)))
                }
                let points = ScoringRules.points(category: category, widgetData: widgetData)
                let half = sqlite3_column_int(statement, 3)
                let teamID = uuid(1)
                if teamID == side.home {
                    tally.homeScore += points
                    if half == 0 { tally.homeFirstHalf += points }
                    if half == 1 { tally.homeSecondHalf += points }
                } else if teamID == side.away {
                    tally.awayScore += points
                    if half == 0 { tally.awayFirstHalf += points }
                    if half == 1 { tally.awaySecondHalf += points }
                }
            }
            tallies[matchID] = tally
        }
        return tallies
    }
}
