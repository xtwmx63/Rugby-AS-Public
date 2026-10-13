#if DEBUG
import SwiftData
import SwiftUI

/// Fictional, disposable content for reviewing the app's main screens in Simulator.
struct RugbyDesignPreview: View {
    @Environment(\.modelContext) private var context
    @State private var isReady = false

    private var section: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--design-section"),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    var body: some View {
        Group {
            if isReady {
                if let route = RugbyDesignRoute(rawValue: section ?? "") {
                    RugbyDesignRoutePreview(route: route)
                } else {
                    RootTabView(initialSection: section)
                }
            } else {
                ProgressView("プレビューを準備中")
            }
        }
        .task {
            guard !isReady else { return }
            // A preview launch must never insert sample data into a saved store.
            guard context.container.configurations.allSatisfy({ $0.isStoredInMemoryOnly }) else { return }
            if !ProcessInfo.processInfo.arguments.contains("--design-empty") {
                RugbyDesignFixture.insert(into: context)
                if section == "team-performance" { insertTeamPerformanceSeasons() }
                guard AppPersistence.save(context) else { return }
            }
            isReady = true
        }
    }

    private func insertTeamPerformanceSeasons() {
        guard let teams = try? context.fetch(FetchDescriptor<Team>()),
              let home = teams.first(where: { $0.name == "青葉大学" }),
              let away = teams.first(where: { $0.name == "海浜大学" }) else { return }
        let year = Calendar.current.component(.year, from: .now) - 1
        let tournament = Tournament(officialName: "大学交流戦", year: year)
        context.insert(tournament)
        var samples = [(month: 9, day: 10, points: 14), (month: 10, day: 10, points: 21)]
        if ProcessInfo.processInfo.arguments.contains("--design-recent-30") {
            samples += (1...30).map { (month: 1, day: $0, points: ($0 % 4 + 1) * 7) }
        }
        for sample in samples {
            let date = Calendar.current.date(from: DateComponents(year: year, month: sample.month, day: sample.day))!
            let match = Match(tournamentID: tournament.id, homeTeamID: home.id, awayTeamID: away.id, playedAt: date)
            context.insert(match)
            for (teamID, tries) in [(home.id, sample.points / 7), (away.id, 2)] {
                for index in 0..<tries {
                    context.insert(StatEvent(matchID: match.id, teamID: teamID, category: "try", outcome: "success", seconds: index * 600))
                    context.insert(StatEvent(matchID: match.id, teamID: teamID, category: "conversion", outcome: "success", seconds: index * 600 + 30))
                }
            }
            context.insert(StatEvent(matchID: match.id, category: "match_state", outcome: "finished", seconds: 2400, half: 1))
        }
        if ProcessInfo.processInfo.arguments.contains("--design-rankings"),
           let players = try? context.fetch(FetchDescriptor<Player>()),
           let matches = try? context.fetch(FetchDescriptor<Match>()),
           let match = matches.first(where: { $0.tournamentID == tournament.id }) {
            let kickers = players.filter { $0.teamID == home.id }.sorted { ($0.number ?? 0) < ($1.number ?? 0) }
            for (index, player) in kickers.prefix(3).enumerated() {
                for attempt in 0..<10 {
                    context.insert(StatEvent(matchID: match.id, teamID: home.id, playerID: player.id,
                                             category: "conversion", outcome: attempt < 9 - index * 2 ? "success" : "fail", seconds: attempt * 120))
                }
            }
        }
    }
}

private enum RugbyDesignRoute: String, Hashable {
    case create, lineup, summary
    case teamPerformance = "team-performance"
}

/// Push the actual screen so its normal back navigation can be reviewed too.
private struct RugbyDesignRoutePreview: View {
    @Query private var teams: [Team]
    @Query(sort: \Match.playedAt, order: .reverse) private var matches: [Match]
    @Query(filter: #Predicate<StatEvent> { $0.category == "match_state" && $0.outcome == "finished" })
    private var finishEvents: [StatEvent]
    let route: RugbyDesignRoute
    @State private var path: [RugbyDesignRoute] = []
    @State private var didOpen = false

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 20) {
                Text("デザインプレビュー")
                    .font(.title2.bold())
                Text("この画面の記録は、アプリを閉じると破棄されます。")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("プレビューを開く") { path.append(route) }
                    .buttonStyle(RugbyPrimaryButtonStyle())
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RugbyTheme.background)
            .navigationTitle("プレビュー")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: RugbyDesignRoute.self) { destination in
                destinationView(destination)
            }
            .task {
                guard !didOpen else { return }
                didOpen = true
                path.append(route)
            }
        }
        .tint(RugbyTheme.accent)
    }

    @ViewBuilder private func destinationView(_ destination: RugbyDesignRoute) -> some View {
        let finishedIDs = Set(finishEvents.map(\.matchID))
        switch destination {
        case .teamPerformance:
            if let team = teams.first(where: { $0.name == "青葉大学" }) {
                TeamPerformanceView(team: team)
            } else {
                ContentUnavailableView("プレビューのチームがありません", systemImage: "shield")
            }
        case .create:
            CreateMatchView()
        case .lineup:
            if let match = matches.first(where: { !finishedIDs.contains($0.id) }) {
                LineupRegistrationView(match: match)
            } else {
                ContentUnavailableView("記録中のプレビュー試合がありません", systemImage: "sportscourt")
            }
        case .summary:
            if let match = matches.first(where: { finishedIDs.contains($0.id) }) {
                MatchSummaryView(match: match)
            } else {
                ContentUnavailableView("終了したプレビュー試合がありません", systemImage: "sportscourt")
            }
        }
    }
}

private enum RugbyDesignFixture {
    static func insert(into context: ModelContext) {
        let teams = [
            // どの試合にも出る青葉大学を青、相手をオレンジ・赤・黄緑にして、対戦の色が見分けやすいようにする
            Team(name: "青葉大学", colorHex: "#1E88E5", category: "大学"),
            Team(name: "東都学院大学", colorHex: "#E8483C", category: "大学"),
            Team(name: "海浜大学", colorHex: "#F08A1C", category: "大学"),
            Team(name: "北星ラグビークラブ", colorHex: "#8CC63F", category: "クラブ")
        ]
        teams.forEach { context.insert($0) }

        let calendar = Calendar.current
        let now = Date.now
        let month = calendar.dateInterval(of: .month, for: now)?.start ?? now
        let previousMonth = calendar.date(byAdding: .month, value: -1, to: month) ?? month
        let year = calendar.component(.year, from: now)
        let tournament = Tournament(officialName: "秋季チャレンジリーグ", year: year,
            variantRaw: RugbyVariant.fifteens.rawValue, formatRaw: TournamentFormat.league.rawValue,
            teamIDs: teams.map(\.id))
        context.insert(tournament)

        let surnames = ["佐藤", "高橋", "森", "中村", "小林", "山本", "伊藤", "松田", "石川", "渡辺", "鈴木", "清水", "木村", "井上", "藤田"]
        let givenNames = [
            ["悠真", "大地", "健太", "陽介", "颯太", "拓海", "陸", "航平", "直樹", "蓮", "翔太", "亮太", "優斗", "海斗", "智也"],
            ["駿", "湊", "和樹", "瑛太", "一輝", "晴人", "匠", "健太郎", "怜", "歩", "大和", "祐介", "涼", "圭太", "光"],
            ["蒼", "太一", "樹", "雄大", "悠人", "健", "快", "陽太", "颯", "拓也", "大輔", "直人", "誠", "翔", "新"],
            ["浩平", "健吾", "俊介", "将太", "康太", "雅人", "雄太", "達也", "哲平", "祐太", "和也", "隆太", "淳", "亮", "慧"]
        ]
        let positions = ["PR", "HO", "PR", "LO", "LO", "FL", "FL", "NO.8", "SH", "SO", "WTB", "CTB", "CTB", "WTB", "FB"]
        var rosters: [UUID: [Player]] = [:]
        for (teamIndex, team) in teams.enumerated() {
            let players = positions.indices.map { index in
                Player(teamID: team.id, number: index + 1,
                    name: surnames[(index + teamIndex * 3) % surnames.count] + " " + givenNames[teamIndex][index],
                    position: positions[index], isFavorite: teamIndex == 0 && [6, 9, 13].contains(index))
            }
            players.forEach { context.insert($0) }
            rosters[team.id] = players
        }

        func date(in month: Date, day: Int) -> Date {
            let dayDate = calendar.date(byAdding: .day, value: day - 1, to: month) ?? month
            return calendar.date(bySettingHour: 14, minute: 0, second: 0, of: dayDate) ?? dayDate
        }

        // Latest is a partial recording; all other matches carry the real finish marker.
        let fixtures: [(home: Int, away: Int, date: Date, homeTries: Int, homeConversions: Int, homePenalties: Int,
                        awayTries: Int, awayConversions: Int, awayPenalties: Int, finished: Bool)] = [
            (0, 1, date(in: month, day: 24), 3, 2, 0, 1, 1, 0, false),
            (0, 2, date(in: month, day: 20), 4, 4, 0, 3, 3, 0, true),
            (1, 0, date(in: month, day: 12), 3, 3, 1, 3, 1, 0, true),
            (0, 3, date(in: previousMonth, day: 24), 3, 2, 0, 3, 0, 0, true),
            (2, 0, date(in: previousMonth, day: 17), 5, 3, 0, 4, 3, 0, true)
        ]

        for (matchIndex, fixture) in fixtures.enumerated() {
            let home = teams[fixture.home]
            let away = teams[fixture.away]
            let match = Match(tournamentID: tournament.id, homeTeamID: home.id,
                awayTeamID: away.id, playedAt: fixture.date)
            context.insert(match)
            if !fixture.finished {
                match.recordingSessionData = try? JSONEncoder().encode(
                    RecordingSession(clock: RecordingClock(accumulated: 1_722)))
            }

            for (side, team) in [home, away].enumerated() {
                let players = rosters[team.id] ?? []
                for (index, player) in players.enumerated() {
                    context.insert(MatchLineup(matchID: match.id, teamID: team.id, playerID: player.id,
                        role: "starter", order: index, number: index + 1))
                }
                let tries = side == 0 ? fixture.homeTries : fixture.awayTries
                let conversions = side == 0 ? fixture.homeConversions : fixture.awayConversions
                let penalties = side == 0 ? fixture.homePenalties : fixture.awayPenalties
                for index in 0..<tries {
                    let half = fixture.finished ? index % 2 : 0
                    let seconds = 420 + index / 2 * 660 + side * 180
                    context.insert(StatEvent(matchID: match.id, teamID: team.id,
                        playerID: players[(10 + index * 2) % players.count].id,
                        category: "try", outcome: "success", seconds: seconds, half: half))
                    // 決まらなかった分は「失敗」として残す(成功率が100%にならないように)
                    context.insert(StatEvent(matchID: match.id, teamID: team.id, playerID: players[9].id,
                        category: "conversion", outcome: index < conversions ? "success" : "fail",
                        seconds: seconds + 65, half: half))
                }
                for index in 0..<penalties {
                    context.insert(StatEvent(matchID: match.id, teamID: team.id, playerID: players[9].id,
                        category: "penalty_goal", outcome: "success", seconds: 1_340 + index * 240, half: 1))
                }
                let tackleCount = fixture.finished ? 42 + matchIndex * 4 + side * 7 : 24 + side * 5
                for index in 0..<tackleCount {
                    context.insert(StatEvent(matchID: match.id, teamID: team.id,
                        playerID: players[(index * 7 + matchIndex) % players.count].id,
                        category: "tackle", outcome: (index + matchIndex + side) % 9 == 0 ? "fail" : "success",
                        seconds: 70 + index * 41 % (fixture.finished ? 2_200 : 1_600),
                        half: fixture.finished ? index % 2 : 0))
                }
                for index in 0..<(fixture.finished ? 8 : 3) {
                    context.insert(StatEvent(matchID: match.id, teamID: team.id, playerID: players[3].id,
                        category: "lineout", outcome: index == 3 && side == 1 ? "fail" : "success",
                        seconds: 120 + index * 260, half: fixture.finished ? index % 2 : 0))
                }
            }
            if fixture.finished {
                context.insert(StatEvent(matchID: match.id, category: "match_state",
                    outcome: "finished", seconds: 2_400, half: 1))
            }
        }
    }
}
#endif
