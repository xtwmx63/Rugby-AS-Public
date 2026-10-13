//
//  TeamViews.swift
//  Rugby AS
//
//  Created by Codex on 2026/05/17.
//

import CoreImage
import PhotosUI
import SwiftData
import SwiftUI
import Vision

// MARK: - Team editor / collection roster

private enum RosterFilter: String, CaseIterable, Identifiable {
    case all
    case favorites
    case hasPhoto
    case needsInput

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "すべて"
        case .favorites: "お気に入り"
        case .hasPhoto: "写真あり"
        case .needsInput: "未入力あり"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "person.3.fill"
        case .favorites: "star.fill"
        case .hasPhoto: "photo.fill"
        case .needsInput: "exclamationmark.circle.fill"
        }
    }
}

private enum RosterPositionFilter: Hashable, Identifiable {
    case all
    case forwards
    case backs
    case position(RugbyPosition)

    static let options: [RosterPositionFilter] =
        [.all, .forwards, .backs]
        + RugbyPosition.allCases
            .filter { $0 != .forward && $0 != .back }
            .map { .position($0) }

    var id: String {
        switch self {
        case .all: "all"
        case .forwards: "forwards"
        case .backs: "backs"
        case .position(let position): "position-\(position.rawValue)"
        }
    }

    var title: String {
        switch self {
        case .all: "全ポジション"
        case .forwards: "FW"
        case .backs: "BK"
        case .position(let position): position.rawValue
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .all: "全ポジション"
        case .forwards: "フォワード"
        case .backs: "バックス"
        case .position(let position): position.selectionLabel
        }
    }

    func matches(_ player: Player) -> Bool {
        guard self != .all else { return true }
        guard let position = player.rugbyPosition else { return false }

        switch self {
        case .all:
            return true
        case .forwards:
            return position.group == .forwards
        case .backs:
            return position.group == .backs
        case .position(let target):
            return position == target
        }
    }
}

extension Player {
    static let rosterProfileFieldCount = 9

    var rosterDisplayName: String {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "名前未設定" : trimmed
    }

    var rosterMissingFieldCount: Int {
        var count = 0
        if number == nil { count += 1 }
        if (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { count += 1 }
        if (nameKana ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { count += 1 }
        if (nameRoman ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { count += 1 }
        if (imagePath ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { count += 1 }
        if rugbyPosition == nil { count += 1 }
        if birthDate == nil { count += 1 }
        if heightCm == nil { count += 1 }
        if weightKg == nil { count += 1 }
        return count
    }

    var rosterProfileIsComplete: Bool {
        rosterMissingFieldCount == 0
    }
}

struct TeamEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var team: Team
    // 注意: init で絞り込み付きの @Query を作ると、選手カードから個人成績を開いたときに
    // 画面の作り直しが止まらなくなる(固まる)。かといって全選手を @Query で読むと、
    // 公式記録の取り込みで選手が4万人を超えて重い。そこで、このチームの選手だけを
    // 画面を開いたときと保存されたときに読み直す(@Query は使わない)。
    @State private var teamPlayers: [Player] = []
    @Query private var allTeams: [Team]

    @State private var logoPickerItem: PhotosPickerItem?
    @State private var isShowingLogoDeleteConfirmation = false
    @State private var isShowingColorPicker = false
    @State private var isShowingMergeSheet = false
    @State private var isAddingAlias = false
    @State private var aliasDraft = ""
    // カードをタップして開く個人成績(全画面で積む)
    @State private var detailPlayer: Player?
    @State private var editingPlayer: Player?
    @State private var queuedPlayerDeletion: Player?
    @State private var playerPendingDeletion: Player?
    @State private var deletionBlockedPlayer: Player?
    @State private var isShowingBulkKanaSheet = false
    @State private var isEditingCategory = false
    @State private var isShowingTeamSettings = false
    @State private var rosterFilter: RosterFilter = .all
    @State private var rosterPositionFilter: RosterPositionFilter = .all
    @State private var searchText = ""
    @State private var categoryDraft = ""
    @AppStorage("teamRosterColumnCount") private var rosterColumnCount = 2

    private var columns: [GridItem] {
        let count = min(3, max(2, rosterColumnCount))
        let spacing: CGFloat = count == 2 ? 12 : 8
        return Array(repeating: GridItem(.flexible(), spacing: spacing), count: count)
    }

    private var players: [Player] {
        teamPlayers
            // 消した直後(読み直す前)の選手は除く。消えた選手の値を読むとアプリが落ちるため
            .filter { $0.modelContext != nil && !$0.isDeleted && $0.teamID == team.id }
            .sorted {
                if ($0.number ?? Int.max) == ($1.number ?? Int.max) {
                    return ($0.name ?? "") < ($1.name ?? "")
                }
                return ($0.number ?? Int.max) < ($1.number ?? Int.max)
            }
    }

    private var registeredCount: Int {
        players.filter { player in
            player.imagePath != nil || !(player.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
    }

    private var visiblePlayers: [Player] {
        let query = normalizedSearchKey(searchText)

        return players.filter { player in
            let matchesQuery: Bool
            if query.isEmpty {
                matchesQuery = true
            } else {
                let searchableValues = [
                    player.number.map(String.init) ?? "",
                    player.name ?? "",
                    player.nameKana ?? "",
                    player.nameRoman ?? "",
                    player.rugbyPosition?.rawValue ?? "",
                    player.rugbyPosition?.name ?? ""
                ]
                matchesQuery = searchableValues.contains {
                    normalizedSearchKey($0).contains(query)
                }
            }

            let matchesFilter: Bool
            switch rosterFilter {
            case .all:
                matchesFilter = true
            case .favorites:
                matchesFilter = player.isFavorite
            case .hasPhoto:
                matchesFilter = player.imagePath != nil
            case .needsInput:
                matchesFilter = player.rosterMissingFieldCount > 0
            }

            return matchesQuery
                && matchesFilter
                && rosterPositionFilter.matches(player)
        }
    }

    private var completedProfileCount: Int {
        players.filter(\.rosterProfileIsComplete).count
    }

    private var duplicatedNumbers: Set<Int> {
        var seen: Set<Int> = []
        var duplicated: Set<Int> = []
        for player in players {
            guard let number = player.number else { continue }
            if !seen.insert(number).inserted { duplicated.insert(number) }
        }
        return duplicated
    }

    // チームカラー未設定なら、チームごとに決まった仮の色
    private var teamColor: Color {
        team.displayColor
    }

    // 白い画面の上で文字やアイコンに使う色(明るすぎるチームカラーは濃い文字色に)
    private var ink: Color {
        teamColor.prefersDarkText ? RugbyTheme.textPrimary : teamColor
    }

    // チームカラーで塗った面の上の文字色
    private var onTeamColor: Color {
        teamColor.prefersDarkText ? RugbyTheme.textPrimary : .white
    }

    private var selectedColorName: String {
        guard let hex = team.colorHex else { return "未設定（仮の色を表示中）" }
        return TeamColorPalette.options.first(where: { $0.hex == hex })?.name ?? hex
    }

    private func loadPlayers() {
        let teamID = team.id
        teamPlayers = (try? modelContext.fetch(FetchDescriptor<Player>(
            predicate: #Predicate { $0.teamID == teamID }, sortBy: [SortDescriptor(\.number)]))) ?? []
    }

    // 長い画面定義に修飾を足すとビルドが極端に遅くなるため、外側で包む
    var body: some View {
        content
            .onReceive(ModelSaveSignal.didSave) { _ in loadPlayers() }
    }

    private var content: some View {
        ZStack {
            RugbyTheme.background.ignoresSafeArea()

            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    rosterHeroCard
                    teamSectionNavigation

                    VStack(spacing: 18) {
                        teamSettingsDisclosure
                        rosterTitle
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 6)
                    .padContentWidth(860)

                    Section {
                        rosterContent
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padContentWidth(860)
                    } header: {
                        rosterPinnedControls
                    }
                }
                .padding(.bottom, 36)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle(team.name.isEmpty ? "チーム編集" : team.name)
        .navigationBarTitleDisplayMode(.inline)
        // ナビゲーションバーは白にして、下のチームカラーの帯とメリハリをつける
        .toolbarBackground(RugbyTheme.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.light, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    team.isFavorite.toggle()
                    AppPersistence.save(modelContext)
                } label: {
                    Image(systemName: team.isFavorite ? "star.fill" : "star")
                }
                .foregroundStyle(team.isFavorite ? Color.orange : RugbyTheme.textPrimary)
                .accessibilityLabel(team.isFavorite ? "お気に入りから外す" : "お気に入りに追加")
            }
        }
        .onAppear { loadPlayers(); ensureInitialPlayers() }
        .onChange(of: logoPickerItem) { _, newItem in
            handleSelectedLogo(newItem)
        }
        .onChange(of: team.name) { _, _ in
            guard AppPersistence.save(modelContext) else { return }
        }
        .sheet(isPresented: $isShowingMergeSheet) {
            TeamMergeSheet(target: team)
        }
        .sheet(isPresented: $isShowingColorPicker) {
            TeamColorPickerSheet(team: team)
        }
        .sheet(isPresented: $isShowingBulkKanaSheet) {
            BulkRosterInputSheet(players: players, accent: teamColor)
        }
        .navigationDestination(item: $detailPlayer) { player in
            PlayerDetailView(player: player, onRequestDelete: { player in
                queuePlayerDeletion(player)
            })
        }
        .onChange(of: detailPlayer) { _, newValue in
            // 個人成績の編集から削除を頼まれたら、チーム画面に戻ってから確認を出す
            if newValue == nil { processQueuedPlayerDeletion() }
        }
        .sheet(item: $editingPlayer, onDismiss: processQueuedPlayerDeletion) { player in
            PlayerCardEditorSheet(
                player: player,
                teamName: team.name,
                accent: teamColor,
                isNumberDuplicated: player.number.map { duplicatedNumbers.contains($0) } ?? false,
                onRequestDelete: {
                    queuePlayerDeletion(player)
                }
            )
        }
        .confirmationDialog(
            "ロゴを削除しますか？",
            isPresented: $isShowingLogoDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("削除する", role: .destructive) { deleteLogo() }
            Button("キャンセル", role: .cancel) { }
        }
        .confirmationDialog(
            "この選手を削除しますか？",
            isPresented: Binding(
                get: { playerPendingDeletion != nil },
                set: { if !$0 { playerPendingDeletion = nil } }
            ),
            presenting: playerPendingDeletion
        ) { player in
            Button("削除する", role: .destructive) {
                deletePlayer(player)
                playerPendingDeletion = nil
            }
            Button("キャンセル", role: .cancel) {
                playerPendingDeletion = nil
            }
        } message: { player in
            Text("「\(playerLabel(player))」を名簿から削除します。写真も消えます。")
        }
        .alert(
            "削除できません",
            isPresented: Binding(
                get: { deletionBlockedPlayer != nil },
                set: { if !$0 { deletionBlockedPlayer = nil } }
            ),
            presenting: deletionBlockedPlayer
        ) { _ in
            Button("OK", role: .cancel) {
                deletionBlockedPlayer = nil
            }
        } message: { player in
            Text("「\(playerLabel(player))」は試合の記録（得点・メンバー表・交代）で使われているため削除できません。")
        }
    }

    private var teamSectionNavigation: some View {
        HStack(spacing: 4) {
            Label("選手名簿", systemImage: "person.3")
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity, minHeight: 46)
                .foregroundStyle(.white)
                .background(RugbyTheme.header, in: RoundedRectangle(cornerRadius: 5))
                .accessibilityAddTraits(.isSelected)
            NavigationLink {
                TeamPerformanceView(team: team)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chart.xyaxis.line").foregroundStyle(team.displayColor)
                    Text("チーム成績").fontWeight(.bold)
                    Image(systemName: "chevron.right").font(.caption2)
                }
                .font(.subheadline)
                .foregroundStyle(RugbyTheme.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 46)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .padding(4)
        .background(RugbyTheme.background, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16).padding(.vertical, 12)
        .padContentWidth(860)
        .frame(maxWidth: .infinity)
        .background(RugbyTheme.surface)
    }

    private var rosterHeroCard: some View {
        HStack(spacing: 15) {
            rosterLogoThumbnail

            VStack(alignment: .leading, spacing: 6) {
                Text("選手名簿")
                    .font(.caption.weight(.heavy))
                    .tracking(1)
                    .opacity(0.8)

                Text(team.name.isEmpty ? "チーム名未設定" : team.name)
                    .font(.title2.weight(.heavy))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)

                HStack(spacing: 8) {
                    ProgressView(
                        value: Double(registeredCount),
                        total: Double(max(players.count, 1))
                    )
                    .tint(onTeamColor)

                    Text("\(registeredCount)/\(players.count)")
                        .font(.caption.weight(.black).monospacedDigit())
                }

                Text("完成プロフィール \(completedProfileCount)人")
                    .font(.caption2.weight(.semibold))
                    .opacity(0.75)
            }

            Spacer(minLength: 0)
        }
        .foregroundStyle(onTeamColor)
        .padding(20)
        .padContentWidth(860)
        .frame(maxWidth: .infinity)
        .background {
            teamColor
                .overlay(DiagonalStripes().fill(Color.white.opacity(0.07)))
                .overlay(LinearGradient(colors: [.clear, .black.opacity(0.15)], startPoint: .top, endPoint: .bottom))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(team.name)、選手カード\(registeredCount)人、完成プロフィール\(completedProfileCount)人"
        )
    }

    @ViewBuilder
    private var rosterLogoThumbnail: some View {
        StoredImageView(name: team.logoPath, maxDimension: 256) { image in
            image
                .resizable()
                .scaledToFit()
                .padding(6)
                .frame(width: 70, height: 70)
                .background(Color.white.opacity(0.94))
                .clipShape(RoundedRectangle(cornerRadius: 17))
        } placeholder: {
            ZStack {
                RoundedRectangle(cornerRadius: 17)
                    .fill(Color.white.opacity(0.18))
                Image(systemName: "shield.fill")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(onTeamColor.opacity(0.8))
            }
            .frame(width: 70, height: 70)
        }
    }

    private var teamSettingsDisclosure: some View {
        VStack(spacing: 14) {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) {
                    isShowingTeamSettings.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "gearshape.fill")
                        .font(.headline)
                        .foregroundStyle(ink)
                        .frame(width: 38, height: 38)
                        .background(ink.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 11))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("チーム設定")
                            .font(.headline.weight(.heavy))
                            .foregroundStyle(RugbyTheme.textPrimary)
                        Text("ロゴ・カラー・マイフォルダ")
                            .font(.caption)
                            .foregroundStyle(RugbyTheme.textSecondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.down")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(RugbyTheme.textSecondary)
                        .rotationEffect(.degrees(isShowingTeamSettings ? 180 : 0))
                }
                .padding(14)
                .teamSettingsCard()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isShowingTeamSettings ? "チーム設定を閉じる" : "チーム設定を開く")

            if isShowingTeamSettings {
                VStack(spacing: 18) {
                    teamIdentityCard
                    colorSelectionCard
                    categoryCard
                    aliasAndMergeCard
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var teamIdentityCard: some View {
        HStack(spacing: 18) {
            PhotosPicker(selection: $logoPickerItem, matching: .images) {
                ZStack(alignment: .bottomTrailing) {
                    logoThumbnail

                    Image(systemName: "camera.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(onTeamColor)
                        .frame(width: 32, height: 32)
                        .background(teamColor)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(RugbyTheme.surface, lineWidth: 2))
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 8) {
                Text("チーム")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(ink)

                TextField("チーム名", text: $team.name)
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(RugbyTheme.textPrimary)
                    .textInputAutocapitalization(.words)

                Text("ロゴをタップして変更")
                    .font(.subheadline)
                    .foregroundStyle(RugbyTheme.textSecondary)

                if team.logoPath != nil {
                    Button("ロゴを削除", role: .destructive) {
                        isShowingLogoDeleteConfirmation = true
                    }
                    .font(.caption.weight(.bold))
                }
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .teamSettingsCard()
    }

    private var colorSelectionCard: some View {
        Button {
            isShowingColorPicker = true
        } label: {
            HStack(spacing: 14) {
                Circle()
                    .fill(teamColor)
                    .frame(width: 46, height: 46)
                    .overlay(
                        Circle()
                            .stroke(RugbyTheme.border, lineWidth: 2)
                    )
                    .overlay {
                        // 仮の色は点線の輪で「未設定」と分かるようにする
                        if team.colorHex == nil {
                            Circle()
                                .strokeBorder(RugbyTheme.surface, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                                .padding(4)
                        }
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text("チームカラー")
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(RugbyTheme.textPrimary)
                    Text("\(selectedColorName)・カードや画面上部の色に使用")
                        .font(.caption)
                        .foregroundStyle(RugbyTheme.textSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(RugbyTheme.textSecondary)
            }
            .padding(18)
            .teamSettingsCard()
        }
        .buttonStyle(.plain)
    }

    // チーム一覧の「マイフォルダ」(Team.category に入れる)。自由入力で、1チーム1つ。
    // 既存のフォルダはワンタップで選べるチップにしておく。
    private var categoryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("マイフォルダ", systemImage: "folder")
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(RugbyTheme.textPrimary)
                Spacer()
                Text(currentCategoryLabel)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(RugbyTheme.textSecondary)
            }

            // 既存カテゴリーのチップ + 「＋新規」
            let existing = existingCategories
            if !existing.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(existing, id: \.self) { name in
                            categoryChip(name, isSelected: (team.category ?? "") == name) {
                                team.category = name
                                guard AppPersistence.save(modelContext) else { return }
                            }
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                categoryChip("＋ 新しいフォルダ", isSelected: false) {
                    categoryDraft = team.category ?? ""
                    isEditingCategory = true
                }
                if team.category?.isEmpty == false {
                    categoryChip("フォルダから外す", isSelected: false) {
                        team.category = nil
                        guard AppPersistence.save(modelContext) else { return }
                    }
                }
            }

            Text("チーム一覧は、出場した大会の男女・カテゴリー・人数で自動的にフォルダ分けされます。それとは別に、よく見るチームを自由な名前のフォルダにまとめられます(1チーム1つ)。")
                .font(.caption)
                .foregroundStyle(RugbyTheme.textSecondary)
        }
        .padding(18)
        .teamSettingsCard()
        .alert("マイフォルダの名前", isPresented: $isEditingCategory) {
            TextField("例: 今季の対戦相手 / 関東", text: $categoryDraft)
            Button("保存") {
                let trimmed = categoryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                team.category = trimmed.isEmpty ? nil : trimmed
                guard AppPersistence.save(modelContext) else { return }
            }
            Button("キャンセル", role: .cancel) {}
        }
    }

    // 別名(大会ごとの表記ゆれ・旧名)と、ほかのチームの統合。
    // 同じチームが別々に登録されてしまったときに、ここで1つにまとめる。
    private var aliasAndMergeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("別名・統合", systemImage: "arrow.triangle.merge")
                .font(.headline.weight(.heavy))
                .foregroundStyle(RugbyTheme.textPrimary)

            if team.aliases.isEmpty {
                Text("別名はありません")
                    .font(.subheadline)
                    .foregroundStyle(RugbyTheme.textSecondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(team.aliases, id: \.self) { alias in
                            HStack(spacing: 4) {
                                Text(alias)
                                Button {
                                    team.aliases.removeAll { $0 == alias }
                                    AppPersistence.save(modelContext)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(RugbyTheme.textSecondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("別名「\(alias)」を外す")
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(RugbyTheme.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(RugbyTheme.background, in: Capsule())
                            .overlay(Capsule().stroke(RugbyTheme.border, lineWidth: 1))
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                categoryChip("＋ 別名を追加", isSelected: false) {
                    aliasDraft = ""
                    isAddingAlias = true
                }
                categoryChip("ほかのチームを統合…", isSelected: false) {
                    isShowingMergeSheet = true
                }
            }

            Text("大会によってチーム名の書き方が違う、名前が変わった、などで同じチームが2つに分かれたときは「ほかのチームを統合」でまとめます。別名は公式記録を取り込むときの照合にも使います。")
                .font(.caption)
                .foregroundStyle(RugbyTheme.textSecondary)
        }
        .padding(18)
        .teamSettingsCard()
        .alert("別名を追加", isPresented: $isAddingAlias) {
            TextField("例: 旧チーム名・大会での表記", text: $aliasDraft)
            Button("追加") {
                let trimmed = aliasDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed != team.name, !team.aliases.contains(trimmed) else { return }
                team.aliases.append(trimmed)
                AppPersistence.save(modelContext)
            }
            Button("キャンセル", role: .cancel) {}
        }
    }

    private var currentCategoryLabel: String {
        let trimmed = (team.category ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "なし" : trimmed
    }

    private var existingCategories: [String] {
        let names = allTeams.compactMap { team -> String? in
            let trimmed = (team.category ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return Array(Set(names)).sorted()
    }

    private func categoryChip(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(isSelected ? onTeamColor : RugbyTheme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(isSelected ? teamColor : RugbyTheme.background)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(isSelected ? teamColor : RugbyTheme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var rosterTitle: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("選手名簿")
                        .font(.title2.weight(.heavy))
                        .foregroundStyle(RugbyTheme.textPrimary)
                    HStack(spacing: 3) {
                        ForEach(0..<3, id: \.self) { _ in
                            Capsule()
                                .fill(ink)
                                .frame(width: 13, height: 3)
                                .rotationEffect(.degrees(-45))
                        }
                    }
                }

                Text("カードをタップして個人成績を見る")
                    .font(.subheadline)
                    .foregroundStyle(RugbyTheme.textSecondary)
            }

            Spacer()

            Text(
                visiblePlayers.count == players.count
                    ? "\(players.count)人"
                    : "\(visiblePlayers.count)/\(players.count)人"
            )
                .font(.title3.weight(.black).monospacedDigit())
                .foregroundStyle(ink)
        }
    }

    private var rosterPinnedControls: some View {
        VStack(spacing: 10) {
            rosterSearchField
            rosterControls
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .padContentWidth(860)
        .frame(maxWidth: .infinity)
        .background(RugbyTheme.background)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(RugbyTheme.border)
                .frame(height: 1)
        }
        .zIndex(20)
    }

    private var rosterContent: some View {
        // 描き直し1回につき1回だけ計算する(カードごとに名簿全体を数え直さない)
        let visiblePlayers = visiblePlayers
        let duplicatedNumbers = duplicatedNumbers
        let teamColor = teamColor
        return VStack(spacing: 14) {
            if visiblePlayers.isEmpty {
                rosterEmptyState
            } else {
                LazyVGrid(columns: columns, spacing: rosterColumnCount == 2 ? 14 : 10) {
                    ForEach(visiblePlayers) { player in
                        Button {
                            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.65)
                            openProfile(player)
                        } label: {
                            PlayerCollectionCard(
                                player: player,
                                accent: teamColor,
                                isNumberDuplicated: player.number.map { duplicatedNumbers.contains($0) } ?? false,
                                statusLabel: rosterFilter == .needsInput
                                    ? (rosterColumnCount == 2
                                        ? "未入力 \(player.rosterMissingFieldCount)"
                                        : "未 \(player.rosterMissingFieldCount)")
                                    : nil
                            )
                        }
                        .buttonStyle(CollectionCardButtonStyle())
                        .accessibilityLabel(
                            [
                                playerLabel(player),
                                player.rugbyPosition?.selectionLabel,
                                player.isFavorite ? "お気に入り" : nil,
                                player.rosterProfileIsComplete
                                    ? "プロフィール入力完了"
                                    : "未入力\(player.rosterMissingFieldCount)項目"
                            ]
                            .compactMap { $0 }
                            .joined(separator: "、")
                        )
                        .accessibilityHint("ダブルタップして個人成績を表示")
                        .accessibilityAction(named: "編集") {
                            editingPlayer = player
                        }
                        .contextMenu {
                            Button {
                                openProfile(player)
                            } label: {
                                Label("個人成績を見る", systemImage: "chart.bar")
                            }

                            Button {
                                editingPlayer = player
                            } label: {
                                Label("選手を編集", systemImage: "pencil")
                            }
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: rosterColumnCount)
            }

            Button {
                addPlayerSlot()
            } label: {
                Label("選手を追加", systemImage: "plus")
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(onTeamColor)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(teamColor, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)

            Button {
                isShowingBulkKanaSheet = true
            } label: {
                Label("選手をまとめて入力", systemImage: "square.and.pencil")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(RugbyTheme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(RugbyTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(RugbyTheme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)

            Text("名前は空欄のままでも記録できます。編集は個人成績の右上、またはカードの長押しから行えます。")
                .font(.caption)
                .foregroundStyle(RugbyTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var rosterSearchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(RugbyTheme.textSecondary)

            TextField(
                "名前・読み・背番号・ポジションで検索",
                text: $searchText,
                prompt: Text("名前・読み・背番号・ポジションで検索").foregroundStyle(RugbyTheme.textSecondary.opacity(0.7))
            )
                .font(.subheadline)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .foregroundStyle(RugbyTheme.textPrimary)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(RugbyTheme.textSecondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("検索をクリア")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(RugbyTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(searchText.isEmpty ? RugbyTheme.border : ink.opacity(0.6), lineWidth: 1)
        )
    }

    private var rosterControls: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(RosterFilter.allCases) { filter in
                        rosterFilterChip(filter)
                    }

                    rosterPositionPicker
                }
            }

            rosterColumnPicker
        }
    }

    private func rosterFilterChip(_ filter: RosterFilter) -> some View {
        let isSelected = rosterFilter == filter

        return Button {
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.easeInOut(duration: 0.16)) {
                rosterFilter = filter
            }
        } label: {
            Label(filter.title, systemImage: filter.systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(isSelected ? onTeamColor : RugbyTheme.textPrimary)
                .padding(.horizontal, 11)
                .frame(height: 44)
                .background(isSelected ? teamColor : RugbyTheme.surface)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(isSelected ? teamColor : RugbyTheme.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var rosterPositionPicker: some View {
        Menu {
            ForEach(RosterPositionFilter.options) { filter in
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    withAnimation(.easeInOut(duration: 0.16)) {
                        rosterPositionFilter = filter
                    }
                } label: {
                    if rosterPositionFilter == filter {
                        Label(filter.accessibilityLabel, systemImage: "checkmark")
                    } else {
                        Text(filter.accessibilityLabel)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "figure.rugby")
                Text(rosterPositionFilter.title)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .black))
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(rosterPositionFilter == .all ? RugbyTheme.textPrimary : onTeamColor)
            .padding(.horizontal, 10)
            .frame(height: 44)
            .background(rosterPositionFilter == .all ? RugbyTheme.surface : teamColor)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(
                        rosterPositionFilter == .all ? RugbyTheme.border : teamColor,
                        lineWidth: 1
                    )
            )
        }
        .accessibilityLabel("ポジション絞り込み")
        .accessibilityValue(rosterPositionFilter.accessibilityLabel)
    }

    private var rosterColumnPicker: some View {
        HStack(spacing: 2) {
            rosterColumnButton(2)
            rosterColumnButton(3)
        }
        .padding(2)
        .background(RugbyTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(RugbyTheme.border, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("カードの表示列数")
    }

    private func rosterColumnButton(_ count: Int) -> some View {
        let isSelected = rosterColumnCount == count

        return Button {
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.easeInOut(duration: 0.2)) {
                rosterColumnCount = count
            }
        } label: {
            Text("\(count)列")
                .font(.caption2.weight(.black).monospacedDigit())
                .foregroundStyle(isSelected ? onTeamColor : RugbyTheme.textSecondary)
                .frame(width: 42, height: 42)
                .background(isSelected ? teamColor : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(count)列表示")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var rosterEmptyState: some View {
        VStack(spacing: 12) {
            Image(
                systemName: rosterFilter == .needsInput
                    ? "checkmark.seal.fill"
                    : (rosterFilter == .favorites ? "star.slash" : "person.crop.circle.badge.questionmark")
            )
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(ink)

            Text(rosterFilter == .needsInput
                 && searchText.isEmpty
                 && rosterPositionFilter == .all
                 ? "すべての選手情報が入力されています"
                 : "条件に合う選手がいません")
                .font(.headline.weight(.heavy))
                .foregroundStyle(RugbyTheme.textPrimary)
                .multilineTextAlignment(.center)

            Text("検索語を変えるか、絞り込みを解除してください。")
                .font(.subheadline)
                .foregroundStyle(RugbyTheme.textSecondary)
                .multilineTextAlignment(.center)

            Button("条件をクリア") {
                withAnimation(.easeInOut(duration: 0.18)) {
                    searchText = ""
                    rosterFilter = .all
                    rosterPositionFilter = .all
                }
            }
            .font(.subheadline.weight(.bold))
            .foregroundStyle(ink)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, 18)
        .teamSettingsCard()
    }

    @ViewBuilder
    private var logoThumbnail: some View {
        StoredImageView(name: team.logoPath, maxDimension: 360) { image in
            image
                .resizable()
                .scaledToFill()
                .frame(width: 104, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 20))
        } placeholder: {
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(RugbyTheme.elevated)
                Image(systemName: "shield.fill")
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(ink.opacity(0.8))
            }
            .frame(width: 104, height: 104)
        }
    }

    private func normalizedSearchKey(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "ja_JP")
            )
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .lowercased()
    }

    private func handleSelectedLogo(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            let data = try? await item.loadTransferable(type: Data.self)
            await MainActor.run {
                if let data, let newName = ImageStorage.save(data) {
                    SafeImageMutation.replace(old: team.logoPath, new: newName, context: modelContext,
                        set: { team.logoPath = $0 }, removeImage: { ImageStorage.delete(named: $0) })
                }
                logoPickerItem = nil
            }
        }
    }

    private func deleteLogo() {
        SafeImageMutation.replace(old: team.logoPath, new: nil, context: modelContext,
            set: { team.logoPath = $0 }, removeImage: { ImageStorage.delete(named: $0) })
    }

    private func ensureInitialPlayers() {
        guard players.isEmpty else { return }
        for number in 1...15 {
            modelContext.insert(Player(teamID: team.id, number: number))
        }
        guard AppPersistence.save(modelContext) else { return }
    }

    private func addPlayerSlot() {
        let nextNumber = (players.compactMap(\.number).max() ?? 0) + 1
        let player = Player(teamID: team.id, number: nextNumber)
        modelContext.insert(player)
        guard AppPersistence.save(modelContext) else { return }
        editingPlayer = player
    }

    private func playerLabel(_ player: Player) -> String {
        let name = (player.name?.isEmpty == false) ? player.name! : "名前未設定"
        if let number = player.number { return "#\(number) \(name)" }
        return name
    }

    private func openProfile(_ player: Player) {
        detailPlayer = player
    }

    private func queuePlayerDeletion(_ player: Player) {
        queuedPlayerDeletion = player
        detailPlayer = nil
        editingPlayer = nil
    }

    private func processQueuedPlayerDeletion() {
        guard detailPlayer == nil,
              editingPlayer == nil,
              let player = queuedPlayerDeletion else { return }

        queuedPlayerDeletion = nil
        if isPlayerUsedInRecords(player) {
            deletionBlockedPlayer = player
        } else {
            playerPendingDeletion = player
        }
    }

    private func isPlayerUsedInRecords(_ player: Player) -> Bool {
        let playerID = player.id

        var eventDescriptor = FetchDescriptor<StatEvent>(
            predicate: #Predicate { $0.playerID == playerID }
        )
        eventDescriptor.fetchLimit = 1
        if (try? modelContext.fetch(eventDescriptor).first) != nil { return true }

        var lineupDescriptor = FetchDescriptor<MatchLineup>(
            predicate: #Predicate { $0.playerID == playerID }
        )
        lineupDescriptor.fetchLimit = 1
        if (try? modelContext.fetch(lineupDescriptor).first) != nil { return true }

        var substitutionDescriptor = FetchDescriptor<Substitution>(
            predicate: #Predicate { $0.playerInID == playerID || $0.playerOutID == playerID }
        )
        substitutionDescriptor.fetchLimit = 1
        return ((try? modelContext.fetch(substitutionDescriptor).first) != nil)
    }

    private func deletePlayer(_ player: Player) {
        SafeDeletion.player(player, context: modelContext) { ImageStorage.delete(named: $0) }
    }
}

#Preview {
    NavigationStack {
        TeamListView()
    }
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

private extension View {
    // チーム画面の白いカード(試合一覧・選手詳細と同じ白い面と細い枠)
    func teamSettingsCard() -> some View {
        background(RugbyTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(RugbyTheme.border, lineWidth: 1))
    }
}
