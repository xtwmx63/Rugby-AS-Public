//
//  PersonLinkSheet.swift
//  Rugby AS
//
//  選手の編集から開く「同一人物としてつなぐ」画面。
//  別のチームに登録された同じ人(移籍・代表・国体・合同チームなど)を選んでつなぐ。
//  記録は書き換えないので、いつでも外せる。
//

import SwiftData
import SwiftUI

struct PersonLinkSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let player: Player

    @Query private var teams: [Team]
    @State private var searchText = ""
    // 選手は数万人いるので、開いたときに1回だけ読み、検索に使う名前もそのとき作っておく
    // (文字を打つたびに全選手の名前を作り直すと重いため)。つないだ・外したときは読み直す。
    @State private var allCandidates: [(player: Player, keys: [String])] = []
    @State private var linked: [Player] = []

    private func load() {
        if let personID = player.personID {
            let ownID = player.id
            linked = ((try? modelContext.fetch(FetchDescriptor<Player>(
                predicate: #Predicate { $0.personID == personID }))) ?? []).filter { $0.id != ownID }
        } else {
            linked = []
        }
        if allCandidates.isEmpty {
            let teamID = player.teamID
            let others = (try? modelContext.fetch(FetchDescriptor<Player>(
                predicate: #Predicate { $0.teamID != teamID }, sortBy: [SortDescriptor(\.name)]))) ?? []
            allCandidates = others.map { ($0, keys($0)) }
        }
    }

    /// つなげる候補: ほかのチームの選手で、まだこの人とつながっていないもの
    private var candidates: [(player: Player, keys: [String])] {
        let linkedIDs = Set(linked.map(\.id))
        return allCandidates.filter { $0.player.modelContext != nil && !linkedIDs.contains($0.player.id) }
    }

    private func keys(_ target: Player) -> [String] {
        ([target.name, target.nameKana, target.nameRoman].compactMap { $0 } + target.aliases)
            .map(OfficialRecordImporter.nameKey)
            .filter { $0.count >= 2 }
    }

    /// 名前・読み・英語表記・別名のどれかが一致する(片方がもう片方に含まれる)選手
    private var similar: [Player] {
        let mine = keys(player)
        return candidates.filter { other in
            other.keys.contains { key in mine.contains { $0 == key || $0.contains(key) || key.contains($0) } }
        }.map(\.player)
    }

    private var searchResults: [Player] {
        let key = OfficialRecordImporter.nameKey(searchText)
        guard !key.isEmpty else { return [] }
        return candidates.filter { other in
            other.keys.contains { $0.contains(key) }
                || OfficialRecordImporter.nameKey(teamName(other.player.teamID)).contains(key)
        }.map(\.player)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("移籍・代表・国体・合同チームなどで、別のチームにも登録されている同じ人をつなぎます。チームごとの登録や背番号はそのままで、個人成績では記録をまとめて「通算」と「チーム別・年度別」で見られます。いつでも外せます。")
                        .font(.footnote)
                        .foregroundStyle(RugbyTheme.textSecondary)
                }
                Section("つないでいる登録") {
                    if linked.isEmpty {
                        Text("まだつないでいません")
                            .foregroundStyle(RugbyTheme.textSecondary)
                    }
                    ForEach(linked) { other in
                        HStack {
                            playerLabel(other)
                            Spacer()
                            Button("外す", role: .destructive) {
                                PersonLink.unlink(other, context: modelContext)
                                load()
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                if searchText.isEmpty {
                    Section("同じ名前の選手（ほかのチーム）") {
                        if similar.isEmpty {
                            Text("候補はありません。下の検索で探せます。")
                                .foregroundStyle(RugbyTheme.textSecondary)
                        }
                        ForEach(similar) { candidateRow($0) }
                    }
                } else {
                    Section("検索結果") {
                        if searchResults.isEmpty {
                            Text("該当する選手がいません")
                                .foregroundStyle(RugbyTheme.textSecondary)
                        }
                        ForEach(searchResults) { candidateRow($0) }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "名前・読み・チーム名で検索")
            .navigationTitle("同一人物としてつなぐ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(RugbyTheme.background, for: .navigationBar)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                        .fontWeight(.bold)
                        .foregroundStyle(RugbyTheme.textPrimary)
                }
            }
        }
        .preferredColorScheme(.light)
        .onAppear(perform: load)
    }

    private func candidateRow(_ other: Player) -> some View {
        HStack {
            playerLabel(other)
            Spacer()
            Button("つなぐ") {
                PersonLink.link(player, with: other, context: modelContext)
                load()
            }
            .buttonStyle(.bordered)
            .tint(RugbyTheme.accent)
        }
    }

    private func playerLabel(_ other: Player) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(teams.first { $0.id == other.teamID }?.displayColor ?? RugbyTheme.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(other.rosterDisplayName)
                    .foregroundStyle(RugbyTheme.textPrimary)
                Text(teamName(other.teamID) + (other.number.map { " #\($0)" } ?? ""))
                    .font(.caption)
                    .foregroundStyle(RugbyTheme.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private func teamName(_ id: UUID) -> String {
        teams.first { $0.id == id }?.name ?? "チーム未設定"
    }
}
