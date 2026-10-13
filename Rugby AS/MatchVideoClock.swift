//
//  MatchVideoClock.swift
//  Rugby AS
//
//  このアプリには時間が2種類ある。
//
//   1. 試合時計 … 記録が持っている「前半12:34」(StatEvent の half と seconds)
//   2. 動画の位置 … 動画ファイルの何秒目か
//
//  「前半12:34のプレーの映像を見る」には、この2つを行き来する必要がある。
//  その変換をここ1か所にまとめる。
//
//  変換に要るものは3つ:
//   ・ハーフの長さと中断時間 (MatchClockSettings。動画編集の「試合時間」で決める)
//   ・キックオフ合わせ (動画の何秒目が前半0:00/後半0:00か。MatchVideoAnchor)
//   ・その試合の動画ファイル (VideoStorage)
//
//  キックオフ合わせが未設定なら「動画の頭＝前半0:00」とみなす。
//  つまり何も設定していない試合は、これまでと同じ振る舞いになる。
//

import Foundation

// MARK: - 試合時計の設定(ハーフの長さと中断)

struct MatchClockSettings: Codable, Equatable {
    var firstHalfSeconds: Int
    var secondHalfSeconds: Int
    var stoppages: [MatchClockStop]
    // ハーフタイム(前半と後半のあいだ)の長さ。
    // 後から足した項目なので、古い保存データでは nil = 既定の60秒。
    var halfTimeSeconds: Int?

    static let standard = MatchClockSettings(
        firstHalfSeconds: 40 * 60,
        secondHalfSeconds: 40 * 60,
        stoppages: [],
        halfTimeSeconds: nil
    )

    static let defaultHalfTimeSeconds = 60

    var halfTimeDuration: Int {
        min(max(0, halfTimeSeconds ?? Self.defaultHalfTimeSeconds), 30 * 60)
    }

    func clockDuration(for half: Int) -> Int {
        half >= 1 ? secondHalfSeconds : firstHalfSeconds
    }

    mutating func setClockDuration(_ seconds: Int, for half: Int) {
        if half >= 1 {
            secondHalfSeconds = seconds
        } else {
            firstHalfSeconds = seconds
        }
        self = normalized()
    }

    func totalStoppageSeconds(for half: Int) -> Int {
        stoppages
            .filter { $0.half == normalizedHalf(half) }
            .reduce(0) { $0 + max(0, $1.durationSeconds) }
    }

    /// そのハーフが実時間で何秒あったか(時計の長さ + 中断の合計)
    func actualHalfTimelineDuration(for half: Int) -> Int {
        clockDuration(for: half) + totalStoppageSeconds(for: half)
    }

    func stoppagesForTimelineScope(_ half: Int?) -> [MatchClockStop] {
        stoppages
            .filter { stop in half == nil || stop.half == half }
            .sorted { lhs, rhs in
                if lhs.half != rhs.half { return lhs.half < rhs.half }
                if lhs.clockSecond != rhs.clockSecond { return lhs.clockSecond < rhs.clockSecond }
                return lhs.durationSeconds < rhs.durationSeconds
            }
    }

    /// 試合時計の秒 → そのハーフが始まってから実際に何秒経ったか
    func timelineSecond(forClockSecond clockSecond: Int, half: Int) -> Int {
        Int(timelineSecond(forClockSeconds: Double(clockSecond), half: half))
    }

    func timelineSecond(forClockSeconds clockSecond: Double, half: Int) -> Double {
        let half = normalizedHalf(half)
        let clampedClockSecond = min(max(0, clockSecond.isFinite ? clockSecond : 0), Double(clockDuration(for: half)))
        let stoppageSecondsBefore = stoppagesForTimelineScope(half)
            .filter { Double($0.clockSecond) < clampedClockSecond }
            .reduce(0) { $0 + max(0, $1.durationSeconds) }
        return clampedClockSecond + Double(stoppageSecondsBefore)
    }

    /// 上の逆向き(実際の経過秒 → 試合時計の秒)
    func clockSecond(fromTimelineSecond timelineSecond: Int, half: Int) -> Int {
        Int(clockSeconds(fromTimelineSecond: Double(timelineSecond), half: half).rounded())
    }

    func clockSeconds(fromTimelineSecond timelineSecond: Double, half: Int) -> Double {
        let half = normalizedHalf(half)
        let clampedTimelineSecond = min(max(0, timelineSecond.isFinite ? timelineSecond : 0), Double(actualHalfTimelineDuration(for: half)))
        var elapsedStoppageSeconds: Double = 0

        for stoppage in stoppagesForTimelineScope(half) {
            let stopStart = Double(stoppage.clockSecond) + elapsedStoppageSeconds
            let stopEnd = stopStart + Double(stoppage.durationSeconds)
            if clampedTimelineSecond < stopStart {
                return min(Double(clockDuration(for: half)), max(0, clampedTimelineSecond - elapsedStoppageSeconds))
            }
            if clampedTimelineSecond <= stopEnd {
                return Double(stoppage.clockSecond)
            }
            elapsedStoppageSeconds += Double(stoppage.durationSeconds)
        }

        return min(Double(clockDuration(for: half)), max(0, clampedTimelineSecond - elapsedStoppageSeconds))
    }

    func normalized() -> MatchClockSettings {
        let firstHalfSeconds = min(max(60, firstHalfSeconds), 80 * 60)
        let secondHalfSeconds = min(max(60, secondHalfSeconds), 80 * 60)
        let normalizedStoppages = stoppages.map { stoppage in
            let half = normalizedHalf(stoppage.half)
            let clockDuration = half == 0 ? firstHalfSeconds : secondHalfSeconds
            return MatchClockStop(
                id: stoppage.id,
                half: half,
                clockSecond: min(max(0, stoppage.clockSecond), clockDuration),
                durationSeconds: min(max(1, stoppage.durationSeconds), 20 * 60)
            )
        }
        .sorted { lhs, rhs in
            if lhs.half != rhs.half { return lhs.half < rhs.half }
            if lhs.clockSecond != rhs.clockSecond { return lhs.clockSecond < rhs.clockSecond }
            return lhs.durationSeconds < rhs.durationSeconds
        }

        // 既定(60秒)と同じなら持たない。そうしておくと「何も設定していない試合」と
        // 同じ扱いになり、保存も増えない。
        let normalizedHalfTime: Int? = halfTimeSeconds.map { min(max(0, $0), 30 * 60) }
        return MatchClockSettings(
            firstHalfSeconds: firstHalfSeconds,
            secondHalfSeconds: secondHalfSeconds,
            stoppages: normalizedStoppages,
            halfTimeSeconds: normalizedHalfTime == Self.defaultHalfTimeSeconds ? nil : normalizedHalfTime
        )
    }

    private func normalizedHalf(_ half: Int) -> Int {
        half >= 1 ? 1 : 0
    }
}

struct MatchClockStop: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var half: Int
    var clockSecond: Int
    var durationSeconds: Int
}

enum MatchClockStorage {
    private static let storageKey = "matchClockSettingsByMatchID"

    static func settings(for matchID: UUID) -> MatchClockSettings {
        settingsMap()[matchID.uuidString]?.normalized() ?? .standard
    }

    static func setSettings(_ settings: MatchClockSettings, for matchID: UUID) {
        var map = settingsMap()
        let normalizedSettings = settings.normalized()
        if normalizedSettings == .standard {
            map.removeValue(forKey: matchID.uuidString)
        } else {
            map[matchID.uuidString] = normalizedSettings
        }

        guard let data = try? JSONEncoder().encode(map) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private static func settingsMap() -> [String: MatchClockSettings] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let map = try? JSONDecoder().decode([String: MatchClockSettings].self, from: data) else {
            return [:]
        }
        return map
    }
}

// MARK: - キックオフ合わせ(動画の何秒目が0:00か)

struct MatchVideoAnchor: Codable, Equatable {
    /// どの動画ファイルか(1試合に複数本ある場合があるため)
    var fileName: String
    /// その動画の何秒目がキックオフか
    var seconds: Double
}

enum MatchVideoAnchorStorage {
    private static let storageKey = "matchVideoAnchorsByMatchID"

    /// キーは "0" = 前半, "1" = 後半
    static func anchors(for matchID: UUID) -> [Int: MatchVideoAnchor] {
        var result: [Int: MatchVideoAnchor] = [:]
        for (halfKey, anchor) in anchorMap()[matchID.uuidString] ?? [:] {
            if let half = Int(halfKey) { result[half] = anchor }
        }
        return result
    }

    static func anchor(half: Int, for matchID: UUID) -> MatchVideoAnchor? {
        anchors(for: matchID)[half >= 1 ? 1 : 0]
    }

    static func setAnchor(_ anchor: MatchVideoAnchor?, half: Int, for matchID: UUID) {
        var map = anchorMap()
        var halves = map[matchID.uuidString] ?? [:]
        let halfKey = String(half >= 1 ? 1 : 0)

        if let anchor {
            halves[halfKey] = MatchVideoAnchor(fileName: anchor.fileName, seconds: max(0, anchor.seconds))
        } else {
            halves.removeValue(forKey: halfKey)
        }

        if halves.isEmpty {
            map.removeValue(forKey: matchID.uuidString)
        } else {
            map[matchID.uuidString] = halves
        }
        save(map)
    }

    static func removeAnchors(for matchID: UUID) {
        var map = anchorMap()
        guard map.removeValue(forKey: matchID.uuidString) != nil else { return }
        save(map)
    }

    private static func anchorMap() -> [String: [String: MatchVideoAnchor]] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let map = try? JSONDecoder().decode([String: [String: MatchVideoAnchor]].self, from: data) else {
            return [:]
        }
        return map
    }

    private static func save(_ map: [String: [String: MatchVideoAnchor]]) {
        if map.isEmpty {
            UserDefaults.standard.removeObject(forKey: storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(map) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

// MARK: - 試合時計 ⇄ 動画の位置

struct MatchVideoClock {
    let settings: MatchClockSettings
    let videoNames: [String]
    private let storedAnchors: [Int: MatchVideoAnchor]

    init(matchID: UUID) {
        self.init(settings: MatchClockStorage.settings(for: matchID),
                  videoNames: VideoStorage.videoNames(for: matchID),
                  anchors: MatchVideoAnchorStorage.anchors(for: matchID))
    }

    init(settings: MatchClockSettings, videoNames: [String], anchors: [Int: MatchVideoAnchor]) {
        self.settings = settings.normalized()
        self.videoNames = videoNames
        self.storedAnchors = anchors.filter {
            videoNames.contains($0.value.fileName) && $0.value.seconds.isFinite && $0.value.seconds >= 0
        }
    }

    var hasVideo: Bool { !videoNames.isEmpty }

    /// 前半のキックオフを手で合わせてあるか(合わせていないと映像がズレる)
    var isKickoffAligned: Bool { storedAnchors[0] != nil }

    func storedAnchor(half: Int) -> MatchVideoAnchor? { storedAnchors[half >= 1 ? 1 : 0] }

    /// 実際に使うキックオフ位置。未設定なら見なし値を返す。
    func anchor(half: Int) -> MatchVideoAnchor? {
        let half = half >= 1 ? 1 : 0
        if let stored = storedAnchors[half] { return stored }
        guard let firstVideo = videoNames.first else { return nil }

        // 前半: 動画の頭がキックオフとみなす
        let firstHalfAnchor = storedAnchors[0] ?? MatchVideoAnchor(fileName: firstVideo, seconds: 0)
        if half == 0 { return firstHalfAnchor }

        // 後半: 同じ動画で前半の続きを撮っているとみなす
        let afterFirstHalf = firstHalfAnchor.seconds
            + Double(settings.actualHalfTimelineDuration(for: 0))
            + Double(settings.halfTimeDuration)
        return MatchVideoAnchor(fileName: firstHalfAnchor.fileName, seconds: afterFirstHalf)
    }

    /// 試合時計 → 動画のどこか
    func videoPosition(half: Int, seconds: Int) -> (fileName: String, at: Double)? {
        videoPosition(half: half, clockSeconds: Double(seconds))
    }

    func videoPosition(half: Int, clockSeconds: Double) -> (fileName: String, at: Double)? {
        guard let anchor = anchor(half: half) else { return nil }
        let elapsed = settings.timelineSecond(forClockSeconds: clockSeconds, half: half)
        return (anchor.fileName, max(0, anchor.seconds + elapsed))
    }

    /// 動画のどこか → 試合時計。ハーフの外(キックオフ前やハーフタイム)なら nil。
    func matchTime(fileName: String, at position: Double) -> (half: Int, seconds: Int)? {
        guard let time = preciseMatchTime(fileName: fileName, at: position) else { return nil }
        return (time.half, Int(time.seconds.rounded()))
    }

    func preciseMatchTime(fileName: String, at position: Double, preferredHalf: Int? = nil) -> (half: Int, seconds: Double)? {
        guard position.isFinite else { return nil }
        // 後半から先に見る(同じ動画で前半と後半が続いている場合、後ろが正解)
        let order = preferredHalf.map { $0 >= 1 ? [1, 0] : [0, 1] } ?? [1, 0]
        for half in order {
            guard let anchor = anchor(half: half), anchor.fileName == fileName else { continue }
            let elapsed = position - anchor.seconds
            guard elapsed >= 0,
                  elapsed <= Double(settings.actualHalfTimelineDuration(for: half)) else { continue }
            return (half, settings.clockSeconds(fromTimelineSecond: elapsed, half: half))
        }
        return nil
    }
}

// MARK: - 試合を消すときの後片づけ

// 試合削除時に、その試合の時計設定とキックオフ合わせを消す。
enum MatchClockSettingsCleanup {
    static func removeSettings(for matchID: UUID) {
        MatchClockStorage.setSettings(.standard, for: matchID)
        MatchVideoAnchorStorage.removeAnchors(for: matchID)
    }
}
