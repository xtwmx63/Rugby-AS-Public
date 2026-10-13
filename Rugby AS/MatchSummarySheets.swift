// MatchSummaryView.swift から分割(中身は変更なし)

import SwiftData
import SwiftUI
import UIKit

// 生成したサマリー画像のプレビューと共有
struct SummaryImageShareSheet: View {
    let image: UIImage
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("画像で共有")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(
                        item: Image(uiImage: image),
                        preview: SharePreview(title, image: Image(uiImage: image))
                    )
                }
            }
        }
    }
}

// 得点の時刻(前後半・分・秒)を手動で修正するシート。
// 得点経過リストの各行の時刻をタップして開く。
// (種類やチームまで直したいときは「編集」のプレー一覧を使う)
struct ScoreTimeEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var event: StatEvent
    let onSave: () -> Void

    @State private var half: Int
    @State private var minute: Int
    @State private var second: Int

    init(event: StatEvent, onSave: @escaping () -> Void) {
        self._event = Bindable(wrappedValue: event)
        self.onSave = onSave
        let total = max(0, event.seconds)
        self._half = State(initialValue: event.half >= 1 ? 1 : 0)
        self._minute = State(initialValue: total / 60)
        self._second = State(initialValue: total % 60)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("前半 / 後半") {
                    Picker("ハーフ", selection: $half) {
                        Text("前半").tag(0)
                        Text("後半").tag(1)
                    }
                    .pickerStyle(.segmented)
                }

                Section("時刻") {
                    Stepper(value: $minute, in: 0...200) {
                        HStack {
                            Text("分")
                            Spacer()
                            Text("\(minute)").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    Stepper(value: $second, in: 0...59) {
                        HStack {
                            Text("秒")
                            Spacer()
                            Text(String(format: "%02d", second)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text("表示")
                        Spacer()
                        Text("\(half == 1 ? "後半" : "前半") \(minute):\(String(format: "%02d", second))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("得点の時刻")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        event.half = half
                        event.seconds = minute * 60 + second
                        onSave()
                    }
                    .fontWeight(.bold)
                }
            }
        }
    }
}

// 得点経過チャートのHT(ハーフタイム)区切りに使う縦の点線
struct VerticalDashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}
