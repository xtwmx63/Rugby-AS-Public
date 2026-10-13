import Foundation

/// All selected conditions apply to the same recorded event (AND).
nonisolated struct RecordingAnalysisFilter: Codable, Equatable, Sendable {
    var teamID: UUID?
    var half: Int?
    var category = ""
    // Empty = all players; "unset" = no player assigned.
    var player = ""
    var outcome = ""
    var origin = ""
    // Attack-relative rows: 0 enemy, 1 middle, 2 own, 3 unrecorded.
    var zoneRow = -1
    var zoneColumn = -1
    var startTime = ""
    var endTime = ""

    static func seconds(from text: String) -> Int? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let minutes = Int(parts[0]), minutes <= 9999 else { return nil }
        let seconds = parts.count == 2 ? Int(parts[1]) : 0
        guard let seconds, (0..<60).contains(seconds) else { return nil }
        return minutes * 60 + seconds
    }

    var validationMessage: String? {
        let start = startTime.trimmingCharacters(in: .whitespacesAndNewlines)
        let end = endTime.trimmingCharacters(in: .whitespacesAndNewlines)
        if (!start.isEmpty && Self.seconds(from: start) == nil) ||
            (!end.isEmpty && Self.seconds(from: end) == nil) {
            return "時間は「10:30」のように分:秒で入力してください。分だけでも指定できます。"
        }
        if let lower = Self.seconds(from: start), let upper = Self.seconds(from: end), lower > upper {
            return "終了時刻は開始時刻以降にしてください。"
        }
        return nil
    }

    var activeCount: Int {
        [teamID != nil, half != nil, !category.isEmpty, !player.isEmpty, !outcome.isEmpty,
         !origin.isEmpty, zoneRow != -1, zoneColumn != -1,
         !startTime.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
         !endTime.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty].filter { $0 }.count
    }

    func matches<E: AnalysisEventRecord>(_ event: E, matchID: UUID) -> Bool {
        prepared().matches(event, matchID: matchID)
    }

    /// Parse and validate text once per collection, not once for every play.
    func prepared() -> Prepared {
        Prepared(filter: self, isValid: validationMessage == nil,
                 lower: Self.seconds(from: startTime), upper: Self.seconds(from: endTime))
    }

    struct Prepared {
        fileprivate let filter: RecordingAnalysisFilter
        fileprivate let isValid: Bool
        fileprivate let lower: Int?
        fileprivate let upper: Int?

        func matches<E: AnalysisEventRecord>(_ event: E, matchID: UUID) -> Bool {
            filter.matches(event, matchID: matchID, isValid: isValid, lower: lower, upper: upper)
        }
    }

    private func matches<E: AnalysisEventRecord>(_ event: E, matchID: UUID, isValid: Bool, lower: Int?, upper: Int?) -> Bool {
        guard isValid, event.matchID == matchID, event.category != "match_state",
              teamID == nil || event.teamID == teamID,
              half == nil || event.half == half,
              category.isEmpty || event.category == category,
              outcome.isEmpty || event.outcome == outcome else { return false }
        if player == "unset" {
            guard event.playerID == nil else { return false }
        } else if !player.isEmpty && event.playerID?.uuidString != player { return false }
        if origin == "unset" {
            guard event.origin == nil || event.origin == "" else { return false }
        } else if !origin.isEmpty && event.recordingOrigin?.rawValue != origin { return false }

        // An unrestricted filter does not need to decode details at all.
        guard zoneRow >= 0 || zoneColumn >= 0 || lower != nil || upper != nil else { return true }
        let details = event.recordingDetails
        if zoneRow >= 0 || zoneColumn >= 0 {
            let normalizedZone = details.zone.flatMap { (0..<9).contains($0) ? (details.attackUp ? $0 : 8 - $0) : nil }
            if zoneRow == 3 {
                guard normalizedZone == nil else { return false }
            } else if zoneRow >= 0 {
                guard let normalizedZone, normalizedZone / 3 == zoneRow else { return false }
            }
            if zoneColumn >= 0 {
                guard let normalizedZone, normalizedZone % 3 == zoneColumn else { return false }
            }
        }

        // Legacy exact fields are video coordinates. Only marked new values
        // represent the half's clock; old records retain their integer clock.
        let seconds = details.timeBasis == .halfClock
            ? (event.startSecondsExact ?? Double(event.category == "possession" ? (event.startSeconds ?? 0) : event.seconds))
            : Double(event.category == "possession" ? (event.startSeconds ?? 0) : event.seconds)
        if lower != nil || upper != nil {
            guard seconds.isFinite else { return false }
        }
        if let lower, seconds < Double(lower) { return false }
        if let upper, seconds > Double(upper) { return false }
        return true
    }
}
