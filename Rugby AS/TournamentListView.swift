//
//  TournamentListView.swift
//  Rugby AS
//
//  大会の一覧。チーム一覧と同じ流儀で、最初はフォルダ(男女・カテゴリー・人数の自動フォルダと
//  シリーズ)を並べ、タップでフォルダの中を年度ごとに開く。フォルダの決め方は TournamentFolders.swift。
//  追加(右上の＋)とスワイプ削除ができる。試合が登録されている大会は、消える件数を確認する画面を出してから
//  試合・記録ごとまとめて削除する(間違えて取り込んだ大会を片付けるため)。
//  各行の共有ボタンから、その大会の全試合CSVも書き出せる。
//

import CoreTransferable
import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

// 共有シートに渡す「大会CSVのもと」。共有される瞬間にデータを集めてファイル化する
struct TournamentCSVExportRequest: Transferable {
    let container: ModelContainer
    let tournamentID: UUID
    let tournamentName: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { request in
            let categoryNames = await MainActor.run { RecordingMetricCatalog.titlesByCategory }
            let worker = Task.detached(priority: .userInitiated) {
                try TournamentCSVLoader.makeFile(container: request.container,
                    tournamentID: request.tournamentID, tournamentName: request.tournamentName,
                    metricCategoryNames: categoryNames)
            }
            let file = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            try Task.checkCancellation()

            let url = FileManager.default.temporaryDirectory.appendingPathComponent(file.fileName)
            var data = Data([0xEF, 0xBB, 0xBF])
            data.append(Data(file.csvText.utf8))
            try data.write(to: url)
            return SentTransferredFile(url)
        }
    }
}

struct TournamentListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Tournament.officialName) private var tournaments: [Tournament]
    @Query private var matches: [Match]

    @State private var searchText = ""
    // 男子/女子の切り替え(空 = すべて)。次に開いたときも同じ表示にする
    @AppStorage("tournamentListGender") private var genderSelection = ""
    @State private var editingTournament: Tournament?
    @State private var tournamentPendingDeletion: Tournament?
    // 試合のある大会をまとめて削除する確認画面
    @State private var bulkDeletionTournament: Tournament?

    private var genderFilter: String? { genderSelection.isEmpty ? nil : genderSelection }

    var body: some View {
        NavigationStack {
            content
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .padContentWidth(800)
                .background(RugbyTheme.background)
                .navigationTitle("大会")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $searchText, prompt: "大会名・シリーズ・年度で検索")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("閉じる") {
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            addTournament()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("大会を追加")
                    }
                }
                .tournamentManagement(editing: $editingTournament, pending: $tournamentPendingDeletion,
                                      bulk: $bulkDeletionTournament)
        }
    }

    private var content: some View {
        // 削除した直後の描き直しで、消した大会を読まないようにする
        // (保存後の削除済みの大会はデータベースから外れている = modelContext が nil)
        let live = tournaments.filter { $0.modelContext != nil && !$0.isDeleted }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return List {
            if live.isEmpty {
                ContentUnavailableView(
                    "大会がありません",
                    systemImage: "trophy",
                    description: Text("右上の＋から大会を追加します。")
                )
                .listRowBackground(Color.clear)
            } else if !query.isEmpty {
                searchResults(live, query: query)
            } else {
                GenderSwitchSection(selection: $genderSelection)
                favoritesSection(live)
                autoFolderSection(live)
                seriesSection(live)
                uncategorizedSection(live)
            }
        }
    }

    // MARK: - お気に入り

    /// よく開く大会を一番上に横並びで出す(タップで直接大会へ)。1つもなければ出さない
    @ViewBuilder
    private func favoritesSection(_ live: [Tournament]) -> some View {
        let favorites = live.filter { $0.isFavorite && TournamentFolders.matchesGender($0, genderRaw: genderFilter) }
            .sorted { ($0.year ?? Int.min, $1.officialName) > ($1.year ?? Int.min, $0.officialName) }
        if !favorites.isEmpty {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(favorites) { tournament in
                            NavigationLink {
                                TournamentDetailView(tournament: tournament)
                            } label: {
                                FavoriteTournamentTile(tournament: tournament)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(RugbyTheme.surface)
            } header: {
                Label("お気に入り", systemImage: "star.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(RugbyTheme.textSecondary)
                    .textCase(nil)
            }
        }
    }

    // MARK: - フォルダ

    private func autoFolderSection(_ live: [Tournament]) -> some View {
        let folders = TournamentFolders.autoFolders(live, genderRaw: genderFilter)
        return Section {
            folderLink(.all, live: live)
            ForEach(folders, id: \.key) { folder in
                folderLink(.auto(folder.key), live: live)
            }
            if folders.isEmpty && genderFilter != nil {
                Text("\(RugbyGender.displayName(for: genderFilter) ?? "")の大会はまだありません")
                    .font(.subheadline)
                    .foregroundStyle(RugbyTheme.textSecondary)
                    .listRowBackground(RugbyTheme.surface)
            }
        } header: {
            DirectorySectionHeader(title: "カテゴリー")
        } footer: {
            Text("大会の設定(男女・カテゴリー・人数)で自動的に分かれます。")
        }
    }

    @ViewBuilder
    private func seriesSection(_ live: [Tournament]) -> some View {
        let folders = TournamentFolders.seriesFolders(live, genderRaw: genderFilter)
        Section {
            if folders.isEmpty {
                Text("まだありません")
                    .font(.subheadline)
                    .foregroundStyle(RugbyTheme.textSecondary)
                    .listRowBackground(RugbyTheme.surface)
            }
            ForEach(folders, id: \.name) { folder in
                folderLink(.series(folder.name), live: live)
            }
        } header: {
            DirectorySectionHeader(title: "シリーズ")
        } footer: {
            Text("大会の設定でシリーズ名を付けると、同じシリーズの大会(各戦・各年度)がここにまとまります。大会を右にスワイプするとお気に入りになり、この一覧の一番上に並びます。")
        }
    }

    @ViewBuilder
    private func uncategorizedSection(_ live: [Tournament]) -> some View {
        // 男女が分からない大会なので、男子/女子を選んでいるときは出さない
        if genderFilter == nil, !TournamentFolders.tournaments(in: .uncategorized, from: live, genderRaw: nil).isEmpty {
            Section {
                folderLink(.uncategorized, live: live)
            } footer: {
                Text("男女・カテゴリー・人数もシリーズも付いていない大会です。")
            }
        }
    }

    private func folderLink(_ folder: TournamentFolder, live: [Tournament]) -> some View {
        let count = TournamentFolders.tournaments(in: folder, from: live, genderRaw: genderFilter).count
        return NavigationLink {
            TournamentFolderView(folder: folder, genderRaw: genderFilter)
        } label: {
            DirectoryFolderRow(symbol: folder.symbol, title: folder.title, count: count, unit: "大会")
        }
        .listRowBackground(RugbyTheme.surface)
        .listRowSeparatorTint(RugbyTheme.border)
    }

    // MARK: - 検索

    @ViewBuilder
    private func searchResults(_ live: [Tournament], query: String) -> some View {
        let results = live.filter { tournament in
            tournament.officialName.localizedStandardContains(query)
                || (TournamentFolders.seriesName(of: tournament)?.localizedStandardContains(query) ?? false)
                || (TeamFolderKey(tournament: tournament)?.label.localizedStandardContains(query) ?? false)
                || TournamentFolders.yearTitle(tournament.year).localizedStandardContains(query)
        }
        if results.isEmpty {
            Section {
                ContentUnavailableView.search(text: query)
                    .listRowBackground(Color.clear)
            }
        } else {
            TournamentYearSections(tournaments: results, matches: matches,
                                   editing: $editingTournament, pending: $tournamentPendingDeletion,
                                   bulk: $bulkDeletionTournament)
        }
    }

    private func addTournament() {
        let tournament = Tournament(officialName: "新しい大会")
        modelContext.insert(tournament)
        guard AppPersistence.save(modelContext) else { return }
        editingTournament = tournament
    }
}

// MARK: - Folder contents

/// フォルダを開いた画面。中の大会を年度ごと(新しい年度が上)に並べる。
struct TournamentFolderView: View {
    let folder: TournamentFolder
    /// 一覧で選んでいた男子/女子(nil = すべて)
    let genderRaw: String?

    @Query(sort: \Tournament.officialName) private var tournaments: [Tournament]
    @Query private var matches: [Match]

    @State private var searchText = ""
    @State private var editingTournament: Tournament?
    @State private var tournamentPendingDeletion: Tournament?
    @State private var bulkDeletionTournament: Tournament?

    var body: some View {
        let live = tournaments.filter { $0.modelContext != nil && !$0.isDeleted }
        let members = TournamentFolders.tournaments(in: folder, from: live, genderRaw: genderRaw)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = query.isEmpty ? members : members.filter { $0.officialName.localizedStandardContains(query) }
        return List {
            if shown.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "大会がありません" : "大会が見つかりません",
                    systemImage: query.isEmpty ? "trophy" : "magnifyingglass",
                    description: Text(query.isEmpty ? "このフォルダに入る大会はまだありません。" : "大会名を変えて検索してください。")
                )
                .listRowBackground(Color.clear)
            } else {
                TournamentYearSections(tournaments: shown, matches: matches,
                                       editing: $editingTournament, pending: $tournamentPendingDeletion,
                                       bulk: $bulkDeletionTournament)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .padContentWidth(800)
        .background(RugbyTheme.background)
        .navigationTitle(folder.title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "このフォルダの大会を検索")
        .tournamentManagement(editing: $editingTournament, pending: $tournamentPendingDeletion,
                              bulk: $bulkDeletionTournament)
    }
}

/// 大会を年度ごとの見出しで並べる(FotMob のシーズン一覧と同じ形)
private struct TournamentYearSections: View {
    let tournaments: [Tournament]
    let matches: [Match]
    @Binding var editing: Tournament?
    @Binding var pending: Tournament?
    @Binding var bulk: Tournament?

    // 大会ごとの試合数と最新の試合日は、試合が変わったときだけ数える(試合が2万あるため)
    @State private var matchCounts: [UUID: Int] = [:]
    @State private var latestMatch: [UUID: Date] = [:]
    @State private var dataRevision = 0

    private struct CountKey: Equatable { let matches: Int; let revision: Int }

    var body: some View {
        sections
            .onChange(of: CountKey(matches: matches.count, revision: dataRevision), initial: true) { _, _ in
                let liveMatches = matches.filter { $0.modelContext != nil }
                matchCounts = Dictionary(grouping: liveMatches, by: \.tournamentID).mapValues(\.count)
                latestMatch = TournamentFolders.latestMatchDates(liveMatches)
            }
            .onReceive(ModelSaveSignal.didSave) { _ in dataRevision += 1 }
    }

    @ViewBuilder private var sections: some View {
        let groups = TournamentFolders.byYear(tournaments, latestMatch: latestMatch)
        ForEach(groups, id: \.year) { group in
            Section {
                ForEach(group.tournaments) { tournament in
                    TournamentDirectoryRow(
                        tournament: tournament,
                        matchCount: matchCounts[tournament.id] ?? 0,
                        onEdit: { editing = tournament },
                        onDelete: {
                            // 試合のある大会は、消える件数を確かめる画面を出してからまとめて消す
                            if (matchCounts[tournament.id] ?? 0) > 0 { bulk = tournament } else { pending = tournament }
                        }
                    )
                }
            } header: {
                HStack {
                    DirectorySectionHeader(title: TournamentFolders.yearTitle(group.year))
                    Spacer()
                    Text("\(group.tournaments.count)大会")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(RugbyTheme.textSecondary)
                }
            }
        }
    }
}

// MARK: - Rows

/// 大会の行(ロゴ・正式名称・区分・チーム数と試合数)。タップで大会の画面へ。
private struct TournamentDirectoryRow: View {
    @Environment(\.modelContext) private var modelContext
    let tournament: Tournament
    let matchCount: Int
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        // 消した直後に古い行が一度だけ描き直されることがあるので、外れた大会は描かない
        if tournament.modelContext != nil && !tournament.isDeleted {
            row
        }
    }

    private var detailText: String {
        let parts = [TeamFolderKey(tournament: tournament)?.label,
                     "\(tournament.teamIDs.count)チーム・\(matchCount)試合"]
        return parts.compactMap { $0 }.joined(separator: "  ")
    }

    private var row: some View {
        NavigationLink {
            TournamentDetailView(tournament: tournament)
        } label: {
            HStack(spacing: 12) {
                logoThumbnail

                VStack(alignment: .leading, spacing: 3) {
                    // 大会名は長く、末尾(第1戦熊谷大会 など)で見分けることが多いので3行まで出す
                    (Text(tournament.officialName)
                        + (tournament.isFavorite ? Text(" \(Image(systemName: "star.fill"))").foregroundColor(.orange) : Text("")))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(RugbyTheme.textPrimary)
                        .lineLimit(3)
                    Text(detailText)
                        .font(.caption)
                        .foregroundStyle(RugbyTheme.textSecondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 4)

                Button(action: onEdit) {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(RugbyTheme.textSecondary)
                        .frame(width: 32, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("大会を編集")
            }
            .padding(.vertical, 2)
        }
        .listRowBackground(RugbyTheme.surface)
        .listRowSeparatorTint(RugbyTheme.border)
        .contextMenu {
            Button(action: toggleFavorite) {
                Label(tournament.isFavorite ? "お気に入りから外す" : "お気に入りに追加",
                      systemImage: tournament.isFavorite ? "star.slash" : "star")
            }
            Button(action: onEdit) { Label("大会を編集", systemImage: "slider.horizontal.3") }
            Button(role: .destructive, action: onDelete) {
                Label(matchCount > 0 ? "試合ごと大会を削除…" : "大会を削除", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            Button(action: toggleFavorite) {
                Label(tournament.isFavorite ? "お気に入りから外す" : "お気に入り",
                      systemImage: tournament.isFavorite ? "star.slash" : "star")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("削除", role: .destructive, action: onDelete)
            Button("編集", action: onEdit)
                .tint(.blue)
        }
    }

    private func toggleFavorite() {
        tournament.isFavorite.toggle()
        AppPersistence.save(modelContext)
    }

    private var logoThumbnail: some View {
        StoredImageView(name: tournament.logoPath, maxDimension: 128) { image in
            image
                .resizable()
                .scaledToFill()
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } placeholder: {
            Image(systemName: "trophy.fill")
                .font(.system(size: 17))
                .foregroundStyle(.yellow)
                .frame(width: 40, height: 40)
                .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityHidden(true)
    }
}

/// お気に入りの大会(ロゴと名前のタイル)
private struct FavoriteTournamentTile: View {
    let tournament: Tournament

    var body: some View {
        VStack(spacing: 6) {
            StoredImageView(name: tournament.logoPath, maxDimension: 180) { image in
                image
                    .resizable()
                    .scaledToFit()
                    .padding(6)
            } placeholder: {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.yellow)
            }
            .frame(width: 58, height: 58)
            .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            .accessibilityHidden(true)

            // 同じシリーズの大会は名前の頭が同じなので、見分けがつく末尾(第3戦北九州大会 など)を残して頭を省く
            Text(tournament.officialName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(RugbyTheme.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .truncationMode(.head)
                .frame(width: 96)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("お気に入り、\(tournament.officialName)")
    }
}

extension TournamentFolder {
    var symbol: String {
        switch self {
        case .all: return "square.stack.3d.up.fill"
        case .auto: return "folder.fill"
        case .series: return "rectangle.stack"
        case .uncategorized: return "tray"
        }
    }
}

// MARK: - Edit / delete

/// 大会の編集シートと削除の確認(一覧とフォルダの画面で共通)
private struct TournamentManagementFlow: ViewModifier {
    @Environment(\.modelContext) private var modelContext
    @Binding var editing: Tournament?
    @Binding var pending: Tournament?
    @Binding var bulk: Tournament?

    func body(content: Content) -> some View {
        content
            .sheet(item: $editing) { tournament in
                TournamentEditorView(tournament: tournament)
            }
            .confirmationDialog(
                "この大会を削除しますか？",
                isPresented: Binding(
                    get: { pending != nil },
                    set: { if !$0 { pending = nil } }
                ),
                presenting: pending,
                actions: { tournament in
                    Button("削除する", role: .destructive) {
                        delete(tournament)
                        pending = nil
                    }
                    Button("キャンセル", role: .cancel) {
                        pending = nil
                    }
                },
                message: { tournament in
                    Text("大会「\(tournament.officialName)」を削除します。")
                }
            )
            .sheet(item: $bulk) { tournament in
                TournamentDeletionSheet(tournament: tournament)
            }
    }

    private func delete(_ tournament: Tournament) {
        let logo = tournament.logoPath
        AppPersistence.transaction(modelContext, mutation: {
            let id = tournament.id
            guard try modelContext.fetch(FetchDescriptor<Match>(predicate: #Predicate { $0.tournamentID == id })).isEmpty else {
                throw RecordingWidgetError.invalid("試合がある大会は削除できません。")
            }
            modelContext.delete(tournament)
        }, afterSave: {
            SafeDeletion.removeUnreferencedImages([logo].compactMap { $0 }, context: modelContext,
                remove: { ImageStorage.delete(named: $0) })
        })
    }
}

private extension View {
    func tournamentManagement(editing: Binding<Tournament?>, pending: Binding<Tournament?>,
                              bulk: Binding<Tournament?>) -> some View {
        modifier(TournamentManagementFlow(editing: editing, pending: pending, bulk: bulk))
    }
}

#Preview {
    TournamentListView()
        .modelContainer(for: [
            Team.self,
            Player.self,
            Tournament.self,
            Match.self,
            StatEvent.self,
            MatchLineup.self,
            Substitution.self
        ], inMemory: true)
}
