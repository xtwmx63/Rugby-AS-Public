import Foundation
import SQLite3

// This archive is bundled reference data. It never opens the personal SwiftData store.
nonisolated struct OfficialRecordSummary: Identifiable, Sendable {
    let id: String
    let source: String
    let season: String
    let year: Int
    let category: String
    let tournament: String
    let round: String
    let date: String
    let kickoff: String
    let venue: String
    let homeTeam: String
    let awayTeam: String
    let homeScore: Int?
    let awayScore: Int?
    let status: String
    let detailLevel: String
}

nonisolated struct OfficialRecord: Decodable, Sendable {
    let id: String
    let source: String
    let season: String
    let year: Int
    let category: String
    let categories: [String]?
    let tournament: String
    let round: String
    let date: String
    let kickoff: String
    /// 海外大会は開催地の表示時刻とは別に、取り込み用の絶対時刻を持つ。
    let kickoffUTC: String?
    let seriesName: String?
    let omissions: [String]?
    let venue: String
    let homeTeam: String
    let awayTeam: String
    let homeScore: Int?
    let awayScore: Int?
    let homeFirstHalfScore: Int?
    let awayFirstHalfScore: Int?
    let homeSecondHalfScore: Int?
    let awaySecondHalfScore: Int?
    let status: String
    let sourceURL: String
    let officialRecordURL: String?
    let fetchedAt: String
    let detailLevel: String
    let players: [OfficialRecordPlayer]
    let scoreEvents: [OfficialRecordScoreEvent]
    let substitutions: [OfficialRecordSubstitution]
    let stats: [OfficialRecordStat]

    var categoryMemberships: [String] { categories ?? [category] }
}

nonisolated struct OfficialRecordPlayer: Decodable, Sendable {
    let side: String
    let number: Int?
    let name: String
    let position: String
    let role: String
}

nonisolated struct OfficialRecordScoreEvent: Decodable, Sendable {
    let period: String
    let time: String
    let side: String
    let player: String
    let kind: String
    let points: Int?
    let homeScore: Int?
    let awayScore: Int?
}

nonisolated struct OfficialRecordSubstitution: Decodable, Sendable {
    let side: String
    let period: String
    let time: String
    let outgoing: String
    let incoming: String
    let kind: String
}

nonisolated struct OfficialRecordStat: Decodable, Sendable {
    let label: String
    let home: String
    let away: String
}

nonisolated struct OfficialArchiveCoverage: Decodable, Sendable {
    let source: String
    let season: String
    let category: String
    let scheduleURL: String
    let discovered: Int
    let imported: Int
    let fullDetails: Int
}

nonisolated struct OfficialArchiveManifest: Decodable, Sendable {
    let schemaVersion: Int
    let generatedAt: String
    let coverage: [OfficialArchiveCoverage]
    let errors: [ImportError]
    let matchCount: Int
    let fullDetailCount: Int

    nonisolated struct ImportError: Decodable, Sendable {
        let url: String
        let message: String
    }
}

nonisolated struct OfficialArchiveOptions: Sendable {
    let sources: [String]
    let categories: [String]
    let years: [String]
    let seasons: [String]
    let tournaments: [String]
}

nonisolated struct OfficialArchiveQuery: Equatable, Sendable {
    var text = ""
    var source = ""
    var category = ""
    var year = ""
    var season = ""
    var tournament = ""
    var status = ""

    var filterCount: Int {
        [source, category, year, season, tournament, status].filter { !$0.isEmpty }.count
    }
}

nonisolated struct OfficialTournamentStage: Sendable {
    let tournament: String
    let year: Int
    let matchCount: Int
    let firstDate: String
    let lastDate: String
    let finishedCount: Int
}

nonisolated struct OfficialArchivePage: Sendable {
    let matches: [OfficialRecordSummary]
    let total: Int
}

nonisolated enum OfficialArchiveError: LocalizedError {
    case missing
    case unreadable
    case unsupportedVersion
    case missingMatch

    var errorDescription: String? {
        switch self {
        case .missing: return "公式記録のデータベースが見つかりません。"
        case .unreadable: return "公式記録を読み込めませんでした。もう一度お試しください。"
        case .unsupportedVersion: return "この公式記録を開くにはアプリの更新が必要です。"
        case .missingMatch: return "この試合の詳細を見つけられませんでした。"
        }
    }
}

nonisolated enum OfficialRecordsStore {
    static let pageSize = 80

    static func metadata(at url: URL) throws -> (OfficialArchiveManifest, OfficialArchiveOptions) {
        try withDatabase(at: url) { db in
            let statement = try prepare(db, "SELECT value FROM metadata WHERE key = 'manifest'")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let data = string(statement, 0).data(using: .utf8) else { throw OfficialArchiveError.unreadable }
            let manifest = try JSONDecoder().decode(OfficialArchiveManifest.self, from: data)
            guard manifest.schemaVersion == 1 else { throw OfficialArchiveError.unsupportedVersion }
            let options = OfficialArchiveOptions(
                sources: try distinct(db, column: "source"),
                categories: try distinct(db, table: "match_categories", column: "category"),
                years: try distinct(db, column: "year", descending: true),
                seasons: try distinct(db, column: "season", descending: true),
                tournaments: try distinct(db, column: "tournament")
            )
            return (manifest, options)
        }
    }

    static func search(at url: URL, query: OfficialArchiveQuery, offset: Int = 0) throws -> OfficialArchivePage {
        try withDatabase(at: url) { db in
            var clauses: [String] = []
            var values: [String] = []
            for (column, value) in [("source", query.source),
                                    ("year", query.year), ("season", query.season), ("tournament", query.tournament), ("status", query.status)] {
                if !value.isEmpty { clauses.append("\(column) = ?"); values.append(value) }
            }
            if !query.category.isEmpty {
                clauses.append("EXISTS (SELECT 1 FROM match_categories AS membership WHERE membership.matchID = matches.id AND membership.category = ?)")
                values.append(query.category)
            }
            // Each word must occur in at least one of the names. Bind every value;
            // a literal '%' or '_' in the user's text is not a SQL wildcard.
            for term in query.text.split(whereSeparator: { $0.isWhitespace }) {
                clauses.append("(homeTeam LIKE ? ESCAPE '\\' OR awayTeam LIKE ? ESCAPE '\\' OR tournament LIKE ? ESCAPE '\\')")
                let escaped = String(term).replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                values.append(contentsOf: Array(repeating: "%\(escaped)%", count: 3))
            }
            let predicate = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
            let counter = try prepare(db, "SELECT COUNT(*) FROM matches" + predicate, values: values)
            defer { sqlite3_finalize(counter) }
            guard sqlite3_step(counter) == SQLITE_ROW else { throw OfficialArchiveError.unreadable }
            let total = Int(sqlite3_column_int64(counter, 0))
            let sql = "SELECT \(summaryColumns) FROM matches" + predicate + " ORDER BY date DESC, kickoff DESC, id ASC LIMIT ? OFFSET ?"
            let statement = try prepare(db, sql, values: values + [String(pageSize), String(max(0, offset))])
            defer { sqlite3_finalize(statement) }
            return OfficialArchivePage(matches: try summaries(from: statement), total: total)
        }
    }

    /// 終了した全試合の概要(ページ分けなし)。チームどうしの対戦を探すときに使う。
    /// 表記ゆれ(空白・全角半角)は呼ぶ側で整えて比べるため、ここでは絞り込まない。
    static func finishedSummaries(at url: URL) throws -> [OfficialRecordSummary] {
        try withDatabase(at: url) { db in
            let statement = try prepare(db, "SELECT \(summaryColumns) FROM matches WHERE status = 'finished' AND homeScore IS NOT NULL AND awayScore IS NOT NULL ORDER BY date DESC, kickoff DESC, id ASC")
            defer { sqlite3_finalize(statement) }
            return try summaries(from: statement)
        }
    }

    private static let summaryColumns = "id, source, season, year, category, tournament, round, date, kickoff, venue, homeTeam, awayTeam, homeScore, awayScore, status, detailLevel"

    private static func summaries(from statement: OpaquePointer) throws -> [OfficialRecordSummary] {
        var result: [OfficialRecordSummary] = []
        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw OfficialArchiveError.unreadable }
            result.append(OfficialRecordSummary(
                id: string(statement, 0), source: string(statement, 1), season: string(statement, 2),
                year: Int(sqlite3_column_int64(statement, 3)), category: string(statement, 4),
                tournament: string(statement, 5), round: string(statement, 6), date: string(statement, 7),
                kickoff: string(statement, 8), venue: string(statement, 9), homeTeam: string(statement, 10),
                awayTeam: string(statement, 11), homeScore: integer(statement, 12), awayScore: integer(statement, 13),
                status: string(statement, 14), detailLevel: string(statement, 15)
            ))
        }
        return result
    }

    /// 大会名(段階ごとの正式名)・年度ごとの試合数と日付範囲。まとめ取り込みの大会一覧に使う。
    static func tournamentStages(at url: URL) throws -> [OfficialTournamentStage] {
        try withDatabase(at: url) { db in
            let statement = try prepare(db, """
                SELECT tournament, year, COUNT(*), MIN(date), MAX(date),
                       SUM(CASE WHEN status = 'finished' THEN 1 ELSE 0 END)
                FROM matches GROUP BY tournament, year
                """)
            defer { sqlite3_finalize(statement) }
            var result: [OfficialTournamentStage] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append(OfficialTournamentStage(
                    tournament: string(statement, 0), year: Int(sqlite3_column_int64(statement, 1)),
                    matchCount: Int(sqlite3_column_int64(statement, 2)), firstDate: string(statement, 3),
                    lastDate: string(statement, 4), finishedCount: Int(sqlite3_column_int64(statement, 5))))
            }
            return result
        }
    }

    /// 指定した大会名(段階)・年の試合を、日付の古い順にすべて読む。
    static func records(at url: URL, tournaments: [String], years: [Int]) throws -> [OfficialRecord] {
        guard !tournaments.isEmpty, !years.isEmpty else { return [] }
        return try withDatabase(at: url) { db in
            let marks = Array(repeating: "?", count: tournaments.count).joined(separator: ", ")
            let yearMarks = Array(repeating: "?", count: years.count).joined(separator: ", ")
            let statement = try prepare(db, "SELECT payload FROM matches WHERE year IN (\(yearMarks)) AND tournament IN (\(marks)) ORDER BY date ASC, kickoff ASC, id ASC",
                                        values: years.map(String.init) + tournaments)
            defer { sqlite3_finalize(statement) }
            var result: [OfficialRecord] = []
            while true {
                try Task.checkCancellation()
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW, let data = string(statement, 0).data(using: .utf8) else {
                    throw OfficialArchiveError.unreadable
                }
                result.append(try JSONDecoder().decode(OfficialRecord.self, from: data))
            }
            return result
        }
    }

    /// 指定した日付の、詳細のある試合をすべて読む。以前に取り込んだ試合を公式記録と照合し直すのに使う。
    static func records(at url: URL, dates: [String]) throws -> [OfficialRecord] {
        guard !dates.isEmpty else { return [] }
        return try withDatabase(at: url) { db in
            var result: [OfficialRecord] = []
            // SQLite の ? の数の上限を超えないよう、日付を分けて読む
            for start in stride(from: 0, to: dates.count, by: 400) {
                let chunk = Array(dates[start..<min(start + 400, dates.count)])
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                let statement = try prepare(db, "SELECT payload FROM matches WHERE detailLevel = 'full' AND date IN (\(marks))",
                                            values: chunk)
                defer { sqlite3_finalize(statement) }
                while true {
                    try Task.checkCancellation()
                    let status = sqlite3_step(statement)
                    if status == SQLITE_DONE { break }
                    guard status == SQLITE_ROW, let data = string(statement, 0).data(using: .utf8) else {
                        throw OfficialArchiveError.unreadable
                    }
                    result.append(try JSONDecoder().decode(OfficialRecord.self, from: data))
                }
            }
            return result
        }
    }

    /// Bounded reads for bulk import; never decode the entire archive at once.
    static func records(at url: URL, ids: [String]) throws -> [OfficialRecord] {
        guard !ids.isEmpty else { return [] }
        return try withDatabase(at: url) { db in
            var records: [String: OfficialRecord] = [:]
            for start in stride(from: 0, to: ids.count, by: 100) {
                let chunk = Array(ids[start..<min(start + 100, ids.count)])
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let statement = try prepare(db, "SELECT payload FROM matches WHERE id IN (\(marks))", values: chunk)
                defer { sqlite3_finalize(statement) }
                while true {
                    try Task.checkCancellation()
                    let status = sqlite3_step(statement)
                    if status == SQLITE_DONE { break }
                    guard status == SQLITE_ROW, let data = string(statement, 0).data(using: .utf8) else {
                        throw OfficialArchiveError.unreadable
                    }
                    let record = try JSONDecoder().decode(OfficialRecord.self, from: data)
                    records[record.id] = record
                }
            }
            return try ids.map { id in
                guard let record = records[id] else { throw OfficialArchiveError.missingMatch }
                return record
            }
        }
    }

    static func detail(at url: URL, id: String) throws -> OfficialRecord {
        try withDatabase(at: url) { db in
            let statement = try prepare(db, "SELECT payload FROM matches WHERE id = ?", values: [id])
            defer { sqlite3_finalize(statement) }
            let status = sqlite3_step(statement)
            guard status != SQLITE_DONE else { throw OfficialArchiveError.missingMatch }
            guard status == SQLITE_ROW, let data = string(statement, 0).data(using: .utf8) else {
                throw OfficialArchiveError.unreadable
            }
            return try JSONDecoder().decode(OfficialRecord.self, from: data)
        }
    }

    private static func withDatabase<T>(at url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        try Task.checkCancellation()
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard status == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw OfficialArchiveError.unreadable
        }
        defer { sqlite3_close(handle) }
        return try body(handle)
    }

    private static func prepare(_ db: OpaquePointer, _ sql: String, values: [String] = []) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw OfficialArchiveError.unreadable
        }
        for (index, value) in values.enumerated() {
            let result = value.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            guard result == SQLITE_OK else { sqlite3_finalize(statement); throw OfficialArchiveError.unreadable }
        }
        return statement
    }

    private static func distinct(_ db: OpaquePointer, table: String = "matches", column: String, descending: Bool = false) throws -> [String] {
        // Table and column names here are internal constants, never input from the UI.
        let statement = try prepare(db, "SELECT DISTINCT \(column) FROM \(table) WHERE \(column) IS NOT NULL AND \(column) != '' ORDER BY \(column) \(descending ? "DESC" : "ASC")")
        defer { sqlite3_finalize(statement) }
        var values: [String] = []
        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return values }
            guard status == SQLITE_ROW else { throw OfficialArchiveError.unreadable }
            values.append(string(statement, 0))
        }
    }

    private static func string(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: text)
    }

    private static func integer(_ statement: OpaquePointer, _ index: Int32) -> Int? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, index))
    }
}
