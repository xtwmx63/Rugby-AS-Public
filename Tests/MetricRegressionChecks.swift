import Foundation

/// 既存の実行入口から run() を呼べる独立した回帰チェック。
enum MetricRegressionChecks {
    private enum Failure: Error { case failed(String) }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.failed(message) }
    }

    static func run() throws {
        try validatesCatalog()
        try separatesTeamsAndCategories()
        try excludesUnratedEventsFromSuccessRate()
        try excludesMissingNumbersFromAverage()
        try preservesZeroAndNegativeMeasurements()
        try preservesMissingData()
        try refusesToCombineDifferentUnits()
        print("PASS: 7 metric regression checks")
    }

    private static func validatesCatalog() throws {
        let presets = RecordingMetricCatalog.all
        try expect(presets.count == 49, "Catalog has 49 usable metric presets")
        try expect(Set(presets.map(\.id)).count == presets.count, "Preset IDs are unique")
        try expect(Set(presets.map(\.group)) == Set(RecordingMetricCatalog.groups), "All eight groups contain metrics")
        try expect(Set(presets.map { $0.widget.id }).count == presets.count, "Widgets have independent identities")
        for preset in presets {
            _ = try RecordingLayout(widgets: [preset.widget]).validated()
            if preset.widget.kind == .number {
                try expect(!preset.widget.unit.isEmpty, "Numeric presets explain their units")
            }
            if preset.widget.kind == .successRate {
                try expect(presets.contains { $0.widget.kind == .result && $0.widget.category == preset.widget.category }, "Rates have a matching result input")
            }
        }
        let second = RecordingMetricCatalog.all
        try expect(presets.map(\.id) == second.map(\.id), "Preset identities are stable")
        try expect(zip(presets, second).allSatisfy { $0.widget.id != $1.widget.id }, "Adding the same preset can create a new widget")
    }

    private static func event(category: String = "tackle", outcome: String = "count", team: UUID? = nil, number: Double? = nil, unit: String? = nil) -> StatEvent {
        let event = StatEvent(matchID: UUID(), teamID: team, category: category, outcome: outcome, seconds: 0)
        if let number {
            var details = RecordingEventDetails()
            details.number = number
            details.unit = unit
            event.recordingDetails = details
        }
        return event
    }

    private static func separatesTeamsAndCategories() throws {
        let home = UUID(), away = UUID()
        let events = [event(outcome: "success", team: home), event(outcome: "fail", team: away), event(category: "scrum", outcome: "success", team: home), event()]
        let own = RecordingMetricAggregation.summary(events: events, category: "tackle", teamID: home)
        try expect(own.count == 1 && own.successes == 1 && own.attempts == 1, "Only selected team's category is included")
        let all = RecordingMetricAggregation.summary(events: events, category: "tackle")
        try expect(all.count == 3 && all.attempts == 2, "Nil scope includes both teams and unassigned events")
    }

    private static func excludesUnratedEventsFromSuccessRate() throws {
        let events = [event(outcome: "success"), event(outcome: "fail"), event(outcome: "count"), event(outcome: "unknown")]
        let result = RecordingMetricAggregation.summary(events: events, category: "tackle")
        try expect(result.count == 4 && result.attempts == 2 && result.successRate == 0.5, "Only explicit success or fail contributes to a rate")
    }

    private static func excludesMissingNumbersFromAverage() throws {
        let events = [event(category: "ruck_speed", number: 2), event(category: "ruck_speed"), event(category: "ruck_speed", number: 4)]
        let result = RecordingMetricAggregation.summary(events: events, category: "ruck_speed")
        try expect(result.count == 3 && result.numericCount == 2 && result.total == 6 && result.average == 3, "Unentered numbers do not count as zero")
    }

    private static func preservesZeroAndNegativeMeasurements() throws {
        let events = [event(category: "carry_metres", number: 0), event(category: "carry_metres", number: -4), event(category: "carry_metres", number: 10)]
        let result = RecordingMetricAggregation.summary(events: events, category: "carry_metres")
        try expect(result.numericCount == 3 && result.total == 6 && result.average == 2, "Zero and retreat measurements remain real values")
        let zero = RecordingMetricAggregation.summary(events: [event(category: "carry_metres", number: 0)], category: "carry_metres")
        try expect(zero.total == 0 && zero.average == 0, "Recorded zero differs from missing data")
    }

    private static func preservesMissingData() throws {
        let empty = RecordingMetricAggregation.summary(events: [StatEvent](), category: "tackle")
        try expect(empty.count == 0 && empty.total == nil && empty.average == nil && empty.successRate == nil, "Empty data never fabricates numeric or rate values")
        let unmeasured = RecordingMetricAggregation.summary(events: [event()], category: "tackle")
        try expect(unmeasured.numericCount == 0 && unmeasured.average == nil && unmeasured.successRate == nil, "Counts alone do not imply measurements or attempts")
    }

    private static func refusesToCombineDifferentUnits() throws {
        let metres = event(category: "kick_distance", number: 30, unit: "m")
        let yards = event(category: "kick_distance", number: 40, unit: "yd")
        let mixed = RecordingMetricAggregation.summary(events: [metres, yards], category: "kick_distance")
        try expect(mixed.numericCount == 2 && mixed.hasMixedUnits && mixed.total == nil && mixed.average == nil, "Different units are never silently summed")
        let consistent = RecordingMetricAggregation.summary(events: [metres], category: "kick_distance")
        try expect(consistent.unit == "m" && !consistent.hasMixedUnits && consistent.total == 30, "The recorded unit is preserved for display")
    }
}
