import Foundation

/// 新旧の記録形式を、試合の集計で同じように扱う。
enum MatchStatistics {
    /// 同時刻ではTRY→CONの順にし、取得順に左右されない累積得点を表示する。
    static func scoringEventPrecedes(_ lhs: StatEvent, _ rhs: StatEvent) -> Bool {
        if lhs.half != rhs.half { return lhs.half < rhs.half }
        if lhs.seconds != rhs.seconds { return lhs.seconds < rhs.seconds }
        func priority(_ category: String) -> Int {
            switch ScoringCategory(rawValue: category) {
            case .tryScore, .penaltyTry: return 0
            case .conversion: return 1
            default: return 2
            }
        }
        let leftPriority = priority(lhs.category), rightPriority = priority(rhs.category)
        if leftPriority != rightPriority { return leftPriority < rightPriority }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    static func possessionTotals(
        events: [StatEvent], match: Match, half: Int? = nil,
        excludingBIPInterval: (half: Int, start: Double)? = nil
    ) -> [RecordingTimerTarget: Double] {
        var totals: [RecordingTimerTarget: Double] = [.home: 0, .away: 0, .bip: 0]
        var intervalsByHalf: [Int: [(start: Double, end: Double)]] = [:]
        var unlocatedTeamSeconds: [Int: Double] = [:]
        var unlocatedBIPSeconds: [Int: Double] = [:]
        for event in events {
            guard event.matchID == match.id, event.category == "possession",
                  half == nil || event.half == half,
                  let target = possessionTarget(for: event, match: match) else { continue }
            let duration = event.durationSecondsExact ?? Double(event.seconds)
            guard duration.isFinite, duration >= 0 else { continue }
            if target != .bip { totals[target, default: 0] += duration }

            // BIPとチーム保持は同じ時間を記録するため、開始時刻のある区間は
            // 重なりを除いて合計する。新旧の記録が混在しても片方を捨てない。
            if let start = event.startSecondsExact ?? event.startSeconds.map(Double.init), start.isFinite {
                let intervalStart = max(0, start)
                var intervalEnd = intervalStart + duration
                // 実行中のBIPは呼び出し側が経過秒を足す。その範囲を保存済みの
                // チーム保持から補完すると、チーム切替のたびに二重計上される。
                if let excluded = excludingBIPInterval, excluded.half == event.half, excluded.start.isFinite {
                    intervalEnd = min(intervalEnd, max(0, excluded.start))
                }
                if intervalEnd > intervalStart {
                    intervalsByHalf[event.half, default: []].append((intervalStart, intervalEnd))
                }
            } else if target == .bip {
                unlocatedBIPSeconds[event.half, default: 0] += duration
            } else {
                unlocatedTeamSeconds[event.half, default: 0] += duration
            }
        }
        let halves = Set(intervalsByHalf.keys).union(unlocatedTeamSeconds.keys).union(unlocatedBIPSeconds.keys)
        for period in halves {
            let sorted = (intervalsByHalf[period] ?? []).sorted { $0.start < $1.start }
            var intervalStart = 0.0, intervalEnd = 0.0, duration = 0.0
            for interval in sorted {
                if interval.start > intervalEnd {
                    duration += intervalEnd - intervalStart
                    intervalStart = interval.start
                }
                intervalEnd = max(intervalEnd, interval.end)
            }
            duration += intervalEnd - intervalStart
            // 開始時刻のない旧記録では重なりを判定できないので、BIPと
            // チーム保持の大きい方を用い、同じ時間を二重に足さない。
            totals[.bip, default: 0] += duration + max(unlocatedTeamSeconds[period] ?? 0, unlocatedBIPSeconds[period] ?? 0)
        }
        return totals
    }

    nonisolated static func possessionTarget(for event: StatEvent, match: Match) -> RecordingTimerTarget? {
        if event.outcome == "none" { return .bip }
        if let teamID = event.teamID {
            // 開始時刻のある記録は、旧タイムラインの opponent を含めて
            // teamID が保持した側。最古画面の時刻なし記録だけが相対指定。
            let isRelativeOpponent = event.outcome == "opponent"
                && event.startSeconds == nil && event.startSecondsExact == nil
            if teamID == match.homeTeamID { return isRelativeOpponent ? .away : .home }
            if teamID == match.awayTeamID { return isRelativeOpponent ? .home : .away }
            return nil
        }
        if event.outcome == "own" { return .home }
        if event.outcome == "opponent" { return .away }
        return nil
    }

    /// 終了の記録も時計の到達時刻として使う。保持は継続秒ではなく終了時刻で比べる。
    static func halfEndSeconds(events: [StatEvent], half: Int) -> Double {
        events.lazy.filter { $0.half == half }.map { event -> Double in
            guard event.category == "possession" else { return Double(max(0, event.seconds)) }
            let start = event.startSecondsExact ?? Double(event.startSeconds ?? 0)
            let duration = event.durationSecondsExact ?? Double(event.seconds)
            guard start.isFinite, duration.isFinite else { return 0 }
            return max(0, start) + max(0, duration)
        }.max() ?? 0
    }
}

enum PlayingTimeCalculator {
    struct Result {
        var minutesByPlayer: [UUID: Int] = [:]
        var hasStarterInfo = false
        var totalMinutes = 0
    }

    static func calculate(
        matchID: UUID,
        lineups: [MatchLineup],
        substitutions: [Substitution],
        events: [StatEvent]
    ) -> Result {
        let starters = lineups
            .filter { $0.matchID == matchID && $0.role == "starter" }
            .map(\.playerID)
        let matchSubstitutions = substitutions.filter { $0.matchID == matchID }
        let matchEvents = events.filter { $0.matchID == matchID }
        guard !starters.isEmpty else { return Result() }

        let firstHalfMinutes = halfMinutes(half: 0, events: matchEvents, substitutions: matchSubstitutions)
        let secondHalfMinutes = halfMinutes(half: 1, events: matchEvents, substitutions: matchSubstitutions)
        let totalMinutes = firstHalfMinutes + secondHalfMinutes
        let orderedSubstitutions = matchSubstitutions
            .map { substitution -> (absoluteMinute: Int, substitution: Substitution) in
                let base = substitution.half >= 1 ? firstHalfMinutes : 0
                let clampedMinute = min(max(0, substitution.minute),
                    substitution.half >= 1 ? secondHalfMinutes : firstHalfMinutes)
                return (base + clampedMinute, substitution)
            }
            .sorted { $0.absoluteMinute < $1.absoluteMinute }

        var enteredAtMinute: [UUID: Int] = [:]
        var minutesByPlayer: [UUID: Int] = [:]
        for starter in starters { enteredAtMinute[starter] = 0 }
        for entry in orderedSubstitutions {
            let substitution = entry.substitution
            if let entered = enteredAtMinute.removeValue(forKey: substitution.playerOutID) {
                minutesByPlayer[substitution.playerOutID, default: 0] += max(0, entry.absoluteMinute - entered)
            }
            if enteredAtMinute[substitution.playerInID] == nil {
                enteredAtMinute[substitution.playerInID] = entry.absoluteMinute
            }
        }
        for (playerID, entered) in enteredAtMinute {
            minutesByPlayer[playerID, default: 0] += max(0, totalMinutes - entered)
        }
        return Result(minutesByPlayer: minutesByPlayer, hasStarterInfo: true, totalMinutes: totalMinutes)
    }

    private static func halfMinutes(half: Int, events: [StatEvent], substitutions: [Substitution]) -> Int {
        let eventMinutes = Int(ceil(MatchStatistics.halfEndSeconds(events: events, half: half) / 60))
        let substitutionMinutes = substitutions.filter { $0.half == half }.map(\.minute).max() ?? 0
        let minutes = max(eventMinutes, substitutionMinutes)
        return half == 0 ? max(1, minutes) : minutes
    }
}
