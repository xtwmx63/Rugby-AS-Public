//
//  MatchHeadToHeadView.swift
//  Rugby AS
//
//  試合詳細の「対戦成績」タブ。この2チームの過去の対戦(この試合より前、
//  「分析・集計に含める」試合だけ。開発版では、まだ取り込んでいない公式記録の試合も加える)を、
//  左=この試合のホーム・右=アウェイの向きで
//  勝ち・引き分け・負けと平均得点にまとめ、下に試合の一覧を出す。
//  上の切り替えで「全体」と年度ごと(大会の年度。未設定なら試合日の年)を選べる。
//  点数は保存値でなく StatEvent から数え直す(後から記録を直しても正しくなる)。
//

import SwiftData
import SwiftUI

struct MatchHeadToHeadView: View {
    @Environment(\.modelContext) private var modelContext

    let match: Match
    let homeTeam: Team?
    let awayTeam: Team?
    let homeColor: Color
    let awayColor: Color

    @Query private var tournaments: [Tournament]
    @State private var meetings: [Meeting] = []
    @State private var hasLoaded = false
    // 表示する年度。nil なら全体
    @State private var selectedYear: Int?
    // タップした過去の試合(値で積む。NavigationLink の遷移先を直接書くと、
    // 試合詳細の中から試合詳細を積んだときに画面の作り直しが止まらなくなるため)
    @State private var openedMatch: Match?
    @State private var openedOfficial: OfficialRecordLink?
    // 公式記録の終了した試合(開いたときに1回だけ読む。公式記録のない配布版では空)
    @State private var officialRecords: [OfficialRecordSummary] = []

    private struct OfficialRecordLink: Identifiable, Hashable { let id: String }

    /// 過去の対戦1試合ぶん。点数・チームはその試合のホーム/アウェイの向き
    private struct Meeting: Identifiable {
        let id: String
        let playedAt: Date
        let tournamentName: String
        let homeTeam: Team?
        let awayTeam: Team?
        let homeScore: Int
        let awayScore: Int
        // その試合のホームが、この試合のホームと同じチームか
        let homeIsThisHome: Bool
        // 大会の年度(未設定なら試合日の年)。公式記録は公式の年度
        let seasonYear: Int
        // 保存した試合なら試合、まだ取り込んでいない公式記録なら公式記録の ID
        let match: Match?
        let officialRecordID: String?
    }

    /// 選んだ年度の試合(全体ならすべて)
    private var visibleMeetings: [Meeting] {
        guard let selectedYear else { return meetings }
        return meetings.filter { $0.seasonYear == selectedYear }
    }

    /// 過去の対戦がある年度(新しい順)
    private var availableYears: [Int] {
        Array(Set(meetings.map(\.seasonYear))).sorted(by: >)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if hasLoaded && meetings.isEmpty {
                emptyState
            } else {
                yearPicker
                summaryCard
                meetingsList
            }
        }
        .navigationDestination(item: $openedMatch) { past in
            // 試合詳細は画面下に独自のボタンがあるのでタブを隠す(試合一覧から開いたときと同じ)
            MatchSummaryView(match: past)
                .toolbar(.hidden, for: .tabBar)
        }
        #if DEBUG
        .navigationDestination(item: $openedOfficial) { link in
            OfficialRecordDetailView(id: link.id)
                .toolbar(.hidden, for: .tabBar)
        }
        #endif
        .onAppear(perform: load)
        .task { await loadOfficialRecords() }
        .onReceive(ModelSaveSignal.didSave) { _ in load() }
    }

    // MARK: - 全体/年度の切り替え

    private var scopeTitle: String {
        selectedYear.map { "\(String($0))年度" } ?? "過去全体"
    }

    private var yearPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                yearChip(title: "全体", year: nil)
                ForEach(availableYears, id: \.self) { year in
                    yearChip(title: "\(String(year))年度", year: year)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("表示する年度")
    }

    private func yearChip(title: String, year: Int?) -> some View {
        let isSelected = selectedYear == year
        return Button { selectedYear = year } label: {
            Text(title)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(isSelected ? RugbyTheme.onAccent : RugbyTheme.textSecondary)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(isSelected ? RugbyTheme.accent : RugbyTheme.surface,
                            in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - まとめ(勝ち・引き分け・負け)

    private var summary: (homeWins: Int, draws: Int, awayWins: Int, homeAverage: Double, awayAverage: Double) {
        var homeWins = 0, draws = 0, awayWins = 0, homePoints = 0, awayPoints = 0
        for meeting in visibleMeetings {
            let (home, away) = pointsForThisMatchSides(meeting)
            homePoints += home
            awayPoints += away
            if home > away { homeWins += 1 } else if home < away { awayWins += 1 } else { draws += 1 }
        }
        let count = Double(max(visibleMeetings.count, 1))
        return (homeWins, draws, awayWins, Double(homePoints) / count, Double(awayPoints) / count)
    }

    // 過去の試合の点数を「この試合のホーム側・アウェイ側」に並べ替える
    private func pointsForThisMatchSides(_ meeting: Meeting) -> (Int, Int) {
        meeting.homeIsThisHome
            ? (meeting.homeScore, meeting.awayScore)
            : (meeting.awayScore, meeting.homeScore)
    }

    private var summaryCard: some View {
        let result = summary

        return VStack(spacing: 14) {
            Text("\(scopeTitle) \(visibleMeetings.count)試合の対戦成績")
                .font(.headline.weight(.heavy))
                .foregroundStyle(RugbyTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .top) {
                countBlock(result.homeWins, label: "勝ち", team: homeTeam, color: homeColor)
                Spacer()
                countBlock(result.draws, label: "引き分け", team: nil, color: Color(white: 0.55))
                Spacer()
                countBlock(result.awayWins, label: "勝ち", team: awayTeam, color: awayColor)
            }

            HStack {
                Text(String(format: "%.1f", result.homeAverage))
                    .font(.title3.weight(.heavy).monospacedDigit())
                    .foregroundStyle(homeColor.prefersDarkText ? RugbyTheme.textPrimary : homeColor)
                Spacer()
                Text("平均得点")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(RugbyTheme.textSecondary)
                Spacer()
                Text(String(format: "%.1f", result.awayAverage))
                    .font(.title3.weight(.heavy).monospacedDigit())
                    .foregroundStyle(awayColor.prefersDarkText ? RugbyTheme.textPrimary : awayColor)
            }

            // 平均得点の割合(両チームの色で分ける。どちらも0点なら半分ずつ灰色)
            GeometryReader { proxy in
                let sum = result.homeAverage + result.awayAverage
                let homeShare = sum > 0 ? result.homeAverage / sum : 0.5
                HStack(spacing: 2) {
                    Rectangle().fill(sum > 0 ? homeColor : Color(white: 0.8))
                        .frame(width: max(0, (proxy.size.width - 2) * homeShare))
                    Rectangle().fill(sum > 0 ? awayColor : Color(white: 0.8))
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
            .accessibilityHidden(true)
        }
        .padding(16)
        .headToHeadCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(scopeTitle) \(visibleMeetings.count)試合、\(teamName(homeTeam))\(result.homeWins)勝、引き分け\(result.draws)、\(teamName(awayTeam))\(result.awayWins)勝"
        )
    }

    private func countBlock(_ count: Int, label: String, team: Team?, color: Color) -> some View {
        VStack(spacing: 6) {
            Text("\(count)")
                .font(.system(size: 26, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(color.prefersDarkText ? RugbyTheme.textPrimary : .white)
                .frame(minWidth: 56, minHeight: 44)
                .background(color, in: RoundedRectangle(cornerRadius: 12))
            Text(team.map { "\(teamName($0))の\(label)" } ?? label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(RugbyTheme.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: 110)
        }
    }

    // MARK: - 過去の試合の一覧

    private var meetingsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("過去の対戦")
                .font(.headline.weight(.heavy))
                .foregroundStyle(RugbyTheme.textPrimary)
            VStack(spacing: 0) {
                ForEach(Array(visibleMeetings.enumerated()), id: \.element.id) { index, meeting in
                    if index > 0 { Divider().overlay(RugbyTheme.border) }
                    Button {
                        if let past = meeting.match {
                            openedMatch = past
                        } else if let id = meeting.officialRecordID {
                            openedOfficial = OfficialRecordLink(id: id)
                        }
                    } label: {
                        meetingRow(meeting)
                    }
                    .buttonStyle(.plain)
                }
            }
            .headToHeadCard()
            Text("この試合より前の、同じ2チームの試合です（ホーム・アウェイは問いません）。「分析・集計に含める」をオフにした試合は数えません。年度は大会の年度で、未設定の大会は試合日の年で分けます。"
                 + (officialRecords.isEmpty ? "" : "「公式記録」の印は、まだ取り込んでいない公式記録の試合です（取り込み済みの試合や同じ日の同じ対戦とは重ねて数えません）。"))
                .font(.caption)
                .foregroundStyle(RugbyTheme.textSecondary)
        }
    }

    /// 過去の1試合。FotMob・Premier League の対戦成績と同じく、スコアの両脇にロゴを置き、
    /// 外側にチーム名(勝った側は太字)。上の行は日付と大会名。
    private func meetingRow(_ meeting: Meeting) -> some View {
        let homeWon = meeting.homeScore > meeting.awayScore
        let awayWon = meeting.awayScore > meeting.homeScore
        let home = meeting.homeTeam
        let away = meeting.awayTeam

        return VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text(Self.dateFormatter.string(from: meeting.playedAt))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(RugbyTheme.textSecondary)
                if meeting.officialRecordID != nil {
                    Text("公式記録")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(RugbyTheme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(Capsule().stroke(RugbyTheme.accent, lineWidth: 1))
                }
                Spacer(minLength: 8)
                Text(meeting.tournamentName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(RugbyTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RugbyTheme.background, in: Capsule())
            }

            HStack(spacing: 8) {
                Text(teamName(home))
                    .font(.subheadline.weight(homeWon ? .heavy : .medium))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                crest(home, size: 28)
                Text("\(meeting.homeScore) - \(meeting.awayScore)")
                    .font(.subheadline.weight(.heavy).monospacedDigit())
                    .foregroundStyle(RugbyTheme.onAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RugbyTheme.header, in: RoundedRectangle(cornerRadius: 6))
                    .fixedSize()
                crest(away, size: 28)
                Text(teamName(away))
                    .font(.subheadline.weight(awayWon ? .heavy : .medium))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(RugbyTheme.textPrimary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(teamName(home)) \(meeting.homeScore)対\(meeting.awayScore) \(teamName(away))")
        .accessibilityValue("\(Self.dateFormatter.string(from: meeting.playedAt))、\(meeting.tournamentName)" + (meeting.officialRecordID == nil ? "" : "、まだ取り込んでいない公式記録"))
        .accessibilityAddTraits(.isButton)
    }

    private func crest(_ team: Team?, size: CGFloat) -> some View {
        let accent = team?.displayColor ?? RugbyTheme.textSecondary
        return StoredImageView(name: team?.logoPath, maxDimension: size * 3) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            Image(systemName: "shield.lefthalf.filled")
                .resizable()
                .scaledToFit()
                .padding(size * 0.1)
                .foregroundStyle(accent)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.title2)
                .foregroundStyle(RugbyTheme.textSecondary)
            Text("この2チームの過去の対戦はまだありません")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(RugbyTheme.textPrimary)
            Text("この試合より前の、「分析・集計に含める」試合が対象です。")
                .font(.caption)
                .foregroundStyle(RugbyTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .headToHeadCard()
    }

    // MARK: - 読み込み

    private func load() {
        let teamA = match.homeTeamID
        let teamB = match.awayTeamID
        let currentID = match.id
        let playedAt = match.playedAt

        // この2チームの保存済みの試合すべて(公式記録との重複を除くのにも使う)
        let between = (try? modelContext.fetch(FetchDescriptor<Match>(
            predicate: #Predicate {
                ($0.homeTeamID == teamA && $0.awayTeamID == teamB)
                    || ($0.homeTeamID == teamB && $0.awayTeamID == teamA)
            },
            sortBy: [SortDescriptor(\.playedAt, order: .reverse)]
        ))) ?? []
        let pastMatches = between.filter { $0.playedAt < playedAt && $0.id != currentID && !$0.isExcludedFromStats }

        let matchIDs = pastMatches.map(\.id)
        let categories = ScoringRules.categories
        let events = (try? modelContext.fetch(FetchDescriptor<StatEvent>(
            predicate: #Predicate {
                matchIDs.contains($0.matchID) && $0.outcome == "success" && categories.contains($0.category)
            }
        ))) ?? []

        var points: [UUID: [UUID: Int]] = [:]
        for event in events {
            guard let teamID = event.teamID else { continue }
            points[event.matchID, default: [:]][teamID, default: 0] += ScoringRules.points(category: event.category, widgetData: event.widgetData)
        }

        let calendar = Calendar(identifier: .gregorian)
        var combined = pastMatches.map { past in
            let byTeam = points[past.id] ?? [:]
            let tournamentYear = tournaments.first { $0.id == past.tournamentID }?.year
            return Meeting(
                id: past.id.uuidString,
                playedAt: past.playedAt,
                tournamentName: tournamentName(for: past),
                homeTeam: team(for: past.homeTeamID),
                awayTeam: team(for: past.awayTeamID),
                homeScore: byTeam[past.homeTeamID] ?? 0,
                awayScore: byTeam[past.awayTeamID] ?? 0,
                homeIsThisHome: past.homeTeamID == teamA,
                seasonYear: tournamentYear ?? calendar.component(.year, from: past.playedAt),
                match: past,
                officialRecordID: nil
            )
        }

        // まだ取り込んでいない公式記録の対戦(この試合自体・取り込み済み・同じ日の同じ対戦は除く)
        if !officialRecords.isEmpty, let home = homeTeam, let away = awayTeam {
            let saved = between.map { OfficialHeadToHead.SavedMatch(officialRecordID: $0.officialRecordID, playedAt: $0.playedAt) }
            // この試合の人数(大会の設定、なければ大会名から)。違う人数の公式記録は混ぜない
            let thisTournament = tournaments.first { $0.id == match.tournamentID }
            let variant = thisTournament.flatMap { $0.variantRaw.flatMap(RugbyVariant.init(rawValue:))
                ?? TournamentCategory.inferredVariant(from: $0.officialName) }
            let found = OfficialHeadToHead.meetings(in: officialRecords, teamA: [home.name] + home.aliases,
                                                    teamB: [away.name] + away.aliases, before: playedAt, saved: saved,
                                                    variant: variant)
            combined += found.map { item in
                Meeting(
                    id: item.summary.id,
                    playedAt: item.playedAt,
                    tournamentName: item.summary.tournament,
                    homeTeam: item.homeIsTeamA ? home : away,
                    awayTeam: item.homeIsTeamA ? away : home,
                    homeScore: item.summary.homeScore ?? 0,
                    awayScore: item.summary.awayScore ?? 0,
                    homeIsThisHome: item.homeIsTeamA,
                    seasonYear: item.summary.year,
                    match: nil,
                    officialRecordID: item.summary.id
                )
            }
        }
        meetings = combined.sorted { $0.playedAt > $1.playedAt }
        // 記録を直して選んでいた年度の試合がなくなったら全体に戻す
        if let selectedYear, !meetings.contains(where: { $0.seasonYear == selectedYear }) {
            self.selectedYear = nil
        }
        hasLoaded = true
    }

    /// 公式記録の終了した試合を読む(公式記録のない配布版では何もしない)。重いので裏で読む。
    private func loadOfficialRecords() async {
        guard officialRecords.isEmpty,
              let url = Bundle.main.url(forResource: "OfficialRecords", withExtension: "sqlite") else { return }
        let records = (try? await OfficialSummaryCache.shared.finished(at: url)) ?? []
        guard !records.isEmpty else { return }
        officialRecords = records
        load()
    }

    // MARK: - 小さな部品

    private func team(for id: UUID) -> Team? {
        if id == homeTeam?.id { return homeTeam }
        if id == awayTeam?.id { return awayTeam }
        return nil
    }

    private func teamName(_ team: Team?) -> String {
        team?.name ?? "チーム未設定"
    }

    private func tournamentName(for match: Match) -> String {
        tournaments.first { $0.id == match.tournamentID }?.officialName ?? "大会未設定"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter
    }()
}

private extension View {
    // 試合詳細の他のカードと同じ白い面と細い枠
    func headToHeadCard() -> some View {
        background(RugbyTheme.surface, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(RugbyTheme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
