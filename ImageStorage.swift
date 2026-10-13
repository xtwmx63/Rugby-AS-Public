//
//  ImageStorage.swift
//  Rugby AS
//
//  選手の顔写真 / チームのロゴ画像を端末のドキュメントディレクトリに
//  保存・読込・削除するユーティリティ。SwiftData にはファイル名だけを保持する。
//

import Foundation
import UIKit

enum ImageStorage {
    nonisolated private static var directory: URL {
        URL.documentsDirectory
    }

    // body が再描画されるたびにディスクから読み直すと体感ラグが出るので、
    // 画像はファイル名をキーにメモリキャッシュしておく。
    // NSCache synchronizes concurrent lookups/insertions internally.
    nonisolated(unsafe) private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 256
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    // Decode one image at a time outside the UI thread. A full roster must not
    // launch dozens of simultaneous full-resolution image allocations.
    nonisolated private static let decodeQueue = DispatchQueue(label: "RugbyAS.image-decoding", qos: .userInitiated)

    /// データをリサイズ（長辺 1024px）+ JPEG quality 0.8 で保存し、ファイル名を返す。失敗時 nil。
    static func save(_ data: Data) -> String? {
        guard let resized = downsample(data) else { return nil }
        guard let jpegData = resized.jpegData(compressionQuality: 0.8) else { return nil }
        return write(jpegData, image: resized, fileExtension: "jpg")
    }

    /// 透明背景を保持したまま PNG で保存する。背景削除後の選手写真に使う。
    static func savePNG(_ data: Data) -> String? {
        guard let resized = downsample(data) else { return nil }
        guard let pngData = resized.pngData() else { return nil }
        return write(pngData, image: resized, fileExtension: "png")
    }

    /// カード表示用の縮小版(長辺 maxDimension)。ファイル名は使い回されない
    /// (UUID)前提なのでキャッシュは名前+サイズをキーにする。
    nonisolated static func thumbnail(named name: String, maxDimension: CGFloat = 360) -> UIImage? {
        guard isSafeFileName(name) else { return nil }
        let pixels = pixelLimit(maxDimension)
        let key = cacheKey(name: name, pixels: pixels)
        if let cached = cache.object(forKey: key) { return cached }
        // ImageIO downsamples directly from the encoded file. Loading UIImage
        // first would decode the whole original before reducing it for a row.
        guard let cgImage = ImageThumbnailDecoder.image(at: directory.appendingPathComponent(name),
                                                        maxDimension: pixels) else { return nil }
        let image = UIImage(cgImage: cgImage)
        cache.setObject(image, forKey: key, cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }

    nonisolated static func cachedThumbnail(named name: String, maxDimension: CGFloat) -> UIImage? {
        cache.object(forKey: cacheKey(name: name, pixels: pixelLimit(maxDimension)))
    }

    nonisolated static func loadThumbnail(named name: String, maxDimension: CGFloat) async -> UIImage? {
        if let cached = cachedThumbnail(named: name, maxDimension: maxDimension) { return cached }
        return await withCheckedContinuation { continuation in
            decodeQueue.async {
                let image = autoreleasepool { thumbnail(named: name, maxDimension: maxDimension) }
                continuation.resume(returning: image)
            }
        }
    }

    nonisolated static func image(named name: String) -> UIImage? {
        thumbnail(named: name, maxDimension: 1024)
    }

    static func delete(named name: String) {
        guard isSafeFileName(name) else { return }
        let url = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        for pixels in stride(from: 64, through: 1024, by: 64) {
            cache.removeObject(forKey: cacheKey(name: name, pixels: pixels))
        }
    }

    private static func write(_ data: Data, image: UIImage, fileExtension: String) -> String? {
        let name = UUID().uuidString + "." + fileExtension
        let url = directory.appendingPathComponent(name)
        do {
            try data.write(to: url)
            let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
            cache.setObject(image, forKey: cacheKey(name: name, pixels: 1024), cost: cost)
            return name
        } catch {
            return nil
        }
    }

    nonisolated private static func pixelLimit(_ dimension: CGFloat) -> Int {
        guard dimension.isFinite else { return 1024 }
        return Int(ceil(min(1024, max(64, dimension)) / 64)) * 64
    }

    nonisolated private static func cacheKey(name: String, pixels: Int) -> NSString {
        "\(pixels)-\(name)" as NSString
    }

    nonisolated private static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
    }

    /// Import large camera photos without decoding the original at full size.
    private static func downsample(_ data: Data) -> UIImage? {
        guard let image = ImageThumbnailDecoder.image(data: data, maxDimension: 1024) else { return nil }
        return UIImage(cgImage: image)
    }
}
