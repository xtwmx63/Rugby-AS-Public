//
//  DirectoryComponents.swift
//  Rugby AS
//
//  チーム一覧と大会一覧で同じ見た目にするための部品(フォルダの行・男女の切り替え・見出し)。
//

import SwiftUI

/// フォルダの行。アイコン・名前・件数。色の丸(中身の色)を添えられる。
struct DirectoryFolderRow: View {
    let symbol: String
    let title: String
    let count: Int
    var unit = ""
    var previewColors: [Color] = []

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(RugbyTheme.accent)
                .frame(width: 40, height: 40)
                .background(RugbyTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)

            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(RugbyTheme.textPrimary)
                .lineLimit(2)

            Spacer(minLength: 8)

            if !previewColors.isEmpty {
                // 先頭の4つの色を少しずつ重ねた丸
                HStack(spacing: -6) {
                    ForEach(Array(previewColors.prefix(4).enumerated()), id: \.offset) { _, color in
                        Circle()
                            .fill(color)
                            .frame(width: 14, height: 14)
                            .overlay(Circle().stroke(RugbyTheme.surface, lineWidth: 1.5))
                    }
                }
                .accessibilityHidden(true)
            }

            Text("\(count)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(RugbyTheme.textSecondary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)、\(count)\(unit)")
    }
}

/// 「すべて/男子/女子」の切り替え(空文字 = すべて)
struct GenderSwitchSection: View {
    @Binding var selection: String

    var body: some View {
        Section {
            Picker("男子・女子", selection: $selection) {
                Text("すべて").tag("")
                ForEach(RugbyGender.allCases) { gender in
                    Text(gender.displayName).tag(gender.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
            .listRowBackground(Color.clear)
        }
    }
}

/// 一覧の見出し(小さめ・大文字変換なし)
struct DirectorySectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(RugbyTheme.textSecondary)
            .textCase(nil)
    }
}
