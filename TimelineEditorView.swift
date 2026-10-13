//
//  TimelineEditorView.swift
//  Rugby AS
//
//  Created by Codex on 2026/05/29.
//

import AVFoundation
import Combine
import CoreTransferable
import PhotosUI
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct TimelineEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel: TimelineEditorViewModel
    @State private var selectedVideoItems: [PhotosPickerItem] = []
    @State private var isVideoImporting = false
    @State private var videoImportProgress: Double = 0
    @State private var editorErrorMessage: String?
    @State private var didLoadStoredVideos = false
    @State private var didLoadStoredEvents = false
    @State private var representedEventIDs: Set<UUID> = []
    @StateObject private var youtubePlayer = YouTubePlayerController()
    @State private var isYouTubeLinkPresented = false
    @State private var videoPlayer: AVPlayer?
    @State private var activeVideoSegmentID: UUID?
    @State private var playbackTimeObserver: Any?
    @State private var videoEndObserver: NSObjectProtocol?
    @State private var isScrubbingTimeline = false
    // スクラブ(指でのシーク)中は、動画へのシーク要求を間引いて軽くする
    @State private var pendingScrubSeekTime: Double?
    @State private var isScrubSeekInFlight = false
    @State private var isMatchClockSettingsPresented = false
    @State private var isKickoffAnchorPresented = false
    @State private var isHighlightExportPresented = false
    @State private var matchClockSettings: MatchClockSettings = .standard
    // キックオフ合わせ(動画の何秒目が前半/後半の0:00か)。0=前半, 1=後半。
    @State private var kickoffAnchors: [Int: MatchVideoAnchor] = [:]
    // トラック連続再生: 選択中の行と、再生する区間のリスト・現在位置
    // 下の記録ボタンを出すかどうか。畳むとタイムラインがその分広くなる。
    // 次に開いたときも同じ状態にしたいので端末に覚えさせる。
    @AppStorage("timelineToolPaletteVisible") private var isToolPaletteVisible = true
    @State private var selectedPlaybackTrack: TimelineTrackType?
    @State private var playbackQueue: [(start: Double, end: Double)] = []
    @State private var playbackQueueIndex = 0

    let match: Match?

    init(match: Match? = nil) {
        self.match = match
        _viewModel = StateObject(wrappedValue: TimelineEditorViewModel.empty())
    }

    init(match: Match? = nil, viewModel: TimelineEditorViewModel) {
        self.match = match
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    private var isYouTubeActive: Bool {
        guard let name = viewModel.videoSegment(id: activeVideoSegmentID)?.fileName else { return false }
        return YouTubeVideoLink.videoID(forSourceName: name) != nil
    }

    // Keep app actions outside the YouTube player so its controls remain usable.
    private func videoPreview(height videoHeight: CGFloat) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 16) {
                PhotosPicker(selection: $selectedVideoItems, maxSelectionCount: 8, matching: .videos) {
                    Label("動画追加", systemImage: "plus")
                }
                Button { isYouTubeLinkPresented = true } label: {
                    Label("YouTubeリンク", systemImage: "link")
                }
                .accessibilityIdentifier("addYouTubeLink")
                Spacer(minLength: 0)
                if viewModel.selectedVideoSegmentID != nil {
                    Button(role: .destructive) { deleteSelectedTimelineItem() } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("選択した動画を外す")
                }
            }
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .frame(height: 34)
            .disabled(isVideoImporting)

            if isVideoImporting {
                ProgressView("読み込み中", value: videoImportProgress)
            }
            if isYouTubeActive {
                YouTubePlayerView(controller: youtubePlayer)
            } else {
                VideoPreviewCard(
                    videoSegments: viewModel.videoSegments,
                    player: videoPlayer,
                    selectedVideoSegmentID: viewModel.selectedVideoSegmentID
                )
            }
        }
        .frame(height: videoHeight)
    }

    var body: some View {
        GeometryReader { proxy in
            let topPadding = max(58, min(proxy.safeAreaInsets.top + 10, 86))
            let bottomPadding = max(proxy.safeAreaInsets.bottom, 8)
            let availableHeight = max(0, proxy.size.height - topPadding - bottomPadding)
            let verticalSpacing: CGFloat = 40
            // 記録ボタンを出しているときと畳んだときの高さ
            let expandedPaletteHeight: CGFloat = 144
            let collapsedPaletteHeight: CGFloat = 44
            let paletteHeight: CGFloat = isToolPaletteVisible ? expandedPaletteHeight : collapsedPaletteHeight
            // 高さの基準は常に「ボタンを出している状態」で決める。
            // こうするとヘッダー・動画・再生バー・タイムラインの上端は畳んでも動かず、
            // 畳んで空いた分だけタイムラインが下へ伸びる(下に隠れていた行が見える)。
            let fixedHeight: CGFloat = 54 + 58 + expandedPaletteHeight + verticalSpacing
            let minimumTimelineHeight: CGFloat = 42 + (48 * 4)
            let widthBasedVideoHeight = proxy.size.width * 0.58
            let heightBasedVideoHeight = availableHeight * 0.38
            let videoHeight = min(max(min(widthBasedVideoHeight, heightBasedVideoHeight), 280), 390)
            let baseTimelineHeight = max(minimumTimelineHeight, availableHeight - fixedHeight - videoHeight)
            let timelineHeight = baseTimelineHeight + (expandedPaletteHeight - paletteHeight)

            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.00, green: 0.02, blue: 0.06),
                        Color(red: 0.02, green: 0.09, blue: 0.18),
                        Color(red: 0.00, green: 0.16, blue: 0.30)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(spacing: 10) {
                    TimelineHeaderView(
                        onBack: { dismiss() },
                        onExport: {
                            // 書き出し中に映像が動いていると紛らわしいので止める
                            pausePlayback()
                            viewModel.isPlaying = false
                            isHighlightExportPresented = true
                        }
                    )

                    videoPreview(height: videoHeight)

                    PlaybackControlBar(
                        currentVideoTime: viewModel.currentVideoTime,
                        videoDuration: viewModel.videoDuration,
                        isPlaying: viewModel.isPlaying,
                        canUndo: viewModel.canUndo,
                        canRedo: viewModel.canRedo,
                        onPlayPause: { toggleVideoPlayback() },
                        onUndo: {
                            viewModel.undo()
                            persistTimelineStateToStorage()
                            loadMatchSegments()
                            configurePlayerForSelectedVideo(autoplay: false)
                        },
                        onRedo: {
                            viewModel.redo()
                            persistTimelineStateToStorage()
                            loadMatchSegments()
                            configurePlayerForSelectedVideo(autoplay: false)
                        }
                    )

                    TimelineTracksView(
                        viewModel: viewModel,
                        isScrubbingTimeline: $isScrubbingTimeline,
                        selectedPlaybackTrack: selectedPlaybackTrack,
                        onSelectVideoSegment: { segment in
                            selectVideoSegment(segment, autoplay: false)
                        },
                        onTrackLabelTap: { trackType in
                            toggleSequentialPlayback(for: trackType)
                        },
                        onAdjustSelectedStart: { delta in
                            adjustSelectedClipStart(by: delta)
                        },
                        onAdjustSelectedEnd: { delta in
                            adjustSelectedClipEnd(by: delta)
                        },
                        onMoveSelected: { delta in
                            moveSelectedClip(by: delta)
                        },
                        onMatchSegmentDrag: { mode, delta in
                            switch viewModel.selectedMatchSelection {
                            case .half:
                                // ハーフは右端だけ(試合時間の調整)
                                guard mode == .end else { return }
                                adjustSelectedHalfLength(by: delta)
                            case .halfTime:
                                // ハーフタイムも右端だけ(後半の始まりが動く)
                                guard mode == .end else { return }
                                adjustHalfTime(by: delta)
                            case .stoppage:
                                adjustSelectedStoppage(mode: mode, delta: delta)
                            case nil:
                                break
                            }
                        },
                        onTimelineTimeChanged: { time in
                            scrubTimeline(to: time)
                        }
                    )
                        .frame(height: timelineHeight)

                    TimelineEditToolbarView(
                        showsMatchButtons: match != nil,
                        hasKickoffAnchor: kickoffAnchors[0] != nil,
                        canSplit: viewModel.splitTargetClip(at: viewModel.currentVideoTime) != nil,
                        isPaletteVisible: $isToolPaletteVisible,
                        onKickoff: { pausePlayback(); isKickoffAnchorPresented = true },
                        onClockSettings: { isMatchClockSettingsPresented = true },
                        onSplit: { splitClipAtPlayhead() }
                    )

                    if isToolPaletteVisible {
                        BottomToolPaletteView(
                            viewModel: viewModel,
                            isVisible: $isToolPaletteVisible
                        ) { tool in
                            handleToolTap(tool)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, topPadding)
                .padding(.bottom, bottomPadding)
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
        .task {
            await loadPracticalDataIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { pausePlayback(); viewModel.isPlaying = false }
        }
        .onChange(of: isYouTubeLinkPresented) { _, presented in
            if presented { pausePlayback(); viewModel.isPlaying = false }
        }
        .onChange(of: selectedVideoItems) { _, items in
            importSelectedVideos(items)
        }
        .onChange(of: isScrubbingTimeline) { _, isScrubbing in
            // 指を離した瞬間に1回だけ、正確な位置へシークし直す
            guard !isScrubbing else { return }
            pendingScrubSeekTime = nil
            seekPlayerToCurrentTime(selectingSegmentAtCurrentTime: true)
        }
        .sheet(isPresented: $isYouTubeLinkPresented) {
            YouTubeLinkSheet { addYouTubeVideo($0) }
        }
        .sheet(isPresented: $isMatchClockSettingsPresented) {
            if let match {
                let position = matchClockSettingsPosition()
                MatchClockSettingsSheet(
                    initialSettings: matchClockSettings,
                    currentTimelineSecond: position.timelineSecond,
                    currentHalf: position.half,
                    secondHalfTimelineOffset: position.secondHalfTimelineOffset,
                    onSave: { settings in
                        matchClockSettings = settings.normalized()
                        MatchClockStorage.setSettings(matchClockSettings, for: match.id)
                        loadMatchSegments()
                        reloadStoredEvents()
                    }
                )
                .presentationDetents([.large])
            }
        }
        .sheet(isPresented: $isKickoffAnchorPresented) {
            if let match {
                MatchKickoffAnchorSheet(
                    currentPosition: currentVideoAnchor(),
                    anchors: kickoffAnchors,
                    onSet: { half, anchor in
                        MatchVideoAnchorStorage.setAnchor(anchor, half: half, for: match.id)
                        kickoffAnchors = MatchVideoAnchorStorage.anchors(for: match.id)
                        reloadStoredEvents()
                    }
                )
                .presentationDetents([.medium])
            }
        }
        .sheet(isPresented: $isHighlightExportPresented) {
            HighlightExportSheet(
                clips: viewModel.timelineClips,
                videoSegments: viewModel.videoSegments
            )
        }
        .alert("操作できませんでした", isPresented: Binding(
            get: { editorErrorMessage != nil },
            set: { if !$0 { editorErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { editorErrorMessage = nil }
        } message: {
            Text(editorErrorMessage ?? "")
        }
        .onDisappear {
            removePlaybackObserver()
            pausePlayback()
            youtubePlayer.stop()
        }
    }

    private func loadPracticalDataIfNeeded() async {
        loadMatchSegments()
        await loadStoredVideosIfNeeded()
        loadStoredEventsIfNeeded()
        configurePlayerForSelectedVideo(autoplay: false)
    }

    private var videoTimeline: MatchVideoTimeline {
        let videos = viewModel.videoSegments.compactMap { segment -> MatchTimelineVideoRange? in
            guard let fileName = segment.fileName else { return nil }
            return .init(fileName: fileName, start: segment.startTime, end: segment.endTime)
        }
        let names = match.map { VideoStorage.preservingMissingNames(edited: videos.map(\.fileName), stored: VideoStorage.videoNames(for: $0.id)) }
            ?? videos.map(\.fileName)
        let clock = MatchVideoClock(settings: matchClockSettings, videoNames: names, anchors: kickoffAnchors)
        return MatchVideoTimeline(clock: clock, videos: videos)
    }

    private func reloadStoredEvents(resetHistory: Bool = true) {
        didLoadStoredEvents = false
        loadStoredEventsIfNeeded()
        // Earlier snapshots use the previous video coordinates.
        if resetHistory {
            viewModel.undoStack = []
            viewModel.redoStack = []
        }
    }

    private func loadStoredEventsIfNeeded() {
        guard !didLoadStoredEvents, let match else { return }
        didLoadStoredEvents = true

        do {
            let matchID = match.id
            var descriptor = FetchDescriptor<StatEvent>(
                predicate: #Predicate<StatEvent> { event in
                    event.matchID == matchID
                }
            )
            descriptor.sortBy = [
                SortDescriptor(\.half),
                SortDescriptor(\.seconds)
            ]
            let events = try modelContext.fetch(descriptor)
            let clips = events.compactMap { timelineClip(from: $0, match: match) }
            representedEventIDs = Set(clips.map(\.id))
            viewModel.setTimelineClips(clips)
        } catch {
            editorErrorMessage = "イベントを読み込めませんでした。"
        }
    }

    private func loadMatchSegments() {
        guard let match else {
            matchClockSettings = .standard
            kickoffAnchors = [:]
            viewModel.setMatchSegments([])
            return
        }

        let settings = MatchClockStorage.settings(for: match.id).normalized()
        matchClockSettings = settings
        kickoffAnchors = MatchVideoAnchorStorage.anchors(for: match.id)
        let breakDuration = Double(settings.halfTimeDuration)
        let firstSegments = makeMatchSegments(
            settings: settings,
            half: 0,
            halfType: .first,
            timelineStart: 0
        )
        let secondStart = Double(settings.actualHalfTimelineDuration(for: 0)) + breakDuration
        let secondSegments = makeMatchSegments(
            settings: settings,
            half: 1,
            halfType: .second,
            timelineStart: secondStart
        )
        var segments = firstSegments
        if breakDuration > 0, let firstEnd = firstSegments.map(\.endTime).max() {
            segments.append(
                MatchSegment(
                    id: halfTimeSegmentID,
                    halfType: .first,
                    startTime: firstEnd,
                    endTime: firstEnd + breakDuration,
                    displayLabel: "ハーフタイム \(TimelineTimeFormat.duration(breakDuration))",
                    selectionKey: .halfTime,
                    isHalfTime: true
                )
            )
        }
        segments += secondSegments
        viewModel.setMatchSegments(segments)
        if let latestMatchTime = segments.map(\.endTime).max(), viewModel.videoSegments.isEmpty {
            viewModel.videoDuration = max(viewModel.videoDuration, latestMatchTime)
        }
    }

    private func makeMatchSegments(
        settings: MatchClockSettings,
        half: Int,
        halfType: MatchHalfType,
        timelineStart: Double
    ) -> [MatchSegment] {
        let clockDuration = settings.clockDuration(for: half)
        let halfTimelineDuration = settings.actualHalfTimelineDuration(for: half)
        let stops = settings.stoppagesForTimelineScope(half)
        var cursor = 0
        var segments: [MatchSegment] = []

        for stoppage in stops {
            let stopStart = settings.timelineSecond(forClockSecond: stoppage.clockSecond, half: half)
            if stopStart > cursor {
                segments.append(
                    makeMatchSegment(
                        halfType: halfType,
                        timelineStart: timelineStart,
                        localStart: cursor,
                        localEnd: stopStart,
                        clockDuration: clockDuration,
                        isFirstSegmentInHalf: segments.isEmpty
                    )
                )
            }
            let stopEnd = stopStart + max(1, stoppage.durationSeconds)
            segments.append(
                MatchSegment(
                    id: stoppage.id,
                    halfType: halfType,
                    startTime: timelineStart + Double(stopStart),
                    endTime: timelineStart + Double(stopEnd),
                    displayLabel: "中断 \(TimelineTimeFormat.duration(Double(max(1, stoppage.durationSeconds))))",
                    selectionKey: .stoppage(stoppage.id),
                    isStoppage: true
                )
            )
            cursor = max(cursor, stopEnd)
        }

        if halfTimelineDuration > cursor {
            segments.append(
                makeMatchSegment(
                    halfType: halfType,
                    timelineStart: timelineStart,
                    localStart: cursor,
                    localEnd: halfTimelineDuration,
                    clockDuration: clockDuration,
                    isFirstSegmentInHalf: segments.isEmpty
                )
            )
        }

        if segments.isEmpty {
            segments.append(
                makeMatchSegment(
                    halfType: halfType,
                    timelineStart: timelineStart,
                    localStart: 0,
                    localEnd: max(1, halfTimelineDuration),
                    clockDuration: clockDuration,
                    isFirstSegmentInHalf: true
                )
            )
        }

        // そのハーフの最後の「試合が動いている帯」に印を付ける。
        // その右端を引くと、ハーフの長さが変わる。
        if let lastPlayIndex = segments.lastIndex(where: { !$0.isStoppage }) {
            segments[lastPlayIndex].isHalfEnd = true
        }

        return segments
    }

    private func makeMatchSegment(
        halfType: MatchHalfType,
        timelineStart: Double,
        localStart: Int,
        localEnd: Int,
        clockDuration: Int,
        isFirstSegmentInHalf: Bool
    ) -> MatchSegment {
        MatchSegment(
            id: UUID(),
            halfType: halfType,
            startTime: timelineStart + Double(localStart),
            endTime: timelineStart + Double(localEnd),
            displayLabel: isFirstSegmentInHalf
                ? "\(TimelineTimeFormat.duration(Double(clockDuration)))\n(\(halfType.title))"
                : halfType.title,
            selectionKey: .half(halfType == .first ? 0 : 1)
        )
    }

    // MARK: - 試合時間・ハーフタイム・中断を、帯を引いて編集する

    // ハーフタイムの帯のid(毎回作り直すので固定値にしておく)
    private var halfTimeSegmentID: UUID {
        UUID(uuidString: "00000000-0000-0000-0000-00000000A1F0") ?? UUID()
    }

    /// ハーフタイムの長さを変える(帯の右端を引いたとき)
    private func adjustHalfTime(by delta: Double) {
        var settings = matchClockSettings
        let current = settings.halfTimeDuration
        let updated = min(max(0, current + Int(delta.rounded())), 30 * 60)
        guard updated != current else { return }
        settings.halfTimeSeconds = updated
        applyClockSettings(settings)
    }

    /// 再生ヘッドの位置を「後半のキックオフ」にする(=ハーフタイムの長さを決める)
    private func setHalfTimeAtPlayhead() {
        guard match != nil else {
            editorErrorMessage = "試合情報がないため、ハーフタイムを設定できません。"
            return
        }

        let firstHalfEnd = viewModel.matchSegments
            .filter { $0.halfType == .first && !$0.isHalfTime }
            .map(\.endTime)
            .max() ?? 0

        let time = viewModel.currentVideoTime
        guard time > firstHalfEnd else {
            editorErrorMessage = "前半の終わりより後ろ(後半のキックオフの位置)に再生ヘッドを置いてから押してください。"
            return
        }

        var settings = matchClockSettings
        settings.halfTimeSeconds = min(Int((time - firstHalfEnd).rounded()), 30 * 60)
        applyClockSettings(settings)
        viewModel.selectMatchSelection(.halfTime)
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    /// そのハーフの帯が、タイムラインの何秒から始まっているか
    private func halfTimelineStart(for half: Int) -> Double? {
        let halfType: MatchHalfType = half >= 1 ? .second : .first
        return viewModel.matchSegments
            .filter { $0.halfType == halfType }
            .map(\.startTime)
            .min()
    }

    /// 設定を保存して帯を作り直す(選んでいたものはそのまま選び直す)
    private func applyClockSettings(_ settings: MatchClockSettings) {
        guard let match else { return }
        let normalized = settings.normalized()
        matchClockSettings = normalized
        MatchClockStorage.setSettings(normalized, for: match.id)
        let keep = viewModel.selectedMatchSelection
        loadMatchSegments()
        reloadStoredEvents()
        viewModel.selectMatchSelection(keep)
    }

    /// ハーフの長さを変える(最後の帯の右端を引いたとき)
    private func adjustSelectedHalfLength(by delta: Double) {
        guard case .half(let half)? = viewModel.selectedMatchSelection else { return }
        var settings = matchClockSettings
        let current = settings.clockDuration(for: half)
        let updated = current + Int(delta.rounded())
        guard updated != current else { return }
        settings.setClockDuration(updated, for: half)
        applyClockSettings(settings)
    }

    /// 中断を動かす・伸ばす
    private func adjustSelectedStoppage(mode: ClipDragMode, delta: Double) {
        guard case .stoppage(let id)? = viewModel.selectedMatchSelection,
              let segment = viewModel.selectedMatchSegment(),
              let index = matchClockSettings.stoppages.firstIndex(where: { $0.id == id }) else { return }

        var settings = matchClockSettings
        let stoppage = settings.stoppages[index]
        let half = stoppage.half >= 1 ? 1 : 0
        guard let halfStart = halfTimelineStart(for: half) else { return }

        switch mode {
        case .move:
            let newStart = max(halfStart, segment.startTime + delta)
            settings.stoppages[index].clockSecond = clockSecond(
                forTimelineStart: newStart,
                half: half,
                halfStart: halfStart,
                excluding: index,
                in: settings
            )
        case .start:
            // 左端を動かす: 始まりだけ動いて、終わりはそのまま
            let newStart = min(max(halfStart, segment.startTime + delta), segment.endTime - 1)
            settings.stoppages[index].durationSeconds = max(1, Int((segment.endTime - newStart).rounded()))
            settings.stoppages[index].clockSecond = clockSecond(
                forTimelineStart: newStart,
                half: half,
                halfStart: halfStart,
                excluding: index,
                in: settings
            )
        case .end:
            let newEnd = max(segment.startTime + 1, segment.endTime + delta)
            settings.stoppages[index].durationSeconds = max(1, Int((newEnd - segment.startTime).rounded()))
        }

        applyClockSettings(settings)
    }

    /// 「タイムラインのこの位置」を、その中断を除いた試合時計の秒に直す
    private func clockSecond(
        forTimelineStart start: Double,
        half: Int,
        halfStart: Double,
        excluding index: Int,
        in settings: MatchClockSettings
    ) -> Int {
        var withoutSelf = settings
        withoutSelf.stoppages.remove(at: index)
        let local = Int(max(0, start - halfStart).rounded())
        return withoutSelf.clockSecond(fromTimelineSecond: local, half: half)
    }

    /// 再生ヘッドの位置に中断を1つ足す
    private func addStoppageAtPlayhead() {
        guard match != nil else {
            editorErrorMessage = "試合情報がないため、中断を追加できません。"
            return
        }

        let time = viewModel.currentVideoTime
        guard let segment = viewModel.matchSegments.first(where: {
            !$0.isStoppage && $0.startTime <= time && time <= $0.endTime
        }) else {
            editorErrorMessage = "再生ヘッドを前半または後半の帯の中に置いてから「中断」を押してください。"
            return
        }

        let half = segment.halfType == .first ? 0 : 1
        guard let halfStart = halfTimelineStart(for: half) else { return }

        var settings = matchClockSettings
        let local = Int(max(0, time - halfStart).rounded())
        let clock = settings.clockSecond(fromTimelineSecond: local, half: half)
        let stoppage = MatchClockStop(half: half, clockSecond: clock, durationSeconds: 60)
        settings.stoppages.append(stoppage)
        matchClockSettings = settings.normalized()
        if let match {
            MatchClockStorage.setSettings(matchClockSettings, for: match.id)
        }
        loadMatchSegments()
        viewModel.selectMatchSelection(.stoppage(stoppage.id))
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    /// 選んでいる中断を消す(ハーフタイムなら0にする)
    private func deleteSelectedStoppage() -> Bool {
        switch viewModel.selectedMatchSelection {
        case .stoppage(let id):
            var settings = matchClockSettings
            settings.stoppages.removeAll { $0.id == id }
            viewModel.selectMatchSelection(nil)
            applyClockSettings(settings)
            return true
        case .halfTime:
            var settings = matchClockSettings
            settings.halfTimeSeconds = 0
            viewModel.selectMatchSelection(nil)
            applyClockSettings(settings)
            return true
        default:
            return false
        }
    }

    private func matchClockSettingsPosition() -> (half: Int?, timelineSecond: Double, secondHalfTimelineOffset: Int) {
        let secondHalfStart = viewModel.matchSegments
            .filter { $0.halfType == .second }
            .map(\.startTime)
            .min() ?? 0

        if let first = viewModel.matchSegments.first(where: {
            $0.halfType == .first && $0.startTime <= viewModel.currentVideoTime && viewModel.currentVideoTime <= $0.endTime
        }) {
            return (0, max(0, viewModel.currentVideoTime - first.startTime), Int(secondHalfStart.rounded()))
        }

        if let second = viewModel.matchSegments.first(where: {
            $0.halfType == .second && $0.startTime <= viewModel.currentVideoTime && viewModel.currentVideoTime <= $0.endTime
        }) {
            return (1, max(0, viewModel.currentVideoTime - second.startTime), Int(secondHalfStart.rounded()))
        }

        return (nil, viewModel.currentVideoTime, Int(secondHalfStart.rounded()))
    }

    /// いま画面に映っている位置を「動画ファイル名 + その動画の何秒目か」で返す。
    /// タイムラインは複数本の動画を1本の帯に並べているので、帯の位置から引き算して出す。
    private func currentVideoAnchor() -> (anchor: MatchVideoAnchor, sourceName: String)? {
        let time = viewModel.currentVideoTime
        let segment = viewModel.videoSegments.first {
            $0.fileName != nil && $0.startTime <= time && time <= $0.endTime
        } ?? viewModel.videoSegment(id: viewModel.selectedVideoSegmentID)

        guard let segment, let fileName = segment.fileName else { return nil }
        let local = min(max(0, time - segment.startTime), max(0, segment.endTime - segment.startTime))
        return (MatchVideoAnchor(fileName: fileName, seconds: local), segment.sourceName)
    }

    private func handleToolTap(_ tool: TimelineTrackType) {
        if tool == .deleteTool {
            deleteSelectedTimelineItem()
            return
        }

        if tool == .stoppage {
            addStoppageAtPlayhead()
            return
        }

        if tool == .halfTime {
            setHalfTimeAtPlayhead()
            return
        }

        guard let match else {
            editorErrorMessage = "試合情報がないため、イベントを保存できません。"
            return
        }

        guard let event = makeStatEvent(for: tool, match: match) else { return }
        modelContext.insert(event)

        do {
            try modelContext.save()
            if let clip = timelineClip(from: event, match: match) {
                representedEventIDs.insert(event.id)
                viewModel.appendPersistedClip(clip)
            }
        } catch {
            modelContext.delete(event)
            editorErrorMessage = "イベントを保存できませんでした。"
        }
    }

    private func makeStatEvent(for tool: TimelineTrackType, match: Match) -> StatEvent? {
        guard let time = videoTimeline.time(at: viewModel.currentVideoTime) else {
            editorErrorMessage = "この位置は試合時間の外です。キックオフ合わせを確認してください。"
            return nil
        }
        let start = Int(time.seconds.rounded())
        let intervalLength = max(1, min(58, matchClockSettings.clockDuration(for: time.half) - start))

        switch tool {
        case .home:
            return StatEvent(
                matchID: match.id,
                teamID: match.homeTeamID,
                category: "possession",
                outcome: "own",
                seconds: intervalLength,
                startSeconds: start,
                half: time.half
            )
        case .away:
            return StatEvent(
                matchID: match.id,
                teamID: match.awayTeamID,
                category: "possession",
                outcome: "own",
                seconds: intervalLength,
                startSeconds: start,
                half: time.half
            )
        case .bip:
            return StatEvent(
                matchID: match.id,
                category: "possession",
                outcome: "none",
                seconds: intervalLength,
                startSeconds: start,
                half: time.half
            )
        case .tryEvent:
            return StatEvent(matchID: match.id, category: "try", outcome: "success", seconds: start, half: time.half)
        case .conv:
            return StatEvent(matchID: match.id, category: "conversion", outcome: "success", seconds: start, half: time.half)
        case .pg:
            return StatEvent(matchID: match.id, category: "penalty_goal", outcome: "success", seconds: start, half: time.half)
        case .dg:
            return StatEvent(matchID: match.id, category: "drop_goal", outcome: "success", seconds: start, half: time.half)
        case .lo:
            return StatEvent(matchID: match.id, category: "lineout", outcome: "success", seconds: start, half: time.half)
        case .scr:
            return StatEvent(matchID: match.id, category: "scrum", outcome: "success", seconds: start, half: time.half)
        case .video, .match, .halfTime, .stoppage, .deleteTool, .metric:
            return nil
        }
    }

    private func deleteSelectedTimelineItem() {
        if deleteSelectedStoppage() { return }

        if let removedVideo = viewModel.deleteSelectedVideoSegment() {
            if let fileName = removedVideo.fileName {
                if let match {
                    VideoStorage.removeVideoName(fileName, for: match.id)
                }
            }
            reloadStoredEvents(resetHistory: false)
            configurePlayerForSelectedVideo(autoplay: false)
            return
        }

        guard let selectedClipID = viewModel.selectedClipID else { return }
        if let event = fetchStatEvent(id: selectedClipID) {
            modelContext.delete(event)
            do {
                try modelContext.save()
            } catch {
                editorErrorMessage = "イベントを削除できませんでした。"
                return
            }
        }
        viewModel.deleteSelectedClip()
    }

    // はさみ: 再生ヘッドの位置で帯を2つに切る。
    // 左は元の記録の長さを縮めるだけ、右は同じ中身の新しい記録として保存する。
    private func splitClipAtPlayhead() {
        guard let match else {
            editorErrorMessage = "試合情報がないため、分割できません。"
            return
        }

        let time = viewModel.currentVideoTime
        guard let target = viewModel.splitTargetClip(at: time) else {
            editorErrorMessage = splitUnavailableMessage()
            return
        }
        guard let result = viewModel.splitClip(id: target.id, at: time) else { return }

        guard let leftEvent = fetchStatEvent(id: result.left.id),
              let rightEvent = makeStatEvent(from: result.right, match: match) else {
            viewModel.undo()
            editorErrorMessage = "分割した内容を保存できませんでした。"
            return
        }

        do {
            try apply(clip: result.left, to: leftEvent)
            modelContext.insert(rightEvent)
            try modelContext.save()
            representedEventIDs.insert(rightEvent.id)
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        } catch {
            modelContext.rollback()
            viewModel.undo()
            editorErrorMessage = "分割した内容を保存できませんでした。"
        }
    }

    // 分割できないときに、次に何をすればいいかを伝える文言
    private func splitUnavailableMessage() -> String {
        guard let selected = viewModel.clip(id: viewModel.selectedClipID) else {
            return "切りたい帯をタップして選んでから、分割したい位置で「分割」を押してください。"
        }
        guard selected.trackType.isIntervalTrack else {
            return "分割できるのはHOME・AWAY保持とBIPの区間です。得点など1回のプレーは分割できません。"
        }
        return "再生ヘッドが \(selected.trackType.title) の帯の内側(両端から0.1秒以上)にあるときに分割できます。"
    }

    private func adjustSelectedClipStart(by delta: Double) {
        guard viewModel.adjustSelectedClipStart(by: delta) else { return }
        saveSelectedClipToEvent()
    }

    private func adjustSelectedClipEnd(by delta: Double) {
        guard viewModel.adjustSelectedClipEnd(by: delta) else { return }
        saveSelectedClipToEvent()
    }

    private func moveSelectedClip(by delta: Double) {
        guard viewModel.moveSelectedClip(by: delta) else { return }
        saveSelectedClipToEvent()
    }

    private func saveSelectedClipToEvent() {
        guard let clip = viewModel.clip(id: viewModel.selectedClipID),
              let event = fetchStatEvent(id: clip.id) else { return }

        do {
            try apply(clip: clip, to: event)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            viewModel.undo()
            editorErrorMessage = error.localizedDescription
        }
    }

    private func persistTimelineStateToStorage() {
        guard let match else { return }

        do {
            let matchID = match.id
            let descriptor = FetchDescriptor<StatEvent>(
                predicate: #Predicate<StatEvent> { event in
                    event.matchID == matchID
                }
            )
            let existingEvents = try modelContext.fetch(descriptor)
            let existingByID = Dictionary(uniqueKeysWithValues: existingEvents.map { ($0.id, $0) })
            let timelineClipIDs = Set(viewModel.timelineClips.map(\.id))

            for event in existingEvents {
                if representedEventIDs.contains(event.id) && !timelineClipIDs.contains(event.id) {
                    modelContext.delete(event)
                }
            }

            for clip in viewModel.timelineClips {
                if let existingEvent = existingByID[clip.id] {
                    try apply(clip: clip, to: existingEvent)
                } else if let newEvent = makeStatEvent(from: clip, match: match) {
                    modelContext.insert(newEvent)
                }
            }

            try modelContext.save()

            let videoNames = viewModel.videoSegments.compactMap(\.fileName)
            VideoStorage.setVideoNames(VideoStorage.preservingMissingNames(edited: videoNames,
                stored: VideoStorage.videoNames(for: match.id)), for: match.id)
        } catch {
            modelContext.rollback()
            editorErrorMessage = "編集履歴を保存状態へ反映できませんでした。"
        }
    }

    private func fetchStatEvent(id: UUID) -> StatEvent? {
        var descriptor = FetchDescriptor<StatEvent>(
            predicate: #Predicate<StatEvent> { event in
                event.id == id
            }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    // 映像の位置をハーフ内の時計へ戻して保存する。成否・選手・任意詳細を保持し、
    // 古い相対指定の保持だけは実際に保持したチームへ正規化する。
    private func apply(clip: TimelineClip, to event: StatEvent) throws {
        try TimelineEventTiming.update(event, start: clip.startTime, length: clip.endTime - clip.startTime,
                                       isInterval: clip.trackType.isIntervalTrack, timeline: videoTimeline, match: match)
    }

    private func makeStatEvent(from clip: TimelineClip, match: Match) -> StatEvent? {
        guard let event = makeBaseStatEvent(from: clip, match: match) else { return nil }
        // 位置と長さ(0.1秒きざみを含む)は1か所にまとめて書き込む
        do {
            try apply(clip: clip, to: event)
        } catch {
            editorErrorMessage = error.localizedDescription
            return nil
        }
        return event
    }

    private func makeBaseStatEvent(from clip: TimelineClip, match: Match) -> StatEvent? {
        let start = Int(max(0, clip.startTime).rounded())
        let length = Int(max(1, clip.endTime - clip.startTime).rounded())

        // 元の記録の控えがあるなら、それをそのまま復元する。
        // (取り消しで戻したときに、成否や選手が消えないようにするため)
        if let details = clip.details {
            return details.makeEvent(id: clip.id, matchID: match.id)
        }

        switch clip.trackType {
        case .home:
            return StatEvent(
                id: clip.id,
                matchID: match.id,
                teamID: match.homeTeamID,
                category: "possession",
                outcome: "own",
                seconds: length,
                startSeconds: start
            )
        case .away:
            return StatEvent(
                id: clip.id,
                matchID: match.id,
                teamID: match.awayTeamID,
                category: "possession",
                outcome: "own",
                seconds: length,
                startSeconds: start
            )
        case .bip:
            return StatEvent(
                id: clip.id,
                matchID: match.id,
                category: "possession",
                outcome: "none",
                seconds: length,
                startSeconds: start
            )
        case .tryEvent, .conv, .pg, .dg, .lo, .scr:
            guard let category = storageCategory(for: clip.trackType) else { return nil }
            return StatEvent(
                id: clip.id,
                matchID: match.id,
                category: category,
                outcome: "success",
                seconds: start
            )
        case .video, .match, .halfTime, .stoppage, .deleteTool, .metric:
            return nil
        }
    }

    private func timelineClip(from event: StatEvent, match: Match) -> TimelineClip? {
        guard let trackType = trackType(for: event, match: match) else { return nil }
        let minimum = TimelineEditorViewModel.minimumClipLength
        guard let range = TimelineEventTiming.range(of: event, isInterval: trackType.isIntervalTrack,
                                                    timeline: videoTimeline) else { return nil }
        let start = range.start
        let end = range.end
        let title: String
        if case .metric = trackType { title = event.recordingTitle }
        else { title = trackType.title }

        return TimelineClip(
            id: event.id,
            trackType: trackType,
            startTime: start,
            endTime: min(max(start + minimum, end), max(start + minimum, viewModel.videoDuration)),
            title: title,
            isSelected: event.id == viewModel.selectedClipID,
            details: StatEventDetails(event: event)
        )
    }

    private func trackType(for event: StatEvent, match: Match) -> TimelineTrackType? {
        switch event.category {
        case "possession":
            switch MatchStatistics.possessionTarget(for: event, match: match) {
            case .some(.home): return .home
            case .some(.away): return .away
            case .some(.bip): return .bip
            case .none: return nil
            }
        case "try": return .tryEvent
        case "conversion": return .conv
        case "penalty_goal": return .pg
        case "drop_goal": return .dg
        case "lineout": return .lo
        case "scrum": return .scr
        case "match_state", "": return nil
        default: return .metric(category: event.category, title: event.recordingTitle)
        }
    }

    private func storageCategory(for trackType: TimelineTrackType) -> String? {
        switch trackType {
        case .tryEvent: return "try"
        case .conv: return "conversion"
        case .pg: return "penalty_goal"
        case .dg: return "drop_goal"
        case .lo: return "lineout"
        case .scr: return "scrum"
        default: return nil
        }
    }

    private func defaultVisibleLength(for trackType: TimelineTrackType) -> Double {
        switch trackType {
        case .tryEvent, .conv, .pg, .dg, .lo, .scr:
            return 26
        default:
            return 58
        }
    }

    private func importSelectedVideos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        isVideoImporting = true
        videoImportProgress = 0

        Task {
            var importedCount = 0
            do {
                for (index, item) in items.enumerated() {
                    guard let movie = try await item.loadTransferable(type: TimelineImportedMovie.self) else {
                        throw TimelineVideoImportError.unavailable
                    }

                    let duration = await videoDurationSeconds(for: movie.fileName)
                    await MainActor.run {
                        let sourceName = "V\(viewModel.videoSegments.count + 1)"
                        let segment = viewModel.addVideoSegment(
                            sourceName: sourceName,
                            duration: duration,
                            fileName: movie.fileName
                        )
                        if let match {
                            VideoStorage.appendVideoNames([movie.fileName], for: match.id)
                        }
                        reloadStoredEvents()
                        selectVideoSegment(segment, autoplay: false)
                        importedCount += 1
                        videoImportProgress = Double(index + 1) / Double(max(1, items.count))
                    }
                }

                await MainActor.run {
                    selectedVideoItems = []
                    isVideoImporting = false
                    videoImportProgress = 0
                }
            } catch {
                await MainActor.run {
                    selectedVideoItems = []
                    isVideoImporting = false
                    videoImportProgress = 0
                    editorErrorMessage = importedCount > 0
                        ? "一部の動画だけ読み込みました。読み込めなかった動画があります。"
                        : "動画を読み込めませんでした。別の動画で試してください。"
                }
            }
        }
    }

    private func pausePlayback() {
        videoPlayer?.pause()
        youtubePlayer.pause()
    }

    private var estimatedYouTubeDuration: Double {
        let matchLength = matchClockSettings.actualHalfTimelineDuration(for: 0)
            + matchClockSettings.halfTimeDuration + matchClockSettings.actualHalfTimelineDuration(for: 1)
        return max(2 * 60 * 60, Double(matchLength) + (kickoffAnchors.values.map(\.seconds).max() ?? 0))
    }

    private func addYouTubeVideo(_ link: YouTubeVideoLink) {
        pausePlayback()
        clearSequentialPlayback()
        let segment: VideoSegment
        if let existing = viewModel.videoSegments.first(where: { $0.fileName == link.sourceName }) {
            segment = existing
        } else {
            segment = viewModel.addVideoSegment(
                sourceName: "YouTube \(viewModel.videoSegments.count + 1)",
                duration: YouTubeVideoLink.cachedDuration(videoID: link.videoID)
                    ?? max(estimatedYouTubeDuration, link.startSeconds + estimatedYouTubeDuration),
                fileName: link.sourceName
            )
            if let match { VideoStorage.appendVideoNames([link.sourceName], for: match.id) }
            reloadStoredEvents()
        }
        viewModel.selectVideoSegment(segment.id)
        viewModel.currentVideoTime = segment.startTime + min(link.startSeconds, segment.endTime - segment.startTime)
        configurePlayer(for: segment, autoplay: false)
    }

    private func configureYouTubeCallbacks(segmentID: UUID, videoID: String) {
        youtubePlayer.onTimeChange = { seconds in
            guard activeVideoSegmentID == segmentID, !isScrubbingTimeline,
                  let segment = viewModel.videoSegment(id: segmentID) else { return }
            viewModel.currentVideoTime = min(viewModel.videoDuration, segment.startTime + seconds)
            checkSequentialPlaybackProgress()
        }
        youtubePlayer.onPlaybackChange = { playing in
            guard activeVideoSegmentID == segmentID else { return }
            viewModel.isPlaying = playing
        }
        youtubePlayer.onDurationChange = { duration in
            guard activeVideoSegmentID == segmentID, duration.isFinite, duration > 0,
                  let index = viewModel.videoSegments.firstIndex(where: { $0.id == segmentID }) else { return }
            YouTubeVideoLink.cacheDuration(duration, videoID: videoID)
            let old = viewModel.videoSegments[index]
            guard abs(old.endTime - old.startTime - duration) > 0.5 else { return }
            let delta = duration - (old.endTime - old.startTime)
            viewModel.videoSegments[index].endTime = old.startTime + duration
            for following in viewModel.videoSegments.indices where following > index {
                viewModel.videoSegments[following].startTime += delta
                viewModel.videoSegments[following].endTime += delta
            }
            viewModel.videoDuration = max(16 * 60, viewModel.videoSegments.map(\.endTime).max() ?? 0)
            viewModel.currentVideoTime = min(viewModel.currentVideoTime, viewModel.videoDuration)
            loadMatchSegments()
            reloadStoredEvents()
        }
        youtubePlayer.onEnded = {
            guard activeVideoSegmentID == segmentID else { return }
            // YouTube reports stopped before its ended callback.
            viewModel.isPlaying = true
            handleVideoDidPlayToEnd()
        }
    }

    private func loadStoredVideosIfNeeded() async {
        guard !didLoadStoredVideos, let match else { return }
        didLoadStoredVideos = true

        let storedNames = VideoStorage.videoNames(for: match.id)
        let availableNames = storedNames.filter { VideoStorage.isAvailable(named: $0) }
        guard !availableNames.isEmpty else { return }

        var segments: [VideoSegment] = []
        var cursor: Double = 0

        for (index, fileName) in availableNames.enumerated() {
            let duration = await videoDurationSeconds(for: fileName)
            let end = cursor + max(1, duration)
            segments.append(
                VideoSegment(
                    id: UUID(),
                    sourceName: YouTubeVideoLink.videoID(forSourceName: fileName) == nil ? "V\(index + 1)" : "YouTube \(index + 1)",
                    startTime: cursor,
                    endTime: end,
                    fileName: fileName
                )
            )
            cursor = end + 12
        }

        viewModel.setVideoSegments(segments)
        configurePlayerForSelectedVideo(autoplay: false)
    }

    private func videoDurationSeconds(for fileName: String) async -> Double {
        if let id = YouTubeVideoLink.videoID(forSourceName: fileName) {
            return YouTubeVideoLink.cachedDuration(videoID: id) ?? estimatedYouTubeDuration
        }
        guard let url = VideoStorage.url(named: fileName) else { return 1 }
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let seconds = duration.seconds
            return seconds.isFinite && seconds > 0 ? seconds : 1
        } catch {
            return 1
        }
    }

    private func toggleVideoPlayback() {
        if viewModel.isPlaying {
            pausePlayback()
            viewModel.isPlaying = false
            return
        }

        if let segmentAtTime = playableVideoSegment(at: viewModel.currentVideoTime),
           segmentAtTime.id != viewModel.selectedVideoSegmentID {
            viewModel.selectVideoSegment(segmentAtTime.id)
            configurePlayer(for: segmentAtTime, autoplay: false)
        } else if activeVideoSegmentID == nil {
            configurePlayerForSelectedVideo(autoplay: false)
        }

        if isYouTubeActive {
            youtubePlayer.play()
            return
        }
        guard let videoPlayer else {
            editorErrorMessage = "再生できる動画がありません。先に動画を追加してください。"
            return
        }

        videoPlayer.play()
        viewModel.isPlaying = true
    }

    private func selectVideoSegment(_ segment: VideoSegment, autoplay: Bool) {
        viewModel.currentVideoTime = segment.startTime
        viewModel.selectVideoSegment(segment.id)
        configurePlayer(for: segment, autoplay: autoplay)
    }

    private func scrubTimeline(to time: Double) {
        let clampedTime = min(max(0, time), viewModel.videoDuration)
        guard abs(viewModel.currentVideoTime - clampedTime) > 0.03 else { return }

        // 指でスクラブしたら連続再生モードは解除して通常操作に戻す
        clearSequentialPlayback()

        viewModel.currentVideoTime = clampedTime
        pausePlayback()
        viewModel.isPlaying = false

        if isScrubbingTimeline {
            // スクラブ中: 粗い精度のシークを直列に間引いて発行する。
            // 毎フレーム誤差ゼロシークを発行すると詰まってカクつくため。
            requestScrubSeek(to: clampedTime)
        } else {
            // タップ等の単発移動は即・正確にシーク
            seekPlayerToCurrentTime(selectingSegmentAtCurrentTime: true)
        }
    }

    // 「最後に要求された時刻」だけを覚えておき、前のシークが終わってから次を出す
    private func requestScrubSeek(to time: Double) {
        pendingScrubSeekTime = time
        performPendingScrubSeek()
    }

    private func performPendingScrubSeek() {
        guard !isScrubSeekInFlight, let target = pendingScrubSeekTime else { return }
        guard let segment = playableVideoSegment(at: target) else { return }

        if activeVideoSegmentID != segment.id {
            pendingScrubSeekTime = nil
            viewModel.selectVideoSegment(segment.id)
            configurePlayer(for: segment, autoplay: false)
            return
        }

        if isYouTubeActive {
            pendingScrubSeekTime = nil
            youtubePlayer.seek(to: target - segment.startTime, autoplay: false)
            return
        }
        guard let player = videoPlayer else { return }
        pendingScrubSeekTime = nil
        isScrubSeekInFlight = true
        let localTime = min(max(0, target - segment.startTime), max(0, segment.endTime - segment.startTime))
        let tolerance = CMTime(seconds: 0.3, preferredTimescale: 600)
        player.seek(
            to: CMTime(seconds: localTime, preferredTimescale: 600),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        ) { _ in
            Task { @MainActor in
                isScrubSeekInFlight = false
                performPendingScrubSeek()
            }
        }
    }

    // ===== トラック連続再生 =====
    // 左のラベル(HOME など)をタップすると、その行のクリップ区間だけを
    // 時系列順に動画で連続再生する。区間の合間は自動でスキップ。

    private func toggleSequentialPlayback(for trackType: TimelineTrackType) {
        if selectedPlaybackTrack == trackType {
            clearSequentialPlayback()
            pausePlayback()
            viewModel.isPlaying = false
            return
        }

        let queue = sequentialPlaybackQueue(for: trackType)
        guard !queue.isEmpty else {
            editorErrorMessage = "\(trackType.title) のクリップがまだありません。"
            return
        }
        // 動画が重なっている最初の区間から始める
        guard let firstIndex = queue.firstIndex(where: { playableVideoSegment(at: $0.start) != nil }) else {
            editorErrorMessage = "\(trackType.title) のクリップに重なる動画がありません。"
            return
        }

        selectedPlaybackTrack = trackType
        playbackQueue = queue
        playbackQueueIndex = firstIndex
        jumpPlayback(to: queue[firstIndex].start, keepPlaying: true)
    }

    private func clearSequentialPlayback() {
        selectedPlaybackTrack = nil
        playbackQueue = []
        playbackQueueIndex = 0
    }

    // その行のクリップを時系列順に並べ、重なる・つながる区間は1つにまとめる
    private func sequentialPlaybackQueue(for trackType: TimelineTrackType) -> [(start: Double, end: Double)] {
        let clips = viewModel.timelineClips
            .filter { $0.trackType == trackType && $0.endTime > $0.startTime }
            .sorted { $0.startTime < $1.startTime }

        var merged: [(start: Double, end: Double)] = []
        for clip in clips {
            if let last = merged.last, clip.startTime <= last.end + 0.5 {
                merged[merged.count - 1].end = max(last.end, clip.endTime)
            } else {
                merged.append((clip.startTime, clip.endTime))
            }
        }
        return merged
    }

    // 再生を続けたまま、タイムライン上の指定時刻へ動画を飛ばす
    private func jumpPlayback(to time: Double, keepPlaying: Bool) {
        let clampedTime = min(max(0, time), viewModel.videoDuration)
        viewModel.currentVideoTime = clampedTime

        guard let segment = playableVideoSegment(at: clampedTime) else { return }

        if activeVideoSegmentID != segment.id {
            viewModel.selectVideoSegment(segment.id)
            configurePlayer(for: segment, autoplay: keepPlaying)
        } else {
            let localTime = min(max(0, clampedTime - segment.startTime), max(0, segment.endTime - segment.startTime))
            if isYouTubeActive {
                youtubePlayer.seek(to: localTime, autoplay: keepPlaying)
                return
            }
            videoPlayer?.seek(
                to: CMTime(seconds: localTime, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            if keepPlaying {
                videoPlayer?.play()
                viewModel.isPlaying = true
            }
        }
    }

    // 再生位置が今の区間の終わりまで来たら、次の区間へ自動で飛ぶ。
    // 動画の時間監視(0.2秒ごと)から呼ばれる。
    private func checkSequentialPlaybackProgress() {
        guard selectedPlaybackTrack != nil,
              viewModel.isPlaying,
              playbackQueueIndex < playbackQueue.count else {
            return
        }
        let current = playbackQueue[playbackQueueIndex]
        guard viewModel.currentVideoTime >= current.end - 0.1 else { return }

        var nextIndex = playbackQueueIndex + 1
        // 動画が重なっていない区間は飛ばす
        while nextIndex < playbackQueue.count,
              playableVideoSegment(at: playbackQueue[nextIndex].start) == nil {
            nextIndex += 1
        }

        guard nextIndex < playbackQueue.count else {
            // 最後の区間まで見終わったら停止して選択も解除
            pausePlayback()
            viewModel.isPlaying = false
            clearSequentialPlayback()
            return
        }

        playbackQueueIndex = nextIndex
        jumpPlayback(to: playbackQueue[nextIndex].start, keepPlaying: true)
    }

    private func seekPlayerToCurrentTime(selectingSegmentAtCurrentTime: Bool) {
        let segment: VideoSegment?
        if selectingSegmentAtCurrentTime {
            segment = playableVideoSegment(at: viewModel.currentVideoTime)
                ?? viewModel.videoSegment(id: viewModel.selectedVideoSegmentID)
        } else {
            segment = viewModel.videoSegment(id: viewModel.selectedVideoSegmentID)
        }

        guard let segment else { return }

        if activeVideoSegmentID != segment.id {
            viewModel.selectVideoSegment(segment.id)
            configurePlayer(for: segment, autoplay: false)
            return
        }

        let localTime = min(max(0, viewModel.currentVideoTime - segment.startTime), max(0, segment.endTime - segment.startTime))
        if isYouTubeActive {
            youtubePlayer.seek(to: localTime, autoplay: false)
            return
        }
        videoPlayer?.seek(
            to: CMTime(seconds: localTime, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func playableVideoSegment(at time: Double) -> VideoSegment? {
        viewModel.videoSegments.first { segment in
            segment.fileName != nil && segment.startTime <= time && time <= segment.endTime
        }
    }

    private func configurePlayerForSelectedVideo(autoplay: Bool) {
        guard let segment = viewModel.videoSegment(id: viewModel.selectedVideoSegmentID)
                ?? viewModel.videoSegments.first(where: { $0.fileName != nil }) else {
            removePlaybackObserver()
            pausePlayback()
            videoPlayer = nil
            youtubePlayer.stop()
            activeVideoSegmentID = nil
            viewModel.isPlaying = false
            return
        }
        viewModel.selectVideoSegment(segment.id)
        configurePlayer(for: segment, autoplay: autoplay)
    }

    private func configurePlayer(for segment: VideoSegment, autoplay: Bool) {
        if let name = segment.fileName, let id = YouTubeVideoLink.videoID(forSourceName: name) {
            removePlaybackObserver()
            videoPlayer?.pause()
            videoPlayer = nil
            activeVideoSegmentID = segment.id
            configureYouTubeCallbacks(segmentID: segment.id, videoID: id)
            let local = min(max(0, viewModel.currentVideoTime - segment.startTime), segment.endTime - segment.startTime)
            youtubePlayer.load(videoID: id, startSeconds: local, autoplay: autoplay)
            return
        }
        youtubePlayer.stop()
        guard let fileName = segment.fileName,
              let url = VideoStorage.url(named: fileName) else {
            removePlaybackObserver()
            pausePlayback()
            videoPlayer = nil
            youtubePlayer.stop()
            activeVideoSegmentID = nil
            viewModel.isPlaying = false
            editorErrorMessage = "この動画ファイルを開けませんでした。"
            return
        }

        let player: AVPlayer
        if activeVideoSegmentID == segment.id, let existingPlayer = videoPlayer {
            player = existingPlayer
        } else {
            removePlaybackObserver()
            videoPlayer?.pause()
            player = AVPlayer(url: url)
            videoPlayer = player
            activeVideoSegmentID = segment.id
            addPlaybackObserver(to: player, segment: segment)
            addVideoEndObserver(to: player)
        }

        let localTime = min(max(0, viewModel.currentVideoTime - segment.startTime), max(0, segment.endTime - segment.startTime))
        player.seek(to: CMTime(seconds: localTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)

        if autoplay {
            player.play()
            viewModel.isPlaying = true
        } else {
            player.pause()
            viewModel.isPlaying = false
        }
    }

    private func addPlaybackObserver(to player: AVPlayer, segment: VideoSegment) {
        playbackTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { time in
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            Task { @MainActor in
                viewModel.currentVideoTime = min(viewModel.videoDuration, segment.startTime + seconds)
                checkSequentialPlaybackProgress()
            }
        }
    }

    private func removePlaybackObserver() {
        if let playbackTimeObserver, let videoPlayer {
            videoPlayer.removeTimeObserver(playbackTimeObserver)
        }
        playbackTimeObserver = nil
        removeVideoEndObserver()
    }

    // ===== 動画ファイルの終端処理 =====
    // 1本目の動画が最後まで再生されたら、タイムライン上の次の動画へ自動で続ける。
    // 1本目の終わりと2本目の頭の間が空いていても(撮影のラグ等)、待たずに飛ばす。

    private func addVideoEndObserver(to player: AVPlayer) {
        removeVideoEndObserver()
        guard let item = player.currentItem else { return }
        videoEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            Task { @MainActor in
                handleVideoDidPlayToEnd()
            }
        }
    }

    private func removeVideoEndObserver() {
        if let videoEndObserver {
            NotificationCenter.default.removeObserver(videoEndObserver)
        }
        videoEndObserver = nil
    }

    private func handleVideoDidPlayToEnd() {
        guard viewModel.isPlaying else { return }

        // ファイルが付いている動画セグメントを時系列に並べ、今の次を探す
        let playableSegments = viewModel.videoSegments
            .filter { $0.fileName != nil }
            .sorted { $0.startTime < $1.startTime }

        guard let activeID = activeVideoSegmentID,
              let activeIndex = playableSegments.firstIndex(where: { $0.id == activeID }),
              activeIndex + 1 < playableSegments.count else {
            // 次の動画がなければここで停止
            pausePlayback()
            viewModel.isPlaying = false
            return
        }

        let next = playableSegments[activeIndex + 1]
        jumpPlayback(to: next.startTime, keepPlaying: true)
    }
}

#Preview {
    NavigationStack {
        TimelineEditorView(match: Match(tournamentID: UUID(), homeTeamID: UUID(), awayTeamID: UUID(), playedAt: Date()))
    }
    .modelContainer(for: [
        Team.self,
        Player.self,
        Tournament.self,
        Match.self,
        StatEvent.self,
        MatchLineup.self,
        Substitution.self
    ], inMemory: true)
}
