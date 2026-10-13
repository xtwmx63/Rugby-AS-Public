import Foundation

@MainActor
enum AnalysisReportRegressionChecks {
    private enum Failure: Error { case failed(String) }
    private static func expect(_ value: @autoclosure () -> Bool, _ label: String) throws {
        if !value() { throw Failure.failed(label) }
    }
    static func run() throws {
        let id = UUID()
        let tackle = StatEvent(matchID: id, category: "tackle", outcome: "success", seconds: 10)
        let miss = StatEvent(matchID: id, category: "tackle", outcome: "fail", seconds: 20)
        let carry = StatEvent(matchID: id, category: "carry", outcome: "success", seconds: 30)
        var details = RecordingEventDetails(); details.number = 12; details.unit = "m"; carry.recordingDetails = details
        let events = [tackle, miss, carry]
        var ratio = AnalysisRatio(numerator: "tackle", measure: .successes, denominator: "tackle", factor: 100)
        try expect(ratio.result(events: events).value == 50, "Explicit success denominator")
        ratio.numerator = "carry"; ratio.measure = .numericTotal; ratio.factor = 1
        try expect(ratio.result(events: events).value == 6 && ratio.result(events: events).unit == "m", "Numeric total per recorded denominator")
        ratio.denominator = "missing"
        try expect(ratio.result(events: events).value == nil, "Missing denominator is unavailable")
        ratio.denominator = "tackle"; ratio.numerator = "missing"; ratio.measure = .records
        try expect(ratio.result(events: events).value == nil, "Missing numerator is not reported as zero")
        var report = AnalysisReport(name: "条件,保存", categories: ["carry", "tackle"])
        report.scope.filter.half = 1
        let encoded = try JSONEncoder().encode([report])
        var changed = report; changed.categories.reverse()
        let merged = try AnalysisReport.merged(current: encoded, incoming: JSONEncoder().encode([changed]))!
        let restored = try JSONDecoder().decode([AnalysisReport].self, from: merged)
        try expect(restored == [changed] && restored[0].scope.filter.half == 1, "Named report retains conditions and order without duplicates")
        let unchanged = try AnalysisReport.merged(current: merged, incoming: Data())
        let unchangedReports = try JSONDecoder().decode([AnalysisReport].self, from: unchanged!)
        try expect(unchangedReports == restored, "An empty legacy settings value preserves saved reports")
        report.name = "=formula"
        let csv = AnalysisReportExport.csv(report: report, events: events, matches: [], titles: [:], conditions: "後半")
        try expect(csv.contains("'\(report.name)") && csv.contains("\"後半\""), "Export includes conditions and escapes formula labels")
        print("PASS: 6 analysis report regression checks")
    }
}
