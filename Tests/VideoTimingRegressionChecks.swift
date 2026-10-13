import Foundation

private enum VideoTimingCheckFailure: Error { case failed(String) }

enum VideoTimingRegressionChecks {
    static func run() throws {
        try respectsHalfTimeAndStoppages()
        try usesExplicitSecondHalfAnchor()
        try roundTripsFractionalClockPositions()
        try separatesSameClockTimeInDifferentHalves()
        try mapsMultipleSourceFiles()
        try rejectsRemovedAndInvalidAnchors()
        try savesHalfRelativeTimeAfterMoving()
        try rejectsUnalignedVideoPositionsWithoutMutation()
        try preservesMetadataAndExactTimeOnUndo()
        try measuresIntervalsAcrossStoppages()
        try acceptsAnIntervalEndingAtZeroLengthHalfTime()
        try onlySplitsIntervalEvents()
        try keepsUnavailableSourceEventsOutOfOtherVideos()
        try keepsLegacyPossessionOnItsOriginalTeamWhenMoved()
        try preservesLegacyExactVideoCoordinates()
        try normalizesLegacyCoordinatesOnlyAfterMoving()
        try distinguishesMarkedHalfClockCoordinates()
        print("PASS: 17 video timing regression checks")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw VideoTimingCheckFailure.failed(message) }
    }

    private static func close(_ value: Double?, _ expected: Double) -> Bool {
        guard let value else { return false }
        return abs(value - expected) < 0.00001
    }

    private static var settings: MatchClockSettings {
        .init(firstHalfSeconds: 420, secondHalfSeconds: 420,
              stoppages: [.init(half: 0, clockSecond: 100, durationSeconds: 30)], halfTimeSeconds: 180)
    }

    private static var clock: MatchVideoClock {
        .init(settings: settings, videoNames: ["match.mov"],
              anchors: [0: .init(fileName: "match.mov", seconds: 20)])
    }

    private static var timeline: MatchVideoTimeline {
        .init(clock: clock, videos: [.init(fileName: "match.mov", start: 0, end: 1200)])
    }

    private static func respectsHalfTimeAndStoppages() throws {
        try expect(close(clock.anchor(half: 1)?.seconds, 650), "Second-half fallback must include configured halftime and first-half stoppages")
        try expect(close(clock.videoPosition(half: 1, seconds: 60)?.at, 710), "Second-half playback must use the user's halftime setting")
        try expect(clock.matchTime(fileName: "match.mov", at: 500) == nil, "Halftime must not be recorded as playing time")
    }

    private static func usesExplicitSecondHalfAnchor() throws {
        let clock = MatchVideoClock(settings: settings, videoNames: ["match.mov", "second.mov"],
                                   anchors: [0: .init(fileName: "match.mov", seconds: 20),
                                             1: .init(fileName: "second.mov", seconds: 5)])
        let position = clock.videoPosition(half: 1, seconds: 60)
        try expect(position?.fileName == "second.mov" && close(position?.at, 65), "Explicit kickoff must override the estimated continuation")
    }

    private static func roundTripsFractionalClockPositions() throws {
        for seconds in [0.0, 80.25, 100, 100.1, 150.75, 419.9] {
            let position = clock.videoPosition(half: 0, clockSeconds: seconds)!
            let restored = clock.preciseMatchTime(fileName: position.fileName, at: position.at)
            try expect(restored?.half == 0 && close(restored?.seconds, seconds), "Fractional time must round-trip around stoppages")
        }
        try expect(close(clock.preciseMatchTime(fileName: "match.mov", at: 130)?.seconds, 100), "A stopped clock stays at its stop timestamp")
    }

    private static func separatesSameClockTimeInDifferentHalves() throws {
        try expect(close(timeline.position(half: 0, seconds: 60), 80), "First-half clip must include kickoff offset")
        try expect(close(timeline.position(half: 1, seconds: 60), 710), "Second-half clip must not overlay first-half footage")
        let noVideo = MatchVideoTimeline(clock: .init(settings: settings, videoNames: [], anchors: [:]), videos: [])
        try expect(close(noVideo.position(half: 1, seconds: 60), 690), "An editor without video must still place halves on a continuous match timeline")
    }

    private static func mapsMultipleSourceFiles() throws {
        let clock = MatchVideoClock(settings: settings, videoNames: ["first.mov", "second.mov"],
                                   anchors: [0: .init(fileName: "first.mov", seconds: 30),
                                             1: .init(fileName: "second.mov", seconds: 15)])
        let timeline = MatchVideoTimeline(clock: clock, videos: [.init(fileName: "first.mov", start: 0, end: 700),
                                                                  .init(fileName: "second.mov", start: 900, end: 1500)])
        try expect(close(timeline.position(half: 1, seconds: 60), 975), "A second source must include both its timeline offset and local kickoff")
        let time = timeline.time(at: 975)
        try expect(time?.half == 1 && close(time?.seconds, 60), "Source offsets must be removed before saving match time")
        try expect(timeline.time(at: 800) == nil, "A gap between source files is not match footage")
    }

    private static func rejectsRemovedAndInvalidAnchors() throws {
        let clock = MatchVideoClock(settings: settings, videoNames: ["new.mov"],
                                   anchors: [0: .init(fileName: "removed.mov", seconds: 500),
                                             1: .init(fileName: "new.mov", seconds: .nan)])
        try expect(!clock.isKickoffAligned && clock.storedAnchor(half: 1) == nil, "Removed source and nonfinite anchors must not remain active")
        let position = clock.videoPosition(half: 0, seconds: 60)
        try expect(position?.fileName == "new.mov" && close(position?.at, 60), "Replacing a video must never reuse the removed source")
    }

    private static func savesHalfRelativeTimeAfterMoving() throws {
        let event = StatEvent(matchID: UUID(), category: "try", outcome: "success", seconds: 60, half: 0)
        var details = RecordingEventDetails()
        details.note = "映像を確認"; details.zone = 3
        event.recordingDetails = details
        try TimelineEventTiming.update(event, start: 710.2, length: 26, isInterval: false, timeline: timeline)
        try expect(event.half == 1 && event.seconds == 60 && close(event.startSecondsExact, 60.2), "Editing video position must save the correct half and local clock")
        try expect(event.recordingDetails.note == details.note && event.recordingDetails.zone == details.zone,
                   "Moving a clip must retain attached details")
        let range = TimelineEventTiming.range(of: event, isInterval: false, timeline: timeline)
        try expect(close(range?.start, 710.2), "Reopening a moved clip must preserve its footage position")
    }

    private static func rejectsUnalignedVideoPositionsWithoutMutation() throws {
        let event = StatEvent(matchID: UUID(), category: "try", outcome: "success", seconds: 60, half: 1)
        let original = StatEventDetails(event: event)
        do {
            try TimelineEventTiming.update(event, start: 10, length: 26, isInterval: false, timeline: timeline)
            throw VideoTimingCheckFailure.failed("Pre-kickoff editing should be rejected")
        } catch is RecordingWidgetError { }
        try expect(StatEventDetails(event: event) == original, "Rejected editing must leave persisted event fields untouched")
    }

    private static func preservesMetadataAndExactTimeOnUndo() throws {
        let event = StatEvent(matchID: UUID(), teamID: UUID(), playerID: UUID(), category: "possession", outcome: "own",
                              seconds: 4, startSeconds: 30, half: 1, origin: "scrum",
                              startSecondsExact: 30.25, durationSecondsExact: 3.75, widgetData: Data([9, 8, 7]))
        let details = StatEventDetails(event: event)
        let restored = details.makeEvent(id: event.id, matchID: event.matchID)
        let range = TimelineEventTiming.range(of: restored, isInterval: true, timeline: timeline)!
        try TimelineEventTiming.update(restored, start: range.start, length: range.end - range.start, isInterval: true, timeline: timeline)
        try expect(StatEventDetails(event: restored) == details, "Undo must preserve note/zone/video data and exact original timing")
    }

    private static func measuresIntervalsAcrossStoppages() throws {
        let event = StatEvent(matchID: UUID(), category: "possession", outcome: "own", seconds: 1)
        try TimelineEventTiming.update(event, start: 110, length: 60, isInterval: true, timeline: timeline)
        try expect(event.startSeconds == 90 && event.seconds == 30, "An interval across a stopped clock must save its clock duration")
        let range = TimelineEventTiming.range(of: event, isInterval: true, timeline: timeline)
        try expect(close(range?.start, 110) && close(range?.end, 170), "Interval mapping must recover the original footage bounds")
    }

    private static func acceptsAnIntervalEndingAtZeroLengthHalfTime() throws {
        let settings = MatchClockSettings(firstHalfSeconds: 420, secondHalfSeconds: 420, stoppages: [], halfTimeSeconds: 0)
        let timeline = MatchVideoTimeline(clock: .init(settings: settings, videoNames: [], anchors: [:]), videos: [])
        let event = StatEvent(matchID: UUID(), category: "possession", outcome: "own", seconds: 1)
        try TimelineEventTiming.update(event, start: 400, length: 20, isInterval: true, timeline: timeline)
        try expect(event.half == 0 && event.startSeconds == 400 && event.seconds == 20, "An interval ending at halftime belongs to its starting half")
    }

    private static func onlySplitsIntervalEvents() throws {
        try expect(TimelineEventTiming.canSplit(category: "possession"), "Possession and BIP intervals can split")
        for category in ["try", "conversion", "penalty_goal", "drop_goal", "lineout", "scrum"] {
            try expect(!TimelineEventTiming.canSplit(category: category), "A score or single result must never duplicate when split")
        }
    }

    private static func keepsUnavailableSourceEventsOutOfOtherVideos() throws {
        let short = MatchVideoTimeline(clock: clock, videos: [.init(fileName: "match.mov", start: 0, end: 400),
                                                              .init(fileName: "other.mov", start: 412, end: 1400)])
        try expect(short.position(half: 1, seconds: 60) == nil, "An out-of-range source position must not spill into an unrelated next video")
    }

    private static func keepsLegacyPossessionOnItsOriginalTeamWhenMoved() throws {
        let match = Match(tournamentID: UUID(), homeTeamID: UUID(), awayTeamID: UUID(), playedAt: .now)
        for (selectedTeam, outcome, expectedTeam) in [
            (match.homeTeamID, "opponent", match.awayTeamID),
            (match.awayTeamID, "opponent", match.homeTeamID),
            (match.awayTeamID, "own", match.awayTeamID)
        ] {
            let event = StatEvent(matchID: match.id, teamID: selectedTeam, category: "possession", outcome: outcome, seconds: 20)
            let previousTarget = MatchStatistics.possessionTarget(for: event, match: match)
            try TimelineEventTiming.update(event, start: 60, length: 20, isInterval: true, timeline: timeline, match: match)
            try expect(event.teamID == expectedTeam && event.outcome == "own", "Moving old relative possession must make the actual team explicit")
            try expect(MatchStatistics.possessionTarget(for: event, match: match) == previousTarget,
                       "Adding an exact start must never transfer possession to the other team")
        }
    }

    private static func preservesLegacyExactVideoCoordinates() throws {
        let event = StatEvent(matchID: UUID(), category: "try", outcome: "success", seconds: 710, half: 1,
                              startSecondsExact: 710.25, durationSecondsExact: 20.75)
        var details = RecordingEventDetails()
        details.note = "旧クリップ"
        var oldJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(details)) as! [String: Any]
        oldJSON.removeValue(forKey: "timeBasis")
        event.widgetData = try JSONSerialization.data(withJSONObject: oldJSON)
        let original = StatEventDetails(event: event)
        let range = TimelineEventTiming.range(of: event, isInterval: false, timeline: timeline)!
        try expect(close(range.start, 710.25) && close(range.end, 731), "Unmarked exact data must retain its original video coordinates")
        try expect(event.recordingDetails.timeBasis == nil, "An old JSON payload must decode with no time-basis marker")
        try TimelineEventTiming.update(event, start: range.start, length: range.end - range.start, isInterval: false, timeline: timeline)
        try expect(StatEventDetails(event: event) == original, "Loading or undoing unchanged legacy clips must not migrate any saved values")
    }

    private static func normalizesLegacyCoordinatesOnlyAfterMoving() throws {
        let event = StatEvent(matchID: UUID(), category: "try", outcome: "success", seconds: 710, half: 0,
                              startSecondsExact: 710, durationSecondsExact: 26)
        try TimelineEventTiming.update(event, start: 711.5, length: 26, isInterval: false, timeline: timeline)
        try expect(event.half == 1 && close(event.startSecondsExact, 61.5), "Moving an old clip must convert its video position to the correct half clock")
        try expect(event.recordingDetails.timeBasis == .halfClock, "A successfully moved clip must save its explicit new coordinate basis")
        let reopened = TimelineEventTiming.range(of: event, isInterval: false, timeline: timeline)
        try expect(close(reopened?.start, 711.5), "The normalized clip must reopen at the position chosen by the user")
    }

    private static func distinguishesMarkedHalfClockCoordinates() throws {
        let event = StatEvent(matchID: UUID(), category: "possession", outcome: "own", seconds: 4,
                              startSeconds: 30, half: 1, startSecondsExact: 30.25, durationSecondsExact: 3.75)
        var details = RecordingEventDetails()
        details.timeBasis = .halfClock
        event.recordingDetails = details
        let range = TimelineEventTiming.range(of: event, isInterval: true, timeline: timeline)
        try expect(close(range?.start, 680.25) && close(range?.end, 684), "Marked exact values from new recordings must include the half's video offset")
    }
}
