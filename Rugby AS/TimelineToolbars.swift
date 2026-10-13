// TimelineEditorView.swift から分割(中身は変更なし)

import AVFoundation
import Combine
import CoreTransferable
import PhotosUI
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// タイムラインのすぐ下に置く操作バー。
// キックオフ・試合時間・分割をここにまとめる。
// (タイムラインの上に浮かせるとクリップや目盛りに重なってしまうため)
struct TimelineEditToolbarView: View {
    var showsMatchButtons: Bool
    var hasKickoffAnchor: Bool
    var canSplit: Bool
    @Binding var isPaletteVisible: Bool
    var onKickoff: () -> Void
    var onClockSettings: () -> Void
    var onSplit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if showsMatchButtons {
                chipButton(
                    title: "キックオフ",
                    systemImage: hasKickoffAnchor ? "flag.fill" : "flag",
                    isOn: hasKickoffAnchor,
                    action: onKickoff
                )

                chipButton(
                    title: "試合時間",
                    systemImage: "timer",
                    isOn: false,
                    action: onClockSettings
                )
            }

            Spacer(minLength: 4)

            paletteToggle

            Spacer(minLength: 4)

            splitButton
        }
        .frame(height: 44)
        .simultaneousGesture(paletteDragGesture)
    }

    // 記録ボタンの出し入れ(ここを下へ引いても畳める)
    private var paletteToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) { isPaletteVisible.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isPaletteVisible ? "chevron.down" : "chevron.up")
                    .font(.system(size: 11, weight: .bold))
                Text(isPaletteVisible ? "隠す" : "ボタン")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(Color.white.opacity(0.84))
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(Capsule().fill(Color.white.opacity(0.10)))
            .overlay(Capsule().stroke(Color.white.opacity(0.20), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // 分割(はさみ)。編集中いちばん使うので、指の届く下側の右端に置く。
    private var splitButton: some View {
        Button(action: onSplit) {
            HStack(spacing: 5) {
                Image(systemName: "scissors")
                    .font(.system(size: 15, weight: .bold))
                Text("分割")
                    .font(.system(size: 13, weight: .black, design: .rounded))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Capsule().fill(Color.white.opacity(canSplit ? 0.20 : 0.06)))
            .overlay(Capsule().stroke(Color.white.opacity(canSplit ? 0.60 : 0.16), lineWidth: 1))
            .opacity(canSplit ? 1 : 0.5)
        }
        .buttonStyle(.plain)
    }

    private func chipButton(
        title: String,
        systemImage: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .bold))
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(isOn ? Color(red: 0.16, green: 0.78, blue: 0.55) : Color.white.opacity(0.88))
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // このバーを下へ引くと記録ボタンを畳む・上へ引くと戻す
    private var paletteDragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onEnded { value in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                if value.translation.height > 30 {
                    withAnimation(.easeInOut(duration: 0.22)) { isPaletteVisible = false }
                } else if value.translation.height < -30 {
                    withAnimation(.easeInOut(duration: 0.22)) { isPaletteVisible = true }
                }
            }
    }
}

struct BottomToolPaletteView: View {
    @ObservedObject var viewModel: TimelineEditorViewModel
    @Binding var isVisible: Bool
    var onToolTap: (TimelineTrackType) -> Void

    // 下へスライドして畳んでいる最中の、指についてくる量
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        toolRow
            .offset(y: max(0, dragOffset))
            .simultaneousGesture(hideByDragGesture)
    }

    // カードごと下へスライドすると畳む。
    // 途中まで引いて戻したときは、元の位置に戻す。
    private var hideByDragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                // 横向きの動きはボタン列の横スクロールなので、縦のときだけ受け取る
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                dragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                let isVertical = abs(value.translation.height) > abs(value.translation.width)
                let pulledEnough = isVertical
                    && (value.translation.height > 40 || value.predictedEndTranslation.height > 90)
                withAnimation(.easeInOut(duration: 0.22)) {
                    dragOffset = 0
                    if pulledEnough { isVisible = false }
                }
            }
    }

    private var toolRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(TimelineTrackType.toolPalette) { tool in
                    VStack(spacing: 7) {
                        Image(systemName: tool.systemImage)
                            .font(.system(size: 26, weight: .bold))
                            .frame(height: 30)

                        Text(tool.title)
                            .font(.system(size: 14, weight: .black, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.64)
                    }
                    .foregroundStyle(.white)
                    .frame(width: 68, height: 80)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(tool.color.gradient)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(
                                viewModel.selectedTool == tool ? Color.white : Color.white.opacity(0.16),
                                lineWidth: viewModel.selectedTool == tool ? 3 : 1
                            )
                    )
                    .shadow(
                        color: viewModel.selectedTool == tool ? tool.color.opacity(0.62) : Color.black.opacity(0.24),
                        radius: viewModel.selectedTool == tool ? 12 : 5,
                        x: 0,
                        y: 5
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 9))
                    .onTapGesture {
                        onToolTap(tool)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .frame(height: 98)
    }
}
