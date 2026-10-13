//
//  BackupManager.swift
//  Rugby AS
//
//  全記録のバックアップ(書き出し/読み込み)。
//  チーム・選手・大会・試合・記録・メンバー表と、選手写真/ロゴ、
//  試合時間設定、デフォルト自チーム名を1つのJSONファイルにまとめる。
//  動画ファイルはサイズが大きすぎるため含めない(再取り込みで復元する)。
//
//  読み込みは「合体」方式: 同じID
//  のデータは上書き、無いものは追加。削除は絶対にしない。
//  何度読み込んでも壊れない(機種変更・二重読み込みに安全)。
//

import Foundation
import SwiftData
import UniformTypeIdentifiers

// MARK: - バックアップファイルの中身(JSONの形)

nonisolated struct BackupFile: Codable, Sendable {
    var formatVersion: Int = 1
    var exportedAt: Date
    var defaultTeamName: String?
    // 試合時間設定(matchClockSettingsByMatchID)の保存内容をそのまま持つ
    var matchClockSettingsRaw: Data?
    // 全試合で使い回すマイテンプレート。追加前のバックアップでは欠落する。
    var recordingTemplatesRaw: Data? = nil
    var analysisReportsRaw: Data? = nil
    var videoAnchorsRaw: Data? = nil
    var videoNamesByMatch: [String: [String]]? = nil
    var teams: [BackupTeam]
    var players: [BackupPlayer]
    var tournaments: [BackupTournament]
    var matches: [BackupMatch]
    var statEvents: [BackupStatEvent]
    var matchLineups: [BackupMatchLineup]
    var substitutions: [BackupSubstitution]
}

nonisolated struct BackupTeam: Codable, Sendable {
    var id: UUID
    var name: String
    var colorHex: String?
    // フォルダ分けのカテゴリー。古いバックアップには無いので任意。
    var category: String?
    var logoImageBase64: String?
    // 別名(統合したチームの旧表記など)。古いバックアップには無いので任意。
    var aliases: [String]?
    // お気に入り。古いバックアップには無いので任意。
    var isFavorite: Bool?
}

nonisolated struct BackupPlayer: Codable, Sendable {
    var id: UUID
    var teamID: UUID
    // nil = 背番号なし(古いバックアップは必ず数値が入っている)
    var number: Int?
    var name: String?
    // 読み(かな)と英語表記。古いバックアップには無い項目なので nil 許容。
    var nameKana: String?
    var nameRoman: String?
    // プロフィール(生年月日・身長・体重)。同じく後付けの任意項目。
    var birthDate: Date?
    var heightCm: Int?
    var weightKg: Int?
    // ポジションとお気に入り。古いバックアップに無いので任意。
    var position: String?
    var isFavorite: Bool?
    var imageBase64: String?
    // 別名(旧姓・表記ゆれ)。古いバックアップには無いので任意。
    var aliases: [String]?
    // 同一人物の印(移籍・代表など別チームの同じ人)。古いバックアップには無いので任意。
    var personID: UUID?
}

nonisolated struct BackupTournament: Codable, Sendable {
    var id: UUID
    var officialName: String
    // 以下は後から足した任意項目。古いバックアップには無いので nil/欠落を許容。
    var year: Int?
    var variantRaw: String?
    var formatRaw: String?
    var teamIDs: [UUID]?
    var logoImageBase64: String?
    var seriesName: String?
    var category: String?
    // 男子/女子。古いバックアップには無いので任意。
    var genderRaw: String?
    // お気に入り。古いバックアップには無いので任意。
    var isFavorite: Bool?
}

nonisolated struct BackupMatch: Codable, Sendable {
    var id: UUID
    var tournamentID: UUID
    var homeTeamID: UUID
    var awayTeamID: UUID
    var playedAt: Date
    var recordingLayoutData: Data?
    var recordingSessionData: Data?
    // 後から追加(集計対象外)。古いバックアップには無いので任意(無ければ「含める」)
    var isExcludedFromStats: Bool?
    // 後から追加(公式記録の出典)。古いバックアップには無い
    var officialRecordID: String?
    var officialPageURL: String?
    var officialSheetURL: String?
}

nonisolated struct BackupStatEvent: Codable, Sendable {
    var id: UUID
    var matchID: UUID
    var teamID: UUID?
    var playerID: UUID?
    var category: String
    var outcome: String
    var seconds: Int
    var startSeconds: Int?
    var half: Int
    // 起点プレー。古いバックアップには無い項目なので nil 許容
    var origin: String?
    // タイムライン編集で付いた 0.1 秒きざみの位置と長さ。
    // これも後から足した項目なので、古いバックアップでは nil になる。
    var startSecondsExact: Double?
    var durationSecondsExact: Double?
    // カスタム録画ウィジェットの任意入力。古いバックアップには無いので nil 許容。
    var widgetData: Data?
}

nonisolated struct BackupMatchLineup: Codable, Sendable {
    var id: UUID
    var matchID: UUID
    var teamID: UUID
    var playerID: UUID
    var role: String
    var order: Int
    // 後から追加した列(試合ごとの背番号)。古いバックアップには無いので任意
    var number: Int?
}

nonisolated struct BackupSubstitution: Codable, Sendable {
    var id: UUID
    var matchID: UUID
    var playerInID: UUID
    var playerOutID: UUID
    var minute: Int
    // 後から追加した列。古いバックアップには無いので任意(nil=前半)
    var half: Int?
}

// 読み込み結果の件数(画面に表示する)
struct BackupRestoreSummary {
    var teams = 0
    var players = 0
    var tournaments = 0
    var matches = 0
    var statEvents = 0
    var matchLineups = 0
    var substitutions = 0

    var message: String {
        "チーム\(teams.formatted())件・選手\(players.formatted())件・大会\(tournaments.formatted())件・"
            + "試合\(matches.formatted())件・記録\(statEvents.formatted())件を読み込みました。"
    }
}

nonisolated enum BackupError: LocalizedError {
    case unsupportedVersion(Int)
    case unreadableFile
    case unreadableImage
    case unreadableTemplates

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "このバックアップ(形式\(version))は、より新しいバージョンのアプリで作られています。アプリを更新してから読み込んでください。"
        case .unreadableFile:
            return "バックアップファイルを読み取れませんでした。Rugby ASで書き出したファイルか確認してください。"
        case .unreadableImage:
            return "写真・ロゴを読み書きできませんでした。空き容量とバックアップファイルを確認してください。データの読み込みは取り消しました。"
        case .unreadableTemplates:
            return "マイテンプレートを読み込めませんでした。データの読み込みは取り消しました。"
        }
    }
}

// MARK: - 書き出し/読み込みの本体

enum BackupManager {
    fileprivate static let clockSettingsKey = "matchClockSettingsByMatchID"
    fileprivate static let defaultTeamNameKey = "defaultTeamName"
    fileprivate static let recordingTemplatesKey = "recording.savedBoardTemplates.v1"

    // 全データを集めてJSONにする
    static func makeBackupData(context: ModelContext, defaults: UserDefaults = .standard,
                               imageFiles: BackupImageFiles = BackupImageFiles()) throws -> Data {
        try encodeBackup(makeBackupFile(context: context, defaults: defaults, imageFiles: imageFiles))
    }

    /// バックアップを JSON にする。画面を止めないよう、裏の処理からも呼べる。
    nonisolated static func encodeBackup(_ backup: BackupFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(backup)
    }

    // 全データ(写真・ロゴを含む)を、バックアップファイルの形に集める
    static func makeBackupFile(context: ModelContext, defaults: UserDefaults = .standard,
                               imageFiles: BackupImageFiles = BackupImageFiles()) throws -> BackupFile {
        let teams = try context.fetch(FetchDescriptor<Team>())
        let players = try context.fetch(FetchDescriptor<Player>())
        let tournaments = try context.fetch(FetchDescriptor<Tournament>())
        let matches = try context.fetch(FetchDescriptor<Match>())
        let statEvents = try context.fetch(FetchDescriptor<StatEvent>())
        let lineups = try context.fetch(FetchDescriptor<MatchLineup>())
        let substitutions = try context.fetch(FetchDescriptor<Substitution>())

        return BackupFile(
            exportedAt: Date(),
            defaultTeamName: defaults.string(forKey: defaultTeamNameKey),
            matchClockSettingsRaw: defaults.data(forKey: clockSettingsKey),
            recordingTemplatesRaw: defaults.data(forKey: recordingTemplatesKey),
            analysisReportsRaw: defaults.data(forKey: AnalysisReport.storageKey),
            videoAnchorsRaw: defaults.data(forKey: "matchVideoAnchorsByMatchID"),
            videoNamesByMatch: videoMap(defaults: defaults),
            teams: try teams.map { team in
                BackupTeam(
                    id: team.id,
                    name: team.name,
                    colorHex: team.colorHex,
                    category: team.category,
                    logoImageBase64: try imageBase64(named: team.logoPath, imageFiles: imageFiles),
                    aliases: team.aliases.isEmpty ? nil : team.aliases,
                    isFavorite: team.isFavorite ? true : nil
                )
            },
            players: try players.map { player in
                BackupPlayer(
                    id: player.id,
                    teamID: player.teamID,
                    number: player.number,
                    name: player.name,
                    nameKana: player.nameKana,
                    nameRoman: player.nameRoman,
                    birthDate: player.birthDate,
                    heightCm: player.heightCm,
                    weightKg: player.weightKg,
                    position: player.position,
                    isFavorite: player.isFavorite,
                    imageBase64: try imageBase64(named: player.imagePath, imageFiles: imageFiles),
                    aliases: player.aliases.isEmpty ? nil : player.aliases,
                    personID: player.personID
                )
            },
            tournaments: try tournaments.map {
                BackupTournament(
                    id: $0.id,
                    officialName: $0.officialName,
                    year: $0.year,
                    variantRaw: $0.variantRaw,
                    formatRaw: $0.formatRaw,
                    teamIDs: $0.teamIDs,
                    logoImageBase64: try imageBase64(named: $0.logoPath, imageFiles: imageFiles),
                    seriesName: $0.seriesName,
                    category: $0.category,
                    genderRaw: $0.genderRaw,
                    isFavorite: $0.isFavorite ? true : nil
                )
            },
            matches: matches.map {
                BackupMatch(
                    id: $0.id,
                    tournamentID: $0.tournamentID,
                    homeTeamID: $0.homeTeamID,
                    awayTeamID: $0.awayTeamID,
                    playedAt: $0.playedAt,
                    recordingLayoutData: $0.recordingLayoutData,
                    recordingSessionData: $0.recordingSessionData,
                    isExcludedFromStats: $0.isExcludedFromStats,
                    officialRecordID: $0.officialRecordID,
                    officialPageURL: $0.officialPageURL,
                    officialSheetURL: $0.officialSheetURL
                )
            },
            statEvents: statEvents.map {
                BackupStatEvent(
                    id: $0.id,
                    matchID: $0.matchID,
                    teamID: $0.teamID,
                    playerID: $0.playerID,
                    category: $0.category,
                    outcome: $0.outcome,
                    seconds: $0.seconds,
                    startSeconds: $0.startSeconds,
                    half: $0.half,
                    origin: $0.origin,
                    startSecondsExact: $0.startSecondsExact,
                    durationSecondsExact: $0.durationSecondsExact,
                    widgetData: $0.widgetData
                )
            },
            matchLineups: lineups.map {
                BackupMatchLineup(
                    id: $0.id,
                    matchID: $0.matchID,
                    teamID: $0.teamID,
                    playerID: $0.playerID,
                    role: $0.role,
                    order: $0.order,
                    number: $0.number
                )
            },
            substitutions: substitutions.map {
                BackupSubstitution(
                    id: $0.id,
                    matchID: $0.matchID,
                    playerInID: $0.playerInID,
                    playerOutID: $0.playerOutID,
                    minute: $0.minute,
                    half: $0.half
                )
            }
        )
    }

    // バックアップJSONを一時ファイルに書き出して、その場所(URL)を返す。
    // 共有シートには「もう出来上がったファイル」を渡す形にする。
    // (Transferable の中で遅延生成すると、共有シート側の実行タイミングで
    //  不安定になり落ちることがあるため、タップ時に手前で作ってしまう)
    static func writeBackupFile(context: ModelContext) throws -> URL {
        let data = try makeBackupData(context: context)
        let url = backupFileURL()
        try data.write(to: url)
        return url
    }

    /// 画面に進み具合を出しながら書き出す。中身は writeBackupFile(context:) と同じ。
    /// データを集める段階だけは画面と同じ場所で行い、JSON への変換とファイルへの書き込みは裏で行う。
    static func writeBackupFileShowingProgress(context: ModelContext,
                                               progress: (BackupExportProgress) -> Void) async throws -> URL {
        progress(BackupExportProgress(stage: .collecting))
        await letScreenUpdate()
        let backup = try makeBackupFile(context: context)
        let counts = BackupRestoreProgress.Counts(backup)
        progress(BackupExportProgress(stage: .encoding, counts: counts))
        let data = try await Task.detached(priority: .userInitiated) { try encodeBackup(backup) }.value
        progress(BackupExportProgress(stage: .writing, counts: counts, fileBytes: data.count))
        let url = backupFileURL()
        try await Task.detached(priority: .userInitiated) { try data.write(to: url) }.value
        return url
    }

    private static func backupFileURL() -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        let fileName = "RugbyAS_backup_\(formatter.string(from: Date())).json"
        return FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
    }

    // JSONを読み込んで合体させる(同じIDは上書き・無いものは追加・削除しない)
    @discardableResult
    static func restore(from data: Data, context: ModelContext, defaults: UserDefaults = .standard,
                        imageFiles: BackupImageFiles = BackupImageFiles()) throws -> BackupRestoreSummary {
        let backup = try decodeBackup(data)
        let job = try BackupRestoreJob(backup: backup, context: context, defaults: defaults, imageFiles: imageFiles)
        do {
            for stage in BackupRestoreStage.applyingStages { try job.run(stage) }
            return try job.finish()
        } catch {
            job.rollback()
            throw error
        }
    }

    /// 画面に進み具合を出しながら読み込む。中身は restore(from:) と同じ。
    /// 重い段階の合間に少しだけ手を離し、画面(進み具合・経過時間)が止まって見えないようにする。
    /// ファイルの読み取りと JSON の解読は、画面を止めないよう裏で行う。
    @discardableResult
    static func restoreShowingProgress(from url: URL, context: ModelContext, defaults: UserDefaults = .standard,
                                       imageFiles: BackupImageFiles = BackupImageFiles(),
                                       progress: (BackupRestoreProgress) -> Void) async throws -> BackupRestoreSummary {
        progress(BackupRestoreProgress(stage: .reading))
        let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
        progress(BackupRestoreProgress(stage: .checking, fileBytes: data.count))
        let backup = try await Task.detached(priority: .userInitiated) { try decodeBackup(data) }.value
        let counts = BackupRestoreProgress.Counts(backup)

        // 合間に画面へ手を離すあいだ、自動保存で途中の状態が保存されないようにする(失敗時に取り消せるように)
        let autosave = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = autosave }

        let job = try BackupRestoreJob(backup: backup, context: context, defaults: defaults, imageFiles: imageFiles)
        do {
            for stage in BackupRestoreStage.applyingStages {
                let parts = job.parts(of: stage)
                let total = parts.reduce(0) { $0 + $1.count }
                var done = 0
                progress(BackupRestoreProgress(stage: stage, fileBytes: data.count, counts: counts, done: 0, total: total))
                await letScreenUpdate()
                // 件数が多い段階は小分けにして、合間に画面(件数・経過時間)を進める
                var lastUpdate = ContinuousClock.now
                for part in parts where part.count > 0 {
                    // 既存データの読み込みも、ページごとに画面を進める
                    var page = 0
                    while try part.loadPage(page) {
                        page += 1
                        if ContinuousClock.now - lastUpdate > .milliseconds(200) {
                            await letScreenUpdate(.milliseconds(16))
                            lastUpdate = .now
                        }
                    }
                    var start = 0
                    while start < part.count {
                        let end = min(part.count, start + BackupRestoreJob.batchSize)
                        try part.apply(start..<end)
                        done += end - start
                        start = end
                        if ContinuousClock.now - lastUpdate > .milliseconds(200) {
                            progress(BackupRestoreProgress(stage: stage, fileBytes: data.count, counts: counts,
                                                           done: done, total: total))
                            await letScreenUpdate(.milliseconds(16))
                            lastUpdate = .now
                        }
                    }
                }
            }
            progress(BackupRestoreProgress(stage: .saving, fileBytes: data.count, counts: counts))
            await letScreenUpdate()
            return try job.finish()
        } catch {
            job.rollback()
            throw error
        }
    }

    /// 画面が1コマ描き直せるだけ、ほんの少し待つ
    private static func letScreenUpdate(_ duration: Duration = .milliseconds(40)) async {
        try? await Task.sleep(for: duration)
    }

    /// バックアップの JSON を解読する。画面を止めないよう、裏の処理からも呼べる。
    nonisolated static func decodeBackup(_ data: Data) throws -> BackupFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let backup = try? decoder.decode(BackupFile.self, from: data) else {
            throw BackupError.unreadableFile
        }
        guard backup.formatVersion <= 1 else {
            throw BackupError.unsupportedVersion(backup.formatVersion)
        }
        return backup
    }

    // MARK: - 画像の変換

    fileprivate static func videoMap(defaults: UserDefaults) -> [String: [String]] {
        (defaults.dictionary(forKey: "matchVideoFileNamesByMatchID") ?? [:]).compactMapValues {
            if let names = $0 as? [String] { return names }
            if let name = $0 as? String { return [name] }
            return nil
        }
    }

    fileprivate static func mergedVideoNames(current: [String: [String]], incoming: [String: [String]]?) throws -> [String: [String]] {
        guard let incoming else { return current }
        var result = current
        for (id, names) in incoming {
            guard UUID(uuidString: id) != nil, names.allSatisfy(VideoStorage.isSafeFileName) else { throw BackupError.unreadableFile }
            var seen = Set<String>()
            result[id] = (names + (current[id] ?? [])).filter { seen.insert($0).inserted }
        }
        return result
    }

    fileprivate static func mergedVideoAnchors(current: Data?, incoming: Data?) throws -> Data? {
        guard let incoming else { return current }
        let decoder = JSONDecoder()
        var result = try current.map { try decoder.decode([String: [String: MatchVideoAnchor]].self, from: $0) } ?? [:]
        let imported = try decoder.decode([String: [String: MatchVideoAnchor]].self, from: incoming)
        for (id, anchors) in imported {
            guard UUID(uuidString: id) != nil else { throw BackupError.unreadableFile }
            for (half, anchor) in anchors {
                guard ["0", "1"].contains(half), anchor.seconds.isFinite, anchor.seconds >= 0,
                      VideoStorage.isSafeFileName(anchor.fileName) else { throw BackupError.unreadableFile }
            }
            result[id] = (result[id] ?? [:]).merging(anchors) { _, imported in imported }
        }
        return try JSONEncoder().encode(result)
    }

    private static func imageBase64(named name: String?, imageFiles: BackupImageFiles) throws -> String? {
        guard let name else { return nil }
        return try imageFiles.read(named: name).base64EncodedString()
    }

    fileprivate static func mergedTemplatesRaw(current: Data?, backup: Data?) throws -> Data? {
        guard let backup else { return current }
        do {
            let decoder = JSONDecoder()
            var templates = try current.flatMap { $0.isEmpty ? nil : try decoder.decode([RecordingLayout].self, from: $0) } ?? []
            let incoming = backup.isEmpty ? [] : try decoder.decode([RecordingLayout].self, from: backup)
            for template in incoming {
                let validated = try template.validated()
                templates.removeAll { $0.name == validated.name }
                templates.append(validated)
            }
            // 合体で20件を超えても、既存テンプレートを切り捨てない。
            return try JSONEncoder().encode(templates)
        } catch {
            throw BackupError.unreadableTemplates
        }
    }

    // 試合時間設定(試合IDごとの辞書)を、中身の型を知らずに合体させる
    fileprivate static func mergedClockSettingsRaw(current: Data?, backup: Data?) -> Data? {
        guard let backup else { return current }
        guard let current else { return backup }
        guard let currentDict = (try? JSONSerialization.jsonObject(with: current)) as? [String: Any],
              let backupDict = (try? JSONSerialization.jsonObject(with: backup)) as? [String: Any] else {
            return backup
        }
        let merged = currentDict.merging(backupDict) { _, backupValue in backupValue }
        return try? JSONSerialization.data(withJSONObject: merged)
    }
}

// MARK: - 読み込みの段階

/// id で引けるモデル(読み込みで、同じIDの既存データを探すのに使う)
protocol Identified { var id: UUID { get } }
extension Team: Identified {}
extension Player: Identified {}
extension Tournament: Identified {}
extension Match: Identified {}
extension StatEvent: Identified {}
extension MatchLineup: Identified {}
extension Substitution: Identified {}

/// 読み込みの段階。画面の進み具合の表示にも使う。
enum BackupRestoreStage: Int, CaseIterable, Comparable {
    case reading, checking, images, teamsAndPlayers, tournamentsAndMatches, records, saving

    /// データベースに反映する段階(この順に進める)
    static let applyingStages: [BackupRestoreStage] = [.images, .teamsAndPlayers, .tournamentsAndMatches, .records]

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// 進み具合。今の段階と、ファイルの大きさ・件数(分かった時点から)を持つ。
struct BackupRestoreProgress: Equatable {
    struct Counts: Equatable {
        var teams = 0, players = 0, images = 0, tournaments = 0, matches = 0, records = 0, lineups = 0

        init() {}
        init(_ backup: BackupFile) {
            teams = backup.teams.count
            players = backup.players.count
            images = backup.teams.filter { $0.logoImageBase64 != nil }.count
                + backup.players.filter { $0.imageBase64 != nil }.count
                + backup.tournaments.filter { $0.logoImageBase64 != nil }.count
            tournaments = backup.tournaments.count
            matches = backup.matches.count
            records = backup.statEvents.count
            lineups = backup.matchLineups.count + backup.substitutions.count
        }
    }

    var stage: BackupRestoreStage
    var fileBytes: Int? = nil
    var counts: Counts? = nil
    /// 今の段階で反映し終えた件数と、その段階の全件数
    var done: Int? = nil
    var total: Int? = nil
}

/// 書き出しの段階
enum BackupExportStage: Int, CaseIterable, Comparable {
    case collecting, encoding, writing

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct BackupExportProgress: Equatable {
    var stage: BackupExportStage
    var counts: BackupRestoreProgress.Counts? = nil
    var fileBytes: Int? = nil
}

/// 1回の読み込みで使う途中の状態。段階ごとに run を呼び、最後に finish で保存する。
/// 途中で失敗したら rollback で、読み込む前の状態と書き出した画像を元に戻す。
fileprivate final class BackupRestoreJob {
    let backup: BackupFile
    let context: ModelContext
    let defaults: UserDefaults
    let imageFiles: BackupImageFiles
    let mergedTemplates: Data?
    let mergedReports: Data?
    let mergedAnchors: Data?
    let mergedVideos: [String: [String]]

    var newImages: [String] = []
    var replacedImages = Set<String>()
    var restoreVisibleValues: [() -> Void] = []
    var didSave = false
    var summary = BackupRestoreSummary()
    var teamImages: [String?] = []
    var playerImages: [String?] = []
    var tournamentImages: [String?] = []

    private var clockSettingsKey: String { BackupManager.clockSettingsKey }
    private var defaultTeamNameKey: String { BackupManager.defaultTeamNameKey }
    private var recordingTemplatesKey: String { BackupManager.recordingTemplatesKey }

    init(backup: BackupFile, context: ModelContext, defaults: UserDefaults, imageFiles: BackupImageFiles) throws {
        self.backup = backup
        self.context = context
        self.defaults = defaults
        self.imageFiles = imageFiles
        // 外部設定は、内容を先に検証し、データベースの保存成功後にだけ書き換える。
        mergedTemplates = try BackupManager.mergedTemplatesRaw(
            current: defaults.data(forKey: BackupManager.recordingTemplatesKey), backup: backup.recordingTemplatesRaw)
        mergedReports = try AnalysisReport.merged(current: defaults.data(forKey: AnalysisReport.storageKey), incoming: backup.analysisReportsRaw)
        mergedAnchors = try BackupManager.mergedVideoAnchors(current: defaults.data(forKey: "matchVideoAnchorsByMatchID"), incoming: backup.videoAnchorsRaw)
        mergedVideos = try BackupManager.mergedVideoNames(current: BackupManager.videoMap(defaults: defaults), incoming: backup.videoNamesByMatch)

        // この画面を開く前の編集を、復元失敗時の rollback に巻き込まない。
        if context.hasChanges { try context.save() }
    }

    /// 1つの段階を、件数と「この範囲を反映する」処理の組に分けたもの。
    /// 画面に進み具合を出すときは、範囲を小分けにして呼ぶ。
    struct Part {
        let count: Int
        /// 既存データを1ページ読む(まだ続きがあれば true)
        let loadPage: (Int) throws -> Bool
        let apply: (Range<Int>) throws -> Void
    }

    func parts(of stage: BackupRestoreStage) -> [Part] {
        switch stage {
        case .images: [Part(count: 1, loadPage: { _ in false }) { _ in try self.images() }]
        case .teamsAndPlayers: [part(backup.teams.count, Team.self, apply: teams),
                                part(backup.players.count, Player.self, apply: players)]
        case .tournamentsAndMatches: [part(backup.tournaments.count, Tournament.self, apply: tournaments),
                                      part(backup.matches.count, Match.self, apply: matches)]
        case .records: [part(backup.statEvents.count, StatEvent.self, apply: statEvents),
                        part(backup.matchLineups.count, MatchLineup.self, apply: lineups),
                        part(backup.substitutions.count, Substitution.self, apply: substitutions)]
        case .reading, .checking, .saving: []
        }
    }

    private func part<Model: PersistentModel & Identified>(_ count: Int, _ type: Model.Type,
                                                          apply: @escaping (Range<Int>) throws -> Void) -> Part {
        Part(count: count, loadPage: { page in try self.loadExisting(type, page: page) }, apply: apply)
    }

    /// 1回に反映する件数
    static let batchSize = 2_000
    /// 既存データを1回に読む件数(全件を一度に読むと、記録が多いときに長く止まるため分ける)
    static let pageSize = 20_000

    func run(_ stage: BackupRestoreStage) throws {
        for part in parts(of: stage) where part.count > 0 {
            var page = 0
            while try part.loadPage(page) { page += 1 }
            for start in stride(from: 0, to: part.count, by: Self.batchSize) {
                try part.apply(start..<min(part.count, start + Self.batchSize))
            }
        }
    }

    // 同じIDの既存データを引く表(種類ごと)。反映を始める前に、ページに分けて読み込んでおく
    private var tables: [ObjectIdentifier: Any] = [:]

    func loadExisting<Model: PersistentModel & Identified>(_ type: Model.Type, page: Int) throws -> Bool {
        var descriptor = FetchDescriptor<Model>()
        descriptor.fetchOffset = page * Self.pageSize
        descriptor.fetchLimit = Self.pageSize
        let models = try context.fetch(descriptor)
        // 取り出してから足す(表を写さずに済むように)
        var table = (tables.removeValue(forKey: ObjectIdentifier(type)) as? [UUID: Model]) ?? [:]
        for model in models where table[model.id] == nil { table[model.id] = model }
        tables[ObjectIdentifier(type)] = table
        return models.count == Self.pageSize
    }

    private func existing<Model: PersistentModel>(_ type: Model.Type) -> [UUID: Model] {
        tables[ObjectIdentifier(type)] as? [UUID: Model] ?? [:]
    }

    /// 途中で失敗したときに、読み込む前の状態へ戻す(保存は済んでいないので、データベースは元のまま)
    func rollback() {
        guard !didSave else { return }
        context.rollback()
        // SwiftData の rollback で永続データは戻っても、画面が保持する
        // モデル参照には直前の値が残ることがある。元値も明示的に戻し、
        // その代入を未保存の編集として残さない。ここでは保存し直さない。
        for restoreValues in restoreVisibleValues.reversed() { restoreValues() }
        context.processPendingChanges()
        context.rollback()
        for name in newImages { imageFiles.delete(named: name) }
    }

    private func restoreImage(_ base64: String?) throws -> String? {
        guard let base64 else { return nil }
        guard let bytes = Data(base64Encoded: base64) else { throw BackupError.unreadableImage }
        let name = try imageFiles.save(bytes)
        newImages.append(name)
        return name
    }

    // 画像の破損・書き込み失敗は、既存モデルに触る前にすべて検出する。
    func images() throws {
        teamImages = try backup.teams.map { try restoreImage($0.logoImageBase64) }
        playerImages = try backup.players.map { try restoreImage($0.imageBase64) }
        tournamentImages = try backup.tournaments.map { try restoreImage($0.logoImageBase64) }
    }

    // チーム
    func teams(_ range: Range<Int>) throws {
        let existingTeams = existing(Team.self)
        for index in range {
            let item = backup.teams[index]
            let logoPath = teamImages[index]
            if let existing = existingTeams[item.id] {
                let original = (existing.name, existing.colorHex, existing.category, existing.logoPath, existing.aliases)
                let originalFavorite = existing.isFavorite
                restoreVisibleValues.append {
                    (existing.name, existing.colorHex, existing.category, existing.logoPath, existing.aliases) = original
                    existing.isFavorite = originalFavorite
                }
                existing.name = item.name
                existing.colorHex = item.colorHex ?? existing.colorHex
                existing.category = item.category ?? existing.category
                // お気に入りは、どちらかで付けていれば残す(手元で付けた印を消さない)
                existing.isFavorite = existing.isFavorite || (item.isFavorite ?? false)
                // 別名は足し合わせる(手元で付けた別名を消さない)
                for alias in item.aliases ?? [] where !existing.aliases.contains(alias) && alias != existing.name {
                    existing.aliases.append(alias)
                }
                if let logoPath {
                    if let oldPath = existing.logoPath { replacedImages.insert(oldPath) }
                    existing.logoPath = logoPath
                }
            } else {
                context.insert(Team(id: item.id, name: item.name, logoPath: logoPath, colorHex: item.colorHex, category: item.category,
                                    aliases: item.aliases ?? [], isFavorite: item.isFavorite ?? false))
            }
            summary.teams += 1
        }
    }

    // 選手
    func players(_ range: Range<Int>) throws {
        let existingPlayers = existing(Player.self)
        for index in range {
            let item = backup.players[index]
            let imagePath = playerImages[index]
            if let existing = existingPlayers[item.id] {
                let original = (existing.teamID, existing.number, existing.name, existing.nameKana,
                    existing.nameRoman, existing.birthDate, existing.heightCm, existing.weightKg,
                    existing.position, existing.isFavorite, existing.imagePath, existing.aliases)
                restoreVisibleValues.append {
                    (existing.teamID, existing.number, existing.name, existing.nameKana,
                     existing.nameRoman, existing.birthDate, existing.heightCm, existing.weightKg,
                     existing.position, existing.isFavorite, existing.imagePath, existing.aliases) = original
                }
                let originalPersonID = existing.personID
                restoreVisibleValues.append { existing.personID = originalPersonID }
                existing.personID = item.personID ?? existing.personID
                existing.teamID = item.teamID
                existing.number = item.number ?? existing.number
                existing.name = item.name ?? existing.name
                existing.nameKana = item.nameKana ?? existing.nameKana
                existing.nameRoman = item.nameRoman ?? existing.nameRoman
                existing.birthDate = item.birthDate ?? existing.birthDate
                existing.heightCm = item.heightCm ?? existing.heightCm
                existing.weightKg = item.weightKg ?? existing.weightKg
                existing.position = item.position ?? existing.position
                existing.isFavorite = item.isFavorite ?? existing.isFavorite
                // 別名は足し合わせる(手元で付けた別名を消さない)
                for alias in item.aliases ?? [] where !existing.aliases.contains(alias) && alias != existing.name {
                    existing.aliases.append(alias)
                }
                if let imagePath {
                    if let oldPath = existing.imagePath { replacedImages.insert(oldPath) }
                    existing.imagePath = imagePath
                }
            } else {
                context.insert(Player(
                    id: item.id,
                    teamID: item.teamID,
                    number: item.number,
                    name: item.name,
                    nameKana: item.nameKana,
                    nameRoman: item.nameRoman,
                    imagePath: imagePath,
                    position: item.position,
                    isFavorite: item.isFavorite ?? false,
                    birthDate: item.birthDate,
                    heightCm: item.heightCm,
                    weightKg: item.weightKg,
                    aliases: item.aliases ?? [],
                    personID: item.personID
                ))
            }
            summary.players += 1
        }
    }

    // 大会
    func tournaments(_ range: Range<Int>) throws {
        let existingTournaments = existing(Tournament.self)
        for index in range {
            let item = backup.tournaments[index]
            let logoPath = tournamentImages[index]
            if let existing = existingTournaments[item.id] {
                let original = (existing.officialName, existing.year, existing.variantRaw,
                    existing.formatRaw, existing.teamIDs, existing.logoPath)
                let originalSeries = existing.seriesName
                let originalCategory = existing.category
                let originalGender = existing.genderRaw
                let originalFavorite = existing.isFavorite
                restoreVisibleValues.append {
                    (existing.officialName, existing.year, existing.variantRaw,
                     existing.formatRaw, existing.teamIDs, existing.logoPath) = original
                    existing.seriesName = originalSeries
                    existing.category = originalCategory
                    existing.genderRaw = originalGender
                    existing.isFavorite = originalFavorite
                }
                existing.officialName = item.officialName
                existing.year = item.year ?? existing.year
                existing.variantRaw = item.variantRaw ?? existing.variantRaw
                existing.formatRaw = item.formatRaw ?? existing.formatRaw
                existing.teamIDs = item.teamIDs ?? existing.teamIDs
                existing.seriesName = item.seriesName ?? existing.seriesName
                existing.category = item.category ?? existing.category
                existing.genderRaw = item.genderRaw ?? existing.genderRaw
                // お気に入りは、どちらかで付けていれば残す(手元で付けた印を消さない)
                existing.isFavorite = existing.isFavorite || (item.isFavorite ?? false)
                if let logoPath {
                    if let oldPath = existing.logoPath { replacedImages.insert(oldPath) }
                    existing.logoPath = logoPath
                }
            } else {
                context.insert(Tournament(
                    id: item.id,
                    officialName: item.officialName,
                    year: item.year,
                    logoPath: logoPath,
                    variantRaw: item.variantRaw,
                    formatRaw: item.formatRaw,
                    teamIDs: item.teamIDs ?? [],
                    seriesName: item.seriesName,
                    category: item.category,
                    genderRaw: item.genderRaw,
                    isFavorite: item.isFavorite ?? false
                ))
            }
            summary.tournaments += 1
        }
    }

    // 試合
    func matches(_ range: Range<Int>) throws {
        let existingMatches = existing(Match.self)
        for item in backup.matches[range] {
            if let existing = existingMatches[item.id] {
                let original = (existing.tournamentID, existing.homeTeamID, existing.awayTeamID,
                    existing.playedAt, existing.recordingLayoutData, existing.recordingSessionData)
                let originalExcluded = existing.isExcludedFromStats
                let originalOfficial = (existing.officialRecordID, existing.officialPageURL, existing.officialSheetURL)
                restoreVisibleValues.append {
                    (existing.tournamentID, existing.homeTeamID, existing.awayTeamID,
                     existing.playedAt, existing.recordingLayoutData, existing.recordingSessionData) = original
                    existing.isExcludedFromStats = originalExcluded
                    (existing.officialRecordID, existing.officialPageURL, existing.officialSheetURL) = originalOfficial
                }
                existing.tournamentID = item.tournamentID
                existing.homeTeamID = item.homeTeamID
                existing.awayTeamID = item.awayTeamID
                existing.playedAt = item.playedAt
                existing.recordingLayoutData = item.recordingLayoutData ?? existing.recordingLayoutData
                existing.recordingSessionData = item.recordingSessionData ?? existing.recordingSessionData
                existing.isExcludedFromStats = item.isExcludedFromStats ?? existing.isExcludedFromStats
                existing.officialRecordID = item.officialRecordID ?? existing.officialRecordID
                existing.officialPageURL = item.officialPageURL ?? existing.officialPageURL
                existing.officialSheetURL = item.officialSheetURL ?? existing.officialSheetURL
            } else {
                let restored = Match(
                    id: item.id,
                    tournamentID: item.tournamentID,
                    homeTeamID: item.homeTeamID,
                    awayTeamID: item.awayTeamID,
                    playedAt: item.playedAt,
                    recordingLayoutData: item.recordingLayoutData,
                    recordingSessionData: item.recordingSessionData,
                    isExcludedFromStats: item.isExcludedFromStats ?? false
                )
                restored.officialRecordID = item.officialRecordID
                restored.officialPageURL = item.officialPageURL
                restored.officialSheetURL = item.officialSheetURL
                context.insert(restored)
            }
            summary.matches += 1
        }
    }

    // 記録(スタッツ)
    func statEvents(_ range: Range<Int>) throws {
        let existingEvents = existing(StatEvent.self)
        for item in backup.statEvents[range] {
            if let existing = existingEvents[item.id] {
                let original = (existing.matchID, existing.teamID, existing.playerID, existing.category,
                    existing.outcome, existing.seconds, existing.startSeconds, existing.half,
                    existing.origin, existing.startSecondsExact, existing.durationSecondsExact, existing.widgetData)
                restoreVisibleValues.append {
                    (existing.matchID, existing.teamID, existing.playerID, existing.category,
                     existing.outcome, existing.seconds, existing.startSeconds, existing.half,
                     existing.origin, existing.startSecondsExact, existing.durationSecondsExact, existing.widgetData) = original
                }
                existing.matchID = item.matchID
                existing.teamID = item.teamID
                existing.playerID = item.playerID
                existing.category = item.category
                existing.outcome = item.outcome
                existing.seconds = item.seconds
                existing.startSeconds = item.startSeconds ?? existing.startSeconds
                existing.half = item.half
                existing.origin = item.origin ?? existing.origin
                existing.startSecondsExact = item.startSecondsExact ?? existing.startSecondsExact
                existing.durationSecondsExact = item.durationSecondsExact ?? existing.durationSecondsExact
                existing.widgetData = item.widgetData ?? existing.widgetData
            } else {
                context.insert(StatEvent(
                    id: item.id,
                    matchID: item.matchID,
                    teamID: item.teamID,
                    playerID: item.playerID,
                    category: item.category,
                    outcome: item.outcome,
                    seconds: item.seconds,
                    startSeconds: item.startSeconds,
                    half: item.half,
                    origin: item.origin,
                    startSecondsExact: item.startSecondsExact,
                    durationSecondsExact: item.durationSecondsExact,
                    widgetData: item.widgetData
                ))
            }
            summary.statEvents += 1
        }
    }

    // メンバー表
    func lineups(_ range: Range<Int>) throws {
        let existingLineups = existing(MatchLineup.self)
        for item in backup.matchLineups[range] {
            if let existing = existingLineups[item.id] {
                let original = (existing.matchID, existing.teamID, existing.playerID,
                    existing.role, existing.order, existing.number)
                restoreVisibleValues.append {
                    (existing.matchID, existing.teamID, existing.playerID,
                     existing.role, existing.order, existing.number) = original
                }
                existing.matchID = item.matchID
                existing.teamID = item.teamID
                existing.playerID = item.playerID
                existing.role = item.role
                existing.order = item.order
                existing.number = item.number ?? existing.number
            } else {
                context.insert(MatchLineup(
                    id: item.id,
                    matchID: item.matchID,
                    teamID: item.teamID,
                    playerID: item.playerID,
                    role: item.role,
                    order: item.order,
                    number: item.number
                ))
            }
            summary.matchLineups += 1
        }
    }

    // 交代(V2用の器。あれば持ち込む)
    func substitutions(_ range: Range<Int>) throws {
        let existingSubstitutions = existing(Substitution.self)
        for item in backup.substitutions[range] {
            if let existing = existingSubstitutions[item.id] {
                let original = (existing.matchID, existing.playerInID, existing.playerOutID, existing.minute, existing.half)
                restoreVisibleValues.append {
                    (existing.matchID, existing.playerInID, existing.playerOutID, existing.minute, existing.half) = original
                }
                existing.matchID = item.matchID
                existing.playerInID = item.playerInID
                existing.playerOutID = item.playerOutID
                existing.minute = item.minute
                existing.half = item.half ?? existing.half
            } else {
                context.insert(Substitution(
                    id: item.id,
                    matchID: item.matchID,
                    playerInID: item.playerInID,
                    playerOutID: item.playerOutID,
                    minute: item.minute,
                    half: item.half ?? 0
                ))
            }
            summary.substitutions += 1
        }
    }

    // 保存して、外部設定を書き換える
    func finish() throws -> BackupRestoreSummary {
        // 別のレコードも同じ画像を参照している場合には残す。
        let referencedImages = Set(
            try context.fetch(FetchDescriptor<Team>()).compactMap(\.logoPath)
                + context.fetch(FetchDescriptor<Player>(predicate: #Predicate { $0.imagePath != nil })).compactMap(\.imagePath)
                + context.fetch(FetchDescriptor<Tournament>()).compactMap(\.logoPath))
        try context.save()
        didSave = true
        for name in replacedImages.subtracting(referencedImages) { imageFiles.delete(named: name) }

        if let mergedTemplates { defaults.set(mergedTemplates, forKey: recordingTemplatesKey) }
        if let mergedReports { defaults.set(mergedReports, forKey: AnalysisReport.storageKey) }
        if let mergedAnchors { defaults.set(mergedAnchors, forKey: "matchVideoAnchorsByMatchID") }
        defaults.set(mergedVideos, forKey: "matchVideoFileNamesByMatchID")

        // 試合時間設定は「今の端末の内容+バックアップの内容」を合体(バックアップ優先)
        if let merged = BackupManager.mergedClockSettingsRaw(
            current: defaults.data(forKey: clockSettingsKey),
            backup: backup.matchClockSettingsRaw
        ) {
            defaults.set(merged, forKey: clockSettingsKey)
        }

        // デフォルト自チーム名は、端末側が未設定のときだけ持ち込む
        if let name = backup.defaultTeamName, !name.isEmpty,
           (defaults.string(forKey: defaultTeamNameKey) ?? "").isEmpty {
            defaults.set(name, forKey: defaultTeamNameKey)
        }

        return summary
    }
}
