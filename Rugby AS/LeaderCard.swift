import SwiftUI
import UIKit
import Vision

/// ランキング1位のカード(サッカーアプリの「得点王」カードの形)。
/// 背景はチームカラーのグラデーション、写真は枠なしで顔を中心に切り抜いて右側に大きく置く。
struct LeaderCard: View {
    let name: String
    let teamName: String
    let value: Int
    let unit: String
    /// 数字の補足(例: 「10/12本」)
    var detail: String? = nil
    let imagePath: String?
    let number: Int?
    let teamColorHex: String?
    var valueText: String? = nil

    /// チームカラー未登録なら標準の紺
    private var baseColor: Color {
        if let hex = teamColorHex, let color = Color(hex: hex) { return color }
        return Color(red: 0.10, green: 0.20, blue: 0.45)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            LinearGradient(colors: [blend(baseColor, toward: .black, 0.35), baseColor, blend(baseColor, toward: .white, 0.25)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)

            HStack(alignment: .bottom, spacing: 0) {
                Spacer(minLength: 0)
                photo
                    .frame(width: 170, height: 170)
                    // 下の端をカードに溶け込ませる
                    .mask(LinearGradient(colors: [.black, .black, .clear], startPoint: .top, endPoint: .bottom))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("1")
                    .font(.caption.weight(.black))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 0)
                Text(name)
                    .font(.title3.weight(.heavy))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Text(teamName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(valueText ?? "\(value)")
                        .font(.system(size: 40, weight: .black).monospacedDigit())
                        .lineLimit(1).minimumScaleFactor(0.65)
                    Text(unit)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.8))
                    if let detail {
                        Text(detail)
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            .padding(16)
            .frame(maxWidth: 210, alignment: .leading)
        }
        .frame(height: 170)
        .clipped()
        .accessibilityElement(children: .combine)
    }

    /// 色を黒や白に少し近づける(iOS 17 でも使えるように自前で計算)
    private func blend(_ color: Color, toward target: UIColor, _ amount: CGFloat) -> Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
        guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a),
              target.getRed(&tr, green: &tg, blue: &tb, alpha: &ta) else { return color }
        return Color(red: r + (tr - r) * amount, green: g + (tg - g) * amount, blue: b + (tb - b) * amount)
    }

    @ViewBuilder
    private var photo: some View {
        if let imagePath {
            FaceCroppedPhoto(name: imagePath)
        } else {
            // 写真がない選手は背番号を大きく
            Text(number.map { "\($0)" } ?? "")
                .font(.system(size: 96, weight: .black))
                .foregroundStyle(.white.opacity(0.22))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 顔の位置を見つけて、顔から肩あたりが入るように切り抜いた写真。
/// 顔は iPhone の中で探す(ネットには送らない)。見つからなければ上寄りの中央で切り抜く。元の写真は変えない。
struct FaceCroppedPhoto: View {
    let name: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.clear
            }
        }
        .task(id: name) {
            image = await FaceCrop.image(named: name)
        }
    }
}

enum FaceCrop {
    // NSCache は複数のスレッドから安全に使える
    private nonisolated(unsafe) static let cache = NSCache<NSString, UIImage>()

    nonisolated static func image(named name: String) async -> UIImage? {
        if let cached = cache.object(forKey: name as NSString) { return cached }
        let result = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let source = ImageStorage.thumbnail(named: name, maxDimension: 900),
                  let cgImage = source.cgImage else { return nil }
            let cropped = cgImage.cropping(to: cropRect(for: cgImage)) ?? cgImage
            return UIImage(cgImage: cropped, scale: source.scale, orientation: .up)
        }.value
        if let result { cache.setObject(result, forKey: name as NSString) }
        return result
    }

    /// 正方形の切り抜き範囲(ピクセル・左上原点)。顔の幅の約2.6倍の正方形で、顔を上から1/3あたりに置く。
    nonisolated static func cropRect(for image: CGImage) -> CGRect {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        // いちばん大きい顔を使う。Vision の座標は左下原点の 0〜1
        if let face = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) {
            let box = face.boundingBox
            let faceWidth = box.width * width
            let side = min(max(faceWidth * 2.6, 1), min(width, height))
            let centerX = box.midX * width
            let faceTop = (1 - box.maxY) * height
            let originY = faceTop - side * 0.18
            return clamp(CGRect(x: centerX - side / 2, y: originY, width: side, height: side), width: width, height: height)
        }
        let side = min(width, height)
        return clamp(CGRect(x: (width - side) / 2, y: 0, width: side, height: side), width: width, height: height)
    }

    private nonisolated static func clamp(_ rect: CGRect, width: CGFloat, height: CGFloat) -> CGRect {
        var r = rect
        r.origin.x = min(max(0, r.origin.x), max(0, width - r.width))
        r.origin.y = min(max(0, r.origin.y), max(0, height - r.height))
        return r.integral
    }
}
