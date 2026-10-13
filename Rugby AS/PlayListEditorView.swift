//
//  PlayListEditorView.swift
//  Rugby AS
//
//  記録した全プレーを時系列に並べ、映像を見ながら直す画面。
//
//  ・行をタップ → そのプレーの場面から再生(端末の動画は3秒前から)
//  ・行の鉛筆   → 種類・チーム・選手・前後半・時刻・成否・起点を直す
//  ・＋        → いま映っている場面にプレーを足す(記録漏れの後入れ)
//  ・左スワイプ → 削除
//
//  時刻と映像の対応づけは MatchVideoClock に任せる。
//  動画が無い試合でも、リストだけで同じ編集ができる。
//

import AVFoundation
import SwiftData
import SwiftUI

// MARK: - プレーの種類

/// StatEvent の category / outcome の組み合わせを、画面で選べる1つの「種類」にまとめたもの。
/// (保存の形は変えず、見せ方だけ人が分かる単位にする)
enum PlayKind: String, CaseIterable, Identifiable {
    case possession
    case ballOutOfPlay
    case tryScore
    case conversion
    case penaltyGoal
    case dropGoal
    case penaltyTry
    case lineout
    case scrum
    case penalty

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .possession: return "ポゼッション"
        case .ballOutOfPlay: return "BIP(ボールが動いていない時間)"
        case .tryScore: return "トライ"
        case .conversion: return "コンバージョン"
        case .penaltyGoal: return "PG"
        case .dropGoal: return "DG"
        case .penaltyTry: return "認定トライ"
        case .lineout: return "ラインアウト"
        case .scrum: return "スクラム"
        case .penalty: return "反則"
        }
    }

    var shortName: String {
        switch self {
        case .possession: return "保持"
        case .ballOutOfPlay: return "BIP"
        case .tryScore: return "トライ"
        case .conversion: return "CONV"
        case .penaltyGoal: return "PG"
        case .dropGoal: return "DG"
        case .penaltyTry: return "認定T"
        case .lineout: return "LO"
        case .scrum: return "SCR"
        case .penalty: return "反則"
        }
    }

    /// 時間の幅を持つプレー(始まりと長さで記録する)
    var isInterval: Bool {
        self == .possession || self == .ballOutOfPlay
    }

    /// 成功/失敗を選べるプレー
    var hasResult: Bool {
        switch self {
        case .conversion, .penaltyGoal, .dropGoal, .lineout, .scrum: return true
        default: return false
        }
    }

    /// どちらのチームか を持てるプレー(BIP はどちらのものでもない)
    var allowsTeam: Bool { self != .ballOutOfPlay }

    /// 選手を紐づけられるプレー(得点のみ。既存の集計に合わせる)
    var allowsPlayer: Bool {
        switch self {
        case .tryScore, .conversion, .penaltyGoal, .dropGoal: return true
        default: return false
        }
    }

    /// 起点プレーを付けられるプレー(攻撃とトライ。既存の集計に合わせる)
    var allowsOrigin: Bool {
        self == .possession || self == .tryScore || self == .penaltyTry
    }

    var storageCategory: String {
        switch self {
        case .possession, .ballOutOfPlay: return "possession"
        case .tryScore: return "try"
        case .conversion: return "conversion"
        case .penaltyGoal: return "penalty_goal"
        case .dropGoal: return "drop_goal"
        case .penaltyTry: return ScoringRules.penaltyTryCategory
        case .lineout: return "lineout"
        case .scrum: return "scrum"
        case .penalty: return "penalty"
        }
    }

    /// 保存されている記録がどの種類かを判定する
    static func kind(for event: StatEvent) -> PlayKind? {
        switch event.category {
        case "possession": return event.outcome == "none" ? .ballOutOfPlay : .possession
        case "try": return .tryScore
        case "conversion": return .conversion
        case "penalty_goal": return .penaltyGoal
        case "drop_goal": return .dropGoal
        case ScoringRules.penaltyTryCategory: return .penaltyTry
        case "lineout": return .lineout
        case "scrum": return .scrum
        case "penalty": return .penalty
        default: return nil  // match_state など、画面に出さないもの
        }
    }
}

// MARK: - 一覧本体

struct PlayListEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Query private var teams: [Team]
    @Query private var matchEvents: [StatEvent]
    @Query private var matchPlayers: [Player]
    @Query private var matchLineups: [MatchLineup]

    let match: Match
    /// 開いた直後に選んでおくプレー(サマリーの行から飛んできたとき)
    let initialEventID: UUID?

    init(match: Match, initialEventID: UUID? = nil) {
        self.match = match
        self.initialEventID = initialEventID
        let matchID = match.id
        let homeID = match.homeTeamID
        let awayID = match.awayTeamID
        _matchEvents = Query(filter: #Predicate<StatEvent> { $0.matchID == matchID })
        _matchLineups = Query(filter: #Predicate<MatchLineup> { $0.matchID == matchID })
        _matchPlayers = Query(
            filter: #Predicate<Player> { $0.teamID == homeID || $0.teamID == awayID },
            sort: [SortDescriptor(\Player.number)]
        )
    }

    @State private var player: AVPlayer?
    @StateObject private var youTubePlayer = YouTubePlayerController()
    @State private var loadedFileName: String?
    @State private var currentSeconds: Double = 0
    @State private var isPlaying = false
    @State private var timeObserver: Any?
    @State private var selectedEventID: UUID?
    @State private var editingEvent: StatEvent?
    @State private var errorMessage: String?
    @State private var didJumpToInitialEvent = false
    @State private var isYouTubeLinkPresented = false
    @State private var playbackTask: Task<Void, Never>?

    private var clock: MatchVideoClock { MatchVideoClock(matchID: match.id) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                videoArea
                playList
            }
            .navigationTitle("プレーの編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        pausePlayback()
                        isYouTubeLinkPresented = true
                    } label: {
                        Label("YouTubeリンク", systemImage: "link")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        addPlayAtCurrentPosition()
                    } label: {
                        Label("追加", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $editingEvent) { event in
                PlayEditSheet(
                    event: event,
                    match: match,
                    teams: teams,
                    players: matchPlayers,
                    lineups: matchLineups,
                    currentMatchTime: currentMatchTime(),
                    onDelete: { delete(event) }
                )
            }
            .sheet(isPresented: $isYouTubeLinkPresented) {
                YouTubeLinkSheet { link in
                    addYouTubeVideo(link)
                }
            }
            .alert(
                "うまくいきませんでした",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .onAppear {
            configureYouTubeCallbacks()
            jumpToInitialEventIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { pausePlayback() }
        }
        .onDisappear { teardownPlayer() }
    }

    // MARK: - 映像

    @ViewBuilder
    private var videoArea: some View {
        if clock.hasVideo {
            VStack(spacing: 8) {
                if isYouTubeLoaded {
                    YouTubePlayerView(controller: youTubePlayer)
                        .frame(height: youTubePlayer.errorMessage == nil ? 220 : 330)
                } else {
                    ZStack {
                        Color.black
                        if let player {
                            TimelineVideoPlayerView(player: player)
                        } else {
                            Text("行をタップすると、その場面から再生します")
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                }

                HStack(spacing: 14) {
                    Button {
                        togglePlayback()
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                    }
                    .disabled(!hasLoadedVideo)

                    Button {
                        seek(to: currentSeconds - 5, autoplay: false)
                    } label: {
                        Image(systemName: "gobackward.5")
                    }
                    .disabled(!hasLoadedVideo)

                    Text(currentTimeLabel)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Spacer()
                }
                .padding(.horizontal, 16)

                if !clock.isKickoffAligned {
                    Text("キックオフ合わせが未設定です。映像がずれる場合は、動画編集の「キックオフ」で合わせてください。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.bottom, 8)
            .background(Color(.secondarySystemBackground))
        } else {
            Button {
                isYouTubeLinkPresented = true
            } label: {
                Label("YouTubeリンクを貼って映像を追加", systemImage: "link")
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .background(Color(.secondarySystemBackground))
        }
    }

    private var currentTimeLabel: String {
        guard let time = currentMatchTime() else {
            return "試合時間の外"
        }
        return halfLabel(time.half) + " " + timeText(time.seconds)
    }

    // MARK: - 一覧

    private var playList: some View {
        List {
            ForEach([0, 1], id: \.self) { half in
                let rows = plays.filter { $0.event.half == half }
                if !rows.isEmpty {
                    Section(halfLabel(half)) {
                        ForEach(rows, id: \.event.id) { row in
                            playRow(row)
                        }
                        .onDelete { offsets in
                            for index in offsets { delete(rows[index].event) }
                        }
                    }
                }
            }

            if plays.isEmpty {
                Text("まだ記録がありません。右上の＋で足せます。")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func playRow(_ row: (event: StatEvent, kind: PlayKind)) -> some View {
        HStack(spacing: 10) {
            Text(timeText(startSeconds(of: row.event, kind: row.kind)))
                .font(.subheadline.monospacedDigit())
                .frame(width: 52, alignment: .leading)

            RoundedRectangle(cornerRadius: 3)
                .fill(teamColor(row.event.teamID) ?? Color.secondary.opacity(0.4))
                .frame(width: 4, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.kind.shortName)
                        .font(.subheadline.weight(.semibold))
                    if row.kind.hasResult {
                        Text(row.event.outcome == "fail" ? "失敗" : "成功")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(row.event.outcome == "fail" ? .red : .green)
                    }
                    if row.kind.isInterval {
                        Text("\(max(1, row.event.seconds))秒")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(subtitle(for: row))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Button {
                pausePlayback()
                editingEvent = row.event
            } label: {
                Image(systemName: "pencil")
                    .foregroundStyle(.tint)
                    .frame(width: 34, height: 34)
            }
            // 行そのもののタップ(再生)と取り合わないよう、鉛筆は独立したボタンにする
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .listRowBackground(
            row.event.id == selectedEventID
                ? Color.accentColor.opacity(0.12)
                : Color(.secondarySystemGroupedBackground)
        )
        .onTapGesture {
            selectedEventID = row.event.id
            playFromStart(of: row.event, kind: row.kind)
        }
    }

    private func subtitle(for row: (event: StatEvent, kind: PlayKind)) -> String {
        var parts: [String] = []
        parts.append(teamName(row.event.teamID) ?? (row.kind.allowsTeam ? "チーム未設定" : "両チーム"))

        if let playerID = row.event.playerID,
           let player = matchPlayers.first(where: { $0.id == playerID }) {
            parts.append(MatchNumbering.label(for: player, matchID: match.id, lineups: matchLineups))
        } else if row.kind.allowsPlayer {
            parts.append("選手未設定")
        }

        if let origin = PlayOrigin.displayName(for: row.event.origin) {
            parts.append("起点: " + origin)
        }
        return parts.joined(separator: " ・ ")
    }

    /// 表示と再生に使う「そのプレーが始まった時刻」
    private func startSeconds(of event: StatEvent, kind: PlayKind) -> Int {
        if event.recordingDetails.timeBasis == .halfClock {
            return Int(max(0, TimelineEventTiming.start(of: event, isInterval: kind.isInterval)).rounded())
        }
        guard kind.isInterval else { return max(0, event.seconds) }
        return max(0, event.startSeconds ?? max(0, event.seconds - 58))
    }

    private var plays: [(event: StatEvent, kind: PlayKind)] {
        matchEvents
            .compactMap { event in
                guard let kind = PlayKind.kind(for: event) else { return nil }
                return (event: event, kind: kind)
            }
            .sorted { lhs, rhs in
                if lhs.event.half != rhs.event.half { return lhs.event.half < rhs.event.half }
                let lhsStart = startSeconds(of: lhs.event, kind: lhs.kind)
                let rhsStart = startSeconds(of: rhs.event, kind: rhs.kind)
                if lhsStart != rhsStart { return lhsStart < rhsStart }
                return lhs.kind.rawValue < rhs.kind.rawValue
            }
    }

    // MARK: - 再生

    private var isYouTubeLoaded: Bool {
        loadedFileName.flatMap(YouTubeVideoLink.videoID(forSourceName:)) != nil
    }

    private var hasLoadedVideo: Bool { player != nil || isYouTubeLoaded }

    private func playFromStart(of event: StatEvent, kind: PlayKind) {
        playbackTask?.cancel()
        playbackTask = Task { @MainActor in
            guard let position = await videoPosition(for: event, kind: kind), !Task.isCancelled else { return }
            load(fileName: position.fileName)
            let leadTime: Double = YouTubeVideoLink.videoID(forSourceName: position.fileName) == nil ? 3 : 0
            seek(to: position.at - leadTime, autoplay: true)
        }
    }

    private func videoPosition(for event: StatEvent, kind: PlayKind) async -> (fileName: String, at: Double)? {
        // Older timeline edits stored a position on the entire video strip.
        // Its coordinates include the 12-second gaps between source videos.
        if event.recordingDetails.timeBasis != .halfClock,
           let exactStart = event.startSecondsExact,
           event.durationSecondsExact != nil {
            let sources = clock.videoNames.filter { VideoStorage.isAvailable(named: $0) }
            let target = max(0, exactStart)
            var cursor: Double = 0
            for (index, source) in sources.enumerated() {
                guard !Task.isCancelled else { return nil }
                if index == sources.count - 1, target >= cursor {
                    return (source, target - cursor)
                }
                let duration: Double
                if let videoID = YouTubeVideoLink.videoID(forSourceName: source) {
                    guard let cachedDuration = YouTubeVideoLink.cachedDuration(videoID: videoID) else {
                        errorMessage = "動画の長さを確認できません。動画編集でYouTubeを一度読み込んでから、この場面を開いてください。"
                        return nil
                    }
                    duration = cachedDuration
                } else if let url = VideoStorage.url(named: source) {
                    let asset = AVURLAsset(url: url)
                    guard let loadedDuration = try? await asset.load(.duration), loadedDuration.seconds.isFinite else {
                        errorMessage = "動画の長さを確認できませんでした。動画編集でファイルを確認してください。"
                        return nil
                    }
                    duration = max(1, loadedDuration.seconds)
                } else {
                    continue
                }
                if cursor <= target, target <= cursor + duration {
                    return (source, target - cursor)
                }
                cursor += duration + 12
            }
            return nil
        }

        return clock.videoPosition(
            half: event.half,
            clockSeconds: TimelineEventTiming.start(of: event, isInterval: kind.isInterval)
        )
    }

    private func load(fileName: String) {
        guard loadedFileName != fileName else { return }
        teardownCurrentPlayer()
        if let videoID = YouTubeVideoLink.videoID(forSourceName: fileName) {
            loadedFileName = fileName
            configureYouTubeCallbacks()
            youTubePlayer.load(videoID: videoID)
            return
        }
        guard let url = VideoStorage.url(named: fileName) else {
            errorMessage = "この試合の動画ファイルが見つかりませんでした。"
            return
        }
        let newPlayer = AVPlayer(url: url)
        timeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { time in
            guard time.seconds.isFinite else { return }
            Task { @MainActor in currentSeconds = time.seconds }
        }
        player = newPlayer
        loadedFileName = fileName
    }

    private func seek(to seconds: Double, autoplay: Bool) {
        let target = max(0, seconds)
        if isYouTubeLoaded {
            youTubePlayer.seek(to: target, autoplay: autoplay)
            currentSeconds = target
            return
        }
        guard let player else { return }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentSeconds = target
        if autoplay {
            player.play()
            isPlaying = true
        }
    }

    private func togglePlayback() {
        if isYouTubeLoaded {
            if isPlaying { youTubePlayer.pause() } else { youTubePlayer.play() }
            return
        }
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    private func teardownPlayer() {
        playbackTask?.cancel()
        playbackTask = nil
        teardownCurrentPlayer()
    }

    private func pausePlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        player?.pause()
        youTubePlayer.pause()
        isPlaying = false
    }

    private func teardownCurrentPlayer() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player?.pause()
        player = nil
        youTubePlayer.stop()
        youTubePlayer.onTimeChange = nil
        youTubePlayer.onDurationChange = nil
        youTubePlayer.onPlaybackChange = nil
        youTubePlayer.onEnded = nil
        loadedFileName = nil
        isPlaying = false
    }

    private func configureYouTubeCallbacks() {
        youTubePlayer.onTimeChange = { seconds in
            guard isYouTubeLoaded else { return }
            currentSeconds = seconds
        }
        youTubePlayer.onPlaybackChange = { playing in
            guard isYouTubeLoaded else { return }
            isPlaying = playing
        }
        youTubePlayer.onEnded = { isPlaying = false }
        youTubePlayer.onDurationChange = { duration in
            guard let videoID = loadedFileName.flatMap(YouTubeVideoLink.videoID(forSourceName:)) else { return }
            YouTubeVideoLink.cacheDuration(duration, videoID: videoID)
        }
    }

    private func addYouTubeVideo(_ link: YouTubeVideoLink) {
        if !VideoStorage.videoNames(for: match.id).contains(link.sourceName) {
            VideoStorage.appendVideoNames([link.sourceName], for: match.id)
        }
        load(fileName: link.sourceName)
        seek(to: link.startSeconds, autoplay: true)
    }

    /// いま映っている場面が試合時計で何分何秒か(ハーフの外なら nil)
    private func currentMatchTime() -> (half: Int, seconds: Int)? {
        guard let loadedFileName else { return nil }
        return clock.matchTime(fileName: loadedFileName, at: currentSeconds)
    }

    private func jumpToInitialEventIfNeeded() {
        guard !didJumpToInitialEvent, let initialEventID else { return }
        didJumpToInitialEvent = true
        guard let row = plays.first(where: { $0.event.id == initialEventID }) else { return }
        selectedEventID = initialEventID
        playFromStart(of: row.event, kind: row.kind)
    }

    // MARK: - 追加と削除

    private func addPlayAtCurrentPosition() {
        pausePlayback()
        if hasLoadedVideo, currentMatchTime() == nil {
            errorMessage = "この場面は試合時間の外です。動画編集の「キックオフ」と「試合時間」を確認してください。"
            return
        }
        let time = currentMatchTime() ?? (half: 0, seconds: 0)
        let event = StatEvent(
            matchID: match.id,
            teamID: match.homeTeamID,
            category: PlayKind.tryScore.storageCategory,
            outcome: "success",
            seconds: time.seconds,
            half: time.half
        )
        var details = event.recordingDetails
        details.timeBasis = .halfClock
        event.recordingDetails = details
        modelContext.insert(event)
        do {
            try modelContext.save()
            selectedEventID = event.id
            // 種類やチームはこの場で直してもらう
            editingEvent = event
        } catch {
            modelContext.delete(event)
            errorMessage = "プレーを追加できませんでした。"
        }
    }

    private func delete(_ event: StatEvent) {
        if selectedEventID == event.id { selectedEventID = nil }
        modelContext.delete(event)
        do {
            try modelContext.save()
        } catch {
            errorMessage = "プレーを削除できませんでした。"
        }
    }

    // MARK: - 表示の小道具

    private func halfLabel(_ half: Int) -> String { half >= 1 ? "後半" : "前半" }

    private func timeText(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        return String(format: "%d:%02d", clamped / 60, clamped % 60)
    }

    private func teamName(_ teamID: UUID?) -> String? {
        guard let teamID else { return nil }
        return teams.first { $0.id == teamID }?.name
    }

    private func teamColor(_ teamID: UUID?) -> Color? {
        guard let teamID else { return nil }
        if let hex = teams.first(where: { $0.id == teamID })?.colorHex, let color = Color(hex: hex) {
            return color
        }
        return teamID == match.homeTeamID ? .blue : .red
    }
}

// MARK: - 1件を直す画面

private struct PlayEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let event: StatEvent
    let match: Match
    let teams: [Team]
    let players: [Player]
    let lineups: [MatchLineup]
    /// いま映っている場面の試合時計(映像から時刻を取り込むのに使う)
    let currentMatchTime: (half: Int, seconds: Int)?
    let onDelete: () -> Void

    @State private var kind: PlayKind = .possession
    @State private var teamID: UUID?
    @State private var playerID: UUID?
    @State private var half = 0
    @State private var minute = 0
    @State private var second = 0
    @State private var lengthSeconds = 30
    @State private var isSuccess = true
    @State private var originRaw: String?
    @State private var isPlayerSelectionPresented = false
    @State private var isDeleteConfirmPresented = false

    var body: some View {
        NavigationStack {
            Form {
                Section("種類") {
                    Picker("種類", selection: $kind) {
                        ForEach(PlayKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.menu)

                    if kind.hasResult {
                        Picker("結果", selection: $isSuccess) {
                            Text("成功").tag(true)
                            Text("失敗").tag(false)
                        }
                        .pickerStyle(.segmented)
                    }
                }

                if kind.allowsTeam {
                    Section("チーム") {
                        Picker("チーム", selection: $teamID) {
                            Text(teamName(match.homeTeamID)).tag(Optional(match.homeTeamID))
                            Text(teamName(match.awayTeamID)).tag(Optional(match.awayTeamID))
                            Text("未設定").tag(UUID?.none)
                        }
                        .pickerStyle(.segmented)
                    }
                }

                if kind.allowsPlayer {
                    Section("選手") {
                        Button {
                            isPlayerSelectionPresented = true
                        } label: {
                            LabeledContent("選手", value: playerLabel)
                        }
                    }
                }

                Section("時間") {
                    Picker("前半・後半", selection: $half) {
                        Text("前半").tag(0)
                        Text("後半").tag(1)
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Picker("分", selection: $minute) {
                            ForEach(0..<100, id: \.self) { Text("\($0)分").tag($0) }
                        }
                        .pickerStyle(.wheel)
                        .frame(maxWidth: .infinity, maxHeight: 110)
                        .clipped()

                        Picker("秒", selection: $second) {
                            ForEach(0..<60, id: \.self) { Text(String(format: "%02d秒", $0)).tag($0) }
                        }
                        .pickerStyle(.wheel)
                        .frame(maxWidth: .infinity, maxHeight: 110)
                        .clipped()
                    }

                    if let currentMatchTime {
                        Button("いま映っている場面の時刻にする（\(currentMatchTime.half >= 1 ? "後半" : "前半") \(currentMatchTime.seconds / 60):\(String(format: "%02d", currentMatchTime.seconds % 60))）") {
                            half = currentMatchTime.half
                            minute = currentMatchTime.seconds / 60
                            second = currentMatchTime.seconds % 60
                        }
                    }

                    if kind.isInterval {
                        Stepper("長さ \(lengthSeconds)秒", value: $lengthSeconds, in: 1...1800, step: 5)
                    }
                }

                if kind.allowsOrigin {
                    Section("起点プレー") {
                        Picker("起点", selection: $originRaw) {
                            Text("なし").tag(String?.none)
                            ForEach(PlayOrigin.allCases) { origin in
                                Text(origin.displayName).tag(Optional(origin.rawValue))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                Section {
                    Button("このプレーを削除", role: .destructive) {
                        isDeleteConfirmPresented = true
                    }
                }
            }
            .navigationTitle("プレーを直す")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("やめる") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $isPlayerSelectionPresented) {
                PlayerSelectionSheet(
                    players: candidatePlayers,
                    title: "選手を選ぶ",
                    numberFor: { MatchNumbering.number(for: $0, matchID: match.id, lineups: lineups) }
                ) { player in
                    playerID = player?.id
                    isPlayerSelectionPresented = false
                }
            }
            .confirmationDialog(
                "このプレーを削除しますか？",
                isPresented: $isDeleteConfirmPresented,
                titleVisibility: .visible
            ) {
                Button("削除する", role: .destructive) {
                    onDelete()
                    dismiss()
                }
                Button("やめる", role: .cancel) {}
            }
        }
        .onAppear { loadFromEvent() }
    }

    private var candidatePlayers: [Player] {
        guard let teamID else { return players }
        return players.filter { $0.teamID == teamID }
    }

    private var playerLabel: String {
        guard let playerID, let player = players.first(where: { $0.id == playerID }) else {
            return "未設定"
        }
        return MatchNumbering.label(for: player, matchID: match.id, lineups: lineups)
    }

    private func teamName(_ id: UUID) -> String {
        teams.first { $0.id == id }?.name ?? (id == match.homeTeamID ? "HOME" : "AWAY")
    }

    private func loadFromEvent() {
        let kind = PlayKind.kind(for: event) ?? .possession
        self.kind = kind
        teamID = event.teamID
        playerID = event.playerID
        half = event.half >= 1 ? 1 : 0
        isSuccess = event.outcome != "fail"
        originRaw = event.origin

        let start = kind.isInterval
            ? max(0, event.startSeconds ?? max(0, event.seconds - 58))
            : max(0, event.seconds)
        minute = min(99, start / 60)
        second = start % 60
        lengthSeconds = kind.isInterval ? max(1, event.seconds) : 30
    }

    private func save() {
        let start = minute * 60 + second

        event.category = kind.storageCategory
        event.half = half
        event.origin = kind.allowsOrigin ? originRaw : nil
        event.playerID = kind.allowsPlayer ? playerID : nil

        switch kind {
        case .ballOutOfPlay:
            event.teamID = nil
            event.outcome = "none"
        case .possession:
            event.teamID = teamID
            event.outcome = "own"
        case .penalty:
            event.teamID = teamID
            event.outcome = "conceded"
        default:
            event.teamID = teamID
            event.outcome = kind.hasResult ? (isSuccess ? "success" : "fail") : "success"
        }

        if kind.isInterval {
            event.startSeconds = start
            event.seconds = max(1, lengthSeconds)
        } else {
            event.startSeconds = nil
            event.seconds = start
        }
        // ここで時刻を入れ直したら、動画タイムラインで付いた 0.1 秒きざみの控えは
        // 古い位置を指したままになるので消す(秒の値を正とする)
        event.startSecondsExact = nil
        event.durationSecondsExact = nil
        var details = event.recordingDetails
        details.timeBasis = .halfClock
        event.recordingDetails = details

        AppPersistence.save(modelContext)
    }
}
