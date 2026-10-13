import SwiftUI
import SwiftData
import Charts

// 記録が数十万件あっても固まらないよう、集計は AnalysisWorkspaceLoader が裏で行う。
// この画面は条件を渡して、返ってきた結果を表示するだけにする(全記録・全選手をここでは読まない)。
struct AnalysisWorkspaceView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Team.name) private var teams: [Team]
    @Query private var tournaments: [Tournament]
    @State private var loader: AnalysisWorkspaceLoader?
    @State private var result: AnalysisWorkspaceResult?
    @State private var isComputing = false
    @State private var computeError: String?
    @State private var dataRevision = 0
    @State private var scope = AnalysisScope()
    @State private var category = ""
    @State private var mode = 0
    @State private var showingScope = false
    @State private var editingConditions = false
    @State private var editingInclusion = false
    var initialPlayerID: UUID?

    private var request: AnalysisWorkspaceRequest {
        AnalysisWorkspaceRequest(scope: scope, category: category, templateCategories: AnalysisMetricChoices.templateCategories)
    }

    private struct ComputeKey: Equatable {
        let request: AnalysisWorkspaceRequest
        let revision: Int
    }

    /// 条件に選んだ選手(条件の要約に名前を出すため、その1人だけ読む)
    private var selectedPlayers: [Player] {
        guard let id = UUID(uuidString: scope.filter.player) else { return [] }
        return (try? modelContext.fetch(FetchDescriptor<Player>(predicate: #Predicate { $0.id == id }))) ?? []
    }

    /// 条件の画面で、選んだチームの選手だけを読む
    private func players(of teamID: UUID) -> [Player] {
        (try? modelContext.fetch(FetchDescriptor<Player>(predicate: #Predicate { $0.teamID == teamID }))) ?? []
    }

    var body: some View {
        content
            .onAppear { if let initialPlayerID { scope.filter.player = initialPlayerID.uuidString } }
            .task(id: ComputeKey(request: request, revision: dataRevision)) { await compute() }
            .onReceive(ModelSaveSignal.didSave) { _ in
                // 記録が変わったら、控えを捨てて集計し直す
                Task { await loader?.invalidate() }
                dataRevision += 1
            }
    }

    private func compute() async {
        // 集計係はアプリで1つを使い回す(開き直すたびに全記録を読み直さないため)
        let loader = self.loader ?? AnalysisLoaderStore.loader(for: modelContext.container)
        self.loader = loader
        isComputing = true
        defer { isComputing = false }
        do {
            let value = try await loader.compute(request)
            guard !Task.isCancelled else { return }
            result = value
            computeError = nil
        } catch is CancellationError {
        } catch {
            computeError = "集計できませんでした。もう一度開き直してください。"
        }
    }

    @ViewBuilder private var content: some View {
        if let result {
            workspace(result)
        } else {
            VStack(spacing: 14) {
                if let computeError {
                    Label(computeError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(RugbyTheme.textSecondary)
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .tint(RugbyTheme.accent)
                    Text("記録を集計しています…")
                        .font(.subheadline.weight(.semibold))
                    Text("記録が多いと少し時間がかかります。")
                        .font(.caption)
                        .foregroundStyle(RugbyTheme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RugbyTheme.background)
            .navigationTitle("分析")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func workspace(_ result: AnalysisWorkspaceResult) -> some View {
        let definitions = result.choices.definitions
        let selectedCategory = result.selectedCategory
        let overall = result.overall

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                RugbyScreenHeading(eyebrow: "PERFORMANCE", title: "分析・比較", subtitle: "試合を振り返り、次のプレーにつなげる。")

                scopeCard(selectedCount: result.selectedCount, definitions: definitions, excludedCount: result.excludedCount,
                          allMatches: result.allMatches)

                if isComputing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(RugbyTheme.accent)
                        Text("集計し直しています…").font(.caption).foregroundStyle(RugbyTheme.textSecondary)
                    }
                }

                if definitions.isEmpty {
                    RugbyEmptyState(symbol: "chart.bar.xaxis", title: "分析する記録がありません", message: "試合の記録が増えると、ここで試合別・選手別に比較できます。")
                        .background(RugbyTheme.surface)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("パフォーマンス概要")
                                .font(.headline)
                            Spacer(minLength: 8)
                            Text("\(result.selectedCount.formatted())試合が対象")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(RugbyTheme.textSecondary)
                        }
                        Picker("比較する指標", selection: Binding(get: { selectedCategory }, set: { category = $0 })) {
                            ForEach(definitions) { Text($0.title).tag($0.category) }
                        }
                        .pickerStyle(.menu)
                        .disabled(!scope.filter.category.isEmpty)
                        .tint(RugbyTheme.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(RugbyTheme.accentSoft, in: RoundedRectangle(cornerRadius: 6))

                        overview(overall)
                    }
                    .padding(18)
                    .background(RugbyTheme.surface)
                    .overlay(alignment: .top) {
                        Rectangle().fill(RugbyTheme.accent).frame(height: 3)
                    }

                    comparison(result)

                    Label {
                        Text("表示は入力された記録に基づきます。記録がない試合は、プレーが0回だった試合とはみなしません。成否を指定した場合は、絞り込み後の成功率を表示します。")
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(.caption)
                    .foregroundStyle(RugbyTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                NavigationLink { AnalysisReportView(scope: scope, loader: loader) } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "doc.text.image")
                            .font(.title3)
                            .foregroundStyle(RugbyTheme.accent)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("マイ分析・レポート")
                                .font(.headline)
                                .foregroundStyle(RugbyTheme.textPrimary)
                            Text("指標を組み合わせて、保存・共有")
                                .font(.caption)
                                .foregroundStyle(RugbyTheme.textSecondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(RugbyTheme.accent)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 18)
                    .overlay(alignment: .top) {
                        Rectangle().fill(RugbyTheme.border).frame(height: 1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: 1040)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .background(RugbyTheme.background)
        .foregroundStyle(RugbyTheme.textPrimary)
        .tint(RugbyTheme.accent)
        .navigationTitle("分析")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { AnalysisReportView(scope: scope, loader: loader) } label: {
                    Label("レポート", systemImage: "doc.text.image")
                }
                .tint(RugbyTheme.accent)
            }
        }
        .sheet(isPresented: $editingInclusion) { StatsInclusionEditor() }
        .sheet(isPresented: $editingConditions) {
            RecordingAnalysisConditions(filter: scope.filter, definitions: definitions, players: selectedPlayers,
                lineups: [], match: nil, teams: teams, loadPlayers: players(of:)) { scope.filter = $0 }
        }
    }

    private func scopeCard(selectedCount: Int, definitions: [RecordingWidgetDefinition], excludedCount: Int,
                           allMatches: [AnalysisWorkspaceResult.MatchItem]) -> some View {
        DisclosureGroup(isExpanded: $showingScope) {
            VStack(alignment: .leading, spacing: 16) {
                Divider().overlay(RugbyTheme.border)
                Picker("大会", selection: $scope.tournamentID) {
                    Text("すべての大会").tag(UUID?.none)
                    ForEach(tournaments) { Text($0.officialName).tag(Optional($0.id)) }
                }
                .pickerStyle(.menu)
                Picker("試合数", selection: $scope.recentLimit) {
                    Text("すべて").tag(0)
                    Text("直近5試合").tag(5)
                    Text("直近10試合").tag(10)
                }
                .pickerStyle(.menu)
                CompetitionFilterMenus(
                    filter: Binding(get: { scope.competition ?? CompetitionFilter() },
                                    set: { scope.competition = $0.isActive ? $0 : nil }),
                    categories: tournaments.compactMap(\.category)
                )
                NavigationLink { matchSelection(allMatches) } label: {
                    controlRow("対象試合を選ぶ", symbol: "sportscourt", value: "\(selectedCount.formatted())試合")
                }
                Button { editingConditions = true } label: {
                    controlRow("条件を組み合わせる", symbol: "line.3.horizontal.decrease", value: "\(scope.filter.activeCount)条件")
                }
                if scope.filter.activeCount > 0 {
                    Text(RecordingAnalysisConditions.summary(scope.filter, definitions: definitions, players: selectedPlayers,
                        lineups: [], match: nil, teams: teams))
                        .font(.caption)
                        .foregroundStyle(RugbyTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("条件を解除") { scope.filter = RecordingAnalysisFilter() }
                        .font(.subheadline.weight(.medium))
                }
                Divider().overlay(RugbyTheme.border)
                Button { editingInclusion = true } label: {
                    controlRow("集計に含める試合", symbol: "checklist", value: excludedCount > 0 ? "対象外 \(excludedCount)" : "設定")
                }
                Text("大会・カテゴリー・7人制/15人制・チーム・選手・指定試合で絞り込んでから、直近の試合数を適用します。")
                    .font(.caption)
                    .foregroundStyle(RugbyTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 12)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3")
                    .font(.title3)
                    .foregroundStyle(RugbyTheme.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("集計対象と条件").font(.subheadline.weight(.semibold)).foregroundStyle(RugbyTheme.textPrimary)
                    Text(scopeDescription(selectedCount: selectedCount))
                        .font(.caption)
                        .foregroundStyle(RugbyTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)
        }
        .tint(RugbyTheme.accent)
        .buttonStyle(.plain)
        .padding(14)
        .background(RugbyTheme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
    }

    private func scopeDescription(selectedCount: Int) -> String {
        let tournament = tournaments.first { $0.id == scope.tournamentID }?.officialName ?? "すべての大会"
        let conditions = scope.filter.activeCount > 0 ? " · \(scope.filter.activeCount)条件" : ""
        let limit = scope.recentLimit > 0 ? " · 直近\(scope.recentLimit)試合" : ""
        let competition = scope.competition?.label.map { " · " + $0 } ?? ""
        return "\(tournament)\(competition) · \(selectedCount.formatted())試合\(limit)\(conditions)"
    }

    private func controlRow(_ title: String, symbol: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 22)
                .foregroundStyle(RugbyTheme.accent)
                .accessibilityHidden(true)
            Text(title).foregroundStyle(RugbyTheme.textPrimary)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption)
                .foregroundStyle(RugbyTheme.textSecondary)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(RugbyTheme.textSecondary)
                .accessibilityHidden(true)
        }
        .font(.subheadline)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private func matchSelection(_ matches: [AnalysisWorkspaceResult.MatchItem]) -> some View {
        List {
            Section {
                Button("全試合を対象にする") { scope.matchIDs = [] }
            } footer: {
                Text("個別に選択していない場合は、すべての試合が対象です。")
            }
            Section {
                ForEach(matches) { match in
                    if match.isExcluded {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(match.title)
                            Text(match.playedAt.formatted(date: .numeric, time: .omitted) + " · 集計対象外")
                                .font(.caption)
                        }
                        .foregroundStyle(RugbyTheme.textSecondary)
                        .padding(.vertical, 6)
                    } else {
                        Button {
                            if scope.matchIDs.contains(match.id) { scope.matchIDs.remove(match.id) }
                            else { scope.matchIDs.insert(match.id) }
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(match.title).foregroundStyle(RugbyTheme.textPrimary)
                                    Text(match.playedAt.formatted(date: .numeric, time: .omitted))
                                        .font(.caption)
                                        .foregroundStyle(RugbyTheme.textSecondary)
                                }
                                Spacer()
                                Image(systemName: scope.matchIDs.contains(match.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(scope.matchIDs.contains(match.id) ? RugbyTheme.accent : RugbyTheme.textSecondary)
                            }
                            .padding(.vertical, 6)
                        }
                        .accessibilityValue(scope.matchIDs.contains(match.id) ? "選択済み" : "未選択")
                    }
                }
            }
            .listRowBackground(RugbyTheme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(RugbyTheme.background)
        .foregroundStyle(RugbyTheme.textPrimary)
        .tint(RugbyTheme.accent)
        .navigationTitle("対象試合")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func overview(_ value: RecordingMetricSummary) -> some View {
        if value.count == 0 {
            VStack(alignment: .leading, spacing: 8) {
                Text("記録なし").font(.title2.weight(.bold))
                Text("対象の試合・条件に一致する記録がありません。")
                    .font(.subheadline)
                    .foregroundStyle(RugbyTheme.textSecondary)
            }
            .padding(.vertical, 8)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 20) {
                metric(value: value.count.formatted(), unit: "件", label: "記録数", highlighted: true)
                if let rate = value.successRate {
                    metric(value: String(format: "%.1f", rate * 100), unit: "%",
                           label: "成功率 · \(value.successes.formatted())/\(value.attempts.formatted())")
                }
            }
            numericSummary(value)
        }
    }

    private func metric(value: String, unit: String, label: String, highlighted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(RugbyTheme.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(.largeTitle, design: .default, weight: .bold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text(unit).font(.subheadline.weight(.medium))
            }
            .foregroundStyle(highlighted ? RugbyTheme.accent : RugbyTheme.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }

    private func comparison(_ result: AnalysisWorkspaceResult) -> some View {
        // 新しい順に上限まで(上限は集計側で絞ってある)。グラフは左から古い順に並べる
        let rows = result.matchRows
        let playerRows = result.playerRows
        return VStack(alignment: .leading, spacing: 16) {
            Text("記録を比較").font(.title3.weight(.bold))
            Picker("比較対象", selection: $mode) {
                Text("試合別").tag(0)
                Text("選手別").tag(1)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("比較対象")

            if mode == 0 {
                if rows.contains(where: { $0.summary.count > 0 }) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("試合ごとの記録数")
                            .font(.subheadline.weight(.semibold))
                        Chart(Array(rows.reversed().enumerated()), id: \.element.id) { entry in
                            if entry.element.summary.count > 0 {
                                BarMark(x: .value("試合（古い順）", String(entry.offset + 1)),
                                        y: .value("記録数", entry.element.summary.count), width: .ratio(0.5))
                                    .foregroundStyle(RugbyTheme.accent)
                                    .cornerRadius(2)
                                    .accessibilityLabel(entry.element.title)
                                    .accessibilityValue("\(entry.element.summary.count)件")
                            }
                        }
                        .chartXScale(domain: rows.indices.map { String($0 + 1) })
                        .chartYAxis {
                            AxisMarks(position: .leading) { _ in
                                AxisGridLine().foregroundStyle(RugbyTheme.border)
                                AxisValueLabel().foregroundStyle(RugbyTheme.textSecondary)
                            }
                        }
                        .chartXAxis {
                            // 棒が多いと番号が重なるので、5本ごとに番号を出す
                            AxisMarks(values: rows.indices.filter { rows.count <= 15 || $0 % 5 == 0 }.map { String($0 + 1) }) { _ in
                                AxisValueLabel().foregroundStyle(RugbyTheme.textSecondary)
                            }
                        }
                        .frame(height: 190)
                        .accessibilityLabel("対象試合の記録数比較")
                        Text("左から古い試合順。未記録の試合は棒を表示しません。"
                             + (result.selectedCount > rows.count ? "新しい\(rows.count)試合を表示しています（全\(result.selectedCount.formatted())試合）。" : ""))
                            .font(.caption)
                            .foregroundStyle(RugbyTheme.textSecondary)
                    }
                    .padding(18)
                    .background(RugbyTheme.surface)
                }
                if rows.isEmpty {
                    RugbyEmptyState(symbol: "line.3.horizontal.decrease.circle", title: "対象の試合がありません", message: "集計対象や条件を変更すると、比較を表示できます。")
                        .background(RugbyTheme.surface)
                }
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        Group {
                            VStack(alignment: .leading, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(row.playedAt.formatted(date: .numeric, time: .omitted))
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(RugbyTheme.textSecondary)
                                    Text(row.title).font(.subheadline.weight(.semibold))
                                }
                                summary(row.summary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(18)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(RugbyTheme.border).frame(height: 1)
                            }
                        }
                    }
                }
                .background(RugbyTheme.surface)
            } else {
                if playerRows.isEmpty {
                    RugbyEmptyState(symbol: "person.crop.circle", title: "選手別の記録がありません", message: "記録に選手を紐づけると、ここで比較できます。")
                        .background(RugbyTheme.surface)
                }
                VStack(spacing: 0) {
                    ForEach(playerRows) { row in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(row.name).font(.subheadline.weight(.semibold))
                            summary(row.summary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(RugbyTheme.border).frame(height: 1)
                        }
                    }
                }
                .background(RugbyTheme.surface)
                if result.playerTotal > playerRows.count {
                    Text("記録の多い\(playerRows.count)人を表示しています（全\(result.playerTotal.formatted())人）。")
                        .font(.caption)
                        .foregroundStyle(RugbyTheme.textSecondary)
                }
                let unassigned = result.unassignedCount
                if unassigned > 0 {
                    Text("選手未設定の記録が\(unassigned)件あります。選手別の比較には含めていません。")
                        .font(.caption)
                        .foregroundStyle(RugbyTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private func summary(_ value: RecordingMetricSummary) -> some View {
        if value.count == 0 {
            Text("記録なし").font(.subheadline).foregroundStyle(RugbyTheme.textSecondary)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    recordCount(value)
                    Spacer(minLength: 8)
                    successSummary(value)
                }
                VStack(alignment: .leading, spacing: 8) {
                    recordCount(value)
                    successSummary(value)
                }
            }
            numericSummary(value)
        }
    }

    private func recordCount(_ value: RecordingMetricSummary) -> some View {
        Text("\(value.count.formatted())件")
            .font(.title3.weight(.bold))
            .foregroundStyle(RugbyTheme.accent)
            .monospacedDigit()
    }

    @ViewBuilder private func successSummary(_ value: RecordingMetricSummary) -> some View {
        if let rate = value.successRate {
            Text("成功 \(value.successes)/\(value.attempts) · \(rate * 100, specifier: "%.1f")%")
                .font(.subheadline)
                .monospacedDigit()
        }
    }

    @ViewBuilder private func numericSummary(_ value: RecordingMetricSummary) -> some View {
        if value.hasMixedUnits {
            Label("単位が混在しているため数値を合算できません。", systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(RugbyTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        } else if let total = value.total, let average = value.average {
            Text("合計 \(total, specifier: "%g")\(value.unit ?? "") · 平均 \(average, specifier: "%.1f")\(value.unit ?? "")（入力\(value.numericCount)件）")
                .font(.subheadline)
                .foregroundStyle(RugbyTheme.textSecondary)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
