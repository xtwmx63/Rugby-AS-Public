// TimelineEditorView.swift から分割(中身は変更なし)

import AVFoundation
import Combine
import CoreTransferable
import PhotosUI
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
final class TimelineEditorViewModel: ObservableObject {
    @Published var currentVideoTime: Double
    @Published var videoDuration: Double
    @Published var selectedTool: TimelineTrackType
    @Published var selectedClipID: UUID?
    @Published var visibleTracks: [TimelineTrackType]
    @Published var timelineClips: [TimelineClip]
    @Published var matchSegments: [MatchSegment]
    @Published var videoSegments: [VideoSegment]
    @Published var undoStack: [TimelineState]
    @Published var redoStack: [TimelineState]
    @Published var isPlaying: Bool
    @Published var selectedVideoSegmentID: UUID?
    @Published var selectedMatchSelection: MatchSelection?

    init(
        currentVideoTime: Double,
        videoDuration: Double,
        selectedTool: TimelineTrackType,
        selectedClipID: UUID?,
        visibleTracks: [TimelineTrackType],
        timelineClips: [TimelineClip],
        matchSegments: [MatchSegment],
        videoSegments: [VideoSegment],
        undoStack: [TimelineState] = [],
        redoStack: [TimelineState] = [],
        isPlaying: Bool = false,
        selectedVideoSegmentID: UUID? = nil
    ) {
        self.currentVideoTime = currentVideoTime
        self.videoDuration = videoDuration
        self.selectedTool = selectedTool
        self.selectedClipID = selectedClipID
        self.visibleTracks = visibleTracks
        self.timelineClips = timelineClips
        self.matchSegments = matchSegments
        self.videoSegments = videoSegments
        self.undoStack = undoStack
        self.redoStack = redoStack
        self.isPlaying = isPlaying
        self.selectedVideoSegmentID = selectedVideoSegmentID
    }

    static func empty() -> TimelineEditorViewModel {
        TimelineEditorViewModel(
            currentVideoTime: 0,
            videoDuration: 16 * 60,
            selectedTool: .home,
            selectedClipID: nil,
            visibleTracks: TimelineTrackType.timelineTracks,
            timelineClips: [],
            matchSegments: [],
            videoSegments: []
        )
    }

    static func mock() -> TimelineEditorViewModel {
        let selectedClipID = UUID()
        return TimelineEditorViewModel(
            currentVideoTime: 335.9,
            videoDuration: 16 * 60,
            selectedTool: .home,
            selectedClipID: selectedClipID,
            visibleTracks: TimelineTrackType.timelineTracks,
            timelineClips: [
                TimelineClip(id: selectedClipID, trackType: .home, startTime: 8, endTime: 318, title: "HOME", isSelected: true),
                TimelineClip(id: UUID(), trackType: .home, startTime: 342, endTime: 408, title: "HOME", isSelected: false),
                TimelineClip(id: UUID(), trackType: .home, startTime: 535, endTime: 604, title: "HOME", isSelected: false),
                TimelineClip(id: UUID(), trackType: .away, startTime: 18, endTime: 92, title: "AWAY", isSelected: false),
                TimelineClip(id: UUID(), trackType: .away, startTime: 316, endTime: 397, title: "AWAY", isSelected: false),
                TimelineClip(id: UUID(), trackType: .away, startTime: 412, endTime: 604, title: "AWAY", isSelected: false),
                TimelineClip(id: UUID(), trackType: .bip, startTime: 54, endTime: 152, title: "BIP", isSelected: false),
                TimelineClip(id: UUID(), trackType: .bip, startTime: 546, endTime: 648, title: "BIP", isSelected: false),
                TimelineClip(id: UUID(), trackType: .tryEvent, startTime: 454, endTime: 482, title: "TRY", isSelected: false),
                TimelineClip(id: UUID(), trackType: .tryEvent, startTime: 826, endTime: 852, title: "TRY", isSelected: false),
                TimelineClip(id: UUID(), trackType: .conv, startTime: 491, endTime: 516, title: "CONV", isSelected: false),
                TimelineClip(id: UUID(), trackType: .lo, startTime: 116, endTime: 150, title: "LO", isSelected: false),
                TimelineClip(id: UUID(), trackType: .lo, startTime: 698, endTime: 735, title: "LO", isSelected: false),
                TimelineClip(id: UUID(), trackType: .scr, startTime: 238, endTime: 286, title: "SCR", isSelected: false),
                TimelineClip(id: UUID(), trackType: .scr, startTime: 760, endTime: 812, title: "SCR", isSelected: false)
            ],
            matchSegments: [
                MatchSegment(id: UUID(), halfType: .first, startTime: 22, endTime: 442, displayLabel: "07:00\n(前半)"),
                MatchSegment(id: UUID(), halfType: .second, startTime: 568, endTime: 958, displayLabel: "~09:00\n(後半)")
            ],
            videoSegments: [
                VideoSegment(id: UUID(), sourceName: "V1", startTime: 0, endTime: 320),
                VideoSegment(id: UUID(), sourceName: "V2", startTime: 372, endTime: 960)
            ],
            undoStack: [],
            redoStack: []
        )
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func togglePlayback() {
        isPlaying.toggle()
    }

    func selectTool(_ tool: TimelineTrackType) {
        selectedTool = tool
        if tool == .deleteTool {
            deleteSelectedClip()
        }
    }

    func activateTool(_ tool: TimelineTrackType) {
        selectedTool = tool
        if tool == .deleteTool {
            deleteSelectedClip()
        } else {
            addClip(on: tool)
        }
    }

    func selectClip(_ id: UUID?) {
        selectedClipID = id
        if id != nil {
            selectedVideoSegmentID = nil
            selectedMatchSelection = nil
        }
        timelineClips = timelineClips.map { clip in
            var updated = clip
            updated.isSelected = clip.id == id
            return updated
        }
    }

    func selectVideoSegment(_ id: UUID?) {
        selectedVideoSegmentID = id
        if id != nil {
            selectClip(nil)
            selectedMatchSelection = nil
        }
    }

    func selectMatchSelection(_ selection: MatchSelection?) {
        selectedMatchSelection = selection
        if selection != nil {
            selectClip(nil)
            selectedVideoSegmentID = nil
        }
    }

    /// いま選んでいる MATCH の帯(中断なら中断の帯、ハーフなら右端の帯)
    func selectedMatchSegment() -> MatchSegment? {
        guard let selection = selectedMatchSelection else { return nil }
        switch selection {
        case .stoppage:
            return matchSegments.first { $0.selectionKey == selection }
        case .half:
            return matchSegments.first { $0.selectionKey == selection && $0.isHalfEnd }
        case .halfTime:
            return matchSegments.first { $0.selectionKey == selection }
        }
    }

    func setTimelineClips(_ clips: [TimelineClip]) {
        visibleTracks = TimelineTrackType.tracks(for: clips)
        selectedClipID = selectedClipID.flatMap { id in
            clips.contains(where: { $0.id == id }) ? id : nil
        }
        timelineClips = clips.map { clip in
            var updated = clip
            updated.isSelected = clip.id == selectedClipID
            return updated
        }
    }

    func appendPersistedClip(_ clip: TimelineClip) {
        saveForUndo()
        var selectedClip = clip
        selectedClip.isSelected = true
        timelineClips.append(selectedClip)
        selectClip(selectedClip.id)
    }

    func setMatchSegments(_ segments: [MatchSegment]) {
        matchSegments = segments
    }

    func addClip(on trackType: TimelineTrackType) {
        guard trackType.isTimelineTrack, trackType != .video, trackType != .match else { return }
        saveForUndo()

        let length = defaultClipLength(for: trackType)
        let start = min(max(0, currentVideoTime), videoDuration - 1)
        let end = min(videoDuration, start + length)
        let clip = TimelineClip(
            id: UUID(),
            trackType: trackType,
            startTime: start,
            endTime: end,
            title: trackType.title,
            isSelected: true
        )
        timelineClips.append(clip)
        selectClip(clip.id)
    }

    @discardableResult
    func addVideoSegment(sourceName: String, duration: Double, fileName: String? = nil) -> VideoSegment {
        saveForUndo()
        let start = videoSegments.map(\.endTime).max().map { $0 + 12 } ?? 0
        let end = start + max(1, duration)
        let segment = VideoSegment(
            id: UUID(),
            sourceName: sourceName,
            startTime: start,
            endTime: end,
            fileName: fileName
        )
        videoSegments.append(segment)
        selectVideoSegment(segment.id)
        videoDuration = max(videoDuration, end)
        return segment
    }

    func setVideoSegments(_ segments: [VideoSegment]) {
        videoSegments = segments
        selectedVideoSegmentID = selectedVideoSegmentID.flatMap { id in
            segments.contains(where: { $0.id == id }) ? id : nil
        } ?? segments.first?.id
        if let maxEndTime = segments.map(\.endTime).max() {
            videoDuration = max(16 * 60, maxEndTime)
            currentVideoTime = min(currentVideoTime, videoDuration)
        }
    }

    func deleteSelectedVideoSegment() -> VideoSegment? {
        guard let selectedVideoSegmentID,
              let index = videoSegments.firstIndex(where: { $0.id == selectedVideoSegmentID }) else { return nil }
        saveForUndo()
        let removed = videoSegments.remove(at: index)
        self.selectedVideoSegmentID = videoSegments.first?.id
        videoDuration = max(16 * 60, videoSegments.map(\.endTime).max() ?? 16 * 60)
        return removed
    }

    func videoSegment(id: UUID?) -> VideoSegment? {
        guard let id else { return nil }
        return videoSegments.first { $0.id == id }
    }

    func clip(id: UUID?) -> TimelineClip? {
        guard let id else { return nil }
        return timelineClips.first { $0.id == id }
    }

    func deleteSelectedClip() {
        guard let selectedClipID,
              timelineClips.contains(where: { $0.id == selectedClipID }) else { return }
        saveForUndo()
        timelineClips.removeAll { $0.id == selectedClipID }
        self.selectedClipID = nil
    }

    @discardableResult
    func adjustSelectedClipStart(by delta: Double) -> Bool {
        guard let selectedClipID,
              let index = timelineClips.firstIndex(where: { $0.id == selectedClipID }) else { return false }
        let limit = timelineClips[index].endTime - Self.minimumClipLength
        let newStart = Self.snapped(min(max(0, timelineClips[index].startTime + delta), limit))
        guard abs(newStart - timelineClips[index].startTime) > 0.001 else { return false }
        saveForUndo()
        timelineClips[index].startTime = newStart
        return true
    }

    @discardableResult
    func adjustSelectedClipEnd(by delta: Double) -> Bool {
        guard let selectedClipID,
              let index = timelineClips.firstIndex(where: { $0.id == selectedClipID }) else { return false }
        let limit = timelineClips[index].startTime + Self.minimumClipLength
        let newEnd = Self.snapped(max(min(videoDuration, timelineClips[index].endTime + delta), limit))
        guard abs(newEnd - timelineClips[index].endTime) > 0.001 else { return false }
        saveForUndo()
        timelineClips[index].endTime = newEnd
        return true
    }

    // 選択中のクリップを、長さを保ったまま左右へ動かす
    @discardableResult
    func moveSelectedClip(by delta: Double) -> Bool {
        guard let selectedClipID,
              let index = timelineClips.firstIndex(where: { $0.id == selectedClipID }) else { return false }
        let length = timelineClips[index].endTime - timelineClips[index].startTime
        let newStart = Self.snapped(min(max(0, timelineClips[index].startTime + delta), max(0, videoDuration - length)))
        guard abs(newStart - timelineClips[index].startTime) > 0.001 else { return false }
        saveForUndo()
        timelineClips[index].startTime = newStart
        timelineClips[index].endTime = newStart + length
        return true
    }

    @discardableResult
    func adjustSelectedClipStart(to newStart: Double) -> Bool {
        guard let selectedClipID,
              let index = timelineClips.firstIndex(where: { $0.id == selectedClipID }) else { return false }
        let clampedStart = Self.snapped(min(max(0, newStart), timelineClips[index].endTime - Self.minimumClipLength))
        guard abs(clampedStart - timelineClips[index].startTime) > 0.001 else { return false }
        saveForUndo()
        timelineClips[index].startTime = clampedStart
        return true
    }

    @discardableResult
    func adjustSelectedClipEnd(to newEnd: Double) -> Bool {
        guard let selectedClipID,
              let index = timelineClips.firstIndex(where: { $0.id == selectedClipID }) else { return false }
        let clampedEnd = Self.snapped(max(min(videoDuration, newEnd), timelineClips[index].startTime + Self.minimumClipLength))
        guard abs(clampedEnd - timelineClips[index].endTime) > 0.001 else { return false }
        saveForUndo()
        timelineClips[index].endTime = clampedEnd
        return true
    }

    // MARK: 分割(はさみ)

    // 分割や伸縮でできる帯の、いちばん短い長さ(0.1秒きざみで編集できる)
    static let minimumClipLength: Double = 0.1

    // 0.1秒きざみにそろえる(細かい端数を持ち回らないため)
    static func snapped(_ seconds: Double) -> Double {
        (seconds * 10).rounded() / 10
    }

    func canSplit(_ clip: TimelineClip, at time: Double) -> Bool {
        // A score is one event: splitting its visible preview would duplicate points.
        guard clip.trackType.isIntervalTrack,
              TimelineEventTiming.canSplit(category: clip.details?.category ?? "possession") else { return false }
        let margin = Self.minimumClipLength
        return time >= clip.startTime + margin && time <= clip.endTime - margin
    }

    // 再生ヘッドの位置で切れる帯を1つ決める。
    // (1) 帯を選んでいるなら、切るのは必ずその帯だけ
    //     (選んだものと違う帯が切れると分かりにくいため)
    // (2) 何も選んでいないときは、再生ヘッドが乗っている帯が
    //     ちょうど1つのときだけ、その帯を切る。
    //     2つ以上あるときは、どれを切りたいのか分からないので何も返さない。
    func splitTargetClip(at time: Double) -> TimelineClip? {
        if let selected = clip(id: selectedClipID) {
            return canSplit(selected, at: time) ? selected : nil
        }
        let candidates = timelineClips.filter { canSplit($0, at: time) }
        return candidates.count == 1 ? candidates.first : nil
    }

    // 帯を再生ヘッドの位置で2つに切る。
    // 左は元の帯をそのまま短くし、右は新しい帯として足す(中身は引き継ぐ)。
    func splitClip(id: UUID, at time: Double) -> (left: TimelineClip, right: TimelineClip)? {
        guard let index = timelineClips.firstIndex(where: { $0.id == id }),
              canSplit(timelineClips[index], at: time) else { return nil }
        saveForUndo()

        let original = timelineClips[index]
        let cut = Self.snapped(time)
        var left = original
        left.endTime = cut

        let right = TimelineClip(
            id: UUID(),
            trackType: original.trackType,
            startTime: cut,
            endTime: original.endTime,
            title: original.title,
            isSelected: true,
            details: original.details
        )

        timelineClips[index] = left
        timelineClips.insert(right, at: index + 1)
        // 切った直後は右側を選んでおく(そのまま続けて動かせるように)
        selectClip(right.id)
        return (left, right)
    }

    func undo() {
        guard let previousState = undoStack.popLast() else { return }
        redoStack.append(snapshot())
        restore(previousState)
    }

    func redo() {
        guard let nextState = redoStack.popLast() else { return }
        undoStack.append(snapshot())
        restore(nextState)
    }

    var currentState: TimelineState {
        snapshot()
    }

    private func saveForUndo() {
        undoStack.append(snapshot())
        if undoStack.count > 50 {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    private func snapshot() -> TimelineState {
        TimelineState(
            timelineClips: timelineClips,
            matchSegments: matchSegments,
            videoSegments: videoSegments,
            selectedClipID: selectedClipID,
            selectedVideoSegmentID: selectedVideoSegmentID
        )
    }

    private func restore(_ state: TimelineState) {
        timelineClips = state.timelineClips
        visibleTracks = TimelineTrackType.tracks(for: state.timelineClips)
        matchSegments = state.matchSegments
        videoSegments = state.videoSegments
        selectedVideoSegmentID = state.selectedVideoSegmentID
        selectClip(state.selectedClipID)
        if state.selectedVideoSegmentID != nil {
            selectedVideoSegmentID = state.selectedVideoSegmentID
        }
    }

    private func defaultClipLength(for trackType: TimelineTrackType) -> Double {
        switch trackType {
        case .tryEvent, .conv, .pg, .dg, .lo, .scr:
            return 26
        default:
            return 58
        }
    }
}
