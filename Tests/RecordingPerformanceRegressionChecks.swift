import Combine
import Foundation
import SwiftData

@MainActor
enum RecordingPerformanceRegressionChecks {
    static func run() throws {
        try indexedCardsPreserveMixedRecords()
        try editsAndUndoInvalidateSummaries()
        try unchangedRefreshDoesNotRedrawTheBoard()
        try extendedDeadlinesKeepExactDurations()
        try playerPickerUsesMatchNumbersAndKeepsAdditionalSelection()
        try largeRosterResolvesNumbersOnce()
        try draftTapLatencyWithLongMatch()
        print("PASS: 7 recording performance regression checks")
    }

    private static func playerPickerUsesMatchNumbersAndKeepsAdditionalSelection() throws {
        let teamID = UUID(), matchID = UUID()
        let base = Player(teamID: teamID, number: 9, name: "基本番号")
        let matchOnly = Player(teamID: teamID, number: nil, name: "試合番号のみ")
        let fallback = Player(teamID: teamID, number: 4, name: "基本番号へ戻る")
        let additional = Player(teamID: teamID, number: nil, name: "番号なし")
        let opponent = Player(teamID: UUID(), number: 1, name: "相手")
        let roster = RecordingPlayerRoster(players: [additional, base, fallback, opponent, matchOnly], teamID: teamID, matchID: matchID, lineups: [
            MatchLineup(matchID: UUID(), teamID: teamID, playerID: additional.id, role: "starter", order: 0, number: 1),
            MatchLineup(matchID: matchID, teamID: teamID, playerID: base.id, role: "starter", order: 0, number: 3),
            MatchLineup(matchID: matchID, teamID: teamID, playerID: matchOnly.id, role: "reserve", order: 1, number: 2),
            MatchLineup(matchID: matchID, teamID: teamID, playerID: fallback.id, role: "reserve", order: 2)
        ])
        try RecordingRegressionChecks.expect(roster.visiblePlayers(includeOthers: false).map(\.id) == [matchOnly.id, base.id, fallback.id],
            "Default picker shows match-numbered players and base-number fallback in number order, never another team or match")
        try RecordingRegressionChecks.expect(roster.visiblePlayers(includeOthers: true).map(\.id) == [matchOnly.id, base.id, fallback.id, additional.id],
            "Additional players remain available exactly once on expansion")
        try RecordingRegressionChecks.expect(roster.visiblePlayers(includeOthers: false, selectedPlayerID: additional.id).last?.id == additional.id,
            "Selected unnumbered player remains visible when extra players are collapsed")
        try RecordingRegressionChecks.expect(roster.visiblePlayers(includeOthers: false, selectedPlayerID: opponent.id).count == 3,
            "Pinned selection cannot introduce an opposing player")
        let unnumbered = RecordingPlayerRoster(players: [additional], numberFor: { $0.number })
        try RecordingRegressionChecks.expect(unnumbered.numbered.isEmpty && unnumbered.visiblePlayers(includeOthers: true).count == 1,
            "A team with no numbers can still expand and select its players")
    }

    private static func largeRosterResolvesNumbersOnce() throws {
        let teamID = UUID()
        let players = (0..<2000).map { Player(teamID: teamID, number: $0 < 23 ? 23 - $0 : nil, name: "選手\($0)") }
        var numberReads = 0
        let roster = RecordingPlayerRoster(players: players) { player in
            numberReads += 1
            return player.number
        }
        try RecordingRegressionChecks.expect(numberReads == players.count && roster.numbered.count == 23 && roster.others.count == 1977,
            "Large team resolves each number once and initially exposes only registered numbers")
        for _ in 0..<100 {
            let visible = roster.visiblePlayers(includeOthers: false)
            for player in visible { _ = roster.number(for: player) }
        }
        try RecordingRegressionChecks.expect(numberReads == players.count,
            "Repeated selection redraws do not rescan or sort the whole roster")
        try RecordingRegressionChecks.expect(roster.numbered.compactMap { roster.number(for: $0) } == Array(1...23),
            "Default picker retains all registered numbers in ascending order")
    }

    private static func draftTapLatencyWithLongMatch() throws {
        let (container, match) = try RecordingRegressionChecks.fixture()
        let context = container.mainContext
        let a = Player(teamID: match.homeTeamID, number: 1, name: "A")
        let b = Player(teamID: match.homeTeamID, number: 2, name: "B")
        context.insert(a); context.insert(b)
        for index in 0..<3000 {
            context.insert(StatEvent(matchID: match.id, teamID: index % 2 == 0 ? match.homeTeamID : match.awayTeamID,
                category: "tackle", outcome: "success", seconds: index / 2))
        }
        try context.save()
        let store = RecordingWidgetStore(match: match, context: context)
        let widget = store.layout.widgets.first { $0.category == "try" }!
        _ = store.beginTry(widget)
        let id = store.session.scoringFlow!.id
        let playerStart = Date()
        for i in 0..<30 { _ = store.setScoringPlayer(i % 2 == 0 ? a.id : b.id, flowID: id) }
        let playerDuration = Date().timeIntervalSince(playerStart)
        let originStart = Date()
        for i in 0..<30 { store.setTryOrigin(i % 2 == 0 ? "scrum" : "lineout", flowID: id) }
        let originDuration = Date().timeIntervalSince(originStart)
        try RecordingRegressionChecks.expect(store.confirmTry(flowID: id), "Long match still confirms selected scorer and origin")
        let kickStart = Date()
        for i in 0..<30 { _ = store.recordConversionTime(flowID: id, at: Date().addingTimeInterval(Double(i))) }
        let kickDuration = Date().timeIntervalSince(kickStart)
        print(String(format: "TAP benchmark, 3000 events, mean ms: player %.2f, origin %.2f, kick %.2f",
            playerDuration / 30 * 1000, originDuration / 30 * 1000, kickDuration / 30 * 1000))
        let home = store.layout.widgets.first { $0.kind == .possession && $0.timerTarget == .home }!
        let away = store.layout.widgets.first { $0.kind == .possession && $0.timerTarget == .away }!
        let bip = store.layout.widgets.first { $0.kind == .possession && $0.timerTarget == .bip }!
        let baseline = Date()
        let possessionStart = Date()
        for i in 0..<30 { store.activate(i % 2 == 0 ? home : away, at: baseline.addingTimeInterval(Double(i))) }
        let possessionDuration = Date().timeIntervalSince(possessionStart)
        let bipStart = Date()
        for i in 30..<60 { store.activate(bip, at: baseline.addingTimeInterval(Double(i))) }
        let bipDuration = Date().timeIntervalSince(bipStart)
        let clockStart = Date()
        for i in 60..<90 { store.toggleClock(at: baseline.addingTimeInterval(Double(i))) }
        let clockDuration = Date().timeIntervalSince(clockStart)
        let scoreStart = Date()
        for _ in 0..<30 { store.activate(widget) }
        let scoreDuration = Date().timeIntervalSince(scoreStart)
        print(String(format: "BOARD benchmark, 3000 events, mean ms: possession %.2f, BIP %.2f, clock %.2f, score %.2f",
            possessionDuration / 30 * 1000, bipDuration / 30 * 1000, clockDuration / 30 * 1000, scoreDuration / 30 * 1000))
        let resumed = RecordingWidgetStore(match: match, context: context)
        try RecordingRegressionChecks.expect(resumed.session.scoringFlow?.scorerID == b.id && resumed.session.scoringFlow?.origin == "lineout"
            && resumed.session.scoringFlow?.kickSeconds != nil, "Rapid draft changes remain durable across reopening")
    }

    private static func indexedCardsPreserveMixedRecords() throws {
        let (container, match) = try RecordingRegressionChecks.fixture()
        let playerID = UUID()
        for index in 0..<600 {
            let category = ["try", "tackle", "carry_metres", "possession", "match_state"][index % 5]
            let event = StatEvent(matchID: match.id,
                teamID: index % 3 == 0 ? match.awayTeamID : match.homeTeamID,
                playerID: playerID, category: category, outcome: index % 4 == 0 ? "fail" : "success",
                seconds: index, half: index > 300 ? 1 : 0)
            if category == "carry_metres" {
                var details = RecordingEventDetails()
                details.number = Double(index % 12) - 4; details.unit = "m"
                event.recordingDetails = details
            }
            container.mainContext.insert(event)
        }
        try container.mainContext.save()
        let store = RecordingWidgetStore(match: match, context: container.mainContext)
        for teamID in [match.homeTeamID, match.awayTeamID] {
            store.selectTeam(teamID)
            for category in ["try", "tackle", "carry_metres", "not_recorded"] {
                var widget = RecordingWidgetDefinition.make(.count)
                widget.category = category
                let expected = store.events.filter { $0.teamID == teamID && $0.category == category }
                try RecordingRegressionChecks.expect(Set(store.matchingEvents(widget).map(\.id)) == Set(expected.map(\.id)),
                    "A cached card must retain its category and selected-team boundaries")
                let count = expected.filter { category != "try" || $0.outcome == "success" }.count
                try RecordingRegressionChecks.expect(store.count(widget) == count, "Score counts exclude unsuccessful attempts")
                try RecordingRegressionChecks.expect(store.summary(widget) == RecordingMetricAggregation.summary(events: expected, category: category),
                    "Cached numeric and success-rate calculations match the event data")
            }
            let score = store.events.filter { $0.teamID == teamID }.reduce(0) {
                $0 + RecordingFormatting.score(category: $1.category, outcome: $1.outcome)
            }
            try RecordingRegressionChecks.expect(store.score(teamID: teamID) == score && store.scoringLeader(teamID: teamID)?.points == score,
                "The score and scoring leader retain their team scope")
            let recent = store.events.filter { $0.teamID == teamID && $0.category != "possession" && $0.category != "match_state" }
                .sorted { $1.isRecordedBefore($0) }
            try RecordingRegressionChecks.expect(store.recentEvents.map(\.id) == recent.map(\.id) && store.latestEvent?.id == recent.first?.id,
                "Cached latest/recent cards preserve chronological order")
        }
    }

    private static func editsAndUndoInvalidateSummaries() throws {
        let (container, match) = try RecordingRegressionChecks.fixture()
        let store = RecordingWidgetStore(match: match, context: container.mainContext)
        var widget = RecordingWidgetDefinition.make(.number)
        widget.category = "carry_metres"; widget.unit = "m"; widget.attachesToLatest = false
        try RecordingRegressionChecks.expect(store.submitInput(widget, number: -2), "The initial input saves")
        try RecordingRegressionChecks.expect(store.summary(widget).average == -2, "The first summary is populated")
        let event = store.matchingEvents(widget)[0]
        var details = event.recordingDetails
        details.number = 7
        try RecordingRegressionChecks.expect(store.updateEvent(event, playerID: nil, details: details), "The edit saves")
        try RecordingRegressionChecks.expect(store.summary(widget).average == 7, "A saved edit replaces the cached summary")
        store.undo()
        try RecordingRegressionChecks.expect(store.summary(widget).average == -2, "Undo replaces the cached summary")
        var external = event.recordingDetails
        external.number = 9
        event.recordingDetails = external
        try container.mainContext.save()
        store.refresh()
        try RecordingRegressionChecks.expect(store.summary(widget).average == 9 && !store.canUndo,
            "An external edit refreshes the cache and invalidates stale undo")
    }

    private static func unchangedRefreshDoesNotRedrawTheBoard() throws {
        let (container, match) = try RecordingRegressionChecks.fixture()
        let store = RecordingWidgetStore(match: match, context: container.mainContext)
        let tryWidget = store.layout.widgets.first { $0.category == "try" }!
        _ = store.activate(tryWidget)
        var changes = 0
        let observation = store.objectWillChange.sink { changes += 1 }
        store.refresh()
        store.selectTeam(store.selectedTeamID)
        _ = store.pause()
        for _ in 0..<100 {
            _ = store.count(tryWidget)
            _ = store.summary(tryWidget)
            _ = store.latestEvent
        }
        try RecordingRegressionChecks.expect(changes == 0 && store.canUndo,
            "Reading cards, an unchanged refresh, and already-stopped controls must not publish redundant board updates")
        withExtendedLifetime(observation) {}
    }

    private static func extendedDeadlinesKeepExactDurations() throws {
        let (container, match) = try RecordingRegressionChecks.fixture()
        let store = RecordingWidgetStore(match: match, context: container.mainContext)
        var widget = RecordingWidgetDefinition.make(.timed)
        widget.lagTime = 2
        try RecordingRegressionChecks.expect(store.saveLayout(RecordingLayout(widgets: [widget])), "Timed layout saves")
        let start = Date()
        _ = store.activate(widget, at: start)
        try RecordingRegressionChecks.expect(store.nextIntervalExpiration == start.addingTimeInterval(2), "The next deadline comes from the active clip")
        _ = store.activate(widget, at: start.addingTimeInterval(0.75))
        try RecordingRegressionChecks.expect(store.nextIntervalExpiration == start.addingTimeInterval(2.75), "Extending a clip replaces the pending deadline")
        store.reconcile(at: start.addingTimeInterval(2.5))
        try RecordingRegressionChecks.expect(store.activeInterval(widget) != nil, "An old deadline cannot end an extended clip")
        store.reconcile(at: start.addingTimeInterval(3.4))
        try RecordingRegressionChecks.expect(store.nextIntervalExpiration == nil && store.activeInterval(widget) == nil,
            "Finishing the last timed clip removes the need for a deadline task")
        try RecordingRegressionChecks.expect(abs((store.matchingEvents(widget).first?.recordingDetails.intervalDuration ?? 0) - 2.75) < 0.00001,
            "A delayed wake-up saves the exact deadline, not the wake-up time")
    }
}
