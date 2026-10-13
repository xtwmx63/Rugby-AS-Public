import Foundation
import SwiftData

@MainActor
enum ScoringFlowRegressionChecks {
    static func run() throws {
        try deferredScoringAndCapturedTimes()
        try restoresOnlyAccidentalCancellation()
        try keepsInterveningMeasurement()
        try failedConversionAndUndo()
        try persistenceAndIndependentPlayers()
        try legacyTimerRelationships()
        try penaltyTryReplacesTryAndKick()
        print("PASS: 7 try/conversion flow regression checks")
    }
    private static func deferredScoringAndCapturedTimes() throws {
        let (container, match) = try RecordingRegressionChecks.fixture()
        let store = RecordingWidgetStore(match: match, context: container.mainContext)
        let start = Date()
        let home = store.layout.widgets.first { $0.kind == .possession && $0.timerTarget == .home }!
        let widget = store.layout.widgets.first { $0.category == "try" }!
        store.activate(home, at: start)
        try RecordingRegressionChecks.expect(store.beginTry(widget, at: start.addingTimeInterval(20)), "Try input opens")
        let id = store.session.scoringFlow!.id
        try RecordingRegressionChecks.expect(store.score(teamID: match.homeTeamID) == 0 && store.session.active.isEmpty, "Draft stops BIP and possession without scoring")
        try RecordingRegressionChecks.expect(store.session.clock.elapsed(at: start.addingTimeInterval(30)) == 30, "Match clock continues")
        try RecordingRegressionChecks.expect(store.timerTotal(.home, at: start.addingTimeInterval(30)) == 20 && store.timerTotal(.bip, at: start.addingTimeInterval(30)) == 20, "Possession stops at try tap")
        store.selectTeam(match.awayTeamID)
        try RecordingRegressionChecks.expect(store.confirmTry(flowID: id), "Try confirmation saves")
        try RecordingRegressionChecks.expect(!store.confirmTry(flowID: id), "Repeated confirmation is ignored")
        try RecordingRegressionChecks.expect(store.score(teamID: match.homeTeamID) == 5 && store.score(teamID: match.awayTeamID) == 0, "Try keeps original team")
        try RecordingRegressionChecks.expect(!store.completeConversion(flowID: id, success: true), "Result requires captured kick time")
        try RecordingRegressionChecks.expect(store.recordConversionTime(flowID: id, at: start.addingTimeInterval(48)), "Kick time captured")
        try RecordingRegressionChecks.expect(store.recordConversionTime(flowID: id, at: start.addingTimeInterval(55)), "Repeated capture updates kick time")
        try RecordingRegressionChecks.expect(store.session.scoringFlow?.kickSeconds == 55 && store.session.scoringFlow?.kickRecordedAt == start.addingTimeInterval(55), "Clock and capture date update together")
        try RecordingRegressionChecks.expect(!store.correctConversionTime(flowID: id, clockText: "00:19"), "Kick cannot be corrected to precede try")
        try RecordingRegressionChecks.expect(!store.correctConversionTime(flowID: id, clockText: "00:90"), "Malformed clock is rejected")
        try RecordingRegressionChecks.expect(store.correctConversionTime(flowID: id, clockText: "00:48"), "Explicit time correction succeeds")
        try RecordingRegressionChecks.expect(store.recordConversionTime(flowID: id, at: start.addingTimeInterval(62)), "Capture remains available after manual correction")
        try RecordingRegressionChecks.expect(store.completeConversion(flowID: id, success: true), "Result commits")
        try RecordingRegressionChecks.expect(!store.completeConversion(flowID: id, success: false), "Repeated result cannot duplicate or replace")
        try RecordingRegressionChecks.expect(!store.recordConversionTime(flowID: id, at: start.addingTimeInterval(70)), "Completed result locks captured time")
        let attempt = store.events.first { $0.category == "conversion" }!
        try RecordingRegressionChecks.expect(attempt.seconds == 62 && attempt.recordingDetails.recordedAt == start.addingTimeInterval(62) && attempt.teamID == match.homeTeamID && attempt.recordingDetails.relatedTryID == store.session.scoringFlow?.tryID, "Conversion uses captured time and original try")
        try RecordingRegressionChecks.expect(store.events.first { $0.category == "try" }?.seconds == 20 && store.score(teamID: match.homeTeamID) == 7, "Try time and score are accurate")
    }
    private static func penaltyTryReplacesTryAndKick() throws {
        let (container, match) = try RecordingRegressionChecks.fixture()
        let store = RecordingWidgetStore(match: match, context: container.mainContext)
        let start = Date()
        let widget = store.layout.widgets.first { $0.category == "try" }!
        let expect = RecordingRegressionChecks.expect
        let home = store.layout.widgets.first { $0.kind == .possession && $0.timerTarget == .home }!
        store.activate(home, at: start)
        // 入力中のトライをそのまま認定トライに
        _ = store.beginTry(widget, at: start.addingTimeInterval(30))
        store.setTryOrigin(PlayOrigin.scrum.rawValue, flowID: store.session.scoringFlow!.id)
        let draftID = store.session.scoringFlow!.id
        try expect(store.recordPenaltyTry(flowID: draftID), "Draft try becomes a penalty try")
        try expect(!store.recordPenaltyTry(flowID: draftID), "Repeated penalty try is ignored")
        try expect(store.score(teamID: match.homeTeamID) == 7 && store.session.scoringFlow?.isComplete == true, "Penalty try scores 7 and ends the input")
        let penalty = store.events.filter { $0.category == ScoringRules.penaltyTryCategory }
        try expect(penalty.count == 1 && penalty[0].playerID == nil && penalty[0].seconds == 30 && penalty[0].origin == PlayOrigin.scrum.rawValue
            && !store.events.contains { $0.category == "try" || $0.category == "conversion" }, "Only one playerless penalty try keeps the try time and origin")
        try expect(!store.cancelTry(flowID: draftID, accidental: false), "Completed penalty try cannot be cancelled as a draft")
        // 確定・キック成功のあとで認定トライに訂正(合計は7点のまま)
        try expect(store.beginTry(widget, at: start.addingTimeInterval(100)), "Next try opens after penalty try")
        let id = store.session.scoringFlow!.id
        _ = store.confirmTry(flowID: id)
        _ = store.recordConversionTime(flowID: id, at: start.addingTimeInterval(130))
        _ = store.completeConversion(flowID: id, success: true)
        try expect(store.score(teamID: match.homeTeamID) == 14, "Try and conversion add 7")
        try expect(store.recordPenaltyTry(flowID: id), "Completed try is corrected to a penalty try")
        try expect(store.score(teamID: match.homeTeamID) == 14 && store.events.filter { $0.category == ScoringRules.penaltyTryCategory }.count == 2
            && !store.events.contains { $0.category == "try" || $0.category == "conversion" }, "Correction removes try and kick without changing the total")
        store.undo()
        try expect(store.events.contains { $0.category == "try" } && store.events.contains { $0.category == "conversion" }
            && store.score(teamID: match.homeTeamID) == 14, "Undo restores the original try and kick")
        let tally = try MatchListSummary.load(context: container.mainContext,
            sides: [MatchListSide(id: match.id, home: match.homeTeamID, away: match.awayTeamID)])[match.id]
        try expect(tally?.homeScore == 14, "Match list counts penalty tries as 7 points")
    }
    private static func restoresOnlyAccidentalCancellation() throws {
        let (container, match) = try RecordingRegressionChecks.fixture()
        let store = RecordingWidgetStore(match: match, context: container.mainContext)
        let start = Date()
        let home = store.layout.widgets.first { $0.kind == .possession && $0.timerTarget == .home }!
        let widget = store.layout.widgets.first { $0.category == "try" }!
        store.activate(home, at: start)
        _ = store.beginTry(widget, at: start.addingTimeInterval(10))
        try RecordingRegressionChecks.expect(store.cancelTry(flowID: store.session.scoringFlow!.id, accidental: true), "Accidental cancellation succeeds")
        try RecordingRegressionChecks.expect(store.timerTotal(.home, at: start.addingTimeInterval(20)) == 20 && store.timerTotal(.bip, at: start.addingTimeInterval(20)) == 20 && store.events.isEmpty, "Cancellation restores continuous original intervals without double counting")
        _ = store.beginTry(widget, at: start.addingTimeInterval(25))
        try RecordingRegressionChecks.expect(store.cancelTry(flowID: store.session.scoringFlow!.id, accidental: false), "Ruling cancellation succeeds")
        try RecordingRegressionChecks.expect(store.session.active.isEmpty && store.timerTotal(.bip, at: start.addingTimeInterval(40)) == 25, "Ruling leaves timers stopped")
    }
    private static func keepsInterveningMeasurement() throws {
        let (container, match) = try RecordingRegressionChecks.fixture()
        let store = RecordingWidgetStore(match: match, context: container.mainContext)
        let start = Date()
        let home = store.layout.widgets.first { $0.kind == .possession && $0.timerTarget == .home }!
        let away = store.layout.widgets.first { $0.kind == .possession && $0.timerTarget == .away }!
        let widget = store.layout.widgets.first { $0.category == "try" }!
        store.activate(home, at: start)
        _ = store.beginTry(widget, at: start.addingTimeInterval(10))
        let id = store.session.scoringFlow!.id
        store.activate(away, at: start.addingTimeInterval(15))
        try RecordingRegressionChecks.expect(!store.cancelTry(flowID: id, accidental: true), "Stale intervals cannot replace subsequent measurement")
        try RecordingRegressionChecks.expect(store.session.active.contains { $0.id == "away" } && store.timerTotal(.home, at: start.addingTimeInterval(20)) == 10, "Subsequent possession remains intact")
    }
    private static func failedConversionAndUndo() throws {
        let (container, match) = try RecordingRegressionChecks.fixture()
        let store = RecordingWidgetStore(match: match, context: container.mainContext)
        let widget = store.layout.widgets.first { $0.category == "try" }!
        _ = store.beginTry(widget)
        let id = store.session.scoringFlow!.id
        _ = store.confirmTry(flowID: id)
        _ = store.recordConversionTime(flowID: id)
        _ = store.completeConversion(flowID: id, success: false)
        try RecordingRegressionChecks.expect(store.score(teamID: match.homeTeamID) == 5 && store.events.filter { $0.category == "conversion" }.count == 1, "Failed attempt persists with zero points")
        store.undo()
        try RecordingRegressionChecks.expect(store.session.scoringFlow?.isComplete == false && store.events.filter { $0.category == "conversion" }.isEmpty, "Undo reopens result while retaining kick time")
        _ = store.completeConversion(flowID: id, success: true)
        try RecordingRegressionChecks.expect(store.score(teamID: match.homeTeamID) == 7, "Corrected attempt is counted once")
    }
    private static func persistenceAndIndependentPlayers() throws {
        let (container, match) = try RecordingRegressionChecks.fixture()
        let scorer = Player(teamID: match.homeTeamID, number: 3, name: "Scorer")
        let kicker = Player(teamID: match.homeTeamID, number: 8, name: "Kicker")
        let opponent = Player(teamID: match.awayTeamID, number: 9, name: "Opponent")
        for player in [scorer, kicker, opponent] { container.mainContext.insert(player) }
        try container.mainContext.save()
        var store = RecordingWidgetStore(match: match, context: container.mainContext)
        let widget = store.layout.widgets.first { $0.category == "try" }!
        _ = store.beginTry(widget)
        let id = store.session.scoringFlow!.id
        try RecordingRegressionChecks.expect(!store.setScoringPlayer(opponent.id, flowID: id), "Opposing player rejected")
        _ = store.setScoringPlayer(scorer.id, flowID: id)
        _ = store.confirmTry(flowID: id)
        try RecordingRegressionChecks.expect(store.session.scoringFlow?.kickerID == nil, "Scorer is not implicitly kicker")
        _ = store.recordConversionTime(flowID: id)
        store = RecordingWidgetStore(match: match, context: container.mainContext)
        try RecordingRegressionChecks.expect(store.session.scoringFlow?.id == id && store.session.scoringFlow?.kickSeconds != nil, "Pending input and time survive reopening")
        _ = store.completeConversion(flowID: id, success: true)
        _ = store.setScoringPlayer(kicker.id, flowID: id)
        try RecordingRegressionChecks.expect(store.events.first { $0.category == "try" }?.playerID == scorer.id && store.events.first { $0.category == "conversion" }?.playerID == kicker.id && store.events.count == 2, "Kicker can be assigned after result without adding another event")
    }
    private static func legacyTimerRelationships() throws {
        let (container, match) = try RecordingRegressionChecks.fixture()
        let store = RecordingWidgetStore(match: match, context: container.mainContext)
        let start = Date()
        let home = store.layout.widgets.first { $0.kind == .possession && $0.timerTarget == .home }!
        let bip = store.layout.widgets.first { $0.kind == .possession && $0.timerTarget == .bip }!
        store.activate(bip, at: start)
        try RecordingRegressionChecks.expect(store.session.clock.startedAt == nil && store.session.active.isEmpty, "BIP alone cannot start a stopped match clock")
        store.activate(home, at: start)
        store.activate(home, at: start.addingTimeInterval(5))
        try RecordingRegressionChecks.expect(store.session.active.map(\.id) == ["bip"] && store.session.clock.startedAt != nil, "Retapping possession stops only that team")
        store.toggleClock(at: start.addingTimeInterval(10))
        store.toggleClock(at: start.addingTimeInterval(15))
        try RecordingRegressionChecks.expect(store.session.active.isEmpty && store.session.clock.startedAt != nil, "Clock resumes alone")
    }
}
