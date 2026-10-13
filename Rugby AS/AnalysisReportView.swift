import SwiftUI
import SwiftData

// 集計は分析画面と同じ裏の作業場所(AnalysisWorkspaceLoader)で行い、ここでは指標ごとの値だけを受け取る
// (全記録・全選手をこの画面で読むと、記録が多いときに固まるため)。
struct AnalysisReportView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var teams: [Team]
    @AppStorage(AnalysisReport.storageKey) private var savedData = Data()
    @State private var report: AnalysisReport
    @State private var editingConditions = false
    @State private var message: String?
    @State private var initialized = false
    @State private var loader: AnalysisWorkspaceLoader?
    @State private var data: AnalysisReportData?
    @State private var isComputing = false
    @State private var dataRevision = 0

    init(scope: AnalysisScope, loader: AnalysisWorkspaceLoader? = nil) {
        var initial = AnalysisReport(scope: scope)
        if !scope.filter.category.isEmpty { initial.categories = [scope.filter.category] }
        initial.scope.filter.category = ""
        _report = State(initialValue: initial)
        _loader = State(initialValue: loader)
    }

    private struct ComputeKey: Equatable {
        let scope: AnalysisScope
        let revision: Int
    }

    private func compute() async {
        // 集計係はアプリで1つを使い回す(開き直すたびに全記録を読み直さないため)
        let loader = self.loader ?? AnalysisLoaderStore.loader(for: modelContext.container)
        self.loader = loader
        isComputing = true
        defer { isComputing = false }
        guard let value = try? await loader.report(report.scope, templateCategories: AnalysisMetricChoices.templateCategories),
              !Task.isCancelled else { return }
        data = value
        if !initialized {
            initialized = true
            if report.categories.isEmpty { report.categories = Array(value.choices.definitions.prefix(4).map(\.category)) }
        }
    }

    /// 条件に選んだ選手(条件の要約に名前を出すため、その1人だけ読む)
    private var selectedPlayers: [Player] {
        guard let id = UUID(uuidString: report.scope.filter.player) else { return [] }
        return (try? modelContext.fetch(FetchDescriptor<Player>(predicate: #Predicate { $0.id == id }))) ?? []
    }

    private func players(of teamID: UUID) -> [Player] {
        (try? modelContext.fetch(FetchDescriptor<Player>(predicate: #Predicate { $0.teamID == teamID }))) ?? []
    }

    private func title(_ category: String, titles: [String: String]) -> String {
        titles[category] ?? RecordingMetricCatalog.titlesByCategory[category] ?? category
    }

    var body: some View {
        Group {
            if let data {
                content(data)
            } else {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large).tint(RugbyTheme.accent)
                    Text("記録を集計しています…").font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("マイ分析レポート").navigationBarTitleDisplayMode(.inline)
        .task(id: ComputeKey(scope: report.scope, revision: dataRevision)) { await compute() }
        .onReceive(ModelSaveSignal.didSave) { _ in
            Task { await loader?.invalidate() }
            dataRevision += 1
        }
    }

    private func content(_ data: AnalysisReportData) -> some View {
        // These values are shared by every row, picker and export.
        let definitions = data.choices.definitions
        let titles = Dictionary(definitions.map { ($0.category, $0.title) }, uniquingKeysWith: { first, _ in first })
        let saved = (try? JSONDecoder().decode([AnalysisReport].self, from: savedData)) ?? []
        let snapshot = data.snapshot
        let details = RecordingAnalysisConditions.summary(report.scope.filter, definitions: definitions, players: selectedPlayers,
            lineups: [], match: nil, teams: teams)
        let conditions = "\(data.selectedCount.formatted())試合 · " + (details.isEmpty ? "記録条件なし" : details)
        return List {
            Section("分析を保存・呼び出す") {
                TextField("分析名", text: $report.name)
                HStack {
                    Button("保存") { save() }
                    Spacer()
                    Menu("呼び出す") {
                        ForEach(saved) { item in Button(item.name) { report = item } }
                        Button("新しい分析") { report = AnalysisReport(scope: report.scope) }
                    }
                }
                if saved.contains(where: { $0.id == report.id }) {
                    Button("この分析を別名で複製") { report.id = UUID(); report.name += " コピー" }
                    Button("保存した分析を削除", role: .destructive) {
                        do { savedData = try JSONEncoder().encode(saved.filter { $0.id != report.id }); report.id = UUID() }
                        catch { message = error.localizedDescription }
                    }
                }
            }
            Section {
                Text(conditions).font(.subheadline)
                if isComputing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("集計し直しています…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("記録の条件を変更") { editingConditions = true }
                Picker("試合数", selection: $report.scope.recentLimit) {
                    Text("すべて").tag(0); Text("直近5試合").tag(5); Text("直近10試合").tag(10)
                }
            } header: { Text("対象") } footer: {
                Text("大会・カテゴリー・7人制/15人制と指定試合は分析・比較画面から引き継ぎます。指標は下の一覧で選び、その他の条件はすべての指標に共通で適用します。")
            }
            Section {
                NavigationLink("指標を選ぶ・並べ替える（\(report.categories.count)項目）") { metricPicker(definitions: definitions, titles: titles) }
                ForEach(report.categories, id: \.self) { category in metricRow(category, snapshot: snapshot, titles: titles) }
            } header: { Text("レポート") } footer: {
                Text("試合平均の分母は、その指標の記録がある試合数です。未記録の試合は0回として扱いません。")
            }
            ratioSection(definitions: definitions, snapshot: snapshot, titles: titles)
            Section {
                ShareLink(item: MatchCSVFile(fileName: "RugbyAS_分析_\(report.id.uuidString).csv",
                    csvText: AnalysisReportExport.csv(report: report, snapshot: snapshot, matchCount: data.selectedCount, titles: titles, conditions: conditions)),
                    preview: SharePreview(report.name)) {
                        Label("この並びでCSVを書き出す", systemImage: "square.and.arrow.up")
                    }.disabled(report.categories.isEmpty && report.ratio == nil)
            }
        }
        .sheet(isPresented: $editingConditions) {
            RecordingAnalysisConditions(filter: report.scope.filter, definitions: definitions, players: selectedPlayers,
                lineups: [], match: nil, teams: teams, loadPlayers: players(of:)) { value in
                    report.scope.filter = value
                    if !value.category.isEmpty && !report.categories.contains(value.category) { report.categories.append(value.category) }
                    report.scope.filter.category = ""
                }
        }
        .alert("マイ分析", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
    }

    private func metricPicker(definitions: [RecordingWidgetDefinition], titles: [String: String]) -> some View {
        List {
            Section("表示順（右のハンドルで移動）") {
                ForEach(report.categories, id: \.self) { Text(title($0, titles: titles)) }
                    .onMove { report.categories.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { report.categories.remove(atOffsets: $0) }
            }
            Section("追加する指標") {
                ForEach(definitions.filter { !report.categories.contains($0.category) }) { definition in
                    Button { report.categories.append(definition.category) } label: { Label(definition.title, systemImage: "plus.circle") }
                }
            }
        }.environment(\.editMode, .constant(.active))
            .navigationTitle("指標と表示順").navigationBarTitleDisplayMode(.inline)
    }

    private func metricRow(_ category: String, snapshot: AnalysisMetricSnapshot, titles: [String: String]) -> some View {
        let summary = snapshot.summary(for: category)
        let count = snapshot.recordedMatchCount(for: category)
        return VStack(alignment: .leading, spacing: 5) {
            Text(title(category, titles: titles)).font(.headline)
            if summary.count == 0 { Text("記録なし").foregroundStyle(.secondary) }
            else {
                Text("\(summary.count)件 · \(count)試合 · 試合平均 \(Double(summary.count) / Double(max(1, count)), specifier: "%.1f")件")
                if let rate = summary.successRate { Text("成功 \(summary.successes)/\(summary.attempts) · \(rate * 100, specifier: "%.1f")%") }
                if summary.hasMixedUnits { Text("単位が混在しています").foregroundStyle(.orange) }
                else if let total = summary.total, let average = summary.average {
                    Text("合計 \(total, specifier: "%g")\(summary.unit ?? "") · 平均 \(average, specifier: "%.1f")\(summary.unit ?? "")")
                }
            }
        }.font(.subheadline).padding(.vertical, 3)
    }

    @ViewBuilder private func ratioSection(definitions: [RecordingWidgetDefinition], snapshot: AnalysisMetricSnapshot, titles: [String: String]) -> some View {
        Section {
            Toggle("独自の比率を表示", isOn: Binding(get: { report.ratio != nil }, set: {
                report.ratio = $0 ? AnalysisRatio(numerator: definitions.first?.category ?? "", denominator: definitions.first?.category ?? "") : nil
            }))
            if let ratio = report.ratio {
                Picker("分子", selection: ratioBinding(\.numerator, fallback: "")) {
                    ForEach(definitions) { Text($0.title).tag($0.category) }
                }
                Picker("分子に使う値", selection: ratioBinding(\.measure, fallback: .records)) {
                    ForEach(AnalysisRatio.Numerator.allCases, id: \.rawValue) { Text($0.title).tag($0) }
                }
                Picker("分母（記録数）", selection: ratioBinding(\.denominator, fallback: "")) {
                    ForEach(definitions) { Text($0.title).tag($0.category) }
                }
                Picker("何件当たり", selection: ratioBinding(\.factor, fallback: 1)) {
                    Text("1件").tag(1); Text("10件").tag(10); Text("100件").tag(100)
                }
                let result = ratio.result(snapshot: snapshot)
                Text("\(title(ratio.numerator, titles: titles))の\(ratio.measure.title) ÷ \(title(ratio.denominator, titles: titles))の記録数 × \(ratio.factor)")
                    .font(.caption).foregroundStyle(.secondary)
                if let value = result.value {
                    Text("\(value, specifier: "%.2f")\(result.unit ?? "")（分母 \(result.denominator)件）").bold()
                } else { Text("算出不可：分子の入力と、分母の記録が必要です。単位が混在する数値は合算できません。").font(.caption) }
            }
        } header: { Text("指標を組み合わせる") } footer: {
            Text("比率は入力された記録同士の比較です。成功率とは限らず、100を超えることがあります。")
        }
    }

    private func ratioBinding<T>(_ key: WritableKeyPath<AnalysisRatio, T>, fallback: T) -> Binding<T> {
        Binding(get: { report.ratio?[keyPath: key] ?? fallback }, set: { report.ratio?[keyPath: key] = $0 })
    }

    private func save() {
        do {
            let valid = try report.validated()
            savedData = try AnalysisReport.merged(current: savedData, incoming: JSONEncoder().encode([valid])) ?? Data()
            message = "条件・指標の並び・比率を保存しました。"
        } catch { message = error.localizedDescription }
    }
}
