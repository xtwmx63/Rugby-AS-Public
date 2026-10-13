//
//  LineupRegistrationView.swift
//  Rugby AS
//
//  試合記録の前に、その試合のスタメンとリザーブを登録する画面。
//

import SwiftData
import SwiftUI

struct LineupRegistrationView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query private var teams: [Team]
    // この試合の 2 チームの選手だけに絞る。全選手をフェッチして main thread で
    // ソート → 毎フレーム body 内で再 filter するのは重い。
    @Query private var allPlayers: [Player]
    @Query private var lineupEntries: [MatchLineup]
    // 「前の試合からコピー」のコピー元。全試合・全メンバー表は読まず、このチームの分だけを
    // チームを切り替えたときに1回だけ探す(公式記録でメンバー表が数十万行あり、毎回探すと重いため)
    @State private var copySource: Match?

    let match: Match

    @State private var selectedTeamID: UUID?
    @State private var addingContext: AddingContext?
    @State private var pendingRemoval: MatchLineup?
    @State private var showsRecordingChoice = false
    @State private var showsWidgetRecording = false
    @State private var showsLegacyRecording = false
    // 背番号を編集中のメンバー表エントリ
    @State private var numberEditingEntry: MatchLineup?
    @State private var numberText = ""

    init(match: Match) {
        self.match = match
        let matchID = match.id
        let homeID = match.homeTeamID
        let awayID = match.awayTeamID
        _lineupEntries = Query(filter: #Predicate<MatchLineup> { entry in
            entry.matchID == matchID
        })
        _allPlayers = Query(
            filter: #Predicate<Player> { player in
                player.teamID == homeID || player.teamID == awayID
            },
            sort: [SortDescriptor(\Player.number)]
        )
    }

    private var currentTeamID: UUID {
        selectedTeamID ?? match.homeTeamID
    }

    private var teamLineupEntries: [MatchLineup] {
        // 「番号の控え」行(記録から自動生成)はメンバー表としては扱わない
        lineupEntries.filter {
            $0.teamID == currentTeamID && ($0.role == "starter" || $0.role == "reserve")
        }
    }

    private var starters: [MatchLineup] {
        teamLineupEntries.filter { $0.role == "starter" }.sorted { $0.order < $1.order }
    }

    private var reserves: [MatchLineup] {
        teamLineupEntries.filter { $0.role == "reserve" }.sorted { $0.order < $1.order }
    }

    private var teamPlayers: [Player] {
        allPlayers.filter { $0.teamID == currentTeamID }
    }

    private var availablePlayers: [Player] {
        let registered = Set(teamLineupEntries.map { $0.playerID })
        return teamPlayers.filter { !registered.contains($0.id) }
    }

    // 長い画面定義に修飾を足すとビルドが極端に遅くなるため、外側で包む
    var body: some View {
        content
            .task(id: CopySourceKey(teamID: currentTeamID, isEmpty: teamLineupEntries.isEmpty)) {
                copySource = teamLineupEntries.isEmpty ? findCopySourceMatch() : nil
            }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                teamHeader
                teamToggle

                // このチームのメンバーが空なら、前の試合のメンバー表を丸ごと流用できる
                if teamLineupEntries.isEmpty, let source = copySource {
                    Button {
                        copyLineup(from: source)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "doc.on.doc")
                                .font(.body)
                                .foregroundStyle(RugbyTheme.accent)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("前の試合からコピー")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(RugbyTheme.textPrimary)
                                Text("\(Self.copyDateFormatter.string(from: source.playedAt)) のメンバー表を使う")
                                    .font(.caption)
                                    .foregroundStyle(RugbyTheme.textSecondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.down.to.line")
                                .foregroundStyle(RugbyTheme.accent)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(RugbyTheme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }

                if teamPlayers.isEmpty {
                    Label("このチームの名簿はまだありません。選手はチームページで追加できます。", systemImage: "person.crop.circle.badge.plus")
                        .font(.subheadline)
                        .foregroundStyle(RugbyTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if availablePlayers.isEmpty {
                    Label("このチームの選手は全員メンバーに登録されています。", systemImage: "checkmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(RugbyTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                sectionView(title: "スタメン", entries: starters, role: "starter")
                sectionView(title: "リザーブ", entries: reserves, role: "reserve")

                Label("背番号をタップすると、この試合の番号だけを変更できます。通常はチームページで登録した番号が使われます。", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(RugbyTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 960)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
        .background(RugbyTheme.background)
        .labelStyle(.titleAndIcon)
        .safeAreaInset(edge: .bottom, spacing: 0) { recordingAction }
        .navigationTitle("メンバー登録")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(RugbyTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .tint(RugbyTheme.accent)
        // 同じ NavigationStack に navigationDestination(item:) と
        // navigationDestination(isPresented:) を入れ子で重ねると、後者が
        // 無視されることがある SwiftUI の挙動を避けるため、ここは fullScreenCover で出す。
        .fullScreenCover(isPresented: $showsWidgetRecording) {
            WidgetRecordingView(
                match: match,
                context: modelContext,
                initialSeconds: 0,
                initialHalf: 0,
                onClose: { _, _, _ in }
            )
            .preferredColorScheme(.dark)
            .tint(.blue)
        }
        .fullScreenCover(isPresented: $showsLegacyRecording) {
            V3RecordingView(match: match)
                .preferredColorScheme(.dark)
                .tint(.blue)
        }
        .confirmationDialog("記録画面を選択", isPresented: $showsRecordingChoice, titleVisibility: .visible) {
            Button("カスタム記録画面") { showsWidgetRecording = true }
            Button("従来の記録画面") { showsLegacyRecording = true }
            Button("キャンセル", role: .cancel) { }
        }
        .sheet(item: $addingContext) { context in
            playerPickerSheet(role: context.role)
        }
        .alert("背番号を変更", isPresented: Binding(
            get: { numberEditingEntry != nil },
            set: { if !$0 { numberEditingEntry = nil } }
        )) {
            TextField("番号", text: $numberText)
                .keyboardType(.numberPad)
            Button("保存") {
                if let number = Int(numberText), number > 0 {
                    numberEditingEntry?.number = number
                    AppPersistence.save(modelContext)
                }
                numberEditingEntry = nil
            }
            Button("キャンセル", role: .cancel) {
                numberEditingEntry = nil
            }
        } message: {
            Text("この試合で着ける背番号を入力してください。")
        }
        .confirmationDialog(
            "この選手を外しますか？",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { entry in
            Button("外す", role: .destructive) {
                modelContext.delete(entry)
                AppPersistence.save(modelContext)
                pendingRemoval = nil
            }
            Button("キャンセル", role: .cancel) {
                pendingRemoval = nil
            }
        }
    }

    // MARK: - Header

    private var teamHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Label(match.playedAt.formatted(.dateTime.year().month().day().weekday(.abbreviated).locale(Locale(identifier: "ja_JP"))), systemImage: "calendar")
                .font(.caption.weight(.medium))
                .foregroundStyle(RugbyTheme.textSecondary)
                .labelStyle(.titleAndIcon)
            Spacer(minLength: 0)
            Text("登録は任意")
                .font(.caption.weight(.medium))
                .foregroundStyle(RugbyTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func teamLogo(for teamID: UUID) -> some View {
        let team = teams.first { $0.id == teamID }
        StoredImageView(name: team?.logoPath, maxDimension: 160) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "shield.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(RugbyTheme.textSecondary)
                .padding(8)
        }
        .background(RugbyTheme.elevated)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Team selection

    private var teamToggle: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("登録するチーム")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(RugbyTheme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                teamSelectionButton(match.homeTeamID, side: "HOME")
                teamSelectionButton(match.awayTeamID, side: "AWAY")
            }
        }
    }

    private func teamSelectionButton(_ teamID: UUID, side: String) -> some View {
        let isSelected = currentTeamID == teamID
        return Button {
            selectedTeamID = teamID
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(side).font(.caption2.weight(.bold)).tracking(1.5)
                    Spacer(minLength: 4)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.subheadline)
                        .accessibilityHidden(true)
                }
                HStack(spacing: 8) {
                    teamLogo(for: teamID)
                        .frame(width: 30, height: 30)
                        .accessibilityHidden(true)
                    Text(teamName(for: teamID))
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(isSelected ? RugbyTheme.onAccent : RugbyTheme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(isSelected ? RugbyTheme.accent : RugbyTheme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? RugbyTheme.accent : RugbyTheme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(teamName(for: teamID))のメンバーを登録")
        .accessibilityValue(isSelected ? "選択中" : "未選択")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var recordingAction: some View {
        VStack(spacing: 10) {
            Text("未登録でも記録できます。メンバーは後から追加・変更できます。")
                .font(.caption)
                .foregroundStyle(RugbyTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                showsRecordingChoice = true
            } label: {
                HStack(spacing: 10) {
                    Text("記録画面を選ぶ")
                    Image(systemName: "arrow.right")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(RugbyPrimaryButtonStyle())
            .accessibilityHint("カスタム記録画面と従来の記録画面から選択します")
        }
        .frame(maxWidth: 960)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(RugbyTheme.surface)
        .overlay(alignment: .top) { Rectangle().fill(RugbyTheme.border).frame(height: 1) }
    }

    // MARK: - Roster sections

    private func sectionView(title: String, entries: [MatchLineup], role: String) -> some View {
        let headerLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
        return VStack(alignment: .leading, spacing: 0) {
            headerLayout {
                HStack(spacing: 10) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(RugbyTheme.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text("\(entries.count)人")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(RugbyTheme.textSecondary)
                        .monospacedDigit()
                }
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 4) }
                Button {
                    addingContext = AddingContext(role: role)
                } label: {
                    Label("追加", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                }
                .disabled(availablePlayers.isEmpty)
                .accessibilityLabel("\(title)に選手を追加")
            }
            .padding(.bottom, 4)
            if entries.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(title)はまだ登録されていません")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(RugbyTheme.textPrimary)
                    Text("必要な選手だけ追加できます。")
                        .font(.caption)
                        .foregroundStyle(RugbyTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(entries) { entry in
                        if let player = player(for: entry) {
                            Rectangle().fill(RugbyTheme.border).frame(height: 1)
                            playerRow(player: player, entry: entry) {
                                pendingRemoval = entry
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(RugbyTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(RugbyTheme.border, lineWidth: 1))
    }

    private func playerRow(player: Player, entry: MatchLineup, onTap: @escaping () -> Void) -> some View {
        let matchNumber = MatchNumbering.number(for: player, matchID: match.id, lineups: [entry])
        let isDuplicated = matchNumber.map { duplicatedNumbers.contains($0) } ?? false
        let playerLabel = MatchNumbering.label(for: player, matchID: match.id, lineups: [entry])

        return HStack(spacing: 10) {
            // 番号タップ = この試合の背番号を変更
            Button {
                numberText = matchNumber.map(String.init) ?? ""
                numberEditingEntry = entry
            } label: {
                HStack(spacing: 4) {
                    Text(MatchNumbering.numberText(matchNumber))
                        .monospacedDigit()
                    Image(systemName: "pencil").font(.caption2)
                }
                .font(.subheadline.weight(.bold))
                .foregroundStyle(isDuplicated ? Color.orange : RugbyTheme.accent)
                .frame(minWidth: 48, minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(player.name ?? "選手")の背番号を変更")
            .accessibilityValue(matchNumber.map { "\($0)番" } ?? "背番号なし")

            if !dynamicTypeSize.isAccessibilitySize {
                playerAvatar(player: player)
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(player.name ?? "名前未設定")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(player.name == nil ? RugbyTheme.textSecondary : RugbyTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if isDuplicated {
                    Label("番号が重複", systemImage: "exclamationmark.circle")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onTap) {
                Image(systemName: "minus.circle")
                    .font(.body)
                    .foregroundStyle(RugbyTheme.textSecondary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(playerLabel)をメンバーから外す")
            .accessibilityHint("確認画面が開きます")
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // 同一チーム内で重複している試合用背番号(オレンジで警告表示)
    private var duplicatedNumbers: Set<Int> {
        var seen: Set<Int> = []
        var duplicated: Set<Int> = []
        for entry in teamLineupEntries {
            guard let player = player(for: entry),
                  let number = MatchNumbering.number(for: player, matchID: match.id, lineups: [entry]) else { continue }
            if !seen.insert(number).inserted {
                duplicated.insert(number)
            }
        }
        return duplicated
    }

    @ViewBuilder
    private func playerAvatar(player: Player) -> some View {
        StoredImageView(name: player.imagePath, maxDimension: 256) { image in
            image
                .resizable()
                .scaledToFill()
                .clipShape(Circle())
        } placeholder: {
            Circle()
                .fill(RugbyTheme.background)
                .overlay(
                    Image(systemName: "person.fill")
                        .font(.title2)
                        .foregroundStyle(RugbyTheme.textSecondary)
                )
        }
    }

    // MARK: - Picker sheet

    private func playerPickerSheet(role: String) -> some View {
        NavigationStack {
            List {
                if availablePlayers.isEmpty {
                    RugbyEmptyState(
                        symbol: "person.crop.circle.badge.questionmark",
                        title: "追加できる選手がいません",
                        message: "チームページで選手を追加してください。メンバー未登録でも記録は始められます。"
                    )
                    .listRowBackground(RugbyTheme.surface)
                } else {
                    Section {
                        ForEach(availablePlayers) { player in
                            Button {
                                addPlayer(player, role: role)
                                addingContext = nil
                            } label: {
                                HStack(spacing: 14) {
                                    Text(MatchNumbering.numberLabel(for: player, matchID: match.id, lineups: lineupEntries))
                                        .font(.headline.monospacedDigit())
                                        .foregroundStyle(RugbyTheme.accent)
                                        .frame(minWidth: 48, minHeight: 44)
                                        .background(RugbyTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                                    Text(player.name ?? "名前未設定")
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(player.name == nil ? RugbyTheme.textSecondary : RugbyTheme.textPrimary)
                                    Spacer(minLength: 0)
                                    Image(systemName: "plus.circle")
                                        .foregroundStyle(RugbyTheme.accent)
                                        .accessibilityHidden(true)
                                }
                                .padding(.vertical, 6)
                            }
                            .accessibilityLabel("\(MatchNumbering.label(for: player, matchID: match.id, lineups: lineupEntries))を追加")
                        }
                        .listRowBackground(RugbyTheme.surface)
                    } header: {
                        Text(teamName(for: currentTeamID))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(RugbyTheme.background)
            .navigationTitle(role == "starter" ? "スタメンを追加" : "リザーブを追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbarBackground(RugbyTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") {
                        addingContext = nil
                    }
                }
            }
        }
        .tint(RugbyTheme.accent)
        .presentationDetents([.medium, .large])
    }

    // MARK: - Helpers

    private func teamName(for id: UUID) -> String {
        teams.first { $0.id == id }?.name ?? "未設定"
    }

    private func player(for entry: MatchLineup) -> Player? {
        allPlayers.first { $0.id == entry.playerID }
    }

    private func addPlayer(_ player: Player, role: String) {
        let existing = teamLineupEntries.filter { $0.role == role }
        let nextOrder = (existing.map { $0.order }.max() ?? -1) + 1

        // 記録から自動生成された「番号の控え」行が既にあれば、それを昇格させる
        // (同じ選手の行が二重にできるのを防ぐ。控えの番号はそのまま引き継ぐ)
        if let snapshot = lineupEntries.first(where: {
            $0.playerID == player.id && $0.role == MatchNumbering.numberSnapshotRole
        }) {
            snapshot.role = role
            snapshot.order = nextOrder
            AppPersistence.save(modelContext)
            return
        }

        // チームページで事前登録した「今の背番号」を書き込んで固定する。
        // 後からチームページで番号を変えても、登録済みの試合は変わらない
        // (過去の試合の背番号が遡って書き換わる事故を防ぐ)。
        let entry = MatchLineup(
            matchID: match.id,
            teamID: currentTeamID,
            playerID: player.id,
            role: role,
            order: nextOrder,
            number: player.number
        )
        modelContext.insert(entry)
        AppPersistence.save(modelContext)
    }

    // MARK: - 前の試合からコピー

    private struct CopySourceKey: Equatable {
        let teamID: UUID
        let isEmpty: Bool
    }

    // コピー元: このチームのメンバー表がある、この試合より前の直近の試合。
    // 同じ大会の試合を優先する(大会単位の登録メンバーを引き継ぐ想定)。
    private func findCopySourceMatch() -> Match? {
        let teamID = currentTeamID
        let currentID = match.id
        // 条件は単純にして読み、残りはここで絞る(複雑な条件式はビルドに時間がかかるため)
        let entries = ((try? modelContext.fetch(FetchDescriptor<MatchLineup>(predicate: #Predicate { $0.teamID == teamID }))) ?? [])
            .filter { $0.matchID != currentID && ($0.role == "starter" || $0.role == "reserve") }
        let matchIDsWithLineup = Array(Set(entries.map(\.matchID)))
        guard !matchIDsWithLineup.isEmpty else { return nil }
        let playedAt = match.playedAt
        let candidates = ((try? modelContext.fetch(FetchDescriptor<Match>(predicate: #Predicate {
            matchIDsWithLineup.contains($0.id)
        }))) ?? []).filter { $0.playedAt <= playedAt }
        let sameTournament = candidates
            .filter { $0.tournamentID == match.tournamentID }
            .max { $0.playedAt < $1.playedAt }
        return sameTournament ?? candidates.max { $0.playedAt < $1.playedAt }
    }

    private func copyLineup(from source: Match) {
        let teamID = currentTeamID
        let sourceID = source.id
        let sourceEntries = ((try? modelContext.fetch(FetchDescriptor<MatchLineup>(predicate: #Predicate {
            $0.matchID == sourceID
        }))) ?? []).filter { $0.teamID == teamID && ($0.role == "starter" || $0.role == "reserve") }
        for sourceEntry in sourceEntries {
            // 番号は前の試合の値ではなく「今のチームページの番号」を使う
            // (大会前に事前変更した番号が、次の試合へ正しく引き継がれるように)
            let entry = MatchLineup(
                matchID: match.id,
                teamID: teamID,
                playerID: sourceEntry.playerID,
                role: sourceEntry.role,
                order: sourceEntry.order,
                number: player(for: sourceEntry)?.number ?? sourceEntry.number
            )
            modelContext.insert(entry)
        }
        AppPersistence.save(modelContext)
    }

    private static let copyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    private struct AddingContext: Identifiable {
        let role: String
        var id: String { role }
    }
}

#Preview {
    NavigationStack {
        LineupRegistrationView(
            match: Match(
                tournamentID: UUID(),
                homeTeamID: UUID(),
                awayTeamID: UUID(),
                playedAt: Date()
            )
        )
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
