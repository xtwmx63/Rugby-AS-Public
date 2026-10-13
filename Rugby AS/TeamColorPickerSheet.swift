// TeamViews.swift から分割(中身は変更なし)

import CoreImage
import PhotosUI
import SwiftData
import SwiftUI
import Vision

// MARK: - Team color picker

struct TeamColorPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let team: Team
    // 選んでいる色はこの画面の中だけで持ち、閉じるときにチームへ1回だけ反映する。
    // タップのたびにチームの色を書き換えると、裏のチーム画面・チーム一覧・試合一覧まで毎回描き直されて重い。
    // (チームの色を読む処理自体も遅いので、ボタンごとに読まないためでもある)
    @State private var selectedHex: String?

    init(team: Team) {
        self.team = team
        _selectedHex = State(initialValue: team.colorHex)
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        // NavigationStack は作るのが重く、シートが開くときにもたつくので、見出しは自前で並べる
        VStack(spacing: 0) {
            ZStack {
                Text("チームカラー")
                    .font(.headline)
                    .foregroundStyle(.white)
                Button("完了") { dismiss() }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 6)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    colorButton(hex: nil, name: "未設定")
                    ForEach(TeamColorPalette.options) { option in
                        colorButton(hex: option.hex, name: option.name, outlined: option.isDark)
                    }
                }
                .padding(18)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
        // 「完了」でも下へのスワイプでも、閉じたときに反映して保存する
        .onDisappear {
            guard team.colorHex != selectedHex else { return }
            team.colorHex = selectedHex
            AppPersistence.save(modelContext)
        }
    }

    private func colorButton(hex: String?, name: String, outlined: Bool = false) -> some View {
        let isSelected = selectedHex == hex
        return Button {
            selectedHex = hex
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 74)

                    if let hex, let color = Color(hex: hex) {
                        Circle()
                            .fill(color)
                            .frame(width: 44, height: 44)
                            // 黒・紺は黒い背景に溶けるので、細い縁で丸の形を見せる
                            .overlay {
                                if outlined {
                                    Circle().stroke(Color.white.opacity(0.35), lineWidth: 1)
                                }
                            }
                    } else {
                        Circle()
                            .stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 2, dash: [4]))
                            .frame(width: 44, height: 44)
                            .overlay(
                                Image(systemName: "circle.slash")
                                    .foregroundStyle(.white.opacity(0.55))
                            )
                    }

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .background(Circle().fill(Color.black))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(7)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(isSelected ? Color.white : Color.white.opacity(0.08), lineWidth: isSelected ? 2 : 1)
                )

                Text(name)
                    .font(.caption.weight(isSelected ? .black : .semibold))
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.65))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .buttonStyle(.plain)
    }
}
