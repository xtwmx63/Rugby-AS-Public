import Foundation

/// A source file's place on the editor's continuous video strip.
struct MatchTimelineVideoRange {
    var fileName: String
    var start: Double
    var end: Double
}

/// Keeps the editor's video coordinates separate from each half's match clock.
struct MatchVideoTimeline {
    var clock: MatchVideoClock
    var videos: [MatchTimelineVideoRange]

    func position(half: Int, seconds: Double) -> Double? {
        if videos.isEmpty {
            return nominalStart(half: half) + clock.settings.timelineSecond(forClockSeconds: seconds, half: half)
        }
        guard let position = clock.videoPosition(half: half, clockSeconds: seconds),
              let video = videos.first(where: { $0.fileName == position.fileName }),
              position.at <= video.end - video.start else { return nil }
        return video.start + position.at
    }

    func time(at position: Double, preferredHalf: Int? = nil) -> (half: Int, seconds: Double)? {
        guard position.isFinite else { return nil }
        if videos.isEmpty {
            let order = preferredHalf.map { $0 >= 1 ? [1, 0] : [0, 1] } ?? [1, 0]
            for half in order {
                let elapsed = position - nominalStart(half: half)
                if elapsed >= 0 && elapsed <= Double(clock.settings.actualHalfTimelineDuration(for: half)) {
                    return (half, clock.settings.clockSeconds(fromTimelineSecond: elapsed, half: half))
                }
            }
            return nil
        }
        guard let video = videos.first(where: { $0.start <= position && position <= $0.end }) else { return nil }
        return clock.preciseMatchTime(fileName: video.fileName, at: position - video.start, preferredHalf: preferredHalf)
    }

    private func nominalStart(half: Int) -> Double {
        half >= 1 ? Double(clock.settings.actualHalfTimelineDuration(for: 0) + clock.settings.halfTimeDuration) : 0
    }
}

/// Metadata copied into undo and split snapshots, including custom notes, zones
/// and video linkage. Timing is kept on the clip separately.
struct StatEventDetails: Equatable {
    var category: String
    var teamID: UUID?
    var playerID: UUID?
    var outcome: String
    var half: Int
    var origin: String?
    var widgetData: Data?
    var seconds: Int
    var startSeconds: Int?
    var startSecondsExact: Double?
    var durationSecondsExact: Double?

    init(event: StatEvent) {
        category = event.category
        teamID = event.teamID
        playerID = event.playerID
        outcome = event.outcome
        half = event.half
        origin = event.origin
        widgetData = event.widgetData
        seconds = event.seconds
        startSeconds = event.startSeconds
        startSecondsExact = event.startSecondsExact
        durationSecondsExact = event.durationSecondsExact
    }

    func makeEvent(id: UUID, matchID: UUID) -> StatEvent {
        StatEvent(id: id, matchID: matchID, teamID: teamID, playerID: playerID, category: category,
                  outcome: outcome, seconds: seconds, startSeconds: startSeconds, half: half,
                  origin: origin, startSecondsExact: startSecondsExact,
                  durationSecondsExact: durationSecondsExact, widgetData: widgetData)
    }
}

enum TimelineEventTiming {
    static func canSplit(category: String) -> Bool { category == "possession" }

    static func start(of event: StatEvent, isInterval: Bool) -> Double {
        event.startSecondsExact ?? Double(isInterval ? (event.startSeconds ?? max(0, event.seconds - 58)) : event.seconds)
    }

    static func update(_ event: StatEvent, start: Double, length: Double, isInterval: Bool,
                       timeline: MatchVideoTimeline, match: Match? = nil) throws {
        if let original = range(of: event, isInterval: isInterval, timeline: timeline),
           abs(original.start - start) < 0.00001 && abs(original.end - original.start - length) < 0.00001 {
            return // Undo must preserve original subsecond values and unset fields.
        }
        guard let time = timeline.time(at: start) else {
            throw RecordingWidgetError.invalid("この位置は試合時間の外です。キックオフ合わせと前後半の長さを確認してください。")
        }
        var duration = max(0.1, length)
        if isInterval {
            guard let end = timeline.time(at: start + duration, preferredHalf: time.half), end.half == time.half else {
                throw RecordingWidgetError.invalid("区間は同じハーフ内に収めてください。動画の切れ目やハーフタイムをまたぐことはできません。")
            }
            duration = max(0.1, end.seconds - time.seconds)
        }
        // Older records can describe possession relative to a selected team.
        // Resolve that meaning before adding a start position changes their format.
        let possessionTarget = isInterval ? match.flatMap { MatchStatistics.possessionTarget(for: event, match: $0) } : nil
        event.half = time.half
        event.startSecondsExact = (time.seconds * 10).rounded() / 10
        event.durationSecondsExact = (duration * 10).rounded() / 10
        if isInterval {
            event.startSeconds = Int(time.seconds.rounded())
            event.seconds = max(1, Int(duration.rounded()))
        } else {
            event.seconds = Int(time.seconds.rounded())
        }
        if let match, let possessionTarget {
            switch possessionTarget {
            case .home: event.teamID = match.homeTeamID; event.outcome = "own"
            case .away: event.teamID = match.awayTeamID; event.outcome = "own"
            case .bip: event.teamID = nil; event.outcome = "none"
            }
        }
        var details = event.recordingDetails
        details.timeBasis = .halfClock
        event.recordingDetails = details
    }

    static func range(of event: StatEvent, isInterval: Bool, timeline: MatchVideoTimeline) -> (start: Double, end: Double)? {
        // Older editor versions wrote the visible video coordinates into these
        // fields. Keep their position until the user actually edits that clip.
        if event.recordingDetails.timeBasis != .halfClock,
           let exactStart = event.startSecondsExact, let exactDuration = event.durationSecondsExact {
            let start = max(0, exactStart)
            return (start, start + max(0.1, exactDuration))
        }
        let clockStart = start(of: event, isInterval: isInterval)
        guard let start = timeline.position(half: event.half, seconds: clockStart) else { return nil }
        if isInterval {
            let duration = event.durationSecondsExact ?? Double(max(1, event.seconds))
            guard let end = timeline.position(half: event.half, seconds: clockStart + duration) else { return nil }
            return (start, max(start + 0.1, end))
        }
        return (start, start + max(0.1, event.durationSecondsExact ?? 26))
    }
}
