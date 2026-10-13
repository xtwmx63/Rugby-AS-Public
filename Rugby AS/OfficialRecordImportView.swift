// 公式記録と同じく、許可が取れるまで配布版(Release)には入れない(OfficialRecordsView.swift の冒頭を参照)。
#if DEBUG
import SwiftData
import SwiftUI

/// 公式記録から作った下書きを確認・修正してから、自分の試合として保存する画面。
struct OfficialRecordImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var teams: [Team]
    @Query private var matches: [Match]
    @State private var draft: OfficialImportDraft
    @State private var failure: String?
    @State private var isSaved = false

    init(record: OfficialRecord) {
        _draft = State(initialValue: OfficialRecordImporter.draft(from: record))
    }

    var body: some View {
        NavigationStack {
            Form {
                matchSection
                teamSection
                scoreSection
                if !draft.members.isEmpty { lineupSection }
                if !draft.notes.isEmpty || isDuplicate { noteSection }
            }
            .navigationTitle("取り込みの確認")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(!canSave)
                }
            }
            .alert("保存できませんでした", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("閉じる", role: .cancel) { }
            } message: { Text(failure ?? "") }
            .alert("取り込みました", isPresented: $isSaved) {
                Button("閉じる") { dismiss() }
            } message: { Text("試合一覧に「終了」の試合として追加しました。プレー一覧から詳しく追記できます。") }
        }
    }

    // MARK: - 各セクション

    private var matchSection: some View {
        Section("試合") {
            LabeledContent("大会") {
                TextField("大会名", text: $draft.tournamentName).multilineTextAlignment(.trailing)
            }
            if let year = draft.year { LabeledContent("年度", value: String(year)) }
            DatePicker("日時", selection: $draft.playedAt)
        }
    }

    private var teamSection: some View {
        Section {
            teamField("HOME", name: $draft.homeTeamName)
            teamField("AWAY", name: $draft.awayTeamName)
        } header: { Text("チーム") } footer: {
            Text("同じ名前のチームが既にあれば、そのチームに記録します。")
        }
    }

    private func teamField(_ label: String, name: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(label) {
                TextField("チーム名", text: name).multilineTextAlignment(.trailing)
            }
            Text(OfficialRecordImporter.existingTeam(named: name.wrappedValue, in: teams) == nil ? "新しく作ります" : "既存のチームを使います")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var scoreSection: some View {
        Section {
            HStack {
                Text("取り込む得点")
                Spacer()
                Text("\(draft.score(side: "home")) - \(draft.score(side: "away"))").monospacedDigit().bold()
            }
            if let home = draft.officialHomeScore, let away = draft.officialAwayScore {
                Label(draft.matchesOfficialScore == true ? "公式記録のスコア（\(home) - \(away)）と一致" : "公式記録のスコアは \(home) - \(away) です",
                      systemImage: draft.matchesOfficialScore == true ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(draft.matchesOfficialScore == true ? .green : .orange)
                    .font(.subheadline)
            }
            ForEach($draft.events) { $event in
                Button { event.isIncluded.toggle() } label: { eventRow(event) }
                    .buttonStyle(.plain)
            }
        } header: { Text("得点経過（\(draft.events.count)件）") } footer: {
            Text("タップで取り込む／取り込まないを切り替えます。時刻や選手の細かい修正は、取り込み後にプレー一覧でできます。")
        }
    }

    private func eventRow(_ event: OfficialImportEvent) -> some View {
        HStack(spacing: 10) {
            Image(systemName: event.isIncluded ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(event.isIncluded ? Color.accentColor : .secondary)
            Text("\(event.half == 0 ? "前半" : "後半") \(event.minute)分").monospacedDigit()
                .frame(width: 76, alignment: .leading)
            Text(event.side == "home" ? "HOME" : "AWAY").font(.caption.bold())
                .foregroundStyle(event.side == "home" ? .blue : .red)
            Text(kindLabel(event)).font(.subheadline.bold())
            Text(event.playerName.isEmpty ? "—" : (event.playerNumber.map { "\($0) " } ?? "") + event.playerName).lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .opacity(event.isIncluded ? 1 : 0.4)
        .contentShape(Rectangle())
    }

    private var lineupSection: some View {
        Section {
            Toggle("メンバー表も取り込む", isOn: $draft.includesLineups)
            if draft.includesLineups {
                lineupCount("HOME", side: "home", teamName: draft.homeTeamName)
                lineupCount("AWAY", side: "away", teamName: draft.awayTeamName)
            }
        } header: { Text("メンバー表") } footer: {
            Text("同じチームに同じ名前の選手がいれば、その選手を使います。背番号はこの試合の番号として記録します。")
        }
    }

    private func lineupCount(_ label: String, side: String, teamName: String) -> some View {
        let members = draft.members.filter { $0.side == side }
        let team = OfficialRecordImporter.existingTeam(named: teamName, in: teams)
        // そのチームの選手だけを読む(全選手は数万人いるため)
        let teamID = team?.id
        let teamPlayers = teamID.map { id in (try? modelContext.fetch(FetchDescriptor<Player>(predicate: #Predicate { $0.teamID == id }))) ?? [] } ?? []
        let known = Set(teamPlayers.compactMap { $0.name.map(OfficialRecordImporter.nameKey) })
        let existing = members.filter { known.contains(OfficialRecordImporter.nameKey($0.name)) }.count
        return LabeledContent(label, value: "\(members.count)人（既存 \(existing)・新規 \(members.count - existing)）")
    }

    private var noteSection: some View {
        Section("確認してください") {
            if isDuplicate {
                Label("同じ日に同じ対戦の試合が既にあります。二重に取り込んでいないか確認してください。", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            ForEach(draft.notes, id: \.self) { Text($0).font(.subheadline) }
        }
    }

    // MARK: - 補助

    private var isDuplicate: Bool {
        OfficialRecordImporter.hasSameDayMatch(draft, teams: teams, matches: matches)
    }

    private var canSave: Bool {
        let home = OfficialRecordImporter.nameKey(draft.homeTeamName)
        let away = OfficialRecordImporter.nameKey(draft.awayTeamName)
        return !home.isEmpty && !away.isEmpty && home != away
    }

    private func kindLabel(_ event: OfficialImportEvent) -> String {
        let base = ScoringCategory(rawValue: event.category)?.displayName ?? event.category
        let name = event.category == "conversion" ? "ゴール" : base
        return event.outcome == "fail" ? name + "×" : name + (event.officialPoints.map { "（\($0)点）" } ?? "")
    }

    private func save() {
        do {
            try OfficialRecordImporter.save(draft, context: modelContext)
            isSaved = true
        } catch {
            failure = error.localizedDescription
        }
    }
}
#endif
