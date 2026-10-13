import Foundation

struct AnalysisReport: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "マイ分析"
    var scope = AnalysisScope()
    var categories: [String] = []
    var ratio: AnalysisRatio?

    static let storageKey = "analysis.savedReports.v1"

    func validated() throws -> Self {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80,
              categories.count <= 100, Set(categories).count == categories.count,
              categories.allSatisfy({ !$0.isEmpty }),
              [0, 5, 10].contains(scope.recentLimit), scope.filter.validationMessage == nil else {
            throw RecordingWidgetError.invalid("分析名・指標・条件を確認してください。")
        }
        if let ratio {
            guard !ratio.numerator.isEmpty, !ratio.denominator.isEmpty, [1, 10, 100].contains(ratio.factor) else {
                throw RecordingWidgetError.invalid("比率の分子・分母を選んでください。")
            }
        }
        return self
    }

    static func merged(current: Data?, incoming: Data?) throws -> Data? {
        guard let incoming else { return current }
        let decoder = JSONDecoder()
        var reports = try current.flatMap { $0.isEmpty ? nil : try decoder.decode([Self].self, from: $0) } ?? []
        let imported: [Self]
        if incoming.isEmpty { imported = [] }
        else { imported = try decoder.decode([Self].self, from: incoming) }
        for report in imported {
            let valid = try report.validated()
            reports.removeAll { $0.id == valid.id }
            reports.append(valid)
        }
        return try JSONEncoder().encode(reports)
    }
}

struct AnalysisRatio: Codable, Equatable {
    enum Numerator: String, Codable, CaseIterable {
        case records, successes, numericTotal
        var title: String {
            switch self { case .records: "記録数"; case .successes: "成功数"; case .numericTotal: "数値の合計" }
        }
    }
    var numerator = ""
    var measure = Numerator.records
    var denominator = ""
    var factor = 1

    func result(events: [StatEvent]) -> AnalysisRatioResult {
        let top = RecordingMetricAggregation.summary(events: events, category: numerator)
        let bottom = events.lazy.filter { $0.category == denominator }.count
        return result(top: top, bottom: bottom)
    }

    func result(snapshot: AnalysisMetricSnapshot) -> AnalysisRatioResult {
        result(top: snapshot.summary(for: numerator), bottom: snapshot.summary(for: denominator).count)
    }

    private func result(top: RecordingMetricSummary, bottom: Int) -> AnalysisRatioResult {
        let value: Double?
        switch measure {
        case .records: value = top.count > 0 ? Double(top.count) : nil
        case .successes: value = top.attempts > 0 ? Double(top.successes) : nil
        case .numericTotal: value = top.hasMixedUnits ? nil : top.total
        }
        return AnalysisRatioResult(numerator: value, denominator: bottom,
            value: bottom > 0 ? value.map { $0 / Double(bottom) * Double(factor) } : nil,
            unit: measure == .numericTotal ? top.unit : nil)
    }
}

struct AnalysisRatioResult {
    let numerator: Double?
    let denominator: Int
    let value: Double?
    let unit: String?
}

enum AnalysisReportExport {
    static func csv(report: AnalysisReport, events: [StatEvent], matches: [Match], titles: [String: String], conditions: String) -> String {
        csv(report: report, snapshot: AnalysisMetricSnapshot(events: events), matchCount: matches.count,
            titles: titles, conditions: conditions)
    }

    static func csv(report: AnalysisReport, snapshot: AnalysisMetricSnapshot, matchCount: Int, titles: [String: String], conditions: String) -> String {
        var lines = [["分析名", report.name], ["条件", conditions], ["対象試合数", String(matchCount)],
                     ["指標", "記録数", "成功", "成否入力", "成功率(%)", "数値入力", "合計", "平均", "単位", "記録のある試合数", "記録のある試合当たり"]]
        for category in report.categories {
            let value = snapshot.summary(for: category)
            let recordedMatches = snapshot.recordedMatchCount(for: category)
            lines.append([titles[category] ?? category, value.count > 0 ? String(value.count) : "記録なし",
                          String(value.successes), String(value.attempts), value.successRate.map { String($0 * 100) } ?? "",
                          String(value.numericCount), value.total.map(String.init(describing:)) ?? "",
                          value.average.map(String.init(describing:)) ?? "", value.hasMixedUnits ? "混在" : value.unit ?? "",
                          String(recordedMatches), recordedMatches > 0 ? String(Double(value.count) / Double(recordedMatches)) : ""])
        }
        if let ratio = report.ratio {
            let result = ratio.result(snapshot: snapshot)
            lines.append(["独自比率", titles[ratio.numerator] ?? ratio.numerator, ratio.measure.title,
                          "÷", titles[ratio.denominator] ?? ratio.denominator, "記録数", "×", String(ratio.factor),
                          result.value.map(String.init(describing:)) ?? "算出不可", result.unit ?? "",
                          "分母", String(result.denominator)])
        }
        return lines.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    nonisolated private static func escape(_ value: String) -> String {
        // Keep user-entered labels as text when opened in spreadsheets.
        let safe = ["=", "+", "-", "@"].contains(value.first.map(String.init) ?? "") ? "'" + value : value
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
