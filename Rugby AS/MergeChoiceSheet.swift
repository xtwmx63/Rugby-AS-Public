//
//  MergeChoiceSheet.swift
//  Rugby AS
//
//  統合で「どちらを残すか」を選ぶ画面。2つを並べ、背番号・読み・出場の時期・大会などを出して、
//  同姓同名や似た名前でもどちらがどちらか分かるようにする。
//

import SwiftUI

struct MergeChoiceSheet: View {
    struct Option {
        let id: UUID
        let title: String
        let symbol: String
        let color: Color
        /// 見分けるための情報(背番号・読み・チーム・出場の時期・大会など)
        let lines: [String]
    }

    let heading: String
    let first: Option
    let second: Option
    /// 残す方のIDを渡す
    let onChoose: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("残す方を選んでください。選ばなかった方の記録は残す方に付け替わり、名前は別名として残ります。")
                        .font(.footnote)
                        .foregroundStyle(RugbyTheme.textSecondary)
                    optionCard(first, label: "A")
                    optionCard(second, label: "B")
                }
                .padding(16)
                .padContentWidth(640)
            }
            .background(RugbyTheme.background)
            .navigationTitle(heading)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(RugbyTheme.background, for: .navigationBar)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                        .foregroundStyle(RugbyTheme.textPrimary)
                }
            }
        }
        .preferredColorScheme(.light)
    }

    private func optionCard(_ option: Option, label: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Text(label)
                    .font(.caption.weight(.black))
                    .foregroundStyle(RugbyTheme.onAccent)
                    .frame(width: 24, height: 24)
                    .background(RugbyTheme.accent, in: Circle())
                Image(systemName: option.symbol)
                    .foregroundStyle(option.color)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(option.title)
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(RugbyTheme.textPrimary)
                    ForEach(Array(option.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(RugbyTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Button {
                onChoose(option.id)
                dismiss()
            } label: {
                Text("\(label) を残す")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(RugbyTheme.accent)
        }
        .padding(16)
        .background(RugbyTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(RugbyTheme.border, lineWidth: 1))
    }
}
