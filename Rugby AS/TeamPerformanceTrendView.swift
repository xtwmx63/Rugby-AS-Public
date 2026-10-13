import Charts
import SwiftUI

/// 試合ごとの実測値。平滑化や推測値は使わず、得点と失点の線種を変える。
struct TeamPerformanceTrendView: View {
    let results: [TeamPerformance.Result]
    let accent: Color
    let opponentName: (UUID) -> String
    let openMatch: (Match) -> Void
    @AppStorage("teamPerformance.trendMetric") private var metric = "score"
    @AppStorage("teamPerformance.trendCount") private var count = 10
    // 得点・失点の線はどちらか片方だけ表示にできる(凡例をタップ。両方消すことはできない)
    @AppStorage("teamPerformance.trendShowsFor") private var showsFor = true
    @AppStorage("teamPerformance.trendShowsAgainst") private var showsAgainst = true
    @State private var selectedIndex: Int?

    private var rows: [TeamPerformance.Result] {
        Array((count == 0 ? results : Array(results.prefix(count))).reversed())
    }
    private var selected: TeamPerformance.Result? {
        guard let selectedIndex, rows.indices.contains(selectedIndex) else { return nil }
        return rows[selectedIndex]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("パフォーマンス推移", systemImage: "chart.xyaxis.line").font(.headline)
                Spacer()
                Menu {
                    Button("直近5試合") { count = 5 }
                    Button("直近10試合") { count = 10 }
                    Button("選択範囲の全試合") { count = 0 }
                } label: {
                    HStack(spacing: 5) {
                        Text(count == 0 ? "全試合" : "直近\(count)試合")
                        Image(systemName: "chevron.down").font(.caption2)
                    }.font(.caption.bold()).frame(minHeight: 44)
                }.accessibilityLabel("グラフの試合数")
            }
            Picker("グラフの指標", selection: $metric) {
                Text("得点・失点").tag("score")
                Text("得失点差").tag("margin")
            }.pickerStyle(.segmented)
            if metric == "score" {
                HStack(spacing: 20) {
                    legend("得点", color: accent, dashed: false, isOn: showsFor) {
                        if showsFor { showsFor = false; showsAgainst = true } else { showsFor = true }
                    }
                    legend("失点", color: TeamPerformanceColors.charcoal, dashed: true, isOn: showsAgainst) {
                        if showsAgainst { showsAgainst = false; showsFor = true } else { showsAgainst = true }
                    }
                    Spacer()
                    Text("単位：点").font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("0より上は得点超過、下は失点超過").font(.caption).foregroundStyle(.secondary)
            }
            chart
                .frame(height: 200)
                .chartXSelection(value: $selectedIndex)
                .chartYScale(domain: .automatic(includesZero: true))
                .chartXScale(domain: -0.5...(Double(max(rows.count - 1, 0)) + 0.5))
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) }
                .chartXAxis {
                    AxisMarks(values: axisIndices) { value in
                        AxisTick()
                        AxisValueLabel {
                            if let index = value.as(Int.self), rows.indices.contains(index) {
                                VStack(spacing: 2) {
                                    if spansYears {
                                        Text(rows[index].match.playedAt, format: .dateTime.year())
                                    }
                                    Text(rows[index].match.playedAt, format: .dateTime.month(.twoDigits).day(.twoDigits))
                                }
                            }
                        }
                    }
                }
            if let selected {
                Button { openMatch(selected.match) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(selected.match.playedAt, format: .dateTime.year().month().day()).font(.caption)
                            Text("対 \(opponentName(selected.opponentID))").font(.subheadline.bold())
                        }
                        Spacer()
                        Text("\(selected.pointsFor) – \(selected.pointsAgainst)").font(.headline.monospacedDigit())
                        Image(systemName: "chevron.right").font(.caption)
                    }.padding(12).background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain)
            } else {
                HStack {
                    Text("\(rows.count)試合 · 古い順").font(.caption)
                    Spacer()
                    Text("タップして試合を確認").font(.caption2)
                }.foregroundStyle(RugbyTheme.textSecondary)
            }
        }
        .padding(18)
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
        .tint(RugbyTheme.accent)
        .onChange(of: count) { _, _ in selectedIndex = nil }
        .onChange(of: results.map(\.id)) { _, _ in selectedIndex = nil }
    }

    private var spansYears: Bool {
        Set(rows.map { Calendar.current.component(.year, from: $0.match.playedAt) }).count > 1
    }
    private var axisIndices: [Int] {
        if rows.count <= 5 && !spansYears { return Array(rows.indices) }
        return [0, (rows.count - 1) / 2, rows.count - 1]
    }

    private var chart: some View {
        Chart {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if metric == "margin" {
                    BarMark(x: .value("試合", index), y: .value("得失点差", row.pointsFor - row.pointsAgainst))
                        .foregroundStyle(row.pointsFor >= row.pointsAgainst ? accent : TeamPerformanceColors.charcoal)
                        .cornerRadius(2)
                        .accessibilityLabel("\(opponentName(row.opponentID))戦")
                        .accessibilityValue("得失点差 \(row.pointsFor - row.pointsAgainst)点")
                } else {
                    if showsFor {
                        LineMark(x: .value("試合", index), y: .value("得点", row.pointsFor), series: .value("種別", "得点"))
                            .foregroundStyle(accent).lineStyle(StrokeStyle(lineWidth: 2.5))
                        PointMark(x: .value("試合", index), y: .value("得点", row.pointsFor))
                            .foregroundStyle(accent).symbol(.circle).symbolSize(30)
                            .accessibilityLabel("\(opponentName(row.opponentID))戦、得点")
                            .accessibilityValue("\(row.pointsFor)点")
                    }
                    if showsAgainst {
                        LineMark(x: .value("試合", index), y: .value("失点", row.pointsAgainst), series: .value("種別", "失点"))
                            .foregroundStyle(TeamPerformanceColors.charcoal).lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 4]))
                        PointMark(x: .value("試合", index), y: .value("失点", row.pointsAgainst))
                            .foregroundStyle(TeamPerformanceColors.charcoal).symbol(.square).symbolSize(22)
                            .accessibilityLabel("\(opponentName(row.opponentID))戦、失点")
                            .accessibilityValue("\(row.pointsAgainst)点")
                    }
                }
            }
            if metric == "margin" { RuleMark(y: .value("基準", 0)).foregroundStyle(Color.gray.opacity(0.4)) }
            if let selectedIndex, rows.indices.contains(selectedIndex) {
                RuleMark(x: .value("選択した試合", selectedIndex)).foregroundStyle(accent.opacity(0.25))
            }
        }
    }
    private func legend(_ label: String, color: Color, dashed: Bool, isOn: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.caption).foregroundStyle(isOn ? color : RugbyTheme.textSecondary)
                Path { path in path.move(to: CGPoint(x: 0, y: 3)); path.addLine(to: CGPoint(x: 20, y: 3)) }
                    .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [3, 3] : []))
                    .frame(width: 20, height: 6)
                Text(label).font(.caption)
            }
            .opacity(isOn ? 1 : 0.4)
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label)の線")
        .accessibilityValue(isOn ? "表示中" : "非表示")
        .accessibilityHint("タップで表示を切り替え")
    }
}
