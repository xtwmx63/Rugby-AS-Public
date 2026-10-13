import Foundation
import CoreGraphics
import ImageIO
import SwiftData

@MainActor
enum BackupRegressionChecks {
    private enum Failure: Error { case failed(String) }
    private static let templateKey = "recording.savedBoardTemplates.v1"
    // 標準エンコーダで作る透明な1px PNG。元バイトと拡張子の保持を確認する。
    private static let png: Data = {
        let bitmap = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmap.clear(CGRect(x: 0, y: 0, width: 1, height: 1))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, bitmap.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination), "PNG fixture must encode")
        return data as Data
    }()

    private struct Fixture {
        let container: ModelContainer
        let defaults: UserDefaults
        let suite: String
        let images: BackupImageFiles
        var context: ModelContext { container.mainContext }

        func cleanup() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: images.directory)
        }
    }

    private static func fixture() throws -> Fixture {
        let container = try ModelContainer(for: Team.self, Player.self, Tournament.self, Match.self,
            StatEvent.self, MatchLineup.self, Substitution.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let suite = "rugby-as-backup-checks." + UUID().uuidString
        let images = BackupImageFiles(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true))
        return Fixture(container: container, defaults: UserDefaults(suiteName: suite)!, suite: suite, images: images)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.failed(message) }
    }

    private static func encoded(_ backup: BackupFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(backup)
    }

    private static func backup(in fixture: Fixture) throws -> BackupFile {
        let data = try BackupManager.makeBackupData(context: fixture.context,
            defaults: fixture.defaults, imageFiles: fixture.images)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackupFile.self, from: data)
    }

    private static func restore(_ backup: BackupFile, into fixture: Fixture) throws {
        try BackupManager.restore(from: encoded(backup), context: fixture.context,
            defaults: fixture.defaults, imageFiles: fixture.images)
    }

    static func run() throws {
        try roundTripsBoardAndRecordDetails()
        try mergesTemplatesWithoutDiscardingExistingOnes()
        try oldBackupsPreserveNewerDetails()
        try preservesPNGBytesThroughRepeatedRestore()
        try failedRestoreRollsBackAndKeepsExistingImages()
        try saveFailureRestoresVisibleAndStoredData()
        try replacesOnlyUnreferencedImages()
        try exportRefusesToOmitMissingImages()
        try preservesVideoReferencesAndSavedReports()
        try invalidVideoMetadataDoesNotMutateData()
        try mediaRecoveryStagesAndNeverOverwrites()
        try roundTripsHistoricalScore()
        print("PASS: 12 backup regression checks")
    }

    /// 進み具合を出しながら読み込む版(設定画面で使う)が、通常の読み込みと同じ結果になることを確かめる
    static func runProgressRestore() async throws {
        try await progressRestoreMatchesPlainRestore()
        try await progressRestoreRollsBackOnFailure()
        print("PASS: 2 progress restore checks")
    }

    private static func progressRestoreMatchesPlainRestore() async throws {
        let source = try fixture(), plain = try fixture(), staged = try fixture()
        defer { source.cleanup(); plain.cleanup(); staged.cleanup() }
        let team = Team(name: "進み具合FC")
        source.context.insert(team)
        // 小分けの単位(2,000件)をまたぐ件数にして、途中で区切っても同じになることを見る
        for index in 0..<2_345 {
            source.context.insert(Player(teamID: team.id, number: index % 99, name: "選手\(index)",
                                         heightCm: 170 + index % 20))
        }
        let match = Match(tournamentID: UUID(), homeTeamID: team.id, awayTeamID: UUID(), playedAt: .now)
        source.context.insert(match)
        for second in 0..<30 {
            source.context.insert(StatEvent(matchID: match.id, teamID: team.id, category: "try", outcome: "success", seconds: second))
        }
        try source.context.save()
        let data = try encoded(backup(in: source))
        let url = source.images.directory.appendingPathComponent("progress.json")
        try FileManager.default.createDirectory(at: source.images.directory, withIntermediateDirectories: true)
        try data.write(to: url)

        try BackupManager.restore(from: data, context: plain.context, defaults: plain.defaults, imageFiles: plain.images)
        staged.context.autosaveEnabled = true
        var reports: [BackupRestoreProgress] = []
        let summary = try await BackupManager.restoreShowingProgress(
            from: url, context: staged.context, defaults: staged.defaults, imageFiles: staged.images) { reports.append($0) }

        func snapshot(_ context: ModelContext) throws -> [String] {
            try context.fetch(FetchDescriptor<Player>()).map { "\($0.id)|\($0.name ?? "")|\($0.number ?? -1)|\($0.heightCm ?? 0)" }.sorted()
        }
        let stagedPlayers = try snapshot(staged.context), plainPlayers = try snapshot(plain.context)
        let stagedEvents = try staged.context.fetchCount(FetchDescriptor<StatEvent>())
        try expect(stagedPlayers == plainPlayers, "Staged restore stores the same players as the plain restore")
        try expect(stagedEvents == 30, "Staged restore stores every record")
        try expect(summary.players == 2_345 && summary.statEvents == 30, "Staged restore reports the same counts")
        let stages = reports.map(\.stage)
        try expect(stages == stages.sorted() && stages.first == .reading && stages.last == .saving,
                   "Progress moves forward from reading to saving")
        let playerReports = reports.filter { $0.stage == .teamsAndPlayers }
        try expect(playerReports.first?.total == 2_346 && playerReports.allSatisfy { ($0.done ?? 0) <= 2_346 },
                   "Team and player progress counts toward the stage total")
        try expect(staged.context.autosaveEnabled, "Autosave is switched back on after the staged restore")
        try expect(!staged.context.hasChanges, "Nothing is left unsaved after the staged restore")
    }

    private static func progressRestoreRollsBackOnFailure() async throws {
        let target = try fixture()
        defer { target.cleanup() }
        let existing = Team(name: "元からいるチーム")
        target.context.insert(existing)
        try target.context.save()
        var broken = BackupFile(exportedAt: .now, teams: [BackupTeam(id: existing.id, name: "書き換わってはいけない")],
                                players: [], tournaments: [], matches: [], statEvents: [], matchLineups: [], substitutions: [])
        broken.players = [BackupPlayer(id: UUID(), teamID: existing.id, number: 1, imageBase64: "これは画像ではない")]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try encoded(broken).write(to: url)
        do {
            _ = try await BackupManager.restoreShowingProgress(from: url, context: target.context,
                                                               defaults: target.defaults, imageFiles: target.images) { _ in }
            throw Failure.failed("A broken image was accepted")
        } catch BackupError.unreadableImage {}
        let teamNames = try target.context.fetch(FetchDescriptor<Team>()).map(\.name)
        let playerCount = try target.context.fetchCount(FetchDescriptor<Player>())
        try expect(teamNames == ["元からいるチーム"], "A failed staged restore leaves existing data untouched")
        try expect(playerCount == 0, "A failed staged restore adds nothing")
    }

    private static func roundTripsHistoricalScore() throws {
        let source = try fixture(), destination = try fixture()
        defer { source.cleanup(); destination.cleanup() }
        let team = Team(name: "Australia（男子15人制）")
        let tournament = Tournament(officialName: "男子ラグビーワールドカップ1991", year: 1991)
        let match = Match(tournamentID: tournament.id, homeTeamID: team.id, awayTeamID: UUID(), playedAt: .now)
        var value = RecordingEventDetails()
        value.officialPoints = 4
        value.officialScoringCategory = "try"
        let event = StatEvent(matchID: match.id, teamID: team.id, category: "try", outcome: "success", seconds: 1800,
                              widgetData: try JSONEncoder().encode(value))
        source.context.insert(team); source.context.insert(tournament); source.context.insert(match); source.context.insert(event)
        try source.context.save()
        try restore(backup(in: source), into: destination)
        let restored = try destination.context.fetch(FetchDescriptor<StatEvent>()).first!
        try expect(ScoringRules.points(category: restored.category, widgetData: restored.widgetData) == 4,
                   "Historical World Cup points survive backup and restore")
        try expect(restored.recordingDetails.officialScoringCategory == "try", "The stored point value remains tied to its scoring category")
    }

    private static func mediaRecoveryStagesAndNeverOverwrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.mov"), destination = root.appendingPathComponent("restored")
        let original = Data(repeating: 37, count: 5 * 1024 * 1024 + 17)
        try original.write(to: source)
        try VideoStorage.recover(from: source, as: "original.mov", destinationDirectory: destination)
        let actual = try Data(contentsOf: destination.appendingPathComponent("original.mov"))
        try expect(actual == original, "Chunked copy preserves all bytes and restores the original name")
        try Data([1, 2, 3]).write(to: source)
        do { try VideoStorage.recover(from: source, as: "original.mov", destinationDirectory: destination); throw Failure.failed("Existing media overwritten") }
        catch is VideoStorageError { }
        let unchanged = try Data(contentsOf: destination.appendingPathComponent("original.mov"))
        try expect(unchanged == original, "An existing recording is never replaced")
        let files = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        try expect(files == ["original.mov"], "No staged copy is left behind")
    }

    private static func preservesVideoReferencesAndSavedReports() throws {
        let source = try fixture(), target = try fixture()
        defer { source.cleanup(); target.cleanup() }
        let id = UUID().uuidString
        let namesKey = "matchVideoFileNamesByMatchID", anchorsKey = "matchVideoAnchorsByMatchID"
        let youtube = "youtube-AbC_12-xyZ9"
        source.defaults.set([id: ["first.mov", "second.mov", youtube]], forKey: namesKey)
        let anchors = [id: ["0": MatchVideoAnchor(fileName: "first.mov", seconds: 12.5),
                            "1": MatchVideoAnchor(fileName: youtube, seconds: 7200.5)]]
        source.defaults.set(try JSONEncoder().encode(anchors), forKey: anchorsKey)
        var report = AnalysisReport(name: "移行する分析", categories: ["try", "tackle"])
        report.scope.filter.zoneRow = 0
        source.defaults.set(try JSONEncoder().encode([report]), forKey: AnalysisReport.storageKey)
        target.defaults.set([id: ["local.mov"]], forKey: namesKey)
        try restore(backup(in: source), into: target)
        try expect((target.defaults.dictionary(forKey: namesKey)?[id] as? [String]) == ["first.mov", "second.mov", youtube, "local.mov"], "Imported local and YouTube video order is retained without deleting existing references")
        let restored = try JSONDecoder().decode([String: [String: MatchVideoAnchor]].self, from: target.defaults.data(forKey: anchorsKey)!)
        try expect(restored == anchors, "Exact kickoff offsets and file references survive")
        let reports = try JSONDecoder().decode([AnalysisReport].self, from: target.defaults.data(forKey: AnalysisReport.storageKey)!)
        try expect(reports == [report], "Report order and filter survive transfer")
        var old = try backup(in: source); old.videoNamesByMatch = nil; old.videoAnchorsRaw = nil; old.analysisReportsRaw = nil
        try restore(old, into: target)
        try expect(target.defaults.data(forKey: anchorsKey) != nil && target.defaults.data(forKey: AnalysisReport.storageKey) != nil, "Older backups preserve newer external settings")
    }

    private static func invalidVideoMetadataDoesNotMutateData() throws {
        let current = try fixture(); defer { current.cleanup() }
        var incoming = try backup(in: current)
        incoming.videoNamesByMatch = [UUID().uuidString: ["../outside.mov"]]
        incoming.teams = [BackupTeam(id: UUID(), name: "未保存", colorHex: nil, category: nil, logoImageBase64: nil)]
        do { try restore(incoming, into: current); throw Failure.failed("Invalid media path accepted") }
        catch is BackupError { }
        let teams = try current.context.fetch(FetchDescriptor<Team>())
        try expect(teams.isEmpty && current.defaults.dictionary(forKey: "matchVideoFileNamesByMatchID") == nil, "Validation happens before any record or setting changes")
        try expect(!VideoStorage.isSafeFileName("../a.mov") && !VideoStorage.isSafeFileName("/a.mov") && VideoStorage.isSafeFileName("元動画.mov"), "Video names stay inside the app media directory")
        let preserved = VideoStorage.preservingMissingNames(edited: ["second.mov"], stored: ["first.mov", "second.mov"], exists: { $0 == "second.mov" })
        try expect(preserved == ["first.mov", "second.mov"], "Timeline saves do not discard missing video slots or promote second video to first")
    }

    private static func roundTripsBoardAndRecordDetails() throws {
        let source = try fixture(), destination = try fixture()
        defer { source.cleanup(); destination.cleanup() }
        let team = Team(name: "ホーム")
        let player = Player(teamID: team.id, number: 10, name: "選手", position: "SO", isFavorite: true)
        let tournament = Tournament(officialName: "大会", year: 2026)
        var layout = RecordingLayout.legacyRecordingTemplate
        layout.name = "距離と成功率"
        layout.widgets[0].appearance = RecordingWidgetAppearance(style: .outline, corner: .square,
            showIcon: false, customColorHex: "#123ABC")
        let layoutData = try JSONEncoder().encode(layout)
        let sessionData = try JSONEncoder().encode(RecordingSession(clock: RecordingClock(accumulated: 123)))
        let match = Match(tournamentID: tournament.id, homeTeamID: team.id, awayTeamID: UUID(), playedAt: .now,
            recordingLayoutData: layoutData, recordingSessionData: sessionData)
        let details = Data(#"{"number":-12.5,"unit":"m","choice":"左","zone":2,"note":"確認"}"#.utf8)
        let event = StatEvent(matchID: match.id, teamID: team.id, playerID: player.id, category: "carry_metres",
            outcome: "success", seconds: 80, startSeconds: 75, half: 1, origin: "scrum",
            startSecondsExact: 75.25, durationSecondsExact: 5.75, widgetData: details)
        source.context.insert(team); source.context.insert(player); source.context.insert(tournament)
        source.context.insert(match); source.context.insert(event)
        source.defaults.set(try JSONEncoder().encode([layout]), forKey: templateKey)
        try source.context.save()
        try restore(backup(in: source), into: destination)
        let restoredMatch = try destination.context.fetch(FetchDescriptor<Match>()).first!
        let restoredEvent = try destination.context.fetch(FetchDescriptor<StatEvent>()).first!
        try expect(restoredMatch.recordingLayoutData == layoutData && restoredMatch.recordingSessionData == sessionData,
                   "Backup preserves layout appearance and match clock")
        try expect(restoredEvent.widgetData == details && restoredEvent.startSecondsExact == 75.25
            && restoredEvent.durationSecondsExact == 5.75 && restoredEvent.origin == "scrum" && restoredEvent.half == 1,
                   "Backup preserves numeric units, choices, zones, notes and precise event positions")
        let restoredTemplates = try JSONDecoder().decode([RecordingLayout].self,
            from: destination.defaults.data(forKey: templateKey)!)
        try expect(restoredTemplates == [layout], "Saved templates travel with the backup")
    }

    private static func mergesTemplatesWithoutDiscardingExistingOnes() throws {
        let current = try fixture()
        defer { current.cleanup() }
        var originals = (0..<20).map { RecordingLayout(name: "既存\($0)", widgets: []) }
        current.defaults.set(try JSONEncoder().encode(originals), forKey: templateKey)
        var incoming = try backup(in: current)
        var replacement = RecordingLayout.legacyRecordingTemplate
        replacement.name = originals[0].name
        incoming.recordingTemplatesRaw = try JSONEncoder().encode([replacement, RecordingLayout(name: "追加", widgets: [])])
        try restore(incoming, into: current)
        try restore(incoming, into: current)
        let merged = try JSONDecoder().decode([RecordingLayout].self, from: current.defaults.data(forKey: templateKey)!)
        try expect(merged.count == 21 && Set(merged.map(\.name)).count == 21,
                   "Merging and repeated import never drops existing templates or adds duplicate names")
        try expect(merged.first { $0.name == replacement.name } == replacement,
                   "A matching name receives the restored template")
        originals.removeFirst()
        try expect(originals.allSatisfy { merged.contains($0) }, "Other local templates survive")
        incoming.recordingTemplatesRaw = nil
        try restore(incoming, into: current)
        let afterOldBackup = try JSONDecoder().decode([RecordingLayout].self, from: current.defaults.data(forKey: templateKey)!)
        try expect(afterOldBackup == merged, "Older backup without templates leaves current templates untouched")
    }

    private static func oldBackupsPreserveNewerDetails() throws {
        let current = try fixture()
        defer { current.cleanup() }
        let match = Match(tournamentID: UUID(), homeTeamID: UUID(), awayTeamID: UUID(), playedAt: .now,
            recordingLayoutData: Data([1]), recordingSessionData: Data([2]))
        let player = Player(teamID: match.homeTeamID, number: 8, nameKana: "なまえ", position: "NO.8", isFavorite: true)
        let event = StatEvent(matchID: match.id, category: "carry_metres", outcome: "success", seconds: 30,
            origin: "lineout", startSecondsExact: 30.5, durationSecondsExact: 1.5, widgetData: Data([3]))
        current.context.insert(match); current.context.insert(player); current.context.insert(event)
        try current.context.save()
        var old = try backup(in: current)
        old.matches[0].recordingLayoutData = nil; old.matches[0].recordingSessionData = nil
        old.statEvents[0].widgetData = nil; old.statEvents[0].origin = nil
        old.statEvents[0].startSecondsExact = nil; old.statEvents[0].durationSecondsExact = nil
        old.players[0].nameKana = nil; old.players[0].position = nil; old.players[0].isFavorite = nil
        old.statEvents[0].seconds = 31
        try restore(old, into: current)
        try expect(match.recordingLayoutData == Data([1]) && match.recordingSessionData == Data([2])
            && event.widgetData == Data([3]), "Missing older custom fields do not erase current layout/session/input")
        try expect(event.origin == "lineout" && event.startSecondsExact == 30.5 && event.durationSecondsExact == 1.5,
                   "Missing newer event fields remain intact")
        try expect(player.nameKana == "なまえ" && player.position == "NO.8" && player.isFavorite,
                   "Missing newer player details remain intact")
        try expect(event.seconds == 31, "Fields present in the backup still update existing records")
    }

    private static func preservesPNGBytesThroughRepeatedRestore() throws {
        let current = try fixture()
        defer { current.cleanup() }
        let name = try current.images.save(png)
        let player = Player(teamID: UUID(), number: 1, imagePath: name)
        current.context.insert(player)
        try current.context.save()
        let exported = try backup(in: current)
        try restore(exported, into: current)
        try restore(backup(in: current), into: current)
        try expect(player.imagePath!.hasSuffix(".png"), "Restored transparent images keep the PNG extension")
        let bytes = try current.images.read(named: player.imagePath!)
        try expect(bytes == png, "Repeated backup/restore preserves every PNG byte without JPEG recompression")
    }

    private static func failedRestoreRollsBackAndKeepsExistingImages() throws {
        let current = try fixture()
        defer { current.cleanup() }
        let oldImage = try current.images.save(png)
        let team = Team(name: "元の名前", logoPath: oldImage)
        current.context.insert(team)
        try current.context.save()
        var incoming = try backup(in: current)
        incoming.teams[0].name = "変更後"
        incoming.players.append(BackupPlayer(id: UUID(), teamID: team.id, number: 1))
        incoming.defaultTeamName = "変更後"
        incoming.recordingTemplatesRaw = try JSONEncoder().encode([RecordingLayout(name: "読み込み", widgets: [])])
        // Base64の破損だけでなく、PNGの先頭だけ正常な画像も実際の復号で拒否する。
        for corruptImage in ["not base64", Data(png.prefix(16)).base64EncodedString()] {
            incoming.players[0].imageBase64 = corruptImage
            var failed = false
            do { try restore(incoming, into: current) } catch { failed = true }
            try expect(failed, "Unreadable or truncated imported image aborts restore")
            let verificationContext = ModelContext(current.container)
            let persisted = try verificationContext.fetch(FetchDescriptor<Team>()).first!
            try expect(persisted.name == "元の名前" && persisted.logoPath == oldImage,
                       "Failure preserves stored data: name=\(persisted.name), image=\(persisted.logoPath ?? "nil")")
            try expect(team.name == "元の名前" && team.logoPath == oldImage,
                       "Failure restores visible data: name=\(team.name), image=\(team.logoPath ?? "nil")")
            try expect(!current.context.hasChanges, "Failure leaves no pending database edits")
            let files = try FileManager.default.contentsOfDirectory(atPath: current.images.directory.path)
            try expect(files == [oldImage], "Failure retains the old image and cleans newly restored files")
            try expect(current.defaults.data(forKey: templateKey) == nil
                && current.defaults.string(forKey: "defaultTeamName") == nil, "Failure never changes external settings")
        }
    }

    private static func replacesOnlyUnreferencedImages() throws {
        let current = try fixture()
        defer { current.cleanup() }
        let oldImage = try current.images.save(png)
        let team = Team(name: "ホーム", logoPath: oldImage)
        let player = Player(teamID: team.id, number: 1, imagePath: oldImage)
        current.context.insert(team); current.context.insert(player)
        try current.context.save()
        var incoming = try backup(in: current)
        incoming.players = []
        try restore(incoming, into: current)
        try expect(FileManager.default.fileExists(atPath: current.images.directory.appendingPathComponent(oldImage).path),
                   "A replaced image remains while another record references it")
        incoming = try backup(in: current)
        try restore(incoming, into: current)
        try expect(!FileManager.default.fileExists(atPath: current.images.directory.appendingPathComponent(oldImage).path),
                   "The old image is deleted only after successful replacement of its last reference")
    }

    private static func saveFailureRestoresVisibleAndStoredData() throws {
        let temporary = try fixture()
        defer { temporary.cleanup() }
        let oldImage = try temporary.images.save(png)
        let schema = Schema([Team.self, Player.self, Tournament.self, Match.self,
                             StatEvent.self, MatchLineup.self, Substitution.self])
        let databaseURL = temporary.images.directory.appendingPathComponent("read-only.store")
        do {
            let seed = try ModelContainer(for: schema,
                configurations: ModelConfiguration(url: databaseURL, cloudKitDatabase: .none))
            seed.mainContext.insert(Team(name: "保存済み", logoPath: oldImage))
            try seed.mainContext.save()
        }
        // 実際に保存を拒否するストアを開く。テスト用の疑似エラーには置き換えない。
        let readOnly = try ModelContainer(for: schema, configurations:
            ModelConfiguration(url: databaseURL, allowsSave: false, cloudKitDatabase: .none))
        readOnly.mainContext.autosaveEnabled = false
        let current = Fixture(container: readOnly, defaults: temporary.defaults,
                              suite: temporary.suite, images: temporary.images)
        let visibleTeam = try current.context.fetch(FetchDescriptor<Team>()).first!
        var incoming = try backup(in: current)
        incoming.teams[0].name = "保存に失敗する変更"
        let originalFiles = Set(try FileManager.default.contentsOfDirectory(atPath: current.images.directory.path)
            .filter { $0.hasSuffix(".png") || $0.hasSuffix(".jpg") })
        var failed = false
        do { try restore(incoming, into: current) } catch { failed = true }
        try expect(failed, "A read-only store must reject saving the restore")
        let persisted = try ModelContext(readOnly).fetch(FetchDescriptor<Team>()).first!
        try expect(persisted.name == "保存済み" && persisted.logoPath == oldImage,
                   "Save failure preserves persistent values")
        try expect(visibleTeam.name == "保存済み" && visibleTeam.logoPath == oldImage,
                   "Save failure restores the model reference held by the screen")
        try expect(!current.context.hasChanges, "Save failure leaves no pending changes")
        let remainingFiles = Set(try FileManager.default.contentsOfDirectory(atPath: current.images.directory.path)
            .filter { $0.hasSuffix(".png") || $0.hasSuffix(".jpg") })
        try expect(remainingFiles == originalFiles, "Save failure retains old images and removes staged replacements")
    }

    private static func exportRefusesToOmitMissingImages() throws {
        let current = try fixture()
        defer { current.cleanup() }
        current.context.insert(Team(name: "ホーム", logoPath: "missing.png"))
        try current.context.save()
        var failed = false
        do { _ = try backup(in: current) } catch { failed = true }
        try expect(failed, "Export reports a missing stored image instead of silently omitting it")
    }
}
