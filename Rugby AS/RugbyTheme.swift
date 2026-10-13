import SwiftUI

/// アプリ全体の配色。設定で選んだ配色(RugbyPalette)に合わせて色を返す。
/// どの配色も、標準の紫と「色の濃さ(明るさ・鮮やかさ)」は同じで、色合いだけを変える
/// (見出しの濃さや文字の読みやすさが配色で変わらないように)。
enum RugbyTheme {
    static var background: Color { tokens.background.color }
    static var surface: Color { Color.white }
    static var elevated: Color { tokens.elevated.color }
    static var header: Color { tokens.header.color }
    static var accent: Color { tokens.header.color }
    static var onAccent: Color { Color.white }
    static var accentSoft: Color { tokens.accentSoft.color }
    static var highlight: Color { tokens.highlight.color }
    static var textPrimary: Color { tokens.textPrimary.color }
    static var textSecondary: Color { tokens.textSecondary.color }
    static var border: Color { tokens.header.color.opacity(0.10) }

    /// 配色を変えても変わらない赤(標準の強調色と同じ)。カレンダーの日曜など、意味で色を決めている所に使う
    static let fixedRed = Color(red: 0.851, green: 0.055, blue: 0.392)
    /// 配色を変えても変わらない文字色(標準のパープルのときの色)。試合詳細の一番上のスコアに使う
    static let fixedTextPrimary = Color(red: 0.180, green: 0.055, blue: 0.204)
    static let fixedTextSecondary = Color(red: 0.420, green: 0.376, blue: 0.443)

    static let paletteKey = "appearance.palette"

    /// 今の配色。設定の値が変わったら作り直す(毎回計算しないよう、配色ごとに1回だけ作る)
    private static var cached: (RugbyPalette, Tokens)?
    private static var tokens: Tokens {
        let palette = RugbyPalette(rawValue: UserDefaults.standard.string(forKey: paletteKey) ?? "") ?? .purple
        if let cached, cached.0 == palette { return cached.1 }
        let made = Tokens(palette)
        cached = (palette, made)
        return made
    }

    /// 標準(紫)の色。ほかの配色はここから色合いだけを回して作る
    struct Tokens {
        var background = RGB(0.965, 0.957, 0.973)
        var elevated = RGB(0.929, 0.906, 0.945)
        var header = RGB(0.216, 0.000, 0.235)
        var accentSoft = RGB(0.949, 0.918, 0.961)
        var highlight = RGB(0.851, 0.055, 0.392)
        var textPrimary = RGB(0.180, 0.055, 0.204)
        var textSecondary = RGB(0.420, 0.376, 0.443)

        init(_ palette: RugbyPalette = .purple) {
            guard palette != .purple else { return }
            // 見出しの色合いを基準に、全部の色を同じだけ回す(紫の中での色どうしの関係を保つ)
            let shift = palette.hue - header.hsb.hue
            for keyPath in [\Tokens.background, \Tokens.elevated, \Tokens.header, \Tokens.accentSoft,
                            \Tokens.textPrimary, \Tokens.textSecondary] {
                self[keyPath: keyPath] = self[keyPath: keyPath].rotated(by: shift, saturation: palette.saturation)
            }
            // 強調色(選択中の下線など)は、どの配色でも標準(パープル)のときと同じピンクのまま
        }
    }

    /// 0〜1 の RGB。Color へは使うときに変える
    struct RGB {
        let red: Double, green: Double, blue: Double
        init(_ red: Double, _ green: Double, _ blue: Double) { (self.red, self.green, self.blue) = (red, green, blue) }

        var color: Color { Color(red: red, green: green, blue: blue) }

        var hsb: (hue: Double, saturation: Double, brightness: Double) {
            let maxValue = max(red, green, blue), minValue = min(red, green, blue), delta = maxValue - minValue
            var hue = 0.0
            if delta > 0 {
                if maxValue == red { hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6) }
                else if maxValue == green { hue = (blue - red) / delta + 2 }
                else { hue = (red - green) / delta + 4 }
                hue /= 6
                if hue < 0 { hue += 1 }
            }
            return (hue, maxValue == 0 ? 0 : delta / maxValue, maxValue)
        }

        /// 色合いを回す。明るさはそのまま、鮮やかさは配色ごとの倍率(灰色系は0)
        func rotated(by shift: Double, saturation scale: Double) -> RGB {
            let (hue, saturation, brightness) = hsb
            var h = (hue + shift).truncatingRemainder(dividingBy: 1)
            if h < 0 { h += 1 }
            let s = min(1, saturation * scale), v = brightness
            let i = Int(h * 6) % 6, f = h * 6 - Double(Int(h * 6))
            let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
            switch i {
            case 0: return RGB(v, t, p)
            case 1: return RGB(q, v, p)
            case 2: return RGB(p, v, t)
            case 3: return RGB(p, q, v)
            case 4: return RGB(t, p, v)
            default: return RGB(v, p, q)
            }
        }
    }
}

/// 設定で選べる配色。hue は見出しの色合い(0〜1)、saturation は鮮やかさの倍率
enum RugbyPalette: String, CaseIterable, Identifiable {
    case purple, indigo, navy, blue, teal, green, olive, brown, bordeaux, charcoal

    var id: String { rawValue }

    var name: String {
        switch self {
        case .purple: return "パープル（標準）"
        case .indigo: return "インディゴ"
        case .navy: return "ネイビー"
        case .blue: return "ブルー"
        case .teal: return "ティール"
        case .green: return "グリーン"
        case .olive: return "オリーブ"
        case .brown: return "ブラウン"
        case .bordeaux: return "ボルドー"
        case .charcoal: return "チャコール"
        }
    }

    var hue: Double {
        switch self {
        case .purple: return 294.0 / 360
        case .indigo: return 262.0 / 360
        case .navy: return 226.0 / 360
        case .blue: return 202.0 / 360
        case .teal: return 175.0 / 360
        case .green: return 145.0 / 360
        case .olive: return 70.0 / 360
        case .brown: return 25.0 / 360
        case .bordeaux: return 345.0 / 360
        case .charcoal: return 222.0 / 360
        }
    }

    var saturation: Double { self == .charcoal ? 0.12 : 1 }

    /// 見本の色(設定画面の丸)
    var swatch: Color { RugbyTheme.Tokens(self).header.color }
}

struct RugbyScreenHeading: View {
    let eyebrow: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title.weight(.heavy))
                .foregroundStyle(RugbyTheme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(RugbyTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RugbyIconBadge: View {
    let symbol: String
    var tint: Color = RugbyTheme.accent

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
    }
}

struct RugbyEmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(RugbyTheme.accent)
                .frame(width: 64, height: 64)
                .background(RugbyTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(RugbyTheme.textPrimary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(RugbyTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
    }
}

struct RugbyPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .foregroundStyle(RugbyTheme.onAccent)
            .padding(.horizontal, 18)
            .frame(minHeight: 46)
            .background(RugbyTheme.accent.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 8))
    }
}

extension View {
    func rugbyCard() -> some View {
        padding(16)
            .background(RugbyTheme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(RugbyTheme.border, lineWidth: 1))
    }
}
