import Foundation
import ImageIO

// バックアップは、既に端末で保存した画像のバイト列をそのまま戻す。
// JPEG への再圧縮を避けることで、透過 PNG と繰り返し復元した写真の品質を保つ。
struct BackupImageFiles {
    var directory: URL = .documentsDirectory

    func read(named name: String) throws -> Data {
        try Data(contentsOf: fileURL(named: name))
    }

    func save(_ data: Data) throws -> String {
        let fileExtension: String
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            fileExtension = "png"
        } else if data.starts(with: [0xFF, 0xD8, 0xFF]) {
            fileExtension = "jpg"
        } else {
            throw BackupError.unreadableImage
        }
        // 拡張子の判定だけでは、途中で壊れた画像も通ってしまう。
        // 即時復号まで成功した画像だけを戻し、元の画像との誤った差し替えを防ぐ。
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil else {
            throw BackupError.unreadableImage
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = UUID().uuidString + "." + fileExtension
        try data.write(to: fileURL(named: name), options: .atomic)
        return name
    }

    func delete(named name: String) {
        guard let url = try? fileURL(named: name) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func fileURL(named name: String) throws -> URL {
        guard !name.isEmpty, name == (name as NSString).lastPathComponent,
              name != ".", name != ".." else { throw BackupError.unreadableImage }
        return directory.appendingPathComponent(name)
    }
}
