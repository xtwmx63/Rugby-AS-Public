//
//  CompetitionFilter.swift
//  Rugby AS
//
//  「男子/女子」「カテゴリー(トップ・大学など)」「7人制/15人制」で試合を絞り込むメニュー。
//  条件そのもの(CompetitionFilter)は TournamentCategory.swift。試合一覧と分析の両方で使う。
//

import SwiftUI

/// 男女・カテゴリー・人数の3つのメニュー。選んでいるものは塗りつぶして目立たせる。
/// 3つ並ぶと狭い画面ではみ出すので、横にスクロールできるようにしている。
struct CompetitionFilterMenus: View {
    @Binding var filter: CompetitionFilter
    /// 選べるカテゴリー(大会で使われている名前)
    let categories: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            menus
        }
    }

    private var menus: some View {
        HStack(spacing: 8) {
            Menu {
                Button { filter.genderRaw = nil } label: { checkLabel("男子・女子", selected: filter.genderRaw == nil) }
                ForEach(RugbyGender.allCases) { gender in
                    Button { filter.genderRaw = gender.rawValue } label: {
                        checkLabel(gender.displayName, selected: filter.genderRaw == gender.rawValue)
                    }
                }
            } label: {
                chip(title: RugbyGender.displayName(for: filter.genderRaw) ?? "男女", isActive: filter.genderRaw != nil)
            }
            .accessibilityLabel("男子・女子で絞り込む")

            Menu {
                Button { filter.category = nil } label: { checkLabel("すべてのカテゴリー", selected: filter.category == nil) }
                ForEach(sortedCategories, id: \.self) { name in
                    Button { filter.category = name } label: { checkLabel(name, selected: filter.category == name) }
                }
                Button { filter.category = "" } label: { checkLabel("カテゴリー未設定", selected: filter.category == "") }
            } label: {
                chip(title: filter.category.map { $0.isEmpty ? "未設定" : $0 } ?? "カテゴリー",
                     isActive: filter.category != nil)
            }
            .accessibilityLabel("カテゴリーで絞り込む")

            Menu {
                Button { filter.variantRaw = nil } label: { checkLabel("7人制・15人制", selected: filter.variantRaw == nil) }
                ForEach(RugbyVariant.allCases) { variant in
                    Button { filter.variantRaw = variant.rawValue } label: {
                        checkLabel(variant.displayName, selected: filter.variantRaw == variant.rawValue)
                    }
                }
            } label: {
                chip(title: RugbyVariant.displayName(for: filter.variantRaw) ?? "7人制・15人制",
                     isActive: filter.variantRaw != nil)
            }
            .accessibilityLabel("7人制・15人制で絞り込む")

            if filter.isActive {
                Button { filter = CompetitionFilter() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(RugbyTheme.textSecondary)
                        .frame(width: 32, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("男女・カテゴリーの絞り込みを解除")
            }
        }
    }

    private var sortedCategories: [String] {
        Array(Set(categories.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
            .sorted { TournamentCategory.sortKey($0) < TournamentCategory.sortKey($1) }
    }

    @ViewBuilder
    private func checkLabel(_ title: String, selected: Bool) -> some View {
        if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    private func chip(title: String, isActive: Bool) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .black))
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(isActive ? RugbyTheme.onAccent : RugbyTheme.textPrimary)
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
        .background(isActive ? RugbyTheme.accent : RugbyTheme.surface, in: Capsule())
        .overlay(Capsule().stroke(isActive ? RugbyTheme.accent : RugbyTheme.border, lineWidth: 1))
    }
}
