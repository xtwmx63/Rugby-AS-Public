// TimelineEditorView.swift から分割(中身は変更なし)

import AVFoundation
import Combine
import CoreTransferable
import PhotosUI
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum TimelineTimeFormat {
    static func videoClock(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let minutes = Int(clamped) / 60
        let wholeSeconds = Int(clamped) % 60
        let tenths = Int((clamped * 10).rounded(.down)) % 10
        return String(format: "%02d:%02d.%d", minutes, wholeSeconds, tenths)
    }

    static func duration(_ seconds: Double) -> String {
        let clamped = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }

    static func rulerMinute(_ minute: Int) -> String {
        String(format: "%02d:00", minute)
    }
}
// 記録の時刻(前半12:34)と映像を結びつけるための画面。
// 「キックオフの瞬間で止めてボタンを押す」だけで合わせられるようにしている。
struct MatchKickoffAnchorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let currentPosition: (anchor: MatchVideoAnchor, sourceName: String)?
    let anchors: [Int: MatchVideoAnchor]
    let onSet: (Int, MatchVideoAnchor?) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("記録の時刻と映像を結びつけます。キックオフの瞬間で映像を止めてから、下のボタンを押してください。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("いま映っている位置") {
                    if let currentPosition {
                        LabeledContent(
                            currentPosition.sourceName,
                            value: TimelineTimeFormat.videoClock(currentPosition.anchor.seconds)
                        )
                    } else {
                        Text("動画がありません")
                            .foregroundStyle(.secondary)
                    }
                }

                halfSection(half: 0, title: "前半のキックオフ")
                halfSection(half: 1, title: "後半のキックオフ")

                Section {
                    Text("後半を合わせていない場合は、前半の続きとして自動で見当をつけます。ズレていたら後半も合わせてください。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("キックオフ合わせ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func halfSection(half: Int, title: String) -> some View {
        Section(title) {
            if let anchor = anchors[half] {
                LabeledContent("設定済み", value: TimelineTimeFormat.videoClock(anchor.seconds))
                Button("解除する", role: .destructive) { onSet(half, nil) }
            } else {
                Text("未設定")
                    .foregroundStyle(.secondary)
            }

            Button("いまの位置をここにする") {
                if let currentPosition { onSet(half, currentPosition.anchor) }
            }
            .disabled(currentPosition == nil)
        }
    }
}

struct TimelineImportedMovie: Transferable, Sendable {
    let fileName: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            guard let url = VideoStorage.url(named: movie.fileName) else {
                throw TimelineVideoImportError.unavailable
            }
            return SentTransferredFile(url)
        } importing: { receivedFile in
            let fileName = try VideoStorage.save(from: receivedFile.file) { fraction, copiedBytes, totalBytes in
                NotificationCenter.default.post(
                    name: .videoStorageCopyProgress,
                    object: nil,
                    userInfo: [
                        "fraction": fraction,
                        "copiedBytes": copiedBytes,
                        "totalBytes": totalBytes
                    ]
                )
            }
            return TimelineImportedMovie(fileName: fileName)
        }
    }
}

enum TimelineVideoImportError: Error {
    case unavailable
}


struct MatchClockSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let initialSettings: MatchClockSettings
    let currentTimelineSecond: Double
    let currentHalf: Int?
    let secondHalfTimelineOffset: Int
    let onSave: (MatchClockSettings) -> Void

    @State private var draft: MatchClockSettings

    init(
        initialSettings: MatchClockSettings,
        currentTimelineSecond: Double,
        currentHalf: Int?,
        secondHalfTimelineOffset: Int,
        onSave: @escaping (MatchClockSettings) -> Void
    ) {
        self.initialSettings = initialSettings
        self.currentTimelineSecond = currentTimelineSecond
        self.currentHalf = currentHalf
        self.secondHalfTimelineOffset = secondHalfTimelineOffset
        self.onSave = onSave
        _draft = State(initialValue: initialSettings.normalized())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Capsule()
                    .fill(Color.secondary.opacity(0.32))
                    .frame(width: 72, height: 5)
                    .frame(maxWidth: .infinity)

                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("試合時計")
                            .font(.title2.weight(.black))
                        Text("前後半の長さと停止区間")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("閉じる") {
                        dismiss()
                    }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.blue)
                }

                section("形式") {
                    HStack(spacing: 8) {
                        presetButton("15人制 40分", seconds: 40 * 60)
                        presetButton("7人制 7分", seconds: 7 * 60)
                    }
                }

                section("前後半") {
                    halfDurationEditor(title: "前半", half: 0)
                    halfDurationEditor(title: "後半", half: 1)
                }

                section("停止区間") {
                    Button {
                        addStopAtCurrentPosition()
                    } label: {
                        Label("現在位置で停止を追加", systemImage: "plus.circle.fill")
                            .font(.headline.weight(.black))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(Color.orange)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)

                    if draft.stoppages.isEmpty {
                        Text("停止区間なし")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(draft.stoppagesForTimelineScope(nil)) { stoppage in
                                stoppageRow(stoppage)
                            }
                        }
                    }
                }

                Button {
                    onSave(draft.normalized())
                    dismiss()
                } label: {
                    Label("保存", systemImage: "checkmark.circle.fill")
                        .font(.headline.weight(.black))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
            .padding(20)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.black))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func presetButton(_ title: String, seconds: Int) -> some View {
        Button {
            draft.firstHalfSeconds = seconds
            draft.secondHalfSeconds = seconds
            draft = draft.normalized()
        } label: {
            Text(title)
                .font(.subheadline.weight(.black))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(Color.blue)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func halfDurationEditor(title: String, half: Int) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.headline.weight(.black))
                .frame(width: 52, alignment: .leading)

            Text(Self.timeText(draft.clockDuration(for: half)))
                .font(.system(size: 26, weight: .black, design: .monospaced))
                .frame(width: 96, alignment: .leading)

            Spacer(minLength: 4)

            smallButton("-1分", color: .orange) {
                adjustHalfDuration(half: half, delta: -60)
            }

            smallButton("+1分", color: .blue) {
                adjustHalfDuration(half: half, delta: 60)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func stoppageRow(_ stoppage: MatchClockStop) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button(halfLabel(stoppage.half)) {
                    updateStoppage(stoppage) { item in
                        item.half = item.half == 0 ? 1 : 0
                    }
                }
                .font(.caption.weight(.black))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Color.blue)
                .clipShape(Capsule())

                Text(Self.timeText(stoppage.clockSecond))
                    .font(.headline.weight(.black).monospacedDigit())

                Text("+\(Self.timeText(stoppage.durationSeconds))")
                    .font(.headline.weight(.black).monospacedDigit())
                    .foregroundStyle(.orange)

                Spacer()

                Button(role: .destructive) {
                    draft.stoppages.removeAll { $0.id == stoppage.id }
                } label: {
                    Image(systemName: "trash.fill")
                        .font(.headline.weight(.bold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                smallButton("-10秒", color: .orange) {
                    adjustStoppageClock(stoppage, delta: -10)
                }
                smallButton("+10秒", color: .blue) {
                    adjustStoppageClock(stoppage, delta: 10)
                }
                smallButton("-停止", color: .orange) {
                    adjustStoppageDuration(stoppage, delta: -10)
                }
                smallButton("+停止", color: .blue) {
                    adjustStoppageDuration(stoppage, delta: 10)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func smallButton(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.black).monospacedDigit())
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(color)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func adjustHalfDuration(half: Int, delta: Int) {
        draft.setClockDuration(draft.clockDuration(for: half) + delta, for: half)
    }

    private func addStopAtCurrentPosition() {
        let half: Int
        let localTimelineSecond: Int

        if let currentHalf {
            half = currentHalf
            localTimelineSecond = max(0, Int(currentTimelineSecond.rounded()))
        } else if currentTimelineSecond >= Double(secondHalfTimelineOffset) {
            half = 1
            localTimelineSecond = max(0, Int((currentTimelineSecond - Double(secondHalfTimelineOffset)).rounded()))
        } else {
            half = 0
            localTimelineSecond = max(0, Int(currentTimelineSecond.rounded()))
        }

        let clockSecond = draft.clockSecond(fromTimelineSecond: localTimelineSecond, half: half)
        draft.stoppages.append(
            MatchClockStop(
                half: half,
                clockSecond: clockSecond,
                durationSeconds: 30
            )
        )
        draft = draft.normalized()
    }

    private func adjustStoppageClock(_ stoppage: MatchClockStop, delta: Int) {
        updateStoppage(stoppage) { item in
            item.clockSecond += delta
        }
    }

    private func adjustStoppageDuration(_ stoppage: MatchClockStop, delta: Int) {
        updateStoppage(stoppage) { item in
            item.durationSeconds += delta
        }
    }

    private func updateStoppage(
        _ stoppage: MatchClockStop,
        transform: (inout MatchClockStop) -> Void
    ) {
        guard let index = draft.stoppages.firstIndex(where: { $0.id == stoppage.id }) else { return }
        transform(&draft.stoppages[index])
        draft = draft.normalized()
    }

    private func halfLabel(_ half: Int) -> String {
        half >= 1 ? "後半" : "前半"
    }

    private static func timeText(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
