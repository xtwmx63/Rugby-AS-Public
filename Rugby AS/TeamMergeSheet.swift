//
//  TeamMergeSheet.swift
//  Rugby AS
//
//  チーム設定から開く「ほかのチームをこのチームに統合」画面。
//  似た名前のチームを上に出し、選ぶと付け替わる件数を見せて確認してから統合する。
//

import SwiftData
import SwiftUI

struct TeamMergeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    /// 残す方のチーム(このチームにまとめる)
    let target: Team

    @Query(sort: \Team.name) private var allTeams: [Team]
    @State private var searchText = ""
    @State private var pending: PendingMerge?
    @State private var blockedMessage: String?
    // 出場の様子(似た名前のチームを見分ける手がかり)
    @State private var activity: [UUID: DuplicateFinder.Activity] = [:]
    @State private var tournamentNames: [UUID: String] = [:]

    private struct PendingMerge: Identifiable {
        let source: Team
        let impact: TeamMerge.Impact
        var id: UUID { source.id }
    }

    private var otherTeams: [Team] {
        allTeams.filter { $0.id != target.id }
    }

    private var searchResults: [Team] {
        let key = OfficialRecordImporter.nameKey(searchText)
        guard !key.isEmpty else { return otherTeams }
        return otherTeams.filter { team in
            ([team.name] + team.aliases).contains { OfficialRecordImporter.nameKey($0).contains(key) }
        }
    }

    /// 名前が似ているチーム(片方の名前がもう片方に含まれる。別名も見る)
    private var similarTeams: [Team] {
        let targetKeys = ([target.name] + target.aliases).map(OfficialRecordImporter.nameKey).filter { $0.count >= 2 }
        return otherTeams.filter { team in
            let keys = ([team.name] + team.aliases).map(OfficialRecordImporter.nameKey).filter { $0.count >= 2 }
            return keys.contains { key in targetKeys.contains { $0.contains(key) || key.contains($0) } }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("選んだチームの試合・選手・記録を「\(target.name)」に付け替え、選んだチームの名前は別名として残します。公式記録の取り込みでは、別名も同じチームとして扱います。")
                        .font(.footnote)
                        .foregroundStyle(RugbyTheme.textSecondary)
                }
                if searchText.isEmpty && !similarTeams.isEmpty {
                    Section("似た名前のチーム") {
                        ForEach(similarTeams) { teamRow($0) }
                    }
                }
                Section(searchText.isEmpty ? "すべてのチーム" : "検索結果") {
                    if searchResults.isEmpty {
                        Text("該当するチームがありません")
                            .foregroundStyle(RugbyTheme.textSecondary)
                    }
                    ForEach(searchResults) { teamRow($0) }
                }
            }
            .searchable(text: $searchText, prompt: "チーム名・別名で検索")
            .onAppear {
                activity = DuplicateFinder.activities(context: modelContext)
                let tournaments = (try? modelContext.fetch(FetchDescriptor<Tournament>())) ?? []
                tournamentNames = Dictionary(tournaments.map { ($0.id, $0.officialName) }, uniquingKeysWith: { first, _ in first })
            }
            .navigationTitle("\(target.name) に統合")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(RugbyTheme.background, for: .navigationBar)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                        .foregroundStyle(RugbyTheme.textPrimary)
                }
            }
            .confirmationDialog(
                "チームを統合しますか？",
                isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                titleVisibility: .visible,
                presenting: pending
            ) { merge in
                Button("「\(merge.source.name)」を統合する", role: .destructive) {
                    if TeamMerge.merge(merge.source, into: target, context: modelContext,
                                       removeImage: { ImageStorage.delete(named: $0) }) {
                        dismiss()
                    }
                }
                Button("キャンセル", role: .cancel) {}
            } message: { merge in
                Text(confirmMessage(merge))
            }
            .alert("統合できません", isPresented: Binding(get: { blockedMessage != nil }, set: { if !$0 { blockedMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(blockedMessage ?? "")
            }
        }
        .preferredColorScheme(.light)
    }

    private func teamRow(_ team: Team) -> some View {
        Button {
            choose(team)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "shield.lefthalf.filled")
                    .foregroundStyle(team.displayColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(team.name)
                        .foregroundStyle(RugbyTheme.textPrimary)
                    if !team.aliases.isEmpty {
                        Text("別名: " + team.aliases.joined(separator: "、"))
                            .font(.caption)
                            .foregroundStyle(RugbyTheme.textSecondary)
                            .lineLimit(2)
                    }
                    Text(DuplicateFinder.periodText(activity[team.id]))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(RugbyTheme.textSecondary)
                    if let tournaments = DuplicateFinder.tournamentText(activity[team.id], names: tournamentNames) {
                        Text(tournaments)
                            .font(.caption)
                            .foregroundStyle(RugbyTheme.textSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                Image(systemName: "arrow.merge")
                    .foregroundStyle(RugbyTheme.textSecondary)
            }
        }
    }

    private func choose(_ team: Team) {
        do {
            let impact = try TeamMerge.impact(of: team, into: target, context: modelContext)
            if impact.matchesBetween > 0 {
                blockedMessage = TeamMerge.MergeError.playedEachOther(impact.matchesBetween).errorDescription
            } else {
                pending = PendingMerge(source: team, impact: impact)
            }
        } catch {
            AppPersistence.report(error)
        }
    }

    private func confirmMessage(_ merge: PendingMerge) -> String {
        let impact = merge.impact
        return """
        残す: \(target.name)（\(DuplicateFinder.periodText(activity[target.id]))）
        消える: \(merge.source.name)（\(DuplicateFinder.periodText(activity[merge.source.id]))）
        試合 \(impact.matches)・選手 \(impact.players)人・記録 \(impact.events)件・メンバー表 \(impact.lineups)件・大会 \(impact.tournaments) を付け替えます。
        「\(merge.source.name)」は別名として残りますが、チームとしては消え、元に戻せません。心配なときは先に設定からバックアップを書き出してください。
        """
    }
}
