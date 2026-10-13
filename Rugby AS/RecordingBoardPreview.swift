#if DEBUG
import SwiftUI
import SwiftData

/// Isolated launch fixture for Simulator UI verification; never uses saved matches.
struct RecordingBoardPreview: View {
    @Environment(\.modelContext) private var context
    @State private var match: Match?
    var body: some View {
        Group {
            if let match {
                if ProcessInfo.processInfo.arguments.contains("--analysis-workspace-preview") {
                    NavigationStack { AnalysisWorkspaceView() }
                } else if ProcessInfo.processInfo.arguments.contains("--settings-preview") {
                    NavigationStack { SettingsView() }
                } else if ProcessInfo.processInfo.arguments.contains("--metrics-video-preview") {
                    TimelineEditorView(match: match)
                } else {
                    WidgetRecordingView(match: match, context: context, initialSeconds: 0, initialHalf: 0, onClose: { _, _, _ in })
                }
            } else { ProgressView() }
        }.task {
            guard match == nil else { return }
            let home = Team(name: "ホームチーム")
            let away = Team(name: "アウェイチーム")
            let tournament = Tournament(officialName: "ボード動作確認")
            let value = Match(tournamentID: tournament.id, homeTeamID: home.id, awayTeamID: away.id, playedAt: .now)
            context.insert(home); context.insert(away); context.insert(tournament); context.insert(value)
            value.recordingSessionData = try? JSONEncoder().encode(RecordingSession(clock: RecordingClock(accumulated: 56)))
            if ProcessInfo.processInfo.arguments.contains("--recording-controls-preview") {
                var homeBadge = RecordingWidgetDefinition.make(.teamBadge)
                homeBadge.scope = .home
                var awayBadge = RecordingWidgetDefinition.make(.teamBadge)
                awayBadge.scope = .away; awayBadge.title = "AWAY"; awayBadge.color = .red
                var scoreboard = RecordingWidgetDefinition.make(.scoreboard)
                scoreboard.size = .compact
                var layout = RecordingLayout.legacyRecordingTemplate
                layout.name = "試合操作も自由に配置"
                layout.widgets.insert(contentsOf: [homeBadge, awayBadge, scoreboard, .make(.matchClock)], at: 0)
                value.recordingLayoutData = try? JSONEncoder().encode(layout)
            }
            for (category, seconds) in [("try", 10), ("try", 30), ("conversion", 40)] {
                context.insert(StatEvent(matchID: value.id, teamID: home.id, category: category, outcome: "success", seconds: seconds))
            }
            if ProcessInfo.processInfo.arguments.contains("--inline-input-preview") {
                var number = RecordingWidgetDefinition.make(.number)
                number.size = .large; number.inlineInput = true
                var choice = RecordingWidgetDefinition.make(.choice); choice.inlineInput = true
                var zone = RecordingWidgetDefinition.make(.zone); zone.inlineInput = true
                value.recordingLayoutData = try? JSONEncoder().encode(RecordingLayout(name: "直接入力", widgets: [number, choice, zone]))
            }
            for team in [home, away] {
                context.insert(Player(teamID: team.id, number: 1, name: "選手A"))
                context.insert(Player(teamID: team.id, number: 2, name: "選手B"))
            }
            if ProcessInfo.processInfo.arguments.contains("--metrics-video-preview") {
                for (category, seconds) in [("tackle", 12), ("ruck_speed", 23), ("custom_attack", 40)] {
                    let event = StatEvent(matchID: value.id, teamID: home.id, category: category, outcome: "success", seconds: seconds)
                    var details = RecordingEventDetails()
                    details.title = category == "custom_attack" ? "独自の攻撃" : nil
                    event.recordingDetails = details
                    context.insert(event)
                }
            }
            try? context.save()
            match = value
        }
    }
}
#endif
