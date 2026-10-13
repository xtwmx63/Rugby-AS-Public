import SwiftUI

enum TeamPerformanceColors {
    static let charcoal = Color(white: 0.32)
}

/// 白地の小さい文字や操作に使う色。バー・グラフ等の面には補正せずdisplayColorを使う。
extension Team {
    var performanceAccent: Color {
        let source = UIColor(displayColor)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard source.getRed(&r, green: &g, blue: &b, alpha: &a) else { return RugbyTheme.accent }
        func linear(_ x: CGFloat) -> Double {
            let value = Double(x)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        for _ in 0..<30 {
            let luminance = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
            if 1.05 / (luminance + 0.05) >= 4.5 { break }
            r *= 0.92; g *= 0.92; b *= 0.92
        }
        return Color(red: Double(r), green: Double(g), blue: Double(b))
    }
}
