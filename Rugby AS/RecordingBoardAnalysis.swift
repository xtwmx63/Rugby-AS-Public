import SwiftUI

struct RecordingBoardAnalysis: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: RecordingWidgetStore
    let players: [Player]
    let lineups: [MatchLineup]
    @State private var filter = RecordingAnalysisFilter()
    @State private var editingConditions = false
    var body: some View {
        let prepared = filter.prepared()
        let events = store.events.filter { prepared.matches($0, matchID: store.match.id) }
        let snapshot = AnalysisMetricSnapshot(events: events)
        let definitions = AnalysisComparison.definitions(events: store.events, preferred: store.layout.widgets, boardOnly: true)
        let visibleDefinitions = definitions.filter { snapshot.eventsByCategory[$0.category] != nil }
        NavigationStack {
            VStack(spacing: 10) {
                Picker("集計対象", selection: $filter.teamID) {
                    Text("両チーム").tag(UUID?.none)
                    Text("HOME").tag(Optional(store.match.homeTeamID))
                    Text("AWAY").tag(Optional(store.match.awayTeamID))
                }.pickerStyle(.segmented).padding(.horizontal, 16)
                List {
                    Section {
                        Button { editingConditions = true } label: {
                            HStack {
                                Label("条件を組み合わせる", systemImage: "line.3.horizontal.decrease.circle")
                                Spacer()
                                Text(filter.activeCount == 0 ? "すべて" : "\(filter.activeCount)条件")
                                    .foregroundStyle(.secondary)
                            }.frame(minHeight: 36)
                        }
                        if filter.activeCount > 0 {
                            Text(RecordingAnalysisConditions.summary(filter, definitions: definitions, players: players,
                                lineups: lineups, match: store.match)).font(.subheadline)
                            Button("すべての条件を解除") { filter = RecordingAnalysisFilter() }
                        }
                        NavigationLink {
                            RecordingEventList(store: store, players: players, lineups: lineups, eventIDs: events.map(\.id))
                                .navigationTitle("条件に合う記録").navigationBarTitleDisplayMode(.inline)
                        } label: {
                            Label("該当する記録 \(events.count)件を見る", systemImage: "list.bullet.clipboard")
                        }.disabled(events.isEmpty)
                    } footer: {
                        Text("指定した条件をすべて満たす記録を集計します。場所・選手などが未入力の記録は、その条件を指定した場合に除外します。")
                    }
                    if events.isEmpty {
                        ContentUnavailableView(filter.activeCount == 0 ? "まだ記録がありません" : "条件に合う記録がありません",
                            systemImage: "line.3.horizontal.decrease.circle",
                            description: Text("条件を変更するか、記録に選手・場所などを追加してください。"))
                    } else if visibleDefinitions.isEmpty {
                        Text("条件に合う保持・メモなどの詳細は、上の「該当する記録」から確認できます。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(visibleDefinitions) { widget in
                        NavigationLink {
                            RecordingEventList(store: store, players: players, lineups: lineups,
                                eventIDs: (snapshot.eventsByCategory[widget.category] ?? []).map(\.id))
                                .navigationTitle(widget.title).navigationBarTitleDisplayMode(.inline)
                        } label: {
                            metricRow(widget, snapshot: snapshot)
                        }
                    }
                    Section {
                        Text("入力した記録のみを集計します。未入力の値は平均に含めません。判定基準や単位はチーム内で揃えてください。")
                            .font(.caption).foregroundStyle(.secondary)
                        if !filter.outcome.isEmpty {
                            Text("成否を絞っているため、成功率も絞り込み後の記録だけで計算しています。")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }.listStyle(.insetGrouped)
            }
            .navigationTitle("指標の集計").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
            .sheet(isPresented: $editingConditions) {
                RecordingAnalysisConditions(filter: filter, definitions: definitions, players: players,
                    lineups: lineups, match: store.match) { filter = $0 }
            }
        }.preferredColorScheme(.dark)
    }
    private func metricRow(_ widget: RecordingWidgetDefinition, snapshot: AnalysisMetricSnapshot) -> some View {
        let events = snapshot.eventsByCategory[widget.category] ?? []
        let summary = snapshot.summary(for: widget.category)
        let choices = Dictionary(grouping: events.compactMap { $0.recordingDetails.choice }, by: { $0 })
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(widget.title, systemImage: widget.symbol).font(.headline)
                Spacer()
                Text("\(summary.count)件").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            if widget.kind == .result || widget.kind == .successRate ||
                RecordingMetricCatalog.templates.contains(where: { $0.widget.category == widget.category && $0.widget.kind == .result }) ||
                events.contains(where: { $0.outcome == "fail" }) {
                Text(summary.successRate.map { "成功 \(summary.successes) / \(summary.attempts)  ·  \(Int(($0 * 100).rounded()))%" } ?? "成否の記録なし")
                    .font(.subheadline.monospacedDigit())
            }
            if summary.hasMixedUnits {
                Text("単位が混在しているため、合計・平均を表示できません。")
                    .font(.caption).foregroundStyle(.orange)
            } else if let total = summary.total, let average = summary.average {
                let unit = summary.unit ?? widget.unit
                HStack {
                    Text("合計 " + String(format: "%g", total) + " " + unit)
                    Spacer()
                    Text("平均 " + String(format: "%.1f", average) + " " + unit)
                }.font(.subheadline.monospacedDigit())
                Text("数値入力済み \(summary.numericCount)件").font(.caption).foregroundStyle(.secondary)
            }
            if !choices.isEmpty {
                Text(choices.keys.sorted().map { "\($0) \(choices[$0]!.count)" }.joined(separator: "  ·  "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 5)
    }
}

struct RecordingAnalysisConditions: View {
    @Environment(\.dismiss) private var dismiss
    @State var filter: RecordingAnalysisFilter
    let definitions: [RecordingWidgetDefinition]
    let players: [Player]
    let lineups: [MatchLineup]
    let match: Match?
    var teams: [Team] = []
    /// 試合をまたぐ分析では全選手を持たず、選んだチームの選手だけをその都度読む
    /// (選手が数万人いると、選択肢を並べるだけで固まるため)
    var loadPlayers: ((UUID) -> [Player])? = nil
    let apply: (RecordingAnalysisFilter) -> Void

    private var availablePlayers: [Player] {
        let candidates: [Player]
        if let loadPlayers {
            candidates = filter.teamID.map(loadPlayers) ?? []
        } else {
            candidates = players.filter { filter.teamID == nil || $0.teamID == filter.teamID }
        }
        return candidates.sorted { playerLabel($0) < playerLabel($1) }
    }
    private func playerLabel(_ player: Player) -> String {
        Self.playerLabel(player, match: match, lineups: lineups, teams: teams)
    }
    private static func playerLabel(_ player: Player, match: Match?, lineups: [MatchLineup], teams: [Team] = []) -> String {
        let team = match.map { player.teamID == $0.homeTeamID ? "HOME" : "AWAY" }
            ?? teams.first { $0.id == player.teamID }?.name ?? "チーム未設定"
        let number = (match.map { MatchNumbering.number(for: player, matchID: $0.id, lineups: lineups) } ?? player.number).map { "#\($0) " } ?? ""
        return team + " · " + number + (player.name ?? "名前未設定")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("チーム", selection: $filter.teamID) {
                        Text(match == nil ? "すべて" : "両チーム").tag(UUID?.none)
                        if let match {
                            Text("HOME").tag(Optional(match.homeTeamID))
                            Text("AWAY").tag(Optional(match.awayTeamID))
                        } else {
                            ForEach(teams) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                    Picker("前後半", selection: $filter.half) {
                        Text("両方").tag(Int?.none)
                        Text("前半").tag(Optional(0)); Text("後半").tag(Optional(1))
                    }
                    Picker("指標", selection: $filter.category) {
                        Text("すべて").tag("")
                        ForEach(definitions) { Text($0.title).tag($0.category) }
                    }
                    Picker("選手", selection: $filter.player) {
                        Text("すべて").tag(""); Text("選手未設定").tag("unset")
                        ForEach(availablePlayers) { Text(playerLabel($0)).tag($0.id.uuidString) }
                        if let selected = players.first(where: { $0.id.uuidString == filter.player }),
                           !availablePlayers.contains(where: { $0.id == selected.id }) {
                            Text(playerLabel(selected) + "（別チーム）").tag(selected.id.uuidString)
                        }
                    }
                    if loadPlayers != nil && filter.teamID == nil {
                        Text("チームを選ぶと、そのチームの選手で絞り込めます。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Picker("成否", selection: $filter.outcome) {
                        Text("すべて").tag(""); Text("成功").tag("success"); Text("失敗").tag("fail")
                    }
                } header: { Text("記録の条件") } footer: {
                    Text("条件はすべて同時に適用します。成否を指定すると、回数のみの記録は対象外になります。")
                }
                Section {
                    HStack {
                        Text("開始")
                        TextField("例: 10:00", text: $filter.startTime).multilineTextAlignment(.trailing)
                            .keyboardType(.numbersAndPunctuation).accessibilityLabel("開始時刻、分と秒")
                    }
                    HStack {
                        Text("終了")
                        TextField("例: 20:00", text: $filter.endTime).multilineTextAlignment(.trailing)
                            .keyboardType(.numbersAndPunctuation).accessibilityLabel("終了時刻、分と秒")
                    }
                    if let message = filter.validationMessage { Text(message).font(.caption).foregroundStyle(.red) }
                } header: { Text("時間帯") } footer: {
                    Text("各ハーフの時計で指定します。空欄は制限なし。開始・終了時刻を含み、区間の記録は開始時刻で判定します。")
                }
                Section {
                    Picker("エリア", selection: $filter.zoneRow) {
                        Text("すべて").tag(-1); Text("敵陣").tag(0); Text("中央").tag(1)
                        Text("自陣").tag(2); Text("場所未入力").tag(3)
                    }
                    Picker("レーン", selection: $filter.zoneColumn) {
                        Text("すべて").tag(-1); Text("左").tag(0); Text("中央").tag(1); Text("右").tag(2)
                    }.disabled(filter.zoneRow == 3)
                    Picker("起点", selection: $filter.origin) {
                        Text("すべて").tag(""); Text("起点未設定").tag("unset")
                        ForEach(PlayOrigin.allCases) { Text($0.displayName).tag($0.rawValue) }
                    }
                } header: { Text("場所・起点") } footer: {
                    Text("記録時の攻撃方向に合わせて、自陣・敵陣と左右を判定します。起点は、その記録に登録したものを使います。")
                }
                Section {
                    Button { apply(filter); dismiss() } label: {
                        Label("この条件で集計", systemImage: "chart.bar.xaxis")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }.disabled(filter.validationMessage != nil)
                    Button("すべての条件を解除") { filter = RecordingAnalysisFilter() }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("分析の条件").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("適用") { apply(filter); dismiss() }.disabled(filter.validationMessage != nil)
                }
            }
            .onChange(of: filter.zoneRow) { _, row in if row == 3 { filter.zoneColumn = -1 } }
        }
    }

    static func summary(_ filter: RecordingAnalysisFilter, definitions: [RecordingWidgetDefinition],
                        players: [Player], lineups: [MatchLineup], match: Match?, teams: [Team] = []) -> String {
        var parts: [String] = []
        if let team = filter.teamID {
            parts.append(match.map { team == $0.homeTeamID ? "HOME" : "AWAY" } ?? teams.first { $0.id == team }?.name ?? "チーム未設定")
        }
        if let half = filter.half { parts.append(half == 0 ? "前半" : "後半") }
        if !filter.category.isEmpty { parts.append(definitions.first { $0.category == filter.category }?.title ?? filter.category) }
        if filter.player == "unset" { parts.append("選手未設定") }
        else if let player = players.first(where: { $0.id.uuidString == filter.player }) {
            parts.append(playerLabel(player, match: match, lineups: lineups, teams: teams))
        }
        if !filter.outcome.isEmpty { parts.append(filter.outcome == "success" ? "成功" : "失敗") }
        if (0...3).contains(filter.zoneRow) { parts.append(["敵陣", "中央エリア", "自陣", "場所未入力"][filter.zoneRow]) }
        if (0...2).contains(filter.zoneColumn) { parts.append(["左レーン", "中央レーン", "右レーン"][filter.zoneColumn]) }
        if filter.origin == "unset" { parts.append("起点未設定") }
        else if let origin = PlayOrigin(rawValue: filter.origin) { parts.append(origin.displayName) }
        let lower = RecordingAnalysisFilter.seconds(from: filter.startTime)
        let upper = RecordingAnalysisFilter.seconds(from: filter.endTime)
        if lower != nil || upper != nil {
            parts.append((lower.map { RecordingFormatting.time(Double($0)) } ?? "開始") + "〜" +
                         (upper.map { RecordingFormatting.time(Double($0)) } ?? "終了"))
        }
        return parts.joined(separator: " · ")
    }
}
