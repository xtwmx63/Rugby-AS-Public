import SwiftUI
import SwiftData
import AVFoundation

struct RecordingEventList: View {
    @ObservedObject var store: RecordingWidgetStore
    let players: [Player]
    let lineups: [MatchLineup]
    let eventIDs: [UUID]?
    @State private var selected: StatEvent?
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(displayEvents) { event in
                    Button { selected = event } label: {
                        HStack(spacing: 12) {
                            Image(systemName: eventSymbol(event)).font(.title3).foregroundStyle(eventColor(event)).frame(width: 32)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(event.recordingTitle).font(.headline)
                                Text(detailText(event)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text((event.half == 0 ? "前半 " : "後半 ") + RecordingFormatting.time(Double(event.recordingSortSeconds)))
                                .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                        .padding(12).frame(minHeight: 64)
                        .background(.white.opacity(event.recordingDetails.needsReview ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(alignment: .leading) {
                            if event.recordingDetails.needsReview { Capsule().fill(.yellow).frame(width: 4).padding(.vertical, 8) }
                        }
                    }.buttonStyle(.plain)
                }
                if displayEvents.isEmpty { ContentUnavailableView("まだ記録がありません", systemImage: "list.bullet.clipboard") }
            }.padding(.horizontal, 16).padding(.vertical, 12)
        }
        .sheet(item: $selected) { event in
            RecordingEventEditor(store: store, event: event, kind: .note, widget: nil, players: players, lineups: lineups)
        }
        .background(Color(red: 0.02, green: 0.06, blue: 0.12).ignoresSafeArea())
    }
    private var displayEvents: [StatEvent] {
        let all = store.events.filter { $0.category != "match_state" }
        guard let eventIDs else { return all.sorted { $1.isRecordedBefore($0) } }
        let wanted = Set(eventIDs)
        return all.filter { wanted.contains($0.id) }.sorted { $0.isRecordedBefore($1) }
    }
    private func eventSymbol(_ event: StatEvent) -> String {
        if event.recordingDetails.needsReview { return "flag.fill" }
        switch event.category { case "try": return "rugbyball.fill"; case "possession": return "stopwatch.fill"; case "lineout": return "arrow.up.and.down.and.sparkles"; case "scrum": return "person.3.fill"; default: return "circle.fill" }
    }
    private func eventColor(_ event: StatEvent) -> Color {
        if event.recordingDetails.needsReview { return .yellow }
        switch event.category { case "try": return .green; case "penalty", "tackle": return .orange; case "lineout": return .cyan; default: return .blue }
    }
    private func detailText(_ event: StatEvent) -> String {
        var values: [String] = []
        if let playerID = event.playerID, let player = players.first(where: { $0.id == playerID }) {
            let number = MatchNumbering.number(for: player, matchID: store.match.id, lineups: lineups).map { "\($0) " } ?? ""
            values.append(number + (player.name?.isEmpty == false ? player.name! : "名前未設定"))
        } else if event.playerID == nil && ["try", "conversion", "penalty_goal", "drop_goal"].contains(event.category) { values.append("選手未設定") }
        if let choice = event.recordingDetails.choice { values.append(choice) }
        if let zone = event.recordingDetails.zone { values.append(RecordingFormatting.zone(zone, attackUp: event.recordingDetails.attackUp)) }
        if event.recordingDetails.number != nil { values.append("\(event.recordingDetails.number!) \(event.recordingDetails.unit ?? "")") }
        if event.recordingDetails.needsReview { values.append("要確認") }
        return values.isEmpty ? outcomeLabel(event.outcome) : values.joined(separator: " · ")
    }
    private func outcomeLabel(_ outcome: String) -> String {
        switch outcome { case "success": return "成功"; case "fail": return "失敗"; case "conceded": return "反則"; default: return outcome }
    }
}

struct RecordingEventEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: RecordingWidgetStore
    let event: StatEvent
    let kind: RecordingWidgetKind
    let widget: RecordingWidgetDefinition?
    let players: [Player]
    let lineups: [MatchLineup]
    @State private var selectedPlayerID: UUID?
    @State private var playerRoster = RecordingPlayerRoster()
    @State private var showOtherPlayers = false
    let isNewEvent: Bool
    @State private var didSave = false
    @State private var numberText = ""
    @State private var choice = ""
    @State private var originSelection = ""
    @State private var zone: Int?
    @State private var attackUp = true
    @State private var needsReview = false
    @State private var note = ""
    @State private var outcome: String
    @State private var message: String?
    init(store: RecordingWidgetStore, event: StatEvent, kind: RecordingWidgetKind, widget: RecordingWidgetDefinition?, players: [Player], lineups: [MatchLineup], isNewEvent: Bool = false) {
        self.store = store; self.event = event; self.kind = kind; self.players = players; self.lineups = lineups
        self.isNewEvent = isNewEvent
        self.widget = widget ?? store.layout.widgets.first { $0.id == event.recordingDetails.widgetID }
            ?? RecordingMetricCatalog.templates.first { $0.widget.category == event.category && !$0.widget.kind.isDisplay }?.widget
        let details = event.recordingDetails
        _selectedPlayerID = State(initialValue: event.playerID)
        _numberText = State(initialValue: details.number.map { String($0) } ?? "")
        _choice = State(initialValue: details.choice ?? "")
        _originSelection = State(initialValue: event.recordingOrigin?.rawValue ?? "")
        _zone = State(initialValue: details.zone)
        _attackUp = State(initialValue: details.attackUp)
        _needsReview = State(initialValue: details.needsReview)
        _note = State(initialValue: details.note)
        _outcome = State(initialValue: event.outcome)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("記録") {
                    HStack { Image(systemName: "clock"); Text(event.recordingTitle); Spacer(); Text(RecordingFormatting.time(Double(event.seconds))).monospacedDigit() }
                }
                if isPlayerInput {
                    Section("選手") {
                        if kind == .player {
                            playerPhotoGrid
                        } else {
                            Picker("選手", selection: $selectedPlayerID) {
                                Text("選手未設定").tag(Optional<UUID>.none)
                                ForEach(eligiblePlayers) { player in
                                    Text(playerLabel(player)).tag(Optional(player.id))
                                }
                            }
                        }
                    }
                }
                if isPlayerInput && !playerRoster.others.isEmpty {
                    Section {
                        Button(showOtherPlayers ? "背番号ありの選手のみ表示" : "その他の選手を表示（\(playerRoster.others.count)人）") {
                            showOtherPlayers.toggle()
                        }
                    }
                }
                if isResultInput {
                    Section("結果") {
                        Picker("結果", selection: $outcome) { Text("成功").tag("success"); Text("失敗").tag("fail") }.pickerStyle(.segmented)
                    }
                }
                if isChoiceInput {
                    Section("内容") {
                        if let widget, !widget.choices.isEmpty {
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                                ForEach(widget.choices, id: \.self) { value in
                                    Button { choice = value } label: {
                                        Text(value).font(.subheadline).frame(maxWidth: .infinity, minHeight: 44)
                                            .background(choice == value ? Color.blue : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                        TextField("選択内容", text: $choice)
                    }
                }
                if isOriginInput {
                    Section("攻撃の起点") {
                        Picker("起点", selection: $originSelection) {
                            Text(event.origin == nil ? "未設定" : "変更しない").tag("")
                            ForEach(PlayOrigin.allCases) { origin in
                                Text(origin.displayName).tag(origin.rawValue)
                            }
                            if event.origin != nil {
                                Text("未設定に戻す").tag("__clear")
                            }
                        }
                    }
                }
                if isZoneInput {
                    Section("場所") {
                        Toggle("攻撃方向を上にする", isOn: $attackUp)
                        zonePicker
                    }
                }
                if isNumberInput {
                    Section("数値") {
                        TextField("数値", text: $numberText).keyboardType(.decimalPad)
                        if event.category == "carry_metres" {
                            Button("前進／後退（＋／−）を切り替え") {
                                numberText = numberText.hasPrefix("-") ? String(numberText.dropFirst()) : "-" + numberText
                            }
                        }
                        HStack(spacing: 8) {
                            ForEach([10, 20, 30], id: \.self) { value in
                                Button("\(value) \(effectiveNumberUnit)") { numberText = String(value) }
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(numberText == String(value) ? Color.blue : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                            }
                        }.buttonStyle(.plain)
                        Text("単位：\(effectiveNumberUnit)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if isReviewInput {
                    Section("確認") {
                        Toggle("要確認", isOn: $needsReview)
                        TextField("メモ（任意）", text: $note, axis: .vertical).lineLimit(2...5)
                    }
                }
            }
            .navigationTitle("記録を詳しくする").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
            }
            .alert("入力を確認してください", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("閉じる", role: .cancel) { message = nil } } message: { Text(message ?? "") }
        }
        .onAppear {
            if let teamID = event.teamID {
                playerRoster = RecordingPlayerRoster(players: players, teamID: teamID, matchID: store.match.id, lineups: lineups)
            }
        }
        .onDisappear {
            if isNewEvent && !didSave { _ = store.discardUnconfirmedEvent(event) }
        }
    }
    private var effectiveNumberUnit: String { event.recordingDetails.unit ?? widget?.unit ?? "" }
    private var isNumberInput: Bool { kind == .number || (kind == .note && (widget?.kind == .number || event.recordingDetails.number != nil)) }
    private var isChoiceInput: Bool {
        widget?.category != "origin" && (kind == .choice || (kind == .note && (widget?.kind == .choice || event.recordingDetails.choice != nil)))
    }
    private var isOriginInput: Bool { widget?.category == "origin" || kind == .note }
    private var isZoneInput: Bool { kind == .zone || (kind == .note && event.recordingDetails.zone != nil) }
    private var isPlayerInput: Bool { kind == .player || ["try", "conversion", "penalty_goal", "drop_goal"].contains(event.category) }
    private var isResultInput: Bool {
        kind == .result || ["lineout", "scrum", "conversion", "penalty_goal", "drop_goal"].contains(event.category)
            || RecordingMetricCatalog.templates.contains { $0.widget.category == event.category && $0.widget.kind == .result }
    }
    private var isReviewInput: Bool { kind == .note || event.recordingDetails.needsReview || needsReview }
    private var eligiblePlayers: [Player] {
        playerRoster.visiblePlayers(includeOthers: showOtherPlayers, selectedPlayerID: selectedPlayerID)
    }
    @ViewBuilder private var zonePicker: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(0..<9, id: \.self) { index in
                Button { zone = index } label: {
                    Text(RecordingFormatting.zone(index, attackUp: attackUp)).font(.subheadline).frame(maxWidth: .infinity, minHeight: 50)
                        .background(zone == index ? Color.blue : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain)
            }
        }
    }
    private var playerPhotoGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 10) {
            Button { selectedPlayerID = nil } label: {
                VStack(spacing: 5) {
                    Image(systemName: "person.crop.rectangle").font(.title2).frame(height: 56)
                    Text("未設定").font(.caption)
                }
                .frame(maxWidth: .infinity, minHeight: 92)
                .background(selectedPlayerID == nil ? Color.blue : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain)
            ForEach(eligiblePlayers) { player in
                Button { selectedPlayerID = player.id } label: {
                    VStack(spacing: 5) {
                        RecordingPlayerPhoto(player: player).frame(height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
                        Text(playerLabel(player)).font(.caption).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 92)
                    .background(selectedPlayerID == player.id ? Color.blue : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(selectedPlayerID == player.id ? .white : .clear, lineWidth: 2))
                }.buttonStyle(.plain)
            }
        }
    }
    private func playerLabel(_ player: Player) -> String {
        let number = playerRoster.number(for: player).map { "\($0) " } ?? ""
        return number + (player.name?.isEmpty == false ? player.name! : "名前未設定")
    }
    private func save() {
        var details = event.recordingDetails
        if isNewEvent && widget?.attachesToLatest != true {
            details.widgetID = widget?.id ?? details.widgetID
            details.title = widget?.title ?? details.title
        }
        if widget?.category != "origin" { details.choice = choice.isEmpty ? nil : choice }
        details.zone = zone
        details.attackUp = attackUp
        details.number = Double(numberText.replacingOccurrences(of: ",", with: "."))
        if !numberText.trimmingCharacters(in: .whitespaces).isEmpty && details.number == nil {
            message = "有効な数値を入力してください。"
            return
        }
        if isNumberInput { details.unit = effectiveNumberUnit }
        details.needsReview = needsReview
        details.note = note
        if kind == .player { details.needsReview = event.recordingDetails.needsReview; details.note = event.recordingDetails.note }
        let origin = isOriginInput ? PlayOrigin(rawValue: originSelection)?.rawValue : nil
        let clearOrigin = isOriginInput && originSelection == "__clear"
        if store.updateEvent(event, playerID: selectedPlayerID, details: details, outcome: outcome, origin: origin, clearOrigin: clearOrigin) {
            didSave = true
            dismiss()
        }
        else { message = store.error; store.error = nil }
    }
}
