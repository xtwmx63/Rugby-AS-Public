import SwiftUI

struct TeamPerformanceLeadersView: View {
    let team: Team
    let players: [Player]
    let entries: [TeamPerformance.ScoringEntry]
    let matchIDs: Set<UUID>
    let openPlayer: (Player) -> Void
    @AppStorage("teamPerformance.rankingMetric") private var rankingMetric = "得点"
    @AppStorage("teamPerformance.conversionMinKicks") private var minimumKicks = 5
    @State private var showsAll = false
    @State private var showsThresholdInput = false
    @State private var thresholdText = ""

    private var metric: TeamPerformance.RankingMetric {
        TeamPerformance.RankingMetric(rawValue: rankingMetric) ?? .points
    }
    private var isKickMetric: Bool { metric == .conversions || metric == .conversionRate }
    private var threshold: Int { max(1, minimumKicks) }
    private var enteredThreshold: Int? {
        guard let value = Int(thresholdText), value > 0 else { return nil }
        return value
    }

    var body: some View {
        let standings = TeamPerformance.standings(entries: entries, matchIDs: matchIDs, metric: metric,
                                                  minimumConversionAttempts: threshold)
        let displayed = showsAll ? standings : standings.filter { $0.rank <= 3 }
        VStack(alignment: .leading, spacing: 16) {
            Label("チーム内ランキング", systemImage: "medal").font(.headline)
            HStack {
                Menu {
                    Picker("ランキングの指標", selection: $rankingMetric) {
                        ForEach(TeamPerformance.RankingMetric.allCases, id: \.rawValue) { value in
                            Text(value.rawValue).tag(value.rawValue)
                        }
                    }
                } label: {
                    menuLabel(metric.rawValue)
                }.accessibilityLabel("ランキングの指標、\(metric.rawValue)")
                Spacer(minLength: 8)
                if metric == .conversionRate {
                    Menu {
                        ForEach([1, 3, 5, 10, 15, 20, 30, 50], id: \.self) { value in
                            Button("\(value)本以上") { minimumKicks = value }
                        }
                        Button("本数を指定…") {
                            thresholdText = String(threshold)
                            showsThresholdInput = true
                        }
                    } label: {
                        menuLabel("\(threshold)本以上")
                    }.accessibilityLabel("成功率ランキングの最低試行本数、\(threshold)本以上")
                }
            }
            Text("選択中の年度・対戦相手で集計")
                .font(.caption).foregroundStyle(RugbyTheme.textSecondary)
            if metric == .conversionRate {
                Text("\(threshold)本以上蹴った選手が対象。成功数÷試行数で計算し、同率は同順位です。")
                    .font(.caption).foregroundStyle(RugbyTheme.textSecondary)
            }
            if standings.isEmpty {
                Text(metric == .conversionRate ? "\(threshold)本以上の試行が記録された選手はいません。" : "選手に紐づいた\(metric.rawValue)の記録はありません。")
                    .font(.subheadline).foregroundStyle(RugbyTheme.textSecondary).padding(.vertical, 12)
            }
            ForEach(displayed) { standing in
                let player = players.first { $0.id == standing.playerID }
                Button {
                    if let player { openPlayer(player) }
                } label: {
                    if standing.rank == 1 {
                        VStack(alignment: .leading, spacing: 6) {
                            LeaderCard(name: playerName(player), teamName: team.name,
                                       value: standing.value, unit: metric.unit,
                                       imagePath: player?.imagePath, number: player?.number, teamColorHex: team.colorHex,
                                       valueText: valueText(standing))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            if isKickMetric {
                                Text(kickDetail(standing)).font(.caption.monospacedDigit())
                                    .foregroundStyle(RugbyTheme.textSecondary)
                            }
                        }
                    } else {
                        rankingRow(standing, player: player)
                    }
                }
                .buttonStyle(.plain).disabled(player == nil)
                if standing.id != displayed.last?.id && standing.rank != 1 { Divider() }
            }
            if standings.contains(where: { $0.rank > 3 }) {
                Button(showsAll ? "3位まで表示" : "全員を見る") { showsAll.toggle() }
                    .font(.subheadline.bold()).frame(maxWidth: .infinity, minHeight: 44)
            }
            if let disclosure = unattributedDisclosure {
                Text(disclosure).font(.caption2).foregroundStyle(RugbyTheme.textSecondary)
            }
        }
        .padding(18).background(.white, in: RoundedRectangle(cornerRadius: 8))
        .tint(team.performanceAccent)
        .alert("最低試行本数", isPresented: $showsThresholdInput) {
            TextField("本数", text: $thresholdText).keyboardType(.numberPad)
            Button("キャンセル", role: .cancel) { }
            Button("適用") {
                if let value = enteredThreshold { minimumKicks = value }
            }.disabled(enteredThreshold == nil)
        } message: {
            Text("成功率ランキングの対象にする最低試行本数を、1以上の整数で指定してください。")
        }
    }

    private func menuLabel(_ title: String) -> some View {
        HStack(spacing: 5) {
            Text(title)
            Image(systemName: "chevron.down").font(.caption2)
        }.font(.caption.bold()).frame(minHeight: 44)
    }

    private func valueText(_ standing: TeamPerformance.PlayerStanding) -> String {
        metric == .conversionRate
            ? ((standing.conversionRate ?? 0) * 100).formatted(.number.precision(.fractionLength(1)))
            : String(standing.value)
    }

    private func kickDetail(_ standing: TeamPerformance.PlayerStanding) -> String {
        "成功 \(standing.conversions) / 試行 \(standing.conversionAttempts)本"
    }

    private func playerName(_ player: Player?) -> String {
        player?.name.flatMap { $0.isEmpty ? nil : $0 } ?? "名前未登録"
    }

    private func rankingRow(_ standing: TeamPerformance.PlayerStanding, player: Player?) -> some View {
        HStack(spacing: 12) {
            Text(String(standing.rank)).font(.headline.monospacedDigit())
                .frame(width: 30, height: 36)
                .foregroundStyle(standing.rank <= 3 ? .black : RugbyTheme.textSecondary)
                .background(rankColor(standing.rank), in: RoundedRectangle(cornerRadius: 5))
            StoredImageView(name: player?.imagePath, maxDimension: 120) { image in
                image.resizable().scaledToFill().frame(width: 44, height: 44).clipShape(Circle())
            } placeholder: {
                Image(systemName: "person.fill").foregroundStyle(team.displayColor)
                    .frame(width: 44, height: 44).background(team.displayColor.opacity(0.07), in: Circle())
            }.accessibilityHidden(true)
            Text(playerName(player)).font(.subheadline.bold()).multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(valueText(standing)).font(.title2.weight(.heavy).monospacedDigit())
                    Text(metric.unit).font(.caption).foregroundStyle(RugbyTheme.textSecondary)
                }
                if isKickMetric {
                    Text("\(standing.conversions)/\(standing.conversionAttempts)本")
                        .font(.caption2.monospacedDigit()).foregroundStyle(RugbyTheme.textSecondary)
                }
            }
        }.padding(.vertical, 6).foregroundStyle(RugbyTheme.textPrimary)
    }

    private func rankColor(_ rank: Int) -> Color {
        switch rank {
        case 2: Color(white: 0.72)
        case 3: Color(red: 0.80, green: 0.52, blue: 0.30)
        default: .clear
        }
    }

    private var unattributedDisclosure: String? {
        let unknown = entries.filter { matchIDs.contains($0.matchID) && $0.playerID == nil }
        if isKickMetric {
            let count = unknown.reduce(0) { $0 + $1.conversionAttempts }
            return count > 0 ? "キッカー不明の\(count)本は個人順位に含めていません。" : nil
        }
        let value = unknown.reduce(0) { $0 + (metric == .points ? $1.points : $1.tries) }
        guard value > 0 else { return nil }
        return metric == .points ? "選手不明・認定トライの\(value)点は個人順位に含めていません。" : "選手不明の\(value)トライは個人順位に含めていません。"
    }
}
