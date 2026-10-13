import Foundation
import CryptoKit
import SQLite3

@main
nonisolated enum OfficialRecordsRegressionChecks {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw Failure(description: "Usage: OfficialRecordsRegressionChecks <actual-archive.sqlite>")
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        // Match the production reader's off-main execution and Sendable boundary.
        let task = Task.detached(priority: .userInitiated) { try run(at: url) }
        try await task.value
    }

    private static func run(at url: URL) throws {
        let before = try fingerprint(url)
        let (manifest, options) = try OfficialRecordsStore.metadata(at: url)
        try expect(manifest.schemaVersion == 1, "Manifest version is supported")
        try expect(manifest.matchCount > 0, "Checks require the actual, nonempty official archive")
        let all = try pages(at: url, query: OfficialArchiveQuery())
        try expect(all.count == manifest.matchCount, "Manifest count equals the paginated archive count")
        try expect(Set(all.map(\.id)).count == all.count, "No match repeats across pages")
        let expectedOrder = all.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            if $0.kickoff != $1.kickoff { return $0.kickoff > $1.kickoff }
            return $0.id < $1.id
        }
        try expect(all.map(\.id) == expectedOrder.map(\.id), "Date, kickoff and ID give stable pagination")
        let beyond = try OfficialRecordsStore.search(at: url, query: OfficialArchiveQuery(), offset: all.count)
        try expect(beyond.matches.isEmpty && beyond.total == all.count, "The page after the final result is empty")

        var details: [OfficialRecord] = []
        for row in all {
            let detail = try OfficialRecordsStore.detail(at: url, id: row.id)
            try expect(detail.id == row.id && detail.source == row.source, "Details retain their source ID: \(row.id)")
            try expect(detail.homeTeam == row.homeTeam && detail.awayTeam == row.awayTeam, "Summary and detail teams agree: \(row.id)")
            try expect(detail.homeScore == row.homeScore && detail.awayScore == row.awayScore, "Optional scores survive summary and JSON decoding: \(row.id)")
            try expect(detail.tournament == row.tournament && detail.category == row.category && detail.date == row.date,
                       "Summary and detail scope agree: \(row.id)")
            try expect(detail.year == row.year && detail.season == row.season && detail.detailLevel == row.detailLevel,
                       "Summary and detail season/coverage agree: \(row.id)")
            details.append(detail)
        }
        try expect(details.filter { $0.detailLevel == "full" }.count == manifest.fullDetailCount,
                   "Manifest full-detail count equals decoded full details")
        try verifyRawOptionalScores(at: url, details: details)
        try verifyRawCategoryMemberships(at: url, details: details)
        let membershipsByID = Dictionary(uniqueKeysWithValues: details.map { ($0.id, Set($0.categoryMemberships)) })

        try expect(Set(options.sources) == Set(all.map(\.source)), "Source filter options reflect the archive")
        try expect(Set(options.categories) == Set(details.flatMap(\.categoryMemberships)), "Category options include every official membership")
        try expect(Set(options.years) == Set(all.map { String($0.year) }), "Year filter options reflect the archive")
        try expect(Set(options.seasons) == Set(all.map(\.season).filter { !$0.isEmpty }), "Season filter options reflect the archive")
        try expect(Set(options.tournaments) == Set(all.map(\.tournament).filter { !$0.isEmpty }), "Tournament filter options reflect the archive")

        for source in options.sources {
            var query = OfficialArchiveQuery(); query.source = source
            try checkFilter(at: url, query: query, expected: all.filter { $0.source == source }, label: "source")
        }
        for status in ["finished", "scheduled", "cancelled", "unknown"] {
            var query = OfficialArchiveQuery(); query.status = status
            try checkFilter(at: url, query: query, expected: all.filter { $0.status == status }, label: "status")
        }
        for category in options.categories {
            var query = OfficialArchiveQuery(); query.category = category
            try checkFilter(at: url, query: query, expected: all.filter { membershipsByID[$0.id]?.contains(category) == true }, label: "category membership")
        }
        for year in options.years {
            var query = OfficialArchiveQuery(); query.year = year
            try checkFilter(at: url, query: query, expected: all.filter { String($0.year) == year }, label: "year")
        }
        for season in options.seasons {
            var query = OfficialArchiveQuery(); query.season = season
            try checkFilter(at: url, query: query, expected: all.filter { $0.season == season }, label: "season")
        }
        for tournament in [options.tournaments.first, options.tournaments.last].compactMap({ $0 }) {
            var query = OfficialArchiveQuery(); query.tournament = tournament
            try checkFilter(at: url, query: query, expected: all.filter { $0.tournament == tournament }, label: "tournament")
        }
        let sample = all[0]
        var combined = OfficialArchiveQuery()
        combined.source = sample.source; combined.category = sample.category
        combined.year = String(sample.year); combined.season = sample.season; combined.tournament = sample.tournament
        try checkFilter(at: url, query: combined, expected: all.filter {
            $0.source == sample.source && membershipsByID[$0.id]?.contains(sample.category) == true && $0.year == sample.year &&
                $0.season == sample.season && $0.tournament == sample.tournament
        }, label: "combined filters")

        for term in [sample.homeTeam, sample.tournament, "%", "_", "\\", "%' OR 1=1 --"].filter({ !$0.isEmpty }) {
            var query = OfficialArchiveQuery(); query.text = term
            let words = term.split(whereSeparator: { $0.isWhitespace }).map { String($0).lowercased() }
            let expected = all.filter { row in
                let fields = [row.homeTeam, row.awayTeam, row.tournament].map { $0.lowercased() }
                return words.allSatisfy { word in fields.contains { $0.contains(word) } }
            }
            try checkFilter(at: url, query: query, expected: expected, label: "literal text: \(term)")
        }
        do {
            _ = try OfficialRecordsStore.detail(at: url, id: "regression:missing")
            throw Failure(description: "An unknown match must fail rather than return another record")
        } catch OfficialArchiveError.missingMatch { }

        let nonexistent = FileManager.default.temporaryDirectory.appendingPathComponent("official-records-missing-\(UUID().uuidString).sqlite")
        do {
            _ = try OfficialRecordsStore.search(at: nonexistent, query: OfficialArchiveQuery())
            throw Failure(description: "Read-only opening must reject a missing archive")
        } catch OfficialArchiveError.unreadable { }
        try expect(!FileManager.default.fileExists(atPath: nonexistent.path), "Reading a missing archive must not create a database")
        let after = try fingerprint(url)
        try expect(before == after, "Queries must leave database bytes, modification time and sidecar presence unchanged")
        let nulls = details.filter { $0.homeScore == nil || $0.awayScore == nil }.count
        let zeros = details.filter { $0.homeScore == 0 || $0.awayScore == 0 }.count
        print("PASS: official archive integration — \(all.count) summaries + details, manifest, pagination, filters, literal SQL text and read-only file checks")
        print("Actual score samples verified: \(nulls) matches with missing scores; \(zeros) matches with a recorded zero (zero counts mean that case is absent from this source snapshot)")
    }

    private static func pages(at url: URL, query: OfficialArchiveQuery) throws -> [OfficialRecordSummary] {
        var result: [OfficialRecordSummary] = []
        var expectedTotal: Int?
        repeat {
            let page = try OfficialRecordsStore.search(at: url, query: query, offset: result.count)
            if let expectedTotal { try expect(page.total == expectedTotal, "Page totals remain stable") }
            else { expectedTotal = page.total }
            try expect(page.matches.count <= OfficialRecordsStore.pageSize, "A page never decodes more summaries than requested")
            if page.matches.isEmpty { break }
            result.append(contentsOf: page.matches)
        } while result.count < (expectedTotal ?? 0)
        try expect(result.count == expectedTotal, "Paging retrieves every reported result")
        try expect(Set(result.map(\.id)).count == result.count, "Filtered pages have unique IDs")
        return result
    }

    private static func checkFilter(at url: URL, query: OfficialArchiveQuery, expected: [OfficialRecordSummary], label: String) throws {
        let actual = try pages(at: url, query: query)
        try expect(actual.map(\.id) == expected.map(\.id), "Filter returns exactly the expected records: \(label)")
    }

    private static func verifyRawOptionalScores(at url: URL, details: [OfficialRecord]) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            throw Failure(description: "Could not independently inspect raw archive scores")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let sql = "SELECT id, homeScore, awayScore, homeFirstHalfScore, awayFirstHalfScore, homeSecondHalfScore, awaySecondHalfScore FROM matches"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure(description: "Could not inspect raw archive score columns")
        }
        defer { sqlite3_finalize(statement) }
        let byID = Dictionary(uniqueKeysWithValues: details.map { ($0.id, $0) })
        var count = 0
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            try expect(step == SQLITE_ROW, "Raw score query must finish successfully")
            guard let rawID = sqlite3_column_text(statement, 0), let detail = byID[String(cString: rawID)] else {
                throw Failure(description: "Each raw SQLite row must have a decoded detail")
            }
            let decoded = [detail.homeScore, detail.awayScore, detail.homeFirstHalfScore, detail.awayFirstHalfScore,
                           detail.homeSecondHalfScore, detail.awaySecondHalfScore]
            for (index, value) in decoded.enumerated() {
                let column = Int32(index + 1)
                if sqlite3_column_type(statement, column) == SQLITE_NULL {
                    try expect(value == nil, "SQL NULL stays missing in JSON: \(detail.id)")
                } else {
                    try expect(sqlite3_column_type(statement, column) == SQLITE_INTEGER, "Scores are typed integers: \(detail.id)")
                    try expect(value == Int(sqlite3_column_int64(statement, column)), "Real score including zero is preserved: \(detail.id)")
                }
            }
            count += 1
        }
        try expect(count == details.count, "Raw SQL and decoder cover the same complete archive")
    }

    private static func verifyRawCategoryMemberships(at url: URL, details: [OfficialRecord]) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            throw Failure(description: "Could not inspect category memberships")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT matchID, category FROM match_categories", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw Failure(description: "Category membership table is required") }
        defer { sqlite3_finalize(statement) }
        var actual: [String: Set<String>] = [:]
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            try expect(step == SQLITE_ROW, "Category query must finish successfully")
            guard let rawID = sqlite3_column_text(statement, 0), let rawCategory = sqlite3_column_text(statement, 1) else {
                throw Failure(description: "A membership must identify its match and category")
            }
            let id = String(cString: rawID), category = String(cString: rawCategory)
            try expect(actual[id]?.contains(category) != true, "A category membership cannot be duplicated")
            actual[id, default: []].insert(category)
        }
        for detail in details {
            try expect(!detail.categoryMemberships.isEmpty && detail.categoryMemberships.contains(detail.category),
                       "Each match includes its primary category: \(detail.id)")
            try expect(Set(detail.categoryMemberships).count == detail.categoryMemberships.count,
                       "Payload memberships have no duplicates: \(detail.id)")
            try expect(actual[detail.id] == Set(detail.categoryMemberships),
                       "All JSON memberships exist in the relation: \(detail.id)")
        }
        try expect(actual.count == details.count, "Every category relation belongs to one archive match")
    }

    private static func fingerprint(_ url: URL) throws -> String {
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let sidecars = ["-wal", "-shm", "-journal"].map { suffix in
            String(FileManager.default.fileExists(atPath: url.path + suffix))
        }.joined(separator: ",")
        return "\(digest)|\(modified)|\(sidecars)"
    }
}
