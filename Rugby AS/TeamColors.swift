// TeamViews.swift から分割(中身は変更なし)

import CoreImage
import PhotosUI
import SwiftData
import SwiftUI
import Vision

// MARK: - Color hex helpers

extension Color {
    /// "#RRGGBB" 形式の文字列から Color を作る。フォーマット不正なら nil。
    init?(hex: String) {
        var trimmed = hex.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") { trimmed.removeFirst() }
        guard trimmed.count == 6, let value = UInt32(trimmed, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self = Color(red: r, green: g, blue: b)
    }

    /// この色の上に文字を置くとき、白より濃い文字の方が読みやすいか(黄色など明るい色で true)。
    var prefersDarkText: Bool {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return false }
        return 0.299 * red + 0.587 * green + 0.114 * blue > 0.68
    }

    /// 現在の Color を "#RRGGBB" 形式の文字列に変換する。
    func toHexString() -> String? {
        let uiColor = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard uiColor.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return String(
            format: "#%02X%02X%02X",
            Int((r * 255).rounded()),
            Int((g * 255).rounded()),
            Int((b * 255).rounded())
        )
    }

    /// 別の色との RGB 距離（0〜sqrt(3)）。値が小さいほど近い。
    func rgbDistance(to other: Color) -> Double {
        let lhs = UIColor(self)
        let rhs = UIColor(other)
        var lr: CGFloat = 0, lg: CGFloat = 0, lb: CGFloat = 0, la: CGFloat = 0
        var rr: CGFloat = 0, rg: CGFloat = 0, rb: CGFloat = 0, ra: CGFloat = 0
        guard lhs.getRed(&lr, green: &lg, blue: &lb, alpha: &la),
              rhs.getRed(&rr, green: &rg, blue: &rb, alpha: &ra) else { return 0 }
        let dr = Double(lr - rr)
        let dg = Double(lg - rg)
        let db = Double(lb - rb)
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    /// HSB の brightness（0〜1）。視覚的な明るさの近似に使う。
    var hsbBrightness: Double {
        let ui = UIColor(self)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return 1 }
        return Double(b)
    }

    /// HSB の hue（0〜1、円環状）。
    var hsbHue: Double {
        let ui = UIColor(self)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return 0 }
        return Double(h)
    }

    /// 円環上の色相距離（0〜0.5）。小さいほど同系色。
    func hueDistance(to other: Color) -> Double {
        let diff = abs(self.hsbHue - other.hsbHue)
        return min(diff, 1 - diff)
    }

    /// 色相・彩度はそのままに、brightness だけ差し替えた Color を返す。
    func withBrightness(_ newBrightness: Double) -> Color {
        let ui = UIColor(self)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        return Color(
            hue: Double(h),
            saturation: Double(s),
            brightness: max(0, min(1, newBrightness))
        )
    }
}

// MARK: - Team display color

extension Team {
    /// 画面に使うチームの色。未設定なら、チームごとに決まった仮の色(保存しない)
    var displayColorHex: String {
        colorHex ?? TeamColorPalette.provisionalHex(for: id)
    }

    var displayColor: Color {
        Color(hex: displayColorHex) ?? RugbyTheme.header
    }
}

// MARK: - Team color palette

struct TeamColorOption: Identifiable, Hashable {
    let hex: String
    let name: String
    var id: String { hex }
    var color: Color { Color(hex: hex) ?? .gray }
    /// 黒い色選択画面の上で背景に溶けてしまう暗い色(黒・紺など)か
    var isDark: Bool { color.hsbBrightness < 0.4 }
}

enum TeamColorPalette {
    /// チームカラー未設定のチームに見せる仮の色。保存はせず、チームのIDから毎回同じ色を選ぶ
    /// (アプリを開き直しても同じチームは同じ色。色を設定すればそちらが優先される)。
    static func provisionalHex(for teamID: UUID) -> String {
        // IDの16バイトから決まった番号を作る(Swift の hashValue は起動ごとに変わるので使わない)
        var hash: UInt64 = 0xcbf29ce484222325
        withUnsafeBytes(of: teamID.uuid) { bytes in
            for byte in bytes {
                hash = (hash ^ UInt64(byte)) &* 0x100000001b3
            }
        }
        return provisionalHexes[Int(hash % UInt64(provisionalHexes.count))]
    }

    /// 仮の色の候補。options とは別に固定しておく。
    /// options に色を足すと候補の数が変わり、未設定チームの仮の色が一斉に入れ替わってしまうため。
    /// 黒・紺などの暗い色も、仮の色には向かないのでここには入れない。
    private static let provisionalHexes: [String] = [
        "#B71C1C", "#E53935", "#FF7043", "#FF8A65", "#EF6C00", "#FB8C00",
        "#FFB300", "#FDD835", "#827717", "#C0CA33", "#43A047", "#1B5E20",
        "#4DB6AC", "#00897B", "#00ACC1", "#26C6DA", "#29B6F6", "#1E88E5",
        "#3949AB", "#5C6BC0", "#9575CD", "#8E24AA", "#6A1B9A", "#BA1FAB",
        "#D81B60", "#EC407A", "#6D4C41", "#A1887F", "#546E7A"
    ]

    static let options: [TeamColorOption] = [
        .init(hex: "#B71C1C", name: "クリムゾン"),
        .init(hex: "#7B1E2D", name: "えんじ"),
        .init(hex: "#E53935", name: "レッド"),
        .init(hex: "#FF7043", name: "コーラル"),
        .init(hex: "#FF8A65", name: "サーモン"),
        .init(hex: "#EF6C00", name: "パンプキン"),
        .init(hex: "#FB8C00", name: "オレンジ"),
        .init(hex: "#FFB300", name: "アンバー"),
        .init(hex: "#C9A227", name: "ゴールド"),
        .init(hex: "#FDD835", name: "イエロー"),
        .init(hex: "#827717", name: "オリーブ"),
        .init(hex: "#C0CA33", name: "ライム"),
        .init(hex: "#43A047", name: "グリーン"),
        .init(hex: "#1B5E20", name: "フォレスト"),
        .init(hex: "#4DB6AC", name: "ミント"),
        .init(hex: "#00897B", name: "ティール"),
        .init(hex: "#00ACC1", name: "シアン"),
        .init(hex: "#26C6DA", name: "アクア"),
        .init(hex: "#29B6F6", name: "スカイ"),
        .init(hex: "#1E88E5", name: "ブルー"),
        .init(hex: "#0D47A1", name: "ディープブルー"),
        .init(hex: "#14284B", name: "ネイビー"),
        // 以前「ネイビー」と呼んでいた色。実際は明るめの青紫なので名前だけ変えた(色は同じ)
        .init(hex: "#3949AB", name: "ウルトラマリン"),
        .init(hex: "#5C6BC0", name: "インディゴ"),
        .init(hex: "#9575CD", name: "ラベンダー"),
        .init(hex: "#8E24AA", name: "パープル"),
        .init(hex: "#6A1B9A", name: "プラム"),
        .init(hex: "#BA1FAB", name: "マゼンタ"),
        .init(hex: "#D81B60", name: "ピンク"),
        .init(hex: "#EC407A", name: "ローズピンク"),
        .init(hex: "#6D4C41", name: "ブラウン"),
        .init(hex: "#A1887F", name: "キャメル"),
        .init(hex: "#546E7A", name: "スレート"),
        .init(hex: "#424242", name: "チャコール"),
        .init(hex: "#212121", name: "ブラック")
    ]

    /// 両チームとも色を決めていても、この距離より近ければ試合画面で見分けにくい(黒と紺など)
    static let minimumMatchupDistance = 0.25

    /// アウェイの色がホームの色と似ているとき、試合画面で使うアウェイの色。
    /// 別の色に替えるとどのチームか分かりにくくなるので、同じ色のまま明るさだけずらす
    /// (ネイビー相手の黒はグレーに、黒相手の紺は明るい紺に)。似ていなければそのまま返す。
    static func matchupColor(_ away: Color, against home: Color) -> Color {
        guard away.rgbDistance(to: home) < minimumMatchupDistance else { return away }
        // 見分けのため、判定の距離より少し大きく離す
        let target = 0.32
        let brightness = away.hsbBrightness
        // 相手より暗い色はもっと暗く、明るい色はもっと明るくする方を先に試す
        let directions: [Double] = brightness >= home.hsbBrightness ? [1, -1] : [-1, 1]
        for step in stride(from: 0.1, through: 0.6, by: 0.1) {
            for direction in directions {
                let shifted = brightness + direction * step
                // 真っ黒・明るさの上限を超える色は作らない
                guard shifted >= 0.12, shifted <= 1 else { continue }
                let candidate = away.withBrightness(shifted)
                if candidate.rgbDistance(to: home) >= target { return candidate }
            }
        }
        return nearestDistinct(from: away, against: home, minDistance: target, minHueDistance: 0)
    }

    static func nearestDistinct(
        from preferred: Color,
        against home: Color,
        minDistance: Double,
        minHueDistance: Double = 0.04
    ) -> Color {
        let rgbOK = home.rgbDistance(to: preferred) >= minDistance
        let hueOK = home.hueDistance(to: preferred) >= minHueDistance
        if rgbOK && hueOK { return preferred }

        var bestColor: Color?
        var bestSimilarity = Double.infinity
        for option in options {
            let candidate = option.color
            guard home.rgbDistance(to: candidate) >= minDistance else { continue }
            guard home.hueDistance(to: candidate) >= minHueDistance else { continue }
            let similarity = preferred.rgbDistance(to: candidate)
            if similarity < bestSimilarity {
                bestSimilarity = similarity
                bestColor = candidate
            }
        }
        if let bestColor { return bestColor }

        return options.max {
            home.rgbDistance(to: $0.color) < home.rgbDistance(to: $1.color)
        }?.color ?? preferred
    }
}
