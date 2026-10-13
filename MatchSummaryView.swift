//
//  MatchSummaryView.swift
//  Rugby AS
//
//  Created by Codex on 2026/05/17.
//

import SwiftData
import SwiftUI
import UIKit

struct MatchSummaryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPadLayout) private var isPadLayout
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query(sort: \Player.number) private var allPlayers: [Player]
    @Query private var matchEvents: [StatEvent]
    @Query private var teams: [Team]
    @Query private var tournaments: [Tournament]
    @Query private var allSubstitutions: [Substitution]
    @Query private var allLineups: [MatchLineup]

    let match: Match

    @State private var scoringEventForPlayerSelection: StatEvent?
    @State private var timeEditingEvent: StatEvent?
    @State private var isLegacyRecordingPresented = false
    @State private var isTimelineEditorPresented = false
    @State private var isPlayListEditorPresented = false
    // プレー編集を開いたときに最初に選んでおく記録(得点の行から飛んだとき)
    @State private var playListInitialEventID: UUID?
    @State private var selectedScope: SummaryScope = .all
    @State private var selectedSection: SummarySection = .overview
    // 得点経過チャートで選択中の得点(タップで吹き出し表示)
    @State private var selectedProgressionEventID: UUID?
    // 得点差グラフの視点。nil なら自動(最終勝者、同点はHOME)
    // 「画像で共有」で生成したサマリー画像(セット中はプレビューシートを表示)
    @State private var exportedSummaryImage: UIImage?
    // 交代の追加シート
    @State private var isSubstitutionSheetPresented = false

    private enum SummarySection: String, CaseIterable, Identifiable {
        case overview = "概要"
        case stats = "スタッツ"
        case members = "メンバー"
        case headToHead = "対戦成績"

        var id: String { rawValue }
    }

    private enum SummaryScope: String, CaseIterable, Identifiable {
        case all
        case first
        case second

        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "全体"
            case .first: return "前半"
            case .second: return "後半"
            }
        }
        var half: Int? {
            switch self {
            case .all: return nil
            case .first: return 0
            case .second: return 1
            }
        }
    }

    private var scopeSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 36)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height
                guard abs(horizontal) > abs(vertical) * 1.4 else { return }

                if horizontal < 0 {
                    moveScope(forward: true)
                } else {
                    moveScope(forward: false)
                }
            }
    }

    init(match: Match) {
        self.match = match
        let matchID = match.id
        let homeID = match.homeTeamID, awayID = match.awayTeamID
        _allPlayers = Query(filter: #Predicate<Player> { $0.teamID == homeID || $0.teamID == awayID }, sort: [SortDescriptor(\Player.number)])
        _allLineups = Query(filter: #Predicate<MatchLineup> { $0.matchID == matchID })
        _allSubstitutions = Query(filter: #Predicate<Substitution> { $0.matchID == matchID })
        _matchEvents = Query(filter: #Predicate<StatEvent> { event in
            event.matchID == matchID
        })
    }

    // MARK: - Derived collections

    private var players: [Player] {
        allPlayers
            .filter { $0.teamID == match.homeTeamID || $0.teamID == match.awayTeamID }
            .sorted { lhs, rhs in
                if lhs.teamID == rhs.teamID {
                    return (lhs.number ?? Int.max) < (rhs.number ?? Int.max)
                }
                return lhs.teamID == match.homeTeamID
            }
    }

    private var possessionEvents: [StatEvent] {
        matchEvents.filter { $0.category == "possession" }
    }

    private var scoringEvents: [StatEvent] {
        matchEvents
            .filter { ScoringCategory(rawValue: $0.category) != nil }
            .sorted { MatchStatistics.scoringEventPrecedes($0, $1) }
    }

    private var setPieceEvents: [StatEvent] {
        matchEvents.filter { $0.category == "lineout" || $0.category == "scrum" }
    }

    private var isFinished: Bool {
        matchEvents.contains { $0.category == "match_state" && $0.outcome == "finished" }
    }

    // この試合の全記録をCSVにしたもの(共有ボタンから書き出す)
    private var csvFile: MatchCSVFile {
        MatchCSVExporter.makeFile(
            match: match,
            events: matchEvents,
            teams: teams,
            players: players,
            lineups: matchLineups,
            tournamentName: tournaments.first { $0.id == match.tournamentID }?.officialName ?? "大会未設定"
        )
    }

    // Screen chrome retains the standard palette; only selected statistics use team colors.
    private var homeAccent: Color { RugbyTheme.accent }
    // チームの色がないときのアウェイの色。チームの色は配色で変えないので、ここも固定の色にする
    private var awayAccent: Color { RugbyTheme.fixedRed }

    private var homeStatisticsColor: Color { teamAccent(for: match.homeTeamID, fallback: homeAccent) }
    private var awayStatisticsColor: Color { teamAccent(for: match.awayTeamID, fallback: awayAccent) }

    private func teamAccent(for teamID: UUID, fallback: Color) -> Color {
        guard let team = teams.first(where: { $0.id == teamID }) else { return fallback }
        let color = team.displayColor
        guard teamID == match.awayTeamID,
              let home = teams.first(where: { $0.id == match.homeTeamID }) else { return color }
        let homeColor = home.displayColor
        // アウェイの仮の色がホームの色と似ていたら、左右の見分けがつくよう既定の色にする
        if team.colorHex == nil {
            return color.rgbDistance(to: homeColor) < 0.35 ? fallback : color
        }
        // 両チームとも色を決めていても、似ていたら(黒と紺など)アウェイの明るさをずらして見分けられるようにする。
        // 保存されているチームの色は変えず、この試合の表示だけ。
        return TeamColorPalette.matchupColor(color, against: homeColor)
    }

    /// 各得点イベント時点での「ここまでの累計スコア」を返す。
    /// scoringEvents が時系列ソート済みであることに依存。
    private var scoringProgression: [UUID: (home: Int, away: Int)] {
        var home = 0
        var away = 0
        var map: [UUID: (Int, Int)] = [:]
        for event in scoringEvents {
            let value = scoreValue(for: event)
            if event.teamID == match.homeTeamID {
                home += value
            } else if event.teamID == match.awayTeamID {
                away += value
            }
            map[event.id] = (home, away)
        }
        return map
    }

    // MARK: - Body

    private var isSummaryCovered: Bool {
        isLegacyRecordingPresented || isTimelineEditorPresented || isPlayListEditorPresented
    }

    var body: some View {
        ZStack {
            RugbyTheme.surface.ignoresSafeArea()

            // A full-screen recorder saves on every tap. Do not rebuild hidden
            // charts, player rows or CSV exports in response to those saves.
            if !isSummaryCovered {
                VStack(spacing: 0) {
                    topBar
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .padContentWidth(860)
                        .background(RugbyTheme.header, ignoresSafeAreaEdges: [])
                    ScrollView {
                        VStack(spacing: 0) {
                            scoreHeaderCard
                            sectionPicker
                            VStack(alignment: .leading, spacing: 16) {
                                // 対戦成績は試合をまたぐので、前半・後半の切り替えは出さない
                                if selectedSection != .headToHead {
                                    scopePicker
                                }
                                switch selectedSection {
                                case .overview:
                                    scoringProgressionCard
                                    scoreMarginCard
                                    statsInclusionCard
                                case .stats:
                                    possessionCard
                                    let metricsLayout = isPadLayout && !dynamicTypeSize.isAccessibilitySize
                                        ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                                        : AnyLayout(VStackLayout(spacing: 16))
                                    metricsLayout {
                                        scoringBreakdownCard
                                        setPieceCard
                                    }
                                    attackOriginCard
                                case .members:
                                    scorerTimelineCard
                                    playingTimeNote
                                    substitutionCard
                                    registeredLineups
                                case .headToHead:
                                    MatchHeadToHeadView(
                                        match: match,
                                        homeTeam: teams.first { $0.id == match.homeTeamID },
                                        awayTeam: teams.first { $0.id == match.awayTeamID },
                                        homeColor: teamAccent(for: match.homeTeamID, fallback: homeAccent),
                                        awayColor: teamAccent(for: match.awayTeamID, fallback: awayAccent)
                                    )
                                }
                                matchActions
                                // 公式記録から取り込んだ試合だけ、公式の試合ページ・記録表へのリンクを出す
                                OfficialMatchLinks(pageURL: match.officialPageURL, sheetURL: match.officialSheetURL)
                            }
                            .padding(16)
                        }
                        .padding(.bottom, 16)
                        // iPad では横に伸びきると数字が左右に離れて読みにくいので、
                        // 内容の最大幅を決めて中央に置く。iPhone では何も変わらない。
                        .padContentWidth(860)
                    }
                    .background(summaryBackground)
                    .simultaneousGesture(scopeSwipeGesture)

                    csvExportBar
                        .padContentWidth(860)
                }
            }
        }
        .tint(RugbyTheme.accent)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: selectedScope) { _, _ in
            selectedProgressionEventID = nil
        }
        .fullScreenCover(isPresented: $isLegacyRecordingPresented) {
            V3RecordingView(match: match)
                .preferredColorScheme(.dark)
                .tint(.blue)
        }
        .fullScreenCover(isPresented: $isTimelineEditorPresented) {
            TimelineEditorView(match: match)
                .preferredColorScheme(.dark)
                .tint(.blue)
        }
        .fullScreenCover(isPresented: $isPlayListEditorPresented) {
            PlayListEditorView(match: match, initialEventID: playListInitialEventID)
                .preferredColorScheme(.dark)
                .tint(.blue)
        }
        .sheet(item: $scoringEventForPlayerSelection) { event in
            PlayerSelectionSheet(
                players: players.filter { $0.teamID == event.teamID },
                title: "得点者を選択",
                numberFor: { player in
                    MatchNumbering.number(for: player, matchID: match.id, lineups: matchLineups)
                }
            ) { player in
                guard player == nil || player?.teamID == event.teamID else { return }
                event.playerID = player?.id
                AppPersistence.save(modelContext)
                // 紐づけた選手の背番号を今の値で控える(過去の遡り変更を防ぐ)
                MatchNumbering.freezeNumbers(forMatch: match.id, context: modelContext)
                scoringEventForPlayerSelection = nil
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $timeEditingEvent) { event in
            ScoreTimeEditSheet(event: event) {
                AppPersistence.save(modelContext)
                timeEditingEvent = nil
            }
            .presentationDetents([.height(300), .medium])
        }
        .sheet(isPresented: Binding(
            get: { exportedSummaryImage != nil },
            set: { if !$0 { exportedSummaryImage = nil } }
        )) {
            if let exportedSummaryImage {
                SummaryImageShareSheet(image: exportedSummaryImage, title: summaryImageTitle)
            }
        }
    }

    // MARK: - Main layout

    private var summaryBackground: Color { RugbyTheme.background }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .foregroundStyle(RugbyTheme.onAccent)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("前の画面に戻る")

            Text("試合詳細")
                .font(.headline)
                .foregroundStyle(RugbyTheme.onAccent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)

            Button { isLegacyRecordingPresented = true } label: {
                Text("記録へ")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(RugbyTheme.onAccent)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(RugbyTheme.onAccent.opacity(0.35), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityHint("記録画面を選んで開きます")
        }
    }

    private var sectionPicker: some View {
        HStack(spacing: 0) {
            ForEach(SummarySection.allCases) { section in
                let selected = selectedSection == section
                Button { selectedSection = section } label: {
                    Text(section.rawValue)
                        .font(.subheadline.weight(selected ? .bold : .medium))
                        .foregroundStyle(selected ? RugbyTheme.accent : RugbyTheme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(selected ? RugbyTheme.highlight : .clear)
                                .frame(height: 3)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .background(RugbyTheme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(RugbyTheme.border).frame(height: 1) }
    }

    private var matchActions: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Button {
                playListInitialEventID = nil
                isPlayListEditorPresented = true
            } label: {
                secondaryActionLabel("プレーを編集", symbol: "square.and.pencil")
            }
            Button { isTimelineEditorPresented = true } label: {
                secondaryActionLabel("動画を分析", symbol: "play.rectangle")
            }
        }
        .buttonStyle(.plain)
    }

    private func secondaryActionLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(RugbyTheme.accent)
            Text(title).foregroundStyle(RugbyTheme.textPrimary)
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 46)
        .background(RugbyTheme.surface, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(RugbyTheme.border, lineWidth: 1))
    }

    // Sharing remains outside the scrollable report, so it is always reachable.
    private var csvExportBar: some View {
        let file = csvFile
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            ShareLink(item: file, preview: SharePreview(file.fileName)) {
                secondaryActionLabel("CSV出力", symbol: "square.and.arrow.up")
            }
            .accessibilityLabel("CSVで書き出し")

            Button { renderSummaryImage() } label: {
                secondaryActionLabel("画像で共有", symbol: "photo")
            }
            .accessibilityLabel("サマリーを画像で共有")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(RugbyTheme.background)
        .overlay(alignment: .top) { Rectangle().fill(RugbyTheme.border).frame(height: 1) }
    }

    // MARK: - サマリーの画像書き出し

    private var summaryImageTitle: String {
        "\(teamName(for: match.homeTeamID)) vs \(teamName(for: match.awayTeamID)) サマリー"
    }

    // 画像として書き出す中身(画面のカードをそのまま並べ、下にクレジットを足す)
    private var summaryImageContent: some View {
        VStack(spacing: 12) {
            scoreHeaderCard
            possessionCard
            scoringBreakdownCard
            setPieceCard
            attackOriginCard
            scoringProgressionCard
            scoreMarginCard
            scorerTimelineCard

            HStack {
                Text(tournaments.first { $0.id == match.tournamentID }?.officialName ?? "")
                    .lineLimit(1)
                Spacer()
                Text("Rugby AS")
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(RugbyTheme.textSecondary)
            .padding(.horizontal, 4)
        }
        .padding(12)
        .background(summaryBackground)
        .environment(\.colorScheme, .light)
        .environment(\.dynamicTypeSize, .large)
        .frame(width: 420)
    }

    // 画面の内容を1枚の画像にする(3倍解像度で鮮明に)
    @MainActor
    private func renderSummaryImage() {
        let renderer = ImageRenderer(content: summaryImageContent)
        renderer.scale = 3
        exportedSummaryImage = renderer.uiImage
    }

    // 分析・選手成績・大会の順位表/ランキング・大会CSV に、この試合を含めるかどうか。
    // 記録は消さないので、いつでも戻せる。
    private var statsInclusionCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { !match.isExcludedFromStats },
                set: { include in
                    match.isExcludedFromStats = !include
                    if !AppPersistence.save(modelContext) { match.isExcludedFromStats = include }
                }
            )) {
                Label("分析・集計に含める", systemImage: "chart.bar.xaxis")
                    .font(.headline)
                    .foregroundStyle(RugbyTheme.textPrimary)
            }
            .tint(RugbyTheme.accent)
            Text(match.isExcludedFromStats
                 ? "この試合は、分析・比較、選手の個人成績、大会の順位表・ランキング、大会CSVに含めていません。記録はそのまま残っています。"
                 : "オフにすると、分析・比較、選手の個人成績、大会の順位表・ランキング、大会CSVからこの試合を外します。記録は消えません。")
                .font(.caption)
                .foregroundStyle(RugbyTheme.textSecondary)
        }
        .padding(14)
        .summaryCard()
    }

    private var scoreHeaderCard: some View {
        MatchScoreHeaderView(
            home: headerSide(for: match.homeTeamID, fallback: homeAccent),
            away: headerSide(for: match.awayTeamID, fallback: awayAccent),
            scorerGroups: headerScorerGroups,
            tournamentName: tournaments.first { $0.id == match.tournamentID }?.officialName ?? "大会未設定",
            playedAt: match.playedAt,
            isFinished: isFinished,
            isExcludedFromStats: match.isExcludedFromStats
        )
    }

    private func headerSide(for teamID: UUID, fallback: Color) -> MatchScoreHeaderView.Side {
        MatchScoreHeaderView.Side(
            name: teamName(for: teamID),
            color: teamAccent(for: teamID, fallback: fallback),
            logoPath: teams.first { $0.id == teamID }?.logoPath,
            score: score(for: teamID),
            firstHalfScore: score(for: teamID, half: 0)
        )
    }

    // 見出しに出す得点者。成功した得点を種類ごと・選手ごとにまとめ、試合の通しの分を付ける
    // (例: "#11 山田 7', 52'")。後半の分は、得点経過グラフと同じく記録から決めた前半の長さに足して数える。
    private var headerScorerGroups: [MatchScoreHeaderView.ScorerGroup] {
        let firstHalfSeconds = halfAxisSeconds(0)
        let successes = scoringEvents.filter { $0.outcome == "success" }
        let kinds: [(category: ScoringCategory, tag: String)] = [
            (.tryScore, "T"), (.penaltyTry, "PT"), (.conversion, "G"), (.penaltyGoal, "PG"), (.dropGoal, "DG")
        ]
        func lines(_ events: [StatEvent]) -> [String] {
            var names: [String] = []
            var minutesByName: [String: [String]] = [:]
            for event in events {
                let name = scorerLabel(for: event)
                let base = event.half >= 1 ? firstHalfSeconds : 0
                let minute = Int((base + Double(event.seconds)) / 60) + 1
                if minutesByName[name] == nil { names.append(name) }
                minutesByName[name, default: []].append("\(minute)'")
            }
            return names.map { "\($0) \((minutesByName[$0] ?? []).joined(separator: ", "))" }
        }
        return kinds.compactMap { kind in
            let events = successes.filter { $0.category == kind.category.rawValue }
            let home = lines(events.filter { $0.teamID == match.homeTeamID })
            let away = lines(events.filter { $0.teamID == match.awayTeamID })
            guard !home.isEmpty || !away.isEmpty else { return nil }
            return MatchScoreHeaderView.ScorerGroup(id: kind.category.rawValue, tag: kind.tag, home: home, away: away)
        }
    }

    private var scopePicker: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            ForEach(SummaryScope.allCases) { scope in
                Button { selectedScope = scope } label: {
                    Text(scope.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(selectedScope == scope ? RugbyTheme.onAccent : RugbyTheme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(selectedScope == scope ? RugbyTheme.accent : RugbyTheme.surface,
                            in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(scope.title)のスタッツ")
                .accessibilityAddTraits(selectedScope == scope ? .isSelected : [])
            }
        }
    }

    private func teamLogoBox(teamID: UUID, size: CGFloat) -> some View {
        let team = teams.first { $0.id == teamID }
        let accent = teamAccent(for: teamID, fallback: teamID == match.homeTeamID ? homeAccent : awayAccent)
        // This view also renders offscreen for sharing; an async image task
        // would leave placeholders in an export before its cache is warm.
        return Group {
            if let name = team?.logoPath, let image = ImageStorage.thumbnail(named: name, maxDimension: 160) {
                Image(uiImage: image).resizable().scaledToFit().padding(5)
            } else {
                Image(systemName: "shield.lefthalf.filled")
                    .resizable().scaledToFit().padding(11)
                    .foregroundStyle(accent)
            }
        }
        .frame(width: size, height: size)
        .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(accent.opacity(0.18), lineWidth: 1))
        .accessibilityHidden(true)
    }

    private func teamPill(_ title: String, accent: Color) -> some View {
        Text(title)
            .font(.caption.weight(.black))
            .foregroundStyle(accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(accent.opacity(0.22))
            .clipShape(Capsule())
    }

    // MARK: - Possession

    private var possessionCard: some View {
        let half = selectedScope.half
        let possession = MatchStatistics.possessionTotals(events: possessionEvents, match: match, half: half)
        let homeSeconds = possession[.home] ?? 0
        let awaySeconds = possession[.away] ?? 0
        let bipSeconds = possession[.bip] ?? 0
        let teamsTotal = homeSeconds + awaySeconds
        let homeRatio = teamsTotal == 0 ? 0 : Double(homeSeconds) / Double(teamsTotal)
        let awayRatio = teamsTotal == 0 ? 0 : Double(awaySeconds) / Double(teamsTotal)

        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("ポゼッション")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(RugbyTheme.textPrimary)
                Spacer()
                Text("BIP \(RecordingFormatting.time(bipSeconds))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(RugbyTheme.textSecondary)
                Image(systemName: "info.circle")
                    .font(.callout.weight(.bold))
                    .foregroundStyle(RugbyTheme.textSecondary)
            }

            if teamsTotal == 0 {
                Text("割合を計算できるポゼッション記録がありません。")
                    .font(.caption)
                    .foregroundStyle(RugbyTheme.textSecondary)
            }
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(homeStatisticsColor)
                        .frame(width: max(0, proxy.size.width * homeRatio))
                    Rectangle()
                        .fill(awayStatisticsColor)
                        .frame(width: max(0, proxy.size.width * awayRatio))
                }
                .clipShape(Capsule())
            }
            .frame(height: 5)

            let possessionLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
                : AnyLayout(HStackLayout(alignment: .bottom))
            possessionLayout {
                VStack(alignment: .leading, spacing: 6) {
                    Text(teamsTotal == 0 ? "—" : percentText(homeRatio))
                        .font(.system(size: 26, weight: .black, design: .rounded).monospacedDigit())
                        .foregroundStyle(homeStatisticsColor)
                    HStack(spacing: 8) {
                        Text(RecordingFormatting.time(homeSeconds))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(RugbyTheme.textSecondary)
                        teamPill("HOME", accent: homeStatisticsColor)
                    }
                }
                if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 6) {
                    Text(teamsTotal == 0 ? "—" : percentText(awayRatio))
                        .font(.system(size: 26, weight: .black, design: .rounded).monospacedDigit())
                        .foregroundStyle(awayStatisticsColor)
                    HStack(spacing: 8) {
                        teamPill("AWAY", accent: awayStatisticsColor)
                        Text(RecordingFormatting.time(awaySeconds))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(RugbyTheme.textSecondary)
                    }
                }
            }
        }
        .padding(16)
        .summaryCard()
        .frame(maxWidth: .infinity)
    }

    // MARK: - Scoring breakdown

    private var scoringBreakdownCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("得点内訳", systemImage: "list.bullet.rectangle")
                .font(.headline.weight(.semibold))
                .foregroundStyle(RugbyTheme.textPrimary)
                .labelStyle(.titleAndIcon)

            HStack {
                Text("HOME")
                    .font(.caption.weight(.black))
                    .foregroundStyle(homeStatisticsColor)
                Spacer()
                Text("AWAY")
                    .font(.caption.weight(.black))
                    .foregroundStyle(awayStatisticsColor)
            }

            scoringBreakdownRow(.tryScore, symbol: "rugbyball")
            scoringBreakdownRow(.conversion, symbol: "figure.rugby")
            scoringBreakdownRow(.penaltyGoal, symbol: "p.circle")
            scoringBreakdownRow(.dropGoal, symbol: "d.circle")
            // 認定トライは滅多にないので、記録があるときだけ行を出す
            if scoringEvents.contains(where: { $0.category == ScoringCategory.penaltyTry.rawValue }) {
                scoringBreakdownRow(.penaltyTry, symbol: "checkmark.seal")
            }

            Divider()
                .overlay(RugbyTheme.border)

            HStack {
                Text("\(score(for: match.homeTeamID, half: selectedScope.half))")
                    .font(.system(size: 26, weight: .black, design: .rounded).monospacedDigit())
                    .foregroundStyle(homeStatisticsColor)
                    .frame(width: 48, alignment: .leading)
                Spacer()
                Text("合計")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(RugbyTheme.textSecondary)
                Spacer()
                Text("\(score(for: match.awayTeamID, half: selectedScope.half))")
                    .font(.system(size: 26, weight: .black, design: .rounded).monospacedDigit())
                    .foregroundStyle(awayStatisticsColor)
                    .frame(width: 48, alignment: .trailing)
            }
        }
        .padding(16)
        .summaryCard()
        .frame(maxWidth: .infinity)
    }

    private func scoringBreakdownRow(_ category: ScoringCategory, symbol: String) -> some View {
        let homeCount = countScoring(category, teamID: match.homeTeamID, half: selectedScope.half)
        let awayCount = countScoring(category, teamID: match.awayTeamID, half: selectedScope.half)

        return HStack(spacing: 6) {
            Text("\(homeCount)")
                .font(.headline.weight(.black).monospacedDigit())
                .foregroundStyle(homeStatisticsColor)
                .frame(width: 26, alignment: .leading)
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.subheadline)
                    .foregroundStyle(RugbyTheme.textSecondary)
                Text(category.displayName)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(RugbyTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .layoutPriority(1)
            }
            .frame(maxWidth: .infinity)
            Text("\(awayCount)")
                .font(.headline.weight(.black).monospacedDigit())
                .foregroundStyle(awayStatisticsColor)
                .frame(width: 26, alignment: .trailing)
        }
    }

    // MARK: - Set piece

    private var setPieceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("セットプレー", systemImage: "figure.rugby")
                .font(.headline.weight(.semibold))
                .foregroundStyle(RugbyTheme.textPrimary)

            setPieceRow(title: "ラインアウト", category: "lineout", symbol: "figure.rugby")

            Divider()
                .overlay(RugbyTheme.border)

            setPieceRow(title: "スクラム", category: "scrum", symbol: "circle.grid.cross")

            Divider()
                .overlay(RugbyTheme.border)

            penaltyRow
        }
        .padding(16)
        .summaryCard()
        .frame(maxWidth: .infinity)
    }

    // 反則数(犯した側に記録される)。少ない方が良い数字なのでゲージにはしない
    private var penaltyRow: some View {
        VStack(spacing: 6) {
            Text("ペナルティ(反則)")
                .font(.subheadline.weight(.black))
                .foregroundStyle(RugbyTheme.textPrimary)

            HStack(spacing: 8) {
                Text("\(penaltyCount(for: match.homeTeamID))")
                    .font(.title3.weight(.black).monospacedDigit())
                    .foregroundStyle(homeStatisticsColor)
                Spacer()
                Image(systemName: "flag.fill")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(RugbyTheme.textSecondary)
                Spacer()
                Text("\(penaltyCount(for: match.awayTeamID))")
                    .font(.title3.weight(.black).monospacedDigit())
                    .foregroundStyle(awayStatisticsColor)
            }
            .padding(.horizontal, 14)
        }
    }

    private func penaltyCount(for teamID: UUID) -> Int {
        matchEvents.filter { event in
            event.category == "penalty"
                && event.teamID == teamID
                && (selectedScope.half == nil || event.half == selectedScope.half)
        }.count
    }

    private func setPieceRow(title: String, category: String, symbol: String) -> some View {
        let home = setPieceStats(category: category, teamID: match.homeTeamID, half: selectedScope.half)
        let away = setPieceStats(category: category, teamID: match.awayTeamID, half: selectedScope.half)

        return VStack(spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(RugbyTheme.textPrimary)
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 20))
            layout {
                setPieceMeasure("HOME", success: home.success, total: home.total, rate: home.rate, accent: homeStatisticsColor)
                setPieceMeasure("AWAY", success: away.success, total: away.total, rate: away.rate, accent: awayStatisticsColor)
            }
        }
        .padding(.vertical, 6)
    }

    private func setPieceMeasure(_ side: String, success: Int, total: Int, rate: Double, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(side).font(.caption2.weight(.semibold)).foregroundStyle(RugbyTheme.textSecondary)
            Text(total == 0 ? "—" : percentText(rate))
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(RugbyTheme.textPrimary)
            GeometryReader { geometry in
                Rectangle().fill(RugbyTheme.elevated)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(accent)
                            .frame(width: geometry.size.width * max(0, min(rate, 1)))
                    }
            }
            .frame(height: 4)
            Text(total == 0 ? "記録なし" : "成功 \(success)/\(total)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(RugbyTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - 攻撃の起点

    // 起点別の集計行: (起点, HOME攻撃数, HOMEトライ数, AWAY攻撃数, AWAYトライ数)
    private var attackOriginRows: [(origin: PlayOrigin, homeAttacks: Int, homeTries: Int, awayAttacks: Int, awayTries: Int)] {
        let scoped = matchEvents.filter { event in
            selectedScope.half == nil || event.half == selectedScope.half
        }
        let attacks = scoped.filter { $0.category == "possession" && $0.outcome == "own" && $0.origin != nil }
        let tries = scoped.filter { ($0.category == "try" || $0.category == ScoringRules.penaltyTryCategory) && $0.origin != nil }

        return PlayOrigin.allCases.compactMap { origin in
            let homeAttacks = attacks.filter { $0.teamID == match.homeTeamID && $0.origin == origin.rawValue }.count
            let awayAttacks = attacks.filter { $0.teamID == match.awayTeamID && $0.origin == origin.rawValue }.count
            let homeTries = tries.filter { $0.teamID == match.homeTeamID && $0.origin == origin.rawValue }.count
            let awayTries = tries.filter { $0.teamID == match.awayTeamID && $0.origin == origin.rawValue }.count
            guard homeAttacks + awayAttacks + homeTries + awayTries > 0 else { return nil }
            return (origin, homeAttacks, homeTries, awayAttacks, awayTries)
        }
    }

    @ViewBuilder
    private var attackOriginCard: some View {
        let rows = attackOriginRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Label("攻撃の起点", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(RugbyTheme.textPrimary)
                    Spacer()
                    Text("攻撃回数 / うちトライ")
                        .font(.caption2)
                        .foregroundStyle(RugbyTheme.textSecondary)
                }

                ForEach(rows, id: \.origin) { row in
                    HStack(spacing: 8) {
                        Text(row.origin.displayName)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(RugbyTheme.textPrimary)
                            .frame(width: 104, alignment: .leading)

                        Spacer(minLength: 0)

                        Text("\(row.homeAttacks)回/\(row.homeTries)T")
                            .font(.subheadline.weight(.black).monospacedDigit())
                            .foregroundStyle(homeAccent)
                            .frame(width: 76, alignment: .trailing)

                        Rectangle()
                            .fill(RugbyTheme.border)
                            .frame(width: 1, height: 14)

                        Text("\(row.awayAttacks)回/\(row.awayTries)T")
                            .font(.subheadline.weight(.black).monospacedDigit())
                            .foregroundStyle(awayAccent)
                            .frame(width: 76, alignment: .leading)
                    }
                }
            }
            .padding(12)
            .summaryCard()
        }
    }

    // MARK: - Scorer timeline

    // MARK: - 得点経過チャート

    // チャートに置く1つの得点マーカー
    private struct ProgressionMarker: Identifiable {
        let id: UUID
        let axisSeconds: Double
        let isHome: Bool
        let letter: String
        let event: StatEvent
    }

    // その前後半の軸の長さ(秒)。実際の記録の最終時刻を分単位に切り上げる。
    // 形式(7人制/15人制)を決め打ちしないため、データから長さを決める。
    private func halfAxisSeconds(_ half: Int) -> Double {
        let endSeconds = MatchStatistics.halfEndSeconds(events: matchEvents, half: half)
        return max(60, ceil(endSeconds / 60) * 60)
    }

    // 表示スコープに応じた軸全体の長さと、HT(ハーフタイム)の位置
    private var progressionAxis: (total: Double, halftime: Double?) {
        if let half = selectedScope.half {
            return (halfAxisSeconds(half), nil)
        }
        let firstHalf = halfAxisSeconds(0)
        return (firstHalf + halfAxisSeconds(1), firstHalf)
    }

    private var progressionMarkers: [ProgressionMarker] {
        let firstHalfSeconds = halfAxisSeconds(0)
        return scoringEventsForSelectedScope
            // 成功した得点だけをチャートに置く(失敗したCON/PG/DGは表示しない)
            .filter { $0.outcome == "success" }
            .filter { $0.teamID == match.homeTeamID || $0.teamID == match.awayTeamID }
            .map { event in
                let base = (selectedScope.half == nil && event.half >= 1) ? firstHalfSeconds : 0
                return ProgressionMarker(
                    id: event.id,
                    axisSeconds: base + Double(event.seconds),
                    isHome: event.teamID == match.homeTeamID,
                    letter: progressionLetter(event.category),
                    event: event
                )
            }
    }

    private func progressionLetter(_ category: String) -> String {
        switch category {
        case "try": return "T"
        case "conversion": return "G"
        case "penalty_goal": return "PG"
        case "drop_goal": return "DG"
        case ScoringRules.penaltyTryCategory: return "PT"
        default: return "?"
        }
    }

    // 分表示の間隔。数字だらけにならないよう、試合の長さに合わせて
    // 1/2/5/10/20分刻みから「9個以内に収まる」ものを選ぶ。
    private func progressionTickSeconds(total: Double) -> Double {
        let totalMinutes = total / 60.0
        for minutes in [1.0, 2.0, 5.0, 10.0, 20.0] where totalMinutes / minutes <= 9 {
            return minutes * 60
        }
        return 30 * 60
    }

    private func progressionTimeLabel(for event: StatEvent) -> String {
        if selectedScope.half == nil {
            return "\(halfLabel(event.half)) \(timeText(event.seconds))"
        }
        return timeText(event.seconds)
    }

    /// 得点経過の印1つ。トライと直後のゴールは1つの印「T+G」にまとめる(重なって読めなくなるため)
    private struct ProgressionGroup: Identifiable {
        let axisSeconds: Double
        let isHome: Bool
        var label: String
        var events: [StatEvent]
        var homeScore: Int
        var awayScore: Int
        // 近い印と重ならないよう、行の外側へずらした段(0 = 軸にいちばん近い段)
        var lane = 0
        var id: UUID { events[0].id }
    }

    /// 得点の印の大きさ(種類によらず同じ丸)
    private func progressionChipWidth(_ label: String) -> CGFloat { 21 }

    private func progressionGroups(_ markers: [ProgressionMarker], axisTotal: Double) -> [ProgressionGroup] {
        let progression = scoringProgression
        var groups: [ProgressionGroup] = []
        for marker in markers.sorted(by: { $0.axisSeconds < $1.axisSeconds }) {
            let running = progression[marker.id] ?? (0, 0)
            // 同じチームの直前のトライ(同じハーフ・3分以内)に付いたゴールは、その印にまとめる
            if marker.event.category == "conversion",
               let index = groups.lastIndex(where: { $0.isHome == marker.isHome }),
               groups[index].label == "T",
               groups[index].events[0].half == marker.event.half,
               marker.event.seconds - groups[index].events[0].seconds <= 180 {
                groups[index].label = "T+G"
                groups[index].events.append(marker.event)
                groups[index].homeScore = running.home
                groups[index].awayScore = running.away
                continue
            }
            groups.append(ProgressionGroup(axisSeconds: marker.axisSeconds, isHome: marker.isHome, label: marker.letter,
                                           events: [marker.event], homeScore: running.home, awayScore: running.away))
        }
        // 外れたゴールも、直前のトライ(同じチーム・同じハーフ・3分以内)の詳細に「G×」として載せる
        // (印はトライのまま。点数は変わらないので途中スコアもそのまま)
        let missedConversions = scoringEventsForSelectedScope.filter {
            $0.category == "conversion" && $0.outcome == "fail"
                && ($0.teamID == match.homeTeamID || $0.teamID == match.awayTeamID)
        }
        for miss in missedConversions {
            let isHome = miss.teamID == match.homeTeamID
            if let index = groups.lastIndex(where: {
                $0.isHome == isHome && $0.label == "T" && $0.events[0].half == miss.half
                    && $0.events[0].seconds <= miss.seconds && miss.seconds - $0.events[0].seconds <= 180
            }) {
                groups[index].events.append(miss)
            }
        }
        // 近すぎて重なる印は、行の外側の段へずらす。幅は iPhone のグラフ幅(約280pt)で見積もる
        // (画面の幅に頼らないので、画像で共有したときも同じ並びになる)
        let secondsPerPoint = max(axisTotal, 1) / 280
        var laneEnds: [Bool: [Double]] = [true: [], false: []]
        for index in groups.indices {
            let halfWidth = (max(progressionChipWidth(groups[index].label), 38) / 2 + 3) * secondsPerPoint
            var ends = laneEnds[groups[index].isHome] ?? []
            let lane = ends.firstIndex { $0 <= groups[index].axisSeconds - halfWidth } ?? ends.count
            if lane == ends.count { ends.append(0) }
            ends[lane] = groups[index].axisSeconds + halfWidth
            laneEnds[groups[index].isHome] = ends
            groups[index].lane = lane
        }
        return groups
    }

    /// グラフの左端に置くチームの目印(ロゴ。なければチーム色の盾)
    private func chartTeamMark(_ teamID: UUID, size: CGFloat) -> some View {
        let team = teams.first { $0.id == teamID }
        let accent = teamID == match.homeTeamID ? homeStatisticsColor : awayStatisticsColor
        return Group {
            if let name = team?.logoPath, let image = ImageStorage.thumbnail(named: name, maxDimension: 96) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "shield.lefthalf.filled").resizable().scaledToFit().foregroundStyle(accent)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var scoringProgressionCard: some View {
        let axis = progressionAxis
        let groups = progressionGroups(progressionMarkers, axisTotal: axis.total)

        return VStack(alignment: .leading, spacing: 10) {
            Label("得点経過（\(selectedScope.title)）", systemImage: "chart.xyaxis.line")
                .font(.headline.weight(.semibold))
                .foregroundStyle(RugbyTheme.textPrimary)

            if groups.isEmpty {
                Text("得点記録がありません")
                    .font(.subheadline)
                    .foregroundStyle(RugbyTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                progressionChart(groups: groups, axisTotal: axis.total, halftime: axis.halftime)
                progressionSelectionDetail(groups)
            }
        }
        .padding(16)
        .summaryCard()
        .frame(maxWidth: .infinity)
    }

    /// 時間の目盛り。全体表示では後半も0分から振り直し、ハーフタイムの位置は「HT」にする
    private func progressionTicks(axisTotal: Double, halftime: Double?) -> [(x: Double, label: String)] {
        let step = progressionTickSeconds(total: axisTotal)
        guard let halftime else {
            return stride(from: 0.0, through: axisTotal, by: step).map { ($0, "\(Int($0) / 60)'") }
        }
        var result: [(Double, String)] = stride(from: 0.0, to: halftime - step / 2, by: step).map { ($0, "\(Int($0) / 60)'") }
        result.append((halftime, "HT"))
        result += stride(from: step, through: axisTotal - halftime, by: step).map { (halftime + $0, "\(Int($0) / 60)'") }
        return result
    }

    private func progressionChart(groups: [ProgressionGroup], axisTotal: Double, halftime: Double?) -> some View {
        // 上から: ホームの段(軸から上へ積む) / 時間の目盛り / アウェイの段(軸から下へ積む)
        let unit: CGFloat = 40          // 1段 = 印 + その下の途中スコア
        let tickHeight: CGFloat = 20
        let homeLanes = (groups.filter(\.isHome).map(\.lane).max() ?? 0) + 1
        let awayLanes = (groups.filter { !$0.isHome }.map(\.lane).max() ?? 0) + 1
        let homeHeight = CGFloat(homeLanes) * unit
        let chartHeight = homeHeight + tickHeight + CGFloat(awayLanes) * unit
        let ticks = progressionTicks(axisTotal: axisTotal, halftime: halftime)

        return GeometryReader { geo in
            let labelWidth: CGFloat = 30
            let plotLeft = labelWidth + 16
            let plotRight = max(plotLeft + 1, geo.size.width - 18)
            let tickY = homeHeight + tickHeight / 2
            let homeRowY = homeHeight - unit + 12
            let awayRowY = homeHeight + tickHeight + 12
            let xPosition: (Double) -> CGFloat = { seconds in
                plotLeft + CGFloat(seconds / max(axisTotal, 1)) * (plotRight - plotLeft)
            }
            let chipY: (ProgressionGroup) -> CGFloat = { group in
                group.isHome ? homeRowY - CGFloat(group.lane) * unit : awayRowY + CGFloat(group.lane) * unit
            }

            ZStack(alignment: .topLeading) {
                // チームの目印と、各チームの行の下敷きの線
                chartTeamMark(match.homeTeamID, size: 26).position(x: labelWidth / 2, y: homeRowY)
                chartTeamMark(match.awayTeamID, size: 26).position(x: labelWidth / 2, y: awayRowY)
                ForEach([homeRowY, awayRowY], id: \.self) { y in
                    Rectangle()
                        .fill(RugbyTheme.border)
                        .frame(width: plotRight - plotLeft, height: 1)
                        .position(x: (plotLeft + plotRight) / 2, y: y)
                }

                // ハーフタイムの区切り(全体表示のみ)
                if let halftime {
                    VerticalDashedLine()
                        .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .foregroundStyle(RugbyTheme.textSecondary.opacity(0.6))
                        .frame(width: 1, height: chartHeight)
                        .position(x: xPosition(halftime), y: chartHeight / 2)
                }

                ForEach(ticks, id: \.x) { tick in
                    Text(tick.label)
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(RugbyTheme.textSecondary)
                        .padding(.horizontal, 2)
                        .background(RugbyTheme.surface)
                        .position(x: xPosition(tick.x), y: tickY)
                }

                // 得点の印(タップで得点者を表示)と、その時点のスコア
                ForEach(groups) { group in
                    let accent = group.isHome ? homeStatisticsColor : awayStatisticsColor
                    let isSelected = selectedProgressionEventID == group.id
                    let x = xPosition(group.axisSeconds)
                    let y = chipY(group)

                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            selectedProgressionEventID = isSelected ? nil : group.id
                        }
                    } label: {
                        ScoringKindMark(kind: group.label, color: accent, size: progressionChipWidth(group.label),
                                        isSelected: isSelected)
                            .frame(minWidth: 44, minHeight: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .position(x: x, y: y)
                    .zIndex(isSelected ? 2 : 1)
                    .accessibilityLabel("\(teamName(for: group.isHome ? match.homeTeamID : match.awayTeamID)) \(ScoringKindMark.name(group.label))")
                    .accessibilityValue("\(group.homeScore)対\(group.awayScore)")

                    Text("\(group.homeScore)-\(group.awayScore)")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(isSelected ? RugbyTheme.textPrimary : RugbyTheme.textSecondary)
                        .fixedSize()
                        .position(x: x, y: y + 19)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(height: chartHeight)
    }

    /// 選んだ印の得点者と時間。グラフの上に吹き出しを出すと上に空白が要るので、下に並べる
    @ViewBuilder
    private func progressionSelectionDetail(_ groups: [ProgressionGroup]) -> some View {
        if let group = groups.first(where: { $0.id == selectedProgressionEventID }) {
            let accent = group.isHome ? homeStatisticsColor : awayStatisticsColor
            VStack(alignment: .leading, spacing: 6) {
                ForEach(group.events) { event in
                    let missed = event.outcome == "fail"
                    HStack(spacing: 8) {
                        playerAvatar(playerID: event.playerID, accent: accent, size: 24)
                            .opacity(missed ? 0.5 : 1)
                        Text(progressionLetter(event.category) + (missed ? "×" : ""))
                            .font(.caption.weight(.black))
                            .foregroundStyle(missed ? RugbyTheme.textSecondary : accent)
                            .frame(minWidth: 24, alignment: .leading)
                        Text(progressionTimeLabel(for: event))
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(RugbyTheme.textPrimary)
                        Text(scorerLabel(for: event))
                            .font(.caption)
                            .foregroundStyle(needsScorer(event) ? Color.orange : RugbyTheme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(10)
            .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                progressionLegend(Set(groups.map(\.label)))
                Text("印をタップすると、得点した選手と時間を表示します。")
                    .font(.caption)
                    .foregroundStyle(RugbyTheme.textSecondary)
            }
        }
    }

    /// 印の見方。その試合に出てくる種類だけを、決まった順に並べる
    private func progressionLegend(_ kinds: Set<String>) -> some View {
        let order = ["T", "T+G", "PT", "PG", "DG", "G"].filter(kinds.contains)
        return HStack(spacing: 12) {
            ForEach(order, id: \.self) { kind in
                HStack(spacing: 4) {
                    ScoringKindMark(kind: kind, color: RugbyTheme.textSecondary, size: 18, isSelected: false)
                        .padding(.trailing, kind == "T+G" || kind == "PT" ? 4 : 0)   // 右上の小さな印の分
                    Text(ScoringKindMark.name(kind))
                        .font(.caption2)
                        .foregroundStyle(RugbyTheme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - 得点差の推移グラフ

    // 得点差は常にホーム側から見る(上 = ホームのリード、下 = アウェイのリード)
    // どちらのチームから見るか(上 = このチームのリード)。既定はホーム
    @State private var marginPerspectiveIsHome = true
    // 得点差の推移に重ねる説明(得点の印・最大リード・最終点差)は、最初は出さない。チェックで出せる
    @AppStorage("matchSummary.marginShowsMarks") private var marginShowsMarks = false
    @AppStorage("matchSummary.marginShowsPeaks") private var marginShowsPeaks = false
    @AppStorage("matchSummary.marginShowsFinal") private var marginShowsFinal = false
    private var marginTopTeamID: UUID { marginPerspectiveIsHome ? match.homeTeamID : match.awayTeamID }
    private var marginBottomTeamID: UUID { marginPerspectiveIsHome ? match.awayTeamID : match.homeTeamID }
    private var marginTopColor: Color { marginPerspectiveIsHome ? homeStatisticsColor : awayStatisticsColor }
    private var marginBottomColor: Color { marginPerspectiveIsHome ? awayStatisticsColor : homeStatisticsColor }

    // スコープ開始時点の得点差(後半表示のときは前半終了時の差から始める)
    private func marginAtScopeStart() -> Int {
        guard selectedScope.half == 1 else { return 0 }
        let firstHalfMargin = score(for: match.homeTeamID, half: 0) - score(for: match.awayTeamID, half: 0)
        return marginPerspectiveIsHome ? firstHalfMargin : -firstHalfMargin
    }

    /// 得点差が動いた点。得点経過の印と同じまとめ方(トライとゴールは1つ)で、その得点の種類も持つ
    private struct MarginStep {
        let axisSeconds: Double
        let margin: Int         // 選んだ視点(上のチーム)から見た得点差
        let kind: String        // ScoringKindMark の種類
        let isTop: Bool         // 得点したのが上のチームか
        let half: Int           // 0 = 前半, 1 = 後半
    }

    private func marginSteps(_ groups: [ProgressionGroup]) -> [MarginStep] {
        let sign = marginPerspectiveIsHome ? 1 : -1
        return groups.map { MarginStep(axisSeconds: $0.axisSeconds, margin: sign * ($0.homeScore - $0.awayScore),
                                       kind: $0.label, isTop: $0.isHome == marginPerspectiveIsHome,
                                       half: $0.events[0].half) }
    }

    /// リードしていた時間の割合(ホーム・同点・アウェイ)と、リードが入れ替わった回数
    private func marginLeadShares(_ steps: [MarginStep], start: Int, total: Double)
        -> (home: Double, even: Double, away: Double, changes: Int) {
        var home = 0.0, even = 0.0, away = 0.0, changes = 0
        var time = 0.0, margin = start
        var leader = start.signum()
        func add(until end: Double) {
            let span = max(0, min(end, total) - time)
            if margin > 0 { home += span } else if margin < 0 { away += span } else { even += span }
            time = max(time, min(end, total))
        }
        for step in steps {
            add(until: step.axisSeconds)
            margin = step.margin
            let sign = margin.signum()
            if sign != 0 {
                if leader != 0 && sign != leader { changes += 1 }
                leader = sign
            }
        }
        add(until: total)
        let sum = max(home + even + away, 1)
        return (home / sum, even / sum, away / sum, changes)
    }

    private var scoreMarginCard: some View {
        let axis = progressionAxis
        let steps = marginSteps(progressionGroups(progressionMarkers, axisTotal: axis.total))
        let start = marginAtScopeStart()

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label("得点差の推移（\(selectedScope.title)）", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(RugbyTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    marginPerspectiveChip("HOME", isHome: true)
                    marginPerspectiveChip("AWAY", isHome: false)
                }
            }

            if steps.isEmpty && start == 0 {
                Text("得点記録がありません")
                    .font(.subheadline)
                    .foregroundStyle(RugbyTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                marginLeadTime(marginLeadShares(steps, start: start, total: axis.total))
                marginSideLabel(marginTopTeamID, color: marginTopColor, isTop: true)
                marginChart(steps: steps, axisTotal: axis.total, halftime: axis.halftime)
                marginSideLabel(marginBottomTeamID, color: marginBottomColor, isTop: false)
                marginOverlayToggles
            }
        }
        .padding(16)
        .summaryCard()
        .frame(maxWidth: .infinity)
    }

    /// 「リードしていた時間」の帯。両チームと同点の割合を1本の帯で見せ、逆転の回数を添える
    private func marginLeadTime(_ shares: (home: Double, even: Double, away: Double, changes: Int)) -> some View {
        let parts: [(label: String, share: Double, color: Color)] = [
            (teamName(for: marginTopTeamID), shares.home, marginTopColor),
            ("同点", shares.even, RugbyTheme.textSecondary.opacity(0.35)),
            (teamName(for: marginBottomTeamID), shares.away, marginBottomColor)
        ]
        let percent: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("リードしていた時間")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(RugbyTheme.textSecondary)
                Spacer(minLength: 8)
                Text(shares.changes > 0 ? "逆転 \(shares.changes)回" : "逆転なし")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(RugbyTheme.textPrimary)
            }
            GeometryReader { geo in
                let visible = parts.filter { $0.share > 0 }
                let width = max(0, geo.size.width - CGFloat(max(0, visible.count - 1)) * 2)
                HStack(spacing: 2) {
                    ForEach(visible.indices, id: \.self) { index in
                        Rectangle().fill(visible[index].color).frame(width: width * visible[index].share)
                    }
                }
            }
            .frame(height: 10)
            .clipShape(Capsule())
            HStack(spacing: 10) {
                ForEach(parts.indices, id: \.self) { index in
                    HStack(spacing: 4) {
                        Circle().fill(parts[index].color).frame(width: 7, height: 7)
                        Text(parts[index].label).lineLimit(1).minimumScaleFactor(0.7)
                        Text(percent(parts[index].share)).fontWeight(.bold).monospacedDigit()
                    }
                    if index < parts.count - 1 { Spacer(minLength: 0) }
                }
            }
            .font(.caption2)
            .foregroundStyle(RugbyTheme.textPrimary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("リードしていた時間")
        .accessibilityValue("\(teamName(for: marginTopTeamID)) \(percent(shares.home))、同点 \(percent(shares.even))、"
            + "\(teamName(for: marginBottomTeamID)) \(percent(shares.away))、逆転\(shares.changes)回")
    }

    /// 得点差の推移。0の線より上はホームのリード(ホームの色)、下はアウェイのリード(アウェイの色)で塗る
    /// (NBA・ESPN の「ゲームフロー」と同じ形)。差が動いた所にはその得点の印を置き、最大リードに吹き出しを付ける
    /// (Nike Run Club の Max/Min と同じ見せ方)。なぜ差が動いたか、いちばん開いたのはいつかが一目で分かる。
    private func marginChart(steps: [MarginStep], axisTotal: Double, halftime: Double?) -> some View {
        let plotHeight: CGFloat = 170
        let tickHeight: CGFloat = 20
        let chartHeight = plotHeight + tickHeight
        let startMargin = marginAtScopeStart()
        // 上 = 選んだ視点のチーム、下 = 相手(名前は home/away のままだが、ここでは上/下の意味)
        let homeColor = marginTopColor
        let awayColor = marginBottomColor
        // 縦軸は0を真ん中にして上下同じ幅。目盛りは7点(トライ+ゴール)の倍数で、片側3本まで
        let margins = [startMargin] + steps.map(\.margin)
        let largest = max(7, margins.map(abs).max() ?? 0)
        let gridStep = 7 * max(1, Int(ceil(Double(largest) / 21.0)))
        let limit = Int(ceil(Double(largest) / Double(gridStep))) * gridStep
        let gridValues = Array(stride(from: -limit, through: limit, by: gridStep))
        let ticks = progressionTicks(axisTotal: axisTotal, halftime: halftime)
        let finalMargin = steps.last?.margin ?? startMargin
        let homeBest = margins.max() ?? 0
        let awayBest = margins.min() ?? 0
        // 最大リードに初めて届いた点(0点のリードは出さない)。最後の区間なら右端の最終得点差と同じなので出さない
        let homeBestIndex = homeBest > 0 ? steps.firstIndex { $0.margin == homeBest }.flatMap { $0 == steps.count - 1 ? nil : $0 } : nil
        let awayBestIndex = awayBest < 0 ? steps.firstIndex { $0.margin == awayBest }.flatMap { $0 == steps.count - 1 ? nil : $0 } : nil

        return GeometryReader { geo in
            let labelWidth: CGFloat = 26
            let plotLeft = labelWidth + 8
            let plotRight = max(plotLeft + 1, geo.size.width - 34)
            let inset: CGFloat = 22   // 上下の端に印と吹き出しの入る余白
            // 試合終了の少し先まで横軸を伸ばす。終了間際の得点でも、動いた後の差が線として見えるように
            // 前半の終わりにも試合終了と同じく少し余白を入れる。前半終了間際の得点で逆転したことが、
            // ハーフタイムの点線より前に見えるように(後半はその分だけ右へずらす)
            let halfGap = halftime == nil ? 0 : max(axisTotal, 1) * 0.05
            let shown: (Double, Int) -> Double = { seconds, half in seconds + (half >= 1 ? halfGap : 0) }
            // 試合終了の後の余白は、ハーフタイムの点線の前の余白(halfGap の半分)と同じだけ
            let domain = max(axisTotal, 1) * 1.025 + halfGap
            let xPosition: (Double) -> CGFloat = { seconds in
                plotLeft + CGFloat(seconds / domain) * (plotRight - plotLeft)
            }
            let yPosition: (Int) -> CGFloat = { margin in
                inset + CGFloat(limit - margin) / CGFloat(2 * limit) * (plotHeight - inset * 2)
            }
            let zeroY = yPosition(0)
            let fullTimeX = xPosition(axisTotal + halfGap)
            let halftimeX = halftime.map { xPosition($0 + halfGap / 2) }
            let stepX: (MarginStep) -> CGFloat = { step in xPosition(shown(step.axisSeconds, step.half)) }
            // 得点差の階段の折れ線の点
            let points: [CGPoint] = {
                var result = [CGPoint(x: plotLeft, y: yPosition(startMargin))]
                var current = startMargin
                for step in steps {
                    let x = stepX(step)
                    result.append(CGPoint(x: x, y: yPosition(current)))
                    result.append(CGPoint(x: x, y: yPosition(step.margin)))
                    current = step.margin
                }
                result.append(CGPoint(x: plotRight, y: yPosition(current)))
                return result
            }()
            // 最大リードの吹き出しは、その差が続いた区間の真ん中に置く
            let plateauX: (Int) -> CGFloat = { index in
                let from = stepX(steps[index])
                let to = index + 1 < steps.count ? stepX(steps[index + 1]) : fullTimeX
                return (from + to) / 2
            }

            ZStack(alignment: .topLeading) {
                // 目盛り線(0の線だけ濃く)。数字は選んだ視点のチームから見た点差(上が +、下が −)
                ForEach(gridValues, id: \.self) { value in
                    Rectangle()
                        .fill(RugbyTheme.textSecondary.opacity(value == 0 ? 0.45 : 0.12))
                        .frame(width: plotRight - plotLeft, height: 1)
                        .position(x: (plotLeft + plotRight) / 2, y: yPosition(value))
                    Text(Self.signedMargin(value, zero: "0"))
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(RugbyTheme.textSecondary)
                        .position(x: labelWidth / 2, y: yPosition(value))
                }

                // リードの面。上はホーム、下はアウェイの色
                Canvas { context, size in
                    var area = Path()
                    area.move(to: CGPoint(x: plotLeft, y: zeroY))
                    points.forEach { area.addLine(to: $0) }
                    area.addLine(to: CGPoint(x: plotRight, y: zeroY))
                    area.closeSubpath()
                    var above = context
                    above.clip(to: Path(CGRect(x: 0, y: 0, width: size.width, height: zeroY)))
                    above.fill(area, with: .color(homeColor.opacity(0.35)))
                    var below = context
                    below.clip(to: Path(CGRect(x: 0, y: zeroY, width: size.width, height: size.height - zeroY)))
                    below.fill(area, with: .color(awayColor.opacity(0.35)))

                    var line = Path()
                    line.addLines(points)
                    context.stroke(line, with: .color(RugbyTheme.textPrimary.opacity(0.7)),
                                   style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
                .frame(width: geo.size.width, height: plotHeight)

                // ハーフタイムの区切り(全体表示のみ)
                if let halftime {
                    VerticalDashedLine()
                        .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .foregroundStyle(RugbyTheme.textSecondary.opacity(0.6))
                        .frame(width: 1, height: plotHeight)
                        .position(x: halftimeX ?? xPosition(halftime), y: plotHeight / 2)
                }

                // 差が動いた所の得点の印(得点したチームの色)。上のチームの得点は線の上、下のチームの得点は線の下。
                // 近すぎて重なる印は、さらに外側(上のチームは上、下のチームは下)へ1段ずつずらす
                let markLanes: [Int] = {
                    var lastX: [Bool: [CGFloat]] = [true: [], false: []]
                    return steps.map { step in
                        let x = stepX(step)
                        var ends = lastX[step.isTop] ?? []
                        let lane = ends.firstIndex { $0 <= x - 19 } ?? ends.count
                        if lane == ends.count { ends.append(0) }
                        ends[lane] = x
                        lastX[step.isTop] = ends
                        return lane
                    }
                }()
                ForEach(marginShowsMarks ? Array(steps.indices) : [], id: \.self) { index in
                    let step = steps[index]
                    let offset = 11 + CGFloat(markLanes[index]) * 18
                    ScoringKindMark(kind: step.kind, color: step.isTop ? homeColor : awayColor, size: 16, isSelected: false)
                        .position(x: stepX(step), y: yPosition(step.margin) + (step.isTop ? -offset : offset))
                        .accessibilityHidden(true)
                }

                // 最大リードの吹き出し。得点の印は線の外側にあるので、重ならないよう塗りの内側に置く
                if marginShowsPeaks, let index = homeBestIndex {
                    marginPeakLabel("最大 +\(homeBest)", color: homeColor)
                        .position(x: plateauX(index), y: min(yPosition(homeBest) + 12, (yPosition(homeBest) + zeroY) / 2))
                }
                if marginShowsPeaks, let index = awayBestIndex {
                    // 下のチームのリード = 選んだ視点のチームから見るとマイナス
                    marginPeakLabel("最大 " + Self.signedMargin(awayBest, zero: "0"), color: awayColor)
                        .position(x: plateauX(index), y: max(yPosition(awayBest) - 12, (yPosition(awayBest) + zeroY) / 2))
                }

                ForEach(ticks, id: \.x) { tick in
                    Text(tick.label)
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(RugbyTheme.textSecondary)
                        .position(x: tick.label == "HT" ? (halftimeX ?? xPosition(tick.x))
                                        : xPosition(tick.x + (halftime.map { tick.x > $0 } == true ? halfGap : 0)),
                                  y: plotHeight + tickHeight / 2)
                }

                // 最終的な得点差(選んだ視点のチームから見て +/−。色はリードしているチーム)
                if marginShowsFinal {
                    Text(Self.signedMargin(finalMargin, zero: "同点"))
                        .font(.caption.weight(.black).monospacedDigit())
                        .foregroundStyle(finalMargin > 0 ? homeColor : finalMargin < 0 ? awayColor : RugbyTheme.textSecondary)
                        .fixedSize()
                        .position(x: plotRight + 17, y: yPosition(finalMargin))
                }
            }
        }
        .frame(height: chartHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("得点差の推移")
        .accessibilityValue(finalMargin == 0 ? "同点で終了"
            : "\(teamName(for: finalMargin > 0 ? marginTopTeamID : marginBottomTeamID))が\(abs(finalMargin))点リード")
    }

    /// 点差の表記(+7 / −7)。0 は呼び出し側の言葉(「0」「同点」)
    private static func signedMargin(_ value: Int, zero: String) -> String {
        value > 0 ? "+\(value)" : value < 0 ? "−\(-value)" : zero
    }

    private func marginPeakLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .black).monospacedDigit())
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RugbyTheme.surface, in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.6), lineWidth: 1))
            .fixedSize()
    }

    /// グラフの上と下に置く「〇〇 リード ↑/↓」の見出し
    private func marginSideLabel(_ teamID: UUID, color: Color, isTop: Bool) -> some View {
        let isHome = isTop
        return HStack(spacing: 4) {
            chartTeamMark(teamID, size: 14)
            Text("\(teamName(for: teamID)) のリード")
                .lineLimit(1)
            Image(systemName: isHome ? "arrow.up" : "arrow.down")
                .font(.caption2.weight(.black))
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(color)
    }

    /// 視点の切り替え(HOME/AWAY)。選んだチームのリードが上に来る。
    /// 見た目はポゼッションの HOME/AWAY と同じ(チームの色の文字に薄いチーム色の地)。選んでいない方は灰色
    private func marginPerspectiveChip(_ title: String, isHome: Bool) -> some View {
        let isSelected = marginPerspectiveIsHome == isHome
        let accent = isHome ? homeStatisticsColor : awayStatisticsColor
        return Button {
            withAnimation(.easeOut(duration: 0.2)) { marginPerspectiveIsHome = isHome }
        } label: {
            Text(title)
                .font(.caption.weight(.black))
                .foregroundStyle(isSelected ? accent : RugbyTheme.textSecondary.opacity(0.7))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isSelected ? accent.opacity(0.22) : RugbyTheme.textSecondary.opacity(0.08))
                .clipShape(Capsule())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(teamName(for: isHome ? match.homeTeamID : match.awayTeamID))から見る")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// グラフに重ねる説明(得点の印・最大リード)の表示切り替え。選んだ状態は次回も引き継ぐ
    private var marginOverlayToggles: some View {
        HStack(spacing: 8) {
            marginOverlayToggle("得点の印", isOn: $marginShowsMarks)
            marginOverlayToggle("最大リード", isOn: $marginShowsPeaks)
            marginOverlayToggle("最終点差", isOn: $marginShowsFinal)
            Spacer(minLength: 0)
        }
    }

    private func marginOverlayToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { isOn.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isOn.wrappedValue ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isOn.wrappedValue ? RugbyTheme.accent : RugbyTheme.textSecondary)
                Text(title)
                    .foregroundStyle(isOn.wrappedValue ? RugbyTheme.textPrimary : RugbyTheme.textSecondary)
            }
            .font(.caption.weight(.semibold))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn.wrappedValue ? "表示中" : "非表示")
    }

    // MARK: - 交代カード

    private var matchSubstitutions: [Substitution] {
        allSubstitutions
            .filter { $0.matchID == match.id }
            .sorted { ($0.half, $0.minute) < ($1.half, $1.minute) }
    }

    // 出場時間(スタメン・交代・前後半の長さから計算)。メンバー一覧の各行に出す
    private var playingTime: PlayingTimeCalculator.Result {
        PlayingTimeCalculator.calculate(matchID: match.id, lineups: matchLineups,
                                        substitutions: matchSubstitutions, events: matchEvents)
    }

    /// 出場時間がどう計算されたか(または計算できない理由)。記録が足りない試合でも事情が分かるようにする
    private var playingTimeNoteText: String? {
        let hasLineups = matchLineups.contains { $0.role == "starter" || $0.role == "reserve" }
        let isOfficial = match.officialRecordID != nil
        if !hasLineups {
            return isOfficial
                ? "公式記録にメンバー表が載っていないため、この試合は得点（最終スコア）だけの記録です。出場メンバー・交代・出場時間はありません。"
                : "メンバー表が登録されていないため、出場時間は計算できません。メンバー表と交代を登録すると計算されます。"
        }
        if !matchLineups.contains(where: { $0.role == "starter" }) {
            return "スタメンが登録されていないため、出場時間は計算できません。"
        }
        guard isOfficial else { return nil }
        let first = Int(ceil(MatchStatistics.halfEndSeconds(events: matchEvents, half: 0) / 60))
        let second = Int(ceil(MatchStatistics.halfEndSeconds(events: matchEvents, half: 1) / 60))
        var text = "出場時間は公式記録のメンバー表と交代から計算しています。公式記録に試合時間の記載がないため、前半\(first)分・後半\(second)分とみなしています。"
        if matchSubstitutions.isEmpty { text += "交代の記載がないため、先発は全時間出場として数えています。" }
        return text
    }

    @ViewBuilder private var playingTimeNote: some View {
        if let text = playingTimeNoteText {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle")
                    .foregroundStyle(RugbyTheme.textSecondary)
                    .accessibilityHidden(true)
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(RugbyTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .summaryCard()
        }
    }

    private var registeredLineups: some View {
        let minutes = playingTime
        return VStack(alignment: .leading, spacing: 20) {
            Text("登録メンバー")
                .font(.headline.weight(.semibold))
                .foregroundStyle(RugbyTheme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            ForEach([match.homeTeamID, match.awayTeamID], id: \.self) { teamID in
                registeredTeamLineup(teamID, playingTime: minutes)
            }
        }
        .padding(16)
        .summaryCard()
    }

    private func registeredTeamLineup(_ teamID: UUID, playingTime: PlayingTimeCalculator.Result) -> some View {
        let entries = matchLineups.filter {
            $0.teamID == teamID && ($0.role == "starter" || $0.role == "reserve")
        }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                teamLogoBox(teamID: teamID, size: 32)
                Text(teamName(for: teamID))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(RugbyTheme.textPrimary)
                Spacer(minLength: 0)
                Text("\(entries.count)人")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(RugbyTheme.textSecondary)
            }
            if entries.isEmpty {
                Text("メンバーは登録されていません。")
                    .font(.subheadline)
                    .foregroundStyle(RugbyTheme.textSecondary)
            } else {
                ForEach(["starter", "reserve"], id: \.self) { role in
                    let members = entries.filter { $0.role == role }.sorted { $0.order < $1.order }
                    if !members.isEmpty {
                        Text(role == "starter" ? "スタメン" : "リザーブ")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(RugbyTheme.textSecondary)
                        ForEach(members) { entry in
                            if let player = players.first(where: { $0.id == entry.playerID }) {
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(MatchNumbering.numberLabel(for: player, matchID: match.id, lineups: matchLineups))
                                        .font(.subheadline.weight(.bold).monospacedDigit())
                                        .foregroundStyle(RugbyTheme.accent)
                                        .frame(minWidth: 36, alignment: .leading)
                                    Text(player.name?.isEmpty == false ? player.name! : "名前未設定")
                                        .font(.subheadline)
                                        .foregroundStyle(RugbyTheme.textPrimary)
                                    Spacer(minLength: 0)
                                    if let position = player.position, !position.isEmpty {
                                        Text(position)
                                            .font(.caption)
                                            .foregroundStyle(RugbyTheme.textSecondary)
                                    }
                                    if playingTime.hasStarterInfo {
                                        let played = playingTime.minutesByPlayer[player.id] ?? 0
                                        // 公式記録の交代は分単位なので、最後の分に入った選手は0分になる。出場はしているので「1分未満」
                                        let cameOn = matchSubstitutions.contains { $0.playerInID == player.id }
                                        Text(played > 0 ? "\(played)分" : cameOn ? "1分未満" : "出場なし")
                                            .font(.caption.weight(.semibold).monospacedDigit())
                                            .foregroundStyle(played > 0 ? RugbyTheme.textPrimary : RugbyTheme.textSecondary)
                                            .frame(minWidth: 52, alignment: .trailing)
                                    }
                                }
                                .padding(.vertical, 5)
                                .accessibilityElement(children: .combine)
                                Divider().overlay(RugbyTheme.border)
                            }
                        }
                    }
                }
            }
        }
    }

    private var substitutionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("交代", systemImage: "arrow.left.arrow.right")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(RugbyTheme.textPrimary)
                Spacer()
                Button {
                    isSubstitutionSheetPresented = true
                } label: {
                    Label("追加", systemImage: "plus.circle.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(RugbyTheme.onAccent)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(RugbyTheme.accent)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Divider()
                .overlay(RugbyTheme.border)

            if matchSubstitutions.isEmpty {
                Text("交代の記録がありません")
                    .font(.subheadline)
                    .foregroundStyle(RugbyTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ForEach(matchSubstitutions) { substitution in
                    substitutionRow(substitution)
                }
            }
        }
        .padding(16)
        .summaryCard()
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $isSubstitutionSheetPresented) {
            SubstitutionAddSheet(
                match: match,
                teams: teams,
                players: players,
                lineups: matchLineups,
                initialHalf: selectedScope.half ?? 0,
                initialMinute: 0,
                onAdd: { playerOutID, playerInID, half, minute in
                    let substitution = Substitution(
                        matchID: match.id,
                        playerInID: playerInID,
                        playerOutID: playerOutID,
                        minute: minute,
                        half: half
                    )
                    modelContext.insert(substitution)
                    AppPersistence.save(modelContext)
                    MatchNumbering.freezeNumbers(forMatch: match.id, context: modelContext)
                }
            )
            .presentationDetents([.large])
        }
    }

    private func substitutionRow(_ substitution: Substitution) -> some View {
        HStack(spacing: 8) {
            Text("\(halfLabel(substitution.half)) \(substitution.minute)'")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(RugbyTheme.textSecondary)
                .frame(width: 64, alignment: .leading)

            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.red)
            Text(playerName(for: substitution.playerOutID))
                .font(.subheadline)
                .foregroundStyle(RugbyTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Image(systemName: "arrow.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(RugbyTheme.textSecondary)

            Image(systemName: "arrow.up.circle.fill")
                .foregroundStyle(.green)
            Text(playerName(for: substitution.playerInID))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(RugbyTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Spacer(minLength: 4)

            Button {
                modelContext.delete(substitution)
                AppPersistence.save(modelContext)
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(RugbyTheme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 3)
    }

    private var scorerTimelineCard: some View {
        let visibleEvents = scoringEventsForSelectedScope

        return VStack(alignment: .leading, spacing: 12) {
            Label("得点タイムライン（\(selectedScope.title)）", systemImage: "clock")
                .font(.headline.weight(.semibold))
                .foregroundStyle(RugbyTheme.textPrimary)

            Divider()
                .overlay(RugbyTheme.border)

            if visibleEvents.isEmpty {
                Text("得点記録がありません")
                    .font(.subheadline)
                    .foregroundStyle(RugbyTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                let progression = scoringProgression
                if selectedScope.half != nil {
                    ForEach(visibleEvents) { event in
                        scorerRow(event, progression: progression[event.id] ?? (0, 0))
                    }
                } else {
                    ForEach([0, 1], id: \.self) { half in
                        let halfEvents = visibleEvents.filter { $0.half == half }
                        if !halfEvents.isEmpty {
                            halfHeaderRow(half)
                            ForEach(halfEvents) { event in
                                scorerRow(event, progression: progression[event.id] ?? (0, 0))
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .summaryCard()
        .frame(maxWidth: .infinity)
    }

    private func halfHeaderRow(_ half: Int) -> some View {
        HStack(spacing: 8) {
            Text(halfLabel(half))
                .font(.caption2.weight(.bold))
                .foregroundStyle(RugbyTheme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(RugbyTheme.border)
                .clipShape(Capsule())
            Rectangle()
                .fill(RugbyTheme.border)
                .frame(height: 1)
        }
    }

    private func scorerRow(_ event: StatEvent, progression: (home: Int, away: Int)) -> some View {
        let teamAccent: Color = event.teamID == match.homeTeamID ? homeStatisticsColor
            : event.teamID == match.awayTeamID ? awayStatisticsColor
            : .secondary
        let usesTeamColor = event.category == ScoringCategory.tryScore.rawValue
            || event.category == ScoringCategory.conversion.rawValue
        let badgeColor = usesTeamColor ? teamAccent : categoryColor(event.category)
        // 失敗したキック(CON/PG/DG)はチップを薄くして✕印を付ける
        let isFailed = event.outcome == "fail"

        return HStack(spacing: 8) {
            // 時刻だけ独立したボタン。タップで時刻の修正シートを開く
            // (行の他の場所をタップすると従来どおり得点者の選択)。
            Button {
                timeEditingEvent = event
            } label: {
                Text(timeText(event.seconds))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(RugbyTheme.textSecondary)
                    // タップできる場所だと分かるよう、控えめな下線を敷く
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(RugbyTheme.border)
                            .frame(height: 1)
                            .offset(y: 2)
                    }
                    .frame(width: 46, alignment: .leading)
                    .frame(minHeight: 44)
                    .opacity(isFailed ? 0.45 : 1.0)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("時刻を修正")

            Button {
                // 認定トライは個人の得点にならないので、選手は選ばせない
                guard event.category != ScoringRules.penaltyTryCategory else { return }
                scoringEventForPlayerSelection = event
            } label: {
                HStack(spacing: 6) {
                    Text(categoryTag(event.category))
                        .font(.callout.weight(.black))
                        .frame(width: 46)
                        .padding(.vertical, 6)
                        .background(badgeColor.opacity(isFailed ? 0.08 : 0.18))
                        .foregroundStyle(badgeColor.opacity(isFailed ? 0.45 : 1.0))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(alignment: .topTrailing) {
                            if isFailed {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.orange)
                                    .background(Circle().fill(RugbyTheme.surface))
                                    .offset(x: 5, y: -5)
                            }
                        }

                    playerAvatar(playerID: event.playerID, accent: teamAccent, size: 26)
                        .opacity(isFailed ? 0.45 : 1.0)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(scorerLabel(for: event))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(needsScorer(event) ? Color.orange : RugbyTheme.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)

                        if let originName = PlayOrigin.displayName(for: event.origin) {
                            Text("起点: \(originName)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.teal)
                                .lineLimit(1)
                        }
                    }
                    // 選手名は最低でも名前5文字ほど(「#15 サム・グ」くらい)は見えるよう幅を確保する
                    // 選手名を点数より先に縮める対象にしない(名前5文字ほどは見えるように)
                    .layoutPriority(1)
                    .opacity(isFailed ? 0.45 : 1.0)

                    Spacer(minLength: 2)

                    // 2桁対2桁(例: 24-31)でも省略せず1行で出す。点数は小さめの字にして、選手名に幅を回す
                    Text("\(progression.home)-\(progression.away)")
                        .font(.footnote.weight(.black).monospacedDigit())
                        .foregroundStyle(RugbyTheme.textPrimary)
                        .lineLimit(1)
                        .fixedSize()
                        .opacity(isFailed ? 0.45 : 1.0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // この得点の場面をプレー編集で開く(映像があればその場面から再生される)
            Button {
                playListInitialEventID = event.id
                isPlayListEditorPresented = true
            } label: {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(RugbyTheme.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("この場面を見る")
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func playerAvatar(playerID: UUID?, accent: Color, size: CGFloat) -> some View {
        let player = playerID.flatMap { id in players.first { $0.id == id } }
        ZStack {
            if let player,
               let imagePath = player.imagePath,
               let uiImage = ImageStorage.image(named: imagePath) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: size, height: size)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    )
            }
            Circle()
                .stroke(accent, lineWidth: 1.5)
                .frame(width: size, height: size)
        }
    }

    // MARK: - Calculations

    private func score(for teamID: UUID, half: Int? = nil) -> Int {
        scoringEvents
            .filter { event in
                event.teamID == teamID && (half == nil || event.half == half)
            }
            .reduce(0) { $0 + scoreValue(for: $1) }
    }

    private var scoringEventsForSelectedScope: [StatEvent] {
        guard let half = selectedScope.half else { return scoringEvents }
        return scoringEvents.filter { $0.half == half }
    }

    // 得点内訳は「決まった数」を出す。CON/PG/DG は失敗も記録されるので、
    // outcome が success のものだけ数える(蹴った数ではない)。
    private func countScoring(_ category: ScoringCategory, teamID: UUID, half: Int? = nil) -> Int {
        scoringEvents
            .filter { event in
                event.category == category.rawValue
                    && event.teamID == teamID
                    && event.outcome == "success"
                    && (half == nil || event.half == half)
            }
            .count
    }

    private func scoreValue(for event: StatEvent) -> Int {
        guard event.outcome == "success" else { return 0 }
return ScoringRules.points(category: event.category, widgetData: event.widgetData)
    }

    private func setPieceStats(category: String, teamID: UUID, half: Int? = nil) -> (success: Int, total: Int, rate: Double) {
        let events = setPieceEvents.filter { event in
            event.category == category
                && event.teamID == teamID
                && (half == nil || event.half == half)
        }
        let success = events.filter { $0.outcome == "success" }.count
        let total = events.count
        return (success, total, total == 0 ? 0 : Double(success) / Double(total))
    }

    // MARK: - Formatters

    private func teamName(for id: UUID) -> String {
        teams.first { $0.id == id }?.name ?? "チーム未設定"
    }

    // この試合のメンバー表(試合ごとの背番号)
    private var matchLineups: [MatchLineup] {
        allLineups.filter { $0.matchID == match.id }
    }

    private func playerName(for playerID: UUID?) -> String {
        guard let playerID, let player = players.first(where: { $0.id == playerID }) else {
            return "未設定"
        }
        return MatchNumbering.label(for: player, matchID: match.id, lineups: matchLineups)
    }

    // 認定トライは選手なしが正しい状態なので「未設定」(要入力)扱いにしない
    private func scorerLabel(for event: StatEvent) -> String {
        event.category == ScoringRules.penaltyTryCategory ? "認定トライ" : playerName(for: event.playerID)
    }

    private func needsScorer(_ event: StatEvent) -> Bool {
        event.playerID == nil && event.category != ScoringRules.penaltyTryCategory
    }

    private func percentText(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func timeText(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func halfLabel(_ half: Int) -> String {
        half >= 1 ? "後半" : "前半"
    }

    private func categoryTag(_ category: String) -> String {
        switch ScoringCategory(rawValue: category) {
        case .tryScore: return "TRY"
        case .conversion: return "CON"
        case .penaltyGoal: return "PG"
        case .dropGoal: return "DG"
        case .penaltyTry: return "PT"
        case nil: return category.uppercased()
        }
    }

    private func categoryColor(_ category: String) -> Color {
        switch ScoringCategory(rawValue: category) {
        case .tryScore: return Color(red: 0.10, green: 0.43, blue: 0.28)
        case .conversion: return RugbyTheme.accent
        case .penaltyGoal: return Color(red: 0.16, green: 0.33, blue: 0.65)
        case .dropGoal: return Color(red: 0.62, green: 0.30, blue: 0.04)
        case .penaltyTry: return Color(red: 0.07, green: 0.43, blue: 0.41)
        case nil: return .secondary
        }
    }

    private func moveScope(forward: Bool) {
        let scopes = SummaryScope.allCases
        guard let currentIndex = scopes.firstIndex(of: selectedScope) else { return }
        let nextIndex = forward
            ? min(currentIndex + 1, scopes.count - 1)
            : max(currentIndex - 1, 0)
        guard nextIndex != currentIndex else { return }

        withAnimation(.easeInOut(duration: 0.18)) {
            selectedScope = scopes[nextIndex]
        }
    }

}

private extension View {
    func summaryCard(cornerRadius: CGFloat = 4) -> some View {
        background(RugbyTheme.surface, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(RugbyTheme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .accessibilityElement(children: .contain)
    }
}

#Preview {
    NavigationStack {
        MatchSummaryView(match: Match(tournamentID: UUID(), homeTeamID: UUID(), awayTeamID: UUID(), playedAt: Date()))
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
