//
//  TournamentCategory.swift
//  Rugby AS
//
//  大会のカテゴリー(トップ・大学・高校など)。チームではなく大会に持たせる
//  (同じチームがトップの大会と大学の大会の両方に出ることがあるため)。
//  自由入力で、よく使う名前は候補として出す。7人制/15人制は Tournament.variantRaw(RugbyVariant)。
//
//  公式記録の大会名から、分かるものだけカテゴリーと人数を自動で付ける
//  (取り込み時と、起動時に1回だけ既存の大会へ)。手で付けた値は上書きしない。
//

import Foundation
import SwiftData

enum TournamentCategory {
    /// 候補として並べる名前(この順でチーム一覧のフォルダも並べる)
    nonisolated static let suggestions = ["トップ", "大学", "高校", "高専", "中学", "クラブ", "代表"]

    /// 表示の並び順(候補にない名前は候補のあと、名前順)
    nonisolated static func sortKey(_ name: String) -> (Int, String) {
        (suggestions.firstIndex(of: name) ?? suggestions.count, name)
    }

    /// 大会名からカテゴリーを推測する。分からなければ nil。
    nonisolated static func inferred(from name: String) -> String? {
        let text = name.folding(options: [.widthInsensitive, .caseInsensitive], locale: Locale(identifier: "ja_JP"))
        func has(_ words: String...) -> Bool { words.contains { text.contains($0.lowercased()) } }
        // 「都道府県代表女子」(中学)などがあるので、代表より先に年代を見る
        if has("中学", "ジュニア・ラグビー", "ジュニアラグビー") { return "中学" }
        if has("高等専門学校", "高専") { return "高専" }
        if has("高等学校", "高校", "花園", "u18", "u17") { return "高校" }
        if has("大学", "college", "学生") { return "大学" }
        if has("日本代表", "japan xv", "代表戦", "テストマッチ", "ワールドカップ", "wxv", "u20", "ジュニアワールド", "ネーションズ",
               "svns", "sevens series", "fast four") {
            return "代表"
        }
        if has("リーグワン", "league one", "トップリーグ", "トップチャレンジ", "top league", "ウィメンズセブンズシリーズ", "ウィメンズセブンスシリーズ", "全国女子ラグビーフットボール選手権") {
            return "トップ"
        }
        if has("クラブラグビー", "クラブ大会", "全国クラブ") { return "クラブ" }
        return nil
    }

    /// 大会名から 7人制/15人制 を推測する。はっきりしないもの(12人制など)は nil。
    nonisolated static func inferredVariant(from name: String) -> RugbyVariant? {
        let text = name.folding(options: [.widthInsensitive, .caseInsensitive], locale: Locale(identifier: "ja_JP"))
        func has(_ words: String...) -> Bool { words.contains { text.contains($0.lowercased()) } }
        if has("セブンズ", "セブンス", "7人制", "sevens", "svns", "fast four") { return .sevens }
        if has("12人制", "10人制") { return nil }
        if has("15人制", "リーグワン", "トップリーグ", "トップチャレンジ", "全国大学ラグビーフットボール選手権", "全国高等学校ラグビーフットボール大会",
               "全国高等学校選抜", "高等専門学校", "地区対抗大学", "全国女子ラグビーフットボール選手権",
               "日本代表", "japan xv", "wxv", "ワールドカップ", "ネーションズ", "ジュニアワールド") {
            return .fifteens
        }
        return nil
    }

    /// 大会名から男子/女子を推測する。はっきりしないもの(男女どちらの語もない大会など)は nil。
    nonisolated static func inferredGender(from name: String) -> RugbyGender? {
        let text = name.folding(options: [.widthInsensitive, .caseInsensitive], locale: Locale(identifier: "ja_JP"))
        func has(_ words: String...) -> Bool { words.contains { text.contains($0.lowercased()) } }
        let women = has("女子", "ウィメンズ", "ウィメンス", "women", "レディース", "ladies", "サクラセブンズ", "サクラフィフティーン", "wxv")
        let men = has("男子")
        if women && men { return nil }   // 男女両方の大会
        if women { return .women }
        if men { return .men }
        // 女子の大会は名前に「女子」などが入るので、次の大会は男子とみなす
        if has("リーグワン", "league one", "トップリーグ", "トップチャレンジ", "全国大学ラグビーフットボール選手権", "大学選手権", "対抗戦",
               "全国高等学校ラグビーフットボール大会", "花園", "全国高等学校選抜", "高等専門学校", "地区対抗大学",
               "日本代表", "japan xv", "代表戦", "テストマッチ", "ネーションズ", "ワールドカップ", "ジュニアワールド") {
            return .men
        }
        return nil
    }

    /// 空いているときだけ、名前から推測したカテゴリーと人数を付ける。付けたら true。
    @discardableResult
    nonisolated static func fillIfEmpty(_ tournament: Tournament) -> Bool {
        var changed = false
        if (tournament.category ?? "").isEmpty, let category = inferred(from: tournament.officialName) {
            tournament.category = category
            changed = true
        }
        if tournament.variantRaw == nil, let variant = inferredVariant(from: tournament.officialName) {
            tournament.variantRaw = variant.rawValue
            changed = true
        }
        return changed
    }

    /// 男子/女子が空いているときだけ、名前から推測して付ける。付けたら true。
    /// (カテゴリー・人数の補完とは別の回数で数えるため、別の関数にしている)
    @discardableResult
    nonisolated static func fillGenderIfEmpty(_ tournament: Tournament) -> Bool {
        guard tournament.genderRaw == nil, let gender = inferredGender(from: tournament.officialName) else { return false }
        tournament.genderRaw = gender.rawValue
        return true
    }

    private nonisolated static let backfillKey = "tournamentCategoryBackfill.v1"

    /// カテゴリー機能より前に作った大会にも、名前から分かるカテゴリーと人数を付ける。起動時に1回だけ。
    @discardableResult
    nonisolated static func backfill(context: ModelContext, defaults: UserDefaults = .standard) -> Int {
        guard !defaults.bool(forKey: backfillKey) else { return 0 }
        guard let tournaments = try? context.fetch(FetchDescriptor<Tournament>()) else { return 0 }
        let filled = tournaments.filter { fillIfEmpty($0) }.count
        if filled == 0 || (try? context.save()) != nil { defaults.set(true, forKey: backfillKey) }
        return filled
    }

    private nonisolated static let genderBackfillKey = "tournamentGenderBackfill.v1"

    /// 男子/女子の項目より前に作った大会にも、名前から分かる男女を付ける。起動時に1回だけ。
    /// カテゴリーと人数には触らない(消したカテゴリーをもう一度付け直さないため)。
    @discardableResult
    nonisolated static func backfillGender(context: ModelContext, defaults: UserDefaults = .standard) -> Int {
        guard !defaults.bool(forKey: genderBackfillKey) else { return 0 }
        guard let tournaments = try? context.fetch(FetchDescriptor<Tournament>()) else { return 0 }
        let filled = tournaments.filter { fillGenderIfEmpty($0) }.count
        if filled == 0 || (try? context.save()) != nil { defaults.set(true, forKey: genderBackfillKey) }
        return filled
    }

    /// 画面に出す「女子・大学・7人制」のような区分名。どれもなければ nil。
    nonisolated static func label(category: String?, variantRaw: String?, genderRaw: String? = nil) -> String? {
        let parts = [RugbyGender.displayName(for: genderRaw), category?.trimmingCharacters(in: .whitespacesAndNewlines),
                     RugbyVariant.displayName(for: variantRaw)]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "・")
    }
}

/// 「男子/女子」「カテゴリー」「7人制/15人制」の絞り込み条件。どれも大会の設定を見る。
nonisolated struct CompetitionFilter: Codable, Equatable, Sendable {
    /// nil = すべて。"" はカテゴリー未設定の大会
    var category: String?
    /// nil = すべて。RugbyVariant の rawValue
    var variantRaw: String?
    /// nil = すべて。RugbyGender の rawValue。後から足した項目なので、保存済みの分析では nil
    var genderRaw: String?

    var isActive: Bool { category != nil || variantRaw != nil || genderRaw != nil }

    /// この大会の試合が条件に合うか
    func matches(_ tournament: Tournament?) -> Bool {
        matches(category: tournament?.category, variantRaw: tournament?.variantRaw, genderRaw: tournament?.genderRaw)
    }

    func matches(category tournamentCategory: String?, variantRaw tournamentVariant: String?, genderRaw tournamentGender: String?) -> Bool {
        if let category {
            let value = (tournamentCategory ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard value == category else { return false }
        }
        if let variantRaw, tournamentVariant != variantRaw { return false }
        if let genderRaw, tournamentGender != genderRaw { return false }
        return true
    }

    /// 絞り込み中の内容(例: 「女子・大学・7人制」)
    var label: String? {
        guard isActive else { return nil }
        let categoryText = category.map { $0.isEmpty ? "カテゴリー未設定" : $0 }
        return [RugbyGender.displayName(for: genderRaw), categoryText, RugbyVariant.displayName(for: variantRaw)]
            .compactMap { $0 }.joined(separator: "・")
    }
}
