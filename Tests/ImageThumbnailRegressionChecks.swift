import Foundation
import ImageIO

enum ImageThumbnailRegressionChecks {
    private enum Failure: Error { case failed(String) }

    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure.failed(message) }
    }

    static func run() throws {
        try largeImageUsesDisplaySizedBuffer()
        try preservesTransparencyAndOriginalFile()
        try respectsCameraOrientation()
        try expect(ImageThumbnailDecoder.image(data: Data("not an image".utf8), maxDimension: 160) == nil,
                   "Unreadable photos use a placeholder")
        print("PASS: 4 image thumbnail regression checks")
    }

    private static func fixture(width: Int, height: Int, type: String = "public.png", orientation: Int = 1) throws -> Data {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.failed("Fixture context") }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        let bytes = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(bytes as CFMutableData, type as CFString, 1, nil)
        else { throw Failure.failed("Fixture destination") }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        try expect(CGImageDestinationFinalize(destination), "Fixture image encodes")
        return bytes as Data
    }

    private static func largeImageUsesDisplaySizedBuffer() throws {
        let original = try fixture(width: 2048, height: 1024)
        guard let image = ImageThumbnailDecoder.image(data: original, maxDimension: 160) else { throw Failure.failed("Large image decodes") }
        try expect(image.width == 160 && image.height == 80, "A logo decodes only its requested display dimensions")
        try expect(image.bytesPerRow * image.height < 100_000, "A small logo does not retain a multi-megabyte pixel buffer")
    }

    private static func preservesTransparencyAndOriginalFile() throws {
        let original = try fixture(width: 128, height: 64)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try original.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let image = ImageThumbnailDecoder.image(at: file, maxDimension: 64),
              let context = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 256,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Failure.failed("Transparent thumbnail decodes") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 32))
        let pixel = context.data!.assumingMemoryBound(to: UInt8.self)
        try expect(pixel[3] == 0 && pixel[63 * 4 + 3] == 255, "Player cutouts retain transparent and opaque pixels")
        let saved = try Data(contentsOf: file)
        try expect(saved == original, "Thumbnails never rewrite the original photo")
    }

    private static func respectsCameraOrientation() throws {
        let original = try fixture(width: 128, height: 64, type: "public.jpeg", orientation: 6)
        guard let image = ImageThumbnailDecoder.image(data: original, maxDimension: 64) else { throw Failure.failed("Rotated photo decodes") }
        try expect(image.width == 32 && image.height == 64, "Camera orientation is applied while downsampling")
    }
}
