//
//  MatchScoreHeaderView.swift
//  Rugby AS
//
//  試合詳細の一番上(スコアの部分)。左右をホーム/アウェイのチームカラーで塗り分け、
//  真ん中の白いカードに合計点とハーフタイムの点(Half)を出す。下の白い面に得点者を
//  「ホームは左・アウェイは右」で種類ごと(T/C/PG/DG)に並べる。
//  値は MatchSummaryView が StatEvent から計算して渡す(ここでは数えない)。
//

import SwiftUI
import UIKit

struct MatchScoreHeaderView: View {
    struct Side {
        let name: String
        let color: Color
        let logoPath: String?
        let score: Int
        let firstHalfScore: Int
    }

    /// 得点の種類1つ分(例: トライ)。各チームの「名前 12', 35'」の行を持つ
    struct ScorerGroup: Identifiable {
        let id: String
        let tag: String
        let home: [String]
        let away: [String]
    }

    let home: Side
    let away: Side
    let scorerGroups: [ScorerGroup]
    let tournamentName: String
    let playedAt: Date
    let isFinished: Bool
    let isExcludedFromStats: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let scoreCardWidth: CGFloat = 156

    var body: some View {
        VStack(spacing: 0) {
            colorBand
            detailSheet
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - 色の帯(チーム・点数)

    private var colorBand: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // 大きな文字では横に並べると切れるので、縦に積む
                VStack(spacing: 12) {
                    accessibleRow(home)
                    accessibleRow(away)
                }
                .padding(20)
            } else {
                HStack(spacing: 0) {
                    teamColumn(home)
                    Color.clear.frame(width: scoreCardWidth)
                    teamColumn(away)
                }
                .padding(.top, 20)
                .padding(.bottom, 22)
                .overlay(alignment: .top) {
                    scoreCard.padding(.top, 20)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background {
            HStack(spacing: 0) {
                teamBackground(home.color)
                teamBackground(away.color)
            }
        }
    }

    private func teamBackground(_ color: Color) -> some View {
        color
            .overlay(DiagonalStripes().fill(Color.white.opacity(0.07)))
            .overlay(LinearGradient(colors: [.clear, .black.opacity(0.12)], startPoint: .top, endPoint: .bottom))
            .clipped()
    }

    private func teamColumn(_ side: Side) -> some View {
        VStack(spacing: 10) {
            logo(side, size: 64)
            Text(side.name)
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(textColor(on: side.color))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
    }

    private var scoreCard: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text("\(home.score)")
                Text("-").font(.system(size: 24, weight: .bold, design: .rounded))
                Text("\(away.score)")
            }
            .font(.system(size: 36, weight: .heavy, design: .rounded).monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            Text("Half \(home.firstHalfScore) - \(away.firstHalfScore)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(RugbyTheme.fixedTextSecondary)
        }
        // スコアの色は配色に関係なく、標準(パープル)のときの色のまま
        .foregroundStyle(RugbyTheme.fixedTextPrimary)
        .padding(.vertical, 12)
        .padding(.horizontal, 10)
        .frame(width: scoreCardWidth - 16)
        .background(RugbyTheme.surface, in: RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(home.name) \(home.score) 対 \(away.score) \(away.name)、ハーフタイム \(home.firstHalfScore) 対 \(away.firstHalfScore)")
    }

    private func accessibleRow(_ side: Side) -> some View {
        HStack(spacing: 12) {
            logo(side, size: 44)
            Text(side.name).font(.headline)
            Spacer(minLength: 4)
            Text("\(side.score)").font(.title.weight(.heavy).monospacedDigit())
        }
        .foregroundStyle(textColor(on: side.color))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func logo(_ side: Side, size: CGFloat) -> some View {
        // 画像共有でもそのまま描けるよう、読み込みを待たずに縮小画像を使う
        if let name = side.logoPath, let image = ImageStorage.thumbnail(named: name, maxDimension: 200) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "shield.lefthalf.filled")
                .resizable()
                .scaledToFit()
                .padding(size * 0.08)
                .frame(width: size, height: size)
                .foregroundStyle(textColor(on: side.color).opacity(0.9))
                .accessibilityHidden(true)
        }
    }

    // MARK: - 白い面(得点者・大会・日付)

    private var detailSheet: some View {
        VStack(spacing: 16) {
            if !scorerGroups.isEmpty {
                VStack(spacing: 10) {
                    ForEach(scorerGroups) { group in
                        scorerRow(group)
                    }
                }
            }

            VStack(spacing: 6) {
                Text(tournamentName)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(RugbyTheme.textSecondary)
                    .multilineTextAlignment(.center)
                Text(playedAt.formatted(.dateTime.year().month().day().weekday(.abbreviated).locale(Locale(identifier: "ja_JP"))))
                    .font(.caption)
                    .foregroundStyle(RugbyTheme.textSecondary)
                HStack(spacing: 8) {
                    statusBadge(isFinished ? "試合終了" : "記録中",
                                symbol: isFinished ? "checkmark" : "record.circle", color: RugbyTheme.accent)
                    if isExcludedFromStats {
                        statusBadge("集計対象外", symbol: "minus.circle", color: .orange)
                    }
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
        .background(RugbyTheme.surface)
    }

    private func scorerRow(_ group: ScorerGroup) -> some View {
        HStack(alignment: .top, spacing: 10) {
            scorerLines(group.home, alignment: .trailing)
            // T・G・PG などの印は「試合終了」の印と同じく、配色に合わせて色が変わる
            Text(group.tag)
                .font(.caption2.weight(.black))
                .foregroundStyle(RugbyTheme.accent)
                .frame(width: 34, height: 22)
                .background(RugbyTheme.accentSoft, in: Capsule())
            scorerLines(group.away, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private func scorerLines(_ lines: [String], alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(RugbyTheme.fixedTextPrimary)
                    .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
    }

    private func statusBadge(_ title: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            Text(title)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.10), in: Capsule())
    }

    // 明るいチームカラー(黄色など)の上では文字を濃い色にする
    private func textColor(on background: Color) -> Color {
        background.prefersDarkText ? RugbyTheme.textPrimary : .white
    }
}

/// 色の帯に薄く重ねる斜めのしま模様(選手詳細の上部でも使う)
struct DiagonalStripes: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let stripeWidth: CGFloat = 26
        let spacing: CGFloat = 52
        var x = -rect.height
        while x < rect.width + rect.height {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            path.addLine(to: CGPoint(x: x + rect.height + stripeWidth, y: rect.minY))
            path.addLine(to: CGPoint(x: x + stripeWidth, y: rect.maxY))
            path.closeSubpath()
            x += spacing
        }
        return path
    }
}

#Preview {
    MatchScoreHeaderView(
        home: .init(name: "青葉大学", color: Color(red: 0.45, green: 0.1, blue: 0.25), logoPath: nil, score: 28, firstHalfScore: 14),
        away: .init(name: "海浜大学", color: Color(red: 0.98, green: 0.72, blue: 0.1), logoPath: nil, score: 21, firstHalfScore: 14),
        scorerGroups: [
            .init(id: "try", tag: "T", home: ["#11 山田 7', 52'", "#9 佐藤 19'"], away: ["#14 鈴木 11'"]),
            .init(id: "conversion", tag: "G", home: ["#10 田中 8', 20', 53'"], away: ["#10 高橋 12'"])
        ],
        tournamentName: "秋季チャレンジリーグ",
        playedAt: Date(),
        isFinished: true,
        isExcludedFromStats: false
    )
}
