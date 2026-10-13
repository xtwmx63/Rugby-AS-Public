// TeamViews.swift から分割
//
// チーム一覧。チームが増えても探しやすいよう、最初はフォルダを並べ、タップでフォルダの中を開く。
// フォルダの決め方は TeamFolders.swift。検索するとフォルダに関係なく全チームから探す。

import SwiftData
import SwiftUI

// MARK: - Team list

struct TeamListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Team.name) private var teams: [Team]
    // フォルダ分け(出場した大会の男女・カテゴリー・人数)に使う
    @Query private var matches: [Match]
    @Query private var tournaments: [Tournament]

    @State private var teamPendingDeletion: Team?
    @State private var deletionBlockedTeam: Team?
    @State private var searchText = ""
    @State private var selectedTeam: Team?
    // 男子/女子の切り替え(空 = すべて)。次に開いたときも同じ表示にする
    @AppStorage("teamListGender") private var genderSelection = ""
    // マイフォルダを新しく作る: 名前を聞いてから、入れるチームを選ぶ
    @State private var isNamingNewFolder = false
    @State private var newFolderName = ""
    @State private var pickingFolderName: String?

    private var genderFilter: String? { genderSelection.isEmpty ? nil : genderSelection }

    private var trimmedSearch: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    // どのチームがどのフォルダに入るかは、試合や大会が変わったときだけ数える
    // (試合が2万あるので、検索の1文字ごとに数え直すと重い)
    @State private var folderIndex: TeamFolderIndex?
    @State private var dataRevision = 0

    private struct IndexKey: Equatable { let matches: Int; let tournaments: Int; let revision: Int }

    // 長い画面定義に修飾を足すとビルドが極端に遅くなるため、外側で包む
    var body: some View {
        content(folderIndex ?? TeamFolderIndex(matches: [], tournaments: []))
            .onChange(of: IndexKey(matches: matches.count, tournaments: tournaments.count, revision: dataRevision), initial: true) { _, _ in
                folderIndex = TeamFolderIndex(matches: matches, tournaments: tournaments)
            }
            .onReceive(ModelSaveSignal.didSave) { _ in dataRevision += 1 }
    }

    private func content(_ index: TeamFolderIndex) -> some View {
        List {
            headingSection

            if teams.isEmpty {
                emptySection
            } else if !trimmedSearch.isEmpty {
                searchResultsSection(index)
            } else {
                GenderSwitchSection(selection: $genderSelection)
                favoritesSection(index)
                autoFolderSection(index)
                myFolderSection(index)
                uncategorizedSection(index)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .padContentWidth(800)
        .background(RugbyTheme.background)
        .navigationTitle("チーム")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "チーム名・フォルダ名で検索")
        .navigationDestination(item: $selectedTeam) { team in
            TeamEditorView(team: team)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    addTeam()
                } label: {
                    Image(systemName: "plus")
                        .fontWeight(.semibold)
                }
                .tint(RugbyTheme.accent)
                .accessibilityLabel("チームを追加")
            }
        }
        .teamDeletionFlow(pending: $teamPendingDeletion, blocked: $deletionBlockedTeam)
        .alert("新しいマイフォルダ", isPresented: $isNamingNewFolder) {
            TextField("例: 今季の対戦相手 / 関東", text: $newFolderName)
            Button("次へ") {
                let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { pickingFolderName = trimmed }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("次の画面で、このフォルダに入れるチームを選びます。")
        }
        .sheet(item: Binding(
            get: { pickingFolderName.map(FolderNameItem.init) },
            set: { pickingFolderName = $0?.name }
        )) { item in
            TeamFolderMemberPicker(folderName: item.name)
        }
    }

    // MARK: - 見出し

    private var headingSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                RugbyScreenHeading(
                    eyebrow: "TEAM DIRECTORY",
                    title: "チーム",
                    subtitle: "選手名簿とチーム情報を管理。"
                )

                HStack(spacing: 8) {
                    Text("\(teams.count)チーム登録済み")
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(RugbyTheme.textSecondary)
                    Spacer()
                    // 同じチーム・同じ選手が2つに分かれていないかを確かめる
                    NavigationLink {
                        DuplicateCandidatesView()
                    } label: {
                        Label("重複の候補", systemImage: "arrow.triangle.merge")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(RugbyTheme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
            .listRowInsets(EdgeInsets(top: 12, leading: 4, bottom: 4, trailing: 4))
            .listRowBackground(Color.clear)
        }
    }

    private var emptySection: some View {
        Section {
            VStack(spacing: 20) {
                RugbyEmptyState(
                    symbol: "person.3.fill",
                    title: "チームを登録しましょう",
                    message: "自チームも対戦相手もここで管理。選手の名前や写真は、後から追加できます。"
                )
                Button(action: addTeam) {
                    Label("最初のチームを追加", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(RugbyTheme.accent)
                .foregroundStyle(RugbyTheme.onAccent)
            }
            .padding(.vertical, 12)
            .listRowBackground(RugbyTheme.surface)
        }
    }

    // MARK: - お気に入り

    /// よく開くチームを一番上に横並びで出す(タップで直接チームへ)。1つもなければ出さない
    @ViewBuilder
    private func favoritesSection(_ index: TeamFolderIndex) -> some View {
        let favorites = teams.filter { $0.isFavorite && index.matchesGender($0, genderRaw: genderFilter) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !favorites.isEmpty {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(favorites) { team in
                            NavigationLink {
                                TeamEditorView(team: team)
                            } label: {
                                FavoriteTeamTile(team: team)
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

    private func autoFolderSection(_ index: TeamFolderIndex) -> some View {
        let folders = index.autoFolders(teams: teams, genderRaw: genderFilter)
        return Section {
            folderLink(.all, index: index)
            ForEach(folders, id: \.key) { folder in
                folderLink(.auto(folder.key), index: index)
            }
            if folders.isEmpty && genderFilter != nil {
                Text("\(RugbyGender.displayName(for: genderFilter) ?? "")の大会に出たチームはまだありません")
                    .font(.subheadline)
                    .foregroundStyle(RugbyTheme.textSecondary)
                    .listRowBackground(RugbyTheme.surface)
            }
        } header: {
            DirectorySectionHeader(title: "大会のカテゴリー")
        } footer: {
            Text("出場した大会の男女・カテゴリー・人数で自動的に分かれます。分け方は大会の設定で変えられます。")
        }
    }

    @ViewBuilder
    private func myFolderSection(_ index: TeamFolderIndex) -> some View {
        let folders = index.myFolders(teams: teams, genderRaw: genderFilter)
        Section {
            if folders.isEmpty {
                Text("まだありません")
                    .font(.subheadline)
                    .foregroundStyle(RugbyTheme.textSecondary)
                    .listRowBackground(RugbyTheme.surface)
            }
            ForEach(folders, id: \.name) { folder in
                folderLink(.mine(folder.name), index: index)
            }
        } header: {
            HStack {
                DirectorySectionHeader(title: "マイフォルダ")
                Spacer()
                Button {
                    newFolderName = ""
                    isNamingNewFolder = true
                } label: {
                    Label("新しいフォルダ", systemImage: "folder.badge.plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(RugbyTheme.accent)
                }
                .textCase(nil)
            }
        } footer: {
            Text("よく見るチームを自由な名前でまとめられます(1チーム1つ)。チーム画面右上の☆でお気に入りにすると、この一覧の一番上に並びます。")
        }
    }

    @ViewBuilder
    private func uncategorizedSection(_ index: TeamFolderIndex) -> some View {
        // 男女が分からないチームなので、男子/女子を選んでいるときは出さない
        if genderFilter == nil, !index.teams(in: .uncategorized, from: teams, genderRaw: nil).isEmpty {
            Section {
                folderLink(.uncategorized, index: index)
            } footer: {
                Text("男女・カテゴリー・人数の付いた大会に出ておらず、マイフォルダにも入っていないチームです。")
            }
        }
    }

    private func folderLink(_ folder: TeamFolder, index: TeamFolderIndex) -> some View {
        let members = index.teams(in: folder, from: teams, genderRaw: genderFilter)
        return NavigationLink {
            TeamFolderView(folder: folder, genderRaw: genderFilter)
        } label: {
            TeamFolderRow(folder: folder, teams: members)
        }
        .listRowBackground(RugbyTheme.surface)
        .listRowSeparatorTint(RugbyTheme.border)
    }

    // MARK: - 検索

    @ViewBuilder
    private func searchResultsSection(_ index: TeamFolderIndex) -> some View {
        let query = trimmedSearch
        let results = teams.filter { team in
            team.name.localizedStandardContains(query)
                || team.aliases.contains { $0.localizedStandardContains(query) }
                || (TeamFolderIndex.myFolderName(of: team)?.localizedStandardContains(query) ?? false)
                || index.keys(for: team.id).contains { $0.label.localizedStandardContains(query) }
        }
        Section {
            if results.isEmpty {
                VStack(spacing: 12) {
                    RugbyEmptyState(
                        symbol: "magnifyingglass",
                        title: "チームが見つかりません",
                        message: "チーム名やフォルダ名を変えて検索してください。"
                    )
                    Button("検索をクリア") { searchText = "" }
                        .font(.subheadline.weight(.semibold))
                        .tint(RugbyTheme.accent)
                        .padding(.bottom, 12)
                }
                .listRowBackground(RugbyTheme.surface)
            } else {
                ForEach(results) { team in
                    TeamDirectoryRow(team: team, summary: index.summary(for: team.id))
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("削除", role: .destructive) {
                                TeamDeletion.request(team, context: modelContext,
                                                     pending: &teamPendingDeletion, blocked: &deletionBlockedTeam)
                            }
                        }
                }
            }
        } header: {
            DirectorySectionHeader(title: "検索結果 \(results.count)チーム")
        }
    }

    // MARK: - 追加

    private func addTeam() {
        let team = Team(name: "新しいチーム")
        modelContext.insert(team)
        for number in 1...15 {
            modelContext.insert(Player(teamID: team.id, number: number))
        }
        guard AppPersistence.save(modelContext) else { return }
        searchText = ""
        selectedTeam = team
    }
}

// MARK: - Folder contents

/// フォルダを開いた画面。中のチームを名前順に並べる。
struct TeamFolderView: View {
    /// マイフォルダは名前を変えられるので、開いている間の名前をここで持つ
    @State private var folder: TeamFolder
    /// 一覧で選んでいた男子/女子(nil = すべて)
    let genderRaw: String?

    init(folder: TeamFolder, genderRaw: String?) {
        _folder = State(initialValue: folder)
        self.genderRaw = genderRaw
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Team.name) private var teams: [Team]
    @Query private var matches: [Match]
    @Query private var tournaments: [Tournament]

    @State private var searchText = ""
    @State private var teamPendingDeletion: Team?
    @State private var deletionBlockedTeam: Team?
    @State private var isPickingMembers = false
    @State private var isRenaming = false
    @State private var renameDraft = ""
    @State private var isConfirmingRemoval = false

    private var myFolderName: String? {
        if case .mine(let name) = folder { return name }
        return nil
    }

    private var isMyFolder: Bool { myFolderName != nil }

    // フォルダの中身は、試合や大会が変わったときだけ数える(試合が2万あるので、検索の1文字ごとには数えない)
    @State private var folderIndex: TeamFolderIndex?
    @State private var dataRevision = 0

    private struct IndexKey: Equatable { let matches: Int; let tournaments: Int; let revision: Int }

    // 長い画面定義に修飾を足すとビルドが極端に遅くなるため、外側で包む
    var body: some View {
        content(folderIndex ?? TeamFolderIndex(matches: [], tournaments: []))
            .onChange(of: IndexKey(matches: matches.count, tournaments: tournaments.count, revision: dataRevision), initial: true) { _, _ in
                folderIndex = TeamFolderIndex(matches: matches, tournaments: tournaments)
            }
            .onReceive(ModelSaveSignal.didSave) { _ in dataRevision += 1 }
    }

    private func content(_ index: TeamFolderIndex) -> some View {
        let members = index.teams(in: folder, from: teams, genderRaw: genderRaw)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = query.isEmpty ? members : members.filter { $0.name.localizedStandardContains(query) }
        return List {
            Section {
                if shown.isEmpty {
                    RugbyEmptyState(
                        symbol: query.isEmpty ? "folder" : "magnifyingglass",
                        title: query.isEmpty ? "チームがありません" : "チームが見つかりません",
                        message: query.isEmpty ? "このフォルダに入るチームはまだありません。" : "チーム名を変えて検索してください。"
                    )
                    .listRowBackground(RugbyTheme.surface)
                }
                ForEach(shown) { team in
                    TeamDirectoryRow(team: team, summary: index.summary(for: team.id))
                        .listRowBackground(RugbyTheme.surface)
                        .listRowSeparatorTint(RugbyTheme.border)
                        .swipeActions(edge: .leading) {
                            Button {
                                team.isFavorite.toggle()
                                AppPersistence.save(modelContext)
                            } label: {
                                Label(team.isFavorite ? "お気に入りから外す" : "お気に入り",
                                      systemImage: team.isFavorite ? "star.slash" : "star")
                            }
                            .tint(.orange)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("削除", role: .destructive) {
                                TeamDeletion.request(team, context: modelContext,
                                                     pending: &teamPendingDeletion, blocked: &deletionBlockedTeam)
                            }
                        }
                }
            } header: {
                HStack {
                    Text("\(members.count)チーム")
                    Spacer()
                    // 自動フォルダは名前に男女が入っているので、すべて・マイフォルダのときだけ断る
                    if let gender = RugbyGender.displayName(for: genderRaw), folder == .all || isMyFolder {
                        Text("\(gender)のみ表示")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(RugbyTheme.textSecondary)
                .textCase(nil)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .padContentWidth(800)
        .background(RugbyTheme.background)
        .navigationTitle(folder.title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "このフォルダのチームを検索")
        .teamDeletionFlow(pending: $teamPendingDeletion, blocked: $deletionBlockedTeam)
        .toolbar {
            if let name = myFolderName {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { isPickingMembers = true } label: {
                            Label("チームを入れる・外す", systemImage: "checklist")
                        }
                        Button {
                            renameDraft = name
                            isRenaming = true
                        } label: {
                            Label("名前を変更", systemImage: "pencil")
                        }
                        Button(role: .destructive) { isConfirmingRemoval = true } label: {
                            Label("フォルダを削除", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("マイフォルダの操作")
                }
            }
        }
        .sheet(isPresented: $isPickingMembers) {
            if let name = myFolderName { TeamFolderMemberPicker(folderName: name) }
        }
        .alert("フォルダの名前", isPresented: $isRenaming) {
            TextField("フォルダの名前", text: $renameDraft)
            Button("保存") {
                guard let name = myFolderName,
                      TeamFolderEditing.rename(name, to: renameDraft, teams: teams, context: modelContext) else { return }
                folder = .mine(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            Button("キャンセル", role: .cancel) {}
        }
        .confirmationDialog("「\(folder.title)」を削除しますか？", isPresented: $isConfirmingRemoval, titleVisibility: .visible) {
            Button("フォルダを削除", role: .destructive) {
                guard let name = myFolderName,
                      TeamFolderEditing.remove(name, teams: teams, context: modelContext) else { return }
                dismiss()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("フォルダだけを削除します。中のチームや選手は消えません。")
        }
    }
}

/// sheet(item:) に渡すための、フォルダ名の入れ物
private struct FolderNameItem: Identifiable {
    let name: String
    var id: String { name }
}

// MARK: - Rows

/// お気に入りのチーム(ロゴと名前のタイル)
private struct FavoriteTeamTile: View {
    let team: Team

    var body: some View {
        VStack(spacing: 6) {
            StoredImageView(name: team.logoPath, maxDimension: 180) { image in
                image
                    .resizable()
                    .scaledToFit()
                    .padding(6)
            } placeholder: {
                Image(systemName: "shield.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(14)
                    .foregroundStyle(team.displayColor)
            }
            .frame(width: 58, height: 58)
            .background(team.displayColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            .accessibilityHidden(true)

            Text(team.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(RugbyTheme.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(width: 76)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("お気に入り、\(team.name)")
    }
}

/// フォルダの行。中のチームの色を小さく重ねて見せ、どんなチームが入っているか分かるようにする。
struct TeamFolderRow: View {
    let folder: TeamFolder
    let teams: [Team]

    private var symbol: String {
        switch folder {
        case .all: return "square.stack.3d.up.fill"
        case .auto: return "folder.fill"
        case .mine: return "folder"
        case .uncategorized: return "tray"
        }
    }

    var body: some View {
        DirectoryFolderRow(symbol: symbol, title: folder.title, count: teams.count, unit: "チーム",
                           previewColors: teams.prefix(4).map(\.displayColor))
    }
}

/// チームの行(ロゴ・名前・出場した大会の区分)。タップでチームの画面へ。
struct TeamDirectoryRow: View {
    let team: Team
    /// 例: 「女子・トップ・7人制」。大会の情報がなければ nil
    let summary: String?

    var body: some View {
        NavigationLink {
            TeamEditorView(team: team)
        } label: {
            HStack(spacing: 12) {
                thumbnail
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(team.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(RugbyTheme.textPrimary)
                        if team.isFavorite {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .accessibilityLabel("お気に入り")
                        }
                    }
                    Text(summary.map { "出場: " + $0 } ?? "選手名簿・チーム情報")
                        .font(.caption)
                        .foregroundStyle(RugbyTheme.textSecondary)
                        .lineLimit(2)
                }
                .padding(.vertical, 2)
            }
            .padding(.vertical, 3)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        StoredImageView(name: team.logoPath, maxDimension: 160) { image in
            image
                .resizable()
                .scaledToFill()
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } placeholder: {
            Image(systemName: "shield.fill")
                .resizable()
                .scaledToFit()
                .padding(10)
                .frame(width: 40, height: 40)
                .foregroundStyle(accent)
                .background(accent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityHidden(true)
    }

    private var accent: Color {
        let color = team.displayColor
        return color.hsbBrightness > 0.78 ? color.withBrightness(0.65) : color
    }
}

// MARK: - Deletion

/// チームの削除。試合で使われているチームは消せないので、確認の前に調べる。
enum TeamDeletion {
    static func request(_ team: Team, context: ModelContext, pending: inout Team?, blocked: inout Team?) {
        if isUsedInAnyMatch(team, context: context) {
            blocked = team
        } else {
            pending = team
        }
    }

    static func isUsedInAnyMatch(_ team: Team, context: ModelContext) -> Bool {
        let teamID = team.id
        var descriptor = FetchDescriptor<Match>(
            predicate: #Predicate { match in
                match.homeTeamID == teamID || match.awayTeamID == teamID
            }
        )
        descriptor.fetchLimit = 1
        return ((try? context.fetch(descriptor).first) != nil)
    }
}

private struct TeamDeletionFlow: ViewModifier {
    @Environment(\.modelContext) private var modelContext
    @Binding var pending: Team?
    @Binding var blocked: Team?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "このチームを削除しますか？",
                isPresented: Binding(
                    get: { pending != nil },
                    set: { if !$0 { pending = nil } }
                ),
                presenting: pending
            ) { team in
                Button("削除する", role: .destructive) {
                    SafeDeletion.team(team, context: modelContext) { ImageStorage.delete(named: $0) }
                    pending = nil
                }
                Button("キャンセル", role: .cancel) {
                    pending = nil
                }
            } message: { team in
                Text("チーム「\(team.name)」と、所属する選手・写真をまとめて削除します。")
            }
            .alert(
                "削除できません",
                isPresented: Binding(
                    get: { blocked != nil },
                    set: { if !$0 { blocked = nil } }
                ),
                presenting: blocked
            ) { _ in
                Button("OK", role: .cancel) {
                    blocked = nil
                }
            } message: { team in
                Text("「\(team.name)」は試合で使われているため削除できません。先に該当する試合を削除してください。")
            }
    }
}

extension View {
    func teamDeletionFlow(pending: Binding<Team?>, blocked: Binding<Team?>) -> some View {
        modifier(TeamDeletionFlow(pending: pending, blocked: blocked))
    }
}
