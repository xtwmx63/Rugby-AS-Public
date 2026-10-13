//
//  VideoStorage.swift
//  Rugby AS
//
//  試合動画を端末のドキュメントディレクトリに保存・読込・削除する。
//  YouTube は youtube-<動画ID> という参照名で同じ一覧に保持する。
//

import Foundation

enum VideoStorage {
    nonisolated private static let matchVideoMapKey = "matchVideoFileNamesByMatchID"
    nonisolated private static let copyBufferSize = 4 * 1024 * 1024

    nonisolated private static var directory: URL {
        URL.documentsDirectory.appendingPathComponent("MatchVideos", isDirectory: true)
    }

    nonisolated static func save(
        from sourceURL: URL,
        progress: ((Double, Int64, Int64) -> Void)? = nil
    ) throws -> String {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let fileExtension = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
        let name = UUID().uuidString + "." + fileExtension
        let destinationURL = directory.appendingPathComponent(name)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        let didStartAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let totalBytes = try fileSize(for: sourceURL)
        try validateAvailableStorage(requiredFileSize: totalBytes)
        progress?(0, 0, totalBytes)

        do {
            try copyItem(
                from: sourceURL,
                to: destinationURL,
                totalBytes: totalBytes,
                progress: progress
            )
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }

        excludeFromBackup(destinationURL)
        return name
    }

    /// 動画をiCloudバックアップの対象から外す。
    /// 試合動画は数GBあり、含めるとユーザーのiCloud容量を圧迫するため。
    /// (動画は写真アプリ等から再取り込みできるので、消えても復元手段がある)
    nonisolated private static func excludeFromBackup(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }

    /// The directory exclusion also covers existing and subsequently restored
    /// videos. Do not enumerate and rewrite every movie's attributes at startup.
    nonisolated static func excludeAllVideosFromBackup() {
        guard FileManager.default.fileExists(atPath: directory.path),
              (try? directory.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup != true
        else { return }
        excludeFromBackup(directory)
    }

    nonisolated static func videoNames(for matchID: UUID) -> [String] {
        matchVideoMap[matchID.uuidString, default: []]
    }

    /// 動画のある試合と、その動画の名前(全試合を1つずつ調べるより速い)
    nonisolated static var videoNamesByMatch: [UUID: [String]] {
        Dictionary(matchVideoMap.compactMap { key, names in UUID(uuidString: key).map { ($0, names) } },
                   uniquingKeysWith: { first, _ in first })
    }

    nonisolated static func videoName(for matchID: UUID) -> String? {
        videoNames(for: matchID).first
    }

    nonisolated static func setVideoNames(_ names: [String], for matchID: UUID) {
        var map = matchVideoMap
        let cleanedNames = names.filter { !$0.isEmpty }
        if cleanedNames.isEmpty {
            map.removeValue(forKey: matchID.uuidString)
        } else {
            map[matchID.uuidString] = cleanedNames
        }
        UserDefaults.standard.set(map, forKey: matchVideoMapKey)
    }

    nonisolated static func appendVideoNames(_ names: [String], for matchID: UUID) {
        let appendedNames = videoNames(for: matchID) + names.filter { !$0.isEmpty }
        setVideoNames(appendedNames, for: matchID)
    }

    nonisolated static func setVideoName(_ name: String?, for matchID: UUID) {
        if let name {
            setVideoNames([name], for: matchID)
        } else {
            setVideoNames([], for: matchID)
        }
    }

    nonisolated static func removeVideoName(_ name: String, for matchID: UUID) {
        setVideoNames(videoNames(for: matchID).filter { $0 != name }, for: matchID)
    }

    nonisolated static func deleteVideo(for matchID: UUID) {
        deleteVideos(for: matchID)
    }

    nonisolated static func deleteVideos(for matchID: UUID) {
        for name in videoNames(for: matchID) {
            delete(named: name)
        }
        setVideoNames([], for: matchID)
    }

    nonisolated static func url(named name: String) -> URL? {
        guard isSafeFileName(name), YouTubeVideoLink.videoID(forSourceName: name) == nil else { return nil }
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    /// A valid YouTube reference can be opened without a local movie file.
    /// Network access and permission to play are checked by the player itself.
    nonisolated static func isAvailable(named name: String) -> Bool {
        YouTubeVideoLink.videoID(forSourceName: name) != nil || url(named: name) != nil
    }

    nonisolated static func delete(named name: String) {
        guard let url = url(named: name) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    nonisolated static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 255
            && !name.contains("/") && !name.contains("\\") && !name.contains(":")
            && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    nonisolated static func preservingMissingNames(edited: [String], stored: [String],
                                                   exists: (String) -> Bool = { url(named: $0) != nil }) -> [String] {
        var result = edited
        for (index, name) in stored.enumerated()
            where YouTubeVideoLink.videoID(forSourceName: name) == nil && !exists(name) && !result.contains(name) {
            result.insert(name, at: min(index, result.count))
        }
        return result
    }

    /// Restore a missing slot without changing any event or kickoff reference.
    /// Stage under a fresh name and move only after the copy completes; never overwrite existing media.
    nonisolated static func recover(from source: URL, as originalName: String, destinationDirectory: URL? = nil) throws {
        guard isSafeFileName(originalName), YouTubeVideoLink.videoID(forSourceName: originalName) == nil
        else { throw VideoStorageError.copyFailed }
        let folder = destinationDirectory ?? directory
        let destination = folder.appendingPathComponent(originalName)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw VideoStorageError.copyFailed }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let bytes = try fileSize(for: source)
        if destinationDirectory == nil { try validateAvailableStorage(requiredFileSize: bytes) }
        let staged = folder.appendingPathComponent(UUID().uuidString + ".partial")
        defer { try? FileManager.default.removeItem(at: staged) }
        try copyItem(from: source, to: staged, totalBytes: bytes, progress: nil)
        excludeFromBackup(staged)
        try FileManager.default.moveItem(at: staged, to: destination)
    }

    nonisolated private static var matchVideoMap: [String: [String]] {
        let rawMap = UserDefaults.standard.dictionary(forKey: matchVideoMapKey) ?? [:]
        var map: [String: [String]] = [:]

        for (matchID, value) in rawMap {
            if let names = value as? [String] {
                map[matchID] = names
            } else if let name = value as? String {
                map[matchID] = [name]
            }
        }

        return map
    }

    nonisolated private static func fileSize(for sourceURL: URL) throws -> Int64 {
        let resourceValues = try sourceURL.resourceValues(forKeys: [.fileSizeKey])
        return Int64(max(1, resourceValues.fileSize ?? 1))
    }

    nonisolated private static func validateAvailableStorage(requiredFileSize fileSize: Int64) throws {
        let documentsValues = try URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let availableCapacity = documentsValues.volumeAvailableCapacityForImportantUsage else { return }
        let requiredCapacity = Int64(Double(fileSize) * 1.15) + 200_000_000
        if availableCapacity < requiredCapacity {
            throw VideoStorageError.insufficientStorage
        }
    }

    nonisolated private static func copyItem(
        from sourceURL: URL,
        to destinationURL: URL,
        totalBytes: Int64,
        progress: ((Double, Int64, Int64) -> Void)?
    ) throws {
        guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else {
            throw VideoStorageError.copyFailed
        }

        let sourceHandle = try FileHandle(forReadingFrom: sourceURL)
        let destinationHandle = try FileHandle(forWritingTo: destinationURL)
        defer {
            try? sourceHandle.close()
            try? destinationHandle.close()
        }

        var copiedBytes: Int64 = 0
        while true {
            guard let chunk = try sourceHandle.read(upToCount: copyBufferSize), !chunk.isEmpty else {
                break
            }
            try destinationHandle.write(contentsOf: chunk)
            copiedBytes += Int64(chunk.count)
            let fraction = min(1, Double(copiedBytes) / Double(max(1, totalBytes)))
            progress?(fraction, copiedBytes, totalBytes)
        }

        guard copiedBytes == totalBytes else { throw VideoStorageError.copyFailed }
        try destinationHandle.synchronize()
        progress?(1, totalBytes, totalBytes)
    }
}

enum VideoStorageError: Error {
    case insufficientStorage
    case copyFailed
}

extension Notification.Name {
    nonisolated static let videoStorageCopyProgress = Notification.Name("VideoStorageCopyProgress")
}
