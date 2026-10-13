import SwiftUI

/// 得点経過の印。同じ大きさの丸1つで、得点の種類を絵で表す(文字を読まなくても分かるように)。
/// トライ = ラグビーボール、ゴールが決まったトライ = ボール + 右上の「✓」、認定トライ = ボール + 右上の「★」、
/// PG = ゴールポスト、DG = ゴールポスト + 小さな「D」、トライと離れたゴールだけの記録 = ゴールポスト + 小さな「G」。
struct ScoringKindMark: View {
    /// 得点の種類("T" / "T+G" / "PT" / "PG" / "DG" / "G")
    let kind: String
    let color: Color
    let size: CGFloat
    let isSelected: Bool

    static func name(_ kind: String) -> String {
        switch kind {
        case "T": return "トライ"
        case "T+G": return "トライ+ゴール"
        case "PT": return "認定トライ"
        case "PG": return "PG"
        case "DG": return "DG"
        case "G": return "ゴール"
        default: return kind
        }
    }

    private var isTry: Bool { ["T", "T+G", "PT"].contains(kind) }
    private var foreground: Color { color.prefersDarkText ? RugbyTheme.textPrimary : .white }

    var body: some View {
        ZStack {
            Circle().fill(color)
            if isTry {
                Image(systemName: "rugbyball.fill")
                    .resizable()
                    .scaledToFit()
                    .rotationEffect(.degrees(-35))
                    .frame(width: size * 0.62, height: size * 0.62)
                    .foregroundStyle(foreground)
            } else {
                GoalPosts()
                    .stroke(foreground, style: StrokeStyle(lineWidth: max(1.3, size * 0.075), lineCap: .round))
                    .frame(width: size * 0.46, height: size * 0.62)
                    .offset(x: kind == "PG" ? 0 : -size * 0.08)
                if kind == "DG" || kind == "G" {
                    Text(kind == "DG" ? "D" : "G")
                        .font(.system(size: size * 0.32, weight: .black, design: .rounded))
                        .foregroundStyle(foreground)
                        .offset(x: size * 0.24, y: size * 0.16)
                }
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(isSelected ? RugbyTheme.highlight : RugbyTheme.surface, lineWidth: isSelected ? 2.5 : 1))
        .overlay(alignment: .topTrailing) {
            if kind == "T+G" || kind == "PT" {
                badge(symbol: kind == "PT" ? "star.fill" : "checkmark")
                    .offset(x: size * 0.2, y: -size * 0.16)
            }
        }
        .scaleEffect(isSelected ? 1.12 : 1)
    }

    /// 右上の小さな丸(白地にチームの色の印)
    private func badge(symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.26, weight: .black))
            .foregroundStyle(color)
            .frame(width: size * 0.46, height: size * 0.46)
            .background(Circle().fill(RugbyTheme.surface))
            .overlay(Circle().stroke(color, lineWidth: 1.2))
    }
}

/// ラグビーのゴールポスト。横棒を低くして柱を上に長く伸ばす(文字の「H」に見えないように)
private struct GoalPosts: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let left = rect.minX + rect.width * 0.1
        let right = rect.maxX - rect.width * 0.1
        let bar = rect.minY + rect.height * 0.74
        path.move(to: CGPoint(x: left, y: rect.minY))
        path.addLine(to: CGPoint(x: left, y: rect.maxY))
        path.move(to: CGPoint(x: right, y: rect.minY))
        path.addLine(to: CGPoint(x: right, y: rect.maxY))
        path.move(to: CGPoint(x: left, y: bar))
        path.addLine(to: CGPoint(x: right, y: bar))
        return path
    }
}
