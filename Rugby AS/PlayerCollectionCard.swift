// TeamViews.swift から分割
//
// 選手名簿のカード。上はチームカラーの面(斜めのしま模様と大きな背番号の透かし)に
// 選手写真を置き、下の白い帯に名前・ポジション・英語表記を出す。
// 試合詳細や選手詳細の上部と同じ「チームカラー＋しま模様」の見た目にそろえている。

import SwiftData
import SwiftUI

// MARK: - Reusable collection card

struct PlayerCollectionCard: View {
    @Bindable var player: Player
    let accent: Color
    let isNumberDuplicated: Bool
    let statusLabel: String?
    let showsFavoriteBadge: Bool

    init(
        player: Player,
        accent: Color,
        isNumberDuplicated: Bool,
        statusLabel: String? = nil,
        showsFavoriteBadge: Bool = true
    ) {
        self._player = Bindable(wrappedValue: player)
        self.accent = accent
        self.isNumberDuplicated = isNumberDuplicated
        self.statusLabel = statusLabel
        self.showsFavoriteBadge = showsFavoriteBadge
    }

    private var displayName: String {
        player.rosterDisplayName
    }

    private var romanName: String? {
        let trimmed = (player.nameRoman ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.uppercased()
    }

    // チームカラーの面の上に置く文字の色(黄色など明るい色では濃い文字)
    private var onAccent: Color {
        accent.prefersDarkText ? RugbyTheme.textPrimary : .white
    }

    // 白い帯の上でポジションに使う色(明るすぎるチームカラーは読みにくいので濃い色にする)
    private var accentInk: Color {
        accent.prefersDarkText ? RugbyTheme.textPrimary : accent
    }

    var body: some View {
        GeometryReader { proxy in
            let cardShape = CollectionCardShape(cut: max(8, proxy.size.width * 0.075))
            let photoHeight = proxy.size.height * 0.76

            VStack(spacing: 0) {
                photoArea(width: proxy.size.width, height: photoHeight)
                namePlate(cardWidth: proxy.size.width)
                    .frame(height: proxy.size.height - photoHeight)
            }
            .clipShape(cardShape)
            .overlay(cardShape.stroke(RugbyTheme.border, lineWidth: 1))
            // 影はカード枚数ぶんオフスクリーン描画が積み上がって名簿全体が
            // 重くなるため付けない。
        }
        // 1:1 より名前欄の分だけ少し縦長。3列でも顔写真を大きく保つ。
        .aspectRatio(0.78, contentMode: .fit)
    }

    // MARK: - 写真の面

    private func photoArea(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            accent
            DiagonalStripes().fill(Color.white.opacity(0.08))
            LinearGradient(colors: [.clear, .black.opacity(0.16)], startPoint: .top, endPoint: .bottom)

            numberWatermark(width: width)

            playerPhoto(height: height)

            numberBadge(cardWidth: width)
                .padding(max(5, width * 0.035))

            cardStatusBadge(cardWidth: width)
        }
        .frame(width: width, height: height)
        .clipped()
    }

    // F1アプリのカードのように、背番号を右上に大きく薄く敷く
    @ViewBuilder
    private func numberWatermark(width: CGFloat) -> some View {
        if let number = player.number {
            Text("\(number)")
                .font(.system(size: width * 0.46, weight: .black, design: .rounded).monospacedDigit())
                .foregroundStyle(onAccent.opacity(0.22))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.trailing, width * 0.05)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func playerPhoto(height: CGFloat) -> some View {
        // 表示は縮小版を使う(原寸を並べるとスクロールが重くなる)。
        // 背景削除済みかどうかは拡張子で判定する(透明PNGは savePNG 経由の .png のみ)。
        StoredImageView(name: player.imagePath, maxDimension: 360) { image in
            if player.imagePath?.lowercased().hasSuffix(".png") == true {
                image
                    .resizable()
                    .scaledToFit()
                    .padding(.horizontal, 3)
                    .padding(.top, height * 0.12)
                    .frame(maxWidth: .infinity)
                    .frame(height: height, alignment: .bottom)
            } else {
                image
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .clipped()
            }
        } placeholder: {
            VStack(spacing: 7) {
                Image(systemName: "person.fill")
                    .font(.system(size: 38, weight: .medium))
                Text("写真を追加")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(onAccent.opacity(0.55))
            .frame(maxWidth: .infinity)
            .frame(height: height)
        }
    }

    // MARK: - 名前の帯

    private func namePlate(cardWidth: CGFloat) -> some View {
        let nameSize = max(13, min(18, cardWidth * 0.092))
        let subSize = max(8.5, min(11, cardWidth * 0.055))
        let horizontalPadding = max(8, min(12, cardWidth * 0.055))

        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(displayName)
                    .font(.system(size: nameSize, weight: .heavy))
                    .foregroundStyle(RugbyTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)

                Spacer(minLength: 2)

                if showsFavoriteBadge && player.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: max(10, nameSize * 0.75), weight: .black))
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                }
            }

            if romanName != nil || player.rugbyPosition != nil {
                HStack(spacing: 6) {
                    if let position = player.rugbyPosition {
                        Text(position.rawValue)
                            .foregroundStyle(accentInk)
                    }

                    if let romanName {
                        Text(romanName)
                            .foregroundStyle(RugbyTheme.textSecondary)
                    }
                }
                .font(.system(size: subSize, weight: .bold, design: .rounded))
                .tracking(0.6)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RugbyTheme.surface)
        .overlay(alignment: .top) {
            // 写真の面との境目にチームカラーの細い線
            Rectangle()
                .fill(accent)
                .frame(height: 2)
        }
    }

    // MARK: - バッジ

    @ViewBuilder
    private func cardStatusBadge(cardWidth: CGFloat) -> some View {
        if let statusLabel {
            Text(statusLabel)
                .font(.system(size: max(8, min(11, cardWidth * 0.057)), weight: .black))
                .foregroundStyle(.white)
                .padding(.horizontal, max(6, cardWidth * 0.04))
                .padding(.vertical, max(4, cardWidth * 0.025))
                .background(Color.orange, in: Capsule())
                .padding(max(6, cardWidth * 0.045))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func numberBadge(cardWidth: CGFloat) -> some View {
        // 背番号の重複はオレンジで知らせる。未設定は「—」
        let isWarning = isNumberDuplicated
        return Text(player.number.map { "#\($0)" } ?? "—")
            .font(
                .system(
                    size: max(11, min(15, cardWidth * 0.075)),
                    weight: .heavy,
                    design: .rounded
                )
                .monospacedDigit()
            )
            .foregroundStyle(isWarning ? .white : RugbyTheme.textPrimary)
            .padding(.horizontal, max(7, cardWidth * 0.045))
            .padding(.vertical, max(3, cardWidth * 0.02))
            .background(isWarning ? Color.orange : RugbyTheme.surface.opacity(0.92), in: Capsule())
    }
}

struct CollectionCardButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.972 : 1)
            .brightness(configuration.isPressed ? -0.025 : 0)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: configuration.isPressed
            )
    }
}

struct CollectionCardShape: InsettableShape {
    var cut: CGFloat = 10
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let c = min(cut, min(r.width, r.height) * 0.18)
        var path = Path()
        path.move(to: CGPoint(x: r.minX + c, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - c, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY + c))
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c))
        path.addLine(to: CGPoint(x: r.maxX - c, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX + c, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX, y: r.maxY - c))
        path.addLine(to: CGPoint(x: r.minX, y: r.minY + c))
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> CollectionCardShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}
