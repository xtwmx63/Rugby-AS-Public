import Foundation
import ImageIO

/// Keep encoded originals on disk and decode only the pixels needed for display.
enum ImageThumbnailDecoder {
    nonisolated static func image(at url: URL, maxDimension: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return image(from: source, maxDimension: maxDimension)
    }

    nonisolated static func image(data: Data, maxDimension: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return image(from: source, maxDimension: maxDimension)
    }

    nonisolated private static func image(from source: CGImageSource, maxDimension: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxDimension)
        ] as CFDictionary)
    }
}
