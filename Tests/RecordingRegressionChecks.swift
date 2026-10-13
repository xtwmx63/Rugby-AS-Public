import Foundation
import SwiftData

private enum CheckFailure: Error { case failed(String) }

@main
@MainActor
struct RecordingRegressionChecks {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw CheckFailure.failed(message) }
    }

    static func fixture() throws -> (ModelContainer, Match) {
        let container = try ModelContainer(for: Match.self, StatEvent.self, Player.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let match = Match(tournamentID: UUID(), homeTeamID: UUID(), awayTeamID: UUID(), playedAt: .now)
        container.mainContext.insert(match)
        try container.mainContext.save()
        return (container, match)
    }

    static func main() async throws {
        try resumesOlderMatches()
        try preservesSavedClockAndHalf()
        try preservesRunningClockAnchor()
        try legacyAndCustomShareClockAndIntervals()
        try finishesAllIntervals()
        try rejectsOpposingPlayers()
        try preservesExactTimesOnUndo()
        try sortsByHalfAndIntervalStart()
        try decodesPreviousSessions()
        try signedDistanceAndOriginRemainEditable()
        try BoardRegressionChecks.run()
        try MetricRegressionChecks.run()
        try RecordingInputRegressionChecks.run()
        try ScoringFlowRegressionChecks.run()
        try RecordingPerformanceRegressionChecks.run()
        try StartupPerformanceRegressionChecks.run()
        try ImageThumbnailRegressionChecks.run()
        try AnalysisPerformanceRegressionChecks.run()
        try RecordingIntegrationChecks.run()
        try BackupRegressionChecks.run()
        try await BackupRegressionChecks.runProgressRestore()
        try MatchStatisticsRegressionChecks.run()
        try TeamPerformanceRegressionChecks.run()
        try VideoTimingRegressionChecks.run()
        try YouTubeRegressionChecks.run()
        try AnalysisFilterRegressionChecks.run()
        try PersistenceRegressionChecks.run()
        try AnalysisComparisonRegressionChecks.run()
        try await AnalysisComparisonRegressionChecks.runWorkspaceLoader()
        try await ChangeTrackingRegressionChecks.run()
        try BreakdownImportChecks.run()
        try AnalysisReportRegressionChecks.run()
        try await TournamentCSVRegressionChecks.run()
        try await OfficialImportRegressionChecks.run()
        try StatsExclusionRegressionChecks.run()
        print("PASS: all regression checks")
    }

    static func resumesOlderMatches() throws {
        let (container, match) = try fixture()
        let context = container.mainContext
        context.insert(StatEvent(matchID: match.id, category: "try", outcome: "success", seconds: 2000, half: 0))
        context.insert(StatEvent(matchID: match.id, category: "possession", outcome: "own", seconds: 20,
                                 startSeconds: 120, half: 1))
        try context.save()
        let store = RecordingWidgetStore(match: match, context: context)
        try expect(store.session.clock.half == 1, "Older match must resume in second half")
        try expect(store.session.clock.accumulated == 140, "Resume after end of possession, not its duration")
    }

    static func preservesSavedClockAndHalf() throws {
        let (container, match) = try fixture()
        match.recordingSessionData = try JSONEncoder().encode(RecordingSession(clock: RecordingClock(accumulated: 900)))
        container.mainContext.insert(StatEvent(matchID: match.id, category: "try", outcome: "success", seconds: 600))
        try container.mainContext.save()
        var store = RecordingWidgetStore(match: match, context: container.mainContext)
        try expect(store.session.clock.accumulated == 900, "Saved time must not regress to last event")
        store.nextHalf()
        store = RecordingWidgetStore(match: match, context: container.mainContext)
        try expect(store.session.clock.half == 1 && store.session.clock.accumulated == 0, "Second half at zero survives reopening")
    }

    static func preservesRunningClockAnchor() throws {
        let start = Date()
        var clock = RecordingClock(accumulated: 10, startedAt: start)
        let event = StatEvent(matchID: UUID(), category: "try", outcome: "success", seconds: 30)
        clock.advanceToRecordedEvents([event], at: start.addingTimeInterval(5))
        try expect(clock.elapsed(at: start.addingTimeInterval(10)) == 35, "Advancing a running clock preserves elapsed wall time")
    }

    static func legacyAndCustomShareClockAndIntervals() throws {
        let (container, match) = try fixture()
        let context = container.mainContext
        let start = Date()
        var clock = V3TimerState(elapsed: 80)
        var home = V3TimerState()
        var bip = V3TimerState()
        clock.start(at: start)
        bip.start(at: start)
        home.start(at: start.addingTimeInterval(2))
        let session = RecordingSession(clock: clock.recordingClock(half: 1), active: [
            bip.activeInterval(id: "bip", teamID: nil, half: 1, clock: clock)!,
            home.activeInterval(id: "home", teamID: match.homeTeamID, half: 1, clock: clock, origin: "scrum")!
        ], selectedTeamID: match.homeTeamID)
        match.recordingSessionData = try JSONEncoder().encode(session)
        try context.save()
        let store = RecordingWidgetStore(match: match, context: context)
        let end = start.addingTimeInterval(12)
        try expect(store.pause(at: end), "Shared session pause saves")
        try expect(store.session.clock.accumulated == 92 && store.session.clock.half == 1, "Clock and half survive switch")
        let event = store.events.first { $0.teamID == match.homeTeamID }!
        try expect(event.seconds == 10 && event.startSeconds == 82 && event.origin == "scrum", "Pending possession and origin survive close")
        let reopened = RecordingWidgetStore(match: match, context: context)
        try expect(reopened.pause(at: end.addingTimeInterval(50)), "Reopen pause saves")
        try expect(reopened.events.count == 2, "Reopening must not duplicate possession or BIP")
        try expect(reopened.session.clock.accumulated == 92, "Closed screen must not count time")
        try expect(reopened.timerTotal(.home, at: end) == 10 && reopened.timerTotal(.bip, at: end) == 12, "Timer totals survive reopen")
    }

    static func finishesAllIntervals() throws {
        let (container, match) = try fixture()
        let store = RecordingWidgetStore(match: match, context: container.mainContext)
        let start = Date()
        let home = store.layout.widgets.first { $0.kind == .possession && $0.timerTarget == .home }!
        store.activate(home, at: start)
        try expect(store.finish(at: start.addingTimeInterval(15)), "Finish saves")
        try expect(store.session.active.isEmpty && store.session.clock.startedAt == nil, "Finish stops every timer")
        try expect(store.events.filter { $0.category == "possession" }.count == 2, "Finish flushes home and BIP")
        try expect(store.events.contains { $0.category == "match_state" && $0.outcome == "finished" }, "Finish adds status")
    }

    static func rejectsOpposingPlayers() throws {
        let (container, match) = try fixture()
        let context = container.mainContext
        let own = Player(teamID: match.homeTeamID, number: 1)
        let opponent = Player(teamID: match.awayTeamID, number: 1)
        let event = StatEvent(matchID: match.id, teamID: match.homeTeamID, category: "try", outcome: "success", seconds: 5)
        context.insert(own); context.insert(opponent); context.insert(event)
        try context.save()
        let store = RecordingWidgetStore(match: match, context: context)
        try expect(!store.updateEvent(event, playerID: opponent.id, details: event.recordingDetails), "Opposing scorer must be rejected")
        try expect(event.playerID == nil, "Rejected selection leaves event unchanged")
        try expect(store.updateEvent(event, playerID: own.id, details: event.recordingDetails), "Own scorer is accepted")
        try expect(store.updateEvent(event, playerID: nil, details: event.recordingDetails), "Unspecified scorer stays optional")
    }

    static func preservesExactTimesOnUndo() throws {
        let (container, match) = try fixture()
        let context = container.mainContext
        let event = StatEvent(matchID: match.id, teamID: match.homeTeamID, category: "possession", outcome: "own", seconds: 3,
                              startSeconds: 10, startSecondsExact: 10.25, durationSecondsExact: 3.75)
        context.insert(event)
        try context.save()
        let store = RecordingWidgetStore(match: match, context: context)
        store.toggleClock()
        context.delete(event)
        try context.save()
        store.undo()
        let restored = store.events.first { $0.id == event.id }
        try expect(restored?.startSecondsExact == 10.25 && restored?.durationSecondsExact == 3.75, "Undo restores subsecond timing")
    }

    static func sortsByHalfAndIntervalStart() throws {
        let id = UUID()
        let first = StatEvent(matchID: id, category: "try", outcome: "success", seconds: 600, half: 0)
        let second = StatEvent(matchID: id, category: "try", outcome: "success", seconds: 10, half: 1)
        let interval = StatEvent(matchID: id, category: "possession", outcome: "own", seconds: 200, startSeconds: 5, half: 1)
        let ordered = [second, first, interval].sorted { $0.isRecordedBefore($1) }
        try expect(ordered.map(\.id) == [first.id, interval.id, second.id], "Sort uses half and interval start, not duration")
    }

    static func signedDistanceAndOriginRemainEditable() throws {
        let (container, match) = try fixture()
        let context = container.mainContext
        let carry = StatEvent(matchID: match.id, teamID: match.homeTeamID, category: "carry_metres", outcome: "success", seconds: 10)
        let kick = StatEvent(matchID: match.id, teamID: match.homeTeamID, category: "kick_distance", outcome: "success", seconds: 15)
        context.insert(carry); context.insert(kick)
        try context.save()
        let store = RecordingWidgetStore(match: match, context: context)
        var details = carry.recordingDetails
        details.number = -4; details.unit = "m"; details.title = "キャリー距離"
        try expect(store.updateEvent(carry, playerID: nil, details: details, origin: "scrum"), "Retreat distance accepts negative metres")
        try expect(carry.recordingDetails.number == -4 && carry.origin == "scrum", "Signed distance and origin are both saved")
        try expect(!store.updateEvent(kick, playerID: nil, details: details), "Kick distance cannot be negative")
        store.undo()
        try expect(carry.recordingDetails.number == nil && carry.origin == nil, "Undo restores original distance and origin")
        try expect(store.updateEvent(carry, playerID: nil, details: carry.recordingDetails, origin: "kickoff"), "Legacy restart origin saves")
        try expect(carry.recordingOrigin == .restart, "Legacy kickoff restores the restart selection")
        try expect(store.updateEvent(carry, playerID: nil, details: carry.recordingDetails), "Editing without origin selection saves")
        try expect(carry.origin == "kickoff", "No origin selection leaves the stored origin unchanged")
        try expect(store.updateEvent(carry, playerID: nil, details: carry.recordingDetails, origin: "penalty"), "Legacy tap origin saves")
        try expect(carry.recordingOrigin == .tapKick, "Legacy penalty restores the tap-kick selection")
        try expect(store.updateEvent(carry, playerID: nil, details: carry.recordingDetails, clearOrigin: true), "Explicit clear removes the origin")
        try expect(carry.origin == nil && carry.recordingOrigin == nil, "Cleared origin stays unset")
        store.undo()
        try expect(carry.origin == "penalty" && carry.recordingOrigin == .tapKick, "Undo restores an explicitly cleared origin")
    }

    static func decodesPreviousSessions() throws {
        let old = Data(#"{"clock":{"accumulated":5,"half":0},"active":[{"id":"home","half":0,"startedAt":0,"matchStart":0}]}"#.utf8)
        let decoded = try JSONDecoder().decode(RecordingSession.self, from: old)
        try expect(decoded.active.first?.origin == nil, "Sessions without new origin field still load")
    }
}
