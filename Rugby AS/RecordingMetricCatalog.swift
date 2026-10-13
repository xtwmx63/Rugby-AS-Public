import Foundation

struct RecordingMetricPreset: Identifiable {
    let id: String
    let group: String
    let title: String
    let subtitle: String
    let widget: RecordingWidgetDefinition
}

/// 記録者が選んで使う指標。未記録のプレーを推定したり、別の指標から補完したりしない。
/// 分野は World Rugby Game Analysis の攻撃・守備・保持・セットプレー等の分析項目を参考にしている。
/// https://www.world.rugby/the-game/game-analysis/reports
/// https://www.world.rugby/news/778385/hsbc-world-rugby-sevens-series-analysis-kicks-offloads-and-increased-competition
enum RecordingMetricCatalog {
    static let groups = ["得点", "攻撃", "守備", "ブレイクダウン", "セットプレー", "キック", "規律", "エリア・起点"]
    static let titlesByCategory: [String: String] = {
        var titles: [String: String] = [:]
        for preset in templates where titles[preset.widget.category] == nil {
            titles[preset.widget.category] = preset.title
        }
        return titles
    }()

    /// 同じ指標を別のチーム用に追加できるよう、呼ぶたびに新しいウィジェット ID を生成する。
    /// プリセット ID と記録カテゴリーは変わらない。
    static var all: [RecordingMetricPreset] {
        templates.map { preset in
            var widget = preset.widget
            widget.id = UUID()
            return RecordingMetricPreset(id: preset.id, group: preset.group, title: preset.title,
                subtitle: preset.subtitle, widget: widget)
        }
    }

    /// 閲覧・集計用。画面の更新だけでカードを作り直さない。
    /// ボードに追加するときは独立した ID を割り当てる。
    static let templates: [RecordingMetricPreset] = {
        [
            preset("try", "得点", "トライ", "トライの成功を記録。得点に5点を加算。", .count, .green, "rugbyball.fill"),
            preset("conversion", "得点", "コンバージョン", "成功・失敗を記録。成功は2点。", .result, .purple, "scope"),
            preset("penalty_goal", "得点", "PG", "ペナルティゴールの成否。成功は3点。", .result, .blue, "p.circle.fill"),
            preset("drop_goal", "得点", "DG", "ドロップゴールの成否。成功は3点。", .result, .yellow, "d.circle.fill"),

            preset("carry", "攻撃", "キャリー", "ボールを持って仕掛けた回数。", .count, .green, "figure.rugby"),
            preset("carry_metres", "攻撃", "キャリー距離", "1回のキャリーで進んだ距離を入力。後退は負の値。", .number, .green, "arrow.right", unit: "m"),
            preset("line_break", "攻撃", "ラインブレイク", "ボールを持って相手の守備ラインを突破した回数。", .count, .cyan, "arrow.up.right"),
            preset("defender_beaten", "攻撃", "ディフェンダー突破", "キャリーで抜き去った相手の人数を1人ずつ記録。", .count, .green, "person.fill.badge.minus"),
            preset("offload", "攻撃", "オフロード", "接触を受けながら味方につないだパスの回数。", .count, .cyan, "arrowshape.turn.up.right.fill"),
            preset("pass", "攻撃", "パス成否", "味方に届いたら成功、届かなければ失敗。", .result, .cyan, "arrow.left.arrow.right"),
            preset("gain_line", "攻撃", "ゲインライン突破", "プレー開始位置より前進できたかを記録。", .result, .green, "arrow.up.to.line"),
            preset("handling_error", "攻撃", "ハンドリングエラー", "ノックオンや落球などで攻撃が止まった回数。", .count, .orange, "hand.raised.slash.fill"),
            preset("attack_phases", "攻撃", "攻撃フェーズ数", "一連の攻撃が終わったら、継続したフェーズ数を入力。", .number, .green, "square.stack.3d.up.fill", unit: "フェーズ"),

            preset("tackle", "守備", "タックル成否", "止めたら成功、抜かれたら失敗。試行数と成功率を集計。", .result, .orange, "shield.fill"),
            preset("good_tackle", "守備", "ドミナントタックル", "相手を押し戻すなど、優位に終えたタックルの回数。", .count, .orange, "star.fill"),
            preset("tackle_assist", "守備", "タックルアシスト", "主タックラーを支えて相手を止めた回数。", .count, .orange, "person.2.fill"),
            preset("interception", "守備", "インターセプト", "相手のパスを奪った回数。", .count, .green, "hand.raised.fill"),
            preset("line_break_conceded", "守備", "被ラインブレイク", "相手に守備ラインを突破された回数。", .count, .red, "shield.slash.fill"),
            preset("turnover", "守備", "ターンオーバー獲得", "相手の保持からボールを奪った回数。", .count, .green, "arrow.triangle.2.circlepath"),
            preset("tackle_rate", "守備", "タックル成功率", "タックル成否で記録した成功数÷試行数を表示。", .successRate, .orange, "chart.pie.fill", category: "tackle"),

            preset("ruck", "ブレイクダウン", "ラック保持", "自チームのラックで保持したら成功、失ったら失敗。", .result, .orange, "arrow.triangle.branch"),
            preset("ruck_speed", "ブレイクダウン", "ラック供給時間", "ラック成立からボールが出るまでの秒数を入力。", .number, .yellow, "stopwatch.fill", unit: "秒"),
            preset("jackal", "ブレイクダウン", "ジャッカル", "奪取または反則獲得なら成功、それ以外は失敗。", .result, .green, "hand.draw.fill"),
            preset("counter_ruck", "ブレイクダウン", "カウンターラック", "押し込んでボールを奪えたら成功。", .result, .orange, "arrow.up.forward"),
            preset("maul", "ブレイクダウン", "モール保持", "モールで保持を継続できたかを記録。", .result, .purple, "person.3.fill"),

            preset("lineout", "セットプレー", "ラインアウト", "自ボールのラインアウトを獲得したら成功。", .result, .cyan, "figure.strengthtraining.traditional"),
            preset("scrum", "セットプレー", "スクラム", "自ボールのスクラムで保持できたら成功。反則獲得は別記録。", .result, .purple, "person.3.fill"),
            preset("lineout_steal", "セットプレー", "ラインアウトスチール", "相手投入のラインアウトを奪った回数。", .count, .cyan, "arrow.up.bin.fill"),
            preset("scrum_penalty_won", "セットプレー", "スクラム反則獲得", "スクラムで相手の反則を引き出した回数。", .count, .purple, "flag.fill"),
            preset("restart_retain", "セットプレー", "リスタート再獲得", "自チームのキックオフ・再開キックを確保できたか。", .result, .blue, "arrow.clockwise"),
            preset("restart_receive", "セットプレー", "リスタート受球", "相手のキックオフ・再開キックを確保できたか。", .result, .cyan, "arrow.down.circle.fill"),
            preset("lineout_rate", "セットプレー", "ラインアウト成功率", "ラインアウトで記録した成功数÷試行数を表示。", .successRate, .cyan, "chart.pie.fill", category: "lineout"),
            preset("scrum_rate", "セットプレー", "スクラム成功率", "スクラムで記録した成功数÷試行数を表示。", .successRate, .purple, "chart.pie.fill", category: "scrum"),

            preset("kick", "キック", "キック回数", "流れの中で蹴った回数。得点キックは含めない。", .count, .blue, "figure.rugby"),
            preset("kick_distance", "キック", "キック距離", "蹴った地点から到達地点までの距離を入力。", .number, .blue, "ruler.fill", unit: "m"),
            preset("kick_reclaim", "キック", "キック再獲得", "流れの中の自チームのキックを取り戻せたか。", .result, .blue, "arrow.uturn.backward.circle.fill"),
            preset("kick_touch", "キック", "タッチキック成否", "狙ったタッチを取れたら成功、取れなければ失敗。", .result, .cyan, "arrow.right.to.line"),
            preset("kick_type", "キック", "キックの種類", "キックの種類を選び、使い分けを振り返る。", .choice, .blue, "list.bullet", choices: ["パント", "ボックス", "グラバー", "チップ", "クロス", "タッチ", "その他"]),
            preset("exit_success", "キック", "自陣脱出", "自陣22m内から圧力を逃れたら成功。判定基準はチームで統一。", .result, .blue, "arrow.up.right.square.fill"),

            preset("penalty", "規律", "反則の種類", "自チームが犯した反則の種類を記録。", .choice, .red, "flag.fill", choices: ["オフサイド", "ハイタックル", "ノットリリース", "ノットロールアウェイ", "サイドエントリー", "スクラム", "ラインアウト", "その他"]),
            preset("free_kick_conceded", "規律", "FKを与えた回数", "相手にフリーキックを与えた回数。", .count, .orange, "f.circle.fill"),
            preset("yellow_card", "規律", "イエローカード", "自チームに出たイエローカードの枚数。", .count, .yellow, "rectangle.fill"),
            preset("red_card", "規律", "レッドカード", "自チームに出たレッドカードの枚数。", .count, .red, "rectangle.fill"),
            preset("penalty_won", "規律", "反則獲得", "相手の反則でペナルティを得た回数。", .count, .green, "flag.checkered"),

            preset("attacking_22_entry", "エリア・起点", "敵陣22m侵入", "ボールを保持して相手22m内へ入った攻撃の回数。", .count, .green, "sportscourt.fill"),
            preset("attacking_22_outcome", "エリア・起点", "22m侵入の結果", "敵陣22m内の攻撃がどう終わったかを記録。得点は別に入力。", .choice, .green, "target", choices: ["トライ", "PG・DG", "反則獲得", "ボール喪失", "タッチ", "その他"]),
            preset("field_zone", "エリア・起点", "プレーの場所", "直前のプレーに、攻撃方向を踏まえた9分割の場所を追加。", .zone, .green, "square.grid.3x3.fill", attachesToLatest: true),
            preset("attack_channel", "エリア・起点", "攻撃したレーン", "攻めた幅を左・中央・右から選ぶ。", .choice, .cyan, "rectangle.split.3x1", choices: ["左", "中央", "右"]),
            preset("origin", "エリア・起点", "攻撃の起点", "直前のプレーに攻撃の起点を追加。", .choice, .green, "arrow.triangle.branch", choices: PlayOrigin.allCases.map(\.shortName), attachesToLatest: true)
        ]
    }()

    private static func preset(
        _ id: String, _ group: String, _ title: String, _ subtitle: String,
        _ kind: RecordingWidgetKind, _ color: RecordingWidgetColor, _ symbol: String,
        category: String? = nil, unit: String = "", choices: [String] = [],
        attachesToLatest: Bool = false
    ) -> RecordingMetricPreset {
        var widget = RecordingWidgetDefinition.make(kind)
        widget.title = title
        widget.category = category ?? id
        widget.color = color
        widget.symbol = symbol
        widget.size = .compact
        widget.unit = unit
        widget.choices = choices
        widget.attachesToLatest = attachesToLatest
        widget.isPrimaryAction = kind == .count
        return RecordingMetricPreset(id: id, group: group, title: title, subtitle: subtitle, widget: widget)
    }
}

nonisolated struct RecordingMetricSummary: Equatable, Sendable {
    let count: Int
    let successes: Int
    let attempts: Int
    let numericCount: Int
    let unit: String?
    let hasMixedUnits: Bool
    /// 数値が未入力のときは nil。記録された 0 と区別する。
    let total: Double?
    let average: Double?

    /// 0〜1。成功・失敗の記録がなければ nil。
    var successRate: Double? {
        attempts == 0 ? nil : Double(successes) / Double(attempts)
    }
}

nonisolated enum RecordingMetricAggregation {
    /// 呼び出し側で試合を絞る。teamID が nil なら渡された全チームを対象にする。
    /// 単位が混ざる場合は合計・平均を出さない。未指定の単位と指定済みの単位も区別する。
    static func summary<E: AnalysisEventRecord>(events: [E], category: String, teamID: UUID? = nil) -> RecordingMetricSummary {
        // 記録が十万件を超えても速いよう、1回なめるだけで数える(記録を写し直さない)。結果は以前と同じ
        var count = 0, successes = 0, attempts = 0, numericCount = 0
        var units = Set<String>()
        var sum = 0.0
        for event in events where event.category == category && (teamID == nil || event.teamID == teamID) {
            count += 1
            let outcome = event.outcome
            if outcome == "success" { successes += 1; attempts += 1 } else if outcome == "fail" { attempts += 1 }
            let details = event.recordingDetails
            guard let number = details.number, number.isFinite else { continue }
            numericCount += 1
            sum += number
            units.insert((details.unit ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let hasMixedUnits = units.count > 1
        let unit = units.count == 1 ? units.first : nil
        let total = numericCount == 0 || hasMixedUnits || !sum.isFinite ? nil : sum
        return RecordingMetricSummary(
            count: count, successes: successes, attempts: attempts,
            numericCount: numericCount,
            unit: unit == "" ? nil : unit, hasMixedUnits: hasMixedUnits, total: total,
            average: total.map { $0 / Double(numericCount) }
        )
    }
}
