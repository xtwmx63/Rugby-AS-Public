//
//  PlayerMergeSheet.swift
//  Rugby AS
//
//  選手の編集から開く「同じチームのほかの選手をこの選手に統合」画面。
//  名前・読みが似た選手を上に出し、選ぶと付け替わる件数を見せて確認してから統合する。
//

import SwiftData
import SwiftUI

struct PlayerMergeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    /// 残す方の選手(この選手にまとめる)
    let target: Player
    /// 統合できたら呼ぶ(編集画面の入力欄を読み直すため)
    var onMerged: () -> Void = {}

    // 同じチームの選手だけを読む(全選手は数万人いるため)
    @Query private var allPlayers: [Player]
    @State private var searchText = ""
    @State private var pending: PendingMerge?
    @State private var blockedMessage: String?
    // 出場の様子(同姓同名でもどちらがどちらか分かるように、背番号と並べて出す)
    @State private var activity: [UUID: DuplicateFinder.Activity] = [:]
    @State private var tournamentNames: [UUID: String] = [:]

    private struct PendingMerge: Identifiable {
        let source: Player
        let impact: PlayerMerge.Impact
        var id: UUID { source.id }
    }

    init(target: Player, onMerged: @escaping () -> Void = {}) {
        self.target = target
        self.onMerged = onMerged
        let teamID = target.teamID
        _allPlayers = Query(filter: #Predicate<Player> { $0.teamID == teamID }, sort: [SortDescriptor(\Player.number)])
    }

    private var teammates: [Player] {
        allPlayers.filter { $0.teamID == target.teamID && $0.id != target.id }
    }

    private func keys(_ player: Player) -> [String] {
        ([player.name, player.nameKana].compactMap { $0 } + player.aliases)
            .map(OfficialRecordImporter.nameKey)
            .filter { $0.count >= 2 }
    }

    /// 名前・読み・別名の片方がもう片方に含まれる選手
    private var similarPlayers: [Player] {
        let targetKeys = keys(target)
        return teammates.filter { player in
            keys(player).contains { key in targetKeys.contains { $0.contains(key) || key.contains($0) } }
        }
    }

    private var searchResults: [Player] {
        let key = OfficialRecordImporter.nameKey(searchText)
        guard !key.isEmpty else { return teammates }
        return teammates.filter { player in
            keys(player).contains { $0.contains(key) } || player.number.map(String.init) == searchText
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("この選手（残す方）") {
                    playerDetails(target)
                }
                Section {
                    Text("誤字や苗字が変わったなどで、同じ選手が2人に分かれてしまったときに使います。選んだ選手の記録・メンバー表・交代を「\(target.rosterDisplayName)」に付け替え、選んだ選手の名前は別名として残します。別のチームの同じ人(移籍・代表など)は、ここでは統合しません。")
                        .font(.footnote)
                        .foregroundStyle(RugbyTheme.textSecondary)
                }
                if searchText.isEmpty && !similarPlayers.isEmpty {
                    Section("似た名前の選手") {
                        ForEach(similarPlayers) { playerRow($0) }
                    }
                }
                Section(searchText.isEmpty ? "同じチームの選手" : "検索結果") {
                    if searchResults.isEmpty {
                        Text("該当する選手がいません")
                            .foregroundStyle(RugbyTheme.textSecondary)
                    }
                    ForEach(searchResults) { playerRow($0) }
                }
            }
            .searchable(text: $searchText, prompt: "名前・読み・背番号で検索")
            .onAppear {
                activity = DuplicateFinder.activities(context: modelContext)
                let tournaments = (try? modelContext.fetch(FetchDescriptor<Tournament>())) ?? []
                tournamentNames = Dictionary(tournaments.map { ($0.id, $0.officialName) }, uniquingKeysWith: { first, _ in first })
            }
            .navigationTitle("\(target.rosterDisplayName) に統合")
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
                "選手を統合しますか？",
                isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                titleVisibility: .visible,
                presenting: pending
            ) { merge in
                Button("「\(merge.source.rosterDisplayName)\(merge.source.number.map { " #\($0)" } ?? "")」を統合する", role: .destructive) {
                    if PlayerMerge.merge(merge.source, into: target, context: modelContext,
                                         removeImage: { ImageStorage.delete(named: $0) }) {
                        onMerged()
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

    private func playerRow(_ player: Player) -> some View {
        Button {
            choose(player)
        } label: {
            HStack(spacing: 12) {
                Text(player.number.map { "#\($0)" } ?? "—")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(RugbyTheme.textSecondary)
                    .frame(width: 44, alignment: .leading)
                playerDetails(player, showsNumber: false)
                Spacer()
                Image(systemName: "arrow.merge")
                    .foregroundStyle(RugbyTheme.textSecondary)
            }
        }
    }

    /// 名前・読み・別名・出場の時期・大会を並べる
    private func playerDetails(_ player: Player, showsNumber: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(player.rosterDisplayName + (showsNumber ? (player.number.map { "  #\($0)" } ?? "  背番号なし") : ""))
                .foregroundStyle(RugbyTheme.textPrimary)
            let detail = ([player.nameKana, player.rugbyPosition?.name].compactMap { $0 }.filter { !$0.isEmpty }
                          + player.aliases.map { "別名: \($0)" }).joined(separator: "・")
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(RugbyTheme.textSecondary)
                    .lineLimit(2)
            }
            Text(DuplicateFinder.periodText(activity[player.id]))
                .font(.caption.monospacedDigit())
                .foregroundStyle(RugbyTheme.textSecondary)
            if let tournaments = DuplicateFinder.tournamentText(activity[player.id], names: tournamentNames) {
                Text(tournaments)
                    .font(.caption)
                    .foregroundStyle(RugbyTheme.textSecondary)
                    .lineLimit(2)
            }
        }
    }

    private func summary(_ player: Player) -> String {
        player.rosterDisplayName + (player.number.map { " #\($0)" } ?? "")
            + "（" + DuplicateFinder.periodText(activity[player.id]) + "）"
    }

    private func choose(_ player: Player) {
        do {
            let impact = try PlayerMerge.impact(of: player, into: target, context: modelContext)
            if impact.matchesTogether > 0 {
                blockedMessage = PlayerMerge.MergeError.playedTogether(impact.matchesTogether).errorDescription
            } else {
                pending = PendingMerge(source: player, impact: impact)
            }
        } catch {
            AppPersistence.report(error)
        }
    }

    private func confirmMessage(_ merge: PendingMerge) -> String {
        let impact = merge.impact
        let name = merge.source.rosterDisplayName
        return """
        残す: \(summary(target))
        消える: \(summary(merge.source))
        試合 \(impact.matches)・記録 \(impact.events)件・メンバー表 \(impact.lineups)件・交代 \(impact.substitutions)件 を付け替えます。
        「\(name)」は別名として残りますが、選手としては消え、元に戻せません。心配なときは先に設定からバックアップを書き出してください。
        """
    }
}
