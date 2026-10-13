import Foundation

enum AnalysisPerformanceRegressionChecks {
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw NSError(domain: "AnalysisPerformanceChecks", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func run() throws {
        let matchID = UUID(), secondMatch = UUID()
        let first = StatEvent(matchID: matchID, category: "tackle", outcome: "success", seconds: 10)
        let second = StatEvent(matchID: secondMatch, category: "tackle", outcome: "fail", seconds: 20)
        let custom = StatEvent(matchID: matchID, category: "custom_metric", outcome: "count", seconds: 30)
        var details = RecordingEventDetails()
        details.title = "独自指標"; details.number = 0; details.unit = "m"
        details.zone = 2; details.attackUp = false
        custom.recordingDetails = details
        let duplicate = StatEvent(matchID: secondMatch, category: "custom_metric", outcome: "count", seconds: 40)
        details.title = "別の名前"; details.number = -4
        duplicate.recordingDetails = details
        let events = [first, second, custom, duplicate]

        let definitions = AnalysisComparison.definitions(events: events)
        let repeated = AnalysisComparison.definitions(events: events)
        try expect(definitions.map(\.id) == repeated.map(\.id) && definitions.count == 2,
            "Metric identities must survive unrelated SwiftUI updates")
        try expect(definitions.first { $0.category == "custom_metric" }?.title == "独自指標",
            "Deduplication must preserve the first recorded custom title")

        let snapshot = AnalysisMetricSnapshot(events: events)
        for category in ["tackle", "custom_metric", "missing"] {
            try expect(snapshot.summary(for: category) == RecordingMetricAggregation.summary(events: events, category: category),
                "Grouped summaries must preserve counts, rates, zero and signed values")
        }
        try expect(snapshot.recordedMatchCount(for: "custom_metric") == 2 && snapshot.recordedMatchCount(for: "missing") == 0,
            "Only recorded matches count toward the per-match denominator")

        var filter = RecordingAnalysisFilter()
        filter.category = "custom_metric"; filter.zoneRow = 2; filter.zoneColumn = 0
        filter.startTime = "0:30"; filter.endTime = "0:30"
        let prepared = filter.prepared()
        try expect(events.filter { prepared.matches($0, matchID: $0.matchID) }.map(\.id) == [custom.id],
            "Prepared filters preserve AND, attack direction and inclusive clock bounds")
        filter.endTime = "invalid"
        try expect(!filter.prepared().matches(custom, matchID: matchID), "Invalid time text never admits events")

        let ratio = AnalysisRatio(numerator: "custom_metric", measure: .numericTotal, denominator: "tackle", factor: 10)
        try expect(ratio.result(snapshot: snapshot).value == ratio.result(events: events).value,
            "Reports and ratio displays must reuse exactly the same measurements")
        details.number = 6; duplicate.recordingDetails = details
        let updated = AnalysisMetricSnapshot(events: events)
        try expect(updated.summary(for: "custom_metric").total == 6,
            "A new snapshot reflects edits without stale aggregate values")

        let fresh = RecordingMetricCatalog.all
        try expect(zip(RecordingMetricCatalog.templates, fresh).allSatisfy { $0.widget.id != $1.widget.id },
            "Read-only catalog identities must not be reused for inserted cards")
        print("PASS: 5 analysis performance regression checks")
    }
}
