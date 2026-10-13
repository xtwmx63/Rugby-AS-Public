import SwiftData
import SwiftUI

/// 分析・集計に含める試合を、まとめて選び直す画面。
/// チェックを付けた試合が集計対象、外した試合が「集計対象外」(Match.isExcludedFromStats)。
/// 「保存」を押すまでは反映しない(途中でやめても元のまま)。
struct StatsInclusionEditor: View {
    /// 対象にする試合。nil = すべての試合
    var matchIDs: Set<UUID>? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Match.playedAt, order: .reverse) private var allMatches: [Match]
    @Query private var teams: [Team]
    @Query private var tournaments: [Tournament]
    @State private var included: Set<UUID> = []
    @State private var isPrepared = false

    private var matches: [Match] {
        guard let matchIDs else { return allMatches }
        return allMatches.filter { matchIDs.contains($0.id) }
    }

    /// 大会ごとにまとめる(新しい試合がある大会から)
    private var groups: [(tournament: Tournament?, matches: [Match])] {
        let grouped = Dictionary(grouping: matches, by: \.tournamentID)
        return grouped.map { id, items in (tournaments.first { $0.id == id }, items) }
            .sorted { ($0.matches.first?.playedAt ?? .distantPast) > ($1.matches.first?.playedAt ?? .distantPast) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("集計に含める", value: "\(included.count) / \(matches.count)試合")
                    HStack {
                        Button("すべて含める") { included = Set(matches.map(\.id)) }
                        Spacer()
                        Button("すべて外す", role: .destructive) { included = [] }
                    }
                    .buttonStyle(.borderless)
                } footer: {
                    Text("チェックを外した試合は、分析・比較、選手の個人成績、大会の順位表・ランキング、大会CSVに含めません。試合と記録は消えません。")
                }
                ForEach(groups, id: \.matches.first!.tournamentID) { group in
                    Section {
                        ForEach(group.matches) { match in
                            Button { toggle(match.id) } label: { row(match) }
                                .foregroundStyle(.primary)
                        }
                    } header: {
                        HStack {
                            Text(group.tournament?.officialName ?? "大会未設定").lineLimit(2)
                            Spacer()
                            let ids = Set(group.matches.map(\.id))
                            Button(ids.isSubset(of: included) ? "外す" : "含める") {
                                if ids.isSubset(of: included) { included.subtract(ids) } else { included.formUnion(ids) }
                            }
                            .font(.caption.weight(.semibold))
                            .textCase(nil)
                        }
                    }
                }
            }
            .navigationTitle("集計に含める試合")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.fontWeight(.bold) }
            }
            .onAppear {
                guard !isPrepared else { return }
                included = Set(matches.filter { !$0.isExcludedFromStats }.map(\.id))
                isPrepared = true
            }
        }
    }

    private func row(_ match: Match) -> some View {
        let isIncluded = included.contains(match.id)
        return HStack(spacing: 10) {
            Image(systemName: isIncluded ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isIncluded ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(match.playedAt.formatted(date: .numeric, time: .omitted))
                    .font(.caption).foregroundStyle(.secondary)
                Text(teamName(match.homeTeamID) + " vs " + teamName(match.awayTeamID))
                    .font(.subheadline).lineLimit(1)
            }
            Spacer(minLength: 0)
            if !isIncluded {
                Text("対象外").font(.caption.weight(.semibold)).foregroundStyle(.orange)
            }
        }
        .contentShape(Rectangle())
    }

    private func teamName(_ id: UUID) -> String {
        teams.first { $0.id == id }?.name ?? "チーム未設定"
    }

    private func toggle(_ id: UUID) {
        if included.contains(id) { included.remove(id) } else { included.insert(id) }
    }

    private func save() {
        // 変わる試合だけ書き換え、保存に失敗したら元に戻す
        var changed: [(Match, Bool)] = []
        for match in matches {
            let excluded = !included.contains(match.id)
            if match.isExcludedFromStats != excluded {
                changed.append((match, match.isExcludedFromStats))
                match.isExcludedFromStats = excluded
            }
        }
        guard !changed.isEmpty else { dismiss(); return }
        if AppPersistence.save(modelContext) {
            dismiss()
        } else {
            for (match, original) in changed { match.isExcludedFromStats = original }
        }
    }
}
