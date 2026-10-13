import Foundation

enum AnalysisFilterRegressionChecks {
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "AnalysisFilterChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func run() throws {
        try combinesAllConditions()
        try isolatesMatchAndState()
        try normalizesAttackDirection()
        try handlesMissingFields()
        try appliesClockBoundaries()
        try preservesLegacyTimeMeaning()
        try validatesTimeInput()
        try aggregatesOnlyMatchingRecords()
        print("PASS: 8 analysis filter regression checks")
    }

    private static func combinesAllConditions() throws {
        let match = UUID(), team = UUID(), player = UUID()
        let event = StatEvent(matchID: match, teamID: team, playerID: player, category: "tackle", outcome: "success", seconds: 90, half: 1, origin: "scrum")
        var details = RecordingEventDetails(); details.zone = 6; event.recordingDetails = details
        let filter = RecordingAnalysisFilter(teamID: team, half: 1, category: "tackle", player: player.uuidString,
            outcome: "success", origin: "scrum", zoneRow: 2, zoneColumn: 0, startTime: "1", endTime: "2")
        try expect(filter.matches(event, matchID: match), "All conditions should match the same event")
        var variants: [RecordingAnalysisFilter] = []
        var changed = filter; changed.teamID = UUID(); variants.append(changed)
        changed = filter; changed.half = 0; variants.append(changed)
        changed = filter; changed.category = "scrum"; variants.append(changed)
        changed = filter; changed.player = UUID().uuidString; variants.append(changed)
        changed = filter; changed.outcome = "fail"; variants.append(changed)
        changed = filter; changed.origin = "lineout"; variants.append(changed)
        changed = filter; changed.zoneRow = 0; variants.append(changed)
        changed = filter; changed.zoneColumn = 1; variants.append(changed)
        changed = filter; changed.startTime = "1:31"; variants.append(changed)
        try expect(variants.allSatisfy { !$0.matches(event, matchID: match) }, "Changing any one condition must exclude the event")
        try expect(filter.activeCount == 9, "The summary must count every active condition")
    }

    private static func isolatesMatchAndState() throws {
        let match = UUID()
        let event = StatEvent(matchID: match, category: "tackle", outcome: "success", seconds: 0)
        let filter = RecordingAnalysisFilter()
        try expect(filter.matches(event, matchID: match), "No conditions should include regular events")
        try expect(!filter.matches(event, matchID: UUID()), "Other matches must never leak into results")
        event.category = "match_state"
        try expect(!filter.matches(event, matchID: match), "Half-end markers are not plays")
    }

    private static func normalizesAttackDirection() throws {
        let event = StatEvent(matchID: UUID(), category: "tackle", outcome: "success", seconds: 0)
        var details = RecordingEventDetails(); details.zone = 2; details.attackUp = false
        event.recordingDetails = details
        try expect(RecordingAnalysisFilter(zoneRow: 2, zoneColumn: 0).matches(event, matchID: event.matchID), "Downward attack must rotate both row and lane")
        try expect(!RecordingAnalysisFilter(zoneRow: 0, zoneColumn: 2).matches(event, matchID: event.matchID), "Screen coordinates are not attack-relative coordinates")
    }

    private static func handlesMissingFields() throws {
        let event = StatEvent(matchID: UUID(), category: "tackle", outcome: "success", seconds: 0)
        try expect(RecordingAnalysisFilter(player: "unset", origin: "unset", zoneRow: 3).matches(event, matchID: event.matchID), "Explicit missing-field filters must work together")
        try expect(!RecordingAnalysisFilter(zoneRow: 2).matches(event, matchID: event.matchID), "Missing zone must not be inferred")
        event.origin = "kickoff"
        try expect(RecordingAnalysisFilter(origin: "restart").matches(event, matchID: event.matchID), "Old origin aliases must match modern filters")
        event.origin = "penalty"
        try expect(RecordingAnalysisFilter(origin: "tap_kick").matches(event, matchID: event.matchID), "Legacy tap-kick origin must remain searchable")
    }

    private static func appliesClockBoundaries() throws {
        let event = StatEvent(matchID: UUID(), category: "possession", outcome: "own", seconds: 60, startSeconds: 90, half: 1,
                              startSecondsExact: 90.25, durationSecondsExact: 60)
        var details = RecordingEventDetails(); details.timeBasis = .halfClock; event.recordingDetails = details
        try expect(RecordingAnalysisFilter(half: 1, startTime: "1:30", endTime: "1:31").matches(event, matchID: event.matchID), "Time filters use interval start, not duration")
        try expect(!RecordingAnalysisFilter(endTime: "1:30").matches(event, matchID: event.matchID), "Subsecond positions must not be rounded into the interval")
        event.startSecondsExact = 90
        try expect(RecordingAnalysisFilter(startTime: "1:30", endTime: "1:30").matches(event, matchID: event.matchID), "Both time endpoints are inclusive")
        event.startSecondsExact = .nan
        try expect(!RecordingAnalysisFilter(startTime: "1").matches(event, matchID: event.matchID), "An invalid exact clock must not pass a time condition")
    }

    private static func preservesLegacyTimeMeaning() throws {
        let event = StatEvent(matchID: UUID(), category: "try", outcome: "success", seconds: 30, half: 1,
                              startSecondsExact: 700, durationSecondsExact: 26)
        try expect(RecordingAnalysisFilter(startTime: "0:30", endTime: "0:30").matches(event, matchID: event.matchID), "Unmarked exact video coordinates must not become match-clock filters")
        var details = RecordingEventDetails(); details.timeBasis = .halfClock; event.recordingDetails = details
        try expect(!RecordingAnalysisFilter(endTime: "1").matches(event, matchID: event.matchID), "Marked half-clock exact positions take precedence")
    }

    private static func validatesTimeInput() throws {
        try expect(RecordingAnalysisFilter.seconds(from: " 10:05 ") == 605, "Whitespace and minute-second input must parse")
        try expect(RecordingAnalysisFilter.seconds(from: "10") == 600, "Minutes-only input must mean minutes")
        for text in ["1:60", "-1", "1.5", "a", "1:", ":30", "1:2:3", "999999999999999999999"] {
            try expect(RecordingAnalysisFilter(startTime: text).validationMessage != nil, "Malformed time must not silently disable filtering: " + text)
        }
        try expect(RecordingAnalysisFilter(startTime: "2", endTime: "1").validationMessage != nil, "Reversed time range must be rejected")
        try expect(RecordingAnalysisFilter(startTime: " ").activeCount == 0, "Blank time must not count as a condition")
    }

    private static func aggregatesOnlyMatchingRecords() throws {
        let match = UUID(), team = UUID(), otherTeam = UUID()
        let events = [
            StatEvent(matchID: match, teamID: team, category: "tackle", outcome: "success", seconds: 60, half: 1),
            StatEvent(matchID: match, teamID: team, category: "tackle", outcome: "fail", seconds: 70, half: 1),
            StatEvent(matchID: match, teamID: otherTeam, category: "tackle", outcome: "success", seconds: 65, half: 1),
            StatEvent(matchID: match, teamID: team, category: "tackle", outcome: "success", seconds: 65, half: 0)
        ]
        let filter = RecordingAnalysisFilter(teamID: team, half: 1, category: "tackle", startTime: "1", endTime: "2")
        let summary = RecordingMetricAggregation.summary(events: events.filter { filter.matches($0, matchID: match) }, category: "tackle")
        try expect(summary.count == 2 && summary.successRate == 0.5, "Success-rate denominator must use the same combined conditions as the count")
    }
}
