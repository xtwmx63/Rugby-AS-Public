import SwiftData
import SwiftUI

/// 1つのシリーズにまとめる大会を、一覧から自分で選ぶ画面。
/// チェックした大会に同じシリーズ名を付け、外した大会からはそのシリーズ名を外す。
/// 「保存」を押すまでは反映しない。
struct SeriesMembershipEditor: View {
    /// この画面を開いた大会。最初から選んだ状態にする
    let baseTournament: Tournament

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var tournaments: [Tournament]
    @Query private var matches: [Match]
    @State private var seriesName = ""
    @State private var selected: Set<UUID> = []
    @State private var searchText = ""
    @State private var isPrepared = false
    /// 並び順は開いたときに1回だけ決める(チェックのたびに行が動くと押し間違えるため)
    @State private var order: [UUID] = []
    /// 開いたときのシリーズ名(名前を変えたとき、外した大会から古い名前も外すため)
    @State private var originalName = ""

    private var trimmedName: String { seriesName.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 最初の試合日(新しい大会から並べるため)
    private var firstDates: [UUID: Date] {
        Dictionary(matches.map { ($0.tournamentID, $0.playedAt) }, uniquingKeysWith: min)
    }

    private var sortedTournaments: [Tournament] {
        let words = searchText.split(whereSeparator: \.isWhitespace).map(String.init)
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return tournaments
            .filter { item in words.allSatisfy { item.officialName.localizedCaseInsensitiveContains($0) } }
            .sorted { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
    }

    /// 開いた時点で選ばれている大会を上に、その中は日付の新しい順
    private func makeOrder() -> [UUID] {
        let dates = firstDates
        return tournaments.sorted { lhs, rhs in
            let l = selected.contains(lhs.id), r = selected.contains(rhs.id)
            if l != r { return l }
            return (dates[lhs.id] ?? .distantPast) > (dates[rhs.id] ?? .distantPast)
        }.map(\.id)
    }

    private var existingSeriesNames: [String] {
        Array(Set(tournaments.compactMap { $0.seriesName?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })).sorted()
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("シリーズ名（例: 〇〇シリーズ2026）", text: $seriesName)
                    if !existingSeriesNames.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(existingSeriesNames, id: \.self) { name in
                                    Button(name) { useExisting(name) }
                                        .font(.caption)
                                        .buttonStyle(.bordered)
                                        .tint(trimmedName == name ? .accentColor : .secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("シリーズ名")
                } footer: {
                    Text("既存のシリーズ名を選ぶと、そのシリーズの大会が選ばれた状態になります。")
                }
                Section {
                    ForEach(sortedTournaments) { item in
                        Button { toggle(item.id) } label: { row(item) }
                            .foregroundStyle(.primary)
                    }
                } header: {
                    Text("まとめる大会（\(selected.count)大会を選択中）")
                } footer: {
                    Text("チェックした大会を1つのシリーズとして、大会画面の「シリーズ通算」で合算します。別のシリーズに入っている大会を選ぶと、このシリーズに移ります。")
                }
            }
            .searchable(text: $searchText, prompt: "大会名で探す")
            .navigationTitle("シリーズにまとめる")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .fontWeight(.bold)
                        .disabled(trimmedName.isEmpty && !selected.isEmpty)
                }
            }
            .onAppear(perform: prepare)
        }
    }

    private func row(_ item: Tournament) -> some View {
        let isSelected = selected.contains(item.id)
        let otherSeries = item.seriesName.flatMap { name -> String? in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed == trimmedName ? nil : trimmed
        }
        return HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.officialName).font(.subheadline).lineLimit(2)
                HStack(spacing: 6) {
                    if let year = item.year { Text("\(String(year))年度") }
                    Text("\(matches.count { $0.tournamentID == item.id })試合")
                    if let otherSeries { Text("現在: \(otherSeries)").lineLimit(1) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func prepare() {
        guard !isPrepared else { return }
        isPrepared = true
        let name = baseTournament.seriesName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty {
            // シリーズ未設定なら、大会名から候補を出す(例: 「…シリーズ2026 第1戦熊谷大会」→「…シリーズ2026」)
            seriesName = OfficialTournamentGrouping.seriesName(for: baseTournament.officialName) ?? ""
            selected = [baseTournament.id]
        } else {
            seriesName = name
            selected = members(of: name).union([baseTournament.id])
        }
        originalName = name
        order = makeOrder()
    }

    private func members(of name: String) -> Set<UUID> {
        let key = OfficialRecordImporter.nameKey(name)
        return Set(tournaments.filter { $0.seriesName.map(OfficialRecordImporter.nameKey) == key }.map(\.id))
    }

    private func useExisting(_ name: String) {
        seriesName = name
        selected = members(of: name).union([baseTournament.id])
    }

    private func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func save() {
        let name = trimmedName
        let keys = Set([OfficialRecordImporter.nameKey(name), OfficialRecordImporter.nameKey(originalName)]).subtracting([""])
        let original = Dictionary(uniqueKeysWithValues: tournaments.map { ($0.id, $0.seriesName) })
        for item in tournaments {
            if selected.contains(item.id) {
                item.seriesName = name.isEmpty ? nil : name
            } else if let current = item.seriesName.map(OfficialRecordImporter.nameKey), keys.contains(current) {
                // このシリーズから外した大会
                item.seriesName = nil
            }
        }
        if AppPersistence.save(modelContext) {
            dismiss()
        } else {
            for item in tournaments { item.seriesName = original[item.id] ?? nil }
        }
    }
}
