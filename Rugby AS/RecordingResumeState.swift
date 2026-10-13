import Foundation

extension StatEvent {
    var recordingSortSeconds: Int {
        category == "possession" ? startSeconds ?? 0 : seconds
    }

    func isRecordedBefore(_ other: StatEvent) -> Bool {
        (half, recordingSortSeconds, recordingDetails.recordedAt, id.uuidString) <
        (other.half, other.recordingSortSeconds, other.recordingDetails.recordedAt, other.id.uuidString)
    }
}

extension RecordingClock {
    mutating func advanceToRecordedEvents(_ events: [StatEvent], at date: Date = .now) {
        for event in events {
            let end = event.category == "possession"
                ? max(0, event.startSecondsExact ?? Double(event.startSeconds ?? 0))
                    + max(0, event.durationSecondsExact ?? Double(event.seconds))
                : Double(max(0, event.seconds))
            if event.half > half {
                self = RecordingClock(accumulated: end, half: event.half)
            } else if event.half == half, end > elapsed(at: date) {
                accumulated += end - elapsed(at: date)
            }
        }
    }
}

struct V3TimerState {
    // 表示は分:秒だが、内部では秒以下のずれを失わないよう TimeInterval (Double) で持つ。
    // これで 1 秒未満の停止/開始を繰り返しても累積していく（00:00 のまま固まらない）。
    private var accumulatedSeconds: TimeInterval = 0
    private var startedAt: Date?

    init(elapsed: TimeInterval = 0) {
        accumulatedSeconds = elapsed
    }

    func recordingClock(half: Int) -> RecordingClock {
        RecordingClock(accumulated: accumulatedSeconds, startedAt: startedAt, half: half)
    }

    func activeInterval(id: String, teamID: UUID?, half: Int, clock: V3TimerState, origin: String? = nil) -> RecordingActiveInterval? {
        guard let startedAt else { return nil }
        return RecordingActiveInterval(id: id, teamID: teamID, half: half, startedAt: startedAt,
                                       matchStart: clock.elapsedInterval(at: startedAt), origin: origin)
    }

    var isRunning: Bool {
        startedAt != nil
    }

    mutating func toggle(at date: Date) {
        if isRunning {
            _ = stop(at: date)
        } else {
            start(at: date)
        }
    }

    mutating func start(at date: Date) {
        guard !isRunning else { return }
        startedAt = date
    }

    mutating func stop(at date: Date) -> Int? {
        guard let startedAt else { return nil }
        let interval = max(0, date.timeIntervalSince(startedAt))
        accumulatedSeconds += interval
        self.startedAt = nil
        return Int(interval)
    }

    mutating func reset() {
        accumulatedSeconds = 0
        startedAt = nil
    }

    func elapsedText(at date: Date) -> String {
        let seconds = elapsedSeconds(at: date)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    func elapsedSeconds(at date: Date) -> Int {
        Int(elapsedInterval(at: date))
    }

    func elapsedInterval(at date: Date) -> TimeInterval {
        guard let startedAt else {
            return accumulatedSeconds
        }
        return accumulatedSeconds + max(0, date.timeIntervalSince(startedAt))
    }
}
