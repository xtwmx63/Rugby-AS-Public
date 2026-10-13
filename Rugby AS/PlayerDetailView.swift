//
//  PlayerDetailView.swift
//  Rugby AS
//
//  選手の個人成績。上部はチームカラーの帯に選手写真・名前・チーム・背番号を大きく出し、
//  下のタブで「概要(プロフィール・通算成績・直近の試合)」「試合」「大会別」を切り替える。
//  数値は常にStatEventから再計算する(後から記録を直せば自動で正しくなる)。
//
//  「試合数」はメンバー表に登録された試合と、得点記録がある試合を
//  合わせて数える(メンバー表を登録しない運用でも成績が出るように)。
//
//  集計は画面を開いたときと保存があったときに1回だけ行い、値として持つ。
//  (以前は全試合・全記録を @Query で読み、試合の行ごとに全記録を数え直していたため、
//   公式記録を取り込んで記録が増えると開くのがかなり重かった)
//

import SwiftData
import SwiftUI

struct PlayerDetailView: View {
    @Environment(\.modelContext) private var modelContext
    let player: Player
    // チーム画面から開いたときだけ渡される。編集画面の「選手を削除」をチーム画面へ戻して処理する
    var onRequestDelete: ((Player) -> Void)? = nil

    @Query private var teams: [Team]
    @Query private var tournaments: [Tournament]
    @State private var snapshot = Snapshot()
    @State private var selectedTab: DetailTab = .overview
    @State private var isEditing = false
    @State private var isDeletionRequested = false
    // タップした試合(値で積む。NavigationLink の遷移先を直接書くと、値で積まれたこの画面から
    // 試合詳細を開いたときに画面の作り直しが止まらなくなることがあるため)
    @State private var openedMatch: Match?
    @State private var breakdownKind: BreakdownKind = .team

    private enum DetailTab: String, CaseIterable, Identifiable {
        case overview, matches, breakdown
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: return "概要"
            case .matches: return "試合"
            case .breakdown: return "内訳"
            }
        }
    }

    /// 内訳の分け方
    private enum BreakdownKind: String, CaseIterable, Identifiable {
        case team, category, season, tournament
        var id: String { rawValue }
        var title: String {
            switch self {
            case .team: return "チーム別"
            case .category: return "カテゴリー別"
            case .season: return "年度別"
            case .tournament: return "大会別"
            }
        }
    }

    // 直近の試合として並べる数
    private static let recentFormCount = 5

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                hero
                tabBar
                VStack(alignment: .leading, spacing: 20) {
                    switch selectedTab {
                    case .overview:
                        profileCard
                        recordSection
                        recentFormSection
                        compareLink
                    case .matches:
                        matchesSection
                    case .breakdown:
                        breakdownSection
                    }
                }
                .padding(16)
                .padContentWidth(760)
            }
        }
        .background(RugbyTheme.background)
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    toggleFavorite()
                } label: {
                    Image(systemName: player.isFavorite ? "star.fill" : "star")
                }
                .foregroundStyle(player.isFavorite ? Color.orange : RugbyTheme.textPrimary)
                .accessibilityLabel(player.isFavorite ? "お気に入りから外す" : "お気に入りに追加")

                Button {
                    isEditing = true
                } label: {
                    Image(systemName: "pencil")
                }
                .foregroundStyle(RugbyTheme.textPrimary)
                .accessibilityLabel("選手を編集")
            }
        }
        .sheet(isPresented: $isEditing, onDismiss: {
            guard isDeletionRequested else { return }
            isDeletionRequested = false
            onRequestDelete?(player)
        }) {
            PlayerCardEditorSheet(
                player: player,
                teamName: teamName(for: player.teamID),
                accent: heroColor,
                isNumberDuplicated: isNumberDuplicated,
                showsStatsLink: false,
                onRequestDelete: onRequestDelete == nil ? nil : { isDeletionRequested = true }
            )
        }
        // ナビゲーションバーは白にして、下のチームカラーの帯とメリハリをつける
        .toolbarBackground(RugbyTheme.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.light, for: .navigationBar)
        .navigationDestination(item: $openedMatch) { match in
            // 試合詳細は画面下に独自のボタンがあるのでタブを隠す(試合一覧から開いたときと同じ)
            MatchSummaryView(match: match)
                .toolbar(.hidden, for: .tabBar)
        }
        .onAppear(perform: loadSnapshot)
        .onReceive(ModelSaveSignal.didSave) { _ in loadSnapshot() }
    }

    // MARK: - 上部(チームカラーの帯)

    private var team: Team? { teams.first { $0.id == player.teamID } }

    private var heroColor: Color {
        team?.displayColor ?? RugbyTheme.header
    }

    private var hero: some View {
        let color = heroColor
        let textColor: Color = color.prefersDarkText ? RugbyTheme.textPrimary : .white

        return HStack(alignment: .bottom, spacing: 14) {
            heroPhoto
            VStack(alignment: .leading, spacing: 6) {
                if let subtitle = nameSubtitle {
                    Text(subtitle)
                        .font(.subheadline.weight(.semibold))
                        .opacity(0.8)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                // 姓と名(「・」や空白の前後)で改行し、単語の途中で折り返さない
                ForEach(Array(nameLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 30, weight: .heavy))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                teamLine
                if !snapshot.linkedTeamNames.isEmpty {
                    // 同一人物としてつないだほかの所属(代表・移籍前など)
                    Text("ほかの所属: " + snapshot.linkedTeamNames.joined(separator: "・"))
                        .font(.caption.weight(.semibold))
                        .opacity(0.85)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                }
            }
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(textColor)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padContentWidth(760)
        .frame(maxWidth: .infinity)
        .background {
            color
                .overlay(DiagonalStripes().fill(Color.white.opacity(0.07)))
                .overlay(LinearGradient(colors: [.clear, .black.opacity(0.15)], startPoint: .top, endPoint: .bottom))
        }
        .accessibilityElement(children: .combine)
    }

    // 写真は背景を消した切り抜き画像が映えるよう、枠を付けずに下端へそろえて置く
    private var heroPhoto: some View {
        StoredImageView(name: player.imagePath, maxDimension: 600) { image in
            image
                .resizable()
                .scaledToFit()
        } placeholder: {
            Image(systemName: "person.fill")
                .resizable()
                .scaledToFit()
                .padding(.horizontal, 18)
                .padding(.top, 30)
                .opacity(0.35)
        }
        .frame(width: 140, height: 180, alignment: .bottom)
        .accessibilityHidden(true)
    }

    private var teamLine: some View {
        HStack(spacing: 6) {
            if let logoPath = team?.logoPath {
                StoredImageView(name: logoPath, maxDimension: 80) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Color.clear
                }
                .frame(width: 22, height: 22)
            }
            Text(teamName(for: player.teamID))
                .lineLimit(1)
            if let number = player.number {
                Text("・#\(number)")
            }
            if let position = player.rugbyPosition {
                Text("・\(position.rawValue)")
            }
        }
        .font(.subheadline.weight(.semibold))
        .minimumScaleFactor(0.7)
    }

    // 同じチームに同じ背番号の選手がいるか(編集画面でオレンジ表示にする)
    private var isNumberDuplicated: Bool {
        guard let number = player.number else { return false }
        let teamID = player.teamID
        let descriptor = FetchDescriptor<Player>(predicate: #Predicate { $0.teamID == teamID && $0.number == number })
        return ((try? modelContext.fetchCount(descriptor)) ?? 0) > 1
    }

    private func toggleFavorite() {
        UISelectionFeedbackGenerator().selectionChanged()
        player.isFavorite.toggle()
        guard AppPersistence.save(modelContext) else { return }
    }

    private var nameLines: [String] {
        let name = displayName
        guard let separator = name.firstIndex(where: { $0 == " " || $0 == "　" || $0 == "・" }) else { return [name] }
        let first = String(name[..<separator])
        let rest = String(name[name.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        return first.isEmpty || rest.isEmpty ? [name] : [first, rest]
    }

    // 名前の上に小さく出す読み(英語表記を優先、なければかな)
    private var nameSubtitle: String? {
        if let roman = player.nameRoman, !roman.isEmpty { return roman }
        if let kana = player.nameKana, !kana.isEmpty { return kana }
        return nil
    }

    // MARK: - タブ

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(DetailTab.allCases) { tab in
                let isSelected = selectedTab == tab
                Button { selectedTab = tab } label: {
                    VStack(spacing: 8) {
                        Text(tab.title)
                            .font(.headline.weight(isSelected ? .heavy : .semibold))
                            .foregroundStyle(isSelected ? RugbyTheme.textPrimary : RugbyTheme.textSecondary)
                        Capsule()
                            .fill(isSelected ? RugbyTheme.highlight : Color.clear)
                            .frame(height: 3)
                    }
                    .padding(.top, 14)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 12)
        .padContentWidth(760)
        .background(RugbyTheme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(RugbyTheme.border).frame(height: 1) }
    }

    // MARK: - 概要: プロフィール

    private var profileCard: some View {
        let items: [(label: String, value: String)] = [
            ("背番号", player.number.map { "#\($0)" } ?? "—"),
            ("ポジション", player.rugbyPosition?.name ?? "—"),
            ("年齢", ageText ?? "—"),
            ("生年月日", player.birthDate.map { Self.birthDateFormatter.string(from: $0) } ?? "—"),
            ("身長", player.heightCm.map { "\($0)cm" } ?? "—"),
            ("体重", player.weightKg.map { "\($0)kg" } ?? "—")
        ]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
                         alignment: .leading, spacing: 18) {
            ForEach(items, id: \.label) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.label)
                        .font(.caption)
                        .foregroundStyle(RugbyTheme.textSecondary)
                    Text(item.value)
                        .font(.headline.weight(.bold).monospacedDigit())
                        .foregroundStyle(RugbyTheme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(18)
        .detailCard()
    }

    private var ageText: String? {
        guard let birthDate = player.birthDate,
              let age = Calendar.current.dateComponents([.year], from: birthDate, to: Date()).year
        else { return nil }
        return "\(age)歳"
    }

    // MARK: - 概要: 通算成績

    private var recordSection: some View {
        let totals = snapshot.totals
        return VStack(alignment: .leading, spacing: 10) {
            sectionTitle("通算成績")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                recordTile(label: "試合", value: "\(snapshot.countedMatchCount)")
                recordTile(label: "トライ", value: "\(totals.tries)")
                recordTile(label: "得点", value: "\(totals.points)")
                recordTile(label: "出場時間", value: snapshot.totalPlayingMinutesText)
            }
            HStack {
                Text("キック")
                    .foregroundStyle(RugbyTheme.textSecondary)
                Spacer()
                Text("G \(totals.conversions)・PG \(totals.penaltyGoals)・DG \(totals.dropGoals)")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(RugbyTheme.textPrimary)
            }
            .font(.subheadline)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .detailCard()
            Text("出場時間は、スタメン(メンバー表)が登録された試合の記録と交代から自動計算します。「集計対象外」の試合は数えません。"
                 + (snapshot.linkedTeamCount > 1 ? "同一人物としてつないだ\(snapshot.linkedTeamNames.joined(separator: "・"))の記録も含む通算です。チームごとは「内訳」で見られます。" : ""))
                .font(.caption)
                .foregroundStyle(RugbyTheme.textSecondary)
        }
    }

    private func recordTile(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(RugbyTheme.textSecondary)
            Text(value)
                .font(.system(size: 40, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(RugbyTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .detailCard()
        .accessibilityElement(children: .combine)
    }

    // MARK: - 概要: 直近の試合

    private var recentFormSection: some View {
        // 集計対象(分析に含める)試合だけを、新しい順の一覧から直近を取り、左から古い順に並べる
        let recent = Array(snapshot.matchRows
            .filter { !$0.match.isExcludedFromStats }
            .prefix(Self.recentFormCount)
            .reversed())
        return VStack(alignment: .leading, spacing: 10) {
            sectionTitle("直近の試合")
            if recent.isEmpty {
                Text("試合がまだありません")
                    .font(.subheadline)
                    .foregroundStyle(RugbyTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(18)
                    .detailCard()
            } else {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(recent) { row in
                        Button {
                            openedMatch = row.match
                        } label: {
                            formItem(row)
                        }
                        .buttonStyle(.plain)
                    }
                    // 5試合に満たないときも1枠の幅をそろえる
                    ForEach(recent.count..<Self.recentFormCount, id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 16)
                .detailCard()
                Text("分析・集計に含める試合のうち、左が古く右が最新です。点数は左がこの選手のチーム。色は勝ち(緑)・負け(赤)・引き分け(灰)。")
                    .font(.caption)
                    .foregroundStyle(RugbyTheme.textSecondary)
            }
        }
    }

    private func formItem(_ row: MatchRow) -> some View {
        let opponentID = row.opponentTeamID
        return VStack(spacing: 6) {
            Text(Self.shortDateFormatter.string(from: row.match.playedAt))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(RugbyTheme.textSecondary)
            teamLogo(opponentID, size: 34)
            Text(teamName(for: opponentID))
                .font(.caption2.weight(.bold))
                .foregroundStyle(RugbyTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(height: 16)
            Text(row.isHome ? "(H)" : "(A)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(RugbyTheme.textSecondary)
            // 左がこの選手のチームの点数
            Text("\(row.ownScore)-\(row.opponentScore)")
                .font(.caption.weight(.heavy).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(resultColor(row), in: RoundedRectangle(cornerRadius: 5))
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(Self.shortDateFormatter.string(from: row.match.playedAt)) \(teamName(for: opponentID))戦 \(row.isHome ? "ホーム" : "アウェイ") \(row.ownScore)対\(row.opponentScore)")
    }

    private func resultColor(_ row: MatchRow) -> Color {
        if row.ownScore > row.opponentScore { return Color(red: 0.13, green: 0.55, blue: 0.27) }
        if row.ownScore < row.opponentScore { return Color(red: 0.80, green: 0.20, blue: 0.20) }
        return Color(white: 0.55)
    }

    private var compareLink: some View {
        NavigationLink {
            AnalysisWorkspaceView(initialPlayerID: player.id)
        } label: {
            HStack {
                Label("この選手の全指標を比較する", systemImage: "chart.bar.xaxis")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(RugbyTheme.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(RugbyTheme.textSecondary)
            }
            .padding(18)
            .detailCard()
        }
        .buttonStyle(.plain)
    }

    // MARK: - 内訳(チーム別・年度別・大会別)

    private var breakdownRows: [BreakdownRow] {
        switch breakdownKind {
        case .team: return snapshot.byTeam
        case .category: return snapshot.byCategory
        case .season: return snapshot.bySeason
        case .tournament: return snapshot.byTournament
        }
    }

    private var breakdownSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(BreakdownKind.allCases) { kind in
                    let isSelected = breakdownKind == kind
                    Button { breakdownKind = kind } label: {
                        Text(kind.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(isSelected ? RugbyTheme.onAccent : RugbyTheme.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(isSelected ? RugbyTheme.accent : RugbyTheme.surface,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            VStack(spacing: 0) {
                if breakdownRows.isEmpty {
                    Text("記録がまだありません")
                        .foregroundStyle(RugbyTheme.textSecondary)
                        .padding(18)
                } else {
                    let columns = statColumns(breakdownRows.map(\.totals))
                    statHeader(breakdownKind.title.replacingOccurrences(of: "別", with: ""), columns: columns)
                    Divider()
                    ForEach(Array(breakdownRows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider().padding(.leading, 18) }
                        breakdownRowView(row, columns: columns)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .detailCard()
            Text(breakdownFootnote)
                .font(.caption)
                .foregroundStyle(RugbyTheme.textSecondary)
        }
    }

    private var breakdownFootnote: String {
        var text = Self.statLegend + "「集計対象外」の試合は数えません。"
        if breakdownKind == .season { text += "年度は大会の年度で、未設定の大会は試合日の年で分けます。" }
        if breakdownKind == .category { text += "カテゴリーと7人制/15人制は大会の設定で分けます。" }
        if snapshot.linkedTeamCount > 1 { text += "同一人物としてつないだほかのチームの記録も含みます。" }
        return text
    }

    /// 内訳・試合一覧の数字の列。見出しを上に1回だけ出し、数字を縦にそろえて行どうしを比べやすくする
    /// (FotMob の経歴・Apple Sports の順位表と同じ形)。トライと得点は常に出し、
    /// G・PG・DG は一覧のどこかに1本でもあるときだけ列を出す(全部0の列で名前の幅を削らない)。
    private enum StatColumn: String, CaseIterable {
        case tries = "T", conversions = "G", penaltyGoals = "PG", dropGoals = "DG"

        func value(_ totals: ScoringTotals) -> Int {
            switch self {
            case .tries: return totals.tries
            case .conversions: return totals.conversions
            case .penaltyGoals: return totals.penaltyGoals
            case .dropGoals: return totals.dropGoals
            }
        }

        var spokenName: String {
            switch self {
            case .tries: return "トライ"
            case .conversions: return "コンバージョン"
            case .penaltyGoals: return "ペナルティゴール"
            case .dropGoals: return "ドロップゴール"
            }
        }
    }

    private static let statLegend = "T=トライ、G=コンバージョン、PG=ペナルティゴール、DG=ドロップゴール、PTS=得点。"
    private static let statCountWidth: CGFloat = 28
    private static let statPointsWidth: CGFloat = 40
    private static let chevronWidth: CGFloat = 10

    private func statColumns(_ totals: [ScoringTotals]) -> [StatColumn] {
        StatColumn.allCases.filter { column in
            column == .tries || totals.contains { column.value($0) > 0 }
        }
    }

    /// 列の見出し。行の右端に矢印があるときは trailingWidth ぶん空けて列の位置を合わせる
    private func statHeader(_ title: String, columns: [StatColumn], trailingWidth: CGFloat? = nil) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 0)
            statGrid(columns) { column in
                Text(column.rawValue)
            } points: {
                Text("PTS")
            }
            if let trailingWidth {
                Color.clear.frame(width: trailingWidth, height: 1)
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(RugbyTheme.textSecondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .accessibilityHidden(true)
    }

    /// 見出しと各行で同じ幅・同じ間隔の列を作る(ずれないように1か所で決める)。列の中は中央揃え
    private func statGrid<Count: View, Points: View>(
        _ columns: [StatColumn],
        @ViewBuilder count: @escaping (StatColumn) -> Count,
        @ViewBuilder points: () -> Points
    ) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(columns, id: \.self) { column in
                    count(column).frame(width: Self.statCountWidth, alignment: .center)
                }
            }
            points().frame(width: Self.statPointsWidth, alignment: .center)
        }
    }

    private func statNumbers(_ totals: ScoringTotals, columns: [StatColumn]) -> some View {
        statGrid(columns) { column in
            statValue(column.value(totals))
        } points: {
            statValue(totals.points)
        }
    }

    /// 列の数字はすべて同じ大きさ。0は薄く、記録のある数字を目立たせる
    private func statValue(_ value: Int) -> some View {
        Text("\(value)")
            .font(.subheadline.weight(.semibold).monospacedDigit())
            .foregroundStyle(value == 0 ? RugbyTheme.textSecondary.opacity(0.45) : RugbyTheme.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private func statSpokenValue(_ totals: ScoringTotals, columns: [StatColumn]) -> [String] {
        columns.map { "\($0.spokenName)\($0.value(totals))" } + ["\(totals.points)点"]
    }

    private func breakdownRowView(_ row: BreakdownRow, columns: [StatColumn]) -> some View {
        HStack(spacing: 12) {
            if let teamID = row.teamID {
                teamLogo(teamID, size: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(RugbyTheme.textPrimary)
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
                Text(row.detail)
                    .font(.caption)
                    .foregroundStyle(RugbyTheme.textSecondary)
            }
            Spacer(minLength: 0)
            statNumbers(row.totals, columns: columns)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.name)
        .accessibilityValue((statSpokenValue(row.totals, columns: columns) + [row.detail]).joined(separator: "、"))
    }

    // MARK: - 試合一覧

    private var matchesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("試合（\(snapshot.matchRows.count)）")
            VStack(spacing: 0) {
                if snapshot.matchRows.isEmpty {
                    Text("試合がまだありません")
                        .foregroundStyle(RugbyTheme.textSecondary)
                        .padding(18)
                } else {
                    let columns = statColumns(snapshot.matchRows.map(\.totals))
                    statHeader("試合", columns: columns, trailingWidth: Self.chevronWidth)
                    Divider()
                    ForEach(Array(snapshot.matchRows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider().padding(.leading, 18) }
                        Button {
                            openedMatch = row.match
                        } label: {
                            matchRow(row, columns: columns)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .detailCard()
            Text(Self.statLegend + "メンバー表に登録された試合と、得点記録のある試合を表示しています。「集計対象外」の試合は通算・大会別の成績に数えません。")
                .font(.caption)
                .foregroundStyle(RugbyTheme.textSecondary)
        }
    }

    /// 1試合の行。選手の画面なので自チーム名は省き、相手のロゴと名前を主役にする
    /// (FotMob の選手「Matches」と同じ形)。上の行に日付・出場分、下の行に勝敗の印とスコア(自チームが先)。
    private func matchRow(_ row: MatchRow, columns: [StatColumn]) -> some View {
        let match = row.match
        let opponent = "vs \(teamName(for: row.opponentTeamID))"
        let detail = [Self.dateFormatter.string(from: match.playedAt),
                      row.playingMinutes.map { "\($0)分" },
                      match.isExcludedFromStats ? "集計対象外" : nil]
            .compactMap { $0 }
            .joined(separator: " · ")

        return HStack(spacing: 12) {
            teamLogo(row.opponentTeamID, size: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(RugbyTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(opponent)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(RugbyTheme.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                HStack(spacing: 6) {
                    resultBadge(row)
                    Text("\(row.ownScore)-\(row.opponentScore)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(RugbyTheme.textPrimary)
                }
            }
            Spacer(minLength: 0)
            statNumbers(row.totals, columns: columns)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(RugbyTheme.textSecondary)
                .frame(width: Self.chevronWidth)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(opponent)
        .accessibilityValue(([resultText(row), "\(row.ownScore)対\(row.opponentScore)", detail]
                             + statSpokenValue(row.totals, columns: columns)).joined(separator: "、"))
        .accessibilityAddTraits(.isButton)
    }

    private func resultText(_ row: MatchRow) -> String {
        row.ownScore > row.opponentScore ? "勝" : row.ownScore < row.opponentScore ? "負" : "分"
    }

    /// 勝ち=所属チームの色、負け=濃い灰、引き分け=薄い灰(チーム成績の画面と同じ色分け)
    private func resultBadge(_ row: MatchRow) -> some View {
        let color: Color
        if row.ownScore > row.opponentScore {
            color = teams.first { $0.id == row.teamID }?.displayColor ?? RugbyTheme.accent
        } else if row.ownScore < row.opponentScore {
            color = TeamPerformanceColors.charcoal
        } else {
            color = Color(red: 0.60, green: 0.61, blue: 0.64)
        }
        return Text(resultText(row))
            .font(.caption2.weight(.heavy))
            .foregroundStyle(color.prefersDarkText ? RugbyTheme.textPrimary : .white)
            .frame(width: 20, height: 18)
            .background(color, in: RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - 集計

    private struct ScoringTotals {
        var tries = 0
        var conversions = 0
        var penaltyGoals = 0
        var dropGoals = 0
        var points = 0

        mutating func add(_ event: StatEvent) {
            switch ScoringCategory(rawValue: event.category) {
            case .tryScore:
                tries += 1
                points += 5
            case .conversion:
                conversions += 1
                points += 2
            case .penaltyGoal:
                penaltyGoals += 1
                points += 3
            case .dropGoal:
                dropGoals += 1
                points += 3
            case .penaltyTry, nil:
                // 認定トライは選手の得点にしない(ルール上、個人に記録されない)
                break
            }
        }

        mutating func add(_ other: ScoringTotals) {
            tries += other.tries
            conversions += other.conversions
            penaltyGoals += other.penaltyGoals
            dropGoals += other.dropGoals
            points += other.points
        }
    }

    /// 内訳の1行(チーム・年度・大会のどれか1つぶん)
    private struct BreakdownRow: Identifiable {
        let id: String
        let name: String
        var teamID: UUID? = nil
        var matchCount = 0
        var minutes = 0
        var hasMinutes = false
        var totals = ScoringTotals()
        /// 並べ替えの基準。年度は年、チーム・カテゴリー・大会は一番新しい出場日。どれも大きい(新しい)順に並べる
        var sortKey = 0

        var detail: String {
            hasMinutes ? "\(matchCount)試合・\(minutes)分" : "\(matchCount)試合"
        }

        mutating func add(_ totals: ScoringTotals, minutes: Int?) {
            matchCount += 1
            self.totals.add(totals)
            if let minutes {
                self.minutes += minutes
                hasMinutes = true
            }
        }
    }

    private struct MatchRow: Identifiable {
        let match: Match
        let totals: ScoringTotals
        // その試合での出場分数(スタメン未登録の試合は計算不可 = nil)
        let playingMinutes: Int?
        // この選手がどちらのチームで出たか(メンバー表があればその試合のチーム、なければ得点記録のチーム、今の所属の順)
        let isHome: Bool
        let teamID: UUID
        let homeScore: Int
        let awayScore: Int
        var id: UUID { match.id }
        var opponentTeamID: UUID { isHome ? match.awayTeamID : match.homeTeamID }
        var ownScore: Int { isHome ? homeScore : awayScore }
        var opponentScore: Int { isHome ? awayScore : homeScore }
    }

    /// 画面に出す数字をまとめたもの。開いたときと保存があったときに作り直す。
    private struct Snapshot {
        // メンバー表登録 or 得点記録のある試合(新しい順)。集計対象外の試合も含む
        var matchRows: [MatchRow] = []
        // 通算・大会別は集計対象外にした試合を除く
        var countedMatchCount = 0
        var totals = ScoringTotals()
        var totalPlayingMinutesText = "—"
        var byTeam: [BreakdownRow] = []
        var byCategory: [BreakdownRow] = []
        var bySeason: [BreakdownRow] = []
        var byTournament: [BreakdownRow] = []
        // 同一人物としてつないだ登録のチーム数(1ならつないでいない)
        var linkedTeamCount = 1
        var linkedTeamNames: [String] = []
    }

    private func loadSnapshot() {
        let categories = ScoringRules.categories

        // 同一人物としてつないだ登録(移籍・代表など)もまとめて数える。つないでいなければこの選手だけ
        let linkedPlayers = PersonLink.linkedPlayers(of: player, context: modelContext)
        let linkedIDs = Set(linkedPlayers.map(\.id))

        // その選手たちのメンバー表の行と、成功した得点記録だけを読む
        var myLineups: [MatchLineup] = []
        var myScoringEvents: [StatEvent] = []
        for linkedID in linkedIDs {
            let optionalID: UUID? = linkedID
            myLineups += fetch(FetchDescriptor<MatchLineup>(predicate: #Predicate { $0.playerID == linkedID }))
            myScoringEvents += fetch(FetchDescriptor<StatEvent>(predicate: #Predicate {
                $0.playerID == optionalID && $0.outcome == "success" && categories.contains($0.category)
            }))
        }

        let matchIDs = Array(Set(myLineups.map(\.matchID)).union(myScoringEvents.map(\.matchID)))
        let matches = fetch(FetchDescriptor<Match>(
            predicate: #Predicate { matchIDs.contains($0.id) },
            sortBy: [SortDescriptor(\.playedAt, order: .reverse)]
        ))

        // 試合のスコア(両チームの成功した得点)。直近の試合の勝ち負けに使う
        let matchScoringEvents = fetch(FetchDescriptor<StatEvent>(predicate: #Predicate {
            matchIDs.contains($0.matchID) && $0.outcome == "success" && categories.contains($0.category)
        }))
        var pointsByMatchTeam: [UUID: [UUID: Int]] = [:]
        for event in matchScoringEvents {
            guard let teamID = event.teamID else { continue }
            pointsByMatchTeam[event.matchID, default: [:]][teamID, default: 0] += ScoringRules.points(category: event.category, widgetData: event.widgetData)
        }
        let lineupTeamByMatch = Dictionary(myLineups.map { ($0.matchID, $0.teamID) }, uniquingKeysWith: { first, _ in first })
        let scoringTeamByMatch = Dictionary(myScoringEvents.compactMap { event in event.teamID.map { (event.matchID, $0) } },
                                            uniquingKeysWith: { first, _ in first })

        // 出場時間: スタメンが登録された試合だけ、その試合の交代と記録を読んで計算する
        let starters = fetch(FetchDescriptor<MatchLineup>(predicate: #Predicate {
            matchIDs.contains($0.matchID) && $0.role == "starter"
        }))
        let starterMatchIDs = Array(Set(starters.map(\.matchID)))
        let substitutions = fetch(FetchDescriptor<Substitution>(predicate: #Predicate { starterMatchIDs.contains($0.matchID) }))
        let timedEvents = fetch(FetchDescriptor<StatEvent>(predicate: #Predicate { starterMatchIDs.contains($0.matchID) }))
        let startersByMatch = Dictionary(grouping: starters, by: \.matchID)
        let substitutionsByMatch = Dictionary(grouping: substitutions, by: \.matchID)
        let timedEventsByMatch = Dictionary(grouping: timedEvents, by: \.matchID)

        var totalsByMatch: [UUID: ScoringTotals] = [:]
        for event in myScoringEvents {
            totalsByMatch[event.matchID, default: ScoringTotals()].add(event)
        }

        var result = Snapshot()
        var totalMinutes = 0
        var hasAnyComputableMatch = false
        var byTeam: [UUID: BreakdownRow] = [:]
        var byCategory: [String: BreakdownRow] = [:]
        var bySeason: [Int: BreakdownRow] = [:]
        var byTournament: [UUID: BreakdownRow] = [:]
        let calendar = Calendar(identifier: .gregorian)

        for match in matches {
            var minutes: Int?
            if let matchStarters = startersByMatch[match.id] {
                let calculated = PlayingTimeCalculator.calculate(
                    matchID: match.id,
                    lineups: matchStarters,
                    substitutions: substitutionsByMatch[match.id] ?? [],
                    events: timedEventsByMatch[match.id] ?? []
                )
                if calculated.hasStarterInfo {
                    minutes = linkedIDs.reduce(0) { $0 + (calculated.minutesByPlayer[$1] ?? 0) }
                }
            }
            let totals = totalsByMatch[match.id] ?? ScoringTotals()
            let side = lineupTeamByMatch[match.id] ?? scoringTeamByMatch[match.id] ?? player.teamID
            let points = pointsByMatchTeam[match.id] ?? [:]
            result.matchRows.append(MatchRow(
                match: match,
                totals: totals,
                playingMinutes: minutes,
                isHome: side != match.awayTeamID,
                teamID: side,
                homeScore: points[match.homeTeamID] ?? 0,
                awayScore: points[match.awayTeamID] ?? 0
            ))

            guard !match.isExcludedFromStats else { continue }
            result.countedMatchCount += 1
            result.totals.add(totals)
            if let minutes {
                totalMinutes += minutes
                hasAnyComputableMatch = true
            }

            let tournament = tournaments.first { $0.id == match.tournamentID }
            let season = tournament?.year ?? calendar.component(.year, from: match.playedAt)
            // 試合は新しい順に回すので、行を最初に作ったときの試合日が、そのチーム・カテゴリー・大会で一番新しい出場日
            let latestPlayed = Int(match.playedAt.timeIntervalSince1970)
            byTeam[side, default: BreakdownRow(id: side.uuidString, name: teamName(for: side), teamID: side,
                                               sortKey: latestPlayed)]
                .add(totals, minutes: minutes)
            bySeason[season, default: BreakdownRow(id: "\(season)", name: "\(String(season))年度", sortKey: season)]
                .add(totals, minutes: minutes)
            // カテゴリー(トップ・大学など)と 7人制/15人制 の組み合わせごと
            let categoryName = TournamentCategory.label(category: tournament?.category, variantRaw: tournament?.variantRaw,
                                                        genderRaw: tournament?.genderRaw) ?? "カテゴリー未設定"
            byCategory[categoryName, default: BreakdownRow(id: "category-" + categoryName, name: categoryName,
                                                           sortKey: latestPlayed)]
                .add(totals, minutes: minutes)
            byTournament[match.tournamentID, default: BreakdownRow(
                id: match.tournamentID.uuidString, name: tournament?.officialName ?? "大会未設定",
                sortKey: latestPlayed)]
                .add(totals, minutes: minutes)
        }

        result.totalPlayingMinutesText = hasAnyComputableMatch ? "\(totalMinutes)分" : "—"
        // どれも新しい順(年度は新しい年度、ほかは一番新しい出場日)。同じなら名前順
        let newestFirst: (BreakdownRow, BreakdownRow) -> Bool = { ($0.sortKey, $1.name) > ($1.sortKey, $0.name) }
        result.byTeam = byTeam.values.sorted(by: newestFirst)
        result.bySeason = bySeason.values.sorted(by: newestFirst)
        result.byCategory = byCategory.values.sorted(by: newestFirst)
        result.byTournament = byTournament.values.sorted(by: newestFirst)
        let linkedTeamIDs = Set(linkedPlayers.map(\.teamID))
        result.linkedTeamCount = linkedTeamIDs.count
        result.linkedTeamNames = linkedTeamIDs.filter { $0 != player.teamID }.map { teamName(for: $0) }.sorted()
        snapshot = result
    }

    private func fetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) -> [T] {
        (try? modelContext.fetch(descriptor)) ?? []
    }

    // MARK: - 小さな部品

    private var displayName: String {
        if let name = player.name, !name.isEmpty {
            return name
        }
        return player.number.map { "#\($0)" } ?? "名前未設定"
    }

    private func teamName(for teamID: UUID) -> String {
        teams.first { $0.id == teamID }?.name ?? "チーム未設定"
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.title3.weight(.heavy))
            .foregroundStyle(RugbyTheme.textPrimary)
            .accessibilityAddTraits(.isHeader)
    }

    private func teamLogo(_ teamID: UUID, size: CGFloat) -> some View {
        let logoTeam = teams.first { $0.id == teamID }
        let accent = logoTeam?.displayColor ?? RugbyTheme.textSecondary
        return StoredImageView(name: logoTeam?.logoPath, maxDimension: size * 3) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            Image(systemName: "shield.lefthalf.filled")
                .resizable()
                .scaledToFit()
                .padding(size * 0.1)
                .foregroundStyle(accent)
        }
        .frame(width: size, height: size)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter
    }()

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d"
        return formatter
    }()

    private static let birthDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy/M/d"
        return formatter
    }()
}

private extension View {
    // 選手詳細のカード(白い面・角丸)
    func detailCard() -> some View {
        background(RugbyTheme.surface, in: RoundedRectangle(cornerRadius: 18))
    }
}

#Preview {
    NavigationStack {
        PlayerDetailView(player: Player(teamID: UUID(), number: 10, name: "山田 太郎"))
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
