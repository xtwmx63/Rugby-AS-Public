import SwiftData
import SwiftUI

/// チーム成績。右上の切り替えボタンで、一覧に戻らずにほかのチームの成績へ移れる。
struct TeamPerformanceView: View {
    @State private var team: Team

    init(team: Team) {
        _team = State(initialValue: team)
    }

    var body: some View {
        // チームが変わったら中身を作り直す(年度・対戦相手の絞り込みや集計を前のチームから持ち越さない)
        TeamPerformanceContent(team: team) { team = $0 }
            .id(team.id)
    }
}

private struct TeamPerformanceContent: View {
    let team: Team
    let switchTeam: (Team) -> Void
    @Environment(\.modelContext) private var modelContext
    @Query private var matches: [Match]
    @Query private var tournaments: [Tournament]
    @Query private var teams: [Team]
    // 得点ランキングに出る選手だけを読む(全選手を読むと、選手が数万人いるときに重いため)
    @State private var players: [Player] = []
    @State private var scoringEntries: [TeamPerformance.ScoringEntry] = []
    @State private var openedPlayer: Player?
    @State private var showsDisplaySettings = false
    @AppStorage("teamPerformance.showTrend") private var showTrend = true
    @AppStorage("teamPerformance.showLeaders") private var showLeaders = true
    @AppStorage("teamPerformance.showForm") private var showForm = true
    @State private var results: [TeamPerformance.Result] = []
    @State private var selectedYear: Int?
    @State private var selectedOpponent: UUID?
    @State private var openedMatch: Match?
    @State private var refreshID = UUID()
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var section: SectionTab = .overview
    @State private var opponentSearch = ""
    @State private var showsTeamSwitcher = false

    private enum SectionTab: String, CaseIterable {
        case overview = "サマリー", opponents = "対戦相手", matches = "試合"
    }
    private var winColor: Color { team.displayColor }
    private let lossColor = TeamPerformanceColors.charcoal
    private let drawColor = Color(red: 0.60, green: 0.61, blue: 0.64)

    init(team: Team, switchTeam: @escaping (Team) -> Void) {
        self.team = team
        self.switchTeam = switchTeam
        let id = team.id
        _matches = Query(filter: #Predicate<Match> { $0.homeTeamID == id || $0.awayTeamID == id })
    }

    private var years: [Int] { Array(Set(results.map(\.year))).sorted(by: >) }
    private var yearResults: [TeamPerformance.Result] {
        results.filter { selectedYear == nil || $0.year == selectedYear }
    }
    private var opponents: [UUID] {
        let groups = Dictionary(grouping: yearResults, by: \.opponentID)
        return groups.keys.sorted {
            let lhs = groups[$0]?.count ?? 0, rhs = groups[$1]?.count ?? 0
            if lhs != rhs { return lhs > rhs }
            if name($0) != name($1) { return name($0) < name($1) }
            return $0.uuidString < $1.uuidString
        }
    }
    private var visibleResults: [TeamPerformance.Result] {
        yearResults.filter { selectedOpponent == nil || $0.opponentID == selectedOpponent }
    }
    private var scope: String { selectedYear.map { "\(String($0))年度" } ?? "全年度" }
    private var teamTint: Color {
        team.performanceAccent
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    teamHeader
                        .id("top")
                    Section {
                        VStack(alignment: .leading, spacing: 24) {
                            content
                        }
                        .padding(20)
                        .padding(.bottom, 24)
                    } header: {
                        controls
                    }
                }
                .padContentWidth(980)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: section) { _, _ in proxy.scrollTo("top", anchor: .top) }
            .onChange(of: selectedYear) { _, _ in
                if let selectedOpponent, !opponents.contains(selectedOpponent) { self.selectedOpponent = nil }
                proxy.scrollTo("top", anchor: .top)
            }
            .onChange(of: selectedOpponent) { _, _ in proxy.scrollTo("top", anchor: .top) }
        }
        .background(RugbyTheme.background)
        .foregroundStyle(RugbyTheme.textPrimary)
        .navigationTitle("チーム成績")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showsDisplaySettings = true } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("表示をカスタマイズ")
                Button { showsTeamSwitcher = true } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                    .accessibilityLabel("ほかのチームに切り替え")
            }
        }
        .sheet(isPresented: $showsDisplaySettings) { displaySettings }
        .sheet(isPresented: $showsTeamSwitcher) {
            TeamPerformanceSwitcherSheet(teams: teams, currentTeamID: team.id) { picked in
                showsTeamSwitcher = false
                switchTeam(picked)
            }
        }
        .navigationDestination(item: $openedPlayer) { player in PlayerDetailView(player: player) }
        .navigationDestination(item: $openedMatch) { match in
            MatchSummaryView(match: match).toolbar(.hidden, for: .tabBar)
        }
        .task(id: refreshID) { await load() }
        .onReceive(ModelSaveSignal.didSave) { _ in refreshID = UUID() }
    }

    private var teamHeader: some View {
        HStack(spacing: 14) {
            crest(team, size: 54)
            VStack(alignment: .leading, spacing: 5) {
                Text(team.name).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                Text("TEAM PERFORMANCE")
                    .font(.system(size: 10, weight: .bold, design: .rounded)).tracking(2)
                    .foregroundStyle(RugbyTheme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RugbyTheme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(team.displayColor).frame(height: 3) }
    }

    private var controls: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Menu {
                    Button("全年度") { selectedYear = nil }
                    ForEach(years, id: \.self) { year in
                        Button("\(String(year))年度") { selectedYear = year }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "calendar")
                        Text(scope).fontWeight(.semibold)
                        Image(systemName: "chevron.down").font(.caption2.bold())
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 12).frame(minHeight: 44)
                    .background(RugbyTheme.elevated.opacity(0.65), in: Capsule())
                }
                .accessibilityLabel("年度、\(scope)")
                Spacer(minLength: 0)
                Text("\(section == .opponents ? yearResults.count : visibleResults.count)試合")
                    .font(.caption.monospacedDigit()).foregroundStyle(RugbyTheme.textSecondary)
            }
            HStack(spacing: 3) {
                ForEach(SectionTab.allCases, id: \.self) { tab in
                    Button { section = tab } label: {
                        Text(tab.rawValue)
                            .font(.subheadline.weight(section == tab ? .bold : .medium))
                            .foregroundStyle(section == tab ? .white : RugbyTheme.textSecondary)
                            .frame(maxWidth: .infinity).frame(minHeight: 44)
                            .background(section == tab ? RugbyTheme.header : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(section == tab ? .isSelected : [])
                }
            }.padding(3).background(RugbyTheme.background, in: RoundedRectangle(cornerRadius: 7))
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 20).padding(.top, 12)
        .background(RugbyTheme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(RugbyTheme.border).frame(height: 0.5) }
    }

    @ViewBuilder private var content: some View {
        if isLoading {
            ProgressView("成績を集計中…").frame(maxWidth: .infinity).padding(.vertical, 60)
        } else if loadFailed {
            VStack(spacing: 12) {
                RugbyEmptyState(symbol: "exclamationmark.arrow.triangle.2.circlepath", title: "成績を読み込めませんでした",
                                message: "もう一度読み込んでください。")
                Button("再読み込み") { refreshID = UUID() }.buttonStyle(RugbyPrimaryButtonStyle())
            }
        } else if results.isEmpty {
            RugbyEmptyState(symbol: "chart.bar.xaxis", title: "最初の試合結果を待っています",
                            message: "登録・取り込み済みの試合を終了すると、ここに成績が表示されます。集計対象外の試合は含みません。")
        } else {
            if section != .opponents, let selectedOpponent {
                opponentScope(selectedOpponent)
            }
            switch section {
            case .overview: overview
            case .opponents: opponentList
            case .matches: matchList
            }
        }
    }

    private func opponentScope(_ id: UUID) -> some View {
        HStack(spacing: 10) {
            crest(teams.first { $0.id == id }, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text("対戦成績").font(.caption).foregroundStyle(RugbyTheme.textSecondary)
                Text("対 \(name(id))").font(.subheadline.bold())
            }
            Spacer(minLength: 4)
            Button { selectedOpponent = nil } label: {
                Image(systemName: "xmark.circle.fill").font(.title3)
                    .foregroundStyle(RugbyTheme.textSecondary).frame(width: 44, height: 44)
            }.accessibilityLabel("対戦相手の絞り込みを解除")
        }
        .padding(12).background(teamTint.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    private var overview: some View {
        let summary = TeamPerformance.summary(visibleResults)
        return VStack(alignment: .leading, spacing: 24) {
            recordCard(summary)
            if !visibleResults.isEmpty {
                if showTrend {
                    TeamPerformanceTrendView(results: visibleResults, accent: team.displayColor, opponentName: name) { openedMatch = $0 }
                }
                if showForm { recentForm }
                pointsCard(summary)
                if showLeaders { leaderSection }
                if selectedYear == nil { seasonTable }
                VStack(spacing: 12) {
                    sectionHeading("最近の試合", trailing: "すべて見る") { section = .matches }
                    ForEach(Array(visibleResults.prefix(3))) { matchCard($0) }
                }
            } else {
                RugbyEmptyState(symbol: "sportscourt", title: "この条件の試合はありません",
                                message: "年度や対戦相手を変更してください。")
            }
        }
    }

    private func recordCard(_ summary: TeamPerformance.Summary) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(scope + "の成績").font(.subheadline.bold())
                    Text("終了した \(summary.played) 試合")
                        .font(.caption).foregroundStyle(RugbyTheme.textSecondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(summary.winRate.map { ($0 * 100).formatted(.number.precision(.fractionLength(1))) + "%" } ?? "—")
                        .font(.system(size: 32, weight: .heavy)).monospacedDigit()
                        .foregroundStyle(team.displayColor)
                        .minimumScaleFactor(0.7)
                    Text("勝率").font(.caption).foregroundStyle(RugbyTheme.textSecondary)
                }
            }
            HStack(spacing: 0) {
                outcomeMetric(summary.wins, label: "勝ち", color: team.displayColor)
                Divider().frame(height: 42)
                outcomeMetric(summary.draws, label: "引き分け", color: drawColor)
                Divider().frame(height: 42)
                outcomeMetric(summary.losses, label: "負け", color: lossColor)
            }
            resultBar(summary, height: 7)
        }
        .padding(18)
        .background(RugbyTheme.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    private func outcomeMetric(_ value: Int, label: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Text("\(value)").font(.system(size: 32, weight: .heavy)).monospacedDigit()
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label).font(.caption.weight(.medium))
            }.foregroundStyle(RugbyTheme.textSecondary)
        }.frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore).accessibilityLabel("\(value)\(label)")
    }

    private func resultBar(_ summary: TeamPerformance.Summary, height: CGFloat) -> some View {
        GeometryReader { geometry in
            let segments = [
                (count: summary.wins, color: team.displayColor),
                (count: summary.draws, color: drawColor),
                (count: summary.losses, color: lossColor)
            ].filter { $0.count > 0 }
            // 試合詳細と同じ2ptの間隔。空白を除いた幅で勝敗の割合を維持する。
            let availableWidth = max(0, geometry.size.width - CGFloat(max(0, segments.count - 1)) * 2)
            HStack(spacing: 2) {
                ForEach(segments.indices, id: \.self) { index in
                    Rectangle().fill(segments[index].color)
                        .frame(width: availableWidth * CGFloat(segments[index].count) / CGFloat(max(1, summary.played)))
                }
            }
        }.frame(height: height)
            .background(summary.played == 0 ? RugbyTheme.elevated : RugbyTheme.surface)
            .clipShape(Capsule()).accessibilityHidden(true)
    }

    private var recentForm: some View {
        TeamRecentFormView(results: visibleResults, teams: teams) { openedMatch = $0 }
    }

    private func pointsCard(_ summary: TeamPerformance.Summary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("得点・失点").font(.headline)
            HStack(spacing: 12) {
                pointMetric("平均得点", value: decimal(summary.averageFor), total: "総得点 \(summary.pointsFor)", color: team.displayColor)
                Divider()
                pointMetric("平均失点", value: decimal(summary.averageAgainst), total: "総失点 \(summary.pointsAgainst)", color: lossColor)
            }.fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Text("得失点差").font(.subheadline)
                Spacer()
                Text((summary.pointsFor >= summary.pointsAgainst ? "+" : "") + String(summary.pointsFor - summary.pointsAgainst))
                    .font(.headline.monospacedDigit())
            }
        }.padding(20).background(RugbyTheme.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    private func pointMetric(_ title: String, value: String, total: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(RugbyTheme.textSecondary)
            Text(value).font(.system(size: 30, weight: .heavy)).foregroundStyle(color).monospacedDigit()
            Text(total).font(.caption).foregroundStyle(RugbyTheme.textSecondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var seasonTable: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("年度別成績").font(.headline)
            VStack(spacing: 0) {
                ForEach(years, id: \.self) { year in
                    let rows = results.filter { $0.year == year && (selectedOpponent == nil || $0.opponentID == selectedOpponent) }
                    if !rows.isEmpty {
                        let summary = TeamPerformance.summary(rows)
                        Button { selectedYear = year } label: {
                            HStack(spacing: 12) {
                                Text(String(year)).font(.headline.monospacedDigit())
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("\(summary.wins)勝  \(summary.draws)分  \(summary.losses)敗").font(.subheadline.monospacedDigit())
                                    resultBar(summary, height: 4)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Text("\(summary.played)試合").font(.caption).foregroundStyle(RugbyTheme.textSecondary)
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(RugbyTheme.textSecondary)
                            }.padding(16).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        if year != years.last { Divider().padding(.horizontal, 16) }
                    }
                }
            }.background(RugbyTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var opponentList: some View {
        let ids = opponents.filter { opponentSearch.trimmingCharacters(in: .whitespaces).isEmpty || name($0).localizedStandardContains(opponentSearch.trimmingCharacters(in: .whitespaces)) }
        return LazyVStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(RugbyTheme.textSecondary)
                TextField("対戦相手を検索", text: $opponentSearch).submitLabel(.search)
                if !opponentSearch.isEmpty {
                    Button { opponentSearch = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityLabel("検索をクリア")
                }
            }.padding(14).background(RugbyTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Text("\(ids.count)チーム").font(.headline)
                Spacer()
                Text("対戦数が多い順").font(.caption).foregroundStyle(RugbyTheme.textSecondary)
            }
            if ids.isEmpty {
                RugbyEmptyState(symbol: "magnifyingglass", title: "対戦相手が見つかりません", message: "チーム名や年度を変更してください。")
            }
            ForEach(ids, id: \.self) { id in
                let summary = TeamPerformance.summary(yearResults.filter { $0.opponentID == id })
                Button {
                    selectedOpponent = id
                    section = .overview
                } label: {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 12) {
                            crest(teams.first { $0.id == id }, size: 40)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(name(id)).font(.headline).multilineTextAlignment(.leading)
                                Text("\(summary.played)試合 · 得失点差 \(summary.pointsFor - summary.pointsAgainst)")
                                    .font(.caption).foregroundStyle(RugbyTheme.textSecondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(RugbyTheme.textSecondary)
                        }
                        HStack {
                            resultLegend("\(summary.wins)勝", color: team.displayColor)
                            Spacer()
                            resultLegend("\(summary.draws)分", color: drawColor)
                            Spacer()
                            resultLegend("\(summary.losses)敗", color: lossColor)
                        }.font(.subheadline.bold().monospacedDigit())
                        resultBar(summary, height: 5)
                    }.padding(18).background(RugbyTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
            }
        }
    }

    private func resultLegend(_ title: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(title).foregroundStyle(RugbyTheme.textPrimary)
        }
    }

    private var matchList: some View {
        LazyVStack(spacing: 12) {
            sectionHeading("試合結果", trailing: "\(visibleResults.count)試合・新しい順")
            if visibleResults.isEmpty {
                RugbyEmptyState(symbol: "sportscourt", title: "この条件の試合はありません", message: "年度や対戦相手を変更してください。")
            }
            ForEach(visibleResults) { matchCard($0) }
        }
    }

    private func matchCard(_ result: TeamPerformance.Result) -> some View {
        Button { openedMatch = result.match } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(result.match.playedAt, format: .dateTime.year().month().day())
                            .font(.caption.weight(.medium))
                        Text(tournaments.first { $0.id == result.match.tournamentID }?.officialName ?? "大会未設定")
                            .font(.caption2).lineLimit(2)
                    }.foregroundStyle(RugbyTheme.textSecondary)
                    Spacer(minLength: 4)
                    Text(result.outcome).font(.caption.bold()).padding(.horizontal, 9).padding(.vertical, 5)
                        .foregroundStyle(resultColor(result))
                        .background(resultColor(result).opacity(0.1), in: Capsule())
                }
                HStack(spacing: 12) {
                    VStack(spacing: 10) {
                        scoreLine(team, fallback: team.name, score: result.pointsFor)
                        scoreLine(teams.first { $0.id == result.opponentID }, fallback: name(result.opponentID), score: result.pointsAgainst)
                    }
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(RugbyTheme.textSecondary)
                }
            }.padding(16).background(RugbyTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }

    private func scoreLine(_ team: Team?, fallback: String, score: Int) -> some View {
        HStack(spacing: 10) {
            crest(team, size: 24)
            Text(fallback).font(.subheadline.weight(.semibold)).multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            Text("\(score)").font(.system(size: 22, weight: .bold)).monospacedDigit()
        }
    }

    private func sectionHeading(_ title: String, trailing: String, action: (() -> Void)? = nil) -> some View {
        HStack {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            Spacer()
            if let action {
                Button(trailing, action: action).font(.caption.bold()).frame(minHeight: 44)
            } else {
                Text(trailing).font(.caption).foregroundStyle(RugbyTheme.textSecondary)
            }
        }
    }

    private func crest(_ team: Team?, size: CGFloat) -> some View {
        StoredImageView(name: team?.logoPath, maxDimension: 160) { image in
            image.resizable().scaledToFit().frame(width: size, height: size)
        } placeholder: {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: size * 0.47, weight: .medium))
                .foregroundStyle(team?.displayColor ?? RugbyTheme.accent)
                .frame(width: size, height: size)
                .background((team?.displayColor ?? RugbyTheme.accent).opacity(0.09), in: RoundedRectangle(cornerRadius: size * 0.25))
        }.accessibilityHidden(true)
    }

    private var displaySettings: some View {
        NavigationStack {
            Form {
                Section("サマリーに表示") {
                    Toggle("パフォーマンス推移", isOn: $showTrend)
                    Toggle("直近の試合（5〜30試合）", isOn: $showForm)
                    Toggle("チーム内ランキング", isOn: $showLeaders)
                }
                Section {
                    Button("標準の表示に戻す") { showTrend = true; showForm = true; showLeaders = true }
                } footer: {
                    Text("表示の設定は次回も引き継がれます。試合データは変わりません。")
                }
            }
            .tint(teamTint)
            .navigationTitle("表示をカスタマイズ").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { showsDisplaySettings = false } } }
        }.presentationDetents([.medium, .large])
    }

    private var leaderSection: some View {
        TeamPerformanceLeadersView(team: team, players: players, entries: scoringEntries,
                                   matchIDs: Set(visibleResults.map(\.id))) { openedPlayer = $0 }
    }

    private func resultColor(_ result: TeamPerformance.Result) -> Color {
        result.pointsFor > result.pointsAgainst ? winColor : result.pointsFor < result.pointsAgainst ? lossColor : drawColor
    }
    private func name(_ id: UUID) -> String { teams.first { $0.id == id }?.name ?? "チーム未設定" }
    private func decimal(_ value: Double?) -> String { value.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—" }
    private func load() async {
        isLoading = true
        loadFailed = false
        let sides = matches.map { MatchListSide(id: $0.id, home: $0.homeTeamID, away: $0.awayTeamID) }
        let container = modelContext.container
        let teamID = team.id
        let matchIDs = Set(sides.map(\.id))
        let worker = Task.detached(priority: .userInitiated) {
            // このチームの試合の記録だけを読む
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let tallies = try MatchListSummary.load(context: context, sides: sides, onlyListed: true)
            let entries = try TeamPerformance.loadScorers(container: container, teamID: teamID, matchIDs: matchIDs)
            return (tallies, entries)
        }
        do {
            let (tallies, entries) = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            scoringEntries = entries
            let playerIDs = Array(Set(entries.compactMap(\.playerID)))
            players = playerIDs.isEmpty ? [] : (try? modelContext.fetch(FetchDescriptor<Player>(
                predicate: #Predicate { playerIDs.contains($0.id) }))) ?? []
            results = TeamPerformance.results(teamID: team.id, matches: matches, tallies: tallies, tournaments: tournaments)
            if let selectedYear, !years.contains(selectedYear) { self.selectedYear = nil }
            if let selectedOpponent, !opponents.contains(selectedOpponent) { self.selectedOpponent = nil }
            isLoading = false
        } catch {
            guard !Task.isCancelled else { return }
            loadFailed = true
            isLoading = false
        }
    }
}

/// チーム成績の切り替え先を選ぶシート。名前で検索でき、今のチームには印が付く。
private struct TeamPerformanceSwitcherSheet: View {
    let teams: [Team]
    let currentTeamID: UUID
    let pick: (Team) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var visibleTeams: [Team] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return teams
            .filter { query.isEmpty || $0.name.localizedStandardContains(query) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(visibleTeams) { team in
                    Button {
                        if team.id == currentTeamID { dismiss() } else { pick(team) }
                    } label: {
                        HStack(spacing: 12) {
                            StoredImageView(name: team.logoPath, maxDimension: 120) { image in
                                image.resizable().scaledToFit().frame(width: 30, height: 30)
                            } placeholder: {
                                Image(systemName: "shield.lefthalf.filled")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(team.displayColor)
                                    .frame(width: 30, height: 30)
                                    .background(team.displayColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
                            }.accessibilityHidden(true)
                            Text(team.name).foregroundStyle(RugbyTheme.textPrimary)
                            Spacer(minLength: 4)
                            if team.id == currentTeamID {
                                Image(systemName: "checkmark").font(.body.bold()).foregroundStyle(RugbyTheme.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(team.id == currentTeamID ? .isSelected : [])
                }
            }
            .overlay {
                if visibleTeams.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "チーム名で検索")
            .navigationTitle("チームを切り替え").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }
    }
}
