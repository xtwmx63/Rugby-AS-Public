//
//  Models.swift
//  Rugby AS
//
//  Created by Codex on 2026/05/17.
//

import Foundation
import SwiftData

enum RugbyPositionGroup: String {
    case forwards = "FW"
    case backs = "BK"
    case utility = "UT"

    var displayName: String {
        switch self {
        case .forwards: "フォワード"
        case .backs: "バックス"
        case .utility: "ユーティリティ"
        }
    }
}

enum RugbyPosition: String, CaseIterable, Identifiable {
    case forward = "FW"
    case back = "BK"
    case utility = "UT"
    case prop = "PR"
    case hooker = "HO"
    case lock = "LO"
    case flanker = "FL"
    case numberEight = "NO.8"
    case scrumHalf = "SH"
    case standOff = "SO"
    case center = "CTB"
    case wing = "WTB"
    case fullback = "FB"

    var id: String { rawValue }

    var group: RugbyPositionGroup {
        switch self {
        case .forward, .prop, .hooker, .lock, .flanker, .numberEight:
            .forwards
        case .back, .scrumHalf, .standOff, .center, .wing, .fullback:
            .backs
        case .utility:
            .utility
        }
    }

    var name: String {
        switch self {
        case .forward: "フォワード"
        case .back: "バックス"
        case .utility: "ユーティリティ"
        case .prop: "プロップ"
        case .hooker: "フッカー"
        case .lock: "ロック"
        case .flanker: "フランカー"
        case .numberEight: "ナンバーエイト"
        case .scrumHalf: "スクラムハーフ"
        case .standOff: "スタンドオフ"
        case .center: "センター"
        case .wing: "ウイング"
        case .fullback: "フルバック"
        }
    }

    var selectionLabel: String {
        "\(rawValue)（\(name)）"
    }

    var groupedSelectionLabel: String {
        rawValue == group.rawValue
            ? selectionLabel
            : "\(group.rawValue)・\(selectionLabel)"
    }

    var identityTags: [String] {
        rawValue == group.rawValue
            ? [rawValue, name]
            : [group.rawValue, rawValue, name]
    }
}

@Model
final class Team {
    @Attribute(.unique) var id: UUID
    var name: String
    // ロゴ画像のファイル名（ドキュメントディレクトリ配下）。nil で未設定。
    var logoPath: String?
    // チームカラーの 16 進カラーコード（"#RRGGBB"）。nil ならサマリー側で
    // HOME/AWAY 既定色（青/赤）にフォールバック。
    var colorHex: String?
    // フォルダ分け用の自由なカテゴリー名（"男子" "女子" "大学" など）。
    // nil/空 は「未分類」として扱う。
    var category: String?
    // 別名(大会ごとの表記ゆれ・旧チーム名など)。チームを統合したときに消えた方の名前が入り、
    // 公式記録を取り込むときの照合にも使う。後付けの項目なので既存チームは空。
    var aliases: [String] = []
    // お気に入り(チーム一覧の一番上に並べる)。後付けの項目なので既存チームは false。
    var isFavorite: Bool = false

    init(id: UUID = UUID(), name: String, logoPath: String? = nil, colorHex: String? = nil, category: String? = nil,
         aliases: [String] = [], isFavorite: Bool = false) {
        self.id = id
        self.name = name
        self.logoPath = logoPath
        self.colorHex = colorHex
        self.category = category
        self.aliases = aliases
        self.isFavorite = isFavorite
    }
}

@Model
final class Player {
    @Attribute(.unique) var id: UUID
    var teamID: UUID
    // 背番号。nil = 背番号なし(試合に登録されていない選手など)。
    // 試合ごとの実際の番号はメンバー表(MatchLineup.number)に控えられる。
    var number: Int?
    var name: String?
    // 名前の読み(かな)。入力すると英語表記の自動生成に使う。
    var nameKana: String?
    // カードに載せる英語表記。読みから自動生成されるが、手動で上書きも可能。
    var nameRoman: String?
    // 顔写真のファイル名（ドキュメントディレクトリ配下）。nil で未設定。
    var imagePath: String?
    // ラグビーのポジションコード（RugbyPosition.rawValue）。nil で未設定。
    var position: String?
    // 名鑑のお気に入り。既存データは false で軽量移行する。
    var isFavorite: Bool = false
    // プロフィール(すべて任意)。年齢は生年月日から表示時に計算する。
    var birthDate: Date?
    var heightCm: Int?
    var weightKg: Int?
    // 別名(旧姓・表記ゆれ)。選手を統合したときに消えた方の名前が入り、
    // 公式記録を取り込むときの照合にも使う。後付けの項目なので既存選手は空。
    var aliases: [String] = []
    // 同一人物の印。移籍・代表・国体・合同チームなどで別のチームにも登録された同じ人は、
    // 同じ値を持つ(チームごとの登録や背番号はそのまま)。nil = どこともつないでいない。
    var personID: UUID?

    init(
        id: UUID = UUID(),
        teamID: UUID,
        number: Int?,
        name: String? = nil,
        nameKana: String? = nil,
        nameRoman: String? = nil,
        imagePath: String? = nil,
        position: String? = nil,
        isFavorite: Bool = false,
        birthDate: Date? = nil,
        heightCm: Int? = nil,
        weightKg: Int? = nil,
        aliases: [String] = [],
        personID: UUID? = nil
    ) {
        self.id = id
        self.teamID = teamID
        self.number = number
        self.name = name
        self.nameKana = nameKana
        self.nameRoman = nameRoman
        self.imagePath = imagePath
        self.position = position
        self.isFavorite = isFavorite
        self.birthDate = birthDate
        self.heightCm = heightCm
        self.weightKg = weightKg
        self.aliases = aliases
        self.personID = personID
    }
}

extension Player {
    var rugbyPosition: RugbyPosition? {
        get {
            guard let position else { return nil }
            return RugbyPosition(rawValue: position)
        }
        set {
            position = newValue?.rawValue
        }
    }
}

@Model
final class Tournament {
    @Attribute(.unique) var id: UUID
    var officialName: String
    // 年度（西暦）。同じ名前の大会を年ごとに束ねて「過去の年度」を見るのに使う。nil=未設定。
    var year: Int?
    // 大会ロゴ画像のファイル名（ドキュメントディレクトリ配下）。nil で未設定。
    var logoPath: String?
    // 7人制/15人制（RugbyVariant の rawValue）。nil=未設定。
    var variantRaw: String?
    // フォーマット（TournamentFormat の rawValue）。nil=未設定。
    var formatRaw: String?
    // この大会に出場するチームの id 一覧。試合の有無に関係なく事前登録できる。
    var teamIDs: [UUID] = []
    // 同じシリーズの大会(例: 太陽生命ウィメンズセブンズシリーズ2026 の熊谷・北九州…)を束ねる名前。
    // 自由入力。nil/空 = シリーズなし。同じ名前の大会どうしを「シリーズ通算」で合算して見られる。
    var seriesName: String?
    // 大会のカテゴリー(トップ・大学・高校など。自由入力、nil/空 = 未設定)。
    // 同じチームがカテゴリーの違う大会に出るので、チームではなく大会に持たせる。
    var category: String?
    // 男子/女子(RugbyGender の rawValue)。nil=未設定。カテゴリー・人数と同じく大会に持たせる。
    var genderRaw: String?
    // お気に入り(大会一覧の一番上に並べる)。後付けの項目なので既存の大会は false。
    var isFavorite: Bool = false

    init(
        id: UUID = UUID(),
        officialName: String,
        year: Int? = nil,
        logoPath: String? = nil,
        variantRaw: String? = nil,
        formatRaw: String? = nil,
        teamIDs: [UUID] = [],
        seriesName: String? = nil,
        category: String? = nil,
        genderRaw: String? = nil,
        isFavorite: Bool = false
    ) {
        self.id = id
        self.officialName = officialName
        self.year = year
        self.logoPath = logoPath
        self.variantRaw = variantRaw
        self.formatRaw = formatRaw
        self.teamIDs = teamIDs
        self.seriesName = seriesName
        self.category = category
        self.genderRaw = genderRaw
        self.isFavorite = isFavorite
    }
}

@Model
final class Match {
    @Attribute(.unique) var id: UUID
    var tournamentID: UUID
    var homeTeamID: UUID
    var awayTeamID: UUID
    var playedAt: Date
    // カスタム録画ウィジェットのレイアウトと実行中セッション。既存試合は標準レイアウトで開始する。
    var recordingLayoutData: Data?
    var recordingSessionData: Data?
    // true = 分析・選手成績・大会の順位表/ランキング・大会CSV の集計に含めない。
    // 試合そのものや記録は消さず、サマリーからいつでも戻せる。後付けの列なので既存試合は「含める」。
    var isExcludedFromStats: Bool = false
    // 公式記録から取り込んだ試合の出典。試合詳細から公式の試合ページ・公式記録表を開くのに使う。
    // 手で作った試合と、この項目より前の取り込みは nil(起動時に公式記録と照合して後から入れる)。
    var officialRecordID: String?
    var officialPageURL: String?
    var officialSheetURL: String?

    init(
        id: UUID = UUID(),
        tournamentID: UUID,
        homeTeamID: UUID,
        awayTeamID: UUID,
        playedAt: Date,
        recordingLayoutData: Data? = nil,
        recordingSessionData: Data? = nil,
        isExcludedFromStats: Bool = false
    ) {
        self.id = id
        self.tournamentID = tournamentID
        self.homeTeamID = homeTeamID
        self.awayTeamID = awayTeamID
        self.playedAt = playedAt
        self.recordingLayoutData = recordingLayoutData
        self.recordingSessionData = recordingSessionData
        self.isExcludedFromStats = isExcludedFromStats
    }
}

@Model
final class StatEvent {
    @Attribute(.unique) var id: UUID
    var matchID: UUID
    var teamID: UUID?
    var playerID: UUID?
    var category: String
    var outcome: String
    var seconds: Int
    // ポゼッション/BIP など区間イベントの開始時刻。nil の既存データは duration から近似表示する。
    var startSeconds: Int?
    // 0 = 前半, 1 = 後半。既存データは default 0（前半）として扱う。
    var half: Int = 0
    // 起点プレー(PlayOrigin の rawValue)。攻撃(possession)とトライに付ける任意項目。
    var origin: String?
    // 精密な開始位置と長さ。widgetDataのtimeBasisがhalfClockならハーフ内時計。
    // マーカーのない旧タイムライン編集済みデータは動画上の秒として表示を維持する。
    // nilの記録はseconds / startSecondsから読む。読み込み時の一括移行は行わない。
    var startSecondsExact: Double?
    var durationSecondsExact: Double?
    // カスタム録画ウィジェットで入力した任意データ。
    var widgetData: Data?

    init(
        id: UUID = UUID(),
        matchID: UUID,
        teamID: UUID? = nil,
        playerID: UUID? = nil,
        category: String,
        outcome: String,
        seconds: Int,
        startSeconds: Int? = nil,
        half: Int = 0,
        origin: String? = nil,
        startSecondsExact: Double? = nil,
        durationSecondsExact: Double? = nil,
        widgetData: Data? = nil
    ) {
        self.id = id
        self.matchID = matchID
        self.teamID = teamID
        self.playerID = playerID
        self.category = category
        self.outcome = outcome
        self.seconds = seconds
        self.startSeconds = startSeconds
        self.half = half
        self.origin = origin
        self.startSecondsExact = startSecondsExact
        self.durationSecondsExact = durationSecondsExact
        self.widgetData = widgetData
    }
}

@Model
final class MatchLineup {
    @Attribute(.unique) var id: UUID
    var matchID: UUID
    var teamID: UUID
    var playerID: UUID
    // "starter" / "reserve"
    var role: String
    // 表示順（同一 matchID × teamID × role 内で 0 から昇順）
    var order: Int
    // この試合で着ける背番号。nil なら選手の基本番号を使う。
    // (ラグビーは固定背番号を持たず試合ごとに変わるため、試合単位で持つ)
    var number: Int?

    init(
      id: UUID = UUID(),
        matchID: UUID,
        teamID: UUID,
        playerID: UUID,
        role: String,
        order: Int,
        number: Int? = nil
    ) {
        self.id = id
        self.matchID = matchID
        self.teamID = teamID
        self.playerID = playerID
        self.role = role
        self.order = order
        self.number = number
    }
}

@Model
final class Substitution {
    @Attribute(.unique) var id: UUID
    var matchID: UUID
    var playerInID: UUID
    var playerOutID: UUID
    var minute: Int
    // 0 = 前半, 1 = 後半。minute はそのハーフ内の経過分。
    // (StatEvent の half と同じ後付けカラム。既存データは前半扱い)
    var half: Int = 0

    init(
        id: UUID = UUID(),
        matchID: UUID,
        playerInID: UUID,
        playerOutID: UUID,
        minute: Int,
        half: Int = 0
    ) {
        self.id = id
        self.matchID = matchID
        self.playerInID = playerInID
        self.playerOutID = playerOutID
        self.minute = minute
        self.half = half
    }
}

/// 得点になる記録の種類と点数の決まり。点数の計算はここだけを見る
/// (種類を足したときに、画面ごとの計算漏れを起こさないため)。
nonisolated enum ScoringRules {
    /// 認定トライ。7点を1件で表し、キックの記録は作らない(キック成功率に混ぜないため)。
    static let penaltyTryCategory = "penalty_try"
    static let categories = ["try", "conversion", "penalty_goal", "drop_goal", penaltyTryCategory]

    private struct OfficialScoreValue: Decodable {
        let officialPoints: Int?
        let officialScoringCategory: String?
    }

    /// 過去の公式記録にある4点トライ・4/5点認定トライだけを許可する。
    /// 種類を編集した後は、元の得点を別の種類へ持ち越さない。
    static func validatedOfficialPoints(_ points: Int?, category: String) -> Int? {
        guard let points else { return nil }
        switch category {
        case "try": return [4, 5].contains(points) ? points : nil
        case penaltyTryCategory: return [4, 5, 7].contains(points) ? points : nil
        case "conversion": return points == 2 ? points : nil
        case "penalty_goal", "drop_goal": return points == 3 ? points : nil
        default: return nil
        }
    }

    /// 成功した記録1件の点数。得点の種類でなければ 0。
    private static let officialPointsKey = Data("officialPoints".utf8)

    static func points(category: String, widgetData: Data? = nil) -> Int {
        // 公式記録の点数が入っていない記録は、中身をほどかなくてよい(得点の集計が速くなる。結果は同じ)
        if let widgetData, widgetData.range(of: officialPointsKey) != nil,
           let stored = try? JSONDecoder().decode(OfficialScoreValue.self, from: widgetData),
           stored.officialScoringCategory == category,
           let points = validatedOfficialPoints(stored.officialPoints, category: category) {
            return points
        }
        switch category {
        case "try": return 5
        case "conversion": return 2
        case "penalty_goal", "drop_goal": return 3
        case penaltyTryCategory: return 7
        default: return 0
        }
    }
}
