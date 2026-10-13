#if DEBUG
import SwiftData
import SwiftUI

// iPad対応を進めるときに、縦・横・狭いウインドウを同じデータで確認するためのPreview専用データ。
// 各Previewで独立したインメモリ保存領域を作るので、実際の試合データには一切影響しない。
@MainActor
private struct IPadPreviewFixture {
    let container: ModelContainer
    let homeTeam: Team
    let activeMatch: Match
    let finishedMatch: Match

    static func make() -> IPadPreviewFixture {
        let schema = Schema([
            Team.self,
            Player.self,
            Tournament.self,
            Match.self,
            StatEvent.self,
            MatchLineup.self,
            Substitution.self
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try! ModelContainer(
            for: schema,
            configurations: [configuration]
        )
        let context = container.mainContext

        let homeTeam = Team(
            name: "青山大学RFC",
            colorHex: "#168AF2",
            category: "大学"
        )
        let awayTeam = Team(
            name: "赤坂クラブ",
            colorHex: "#E5484D",
            category: "クラブ"
        )
        let tournament = Tournament(
            officialName: "全国大学ラグビー選手権",
            year: 2026,
            teamIDs: [homeTeam.id, awayTeam.id]
        )
        let activeMatch = Match(
            tournamentID: tournament.id,
            homeTeamID: homeTeam.id,
            awayTeamID: awayTeam.id,
            playedAt: .now
        )
        let finishedMatch = Match(
            tournamentID: tournament.id,
            homeTeamID: homeTeam.id,
            awayTeamID: awayTeam.id,
            playedAt: Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
        )

        context.insert(homeTeam)
        context.insert(awayTeam)
        context.insert(tournament)
        context.insert(activeMatch)
        context.insert(finishedMatch)

        let homePlayers = makePlayers(
            teamID: homeTeam.id,
            familyName: "青山"
        )
        let awayPlayers = makePlayers(
            teamID: awayTeam.id,
            familyName: "赤坂"
        )

        for player in homePlayers + awayPlayers {
            context.insert(player)
        }

        for match in [activeMatch, finishedMatch] {
            insertLineup(
                match: match,
                team: homeTeam,
                players: homePlayers,
                context: context
            )
            insertLineup(
                match: match,
                team: awayTeam,
                players: awayPlayers,
                context: context
            )
        }

        insertSampleEvents(
            match: activeMatch,
            homeTeam: homeTeam,
            awayTeam: awayTeam,
            homePlayers: homePlayers,
            awayPlayers: awayPlayers,
            isFinished: false,
            context: context
        )
        insertSampleEvents(
            match: finishedMatch,
            homeTeam: homeTeam,
            awayTeam: awayTeam,
            homePlayers: homePlayers,
            awayPlayers: awayPlayers,
            isFinished: true,
            context: context
        )

        try! context.save()

        return IPadPreviewFixture(
            container: container,
            homeTeam: homeTeam,
            activeMatch: activeMatch,
            finishedMatch: finishedMatch
        )
    }

    private static func makePlayers(teamID: UUID, familyName: String) -> [Player] {
        (1...15).map { number in
            Player(
                teamID: teamID,
                number: number,
                name: "\(familyName) 選手\(number)",
                nameKana: "せんしゅ\(number)",
                nameRoman: "PLAYER \(number)",
                position: number <= 8
                    ? RugbyPosition.forward.rawValue
                    : RugbyPosition.back.rawValue,
                isFavorite: number == 9 || number == 10,
                heightCm: number <= 8 ? 184 : 176,
                weightKg: number <= 8 ? 102 : 82
            )
        }
    }

    private static func insertLineup(
        match: Match,
        team: Team,
        players: [Player],
        context: ModelContext
    ) {
        for (order, player) in players.enumerated() {
            context.insert(
                MatchLineup(
                    matchID: match.id,
                    teamID: team.id,
                    playerID: player.id,
                    role: "starter",
                    order: order,
                    number: player.number
                )
            )
        }
    }

    private static func insertSampleEvents(
        match: Match,
        homeTeam: Team,
        awayTeam: Team,
        homePlayers: [Player],
        awayPlayers: [Player],
        isFinished: Bool,
        context: ModelContext
    ) {
        let events = [
            StatEvent(
                matchID: match.id,
                teamID: nil,
                category: "possession",
                outcome: "none",
                seconds: 780,
                startSeconds: 0,
                half: 0
            ),
            StatEvent(
                matchID: match.id,
                teamID: homeTeam.id,
                category: "possession",
                outcome: "own",
                seconds: 410,
                startSeconds: 18,
                half: 0,
                origin: PlayOrigin.scrum.rawValue
            ),
            StatEvent(
                matchID: match.id,
                teamID: awayTeam.id,
                category: "possession",
                outcome: "opponent",
                seconds: 370,
                startSeconds: 445,
                half: 0,
                origin: PlayOrigin.lineout.rawValue
            ),
            StatEvent(
                matchID: match.id,
                teamID: homeTeam.id,
                playerID: homePlayers[10].id,
                category: "try",
                outcome: "success",
                seconds: 312,
                half: 0,
                origin: PlayOrigin.turnover.rawValue
            ),
            StatEvent(
                matchID: match.id,
                teamID: homeTeam.id,
                playerID: homePlayers[9].id,
                category: "conversion",
                outcome: "success",
                seconds: 338,
                half: 0
            ),
            StatEvent(
                matchID: match.id,
                teamID: awayTeam.id,
                playerID: awayPlayers[7].id,
                category: "penalty_goal",
                outcome: "success",
                seconds: 604,
                half: 0
            ),
            StatEvent(
                matchID: match.id,
                teamID: homeTeam.id,
                category: "lineout",
                outcome: "success",
                seconds: 522,
                half: 0
            ),
            StatEvent(
                matchID: match.id,
                teamID: awayTeam.id,
                category: "scrum",
                outcome: "fail",
                seconds: 690,
                half: 0
            ),
            StatEvent(
                matchID: match.id,
                teamID: homeTeam.id,
                category: "penalty",
                outcome: "conceded",
                seconds: 742,
                half: 0
            )
        ]

        for event in events {
            context.insert(event)
        }

        if isFinished {
            context.insert(
                StatEvent(
                    matchID: match.id,
                    category: "match_state",
                    outcome: "finished",
                    seconds: 2_400,
                    half: 1
                )
            )
        }
    }
}

// Device-specific previews use PreviewProvider: #Preview ignores previewDevice.
private struct IPadMatchListPreview: PreviewProvider {
    static var previews: some View {
        let fixture = IPadPreviewFixture.make()
        return RootTabView()
            .modelContainer(fixture.container)
            .preferredColorScheme(.dark)
            .previewDisplayName("iPad 11・試合一覧・縦")
            .previewDevice("iPad Pro 11-inch (M5)")
            .previewInterfaceOrientation(.portrait)
    }
}

private struct IPadRecordingPreview: PreviewProvider {
    static var previews: some View {
        let fixture = IPadPreviewFixture.make()
        return NavigationStack {
            V3RecordingView(match: fixture.activeMatch)
        }
        .modelContainer(fixture.container)
        .preferredColorScheme(.dark)
        .previewDisplayName("iPad mini・試合記録・横")
        .previewDevice("iPad mini (A17 Pro)")
        .previewInterfaceOrientation(.landscapeLeft)
    }
}

#Preview(
    "iPad・試合記録・狭いウインドウ",
    traits: .fixedLayout(width: 500, height: 700)
) {
    let fixture = IPadPreviewFixture.make()

    NavigationStack {
        V3RecordingView(match: fixture.activeMatch)
    }
    .modelContainer(fixture.container)
    .preferredColorScheme(.dark)
    .environment(\.horizontalSizeClass, .compact)
    .environment(\.verticalSizeClass, .regular)
}

private struct IPadTimelinePreview: PreviewProvider {
    static var previews: some View {
        let fixture = IPadPreviewFixture.make()
        return NavigationStack {
            TimelineEditorView(
                match: fixture.activeMatch,
                viewModel: .empty()
            )
        }
        .modelContainer(fixture.container)
        .preferredColorScheme(.dark)
        .previewDisplayName("iPad 11・タイムライン・横")
        .previewDevice("iPad Pro 11-inch (M5)")
        .previewInterfaceOrientation(.landscapeLeft)
    }
}

#Preview(
    "iPad・タイムライン・短いウインドウ",
    traits: .fixedLayout(width: 900, height: 650)
) {
    let fixture = IPadPreviewFixture.make()

    NavigationStack {
        TimelineEditorView(
            match: fixture.activeMatch,
            viewModel: .empty()
        )
    }
    .modelContainer(fixture.container)
    .preferredColorScheme(.dark)
    .environment(\.horizontalSizeClass, .regular)
    .environment(\.verticalSizeClass, .compact)
}

private struct IPadSummaryPreview: PreviewProvider {
    static var previews: some View {
        let fixture = IPadPreviewFixture.make()
        return NavigationStack {
            MatchSummaryView(match: fixture.finishedMatch)
        }
        .modelContainer(fixture.container)
        .preferredColorScheme(.dark)
        .previewDisplayName("iPad 11・サマリー・横")
        .previewDevice("iPad Pro 11-inch (M5)")
        .previewInterfaceOrientation(.landscapeLeft)
    }
}

private struct IPadRosterPreview: PreviewProvider {
    static var previews: some View {
        let fixture = IPadPreviewFixture.make()
        return NavigationStack {
            TeamEditorView(team: fixture.homeTeam)
        }
        .modelContainer(fixture.container)
        .preferredColorScheme(.dark)
        .previewDisplayName("iPad 11・選手名簿・縦")
        .previewDevice("iPad Pro 11-inch (M5)")
        .previewInterfaceOrientation(.portrait)
    }
}
#endif
