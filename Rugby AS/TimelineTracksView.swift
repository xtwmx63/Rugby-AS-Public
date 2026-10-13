// TimelineEditorView.swift から分割(中身は変更なし)

import AVFoundation
import Combine
import CoreTransferable
import PhotosUI
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - タイムライン描画(Canvas 1枚 + 物理スクロール)
//
// 仕組み(重くしないための設計):
// - 横スクロールは「中身が空の UIScrollView」を物理エンジンとしてだけ使う。
//   慣性・バウンドはネイティブのまま、位置(offset)だけを受け取る。
// - 見た目は、見えている範囲だけを Canvas に毎回描く。クリップを1つずつ
//   ビューにしない → クリップが何百個あっても描画コストがほぼ一定。
// - 再生ヘッドは画面中央に固定し、スクロール位置 = 再生時刻。
// - ピンチで拡大縮小(再生ヘッド中心)。選択クリップは掴んで移動・両端で伸縮。

enum ClipDragMode {
    case move
    case start
    case end
}

struct ClipDragPreview: Equatable {
    var mode: ClipDragMode?
    var delta: Double

    static let inactive = ClipDragPreview(mode: nil, delta: 0)
}

struct TimelineTracksView: View {
    @ObservedObject var viewModel: TimelineEditorViewModel
    @Binding var isScrubbingTimeline: Bool
    var selectedPlaybackTrack: TimelineTrackType?
    var onSelectVideoSegment: (VideoSegment) -> Void
    var onTrackLabelTap: (TimelineTrackType) -> Void
    var onAdjustSelectedStart: (Double) -> Void
    var onAdjustSelectedEnd: (Double) -> Void
    var onMoveSelected: (Double) -> Void
    var onMatchSegmentDrag: (ClipDragMode, Double) -> Void
    var onTimelineTimeChanged: (Double) -> Void

    private let labelWidth: CGFloat = 110
    private let rulerHeight: CGFloat = 42
    private let rowHeight: CGFloat = 48

    // 横スクロール位置と拡大率は、このビューの中で完結させる
    @State private var scrollOffset: CGFloat = 0
    @State private var pixelsPerSecond: CGFloat = 1.55
    @State private var pinchBasePPS: CGFloat?
    @State private var pinchFocusTime: Double = 0
    @State private var dragPreview: ClipDragPreview = .inactive

    var body: some View {
        GeometryReader { proxy in
            let viewportWidth = max(1, proxy.size.width - labelWidth)
            let playheadX = proxy.size.width / 2
            let leadingInset = max(0, playheadX - labelWidth)
            let contentWidth = CGFloat(viewModel.videoDuration) * pixelsPerSecond + viewportWidth
            let rowsHeight = CGFloat(viewModel.visibleTracks.count) * rowHeight

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color(red: 0.01, green: 0.05, blue: 0.10).opacity(0.90))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(Color.white.opacity(0.11), lineWidth: 1)
                    )

                VStack(spacing: 0) {
                    // 目盛り(上部に固定・タップでその時刻へ移動)
                    HStack(spacing: 0) {
                        Color.clear.frame(width: labelWidth, height: rulerHeight)

                        ZStack(alignment: .topLeading) {
                            TimelineScrollPhysicsView(
                                offset: $scrollOffset,
                                isTracking: $isScrubbingTimeline,
                                contentWidth: contentWidth,
                                onTap: { point in
                                    jumpToTapped(contentX: point.x, leadingInset: leadingInset)
                                }
                            )

                            TimelineRulerCanvas(
                                duration: viewModel.videoDuration,
                                pixelsPerSecond: pixelsPerSecond,
                                offset: scrollOffset,
                                leadingInset: leadingInset
                            )
                            .allowsHitTesting(false)
                        }
                        .frame(width: viewportWidth, height: rulerHeight)
                        .clipped()
                    }

                    // トラック(縦にスクロール可)
                    ScrollView(.vertical, showsIndicators: false) {
                        HStack(spacing: 0) {
                            VStack(spacing: 0) {
                                ForEach(viewModel.visibleTracks) { trackType in
                                    TimelineTrackLabelView(
                                        trackType: trackType,
                                        isSelected: selectedPlaybackTrack == trackType,
                                        onTap: trackType.supportsSequentialPlayback
                                            ? { onTrackLabelTap(trackType) }
                                            : nil
                                    )
                                    .frame(width: labelWidth, height: rowHeight)
                                    .overlay(alignment: .bottom) {
                                        Rectangle()
                                            .fill(Color.white.opacity(0.07))
                                            .frame(height: 1)
                                    }
                                }
                            }

                            ZStack(alignment: .topLeading) {
                                TimelineScrollPhysicsView(
                                    offset: $scrollOffset,
                                    isTracking: $isScrubbingTimeline,
                                    contentWidth: contentWidth,
                                    onTap: { point in
                                        handleRowsTap(contentPoint: point, leadingInset: leadingInset)
                                    },
                                    onPinchBegan: {
                                        pinchBasePPS = pixelsPerSecond
                                        pinchFocusTime = viewModel.currentVideoTime
                                    },
                                    onPinchChanged: { scale in
                                        guard let base = pinchBasePPS else { return }
                                        pixelsPerSecond = min(max(base * scale, 0.5), 10)
                                        scrollOffset = CGFloat(pinchFocusTime) * pixelsPerSecond
                                    },
                                    onPinchEnded: {
                                        pinchBasePPS = nil
                                    }
                                )

                                TimelineRowsCanvas(
                                    tracks: viewModel.visibleTracks,
                                    rowHeight: rowHeight,
                                    duration: viewModel.videoDuration,
                                    pixelsPerSecond: pixelsPerSecond,
                                    offset: scrollOffset,
                                    leadingInset: leadingInset,
                                    clips: viewModel.timelineClips,
                                    matchSegments: viewModel.matchSegments,
                                    videoSegments: viewModel.videoSegments,
                                    selectedClipID: viewModel.selectedClipID,
                                    selectedVideoSegmentID: viewModel.selectedVideoSegmentID,
                                    selectedMatchSelection: viewModel.selectedMatchSelection,
                                    playbackTrack: selectedPlaybackTrack,
                                    dragPreview: dragPreview
                                )
                                .allowsHitTesting(false)

                                selectedClipOverlay(leadingInset: leadingInset, viewportWidth: viewportWidth)

                                selectedMatchOverlay(leadingInset: leadingInset, viewportWidth: viewportWidth)
                            }
                            .frame(width: viewportWidth, height: rowsHeight)
                            .clipped()
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18))

                Rectangle()
                    .fill(Color.white.opacity(0.10))
                    .frame(width: 1)
                    .position(x: labelWidth, y: proxy.size.height / 2)
                    .allowsHitTesting(false)

                if viewModel.videoSegments.isEmpty {
                    Text("動画を追加すると、ここに実際のクリップが表示されます")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.36))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: viewportWidth - 24)
                        .position(x: labelWidth + viewportWidth / 2, y: rulerHeight + rowHeight / 2)
                        .allowsHitTesting(false)
                }

                // 再生ヘッド(中央固定)
                VStack(spacing: 0) {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 18, height: 18)
                        .shadow(color: Color.white.opacity(0.60), radius: 8)
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 2)
                }
                .frame(height: proxy.size.height - 12)
                .position(x: playheadX, y: proxy.size.height / 2 + 6)
                .allowsHitTesting(false)
            }
            .onAppear {
                scrollOffset = CGFloat(viewModel.currentVideoTime) * pixelsPerSecond
            }
            .onChange(of: viewModel.currentVideoTime) { _, newTime in
                guard !isScrubbingTimeline, pinchBasePPS == nil else { return }
                scrollOffset = CGFloat(newTime) * pixelsPerSecond
            }
            .onChange(of: scrollOffset) { _, newOffset in
                guard isScrubbingTimeline else { return }
                onTimelineTimeChanged(Double(newOffset / max(1, pixelsPerSecond)))
            }
        }
    }

    // MARK: 選択クリップの操作レイヤー(移動・伸縮)

    @ViewBuilder
    private func selectedClipOverlay(leadingInset: CGFloat, viewportWidth: CGFloat) -> some View {
        if let clip = viewModel.clip(id: viewModel.selectedClipID),
           let rowIndex = viewModel.visibleTracks.firstIndex(of: clip.trackType) {
            let times = previewedTimes(for: clip)
            let x = leadingInset + CGFloat(times.start) * pixelsPerSecond - scrollOffset
            let width = max(28, CGFloat(times.end - times.start) * pixelsPerSecond)
            let y = CGFloat(rowIndex) * rowHeight

            if x + width > -60, x < viewportWidth + 60 {
                // 本体: 掴んで左右へ移動
                Color.clear
                    .frame(width: width, height: rowHeight - 14)
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                    .position(x: x + width / 2, y: y + rowHeight / 2)
                    .gesture(dragGesture(mode: .move))

                // 両端: 伸縮ハンドル
                TimelineClipResizeHandle()
                    .frame(width: 34, height: rowHeight)
                    .contentShape(Rectangle())
                    .position(x: x, y: y + rowHeight / 2)
                    .gesture(dragGesture(mode: .start))

                TimelineClipResizeHandle()
                    .frame(width: 34, height: rowHeight)
                    .contentShape(Rectangle())
                    .position(x: x + width, y: y + rowHeight / 2)
                    .gesture(dragGesture(mode: .end))
            }
        }
    }

    // MARK: 試合時間・中断の操作レイヤー

    @ViewBuilder
    private func selectedMatchOverlay(leadingInset: CGFloat, viewportWidth: CGFloat) -> some View {
        if let segment = viewModel.selectedMatchSegment(),
           let rowIndex = viewModel.visibleTracks.firstIndex(of: .match) {
            let times = previewedMatchTimes(for: segment)
            let x = leadingInset + CGFloat(times.start) * pixelsPerSecond - scrollOffset
            let width = max(28, CGFloat(times.end - times.start) * pixelsPerSecond)
            let y = CGFloat(rowIndex) * rowHeight

            if x + width > -60, x < viewportWidth + 60 {
                if segment.isStoppage {
                    // 中断は掴んで移動できる
                    Color.clear
                        .frame(width: width, height: rowHeight - 14)
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                        .position(x: x + width / 2, y: y + rowHeight / 2)
                        .gesture(matchDragGesture(mode: .move))

                    TimelineClipResizeHandle()
                        .frame(width: 34, height: rowHeight)
                        .contentShape(Rectangle())
                        .position(x: x, y: y + rowHeight / 2)
                        .gesture(matchDragGesture(mode: .start))
                }

                // 右端: 中断なら長さ、ハーフなら試合時間そのもの
                if segment.isStoppage || segment.isHalfTime || segment.isHalfEnd {
                    TimelineClipResizeHandle()
                        .frame(width: 34, height: rowHeight)
                        .contentShape(Rectangle())
                        .position(x: x + width, y: y + rowHeight / 2)
                        .gesture(matchDragGesture(mode: .end))
                }
            }
        }
    }

    private func matchDragGesture(mode: ClipDragMode) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                dragPreview = ClipDragPreview(
                    mode: mode,
                    delta: Double(value.translation.width / max(1, pixelsPerSecond))
                )
            }
            .onEnded { value in
                let delta = Double(value.translation.width / max(1, pixelsPerSecond))
                dragPreview = .inactive
                onMatchSegmentDrag(mode, delta)
            }
    }

    private func previewedMatchTimes(for segment: MatchSegment) -> (start: Double, end: Double) {
        var start = segment.startTime
        var end = segment.endTime

        switch dragPreview.mode {
        case .move where segment.isStoppage:
            let length = end - start
            start = max(0, start + dragPreview.delta)
            end = start + length
        case .start where segment.isStoppage:
            start = min(max(0, start + dragPreview.delta), end - 1)
        case .end:
            end = max(start, end + dragPreview.delta)
        default:
            break
        }

        return (start, end)
    }

    private func dragGesture(mode: ClipDragMode) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                dragPreview = ClipDragPreview(
                    mode: mode,
                    delta: Double(value.translation.width / max(1, pixelsPerSecond))
                )
            }
            .onEnded { value in
                let delta = Double(value.translation.width / max(1, pixelsPerSecond))
                dragPreview = .inactive
                switch mode {
                case .move: onMoveSelected(delta)
                case .start: onAdjustSelectedStart(delta)
                case .end: onAdjustSelectedEnd(delta)
                }
            }
    }

    private func previewedTimes(for clip: TimelineClip) -> (start: Double, end: Double) {
        var start = clip.startTime
        var end = clip.endTime

        switch dragPreview.mode {
        case .move:
            let length = end - start
            start = min(max(0, start + dragPreview.delta), max(0, viewModel.videoDuration - length))
            end = start + length
        case .start:
            start = min(max(0, start + dragPreview.delta), end - 1)
        case .end:
            end = max(min(viewModel.videoDuration, end + dragPreview.delta), start + 1)
        case nil:
            break
        }

        return (start, end)
    }

    // MARK: タップの解釈

    private func jumpToTapped(contentX: CGFloat, leadingInset: CGFloat) {
        let time = min(max(0, Double((contentX - leadingInset) / max(1, pixelsPerSecond))), viewModel.videoDuration)
        scrollOffset = CGFloat(time) * pixelsPerSecond
        onTimelineTimeChanged(time)
    }

    private func handleRowsTap(contentPoint: CGPoint, leadingInset: CGFloat) {
        let rowIndex = Int(contentPoint.y / rowHeight)
        guard rowIndex >= 0, rowIndex < viewModel.visibleTracks.count else { return }
        let trackType = viewModel.visibleTracks[rowIndex]
        let time = Double((contentPoint.x - leadingInset) / max(1, pixelsPerSecond))
        // 細いクリップも拾えるよう、±10pt ぶんの遊びを持たせる
        let slop = Double(10 / max(1, pixelsPerSecond))

        switch trackType {
        case .video:
            if let segment = viewModel.videoSegments.first(where: {
                $0.startTime - slop <= time && time <= $0.endTime + slop
            }) {
                onSelectVideoSegment(segment)
            }
        case .match:
            let candidates = viewModel.matchSegments.filter {
                $0.selectionKey != nil && $0.startTime - slop <= time && time <= $0.endTime + slop
            }
            // 中断は細いことが多いので、重なっていたら中断を優先する
            let hit = candidates.first(where: { $0.isStoppage }) ?? candidates.first
            viewModel.selectMatchSelection(hit?.selectionKey)
        case .deleteTool:
            viewModel.selectClip(nil)
        default:
            let candidates = viewModel.timelineClips.filter {
                $0.trackType == trackType && $0.startTime - slop <= time && time <= $0.endTime + slop
            }
            if let hit = candidates.min(by: {
                abs((($0.startTime + $0.endTime) / 2) - time) < abs((($1.startTime + $1.endTime) / 2) - time)
            }) {
                viewModel.selectClip(hit.id)
            } else {
                viewModel.selectClip(nil)
            }
        }
    }
}

// MARK: - 物理エンジンとしての空スクロールビュー

struct TimelineScrollPhysicsView: UIViewRepresentable {
    @Binding var offset: CGFloat
    @Binding var isTracking: Bool
    var contentWidth: CGFloat
    var onTap: ((CGPoint) -> Void)? = nil
    var onPinchBegan: (() -> Void)? = nil
    var onPinchChanged: ((CGFloat) -> Void)? = nil
    var onPinchEnded: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.alwaysBounceVertical = false

        if onTap != nil {
            let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
            tap.cancelsTouchesInView = false
            scrollView.addGestureRecognizer(tap)
        }
        if onPinchChanged != nil {
            let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
            scrollView.addGestureRecognizer(pinch)
        }
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.parent = self
        // setContentOffset は delegate を同期的に呼ぶ。SwiftUI の画面更新中に
        // 状態を書き戻さないよう、フラグを立てて delegate 側で遅延させる。
        context.coordinator.isPerformingViewUpdate = true
        defer { context.coordinator.isPerformingViewUpdate = false }

        if abs(scrollView.contentSize.width - contentWidth) > 0.5 {
            scrollView.contentSize = CGSize(width: contentWidth, height: 1)
        }

        let maxOffset = max(0, contentWidth - scrollView.bounds.width)
        let clampedOffset = min(max(0, offset), maxOffset)
        if abs(scrollView.contentOffset.x - clampedOffset) > 0.5 {
            scrollView.setContentOffset(CGPoint(x: clampedOffset, y: 0), animated: false)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: TimelineScrollPhysicsView
        var isPerformingViewUpdate = false

        init(_ parent: TimelineScrollPhysicsView) {
            self.parent = parent
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            setIsTracking(true)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let x = scrollView.contentOffset.x
            if isPerformingViewUpdate {
                DispatchQueue.main.async { [weak self] in
                    self?.parent.offset = x
                }
            } else {
                parent.offset = x
            }
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                setIsTracking(false)
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            setIsTracking(false)
        }

        private func setIsTracking(_ value: Bool) {
            if isPerformingViewUpdate {
                DispatchQueue.main.async { [weak self] in
                    self?.parent.isTracking = value
                }
            } else {
                parent.isTracking = value
            }
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView = recognizer.view as? UIScrollView else { return }
            parent.onTap?(recognizer.location(in: scrollView))
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let scrollView = recognizer.view as? UIScrollView else { return }
            switch recognizer.state {
            case .began:
                // ピンチ中は横スクロールを止めて、拡大縮小に専念させる
                scrollView.isScrollEnabled = false
                parent.onPinchBegan?()
            case .changed:
                parent.onPinchChanged?(recognizer.scale)
            default:
                scrollView.isScrollEnabled = true
                parent.onPinchEnded?()
            }
        }
    }
}

// MARK: - 目盛りの描画

struct TimelineRulerCanvas: View {
    var duration: Double
    var pixelsPerSecond: CGFloat
    var offset: CGFloat
    var leadingInset: CGFloat

    var body: some View {
        Canvas { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(Color.white.opacity(0.035))
            )

            let pps = max(0.1, pixelsPerSecond)
            func xFor(_ t: Double) -> CGFloat { leadingInset + CGFloat(t) * pps - offset }

            let visibleStart = max(0, Double((offset - leadingInset) / pps))
            let visibleEnd = min(duration, Double((offset - leadingInset + size.width) / pps) + 1)
            guard visibleEnd > visibleStart else { return }

            // ラベルを付ける間隔(分)は、詰まらない最小の間隔をズームから選ぶ
            let stepCandidates = [1, 2, 5, 10, 15, 30]
            let labelStep = stepCandidates.first(where: { CGFloat($0) * 60 * pps >= 64 }) ?? 30

            let firstMinute = max(0, Int(visibleStart / 60))
            let lastMinute = Int(visibleEnd / 60) + 1
            if lastMinute >= firstMinute {
                for minute in firstMinute...lastMinute {
                    let t = Double(minute * 60)
                    if t > duration + 0.5 { break }
                    let x = xFor(t)
                    let isLabeled = minute % labelStep == 0

                    var tick = Path()
                    tick.move(to: CGPoint(x: x, y: size.height))
                    tick.addLine(to: CGPoint(x: x, y: size.height - (isLabeled ? 16 : 9)))
                    context.stroke(tick, with: .color(Color.white.opacity(isLabeled ? 0.42 : 0.20)), lineWidth: 1)

                    if isLabeled {
                        context.draw(
                            Text(TimelineTimeFormat.rulerMinute(minute))
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.white.opacity(0.72)),
                            at: CGPoint(x: x, y: 12)
                        )
                    }
                }
            }

            // 拡大しているときは10秒の小目盛りも足す
            if pps >= 3 {
                let firstTick = max(0, Int(visibleStart / 10))
                let lastTick = Int(visibleEnd / 10) + 1
                if lastTick >= firstTick {
                    for tickIndex in firstTick...lastTick where tickIndex % 6 != 0 {
                        let t = Double(tickIndex * 10)
                        if t > duration { break }
                        var tick = Path()
                        tick.move(to: CGPoint(x: xFor(t), y: size.height))
                        tick.addLine(to: CGPoint(x: xFor(t), y: size.height - 5))
                        context.stroke(tick, with: .color(Color.white.opacity(0.14)), lineWidth: 1)
                    }
                }
            }
        }
    }
}

// MARK: - トラックの描画(全クリップを1枚に描く)

struct TimelineRowsCanvas: View {
    var tracks: [TimelineTrackType]
    var rowHeight: CGFloat
    var duration: Double
    var pixelsPerSecond: CGFloat
    var offset: CGFloat
    var leadingInset: CGFloat
    var clips: [TimelineClip]
    var matchSegments: [MatchSegment]
    var videoSegments: [VideoSegment]
    var selectedClipID: UUID?
    var selectedVideoSegmentID: UUID?
    var selectedMatchSelection: MatchSelection?
    var playbackTrack: TimelineTrackType?
    var dragPreview: ClipDragPreview

    var body: some View {
        Canvas { context, size in
            let pps = max(0.1, pixelsPerSecond)
            func xFor(_ t: Double) -> CGFloat { leadingInset + CGFloat(t) * pps - offset }
            let visibleStart = Double((offset - leadingInset) / pps)
            let visibleEnd = Double((offset - leadingInset + size.width) / pps)

            // 行の背景と区切り線
            for (index, track) in tracks.enumerated() {
                let y = CGFloat(index) * rowHeight
                let rowRect = CGRect(x: 0, y: y, width: size.width, height: rowHeight)

                if track == .video || track == .match {
                    context.fill(Path(rowRect), with: .color(Color.white.opacity(0.03)))
                }
                if track == playbackTrack {
                    context.fill(Path(rowRect), with: .color(track.color.opacity(0.10)))
                }

                var separator = Path()
                separator.move(to: CGPoint(x: 0, y: y + rowHeight))
                separator.addLine(to: CGPoint(x: size.width, y: y + rowHeight))
                context.stroke(separator, with: .color(Color.white.opacity(0.07)), lineWidth: 1)
            }

            // 5分ごとの縦グリッド
            let gridStep: Double = 300
            var gridTime = max(0, (visibleStart / gridStep).rounded(.down) * gridStep)
            while gridTime <= min(duration, visibleEnd) {
                var line = Path()
                line.move(to: CGPoint(x: xFor(gridTime), y: 0))
                line.addLine(to: CGPoint(x: xFor(gridTime), y: size.height))
                context.stroke(line, with: .color(Color.white.opacity(0.06)), lineWidth: 1)
                gridTime += gridStep
            }

            // 各行の中身
            for (index, track) in tracks.enumerated() {
                let y = CGFloat(index) * rowHeight
                switch track {
                case .video:
                    drawVideoRow(context: context, y: y, xFor: xFor, pps: pps, visibleStart: visibleStart, visibleEnd: visibleEnd)
                case .match:
                    drawMatchRow(context: context, y: y, xFor: xFor, pps: pps, visibleStart: visibleStart, visibleEnd: visibleEnd)
                case .deleteTool:
                    break
                default:
                    drawEventRow(context: context, track: track, y: y, xFor: xFor, pps: pps, visibleStart: visibleStart, visibleEnd: visibleEnd)
                }
            }
        }
    }

    private func drawEventRow(
        context: GraphicsContext,
        track: TimelineTrackType,
        y: CGFloat,
        xFor: (Double) -> CGFloat,
        pps: CGFloat,
        visibleStart: Double,
        visibleEnd: Double
    ) {
        for clip in clips where clip.trackType == track {
            var start = clip.startTime
            var end = clip.endTime

            // ドラッグ中の選択クリップは、指についてくる位置で描く
            if clip.id == selectedClipID, dragPreview.mode != nil {
                switch dragPreview.mode {
                case .move:
                    let length = end - start
                    start = min(max(0, start + dragPreview.delta), max(0, duration - length))
                    end = start + length
                case .start:
                    start = min(max(0, start + dragPreview.delta), end - 1)
                case .end:
                    end = max(min(duration, end + dragPreview.delta), start + 1)
                case nil:
                    break
                }
            }

            guard end > visibleStart - 2, start < visibleEnd + 2 else { continue }

            let startX = xFor(start)
            let width = max(28, CGFloat(end - start) * pps)
            let rect = CGRect(x: startX, y: y + 7, width: width, height: rowHeight - 14)
            let path = Path(roundedRect: rect, cornerRadius: 6)
            let isSelected = clip.id == selectedClipID

            if isSelected {
                context.stroke(
                    Path(roundedRect: rect.insetBy(dx: -2.5, dy: -2.5), cornerRadius: 8),
                    with: .color(clip.color.opacity(0.45)),
                    lineWidth: 5
                )
            }
            context.fill(path, with: .color(clip.color.opacity(0.92)))
            context.stroke(
                path,
                with: .color(isSelected ? .white : Color.white.opacity(0.25)),
                lineWidth: isSelected ? 2 : 1
            )

            if width >= 42 {
                var clipped = context
                clipped.clip(to: path)
                clipped.draw(
                    Text(clip.title)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white),
                    at: CGPoint(x: rect.minX + 8, y: rect.midY),
                    anchor: .leading
                )
            }
        }
    }

    private func drawVideoRow(
        context: GraphicsContext,
        y: CGFloat,
        xFor: (Double) -> CGFloat,
        pps: CGFloat,
        visibleStart: Double,
        visibleEnd: Double
    ) {
        for segment in videoSegments {
            guard segment.endTime > visibleStart - 2, segment.startTime < visibleEnd + 2 else { continue }

            let startX = xFor(segment.startTime)
            let width = max(34, CGFloat(segment.endTime - segment.startTime) * pps)
            let rect = CGRect(x: startX, y: y + 8, width: width, height: rowHeight - 16)
            let path = Path(roundedRect: rect, cornerRadius: 6)
            let isSelected = segment.id == selectedVideoSegmentID

            context.fill(path, with: .color(TimelineTrackType.video.color.opacity(0.85)))
            context.stroke(
                path,
                with: .color(isSelected ? .white : Color.white.opacity(0.32)),
                lineWidth: isSelected ? 2 : 1
            )

            var clipped = context
            clipped.clip(to: path)
            clipped.draw(
                Text("\(Image(systemName: "film.fill")) \(segment.sourceName)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white),
                at: CGPoint(x: rect.minX + 8, y: rect.midY),
                anchor: .leading
            )
        }
    }

    private func drawMatchRow(
        context: GraphicsContext,
        y: CGFloat,
        xFor: (Double) -> CGFloat,
        pps: CGFloat,
        visibleStart: Double,
        visibleEnd: Double
    ) {
        let sorted = matchSegments.sorted { lhs, rhs in
            if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
            return lhs.endTime < rhs.endTime
        }

        // 選んでいる帯は、引いている最中だけ指についてくるように見せる
        func previewed(_ segment: MatchSegment) -> (start: Double, end: Double) {
            var start = segment.startTime
            var end = segment.endTime
            let isSelected = segment.selectionKey != nil && segment.selectionKey == selectedMatchSelection
            guard isSelected else { return (start, end) }

            if segment.isStoppage {
                switch dragPreview.mode {
                case .move:
                    let length = end - start
                    start = max(0, start + dragPreview.delta)
                    end = start + length
                case .start:
                    start = min(max(0, start + dragPreview.delta), end - 1)
                case .end:
                    end = max(start + 1, end + dragPreview.delta)
                case nil:
                    break
                }
            } else if segment.isHalfTime, dragPreview.mode == .end {
                end = max(start, end + dragPreview.delta)
            } else if segment.isHalfEnd, dragPreview.mode == .end {
                end = max(start + 1, end + dragPreview.delta)
            }

            return (start, end)
        }

        // ハーフのあいだの空き(ハーフタイム)は破線で示す
        if sorted.count >= 2 {
            for index in 0..<(sorted.count - 1) {
                let current = sorted[index]
                let next = sorted[index + 1]
                guard next.startTime > current.endTime + 0.5,
                      next.startTime > visibleStart - 2,
                      current.endTime < visibleEnd + 2 else { continue }

                let rect = CGRect(
                    x: xFor(current.endTime),
                    y: y + 12,
                    width: max(20, CGFloat(next.startTime - current.endTime) * pps),
                    height: rowHeight - 24
                )
                context.stroke(
                    Path(roundedRect: rect, cornerRadius: 5),
                    with: .color(Color.white.opacity(0.26)),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
                context.draw(
                    Text(current.halfType == next.halfType ? "空き" : "ハーフタイム")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.58)),
                    at: CGPoint(x: rect.midX, y: rect.midY)
                )
            }
        }

        let matchColor = TimelineTrackType.match.color
        let stoppageColor = TimelineTrackType.stoppage.color
        let halfTimeColor = TimelineTrackType.halfTime.color
        for segment in sorted {
            let times = previewed(segment)
            guard times.end > visibleStart - 2, times.start < visibleEnd + 2 else { continue }

            let isSelected = segment.selectionKey != nil && segment.selectionKey == selectedMatchSelection
            let isBreak = segment.isStoppage || segment.isHalfTime
            let color = segment.isHalfTime ? halfTimeColor : (segment.isStoppage ? stoppageColor : matchColor)
            let startX = xFor(times.start)
            let width = max(isBreak ? 14 : 34, CGFloat(times.end - times.start) * pps)
            let rect = CGRect(x: startX, y: y + 9, width: width, height: rowHeight - 18)
            let path = Path(roundedRect: rect, cornerRadius: 6)

            context.fill(
                path,
                with: .linearGradient(
                    Gradient(colors: [color.opacity(isBreak ? 0.72 : 0.48), color.opacity(isBreak ? 0.42 : 0.18)]),
                    startPoint: CGPoint(x: rect.minX, y: rect.midY),
                    endPoint: CGPoint(x: rect.maxX, y: rect.midY)
                )
            )
            context.stroke(
                path,
                with: .color(isSelected ? Color.white : color.opacity(0.95)),
                lineWidth: isSelected ? 2 : 1
            )

            var clipped = context
            clipped.clip(to: path)
            clipped.draw(
                Text(segment.displayLabel.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.94)),
                at: CGPoint(x: rect.minX + 8, y: rect.midY),
                anchor: .leading
            )
        }
    }
}

struct TimelineTrackLabelView: View {
    var trackType: TimelineTrackType
    var isSelected: Bool = false
    var onTap: (() -> Void)? = nil

    var body: some View {
        let label = HStack(spacing: 8) {
            Image(systemName: trackType.systemImage)
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(trackType.color)
                .frame(width: 28)

            Text(trackType.title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(isSelected ? 0.95 : 0.66))
                .lineLimit(1)
                .minimumScaleFactor(0.78)

            Spacer(minLength: 0)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .background(isSelected ? trackType.color.opacity(0.24) : Color.clear)
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle()
                    .fill(trackType.color)
                    .frame(width: 3)
            }
        }

        if let onTap {
            Button(action: onTap) {
                label
            }
            .buttonStyle(.plain)
        } else {
            label
        }
    }
}

struct TimelineClipResizeHandle: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.white.opacity(0.90))
            .frame(width: 14, height: 32)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.black.opacity(0.20), lineWidth: 1)
            )
            .shadow(color: Color.white.opacity(0.35), radius: 4)
    }
}
