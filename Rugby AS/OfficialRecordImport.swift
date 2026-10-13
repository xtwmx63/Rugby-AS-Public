import Foundation
import SwiftData

// 公式記録の1試合を「自分の試合」として取り込むための下書きと保存処理。
// いきなり保存せず、下書きを画面で確認・修正してから保存する(読み取りの誤りを手で直せるように)。
// 取り込んだ後は通常の試合と同じ記録なので、プレー一覧や記録画面から詳しく追記できる。

nonisolated struct OfficialImportEvent: Identifiable, Equatable, Sendable {
    let id = UUID()
    var side: String          // "home" / "away"
    var half: Int             // 0 = 前半, 1 = 後半
    var minute: Int           // そのハーフ内の経過分
    var category: String      // StatEvent.category
    var outcome: String       // "success" / "fail"
    var playerName: String    // 空 = 選手なし
    var playerNumber: Int?    // 得点者の背番号(リーグワンは「10.名前」の形で載っている)
    var isIncluded = true
    var officialPoints: Int? = nil

    var points: Int { outcome == "success" ? (ScoringRules.validatedOfficialPoints(officialPoints, category: category) ?? ScoringRules.points(category: category)) : 0 }
}

nonisolated struct OfficialImportMember: Equatable, Sendable {
    var side: String
    var number: Int?
    var name: String
    var position: String?     // Player.position に入れる値(RugbyPosition.rawValue)
    var isStarter: Bool
}

/// 交代1件。一時交替(出血・HIA・シンビン)は「出る」と「戻る」の2件に分けて持つ。
nonisolated struct OfficialImportSubstitution: Equatable, Sendable {
    var side: String
    var half: Int             // 0 = 前半, 1 = 後半
    var minute: Int           // そのハーフ内の経過分
    var outgoingName: String
    var outgoingNumber: Int?
    var incomingName: String
    var incomingNumber: Int?
}

nonisolated struct OfficialImportDraft: Equatable, Sendable {
    var tournamentName: String
    var year: Int?
    var playedAt: Date
    var homeTeamName: String
    var awayTeamName: String
    var officialHomeScore: Int?
    var officialAwayScore: Int?
    var events: [OfficialImportEvent]
    var members: [OfficialImportMember]
    var includesLineups = true
    var notes: [String]
    /// 大会を新しく作るときに付けるシリーズ名(例: 太陽生命ウィメンズセブンズシリーズ2026)。nil = なし
    var seriesName: String? = nil
    /// 交代(メンバー表を取り込むときだけ使う)
    var substitutions: [OfficialImportSubstitution] = []
    /// 前半・後半の長さ(分)。公式記録には載っていないので、形式の標準の長さと記録の最終時刻から決める
    var halfMinutes: [Int] = [40, 40]
    /// 出典。試合詳細から公式の試合ページ・公式記録表を開くのに使う
    var officialRecordID: String? = nil
    var officialPageURL: String? = nil
    var officialSheetURL: String? = nil

    func score(side: String) -> Int {
        events.filter { $0.isIncluded && $0.side == side }.reduce(0) { $0 + $1.points }
    }

    /// 取り込む得点の合計が公式の最終スコアと一致するか(公式スコアがない試合は nil)
    var matchesOfficialScore: Bool? {
        guard let home = officialHomeScore, let away = officialAwayScore else { return nil }
        return score(side: "home") == home && score(side: "away") == away
    }
}

enum OfficialRecordImporter {
    /// 公式記録から下書きを作る。保存はしない。
    nonisolated static func draft(from record: OfficialRecord, calendar: Calendar = .current) -> OfficialImportDraft {
        var notes: [String] = record.omissions ?? []
        var events: [OfficialImportEvent] = []
        var skipped = 0
        var extraTime = 0
        var unknownTiming = 0
        for item in record.scoreEvents {
            guard item.side == "home" || item.side == "away",
                  let (category, outcome) = category(forKind: item.kind) else { skipped += 1; continue }
            let half: Int
            switch item.period {
            case "前半": half = 0
            case "後半": half = 1
            default:
                half = 1
                if item.period.isEmpty { unknownTiming += 1 } else { extraTime += 1 }
            }
            if !item.period.isEmpty && item.time.isEmpty { unknownTiming += 1 }
            let minute = Int(item.time.filter(\.isNumber)) ?? 0
            let scorer = splitNumber(item.player)
            events.append(OfficialImportEvent(side: item.side, half: half, minute: minute, category: category,
                                              outcome: outcome, playerName: scorer.name, playerNumber: scorer.number,
                                              officialPoints: ScoringRules.validatedOfficialPoints(item.points ?? historicalPoints(forKind: item.kind), category: category)))
        }
        // 公式記録票の公開が終わった試合は、得点経過がない。試合ページの前後半の内訳(T・G・PT・PG・DG)から作る
        if record.scoreEvents.isEmpty {
            switch breakdownEvents(record) {
            case .some(let made) where !made.isEmpty:
                events = made
                notes.append(breakdownNote)
            case .none where breakdownCounts(record) != nil:
                notes.append("試合ページの得点内訳が公式スコアと合わないため、得点は入りません。必要ならプレー一覧から追加してください。")
            default:
                break
            }
        }
        if events.contains(where: { $0.officialPoints != nil && $0.points != ScoringRules.points(category: $0.category) }) {
            notes.append("当時の得点ルール（4点トライなど）を保って取り込みます。")
        }
        if unknownTiming > 0 {
            notes.append("時刻・時間帯不明の得点\(unknownTiming)件は、時間帯不明なら仮に後半、時刻不明なら0分として入ります。前後半別の集計や得点グラフには確認・修正が必要です。")
        }
        if extraTime > 0 { notes.append("延長の得点\(extraTime)件は「後半」として入ります。") }
        if skipped > 0 { notes.append("種類やチームが読み取れない得点\(skipped)件は取り込みません。") }

        let members = record.players.compactMap { player -> OfficialImportMember? in
            let name = player.name.trimmingCharacters(in: .whitespaces)
            guard player.side == "home" || player.side == "away", !name.isEmpty else { return nil }
            return OfficialImportMember(side: player.side, number: player.number, name: name,
                                        position: position(for: player.position), isStarter: player.role.hasPrefix("先発"))
        }
        let outsiders = Set(events.filter { !$0.playerName.isEmpty && member(for: $0, in: members) == nil }.map(\.playerName))
        if !members.isEmpty && !outsiders.isEmpty {
            notes.append("メンバー表にない得点者（\(outsiders.sorted().joined(separator: "、"))）は、名前だけの選手として登録されます。")
        }

        let (substitutions, skippedSubstitutions) = substitutions(from: record.substitutions, members: members)
        if skippedSubstitutions > 0 {
            notes.append("選手が読み取れない交代・退出\(skippedSubstitutions)件は取り込みません（その選手の出場時間は多めに出ます）。")
        }
        if members.isEmpty {
            notes.append("公式記録にメンバー表がないため、出場時間は計算できません。")
        } else if record.substitutions.isEmpty {
            notes.append("公式記録に交代の記載がないため、先発は全時間出場として計算されます。")
        }
        let halves = halfMinutes(record: record, events: events, substitutions: substitutions)
        notes.append("公式記録に試合時間の記載がないため、前半\(halves[0])分・後半\(halves[1])分として出場時間を計算します。")

        return OfficialImportDraft(
            tournamentName: OfficialTournamentGrouping.parentName(record.tournament), year: record.year,
            playedAt: record.kickoffUTC.flatMap { ISO8601DateFormatter().date(from: $0) }
                ?? playedAt(date: record.date, kickoff: record.kickoff, calendar: calendar) ?? .now,
            homeTeamName: importedTeamName(record.homeTeam, record: record),
            awayTeamName: importedTeamName(record.awayTeam, record: record),
            officialHomeScore: record.homeScore, officialAwayScore: record.awayScore,
            events: events, members: members, includesLineups: !members.isEmpty, notes: notes,
            seriesName: record.seriesName ?? OfficialTournamentGrouping.seriesName(for: record.tournament),
            substitutions: substitutions, halfMinutes: halves, officialRecordID: record.id,
            officialPageURL: record.sourceURL.isEmpty ? nil : record.sourceURL,
            officialSheetURL: record.officialRecordURL.flatMap { $0.isEmpty || $0 == record.sourceURL ? nil : $0 })
    }

    nonisolated static let breakdownNote = "公式記録票の公開が終わった試合のため、試合ページの前後半の得点内訳（T・G・PT・PG・DG）から得点を作ります。時刻と得点者は分からないので、各ハーフの0分・得点者なしで入ります（ゴールは成功の数だけ）。"

    /// 試合ページの得点内訳。[ハーフ(0/1)][種類] = (HOME, AWAY)。内訳がなければ nil
    nonisolated static func breakdownCounts(_ record: OfficialRecord) -> [Int: [String: (home: Int, away: Int)]]? {
        var counts: [Int: [String: (home: Int, away: Int)]] = [:]
        for stat in record.stats {
            let parts = stat.label.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let half = ["前半": 0, "後半": 1][parts[0]],
                  ["T", "G", "PT", "PG", "DG"].contains(parts[1]),
                  let home = Int(stat.home.trimmingCharacters(in: .whitespaces).isEmpty ? "0" : stat.home.trimmingCharacters(in: .whitespaces)),
                  let away = Int(stat.away.trimmingCharacters(in: .whitespaces).isEmpty ? "0" : stat.away.trimmingCharacters(in: .whitespaces)),
                  home >= 0, away >= 0, home <= 50, away <= 50 else { continue }
            counts[half, default: [:]][parts[1]] = (home, away)
        }
        return counts.isEmpty ? nil : counts
    }

    /// 内訳から得点の記録を作る。内訳の点数が公式スコアと合うときだけ(合わなければ nil。内訳がなければ空)。
    /// トライは5点で合わなければ4点(昔の得点ルール)で確かめる。
    nonisolated static func breakdownEvents(_ record: OfficialRecord) -> [OfficialImportEvent]? {
        guard let counts = breakdownCounts(record) else { return [] }
        guard let officialHome = record.homeScore, let officialAway = record.awayScore else { return nil }
        let categories = ["T": "try", "G": "conversion", "PT": ScoringRules.penaltyTryCategory,
                          "PG": "penalty_goal", "DG": "drop_goal"]
        for tryPoints in [5, 4] {
            var events: [OfficialImportEvent] = []
            for half in [0, 1] {
                for kind in ["T", "G", "PT", "PG", "DG"] {
                    guard let pair = counts[half]?[kind], let category = categories[kind] else { continue }
                    for (side, count) in [("home", pair.home), ("away", pair.away)] {
                        for _ in 0..<count {
                            events.append(OfficialImportEvent(side: side, half: half, minute: 0, category: category,
                                                              outcome: "success", playerName: "", playerNumber: nil,
                                                              officialPoints: kind == "T" && tryPoints == 4 ? 4 : nil))
                        }
                    }
                }
            }
            let total = { (side: String) in events.filter { $0.side == side }.reduce(0) { $0 + $1.points } }
            if total("home") == officialHome && total("away") == officialAway { return events }
        }
        return nil
    }

    nonisolated static func historicalPoints(forKind kind: String) -> Int? {
        switch kind {
        case "T4", "PT4": return 4
        case "PT5": return 5
        default: return nil
        }
    }

    /// 公式国名は男女で同じため、取り込み先で名簿が混ざらないよう区別する。
    nonisolated static func importedTeamName(_ name: String, record: OfficialRecord) -> String {
        importedTeamName(name, source: record.source, category: record.category)
    }

    nonisolated static func importedTeamName(_ name: String, source: String, category: String) -> String {
        if source == "rwc" {
            return name + (category.contains("女子") ? "（女子15人制）" : "（男子15人制）")
        }
        guard source == "svns" else { return name }
        if category.contains("女子") { return name + "（女子7人制）" }
        if category.contains("男子") { return name + "（男子7人制）" }
        return name
    }

    /// 公式記録の交代をアプリの交代に直す。一時交替は「入る」と「戻る」の2件にし、戻りのない一時交替
    /// (試合終了まで・そのまま交替になった)は普通の交替として扱う。選手が分からない行と「退出」は数えて飛ばす。
    nonisolated static func substitutions(from items: [OfficialRecordSubstitution],
                                          members: [OfficialImportMember]) -> ([OfficialImportSubstitution], Int) {
        var result: [OfficialImportSubstitution] = []
        var skipped = 0
        let permanent = items.filter { !$0.kind.hasPrefix("一時交替") }
        for item in items {
            guard item.side == "home" || item.side == "away" else { skipped += 1; continue }
            let outgoing = person(item.outgoing, side: item.side, in: members)
            let incoming = person(item.incoming, side: item.side, in: members)
            guard let outgoing, let incoming, let start = periodTime(period: item.period, text: item.time) else {
                skipped += 1
                continue
            }
            let isTemporary = item.kind.hasPrefix("一時交替")
            // 一時交替がそのまま交替になった試合は、同じ2人の交替が別に載っているので二重に数えない
            if isTemporary && permanent.contains(where: { $0.side == item.side && $0.outgoing == item.outgoing && $0.incoming == item.incoming }) {
                continue
            }
            result.append(OfficialImportSubstitution(side: item.side, half: start.half, minute: start.minute,
                outgoingName: outgoing.name, outgoingNumber: outgoing.number,
                incomingName: incoming.name, incomingNumber: incoming.number))
            if isTemporary, let back = returnTime(period: item.period, text: item.time) {
                result.append(OfficialImportSubstitution(side: item.side, half: back.half, minute: back.minute,
                    outgoingName: incoming.name, outgoingNumber: incoming.number,
                    incomingName: outgoing.name, incomingNumber: outgoing.number))
            }
        }
        return (result, skipped)
    }

    /// 交代の選手名(「16. 名前」「名前」、名前の分からないときは背番号だけ)をメンバー表の選手に当てる
    nonisolated private static func person(_ raw: String, side: String, in members: [OfficialImportMember]) -> (name: String, number: Int?)? {
        let split = splitNumber(raw)
        var number = split.number
        var name = split.name
        if number == nil, !name.isEmpty, name.allSatisfy({ $0.isASCII && $0.isNumber }) { number = Int(name); name = "" }
        let sameSide = members.filter { $0.side == side }
        if !name.isEmpty, let found = sameSide.first(where: { nameKey($0.name) == nameKey(name) }) { return (found.name, found.number) }
        if let number, let found = sameSide.first(where: { $0.number == number }) { return (found.name, found.number) }
        return nil
    }

    /// 「4分」→ (その時間帯, 4分)。「38分 → 後半0分」の形は最初の時刻を読む
    nonisolated static func periodTime(period: String, text: String) -> (half: Int, minute: Int)? {
        let first = text.components(separatedBy: "→")[0]
        guard let minute = Int(first.filter { $0.isASCII && $0.isNumber }) else { return nil }
        return (half(of: period), minute)
    }

    /// 一時交替の戻りの時刻(「38分 → 後半0分」の後ろ)。「試合終了」や戻りのない行は nil
    nonisolated static func returnTime(period: String, text: String) -> (half: Int, minute: Int)? {
        let parts = text.components(separatedBy: "→")
        guard parts.count == 2 else { return nil }
        let back = parts[1].trimmingCharacters(in: .whitespaces)
        guard let minute = Int(back.filter { $0.isASCII && $0.isNumber }) else { return nil }
        let backPeriod = ["延長後半", "延長前半", "後半", "前半"].first { back.hasPrefix($0) } ?? period
        return (half(of: backPeriod), minute)
    }

    /// 前半=0、後半と延長=1(得点の取り込みと同じく、延長は後半として入れる)
    nonisolated private static func half(of period: String) -> Int {
        period == "前半" ? 0 : 1
    }

    /// 前後半の長さ(分)。公式記録には試合時間が載っていないので、形式の標準の長さ(7人制7分・高校30分・
    /// それ以外の15人制40分。中学・ミニなど決まらないものはなし)と、得点・交代の最後の時刻の長い方にする。
    nonisolated static func halfMinutes(record: OfficialRecord, events: [OfficialImportEvent],
                                        substitutions: [OfficialImportSubstitution]) -> [Int] {
        let standard = standardHalfMinutes(tournament: record.tournament, category: record.category,
                                           squadSize: max(record.players.filter { $0.side == "home" }.count,
                                                          record.players.filter { $0.side == "away" }.count))
        return [0, 1].map { half in
            let latest = (events.filter { $0.half == half }.map(\.minute) + substitutions.filter { $0.half == half }.map(\.minute)).max() ?? 0
            return max(1, standard ?? 0, latest)
        }
    }

    nonisolated static func standardHalfMinutes(tournament: String, category: String, squadSize: Int) -> Int? {
        let text = tournament + " " + category
        if ["中学", "ミニ", "小学", "U12", "U15"].contains(where: text.contains) { return nil }
        if ["セブンズ", "セブンス", "7人制", "７人制", "Sevens", "SEVENS", "SVNS", "Fast Four"].contains(where: text.contains) { return 7 }
        // 古いW杯の部分的な名簿を7人制と誤認しない。
        if text.contains("ワールドカップ") || text.contains("15人制") { return 40 }
        if (1...13).contains(squadSize) { return 7 }
        if text.contains("高等学校") || text.contains("高校") { return 30 }
        return 40
    }

    /// 「10.名前」を背番号と名前に分ける。番号がなければ名前だけ。
    nonisolated static func splitNumber(_ raw: String) -> (number: Int?, name: String) {
        let text = raw.trimmingCharacters(in: .whitespaces)
        let digits = text.prefix { $0.isASCII && $0.isNumber }
        let rest = text.dropFirst(digits.count)
        // 元データに「.名前」「.」だけの誤記がまれにあるので、先頭の点は落とす
        guard !digits.isEmpty, let first = rest.first, first == "." || first == "．" else {
            return (nil, String(text.drop { $0 == "." || $0 == "．" }).trimmingCharacters(in: .whitespaces))
        }
        return (Int(digits), rest.dropFirst().trimmingCharacters(in: .whitespaces))
    }

    /// 得点者をメンバー表から探す。名前で探し、見つからなければ同じチームの背番号で探す。
    nonisolated static func member(for event: OfficialImportEvent, in members: [OfficialImportMember]) -> OfficialImportMember? {
        let sameSide = members.filter { $0.side == event.side }
        if let byName = sameSide.first(where: { nameKey($0.name) == nameKey(event.playerName) }) { return byName }
        guard let number = event.playerNumber else { return nil }
        return sameSide.first { $0.number == number }
    }

    /// 公式記録の得点記号 → アプリの記録の種類。T/G/PG/DG/PT、x 付きは失敗。
    nonisolated static func category(forKind kind: String) -> (String, String)? {
        let missed = kind.hasSuffix("x")
        let base = missed ? String(kind.dropLast()) : kind
        let category: String
        switch base {
        case "T", "T4": category = "try"
        case "G": category = "conversion"
        case "PG": category = "penalty_goal"
        case "DG": category = "drop_goal"
        case "PT", "PT4", "PT5": category = ScoringRules.penaltyTryCategory
        default: return nil
        }
        // トライと認定トライに「失敗」はない
        if missed && (category == "try" || category == ScoringRules.penaltyTryCategory) { return nil }
        return (category, missed ? "fail" : "success")
    }

    nonisolated static func position(for official: String) -> String? {
        switch official.uppercased() {
        case "NO8", "NO.8", "N8": return RugbyPosition.numberEight.rawValue
        case "TB", "HB": return RugbyPosition.back.rawValue
        case "": return nil
        default: return RugbyPosition(rawValue: official.uppercased())?.rawValue
        }
    }

    /// 名前の照合用。スペースの有無・全角半角・大文字小文字の違いで別人(別チーム)扱いにしない。
    nonisolated static func nameKey(_ name: String) -> String {
        name.filter { !$0.isWhitespace }
            .folding(options: [.widthInsensitive, .caseInsensitive], locale: Locale(identifier: "ja_JP"))
    }

    nonisolated static func playedAt(date: String, kickoff: String, calendar: Calendar) -> Date? {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let time = kickoff.split(separator: ":").compactMap { Int($0.prefix(2)) }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2],
                                                  hour: time.count == 2 ? time[0] : 12, minute: time.count == 2 ? time[1] : 0))
    }

    static func existingTeam(named name: String, in teams: [Team]) -> Team? {
        let key = nameKey(name)
        guard !key.isEmpty else { return nil }
        // 名前が一致するチームを優先し、なければ別名(統合したチームの旧表記など)で探す
        return teams.first { nameKey($0.name) == key }
            ?? teams.first { $0.aliases.contains { nameKey($0) == key } }
    }

    /// 同じ日に同じ2チームの試合が既にあるか(二重取り込みの注意用)
    static func hasSameDayMatch(_ draft: OfficialImportDraft, teams: [Team], matches: [Match], calendar: Calendar = .current) -> Bool {
        guard let home = existingTeam(named: draft.homeTeamName, in: teams),
              let away = existingTeam(named: draft.awayTeamName, in: teams) else { return false }
        return matches.contains { match in
            Set([match.homeTeamID, match.awayTeamID]) == Set([home.id, away.id])
                && calendar.isDate(match.playedAt, inSameDayAs: draft.playedAt)
        }
    }

    /// 下書きを保存して、作った試合を返す。既存の大会・チーム・選手は名前が同じなら使い回す。
    /// 失敗したら何も残さない(途中まで作ったものは取り消す)。
    @discardableResult
    static func save(_ draft: OfficialImportDraft, context: ModelContext) throws -> Match {
        do {
            var index = try ImportIndex(context: context)
            let match = try insert(draft, context: context, index: &index)
            try context.save()
            return match
        } catch {
            context.rollback()
            throw error
        }
    }

    /// 複数の試合をまとめて保存する。1試合でも失敗したら、どれも保存しない。
    @discardableResult
    static func saveAll(_ drafts: [OfficialImportDraft], context: ModelContext) throws -> [Match] {
        do {
            // 既存の大会・チーム・選手の照合表は1回だけ作り、試合ごとに作り直さない
            // (以前は試合ごとに全選手を読み直して名前を整えていたので、大きな大会だと重かった)
            var index = try ImportIndex(context: context)
            let matches = try drafts.map { try insert($0, context: context, index: &index) }
            try context.save()
            return matches
        } catch {
            context.rollback()
            throw error
        }
    }

    /// Official IDs survive renamed teams and edited dates. Older imports without
    /// IDs (and alternate publishers) also use the day and unordered team pair.
    nonisolated struct DuplicateIndex {
        private var ids: Set<String>
        private var games: [String: Set<String>] = [:]
        private var teamKeys: [String: String] = [:]
        private let calendar: Calendar

        init(context: ModelContext, calendar: Calendar = .current) throws {
            self.calendar = calendar
            let teams = try context.fetch(FetchDescriptor<Team>())
            for team in teams { teamKeys[nameKey(team.name)] = team.id.uuidString }
            for team in teams {
                for alias in team.aliases where teamKeys[nameKey(alias)] == nil {
                    teamKeys[nameKey(alias)] = team.id.uuidString
                }
            }
            var descriptor = FetchDescriptor<Match>()
            // Large recording layouts/sessions are irrelevant to duplicate checks.
            descriptor.propertiesToFetch = [\.officialRecordID, \.homeTeamID, \.awayTeamID, \.playedAt]
            let matches = try context.fetch(descriptor)
            ids = Set(matches.compactMap(\.officialRecordID))
            for match in matches {
                let key = gameKey(home: match.homeTeamID.uuidString, away: match.awayTeamID.uuidString, date: match.playedAt)
                games[key, default: []].insert(source(match.officialRecordID))
            }
        }

        private func source(_ id: String?) -> String { id?.components(separatedBy: ":").first ?? "" }
        private func gameKey(home: String, away: String, date: Date) -> String {
            ([home, away].sorted() + [String(calendar.startOfDay(for: date).timeIntervalSince1970)]).joined(separator: "|")
        }
        private func key(_ draft: OfficialImportDraft) -> String {
            let home = nameKey(draft.homeTeamName), away = nameKey(draft.awayTeamName)
            return gameKey(home: teamKeys[home] ?? home, away: teamKeys[away] ?? away, date: draft.playedAt)
        }
        func contains(_ draft: OfficialImportDraft) -> Bool {
            if let id = draft.officialRecordID, ids.contains(id) { return true }
            let publishers = games[key(draft), default: []]
            let incoming = source(draft.officialRecordID)
            // Distinct IDs from the same publisher may be two sevens games on one day.
            return publishers.contains("") || publishers.contains { $0 != incoming } || (incoming.isEmpty && !publishers.isEmpty)
        }
        mutating func insert(_ draft: OfficialImportDraft) {
            if let id = draft.officialRecordID { ids.insert(id) }
            games[key(draft), default: []].insert(source(draft.officialRecordID))
        }
    }

    /// Use a separate context so a failed chunk never rolls back the user's edits.
    /// Reuse the player index across chunks, but keep only the current drafts.
    nonisolated final class BulkSession {
        private let context: ModelContext
        private var index: ImportIndex
        private var duplicates: DuplicateIndex

        convenience init(container: ModelContainer) throws {
            try self.init(context: ModelContext(container))
        }

        init(context: ModelContext) throws {
            context.autosaveEnabled = false
            self.context = context
            self.index = try ImportIndex(context: context)
            self.duplicates = try DuplicateIndex(context: context)
        }

        func saveBatch(_ drafts: [OfficialImportDraft]) throws -> Int {
            var nextDuplicates = duplicates
            var count = 0
            do {
                for draft in drafts where !nextDuplicates.contains(draft) {
                    _ = try OfficialRecordImporter.insert(draft, context: context, index: &index)
                    nextDuplicates.insert(draft)
                    count += 1
                }
                try context.save()
                duplicates = nextDuplicates
                return count
            } catch {
                context.rollback()
                // Discard references to objects invalidated by rollback.
                index = try ImportIndex(context: context)
                throw error
            }
        }
    }

    /// 取り込みで使う照合表。名前は nameKey で整えた形で引く。取り込み中に作ったものも足していく。
    nonisolated private struct ImportIndex {
        var tournaments: [Tournament]
        var tournamentKeys: [String]
        var teamsByKey: [String: Team] = [:]
        var teamsByAlias: [String: Team] = [:]
        var playersByKey: [String: Player] = [:]
        var usedNumbers: [UUID: Set<Int>] = [:]

        init(context: ModelContext) throws {
            tournaments = try context.fetch(FetchDescriptor<Tournament>())
            tournamentKeys = tournaments.map { nameKey($0.officialName) }
            for team in try context.fetch(FetchDescriptor<Team>()) {
                let key = nameKey(team.name)
                if !key.isEmpty, teamsByKey[key] == nil { teamsByKey[key] = team }
                for alias in team.aliases {
                    let aliasKey = nameKey(alias)
                    if !aliasKey.isEmpty, teamsByAlias[aliasKey] == nil { teamsByAlias[aliasKey] = team }
                }
            }
            let players = try context.fetch(FetchDescriptor<Player>())
            var aliasEntries: [(String, Player)] = []
            for player in players {
                if let name = player.name {
                    let key = nameKey(name)
                    if !key.isEmpty {
                        let full = player.teamID.uuidString + "|" + key
                        if playersByKey[full] == nil { playersByKey[full] = player }
                    }
                }
                if let number = player.number { usedNumbers[player.teamID, default: []].insert(number) }
                for alias in player.aliases {
                    let key = nameKey(alias)
                    if !key.isEmpty { aliasEntries.append((player.teamID.uuidString + "|" + key, player)) }
                }
            }
            // 別名(旧姓・表記ゆれ)でも見つける。本名で一致する選手がいればそちらを優先する
            for (key, player) in aliasEntries where playersByKey[key] == nil { playersByKey[key] = player }
        }

        /// 名前が一致するチームを優先し、なければ別名で探す
        func team(key: String) -> Team? {
            key.isEmpty ? nil : (teamsByKey[key] ?? teamsByAlias[key])
        }

        /// チームの選手。名前が同じ既存選手は使い回し、いなければ作る(照合表は取り込み全体で共有)。
        mutating func player(team: Team, name: String, number: Int?, position: String?, context: ModelContext) -> Player {
            let key = team.id.uuidString + "|" + nameKey(name)
            if let existing = playersByKey[key] {
                if existing.position == nil, let position { existing.position = position }
                return existing
            }
            // 背番号は「事前登録の番号」。チーム内で空いているときだけ付ける(試合の番号はメンバー表に残る)
            let base = number.flatMap { usedNumbers[team.id, default: []].contains($0) ? nil : $0 }
            if let base { usedNumbers[team.id, default: []].insert(base) }
            let created = Player(teamID: team.id, number: base, name: name, position: position)
            context.insert(created)
            playersByKey[key] = created
            return created
        }
    }

    nonisolated private static func insert(_ draft: OfficialImportDraft, context: ModelContext, index: inout ImportIndex) throws -> Match {
        let tournamentName = draft.tournamentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let homeName = draft.homeTeamName.trimmingCharacters(in: .whitespacesAndNewlines)
        let awayName = draft.awayTeamName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !homeName.isEmpty, !awayName.isEmpty, nameKey(homeName) != nameKey(awayName) else {
            throw OfficialImportError.invalidTeams
        }

        let tournamentKey = nameKey(tournamentName.isEmpty ? "公式記録から取り込み" : tournamentName)
        // 「第N回」などで回が分かる名前は、年度が違っても同じ大会とみなす(年末年始をまたぐ大会のため)
        let found = index.tournaments.indices.first { i in
            index.tournamentKeys[i] == tournamentKey
                && (index.tournaments[i].year == draft.year || OfficialTournamentGrouping.hasEdition(index.tournaments[i].officialName))
        }.map { index.tournaments[$0] }
        let tournament = found ?? {
            let created = Tournament(officialName: tournamentName.isEmpty ? "公式記録から取り込み" : tournamentName, year: draft.year)
            context.insert(created)
            index.tournaments.append(created)
            index.tournamentKeys.append(tournamentKey)
            return created
        }()
        // シリーズ名は、まだ付いていない大会にだけ付ける(手で付け直した名前は上書きしない)
        if (tournament.seriesName ?? "").isEmpty, let series = draft.seriesName { tournament.seriesName = series }
        // カテゴリーと 7人制/15人制、男子/女子も、空いているときだけ大会名から付ける
        TournamentCategory.fillIfEmpty(tournament)
        TournamentCategory.fillGenderIfEmpty(tournament)

        func team(_ name: String) -> Team {
            let key = nameKey(name)
            if let existing = index.team(key: key) { return existing }
            let created = Team(name: name)
            context.insert(created)
            index.teamsByKey[key] = created
            return created
        }
        let sides = ["home": team(homeName), "away": team(awayName)]
        for side in sides.values where !tournament.teamIDs.contains(side.id) { tournament.teamIDs.append(side.id) }

        let match = Match(tournamentID: tournament.id, homeTeamID: sides["home"]!.id, awayTeamID: sides["away"]!.id,
                          playedAt: draft.playedAt)
        match.officialRecordID = draft.officialRecordID
        match.officialPageURL = draft.officialPageURL
        match.officialSheetURL = draft.officialSheetURL
        context.insert(match)

        func player(side: String, name: String, number: Int?, position: String?) -> Player {
            index.player(team: sides[side]!, name: name, number: number, position: position, context: context)
        }

        if draft.includesLineups {
            insertLineupsAndSubstitutions(draft, match: match, sides: sides, context: context, player: player)
        }

        for event in draft.events where event.isIncluded {
            var playerID: UUID?
            if !event.playerName.isEmpty && event.category != ScoringRules.penaltyTryCategory {
                let known = member(for: event, in: draft.members)
                playerID = player(side: event.side, name: known?.name ?? event.playerName,
                                  number: known?.number ?? event.playerNumber, position: known?.position).id
            }
            var details: Data?
            if let points = ScoringRules.validatedOfficialPoints(event.officialPoints, category: event.category),
               points != ScoringRules.points(category: event.category) {
                var value = RecordingEventDetails()
                value.officialPoints = points
                value.officialScoringCategory = event.category
                details = try JSONEncoder().encode(value)
            }
            context.insert(StatEvent(matchID: match.id, teamID: sides[event.side]!.id, playerID: playerID,
                                     category: event.category, outcome: event.outcome,
                                     seconds: max(0, event.minute) * 60, half: event.half, widgetData: details))
        }
        insertHalfMarkers(draft, match: match, context: context)
        return match
    }

    /// メンバー表(先発・リザーブ)と交代を入れる
    nonisolated private static func insertLineupsAndSubstitutions(_ draft: OfficialImportDraft, match: Match, sides: [String: Team],
                                                      context: ModelContext,
                                                      player: (String, String, Int?, String?) -> Player) {
        var order: [String: Int] = [:]
        for member in draft.members {
            let lineupPlayer = player(member.side, member.name, member.number, member.position)
            let role = member.isStarter ? "starter" : "reserve"
            let key = member.side + role
            context.insert(MatchLineup(matchID: match.id, teamID: sides[member.side]!.id, playerID: lineupPlayer.id,
                                       role: role, order: order[key, default: 0], number: member.number))
            order[key, default: 0] += 1
        }
        for item in draft.substitutions {
            let outgoing = player(item.side, item.outgoingName, item.outgoingNumber, nil)
            let incoming = player(item.side, item.incomingName, item.incomingNumber, nil)
            context.insert(Substitution(matchID: match.id, playerInID: incoming.id, playerOutID: outgoing.id,
                                        minute: item.minute, half: item.half))
        }
    }

    /// 前半の終わりと試合終了の印。記録画面と同じ形にしておくと、出場時間や得点経過の軸が試合の長さになる
    nonisolated private static func insertHalfMarkers(_ draft: OfficialImportDraft, match: Match, context: ModelContext) {
        let halves = draft.halfMinutes.count == 2 ? draft.halfMinutes : [40, 40]
        context.insert(StatEvent(matchID: match.id, category: "match_state", outcome: "half_finished",
                                 seconds: halves[0] * 60, half: 0))
        // 終わった試合として扱う(試合一覧で「終了」、タップでサマリーが開く)
        context.insert(StatEvent(matchID: match.id, category: "match_state", outcome: "finished",
                                 seconds: halves[1] * 60, half: 1))
    }
}

/// The actor owns every imported model. Only IDs, options and counts cross back
/// to the screen; archive decoding, draft creation and saving stay off MainActor.
actor OfficialBulkImportWorker {
    nonisolated static let batchSize = 80
    private nonisolated let executor = OfficialImportExecutor()
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private let container: ModelContainer
    private var session: OfficialRecordImporter.BulkSession?

    init(container: ModelContainer) { self.container = container }

    nonisolated static func make(container: ModelContainer) async -> OfficialBulkImportWorker {
        OfficialBulkImportWorker(container: container)
    }

    func saveBatch(archiveURL: URL, ids: [String], includesLineups: Bool) throws -> Int {
        try Task.checkCancellation()
        if session == nil { session = try OfficialRecordImporter.BulkSession(container: container) }
        let records = try OfficialRecordsStore.records(at: archiveURL, ids: ids)
        let drafts = records.map { record in
            var draft = OfficialRecordImporter.draft(from: record)
            draft.includesLineups = includesLineups && !draft.members.isEmpty
            return draft
        }
        try Task.checkCancellation()
        return try session!.saveBatch(drafts)
    }
}

/// A dedicated serial queue keeps context creation and every model access on
/// the same executor, including on OS versions whose default model executor
/// routes work back to the main queue. No ModelContext crosses this boundary.
nonisolated private final class OfficialImportExecutor: SerialExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "RugbyAS.official-import", qos: .userInitiated)

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }
}

// MARK: - 以前に取り込んだ試合の読み直し

extension OfficialRecordImporter {
    private nonisolated static let resyncKey = "officialImportResync.v1"

    /// 交代の取り込み・出典の保存より前に取り込んだ試合を、公式記録と照合し直す。起動時に1回だけ。
    /// 直すのは メンバー表(先発・リザーブ)・交代・前後半の長さの印・出典 だけで、得点の記録には触れない。
    /// 手で交代を入れた試合は、メンバー表と交代をそのままにする。記録画面で記録した試合は対象外。
    /// 公式記録のデータがない配布版(Release)では何もしない。
    /// 一度に照合し直す試合数。まとめすぎると保存前の変更が積み上がって重くなり、実機でメモリ不足になる
    /// (1,094試合を一度に処理して約1GB・7分かかり、強制終了された)。
    private static let resyncBatchSize = 50

    static func resyncImportedMatches(container: ModelContainer, archiveURL: URL?,
                                      defaults: UserDefaults = .standard) async {
        guard !defaults.bool(forKey: resyncKey), let archiveURL else { return }
        guard let candidateIDs = try? importedMatchIDsWithoutSource(context: ModelContext(container)) else { return }
        // 小分けにして、分けるたびに保存する。途中で止まっても、次の起動では残り(出典のまだない試合)から続く
        for start in stride(from: 0, to: candidateIDs.count, by: resyncBatchSize) {
            let ids = Array(candidateIDs[start..<min(start + resyncBatchSize, candidateIDs.count)])
            guard await resyncBatch(ids, container: container, archiveURL: archiveURL) else { return }
            await Task.yield()   // 画面の操作を止めないよう、区切りごとに順番を譲る
        }
        defaults.set(true, forKey: resyncKey)
    }

    /// 1回分を読み直して保存する。失敗したらこの回の変更は残さない(それまでの回の保存は残る)
    private static func resyncBatch(_ ids: [UUID], container: ModelContainer, archiveURL: URL) async -> Bool {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            let matches = try context.fetch(FetchDescriptor<Match>(predicate: #Predicate { ids.contains($0.id) }))
            let dates = Array(Set(matches.map { dayString($0.playedAt) }))
            // 公式記録の読み込みは画面を止めないよう裏で行い、保存だけこちらで行う
            let loading = Task.detached(priority: .utility) { try OfficialRecordsStore.records(at: archiveURL, dates: dates) }
            let recordsByDate = Dictionary(grouping: try await loading.value, by: \.date)
            // 試合ごとに探さず、この回の分をまとめて読んでおく(1試合ずつ探すと、保存前の変更が増えるほど遅く重くなる)
            let substitutions = Dictionary(grouping: try context.fetch(FetchDescriptor<Substitution>(
                predicate: #Predicate { ids.contains($0.matchID) })), by: \.matchID)
            let lineups = Dictionary(grouping: try context.fetch(FetchDescriptor<MatchLineup>(
                predicate: #Predicate { ids.contains($0.matchID) })), by: \.matchID)
            let states = Dictionary(grouping: try context.fetch(FetchDescriptor<StatEvent>(
                predicate: #Predicate { ids.contains($0.matchID) && $0.category == "match_state" })), by: \.matchID)
            let teams = Dictionary(try context.fetch(FetchDescriptor<Team>()).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var index = try ImportIndex(context: context)
            for match in matches {
                guard let home = teams[match.homeTeamID], let away = teams[match.awayTeamID],
                      let record = officialRecord(for: match, home: home, away: away,
                                                  among: recordsByDate[dayString(match.playedAt)] ?? []) else { continue }
                resync(match, with: record, sides: ["home": home, "away": away],
                       hasSubstitutions: !(substitutions[match.id] ?? []).isEmpty,
                       lineups: lineups[match.id] ?? [], states: states[match.id] ?? [],
                       context: context, index: &index)
            }
            try context.save()
            return true
        } catch {
            context.rollback()
            return false
        }
    }

    /// 出典がまだなく、取り込みの印(秒0の「試合終了」)がある試合。記録画面の試合は終了の秒が試合時間になる。
    /// 同じ日の試合が同じ回に入るよう日付順に並べる(公式記録を日付ごとに読むので、読み込みが減る)
    private static func importedMatchIDsWithoutSource(context: ModelContext) throws -> [UUID] {
        let matches = try context.fetch(FetchDescriptor<Match>(predicate: #Predicate { $0.officialRecordID == nil },
                                                               sortBy: [SortDescriptor(\.playedAt)]))
        guard !matches.isEmpty else { return [] }
        let finished = try context.fetch(FetchDescriptor<StatEvent>(predicate: #Predicate {
            $0.category == "match_state" && $0.outcome == "finished" && $0.seconds == 0
        }))
        let importedIDs = Set(finished.map(\.matchID))
        return matches.map(\.id).filter { importedIDs.contains($0) }
    }

    /// 同じ日・同じ組み合わせ(HOME/AWAYの向きも同じ)の公式記録。チームの別名(統合前の名前)でも探す。
    /// 同じ日に同じ組み合わせが2試合ある(7人制の予選と順位決定など)ときはキックオフ時刻で分け、分からなければ触らない。
    private static func officialRecord(for match: Match, home: Team, away: Team, among records: [OfficialRecord]) -> OfficialRecord? {
        func keys(_ team: Team) -> Set<String> { Set([nameKey(team.name)] + team.aliases.map(nameKey)) }
        let homeKeys = keys(home), awayKeys = keys(away)
        let sameTeams = records.filter {
            homeKeys.contains(nameKey($0.homeTeam)) && awayKeys.contains(nameKey($0.awayTeam)) && !$0.scoreEvents.isEmpty
        }
        guard sameTeams.count > 1 else { return sameTeams.first }
        let time = Calendar.current.dateComponents([.hour, .minute], from: match.playedAt)
        let sameKickoff = sameTeams.filter { record in
            let parts = record.kickoff.split(separator: ":").compactMap { Int($0.prefix(2)) }
            return parts.count == 2 && parts[0] == time.hour && parts[1] == time.minute
        }
        return sameKickoff.count == 1 ? sameKickoff[0] : nil
    }

    private static func resync(_ match: Match, with record: OfficialRecord, sides: [String: Team],
                               hasSubstitutions: Bool, lineups: [MatchLineup], states: [StatEvent],
                               context: ModelContext, index: inout ImportIndex) {
        let draft = draft(from: record)
        let id = match.id
        match.officialRecordID = draft.officialRecordID
        match.officialPageURL = draft.officialPageURL
        match.officialSheetURL = draft.officialSheetURL

        // メンバー表と交代。手で交代を入れた試合は、メンバー表も手で直している可能性があるので触らない
        if !hasSubstitutions && !draft.members.isEmpty {
            lineups.filter { $0.role == "starter" || $0.role == "reserve" }.forEach { context.delete($0) }
            insertLineupsAndSubstitutions(draft, match: match, sides: sides, context: context) { side, name, number, position in
                index.player(team: sides[side]!, name: name, number: number, position: position, context: context)
            }
        }

        // 前後半の長さの印(以前の取り込みは秒0の終了印だけだった)
        if !states.contains(where: { $0.outcome == "half_finished" }) {
            context.insert(StatEvent(matchID: id, category: "match_state", outcome: "half_finished",
                                     seconds: draft.halfMinutes[0] * 60, half: 0))
        }
        for marker in states where marker.outcome == "finished" && marker.seconds == 0 {
            marker.seconds = draft.halfMinutes[1] * 60
            marker.half = 1
        }
    }

    /// 公式記録の日付の書き方(yyyy-MM-dd)。取り込みは公式記録の日付とキックオフから試合日時を作っている
    private static func dayString(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

enum OfficialImportError: LocalizedError {
    case invalidTeams
    var errorDescription: String? {
        switch self {
        case .invalidTeams: return "HOMEとAWAYに、別々のチーム名を入れてください。"
        }
    }
}

// MARK: - 大会ごとのまとめ取り込み

/// 公式記録では1つの大会が「3回戦」「準決勝」「予選リーグ」など段階ごとに別の名前になっている。
/// 末尾の段階名を外した名前で束ね、アプリでは1つの大会として扱う。
struct OfficialTournamentGroup: Identifiable, Hashable {
    let name: String
    let year: Int           // 始まった年
    let years: [Int]        // 公式記録上の年(年末年始をまたぐと2つ)
    let stages: [String]
    let matchCount: Int
    let finishedCount: Int
    let firstDate: String
    let lastDate: String
    var id: String { "\(years)|\(name)" }
}

enum OfficialTournamentGrouping {
    // 末尾に付く段階の書き方(公式記録に実際に出てくるもの)。複数重なることもある。
    private nonisolated static let stagePattern = try! NSRegularExpression(pattern:
        "[\\s　]*(予選リーグ|決勝リーグ|決勝トーナメント|順位決定トーナメント|順位決定戦|プール戦|[0-9０-９]+回戦敗者戦|[0-9０-９]+位決定戦?|入替戦|エキシビション|[0-9０-９]+回戦|準々決勝|準決勝|決勝|[0-9０-９]+日目|[A-ZＡ-Ｚ]ブロック|[（(][^）)]*[）)])+[\\s　]*$")

    /// 段階名を外した大会名。外すと空になる名前はそのまま返す。
    nonisolated static func parentName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "・-－―"))
        // 「13位決定戦・準決勝」のように段階が「・」でつながることがあるので、変わらなくなるまで外す
        var parent = trimmed
        while true {
            let range = NSRange(parent.startIndex..., in: parent)
            let next = stagePattern.stringByReplacingMatches(in: parent, range: range, withTemplate: "")
                .trimmingCharacters(in: separators)
            if next == parent || next.isEmpty { break }
            parent = next
        }
        return parent.isEmpty ? trimmed : parent
    }

    /// 「〇〇シリーズ2026 第1戦熊谷大会」のような大会から、シリーズ名「〇〇シリーズ2026」を取り出す。
    /// チャレンジャートーナメントは出場チームが違うので別シリーズ(「〇〇シリーズ2026 チャレンジャートーナメント」)にする。
    /// シリーズの形でない名前は nil。
    nonisolated static func seriesName(for tournamentName: String) -> String? {
        // 公式記録に「セブンスシリーズ」「セブンズシリーズ」の表記ゆれがあるのでそろえる
        let name = parentName(tournamentName).replacingOccurrences(of: "セブンスシリーズ", with: "セブンズシリーズ")
        guard let range = name.range(of: "^.*?シリーズ[\\s　]*(19|20)[0-9]{2}", options: .regularExpression) else { return nil }
        let base = String(name[range]).trimmingCharacters(in: .whitespaces)
        let rest = name[range.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        return rest.hasPrefix("チャレンジャートーナメント") ? base + " チャレンジャートーナメント" : base
    }

    /// 段階の部分だけ(「準決勝」など)。一覧で試合の段階を見せるのに使う。
    nonisolated static func stageName(_ name: String) -> String {
        let parent = parentName(name)
        guard name.hasPrefix(parent) else { return "" }
        return String(name.dropFirst(parent.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 名前に「第N回」や西暦が入っていれば、その名前だけで大会の回が決まる。
    nonisolated static func hasEdition(_ name: String) -> Bool {
        name.range(of: "第[0-9０-９]+回|(19|20)[0-9]{2}", options: .regularExpression) != nil
    }

    /// 段階ごとの集計を、親の大会名で束ねる。新しい大会から並べる。
    /// 年末年始をまたぐ大会(例: 大学選手権は11月〜1月)は公式記録の「年」が2つに分かれるので、
    /// 回の分かる名前は名前だけで束ね、年度は始まった年にする。回の分からない名前(毎年同じ名前のリーグ等)は年ごとに分ける。
    static func groups(from stages: [OfficialTournamentStage]) -> [OfficialTournamentGroup] {
        let grouped = Dictionary(grouping: stages) { stage -> String in
            let parent = parentName(stage.tournament)
            return hasEdition(parent) ? parent : "\(stage.year)|\(parent)"
        }
        return grouped.values.compactMap { items -> OfficialTournamentGroup? in
            guard let first = items.first else { return nil }
            return OfficialTournamentGroup(
                name: parentName(first.tournament), year: items.map(\.year).min() ?? first.year,
                years: Array(Set(items.map(\.year))).sorted(),
                stages: items.map(\.tournament).sorted(),
                matchCount: items.reduce(0) { $0 + $1.matchCount },
                finishedCount: items.reduce(0) { $0 + $1.finishedCount },
                firstDate: items.map(\.firstDate).min() ?? "", lastDate: items.map(\.lastDate).max() ?? "")
        }.sorted { ($0.lastDate, $0.name) > ($1.lastDate, $1.name) }
    }
}

extension OfficialTournamentGrouping {
    private nonisolated static let backfillKey = "tournamentSeriesBackfill.v1"

    /// シリーズ機能より前に作った大会(例: 先に取り込んだ札幌大会の入替戦)にも、名前からシリーズ名を付ける。
    /// 起動時に1回だけ。シリーズ名がまだない大会だけが対象(手で付けた・外した名前を何度も上書きしないため)。
    @discardableResult
    nonisolated static func backfillSeriesNames(context: ModelContext, defaults: UserDefaults = .standard) -> Int {
        guard !defaults.bool(forKey: backfillKey) else { return 0 }
        guard let tournaments = try? context.fetch(FetchDescriptor<Tournament>()) else { return 0 }
        var filled = 0
        for tournament in tournaments where (tournament.seriesName ?? "").isEmpty {
            if let series = seriesName(for: tournament.officialName) {
                tournament.seriesName = series
                filled += 1
            }
        }
        if filled == 0 || (try? context.save()) != nil { defaults.set(true, forKey: backfillKey) }
        return filled
    }
}

// MARK: - 得点のない取り込み済みの試合に、試合ページの内訳から得点を入れる

extension OfficialRecordImporter {
    nonisolated static let breakdownFillKey = "officialImportBreakdownFill.v1"
    /// 一度に入れる試合数。保存前の変更を溜めすぎないよう小分けにする
    nonisolated private static let breakdownFillBatchSize = 200

    /// 公式記録票の公開が終わっていて得点なしで取り込まれた試合に、前後半の内訳から得点を入れる。起動時に1回だけ、裏で呼ぶ。
    /// 得点の記録が1件でもある試合(手で入れた試合を含む)には触らない。内訳が公式スコアと合わない試合も飛ばす。
    /// 返り値は得点を入れた試合数。
    @discardableResult
    nonisolated static func fillScoresFromBreakdown(container: ModelContainer, archiveURL: URL?,
                                                     defaults: UserDefaults = .standard) -> Int {
        guard !defaults.bool(forKey: breakdownFillKey), let archiveURL else { return 0 }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let candidates = try? matchesWithoutScores(context: context) else { return 0 }
        var filled = 0
        for start in stride(from: 0, to: candidates.count, by: breakdownFillBatchSize) {
            let batch = Array(candidates[start..<min(start + breakdownFillBatchSize, candidates.count)])
            do {
                let records = try OfficialRecordsStore.records(at: archiveURL, ids: batch.map(\.recordID))
                let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                for item in batch {
                    guard let record = byID[item.recordID], record.scoreEvents.isEmpty,
                          let events = breakdownEvents(record), !events.isEmpty else { continue }
                    for event in events {
                        var details: Data?
                        if let points = ScoringRules.validatedOfficialPoints(event.officialPoints, category: event.category),
                           points != ScoringRules.points(category: event.category) {
                            var value = RecordingEventDetails()
                            value.officialPoints = points
                            value.officialScoringCategory = event.category
                            details = try JSONEncoder().encode(value)
                        }
                        context.insert(StatEvent(matchID: item.matchID, teamID: event.side == "home" ? item.home : item.away,
                                                 category: event.category, outcome: event.outcome,
                                                 seconds: 0, half: event.half, widgetData: details))
                    }
                    filled += 1
                }
                try context.save()
            } catch {
                // 途中で失敗したら、この回の分は残さず終える(次の起動で、得点のない試合からやり直す)
                context.rollback()
                return filled
            }
        }
        defaults.set(true, forKey: breakdownFillKey)
        return filled
    }

    private nonisolated struct ScorelessMatch {
        let matchID: UUID
        let recordID: String
        let home: UUID
        let away: UUID
    }

    /// 出典(公式記録のID)があり、得点の記録が1件もない試合
    nonisolated private static func matchesWithoutScores(context: ModelContext) throws -> [ScorelessMatch] {
        var matchFetch = FetchDescriptor<Match>(predicate: #Predicate { $0.officialRecordID != nil })
        matchFetch.propertiesToFetch = [\.id, \.officialRecordID, \.homeTeamID, \.awayTeamID]
        let matches = try context.fetch(matchFetch)
        let scoring = ScoringRules.categories
        var eventFetch = FetchDescriptor<StatEvent>(predicate: #Predicate { scoring.contains($0.category) })
        eventFetch.propertiesToFetch = [\.matchID]
        let scored = Set(try context.fetch(eventFetch).map(\.matchID))
        return matches.compactMap { match in
            guard !scored.contains(match.id), let recordID = match.officialRecordID else { return nil }
            return ScorelessMatch(matchID: match.id, recordID: recordID, home: match.homeTeamID, away: match.awayTeamID)
        }
    }
}
