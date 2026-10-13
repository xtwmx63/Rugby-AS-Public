import SwiftUI

/// 個人成績の直近試合と同じ勝敗色。チーム色とは意味を分ける。
enum TeamFormColors {
    static let win = Color(red: 0.13, green: 0.55, blue: 0.27)
    static let loss = Color(red: 0.80, green: 0.20, blue: 0.20)
    static let draw = Color(white: 0.55)
}

struct TeamRecentFormView: View {
    let results: [TeamPerformance.Result]
    let teams: [Team]
    let openMatch: (Match) -> Void
    @AppStorage("teamPerformance.recentCount") private var requestedCount = 5

    private var limit: Int { min(30, max(5, requestedCount / 5 * 5)) }
    private var recent: [TeamPerformance.Result] { Array(results.prefix(limit).reversed()) }
    private let columns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: 6, alignment: .top), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("直近の試合", systemImage: "clock.arrow.circlepath").font(.headline)
                Spacer(minLength: 4)
                Menu {
                    Picker("表示試合数", selection: $requestedCount) {
                        ForEach(Array(stride(from: 5, through: 30, by: 5)), id: \.self) { count in
                            Text("直近\(count)試合").tag(count)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text("直近\(limit)試合")
                        Image(systemName: "chevron.down").font(.caption2)
                    }.font(.caption.bold()).frame(minHeight: 44)
                }
                .tint(RugbyTheme.accent)
                .accessibilityLabel("直近の試合の表示件数")
                .accessibilityValue("\(limit)試合")
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(recent) { result in
                    formItem(result)
                }
            }
            Text("左上が古く、右下が最新。スコアの左側が自チームです。勝ち＝緑・負け＝赤・引き分け＝灰。")
                .font(.caption2).foregroundStyle(RugbyTheme.textSecondary)
        }
        .padding(16)
        .background(RugbyTheme.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    private func formItem(_ result: TeamPerformance.Result) -> some View {
        let opponent = teams.first { $0.id == result.opponentID }
        let name = opponent?.name ?? "チーム未設定"
        let color = result.pointsFor > result.pointsAgainst ? TeamFormColors.win
            : result.pointsFor < result.pointsAgainst ? TeamFormColors.loss : TeamFormColors.draw
        return Button { openMatch(result.match) } label: {
            VStack(spacing: 6) {
                Text(result.match.playedAt, format: .dateTime.month(.twoDigits).day(.twoDigits))
                    .font(.caption2.monospacedDigit()).foregroundStyle(RugbyTheme.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                StoredImageView(name: opponent?.logoPath, maxDimension: 120) { image in
                    image.resizable().scaledToFit().frame(width: 32, height: 32)
                } placeholder: {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(opponent?.displayColor ?? RugbyTheme.accent)
                        .frame(width: 32, height: 32)
                        .background((opponent?.displayColor ?? RugbyTheme.accent).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }.accessibilityHidden(true)
                Text(name).font(.caption2.bold()).foregroundStyle(RugbyTheme.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.6).frame(height: 16)
                Text(result.outcome).font(.caption2).foregroundStyle(RugbyTheme.textSecondary)
                Text("\(result.pointsFor)-\(result.pointsAgainst)")
                    .font(.caption.weight(.heavy).monospacedDigit())
                    .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity).padding(.vertical, 5)
                    .background(color, in: RoundedRectangle(cornerRadius: 5))
            }.frame(maxWidth: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(result.match.playedAt.formatted(.dateTime.year().month().day()))、\(name)戦、\(result.pointsFor)対\(result.pointsAgainst)、\(result.outcome)")
        .accessibilityHint("試合詳細を開きます")
    }
}
