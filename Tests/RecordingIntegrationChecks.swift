import Foundation
import SwiftData

@MainActor
enum RecordingIntegrationChecks {
    static func run() throws {
        try preservesSubsecondPossession()
        try resumesFromExactIntervalEnd()
        try refreshKeepsUndoUntilAnExternalChange()
        try savesMovableMatchControls()
        try preservesTheFirstHalfEnd()
        print("PASS: 5 recording integration checks")
    }

    private static func preservesSubsecondPossession() throws {
        let (container, match) = try RecordingRegressionChecks.fixture()
        let store = RecordingWidgetStore(match: match, context: container.mainContext)
        let home = store.layout.widgets.first { $0.kind == .possession && $0.timerTarget == .home }!
        let away = store.layout.widgets.first { $0.kind == .possession && $0.timerTarget == .away }!
        let start = Date()
        store.activate(home, at: start)
        store.activate(away, at: start.addingTimeInterval(0.4))
        try RecordingRegressionChecks.expect(abs(store.timerTotal(.bip, at: start.addingTimeInterval(0.8)) - 0.8) < 0.00001,
            "A running BIP interval must not count a completed team interval twice")
        try RecordingRegressionChecks.expect(store.pause(at: start.addingTimeInterval(1.1)), "Fractional intervals save")
        let reopened = RecordingWidgetStore(match: match, context: container.mainContext)
        for (target, expected) in [(RecordingTimerTarget.home, 0.4), (.away, 0.7), (.bip, 1.1)] {
            try RecordingRegressionChecks.expect(abs(reopened.timerTotal(target, at: start) - expected) < 0.00001,
                "Short possession changes must accumulate rather than round down to zero")
        }
        try RecordingRegressionChecks.expect(reopened.events.filter { $0.category == "possession" }.count == 3,
            "Both short team intervals and their BIP interval survive reopening")
    }

    private static func resumesFromExactIntervalEnd() throws {
        let (container, match) = try RecordingRegressionChecks.fixture()
        container.mainContext.insert(StatEvent(matchID: match.id, category: "possession", outcome: "own",
            seconds: 0, startSeconds: 12, half: 1, startSecondsExact: 12.35, durationSecondsExact: 0.45))
        try container.mainContext.save()
        let store = RecordingWidgetStore(match: match, context: container.mainContext)
        try RecordingRegressionChecks.expect(abs(store.session.clock.accumulated - 12.8) < 0.00001,
            "A legacy session resumes after the exact saved interval end")
    }

    private static func refreshKeepsUndoUntilAnExternalChange() throws {
        let (container, match) = try RecordingRegressionChecks.fixture()
        let store = RecordingWidgetStore(match: match, context: container.mainContext)
        let scoring = store.layout.widgets.first { $0.category == "try" }!
        let event = store.activate(scoring)!
        store.refresh()
        try RecordingRegressionChecks.expect(store.canUndo, "Read-only review preserves undo")
        var details = event.recordingDetails
        details.note = "映像で確認済み"
        event.recordingDetails = details
        try container.mainContext.save()
        store.refresh()
        try RecordingRegressionChecks.expect(!store.canUndo, "External edits invalidate a stale whole-match snapshot")
        store.undo()
        try RecordingRegressionChecks.expect(store.events.count == 1 && store.events[0].recordingDetails.note == details.note,
            "Undo after returning from another editor must not erase its changes")
    }

    private static func savesMovableMatchControls() throws {
        let (container, match) = try RecordingRegressionChecks.fixture()
        let store = RecordingWidgetStore(match: match, context: container.mainContext)
        var home = RecordingWidgetDefinition.make(.teamBadge)
        home.scope = .home
        var away = home
        away.id = UUID(); away.scope = .away; away.title = "AWAY"
        let widgets = [home, away, RecordingWidgetDefinition.make(.matchClock), .make(.scoreboard)]
        try RecordingRegressionChecks.expect(store.saveLayout(RecordingLayout(name: "試合操作", widgets: widgets)),
            "A board may contain movable teams, clock and score")
        let reopened = RecordingWidgetStore(match: match, context: container.mainContext)
        try RecordingRegressionChecks.expect(reopened.layout.widgets == widgets, "Match control configuration survives reopening")
        reopened.selectTeam(reopened.teamID(for: away))
        try RecordingRegressionChecks.expect(reopened.selectedTeamID == match.awayTeamID && reopened.events.isEmpty,
            "Switching teams must never create a scoring event")
    }

    private static func preservesTheFirstHalfEnd() throws {
        let (container, match) = try RecordingRegressionChecks.fixture()
        match.recordingSessionData = try JSONEncoder().encode(RecordingSession(clock: RecordingClock(accumulated: 2400)))
        container.mainContext.insert(StatEvent(matchID: match.id, category: "try", outcome: "success", seconds: 600))
        try container.mainContext.save()
        let store = RecordingWidgetStore(match: match, context: container.mainContext)
        store.nextHalf()
        try RecordingRegressionChecks.expect(MatchStatistics.halfEndSeconds(events: store.events, half: 0) == 2400,
            "The first-half length must survive even when its last recorded play was much earlier")
        store.nextHalf()
        try RecordingRegressionChecks.expect(store.events.filter { $0.category == "match_state" }.count == 1,
            "Repeated half change cannot reset the clock or duplicate the marker")
        store.undo()
        try RecordingRegressionChecks.expect(store.session.clock.half == 0 && store.session.clock.accumulated == 2400
            && store.events.count == 1, "Undo restores the first half and removes its end marker")
    }
}
