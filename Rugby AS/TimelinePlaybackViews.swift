// TimelineEditorView.swift から分割(中身は変更なし)

import AVFoundation
import Combine
import CoreTransferable
import PhotosUI
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct TimelineHeaderView: View {
    var onBack: () -> Void
    var onExport: () -> Void

    var body: some View {
        HStack {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Color.white.opacity(0.09)))
                    .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 1))
            }

            Spacer()

            Text("タイムライン編集")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            Spacer()

            Button(action: onExport) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Color.white.opacity(0.09)))
                    .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 1))
            }
        }
        .frame(height: 54)
    }
}

struct VideoPreviewCard: View {
    var videoSegments: [VideoSegment]
    var player: AVPlayer?
    var selectedVideoSegmentID: UUID?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black

                if let player {
                    TimelineVideoPlayerView(player: player)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "film.stack.fill")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.58))
                        Text("動画を追加してください")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.72))
                    }
                }

                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        ForEach(videoSegments) { segment in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(segment.id == selectedVideoSegmentID ? Color.white.opacity(0.80) : Color.white.opacity(0.24))
                                .frame(
                                    width: max(34, proxy.size.width * CGFloat((segment.endTime - segment.startTime) / 960) * 0.22),
                                    height: 4
                                )
                        }
                        Spacer()
                    }
                    .padding(14)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .shadow(color: Color.black.opacity(0.30), radius: 18, x: 0, y: 10)
        }
    }
}

struct PlaybackControlBar: View {
    var currentVideoTime: Double
    var videoDuration: Double
    var isPlaying: Bool
    var canUndo: Bool
    var canRedo: Bool
    var onPlayPause: () -> Void
    var onUndo: () -> Void
    var onRedo: () -> Void

    var body: some View {
        HStack {
            Text("\(TimelineTimeFormat.videoClock(currentVideoTime)) / \(TimelineTimeFormat.duration(videoDuration))")
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onPlayPause) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .background(Circle().fill(Color.white.opacity(0.12)))
                    .overlay(Circle().stroke(Color.white.opacity(0.20), lineWidth: 1))
            }

            HStack(spacing: 12) {
                Button(action: onUndo) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 22, weight: .semibold))
                        .frame(width: 42, height: 42)
                }
                .disabled(!canUndo)
                .opacity(canUndo ? 1 : 0.34)

                Button(action: onRedo) {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.system(size: 22, weight: .semibold))
                        .frame(width: 42, height: 42)
                }
                .disabled(!canRedo)
                .opacity(canRedo ? 1 : 0.34)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(red: 0.01, green: 0.06, blue: 0.12).opacity(0.86))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}

// AVPlayer をそのまま表示するだけの薄い入れ物(プレー一覧の編集画面でも使う)
struct TimelineVideoPlayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> TimelineVideoPlayerContainerView {
        let view = TimelineVideoPlayerContainerView()
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: TimelineVideoPlayerContainerView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}

final class TimelineVideoPlayerContainerView: UIView {
    override static var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}
